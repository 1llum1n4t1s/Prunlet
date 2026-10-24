using System.Text.Json.Serialization;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private sealed class RecycleManifest
    {
        public int Schema { get; set; } = 6;
        public string OperationId { get; set; } = string.Empty;
        public DateTimeOffset CreatedUtc { get; set; } = DateTimeOffset.UtcNow;
        public string MetadataRoot { get; set; } = string.Empty;
        public string MachineName { get; set; } = string.Empty;
        public string OwnerSid { get; set; } = string.Empty;
        public List<RecycleEntry> Entries { get; set; } = [];
    }

    private sealed class RecycleEntry
    {
        public int Index { get; set; }
        public string Path { get; set; } = string.Empty;
        public string Kind { get; set; } = "file";
        public string State { get; set; } = "recycle_intent";
        public MoveEntryIdentity? Identity { get; set; }
        public MoveEntryIdentity? OriginalParent { get; set; }
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public Dictionary<string, RecycleSecurityNode>? Security { get; set; }
    }

    private sealed class RecycleSecurityNode
    {
        public MoveEntryIdentity? Identity { get; set; }
        public byte[] Descriptor { get; set; } = [];
    }

    private sealed class RecycleReceipt
    {
        public int Schema { get; set; } = 6;
        public string OperationId { get; set; } = string.Empty;
        public int Index { get; set; }
        public string ManifestSha256 { get; set; } = string.Empty;
        public string RecycleSha256 { get; set; } = string.Empty;
        public string Action { get; set; } = string.Empty;
        public string Phase { get; set; } = string.Empty;
        public DateTimeOffset CreatedUtc { get; set; } = DateTimeOffset.UtcNow;
        public string Pidl { get; set; } = string.Empty;
        public string PhysicalPath { get; set; } = string.Empty;
        public MoveEntryIdentity? Identity { get; set; }
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public Dictionary<string, RecycleSecurityNode>? Security { get; set; }
    }
}
