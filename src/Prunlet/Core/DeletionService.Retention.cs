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
    public RecoveryMaintenanceResult MaintainRecovery(bool apply = false)
    {
        config.Validate();
        using var coordination = AcquireRecoveryCoordination(create: apply);
        return MaintainAllRecoveryCore(apply, incomingBytes: 0, compactAllHistory: true);
    }

    private RecoveryScan ScanRecovery(List<string> warnings, bool collectCandidates = true)
    {
        var scan = new RecoveryScan();
        try
        {
            // 子の列挙では見えない、保存先ディレクトリ自身のADSも保持容量に含める。
            using var root = NativeFiles.OpenAny(config.BackupDirectory);
            NativeFiles.Verify(root, config.BackupDirectory, directory: true);
            scan.Bytes = NativeFiles.NamedStreamBytes(root);
            if (scan.Bytes > 0) warnings.Add("Recovery root alternate streams were retained and counted against the budget.");
        }
        catch (Exception ex) when (IsOperational(ex) || ex is OverflowException)
        {
            scan.Known = false;
            warnings.Add($"Recovery root alternate streams cannot be safely counted and were retained: {ex.Message}");
        }
        foreach (var member in new DirectoryInfo(config.BackupDirectory).EnumerateFileSystemInfos())
        {
            var path = member.FullName;
            var name = member.Name;
            if (name == "maintenance.lock") continue;
            var operation = Guid.TryParseExact(name, "N", out var id) && id.ToString("N") == name;
            var members = operation && collectCandidates ? new HashSet<string>(StringComparer.Ordinal) : null;
            long bytes;
            try
            {
                // 移動記録の別volumeにある実体は専用の走査で数える。不正記録も旧形式へ戻さない。
                if (operation && IsRegistryOperation(name))
                {
                    ScanRegistryRecovery(scan, name, warnings, collectCandidates);
                    continue;
                }
                if (operation && IsRecycleOperation(name))
                {
                    ScanRecycleRecovery(name);
                    continue;
                }
                if (operation && IsMoveOperation(name)) continue;
                bytes = CountRecoveryPayload(member, operation, members);
                scan.Bytes = checked(scan.Bytes + bytes);
                if (name.StartsWith("registry-pending-", StringComparison.Ordinal)
                    || (operation && Directory.EnumerateFileSystemEntries(path).Any(child => Path.GetFileName(child).StartsWith("registry-", StringComparison.OrdinalIgnoreCase))))
                {
                    scan.Known = false;
                    warnings.Add($"Unpublished registry recovery data {name} was retained; capacity is not considered safe for new deletion.");
                }
            }
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
                // 共通ロックのleaseが保存先までの祖先を固定済み。操作フォルダーだけ追加で固定する。
                using var directory = NativeFiles.OpenDirectory(path);
                NativeFiles.Verify(directory, path, directory: true);
                NativeFiles.RejectCaseSensitive(directory);
                using var operationLock = NativeFiles.OpenLock(Path.Combine(path, "operation.lock"));
                NativeFiles.Verify(operationLock, Path.Combine(path, "operation.lock"));
                NativeFiles.VerifySingleLink(operationLock);
                NativeFiles.RejectNamedStreams(Path.Combine(path, "operation.lock"));
                if (RandomAccess.GetLength(operationLock) != 0) throw new InvalidDataException("Operation lock is not empty.");
                // 整理済みの記録だけの操作もロックは確認し、旧版のコピー開始前を見落とさない。
                // 容量の再走査ではmanifestを読み直さず、残るデータと使用中の操作だけを確かめる。
                if (!collectCandidates) continue;
                // 空ファイルのコピーにも期限を適用する。コピーが残らない記録だけを省略する。
                if (bytes == 0 && !members!.Any(member => member.EndsWith(".bak", StringComparison.OrdinalIgnoreCase))) continue;
                var held = new List<FileStream>();
                try
                {
                    var manifest = ReadValidatedJson<OperationManifest>(HoldPurgeMetadata(Path.Combine(path, "manifest.json"), held));
                    ValidateManifest(manifest, name);
                    if (manifest.Items.Select((entry, index) => (entry, index))
                        .Any(pair => !HasRecoveryCopy(manifest, pair.entry) && members!.Contains($"{pair.index:D4}.bak")))
                    {
                        warnings.Add($"Recovery operation {name} contains unpublished or incomplete copies and was retained; explicit purge is required.");
                        continue;
                    }
                    if (bytes > 0 || manifest.Items.Select((entry, index) => (entry, index))
                        .Any(pair => HasRecoveryCopy(manifest, pair.entry) && members!.Contains($"{pair.index:D4}.bak")))
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

    private static long CountRecoveryPayload(FileSystemInfo member, bool operationDirectory = false, HashSet<string>? members = null)
    {
        var path = member.FullName;
        // 列挙時の属性は開き方の選択にだけ使い、型・reparse・正規パスは取得したハンドルで検証する。
        var directory = (member.Attributes & FileAttributes.Directory) != 0;
        using var handle = directory ? NativeFiles.OpenAny(path) : NativeFiles.OpenBackup(path);
        NativeFiles.Verify(handle, path, directory);
        if (directory)
        {
            // このハンドルは削除共有を許さず、祖先も呼出し元の走査ハンドル/root leaseが保持する。
            NativeFiles.RejectCaseSensitive(handle);
            long size = NativeFiles.NamedStreamBytes(handle);
            var children = new DirectoryInfo(path).EnumerateFileSystemInfos();
            if (!operationDirectory)
            {
                foreach (var child in children) size = checked(size + CountRecoveryPayload(child));
                return size;
            }
            // 祖先ハンドルを保持したまま、小さな束ごとに検査する。全件配列化と再帰的な並列化はしない。
            foreach (var batch in children.Chunk(128))
            {
                foreach (var child in batch) members?.Add(child.Name);
                size = checked(size + CountRecoveryBatch(batch));
            }
            return size;
        }
        // ADSの容量も同じハンドルのstream情報から得る。別パスで開き直さない。
        return checked(RandomAccess.GetLength(handle) + NativeFiles.NamedStreamBytes(handle));
    }

    private static long CountRecoveryMember(FileSystemInfo member)
    {
        var name = member.Name;
        if (name is "manifest.json" or "operation.lock" or "purge-intent.json" || PurgeMetadataKind(name) is not null)
        {
            // 名前だけで記録と見なさず、フォルダー・リンク・ADSによる容量計算の迂回を拒否する。
            using var metadata = NativeFiles.OpenBackup(member.FullName);
            NativeFiles.Verify(metadata, member.FullName);
            NativeFiles.VerifySingleLink(metadata);
            NativeFiles.RejectNamedStreams(member.FullName);
            return 0;
        }
        return CountRecoveryPayload(member);
    }

    private static long CountRecoveryBatch(FileSystemInfo[] batch)
    {
        long bytes = 0;
        var workers = Math.Min(4, Environment.ProcessorCount);
        if (batch.Length < 32 || workers == 1)
        {
            foreach (var member in batch) bytes = checked(bytes + CountRecoveryMember(member));
            return bytes;
        }
        var gate = new object();
        Exception? failure = null;
        Parallel.ForEach(batch, new ParallelOptions { MaxDegreeOfParallelism = workers }, () => 0L,
            (member, loop, local) =>
            {
                try { return checked(local + CountRecoveryMember(member)); }
                catch (Exception ex) when (IsOperational(ex) || ex is OverflowException)
                {
                    Interlocked.CompareExchange(ref failure, ex, null);
                    loop.Stop();
                    return local;
                }
            }, local =>
            {
                lock (gate)
                {
                    try { bytes = checked(bytes + local); }
                    catch (OverflowException ex) { Interlocked.CompareExchange(ref failure, ex, null); }
                }
            });
        // 全workerのハンドル解放後に失敗を返し、部分集計を安全な容量として扱わない。
        if (failure is not null) throw new IOException(failure.Message, failure);
        return bytes;
    }

    private RecoveryCoordination AcquireRecoveryCoordination(bool create, string[]? deletionTargets = null)
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
                    handle = deletionTargets is not null ? NativeFiles.OpenSharedCoordination(path)
                        : create ? NativeFiles.OpenOrCreateLock(path) : NativeFiles.OpenLock(path);
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
            if (deletionTargets is not null)
            {
                // 同じtargetは排他、ancestorは共有。hash衝突は強いclaimへ統合し全batchを昇順で取得する。
                var claims = new SortedDictionary<uint, bool>();
                foreach (var target in deletionTargets)
                {
                    var current = target;
                    var exclusive = true;
                    while (!string.IsNullOrEmpty(current))
                    {
                        var hash = System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(current.TrimEnd('\\').ToUpperInvariant()));
                        var slot = (uint)(hash[0] | hash[1] << 8);
                        claims[slot] = exclusive || claims.GetValueOrDefault(slot);
                        exclusive = false;
                        current = Path.GetDirectoryName(current);
                    }
                }
                foreach (var claim in claims)
                    while (!NativeFiles.TryClaimCoordination(handle, claim.Key, claim.Value))
                    {
                        if (waiting.Elapsed >= nextReport)
                        {
                            RecoveryLockProgress?.Invoke(waiting.Elapsed, false);
                            reported = true;
                            nextReport = waiting.Elapsed + TimeSpan.FromSeconds(5);
                        }
                        Thread.Sleep(100);
                    }
            }
            if (reported) RecoveryLockProgress?.Invoke(waiting.Elapsed, true);
            return new RecoveryCoordination(root, handle);
        }
        catch { handle?.Dispose(); root.Dispose(); throw; }
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
