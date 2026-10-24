using System.Runtime.InteropServices;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private DeleteResult DeleteRecycle(string[] paths, bool dryRun, bool recursive)
    {
        config.Validate();
        ArgumentNullException.ThrowIfNull(paths);
        if (paths.Length is 0 or > 256) throw new ArgumentException("Specify between 1 and 256 paths.");
        var normalized = paths.Select(ValidateAnyTarget).ToArray();
        for (var i = 0; i < normalized.Length; i++)
            for (var j = i + 1; j < normalized.Length; j++)
                if (ExactWithin(normalized[i], normalized[j]) || ExactWithin(normalized[j], normalized[i]))
                    throw new ArgumentException("Duplicate or overlapping target paths are not allowed.");

        // dry-runでは記録・共通lock・Windowsゴミ箱を変更しない。
        using var coordination = dryRun ? null : AcquireRecoveryCoordination(create: true);
        var result = new DeleteResult { DryRun = dryRun };
        var entries = new List<RecycleEntry>();
        var parents = new List<DirectoryLease>();
        try
        {
            for (var index = 0; index < normalized.Length; index++)
            {
                var path = normalized[index];
                var entry = new RecycleEntry { Index = index, Path = path };
                entries.Add(entry);
                var item = new FileOperationResult { Schema2Wire = true, Path = path, Status = "failed" };
                result.Items.Add(item);
                try
                {
                    var identity = InspectMoveLocation(path);
                    CheckRecycleTarget(path, identity?.IsDirectory == true);
                    if (identity is null) { entry.State = item.Status = "already_absent"; continue; }
                    var parentPath = Path.GetDirectoryName(path)!;
                    parents.Add(PathPolicy.PinDirectories(parentPath));
                    using var parent = NativeFiles.OpenDirectory(parentPath);
                    NativeFiles.Verify(parent, parentPath, directory: true);
                    entry.OriginalParent = NativeFiles.MoveIdentity(parent);
                    entry.Identity = identity;
                    entry.Kind = item.Kind = MoveKind(identity);
                    if (!ValidMoveIdentity(identity) || !ValidMoveIdentity(entry.OriginalParent))
                        throw new IOException("The filesystem does not provide a usable persistent identity.");
                    if (identity.IsDirectory && identity.ReparseTag == 0 && !recursive && Directory.EnumerateFileSystemEntries(path).Any())
                        throw new ArgumentException("Nonempty directories require explicit recursive deletion.");
                    using var target = NativeFiles.OpenMoveMeasurement(path);
                    VerifyMoveHandle(target, path, identity);
                    entry.Security = CaptureRecycleSecurity(path, writable: true);
                    ValidateRecycleSecurity(entry.Security, identity);
                    item.Status = "would_delete";
                }
                catch (Exception ex) when (IsRecycleFailure(ex)) { item.Error = ex.Message; }
            }
            if (dryRun) return result;
            if (result.Items.Any(item => item.Status == "failed"))
                throw new IOException("Deletion preflight failed; original targets were retained. " +
                    string.Join(" ", result.Items.Where(item => item.Error is not null).Select(item => item.Error)));

            // 新しいゴミ箱実体はWindowsが所有する。旧記録の保持予算へ加算せず、整理もしない。
            using var operation = NewOperationLease.Create(config.BackupDirectory, privateRegistry: true);
            result.OperationId = operation.OperationId;
            var manifest = new RecycleManifest
            {
                OperationId = operation.OperationId, MetadataRoot = config.BackupDirectory,
                MachineName = Environment.MachineName, OwnerSid = VolumeRecoveryStore.OwnerSid, Entries = entries
            };
            ValidateRecycleManifest(manifest, operation.OperationId);
            var manifestPath = Path.Combine(operation.Directory, RecycleManifestName);
            PublishRecycleJson(manifestPath, operation.OperationId, manifest);
            var held = new List<FileStream>();
            try
            {
                var stream = HoldPurgeMetadata(manifestPath, held);
                var hash = HashStream(stream);
                foreach (var entry in entries.Where(entry => entry.State == "recycle_intent"))
                    ExecuteRecycleDeletion(operation.Directory, manifest, hash, entry, result.Items[entry.Index]);
                TryWriteResult(Path.Combine(operation.Directory, "delete-result.json"), result, result.Warnings);
            }
            finally { foreach (var stream in held) stream.Dispose(); }
            return result;
        }
        finally { for (var index = parents.Count - 1; index >= 0; index--) parents[index].Dispose(); }
    }

    private void ExecuteRecycleDeletion(string directory, RecycleManifest manifest, string hash, RecycleEntry entry, FileOperationResult item)
    {
        var started = false;
        var receipted = false;
        try
        {
            var recycled = NativeRecycleBin.Recycle(entry.Path, source =>
            {
                if (source != entry.Path) throw new IOException("The Shell source differs from the persisted intent.");
                VerifyRecycleParent(entry);
                VerifyRecycleObject(source, entry.Identity!);
                RequireRecycleSecurity(source, entry.Security!, writable: true, exactAttributes: true);
                started = true;
            }, bin =>
            {
                // Windowsの完了callbackでPIDLとFile IDを結び付け、戻り値だけから成功を推定しない。
                var identity = VerifyRecycleObject(bin.PhysicalPath, entry.Identity!);
                if (InspectMoveLocation(entry.Path) is not null)
                    throw new IOException("The original path is occupied after recycling; the state is ambiguous and both locations were retained.");
                FinishRecycleAttributes(bin.PhysicalPath, entry.Identity!);
                var security = CaptureRecycleSecurity(bin.PhysicalPath, writable: false);
                RequireRecycleSecurity(bin.PhysicalPath, entry.Security!, compareSecurity: false);
                WriteRecycleReceipt(directory, manifest, hash, entry, "recycle", "complete", bin, identity, security: security);
                item.BackupPath = bin.PhysicalPath;
                receipted = true;
            });
            if (!receipted) throw new IOException("Windows did not provide a durable recycle completion receipt.");
            item.Status = "deleted";
        }
        catch (Exception ex) when (IsRecycleFailure(ex))
        {
            item.Status = started ? "ambiguous" : "failed";
            item.Error = ex.Message + (started ? " The operation was not retried; inspect the Windows Recycle Bin and retained metadata." : string.Empty);
        }
    }

    private RestoreResult RestoreRecycle(string operationId)
    {
        using var operation = OpenRecycleRecord(operationId);
        var result = new RestoreResult { OperationId = operationId };
        if (operation.Manifest.Entries.Any(entry => entry.State == "recycle_intent" && entry.Security is null))
            result.Warnings.Add("This older schema 6 record has no ACL snapshot; restoration uses Windows ACL behavior and cannot guarantee the original ACL.");
        foreach (var entry in operation.Manifest.Entries)
        {
            var item = new FileOperationResult { Schema2Wire = true, Path = entry.Path, Kind = entry.Kind, Status = "failed" };
            result.Items.Add(item);
            if (entry.State == "already_absent") { item.Status = "not_moved"; continue; }
            try
            {
                if (entry.Security is not null) RestoreRecycleEntrySecure(operation, entry, item);
                else RestoreRecycleEntry(operation, entry, item);
            }
            catch (Exception ex) when (IsRecycleFailure(ex)) { item.Status = "failed"; item.Error = ex.Message; }
        }
        TryWriteResult(Path.Combine(operation.Directory, $"restore-result-{Guid.NewGuid():N}.json"), result, result.Warnings);
        return result;
    }

    private void RestoreRecycleEntry(RecycleRecordLease operation, RecycleEntry entry, FileOperationResult item)
    {
        var recycled = RecycleReceiptFor(operation, entry, "recycle", "complete")
            ?? throw new InvalidDataException("Recycle completion receipt is missing; no object was restored by guessing its original path.");
        var intent = RecycleReceiptFor(operation, entry, "restore", "intent");
        var complete = RecycleReceiptFor(operation, entry, "restore", "complete");
        item.BackupPath = recycled.PhysicalPath;
        // Findは現在のゴミ箱namespaceに属する項目だけを返す。PIDLを直接bindして移動しない。
        var bin = NativeRecycleBin.Find(recycled.Pidl);
        var original = InspectMoveLocation(entry.Path);
        if (bin is null)
        {
            if (original is not null && SameMoveObject(entry.Identity!, original))
            {
                using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(entry.Path)!);
                VerifyRecycleParent(entry);
                FinishRecycleAttributes(entry.Path, entry.Identity!);
                item.Status = "already_restored";
                return;
            }
            item.Status = "missing";
            item.Error = "The recorded item is absent from the Windows Recycle Bin. It may have been emptied or moved outside Prunlet; metadata was retained.";
            return;
        }
        if (bin.PhysicalPath != recycled.PhysicalPath || bin.Pidl != recycled.Pidl)
            throw new InvalidDataException("The current Recycle Bin item differs from its immutable receipt.");
        VerifyRecycleObject(bin.PhysicalPath, recycled.Identity!);
        if (original is not null)
        {
            item.Status = "conflict";
            item.Error = "The destination already exists; neither object was overwritten.";
            return;
        }
        if (complete is not null) throw new InvalidDataException("A completed restore still has a Recycle Bin payload; it was retained.");
        var parentPath = Path.GetDirectoryName(entry.Path)!;
        using var pinnedParents = PathPolicy.PinDirectories(parentPath);
        VerifyRecycleParent(entry);
        var recycleHash = operation.Hashes[RecycleReceiptName(entry, "recycle", "complete")];
        if (intent is null)
            WriteRecycleReceipt(operation.Directory, operation.Manifest, operation.Hash, entry, "restore", "intent", bin, recycled.Identity!, recycleHash);
        var started = false;
        try
        {
            var destination = NativeRecycleBin.RestoreNoReplace(bin, parentPath, Path.GetFileName(entry.Path), source =>
            {
                if (source != bin.PhysicalPath) throw new IOException("The Shell restore source changed.");
                VerifyRecycleObject(source, recycled.Identity!);
                VerifyRecycleParent(entry);
                if (InspectMoveLocation(entry.Path) is not null) throw new IOException("Restore destination already exists.");
                started = true;
            }, restored =>
            {
                if (restored != entry.Path) throw new IOException("Windows returned a different restore destination.");
                VerifyRecycleParent(entry);
                VerifyRecycleObject(restored, entry.Identity!);
                FinishRecycleAttributes(restored, entry.Identity!);
                WriteRecycleReceipt(operation.Directory, operation.Manifest, operation.Hash, entry, "restore", "complete", bin, recycled.Identity!, recycleHash);
            });
            if (destination != entry.Path) throw new IOException("Windows restored to a different destination.");
            FinishRecycleAttributes(destination, entry.Identity!);
            item.Status = "restored";
        }
        catch (Exception ex) when (IsRecycleFailure(ex))
        {
            var destination = InspectMoveLocation(entry.Path);
            if (!started && destination is not null) item.Status = "conflict";
            else item.Status = started ? "ambiguous" : "failed";
            item.Error = ex.Message + (started ? " The operation was not retried; all remaining objects and receipts were retained." : string.Empty);
        }
    }

    private static MoveEntryIdentity VerifyRecycleObject(string path, MoveEntryIdentity expected)
    {
        using var handle = NativeFiles.OpenShellInspection(path);
        VerifyMoveHandle(handle, path, expected);
        return NativeFiles.MoveIdentity(handle);
    }

    private static void FinishRecycleAttributes(string path, MoveEntryIdentity expected)
    {
        var current = VerifyRecycleObject(path, expected);
        if (NormalizeMoveAttributes(current.Attributes) != NormalizeMoveAttributes(expected.Attributes))
        {
            // rename後の既知のArchive付与だけを戻す。他の属性変化を推測で上書きしない。
            if (!IsArchiveOnlyMoveChange(current, expected.Attributes & NativeFiles.RestorableAttributeMask))
                throw new IOException("The recycled object's attributes changed beyond the known rename Archive effect; data was retained.");
            using (var writer = NativeFiles.OpenMoveAttributeGuard(path))
            {
                VerifyMoveHandle(writer, path, expected);
                NativeFiles.RestoreAttributes(writer, expected.Attributes & NativeFiles.RestorableAttributeMask);
            }
            current = VerifyRecycleObject(path, expected);
            if (NormalizeMoveAttributes(current.Attributes) != NormalizeMoveAttributes(expected.Attributes))
                throw new IOException("The recycled object's attributes could not be preserved; data was retained.");
        }
    }

    private static void VerifyRecycleParent(RecycleEntry entry)
    {
        var path = Path.GetDirectoryName(entry.Path)!;
        using var parent = NativeFiles.OpenDirectory(path);
        VerifyMoveHandle(parent, path, entry.OriginalParent!);
    }

    private void CheckRecycleTarget(string path, bool directory)
    {
        CheckMoveTarget(path, directory);
        var bin = Path.Combine(Path.GetPathRoot(path)!, "$Recycle.Bin");
        if (PathPolicy.Within(path, bin) || directory && PathPolicy.Within(bin, path))
            throw new ArgumentException("Windows Recycle Bin storage is protected; use the Windows Recycle Bin to manage its contents.");
    }

    private PurgeResult PurgeRecycleCore(string operationId, bool apply)
    {
        using var operation = OpenRecycleRecord(operationId);
        var result = new PurgeResult { OperationId = operationId, DryRun = !apply };
        result.Warnings.Add("Schema 6 payloads belong to the Windows Recycle Bin; Prunlet retains their metadata and never purges or budgets those payloads.");
        foreach (var entry in operation.Manifest.Entries)
            result.Items.Add(new FileOperationResult { Schema2Wire = true, Path = entry.Path, Kind = entry.Kind, Status = "retained" });
        return result;
    }

    private void ScanRecycleRecovery(string operationId)
    {
        using var operation = OpenRecycleRecord(operationId);
        // 中央metadataとWindows管理の実体を旧復元データの容量・期限整理から分離する。
        // 正常な除外はmaintenanceの未完了理由にしない。不正記録はOpenRecycleRecordが拒否する。
    }

    private static bool IsRecycleFailure(Exception exception) => IsMoveFailure(exception) || exception is COMException or NotSupportedException;
}
