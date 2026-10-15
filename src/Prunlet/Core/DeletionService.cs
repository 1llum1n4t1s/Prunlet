using System.Buffers;
using System.Security.Cryptography;
using System.Text.Json;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private readonly PrunletConfig config;
    private const int CopyBufferSize = 128 * 1024;

    public DeletionService(PrunletConfig config)
    {
        ArgumentNullException.ThrowIfNull(config);
        config.Validate();
        this.config = new PrunletConfig
        {
            Schema = config.Schema,
            AllowedRoots = config.AllowedRoots?.ToArray() ?? [],
            RetentionDays = config.RetentionDays,
            MaxRecoveryBytes = config.MaxRecoveryBytes,
            BackupDirectory = PathPolicy.Resolve(config.BackupDirectory, finalDirectory: true, allowMissing: false)
        };
    }

    public DeleteResult Delete(string[] paths, bool dryRun = false, bool recursive = false)
    {
        config.Validate();
        ArgumentNullException.ThrowIfNull(paths);
        if (paths.Length is 0 or > 256) throw new ArgumentException("Specify between 1 and 256 paths.");
        var normalized = paths.Select(ValidateAnyTarget).ToArray();
        for (var i = 0; i < normalized.Length; i++)
            for (var j = i + 1; j < normalized.Length; j++)
                if (ExactWithin(normalized[i], normalized[j]) || ExactWithin(normalized[j], normalized[i]))
                    throw new ArgumentException("Duplicate or overlapping target paths are not allowed.");
        if (dryRun) return DeleteDispatch(normalized, true, recursive);
        using var coordination = AcquireRecoveryCoordination(create: true);
        var preview = DeleteDispatch(normalized, true, recursive);
        if (preview.Items.Any(item => item.Status == "failed"))
            throw new IOException("Deletion preflight failed; no originals or recovery copies were removed. " +
                string.Join(" ", preview.Items.Where(item => item.Error is not null).Select(item => item.Error)));
        var incoming = preview.Items.Aggregate(0L, (sum, item) => checked(sum + (item.Size ?? 0)));
        if (incoming > config.MaxRecoveryBytes)
            throw new IOException("The incoming recovery copy exceeds maxRecoveryBytes; original targets were retained.");
        var maintenance = MaintainRecoveryCore(apply: true, incoming);
        if (!maintenance.CapacityKnown || !maintenance.BudgetSatisfied)
            throw new IOException("Recovery capacity could not be safely made available; original targets were retained. " + string.Join(" ", maintenance.Warnings));
        remainingRecoveryBytes = config.MaxRecoveryBytes - maintenance.RetainedBytesAfter;
        try
        {
            var result = DeleteDispatch(normalized, false, recursive);
            result.Warnings.AddRange(maintenance.Warnings);
            return result;
        }
        finally { remainingRecoveryBytes = null; }
    }

    private DeleteResult DeleteDispatch(string[] normalized, bool dryRun, bool recursive)
    {
        if (normalized.Any(path => HasSpecialTarget(path, recursive))) return DeleteSpecial(normalized, dryRun, recursive);
        if (normalized.Any(IsDirectoryPath)) return DeleteTrees(normalized, dryRun, recursive);
        return DeleteFiles(normalized, dryRun);
    }

    private DeleteResult DeleteFiles(string[] paths, bool dryRun)
    {
        config.Validate();
        ArgumentNullException.ThrowIfNull(paths);
        if (paths.Length == 0 || paths.Length > 256) throw new ArgumentException("Specify between 1 and 256 files.");
        var normalized = paths.Select(ValidateTarget).ToArray();
        if (normalized.Distinct(StringComparer.OrdinalIgnoreCase).Count() != normalized.Length)
            throw new ArgumentException("Duplicate paths are not allowed.");
        foreach (var path in normalized) PathPolicy.Inspect(path);
        var result = new DeleteResult { DryRun = dryRun };
        if (dryRun)
        {
            foreach (var path in normalized) result.Items.Add(CheckOnly(path));
            return result;
        }

        using var operation = NewOperationLease.Create(config.BackupDirectory);
        var operationId = operation.OperationId;
        var directory = operation.Directory;
        result.OperationId = operationId;
        var manifest = new OperationManifest { OperationId = operationId };
        var prepared = new List<PreparedFile>();
        try
        {
            for (var i = 0; i < normalized.Length; i++)
            {
                var entry = new ManifestEntry { Path = normalized[i] };
                var item = new FileOperationResult { Path = normalized[i], Status = "failed" };
                manifest.Items.Add(entry);
                result.Items.Add(item);
                try
                {
                    var ready = Prepare(normalized[i], BackupPath(directory, i), entry, item);
                    prepared.Add(ready);
                    entry.State = "backup_ready";
                    item.Status = "backup_ready";
                }
                catch (FileNotFoundException) { entry.State = item.Status = "already_absent"; }
                catch (DirectoryNotFoundException) { entry.State = item.Status = "already_absent"; }
                catch (Exception ex) when (IsOperational(ex)) { entry.State = "failed"; item.Error = ex.Message; }
            }
            try { WriteNewJson(Path.Combine(directory, "manifest.json"), manifest); }
            catch (Exception ex) when (IsOperational(ex))
            {
                foreach (var ready in prepared)
                {
                    ready.Item.Status = "failed";
                    ready.Item.Error = $"No deletion was attempted because manifest persistence failed: {ex.Message}";
                }
                return result;
            }
            foreach (var ready in prepared)
            {
                try
                {
                    NativeFiles.Verify(ready.Source.SafeFileHandle, ready.Entry.Path);
                    NativeFiles.DeleteHandle(ready.Source.SafeFileHandle);
                    // DELETE_PENDING は最後のハンドルを閉じた時点で反映される。
                    ready.Source.Dispose();
                    ready.Item.Status = "deleted";
                }
                catch (Exception ex) when (IsOperational(ex))
                {
                    ready.Item.Status = "failed";
                    ready.Item.Error = ex.Message;
                }
            }
            TryWriteResult(Path.Combine(directory, "delete-result.json"), result, result.Warnings);
            return result;
        }
        finally { foreach (var ready in prepared) ready.Dispose(); }
    }

    public RestoreResult Restore(string operationId)
    {
        config.Validate();
        using var coordination = AcquireRecoveryCoordination(create: true);
        if (!Guid.TryParseExact(operationId, "N", out var id) || id.ToString("N") != operationId)
            throw new ArgumentException("Operation ID must be a lowercase 32-character GUID.");
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

    private static FileOperationResult CheckOnly(string path, bool parentsPinned = false)
    {
        var item = new FileOperationResult { Path = path };
        try
        {
            using var parents = parentsPinned ? null : PathPolicy.PinDirectories(Path.GetDirectoryName(path)!);
            using var handle = NativeFiles.OpenBackup(path);
            NativeFiles.Verify(handle, path);
            NativeFiles.VerifySingleLink(handle);
            NativeFiles.RejectNamedStreams(path);
            using var stream = new FileStream(handle, FileAccess.Read);
            item.Size = stream.Length;
            item.Status = "would_delete";
        }
        catch (FileNotFoundException) { item.Status = "already_absent"; }
        catch (DirectoryNotFoundException) { item.Status = "already_absent"; }
        catch (Exception ex) when (IsOperational(ex)) { item.Status = "failed"; item.Error = ex.Message; }
        return item;
    }

    private PreparedFile Prepare(string path, string backupPath, ManifestEntry entry, FileOperationResult item, bool parentsPinned = false)
    {
        var parents = parentsPinned ? null : PathPolicy.PinDirectories(Path.GetDirectoryName(path)!);
        FileStream? source = null, backup = null;
        try
        {
            var sourceHandle = NativeFiles.OpenSource(path);
            try { NativeFiles.Verify(sourceHandle, path); NativeFiles.VerifySingleLink(sourceHandle); source = new FileStream(sourceHandle, FileAccess.Read); }
            catch { sourceHandle.Dispose(); throw; }
            NativeFiles.RejectNamedStreams(path);
            var backupHandle = NativeFiles.CreateDestination(backupPath);
            try { NativeFiles.Verify(backupHandle, backupPath); backup = new FileStream(backupHandle, FileAccess.ReadWrite); }
            catch { backupHandle.Dispose(); throw; }
            entry.Size = source.Length;
            entry.LastWriteUtc = File.GetLastWriteTimeUtc(path);
            using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = ArrayPool<byte>.Shared.Rent(CopyBufferSize);
            try
            {
                int count;
                while ((count = source.Read(buffer, 0, CopyBufferSize)) != 0)
                {
                    ReserveRecoveryBytes(count);
                    backup.Write(buffer, 0, count);
                    digest.AppendData(buffer, 0, count);
                }
            }
            finally { ArrayPool<byte>.Shared.Return(buffer, clearArray: true); }
            backup.Flush(true);
            entry.Sha256 = Convert.ToHexString(digest.GetHashAndReset()).ToLowerInvariant();
            backup.Position = 0;
            var backupHash = Convert.ToHexString(SHA256.HashData(backup)).ToLowerInvariant();
            if (entry.Sha256 != backupHash || backup.Length != entry.Size)
                throw new IOException("Backup size/hash verification failed. Source was not deleted.");
            item.BackupPath = backupPath;
            item.Sha256 = entry.Sha256;
            item.Size = entry.Size;
            return new PreparedFile(parents, source, backup, entry, item);
        }
        catch { backup?.Dispose(); source?.Dispose(); parents?.Dispose(); throw; }
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
            var digest = Convert.ToHexString(SHA256.HashData(backup)).ToLowerInvariant();
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
                if (entry.LastWriteUtc.HasValue) File.SetLastWriteTimeUtc(target, entry.LastWriteUtc.Value);
                item.Status = "restored";
            }
            catch (Exception original) when (IsOperational(original))
            {
                try { NativeFiles.DeleteHandle(destinationHandle); }
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

    private sealed class PreparedFile(DirectoryLease? parents, FileStream source, FileStream backup, ManifestEntry entry, FileOperationResult item) : IDisposable
    {
        internal FileStream Source { get; } = source;
        internal ManifestEntry Entry { get; } = entry;
        internal FileOperationResult Item { get; } = item;
        public void Dispose() { backup.Dispose(); Source.Dispose(); parents?.Dispose(); }
    }
}
