using System.Text.Json;
using System.Text.Json.Serialization;

namespace Prunlet.Core;

public sealed class PrunletConfig
{
    public int Schema { get; set; } = 1;
    // 旧設定との互換性のため保持する。対象パスの制限には使用しない。
    public string[] AllowedRoots { get; set; } = [];
    public string BackupDirectory { get; set; } = string.Empty;

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
        var backup = PathPolicy.Absolute(BackupDirectory);
        PathPolicy.ExistingDirectory(backup);
    }

    internal static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };
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
    public string Path { get; set; } = string.Empty;
    public string State { get; set; } = "pending";
    public string? Sha256 { get; set; }
    public long? Size { get; set; }
    public DateTime? LastWriteUtc { get; set; }
}
