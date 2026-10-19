namespace Prunlet.Core;

public sealed class HistoryCompactionResult
{
    public bool DryRun { get; set; }
    public List<HistoryCompactionOperation> Operations { get; set; } = [];
    public List<string> Warnings { get; set; } = [];
}

public sealed class HistoryCompactionOperation
{
    public string OperationId { get; set; } = string.Empty;
    public string Status { get; set; } = "skipped";
    public string? Error { get; set; }
    public List<HistoryCompactionFile> Files { get; set; } = [];
}

public sealed class HistoryCompactionFile
{
    public string Name { get; set; } = string.Empty;
    public string Status { get; set; } = "verified";
    public string? Error { get; set; }
    public string Sha256 { get; set; } = string.Empty;
    public long LogicalBytes { get; set; }
    public long PhysicalBytesBefore { get; set; }
    public long? PhysicalBytesAfter { get; set; }
    public long? SavedBytes => PhysicalBytesAfter is { } after ? PhysicalBytesBefore - after : null;
}
