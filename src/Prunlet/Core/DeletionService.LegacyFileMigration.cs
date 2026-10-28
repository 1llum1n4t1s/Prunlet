using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private const string LegacyDiscardGateName = ".legacy-file-discard-in-progress";
    private const string LegacyMigrationPrefix = ".legacy-file-migration-";
    private const string LegacyBundlePrefix = ".prunlet-file-migration-";
    internal static event Action<string, string>? LegacyDiscardCheckpoint;

    // 公開deleteの保護解除には使わず、所有確認した明示移行対象だけを渡す。
    private sealed record SourceInternalValidatedMigrationTarget(string Path, MoveEntryIdentity Identity, Action Validate);

    private void MigrateLegacyFileRecovery(bool apply, bool scanCentral, bool retryLegacyDiscard, RecoveryMigrationResult result)
    {
        var gate = Path.Combine(config.BackupDirectory, LegacyDiscardGateName);
        try
        {
            if (InspectMoveLocation(gate) is not null)
            {
                if (!retryLegacyDiscard)
                {
                    result.Complete = false;
                    result.Warnings.Add("Legacy file discard is uncertain. Inspect the original locations and Windows Recycle Bin, then explicitly acknowledge retry with migrate --apply --retry-legacy-discard. Registry processing remains available.");
                    return;
                }
                RemoveLegacyDiscardGate(gate);
            }
        }
        catch (Exception ex) when (IsLegacyDiscardFailure(ex))
        {
            result.Complete = false;
            result.Warnings.Add("Legacy file discard gate was retained: " + ex.Message);
            return;
        }

        var targets = new List<SourceInternalValidatedMigrationTarget>();
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        VolumeRecoveryStore.InspectExistingRoots(config, (path, _, identity, restore) =>
        {
            if (names.Add(path)) targets.Add(new(path, identity,
                () => VolumeRecoveryStore.ValidateExistingRoot(config, path, identity, restore)));
        }, (path, error) =>
        {
            result.Complete = false;
            result.Warnings.Add("Legacy file store is unavailable; explicit migration can retry: " + path + ": " + error.Message);
        }, includeRestore: true);

        if (scanCentral)
        {
            try
            {
                foreach (var path in Directory.EnumerateFileSystemEntries(config.BackupDirectory))
                {
                    var name = Path.GetFileName(path);
                    if (name == LegacyDiscardGateName || name == RegistryRecordsDirectory || name == "maintenance.lock") continue;
                    var typed = name is RecycleRecordsDirectory or ClosedRecordsDirectory;
                    var reserved = name.StartsWith(LegacyMigrationPrefix, StringComparison.Ordinal)
                        || name.StartsWith(LegacyBundlePrefix, StringComparison.Ordinal);
                    var operation = Guid.TryParseExact(name, "N", out var parsed) && parsed.ToString("N") == name;
                    if (!typed && !reserved && !operation) continue;
                    try
                    {
                        var identity = InspectMoveLocation(path) ?? throw new IOException("Legacy candidate disappeared.");
                        void Validate()
                        {
                            using var ancestors = PathPolicy.PinRecoveryDirectories(config.BackupDirectory);
                            using var handle = identity.IsDirectory
                                ? NativeFiles.OpenLegacyDirectoryInspection(path) : NativeFiles.OpenShellInspection(path);
                            var actual = NativeFiles.MoveIdentity(handle);
                            if (!UsableRecordlessIdentity(identity) || !UsableRecordlessIdentity(actual)
                                || !SameRecordlessObject(identity, actual) || actual.ReparseTag != 0)
                                throw new IOException("Legacy candidate identity changed or is a link.");
                            var fileMarker = false;
                            var registrySignal = actual.IsDirectory && NativeFiles.AnyPinnedDirectoryName(handle, entry =>
                            {
                                fileMarker |= IsLegacyFileMarker(entry);
                                return IsLegacyRegistrySignal(entry);
                            });
                            if (typed)
                            {
                                if (!actual.IsDirectory || ValidatedRecordRoot(name) != path || registrySignal)
                                    throw new IOException("Legacy typed file root ownership differs.");
                            }
                            else if (reserved)
                            {
                                using var backup = NativeFiles.OpenPrivateRegistryDirectory(config.BackupDirectory);
                                NativeFiles.VerifyPrivateRegistrySecurity(backup, directory: true);
                                if (actual.IsDirectory && registrySignal)
                                    throw new IOException("Registry signals protect this legacy candidate.");
                            }
                            else if (!actual.IsDirectory || registrySignal || !fileMarker)
                                throw new IOException("Unknown or registry-bearing legacy operation was retained.");
                        }
                        Validate();
                        if (names.Add(path)) targets.Add(new(path, identity, Validate));
                    }
                    catch (Exception ex) when (IsLegacyDiscardFailure(ex))
                    {
                        result.Complete = false;
                        result.Operations.Add(new() { Path = path, Status = "retained", Error = ex.Message });
                    }
                }
            }
            catch (Exception ex) when (IsLegacyDiscardFailure(ex))
            {
                result.Complete = false;
                result.Warnings.Add("Legacy central file discovery is unavailable: " + ex.Message);
            }
        }

        var gateCreated = false;
        var gateCreationAttempted = false;
        var uncertain = false;
        var gateRemovalStarted = false;
        SafeFileHandle? gateLease = null;
        try
        {
            foreach (var target in targets)
            {
                var item = new RecoveryMigrationOperation { Path = target.Path, Status = "would_recycle" };
                result.Operations.Add(item);
                var started = false;
                try
                {
                    if (InspectMoveLocation(target.Path) is null) { item.Status = "already_absent"; continue; }
                    target.Validate();
                    if (target.Identity.IsDirectory && HasLegacyRegistrySignal(target.Path, target.Identity))
                        throw new IOException("Registry signals protect this legacy directory.");
                    if (!apply) continue;
                    using var original = NativeFiles.OpenShellInspection(target.Path);
                    var heldIdentity = NativeFiles.MoveIdentity(original);
                    if (!UsableRecordlessIdentity(target.Identity) || !UsableRecordlessIdentity(heldIdentity)
                        || !SameRecordlessObject(target.Identity, heldIdentity))
                        throw new IOException("Legacy candidate identity changed or is unavailable.");
                    using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(target.Path)!);
                    using (var parent = NativeFiles.OpenDirectory(Path.GetDirectoryName(target.Path)!))
                        NativeFiles.Verify(parent, Path.GetDirectoryName(target.Path)!, directory: true);
                    if (!gateCreated)
                    {
                        gateCreationAttempted = true;
                        gateLease = NativeFiles.CreatePrivateRegistryFile(gate);
                        gateCreated = true;
                        RandomAccess.FlushToDisk(gateLease);
                        VerifyLegacyDiscardGate(gate, gateLease);
                        LegacyDiscardCheckpoint?.Invoke("gate.flushed", target.Path);
                    }
                    NativeRecycleBin.RecycleUnrecorded(target.Path, resolved =>
                    {
                        if (!resolved.Equals(target.Path, StringComparison.OrdinalIgnoreCase))
                            throw new IOException("Shell resolved another legacy migration source.");
                        target.Validate();
                        if (heldIdentity.IsDirectory && HasLegacyRegistrySignal(target.Path, heldIdentity))
                            throw new IOException("Registry signals protect this legacy directory.");
                        started = true;
                        LegacyDiscardCheckpoint?.Invoke("shell.ready", target.Path);
                    }, recycledPath =>
                    {
                        if (heldIdentity.IsDirectory)
                        {
                            using var recycled = NativeFiles.OpenRecycledDirectory(recycledPath);
                            VerifyRecycledObject(recycled, heldIdentity);
                            if (NativeFiles.AnyPinnedDirectoryName(recycled, IsLegacyRegistrySignal))
                                throw new IOException("Registry signals appeared in the recycled legacy directory.");
                        }
                        else VerifyRecycledObject(recycledPath, heldIdentity);
                    });
                    LegacyDiscardCheckpoint?.Invoke("shell.returned", target.Path);
                    if (InspectMoveLocation(target.Path) is not null)
                        throw new IOException("Legacy source remains after Shell recycle.");
                    item.Status = "recycled";
                }
                catch (Exception ex) when (IsLegacyDiscardFailure(ex))
                {
                    item.Status = started ? "ambiguous" : "failed";
                    item.Error = ex.Message;
                    result.Complete = false;
                    if (gateCreated || gateCreationAttempted)
                    {
                        uncertain = true;
                        result.Warnings.Add(gateCreated
                            ? "Legacy file discard stopped with its uncertainty gate retained. Inspect the original location and Windows Recycle Bin before explicitly acknowledging retry."
                            : "Legacy discard gate creation could not be verified; a gate may remain. Inspect the gate and original location before retrying.");
                        break;
                    }
                }
            }
            if (gateCreated && !uncertain)
            {
                try
                {
                    VerifyLegacyDiscardGate(gate, gateLease ?? throw new IOException("Legacy discard gate handle is unavailable."));
                    NativeFiles.SetOriginalDeletePending(gateLease, true);
                    gateRemovalStarted = true;
                }
                catch (Exception ex) when (IsLegacyDiscardFailure(ex))
                {
                    result.Complete = false;
                    result.Warnings.Add("Legacy discard succeeded but its uncertainty gate could not be removed: " + ex.Message);
                }
            }
        }
        finally { gateLease?.Dispose(); }
        if (gateRemovalStarted)
        {
            try
            {
                if (InspectMoveLocation(gate) is not null) throw new IOException("Legacy discard gate still exists after deletion.");
            }
            catch (Exception ex) when (IsLegacyDiscardFailure(ex))
            {
                result.Complete = false;
                result.Warnings.Add("Legacy discard succeeded but its uncertainty gate removal could not be confirmed: " + ex.Message);
            }
        }
    }

    private static bool HasLegacyRegistrySignal(string directory, MoveEntryIdentity expected)
    {
        using var handle = NativeFiles.OpenLegacyDirectoryInspection(directory);
        var actual = NativeFiles.MoveIdentity(handle);
        if (!UsableRecordlessIdentity(expected) || !UsableRecordlessIdentity(actual)
            || !SameRecordlessObject(expected, actual) || actual.ReparseTag != 0)
            throw new IOException("Legacy directory identity changed or is a link.");
        NativeFiles.Verify(handle, directory, directory: true);
        return NativeFiles.AnyPinnedDirectoryName(handle, IsLegacyRegistrySignal);
    }

    private static bool IsLegacyRegistrySignal(string? name) => name is not null
        && (name.StartsWith("registry-", StringComparison.OrdinalIgnoreCase)
            || name.StartsWith(".registry-", StringComparison.OrdinalIgnoreCase) || name == RegistryRecordsDirectory);

    private static bool IsLegacyFileMarker(string name) => name is "manifest.json" or "move-manifest.json" or "recycle-manifest.json";

    private static bool IsLegacyDiscardFailure(Exception error) => IsRecycleFailure(error)
        || error is JsonException or FormatException or System.Security.SecurityException;

    private static void VerifyLegacyDiscardGate(string path)
    {
        using var handle = NativeFiles.OpenLifecycleMetadata(path);
        VerifyLegacyDiscardGate(path, handle);
    }

    private static void VerifyLegacyDiscardGate(string path, SafeFileHandle handle)
    {
        NativeFiles.Verify(handle, path); NativeFiles.VerifySingleLink(handle);
        NativeFiles.VerifyPrivateRegistrySecurity(handle); NativeFiles.RejectNamedStreams(path);
        if (RandomAccess.GetLength(handle) != 0) throw new IOException("Legacy discard gate is not an empty private file.");
    }

    private static void RemoveLegacyDiscardGate(string path)
    {
        using var handle = NativeFiles.OpenLifecycleDelete(path);
        NativeFiles.Verify(handle, path); NativeFiles.VerifySingleLink(handle);
        NativeFiles.VerifyPrivateRegistrySecurity(handle); NativeFiles.RejectNamedStreams(path);
        if (RandomAccess.GetLength(handle) != 0) throw new IOException("Legacy discard gate is not an empty private file.");
        NativeFiles.SetOriginalDeletePending(handle, true);
    }
}
