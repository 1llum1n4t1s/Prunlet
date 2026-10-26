using System.Text.Json.Serialization;

namespace Prunlet.Core;

public sealed class PurgeResult
{
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? LifecycleState { get; set; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? OriginalSchema { get; set; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? TerminalReason { get; set; }
    public string OperationId { get; set; } = string.Empty;
    public bool DryRun { get; set; }
    public long PurgedBytes { get; set; }
    public List<FileOperationResult> Items { get; set; } = [];
    public List<string> Warnings { get; set; } = [];
}
