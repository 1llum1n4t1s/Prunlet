namespace Prunlet.Core;

public sealed class RecoveryMigrationResult
{
    public bool DryRun { get; set; }
    public bool RegistryReady { get; set; }
    public bool Complete { get; set; }
    public List<RecoveryMigrationOperation> Operations { get; set; } = [];
    public List<string> Warnings { get; set; } = [];
}

public sealed class RecoveryMigrationOperation
{
    public string OperationId { get; set; } = "";
    public int? Schema { get; set; }
    public string Status { get; set; } = "";
    public string? Error { get; set; }
    public string? Path { get; set; }
}
