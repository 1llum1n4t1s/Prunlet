using System.Collections.Frozen;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private const string MoveManifestName = "move-manifest.json";
    private static readonly JsonSerializerOptions MoveJsonOptions = new(PrunletConfig.JsonOptions)
        { PropertyNameCaseInsensitive = false };

    private bool IsMoveOperation(string operationId)
    {
        ValidateMoveOperationId(operationId);
        var directory = Path.Combine(config.BackupDirectory, operationId);
        using var pin = PathPolicy.PinRecoveryDirectories(directory);
        return Directory.EnumerateFileSystemEntries(directory).Any(path => Path.GetFileName(path) == MoveManifestName);
    }

    private static void ValidateMoveOperationId(string id)
    {
        if (!Guid.TryParseExact(id, "N", out var guid) || guid.ToString("N") != id)
            throw new ArgumentException("Operation ID must be a lowercase 32-character GUID.");
    }

    private MoveRecordLease OpenMoveRecord(string operationId)
    {
        ValidateMoveOperationId(operationId);
        var directory = Path.Combine(config.BackupDirectory, operationId);
        var pin = PathPolicy.PinRecoveryDirectories(directory);
        SafeFileHandle? operationLock = null;
        MoveRecordLease? operation = null;
        try
        {
            NativeFiles.RejectNamedStreams(directory);
            var lockPath = Path.Combine(directory, "operation.lock");
            operationLock = NativeFiles.OpenLock(lockPath);
            NativeFiles.Verify(operationLock, lockPath);
            NativeFiles.VerifySingleLink(operationLock);
            NativeFiles.RejectNamedStreams(lockPath);
            if (RandomAccess.GetLength(operationLock) != 0) throw new InvalidDataException("Operation lock is not empty.");
            operation = new MoveRecordLease(directory, pin, operationLock);
            var manifest = HoldPurgeMetadata(Path.Combine(directory, MoveManifestName), operation.Held);
            operation.Streams.Add(MoveManifestName, manifest);
            var parsed = ReadMoveJson<MoveManifest>(manifest);
            ValidateMoveManifest(parsed, operationId);
            operation.InitializeManifest(parsed, HashStream(manifest));
            foreach (var member in Directory.EnumerateFileSystemEntries(directory))
            {
                var name = Path.GetFileName(member);
                if (name is MoveManifestName or "operation.lock") continue;
                if (PurgeMetadataKind(name) is not null)
                {
                    using var metadata = NativeFiles.OpenBackup(member);
                    NativeFiles.Verify(metadata, member);
                    NativeFiles.VerifySingleLink(metadata);
                    NativeFiles.RejectNamedStreams(member);
                    continue;
                }
                var match = Regex.Match(name, @"^(move|restore|purge)-([0-9]{4})-(intent|complete|cancelled)\.json$", RegexOptions.CultureInvariant);
                if (!match.Success || !ValidMoveReceiptAction(match.Groups[1].Value, match.Groups[3].Value)
                    || !int.TryParse(match.Groups[2].Value, out var index) || index >= operation.Manifest.Entries.Count)
                    throw new InvalidDataException($"Unknown move operation member was retained: {name}");
                _ = ReadMoveReceipt(operation, operation.Manifest.Entries[index], match.Groups[1].Value, match.Groups[3].Value);
            }
            foreach (var entry in operation.Manifest.Entries)
            {
                ValidateMoveReceiptCombination(entry, operation.Streams.Keys);
                foreach (var action in new[] { "restore", "purge" })
                    if (operation.Streams.ContainsKey(ReceiptName(entry, action, "complete"))
                        && !operation.Streams.ContainsKey(ReceiptName(entry, action, "intent")))
                        throw new InvalidDataException("Completed move action has no matching persisted intent.");
                _ = IsCancelledMoveEntry(operation, entry);
            }
            return operation;
        }
        catch
        {
            if (operation is not null) operation.Dispose();
            else { operationLock?.Dispose(); pin.Dispose(); }
            throw;
        }
    }

    private void ValidateMoveManifest(MoveManifest manifest, string operationId)
    {
        if (manifest.Schema != 4 || manifest.OperationId != operationId || manifest.CreatedUtc == default
            || manifest.MetadataRoot != config.BackupDirectory || manifest.OwnerSid != VolumeRecoveryStore.OwnerSid
            || manifest.StoreKey != VolumeRecoveryStore.StoreKey(config.BackupDirectory)
            || manifest.Entries is null || manifest.Entries.Count is 0 or > 256)
            throw new InvalidDataException("Move manifest binding, schema or entries are invalid.");
        for (var index = 0; index < manifest.Entries.Count; index++)
        {
            var entry = manifest.Entries[index];
            if (entry is null || entry.Index != index || PathPolicy.Absolute(entry.Path) != entry.Path
                || entry.Path.Length == 3 || PathPolicy.Within(entry.Path, config.BackupDirectory)
                || (entry.Identity?.IsDirectory == true && PathPolicy.Within(config.BackupDirectory, entry.Path)))
                throw new InvalidDataException("Move manifest path or index is invalid.");
            for (var previous = 0; previous < index; previous++)
                if (ExactWithin(entry.Path, manifest.Entries[previous].Path) || ExactWithin(manifest.Entries[previous].Path, entry.Path))
                    throw new InvalidDataException("Move manifest contains overlapping targets.");
            if (entry.State == "already_absent")
            {
                if (entry.Identity is not null || entry.OriginalParent is not null || entry.StoreIdentity is not null
                    || entry.PayloadParent is not null || entry.StoreRoot.Length != 0 || entry.PayloadName.Length != 0
                    || entry.VolumeName.Length != 0 || entry.Size is not (null or 0))
                    throw new InvalidDataException("Absent move entry contains storage bindings.");
                continue;
            }
            if (entry.State != "move_intent" || entry.Size is null or < 0
                || !ValidMoveIdentity(entry.Identity) || !ValidMoveIdentity(entry.OriginalParent)
                || !ValidMoveIdentity(entry.StoreIdentity) || !ValidMoveIdentity(entry.PayloadParent)
                || entry.OriginalParent is not { IsDirectory: true, ReparseTag: 0 }
                || entry.StoreIdentity is not { IsDirectory: true, ReparseTag: 0 }
                || entry.PayloadParent is not { IsDirectory: true, ReparseTag: 0 }
                || entry.Identity!.VolumeSerialNumber != entry.StoreIdentity.VolumeSerialNumber
                || entry.Identity.VolumeSerialNumber != entry.PayloadParent.VolumeSerialNumber
                || entry.Identity.VolumeSerialNumber != entry.OriginalParent.VolumeSerialNumber
                || entry.Kind != MoveKind(entry.Identity) || entry.PayloadName != $"{index:D4}.entry"
                || PathPolicy.Absolute(entry.StoreRoot) != entry.StoreRoot
                || !Regex.IsMatch(entry.VolumeName, @"^\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\$", RegexOptions.CultureInvariant))
                throw new InvalidDataException("Move entry identity, volume or payload binding is invalid.");
        }
    }

    private static bool ValidMoveIdentity(MoveEntryIdentity? identity) => identity is not null
        && Regex.IsMatch(identity.FileId, "^[0-9A-Fa-f]{32}$", RegexOptions.CultureInvariant)
        && identity.FileId.Any(character => character != '0')
        && identity.IsDirectory == ((identity.Attributes & (uint)FileAttributes.Directory) != 0)
        && (identity.ReparseTag == 0) == ((identity.Attributes & (uint)FileAttributes.ReparsePoint) == 0);

    private static bool SameMoveObject(MoveEntryIdentity expected, MoveEntryIdentity actual) =>
        expected.VolumeSerialNumber == actual.VolumeSerialNumber && expected.FileId.Equals(actual.FileId, StringComparison.OrdinalIgnoreCase)
        && expected.IsDirectory == actual.IsDirectory && expected.ReparseTag == actual.ReparseTag;

    private static string MoveKind(MoveEntryIdentity identity) => identity.ReparseTag switch
    {
        0 => identity.IsDirectory ? "directory" : "file",
        0xa000000c => "symlink",
        0xa0000003 => "junction",
        _ => throw new IOException("Unsupported reparse point was retained.")
    };

    private static string MovePayloadPath(MoveManifest manifest, MoveEntry entry) =>
        Path.Combine(entry.StoreRoot, manifest.OperationId, entry.PayloadName);

    private void CheckMoveTarget(string path, bool directory)
    {
        if (path != PathPolicy.Absolute(path) || path.Length == 3 || PathPolicy.Within(path, config.BackupDirectory)
            || (directory && PathPolicy.Within(config.BackupDirectory, path)))
            throw new ArgumentException("Target is inside or contains the metadata recovery directory.");
        var protectedRoots = VolumeRecoveryStore.ProtectedRoots(config, path)
            .Concat(config.VolumeRecoveryDirectories.Values.Select(PathPolicy.Absolute));
        foreach (var root in protectedRoots)
            if (PathPolicy.Within(path, root) || (directory && PathPolicy.Within(root, path)))
                throw new ArgumentException("Target is inside or contains a volume recovery directory.");
    }

    private VolumeRecoveryLease OpenRecordedMoveStore(MoveRecordLease operation, MoveEntry entry) =>
        OpenRecordedMoveStore(operation.Manifest, entry, operation.PayloadNamesByStore);

    private VolumeRecoveryLease OpenRecordedMoveStore(MoveManifest manifest, MoveEntry entry,
        FrozenDictionary<string, FrozenSet<string>>? payloadNamesByStore = null)
    {
        CheckMoveTarget(entry.Path, entry.Identity!.IsDirectory);
        if (entry.StoreRoot != VolumeRecoveryStore.ExpectedRoot(config, entry.Path))
            throw new InvalidDataException("Recorded volume recovery path differs from the configured store.");
        var store = VolumeRecoveryStore.Open(config, entry.Path, manifest.OperationId, create: false);
        try
        {
            if (!store.VolumeName.Equals(entry.VolumeName, StringComparison.OrdinalIgnoreCase)
                || !SameMoveObject(entry.StoreIdentity!, store.RootIdentity)
                || !SameMoveObject(entry.PayloadParent!, store.OperationIdentity))
                throw new InvalidDataException("Recorded volume recovery identity changed.");
            FrozenSet<string> allowed;
            if (payloadNamesByStore is null)
                allowed = manifest.Entries.Where(candidate => candidate.State == "move_intent" && candidate.StoreRoot == store.RootPath)
                    .Select(candidate => candidate.PayloadName).ToFrozenSet(StringComparer.Ordinal);
            else if (!payloadNamesByStore.TryGetValue(store.RootPath, out allowed!))
                throw new InvalidDataException("Recorded volume recovery store has no payload bindings.");
            foreach (var member in Directory.EnumerateFileSystemEntries(store.OperationPath))
                if (!allowed.Contains(Path.GetFileName(member))) throw new InvalidDataException("Unknown volume payload was retained.");
            return store;
        }
        catch { store.Dispose(); throw; }
    }

    private static MoveEntryIdentity? InspectMoveLocation(string path)
    {
        try
        {
            using var handle = NativeFiles.OpenMoveMeasurement(path);
            if (NativeFiles.FinalPath(handle) != path) throw new IOException("Move location differs from its canonical path.");
            return NativeFiles.MoveIdentity(handle);
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    private static string ReceiptName(MoveEntry entry, string action, string phase) => $"{action}-{entry.Index:D4}-{phase}.json";

    private static readonly (string Action, string Phase)[] MoveReceiptActions =
        [("move", "complete"), ("move", "cancelled"), ("restore", "intent"), ("restore", "complete"), ("purge", "intent"), ("purge", "complete")];

    private static bool ValidMoveReceiptAction(string action, string phase) =>
        MoveReceiptActions.Contains((action, phase));

    private static void ValidateMoveReceiptCombination(MoveEntry entry, IEnumerable<string> names)
    {
        var receipts = names.ToHashSet(StringComparer.Ordinal);
        if (receipts.Contains(ReceiptName(entry, "move", "cancelled"))
            && MoveReceiptActions.Any(action => action != ("move", "cancelled")
                && receipts.Contains(ReceiptName(entry, action.Action, action.Phase))))
            throw new InvalidDataException("Cancelled move evidence conflicts with move, restore, or purge evidence.");
        if (receipts.Contains(ReceiptName(entry, "restore", "complete"))
            && (receipts.Contains(ReceiptName(entry, "purge", "intent")) || receipts.Contains(ReceiptName(entry, "purge", "complete"))))
            throw new InvalidDataException("Restore and purge completion evidence conflicts.");
    }

    private bool IsCancelledMoveEntry(MoveRecordLease operation, MoveEntry entry)
    {
        if (ReadMoveReceipt(operation, entry, "move", "cancelled") is null) return false;
        foreach (var action in MoveReceiptActions)
            if (action != ("move", "cancelled")) _ = ReadMoveReceipt(operation, entry, action.Action, action.Phase);
        ValidateMoveReceiptCombination(entry, operation.Streams.Keys);
        using var store = OpenRecordedMoveStore(operation, entry);
        if (InspectMoveLocation(MovePayloadPath(operation.Manifest, entry)) is not null)
            throw new InvalidDataException("A cancelled move still has a recovery payload; it was retained.");
        return true;
    }

    // applyの走査だけが呼ぶ。元対象を名前差替え不可で保持し、不在のpayloadを確認してから確定する。
    private bool TryCancelUnmovedMoveEntry(MoveRecordLease operation, MoveEntry entry)
    {
        if (entry.State != "move_intent") return false;
        if (IsCancelledMoveEntry(operation, entry)) return true;
        foreach (var action in MoveReceiptActions)
            if (ReadMoveReceipt(operation, entry, action.Action, action.Phase) is not null) return false;
        using var store = OpenRecordedMoveStore(operation, entry);
        if (InspectMoveLocation(MovePayloadPath(operation.Manifest, entry)) is not null) return false;
        DirectoryLease parents;
        SafeFileHandle original;
        try
        {
            parents = PathPolicy.PinDirectories(Path.GetDirectoryName(entry.Path)!);
            try { original = NativeFiles.OpenAny(entry.Path); }
            catch { parents.Dispose(); throw; }
        }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
        using (parents)
        using (original)
        {
            if (!SameMoveObject(entry.Identity!, NativeFiles.MoveIdentity(original))) return false;
            VerifyMoveHandle(original, entry.Path, entry.Identity!);
            if (InspectMoveLocation(MovePayloadPath(operation.Manifest, entry)) is not null) return false;
            WriteMoveReceipt(operation.Directory, operation.Manifest, operation.ManifestHash, entry, "move", "cancelled");
            return true;
        }
    }

    private MoveReceipt? ReadMoveReceipt(MoveRecordLease operation, MoveEntry entry, string action, string phase)
    {
        if (!ValidMoveReceiptAction(action, phase)) throw new InvalidDataException("Unknown move receipt action or phase.");
        var name = ReceiptName(entry, action, phase);
        if (operation.Receipts.TryGetValue(name, out var cached)) return cached;
        if (!operation.Streams.TryGetValue(name, out var stream))
        {
            try { stream = HoldPurgeMetadata(Path.Combine(operation.Directory, name), operation.Held); }
            catch (FileNotFoundException) { return null; }
            operation.Streams.Add(name, stream);
        }
        var receipt = ReadMoveJson<MoveReceipt>(stream);
        if (receipt.Schema != 4 || receipt.OperationId != operation.Manifest.OperationId || receipt.Index != entry.Index
            || receipt.CreatedUtc == default || receipt.Action != action || receipt.Phase != phase || entry.State != "move_intent"
            || !string.Equals(receipt.ManifestSha256, operation.ManifestHash, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Move receipt does not match the persisted manifest and action.");
        ValidateMoveReceiptAttributes(receipt.Attributes, action, phase);
        // 成功したJSONだけを保持する。共有読取りhandleはlease終了まで書込みと差替えを拒否する。
        operation.Receipts.Add(name, receipt);
        return receipt;
    }

    private static void ValidateMoveReceiptAttributes(uint? attributes, string action, string phase)
    {
        if (attributes is not uint value) return;
        if (action != "restore" || phase != "intent" || (value & ~NativeFiles.RestorableAttributeMask) != 0
            || ((value & (uint)FileAttributes.Normal) != 0 && value != (uint)FileAttributes.Normal))
            throw new InvalidDataException("Move receipt contains invalid attributes or attributes on an unsupported action.");
    }

    private void WriteMoveReceipt(string directory, MoveManifest manifest, string hash, MoveEntry entry, string action, string phase,
        uint? attributes = null)
    {
        if (!ValidMoveReceiptAction(action, phase) || entry.State != "move_intent")
            throw new InvalidDataException("Unknown move receipt action, phase, or entry state.");
        ValidateMoveReceiptAttributes(attributes, action, phase);
        var names = Directory.EnumerateFileSystemEntries(directory).Select(Path.GetFileName).OfType<string>().ToList();
        names.Add(ReceiptName(entry, action, phase));
        ValidateMoveReceiptCombination(entry, names);
        if (action == "move" && phase == "cancelled")
        {
            using var store = OpenRecordedMoveStore(manifest, entry);
            if (InspectMoveLocation(MovePayloadPath(manifest, entry)) is not null)
                throw new InvalidDataException("Cannot cancel a move while its recovery payload exists.");
        }
        var path = Path.Combine(directory, ReceiptName(entry, action, phase));
        if (File.Exists(path))
        {
            var held = new List<FileStream>();
            try
            {
                var receipt = ReadMoveJson<MoveReceipt>(HoldPurgeMetadata(path, held));
                if (receipt.Schema != 4 || receipt.OperationId != manifest.OperationId || receipt.Index != entry.Index
                    || receipt.CreatedUtc == default || receipt.Action != action || receipt.Phase != phase
                    || !string.Equals(receipt.ManifestSha256, hash, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Existing move receipt is invalid.");
                ValidateMoveReceiptAttributes(receipt.Attributes, action, phase);
                if (attributes is not null && receipt.Attributes != attributes)
                    throw new InvalidDataException("Existing move receipt attributes differ from the requested snapshot.");
                return;
            }
            finally { foreach (var stream in held) stream.Dispose(); }
        }
        PublishMoveMetadata(path, manifest.OperationId, new MoveReceipt
        {
            OperationId = manifest.OperationId, Index = entry.Index, ManifestSha256 = hash, Action = action, Phase = phase,
            Attributes = attributes
        });
    }

    private void PublishMoveMetadata<T>(string finalPath, string operationId, T value)
    {
        var pending = Path.Combine(config.BackupDirectory, $"move-pending-{operationId}-{Guid.NewGuid():N}.json");
        using var handle = NativeFiles.CreateDestination(pending);
        NativeFiles.Verify(handle, pending);
        using var stream = new FileStream(handle, FileAccess.ReadWrite);
        JsonSerializer.Serialize(stream, value, MoveJsonOptions);
        stream.Flush(true);
        _ = ReadMoveJson<T>(stream);
        NativeFiles.RenameHandle(handle, finalPath);
        NativeFiles.Verify(handle, finalPath);
        stream.Flush(true);
    }

    private static T ReadMoveJson<T>(FileStream stream)
    {
        // 最大256入力のschema4だけを対象にする。件数無制限の旧schemaの読込みには適用しない。
        if (stream.Length is 0 or > 128L * 1024 * 1024) throw new InvalidDataException("Move metadata size is invalid.");
        stream.Position = 0;
        if (!(stream.ReadByte() == 0xef && stream.ReadByte() == 0xbb && stream.ReadByte() == 0xbf)) stream.Position = 0;
        try
        {
            using var document = JsonDocument.Parse(stream, new JsonDocumentOptions { MaxDepth = 16 });
            ValidateMoveJsonValue(document.RootElement);
            return document.RootElement.Deserialize<T>(MoveJsonOptions) ?? throw new InvalidDataException("Move metadata is empty.");
        }
        catch (JsonException ex) { throw new InvalidDataException("Move metadata JSON is invalid.", ex); }
    }

    private static void ValidateMoveJsonValue(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in value.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new InvalidDataException("Move metadata has duplicate properties.");
                ValidateMoveJsonValue(property.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
        {
            if (value.GetArrayLength() > 256) throw new InvalidDataException("Move metadata contains too many entries.");
            foreach (var child in value.EnumerateArray()) ValidateMoveJsonValue(child);
        }
        else if (value.ValueKind == JsonValueKind.String && value.GetString()!.Length > MetadataPathCharacters)
            throw new InvalidDataException("Move metadata contains an oversized value.");
    }

    private long MeasureMovePayload(string path, List<SafeFileHandle>? held = null)
    {
        var handle = NativeFiles.OpenMoveMeasurement(path);
        if (held is not null) held.Add(handle);
        try
        {
            var identity = NativeFiles.MoveIdentity(handle);
            if (!ValidMoveIdentity(identity)) throw new IOException("The filesystem does not provide a usable persistent file identity.");
            if (NativeFiles.FinalPath(handle) != path) throw new IOException("Recovery payload path changed while measuring.");
            long bytes = NativeFiles.NamedStreamBytes(handle);
            if (identity.ReparseTag != 0) return checked(bytes + NativeFiles.ReadReparse(handle).Length);
            if (!identity.IsDirectory) return checked(bytes + RandomAccess.GetLength(handle));
            foreach (var child in new DirectoryInfo(path).EnumerateFileSystemInfos())
                bytes = checked(bytes + MeasureMovePayload(child.FullName, held));
            return bytes;
        }
        finally { if (held is null) handle.Dispose(); }
    }

    private sealed class MoveRecordLease(string directory, DirectoryLease pin, SafeFileHandle operationLock) : IDisposable
    {
        internal string Directory { get; } = directory;
        internal MoveManifest Manifest { get; private set; } = null!;
        internal string ManifestHash { get; private set; } = string.Empty;
        internal FrozenDictionary<string, FrozenSet<string>> PayloadNamesByStore { get; private set; } = null!;
        internal List<FileStream> Held { get; } = [];
        internal Dictionary<string, FileStream> Streams { get; } = new(StringComparer.Ordinal);
        internal Dictionary<string, MoveReceipt> Receipts { get; } = new(StringComparer.Ordinal);
        internal void InitializeManifest(MoveManifest manifest, string hash)
        {
            Manifest = manifest;
            ManifestHash = hash;
            // 検証済みmanifestの固定値だけを集計し、実体・ACL・markerの検証や毎回の列挙は省かない。
            PayloadNamesByStore = manifest.Entries.Where(entry => entry.State == "move_intent")
                .GroupBy(entry => entry.StoreRoot, StringComparer.Ordinal)
                .ToFrozenDictionary(group => group.Key,
                    group => group.Select(entry => entry.PayloadName).ToFrozenSet(StringComparer.Ordinal), StringComparer.Ordinal);
        }
        public void Dispose() { foreach (var stream in Held) stream.Dispose(); operationLock.Dispose(); pin.Dispose(); }
    }
}
