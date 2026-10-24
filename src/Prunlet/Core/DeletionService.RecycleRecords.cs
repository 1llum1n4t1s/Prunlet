using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private const string RecycleManifestName = "recycle-manifest.json";
    private const int MaximumRecyclePidlCharacters = 1398104;

    private bool IsRecycleOperation(string operationId)
    {
        ValidateMoveOperationId(operationId);
        var directory = Path.Combine(config.BackupDirectory, operationId);
        using var pin = PathPolicy.PinRecoveryDirectories(directory);
        return Directory.EnumerateFileSystemEntries(directory).Any(path => Path.GetFileName(path) == RecycleManifestName);
    }

    private static T ReadRecycleJson<T>(FileStream stream)
    {
        if (stream.Length is <= 0 or > 128L * 1024 * 1024) throw new InvalidDataException("Recycle metadata size is invalid.");
        stream.Position = 0;
        try
        {
            using var actual = JsonDocument.Parse(stream, new JsonDocumentOptions { MaxDepth = 16 });
            ValidateRecycleJsonValue(actual.RootElement);
            var value = actual.RootElement.Deserialize<T>(MoveJsonOptions) ?? throw new InvalidDataException("Recycle metadata is empty.");
            using var canonical = JsonDocument.Parse(JsonSerializer.SerializeToUtf8Bytes(value, MoveJsonOptions));
            RequireRegistryFields(actual.RootElement, canonical.RootElement);
            return value;
        }
        catch (JsonException ex) { throw new InvalidDataException("Recycle metadata JSON is invalid.", ex); }
    }

    private static void ValidateRecycleJsonValue(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in value.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new InvalidDataException("Recycle metadata contains duplicate properties.");
                ValidateRecycleJsonValue(property.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
        {
            if (value.GetArrayLength() > 256) throw new InvalidDataException("Recycle metadata contains too many entries.");
            foreach (var child in value.EnumerateArray()) ValidateRecycleJsonValue(child);
        }
        else if (value.ValueKind == JsonValueKind.String && value.GetString()!.Length > MaximumRecyclePidlCharacters)
            throw new InvalidDataException("Recycle metadata contains an oversized value.");
    }

    private void PublishRecycleJson<T>(string finalPath, string operationId, T value)
    {
        // 最終名への非上書きrenameより先に本文をflushする。失敗時のpendingは保全する。
        var pending = Path.Combine(config.BackupDirectory, $"recycle-pending-{operationId}-{Guid.NewGuid():N}.json");
        using var handle = NativeFiles.CreatePrivateRegistryFile(pending);
        NativeFiles.Verify(handle, pending);
        using var stream = new FileStream(handle, FileAccess.ReadWrite);
        JsonSerializer.Serialize(stream, value, MoveJsonOptions);
        stream.Flush(true);
        _ = ReadRecycleJson<T>(stream);
        NativeFiles.RenameHandle(handle, finalPath);
        NativeFiles.Verify(handle, finalPath);
        stream.Flush(true);
    }

    private RecycleRecordLease OpenRecycleRecord(string operationId)
    {
        ValidateMoveOperationId(operationId);
        var directory = Path.Combine(config.BackupDirectory, operationId);
        var pin = PathPolicy.PinRecoveryDirectories(directory);
        SafeFileHandle? operationLock = null;
        RecycleRecordLease? operation = null;
        try
        {
            NativeFiles.RejectNamedStreams(directory);
            var lockPath = Path.Combine(directory, "operation.lock");
            operationLock = NativeFiles.OpenLock(lockPath);
            NativeFiles.Verify(operationLock, lockPath);
            NativeFiles.VerifySingleLink(operationLock);
            NativeFiles.RejectNamedStreams(lockPath);
            if (RandomAccess.GetLength(operationLock) != 0) throw new InvalidDataException("Operation lock is not empty.");
            operation = new RecycleRecordLease(directory, pin, operationLock);
            var stream = HoldPurgeMetadata(Path.Combine(directory, RecycleManifestName), operation.Held);
            operation.Manifest = ReadRecycleJson<RecycleManifest>(stream);
            ValidateRecycleManifest(operation.Manifest, operationId);
            operation.Hash = HashStream(stream);
            foreach (var member in Directory.EnumerateFileSystemEntries(directory))
            {
                var name = Path.GetFileName(member);
                if (name is RecycleManifestName or "operation.lock") continue;
                if (TryReadRecycleStage(operation, member, name)) continue;
                if (name == "delete-result.json" || Regex.IsMatch(name, "^restore-result-[0-9a-f]{32}\\.json$", RegexOptions.CultureInvariant))
                {
                    _ = HoldPurgeMetadata(member, operation.Held);
                    continue;
                }
                var match = Regex.Match(name, "^(recycle|restore)-([0-9]{4})-(intent|complete)\\.json$", RegexOptions.CultureInvariant);
                if (!match.Success || !int.TryParse(match.Groups[2].Value, out var index)
                    || index >= operation.Manifest.Entries.Count
                    || (match.Groups[1].Value == "recycle" && match.Groups[3].Value != "complete"))
                    throw new InvalidDataException($"Unknown recycle operation member was retained: {name}");
                var receiptStream = HoldPurgeMetadata(member, operation.Held);
                var receipt = ReadRecycleJson<RecycleReceipt>(receiptStream);
                ValidateRecycleReceipt(operation, operation.Manifest.Entries[index], receipt, match.Groups[1].Value, match.Groups[3].Value);
                operation.Receipts.Add(name, receipt);
                operation.Hashes.Add(name, HashStream(receiptStream));
            }
            foreach (var entry in operation.Manifest.Entries)
            {
                var recycled = RecycleReceiptFor(operation, entry, "recycle", "complete");
                var intent = RecycleReceiptFor(operation, entry, "restore", "intent");
                var complete = RecycleReceiptFor(operation, entry, "restore", "complete");
                if ((intent is not null || complete is not null) && recycled is null || complete is not null && intent is null)
                    throw new InvalidDataException("Recycle action receipts are incomplete; remaining objects were retained.");
                foreach (var receipt in new[] { intent, complete }.OfType<RecycleReceipt>())
                    if (receipt.RecycleSha256 != operation.Hashes[RecycleReceiptName(entry, "recycle", "complete")]
                        || receipt.Pidl != recycled!.Pidl || receipt.PhysicalPath != recycled.PhysicalPath || receipt.Identity != recycled.Identity)
                        throw new InvalidDataException("Restore receipt does not match the immutable recycle receipt.");
            }
            ValidateRecycleStages(operation);
            return operation;
        }
        catch
        {
            if (operation is not null) operation.Dispose();
            else { operationLock?.Dispose(); pin.Dispose(); }
            throw;
        }
    }

    private void ValidateRecycleManifest(RecycleManifest manifest, string operationId)
    {
        if (manifest.Schema != 6 || manifest.OperationId != operationId || manifest.CreatedUtc == default
            || manifest.MetadataRoot != config.BackupDirectory || manifest.MachineName != Environment.MachineName
            || manifest.OwnerSid != VolumeRecoveryStore.OwnerSid || manifest.Entries is null || manifest.Entries.Count is 0 or > 256)
            throw new InvalidDataException("Recycle manifest binding, schema or entries are invalid.");
        for (var index = 0; index < manifest.Entries.Count; index++)
        {
            var entry = manifest.Entries[index];
            if (entry is null || entry.Index != index || PathPolicy.Absolute(entry.Path) != entry.Path)
                throw new InvalidDataException("Recycle entry path or index is invalid.");
            CheckRecycleTarget(entry.Path, entry.Identity?.IsDirectory == true);
            for (var previous = 0; previous < index; previous++)
                if (ExactWithin(entry.Path, manifest.Entries[previous].Path) || ExactWithin(manifest.Entries[previous].Path, entry.Path))
                    throw new InvalidDataException("Recycle manifest contains overlapping targets.");
            if (entry.State == "already_absent")
            {
                if (entry.Identity is not null || entry.OriginalParent is not null || entry.Kind != "file" || entry.Security is not null)
                    throw new InvalidDataException("Absent recycle entry contains identity bindings.");
                continue;
            }
            if (entry.State != "recycle_intent" || !ValidMoveIdentity(entry.Identity) || !ValidMoveIdentity(entry.OriginalParent)
                || entry.OriginalParent is not { IsDirectory: true, ReparseTag: 0 }
                || entry.Identity!.VolumeSerialNumber != entry.OriginalParent.VolumeSerialNumber || entry.Kind != MoveKind(entry.Identity))
                throw new InvalidDataException("Recycle entry identity or parent binding is invalid.");
            if (entry.Security is not null) ValidateRecycleSecurity(entry.Security, entry.Identity!);
        }
    }

    private static void ValidateRecycleReceipt(RecycleRecordLease operation, RecycleEntry entry, RecycleReceipt receipt, string action, string phase)
    {
        if (receipt.Schema != 6 || receipt.OperationId != operation.Manifest.OperationId || receipt.Index != entry.Index
            || receipt.CreatedUtc == default || receipt.Action != action || receipt.Phase != phase
            || receipt.ManifestSha256 != operation.Hash || entry.State != "recycle_intent"
            || !ValidMoveIdentity(receipt.Identity) || !SameMoveObject(entry.Identity!, receipt.Identity!)
            || PathPolicy.Absolute(receipt.PhysicalPath) != receipt.PhysicalPath || receipt.PhysicalPath == entry.Path
            || receipt.Pidl.Length is 0 or > MaximumRecyclePidlCharacters
            || action == "recycle" && receipt.RecycleSha256.Length != 0
            || action == "restore" && !Regex.IsMatch(receipt.RecycleSha256, "^[0-9A-Fa-f]{64}$", RegexOptions.CultureInvariant))
            throw new InvalidDataException("Recycle receipt does not match the manifest, identity or action.");
        try
        {
            var bytes = Convert.FromBase64String(receipt.Pidl);
            if (bytes.Length < 2 || Convert.ToBase64String(bytes) != receipt.Pidl)
                throw new InvalidDataException("Recycle PIDL encoding is invalid.");
        }
        catch (FormatException ex) { throw new InvalidDataException("Recycle PIDL encoding is invalid.", ex); }
        if (receipt.Security is not null)
        {
            if (action != "recycle" || phase != "complete" || entry.Security is null)
                throw new InvalidDataException("Unexpected recycle ACL receipt.");
            ValidateRecycleSecurity(receipt.Security, entry.Identity!);
            RequireRecycleSecurityBindings(entry.Security, receipt.Security);
        }
        if (entry.Security is not null && action == "recycle" && receipt.Security is null)
            throw new InvalidDataException("Recycle completion has no bound ACL snapshot.");
    }

    private static string RecycleReceiptName(RecycleEntry entry, string action, string phase) => $"{action}-{entry.Index:D4}-{phase}.json";
    private static RecycleReceipt? RecycleReceiptFor(RecycleRecordLease operation, RecycleEntry entry, string action, string phase) =>
        operation.Receipts.GetValueOrDefault(RecycleReceiptName(entry, action, phase));

    private void WriteRecycleReceipt(string directory, RecycleManifest manifest, string hash, RecycleEntry entry,
        string action, string phase, BinItem bin, MoveEntryIdentity identity, string recycleHash = "",
        Dictionary<string, RecycleSecurityNode>? security = null)
    {
        var receipt = new RecycleReceipt
        {
            OperationId = manifest.OperationId, Index = entry.Index, ManifestSha256 = hash, RecycleSha256 = recycleHash,
            Action = action, Phase = phase, Pidl = bin.Pidl, PhysicalPath = bin.PhysicalPath, Identity = identity, Security = security
        };
        PublishRecycleJson(Path.Combine(directory, RecycleReceiptName(entry, action, phase)), manifest.OperationId, receipt);
    }

    private sealed class RecycleRecordLease(string directory, DirectoryLease pin, SafeFileHandle operationLock) : IDisposable
    {
        internal string Directory { get; } = directory;
        internal RecycleManifest Manifest { get; set; } = null!;
        internal string Hash { get; set; } = string.Empty;
        internal List<FileStream> Held { get; } = [];
        internal Dictionary<string, RecycleReceipt> Receipts { get; } = new(StringComparer.Ordinal);
        internal Dictionary<string, string> Hashes { get; } = new(StringComparer.Ordinal);
        internal Dictionary<string, RecycleStageReceipt> Stages { get; } = new(StringComparer.Ordinal);
        public void Dispose() { foreach (var stream in Held) stream.Dispose(); operationLock.Dispose(); pin.Dispose(); }
    }
}
