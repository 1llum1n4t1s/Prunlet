namespace Prunlet.Core;

public sealed partial class DeletionService
{
    // schema 1/2/3のコピー記録とは別に、移動した同一オブジェクトと保管場所を記録する。
    private sealed class MoveManifest
    {
        public MoveManifest() { }
        public int Schema { get; set; } = 4;
        public string OperationId { get; set; } = string.Empty;
        public DateTimeOffset CreatedUtc { get; set; } = DateTimeOffset.UtcNow;
        public string MetadataRoot { get; set; } = string.Empty;
        public string OwnerSid { get; set; } = string.Empty;
        public string StoreKey { get; set; } = string.Empty;
        public List<MoveEntry> Entries { get; set; } = [];
    }

    private sealed class MoveEntry
    {
        public MoveEntry() { }
        public int Index { get; set; }
        public string Path { get; set; } = string.Empty;
        public string Kind { get; set; } = "file";
        public string State { get; set; } = "move_intent";
        public MoveEntryIdentity? Identity { get; set; }
        public MoveEntryIdentity? OriginalParent { get; set; }
        public string VolumeName { get; set; } = string.Empty;
        public string StoreRoot { get; set; } = string.Empty;
        public MoveEntryIdentity? StoreIdentity { get; set; }
        public MoveEntryIdentity? PayloadParent { get; set; }
        public string PayloadName { get; set; } = string.Empty;
        public long? Size { get; set; }
    }

    private sealed class MoveReceipt
    {
        public MoveReceipt() { }
        public int Schema { get; set; } = 4;
        public string OperationId { get; set; } = string.Empty;
        public int Index { get; set; }
        public string ManifestSha256 { get; set; } = string.Empty;
        public string Action { get; set; } = string.Empty;
        public string Phase { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
        public uint? Attributes { get; set; }
        public DateTimeOffset CreatedUtc { get; set; } = DateTimeOffset.UtcNow;
    }
}
