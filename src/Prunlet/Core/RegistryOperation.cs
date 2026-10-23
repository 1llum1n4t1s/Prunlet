using System.Text.Json.Serialization;

namespace Prunlet.Core;

public sealed class RegistryDeleteRequest
{
    public string Path { get; set; } = "";
    public string View { get; set; } = "";
    public string? ValueName { get; set; }
    public bool Recursive { get; set; }
}

internal sealed record RegistryTarget(string Path, string Hive, string[] Segments, string View, string? ValueName)
{
    internal string Kind => ValueName is null ? "registry-key" : "registry-value";
}

internal sealed class RegistrySnapshot
{
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public RegistryScopeIdentity? Scope { get; set; }
    public int Schema { get; set; } = 5;
    public string Path { get; set; } = "";
    public string View { get; set; } = "";
    public string? ValueName { get; set; }
    public List<RegistryKeySnapshot> Keys { get; set; } = [];
    public RegistryValueSnapshot? Value { get; set; }
    public byte[]? ContextSecurity { get; set; }
}

internal sealed class RegistryKeySnapshot
{
    public string RelativePath { get; set; } = "";
    public string Class { get; set; } = "";
    public byte[] Security { get; set; } = [];
    public long LastWriteFileTime { get; set; }
    public List<RegistryValueSnapshot> Values { get; set; } = [];
}

internal sealed class RegistryValueSnapshot
{
    public string Name { get; set; } = "";
    public uint Type { get; set; }
    public byte[] Data { get; set; } = [];
}

internal sealed class RegistryManifest
{
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public RegistryScopeIdentity? Scope { get; set; }
    public int Schema { get; set; } = 5;
    public string OperationId { get; set; } = "";
    public DateTimeOffset CreatedUtc { get; set; } = DateTimeOffset.UtcNow;
    public string MetadataRoot { get; set; } = "";
    public string OwnerSid { get; set; } = "";
    public string Path { get; set; } = "";
    public string View { get; set; } = "";
    public string? ValueName { get; set; }
    public string Kind { get; set; } = "";
    public long Size { get; set; }
    public string Sha256 { get; set; } = "";
}

internal sealed class RegistryReceipt
{
    public int Schema { get; set; } = 5;
    public string OperationId { get; set; } = "";
    public string ManifestSha256 { get; set; } = "";
    public string Action { get; set; } = "";
    public string Phase { get; set; } = "";
    public DateTimeOffset CreatedUtc { get; set; } = DateTimeOffset.UtcNow;
}
