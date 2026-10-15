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
                ValidatePurgeIntent(intent, expectedIntent, manifest);
            }
            var backupNames = manifest.Items.Select((entry, index) => (entry, index))
                .Where(pair => HasRecoveryCopy(manifest, pair.entry))
                .ToDictionary(pair => $"{pair.index:D4}.bak", pair => pair.index, StringComparer.Ordinal);
            var incomplete = intent?.IncompleteTargets?.ToDictionary(target => target.Index)
                ?? new Dictionary<int, PurgeTarget>();
            if (intent is null)
            {
                // 旧版がコピー途中で失敗した正規名だけを対象にし、未知のファイルは受け入れない。
                for (var index = 0; index < manifest.Items.Count; index++)
                    if (CanHaveIncompleteBackup(manifest, manifest.Items[index]) && members.Contains($"{index:D4}.bak"))
                        incomplete.Add(index, new PurgeTarget { Index = index });
            }
            foreach (var index in incomplete.Keys) backupNames.Add($"{index:D4}.bak", index);
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
                var verifiedCopy = HasRecoveryCopy(manifest, entry);
                if (!verifiedCopy && !incomplete.ContainsKey(index)) continue;
                var target = verifiedCopy
                    ? new PurgeTarget { Index = index, Size = entry.Size!.Value, Sha256 = entry.Sha256! }
                    : incomplete[index];
                item.BackupPath = BackupPath(directory, index);
                item.Size = target.Size;
                item.Sha256 = target.Sha256;
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
                var size = stream.Length;
                var hash = HashStream(stream);
                if (!verifiedCopy && intent is null)
                {
                    // 復元可能とは扱わず、このハンドルで照合した途中コピーの内容を整理intentへ保存する。
                    target.Size = size;
                    target.Sha256 = hash;
                    item.Size = size;
                    item.Sha256 = hash;
                }
                if (size != target.Size || !hash.Equals(target.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException($"Recovery copy size/hash differs from {(verifiedCopy ? "manifest" : "purge intent")}: {name}");
                if (verifiedCopy && manifest.Schema == 3) VerifySpecialBackupContents(stream, entry);
                backups.Add(index, stream);
                item.Status = "would_purge";
            }
            if (incomplete.Count != 0)
            {
                expectedIntent.Schema = 2;
                expectedIntent.IncompleteTargets = incomplete.Values.OrderBy(target => target.Index).ToList();
                result.Warnings.Add($"Includes {incomplete.Count} incomplete backup(s). These copies are not restorable; original targets are not modified.");
            }
            VerifyPurgeMembers(directory, members);
            if (!apply) return result;
            if (intent is null)
            {
                // 全検査が完了するまで意図を書かず、永続化に失敗したら削除を始めない。
                var publishedIntent = PublishPurgeJson(intentPath, operationId, expectedIntent,
                    stream => ValidatePurgeIntent(ReadValidatedJson<PurgeIntent>(stream), expectedIntent, manifest, compareIncomplete: true), held);
                intent = ReadValidatedJson<PurgeIntent>(publishedIntent);
                ValidatePurgeIntent(intent, expectedIntent, manifest, compareIncomplete: true);
                members.Add("purge-intent.json");
            }
            VerifyPurgeMembers(directory, members);
            foreach (var (index, stream) in backups)
            {
                try
                {
                    // 事前検証から保持しているコピーだけを削除する。未知の追加は完了時に検出する。
                    NativeFiles.Verify(stream.SafeFileHandle, result.Items[index].BackupPath!);
                    NativeFiles.VerifySingleLink(stream.SafeFileHandle);
                    NativeFiles.RejectNamedStreams(result.Items[index].BackupPath!);
                    NativeFiles.DeleteHandle(stream.SafeFileHandle);
                    stream.Dispose();
                    members.Remove($"{index:D4}.bak");
                    result.Items[index].Status = "purged";
                    result.PurgedBytes = checked(result.PurgedBytes + result.Items[index].Size!.Value);
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

    private static bool CanHaveIncompleteBackup(OperationManifest manifest, ManifestEntry entry) =>
        entry.State is "failed" or "already_absent" && (manifest.Schema == 3 || entry.Kind == "file");

    private static void ValidatePurgeIntent(PurgeIntent intent, PurgeIntent expected, OperationManifest manifest, bool compareIncomplete = false)
    {
        if (intent.Schema is not (1 or 2) || intent.OperationId != expected.OperationId || intent.ManifestSha256 != expected.ManifestSha256
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
        if ((intent.Schema == 1 && intent.IncompleteTargets is not null)
            || (intent.Schema == 2 && intent.IncompleteTargets is not { Count: > 0 }))
            throw new InvalidDataException("Incomplete purge targets require intent schema 2.");
        var previous = -1;
        foreach (var target in intent.IncompleteTargets ?? [])
        {
            if (target is null || target.Index <= previous || target.Index >= manifest.Items.Count
                || !CanHaveIncompleteBackup(manifest, manifest.Items[target.Index])
                || target.Size < 0 || target.Sha256 is null || target.Sha256.Length != 64 || !target.Sha256.All(char.IsAsciiHexDigit))
                throw new InvalidDataException("Incomplete purge target index/hash/size is invalid.");
            previous = target.Index;
        }
        if (compareIncomplete)
        {
            if (intent.Schema != expected.Schema || (intent.IncompleteTargets?.Count ?? 0) != (expected.IncompleteTargets?.Count ?? 0))
                throw new InvalidDataException("Incomplete purge targets changed before publication.");
            for (var i = 0; i < (expected.IncompleteTargets?.Count ?? 0); i++)
            {
                var target = intent.IncompleteTargets![i];
                var known = expected.IncompleteTargets![i];
                if (target.Index != known.Index || target.Size != known.Size
                    || !target.Sha256.Equals(known.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Incomplete purge target contents changed before publication.");
            }
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
        var incomplete = kind == "purge" ? intent?.IncompleteTargets?.ToDictionary(target => target.Index) : null;
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            var entry = manifest.Items[index];
            var partial = incomplete?.GetValueOrDefault(index);
            var expectedHash = partial?.Sha256 ?? entry.Sha256;
            var expectedSize = partial?.Size ?? entry.Size;
            if (item is null || item.Path != entry.Path || item.Kind != entry.Kind || !statuses.Contains(item.Status, StringComparer.Ordinal)
                || (item.Status == "already_present" && entry.Kind != "directory")
                || (item.BackupPath is not null && ResolveRecordedBackupPath(item.BackupPath) != BackupPath(directory, index))
                || (item.Sha256 is not null && !item.Sha256.Equals(expectedHash, StringComparison.OrdinalIgnoreCase))
                || (item.Size is not null && item.Size != expectedSize))
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
