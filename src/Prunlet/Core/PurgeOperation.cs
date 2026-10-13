namespace Prunlet.Core;

public sealed class PurgeResult
{
    public string OperationId { get; set; } = string.Empty;
    public bool DryRun { get; set; }
    public long PurgedBytes { get; set; }
    public List<FileOperationResult> Items { get; set; } = [];
    public List<string> Warnings { get; set; } = [];
}

internal sealed class PurgeIntent
{
    public int Schema { get; set; } = 1;
    public string OperationId { get; set; } = string.Empty;
    public string ManifestSha256 { get; set; } = string.Empty;
    public DateTimeOffset CreatedUtc { get; set; } = DateTimeOffset.UtcNow;
    public List<PurgeTarget> Targets { get; set; } = [];
}

internal sealed class PurgeTarget
{
    public int Index { get; set; }
    public string Sha256 { get; set; } = string.Empty;
    public long Size { get; set; }
}
