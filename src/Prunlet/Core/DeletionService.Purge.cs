using System.Security.Cryptography;
using System.Text.Json;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    public PurgeResult Purge(string operationId, bool apply = false)
    {
        config.Validate();
        if (!Guid.TryParseExact(operationId, "N", out var id) || id.ToString("N") != operationId)
            throw new ArgumentException("Operation ID must be a lowercase 32-character GUID.");
        var directory = Path.Combine(config.BackupDirectory, operationId);
        using var directories = PathPolicy.PinRecoveryDirectories(directory);
        using var operationLock = NativeFiles.OpenLock(Path.Combine(directory, "operation.lock"));
        NativeFiles.Verify(operationLock, Path.Combine(directory, "operation.lock"));
        NativeFiles.VerifySingleLink(operationLock);
        NativeFiles.RejectNamedStreams(Path.Combine(directory, "operation.lock"));
        if (RandomAccess.GetLength(operationLock) != 0) throw new InvalidDataException("Operation lock is not empty.");
        var held = new List<FileStream>();
        try
        {
            var manifestStream = HoldPurgeMetadata(Path.Combine(directory, "manifest.json"), held);
            var manifestHash = HashStream(manifestStream);
            var manifest = ReadValidatedJson<OperationManifest>(manifestStream);
            ValidateManifest(manifest, operationId);
            var expectedIntent = new PurgeIntent
            {
                OperationId = operationId,
                ManifestSha256 = manifestHash,
                Targets = manifest.Items.Select((entry, index) => (entry, index))
                    .Where(pair => HasRecoveryCopy(manifest, pair.entry))
                    .Select(pair => new PurgeTarget { Index = pair.index, Sha256 = pair.entry.Sha256!, Size = pair.entry.Size!.Value }).ToList()
            };
            var members = Directory.EnumerateFileSystemEntries(directory).Select(Path.GetFileName).ToHashSet(StringComparer.Ordinal);
            PurgeIntent? intent = null;
            var intentPath = Path.Combine(directory, "purge-intent.json");
            if (members.Contains("purge-intent.json"))
            {
                intent = ReadValidatedJson<PurgeIntent>(HoldPurgeMetadata(intentPath, held));
                ValidatePurgeIntent(intent, expectedIntent);
            }
            var backupNames = manifest.Items.Select((entry, index) => (entry, index))
                .Where(pair => HasRecoveryCopy(manifest, pair.entry))
                .ToDictionary(pair => $"{pair.index:D4}.bak", pair => pair.index, StringComparer.Ordinal);
            foreach (var name in members)
            {
                if (name is "manifest.json" or "operation.lock" or "purge-intent.json" || backupNames.ContainsKey(name!)) continue;
                var kind = PurgeMetadataKind(name!);
                if (kind is null) throw new InvalidDataException($"Unknown operation member; purge refused: {name}");
                var stream = HoldPurgeMetadata(Path.Combine(directory, name!), held);
                ValidatePurgeOutcome(stream, kind, manifest, directory, intent);
            }
            var result = new PurgeResult { OperationId = operationId, DryRun = !apply };
            var backups = new Dictionary<int, FileStream>();
            for (var index = 0; index < manifest.Items.Count; index++)
            {
                var entry = manifest.Items[index];
                var item = new FileOperationResult { Path = entry.Path, Kind = entry.Kind, Status = "not_backed_up", Schema2Wire = manifest.Schema >= 2 };
                result.Items.Add(item);
                if (!HasRecoveryCopy(manifest, entry)) continue;
                item.BackupPath = BackupPath(directory, index);
                item.Size = entry.Size;
                item.Sha256 = entry.Sha256;
                var name = $"{index:D4}.bak";
                if (!members.Contains(name))
                {
                    if (intent is null) throw new InvalidDataException($"Verified recovery copy is missing without purge intent: {name}");
                    item.Status = "already_purged";
                    continue;
                }
                var handle = NativeFiles.OpenPurgeTarget(item.BackupPath);
                FileStream stream;
                try
                {
                    NativeFiles.Verify(handle, item.BackupPath);
                    NativeFiles.VerifySingleLink(handle);
                    NativeFiles.RejectNamedStreams(item.BackupPath);
                    stream = new FileStream(handle, FileAccess.Read);
                }
                catch { handle.Dispose(); throw; }
                held.Add(stream);
                if (stream.Length != entry.Size || !HashStream(stream).Equals(entry.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException($"Recovery copy size/hash differs from manifest: {name}");
                if (manifest.Schema == 3) VerifySpecialBackupContents(stream, entry);
                backups.Add(index, stream);
                item.Status = "would_purge";
            }
            VerifyPurgeMembers(directory, members);
            if (!apply) return result;
            if (intent is null)
            {
                // 全検査が完了するまで意図を書かず、永続化に失敗したら削除を始めない。
                var publishedIntent = PublishPurgeJson(intentPath, operationId, expectedIntent,
                    stream => ValidatePurgeIntent(ReadValidatedJson<PurgeIntent>(stream), expectedIntent), held);
                intent = ReadValidatedJson<PurgeIntent>(publishedIntent);
                ValidatePurgeIntent(intent, expectedIntent);
                members.Add("purge-intent.json");
            }
            foreach (var (index, stream) in backups)
            {
                try
                {
                    // 途中で追加された未知のファイルは触らず、以降の削除も止める。
                    VerifyPurgeMembers(directory, members);
                    NativeFiles.Verify(stream.SafeFileHandle, result.Items[index].BackupPath!);
                    NativeFiles.VerifySingleLink(stream.SafeFileHandle);
                    NativeFiles.RejectNamedStreams(result.Items[index].BackupPath!);
                    NativeFiles.DeleteHandle(stream.SafeFileHandle);
                    stream.Dispose();
                    members.Remove($"{index:D4}.bak");
                    VerifyPurgeMembers(directory, members);
                    result.Items[index].Status = "purged";
                    result.PurgedBytes += manifest.Items[index].Size!.Value;
                }
                catch (Exception ex) when (IsOperational(ex))
                {
                    result.Items[index].Status = "failed";
                    result.Items[index].Error = ex.Message;
                    break;
                }
            }
            try
            {
                VerifyPurgeMembers(directory, members);
                PublishPurgeJson(Path.Combine(directory, $"purge-result-{Guid.NewGuid():N}.json"), operationId, result,
                    stream => ValidatePurgeOutcome(stream, "purge", manifest, directory, intent), held);
            }
            catch (Exception ex) when (IsOperational(ex))
            {
                result.Warnings.Add($"Purge outcome record could not be persisted: {ex.Message}. Purge intent remains for safe continuation.");
                if (!result.Items.Any(item => item.Status == "failed"))
                    throw new IOException("Operation contents changed or purge result could not be persisted. Purge intent remains for safe continuation.", ex);
            }
            return result;
        }
        finally { foreach (var stream in held) stream.Dispose(); }
    }

    private FileStream PublishPurgeJson<T>(string finalPath, string operationId, T value, Action<FileStream> validate, List<FileStream> held)
    {
        var stagingPath = Path.Combine(config.BackupDirectory, $"purge-pending-{operationId}-{Guid.NewGuid():N}.json");
        var handle = NativeFiles.CreateDestination(stagingPath);
        FileStream? stream = null;
        var published = false;
        try
        {
            NativeFiles.Verify(handle, stagingPath);
            NativeFiles.VerifySingleLink(handle);
            NativeFiles.RejectNamedStreams(stagingPath);
            stream = new FileStream(handle, FileAccess.ReadWrite);
            JsonSerializer.Serialize(stream, value, PrunletConfig.JsonOptions);
            stream.Flush(true);
            if (stream.Length > 8 * 1024 * 1024) throw new InvalidDataException("Purge metadata is too large to publish safely.");
            validate(stream);
            // 書込み途中の記録は操作フォルダーへ置かず、同じハンドルの rename で完成形だけを公開する。
            NativeFiles.RenameHandle(handle, finalPath);
            published = true;
            NativeFiles.Verify(handle, finalPath);
            NativeFiles.VerifySingleLink(handle);
            NativeFiles.RejectNamedStreams(finalPath);
            stream.Flush(true);
            held.Add(stream);
            return stream;
        }
        catch (Exception original)
        {
            if (!published)
            {
                try { NativeFiles.DeleteHandle(handle); }
                catch (Exception cleanup) when (IsOperational(cleanup))
                { throw new IOException($"{original.Message} Unpublished purge record remains at {stagingPath}: {cleanup.Message}", original); }
            }
            throw;
        }
        finally
        {
            if (stream is null) handle.Dispose();
            else if (!held.Contains(stream)) stream.Dispose();
        }
    }

    private static FileStream HoldPurgeMetadata(string path, List<FileStream> held)
    {
        var handle = NativeFiles.OpenBackup(path);
        try
        {
            NativeFiles.Verify(handle, path);
            NativeFiles.VerifySingleLink(handle);
            NativeFiles.RejectNamedStreams(path);
            var stream = new FileStream(handle, FileAccess.Read);
            held.Add(stream);
            if (stream.Length > 8 * 1024 * 1024) throw new InvalidDataException("Operation metadata is too large.");
            return stream;
        }
        catch { handle.Dispose(); throw; }
    }

    private static string HashStream(FileStream stream)
    {
        stream.Position = 0;
        var hash = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        stream.Position = 0;
        return hash;
    }

    private static T ReadValidatedJson<T>(FileStream stream)
    {
        stream.Position = 0;
        using var document = JsonDocument.Parse(stream);
        ValidateUniqueJsonProperties(document.RootElement);
        string[] required = typeof(T) == typeof(OperationManifest) ? ["schema", "operationId", "createdUtc", "items"]
            : typeof(T) == typeof(PurgeIntent) ? ["schema", "operationId", "manifestSha256", "createdUtc", "targets"]
            : typeof(T) == typeof(DeleteResult) ? ["operationId", "dryRun", "items", "warnings"]
            : typeof(T) == typeof(RestoreResult) ? ["operationId", "items", "warnings"]
            : ["operationId", "dryRun", "purgedBytes", "items", "warnings"];
        RequireJsonProperties(document.RootElement, required);
        if (typeof(T) == typeof(OperationManifest))
        {
            RequireJsonArrayItems(document.RootElement, "items", ["path", "state"]);
            if (document.RootElement.GetProperty("schema").ValueKind == JsonValueKind.Number
                && document.RootElement.GetProperty("schema").TryGetInt32(out var schema))
            {
                if (schema == 2) RequireJsonArrayItems(document.RootElement, "items", ["path", "state", "kind", "treeRoot"]);
                if (schema == 3)
                {
                    RequireJsonArrayItems(document.RootElement, "items", ["path", "state", "kind", "treeRoot", "caseSensitive", "reparseTag", "linkDirectory", "streams", "size", "sha256"]);
                    foreach (var entry in document.RootElement.GetProperty("items").EnumerateArray())
                        if (entry.GetProperty("streams").ValueKind != JsonValueKind.Null)
                            RequireJsonArrayItems(entry, "streams", ["name", "offset", "size", "sha256"]);
                }
            }
        }
        if (typeof(T) == typeof(PurgeIntent))
            RequireJsonArrayItems(document.RootElement, "targets", ["index", "sha256", "size"]);
        try { return document.RootElement.Deserialize<T>(PrunletConfig.JsonOptions) ?? throw new InvalidDataException("Operation metadata is empty."); }
        catch (JsonException ex) { throw new InvalidDataException("Operation metadata JSON is invalid.", ex); }
    }

    private static void RequireJsonProperties(JsonElement value, string[] required)
    {
        if (value.ValueKind != JsonValueKind.Object || required.Any(name => !value.TryGetProperty(name, out _)))
            throw new InvalidDataException("Operation metadata is missing required fields.");
    }

    private static void RequireJsonArrayItems(JsonElement value, string name, string[] required)
    {
        var items = value.GetProperty(name);
        if (items.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Operation metadata items must be an array.");
        foreach (var item in items.EnumerateArray()) RequireJsonProperties(item, required);
    }

    private static void ValidateUniqueJsonProperties(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in value.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new InvalidDataException("Operation metadata has duplicated properties.");
                ValidateUniqueJsonProperties(property.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
            foreach (var element in value.EnumerateArray()) ValidateUniqueJsonProperties(element);
    }

    private static void ValidatePurgeIntent(PurgeIntent intent, PurgeIntent expected)
    {
        if (intent.Schema != 1 || intent.OperationId != expected.OperationId || intent.ManifestSha256 != expected.ManifestSha256
            || intent.CreatedUtc == default || intent.Targets is null || intent.Targets.Count != expected.Targets.Count)
            throw new InvalidDataException("Purge intent does not match this operation manifest.");
        for (var i = 0; i < expected.Targets.Count; i++)
        {
            var target = intent.Targets[i];
            var known = expected.Targets[i];
            if (target is null || target.Index != known.Index || target.Size != known.Size
                || !string.Equals(target.Sha256, known.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Purge intent target index/hash/size is invalid.");
        }
    }

    private static string? PurgeMetadataKind(string name)
    {
        if (name == "delete-result.json") return "delete";
        foreach (var kind in new[] { "restore", "purge" })
        {
            var prefix = kind + "-result-";
            if (!name.StartsWith(prefix, StringComparison.Ordinal) || !name.EndsWith(".json", StringComparison.Ordinal)) continue;
            var id = name[prefix.Length..^5];
            if (Guid.TryParseExact(id, "N", out var parsed) && parsed.ToString("N") == id) return kind;
        }
        return null;
    }

    private static void VerifyPurgeMembers(string directory, HashSet<string?> expected)
    {
        var entries = Directory.EnumerateFileSystemEntries(directory).Select(Path.GetFileName).ToArray();
        if (entries.Length != expected.Count || !expected.SetEquals(entries))
            throw new InvalidDataException("Operation membership changed; purge stopped without touching unknown members.");
    }

    private static void ValidatePurgeOutcome(FileStream stream, string kind, OperationManifest manifest, string directory, PurgeIntent? intent)
    {
        List<FileOperationResult> items;
        List<string> warnings;
        string? operationId;
        string[] statuses;
        if (kind == "delete")
        {
            var result = ReadValidatedJson<DeleteResult>(stream);
            if (result.DryRun) throw new InvalidDataException("Persisted deletion result cannot be a dry run.");
            operationId = result.OperationId; items = result.Items; warnings = result.Warnings;
            statuses = ["deleted", "backup_ready", "already_absent", "failed"];
        }
        else if (kind == "restore")
        {
            var result = ReadValidatedJson<RestoreResult>(stream);
            operationId = result.OperationId; items = result.Items; warnings = result.Warnings;
            statuses = ["restored", "already_present", "conflict", "not_backed_up", "failed"];
        }
        else
        {
            var result = ReadValidatedJson<PurgeResult>(stream);
            if (intent is null || result.DryRun || result.PurgedBytes < 0)
                throw new InvalidDataException("Purge result requires persisted matching intent and apply mode.");
            operationId = result.OperationId; items = result.Items; warnings = result.Warnings;
            statuses = ["purged", "already_purged", "would_purge", "not_backed_up", "failed"];
        }
        if (operationId != manifest.OperationId || items is null || items.Count != manifest.Items.Count
            || warnings is null || warnings.Any(warning => warning is null))
            throw new InvalidDataException("Operation outcome record is invalid.");
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            var entry = manifest.Items[index];
            if (item is null || item.Path != entry.Path || item.Kind != entry.Kind || !statuses.Contains(item.Status, StringComparer.Ordinal)
                || (item.Status == "already_present" && entry.Kind != "directory")
                || (item.BackupPath is not null && ResolveRecordedBackupPath(item.BackupPath) != BackupPath(directory, index))
                || (item.Sha256 is not null && !item.Sha256.Equals(entry.Sha256, StringComparison.OrdinalIgnoreCase))
                || (item.Size is not null && item.Size != entry.Size))
                throw new InvalidDataException("Operation outcome item is invalid.");
        }
    }

    private static string ResolveRecordedBackupPath(string path)
    {
        if (PathPolicy.Absolute(path) != path) throw new InvalidDataException("Recorded recovery path is not canonical.");
        var parent = PathPolicy.Resolve(Path.GetDirectoryName(path)!, finalDirectory: true, allowMissing: false);
        return Path.Combine(parent, Path.GetFileName(path));
    }
}
