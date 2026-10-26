using System.ComponentModel;
using System.Diagnostics;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed class RecoveryMaintenanceResult
{
    public bool RecordAuditRequested { get; set; }
    public bool RecordAuditComplete { get; set; }
    public string RecordAuditScope { get; set; } = "capacity-layout-only";
    public bool DryRun { get; set; }
    public int RetentionDays { get; set; }
    public long MaxRecoveryBytes { get; set; }
    public long RetainedBytesBefore { get; set; }
    // dry-run の場合は検証済み整理候補を除いた見積り。
    public long RetainedBytesAfter { get; set; }
    public long PurgedBytes { get; set; }
    public long PlannedPurgeBytes { get; set; }
    public bool CapacityKnown { get; set; }
    public bool BudgetSatisfied { get; set; }
    public bool Complete { get; set; }
    public List<PurgeResult> Operations { get; set; } = [];
    public List<string> Warnings { get; set; } = [];
}

public sealed partial class DeletionService
{
    public RecoveryMaintenanceResult MaintainRecovery(bool apply = false, bool auditRecords = false)
    {
        config.Validate();
        using var coordination = AcquireRecoveryCoordination(create: apply);
        return MaintainRegistryOnlyCore(apply, incomingBytes: 0, auditRecords: auditRecords);
    }

    private RecoveryCoordination AcquireRecoveryCoordination(bool create, string[]? deletionTargets = null)
    {
        config.Validate();
        var root = PathPolicy.PinRecoveryDirectories(config.BackupDirectory);
        SafeFileHandle? handle = null;
        try
        {
            var path = Path.Combine(config.BackupDirectory, "maintenance.lock");
            // NativeFilesはWin32の未存在もIOExceptionに統一する。dry-runでロックを新設しない。
            var waiting = Stopwatch.StartNew();
            var nextReport = TimeSpan.FromSeconds(1);
            var reported = false;
            while (true)
            {
                try
                {
                    handle = deletionTargets is not null ? NativeFiles.OpenSharedCoordination(path)
                        : create ? NativeFiles.OpenOrCreateLock(path) : NativeFiles.OpenLock(path);
                    break;
                }
                catch (FileNotFoundException) when (!create) { return new RecoveryCoordination(root, null); }
                catch (IOException ex) when (ex.InnerException is Win32Exception { NativeErrorCode: 32 or 33 })
                {
                    // 大量操作は数分以上かかる。取得競合だけを解放まで待ち、排他と容量上限を維持する。
                    if (waiting.Elapsed >= nextReport)
                    {
                        RecoveryLockProgress?.Invoke(waiting.Elapsed, false);
                        reported = true;
                        nextReport = waiting.Elapsed + TimeSpan.FromSeconds(5);
                    }
                    Thread.Sleep(100);
                }
            }
            NativeFiles.Verify(handle, path);
            NativeFiles.VerifySingleLink(handle);
            NativeFiles.RejectNamedStreams(path);
            if (RandomAccess.GetLength(handle) != 0) throw new InvalidDataException("Recovery coordination lock is not empty.");
            if (deletionTargets is not null)
            {
                // 同じtargetは排他、ancestorは共有。hash衝突は強いclaimへ統合し全batchを昇順で取得する。
                var claims = new SortedDictionary<uint, bool>();
                foreach (var target in deletionTargets)
                {
                    var current = target;
                    var exclusive = true;
                    while (!string.IsNullOrEmpty(current))
                    {
                        var hash = System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(current.TrimEnd('\\').ToUpperInvariant()));
                        var slot = (uint)(hash[0] | hash[1] << 8);
                        claims[slot] = exclusive || claims.GetValueOrDefault(slot);
                        exclusive = false;
                        current = Path.GetDirectoryName(current);
                    }
                }
                foreach (var claim in claims)
                    while (!NativeFiles.TryClaimCoordination(handle, claim.Key, claim.Value))
                    {
                        if (waiting.Elapsed >= nextReport)
                        {
                            RecoveryLockProgress?.Invoke(waiting.Elapsed, false);
                            reported = true;
                            nextReport = waiting.Elapsed + TimeSpan.FromSeconds(5);
                        }
                        Thread.Sleep(100);
                    }
            }
            if (reported) RecoveryLockProgress?.Invoke(waiting.Elapsed, true);
            return new RecoveryCoordination(root, handle);
        }
        catch { handle?.Dispose(); root.Dispose(); throw; }
    }

    private sealed class RecoveryScan
    {
        internal long Bytes;
        internal bool Known = true;
        internal List<RecoveryCandidate> Candidates { get; } = [];
    }
    private sealed record RecoveryCandidate(string Id, DateTimeOffset CreatedUtc);
    private sealed class RecoveryCoordination(DirectoryLease root, SafeFileHandle? handle) : IDisposable
    {
        public void Dispose() { handle?.Dispose(); root.Dispose(); }
    }
}
