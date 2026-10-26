using System.Text.RegularExpressions;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private sealed class RegistryTerminalState
    {
        public int Schema { get; set; } = 1;
        public DateTimeOffset ClosedUtc { get; set; }
        public string Reason { get; set; } = "";
        public RegistryStorageIntent Binding { get; set; } = new();
    }

    private sealed class RegistryTerminalCleanup
    {
        public int Schema { get; set; } = 1;
        public string OperationId { get; set; } = "";
        public string TerminalSha256 { get; set; } = "";
    }

    private bool RegistryTerminalCleanupStarted(string root, string id)
    {
        var path = Path.Combine(root, id + ".terminal-cleanup.json");
        if (InspectMoveLocation(path) is null) return false;
        if (InspectMoveLocation(path + ".pending") is not null) throw new InvalidDataException("Registry terminal cleanup has both pending and final controls; both were retained.");
        var cleanup = ReadLifecycleJson<RegistryTerminalCleanup>(path);
        if (cleanup.Schema != 1 || cleanup.OperationId != id || cleanup.TerminalSha256 != HashLifecycleRecord(Path.Combine(root, id + ".terminal.json")))
            throw new InvalidDataException("Registry terminal cleanup binding differs.");
        return true;
    }

    private void VerifyRegistryTerminalRemaining(string root, string id, RegistryTerminalState state)
    {
        var directory = Path.Combine(root, id);
        var partial = RegistryTerminalCleanupStarted(root, id);
        if (InspectMoveLocation(directory) is null)
        {
            if (InspectMoveLocation(Path.Combine(root, id + ".terminal-cleanup.json.pending")) is not null)
                throw new InvalidDataException("Unpublished registry cleanup has no complete source inventory; its pending control was retained.");
            if (!partial && state.ClosedUtc > DateTimeOffset.UtcNow.AddDays(-config.RetentionDays))
                throw new InvalidDataException("Registry terminal directory disappeared before expiry.");
            return;
        }
        using var native = NativeFiles.OpenPrivateRegistryDirectory(directory);
        NativeFiles.VerifyPrivateRegistrySecurity(native, directory: true); NativeFiles.RejectNamedStreams(directory);
        if (!SameMoveObject(state.Binding.DirectoryIdentity, NativeFiles.MoveIdentity(native))
            || !NativeFiles.ReadRegistryMemberSecurity(native).SequenceEqual(state.Binding.DirectorySecurity))
            throw new InvalidDataException("Registry terminal directory identity/security changed.");
        var expected = state.Binding.Files.ToDictionary(file => file.Name, StringComparer.Ordinal);
        var remaining = Directory.EnumerateFileSystemEntries(directory).Select(Path.GetFileName).OfType<string>().ToArray();
        if (!partial && !remaining.ToHashSet(StringComparer.Ordinal).SetEquals(expected.Keys))
            throw new InvalidDataException("Registry terminal membership changed before cleanup.");
        foreach (var name in remaining)
        {
            if (!expected.TryGetValue(name, out var file)) throw new InvalidDataException("Unknown registry terminal member was retained.");
            using var handle = NativeFiles.OpenLifecycleMetadata(Path.Combine(directory, name));
            VerifyRegistryTerminalFile(handle, Path.Combine(directory, name), file);
        }
    }

    private RegistryTerminalState ReadRegistryTerminal(string root, string id)
    {
        if (InspectMoveLocation(Path.Combine(root, id + ".terminal.json.pending")) is not null)
            throw new InvalidDataException("Registry terminal pending has not been reconciled; both controls were retained.");
        var state = ReadLifecycleJson<RegistryTerminalState>(Path.Combine(root, id + ".terminal.json"));
        ValidateRegistryMigration(state.Binding, id, root);
        if (state.Schema != 1 || state.ClosedUtc == default || state.Reason is not ("restored" or "purged")
            || state.Binding.Files.Any(file => file.Name == RegistrySnapshotName)
            || !state.Binding.Files.Any(file => file.Name == RegistryReceiptName(state.Reason == "restored" ? "restore" : "purge", "complete")))
            throw new InvalidDataException("Registry terminal state is invalid.");
        return state;
    }

    private void CaptureRegistryTerminal(string id, List<string> warnings)
    {
        try
        {
            var root = RegistryRoot(create: false);
            var path = Path.Combine(root, id + ".terminal.json");
            if (InspectMoveLocation(path) is not null)
            {
                if (InspectMoveLocation(path + ".pending") is not null) throw new InvalidDataException("Registry terminal has both pending and final controls; both were retained.");
                _ = ReadRegistryTerminal(root, id); return;
            }
            if (!CleanupRegistryPublications(id, warnings)) return;
            using var record = OpenRegistryRecord(id);
            if (record.Ambiguous || record.PayloadPresent || !record.Has("restore", "complete") && !record.Has("purge", "complete")) return;
            var action = record.Has("restore", "complete") ? "restore" : "purge";
            using var receipt = new FileStream(NativeFiles.OpenLifecycleMetadata(Path.Combine(record.Directory, RegistryReceiptName(action, "complete"))), FileAccess.Read);
            var completed = ReadRegistryJson<RegistryReceipt>(receipt);
            PublishRegistryControl(path, new RegistryTerminalState { ClosedUtc = completed.CreatedUtc,
                Reason = action == "restore" ? "restored" : "purged", Binding = CaptureRegistryMigration(id, record, root) }, id, "terminal");
        }
        catch (Exception ex) when (IsOperational(ex)) { warnings.Add($"Registry terminal metadata {id} was retained: {ex.Message}"); }
    }

    private void ExpireRegistryTerminal(string root, string id, List<string> warnings)
    {
        try
        {
            var state = ReadRegistryTerminal(root, id);
            VerifyRegistryTerminalRemaining(root, id, state);
            if (state.ClosedUtc > DateTimeOffset.UtcNow || state.ClosedUtc > DateTimeOffset.UtcNow.AddDays(-config.RetentionDays)) return;
            var directory = Path.Combine(root, id);
            if (InspectMoveLocation(directory) is not null)
            {
                using var moving = NativeFiles.OpenLifecycleDirectoryMove(directory);
                NativeFiles.VerifyPrivateRegistrySecurity(moving, directory: true); NativeFiles.RejectNamedStreams(directory);
                if (!SameMoveObject(state.Binding.DirectoryIdentity, NativeFiles.MoveIdentity(moving))
                    || !NativeFiles.ReadRegistryMemberSecurity(moving).SequenceEqual(state.Binding.DirectorySecurity))
                    throw new InvalidDataException("Registry terminal directory identity/security changed.");
                var expected = state.Binding.Files.ToDictionary(file => file.Name, StringComparer.Ordinal);
                var remaining = Directory.EnumerateFileSystemEntries(directory).Select(Path.GetFileName).OfType<string>().ToArray();
                var held = new List<(string Name, Microsoft.Win32.SafeHandles.SafeFileHandle Handle)>();
                try
                {
                    // DELETE handleを全件先に保持し、末尾memberの不一致を一件目削除前に拒否する。
                    foreach (var name in remaining)
                    {
                        if (!expected.TryGetValue(name, out var file)) throw new InvalidDataException("Unknown registry terminal member was retained.");
                        var handle = NativeFiles.OpenLifecycleDelete(Path.Combine(directory, name)); held.Add((name, handle));
                        VerifyRegistryTerminalFile(handle, Path.Combine(directory, name), file);
                    }
                    var cleanupPath = Path.Combine(root, id + ".terminal-cleanup.json");
                    if (!RegistryTerminalCleanupStarted(root, id)) PublishRegistryControl(cleanupPath, new RegistryTerminalCleanup { OperationId = id, TerminalSha256 = HashLifecycleRecord(Path.Combine(root, id + ".terminal.json")) }, id, "terminal-cleanup");
                    foreach (var file in held)
                    {
                        VerifyRegistryTerminalFile(file.Handle, Path.Combine(directory, file.Name), expected[file.Name]);
                        NativeFiles.DeleteOriginalHandle(file.Handle);
                    }
                }
                finally { foreach (var file in held) file.Handle.Dispose(); }
                if (Directory.EnumerateFileSystemEntries(directory).Any()) throw new InvalidDataException("Registry terminal directory is not empty.");
                NativeFiles.SetOriginalDeletePending(moving, true);
            }
            if (InspectMoveLocation(directory) is not null) throw new IOException("Registry terminal directory removal is not confirmed.");
            var cleanup = Path.Combine(root, id + ".terminal-cleanup.json");
            if (InspectMoveLocation(cleanup) is not null) DeleteLifecycleRecord(cleanup);
            DeleteLifecycleRecord(Path.Combine(root, id + ".terminal.json"));
        }
        catch (Exception ex) when (IsOperational(ex)) { warnings.Add($"Registry terminal cleanup {id} was retained: {ex.Message}"); }
    }

    private static void VerifyRegistryTerminalFile(Microsoft.Win32.SafeHandles.SafeFileHandle handle, string path, RegistryMigrationFile file)
    {
        NativeFiles.Verify(handle, path); NativeFiles.VerifySingleLink(handle); NativeFiles.VerifyPrivateRegistrySecurity(handle); NativeFiles.RejectNamedStreams(path);
        if (!SameMoveObject(file.Identity, NativeFiles.MoveIdentity(handle)) || NativeFiles.MoveIdentity(handle).Attributes != file.Identity.Attributes
            || !NativeFiles.ReadRegistryMemberSecurity(handle).SequenceEqual(file.Security)) throw new InvalidDataException("Registry terminal member identity/security changed.");
        using var borrowed = new Microsoft.Win32.SafeHandles.SafeFileHandle(handle.DangerousGetHandle(), ownsHandle: false);
        using var stream = new FileStream(borrowed, FileAccess.Read);
        if (stream.Length != file.Length || HashStream(stream) != file.Sha256) throw new InvalidDataException("Registry terminal member bytes changed.");
    }

    private RecoveryScan ScanRegistryOnly(List<string> warnings, bool apply, bool collectCandidates = true)
    {
        var scan = new RecoveryScan();
        string root;
        try { RequireRegistryStorageReady(create: false); root = RegistryRoot(create: false); }
        catch (Exception ex) when (IsOperational(ex)) { scan.Known = false; warnings.Add(ex.Message); return scan; }
        if (!ReconcileRegistryControlPending(root, apply, warnings)) scan.Known = false;
        foreach (var member in Directory.EnumerateFileSystemEntries(root).ToArray())
        {
            var name = Path.GetFileName(member);
            if (InspectMoveLocation(member) is null) continue;
            if (name is "layout.json" or StorageMigrationStateName) continue;
            var cleanup = Regex.Match(name, "^([0-9a-f]{32})\\.terminal-cleanup\\.json$", RegexOptions.CultureInvariant);
            if (cleanup.Success)
            {
                try { _ = RegistryTerminalCleanupStarted(root, cleanup.Groups[1].Value); }
                catch (Exception ex) when (IsOperational(ex)) { scan.Known = false; warnings.Add(ex.Message); }
                continue;
            }
            var terminal = Regex.Match(name, "^([0-9a-f]{32})\\.terminal\\.json$", RegexOptions.CultureInvariant);
            if (terminal.Success)
            {
                try { var state = ReadRegistryTerminal(root, terminal.Groups[1].Value); VerifyRegistryTerminalRemaining(root, terminal.Groups[1].Value, state); if (apply) ExpireRegistryTerminal(root, terminal.Groups[1].Value, warnings); }
                catch (Exception ex) when (IsOperational(ex)) { scan.Known = false; warnings.Add(ex.Message); }
                continue;
            }
            if (!Guid.TryParseExact(name, "N", out var id) || id.ToString("N") != name)
            { scan.Known = false; warnings.Add($"Unknown registry storage member {name} was retained."); continue; }
            if (InspectMoveLocation(member) is null) continue;
            // terminalの部分清掃では元manifestが無い場合もある。保存済みinventory以外を読まない。
            if (InspectMoveLocation(Path.Combine(root, name + ".terminal.json")) is not null)
            {
                try { var state = ReadRegistryTerminal(root, name); VerifyRegistryTerminalRemaining(root, name, state); }
                catch (Exception ex) when (IsOperational(ex)) { scan.Known = false; warnings.Add(ex.Message); }
                continue;
            }
            if (apply)
            {
                try
                {
                    _ = CleanupRegistryPublications(name, warnings);
                    using var record = OpenRegistryRecord(name);
                    if (record.Has("restore", "complete") && record.PayloadPresent) ConsumeRegistrySnapshot(record);
                }
                catch (Exception ex) when (IsOperational(ex)) { scan.Known = false; warnings.Add($"Registry metadata reconciliation for {name} was retained: {ex.Message}"); }
            }
            ScanRegistryRecovery(scan, name, warnings, collectCandidates);
            if (apply) CaptureRegistryTerminal(name, warnings);
        }
        return scan;
    }

    private RecoveryMaintenanceResult MaintainRegistryOnlyCore(bool apply, long incomingBytes = 0, bool auditRecords = false)
    {
        var result = new RecoveryMaintenanceResult { DryRun = !apply, RetentionDays = config.RetentionDays, MaxRecoveryBytes = config.MaxRecoveryBytes,
            RecordAuditRequested = auditRecords, RecordAuditScope = "registry-records-only" };
        var scan = ScanRegistryOnly(result.Warnings, apply);
        result.RetainedBytesBefore = result.RetainedBytesAfter = scan.Bytes; result.CapacityKnown = scan.Known;
        var now = DateTimeOffset.UtcNow; var expiry = now.AddDays(-config.RetentionDays);
        var budget = incomingBytes >= config.MaxRecoveryBytes ? 0 : config.MaxRecoveryBytes - incomingBytes;
        foreach (var candidate in scan.Candidates.OrderBy(item => item.CreatedUtc).ThenBy(item => item.Id, StringComparer.Ordinal))
        {
            if (candidate.CreatedUtc > now) { result.Warnings.Add($"Registry operation {candidate.Id} has a future timestamp and was retained."); continue; }
            if (candidate.CreatedUtc > expiry && result.RetainedBytesAfter <= budget) continue;
            try
            {
                var purge = PurgeRegistryCore(candidate.Id, apply); result.Operations.Add(purge); result.Warnings.AddRange(purge.Warnings);
                var bytes = apply ? purge.PurgedBytes : purge.Items.Where(item => item.Status == "would_purge").Sum(item => item.Size ?? 0);
                result.RetainedBytesAfter = Math.Max(0, result.RetainedBytesAfter - bytes);
                if (apply) { result.PurgedBytes = checked(result.PurgedBytes + bytes); CaptureRegistryTerminal(candidate.Id, result.Warnings); }
                else result.PlannedPurgeBytes = checked(result.PlannedPurgeBytes + bytes);
            }
            catch (Exception ex) when (IsOperational(ex) || ex is OverflowException) { result.Warnings.Add($"Registry operation {candidate.Id} was retained: {ex.Message}"); }
        }
        if (apply) { var after = ScanRegistryOnly(result.Warnings, apply: true, collectCandidates: false); result.RetainedBytesAfter = after.Bytes; result.CapacityKnown = after.Known; }
        result.BudgetSatisfied = result.CapacityKnown && result.RetainedBytesAfter <= budget;
        result.RecordAuditComplete = auditRecords && result.CapacityKnown;
        result.Complete = result.BudgetSatisfied && result.Warnings.Count == 0;
        return result;
    }

    public RecoveryOperationSummary[] ListRecoveryOperations()
    {
        using var coordination = AcquireRecoveryCoordination(create: false);
        RequireRegistryStorageReady(create: false); var root = RegistryRoot(create: false);
        var result = new List<RecoveryOperationSummary>();
        foreach (var directory in Directory.EnumerateDirectories(root))
        {
            var id = Path.GetFileName(directory);
            ValidateMoveOperationId(id);
            var terminalPath = Path.Combine(root, id + ".terminal.json");
            if (InspectMoveLocation(terminalPath) is not null)
            { var terminal = ReadRegistryTerminal(root, id); VerifyRegistryTerminalRemaining(root, id, terminal); result.Add(new() { OperationId = id, OriginalSchema = 5, LifecycleState = "closed", TerminalReason = terminal.Reason }); continue; }
            using var record = OpenRegistryRecord(id);
            result.Add(new() { OperationId = id, OriginalSchema = 5, LifecycleState = record.Ambiguous ? "ambiguous" : "active" });
        }
        return result.OrderBy(item => item.OperationId, StringComparer.Ordinal).ToArray();
    }
}
