using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private sealed class RecycleStageReceipt
    {
        public int Schema { get; set; } = 6;
        public string OperationId { get; set; } = string.Empty;
        public int Index { get; set; }
        public string ManifestSha256 { get; set; } = string.Empty;
        public string RecycleSha256 { get; set; } = string.Empty;
        public string IntentSha256 { get; set; } = string.Empty;
        public string Phase { get; set; } = string.Empty;
        public DateTimeOffset CreatedUtc { get; set; } = DateTimeOffset.UtcNow;
        public string StageOperationId { get; set; } = string.Empty;
        public string StageOperationPath { get; set; } = string.Empty;
        public MoveEntryIdentity? StoreRoot { get; set; }
        public MoveEntryIdentity? StageParent { get; set; }
    }

    private static string RecycleStageName(RecycleEntry entry, string phase) => $"recycle-stage-{entry.Index:D4}-{phase}.json";
    private static string RecycleStageId(string operationId, int index) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("Prunlet restore\n" + operationId + "\n" + index.ToString(System.Globalization.CultureInfo.InvariantCulture))))[..32].ToLowerInvariant();

    private bool TryReadRecycleStage(RecycleRecordLease operation, string member, string name)
    {
        var match = Regex.Match(name, "^recycle-stage-([0-9]{4})-(intent|ready)\\.json$", RegexOptions.CultureInvariant);
        if (!match.Success) return false;
        if (!int.TryParse(match.Groups[1].Value, out var index) || index >= operation.Manifest.Entries.Count)
            throw new InvalidDataException("Recycle stage index is invalid.");
        var entry = operation.Manifest.Entries[index];
        var stream = HoldPurgeMetadata(member, operation.Held);
        var stage = ReadRecycleJson<RecycleStageReceipt>(stream);
        var id = RecycleStageId(operation.Manifest.OperationId, index);
        if (entry.Security is null || stage.Schema != 6 || stage.OperationId != operation.Manifest.OperationId
            || stage.Index != index || stage.Phase != match.Groups[2].Value || stage.CreatedUtc == default
            || stage.ManifestSha256 != operation.Hash || stage.StageOperationId != id
            || stage.StageOperationPath != VolumeRecoveryStore.RestoreOperationPath(config, entry.Path, id)
            || !ValidMoveIdentity(stage.StoreRoot) || !ValidMoveIdentity(stage.StageParent)
            || stage.StoreRoot is not { IsDirectory: true, ReparseTag: 0 }
            || stage.StageParent is not { IsDirectory: true, ReparseTag: 0 }
            || stage.StoreRoot.VolumeSerialNumber != entry.Identity!.VolumeSerialNumber
            || stage.StageParent.VolumeSerialNumber != entry.Identity.VolumeSerialNumber
            || stage.Phase == "intent" && stage.IntentSha256.Length != 0)
            throw new InvalidDataException("Recycle stage binding is invalid; objects were retained.");
        operation.Stages.Add(name, stage);
        operation.Hashes.Add(name, HashStream(stream));
        return true;
    }

    private static void ValidateRecycleStages(RecycleRecordLease operation)
    {
        foreach (var entry in operation.Manifest.Entries)
        {
            var intentName = RecycleStageName(entry, "intent");
            var intent = operation.Stages.GetValueOrDefault(intentName);
            var ready = operation.Stages.GetValueOrDefault(RecycleStageName(entry, "ready"));
            var recycled = RecycleReceiptFor(operation, entry, "recycle", "complete");
            if (intent is not null && (recycled is null || intent.RecycleSha256 != operation.Hashes[RecycleReceiptName(entry, "recycle", "complete")]))
                throw new InvalidDataException("Recycle stage has no matching immutable recycle receipt.");
            if (ready is not null && (intent is null || ready.IntentSha256 != operation.Hashes[intentName]
                || ready.RecycleSha256 != intent.RecycleSha256 || ready.StageOperationPath != intent.StageOperationPath
                || ready.StageOperationId != intent.StageOperationId || ready.StoreRoot != intent.StoreRoot || ready.StageParent != intent.StageParent))
                throw new InvalidDataException("Recycle stage-ready receipt does not match its intent.");
            if (entry.Security is not null && RecycleReceiptFor(operation, entry, "restore", "complete") is not null && ready is null)
                throw new InvalidDataException("ACL-preserving restoration has no immutable stage-ready receipt.");
        }
    }

    private void WriteRecycleStage(RecycleRecordLease operation, RecycleEntry entry, VolumeRecoveryLease store,
        string phase, string recycleHash)
    {
        var intentName = RecycleStageName(entry, "intent");
        var receipt = new RecycleStageReceipt
        {
            OperationId = operation.Manifest.OperationId, Index = entry.Index, ManifestSha256 = operation.Hash,
            RecycleSha256 = recycleHash, Phase = phase, StageOperationId = RecycleStageId(operation.Manifest.OperationId, entry.Index),
            StageOperationPath = store.OperationPath, StoreRoot = store.RootIdentity, StageParent = store.OperationIdentity,
            IntentSha256 = phase == "ready" ? operation.Hashes[intentName] : string.Empty
        };
        var name = RecycleStageName(entry, phase);
        var path = Path.Combine(operation.Directory, name);
        PublishRecycleJson(path, operation.Manifest.OperationId, receipt);
        var stream = HoldPurgeMetadata(path, operation.Held);
        operation.Stages.Add(name, receipt);
        operation.Hashes.Add(name, HashStream(stream));
    }

    private static void VerifyRecycleStageStore(VolumeRecoveryLease store, RecycleStageReceipt intent)
    {
        if (store.OperationPath != intent.StageOperationPath || !SameMoveObject(store.RootIdentity, intent.StoreRoot!)
            || !SameMoveObject(store.OperationIdentity, intent.StageParent!))
            throw new IOException("The private restore stage identity changed; it was retained.");
        VerifyMoveHandle(store.StoreRootHandle, store.RootPath, intent.StoreRoot!);
        VerifyMoveHandle(store.ParentHandle, store.OperationPath, intent.StageParent!);
    }

    private void RestoreRecycleEntrySecure(RecycleRecordLease operation, RecycleEntry entry, FileOperationResult item)
    {
        var expected = entry.Security!;
        var recycled = RecycleReceiptFor(operation, entry, "recycle", "complete")
            ?? throw new InvalidDataException("Recycle completion receipt is missing; no location was guessed.");
        var complete = RecycleReceiptFor(operation, entry, "restore", "complete");
        var restoreIntent = RecycleReceiptFor(operation, entry, "restore", "intent");
        var stageIntent = operation.Stages.GetValueOrDefault(RecycleStageName(entry, "intent"));
        var stageReady = operation.Stages.GetValueOrDefault(RecycleStageName(entry, "ready"));
        var stageId = RecycleStageId(operation.Manifest.OperationId, entry.Index);
        var stageDirectory = VolumeRecoveryStore.RestoreOperationPath(config, entry.Path, stageId);
        var stagePath = Path.Combine(stageDirectory, $"{entry.Index:D4}.entry");
        item.BackupPath = stageIntent is null ? recycled.PhysicalPath : stagePath;
        var original = InspectMoveLocation(entry.Path);
        if (original is not null && !SameMoveObject(entry.Identity!, original))
        {
            item.Status = "conflict";
            item.Error = "The original path is occupied; all payloads were retained.";
            return;
        }
        var bin = NativeRecycleBin.Find(recycled.Pidl);

        // 公開済み、またはExplorer等で移動された原本にはACL snapshotを書き戻さない。
        if (original is not null)
        {
            if (bin is not null || stageIntent is not null && InspectMoveLocation(stagePath) is not null)
                throw new IOException("Multiple matching locations exist; no object was changed.");
            if (stageIntent is not null && stageReady is null)
                throw new IOException("The original object is published without a stage-ready receipt; ACLs were not overwritten.");
            using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(entry.Path)!);
            VerifyRecycleParent(entry);
            RequireRecycleSecurity(entry.Path, expected);
            if (complete is null && stageReady is not null)
            {
                RequireRecycleSecurity(entry.Path, expected, exactAttributes: true);
                WriteRecycleReceipt(operation.Directory, operation.Manifest, operation.Hash, entry, "restore", "complete",
                    new BinItem(recycled.Pidl, recycled.PhysicalPath), recycled.Identity!, operation.Hashes[RecycleReceiptName(entry, "recycle", "complete")]);
            }
            else RequireRecycleSecurity(entry.Path, expected, exactAttributes: true);
            item.Status = "already_restored";
            return;
        }
        if (complete is not null) throw new IOException("Completed restoration has no original object; remaining locations were retained.");
        if (stageIntent is null && bin is null) { item.Status = "missing"; item.Error = "The tracked Recycle Bin item is absent; no location was guessed."; return; }
        if (bin is not null && (bin.PhysicalPath != recycled.PhysicalPath || bin.Pidl != recycled.Pidl))
            throw new InvalidDataException("Recycle Bin identity differs from its immutable receipt.");
        if (bin is not null) RequireRecycleSecurity(bin.PhysicalPath, recycled.Security!, writable: true);

        using var pinnedOriginalParents = PathPolicy.PinDirectories(Path.GetDirectoryName(entry.Path)!);
        VerifyRecycleParent(entry);
        using var store = VolumeRecoveryStore.OpenRestore(config, entry.Path, stageId, create: stageIntent is null);
        var recycleHash = operation.Hashes[RecycleReceiptName(entry, "recycle", "complete")];
        if (stageIntent is null)
        {
            WriteRecycleStage(operation, entry, store, "intent", recycleHash);
            stageIntent = operation.Stages[RecycleStageName(entry, "intent")];
        }
        VerifyRecycleStageStore(store, stageIntent);
        item.BackupPath = stagePath;
        foreach (var member in Directory.EnumerateFileSystemEntries(store.OperationPath))
            if (Path.GetFileName(member) != Path.GetFileName(stagePath))
                throw new InvalidDataException("The private stage contains an unbound member; all objects were retained.");
        var staged = InspectMoveLocation(stagePath);
        if (staged is not null && bin is not null) throw new IOException("Both Bin and stage contain payloads; neither was changed.");
        if (staged is null && bin is null) throw new IOException("The tracked item is absent from Bin and stage; no location was guessed.");
        // 前回callの途中状態と外部hardlink経由の変更を区別できないため、未確定stageを再補正しない。
        if (staged is not null && stageReady is null)
            throw new IOException("An existing private stage has no stage-ready receipt; its ACLs and attributes were retained without modification.");
        if (staged is not null) RequireRecycleSecurity(stagePath, expected, exactAttributes: true);
        if (restoreIntent is null)
            WriteRecycleReceipt(operation.Directory, operation.Manifest, operation.Hash, entry, "restore", "intent",
                new BinItem(recycled.Pidl, recycled.PhysicalPath), recycled.Identity!, recycleHash);
        if (staged is null)
        {
            if (stageReady is not null) throw new IOException("Stage-ready payload is missing; it was not recreated.");
            var destination = NativeRecycleBin.RestoreNoReplace(bin!, store.OperationPath, Path.GetFileName(stagePath), source =>
            {
                VerifyRecycleStageStore(store, stageIntent);
                VerifyRecycleParent(entry);
                RequireRecycleSecurity(source, recycled.Security!, writable: true);
                if (InspectMoveLocation(entry.Path) is not null || InspectMoveLocation(stagePath) is not null)
                    throw new IOException("A restore destination became occupied; no replacement was requested.");
            });
            if (destination != stagePath) throw new IOException("Windows returned an unexpected private stage destination.");
        }
        VerifyRecycleObject(stagePath, entry.Identity!);
        using (var rootHandle = NativeFiles.OpenRecycleRestoreRoot(stagePath))
        {
            VerifyMoveHandle(rootHandle, stagePath, entry.Identity!);
            if (stageReady is null)
            {
                RestoreRecycleSecurity(stagePath, expected);
                WriteRecycleStage(operation, entry, store, "ready", recycleHash);
            }
            else RequireRecycleSecurity(stagePath, expected, exactAttributes: true, rootHasDeleteHandle: true);
            VerifyRecycleStageStore(store, stageIntent);
            using var parent = NativeFiles.OpenMoveParent(Path.GetDirectoryName(entry.Path)!, entry.Identity!.IsDirectory);
            VerifyMoveHandle(parent, Path.GetDirectoryName(entry.Path)!, entry.OriginalParent!);
            RequireRecycleSecurity(stagePath, expected, exactAttributes: true, rootHasDeleteHandle: true);
            if (InspectMoveLocation(entry.Path) is not null) { item.Status = "conflict"; item.Error = "Destination became occupied; verified private stage was retained."; return; }
            NativeFiles.MoveNoReplace(rootHandle, parent, Path.GetFileName(entry.Path));
            VerifyRenamedMoveHandle(rootHandle, entry.Path, entry.Identity!);
        }
        // close時のArchive付与も完了記録より先に処理する。公開後のACL差分は補正しない。
        VerifyRecycleParent(entry);
        foreach (var (relative, node) in expected) FinishRecycleAttributes(RecycleSecurityPath(entry.Path, relative), node.Identity!);
        RequireRecycleSecurity(entry.Path, expected, exactAttributes: true);
        WriteRecycleReceipt(operation.Directory, operation.Manifest, operation.Hash, entry, "restore", "complete",
            new BinItem(recycled.Pidl, recycled.PhysicalPath), recycled.Identity!, recycleHash);
        item.BackupPath = stagePath;
        item.Status = "restored";
    }
}
