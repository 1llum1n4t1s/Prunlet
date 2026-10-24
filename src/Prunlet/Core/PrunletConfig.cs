using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;

namespace Prunlet.Core;

public sealed class PrunletConfig
{
    public int Schema { get; set; } = 1;
    // 旧設定との互換性のため保持する。対象パスの制限には使用しない。
    public string[] AllowedRoots { get; set; } = [];
    public string BackupDirectory { get; set; } = string.Empty;
    public int RetentionDays { get; set; } = 7;
    public long MaxRecoveryBytes { get; set; } = 1L * 1024 * 1024 * 1024;
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
    public int CapacityDefaultMigrationVersion { get; set; }
    // 省略時は各ボリュームのユーザー専用領域を使う。検証・管理用の同一ボリューム内配置指定。
    public Dictionary<string, string> VolumeRecoveryDirectories { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public string RegistryScope { get; set; } = "current";
    public string? RegistrySessionFile { get; set; }

    public static PrunletConfig Load(string path)
    {
        var result = JsonSerializer.Deserialize<PrunletConfig>(File.ReadAllText(path), JsonOptions)
            ?? throw new InvalidDataException("Configuration is empty.");
        result.Validate();
        result.BackupDirectory = PathPolicy.Resolve(result.BackupDirectory, finalDirectory: true, allowMissing: false);
        return result;
    }

    public void Validate()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Prunlet supports Windows only.");
        if (Schema != 1) throw new InvalidDataException("Unsupported configuration schema.");
        if (RetentionDays is < 1 or > 36500) throw new InvalidDataException("retentionDays must be between 1 and 36500.");
        if (MaxRecoveryBytes <= 0) throw new InvalidDataException("maxRecoveryBytes must be positive.");
        if (CapacityDefaultMigrationVersion < 0) throw new InvalidDataException("capacityDefaultMigrationVersion cannot be negative.");
        if (VolumeRecoveryDirectories is null) throw new InvalidDataException("volumeRecoveryDirectories cannot be null.");
        if (RegistryScope is not ("current" or "nativeWindows")) throw new InvalidDataException("registryScope must be current or nativeWindows.");
        if (RegistryScope == "nativeWindows" && RegistrySessionFile is null)
            throw new InvalidDataException("nativeWindows requires an absolute registrySessionFile.");
        if (RegistrySessionFile is not null && PathPolicy.Absolute(RegistrySessionFile) != RegistrySessionFile)
            throw new InvalidDataException("registrySessionFile must be a canonical absolute path.");
        var volumes = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in VolumeRecoveryDirectories)
        {
            var volume = PathPolicy.Absolute(pair.Key);
            if (volume.Length != 3 || !volumes.Add(volume)) throw new InvalidDataException("Volume recovery keys must be distinct drive roots.");
            _ = PathPolicy.Absolute(pair.Value);
        }
        var backup = PathPolicy.Absolute(BackupDirectory);
        PathPolicy.ExistingDirectory(backup);
    }

    internal static readonly JsonSerializerOptions JsonOptions = CreateJsonOptions();

    private static JsonSerializerOptions CreateJsonOptions()
    {
        var resolver = new DefaultJsonTypeInfoResolver();
        resolver.Modifiers.Add(info =>
        {
            if (info.Type == typeof(PrunletConfig))
            {
                foreach (var property in info.Properties.Where(property => property.Name == "volumeRecoveryDirectories"))
                    property.ShouldSerialize = (value, _) => ((PrunletConfig)value).VolumeRecoveryDirectories.Count != 0;
                foreach (var property in info.Properties.Where(property => property.Name == "registryScope"))
                    property.ShouldSerialize = (value, _) => ((PrunletConfig)value).RegistryScope != "current";
                foreach (var property in info.Properties.Where(property => property.Name == "registrySessionFile"))
                    property.ShouldSerialize = (value, _) => ((PrunletConfig)value).RegistrySessionFile is not null;
            }
            // 通常属性が既定のschema 1は旧exeの厳密JSON読込との互換性を維持する。
            if (info.Type == typeof(ManifestEntry))
            {
                foreach (var property in info.Properties.Where(property => property.Name is "kind" or "treeRoot"))
                    property.ShouldSerialize = (value, _) => ((ManifestEntry)value).Schema2Wire;
                foreach (var property in info.Properties.Where(property => property.Name is "streams" or "reparseTag" or "linkDirectory" or "caseSensitive"))
                    property.ShouldSerialize = (value, _) => ((ManifestEntry)value).Schema3Wire;
                foreach (var property in info.Properties.Where(property => property.Name == "attributes"))
                    property.ShouldSerialize = (value, _) => ((ManifestEntry)value).Attributes is uint attributes
                        && (((ManifestEntry)value).Schema2Wire || attributes != (uint)FileAttributes.Archive);
            }
            if (info.Type == typeof(FileOperationResult))
                foreach (var property in info.Properties.Where(property => property.Name == "kind"))
                    property.ShouldSerialize = (value, _) => ((FileOperationResult)value).Schema2Wire
                        || ((FileOperationResult)value).Kind is "registry-key" or "registry-value";
        });
        return new JsonSerializerOptions(JsonSerializerDefaults.Web)
        {
            WriteIndented = true,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
            TypeInfoResolver = resolver
        };
    }
}

public sealed class DeleteResult
{
    public string? OperationId { get; set; }
    public bool DryRun { get; set; }
    public List<FileOperationResult> Items { get; set; } = [];
    public List<string> Warnings { get; set; } = [];
}

public sealed class RestoreResult
{
    public string OperationId { get; set; } = string.Empty;
    public List<FileOperationResult> Items { get; set; } = [];
    public List<string> Warnings { get; set; } = [];
}

public sealed class FileOperationResult
{
    internal bool Schema2Wire { get; set; }
    public string Kind { get; set; } = "file";
    public string Path { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string? Error { get; set; }
    public string? BackupPath { get; set; }
    public string? Sha256 { get; set; }
    public long? Size { get; set; }
}

internal sealed class OperationManifest
{
    public int Schema { get; set; } = 1;
    public string OperationId { get; set; } = string.Empty;
    public DateTimeOffset CreatedUtc { get; set; } = DateTimeOffset.UtcNow;
    public List<ManifestEntry> Items { get; set; } = [];
}

internal sealed class ManifestEntry
{
    internal bool Schema2Wire { get; set; }
    internal bool Schema3Wire { get; set; }
    public List<ManifestStream>? Streams { get; set; }
    public uint? ReparseTag { get; set; }
    public bool LinkDirectory { get; set; }
    public bool CaseSensitive { get; set; }
    public string Kind { get; set; } = "file";
    public string? TreeRoot { get; set; }
    public string Path { get; set; } = string.Empty;
    public string State { get; set; } = "pending";
    public string? Sha256 { get; set; }
    public long? Size { get; set; }
    public DateTime? LastWriteUtc { get; set; }
    public uint? Attributes { get; set; }
}

internal sealed class ManifestStream
{
    public string Name { get; set; } = string.Empty;
    public long Offset { get; set; }
    public long Size { get; set; }
    public string Sha256 { get; set; } = string.Empty;
}
