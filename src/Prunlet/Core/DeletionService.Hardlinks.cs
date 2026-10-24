using System.Globalization;
using System.Text.RegularExpressions;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private sealed class HardlinkGroup
    {
        internal int Leader => Entries[0].Index;
        internal List<RecycleEntry> Entries { get; } = [];
        internal Dictionary<string, RecycleSecurityNode> Original { get; } = new(StringComparer.Ordinal);
        internal Dictionary<string, RecycleSecurityNode> Current { get; } = new(StringComparer.Ordinal);
        internal int Sequence;
        internal string Previous = string.Empty;
        internal string IntentHash = string.Empty;
        internal bool Blocked;
        internal bool Ready;
    }

    private sealed class HardlinkTransition
    {
        public int Schema { get; set; } = 6;
        public string OperationId { get; set; } = string.Empty;
        public string ManifestSha256 { get; set; } = string.Empty;
        public int Leader { get; set; }
        public int Sequence { get; set; }
        public int Index { get; set; }
        public string Action { get; set; } = string.Empty;
        public string Phase { get; set; } = string.Empty;
        public string PreviousSha256 { get; set; } = string.Empty;
        public string IntentSha256 { get; set; } = string.Empty;
        public string ProofSha256 { get; set; } = string.Empty;
        public string CauseSha256 { get; set; } = string.Empty;
        public string Location { get; set; } = string.Empty;
        public Dictionary<string, RecycleSecurityNode> Security { get; set; } = new(StringComparer.Ordinal);
    }

    private sealed class HardlinkReady
    {
        public int Schema { get; set; } = 6;
        public string OperationId { get; set; } = string.Empty;
        public string ManifestSha256 { get; set; } = string.Empty;
        public int Leader { get; set; }
        public string PreviousSha256 { get; set; } = string.Empty;
        public Dictionary<string, string> StageReadyHashes { get; set; } = new(StringComparer.Ordinal);
    }

    private static string HardlinkId(RecycleSecurityNode node) => node.Identity!.VolumeSerialNumber.ToString(CultureInfo.InvariantCulture)
        + ":" + node.Identity.FileId.ToUpperInvariant();

    private static bool SameHardlinkNode(RecycleSecurityNode a, RecycleSecurityNode b) => SameMoveObject(a.Identity!, b.Identity!)
        && NormalizeMoveAttributes(a.Identity!.Attributes) == NormalizeMoveAttributes(b.Identity!.Attributes)
        && a.Descriptor.AsSpan().SequenceEqual(b.Descriptor);

    private static List<HardlinkGroup> BuildHardlinkGroups(RecycleManifest manifest)
    {
        var owners = new Dictionary<string, List<RecycleEntry>>(StringComparer.Ordinal);
        var originals = new Dictionary<string, RecycleSecurityNode>(StringComparer.Ordinal);
        var parents = Enumerable.Range(0, manifest.Entries.Count).ToArray();
        int Root(int index) { while (parents[index] != index) index = parents[index]; return index; }
        foreach (var entry in manifest.Entries)
        {
            if (entry.Security is null) continue;
            foreach (var node in entry.Security.Values)
            {
                if (!ValidMoveIdentity(node.Identity)) throw new InvalidDataException("Hardlink snapshot identity is invalid.");
                var id = HardlinkId(node);
                if (originals.TryGetValue(id, out var original) && !SameHardlinkNode(original, node))
                    throw new InvalidDataException("Shared objects have inconsistent initial identity, ACL or attributes.");
                originals[id] = node;
                if (!owners.TryGetValue(id, out var entries)) owners[id] = entries = [];
                if (!entries.Contains(entry)) entries.Add(entry);
            }
        }
        foreach (var entries in owners.Values.Where(entries => entries.Count > 1))
            foreach (var entry in entries.Skip(1)) parents[Root(entry.Index)] = Root(entries[0].Index);
        var groups = new Dictionary<int, HardlinkGroup>();
        foreach (var pair in owners.Where(pair => pair.Value.Count > 1))
        {
            var leader = Root(pair.Value[0].Index);
            if (!groups.TryGetValue(leader, out var group)) groups[leader] = group = new HardlinkGroup();
            group.Original.Add(pair.Key, originals[pair.Key]);
            group.Current.Add(pair.Key, originals[pair.Key]);
            foreach (var entry in pair.Value) if (!group.Entries.Contains(entry)) group.Entries.Add(entry);
        }
        foreach (var group in groups.Values) group.Entries.Sort((a, b) => a.Index.CompareTo(b.Index));
        return groups.Values.OrderBy(group => group.Leader).ToList();
    }

    private static Dictionary<string, RecycleSecurityNode> HardlinkExpected(Dictionary<string, RecycleSecurityNode> template, HardlinkGroup? group)
        => template.ToDictionary(pair => pair.Key, pair => group is not null && group.Current.TryGetValue(HardlinkId(pair.Value), out var current)
            ? current : pair.Value, StringComparer.Ordinal);

    private static Dictionary<string, RecycleSecurityNode> SharedHardlinkNodes(HardlinkGroup group, RecycleEntry entry,
        Dictionary<string, RecycleSecurityNode> security)
    {
        var result = new Dictionary<string, RecycleSecurityNode>(StringComparer.Ordinal);
        foreach (var pair in entry.Security!)
        {
            var id = HardlinkId(pair.Value);
            if (!group.Original.ContainsKey(id)) continue;
            if (!security.TryGetValue(pair.Key, out var node) || !SameMoveObject(pair.Value.Identity!, node.Identity!))
                throw new InvalidDataException("Shared-object proof membership differs from its entry.");
            if (result.TryGetValue(id, out var other) && !SameHardlinkNode(other, node))
                throw new InvalidDataException("Shared-object proof contains inconsistent aliases.");
            result[id] = node;
        }
        return result;
    }

    private static string HardlinkTransitionName(HardlinkGroup group, string phase)
        => $"hardlink-{group.Leader:D4}-{group.Sequence:D4}-{phase}.json";
    private static string HardlinkReadyName(HardlinkGroup group) => $"hardlink-{group.Leader:D4}-ready.json";

    private static string HashHardlinkFile(string path)
    {
        using var handle = NativeFiles.OpenBackup(path);
        NativeFiles.Verify(handle, path);
        NativeFiles.VerifySingleLink(handle);
        NativeFiles.RejectNamedStreams(path);
        using var stream = new FileStream(handle, FileAccess.Read);
        return HashStream(stream);
    }

    private HardlinkTransition NewHardlinkTransition(RecycleManifest manifest, string hash, HardlinkGroup group,
        RecycleEntry entry, string action, string phase) => new()
    {
        OperationId = manifest.OperationId, ManifestSha256 = hash, Leader = group.Leader, Sequence = group.Sequence,
        Index = entry.Index, Action = action, Phase = phase, PreviousSha256 = group.Previous
    };

    private void BeginHardlinkTransition(string directory, RecycleManifest manifest, string hash, HardlinkGroup group,
        RecycleEntry entry, string action)
    {
        if (group.Blocked || group.Ready) throw new IOException("The shared-object component cannot start another transition.");
        group.Blocked = true;
        var intent = NewHardlinkTransition(manifest, hash, group, entry, action, "intent");
        intent.Security = SharedHardlinkNodes(group, entry, HardlinkExpected(entry.Security!, group));
        var path = Path.Combine(directory, HardlinkTransitionName(group, "intent"));
        PublishRecycleJson(path, manifest.OperationId, intent);
        group.IntentHash = HashHardlinkFile(path);
    }

    private void CompleteHardlinkTransition(string directory, RecycleManifest manifest, string hash, HardlinkGroup group,
        RecycleEntry entry, string action, Dictionary<string, RecycleSecurityNode> security, string causeHash, string location)
    {
        var proof = NewHardlinkTransition(manifest, hash, group, entry, action, "proof");
        proof.IntentSha256 = group.IntentHash;
        proof.CauseSha256 = causeHash;
        proof.Location = location;
        proof.Security = SharedHardlinkNodes(group, entry, security);
        var proofPath = Path.Combine(directory, HardlinkTransitionName(group, "proof"));
        PublishRecycleJson(proofPath, manifest.OperationId, proof);
        var complete = NewHardlinkTransition(manifest, hash, group, entry, action, "complete");
        complete.IntentSha256 = group.IntentHash;
        complete.ProofSha256 = HashHardlinkFile(proofPath);
        var completePath = Path.Combine(directory, HardlinkTransitionName(group, "complete"));
        PublishRecycleJson(completePath, manifest.OperationId, complete);
        foreach (var pair in proof.Security) group.Current[pair.Key] = pair.Value;
        group.Previous = HashHardlinkFile(completePath);
        group.Sequence++;
        group.Blocked = false;
    }

    private void LoadHardlinkRecords(RecycleRecordLease operation)
    {
        if (operation.Manifest.HardlinkProtocol == 0) return;
        operation.Hardlinks = BuildHardlinkGroups(operation.Manifest);
        var records = new Dictionary<string, (HardlinkTransition Value, string Hash)>(StringComparer.Ordinal);
        var ready = new Dictionary<int, HardlinkReady>();
        foreach (var member in Directory.EnumerateFileSystemEntries(operation.Directory))
        {
            var name = Path.GetFileName(member);
            if (!name.StartsWith("hardlink-", StringComparison.Ordinal)) continue;
            var stream = HoldPurgeMetadata(member, operation.Held);
            var match = Regex.Match(name, "^hardlink-([0-9]{4})-([0-9]{4})-(intent|proof|complete)\\.json$", RegexOptions.CultureInvariant);
            if (match.Success)
            {
                var record = ReadRecycleJson<HardlinkTransition>(stream);
                var group = operation.Hardlinks.SingleOrDefault(group => group.Leader == record.Leader);
                if (group is null || record.Schema != 6 || record.OperationId != operation.Manifest.OperationId
                    || record.ManifestSha256 != operation.Hash || record.Sequence is < 0 or > 511
                    || name != $"hardlink-{record.Leader:D4}-{record.Sequence:D4}-{record.Phase}.json"
                    || record.Phase is not ("intent" or "proof" or "complete") || record.Action is not ("delete" or "stage")
                    || !group.Entries.Any(entry => entry.Index == record.Index))
                    throw new InvalidDataException("Shared-object transition binding is invalid.");
                records.Add(name, (record, HashStream(stream)));
                continue;
            }
            var readyMatch = Regex.Match(name, "^hardlink-([0-9]{4})-ready\\.json$", RegexOptions.CultureInvariant);
            if (!readyMatch.Success) throw new InvalidDataException("Unknown shared-object metadata was retained.");
            var receipt = ReadRecycleJson<HardlinkReady>(stream);
            if (name != $"hardlink-{receipt.Leader:D4}-ready.json" || !ready.TryAdd(receipt.Leader, receipt))
                throw new InvalidDataException("Shared-object ready binding is invalid.");
        }
        foreach (var group in operation.Hardlinks)
        {
            var deleted = new HashSet<int>();
            var completedDeletes = new HashSet<int>();
            var staged = new HashSet<int>();
            while (records.TryGetValue(HardlinkTransitionName(group, "intent"), out var intentRecord))
            {
                var intent = intentRecord.Value;
                var entry = operation.Manifest.Entries[intent.Index];
                var before = SharedHardlinkNodes(group, entry, HardlinkExpected(entry.Security!, group));
                if (intent.Action == "delete" && (staged.Count != 0 || !deleted.Add(entry.Index))
                    || intent.Action == "stage" && (deleted.Count != group.Entries.Count || !staged.Add(entry.Index)))
                    throw new InvalidDataException("Shared-object action order is invalid.");
                if (intent.PreviousSha256 != group.Previous || !SameHardlinkSecurity(intent.Security, before)
                    || intent.IntentSha256.Length != 0 || intent.ProofSha256.Length != 0 || intent.CauseSha256.Length != 0 || intent.Location.Length != 0)
                    throw new InvalidDataException("Shared-object intent does not match the preceding exact state.");
                if (!records.TryGetValue(HardlinkTransitionName(group, "complete"), out var completeRecord))
                { group.Blocked = true; break; }
                if (!records.TryGetValue(HardlinkTransitionName(group, "proof"), out var proofRecord))
                    throw new InvalidDataException("Shared-object completion has no durable proof.");
                var proof = proofRecord.Value;
                var complete = completeRecord.Value;
                foreach (var record in new[] { proof, complete })
                    if (record.Index != intent.Index || record.Action != intent.Action || record.PreviousSha256 != group.Previous
                        || record.IntentSha256 != intentRecord.Hash)
                        throw new InvalidDataException("Shared-object transition chain is inconsistent.");
                if (complete.ProofSha256 != proofRecord.Hash || complete.Security.Count != 0 || complete.CauseSha256.Length != 0 || complete.Location.Length != 0
                    || proof.ProofSha256.Length != 0 || !proof.Security.Keys.Order().SequenceEqual(before.Keys.Order()))
                    throw new InvalidDataException("Shared-object completion does not bind its proof.");
                foreach (var pair in proof.Security)
                {
                    if (!ValidMoveIdentity(pair.Value.Identity) || !SameMoveObject(group.Original[pair.Key].Identity!, pair.Value.Identity!))
                        throw new InvalidDataException("Shared-object proof identity changed.");
                    NativeFiles.ValidateRecycleSecurity(pair.Value.Descriptor);
                }
                var recycled = RecycleReceiptFor(operation, entry, "recycle", "complete")
                    ?? throw new InvalidDataException("Shared-object transition has no recycle receipt.");
                if (intent.Action == "delete")
                {
                    if (proof.CauseSha256 != operation.Hashes[RecycleReceiptName(entry, "recycle", "complete")]
                        || proof.Location != recycled.PhysicalPath || !SameHardlinkSecurity(proof.Security, SharedHardlinkNodes(group, entry, recycled.Security!)))
                        throw new InvalidDataException("Shared-object deletion proof differs from its immutable receipt.");
                }
                else
                {
                    var stage = operation.Stages.GetValueOrDefault(RecycleStageName(entry, "intent"));
                    if (stage is null || RecycleReceiptFor(operation, entry, "restore", "intent") is null
                        || proof.CauseSha256 != operation.Hashes[RecycleStageName(entry, "intent")]
                        || proof.Location != Path.Combine(stage.StageOperationPath, $"{entry.Index:D4}.entry"))
                        throw new InvalidDataException("Shared-object stage proof differs from its bound private stage.");
                }
                foreach (var pair in proof.Security) group.Current[pair.Key] = pair.Value;
                if (intent.Action == "delete") completedDeletes.Add(entry.Index);
                group.Previous = completeRecord.Hash;
                group.Sequence++;
            }
            if (records.Values.Any(record => record.Value.Leader == group.Leader && record.Value.Sequence > group.Sequence)
                || records.ContainsKey(HardlinkTransitionName(group, "complete")) && !records.ContainsKey(HardlinkTransitionName(group, "intent"))
                || records.ContainsKey(HardlinkTransitionName(group, "proof")) && !records.ContainsKey(HardlinkTransitionName(group, "intent")))
                throw new InvalidDataException("Shared-object transition sequence has a gap.");
            if (group.Entries.Any(entry => RecycleReceiptFor(operation, entry, "recycle", "complete") is null)) group.Blocked = true;
            // receiptだけを残してledger末尾を失った状態を、元snapshotからの正常状態に戻さない。
            if (!group.Blocked && !completedDeletes.SetEquals(group.Entries.Select(entry => entry.Index)))
                throw new InvalidDataException("Shared-object recycle receipts do not have one completed deletion transition per entry.");
            if (ready.TryGetValue(group.Leader, out var receipt))
            {
                if (group.Blocked || receipt.Schema != 6 || receipt.OperationId != operation.Manifest.OperationId
                    || receipt.ManifestSha256 != operation.Hash || receipt.PreviousSha256 != group.Previous
                    || receipt.StageReadyHashes.Count != group.Entries.Count || staged.Count != group.Entries.Count)
                    throw new InvalidDataException("Shared-object group-ready receipt is inconsistent.");
                foreach (var entry in group.Entries)
                    if (!receipt.StageReadyHashes.TryGetValue(entry.Index.ToString(CultureInfo.InvariantCulture), out var hash)
                        || !operation.Hashes.TryGetValue(RecycleStageName(entry, "ready"), out var actual) || hash != actual)
                        throw new InvalidDataException("Shared-object group-ready receipt has a different stage proof.");
                group.Ready = true;
                foreach (var pair in group.Original) group.Current[pair.Key] = pair.Value;
            }
        }
        if (ready.Keys.Any(leader => !operation.Hardlinks.Any(group => group.Leader == leader)))
            throw new InvalidDataException("Unknown shared-object ready component.");
    }

    private static bool SameHardlinkSecurity(Dictionary<string, RecycleSecurityNode> a, Dictionary<string, RecycleSecurityNode> b)
        => a.Count == b.Count && a.All(pair => b.TryGetValue(pair.Key, out var other) && SameHardlinkNode(pair.Value, other));
}
