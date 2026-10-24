using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private RestoreResult RestoreMoves(string operationId)
    {
        using var operation = OpenMoveRecord(operationId);
        var result = new RestoreResult { OperationId = operationId };
        foreach (var entry in operation.Manifest.Entries)
        {
            var item = new FileOperationResult
            {
                Schema2Wire = true, Path = entry.Path, Kind = entry.Kind, Size = entry.Size,
                Status = "failed", BackupPath = entry.State == "already_absent" ? null : MovePayloadPath(operation.Manifest, entry)
            };
            result.Items.Add(item);
            if (entry.State == "already_absent") { item.Status = "not_moved"; continue; }
            try { RestoreMoveEntry(operation, entry, item); }
            catch (Exception ex) when (IsMoveFailure(ex)) { item.Status = "failed"; item.Error = ex.Message; }
        }
        TryWriteResult(Path.Combine(operation.Directory, $"restore-result-{Guid.NewGuid():N}.json"), result, result.Warnings);
        return result;
    }

    private void RestoreMoveEntry(MoveRecordLease operation, MoveEntry entry, FileOperationResult item)
    {
        // 整理開始後は木の一部が既に失われている可能性があり、正常な復元として扱わない。
        if (ReadMoveReceipt(operation, entry, "purge", "intent") is not null
            || ReadMoveReceipt(operation, entry, "purge", "complete") is not null)
            throw new IOException("Recovery cleanup has started for this entry; restoration was refused and remaining data was retained.");
        if (IsCancelledMoveEntry(operation, entry))
        {
            item.Status = "not_moved";
            item.BackupPath = null;
            return;
        }
        var intent = ReadMoveReceipt(operation, entry, "restore", "intent");
        var complete = ReadMoveReceipt(operation, entry, "restore", "complete");
        var moved = ReadMoveReceipt(operation, entry, "move", "complete");
        if (complete is not null && intent is null)
            throw new InvalidDataException("Restore completion has no matching restore intent; both locations were retained.");
        using var store = OpenRecordedMoveStore(operation, entry);
        var payload = MovePayloadPath(operation.Manifest, entry);
        var stored = InspectMoveLocation(payload);
        var original = InspectMoveLocation(entry.Path);
        if (stored is null)
        {
            if (original is null)
                throw new IOException("Neither the original object nor its moved payload could be located.");
            if (!SameMoveObject(entry.Identity!, original))
            {
                item.Status = "conflict";
                item.Error = "The original path contains a different object; it was not overwritten.";
                return;
            }
            using var originalParents = PathPolicy.PinDirectories(Path.GetDirectoryName(entry.Path)!);
            using var originalHandle = NativeFiles.OpenAny(entry.Path);
            VerifyMoveHandle(originalHandle, entry.Path, entry.Identity!);
            if (intent is not null)
            {
                if (complete is null)
                {
                    var current = NativeFiles.MoveIdentity(originalHandle);
                    if (intent.Attributes is uint snapshot)
                    {
                        var expected = RecoverMoveAttributeSnapshot(current, snapshot);
                        using var attributes = new MoveAttributeGuard();
                        attributes.Prepare(entry.Path, expected);
                        attributes.RestoreAndClose(originalHandle, entry.Path, expected);
                        VerifyMoveAttributes(originalHandle, entry.Path, expected);
                    }
                    else if (NeedsMoveAttributeGuard(current) || NeedsMoveAttributeGuard(entry.Identity!))
                        throw new InvalidDataException("Interrupted restore has no attribute snapshot; the original object was retained without guessing its attributes.");
                    WriteMoveReceipt(operation.Directory, operation.Manifest, operation.ManifestHash, entry, "restore", "complete");
                }
                item.Status = "already_restored";
            }
            else if (moved is null) item.Status = "not_moved";
            else throw new IOException("The payload is absent and the original identity matches, but no restore intent authorizes completion.");
            return;
        }
        if (!SameMoveObject(entry.Identity!, stored))
            throw new IOException("The recovery payload identity changed; both locations were retained.");
        if (original is not null)
        {
            item.Status = "conflict";
            item.Error = "Both original and payload paths exist; neither object was changed.";
            return;
        }
        if (complete is not null)
            throw new InvalidDataException("A completed restore still has a payload; it was retained for diagnosis.");

        var parentPath = Path.GetDirectoryName(entry.Path)!;
        using var parents = PathPolicy.PinDirectories(parentPath);
        using var parent = NativeFiles.OpenMoveParent(parentPath, entry.Identity!.IsDirectory);
        VerifyMoveHandle(parent, parentPath, entry.OriginalParent!);
        SafeFileHandle? target = null;
        MoveEntryIdentity? renameIdentity = null;
        using var attributeGuard = new MoveAttributeGuard();
        var renamed = false;
        try
        {
            target = NativeFiles.OpenMoveEntry(payload);
            VerifyMoveHandle(target, payload, entry.Identity!);
            renameIdentity = NativeFiles.MoveIdentity(target);
            // 完了記録のないrenameでArchiveだけが増えた場合は、未完了の元snapshotへ戻す。
            if (moved is null && IsArchiveOnlyMoveChange(renameIdentity, entry.Identity!.Attributes & NativeFiles.RestorableAttributeMask))
                renameIdentity = WithMoveRestorableAttributes(renameIdentity, entry.Identity.Attributes & NativeFiles.RestorableAttributeMask);
            if (intent?.Attributes is uint snapshot)
                renameIdentity = RecoverMoveAttributeSnapshot(renameIdentity, snapshot);
            else if (intent is not null && NeedsMoveAttributeGuard(renameIdentity))
                throw new InvalidDataException("Restore intent has no attribute snapshot for a file requiring attribute preservation; its payload was retained.");
            attributeGuard.Prepare(payload, renameIdentity);
            if (InspectMoveLocation(entry.Path) is not null)
            {
                using var conflictPin = FinishMoveRename(ref target, payload, renameIdentity, attributeGuard);
                item.Status = "conflict";
                item.Error = "The original path became occupied; it was not overwritten.";
                return;
            }
            if (intent is null)
                WriteMoveReceipt(operation.Directory, operation.Manifest, operation.ManifestHash, entry, "restore", "intent",
                    renameIdentity.Attributes & NativeFiles.RestorableAttributeMask);
            NativeFiles.MoveNoReplace(target, parent, Path.GetFileName(entry.Path));
            renamed = true;
            VerifyRenamedMoveHandle(target, entry.Path, entry.Identity!);
            using var finalPin = FinishMoveRename(ref target, entry.Path, renameIdentity, attributeGuard);
            WriteMoveReceipt(operation.Directory, operation.Manifest, operation.ManifestHash, entry, "restore", "complete");
            item.Status = "restored";
        }
        catch (Exception failure) when (IsMoveFailure(failure))
        {
            if (target is not null && renameIdentity is not null)
            {
                try
                {
                    using var failurePin = FinishMoveRename(ref target, renamed ? entry.Path : payload, renameIdentity, attributeGuard);
                }
                catch (Exception attributes) when (IsMoveFailure(attributes))
                {
                    throw new IOException($"Restore failed and attribute preservation could not be confirmed; data was retained: {failure.Message} {attributes.Message}", failure);
                }
            }
            throw;
        }
        finally { target?.Dispose(); }
    }

    private static SafeFileHandle FinishMoveRename(ref SafeFileHandle? target, string path, MoveEntryIdentity expected,
        MoveAttributeGuard attributes, List<SafeFileHandle>? sizingGuards = null)
    {
        // NTFSのArchive付与はDELETEハンドルのcloseで現れるため、先に明示closeする。
        target?.Dispose();
        target = null;
        var pin = NativeFiles.OpenMovePurgePin(path);
        try
        {
            VerifyMoveHandle(pin, path, expected);
            attributes.RestoreAndClose(pin, path, expected);
            if (!expected.IsDirectory && expected.ReparseTag == 0 && sizingGuards is not null)
                ReleaseMoveMeasurementGuards(sizingGuards);
            VerifyMoveAttributes(pin, path, expected);
            if (!expected.IsDirectory && expected.ReparseTag == 0 && sizingGuards is not null)
            {
                var measurement = NativeFiles.OpenMoveMeasurement(path);
                sizingGuards.Add(measurement);
                VerifyMoveAttributes(measurement, path, expected);
            }
            return pin;
        }
        catch { pin.Dispose(); throw; }
    }

    private static bool NeedsMoveAttributeGuard(MoveEntryIdentity identity) =>
        !identity.IsDirectory && identity.ReparseTag == 0 && (identity.Attributes & (uint)FileAttributes.Archive) == 0;

    private static uint NormalizeMoveAttributes(uint attributes) => attributes == (uint)FileAttributes.Normal ? 0u : attributes;

    private static bool IsArchiveOnlyMoveChange(MoveEntryIdentity current, uint snapshot) =>
        !current.IsDirectory && current.ReparseTag == 0 && (snapshot & (uint)FileAttributes.Archive) == 0
        && NormalizeMoveAttributes(current.Attributes & NativeFiles.RestorableAttributeMask)
            == (NormalizeMoveAttributes(snapshot) | (uint)FileAttributes.Archive);

    private static MoveEntryIdentity WithMoveRestorableAttributes(MoveEntryIdentity current, uint snapshot) =>
        current with { Attributes = (current.Attributes & ~NativeFiles.RestorableAttributeMask) | snapshot };

    private static MoveEntryIdentity RecoverMoveAttributeSnapshot(MoveEntryIdentity current, uint snapshot)
    {
        if (NormalizeMoveAttributes(current.Attributes & NativeFiles.RestorableAttributeMask) == NormalizeMoveAttributes(snapshot))
            return current;
        if (IsArchiveOnlyMoveChange(current, snapshot)) return WithMoveRestorableAttributes(current, snapshot);
        throw new InvalidDataException("Attributes changed beyond the known rename Archive effect after restore intent; data and current attributes were retained.");
    }

    private static void VerifyMoveAttributes(SafeFileHandle handle, string path, MoveEntryIdentity expected)
    {
        VerifyMoveHandle(handle, path, expected);
        if (NormalizeMoveAttributes(NativeFiles.MoveIdentity(handle).Attributes) != NormalizeMoveAttributes(expected.Attributes))
            throw new IOException("The moved object's attributes differ after closing its rename and attribute handles.");
    }

    private sealed class MoveAttributeGuard : IDisposable
    {
        private SafeFileHandle? writer;

        internal void Prepare(string path, MoveEntryIdentity expected, bool renamed = false)
        {
            if (NeedsMoveAttributeGuard(expected)) writer ??= NativeFiles.OpenMoveAttributeGuard(path);
            if (writer is not null)
            {
                if (renamed) VerifyRenamedMoveHandle(writer, path, expected);
                else VerifyMoveHandle(writer, path, expected);
            }
        }

        internal void RestoreAndClose(SafeFileHandle pin, string path, MoveEntryIdentity expected)
        {
            if (NeedsMoveAttributeGuard(expected))
            {
                if (writer is null) throw new IOException("Attribute preservation was not authorized before the rename.");
                // 移動後に開き直したpinが正規パスを固定し、writerは同じ実体への属性操作だけに使う。
                VerifyMoveHandle(pin, path, expected);
                if (!SameMoveObject(expected, NativeFiles.MoveIdentity(writer)))
                    throw new IOException("The attribute preservation object's identity changed.");
                NativeFiles.RestoreAttributes(writer, expected.Attributes & NativeFiles.RestorableAttributeMask);
            }
            Dispose();
        }

        public void Dispose() { writer?.Dispose(); writer = null; }
    }

    private static void VerifyMoveHandle(SafeFileHandle handle, string path, MoveEntryIdentity identity)
    {
        if (!NativeFiles.FinalPath(handle).Equals(path, StringComparison.Ordinal)
            || !SameMoveObject(identity, NativeFiles.MoveIdentity(handle)))
            throw new IOException("The move object's identity or canonical path changed.");
    }

    private static void VerifyRenamedMoveHandle(SafeFileHandle handle, string path, MoveEntryIdentity identity)
    {
        // 成功した非上書きrenameの直後だけ、移動先を開き直して名前と同一性を確認する。
        // 元のDELETEハンドルは保持し、移動前の名前情報が残る環境でも名前の差し替えを許さない。
        // 事前検証はVerifyMoveHandleのままとし、同じFile IDの別ハードリンク名を許容しない。
        if (!SameMoveObject(identity, NativeFiles.MoveIdentity(handle)))
            throw new IOException("The renamed move object's identity changed.");
        using var renamed = NativeFiles.OpenMoveMeasurement(path);
        VerifyMoveHandle(renamed, path, identity);
    }

    private static bool IsMoveFailure(Exception exception) =>
        exception is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or OverflowException or System.ComponentModel.Win32Exception;

    private static void ReleaseMoveMeasurementGuards(List<SafeFileHandle> guards)
    {
        for (var i = guards.Count - 1; i >= 0; i--) guards[i].Dispose();
        guards.Clear();
    }
}
