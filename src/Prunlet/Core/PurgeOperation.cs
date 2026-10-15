using System.Text.Json.Serialization;

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
    // schema 1 の既存記録には追加せず、復元不能な途中コピーだけを別に記録する。
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<PurgeTarget>? IncompleteTargets { get; set; }
}

internal sealed class PurgeTarget
{
    public int Index { get; set; }
    public string Sha256 { get; set; } = string.Empty;
    public long Size { get; set; }
}
