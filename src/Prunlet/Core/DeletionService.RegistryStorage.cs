using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private const string StorageMigrationStateName = "storage-migration-v1.json";

    private sealed class RegistryStorageState
    {
        public int Schema { get; set; } = 1;
        public string MetadataRootIdentity { get; set; } = "";
        public string RegistryRootIdentity { get; set; } = "";
        public string MachineName { get; set; } = "";
        public string OwnerSid { get; set; } = "";
        public bool RegistryReady { get; set; }
        public bool AssessmentComplete { get; set; }
        public bool Complete { get; set; }
        public int RetainedCount { get; set; }
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
        public int LegacyFilePolicyVersion { get; set; }
    }

    private sealed class RegistryMigrationFile
    {
        public string Name { get; set; } = "";
        public MoveEntryIdentity Identity { get; set; } = null!;
        public long Length { get; set; }
        public string Sha256 { get; set; } = "";
        public byte[] Security { get; set; } = [];
    }

    private sealed class RegistryStorageIntent
    {
        public int Schema { get; set; } = 1;
        public string OperationId { get; set; } = "";
        public string MetadataRootIdentity { get; set; } = "";
        public string RegistryRootIdentity { get; set; } = "";
        public string MachineName { get; set; } = "";
        public string OwnerSid { get; set; } = "";
        public MoveEntryIdentity DirectoryIdentity { get; set; } = null!;
        public byte[] DirectorySecurity { get; set; } = [];
        public List<RegistryMigrationFile> Files { get; set; } = [];
    }

    private string RegistryRoot(bool create)
    {
        var root = Path.Combine(config.BackupDirectory, RegistryRecordsDirectory);
        if (InspectMoveLocation(root) is null)
        {
            if (!create) throw new DirectoryNotFoundException("migration_required: Registry storage is not initialized; run migrate --apply.");
            return EnsureRecordRoot(config.BackupDirectory, RegistryRecordsDirectory, create: true);
        }
        try { return EnsureRecordRoot(config.BackupDirectory, RegistryRecordsDirectory, create: false); }
        catch (Exception ex) when (IsOperational(ex))
        { throw new InvalidDataException("migration_required: Registry storage marker is missing or invalid; run explicit migrate.", ex); }
    }

    private string RegistryOperationDirectory(string id, bool allowLegacy)
    {
        ValidateMoveOperationId(id);
        var typed = Path.Combine(RegistryRoot(create: false), id);
        if (InspectMoveLocation(typed) is not null) return typed;
        if (allowLegacy)
        {
            var legacy = Path.Combine(config.BackupDirectory, id);
            using var manifest = NativeFiles.OpenLifecycleMetadata(Path.Combine(legacy, RegistryManifestName));
            NativeFiles.VerifyPrivateRegistrySecurity(manifest);
            return legacy;
        }
        throw new DirectoryNotFoundException("Registry operation does not exist in registry storage.");
    }

    private void RequireRegistryStorageReady(bool create)
    {
        var root = RegistryRoot(create);
        if (Directory.EnumerateFiles(root, "*.registry-migration.json*").Any())
            throw new InvalidDataException("migration_required: A registry storage migration is pending; resume explicit migrate.");
        var state = ReadRegistryStorageState(root);
        if (state is not { RegistryReady: true, AssessmentComplete: true })
            throw new InvalidDataException("migration_required: Legacy registry records remain unresolved; run explicit migrate.");
    }

    private RegistryStorageState NewRegistryStorageState(string root)
    {
        using var metadata = NativeFiles.OpenDirectory(config.BackupDirectory);
        using var registry = NativeFiles.OpenPrivateRegistryDirectory(root);
        return new RegistryStorageState { MetadataRootIdentity = NativeFiles.Identity(metadata), RegistryRootIdentity = NativeFiles.Identity(registry),
            MachineName = Environment.MachineName, OwnerSid = NativeRegistry.CurrentSid };
    }

    private RegistryStorageState? ReadRegistryStorageState(string root)
    {
        var path = Path.Combine(root, StorageMigrationStateName);
        if (InspectMoveLocation(path) is null) return null;
        var state = ReadLifecycleJson<RegistryStorageState>(path);
        var expected = NewRegistryStorageState(root);
        if (state.Schema != 1 || state.MetadataRootIdentity != expected.MetadataRootIdentity || state.RegistryRootIdentity != expected.RegistryRootIdentity
            || state.MachineName != expected.MachineName || state.OwnerSid != expected.OwnerSid || state.RetainedCount < 0)
            throw new InvalidDataException("Registry storage assessment binding differs.");
        return state;
    }

    private void PersistRegistryStorageState(string root, RecoveryMigrationResult result)
    {
        var state = NewRegistryStorageState(root);
        state.RegistryReady = result.RegistryReady; state.AssessmentComplete = true; state.Complete = result.Complete;
        state.LegacyFilePolicyVersion = 2;
        state.RetainedCount = result.Operations.Count(item => item.Schema != 5 && (item.Status is "retained" or "failed" or "ambiguous"));
        var path = Path.Combine(root, StorageMigrationStateName);
        {
            // 明示移行の全再評価後だけ更新する集計marker。途中書込みで壊れた本文は
            // authorityとして読まず、private/single-linkの同じ対象へ再評価結果を保存する。
            using var handle = InspectMoveLocation(path) is null ? NativeFiles.CreatePrivateRegistryFile(path) : NativeFiles.OpenLifecyclePendingPublisher(path);
            NativeFiles.Verify(handle, path); NativeFiles.VerifyPrivateRegistrySecurity(handle); NativeFiles.VerifySingleLink(handle); NativeFiles.RejectNamedStreams(path);
            using var stream = new FileStream(handle, FileAccess.ReadWrite);
            stream.SetLength(0); JsonSerializer.Serialize(stream, state, MoveJsonOptions); stream.Flush(true);
            _ = ReadLifecycleJson<RegistryStorageState>(stream);
        }
    }

    public RecoveryMigrationResult MigrateRecoveryStorage(bool apply = false, bool ifNeeded = false, bool retryLegacyDiscard = false)
    {
        if (retryLegacyDiscard && (!apply || ifNeeded))
            throw new ArgumentException("Legacy discard retry acknowledgement requires explicit migrate --apply without --if-needed.");
        using var coordination = AcquireRecoveryCoordination(create: apply);
        var result = new RecoveryMigrationResult { DryRun = !apply };
        string? root = null;
        if (InspectMoveLocation(Path.Combine(config.BackupDirectory, RegistryRecordsDirectory)) is not null || apply)
            root = RegistryRoot(create: apply);
        RegistryStorageState? previous = null;
        if (ifNeeded && root is not null)
        {
            try { previous = ReadRegistryStorageState(root); }
            catch (InvalidDataException) { result.Warnings.Add("The interrupted storage assessment will be recomputed by explicit migration."); }
        }
        if (ifNeeded && root is not null && previous is { RegistryReady: true, AssessmentComplete: true })
        {
            result.RegistryReady = true; result.Complete = previous.Complete;
            // 評価済みの旧rootを更新のたびに再列挙しない。中断の既知controlだけを再開する。
            foreach (var intent in Directory.EnumerateFiles(root, "*.registry-migration.json*"))
            {
                var name = Path.GetFileName(intent);
                if (name.EndsWith(".pending", StringComparison.Ordinal)) name = name[..^8];
                try
                {
                    if (name.Length != 56) throw new InvalidDataException("Unknown registry migration control name was retained.");
                    var operation = MigrateRegistryOperation(name[..32], apply);
                    result.Operations.Add(operation);
                    if (operation.Status is not ("migrated" or "would_migrate")) result.RegistryReady = false;
                }
                catch (Exception ex) when (IsOperational(ex))
                { result.RegistryReady = false; result.Operations.Add(new() { Schema = 5, Status = "failed", Error = ex.Message }); }
            }
            if (!ReconcileRegistryControlPending(root, apply, result.Warnings)) result.RegistryReady = false;
            if (!result.RegistryReady || result.Operations.Any(operation => operation.Status is "retained" or "failed")) result.Complete = false;
            if (previous.RetainedCount != 0) result.Warnings.Add($"Previous migration retained {previous.RetainedCount} file records. Explicit migrate --apply rechecks them.");
            MigrateLegacyFileRecovery(apply, previous.LegacyFilePolicyVersion != 2, retryLegacyDiscard, result);
            if (apply) PersistRegistryStorageState(root, result);
            return result;
        }
        var ids = new HashSet<string>(StringComparer.Ordinal);
        if (root is not null)
            foreach (var intent in Directory.EnumerateFiles(root, "*.registry-migration.json*"))
            {
                var name = Path.GetFileName(intent);
                if (name.EndsWith(".pending", StringComparison.Ordinal)) name = name[..^8];
                if (name.Length != 56 || !Guid.TryParseExact(name[..32], "N", out var parsed) || parsed.ToString("N") != name[..32])
                { result.Operations.Add(new() { Status = "failed", Schema = 5, Error = "Unknown registry migration control name was retained." }); continue; }
                ids.Add(name[..32]);
            }
        // discoveryは明示移行だけ。通常maint/list/deleteからこの列挙を呼ばない。
        foreach (var directory in Directory.EnumerateDirectories(config.BackupDirectory))
        {
            var id = Path.GetFileName(directory);
            if (!Guid.TryParseExact(id, "N", out var parsed) || parsed.ToString("N") != id) continue;
            try
            {
                using var nativeDirectory = NativeFiles.OpenAny(directory);
                if (NativeFiles.IsReparse(nativeDirectory)) continue;
                NativeFiles.Verify(nativeDirectory, directory, directory: true);
                using var manifest = NativeFiles.OpenLifecycleMetadata(Path.Combine(directory, RegistryManifestName));
                ids.Add(id);
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
            catch (Exception ex) when (IsOperational(ex))
            { result.Operations.Add(new() { OperationId = id, Schema = 5, Status = "failed", Error = ex.Message }); }
        }
        foreach (var id in ids.Order(StringComparer.Ordinal))
        {
            try { result.Operations.Add(MigrateRegistryOperation(id, apply)); }
            catch (Exception ex) when (IsOperational(ex))
            { result.Operations.Add(new() { OperationId = id, Schema = 5, Status = "failed", Error = ex.Message }); }
        }
        var controlsReady = root is null || ReconcileRegistryControlPending(root, apply, result.Warnings);
        result.RegistryReady = controlsReady && result.Operations.All(item => item.Schema != 5 || item.Status is "migrated" or "would_migrate")
            && (apply || root is not null && ReadRegistryStorageState(root) is { RegistryReady: true, AssessmentComplete: true });
        result.Complete = result.RegistryReady;
        MigrateLegacyFileRecovery(apply, scanCentral: true, retryLegacyDiscard, result);
        if (result.Operations.Any(item => item.Status is "retained" or "failed" or "ambiguous")) result.Complete = false;
        if (apply && root is not null) PersistRegistryStorageState(root, result);
        return result;
    }

    private void EnsureRegistryOperationAvailable(string id)
    {
        ValidateMoveOperationId(id);
        var root = RegistryRoot(create: true);
        var intent = Path.Combine(root, id + ".registry-migration.json");
        if (InspectMoveLocation(Path.Combine(root, id)) is not null && InspectMoveLocation(intent) is null && InspectMoveLocation(intent + ".pending") is null) return;
        var migrated = MigrateRegistryOperation(id, apply: true);
        if (migrated.Status != "migrated") throw new InvalidDataException(migrated.Error ?? "Registry operation migration is unresolved.");
    }

    private RegistryStorageIntent CaptureRegistryMigration(string id, RegistryRecordLease record, string root)
    {
        var binding = NewRegistryStorageState(root);
        using var directory = NativeFiles.OpenPrivateRegistryDirectory(record.Directory);
        var intent = new RegistryStorageIntent { OperationId = id, MetadataRootIdentity = binding.MetadataRootIdentity, RegistryRootIdentity = binding.RegistryRootIdentity,
            MachineName = binding.MachineName, OwnerSid = binding.OwnerSid, DirectoryIdentity = NativeFiles.MoveIdentity(directory), DirectorySecurity = NativeFiles.ReadRegistryMemberSecurity(directory) };
        foreach (var path in Directory.EnumerateFileSystemEntries(record.Directory).Order(StringComparer.Ordinal))
        {
            var name = Path.GetFileName(path);
            if (name == "operation.lock")
            {
                intent.Files.Add(new() { Name = name, Identity = NativeFiles.MoveIdentity(record.Lock), Length = 0,
                    Sha256 = Convert.ToHexStringLower(SHA256.HashData([])), Security = NativeFiles.ReadRegistryMemberSecurity(record.Lock) });
                continue;
            }
            using var handle = NativeFiles.OpenLifecycleMetadata(path);
            NativeFiles.Verify(handle, path); NativeFiles.VerifySingleLink(handle); NativeFiles.RejectNamedStreams(path); NativeFiles.VerifyPrivateRegistrySecurity(handle);
            using var stream = new FileStream(handle, FileAccess.Read);
            intent.Files.Add(new() { Name = name, Identity = NativeFiles.MoveIdentity(handle), Length = stream.Length, Sha256 = HashStream(stream), Security = NativeFiles.ReadRegistryMemberSecurity(handle) });
        }
        return intent;
    }

    private void ValidateRegistryMigration(RegistryStorageIntent intent, string id, string root)
    {
        var binding = NewRegistryStorageState(root);
        if (intent.Schema != 1 || intent.OperationId != id || intent.MetadataRootIdentity != binding.MetadataRootIdentity || intent.RegistryRootIdentity != binding.RegistryRootIdentity
            || intent.MachineName != binding.MachineName || intent.OwnerSid != binding.OwnerSid || !ValidMoveIdentity(intent.DirectoryIdentity)
            || intent.DirectorySecurity.Length == 0 || intent.Files.Count is < 2 or > 16 || intent.Files.Select(file => file.Name).Distinct(StringComparer.Ordinal).Count() != intent.Files.Count
            || !intent.Files.Any(file => file.Name == RegistryManifestName) || !intent.Files.Any(file => file.Name == "operation.lock"))
            throw new InvalidDataException("Registry migration intent binding is invalid.");
        foreach (var file in intent.Files)
            if (file.Name != Path.GetFileName(file.Name) || file.Name is "." or ".." || !ValidMoveIdentity(file.Identity) || file.Length < 0
                || file.Name != "operation.lock" && file.Length == 0 || !Digest(file.Sha256) || file.Security.Length == 0)
                throw new InvalidDataException("Registry migration file binding is invalid.");
    }

    private void VerifyRegistryMigrationDirectory(string directory, RegistryStorageIntent intent)
    {
        using var record = OpenRegistryRecord(intent.OperationId, directory);
        using var root = NativeFiles.OpenPrivateRegistryDirectory(directory);
        if (record.Ambiguous || !SameMoveObject(intent.DirectoryIdentity, NativeFiles.MoveIdentity(root))
            || !NativeFiles.ReadRegistryMemberSecurity(root).SequenceEqual(intent.DirectorySecurity))
            throw new InvalidDataException("Registry migration source identity/security/outcome differs.");
        var actual = CaptureRegistryMigration(intent.OperationId, record, RegistryRoot(create: false));
        if (JsonSerializer.Serialize(actual.Files, MoveJsonOptions) != JsonSerializer.Serialize(intent.Files, MoveJsonOptions))
            throw new InvalidDataException("Registry migration metadata identity/bytes/security changed.");
    }

    private RecoveryMigrationOperation MigrateRegistryOperation(string id, bool apply)
    {
        ValidateMoveOperationId(id);
        var result = new RecoveryMigrationOperation { OperationId = id, Schema = 5, Status = "would_migrate" };
        var source = Path.Combine(config.BackupDirectory, id);
        var root = apply ? RegistryRoot(create: true) : Path.Combine(config.BackupDirectory, RegistryRecordsDirectory);
        var destination = Path.Combine(root, id); var path = Path.Combine(root, id + ".registry-migration.json");
        var sourceExists = InspectMoveLocation(source) is not null; var destinationExists = InspectMoveLocation(destination) is not null;
        if (sourceExists && destinationExists) throw new InvalidDataException("Registry migration has both source and destination; both were retained.");
        RegistryStorageIntent intent;
        if (InspectMoveLocation(path) is not null)
        {
            if (InspectMoveLocation(path + ".pending") is not null) throw new InvalidDataException("Registry migration has both pending and final controls; both were retained.");
            intent = ReadLifecycleJson<RegistryStorageIntent>(path); ValidateRegistryMigration(intent, id, root);
        }
        else
        {
            if (!sourceExists) throw new DirectoryNotFoundException("Legacy registry operation is absent.");
            using var record = OpenRegistryRecord(id, source);
            if (record.Ambiguous) { result.Status = "retained"; result.Error = "Registry transaction outcome is ambiguous; source and snapshot were retained."; return result; }
            if (!apply) return result;
            intent = CaptureRegistryMigration(id, record, root); ValidateRegistryMigration(intent, id, root);
            PublishRegistryControl(path, intent, id, "migration");
        }
        if (!apply) return result;
        if (!sourceExists && !destinationExists) throw new InvalidDataException("Both registry migration locations are missing.");
        VerifyRegistryMigrationDirectory(sourceExists ? source : destination, intent);
        if (sourceExists)
        {
            // 検証leaseを解放した後、同じdirectoryのDELETE handleを取り直して非上書きrenameする。
            using var moving = NativeFiles.OpenLifecycleDirectoryMove(source);
            NativeFiles.VerifyPrivateRegistrySecurity(moving, directory: true);
            if (!SameMoveObject(intent.DirectoryIdentity, NativeFiles.MoveIdentity(moving)) || !NativeFiles.ReadRegistryMemberSecurity(moving).SequenceEqual(intent.DirectorySecurity))
                throw new InvalidDataException("Registry migration directory changed before publication.");
            NativeFiles.RenameHandle(moving, destination);
        }
        VerifyRegistryMigrationDirectory(destination, intent);
        if (InspectMoveLocation(source) is not null) throw new InvalidDataException("Registry migration source reappeared; both locations were retained.");
        DeleteLifecycleRecord(path);
        result.Status = "migrated"; return result;
    }
}
