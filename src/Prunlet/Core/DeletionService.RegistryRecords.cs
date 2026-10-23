using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private const string RegistryManifestName = "registry-manifest.json";
    private const string RegistrySnapshotName = "registry-snapshot.json";
    private static readonly JsonSerializerOptions RegistryJsonOptions = new(PrunletConfig.JsonOptions)
        { PropertyNameCaseInsensitive = false, NumberHandling = JsonNumberHandling.Strict };

    private bool IsRegistryOperation(string operationId)
    {
        ValidateMoveOperationId(operationId);
        var directory = Path.Combine(config.BackupDirectory, operationId);
        using var pin = PathPolicy.PinRecoveryDirectories(directory);
        return Directory.EnumerateFileSystemEntries(directory).Any(path => Path.GetFileName(path) == RegistryManifestName);
    }

    private static string RegistryReceiptName(string action, string phase) => $"registry-{action}-{phase}.json";

    private RegistryRecordLease OpenRegistryRecord(string operationId)
    {
        ValidateMoveOperationId(operationId);
        var directory = Path.Combine(config.BackupDirectory, operationId);
        var pin = PathPolicy.PinRecoveryDirectories(directory);
        SafeFileHandle? operationLock = null;
        RegistryRecordLease? record = null;
        try
        {
            NativeFiles.RejectNamedStreams(directory);
            using (var directoryHandle = NativeFiles.OpenPrivateRegistryDirectory(directory))
            {
                NativeFiles.Verify(directoryHandle, directory, directory: true);
                NativeFiles.VerifyPrivateRegistrySecurity(directoryHandle, directory: true);
            }
            var lockPath = Path.Combine(directory, "operation.lock");
            operationLock = NativeFiles.OpenLock(lockPath);
            NativeFiles.Verify(operationLock, lockPath);
            NativeFiles.VerifySingleLink(operationLock);
            NativeFiles.RejectNamedStreams(lockPath);
            NativeFiles.VerifyPrivateRegistrySecurity(operationLock);
            if (RandomAccess.GetLength(operationLock) != 0) throw new InvalidDataException("Registry operation lock is not empty.");
            record = new RegistryRecordLease(directory, pin, operationLock);
            var manifest = HoldRegistryFile(Path.Combine(directory, RegistryManifestName), record.Held);
            record.Manifest = ReadRegistryJson<RegistryManifest>(manifest);
            record.ManifestHash = HashStream(manifest);
            ValidateRegistryManifest(record.Manifest, operationId);
            var names = Directory.EnumerateFileSystemEntries(directory).Select(Path.GetFileName).OfType<string>().ToHashSet(StringComparer.Ordinal);
            foreach (var name in names)
            {
                if (name is RegistryManifestName or RegistrySnapshotName or "operation.lock") continue;
                var match = System.Text.RegularExpressions.Regex.Match(name, @"^registry-(delete|restore|purge)-(intent|complete)\.json$", System.Text.RegularExpressions.RegexOptions.CultureInvariant);
                if (!match.Success) throw new InvalidDataException($"Unknown registry recovery member was retained: {name}");
                var receipt = ReadRegistryJson<RegistryReceipt>(HoldRegistryFile(Path.Combine(directory, name), record.Held));
                if (receipt.Schema != 5 || receipt.OperationId != operationId || receipt.ManifestSha256 != record.ManifestHash
                    || receipt.Action != match.Groups[1].Value || receipt.Phase != match.Groups[2].Value || receipt.CreatedUtc == default)
                    throw new InvalidDataException("Registry receipt does not match its manifest or filename.");
                record.Receipts.Add(name);
            }
            foreach (var action in new[] { "delete", "restore", "purge" })
                if (record.Has(action, "complete") && !record.Has(action, "intent"))
                    throw new InvalidDataException("Registry completion has no persisted intent.");
            if ((record.Has("restore", "intent") || record.Has("purge", "intent")) && !record.Has("delete", "complete"))
                throw new InvalidDataException("Registry recovery action has no confirmed deletion.");
            if (record.Has("restore", "intent") && record.Has("purge", "intent"))
                throw new InvalidDataException("Registry restore and purge receipts conflict.");
            record.PayloadPresent = names.Contains(RegistrySnapshotName);
            if (!record.PayloadPresent && !record.Has("restore", "complete") && !record.Has("purge", "intent"))
                throw new InvalidDataException("Registry recovery snapshot is missing without a confirmed consume action.");
            if (record.PayloadPresent)
            {
                // purge用も書込み/削除共有なしで同じ実体を検証し、後で削除可能handleへ明示的に切替える。
                var payload = HoldRegistryFile(Path.Combine(directory, RegistrySnapshotName), record.Held);
                if (payload.Length != record.Manifest.Size || HashStream(payload) != record.Manifest.Sha256)
                    throw new InvalidDataException("Registry snapshot hash or size differs from its manifest.");
                record.Snapshot = ReadRegistryJson<RegistrySnapshot>(payload);
                ValidateRegistrySnapshot(record.Manifest, record.Snapshot);
                record.PayloadStream = payload;
            }
            if (record.Has("purge", "complete") && record.PayloadPresent)
                throw new InvalidDataException("Completed registry purge still has a snapshot; both were retained.");
            return record;
        }
        catch
        {
            if (record is not null) record.Dispose();
            else { operationLock?.Dispose(); pin.Dispose(); }
            throw;
        }
    }

    private void ValidateRegistryManifest(RegistryManifest manifest, string operationId)
    {
        RegistryScopeIdentity.Validate(manifest.Scope);
        var target = NativeRegistry.Target(new RegistryDeleteRequest { Path = manifest.Path, View = manifest.View, ValueName = manifest.ValueName });
        if (manifest.Schema != 5 || manifest.OperationId != operationId || manifest.CreatedUtc == default
            || manifest.MetadataRoot != config.BackupDirectory || manifest.OwnerSid != NativeRegistry.CurrentSid
            || target.Path != manifest.Path || target.Kind != manifest.Kind || manifest.Size is <= 0 or > NativeRegistry.MaximumSnapshotBytes
            || manifest.Sha256 is null || manifest.Sha256.Length != 64 || manifest.Sha256.Any(character => !char.IsAsciiHexDigitLower(character)))
            throw new InvalidDataException("Registry manifest identity, target, owner, size, or digest is invalid.");
    }

    private static void ValidateRegistrySnapshot(RegistryManifest manifest, RegistrySnapshot snapshot)
    {
        RegistryScopeIdentity.Validate(snapshot.Scope);
        if (manifest.Scope != snapshot.Scope) throw new InvalidDataException("Registry snapshot scope does not match its manifest.");
        if (snapshot.Schema != 5 || snapshot.Path != manifest.Path || snapshot.View != manifest.View || snapshot.ValueName != manifest.ValueName
            || snapshot.Keys is null || snapshot.Keys.Count > NativeRegistry.MaximumKeys)
            throw new InvalidDataException("Registry snapshot does not match its manifest.");
        if (manifest.ValueName is not null)
        {
            if (snapshot.Keys.Count != 0 || snapshot.Value is null || snapshot.Value.Name != manifest.ValueName || snapshot.ContextSecurity is null)
                throw new InvalidDataException("Registry value snapshot shape is invalid.");
            NativeRegistry.ValidateSecurity(snapshot.ContextSecurity);
            ValidateValue(snapshot.Value);
            return;
        }
        if (snapshot.Keys.Count == 0 || snapshot.Keys[0] is null || snapshot.Keys[0].RelativePath != ""
            || snapshot.Value is not null || snapshot.ContextSecurity is not null)
            throw new InvalidDataException("Registry key snapshot shape is invalid.");
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var count = 0;
        foreach (var node in snapshot.Keys)
        {
            if (node is null || node.RelativePath is null || node.Class is null || node.Security is null || node.Values is null)
                throw new InvalidDataException("Registry snapshot contains null key metadata.");
            NativeRegistry.ValidateText(node.RelativePath, 32760, "Registry relative path", allowEmpty: true);
            NativeRegistry.ValidateText(node.Class, 32767, "Registry class", allowEmpty: true);
            if (node.RelativePath.Length != 0)
            {
                var segments = node.RelativePath.Split('\\');
                if (segments.Length > NativeRegistry.MaximumDepth || segments.Any(segment => segment.Length is 0 or > 255 || segment is "." or ".."))
                    throw new InvalidDataException("Registry snapshot contains an invalid relative path.");
                var slash = node.RelativePath.LastIndexOf('\\');
                if (!paths.Contains(slash < 0 ? "" : node.RelativePath[..slash]))
                    throw new InvalidDataException("Registry snapshot child has no preceding parent.");
            }
            if (!paths.Add(node.RelativePath)) throw new InvalidDataException("Registry snapshot contains duplicate keys.");
            NativeRegistry.ValidateSecurity(node.Security);
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var value in node.Values)
            {
                ValidateValue(value);
                if (!names.Add(value.Name) || ++count > NativeRegistry.MaximumValues)
                    throw new InvalidDataException("Registry snapshot contains duplicate or excessive values.");
                if (value.Name.Equals("SymbolicLinkValue", StringComparison.OrdinalIgnoreCase) && value.Type == 6)
                    throw new InvalidDataException("Registry snapshot contains a registry link.");
            }
        }
        static void ValidateValue(RegistryValueSnapshot value)
        {
            if (value is null || value.Data is null || value.Data.LongLength > NativeRegistry.MaximumSnapshotBytes / 2)
                throw new InvalidDataException("Registry snapshot value is null or oversized.");
            NativeRegistry.ValidateText(value.Name, 16383, "Registry value name", allowEmpty: true);
        }
    }

    private static T ReadRegistryJson<T>(FileStream stream)
    {
        if (stream.Length is <= 0 or > NativeRegistry.MaximumSnapshotBytes) throw new InvalidDataException("Registry metadata size is invalid.");
        stream.Position = 0;
        try
        {
            using var document = JsonDocument.Parse(stream, new JsonDocumentOptions { MaxDepth = 16 });
            ValidateRegistryJsonValue(document.RootElement);
            var value = document.RootElement.Deserialize<T>(RegistryJsonOptions) ?? throw new InvalidDataException("Registry metadata is empty.");
            // Jsonの既定値補完を許さず、全fieldを出力する正規形とproperty集合を照合する。
            using var canonical = JsonDocument.Parse(JsonSerializer.SerializeToUtf8Bytes(value, RegistryJsonOptions));
            RequireRegistryFields(document.RootElement, canonical.RootElement);
            return value;
        }
        catch (JsonException ex) { throw new InvalidDataException("Registry metadata JSON is invalid.", ex); }
    }

    private static void ValidateRegistryJsonValue(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in value.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new InvalidDataException("Registry metadata contains duplicate properties.");
                ValidateRegistryJsonValue(property.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
        {
            if (value.GetArrayLength() > NativeRegistry.MaximumValues) throw new InvalidDataException("Registry metadata has too many entries.");
            foreach (var child in value.EnumerateArray()) ValidateRegistryJsonValue(child);
        }
    }

    private static void RequireRegistryFields(JsonElement actual, JsonElement canonical)
    {
        if (canonical.ValueKind == JsonValueKind.Object)
        {
            if (actual.ValueKind != JsonValueKind.Object || actual.EnumerateObject().Count() != canonical.EnumerateObject().Count())
                throw new InvalidDataException("Registry metadata is missing required fields.");
            foreach (var property in canonical.EnumerateObject())
            {
                if (!actual.TryGetProperty(property.Name, out var found)) throw new InvalidDataException("Registry metadata is missing a required field.");
                RequireRegistryFields(found, property.Value);
            }
        }
        else if (canonical.ValueKind == JsonValueKind.Array)
        {
            if (actual.ValueKind != JsonValueKind.Array || actual.GetArrayLength() != canonical.GetArrayLength())
                throw new InvalidDataException("Registry metadata array is invalid.");
            var index = 0;
            foreach (var child in canonical.EnumerateArray()) RequireRegistryFields(actual[index++], child);
        }
        else if (actual.ValueKind != canonical.ValueKind)
            throw new InvalidDataException("Registry metadata scalar type is invalid.");
    }

    private FileStream PublishRegistryJson<T>(string finalPath, string operationId, T value, List<FileStream> held)
    {
        var pending = Path.Combine(config.BackupDirectory, $"registry-pending-{operationId}-{Guid.NewGuid():N}.json");
        var handle = NativeFiles.CreatePrivateRegistryFile(pending);
        FileStream? stream = null;
        try
        {
            NativeFiles.Verify(handle, pending); NativeFiles.VerifySingleLink(handle); NativeFiles.RejectNamedStreams(pending);
            stream = new FileStream(handle, FileAccess.ReadWrite);
            JsonSerializer.Serialize(stream, value, RegistryJsonOptions);
            stream.Flush(true);
            _ = ReadRegistryJson<T>(stream);
            NativeFiles.RenameHandle(handle, finalPath);
            NativeFiles.Verify(handle, finalPath);
            NativeFiles.VerifyPrivateRegistrySecurity(handle);
            stream.Flush(true);
            held.Add(stream);
            return stream;
        }
        catch
        {
            // 今回作成した未公開fileだけ同じhandleで除去する。公開後の記録は失敗時も保持する。
            try
            {
                if (NativeFiles.FinalPath(handle) == pending) NativeFiles.DeleteOriginalHandle(handle);
            }
            catch (Exception cleanup) when (IsOperational(cleanup)) { }
            if (stream is null) handle.Dispose(); else stream.Dispose();
            throw;
        }
    }

    private static FileStream HoldRegistryFile(string path, List<FileStream> held)
    {
        var stream = HoldPurgeMetadata(path, held);
        NativeFiles.VerifyPrivateRegistrySecurity(stream.SafeFileHandle);
        return stream;
    }

    private void WriteRegistryReceipt(string directory, RegistryManifest manifest, string hash, string action, string phase, List<FileStream> held)
    {
        PublishRegistryJson(Path.Combine(directory, RegistryReceiptName(action, phase)), manifest.OperationId,
            new RegistryReceipt { OperationId = manifest.OperationId, ManifestSha256 = hash, Action = action, Phase = phase }, held);
    }

    private sealed class RegistryRecordLease(string directory, DirectoryLease pin, SafeFileHandle operationLock) : IDisposable
    {
        internal string Directory { get; } = directory;
        internal List<FileStream> Held { get; } = [];
        internal RegistryManifest Manifest { get; set; } = null!;
        internal string ManifestHash { get; set; } = "";
        internal RegistrySnapshot? Snapshot { get; set; }
        internal FileStream? PayloadStream { get; set; }
        internal bool PayloadPresent { get; set; }
        internal HashSet<string> Receipts { get; } = new(StringComparer.Ordinal);
        internal bool Has(string action, string phase) => Receipts.Contains(RegistryReceiptName(action, phase));
        internal bool Ambiguous => !Has("delete", "complete") || (Has("restore", "intent") && !Has("restore", "complete"));
        public void Dispose()
        {
            foreach (var stream in Held) stream.Dispose();
            operationLock.Dispose(); pin.Dispose();
        }
    }
}
