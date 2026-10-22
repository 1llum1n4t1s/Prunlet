using System.ComponentModel;
using System.Diagnostics;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed class RecoveryMaintenanceResult
{
    public bool DryRun { get; set; }
    public int RetentionDays { get; set; }
    public long MaxRecoveryBytes { get; set; }
    public long RetainedBytesBefore { get; set; }
    // dry-run の場合は検証済み整理候補を除いた見積り。
    public long RetainedBytesAfter { get; set; }
    public long PurgedBytes { get; set; }
    public long PlannedPurgeBytes { get; set; }
    public bool CapacityKnown { get; set; }
    public bool BudgetSatisfied { get; set; }
    public bool Complete { get; set; }
    public HistoryCompactionResult HistoryCompaction { get; set; } = new();
    public List<PurgeResult> Operations { get; set; } = [];
    public List<string> Warnings { get; set; } = [];
}

public sealed partial class DeletionService
{
    private long? remainingRecoveryBytes;

    public RecoveryMaintenanceResult MaintainRecovery(bool apply = false)
    {
        config.Validate();
        using var coordination = AcquireRecoveryCoordination(create: apply);
        return MaintainRecoveryCore(apply, incomingBytes: 0, compactAllHistory: true);
    }

    private RecoveryMaintenanceResult MaintainRecoveryCore(bool apply, long incomingBytes, bool compactAllHistory = false)
    {
        var result = new RecoveryMaintenanceResult
        {
            DryRun = !apply, RetentionDays = config.RetentionDays, MaxRecoveryBytes = config.MaxRecoveryBytes
        };
        var scan = ScanRecovery(result.Warnings);
        result.RetainedBytesBefore = result.RetainedBytesAfter = scan.Bytes;
        result.CapacityKnown = scan.Known;
        var now = DateTimeOffset.UtcNow;
        var expiry = now.AddDays(-config.RetentionDays);
        // 上限より大きい操作は既存コピーを安全に整理し、今回の見積り分だけを予約する。
        var retainedBudget = Math.Max(0, config.MaxRecoveryBytes - incomingBytes);
        foreach (var candidate in scan.Candidates.OrderBy(candidate => candidate.CreatedUtc).ThenBy(candidate => candidate.Id, StringComparer.Ordinal))
        {
            if (candidate.CreatedUtc > now)
            {
                result.Warnings.Add($"Recovery operation {candidate.Id} has a future timestamp and was retained.");
                continue;
            }
            if (candidate.CreatedUtc > expiry && result.RetainedBytesAfter <= retainedBudget) continue;
            try
            {
                // 自動整理も既存のintent永続化・コピー検証・操作ロックを通す。
                var purged = PurgeCore(candidate.Id, apply);
                result.Operations.Add(purged);
                result.Warnings.AddRange(purged.Warnings);
                var bytes = apply ? purged.PurgedBytes
                    : purged.Items.Where(item => item.Status == "would_purge").Aggregate(0L, (sum, item) => checked(sum + (item.Size ?? 0)));
                result.RetainedBytesAfter = checked(result.RetainedBytesAfter - bytes);
                if (apply) result.PurgedBytes = checked(result.PurgedBytes + bytes);
                else result.PlannedPurgeBytes = checked(result.PlannedPurgeBytes + bytes);
                if (purged.Items.Any(item => item.Status == "failed"))
                    result.Warnings.Add($"Recovery operation {candidate.Id} could not be completely purged.");
            }
            catch (Exception ex) when (IsOperational(ex))
            {
                result.Warnings.Add($"Recovery operation {candidate.Id} was retained: {ex.Message}");
            }
        }
        if (apply)
        {
            // 途中失敗や旧プロセスが残したコピーも、推測せず実体を数え直す。
            var after = ScanRecovery(result.Warnings, collectCandidates: false);
            result.RetainedBytesAfter = after.Bytes;
            result.CapacityKnown = after.Known;
        }
        result.BudgetSatisfied = result.CapacityKnown && result.RetainedBytesAfter <= retainedBudget;
        if (!result.CapacityKnown) result.Warnings.Add("Recovery capacity is unknown because some data is busy or cannot be safely inspected.");
        else if (!result.BudgetSatisfied) result.Warnings.Add("Retained recovery data exceeds the available recovery budget; unverified copies were retained.");
        // 定期・明示maintainは既存履歴も対象とする。削除前は今回purgeした操作だけを検証し、
        // 毎削除で全履歴を開き直さない。共通ロックは呼出し元が保持済み。
        result.HistoryCompaction = CompactHistoryCore(apply, automatic: true,
            operationIds: compactAllHistory ? null : result.Operations.Select(operation => operation.OperationId));
        foreach (var operation in result.HistoryCompaction.Operations.Where(operation => operation.Status == "failed"))
            result.Warnings.Add($"History operation {operation.OperationId} could not be compressed: {operation.Error}");
        result.Warnings = result.Warnings.Distinct(StringComparer.Ordinal).ToList();
        result.Complete = result.BudgetSatisfied && result.Warnings.Count == 0
            && result.Operations.All(operation => operation.Items.All(item => item.Status != "failed"));
        return result;
    }

    private RecoveryScan ScanRecovery(List<string> warnings, bool collectCandidates = true)
    {
        var scan = new RecoveryScan();
        try
        {
            // 子の列挙では見えない、保存先ディレクトリ自身のADSも保持容量に含める。
            using var root = NativeFiles.OpenAny(config.BackupDirectory);
            NativeFiles.Verify(root, config.BackupDirectory, directory: true);
            scan.Bytes = CountNamedStreams(config.BackupDirectory, root);
            if (scan.Bytes > 0) warnings.Add("Recovery root alternate streams were retained and counted against the budget.");
        }
        catch (Exception ex) when (IsOperational(ex) || ex is OverflowException)
        {
            scan.Known = false;
            warnings.Add($"Recovery root alternate streams cannot be safely counted and were retained: {ex.Message}");
        }
        foreach (var path in Directory.EnumerateFileSystemEntries(config.BackupDirectory))
        {
            var name = Path.GetFileName(path);
            if (name == "maintenance.lock") continue;
            var operation = Guid.TryParseExact(name, "N", out var id) && id.ToString("N") == name;
            long bytes;
            try { bytes = CountRecoveryPayload(path, operation); scan.Bytes = checked(scan.Bytes + bytes); }
            catch (Exception ex) when (IsOperational(ex) || ex is OverflowException)
            {
                scan.Known = false;
                warnings.Add($"Recovery member {name} cannot be safely counted and was retained: {ex.Message}");
                continue;
            }
            if (!operation)
            {
                warnings.Add($"Unknown recovery member {name} was retained and counted against the budget.");
                continue;
            }
            try
            {
                using var directories = PathPolicy.PinRecoveryDirectories(path);
                using var operationLock = NativeFiles.OpenLock(Path.Combine(path, "operation.lock"));
                NativeFiles.Verify(operationLock, Path.Combine(path, "operation.lock"));
                NativeFiles.VerifySingleLink(operationLock);
                NativeFiles.RejectNamedStreams(Path.Combine(path, "operation.lock"));
                if (RandomAccess.GetLength(operationLock) != 0) throw new InvalidDataException("Operation lock is not empty.");
                // 整理済みの記録だけの操作もロックは確認し、旧版のコピー開始前を見落とさない。
                // 容量の再走査ではmanifestを読み直さず、残るデータと使用中の操作だけを確かめる。
                if (!collectCandidates) continue;
                var members = Directory.EnumerateFileSystemEntries(path).Select(Path.GetFileName).ToHashSet(StringComparer.Ordinal);
                // 空ファイルのコピーにも期限を適用する。コピーが残らない記録だけを省略する。
                if (bytes == 0 && !members.Any(member => member?.EndsWith(".bak", StringComparison.OrdinalIgnoreCase) == true)) continue;
                var held = new List<FileStream>();
                try
                {
                    var manifest = ReadValidatedJson<OperationManifest>(HoldPurgeMetadata(Path.Combine(path, "manifest.json"), held));
                    ValidateManifest(manifest, name);
                    if (manifest.Items.Select((entry, index) => (entry, index))
                        .Any(pair => !HasRecoveryCopy(manifest, pair.entry) && members.Contains($"{pair.index:D4}.bak")))
                    {
                        warnings.Add($"Recovery operation {name} contains unpublished or incomplete copies and was retained; explicit purge is required.");
                        continue;
                    }
                    if (bytes > 0 || manifest.Items.Select((entry, index) => (entry, index))
                        .Any(pair => HasRecoveryCopy(manifest, pair.entry) && members.Contains($"{pair.index:D4}.bak")))
                        scan.Candidates.Add(new RecoveryCandidate(name, manifest.CreatedUtc));
                }
                finally { foreach (var stream in held) stream.Dispose(); }
            }
            catch (IOException ex)
            {
                // 旧版はrootロックを取得しない。操作中なら現在のサイズを上限判定に使わない。
                scan.Known = false;
                warnings.Add($"Recovery operation {name} is busy or unavailable and was retained: {ex.Message}");
            }
            catch (Exception ex) when (IsOperational(ex))
            {
                warnings.Add($"Recovery operation {name} has invalid metadata and was retained: {ex.Message}");
            }
        }
        return scan;
    }

    private static long CountRecoveryPayload(string path, bool operationDirectory = false)
    {
        using var handle = NativeFiles.OpenAny(path);
        if (NativeFiles.IsReparse(handle)) throw new IOException("Recovery links are not followed.");
        var directory = NativeFiles.IsDirectory(handle);
        NativeFiles.Verify(handle, path, directory);
        if (directory)
        {
            // このハンドルは削除共有を許さず、祖先も呼出し元の走査ハンドル/root leaseが保持する。
            NativeFiles.RejectCaseSensitive(handle);
            long size = CountNamedStreams(path, handle);
            foreach (var child in Directory.EnumerateFileSystemEntries(path))
            {
                var name = Path.GetFileName(child);
                if (operationDirectory && (name is "manifest.json" or "operation.lock" or "purge-intent.json" || PurgeMetadataKind(name) is not null))
                {
                    // 名前だけで記録と見なさず、フォルダー・リンク・ADSによる容量計算の迂回を拒否する。
                    using var metadata = NativeFiles.OpenBackup(child);
                    NativeFiles.Verify(metadata, child);
                    NativeFiles.VerifySingleLink(metadata);
                    NativeFiles.RejectNamedStreams(child);
                    continue;
                }
                size = checked(size + CountRecoveryPayload(child));
            }
            return size;
        }
        using var payload = NativeFiles.OpenBackup(path);
        NativeFiles.Verify(payload, path);
        return checked(RandomAccess.GetLength(payload) + CountNamedStreams(path, payload));
    }

    private static long CountNamedStreams(string path, SafeFileHandle handle)
    {
        long bytes = 0;
        foreach (var name in NativeFiles.NamedStreams(handle))
        {
            using var stream = NativeFiles.OpenStream(path, name);
            if (NativeFiles.Identity(stream) != NativeFiles.Identity(handle)) throw new IOException("Recovery stream identity changed.");
            bytes = checked(bytes + RandomAccess.GetLength(stream));
        }
        return bytes;
    }

    private RecoveryCoordination AcquireRecoveryCoordination(bool create)
    {
        config.Validate();
        var root = PathPolicy.PinRecoveryDirectories(config.BackupDirectory);
        SafeFileHandle? handle = null;
        try
        {
            var path = Path.Combine(config.BackupDirectory, "maintenance.lock");
            // NativeFilesはWin32の未存在もIOExceptionに統一する。dry-runでロックを新設しない。
            if (!create && !Directory.EnumerateFileSystemEntries(config.BackupDirectory)
                .Any(member => Path.GetFileName(member).Equals("maintenance.lock", StringComparison.OrdinalIgnoreCase)))
                return new RecoveryCoordination(root, null);
            var waiting = Stopwatch.StartNew();
            var nextReport = TimeSpan.FromSeconds(1);
            var reported = false;
            while (true)
            {
                try
                {
                    handle = create ? NativeFiles.OpenOrCreateLock(path) : NativeFiles.OpenLock(path);
                    break;
                }
                catch (FileNotFoundException) when (!create) { return new RecoveryCoordination(root, null); }
                catch (IOException ex) when (ex.InnerException is Win32Exception { NativeErrorCode: 32 or 33 })
                {
                    // 大量操作は数分以上かかる。取得競合だけを解放まで待ち、排他と容量上限を維持する。
                    if (waiting.Elapsed >= nextReport)
                    {
                        RecoveryLockProgress?.Invoke(waiting.Elapsed, false);
                        reported = true;
                        nextReport = waiting.Elapsed + TimeSpan.FromSeconds(5);
                    }
                    Thread.Sleep(100);
                }
            }
            NativeFiles.Verify(handle, path);
            NativeFiles.VerifySingleLink(handle);
            NativeFiles.RejectNamedStreams(path);
            if (RandomAccess.GetLength(handle) != 0) throw new InvalidDataException("Recovery coordination lock is not empty.");
            if (reported) RecoveryLockProgress?.Invoke(waiting.Elapsed, true);
            return new RecoveryCoordination(root, handle);
        }
        catch { handle?.Dispose(); root.Dispose(); throw; }
    }

    private void ReserveRecoveryBytes(int count)
    {
        if (remainingRecoveryBytes is null) throw new InvalidOperationException("Recovery writes require the capacity coordination lease.");
        if (count > remainingRecoveryBytes.Value) throw new IOException("Recovery budget exhausted; this original target was retained.");
        // 書込み失敗時も予約を戻さず、途中コピーを含む実サイズが上限を超えないようにする。
        remainingRecoveryBytes -= count;
    }

    private sealed class RecoveryScan
    {
        internal long Bytes;
        internal bool Known = true;
        internal List<RecoveryCandidate> Candidates { get; } = [];
    }
    private sealed record RecoveryCandidate(string Id, DateTimeOffset CreatedUtc);
    private sealed class RecoveryCoordination(DirectoryLease root, SafeFileHandle? handle) : IDisposable
    {
        public void Dispose() { handle?.Dispose(); root.Dispose(); }
    }
}
