using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    // 呼出し元が共通の容量ロックを保持する。旧コピーと移動実体を同じ順序で整理する。
    private RecoveryMaintenanceResult MaintainAllRecoveryCore(bool apply, long incomingBytes, bool compactAllHistory = false)
    {
        if (incomingBytes < 0) throw new ArgumentOutOfRangeException(nameof(incomingBytes));
        var result = new RecoveryMaintenanceResult
        {
            DryRun = !apply, RetentionDays = config.RetentionDays, MaxRecoveryBytes = config.MaxRecoveryBytes
        };
        var scan = ScanAllRecovery(result.Warnings, reconcile: apply);
        result.RetainedBytesBefore = result.RetainedBytesAfter = scan.Bytes;
        result.CapacityKnown = scan.Known;
        var now = DateTimeOffset.UtcNow;
        var expiry = now.AddDays(-config.RetentionDays);
        var retainedBudget = incomingBytes >= config.MaxRecoveryBytes ? 0 : config.MaxRecoveryBytes - incomingBytes;
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
                var purged = PurgeCore(candidate.Id, apply);
                result.Operations.Add(purged);
                result.Warnings.AddRange(purged.Warnings);
                var bytes = apply ? purged.PurgedBytes
                    : purged.Items.Where(item => item.Status == "would_purge").Aggregate(0L, (sum, item) => checked(sum + (item.Size ?? 0)));
                result.RetainedBytesAfter = Math.Max(0, checked(result.RetainedBytesAfter - bytes));
                if (apply) result.PurgedBytes = checked(result.PurgedBytes + bytes);
                else result.PlannedPurgeBytes = checked(result.PlannedPurgeBytes + bytes);
                if (purged.Items.Any(item => item.Status == "failed"))
                    result.Warnings.Add($"Recovery operation {candidate.Id} could not be completely purged.");
            }
            catch (Exception ex) when (IsOperational(ex) || ex is OverflowException)
            {
                result.Warnings.Add($"Recovery operation {candidate.Id} was retained: {ex.Message}");
            }
        }
        if (apply)
        {
            // 一部の子だけ消せた場合も、manifestの古い見積りでなく残った実体を再計測する。
            var after = ScanAllRecovery(result.Warnings, collectCandidates: false, reconcile: true);
            result.RetainedBytesAfter = after.Bytes;
            result.CapacityKnown = after.Known;
        }
        result.BudgetSatisfied = result.CapacityKnown && result.RetainedBytesAfter <= retainedBudget;
        if (!result.CapacityKnown) result.Warnings.Add("Recovery capacity is unknown because some data is busy or cannot be safely inspected.");
        else if (!result.BudgetSatisfied) result.Warnings.Add("Recovery data could not be reduced enough to reserve the configured budget.");
        result.HistoryCompaction = CompactHistoryCore(apply, automatic: true,
            operationIds: compactAllHistory ? null : result.Operations.Select(operation => operation.OperationId));
        foreach (var operation in result.HistoryCompaction.Operations.Where(operation => operation.Status == "failed"))
            result.Warnings.Add($"History operation {operation.OperationId} could not be compressed: {operation.Error}");
        result.Warnings = result.Warnings.Distinct(StringComparer.Ordinal).ToList();
        result.Complete = result.BudgetSatisfied && result.Warnings.Count == 0
            && result.Operations.All(operation => operation.Items.All(item => item.Status != "failed"));
        return result;
    }

    private RecoveryScan ScanAllRecovery(List<string> warnings, bool collectCandidates = true, bool reconcile = false)
    {
        var scan = ScanRecovery(warnings, collectCandidates);
        var inventory = new Dictionary<string, Dictionary<string, MoveInventoryOperation>>(StringComparer.Ordinal);
        foreach (var directory in Directory.EnumerateFileSystemEntries(config.BackupDirectory))
        {
            var id = Path.GetFileName(directory);
            if (!Guid.TryParseExact(id, "N", out var parsed) || parsed.ToString("N") != id) continue;
            try
            {
                if (!IsMoveOperation(id)) continue;
                using var record = OpenMoveRecord(id);
                var hasPayload = false;
                foreach (var entry in record.Manifest.Entries)
                {
                    if (entry.State == "already_absent") continue;
                    using var store = OpenRecordedMoveStore(record, entry);
                    var payload = MovePayloadPath(record.Manifest, entry);
                    var identity = InspectMoveLocation(payload);
                    var key = MoveInventoryKey(store.VolumeName, store.RootIdentity);
                    if (!inventory.TryGetValue(key, out var operations)) inventory.Add(key, operations = new(StringComparer.Ordinal));
                    if (!operations.TryGetValue(id, out var operation))
                        operations.Add(id, operation = new MoveInventoryOperation(store.OperationIdentity));
                    if (!SameMoveObject(operation.Identity, store.OperationIdentity))
                        throw new InvalidDataException("Move entries disagree about the recovery operation directory identity.");
                    operation.Payloads.Add(entry.PayloadName, new MoveInventoryPayload(entry.Identity!, identity is not null));
                    if (identity is null)
                    {
                        ValidateMissingMovePayload(record, entry, reconcile);
                        continue;
                    }
                    _ = IsCancelledMoveEntry(record, entry);
                    VerifyMovePayloadIdentity(entry, identity, InspectMoveOriginal(entry));
                    if (ReadMoveReceipt(record, entry, "restore", "complete") is not null
                        || ReadMoveReceipt(record, entry, "purge", "complete") is not null)
                        throw new InvalidDataException("A completed move receipt still has a recovery payload; both were retained.");
                    hasPayload = true;
                }
                if (collectCandidates && hasPayload) scan.Candidates.Add(new RecoveryCandidate(id, record.Manifest.CreatedUtc));
            }
            catch (Exception ex) when (IsOperational(ex) || ex is OverflowException)
            {
                scan.Known = false;
                warnings.Add($"Move recovery operation {id} cannot be safely inspected and was retained: {ex.Message}");
            }
        }
        // 既存recordだけを起点にしない。記録と実体の両側を突合してから実在payloadを数える。
        var inspected = new HashSet<string>(StringComparer.Ordinal);
        VolumeRecoveryStore.InspectExistingRoots(config, (root, volumeName, rootIdentity) =>
        {
            var key = MoveInventoryKey(volumeName, rootIdentity);
            inspected.Add(key);
            inventory.TryGetValue(key, out var operations);
            var seenOperations = new HashSet<string>(StringComparer.Ordinal);
            foreach (var member in Directory.EnumerateFileSystemEntries(root))
            {
                var id = Path.GetFileName(member);
                if (id == "store.json") continue;
                using var store = VolumeRecoveryStore.OpenInventoryOperation(root, volumeName, rootIdentity, id);
                var members = new HashSet<string>(StringComparer.Ordinal);
                foreach (var path in Directory.EnumerateFileSystemEntries(store.OperationPath))
                    if (!members.Add(Path.GetFileName(path)) || members.Count > 256)
                        throw new InvalidDataException("Recovery operation contains too many or duplicate payload names.");
                if (operations is null || !operations.TryGetValue(id, out var expected))
                {
                    // manifest公開前の中断で残った空opは、ACL・ID・ADSを検証した場合だけ0と判断する。
                    if (members.Count != 0) throw new InvalidDataException($"Unreferenced recovery operation {id} contains payload; it was retained.");
                    continue;
                }
                seenOperations.Add(id);
                if (!SameMoveObject(expected.Identity, store.OperationIdentity))
                    throw new InvalidDataException("Recovery operation directory differs from its central manifest binding.");
                if (!members.SetEquals(expected.Payloads.Where(pair => pair.Value.Present).Select(pair => pair.Key)))
                    throw new InvalidDataException("Recovery payload membership is unknown or changed during capacity inspection.");
                foreach (var name in members)
                {
                    var path = Path.Combine(store.OperationPath, name!);
                    var held = new List<SafeFileHandle>();
                    try
                    {
                        var bytes = MeasureMovePayload(path, held);
                        if (held.Count == 0 || !SameMoveObject(expected.Payloads[name!].Identity, NativeFiles.MoveIdentity(held[0]))
                            || NativeFiles.FinalPath(held[0]) != path)
                            throw new InvalidDataException("Recovery payload differs from its central manifest identity.");
                        scan.Bytes = checked(scan.Bytes + bytes);
                    }
                    finally { for (var i = held.Count - 1; i >= 0; i--) held[i].Dispose(); }
                }
            }
            if (operations is not null && operations.Keys.Any(id => !seenOperations.Contains(id)))
                throw new InvalidDataException("A recorded recovery operation directory is missing from the volume inventory.");
        }, (root, ex) =>
        {
            scan.Known = false;
            warnings.Add($"Recovery store {root} cannot be safely inventoried and was retained: {ex.Message}");
        });
        if (inventory.Keys.Any(key => !inspected.Contains(key)))
        {
            scan.Known = false;
            warnings.Add("Some recorded recovery stores were not found in the available local volume inventory.");
        }
        return scan;
    }

    private static string MoveInventoryKey(string volumeName, MoveEntryIdentity identity) =>
        volumeName.ToUpperInvariant() + ":" + identity.VolumeSerialNumber + ":" + identity.FileId.ToUpperInvariant();

    private sealed class MoveInventoryOperation(MoveEntryIdentity identity)
    {
        internal MoveEntryIdentity Identity { get; } = identity;
        internal Dictionary<string, MoveInventoryPayload> Payloads { get; } = new(StringComparer.Ordinal);
    }
    private sealed record MoveInventoryPayload(MoveEntryIdentity Identity, bool Present);

    // 元パスを検査するときも祖先を固定する。原本への削除や属性変更は一切行わない。
    private static MoveEntryIdentity? InspectMoveOriginal(MoveEntry entry)
    {
        try
        {
            using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(entry.Path)!);
            return InspectMoveLocation(entry.Path);
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    private void ValidateMissingMovePayload(MoveRecordLease record, MoveEntry entry, bool reconcile = false)
    {
        if (IsCancelledMoveEntry(record, entry)) return;
        if (reconcile && TryCancelUnmovedMoveEntry(record, entry)) return;
        var moved = ReadMoveReceipt(record, entry, "move", "complete") is not null;
        var restoreIntent = ReadMoveReceipt(record, entry, "restore", "intent") is not null;
        var restored = ReadMoveReceipt(record, entry, "restore", "complete") is not null;
        var purgeIntent = ReadMoveReceipt(record, entry, "purge", "intent") is not null;
        var purged = ReadMoveReceipt(record, entry, "purge", "complete") is not null;
        var original = InspectMoveOriginal(entry);
        var sameSource = entry.Identity is not null && original is not null && SameMoveObject(entry.Identity, original);
        if (restored && (purgeIntent || purged)) throw new InvalidDataException("Restore and purge completion evidence conflicts.");
        if (purged && !purgeIntent) throw new InvalidDataException("Purge completion has no matching durable intent.");
        if (restored) return;
        if (purgeIntent)
        {
            if (sameSource) throw new InvalidDataException("Purge evidence conflicts with the original object at the source path.");
            return;
        }
        // rename前の中断は、次の削除で原本が移動する前に終端記録を永続化する。
        if (sameSource && entry.State == "move_intent" && !moved && !restoreIntent)
        {
            if (reconcile) throw new IOException("The unmoved original could not be durably cancelled; it was retained.");
            return;
        }
        throw new InvalidDataException("Recovery payload is absent without matching restore/purge evidence or the original unmoved object.");
    }

    private static void VerifyMovePayloadIdentity(MoveEntry entry, MoveEntryIdentity payload, MoveEntryIdentity? original)
    {
        if (entry.Identity is null || !SameMoveObject(entry.Identity, payload) || MoveKind(payload) != entry.Kind)
            throw new InvalidDataException("Recovery payload identity or type differs from the move manifest.");
        if (original is not null && SameMoveObject(entry.Identity, original))
            throw new InvalidDataException("The same recorded object exists at both source and recovery locations; both were retained.");
    }

    private PurgeResult PurgeMoveCore(string operationId, bool apply)
    {
        using var record = OpenMoveRecord(operationId);
        var result = new PurgeResult { OperationId = operationId, DryRun = !apply };
        foreach (var entry in record.Manifest.Entries)
        {
            var item = new FileOperationResult { Path = entry.Path, Kind = entry.Kind, Status = "not_backed_up" };
            result.Items.Add(item);
            if (entry.State == "already_absent") { item.Size = 0; continue; }
            try
            {
                using var store = OpenRecordedMoveStore(record, entry);
                var payload = MovePayloadPath(record.Manifest, entry);
                item.BackupPath = payload;
                var identity = InspectMoveLocation(payload);
                if (identity is null)
                {
                    ValidateMissingMovePayload(record, entry, reconcile: apply);
                    if (ReadMoveReceipt(record, entry, "purge", "intent") is not null)
                    {
                        if (apply && ReadMoveReceipt(record, entry, "purge", "complete") is null)
                            WriteMoveReceipt(record.Directory, record.Manifest, record.ManifestHash, entry, "purge", "complete");
                        item.Status = "already_purged";
                    }
                    item.Size = 0;
                    continue;
                }
                _ = IsCancelledMoveEntry(record, entry);
                VerifyMovePayloadIdentity(entry, identity, InspectMoveOriginal(entry));
                if (ReadMoveReceipt(record, entry, "restore", "complete") is not null
                    || ReadMoveReceipt(record, entry, "purge", "complete") is not null)
                    throw new InvalidDataException("A completed receipt conflicts with a recovery payload.");
                // 先に全体を計測し、未知のreparseやロックがある木ではintent前に拒否する。
                item.Size = MeasureMovePayload(payload);
                if (!apply) { item.Status = "would_purge"; continue; }
                using (var root = NativeFiles.OpenMovePurgePin(payload))
                {
                    var pinned = VerifyMovePurgeHandle(root, payload);
                    VerifyMovePayloadIdentity(entry, pinned, InspectMoveOriginal(entry));
                    if (ReadMoveReceipt(record, entry, "purge", "intent") is null)
                        WriteMoveReceipt(record.Directory, record.Manifest, record.ManifestHash, entry, "purge", "intent");
                    // 個々の削除成功時に加算し、途中失敗でも今回消した実測量を返す。
                    PurgeMoveTree(payload, root, bytes => result.PurgedBytes = checked(result.PurgedBytes + bytes));
                }
                if (InspectMoveLocation(payload) is not null) throw new IOException("Recovery payload still exists after purge.");
                WriteMoveReceipt(record.Directory, record.Manifest, record.ManifestHash, entry, "purge", "complete");
                item.Status = "purged";
            }
            catch (Exception ex) when (IsOperational(ex) || ex is OverflowException)
            {
                item.Status = "failed"; item.Error = ex.Message;
                result.Warnings.Add($"Recovery payload for {entry.Path} was retained where possible: {ex.Message}");
            }
        }
        return result;
    }

    private static MoveEntryIdentity VerifyMovePurgeHandle(SafeFileHandle handle, string path)
    {
        if (NativeFiles.FinalPath(handle) != path) throw new IOException("Purge handle differs from the pinned recovery path.");
        var identity = NativeFiles.MoveIdentity(handle);
        var reparse = (identity.Attributes & (uint)FileAttributes.ReparsePoint) != 0;
        if (reparse != (identity.ReparseTag != 0)) throw new IOException("Recovery object has an inconsistent reparse type.");
        if (reparse) _ = NativeFiles.ValidateReparse(NativeFiles.ReadReparse(handle));
        return identity;
    }

    // 子の処理中はDELETEを要求しない親pinを保持し、列挙や祖先検査との共有違反を避ける。
    // 最後にpinを閉じてDELETEを取得し直す。短い切替区間の差替えもID照合で拒否する。
    private static void PurgeMoveTree(string path, SafeFileHandle pin, Action<long> deleted)
    {
        var identity = VerifyMovePurgeHandle(pin, path);
        if (identity.IsDirectory && identity.ReparseTag == 0)
        {
            foreach (var child in Directory.EnumerateFileSystemEntries(path))
            {
                using var childPin = NativeFiles.OpenMovePurgePin(child);
                PurgeMoveTree(child, childPin, deleted);
            }
        }
        pin.Dispose();
        using var handle = NativeFiles.OpenMoveEntry(path);
        var current = VerifyMovePurgeHandle(handle, path);
        if (!SameMoveObject(identity, current))
            throw new IOException("Recovery object changed while acquiring its purge handle; the replacement was retained.");
        // 再取得した同一オブジェクトの現在値だけを、今回消した量として計上する。
        var bytes = checked(NativeFiles.NamedStreamBytes(handle) + (current.ReparseTag != 0
            ? NativeFiles.ReadReparse(handle).LongLength : current.IsDirectory ? 0 : RandomAccess.GetLength(handle)));
        NativeFiles.SetOriginalDeletePending(handle, true);
        // dispositionはhandle closeで実体に反映される。親へ戻る前に子を閉じる。
        handle.Dispose();
        deleted(bytes);
    }
}
