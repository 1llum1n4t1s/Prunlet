namespace Prunlet.Core;

public sealed partial class DeletionService
{
    // 呼出し元は共通lockとoperation lockを保持。内容検証済みの同じsnapshot以外を削除しない。
    private static void ConsumeRegistrySnapshot(RegistryRecordLease record)
    {
        if (!record.PayloadPresent) return;
        if (!record.Has("restore", "complete") && !record.Has("purge", "intent"))
            throw new InvalidDataException("Registry snapshot consumption has no persisted authorization.");
        var path = Path.Combine(record.Directory, RegistrySnapshotName);
        var payload = record.PayloadStream ?? throw new InvalidDataException("Registry snapshot handle is missing.");
        var identity = NativeFiles.MoveIdentity(payload.SafeFileHandle);
        // 書込み/削除共有なしの読取leaseを解放した後もoperation lockと祖先pinを保持し、
        // delete handle上で再度hash/sizeを検証する。置換された実体は削除しない。
        record.Held.Remove(payload); payload.Dispose(); record.PayloadStream = null;
        using var handle = NativeFiles.OpenPurgeTarget(path);
        NativeFiles.Verify(handle, path); NativeFiles.VerifySingleLink(handle); NativeFiles.RejectNamedStreams(path);
        NativeFiles.VerifyPrivateRegistrySecurity(handle);
        if (!SameMoveObject(identity, NativeFiles.MoveIdentity(handle)))
            throw new InvalidDataException("Registry snapshot identity changed before consumption; it was retained.");
        using var stream = new FileStream(handle, FileAccess.Read);
        if (stream.Length != record.Manifest.Size || HashStream(stream) != record.Manifest.Sha256)
            throw new InvalidDataException("Registry snapshot changed before consumption; it was retained.");
        NativeFiles.DeleteOriginalHandle(handle);
        record.PayloadPresent = false;
    }

    private PurgeResult PurgeRegistryCore(string operationId, bool apply)
    {
        using var record = OpenRegistryRecord(operationId);
        var result = new PurgeResult { OperationId = operationId, DryRun = !apply };
        var item = new FileOperationResult
        {
            Path = record.Manifest.Path, Kind = record.Manifest.Kind, Schema2Wire = true,
            Size = record.Manifest.Size, Sha256 = record.Manifest.Sha256,
            BackupPath = Path.Combine(record.Directory, RegistrySnapshotName), Status = "not_backed_up"
        };
        result.Items.Add(item);
        try
        {
            if (record.Ambiguous) throw new InvalidDataException("Registry commit outcome is ambiguous. Snapshot retained; purge is refused.");
            if (!record.PayloadPresent)
            {
                if (apply && record.Has("purge", "intent") && !record.Has("purge", "complete"))
                    WriteRegistryReceipt(record.Directory, record.Manifest, record.ManifestHash, "purge", "complete", record.Held);
                item.Status = record.Has("restore", "complete") ? "already_restored" : "already_purged";
                return result;
            }
            item.Status = "would_purge";
            if (!apply) return result;
            // 完了済みrestoreの残存snapshotはrestoreによる消費を続行し、競合するpurge記録を作らない。
            if (!record.Has("restore", "complete") && !record.Has("purge", "intent"))
            {
                WriteRegistryReceipt(record.Directory, record.Manifest, record.ManifestHash, "purge", "intent", record.Held);
                record.Receipts.Add(RegistryReceiptName("purge", "intent"));
            }
            ConsumeRegistrySnapshot(record);
            result.PurgedBytes = record.Manifest.Size;
            if (!record.Has("restore", "complete") && !record.Has("purge", "complete"))
                WriteRegistryReceipt(record.Directory, record.Manifest, record.ManifestHash, "purge", "complete", record.Held);
            item.Status = "purged";
        }
        catch (Exception ex) when (IsOperational(ex) || ex is OverflowException)
        {
            item.Status = "failed"; item.Error = ex.Message;
            result.Warnings.Add("Registry recovery snapshot was retained where possible: " + ex.Message);
        }
        return result;
    }

    private void ScanRegistryRecovery(RecoveryScan scan, string operationId, List<string> warnings, bool collectCandidates)
    {
        try
        {
            using var record = OpenRegistryRecord(operationId);
            if (record.PayloadPresent) scan.Bytes = checked(scan.Bytes + record.Manifest.Size);
            if (record.Ambiguous)
            {
                // 不確定な操作の容量自体は読めても、安全に整理可能な状態と扱わない。
                scan.Known = false;
                warnings.Add($"Registry recovery operation {operationId} has an ambiguous transaction outcome and was retained.");
                return;
            }
            if (collectCandidates && record.PayloadPresent)
                scan.Candidates.Add(new RecoveryCandidate(operationId, record.Manifest.CreatedUtc));
        }
        catch (Exception ex) when (IsOperational(ex) || ex is OverflowException)
        {
            scan.Known = false;
            warnings.Add($"Registry recovery operation {operationId} cannot be safely inspected and was retained: {ex.Message}");
        }
    }
}
