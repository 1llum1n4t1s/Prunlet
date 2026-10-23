namespace Prunlet.Core;

public sealed partial class DeletionService
{
    public HistoryCompactionResult CompactHistory(bool apply = false)
    {
        using var coordination = AcquireRecoveryCoordination(create: apply);
        return CompactHistoryCore(apply);
    }

    private HistoryCompactionResult CompactHistoryCore(bool apply, bool automatic = false, IEnumerable<string>? operationIds = null)
    {
        var result = new HistoryCompactionResult { DryRun = !apply };
        // ルートの未公開記録や未知名は対象にせず、操作単位でJSONとハンドルを解放する。
        var paths = operationIds is null ? Directory.EnumerateFileSystemEntries(config.BackupDirectory)
            : operationIds.Distinct(StringComparer.Ordinal).Select(id => Path.Combine(config.BackupDirectory, id));
        foreach (var path in paths)
        {
            var id = Path.GetFileName(path);
            if (!Guid.TryParseExact(id, "N", out var parsed) || parsed.ToString("N") != id)
            {
                if (id != "maintenance.lock") result.Warnings.Add($"Unknown recovery member was retained: {id}");
                continue;
            }
            var operation = new HistoryCompactionOperation { OperationId = id };
            result.Operations.Add(operation);
            CompactHistoryOperation(path, id, apply, operation, result.Warnings, automatic);
        }
        return result;
    }

    private void CompactHistoryOperation(string directory, string id, bool apply, HistoryCompactionOperation result, List<string> warnings, bool automatic)
    {
        var held = new Dictionary<string, FileStream>(StringComparer.Ordinal);
        var started = false;
        try
        {
            using var directories = PathPolicy.PinRecoveryDirectories(directory);
            var lockPath = Path.Combine(directory, "operation.lock");
            using var operationLock = NativeFiles.OpenLock(lockPath);
            NativeFiles.Verify(operationLock, lockPath);
            NativeFiles.VerifySingleLink(operationLock);
            NativeFiles.RejectNamedStreams(lockPath);
            if (RandomAccess.GetLength(operationLock) != 0) throw new InvalidDataException("Operation lock is not empty.");
            var members = Directory.EnumerateFileSystemEntries(directory).Select(Path.GetFileName).ToHashSet(StringComparer.Ordinal);
            if (members.Contains(MoveManifestName))
                throw new InvalidDataException("Schema 4 move history is retained; physical compression requires dedicated completion validation.");
            if (!members.Contains("manifest.json") || !members.Contains("purge-intent.json"))
                throw new InvalidDataException("Only completed, purged history with a persisted intent is eligible.");
            foreach (var name in members)
            {
                if (name == "operation.lock") continue;
                if (name is not ("manifest.json" or "purge-intent.json") && PurgeMetadataKind(name!) is null)
                    throw new InvalidDataException($"Recovery payload or unknown operation member was retained: {name}");
                var path = Path.Combine(directory, name!);
                var handle = apply ? NativeFiles.OpenHistoryCompression(path) : NativeFiles.OpenBackup(path);
                try
                {
                    VerifyHistoryFile(handle, path);
                    // FSCTL後のhash検証でも古い読込バッファを再利用しない。
                    held.Add(name!, new FileStream(handle, apply ? FileAccess.ReadWrite : FileAccess.Read, bufferSize: 1));
                }
                catch { handle.Dispose(); throw; }
            }
            if (automatic && held.Values.All(stream => NativeFiles.HistoryCompressionInfo(stream.SafeFileHandle).Format == 2))
            {
                // 内容の妥当性を認定せず、既圧縮のため変更不要として本文の再読を省く。
                VerifyPurgeMembers(directory, members);
                result.Status = "skipped_compressed";
                return;
            }
            ValidateHistoryMetadata(held, id, directory);
            foreach (var (name, stream) in held)
            {
                var info = NativeFiles.HistoryCompressionInfo(stream.SafeFileHandle);
                result.Files.Add(new HistoryCompactionFile
                {
                    Name = name, LogicalBytes = stream.Length, Sha256 = HashStream(stream), PhysicalBytesBefore = info.PhysicalBytes,
                    Status = info.Format == 0 ? "would_compress" : "already_compressed"
                });
            }
            VerifyPurgeMembers(directory, members);
            foreach (var item in result.Files)
            {
                var stream = held[item.Name];
                try
                {
                    VerifyPurgeMembers(directory, members);
                    VerifyHistoryFile(stream.SafeFileHandle, Path.Combine(directory, item.Name));
                    if (stream.Length != item.LogicalBytes || HashStream(stream) != item.Sha256)
                        throw new IOException("History metadata changed after validation.");
                    if (!apply) continue;
                    started = true;
                    if (item.Status != "already_compressed") NativeFiles.CompressHistory(stream.SafeFileHandle);
                    stream.Flush(flushToDisk: true);
                    VerifyHistoryFile(stream.SafeFileHandle, Path.Combine(directory, item.Name));
                    var after = NativeFiles.HistoryCompressionInfo(stream.SafeFileHandle);
                    item.PhysicalBytesAfter = after.PhysicalBytes;
                    if (after.Format != 2 || stream.Length != item.LogicalBytes || HashStream(stream) != item.Sha256)
                        throw new IOException("Compressed history format, length, or SHA-256 verification failed.");
                    if (item.Status != "already_compressed") item.Status = "compressed";
                }
                catch (Exception ex) when (IsOperational(ex))
                {
                    item.Status = "failed"; item.Error = ex.Message;
                    throw;
                }
            }
            ValidateHistoryMetadata(held, id, directory);
            VerifyPurgeMembers(directory, members);
            result.Status = apply ? "compacted" : "eligible";
        }
        catch (Exception ex) when (IsOperational(ex))
        {
            // 事前検証で不確定な操作は触らない。適用開始後の失敗は終了コードにも反映する。
            result.Status = started || result.Files.Any(file => file.Status == "failed") ? "failed" : "skipped";
            if (result.Status == "failed") result.Error = ex.Message;
            warnings.Add($"History operation {id} {result.Status}: {ex.Message}");
        }
        finally { foreach (var stream in held.Values) stream.Dispose(); }
    }

    private static void VerifyHistoryFile(Microsoft.Win32.SafeHandles.SafeFileHandle handle, string path)
    {
        NativeFiles.Verify(handle, path);
        NativeFiles.VerifySingleLink(handle);
        NativeFiles.RejectNamedStreams(path);
        if (NativeFiles.NamedStreams(handle).Count != 0) throw new IOException("History metadata has named streams.");
        _ = NativeFiles.HistoryCompressionInfo(handle);
    }

    private void ValidateHistoryMetadata(Dictionary<string, FileStream> held, string id, string directory)
    {
        var manifestStream = held["manifest.json"];
        var manifest = ReadValidatedJson<OperationManifest>(manifestStream);
        ValidateManifest(manifest, id);
        var intent = ReadValidatedJson<PurgeIntent>(held["purge-intent.json"]);
        var expected = new PurgeIntent
        {
            OperationId = id, ManifestSha256 = HashStream(manifestStream),
            Targets = manifest.Items.Select((entry, index) => (entry, index))
                .Where(pair => HasRecoveryCopy(manifest, pair.entry))
                .Select(pair => new PurgeTarget { Index = pair.index, Sha256 = pair.entry.Sha256!, Size = pair.entry.Size!.Value }).ToList()
        };
        ValidatePurgeIntent(intent, expected, manifest);
        var completed = false;
        foreach (var (name, stream) in held)
        {
            var kind = PurgeMetadataKind(name);
            if (kind is null) continue;
            var items = ValidatePurgeOutcome(stream, kind, manifest, directory, intent);
            if (kind == "purge")
            {
                completed |= items.All(item => (item.Status is "purged" or "already_purged" or "not_backed_up")
                    && string.IsNullOrEmpty(item.Error));
            }
        }
        if (!completed) throw new InvalidDataException("A successful persisted purge outcome is required for history compression.");
    }
}
