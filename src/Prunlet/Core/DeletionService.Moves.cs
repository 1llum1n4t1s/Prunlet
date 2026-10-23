using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private DeleteResult DeleteMoves(string[] paths, bool dryRun, bool recursive)
    {
        config.Validate();
        ArgumentNullException.ThrowIfNull(paths);
        if (paths.Length is 0 or > 256) throw new ArgumentException("Specify between 1 and 256 paths.");
        var normalized = paths.Select(ValidateAnyTarget).ToArray();
        for (var i = 0; i < normalized.Length; i++)
            for (var j = i + 1; j < normalized.Length; j++)
                if (ExactWithin(normalized[i], normalized[j]) || ExactWithin(normalized[j], normalized[i]))
                    throw new ArgumentException("Duplicate or overlapping target paths are not allowed.");

        // dry-runは専用領域・操作記録・共通ロックを作成しない。
        using var coordination = dryRun ? null : AcquireRecoveryCoordination(create: true);
        var result = new DeleteResult { DryRun = dryRun };
        var entries = new List<MoveEntry>();
        var parents = new List<DirectoryLease>();
        var guards = new List<List<SafeFileHandle>>();
        var attributeGuards = new List<MoveAttributeGuard>();
        var stores = new Dictionary<string, VolumeRecoveryLease>(StringComparer.OrdinalIgnoreCase);
        try
        {
            for (var index = 0; index < normalized.Length; index++)
            {
                var path = normalized[index];
                var item = new FileOperationResult { Schema2Wire = true, Path = path, Status = "failed" };
                result.Items.Add(item);
                var entry = new MoveEntry { Index = index, Path = path };
                entries.Add(entry);
                var entryGuards = new List<SafeFileHandle>();
                guards.Add(entryGuards);
                var attributeGuard = new MoveAttributeGuard();
                attributeGuards.Add(attributeGuard);
                try
                {
                    var identity = InspectMoveLocation(path);
                    CheckMoveTarget(path, identity?.IsDirectory == true);
                    if (identity is null)
                    {
                        entry.State = "already_absent";
                        item.Status = "already_absent";
                        continue;
                    }
                    var parentPath = Path.GetDirectoryName(path)!;
                    parents.Add(PathPolicy.PinDirectories(parentPath));
                    using var parent = NativeFiles.OpenDirectory(parentPath);
                    NativeFiles.Verify(parent, parentPath, directory: true);
                    entry.OriginalParent = NativeFiles.MoveIdentity(parent);
                    entry.Identity = identity;
                    entry.Kind = item.Kind = MoveKind(identity);
                    attributeGuard.Prepare(path, identity);
                    if (identity.IsDirectory && identity.ReparseTag == 0 && !recursive
                        && Directory.EnumerateFileSystemEntries(path).Any())
                        throw new ArgumentException("Nonempty directories require explicit recursive deletion.");
                    entry.Size = item.Size = MeasureMovePayload(path, dryRun ? null : entryGuards);
                    var current = InspectMoveLocation(path);
                    if (current is null || !SameMoveObject(identity, current))
                        throw new IOException("Target identity changed during deletion preflight.");
                    item.Status = "would_delete";
                }
                catch (Exception ex) when (IsMoveFailure(ex)) { item.Status = "failed"; item.Error = ex.Message; }
            }
            if (dryRun) return result;
            if (result.Items.Any(item => item.Status == "failed"))
                throw new IOException("Deletion preflight failed; original targets were retained. " +
                    string.Join(" ", result.Items.Where(item => item.Error is not null).Select(item => item.Error)));

            var incoming = entries.Aggregate(0L, (sum, entry) => checked(sum + (entry.Size ?? 0)));
            var operationBudget = Math.Max(config.MaxRecoveryBytes, incoming);
            var maintenance = MaintainAllRecoveryCore(apply: true, incomingBytes: incoming);
            if (!maintenance.CapacityKnown || !maintenance.BudgetSatisfied
                || maintenance.RetainedBytesAfter > operationBudget - incoming)
                throw new IOException("Recovery capacity could not be safely made available; original targets were retained. " +
                    string.Join(" ", maintenance.Warnings));
            result.Warnings.AddRange(maintenance.Warnings);
            if (incoming > config.MaxRecoveryBytes)
                result.Warnings.Add("This operation exceeds maxRecoveryBytes and is eligible for cleanup at the next deletion or maintenance run.");

            using var operation = NewOperationLease.Create(config.BackupDirectory);
            result.OperationId = operation.OperationId;
            var manifest = new MoveManifest
            {
                OperationId = operation.OperationId,
                MetadataRoot = config.BackupDirectory,
                OwnerSid = VolumeRecoveryStore.OwnerSid,
                StoreKey = VolumeRecoveryStore.StoreKey(config.BackupDirectory),
                Entries = entries
            };
            foreach (var entry in entries.Where(entry => entry.State == "move_intent"))
            {
                var root = VolumeRecoveryStore.ExpectedRoot(config, entry.Path);
                if (!stores.TryGetValue(root, out var store))
                {
                    store = VolumeRecoveryStore.Open(config, entry.Path, operation.OperationId, create: true);
                    stores.Add(root, store);
                }
                entry.VolumeName = store.VolumeName;
                entry.StoreRoot = store.RootPath;
                entry.StoreIdentity = store.RootIdentity;
                entry.PayloadParent = store.OperationIdentity;
                entry.PayloadName = entry.Index.ToString("D4") + ".entry";
            }
            var manifestPath = Path.Combine(operation.Directory, MoveManifestName);
            PublishMoveMetadata(manifestPath, operation.OperationId, manifest);
            using var manifestHandle = NativeFiles.OpenBackup(manifestPath);
            NativeFiles.Verify(manifestHandle, manifestPath);
            using var manifestStream = new FileStream(manifestHandle, FileAccess.Read);
            var hash = HashStream(manifestStream);
            foreach (var entry in entries.Where(entry => entry.State == "move_intent"))
                ExecuteMoveDeletion(operation.Directory, manifest, hash, entry, stores[entry.StoreRoot],
                    result.Items[entry.Index], result.Warnings, guards[entry.Index], attributeGuards[entry.Index]);
            TryWriteResult(Path.Combine(operation.Directory, "delete-result.json"), result, result.Warnings);
            return result;
        }
        finally
        {
            foreach (var store in stores.Values) store.Dispose();
            for (var i = guards.Count - 1; i >= 0; i--) ReleaseMoveMeasurementGuards(guards[i]);
            for (var i = attributeGuards.Count - 1; i >= 0; i--) attributeGuards[i].Dispose();
            for (var i = parents.Count - 1; i >= 0; i--) parents[i].Dispose();
        }
    }

    private void ExecuteMoveDeletion(string directory, MoveManifest manifest, string hash, MoveEntry entry,
        VolumeRecoveryLease store, FileOperationResult item, List<string> warnings, List<SafeFileHandle> guards,
        MoveAttributeGuard attributeGuard)
    {
        var payload = MovePayloadPath(manifest, entry);
        item.BackupPath = payload;
        var moved = false;
        var verified = false;
        SafeFileHandle? target = null;
        MoveEntryIdentity? renameIdentity = null;
        try
        {
            target = NativeFiles.OpenMoveEntry(entry.Path);
            VerifyMoveHandle(target, entry.Path, entry.Identity!);
            renameIdentity = NativeFiles.MoveIdentity(target);
            attributeGuard.Prepare(entry.Path, renameIdentity);
            // 子孫を開いたままではWindowsが非空ディレクトリのrenameを拒否する。
            // rootを削除・書込み共有なしで固定してから、今回の対象の計測ハンドルだけを解放する。
            ReleaseMoveMeasurementGuards(guards);
            var originalParentPath = Path.GetDirectoryName(entry.Path)!;
            using var sourceParent = NativeFiles.OpenDirectory(originalParentPath);
            VerifyMoveHandle(sourceParent, originalParentPath, entry.OriginalParent!);
            VerifyMoveHandle(target, entry.Path, entry.Identity!);
            VerifyMoveHandle(store.ParentHandle, store.OperationPath, entry.PayloadParent!);
            NativeFiles.MoveNoReplace(target, store.ParentHandle, entry.PayloadName);
            moved = true;
            VerifyMoveHandle(target, payload, entry.Identity!);
            var size = MeasureMovePayload(payload, guards);
            if (size > entry.Size!.Value)
                throw new IOException("Target grew beyond its reserved recovery capacity during the move.");
            using var finalPin = FinishMoveRename(ref target, payload, renameIdentity, attributeGuard, guards);
            verified = true;
            WriteMoveReceipt(directory, manifest, hash, entry, "move", "complete");
            item.Status = "deleted";
        }
        catch (Exception ex) when (IsMoveFailure(ex))
        {
            item.Status = "failed";
            item.Error = ex.Message;
            var cancelled = !moved;
            if (moved && !verified)
            {
                // 計測途中の例外でも、追加した子孫ハンドルをrollbackへ持ち込まない。
                ReleaseMoveMeasurementGuards(guards);
                try
                {
                    target ??= NativeFiles.OpenMoveEntry(payload);
                    VerifyMoveHandle(target, payload, entry.Identity!);
                    attributeGuard.Prepare(payload, renameIdentity!);
                    using var originalParent = NativeFiles.OpenMoveParent(Path.GetDirectoryName(entry.Path)!, entry.Identity!.IsDirectory);
                    VerifyMoveHandle(originalParent, Path.GetDirectoryName(entry.Path)!, entry.OriginalParent!);
                    NativeFiles.MoveNoReplace(target, originalParent, Path.GetFileName(entry.Path));
                    VerifyMoveHandle(target, entry.Path, entry.Identity!);
                    using var rollbackPin = FinishMoveRename(ref target, entry.Path, renameIdentity!, attributeGuard);
                    item.BackupPath = null;
                    cancelled = true;
                }
                catch (Exception rollback) when (IsMoveFailure(rollback))
                {
                    warnings.Add($"Rollback failed for '{entry.Path}'; the moved object was retained at '{payload}': {rollback.Message}");
                    if (target is not null && renameIdentity is not null)
                    {
                        try
                        {
                            var retainedPath = NativeFiles.FinalPath(target);
                            if (retainedPath != payload && retainedPath != entry.Path)
                                throw new IOException("The retained object moved outside its recorded locations.");
                            using var retainedPin = FinishMoveRename(ref target, retainedPath, renameIdentity, attributeGuard);
                        }
                        catch (Exception attributes) when (IsMoveFailure(attributes))
                        {
                            warnings.Add($"Attributes of the retained object for '{entry.Path}' could not be confirmed: {attributes.Message}");
                        }
                    }
                }
            }
            else if (moved)
                warnings.Add($"The moved object for '{entry.Path}' was retained at '{payload}'; its immutable manifest can be used to restore it.");
            if (cancelled)
            {
                try
                {
                    if (target is not null && renameIdentity is not null)
                    {
                        using var originalPin = FinishMoveRename(ref target, entry.Path, renameIdentity, attributeGuard);
                    }
                    WriteMoveReceipt(directory, manifest, hash, entry, "move", "cancelled");
                    item.BackupPath = null;
                }
                catch (Exception cancellation) when (IsMoveFailure(cancellation))
                {
                    warnings.Add($"The failed move for '{entry.Path}' could not be durably cancelled; its record and any remaining data were retained: {cancellation.Message}");
                }
            }
        }
        finally { target?.Dispose(); }
    }

    // 呼出し元は共通整理ロックを取得済み。操作ロックは必ずその後に取得する。
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
                        attributes.RestoreAndClose(entry.Path, expected);
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
            VerifyMoveHandle(target, entry.Path, entry.Identity!);
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
            attributes.RestoreAndClose(path, expected);
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

        internal void Prepare(string path, MoveEntryIdentity expected)
        {
            if (NeedsMoveAttributeGuard(expected)) writer ??= NativeFiles.OpenMoveAttributeGuard(path);
            if (writer is not null) VerifyMoveHandle(writer, path, expected);
        }

        internal void RestoreAndClose(string path, MoveEntryIdentity expected)
        {
            if (NeedsMoveAttributeGuard(expected))
            {
                if (writer is null) throw new IOException("Attribute preservation was not authorized before the rename.");
                VerifyMoveHandle(writer, path, expected);
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

    private static bool IsMoveFailure(Exception exception) =>
        exception is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or OverflowException or System.ComponentModel.Win32Exception;

    private static void ReleaseMoveMeasurementGuards(List<SafeFileHandle> guards)
    {
        for (var i = guards.Count - 1; i >= 0; i--) guards[i].Dispose();
        guards.Clear();
    }
}
