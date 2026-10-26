using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed class RecoveryOperationSummary
{
    public string OperationId { get; set; } = "";
    public string LifecycleState { get; set; } = "active";
    public int? OriginalSchema { get; set; }
    public string? TerminalReason { get; set; }
}

public sealed partial class DeletionService
{
    internal const string RecycleRecordsDirectory = ".recycle-records-v1";
    internal const string ClosedRecordsDirectory = ".closed-records-v1";
    internal const string RegistryRecordsDirectory = ".registry-records-v1";



    private sealed class RecordLayout
    {
        public int Schema { get; set; } = 1;
        public string Kind { get; set; } = "";
        public string OperationId { get; set; } = "";
        public string DirectoryIdentity { get; set; } = "";
        public string MetadataRootIdentity { get; set; } = "";
        public string MachineName { get; set; } = "";
        public string OwnerSid { get; set; } = "";
        public string Nonce { get; set; } = "";
        [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingDefault)]
        public int PublicationProtocol { get; set; }
    }

    private sealed class RootCreationIntent
    {
        public int Schema { get; set; } = 1;
        public string RootKind { get; set; } = "";
        public string StageName { get; set; } = "";
        public string Nonce { get; set; } = "";
        public string MetadataRootIdentity { get; set; } = "";
        public string MachineName { get; set; } = "";
        public string OwnerSid { get; set; } = "";
    }

    private string ValidatedRecordRoot(string kind) => EnsureRecordRoot(config.BackupDirectory, kind, create: false);

    // 大きい本文の読取りとは分離する。名前だけでのschema判定や0バイト扱いはしない。
    private static string EnsureRecordRoot(string backupDirectory, string name, bool create)
    {
        if (name is not (RecycleRecordsDirectory or ClosedRecordsDirectory or RegistryRecordsDirectory)) throw new ArgumentException("Unknown lifecycle root kind.");
        var root = Path.Combine(backupDirectory, name);
        using var ancestors = PathPolicy.PinRecoveryDirectories(backupDirectory);
        using var metadata = NativeFiles.OpenDirectory(backupDirectory);
        NativeFiles.Verify(metadata, backupDirectory, directory: true);
        var metadataIdentity = NativeFiles.Identity(metadata);
        if (create)
        {
            // 呼出し元は必ずcoordination lockを先に取る。初回shared delete同士だけを追加で直列化する。
            using var creation = new RecordCreationMutex(metadataIdentity);
            ProvisionRecordRoot(backupDirectory, name, metadataIdentity);
        }
        else if (InspectMoveLocation(root) is null) throw new DirectoryNotFoundException(root);
        _ = ValidateRootLayout(root, name, metadataIdentity);
        return root;
    }

    private sealed class RecordCreationMutex : IDisposable
    {
        private readonly Mutex mutex;
        internal RecordCreationMutex(string metadataIdentity)
        {
            var key = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(metadataIdentity + "\n" + VolumeRecoveryStore.OwnerSid)));
            mutex = new Mutex(false, @"Global\Prunlet.RecordCreation." + key);
            try
            {
                try
                {
                    if (!mutex.WaitOne(TimeSpan.FromSeconds(30))) throw new IOException("Lifecycle root creation is busy; no new stage was created.");
                }
                catch (AbandonedMutexException) { /* 所有権を取得済み。durable intentから照合する。 */ }
            }
            catch { mutex.Dispose(); throw; }
        }
        public void Dispose() { mutex.ReleaseMutex(); mutex.Dispose(); }
    }

    private static RecordLayout ValidateRootLayout(string root, string name, string metadataIdentity, string? nonce = null)
    {
        using var directory = NativeFiles.OpenPrivateRegistryDirectory(root);
        NativeFiles.Verify(directory, root, directory: true);
        NativeFiles.RejectCaseSensitive(directory);
        NativeFiles.RejectNamedStreams(root);
        NativeFiles.VerifyPrivateRegistrySecurity(directory, directory: true);
        var marker = ReadLifecycleJson<RecordLayout>(Path.Combine(root, "layout.json"));
        if (marker.Schema != 1 || marker.Kind != name || marker.OperationId != ""

            || marker.DirectoryIdentity != NativeFiles.Identity(directory) || marker.MetadataRootIdentity != metadataIdentity
            || marker.MachineName != Environment.MachineName || marker.OwnerSid != VolumeRecoveryStore.OwnerSid
            || marker.PublicationProtocol != (name == RecycleRecordsDirectory ? 1 : 0)
            || !Guid.TryParseExact(marker.Nonce, "N", out var parsed) || parsed.ToString("N") != marker.Nonce
            || nonce is not null && marker.Nonce != nonce)
            throw new InvalidDataException("Recovery record layout marker does not match its private directory.");
        return marker;
    }

    private static void ValidateCreationIntent(RootCreationIntent intent, string name, string metadataIdentity)
    {
        if (intent.Schema != 1 || intent.RootKind != name || intent.MetadataRootIdentity != metadataIdentity
            || intent.MachineName != Environment.MachineName || intent.OwnerSid != VolumeRecoveryStore.OwnerSid
            || !Guid.TryParseExact(intent.Nonce, "N", out var id) || id.ToString("N") != intent.Nonce
            || intent.StageName != name + ".stage-" + intent.Nonce)
            throw new InvalidDataException("Lifecycle root creation intent has an invalid owner or binding.");
    }

    private static void ProvisionRecordRoot(string backupDirectory, string name, string metadataIdentity)
    {
        var root = Path.Combine(backupDirectory, name);
        var intentPath = Path.Combine(backupDirectory, name + ".create.json");
        RootCreationIntent? intent = null;
        if (InspectMoveLocation(intentPath) is not null)
        {
            intent = ReadLifecycleJson<RootCreationIntent>(intentPath);
            ValidateCreationIntent(intent, name, metadataIdentity);
        }
        if (InspectMoveLocation(root) is not null)
        {
            _ = ValidateRootLayout(root, name, metadataIdentity, intent?.Nonce);
            if (intent is not null)
            {
                if (InspectMoveLocation(Path.Combine(backupDirectory, intent.StageName)) is not null)
                    throw new InvalidDataException("Published and staged lifecycle roots both exist; both were retained.");
                DeleteLifecycleRecord(intentPath);
            }
            return;
        }
        if (intent is null)
        {
            // 初回intent公開より前のpartialは所有根拠がない。同じ失敗で新stageを増殖させない。
            if (Directory.EnumerateFileSystemEntries(backupDirectory).Any(path =>
                Path.GetFileName(path).StartsWith(name + ".create.json.pending-", StringComparison.Ordinal)
                || Path.GetFileName(path).StartsWith(name + ".stage-", StringComparison.Ordinal)))
                throw new InvalidDataException("Unpublished lifecycle root creation evidence was retained; reconcile it before creating another stage.");
            var nonce = Guid.NewGuid().ToString("N");
            intent = new RootCreationIntent { RootKind = name, StageName = name + ".stage-" + nonce, Nonce = nonce,
                MetadataRootIdentity = metadataIdentity, MachineName = Environment.MachineName, OwnerSid = VolumeRecoveryStore.OwnerSid };
            WriteLifecycleJson(intentPath, intent);
            // 作成intentのflush・最終名公開・再読より先にstageを作らない。
            var persisted = ReadLifecycleJson<RootCreationIntent>(intentPath);
            ValidateCreationIntent(persisted, name, metadataIdentity);
            if (persisted.Nonce != nonce) throw new InvalidDataException("Lifecycle root creation intent changed.");
        }
        var stage = Path.Combine(backupDirectory, intent.StageName);
        if (InspectMoveLocation(stage) is not null)
        {
            string stageIdentity;
            bool complete;
            using (var directory = NativeFiles.OpenPrivateRegistryDirectory(stage))
            {
                NativeFiles.Verify(directory, stage, directory: true);
                NativeFiles.VerifyPrivateRegistrySecurity(directory, directory: true);
                NativeFiles.RejectNamedStreams(stage);
                NativeFiles.RejectCaseSensitive(directory);
                stageIdentity = NativeFiles.Identity(directory);
                var members = Directory.EnumerateFileSystemEntries(stage).Select(Path.GetFileName).OfType<string>().ToArray();
                if (members.Any(member => member != "layout.json" && !Regex.IsMatch(member, @"^layout\.json\.pending-[0-9a-f]{32}$", RegexOptions.CultureInvariant)))
                    throw new InvalidDataException("Unknown lifecycle root stage contents were retained.");
                complete = members.Contains("layout.json", StringComparer.Ordinal);
                if (complete) _ = ValidateRootLayout(stage, name, metadataIdentity, intent.Nonce);
                foreach (var pending in members.Where(member => member != "layout.json"))
                    DeleteUnpublishedControlFile(Path.Combine(stage, pending), marker =>
                    {
                        if (marker.Schema != 1 || marker.Kind != name || marker.OperationId != "" || marker.DirectoryIdentity != stageIdentity
                            || marker.MetadataRootIdentity != metadataIdentity || marker.MachineName != intent.MachineName
                            || marker.OwnerSid != intent.OwnerSid || marker.Nonce != intent.Nonce || marker.PublicationProtocol != (name == RecycleRecordsDirectory ? 1 : 0))
                            throw new InvalidDataException("Unpublished root layout contradicts its reservation; it was retained.");
                    });
            }
            if (!complete)
            {
                // 有効intentの正確な予約stageが空の場合だけ、同一handleによる非再帰回収を許す。
                using var empty = NativeFiles.OpenLifecycleDirectoryMove(stage);
                NativeFiles.Verify(empty, stage, directory: true);
                NativeFiles.VerifyPrivateRegistrySecurity(empty, directory: true);
                NativeFiles.RejectNamedStreams(stage);
                if (NativeFiles.Identity(empty) != stageIdentity || Directory.EnumerateFileSystemEntries(stage).Any())
                    throw new InvalidDataException("Reserved empty root stage changed; it was retained.");
                NativeFiles.SetOriginalDeletePending(empty, true);
            }
        }
        if (InspectMoveLocation(stage) is null)
        {
            using var directory = NativeFiles.CreatePrivateRegistryDirectory(stage);
                WriteLifecycleJson(Path.Combine(stage, "layout.json"), new RecordLayout { Kind = name, DirectoryIdentity = NativeFiles.Identity(directory),
                    MetadataRootIdentity = metadataIdentity, MachineName = intent.MachineName, OwnerSid = intent.OwnerSid, Nonce = intent.Nonce,
                    PublicationProtocol = name == RecycleRecordsDirectory ? 1 : 0 });
        }
        _ = ValidateRootLayout(stage, name, metadataIdentity, intent.Nonce);
        using (var moving = NativeFiles.OpenLifecycleDirectoryMove(stage))
        {
            NativeFiles.Verify(moving, stage, directory: true);
            NativeFiles.VerifyPrivateRegistrySecurity(moving, directory: true);
            var layout = ReadLifecycleJson<RecordLayout>(Path.Combine(stage, "layout.json"));
            if (layout.DirectoryIdentity != NativeFiles.Identity(moving)) throw new InvalidDataException("Lifecycle stage identity changed before publication.");
            NativeFiles.RenameHandle(moving, root);
            NativeFiles.Verify(moving, root, directory: true);
        }
        _ = ValidateRootLayout(root, name, metadataIdentity, intent.Nonce);
        DeleteLifecycleRecord(intentPath);
    }

    private static void DeleteUnpublishedControlFile(string path, Action<RecordLayout> validateComplete)
    {
        // 呼出し元が検証済みcontrol root、またはdurable creation-intentの予約stageを固定済み。
        // snapshot・manifest・payload・hiveへこの経路を一般化しない。
        string identity;
        string digest;
        using (var inspecting = NativeFiles.OpenLifecycleMetadata(path))
        {
            NativeFiles.Verify(inspecting, path);
            NativeFiles.VerifySingleLink(inspecting);
            NativeFiles.VerifyPrivateRegistrySecurity(inspecting);
            NativeFiles.RejectNamedStreams(path);
            using var bytes = new FileStream(inspecting, FileAccess.Read);
            if (bytes.Length > 16L * 1024 * 1024) throw new InvalidDataException("Oversized unpublished control metadata was retained.");
            var complete = bytes.Length > 0;
            if (complete)
                try { using var document = JsonDocument.Parse(bytes); }
                catch (JsonException) { complete = false; }
            if (complete) validateComplete(ReadLifecycleJson<RecordLayout>(path));
            identity = NativeFiles.Identity(inspecting);
            digest = HashStream(bytes);
        }
        using var handle = NativeFiles.OpenLifecycleDelete(path);
        NativeFiles.Verify(handle, path);
        NativeFiles.VerifySingleLink(handle);
        NativeFiles.VerifyPrivateRegistrySecurity(handle);
        NativeFiles.RejectNamedStreams(path);
        using var current = new FileStream(handle, FileAccess.Read);
        if (NativeFiles.Identity(handle) != identity || HashStream(current) != digest)
            throw new InvalidDataException("Unpublished control metadata identity or bytes changed.");
        NativeFiles.SetOriginalDeletePending(handle, true);
    }

    private static void WriteLifecycleJson<T>(string path, T value)
    {
        var pending = path + ".pending-" + Guid.NewGuid().ToString("N");
        using var handle = NativeFiles.CreatePrivateRegistryFile(pending);
        using var stream = new FileStream(handle, FileAccess.ReadWrite);
        JsonSerializer.Serialize(stream, value, MoveJsonOptions);
        stream.Flush(true);
        NativeFiles.RenameHandle(handle, path);
        NativeFiles.Verify(handle, path);
        stream.Flush(true);
    }

    private static T ReadLifecycleJson<T>(string path)
    {
        using var handle = NativeFiles.OpenLifecycleMetadata(path);
        NativeFiles.Verify(handle, path);
        NativeFiles.VerifySingleLink(handle);
        NativeFiles.RejectNamedStreams(path);
        NativeFiles.VerifyPrivateRegistrySecurity(handle);
        using var stream = new FileStream(handle, FileAccess.Read);
        return ReadLifecycleJson<T>(stream);
    }

    private static T ReadLifecycleJson<T>(FileStream stream)
    {
        stream.Position = 0;
        if (stream.Length <= 0 || stream.Length > (typeof(T) == typeof(RecordLayout) ? 8192 : 16 * 1024 * 1024)) throw new InvalidDataException("Lifecycle metadata size is invalid.");
        try
        {
            using var actual = JsonDocument.Parse(stream, new JsonDocumentOptions { MaxDepth = 16 });
            ValidateLifecycleJsonValue(actual.RootElement);
            var value = actual.RootElement.Deserialize<T>(MoveJsonOptions) ?? throw new InvalidDataException("Lifecycle metadata is empty.");
            using var canonical = JsonDocument.Parse(JsonSerializer.SerializeToUtf8Bytes(value, MoveJsonOptions));
            RequireRegistryFields(actual.RootElement, canonical.RootElement);
            return value;
        }
        catch (JsonException ex) { throw new InvalidDataException("Lifecycle metadata JSON is invalid.", ex); }
    }

    private static void ValidateLifecycleJsonValue(JsonElement value)
    {
        // 省略可能fieldも明示nullは許さない。nullを既定値へ補正して正本扱いしない。
        if (value.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
            throw new InvalidDataException("Lifecycle metadata contains a null value.");
        if (value.ValueKind == JsonValueKind.Object)
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in value.EnumerateObject())
            {
                if (!seen.Add(property.Name)) throw new InvalidDataException("Duplicate lifecycle property.");
                ValidateLifecycleJsonValue(property.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
        {
            if (value.GetArrayLength() > 8192) throw new InvalidDataException("Lifecycle inventory is too large.");
            foreach (var item in value.EnumerateArray()) ValidateLifecycleJsonValue(item);
        }
        else if (value.ValueKind == JsonValueKind.String && value.GetString()!.Length > 32767)
            throw new InvalidDataException("Lifecycle value is too large.");
    }

    private static void DeleteLifecycleRecord(string path)
    {
        using var handle = NativeFiles.OpenLifecycleDelete(path);
        NativeFiles.Verify(handle, path);
        NativeFiles.VerifySingleLink(handle);
        NativeFiles.VerifyPrivateRegistrySecurity(handle);
        NativeFiles.RejectNamedStreams(path);
        NativeFiles.SetOriginalDeletePending(handle, true);
    }

    private static string HashLifecycleRecord(string path)
    {
        using var handle = NativeFiles.OpenLifecycleMetadata(path);
        NativeFiles.Verify(handle, path);
        NativeFiles.VerifyPrivateRegistrySecurity(handle);
        NativeFiles.RejectNamedStreams(path);
        using var stream = new FileStream(handle, FileAccess.Read);
        return HashStream(stream);
    }

}
