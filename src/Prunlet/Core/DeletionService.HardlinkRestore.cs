using System.Globalization;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private void RestoreHardlinkGroup(RecycleRecordLease operation, HardlinkGroup group, RestoreResult result)
    {
        if (group.Blocked) throw new IOException("The shared-object component has an incomplete transition; all locations were retained.");
        if (!group.Ready) PrepareHardlinkStages(operation, group, result);
        if (!group.Ready) return;

        // 全ready後はShellもACL補正も実行しない。公開済み別名と残stageを先に照合する。
        foreach (var entry in group.Entries)
        {
            VerifyRecycleParent(entry);
            var recycled = RecycleReceiptFor(operation, entry, "recycle", "complete")!;
            if (NativeRecycleBin.Find(recycled.Pidl) is not null)
                throw new IOException("A ready shared-object component still has a Recycle Bin item; all locations were retained.");
            var stage = operation.Stages[RecycleStageName(entry, "intent")];
            var path = Path.Combine(stage.StageOperationPath, $"{entry.Index:D4}.entry");
            using var store = VolumeRecoveryStore.OpenRestore(config, entry.Path, stage.StageOperationId, create: false);
            VerifyRecycleStageStore(store, stage);
            VerifyHardlinkStageMembers(store, entry);
            var original = InspectMoveLocation(entry.Path);
            var staged = InspectMoveLocation(path);
            if (original is not null && SameMoveObject(entry.Identity!, original))
            {
                if (staged is not null) throw new IOException("Multiple matching shared-object locations exist.");
                RequireRecycleSecurity(entry.Path, entry.Security!, exactAttributes: true);
            }
            else
            {
                if (staged is null) throw new IOException("A ready shared-object stage is missing; it was not recreated.");
                RequireRecycleSecurity(path, entry.Security!, exactAttributes: true);
            }
        }
        foreach (var entry in group.Entries) PublishHardlinkStage(operation, entry, result.Items[entry.Index]);
    }

    private void PrepareHardlinkStages(RecycleRecordLease operation, HardlinkGroup group, RestoreResult result)
    {
        var conflict = false;
        foreach (var entry in group.Entries)
        {
            var item = result.Items[entry.Index];
            var recycled = RecycleReceiptFor(operation, entry, "recycle", "complete")!;
            item.BackupPath = recycled.PhysicalPath;
            VerifyRecycleParent(entry);
            var stageId = RecycleStageId(operation.Manifest.OperationId, entry.Index);
            var stagePath = Path.Combine(VolumeRecoveryStore.RestoreOperationPath(config, entry.Path, stageId), $"{entry.Index:D4}.entry");
            if (InspectMoveLocation(stagePath) is not null || operation.Stages.ContainsKey(RecycleStageName(entry, "ready")))
                throw new IOException("A shared-object stage exists without a complete group-ready receipt; ACLs were not reapplied.");
            if (InspectMoveLocation(entry.Path) is not null) conflict = true;
            var bin = NativeRecycleBin.Find(recycled.Pidl);
            if (bin is null || bin.PhysicalPath != recycled.PhysicalPath || bin.Pidl != recycled.Pidl)
                throw new IOException("A shared-object Recycle Bin item is missing or differs from its immutable receipt.");
            RequireRecycleSecurity(bin.PhysicalPath, HardlinkExpected(recycled.Security!, group), writable: true);
        }
        if (conflict)
        {
            foreach (var entry in group.Entries)
            {
                result.Items[entry.Index].Status = "conflict";
                result.Items[entry.Index].Error = "A destination in the shared-object component is occupied; all component payloads were retained.";
            }
            return;
        }

        var stores = new Dictionary<int, VolumeRecoveryLease>();
        var stagedSecurity = new Dictionary<int, Dictionary<string, RecycleSecurityNode>>();
        try
        {
            foreach (var entry in group.Entries)
            {
                var recycled = RecycleReceiptFor(operation, entry, "recycle", "complete")!;
                var recycleHash = operation.Hashes[RecycleReceiptName(entry, "recycle", "complete")];
                var stageId = RecycleStageId(operation.Manifest.OperationId, entry.Index);
                var stageIntent = operation.Stages.GetValueOrDefault(RecycleStageName(entry, "intent"));
                var store = VolumeRecoveryStore.OpenRestore(config, entry.Path, stageId, create: stageIntent is null);
                stores.Add(entry.Index, store);
                if (stageIntent is null)
                {
                    WriteRecycleStage(operation, entry, store, "intent", recycleHash);
                    stageIntent = operation.Stages[RecycleStageName(entry, "intent")];
                }
                VerifyRecycleStageStore(store, stageIntent);
                var stagePath = Path.Combine(store.OperationPath, $"{entry.Index:D4}.entry");
                if (Directory.EnumerateFileSystemEntries(store.OperationPath).Any())
                    throw new IOException("The private shared-object stage is not empty.");
                if (RecycleReceiptFor(operation, entry, "restore", "intent") is null)
                    WriteRecycleReceipt(operation.Directory, operation.Manifest, operation.Hash, entry, "restore", "intent",
                        new BinItem(recycled.Pidl, recycled.PhysicalPath), recycled.Identity!, recycleHash);
                var bin = NativeRecycleBin.Find(recycled.Pidl)
                    ?? throw new IOException("The shared-object Recycle Bin item disappeared before staging.");
                if (bin.PhysicalPath != recycled.PhysicalPath) throw new IOException("The shared-object Recycle Bin location changed.");
                var destination = NativeRecycleBin.RestoreNoReplace(bin, store.OperationPath, Path.GetFileName(stagePath), source =>
                {
                    VerifyRecycleStageStore(store, stageIntent);
                    VerifyRecycleParent(entry);
                    if (source != recycled.PhysicalPath || InspectMoveLocation(entry.Path) is not null || InspectMoveLocation(stagePath) is not null)
                        throw new IOException("A shared-object restore location changed before the Shell move.");
                    RequireRecycleSecurity(source, HardlinkExpected(recycled.Security!, group), writable: true);
                    BeginHardlinkTransition(operation.Directory, operation.Manifest, operation.Hash, group, entry, "stage");
                });
                if (destination != stagePath) throw new IOException("Windows returned an unexpected shared-object stage destination.");
                VerifyRecycleObject(stagePath, entry.Identity!);
                var snapshot = CaptureRecycleSecurity(stagePath, writable: true);
                RequireRecycleSecurityBindings(entry.Security!, snapshot);
                CompleteHardlinkTransition(operation.Directory, operation.Manifest, operation.Hash, group, entry, "stage", snapshot,
                    operation.Hashes[RecycleStageName(entry, "intent")], stagePath);
                stagedSecurity.Add(entry.Index, snapshot);
                result.Items[entry.Index].BackupPath = stagePath;
            }

            // 全Shell移動が完了するまで原本ACLを適用せず、公開済み別名を作らない。
            foreach (var entry in group.Entries)
            {
                var store = stores[entry.Index];
                var stagePath = Path.Combine(store.OperationPath, $"{entry.Index:D4}.entry");
                VerifyRecycleStageStore(store, operation.Stages[RecycleStageName(entry, "intent")]);
                using var root = NativeFiles.OpenRecycleRestoreRoot(stagePath);
                VerifyMoveHandle(root, stagePath, entry.Identity!);
                RequireRecycleSecurity(stagePath, HardlinkExpected(stagedSecurity[entry.Index], group), writable: true, rootHasDeleteHandle: true);
                RestoreRecycleSecurity(stagePath, entry.Security!);
                foreach (var pair in SharedHardlinkNodes(group, entry, entry.Security!)) group.Current[pair.Key] = pair.Value;
            }
            foreach (var entry in group.Entries)
            {
                var store = stores[entry.Index];
                var stagePath = Path.Combine(store.OperationPath, $"{entry.Index:D4}.entry");
                VerifyRecycleParent(entry);
                VerifyRecycleStageStore(store, operation.Stages[RecycleStageName(entry, "intent")]);
                RequireRecycleSecurity(stagePath, entry.Security!, exactAttributes: true);
                if (NativeRecycleBin.Find(RecycleReceiptFor(operation, entry, "recycle", "complete")!.Pidl) is not null)
                    throw new IOException("A staged shared-object alias is still in the Recycle Bin.");
            }
            foreach (var entry in group.Entries)
                WriteRecycleStage(operation, entry, stores[entry.Index], "ready", operation.Hashes[RecycleReceiptName(entry, "recycle", "complete")]);
            var ready = new HardlinkReady
            {
                OperationId = operation.Manifest.OperationId, ManifestSha256 = operation.Hash,
                Leader = group.Leader, PreviousSha256 = group.Previous,
                StageReadyHashes = group.Entries.ToDictionary(entry => entry.Index.ToString(CultureInfo.InvariantCulture),
                    entry => operation.Hashes[RecycleStageName(entry, "ready")], StringComparer.Ordinal)
            };
            PublishRecycleJson(Path.Combine(operation.Directory, HardlinkReadyName(group)), operation.Manifest.OperationId, ready);
            group.Ready = true;
        }
        finally { foreach (var store in stores.Values) store.Dispose(); }
    }

    private void PublishHardlinkStage(RecycleRecordLease operation, RecycleEntry entry, FileOperationResult item)
    {
        var recycled = RecycleReceiptFor(operation, entry, "recycle", "complete")!;
        var stage = operation.Stages[RecycleStageName(entry, "intent")];
        var stagePath = Path.Combine(stage.StageOperationPath, $"{entry.Index:D4}.entry");
        item.BackupPath = stagePath;
        VerifyRecycleParent(entry);
        using var store = VolumeRecoveryStore.OpenRestore(config, entry.Path, stage.StageOperationId, create: false);
        VerifyRecycleStageStore(store, stage);
        VerifyHardlinkStageMembers(store, entry);
        var original = InspectMoveLocation(entry.Path);
        if (original is not null)
        {
            if (!SameMoveObject(entry.Identity!, original))
            { item.Status = "conflict"; item.Error = "Destination is occupied; the verified ready stage was retained."; return; }
            RequireRecycleSecurity(entry.Path, entry.Security!, exactAttributes: true);
        }
        else
        {
            if (RecycleReceiptFor(operation, entry, "restore", "complete") is not null)
                throw new IOException("A completed shared-object publication has no original; stage was not republished.");
            using (var root = NativeFiles.OpenRecycleRestoreRoot(stagePath))
            {
                VerifyMoveHandle(root, stagePath, entry.Identity!);
                using var parent = NativeFiles.OpenMoveParent(Path.GetDirectoryName(entry.Path)!, entry.Identity!.IsDirectory);
                VerifyMoveHandle(parent, Path.GetDirectoryName(entry.Path)!, entry.OriginalParent!);
                RequireRecycleSecurity(stagePath, entry.Security!, exactAttributes: true, rootHasDeleteHandle: true);
                NativeFiles.MoveNoReplace(root, parent, Path.GetFileName(entry.Path));
                VerifyRenamedMoveHandle(root, entry.Path, entry.Identity!);
            }
            foreach (var pair in entry.Security!) FinishRecycleAttributes(RecycleSecurityPath(entry.Path, pair.Key), pair.Value.Identity!);
            RequireRecycleSecurity(entry.Path, entry.Security!, exactAttributes: true);
        }
        if (RecycleReceiptFor(operation, entry, "restore", "complete") is null)
            WriteRecycleReceipt(operation.Directory, operation.Manifest, operation.Hash, entry, "restore", "complete",
                new BinItem(recycled.Pidl, recycled.PhysicalPath), recycled.Identity!, operation.Hashes[RecycleReceiptName(entry, "recycle", "complete")]);
        item.Status = original is null ? "restored" : "already_restored";
    }

    private static void VerifyHardlinkStageMembers(VolumeRecoveryLease store, RecycleEntry entry)
    {
        var expected = $"{entry.Index:D4}.entry";
        if (Directory.EnumerateFileSystemEntries(store.OperationPath).Any(path => Path.GetFileName(path) != expected))
            throw new InvalidDataException("The private shared-object stage contains an unbound member; all objects were retained.");
    }
}
