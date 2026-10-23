using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;

namespace Prunlet.Core;

internal sealed record RegistryScopeIdentity
{
    public string Kind { get; init; } = "";
    public string MachineId { get; init; } = "";
    public string OwnerSid { get; init; } = "";

    internal static void Validate(RegistryScopeIdentity? scope)
    {
        if (scope is null) return;
        if (scope.Kind != "nativeWindows" || scope.MachineId is null || scope.MachineId.Length != 64
            || scope.MachineId.Any(character => !char.IsAsciiHexDigitLower(character))
            || scope.OwnerSid is null || new SecurityIdentifier(scope.OwnerSid).Value != scope.OwnerSid)
            throw new InvalidDataException("Registry scope identity is invalid.");
    }

    internal static void RequireExecutionMatch(RegistryScopeIdentity? saved, RegistryScopeIdentity? executing)
    {
        Validate(saved); Validate(executing);
        // scope欠落の旧記録はcurrent/unknownであり、nativeを推定しない。
        if (saved != executing) throw new InvalidOperationException("Registry recovery scope differs from this execution scope; no registry operation was attempted.");
    }
}

internal sealed class RegistrySessionContext(RegistryScopeIdentity scope)
{
    internal RegistryScopeIdentity Scope { get; } = scope;
}

internal static class RegistrySessionConfiguration
{
    internal static string Fingerprint(PrunletConfig config)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new
        {
            config.Schema, AllowedRoots = config.AllowedRoots ?? [],
            BackupDirectory = PathPolicy.Resolve(config.BackupDirectory, finalDirectory: true, allowMissing: false),
            config.RetentionDays, config.MaxRecoveryBytes,
            config.RegistryScope, config.RegistrySessionFile,
            volumes = config.VolumeRecoveryDirectories
                .Select(pair => new KeyValuePair<string, string>(PathPolicy.Absolute(pair.Key), PathPolicy.Absolute(pair.Value)))
                .OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase).ToArray()
        }, PrunletConfig.JsonOptions);
        return Convert.ToHexStringLower(SHA256.HashData(bytes));
    }
}
