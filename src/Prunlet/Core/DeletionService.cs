namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private readonly PrunletConfig config;
    private readonly RegistrySessionContext? registrySession;
    private const int CopyBufferSize = 128 * 1024;
    internal event Action<TimeSpan, bool>? RecoveryLockProgress;

    public DeletionService(PrunletConfig config) : this(config, null) { }

    internal DeletionService CreateRequestService()
    {
        var request = new DeletionService(config, registrySession);
        // 親の待機診断を引き継ぎ、要求固有のMCP通知は各requestで別途購読する。
        request.RecoveryLockProgress += RecoveryLockProgress;
        return request;
    }

    internal DeletionService(PrunletConfig config, RegistrySessionContext? registrySession)
    {
        ArgumentNullException.ThrowIfNull(config);
        config.Validate();
        this.registrySession = registrySession;
        this.config = new PrunletConfig
        {
            Schema = config.Schema,
            AllowedRoots = config.AllowedRoots?.ToArray() ?? [],
            RetentionDays = config.RetentionDays,
            MaxRecoveryBytes = config.MaxRecoveryBytes,
            RegistryScope = config.RegistryScope,
            RegistrySessionFile = config.RegistrySessionFile,
            VolumeRecoveryDirectories = config.VolumeRecoveryDirectories.ToDictionary(pair => PathPolicy.Absolute(pair.Key),
                pair => PathPolicy.Absolute(pair.Value), StringComparer.OrdinalIgnoreCase),
            BackupDirectory = PathPolicy.Resolve(config.BackupDirectory, finalDirectory: true, allowMissing: false)
        };
    }

    public FileDeleteResult Delete(string[] paths, bool dryRun = false, bool recursive = false)
        => DeleteRecordless(paths, dryRun, recursive);

    public RestoreResult Restore(string operationId)
        => RestoreRegistry(operationId);

    private static bool IsOperational(Exception ex) => ex is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException or System.Security.SecurityException;
}
