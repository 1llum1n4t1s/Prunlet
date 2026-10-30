using System.Text.Json;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    public DeleteResult DeleteRegistry(RegistryDeleteRequest request, bool dryRun = false)
    {
        config.Validate();
        _ = NativeRegistry.Target(request);
        if (registrySession is null && config.RegistryScope == "nativeWindows")
            return RegistrySessionClient.Delete(config, request, dryRun, RecoveryLockProgress);
        return DeleteRegistryLocal(request, dryRun);
    }

    internal DeleteResult DeleteRegistryLocal(RegistryDeleteRequest request, bool dryRun = false, string? requestedOperationId = null)
    {
        config.Validate();
        if (config.RegistryScope == "nativeWindows" && registrySession is null)
            throw new InvalidOperationException("Native registry execution requires a verified session context.");
        var target = NativeRegistry.Target(request);
        using var coordination = AcquireRecoveryCoordination(create: !dryRun);
        RequireRegistryStorageReady(create: false);
        var result = new DeleteResult { DryRun = dryRun };
        var item = RegistryItem(target);
        result.Items.Add(item);
        var held = new List<FileStream>();
        var commitConfirmed = false;
        var intentPublished = false;
        try
        {
            // 単一値は親ACLを変更せず、キー全体だけ完全SACLの権限を要求する。
            using var privileges = target.ValueName is null ? new NativeRegistry.PrivilegeScope(restore: false, requireEffectiveThreadToken: registrySession is not null) : null;
            using var transaction = new NativeRegistry.Transaction();
            RegistrySnapshot snapshot;
            try { snapshot = dryRun ? NativeRegistry.SnapshotForDeletionPreflight(transaction, target, request.Recursive)
                    : NativeRegistry.StageDeletionAndSnapshot(transaction, target, request.Recursive); }
            catch (RegistryTargetMissingException) { item.Status = "already_absent"; item.Size = 0; return result; }
            snapshot.Scope = registrySession?.Scope;
            target = NativeRegistry.Target(new RegistryDeleteRequest { Path = snapshot.Path, View = snapshot.View, ValueName = snapshot.ValueName });
            item.Path = target.Path;
            ValidateRegistrySnapshot(new RegistryManifest { Path = target.Path, View = target.View, ValueName = target.ValueName, Scope = snapshot.Scope }, snapshot);
            var bytes = JsonSerializer.SerializeToUtf8Bytes(snapshot, RegistryJsonOptions);
            if (bytes.LongLength > NativeRegistry.MaximumSnapshotBytes) throw new IOException("Serialized registry snapshot exceeds its maximum size.");
            item.Size = bytes.LongLength;
            if (target.ValueName is null)
                result.Warnings.Add("Registry key class, raw values and complete owner/group/DACL/SACL are preserved. Last-write timestamps are recorded but not restored. Volatile-key attributes are not captured; restoration creates nonvolatile keys.");
            item.Status = "would_delete";
            if (dryRun) return result;
            var incoming = bytes.LongLength;
            var operationBudget = Math.Max(config.MaxRecoveryBytes, incoming);
            var maintenance = MaintainRegistryOnlyCore(apply: true, incomingBytes: incoming);
            if (!maintenance.CapacityKnown || !maintenance.BudgetSatisfied || maintenance.RetainedBytesAfter > operationBudget - incoming)
                throw new IOException("Recovery capacity could not be safely reserved; registry target was retained. " + string.Join(" ", maintenance.Warnings));
            result.Warnings.AddRange(maintenance.Warnings);
            if (incoming > config.MaxRecoveryBytes)
                result.Warnings.Add("This single registry snapshot exceeds the configured recovery budget; it receives the same one-operation exception as file recovery. The next operation uses the normal budget.");
            using var operation = NewOperationLease.Create(config.BackupDirectory, requestedOperationId);
            result.OperationId = operation.OperationId;
            var snapshotPath = Path.Combine(operation.Directory, RegistrySnapshotName);
            var payload = PublishRegistrySnapshot(snapshotPath, operation.OperationId, snapshot, bytes, held, result.Warnings);
            item.BackupPath = snapshotPath;
            item.Sha256 = HashStream(payload);
            item.Size = payload.Length;
            if (payload.Length != incoming) throw new IOException("Registry snapshot serialization changed after capacity reservation.");
            var manifest = new RegistryManifest
            {
                OperationId = operation.OperationId, MetadataRoot = config.BackupDirectory, OwnerSid = NativeRegistry.CurrentSid,
                Path = target.Path, View = target.View, ValueName = target.ValueName, Kind = target.Kind,
                Size = payload.Length, Sha256 = item.Sha256, Scope = snapshot.Scope
            };
            ValidateRegistryManifest(manifest, operation.OperationId);
            ValidateRegistrySnapshot(manifest, snapshot);
            var manifestStream = PublishRegistryJson(Path.Combine(operation.Directory, RegistryManifestName), operation.OperationId, manifest, held, result.Warnings);
            var manifestHash = HashStream(manifestStream);
            WriteRegistryReceipt(operation.Directory, manifest, manifestHash, "delete", "intent", held, result.Warnings);
            intentPublished = true;
            transaction.Commit();
            commitConfirmed = true;
            WriteRegistryReceipt(operation.Directory, manifest, manifestHash, "delete", "complete", held, result.Warnings);
            item.Status = "deleted";
            return result;
        }
        catch (Exception ex) when (IsOperational(ex) || ex is OverflowException)
        {
            item.Status = "failed";
            item.Error = ex.Message;
            if (intentPublished)
                result.Warnings.Add(commitConfirmed
                    ? "Registry commit succeeded but completion could not be persisted. The snapshot is retained as ambiguous; automatic purge and restoration are refused."
                    : "Registry deletion was not confirmed. The snapshot and intent are retained; commit outcome is not inferred from the current registry.");
            return result;
        }
        finally { foreach (var stream in held) stream.Dispose(); }
    }

    public RestoreResult RestoreRegistry(string operationId)
    {
        ValidateMoveOperationId(operationId);
        if (registrySession is null && config.RegistryScope == "nativeWindows")
            return RegistrySessionClient.Restore(config, operationId, RecoveryLockProgress);
        using var coordination = AcquireRecoveryCoordination(create: true);
        EnsureRegistryOperationAvailable(operationId);
        var result = RestoreRegistryCore(operationId);
        if (result.Items.All(item => item.Status is not ("failed" or "conflict"))) CaptureRegistryTerminal(operationId, result.Warnings);
        return result;
    }

    private RestoreResult RestoreRegistryCore(string operationId)
    {
        if (config.RegistryScope == "nativeWindows" && registrySession is null)
            throw new InvalidOperationException("Native registry restoration requires a verified session context.");
        using var record = OpenRegistryRecord(operationId);
        var manifest = record.Manifest;
        var target = NativeRegistry.Target(new RegistryDeleteRequest { Path = manifest.Path, View = manifest.View, ValueName = manifest.ValueName });
        var result = new RestoreResult { OperationId = operationId };
        var item = RegistryItem(target);
        item.BackupPath = Path.Combine(record.Directory, RegistrySnapshotName);
        item.Size = manifest.Size; item.Sha256 = manifest.Sha256;
        result.Items.Add(item);
        var intentPublished = record.Has("restore", "intent");
        var committed = false;
        try
        {
            RegistryScopeIdentity.RequireExecutionMatch(manifest.Scope, registrySession?.Scope);
            if (record.Ambiguous) throw new InvalidDataException("Registry operation has an unconfirmed commit intent. Snapshot retained; restoration is refused.");
            if (record.Has("purge", "intent")) throw new InvalidOperationException("Registry snapshot has been scheduled for purge; restoration is unavailable.");
            if (record.Has("restore", "complete"))
            {
                // 完了記録がある場合は二度とregistryを書かず、残ったsnapshotの消費だけを続行する。
                if (record.PayloadPresent) ConsumeRegistrySnapshot(record);
                item.Status = "already_restored";
                return result;
            }
            if (record.Snapshot is null) throw new InvalidDataException("Registry snapshot is missing.");
            using var privileges = target.ValueName is null ? new NativeRegistry.PrivilegeScope(restore: true, requireEffectiveThreadToken: registrySession is not null) : null;
            using var transaction = new NativeRegistry.Transaction();
            // conflictも内容検証失敗もcommit前にrollbackできる。非上書き作成の検証後にintentを保存する。
            NativeRegistry.Restore(transaction, target, record.Snapshot);
            WriteRegistryReceipt(record.Directory, manifest, record.ManifestHash, "restore", "intent", record.Held, result.Warnings);
            record.Receipts.Add(RegistryReceiptName("restore", "intent"));
            intentPublished = true;
            transaction.Commit();
            committed = true;
            WriteRegistryReceipt(record.Directory, manifest, record.ManifestHash, "restore", "complete", record.Held, result.Warnings);
            record.Receipts.Add(RegistryReceiptName("restore", "complete"));
            ConsumeRegistrySnapshot(record);
            item.Status = "restored";
            if (target.ValueName is null)
                result.Warnings.Add("Registry key timestamps and volatile attributes are not restored; class, raw values and complete security were verified before commit.");
        }
        catch (RegistryConflictException ex) { item.Status = "conflict"; item.Error = ex.Message; }
        catch (Exception ex) when (IsOperational(ex) || ex is OverflowException or InvalidOperationException)
        {
            item.Status = "failed"; item.Error = ex.Message;
            if (intentPublished && !record.Has("restore", "complete"))
                result.Warnings.Add(committed
                    ? "Registry restore committed but completion is unconfirmed. Snapshot retained; repeat restoration and automatic purge are refused."
                    : "Registry restore intent has no confirmed completion. Snapshot retained without guessing the transaction outcome.");
            else if (record.Has("restore", "complete"))
                result.Warnings.Add("Registry restore is confirmed. Snapshot consumption failed; a retry only consumes the snapshot and never restores the registry again.");
        }
        return result;
    }

    private static FileOperationResult RegistryItem(RegistryTarget target) =>
        new() { Path = target.Path, Kind = target.Kind, Schema2Wire = true, Status = "not_backed_up" };

    public DeleteResult ReconcileRegistry(string operationId)
    {
        if (registrySession is null && config.RegistryScope == "nativeWindows")
            return RegistrySessionClient.Reconcile(config, operationId, RecoveryLockProgress);
        using var coordination = AcquireRecoveryCoordination(create: true);
        EnsureRegistryOperationAvailable(operationId);
        using var record = OpenRegistryRecord(operationId);
        RegistryScopeIdentity.RequireExecutionMatch(record.Manifest.Scope, registrySession?.Scope);
        var target = NativeRegistry.Target(new RegistryDeleteRequest { Path = record.Manifest.Path, View = record.Manifest.View, ValueName = record.Manifest.ValueName });
        var item = RegistryItem(target);
        item.Status = record.Ambiguous ? "ambiguous" : record.Has("restore", "complete") ? "restored"
            : record.Has("purge", "complete") ? "purged" : "deleted";
        return new DeleteResult { OperationId = operationId, DryRun = true, Items = [item] };
    }
}
