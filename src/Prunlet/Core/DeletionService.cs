using System.Security.Cryptography;
using System.Text.Json;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private readonly PrunletConfig config;
    private readonly RegistrySessionContext? registrySession;
    private const int CopyBufferSize = 128 * 1024;
    internal event Action<TimeSpan, bool>? RecoveryLockProgress;

    public DeletionService(PrunletConfig config) : this(config, null) { }

    internal DeletionService CreateRequestService() => new(config, registrySession);

    internal DeletionService(PrunletConfig config, RegistrySessionContext? registrySession)
    {
        ArgumentNullException.ThrowIfNull(config);
        config.Validate();
        this.registrySession = registrySession;
        this.config = new PrunletConfig
        {
            Schema = config.Schema,
            AllowedRoots = config.AllowedRoots?.ToArray() ?? [],
            RetentionDays = config.RetentionDays,
            MaxRecoveryBytes = config.MaxRecoveryBytes,
            RegistryScope = config.RegistryScope,
            RegistrySessionFile = config.RegistrySessionFile,
            VolumeRecoveryDirectories = config.VolumeRecoveryDirectories.ToDictionary(pair => PathPolicy.Absolute(pair.Key),
                pair => PathPolicy.Absolute(pair.Value), StringComparer.OrdinalIgnoreCase),
            BackupDirectory = PathPolicy.Resolve(config.BackupDirectory, finalDirectory: true, allowMissing: false)
        };
    }

    public DeleteResult Delete(string[] paths, bool dryRun = false, bool recursive = false)
    {
        return DeleteRecycle(paths, dryRun, recursive);
    }

    public RestoreResult Restore(string operationId)
        => RestoreOperation(operationId, expectedRegistry: null);

    private RestoreResult RestoreOperation(string operationId, bool? expectedRegistry)
    {
        config.Validate();
        if (!Guid.TryParseExact(operationId, "N", out var id) || id.ToString("N") != operationId)
            throw new ArgumentException("Operation ID must be a lowercase 32-character GUID.");
        if (expectedRegistry is bool preflight && preflight != IsRegistryOperation(operationId))
            throw new ArgumentException(preflight ? "Operation is not a registry recovery operation." : "Registry operations cannot be restored through the file-only entry point.");
        // 委任先が同じ共通lockを取るので、RPCは必ず取得より前に行う。
        if (registrySession is null && config.RegistryScope == "nativeWindows" && IsRegistryOperation(operationId))
            return RegistrySessionClient.Restore(config, operationId, RecoveryLockProgress);
        using var coordination = AcquireRecoveryCoordination(create: true);
        var registry = IsRegistryOperation(operationId);
        if (expectedRegistry is bool expected && expected != registry)
            throw new ArgumentException(expected ? "Operation is not a registry recovery operation." : "Registry operations cannot be restored through the file-only entry point.");
        if (registry) return RestoreRegistryCore(operationId);
        if (IsRecycleOperation(operationId)) return RestoreRecycle(operationId);
        if (IsMoveOperation(operationId)) return RestoreMoves(operationId);
        var directory = Path.Combine(config.BackupDirectory, operationId);
        using var directories = PathPolicy.PinRecoveryDirectories(directory);
        using var operationLock = NativeFiles.OpenLock(Path.Combine(directory, "operation.lock"));
        NativeFiles.Verify(operationLock, Path.Combine(directory, "operation.lock"));
        NativeFiles.VerifySingleLink(operationLock);
        NativeFiles.RejectNamedStreams(Path.Combine(directory, "operation.lock"));
        if (Directory.EnumerateFileSystemEntries(directory).Any(path => Path.GetFileName(path).Equals("purge-intent.json", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("Recovery copies have been scheduled for purge; restoration is unavailable for this operation.");
        var manifestPath = Path.Combine(directory, "manifest.json");
        using var manifestHandle = NativeFiles.OpenBackup(manifestPath);
        NativeFiles.Verify(manifestHandle, manifestPath);
        NativeFiles.VerifySingleLink(manifestHandle);
        NativeFiles.RejectNamedStreams(manifestPath);
        using var manifestStream = new FileStream(manifestHandle, FileAccess.Read);
        var manifest = ReadValidatedJson<OperationManifest>(manifestStream);
        ValidateManifest(manifest, operationId);
        if (manifest.Schema == 3) return RestoreSpecial(manifest, directory);
        if (manifest.Schema == 2) return RestoreTrees(manifest, directory);
        var result = new RestoreResult { OperationId = operationId };
        for (var i = 0; i < manifest.Items.Count; i++)
        {
            var entry = manifest.Items[i];
            var item = new FileOperationResult { Path = entry.Path, Status = "not_backed_up" };
            result.Items.Add(item);
            if (entry.State != "backup_ready") continue;
            item.BackupPath = BackupPath(directory, i);
            item.Sha256 = entry.Sha256;
            item.Size = entry.Size;
            try { RestoreOne(entry, item); }
            catch (Exception ex) when (IsOperational(ex)) { item.Status = "failed"; item.Error = ex.Message; }
        }
        TryWriteResult(Path.Combine(directory, $"restore-result-{Guid.NewGuid():N}.json"), result, result.Warnings);
        return result;
    }

    private string ValidateTarget(string path)
    {
        var normalized = PathPolicy.Resolve(path);
        if (PathPolicy.Within(normalized, config.BackupDirectory))
            throw new ArgumentException($"Target path is inside the recovery directory: {normalized}");
        return normalized;
    }

    private void ValidateManifest(OperationManifest manifest, string operationId)
    {
        if (manifest.Schema is not (1 or 2 or 3) || manifest.OperationId != operationId || manifest.CreatedUtc == default || manifest.Items is null
            || manifest.Items.Count == 0 || (manifest.Schema == 1 && manifest.Items.Count > 256))
            throw new InvalidDataException("Manifest schema, ID, or item count is invalid.");
        var seen = new HashSet<string>(manifest.Schema == 3 ? StringComparer.Ordinal : StringComparer.OrdinalIgnoreCase);
        foreach (var entry in manifest.Items)
        {
            if (entry is null) throw new InvalidDataException("Manifest contains a null entry.");
            // schema 1 の記録文字列は変更せず、実行時の実体解決とは分けて検査する。
            var normalized = PathPolicy.Absolute(entry.Path);
            if (normalized != entry.Path || !seen.Add(normalized) || PathPolicy.Within(normalized, config.BackupDirectory)
                || (entry.Kind == "directory" && (normalized.Length == 3 || PathPolicy.Within(config.BackupDirectory, normalized))))
                throw new InvalidDataException("Manifest path is not canonical, duplicated, or inside the recovery directory.");
            if (entry.State is not ("backup_ready" or "already_absent" or "failed")) throw new InvalidDataException("Invalid manifest state.");
            if (entry.Attributes is uint attributes && ((attributes & ~NativeFiles.RestorableAttributeMask) != 0
                || ((attributes & (uint)FileAttributes.Normal) != 0 && attributes != (uint)FileAttributes.Normal)))
                throw new InvalidDataException("Manifest attributes contain unsupported bits or combine Normal with other attributes.");
            if ((manifest.Schema == 3 ? entry.Kind is not ("file" or "directory" or "symlink" or "junction") : entry.Kind is not ("file" or "directory")) || (manifest.Schema == 1 && (entry.Kind != "file" || entry.TreeRoot is not null)))
                throw new InvalidDataException("Invalid manifest entry kind or tree root.");
            if (manifest.Schema != 3 && (entry.Streams is not null || entry.ReparseTag is not null || entry.LinkDirectory || entry.CaseSensitive))
                throw new InvalidDataException("Special metadata requires schema 3.");
            if (manifest.Schema != 3 && entry.Kind == "directory" && (entry.Size is not null || entry.Sha256 is not null))
                throw new InvalidDataException("Directory records cannot contain file backup metadata.");
            if ((entry.Kind == "file" || manifest.Schema == 3) && entry.State == "backup_ready" && (entry.Size is null or < 0 || entry.Sha256 is null
                || entry.Sha256.Length != 64 || !entry.Sha256.All(char.IsAsciiHexDigit)))
                throw new InvalidDataException("Manifest hash or size is invalid.");
        }
        if (manifest.Schema == 3) ValidateSpecialManifest(manifest);
        if (manifest.Schema == 2) ValidateTreeManifest(manifest);
    }

    private void RestoreOne(ManifestEntry entry, FileOperationResult item, FileStream? verifiedBackup = null)
    {
        var target = ValidateTarget(entry.Path);
        using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(target)!);
        using var backupHandle = verifiedBackup is null ? NativeFiles.OpenBackup(item.BackupPath!) : null;
        var heldHandle = verifiedBackup?.SafeFileHandle ?? backupHandle!;
        NativeFiles.Verify(heldHandle, item.BackupPath!);
        NativeFiles.VerifySingleLink(heldHandle);
        NativeFiles.RejectNamedStreams(item.BackupPath!);
        using var ownedBackup = verifiedBackup is null ? new FileStream(backupHandle!, FileAccess.Read) : null;
        var backup = verifiedBackup ?? ownedBackup!;
        // 呼び出し元が検証後も書込み・削除共有なしで保持するコピーは、その同じストリームを借用する。
        if (verifiedBackup is null)
        {
            var digest = Convert.ToHexStringLower(SHA256.HashData(backup));
            if (backup.Length != entry.Size || !digest.Equals(entry.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Backup hash or size differs from the manifest.");
        }
        backup.Position = 0;
        if (Path.Exists(target)) { item.Status = "conflict"; item.Error = "Original path already exists; nothing was overwritten."; return; }
        Microsoft.Win32.SafeHandles.SafeFileHandle destinationHandle;
        try { destinationHandle = NativeFiles.CreateDestination(target); }
        catch (IOException) when (Path.Exists(target)) { item.Status = "conflict"; item.Error = "Original path was concurrently created; nothing was overwritten."; return; }
        using (destinationHandle)
        using (var destination = new FileStream(destinationHandle, FileAccess.ReadWrite))
        {
            try
            {
                NativeFiles.Verify(destinationHandle, target);
                backup.CopyTo(destination);
                destination.Flush(true);
                destination.Position = 0;
                if (!Convert.ToHexString(SHA256.HashData(destination)).Equals(entry.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Restored file hash verification failed.");
                if (entry.LastWriteUtc.HasValue) NativeFiles.RestoreLastWriteTime(destinationHandle, entry.LastWriteUtc.Value);
                NativeFiles.RestoreAttributes(destinationHandle, entry.Attributes);
                item.Status = "restored";
            }
            catch (Exception original) when (IsOperational(original))
            {
                try { NativeFiles.DeleteOriginalHandle(destinationHandle); }
                catch (Exception cleanup) when (IsOperational(cleanup))
                { throw new IOException($"{original.Message} Partial restored file could not be removed: {cleanup.Message}", original); }
                throw;
            }
        }
    }

    private static string BackupPath(string directory, int index) => Path.Combine(directory, $"{index:D4}.bak");

    private static void WriteNewJson<T>(string path, T value)
    {
        using var handle = NativeFiles.CreateDestination(path);
        NativeFiles.Verify(handle, path);
        using var stream = new FileStream(handle, FileAccess.ReadWrite);
        JsonSerializer.Serialize(stream, value, PrunletConfig.JsonOptions);
        stream.Flush(true);
    }

    private static void TryWriteResult<T>(string path, T value, List<string> warnings)
    {
        try { WriteNewJson(path, value); }
        catch (Exception ex) when (IsOperational(ex)) { warnings.Add($"Outcome record could not be persisted: {ex.Message}. Backups remain available."); }
    }

    private static bool IsOperational(Exception ex) => ex is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException or System.Security.SecurityException;
}
