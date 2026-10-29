using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

// 固定された導入先・候補の検査と旧実体の保持。切替入口は回復手順の確定後に接続する。
internal static class StartupUpdateCoordinator
{
    private const uint GenericReadWrite = 0xc0000000;
    private const uint ShareReadDelete = 0x00000005;
    private const uint OpenExisting = 3;
    private const uint OpenReparsePoint = 0x00200000;
    private const int SharingViolation = 32;

    internal sealed record Provenance(string Commit, string CliHash, string MaintenanceHash, string HookHash,
        IReadOnlyDictionary<string, string> AuxiliaryHashes);

    internal static readonly (string BinName, string StagePath)[] AuxiliaryProducts =
    [
        ("Install-Prunlet.ps1", @"scripts\Install-Prunlet.ps1"),
        ("start-prunlet-mcp.ps1", @"integration\start-prunlet-mcp.ps1"),
        ("configuration-common.ps1", @"integration\configuration-common.ps1"),
        ("maintenance-task.ps1", @"integration\maintenance-task.ps1"),
        ("uninstall-maintenance.ps1", @"integration\uninstall-maintenance.ps1"),
        ("install-codex.ps1", @"integration\install-codex.ps1"),
        ("uninstall-codex.ps1", @"integration\uninstall-codex.ps1"),
        ("install-agent-instructions.ps1", @"integration\install-agent-instructions.ps1"),
        ("PRUNLET.md", @"integration\PRUNLET.md")
    ];

    internal sealed class InstallationMutexes : IDisposable
    {
        private readonly Mutex global;
        private readonly Mutex local;

        internal InstallationMutexes(string root)
        {
            var key = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(root.ToLowerInvariant())));
            global = new Mutex(false, @"Global\Prunlet-Install-" + key);
            local = new Mutex(false, @"Local\Prunlet-Install-" + key);
            var ownsGlobal = false;
            try
            {
                ownsGlobal = Acquire(global);
                if (!ownsGlobal || !Acquire(local)) throw new UpdateInProgressException();
            }
            catch
            {
                if (ownsGlobal) global.ReleaseMutex();
                local.Dispose();
                global.Dispose();
                throw;
            }
        }

        private static bool Acquire(Mutex mutex)
        {
            try { return mutex.WaitOne(0); }
            catch (AbandonedMutexException) { return true; }
        }

        public void Dispose()
        {
            local.ReleaseMutex();
            global.ReleaseMutex();
            local.Dispose();
            global.Dispose();
        }
    }

    internal sealed class UpdateInProgressException() : IOException("Another Prunlet installation or update is in progress.");
    internal sealed class UpdateDeferredException(string message) : IOException(message);

    internal sealed class OldProductGuards : IDisposable
    {
        private readonly DirectoryLease parents;
        internal FileStream Cli { get; }
        internal FileStream Maintenance { get; }

        internal OldProductGuards(string bin, string cliName, string maintenanceName, Provenance provenance)
        {
            parents = PathPolicy.PinDirectories(bin);
            try
            {
                Cli = OpenOldGuard(Path.Combine(bin, cliName), provenance.CliHash);
                try { Maintenance = OpenOldGuard(Path.Combine(bin, maintenanceName), provenance.MaintenanceHash); }
                catch { Cli.Dispose(); throw; }
            }
            catch { parents.Dispose(); throw; }
        }

        public void Dispose()
        {
            Maintenance.Dispose();
            Cli.Dispose();
            parents.Dispose();
        }
    }

    internal sealed class UpdateState
    {
        public string Product { get; set; } = "Prunlet";
        public int Schema { get; set; } = 1;
        public string Phase { get; set; } = "idle";
        public int Epoch { get; set; } = 1;
        public string OldCommit { get; set; } = "";
        public string PreparedInstalledSourceInfoSha256 { get; set; } = "";
        public string CandidateCommit { get; set; } = "";
        public string CandidateCliSha256 { get; set; } = "";
        public string CandidateMaintenanceSha256 { get; set; } = "";
        public string CandidateSourceInfoSha256 { get; set; } = "";
        public string CleanupCli { get; set; } = "pending";
        public string CleanupMaintenance { get; set; } = "pending";
        public string CleanupHook { get; set; } = "pending";
        public string StageCleanup { get; set; } = "none";
        public bool IntegrationReady { get; set; }
        public bool MigrationComplete { get; set; }
        public bool? MigrationFileComplete { get; set; }
        public PublishedSlot? SlotCli { get; set; }
        public PublishedSlot? SlotMaintenance { get; set; }
        public PublishedSlot? SlotHook { get; set; }
        public string PackageName { get; set; } = "package.zip";
        public string PackageStatus { get; set; } = "none";
        public string PackagePreviousSha256 { get; set; } = "";
        public long PackagePreviousBytes { get; set; }
        public string PriorStageCommit { get; set; } = "";
        public string PriorStageInfoSha256 { get; set; } = "";
        public string PriorPreviousInfoSha256 { get; set; } = "";
        public string PriorOwnerSha256 { get; set; } = "";
        public string PriorCliSha256 { get; set; } = "";
        public string PriorMaintenanceSha256 { get; set; } = "";
        public string PriorHookSha256 { get; set; } = "";
        public Dictionary<string, string>? PriorAuxiliarySha256 { get; set; }
        public string StageWriteName { get; set; } = "";
        public string StageWriteOldSha256 { get; set; } = "";
        public string StageWriteNewSha256 { get; set; } = "";
        public long StageWriteBytes { get; set; }
        public string RotationName { get; set; } = "";
        public string RotationStatus { get; set; } = "";
        public string RotationPriorSha256 { get; set; } = "";
        public string RotationCandidateSha256 { get; set; } = "";
        public string RotationBackupName { get; set; } = "";
        public string RotationCliBackup { get; set; } = "";
        public string RotationMaintenanceBackup { get; set; } = "";
        public string RotationHookBackup { get; set; } = "";
        public Dictionary<string, string> AuxiliaryBackupSha256 { get; set; } = new(StringComparer.Ordinal);
        public string AuxiliaryRotationName { get; set; } = "";
        public string AuxiliaryRotationStatus { get; set; } = "";
        public string AuxiliaryRotationOldSha256 { get; set; } = "";
        public string AuxiliaryRotationNewSha256 { get; set; } = "";
    }

    internal sealed class PublishedSlot
    {
        public string Generation { get; set; } = "";
        public string Sha256 { get; set; } = "";
        public long Bytes { get; set; }
        public string Status { get; set; } = "writing";
    }

    private static readonly JsonSerializerOptions StateOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = System.Text.Json.Serialization.JsonUnmappedMemberHandling.Disallow
    };

    internal static UpdateState? ReadState(string root)
    {
        var path = Path.Combine(root, ".prunlet-update-state.json");
        SafeFileHandle handle;
        // 読取り中も、同じpathの原子的な状態切替を妨げない。
        try { handle = NativeFiles.OpenHardlinkReadGuard(path); }
        catch (FileNotFoundException) { return null; }
        using (handle)
        {
            NativeFiles.Verify(handle, path);
            NativeFiles.VerifySingleLink(handle);
            using var stream = new FileStream(handle, FileAccess.Read);
            if (stream.Length > 65536) throw new InvalidDataException("Update state exceeds the supported size.");
            using var document = JsonDocument.Parse(stream);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
                throw new InvalidDataException("Update state must be a JSON object.");
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in document.RootElement.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new InvalidDataException("Update state contains duplicate fields.");
                if (property.Name is "priorAuxiliarySha256" or "auxiliaryBackupSha256" or "slotCli" or "slotMaintenance" or "slotHook"
                    && property.Value.ValueKind == JsonValueKind.Object)
                {
                    var nested = new HashSet<string>(StringComparer.Ordinal);
                    foreach (var field in property.Value.EnumerateObject())
                        if (!nested.Add(field.Name)) throw new InvalidDataException("Update state contains duplicate nested fields.");
                }
            }
            if (!names.Contains("product") || !names.Contains("schema") || !names.Contains("phase") || !names.Contains("epoch"))
                throw new InvalidDataException("Update state is missing its identity or phase.");
            var state = document.RootElement.Deserialize<UpdateState>(StateOptions)
                ?? throw new InvalidDataException("Update state is empty.");
            ValidateState(state);
            return state;
        }
    }

    private static void ValidateState(UpdateState state)
    {
        if (state.Product != "Prunlet" || state.Schema != 1 || state.Epoch != 1
            || state.Phase is not ("idle" or "switching" or "migrating" or "cleanup")
            || state.CleanupCli is not ("pending" or "attempting" or "done")
            || state.CleanupMaintenance is not ("pending" or "attempting" or "done")
            || state.CleanupHook is not ("pending" or "attempting" or "done")
            || state.StageCleanup is not ("none" or "pending" or "attempting" or "done")
            || state.PackageStatus is not ("none" or "writing" or "ready")
            || !IsPackageName(state.PackageName)
            || state.PackagePreviousSha256 is null
            || (state.PackagePreviousSha256.Length != 0 || state.PackagePreviousBytes != 0)
                && (!IsHex(state.PackagePreviousSha256, 64) || state.PackagePreviousBytes is <= 0 or > 536870912))
            throw new InvalidDataException("Update state is unsupported or malformed.");
        if (state.StageCleanup != "none" && !IsHex(state.CandidateCommit, 40))
            throw new InvalidDataException("Update state has invalid stage identity.");
        if (state.StageCleanup == "pending" && !IsHex(state.PreparedInstalledSourceInfoSha256, 64))
            throw new InvalidDataException("Update state is missing the prepared installed provenance identity.");
        if (state.MigrationComplete != state.MigrationFileComplete.HasValue
            || state.MigrationComplete && state.Phase == "switching"
            || state.Phase == "idle" && !string.IsNullOrEmpty(state.CandidateCliSha256) && !state.MigrationComplete)
            throw new InvalidDataException("Update state has an inconsistent migration completion record.");
        if (!string.IsNullOrEmpty(state.PriorStageCommit)
            && (!IsHex(state.PriorStageCommit, 40) || !IsHex(state.PriorStageInfoSha256, 64)
                || !IsHex(state.PriorPreviousInfoSha256, 64) || !IsHex(state.PriorOwnerSha256, 64)
                || !IsHex(state.PriorCliSha256, 64) || !IsHex(state.PriorMaintenanceSha256, 64) || !IsHex(state.PriorHookSha256, 64)
                || state.PriorAuxiliarySha256 is null
                || !state.PriorAuxiliarySha256.Keys.ToHashSet(StringComparer.Ordinal).SetEquals(AuxiliaryProducts.Select(item => @"bin\" + item.BinName))
                || state.PriorAuxiliarySha256.Values.Any(hash => !IsHex(hash, 64))))
            throw new InvalidDataException("Update state has incomplete prior stage provenance.");
        if (!string.IsNullOrEmpty(state.StageWriteName)
            && (!IsAllowedStageWrite(state.StageWriteName) || !IsHex(state.StageWriteOldSha256, 64)
                || !IsHex(state.StageWriteNewSha256, 64) || state.StageWriteBytes is <= 0 or > 536870912))
            throw new InvalidDataException("Update state has an invalid staged write record.");
        if (string.IsNullOrEmpty(state.StageWriteName)
            && (!string.IsNullOrEmpty(state.StageWriteOldSha256) || !string.IsNullOrEmpty(state.StageWriteNewSha256) || state.StageWriteBytes != 0))
            throw new InvalidDataException("Update state has an incomplete staged write record.");
        if (!string.IsNullOrEmpty(state.RotationStatus)
            && (state.RotationStatus is not ("writing" or "candidate_ready" or "candidate_named" or "replacing" or "ambiguous" or "switched")
                || state.RotationName is not ("prunlet.exe" or "prunlet-maintenance.exe" or "prunlet-hook.exe")
                || !string.IsNullOrEmpty(state.RotationPriorSha256) && !IsHex(state.RotationPriorSha256, 64)
                || !IsHex(state.RotationCandidateSha256, 64)
                || !IsRotationBackupName(state.RotationName, state.RotationBackupName)))
            throw new InvalidDataException("Update state has an invalid product rotation record.");
        if (!string.IsNullOrEmpty(state.RotationCliBackup) && !IsRotationBackupName("prunlet.exe", state.RotationCliBackup)
            || !string.IsNullOrEmpty(state.RotationMaintenanceBackup) && !IsRotationBackupName("prunlet-maintenance.exe", state.RotationMaintenanceBackup)
            || !string.IsNullOrEmpty(state.RotationHookBackup) && !IsRotationBackupName("prunlet-hook.exe", state.RotationHookBackup))
            throw new InvalidDataException("Update state has an invalid retained product backup name.");
        if (state.AuxiliaryBackupSha256 is null
            || state.AuxiliaryBackupSha256.Any(item => !AuxiliaryProducts.Any(product => @"bin\" + product.BinName == item.Key)
                || !IsHex(item.Value, 64)))
            throw new InvalidDataException("Update state has an invalid auxiliary backup identity.");
        if (!string.IsNullOrEmpty(state.AuxiliaryRotationStatus))
        {
            if (state.AuxiliaryRotationStatus is not ("replacing" or "ambiguous")
                || !AuxiliaryProducts.Any(product => product.BinName == state.AuxiliaryRotationName)
                || !IsHex(state.AuxiliaryRotationOldSha256, 64) || !IsHex(state.AuxiliaryRotationNewSha256, 64))
                throw new InvalidDataException("Update state has an invalid auxiliary replacement record.");
        }
        else if (!string.IsNullOrEmpty(state.AuxiliaryRotationName) || !string.IsNullOrEmpty(state.AuxiliaryRotationOldSha256)
            || !string.IsNullOrEmpty(state.AuxiliaryRotationNewSha256))
            throw new InvalidDataException("Update state has an incomplete auxiliary replacement record.");
        foreach (var slot in new[] { state.SlotCli, state.SlotMaintenance, state.SlotHook })
            if (slot is not null && (!Guid.TryParseExact(slot.Generation, "N", out var generation) || generation == Guid.Empty
                || !IsHex(slot.Sha256, 64) || slot.Bytes is <= 0 or > 256L * 1024 * 1024
                || slot.Status is not ("writing" or "ready")))
                throw new InvalidDataException("Update state has an invalid product slot record.");
        if (state.Phase != "idle" || !string.IsNullOrEmpty(state.CandidateCliSha256))
        {
            if (!IsHex(state.OldCommit, 40) || !IsHex(state.CandidateCommit, 40) || !IsHex(state.CandidateCliSha256, 64)
                || !IsHex(state.CandidateMaintenanceSha256, 64) || !IsHex(state.CandidateSourceInfoSha256, 64))
                throw new InvalidDataException("Update state has invalid candidate identity.");
        }
    }

    private static bool IsHex(string? value, int length) => value is not null && value.Length == length && value.All(Uri.IsHexDigit);

    internal static bool IsPackageName(string? name) => name == "package.zip"
        || name is not null && System.Text.RegularExpressions.Regex.IsMatch(name, @"\Apackage-[0-9a-f]{32}\.zip\z");

    private static bool IsAllowedStageWrite(string name) => name is "owner" or "source-info.json" or "previous-source-info.json"
        or "previous-source-info-original.json" or "prunlet.exe" or "prunlet-maintenance.exe" or "prunlet-hook.exe"
        || AuxiliaryProducts.Any(item => item.StagePath.Equals(name, StringComparison.Ordinal)
            || ("previous-auxiliary/" + item.BinName).Equals(name, StringComparison.Ordinal));

    private static bool IsRotationBackupName(string product, string? backup)
    {
        var prefix = Path.GetFileNameWithoutExtension(product) + ".previous";
        return backup == prefix + ".exe" || backup is not null
            && System.Text.RegularExpressions.Regex.IsMatch(backup,
                "\\A" + System.Text.RegularExpressions.Regex.Escape(prefix) + @"-[0-9a-f]{32}\.exe\z");
    }

    internal static void WriteState(string root, UpdateState state)
    {
        ValidateState(state);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(state, StateOptions);
        if (bytes.Length > 65536) throw new InvalidDataException("Update state exceeds its supported size.");
        StartupUpdateBudget.Ensure(root, bytes.Length);
        var path = Path.Combine(root, ".prunlet-update-state.json");
        // 固定tempは中断後の再開を塞ぐ。未公開の一意tempを正本として扱わない。
        var temporary = Path.Combine(root, ".prunlet-update-state." + Guid.NewGuid().ToString("N") + ".pending");
        using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
            4096, FileOptions.WriteThrough))
        {
            stream.Write(bytes);
            stream.Flush(flushToDisk: true);
        }
        // 正式stateだけを正本とし、副作用の前に原子的に確定する。
        if (ReadState(root) is null) File.Move(temporary, path);
        else File.Replace(temporary, path, null);
    }

    internal sealed record StageCleanupResult(string Status, string? Error = null);

    internal sealed record BeginPublishedResult(string Status, string CandidateCommit, string[]? Warnings = null);

    internal sealed record PublishedPrepareResult(string Status, string CandidateCommit, string[] Warnings);

    internal static BeginPublishedResult BeginPublished(string configPath, string commit, string? expectedInstalledCommit = null)
    {
        if (!IsHex(commit, 40) || !IsHex(expectedInstalledCommit, 40))
            throw new ArgumentException("Resolved release and expected installed commits are required.");
        var root = InstallationRoot(configPath);
        using var parents = PathPolicy.PinDirectories(root);
        using var mutexes = new InstallationMutexes(root);
        // 既存製品の来歴が確認できない導入は自動更新へ進めない。
        var installedInfo = Path.Combine(root, "source-info.json");
        var installed = ReadProvenance(installedInfo);
        if (!installed.Commit.Equals(expectedInstalledCommit, StringComparison.OrdinalIgnoreCase))
            throw new IOException("The installed commit changed after release ancestry was checked; the update was deferred.");
        var installedInfoHash = HashFile(installedInfo);
        var state = ReadState(root);
        var stage = Path.Combine(root, ".prunlet-update-stage");
        var stageExists = false;
        try
        {
            using var handle = NativeFiles.OpenAny(stage);
            NativeFiles.Verify(handle, stage, directory: true);
            stageExists = true;
        }
        catch (FileNotFoundException) { }
        if (state is not null && state.Phase != "idle")
            throw new IOException("A previous update is still active and was preserved.");
        if (state?.StageCleanup == "pending")
        {
            if (state.MigrationComplete && stageExists && !string.IsNullOrEmpty(state.CandidateCliSha256))
            {
                if (string.Equals(state.CandidateCommit, commit, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("The requested release is already installed.");
                VerifyStageOwner(stage, root, state.CandidateCommit);
                var ownerPath = Path.Combine(stage, ".prunlet-stage-owner.json");
                NativeFiles.RejectNamedStreams(ownerPath);
                var ownerHash = HashFile(ownerPath);
                var stageInfo = Path.Combine(stage, "source-info.json");
                VerifyFileHash(stageInfo, state.CandidateSourceInfoSha256);
                VerifyFileHash(installedInfo, state.CandidateSourceInfoSha256);
                if (!installed.Commit.Equals(state.CandidateCommit, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Installed provenance does not match the retained stage.");
                var previousInfo = Path.Combine(stage, "previous-source-info.json");
                var prior = ReadProvenance(previousInfo);
                if (!prior.Commit.Equals(state.OldCommit, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Previous provenance does not match the retained stage.");
                var previousHash = HashFile(previousInfo);
                VerifyFileHash(Path.Combine(stage, "previous-source-info-original.json"), previousHash);
                var priorAuxiliary = prior.AuxiliaryHashes.ToDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
                foreach (var item in state.AuxiliaryBackupSha256)
                {
                    var name = item.Key[@"bin\".Length..];
                    var backup = Path.Combine(stage, "previous-auxiliary", name);
                    NativeFiles.RejectNamedStreams(backup);
                    VerifyFileHash(backup, item.Value);
                    priorAuxiliary[item.Key] = item.Value;
                }
                var oldPackageName = state.PackageName;
                var packageName = oldPackageName;
                var priorPackageHash = "";
                long priorPackageBytes = 0;
                var warnings = new List<string>();
                try
                {
                    var expected = ReadArchiveHash(installedInfo);
                    var packagePath = Path.Combine(stage, oldPackageName);
                    NativeFiles.RejectNamedStreams(packagePath);
                    VerifyFileHash(packagePath, expected);
                    using var file = NativeFiles.OpenBackup(packagePath);
                    using var input = new FileStream(file, FileAccess.Read);
                    priorPackageHash = expected;
                    priorPackageBytes = input.Length;
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException)
                {
                    packageName = "package-" + Guid.NewGuid().ToString("N") + ".zip";
                    warnings.Add("The previous package could not be verified and was retained.");
                }
                state = new UpdateState { CandidateCommit = commit.ToUpperInvariant(), StageCleanup = "pending",
                    PreparedInstalledSourceInfoSha256 = installedInfoHash,
                    SlotCli = state.SlotCli, SlotMaintenance = state.SlotMaintenance, SlotHook = state.SlotHook,
                    PriorStageCommit = installed.Commit, PriorStageInfoSha256 = state.CandidateSourceInfoSha256,
                    PriorPreviousInfoSha256 = previousHash, PriorOwnerSha256 = ownerHash,
                    PriorCliSha256 = prior.CliHash, PriorMaintenanceSha256 = prior.MaintenanceHash, PriorHookSha256 = prior.HookHash,
                    PriorAuxiliarySha256 = priorAuxiliary,
                    AuxiliaryBackupSha256 = state.AuxiliaryBackupSha256.ToDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal),
                    PackageName = packageName, PackageStatus = priorPackageHash.Length == 0 ? "none" : "ready",
                    PackagePreviousSha256 = priorPackageHash, PackagePreviousBytes = priorPackageBytes };
                WriteState(root, state);
                UpdateStageOwner(root, state);
                return new BeginPublishedResult("ready", commit.ToUpperInvariant(), warnings.ToArray());
            }
            if (!string.Equals(state.CandidateCommit, commit, StringComparison.OrdinalIgnoreCase)
                || !string.IsNullOrEmpty(state.CandidateCliSha256) || state.MigrationComplete || state.IntegrationReady)
                throw new IOException("A previous update stage requires attention and was preserved.");
            if (!installedInfoHash.Equals(state.PreparedInstalledSourceInfoSha256, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Installed provenance changed after update preparation; the stage was preserved.");
            if (stageExists)
            {
                if (!string.IsNullOrEmpty(state.PriorStageCommit)) UpdateStageOwner(root, state);
                VerifyStageOwner(stage, root, commit);
                return new BeginPublishedResult("existing", commit.ToUpperInvariant());
            }
        }
        else
        {
            if (stageExists) throw new IOException("An unrecognized update stage was preserved.");
            if (state is not null && (state.StageCleanup is not ("none" or "done")
                || !string.IsNullOrEmpty(state.CandidateCliSha256)
                    && (state.CleanupCli != "done" || state.CleanupMaintenance != "done" || state.CleanupHook != "done")))
                throw new IOException("A previous update or its cleanup requires attention and was preserved.");
            state = new UpdateState { CandidateCommit = commit.ToUpperInvariant(), StageCleanup = "pending",
                PreparedInstalledSourceInfoSha256 = installedInfoHash,
                SlotCli = state?.SlotCli, SlotMaintenance = state?.SlotMaintenance, SlotHook = state?.SlotHook };
            WriteState(root, state);
        }
        NativeFiles.CreateDirectory(stage);
        using var stageParents = PathPolicy.PinDirectories(stage);
        var owner = Path.Combine(stage, ".prunlet-stage-owner.json");
        var ownerBytes = JsonSerializer.SerializeToUtf8Bytes(new { product = "Prunlet", schema = 1, installRoot = root,
            candidateCommit = commit.ToUpperInvariant(), epoch = 1 }, StateOptions);
        if (ownerBytes.Length > 65536) throw new InvalidDataException("Stage owner exceeds its supported size.");
        StartupUpdateBudget.Ensure(root, ownerBytes.Length);
        using (var output = new FileStream(owner, FileMode.CreateNew, FileAccess.Write, FileShare.None,
            4096, FileOptions.WriteThrough))
        {
            output.Write(ownerBytes);
            output.Flush(flushToDisk: true);
        }
        VerifyStageOwner(stage, root, commit);
        return new BeginPublishedResult("ready", commit.ToUpperInvariant());
    }

    private static void UpdateStageOwner(string root, UpdateState state)
    {
        var owner = Path.Combine(root, ".prunlet-update-stage", ".prunlet-stage-owner.json");
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new { product = "Prunlet", schema = 1, installRoot = root,
            candidateCommit = state.CandidateCommit, epoch = 1 }, StateOptions);
        StartupUpdateBudget.Ensure(root, bytes.Length);
        using var input = new MemoryStream(bytes, writable: false);
        WriteKnownStageProduct(root, state, "owner", owner, input, bytes.Length,
            Convert.ToHexString(SHA256.HashData(bytes)), state.PriorOwnerSha256);
        VerifyStageOwner(Path.GetDirectoryName(owner)!, root, state.CandidateCommit);
    }

    private static string ReadArchiveHash(string path)
    {
        using var handle = NativeFiles.OpenBackup(path);
        NativeFiles.Verify(handle, path);
        NativeFiles.VerifySingleLink(handle);
        using var stream = new FileStream(handle, FileAccess.Read);
        if (stream.Length > 65536) throw new InvalidDataException("Product provenance exceeds the supported size.");
        using var document = JsonDocument.Parse(stream);
        if (document.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Product provenance must be an object.");
        return RequiredHex(document.RootElement, "archiveSha256", 64);
    }

    internal static PublishedPrepareResult PreparePublished(string configPath, string repository, string branch, string commit,
        string runtime, string assetSha256, long assetBytes, long assetId)
    {
        if (assetId <= 0 || !System.Text.RegularExpressions.Regex.IsMatch(repository, @"\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z"))
            throw new ArgumentException("A valid authenticated release repository and asset id are required.");
        var root = InstallationRoot(configPath);
        using var mutexes = new InstallationMutexes(root);
        var state = ReadState(root) ?? throw new InvalidDataException("Update preparation state is missing.");
        if (state.Phase != "idle" || state.StageCleanup != "pending" || state.MigrationComplete
            || !string.IsNullOrEmpty(state.CandidateCliSha256)
            || !string.Equals(state.CandidateCommit, commit, StringComparison.OrdinalIgnoreCase))
            throw new IOException("The update stage is not ready for package preparation.");
        using var package = StartupUpdatePackage.OpenVerified(root, repository, branch, commit, runtime, assetSha256, assetBytes);
        StartupUpdateBudget.Ensure(root, 0);
        EnsureOwnedSlotDirectory(root);
        var prior = string.IsNullOrEmpty(state.PriorStageCommit) ? null : ReadProvenance(Path.Combine(root, "source-info.json"));
        if (prior is not null && !prior.Commit.Equals(state.PriorStageCommit, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Installed provenance no longer matches the prior stage.");
        var warnings = new List<string>();
        PrepareSlot(root, state, package, StartupUpdateSlot.Product.Cli, "bin/prunlet.exe", prior?.CliHash, warnings);
        PrepareSlot(root, state, package, StartupUpdateSlot.Product.Maintenance, "bin/prunlet-maintenance.exe", prior?.MaintenanceHash, warnings);
        PrepareSlot(root, state, package, StartupUpdateSlot.Product.Hook, "bin/prunlet-hook.exe", prior?.HookHash, warnings);
        var stage = Path.Combine(root, ".prunlet-update-stage");
        EnsurePlainDirectory(Path.Combine(stage, "scripts"));
        EnsurePlainDirectory(Path.Combine(stage, "integration"));
        foreach (var item in AuxiliaryProducts)
        {
            var product = package.Products.Single(entry => entry.Name == @"bin/" + item.BinName);
            var oldHash = prior?.AuxiliaryHashes[@"bin\" + item.BinName];
            StartupUpdateBudget.Ensure(root, StageProductReserve(Path.Combine(stage, item.StagePath), product.Bytes, product.Sha256, oldHash));
            using var input = package.OpenProduct(product.Name);
            WriteStageProduct(root, state, item.StagePath, Path.Combine(stage, item.StagePath), input, product.Bytes, product.Sha256, oldHash);
        }
        var auxiliary = AuxiliaryProducts.ToDictionary(item => @"bin\" + item.BinName,
            item => package.Products.Single(product => product.Name == @"bin/" + item.BinName).Sha256,
            StringComparer.Ordinal);
        var info = new
        {
            repository, defaultBranch = branch, commitSha = commit.ToLowerInvariant(),
            downloadUrl = $"https://api.github.com/repos/{repository}/releases/assets/{assetId}",
            archiveSha256 = assetSha256.ToUpperInvariant(),
            executableSha256 = package.Products.Single(product => product.Name == "bin/prunlet.exe").Sha256,
            maintenanceExecutableSha256 = package.Products.Single(product => product.Name == "bin/prunlet-maintenance.exe").Sha256,
            hookExecutableSha256 = package.Products.Single(product => product.Name == "bin/prunlet-hook.exe").Sha256,
            auxiliarySha256 = auxiliary, runtime
        };
        var bytes = JsonSerializer.SerializeToUtf8Bytes(info, StateOptions);
        var infoHash = Convert.ToHexString(SHA256.HashData(bytes));
        var priorInfoHash = prior is null ? null : state.PriorStageInfoSha256;
        StartupUpdateBudget.Ensure(root, StageProductReserve(Path.Combine(stage, "source-info.json"), bytes.Length, infoHash, priorInfoHash));
        using (var input = new MemoryStream(bytes, writable: false))
            WriteStageProduct(root, state, "source-info.json", Path.Combine(stage, "source-info.json"), input, bytes.Length, infoHash, priorInfoHash);
        StartupUpdateBudget.Ensure(root, 0);
        return new PublishedPrepareResult("prepared", commit.ToLowerInvariant(), warnings.ToArray());
    }

    private static void PrepareSlot(string root, UpdateState state, StartupUpdatePackage package,
        StartupUpdateSlot.Product kind, string name, string? priorStageHash, List<string> warnings)
    {
        var product = package.Products.Single(item => item.Name == name);
        var candidatePath = Path.Combine(root, ".prunlet-update-stage", Path.GetFileName(name));
        var candidateReserve = StageProductReserve(candidatePath, product.Bytes, product.Sha256, priorStageHash);
        StartupUpdateBudget.Ensure(root, checked(product.Bytes + candidateReserve));
        var previous = kind switch
        {
            StartupUpdateSlot.Product.Cli => state.SlotCli,
            StartupUpdateSlot.Product.Maintenance => state.SlotMaintenance,
            StartupUpdateSlot.Product.Hook => state.SlotHook,
            _ => throw new ArgumentException("Unknown product slot.")
        };
        if (previous?.Status == "writing") warnings.Add("An interrupted product slot was retained: " + kind);
        var reusable = previous?.Status == "ready" ? previous : null;
        using (var lease = StartupUpdateSlot.Acquire(root, kind,
            reusable is null ? null : Guid.ParseExact(reusable.Generation, "N"), reusable?.Sha256, reusable?.Bytes, product.Bytes))
        {
            if (!lease.Reused && reusable is not null)
                warnings.Add("A previous product slot was retained: " + kind + " (" + lease.PreviousStatus + ").");
            var slot = new PublishedSlot { Generation = lease.Generation.ToString("N"), Sha256 = product.Sha256,
                Bytes = product.Bytes, Status = "writing" };
            SetSlot(state, kind, slot);
            WriteState(root, state);
            if (!lease.Reused || reusable is null || !reusable.Sha256.Equals(product.Sha256, StringComparison.OrdinalIgnoreCase)
                || reusable.Bytes != product.Bytes)
            {
                using var input = package.OpenProduct(name);
                lease.WriteVerified(input, product.Bytes, product.Sha256);
            }
            else lease.VerifyBeforeUse(product.Bytes, product.Sha256);
            slot.Status = "ready";
            WriteState(root, state);
            lease.VerifyBeforeUse(product.Bytes, product.Sha256);
            WriteStageProduct(root, state, Path.GetFileName(name), candidatePath, lease.Stream, product.Bytes, product.Sha256, priorStageHash);
            lease.VerifyBeforeUse(product.Bytes, product.Sha256);
        }
        using var parents = PathPolicy.PinDirectories(Path.Combine(root, ".prunlet-update-slots"));
        _ = StartupUpdateSlot.MeasureCache(Path.Combine(root, ".prunlet-update-slots"));
    }

    private static void SetSlot(UpdateState state, StartupUpdateSlot.Product kind, PublishedSlot value)
    {
        switch (kind)
        {
            case StartupUpdateSlot.Product.Cli: state.SlotCli = value; break;
            case StartupUpdateSlot.Product.Maintenance: state.SlotMaintenance = value; break;
            case StartupUpdateSlot.Product.Hook: state.SlotHook = value; break;
            default: throw new ArgumentException("Unknown product slot.");
        }
    }

    private static void EnsureOwnedSlotDirectory(string root)
    {
        var path = Path.Combine(root, ".prunlet-update-slots");
        var created = false;
        try { using var existing = NativeFiles.OpenDirectory(path); NativeFiles.Verify(existing, path, directory: true); }
        catch (FileNotFoundException) { NativeFiles.CreateDirectory(path); created = true; }
        using var parents = PathPolicy.PinDirectories(path);
        var owner = Path.Combine(path, ".prunlet-slot-owner.json");
        if (created)
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(new { product = "Prunlet", schema = 1, installRoot = root }, StateOptions);
            if (bytes.Length > 65536) throw new InvalidDataException("Slot owner exceeds its supported size.");
            StartupUpdateBudget.Ensure(root, bytes.Length);
            using var output = new FileStream(owner, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                4096, FileOptions.WriteThrough);
            output.Write(bytes);
            output.Flush(flushToDisk: true);
            return;
        }
        using var handle = NativeFiles.OpenBackup(owner);
        NativeFiles.Verify(handle, owner);
        NativeFiles.VerifySingleLink(handle);
        NativeFiles.RejectNamedStreams(owner);
        using var stream = new FileStream(handle, FileAccess.Read);
        if (stream.Length > 65536) throw new InvalidDataException("Slot owner record is too large.");
        using var document = JsonDocument.Parse(stream);
        if (document.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Slot owner record is invalid.");
        var properties = document.RootElement.EnumerateObject().ToArray();
        var names = properties.Select(property => property.Name).ToHashSet(StringComparer.Ordinal);
        if (properties.Length != 3 || names.Count != 3 || !names.SetEquals(["product", "schema", "installRoot"])
            || document.RootElement.GetProperty("product").GetString() != "Prunlet"
            || document.RootElement.GetProperty("schema").GetInt32() != 1
            || !string.Equals(document.RootElement.GetProperty("installRoot").GetString(), root, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Slot namespace ownership cannot be confirmed.");
    }

    private static void EnsurePlainDirectory(string path)
    {
        try { using var existing = NativeFiles.OpenDirectory(path); NativeFiles.Verify(existing, path, directory: true); }
        catch (FileNotFoundException) { NativeFiles.CreateDirectory(path); }
        using var parents = PathPolicy.PinDirectories(path);
    }

    private static void WriteFixedProduct(string path, Stream input, long expectedBytes, string expectedSha256)
    {
        using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(path)!);
        try
        {
            using var existing = NativeFiles.OpenBackup(path);
            NativeFiles.Verify(existing, path);
            NativeFiles.VerifySingleLink(existing);
            NativeFiles.RejectNamedStreams(path);
            using var stream = new FileStream(existing, FileAccess.Read);
            if (stream.Length != expectedBytes || !Convert.ToHexString(SHA256.HashData(stream)).Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
                throw new IOException("An existing staged product differs from the candidate and was preserved: " + path);
            return;
        }
        catch (FileNotFoundException) { }
        using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None,
            128 * 1024, FileOptions.WriteThrough))
        {
            using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[128 * 1024];
            long total = 0;
            while (true)
            {
                var read = input.Read(buffer, 0, buffer.Length);
                if (read == 0) break;
                total = checked(total + read);
                if (total > expectedBytes) throw new InvalidDataException("Staged product exceeds its confirmed size.");
                digest.AppendData(buffer, 0, read);
                output.Write(buffer, 0, read);
            }
            output.Flush(flushToDisk: true);
            if (total != expectedBytes || !Convert.ToHexString(digest.GetHashAndReset()).Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Staged product differs from the verified package.");
        }
        NativeFiles.RejectNamedStreams(path);
        VerifyFileHash(path, expectedSha256);
    }

    private static long FixedProductReserve(string path, long expectedBytes, string expectedSha256)
    {
        try
        {
            using var existing = NativeFiles.OpenBackup(path);
            NativeFiles.Verify(existing, path);
            NativeFiles.VerifySingleLink(existing);
            NativeFiles.RejectNamedStreams(path);
            using var stream = new FileStream(existing, FileAccess.Read);
            if (stream.Length != expectedBytes || !Convert.ToHexString(SHA256.HashData(stream)).Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
                throw new IOException("An existing staged product differs from the candidate and was preserved: " + path);
            return 0;
        }
        catch (FileNotFoundException) { return expectedBytes; }
    }

    private static long StageProductReserve(string path, long expectedBytes, string expectedSha256, string? oldSha256)
    {
        if (oldSha256 is null) return FixedProductReserve(path, expectedBytes, expectedSha256);
        try
        {
            using var handle = NativeFiles.OpenBackup(path);
            NativeFiles.Verify(handle, path);
            NativeFiles.VerifySingleLink(handle);
            NativeFiles.RejectNamedStreams(path);
            using var stream = new FileStream(handle, FileAccess.Read);
            var hash = Convert.ToHexString(SHA256.HashData(stream));
            if (!hash.Equals(oldSha256, StringComparison.OrdinalIgnoreCase)
                && !hash.Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
                throw new IOException("A changed staged cache file was preserved: " + path);
            return Math.Max(0, expectedBytes - stream.Length);
        }
        catch (FileNotFoundException) { return expectedBytes; }
    }

    private static void WriteStageProduct(string root, UpdateState state, string key, string path, Stream input,
        long expectedBytes, string expectedSha256, string? oldSha256)
    {
        if (oldSha256 is null) { WriteFixedProduct(path, input, expectedBytes, expectedSha256); return; }
        try
        {
            using var existing = NativeFiles.OpenBackup(path);
        }
        catch (FileNotFoundException)
        {
            if (state.StageWriteName == key) throw new IOException("An interrupted staged cache file is missing and was not recreated.");
            WriteFixedProduct(path, input, expectedBytes, expectedSha256);
            return;
        }
        WriteKnownStageProduct(root, state, key, path, input, expectedBytes, expectedSha256, oldSha256);
    }

    private static void WriteKnownStageProduct(string root, UpdateState state, string key, string path, Stream input,
        long expectedBytes, string expectedSha256, string oldSha256)
    {
        if (!IsAllowedStageWrite(key) || !IsHex(oldSha256, 64) || !IsHex(expectedSha256, 64))
            throw new InvalidDataException("A staged cache update has invalid provenance.");
        NativeFiles.RejectNamedStreams(path);
        var actual = HashFile(path);
        if (actual.Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
        {
            if (state.StageWriteName == key)
            {
                if (!state.StageWriteOldSha256.Equals(oldSha256, StringComparison.OrdinalIgnoreCase)
                    || !state.StageWriteNewSha256.Equals(expectedSha256, StringComparison.OrdinalIgnoreCase)
                    || state.StageWriteBytes != expectedBytes)
                    throw new IOException("The staged write record does not match the candidate.");
                ClearStageWrite(root, state);
            }
            return;
        }
        if (!string.IsNullOrEmpty(state.StageWriteName)
            && (state.StageWriteName != key || !state.StageWriteOldSha256.Equals(oldSha256, StringComparison.OrdinalIgnoreCase)
                || !state.StageWriteNewSha256.Equals(expectedSha256, StringComparison.OrdinalIgnoreCase)
                || state.StageWriteBytes != expectedBytes))
            throw new IOException("A different interrupted staged write was preserved.");
        if (!actual.Equals(oldSha256, StringComparison.OrdinalIgnoreCase))
            throw new IOException("A changed staged cache file was preserved: " + path);
        using var guard = OpenOldGuard(path, oldSha256);
        NativeFiles.RejectNamedStreams(path);
        if (string.IsNullOrEmpty(state.StageWriteName))
        {
            state.StageWriteName = key;
            state.StageWriteOldSha256 = oldSha256;
            state.StageWriteNewSha256 = expectedSha256;
            state.StageWriteBytes = expectedBytes;
            WriteState(root, state);
        }
        guard.Position = 0;
        guard.SetLength(0);
        using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[128 * 1024];
        long total = 0;
        while (true)
        {
            var read = input.Read(buffer, 0, buffer.Length);
            if (read == 0) break;
            total = checked(total + read);
            if (total > expectedBytes) throw new InvalidDataException("Staged cache content exceeds its confirmed size.");
            digest.AppendData(buffer, 0, read);
            guard.Write(buffer, 0, read);
        }
        guard.Flush(flushToDisk: true);
        if (total != expectedBytes || !Convert.ToHexString(digest.GetHashAndReset()).Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Staged cache content differs from the verified product.");
        NativeFiles.Verify(guard.SafeFileHandle, path);
        NativeFiles.RejectNamedStreams(path);
        ClearStageWrite(root, state);
    }

    private static void ClearStageWrite(string root, UpdateState state)
    {
        state.StageWriteName = "";
        state.StageWriteOldSha256 = "";
        state.StageWriteNewSha256 = "";
        state.StageWriteBytes = 0;
        WriteState(root, state);
    }

    internal static StageCleanupResult CleanupStage(string configPath)
    {
        var root = InstallationRoot(configPath);
        var installed = Path.Combine(root, "bin", "prunlet.exe");
        var process = Environment.ProcessPath ?? throw new IOException("Cannot identify the cleanup executable.");
        var actual = PathPolicy.Resolve(process, allowMissing: false);
        if (!actual.Equals(installed, StringComparison.Ordinal))
            throw new IOException("Stage cleanup is available only from the installed Prunlet CLI.");
        using var parents = PathPolicy.PinDirectories(root);
        using var mutexes = new InstallationMutexes(root);
        var state = ReadState(root) ?? throw new InvalidDataException("Stage cleanup has no owned update state.");
        if (state.Phase != "idle") throw new IOException("Stage cleanup is blocked while an update is active.");
        if (state.StageCleanup == "done") return new StageCleanupResult("already_cleaned");
        if (state.StageCleanup != "pending")
            throw new IOException("Stage cleanup was not prepared or its previous outcome is uncertain; it will not be retried.");
        if (!string.IsNullOrEmpty(state.CandidateCliSha256)
            && (state.CleanupCli != "done" || state.CleanupMaintenance != "done" || state.CleanupHook != "done"))
            throw new IOException("Stage cleanup is blocked while previous products still require attention.");

        var stage = Path.Combine(root, ".prunlet-update-stage");
        SafeFileHandle stageHandle;
        try { stageHandle = NativeFiles.OpenMoveMeasurement(stage); }
        catch (FileNotFoundException)
        {
            // 固定親と排他を保持したpending状態では、stage未作成を処理開始前と区別できる。
            state.StageCleanup = "done";
            WriteState(root, state);
            return new StageCleanupResult("already_cleaned");
        }
        using var stageLease = stageHandle;
        NativeFiles.Verify(stageHandle, stage, directory: true);
        VerifyStageOwner(stage, root, state.CandidateCommit);
        // rootの所有証明だけでは配下に追加された他者のファイルを区別できない。
        // 未知の内容を巻き込まないよう、所有済みの実体だけを識別できる方式が整うまで保持する。
        return new StageCleanupResult("retained", "The update stage was preserved because its complete contents cannot be proven owned.");
    }

    internal static void VerifyStageOwner(string stage, string root, string commit)
    {
        var path = Path.Combine(stage, ".prunlet-stage-owner.json");
        using var handle = NativeFiles.OpenBackup(path);
        NativeFiles.Verify(handle, path);
        NativeFiles.VerifySingleLink(handle);
        using var stream = new FileStream(handle, FileAccess.Read);
        if (stream.Length > 65536) throw new InvalidDataException("Stage owner record exceeds the supported size.");
        using var document = JsonDocument.Parse(stream);
        if (document.RootElement.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("Stage owner record must be an object.");
        var properties = document.RootElement.EnumerateObject().ToArray();
        var names = properties.Select(property => property.Name).ToHashSet(StringComparer.Ordinal);
        if (properties.Length != 5 || names.Count != 5 || !names.SetEquals(["product", "schema", "installRoot", "candidateCommit", "epoch"]))
            throw new InvalidDataException("Stage owner record has unsupported or duplicate fields.");
        var value = document.RootElement;
        if (value.GetProperty("product").GetString() != "Prunlet" || value.GetProperty("schema").GetInt32() != 1
            || value.GetProperty("epoch").GetInt32() != 1
            || !string.Equals(value.GetProperty("installRoot").GetString(), root, StringComparison.OrdinalIgnoreCase)
            || !string.Equals(value.GetProperty("candidateCommit").GetString(), commit, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Stage ownership does not match the pending update state.");
    }

    internal static string InstallationRoot(string configPath)
    {
        if (!Path.IsPathFullyQualified(configPath) || !Path.GetFileName(configPath).Equals("config.json", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("The update coordinator requires the installed config.json.");
        var config = PathPolicy.Resolve(configPath, allowMissing: false);
        var root = Path.GetDirectoryName(config) ?? throw new IOException("Cannot determine the installation root.");
        using var parents = PathPolicy.PinDirectories(root);
        using var file = NativeFiles.OpenBackup(config);
        NativeFiles.Verify(file, config);
        NativeFiles.VerifySingleLink(file);
        return root;
    }

    internal static Provenance ReadProvenance(string path)
    {
        using var handle = NativeFiles.OpenBackup(path);
        NativeFiles.Verify(handle, path);
        NativeFiles.VerifySingleLink(handle);
        using var stream = new FileStream(handle, FileAccess.Read);
        if (stream.Length > 65536) throw new InvalidDataException("Product provenance exceeds the supported size.");
        using var json = JsonDocument.Parse(stream);
        if (json.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Product provenance must be an object.");
        var commit = RequiredHex(json.RootElement, "commitSha", 40);
        var cli = RequiredHex(json.RootElement, "executableSha256", 64);
        var maintenance = RequiredHex(json.RootElement, "maintenanceExecutableSha256", 64);
        var hook = RequiredHex(json.RootElement, "hookExecutableSha256", 64);
        if (!hook.Equals(cli, StringComparison.Ordinal))
            throw new InvalidDataException("Hook product does not match the CLI executable.");
        var maps = json.RootElement.EnumerateObject().Where(property => property.NameEquals("auxiliarySha256")).ToArray();
        if (maps.Length != 1 || maps[0].Value.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("Product provenance has an invalid auxiliary hash map.");
        var entries = maps[0].Value.EnumerateObject().ToArray();
        var expectedNames = AuxiliaryProducts.Select(item => @"bin\" + item.BinName).ToHashSet(StringComparer.Ordinal);
        if (entries.Length != expectedNames.Count || !entries.Select(entry => entry.Name).ToHashSet(StringComparer.Ordinal).SetEquals(expectedNames))
            throw new InvalidDataException("Product provenance has unknown, duplicate, or missing auxiliary products.");
        var auxiliary = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var entry in entries)
        {
            if (entry.Value.ValueKind != JsonValueKind.String || !IsHex(entry.Value.GetString(), 64))
                throw new InvalidDataException("Product provenance has an invalid auxiliary hash: " + entry.Name);
            auxiliary.Add(entry.Name, entry.Value.GetString()!.ToUpperInvariant());
        }
        return new Provenance(commit, cli, maintenance, hook, auxiliary);
    }

    private static string RequiredHex(JsonElement value, string name, int length)
    {
        var fields = value.EnumerateObject().Where(property => property.NameEquals(name)).ToArray();
        if (fields.Length != 1 || fields[0].Value.ValueKind != JsonValueKind.String)
            throw new InvalidDataException($"Product provenance has an invalid {name}.");
        var text = fields[0].Value.GetString()!;
        if (text.Length != length || !text.All(Uri.IsHexDigit))
            throw new InvalidDataException($"Product provenance has an invalid {name}.");
        return text.ToUpperInvariant();
    }

    internal static void VerifyStagedProducts(string root, Provenance candidate)
    {
        var stage = Path.Combine(root, ".prunlet-update-stage");
        using var parents = PathPolicy.PinDirectories(stage);
        VerifyFileHash(Path.Combine(stage, "prunlet.exe"), candidate.CliHash);
        VerifyFileHash(Path.Combine(stage, "prunlet-maintenance.exe"), candidate.MaintenanceHash);
        VerifyFileHash(Path.Combine(stage, "prunlet-hook.exe"), candidate.HookHash);
    }

    internal static bool AuxiliaryProductsMatch(string root, Provenance candidate)
    {
        var stage = Path.Combine(root, ".prunlet-update-stage");
        using var stageIntegration = PathPolicy.PinDirectories(Path.Combine(stage, "integration"));
        using var stageScripts = PathPolicy.PinDirectories(Path.Combine(stage, "scripts"));
        using var bin = PathPolicy.PinDirectories(Path.Combine(root, "bin"));
        var matches = true;
        foreach (var product in AuxiliaryProducts)
        {
            var expected = candidate.AuxiliaryHashes[@"bin\" + product.BinName];
            VerifyFileHash(Path.Combine(stage, product.StagePath), expected);
            try
            {
                if (!HashFile(Path.Combine(root, "bin", product.BinName)).Equals(expected, StringComparison.OrdinalIgnoreCase))
                    matches = false;
            }
            catch (FileNotFoundException) { matches = false; }
        }
        return matches;
    }

    private static void VerifyCandidateProcess(string stage)
    {
        var process = Environment.ProcessPath ?? throw new IOException("Cannot identify the candidate executable.");
        if (!PathPolicy.Resolve(process, allowMissing: false).Equals(Path.Combine(stage, "prunlet.exe"), StringComparison.Ordinal))
            throw new IOException("The update coordinator must run from the fixed candidate executable.");
    }

    internal static void ApplyIntegration(string configPath)
    {
        var root = InstallationRoot(configPath);
        var stage = Path.Combine(root, ".prunlet-update-stage");
        VerifyCandidateProcess(stage);
        using var stageParents = PathPolicy.PinDirectories(stage);
        using var mutexes = new InstallationMutexes(root);
        var state = ReadState(root) ?? throw new InvalidDataException("Update state is missing.");
        if (state.Phase != "switching" || state.StageCleanup != "pending")
            throw new IOException("Auxiliary products can only be updated during switching.");
        if (!string.IsNullOrEmpty(state.AuxiliaryRotationStatus))
            throw new IOException("An uncertain auxiliary replacement was preserved; it will not be retried.");
        VerifyStageOwner(stage, root, state.CandidateCommit);
        var candidateInfo = Path.Combine(stage, "source-info.json");
        VerifyFileHash(candidateInfo, state.CandidateSourceInfoSha256);
        var candidate = ReadProvenance(candidateInfo);
        var old = ReadProvenance(Path.Combine(stage, "previous-source-info.json"));
        if (!candidate.Commit.Equals(state.CandidateCommit, StringComparison.OrdinalIgnoreCase)
            || !old.Commit.Equals(state.OldCommit, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Auxiliary provenance differs from the active update state.");
        var bin = Path.Combine(root, "bin");
        if (string.IsNullOrEmpty(state.RotationCliBackup) || string.IsNullOrEmpty(state.RotationMaintenanceBackup)
            || string.IsNullOrEmpty(state.RotationHookBackup))
            throw new IOException("Product rotation has not completed for all products.");
        using var productGuards = new OldProductGuards(bin, state.RotationCliBackup, state.RotationMaintenanceBackup, old);
        VerifyFileHash(Path.Combine(bin, "prunlet.exe"), candidate.CliHash);
        VerifyFileHash(Path.Combine(bin, "prunlet-maintenance.exe"), candidate.MaintenanceHash);
        VerifyFileHash(Path.Combine(bin, "prunlet-hook.exe"), candidate.HookHash);
        using var oldHook = OpenHookReadGuard(Path.Combine(bin, state.RotationHookBackup), old.HookHash);
        using var budgetGuards = StartupUpdateBudget.WithGuards(productGuards.Cli.SafeFileHandle,
            productGuards.Maintenance.SafeFileHandle, oldHook.SafeFileHandle);
        var previousRoot = Path.Combine(stage, "previous-auxiliary");
        try { using var existing = NativeFiles.OpenDirectory(previousRoot); NativeFiles.Verify(existing, previousRoot, directory: true); }
        catch (FileNotFoundException) { NativeFiles.CreateDirectory(previousRoot); }
        using var previousParents = PathPolicy.PinDirectories(previousRoot);
        using var binParents = PathPolicy.PinDirectories(bin);
        foreach (var item in AuxiliaryProducts)
        {
            var key = @"bin\" + item.BinName;
            var current = Path.Combine(bin, item.BinName);
            var previous = Path.Combine(previousRoot, item.BinName);
            var source = Path.Combine(stage, item.StagePath);
            var temporary = Path.Combine(bin, ".prunlet-candidate-" + item.BinName);
            var oldHash = old.AuxiliaryHashes[key];
            var newHash = candidate.AuxiliaryHashes[key];
            VerifyFileHash(source, newHash);
            var previousExists = false;
            try { using var existing = NativeFiles.OpenAny(previous); previousExists = true; }
            catch (FileNotFoundException) { }
            if (oldHash.Equals(newHash, StringComparison.OrdinalIgnoreCase))
            {
                VerifyFileHash(current, oldHash);
                continue;
            }
            if (previousExists)
            {
                var currentHash = HashFile(current);
                var previousHash = HashFile(previous);
                if (currentHash.Equals(newHash, StringComparison.OrdinalIgnoreCase)
                    && previousHash.Equals(oldHash, StringComparison.OrdinalIgnoreCase))
                {
                    using var priorGuard = OpenOldGuard(previous, oldHash);
                    if (!state.AuxiliaryBackupSha256.TryGetValue(key, out var recorded)
                        || !recorded.Equals(oldHash, StringComparison.OrdinalIgnoreCase))
                    {
                        state.AuxiliaryBackupSha256[key] = oldHash;
                        WriteState(root, state);
                    }
                    continue;
                }
                if (!currentHash.Equals(oldHash, StringComparison.OrdinalIgnoreCase)
                    || state.PriorAuxiliarySha256 is null
                    || !state.PriorAuxiliarySha256.TryGetValue(key, out var priorHash)
                    || !previousHash.Equals(priorHash, StringComparison.OrdinalIgnoreCase)
                        && !previousHash.Equals(newHash, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("An unexpected auxiliary backup was preserved: " + previous);
                using (var sourceHandle = NativeFiles.OpenBackup(source))
                using (var input = new FileStream(sourceHandle, FileAccess.Read))
                {
                    StartupUpdateBudget.Ensure(root, input.Length);
                    WriteKnownStageProduct(root, state, "previous-auxiliary/" + item.BinName, previous, input,
                        input.Length, newHash, priorHash);
                }
                NativeFiles.RejectNamedStreams(previous);
                using (var sourceHandle = NativeFiles.OpenMoveEntry(previous))
                using (var parent = NativeFiles.OpenMoveParent(bin))
                    NativeFiles.MoveNoReplace(sourceHandle, parent, Path.GetFileName(temporary));
            }
            using var guard = OpenOldGuard(current, oldHash);
            try { VerifyFileHash(temporary, newHash); }
            catch (FileNotFoundException)
            {
                using var sourceHandle = NativeFiles.OpenBackup(source);
                NativeFiles.Verify(sourceHandle, source);
                NativeFiles.VerifySingleLink(sourceHandle);
                using var input = new FileStream(sourceHandle, FileAccess.Read);
                StartupUpdateBudget.Ensure(root, input.Length);
                using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                    4096, FileOptions.WriteThrough))
                {
                    input.CopyTo(output);
                    output.Flush(flushToDisk: true);
                }
                VerifyFileHash(temporary, newHash);
            }
            NativeFiles.Verify(guard.SafeFileHandle, current);
            state.AuxiliaryRotationName = item.BinName;
            state.AuxiliaryRotationStatus = "replacing";
            state.AuxiliaryRotationOldSha256 = oldHash;
            state.AuxiliaryRotationNewSha256 = newHash;
            WriteState(root, state);
            try
            {
                File.Replace(temporary, current, previous);
                NativeFiles.Verify(guard.SafeFileHandle, previous);
                NativeFiles.VerifySingleLink(guard.SafeFileHandle);
                VerifyFileHash(current, newHash);
                guard.Dispose();
                StartupUpdateBudget.Ensure(root, 0);
                state.AuxiliaryBackupSha256[key] = oldHash;
                state.AuxiliaryRotationName = state.AuxiliaryRotationStatus = state.AuxiliaryRotationOldSha256 = state.AuxiliaryRotationNewSha256 = "";
                WriteState(root, state);
            }
            catch (Exception ex)
            {
                state.AuxiliaryRotationName = item.BinName;
                state.AuxiliaryRotationStatus = "ambiguous";
                state.AuxiliaryRotationOldSha256 = oldHash;
                state.AuxiliaryRotationNewSha256 = newHash;
                try { WriteState(root, state); }
                catch (Exception recordError) { throw new IOException("Auxiliary replacement and its ambiguous state could not be recorded; files were retained.", new AggregateException(ex, recordError)); }
                throw new IOException("Auxiliary replacement could not be verified; all files were retained.", ex);
            }
        }
        if (!AuxiliaryProductsMatch(root, candidate)) throw new IOException("Auxiliary product verification did not complete.");
    }

    internal static void ConfirmIntegration(string configPath)
    {
        var root = InstallationRoot(configPath);
        var stage = Path.Combine(root, ".prunlet-update-stage");
        VerifyCandidateProcess(stage);
        using var stageParents = PathPolicy.PinDirectories(stage);
        using var mutexes = new InstallationMutexes(root);
        var state = ReadState(root) ?? throw new InvalidDataException("Update state is missing.");
        if (state.Phase != "switching" || state.StageCleanup != "pending")
            throw new IOException("Integration confirmation requires an active product switch.");
        if (!string.IsNullOrEmpty(state.AuxiliaryRotationStatus))
            throw new IOException("An uncertain auxiliary replacement was preserved; it cannot be confirmed.");
        VerifyStageOwner(stage, root, state.CandidateCommit);
        var candidateInfo = Path.Combine(stage, "source-info.json");
        VerifyFileHash(candidateInfo, state.CandidateSourceInfoSha256);
        var candidate = ReadProvenance(candidateInfo);
        if (!candidate.Commit.Equals(state.CandidateCommit, StringComparison.OrdinalIgnoreCase)
            || !AuxiliaryProductsMatch(root, candidate))
            throw new IOException("Auxiliary products do not match the candidate.");
        state.IntegrationReady = true;
        WriteState(root, state);
    }

    internal static void VerifyFileHash(string path, string expectedHash)
    {
        if (!HashFile(path).Equals(expectedHash, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Product contents do not match the confirmed provenance: " + path);
    }

    internal static string HashFile(string path)
    {
        using var handle = NativeFiles.OpenBackup(path);
        NativeFiles.Verify(handle, path);
        NativeFiles.VerifySingleLink(handle);
        using var stream = new FileStream(handle, FileAccess.Read);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    internal static void SnapshotPreviousProvenance(string root, UpdateState? state = null)
    {
        var source = Path.Combine(root, "source-info.json");
        var destination = Path.Combine(root, ".prunlet-update-stage", "previous-source-info.json");
        using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(destination)!);
        using var handle = NativeFiles.OpenBackup(source);
        NativeFiles.Verify(handle, source);
        NativeFiles.VerifySingleLink(handle);
        using var input = new FileStream(handle, FileAccess.Read);
        if (input.Length > 65536) throw new InvalidDataException("Product provenance exceeds the supported size.");
        var sourceHash = Convert.ToHexString(SHA256.HashData(input));
        input.Position = 0;
        if (state is not null && !string.IsNullOrEmpty(state.PriorStageCommit))
        {
            StartupUpdateBudget.Ensure(root, Math.Max(0, input.Length));
            WriteStageProduct(root, state, "previous-source-info.json", destination, input, input.Length,
                sourceHash, state.PriorPreviousInfoSha256);
            return;
        }
        try { VerifyFileHash(destination, sourceHash); return; }
        catch (FileNotFoundException) { }
        // 既存名を上書きせず、書込み失敗は成功として扱わない。
        StartupUpdateBudget.Ensure(root, input.Length);
        using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None,
            4096, FileOptions.WriteThrough))
        {
            input.CopyTo(output);
            output.Flush(flushToDisk: true);
        }
        VerifyFileHash(destination, sourceHash);
        StartupUpdateBudget.Ensure(root, 0);
    }

    internal static void SwitchProduct(string root, string leaf, string candidateLeaf, string previousLeaf,
        string candidateHash, SafeFileHandle oldGuard)
    {
        var bin = Path.Combine(root, "bin");
        var current = Path.Combine(bin, leaf);
        var previous = Path.Combine(bin, previousLeaf);
        var temporary = Path.Combine(bin, candidateLeaf);
        var staged = Path.Combine(root, ".prunlet-update-stage", leaf);
        var guardedPath = NativeFiles.ResolveVerified(oldGuard);
        if (guardedPath.Equals(previous, StringComparison.Ordinal))
        {
            NativeFiles.Verify(oldGuard, previous);
            NativeFiles.VerifySingleLink(oldGuard);
            VerifyFileHash(current, candidateHash);
            return;
        }
        if (!guardedPath.Equals(current, StringComparison.Ordinal))
            throw new IOException("The old product guard no longer has an expected name: " + leaf);
        NativeFiles.Verify(oldGuard, current);
        NativeFiles.VerifySingleLink(oldGuard);
        try
        {
            using var existing = NativeFiles.OpenAny(previous);
            throw new IOException("An unexpected previous product was preserved: " + previous);
        }
        catch (FileNotFoundException) { }
        try { VerifyFileHash(temporary, candidateHash); }
        catch (FileNotFoundException)
        {
            using var sourceHandle = NativeFiles.OpenBackup(staged);
            NativeFiles.Verify(sourceHandle, staged);
            NativeFiles.VerifySingleLink(sourceHandle);
            using var source = new FileStream(sourceHandle, FileAccess.Read);
            using (var target = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                128 * 1024, FileOptions.WriteThrough))
            {
                source.CopyTo(target);
                target.Flush(flushToDisk: true);
            }
            VerifyFileHash(temporary, candidateHash);
        }
        // previousが存在しないこととguardの実体を確認した後だけ置換する。
        NativeFiles.Verify(oldGuard, current);
        File.Replace(temporary, current, previous);
        NativeFiles.Verify(oldGuard, previous);
        NativeFiles.VerifySingleLink(oldGuard);
        VerifyFileHash(current, candidateHash);
    }

    // 両旧製品のguard取得後だけswitchingを記録する。失敗時は状態を保全し旧版へ戻さない。
    internal static UpdateState SwitchProducts(string configPath)
    {
        var root = InstallationRoot(configPath);
        var stage = Path.Combine(root, ".prunlet-update-stage");
        var candidateExe = Path.Combine(stage, "prunlet.exe");
        var process = Environment.ProcessPath ?? throw new IOException("Cannot identify the candidate executable.");
        if (!PathPolicy.Resolve(process, allowMissing: false).Equals(candidateExe, StringComparison.Ordinal))
            throw new IOException("The update coordinator must run from the fixed candidate executable.");
        using var stageParents = PathPolicy.PinDirectories(stage);
        using var mutexes = new InstallationMutexes(root);
        var state = ReadState(root) ?? throw new InvalidDataException("Update preparation state is missing.");
        if (state.StageCleanup != "pending") throw new IOException("The update stage is not pending or its cleanup outcome is uncertain.");
        if (state.Phase is not ("idle" or "switching")) throw new IOException("The update is not in the product switching phase.");
        VerifyStageOwner(stage, root, state.CandidateCommit);
        var candidate = ReadProvenance(Path.Combine(stage, "source-info.json"));
        if (!candidate.Commit.Equals(state.CandidateCommit, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Candidate provenance does not match the prepared commit.");
        VerifyStagedProducts(root, candidate);

        var sourceInfo = Path.Combine(root, "source-info.json");
        var previousInfo = Path.Combine(stage, "previous-source-info.json");
        if (state.Phase == "idle") VerifyFileHash(sourceInfo, state.PreparedInstalledSourceInfoSha256);
        var old = ReadProvenance(state.Phase == "idle" ? sourceInfo : previousInfo);
        if (state.Phase == "switching")
        {
            if (!old.Commit.Equals(state.OldCommit, StringComparison.OrdinalIgnoreCase)
                || !candidate.CliHash.Equals(state.CandidateCliSha256, StringComparison.OrdinalIgnoreCase)
                || !candidate.MaintenanceHash.Equals(state.CandidateMaintenanceSha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Product provenance differs from the active update state.");
            VerifyFileHash(Path.Combine(stage, "source-info.json"), state.CandidateSourceInfoSha256);
        }

        var bin = Path.Combine(root, "bin");
        if (state.RotationStatus is "replacing" or "ambiguous")
            throw new IOException("An uncertain product replacement was preserved; it will not be retried.");
        SaveCompletedRotation(root, state);
        var oldCliName = OldGuardName(bin, "prunlet.exe", "prunlet.previous.exe", old.CliHash, candidate.CliHash, state.RotationCliBackup, state);
        var oldMaintenanceName = OldGuardName(bin, "prunlet-maintenance.exe", "prunlet-maintenance.previous.exe", old.MaintenanceHash, candidate.MaintenanceHash, state.RotationMaintenanceBackup, state);
        var oldHookName = OldGuardName(bin, "prunlet-hook.exe", "prunlet-hook.previous.exe", old.HookHash, candidate.HookHash, state.RotationHookBackup, state);
        using var oldGuards = new OldProductGuards(bin, oldCliName, oldMaintenanceName, old);
        using var hookGuard = OpenHookReadGuard(Path.Combine(bin, oldHookName), old.HookHash);
        using var budgetGuards = StartupUpdateBudget.WithGuards(oldGuards.Cli.SafeFileHandle,
            oldGuards.Maintenance.SafeFileHandle, hookGuard.SafeFileHandle);
        if (state.Phase == "idle")
        {
            try
            {
                NativeFiles.RejectNamedStreams(Path.Combine(bin, oldCliName));
                NativeFiles.RejectNamedStreams(Path.Combine(bin, oldMaintenanceName));
                NativeFiles.RejectNamedStreams(Path.Combine(bin, oldHookName));
                NativeFiles.RejectNamedStreams(sourceInfo);
                foreach (var product in AuxiliaryProducts)
                    NativeFiles.RejectNamedStreams(Path.Combine(bin, product.BinName));
            }
            catch (IOException ex)
            {
                throw new UpdateDeferredException("A current product has named streams or cannot be inspected; all products were retained. " + ex.Message);
            }
            SnapshotPreviousProvenance(root, state);
            state.OldCommit = old.Commit;
            state.CandidateCommit = candidate.Commit;
            state.CandidateCliSha256 = candidate.CliHash;
            state.CandidateMaintenanceSha256 = candidate.MaintenanceHash;
            state.CandidateSourceInfoSha256 = HashFile(Path.Combine(stage, "source-info.json"));
            state.CleanupCli = state.CleanupMaintenance = state.CleanupHook = "pending";
            state.IntegrationReady = false;
            state.MigrationComplete = false;
            state.MigrationFileComplete = null;
            state.Phase = "switching";
            WriteState(root, state);
        }
        RotateProduct(root, state, "prunlet.exe", old.CliHash, candidate.CliHash, state.PriorCliSha256, oldGuards.Cli.SafeFileHandle);
        RotateProduct(root, state, "prunlet-maintenance.exe", old.MaintenanceHash, candidate.MaintenanceHash, state.PriorMaintenanceSha256, oldGuards.Maintenance.SafeFileHandle);
        RotateProduct(root, state, "prunlet-hook.exe", old.HookHash, candidate.HookHash, state.PriorHookSha256, hookGuard.SafeFileHandle);
        return state;
    }

    private static string OldGuardName(string bin, string current, string previous, string oldHash, string newHash,
        string savedBackup, UpdateState state)
    {
        if (!string.IsNullOrEmpty(savedBackup)) return savedBackup;
        if (state.Phase == "idle")
        {
            return current;
        }
        var currentHash = HashFile(Path.Combine(bin, current));
        var selected = state.RotationName == current && !string.IsNullOrEmpty(state.RotationBackupName)
            ? state.RotationBackupName : previous;
        if (currentHash.Equals(newHash, StringComparison.OrdinalIgnoreCase)
            && (!currentHash.Equals(oldHash, StringComparison.OrdinalIgnoreCase)
                || state.RotationName == current && state.RotationStatus is "candidate_named" or "switched"))
        {
            try { VerifyFileHash(Path.Combine(bin, selected), oldHash); return selected; }
            catch (FileNotFoundException) { }
        }
        if (currentHash.Equals(oldHash, StringComparison.OrdinalIgnoreCase)) return current;
        throw new IOException("The installed product does not match a recoverable rotation state: " + current);
    }

    private static void RotateProduct(string root, UpdateState state, string leaf, string currentHash,
        string candidateHash, string priorHash, SafeFileHandle guard)
    {
        var saved = leaf switch
        {
            "prunlet.exe" => state.RotationCliBackup,
            "prunlet-maintenance.exe" => state.RotationMaintenanceBackup,
            "prunlet-hook.exe" => state.RotationHookBackup,
            _ => throw new ArgumentException("Unknown rotation product.")
        };
        if (!string.IsNullOrEmpty(saved))
        {
            NativeFiles.Verify(guard, Path.Combine(root, "bin", saved));
            VerifyFileHash(Path.Combine(root, "bin", leaf), candidateHash);
            return;
        }
        var stem = leaf[..^4];
        StartupUpdateRotation.Rotate(root, leaf, stem + ".candidate.exe", stem + ".previous.exe", leaf,
            currentHash, candidateHash, string.IsNullOrEmpty(priorHash) ? null : priorHash, guard, state);
        SaveCompletedRotation(root, state);
    }

    private static void SaveCompletedRotation(string root, UpdateState state)
    {
        if (state.RotationStatus != "switched") return;
        switch (state.RotationName)
        {
            case "prunlet.exe": state.RotationCliBackup = state.RotationBackupName; break;
            case "prunlet-maintenance.exe": state.RotationMaintenanceBackup = state.RotationBackupName; break;
            case "prunlet-hook.exe": state.RotationHookBackup = state.RotationBackupName; break;
            default: throw new InvalidDataException("Unknown completed rotation product.");
        }
        state.RotationName = state.RotationStatus = state.RotationPriorSha256 = state.RotationCandidateSha256 = state.RotationBackupName = "";
        WriteState(root, state);
    }

    internal sealed record MigrationOutcome(bool RegistryReady, bool? FileComplete, string[] Warnings);

    internal sealed record ApplyOutcome(string Status, string Phase, bool? RegistryReady = null,
        bool? FileComplete = null, string[]? Warnings = null);

    internal static ApplyOutcome Apply(string configPath)
    {
        var root = InstallationRoot(configPath);
        var initial = ReadState(root) ?? throw new InvalidDataException("Update preparation state is missing.");
        if (initial.Phase == "idle" && !string.IsNullOrEmpty(initial.CandidateCliSha256))
        {
            var cleanup = CleanupPreviousProducts(configPath);
            return new ApplyOutcome(cleanup.Status, "idle", RegistryReady: true, Warnings: cleanup.Warnings);
        }
        try
        {
            if (initial.Phase is "idle" or "switching") initial = SwitchProducts(configPath);
        }
        catch (OldProductInUseException ex)
        {
            var current = ReadState(root);
            return new ApplyOutcome("deferred", current?.Phase ?? "idle", Warnings: [ex.Message]);
        }
        catch (UpdateInProgressException ex)
        {
            var current = ReadState(root);
            return new ApplyOutcome("deferred", current?.Phase ?? "idle", Warnings: [ex.Message]);
        }
        catch (UpdateDeferredException ex)
        {
            var current = ReadState(root);
            return new ApplyOutcome("deferred", current?.Phase ?? "idle", Warnings: [ex.Message]);
        }
        if (initial.Phase is not ("switching" or "migrating"))
            throw new IOException("The update is not in a resumable phase.");
        var candidate = ReadProvenance(Path.Combine(root, ".prunlet-update-stage", "source-info.json"));
        if (!initial.IntegrationReady || !AuxiliaryProductsMatch(root, candidate))
            return new ApplyOutcome("integration_required", initial.Phase, RegistryReady: false);
        var migration = MigrateAndFinalize(configPath);
        var previous = CleanupPreviousProducts(configPath);
        return new ApplyOutcome(previous.Status, "idle", migration.RegistryReady, migration.FileComplete,
            migration.Warnings.Concat(previous.Warnings).ToArray());
    }

    // 呼出し元は先に固定auxiliary製品と登録の照合を完了する。
    internal static MigrationOutcome MigrateAndFinalize(string configPath)
    {
        var root = InstallationRoot(configPath);
        var stage = Path.Combine(root, ".prunlet-update-stage");
        var process = Environment.ProcessPath ?? throw new IOException("Cannot identify the candidate executable.");
        if (!PathPolicy.Resolve(process, allowMissing: false).Equals(Path.Combine(stage, "prunlet.exe"), StringComparison.Ordinal))
            throw new IOException("The update coordinator must run from the fixed candidate executable.");
        using var stageParents = PathPolicy.PinDirectories(stage);
        using var mutexes = new InstallationMutexes(root);
        var state = ReadState(root) ?? throw new InvalidDataException("Update state is missing.");
        if (state.Phase is not ("switching" or "migrating") || state.StageCleanup != "pending")
            throw new IOException("The update is not ready for recovery migration.");
        VerifyStageOwner(stage, root, state.CandidateCommit);
        var candidateInfo = Path.Combine(stage, "source-info.json");
        var previousInfo = Path.Combine(stage, "previous-source-info.json");
        var candidate = ReadProvenance(candidateInfo);
        var old = ReadProvenance(previousInfo);
        if (!candidate.Commit.Equals(state.CandidateCommit, StringComparison.OrdinalIgnoreCase)
            || !old.Commit.Equals(state.OldCommit, StringComparison.OrdinalIgnoreCase)
            || !candidate.CliHash.Equals(state.CandidateCliSha256, StringComparison.OrdinalIgnoreCase)
            || !candidate.MaintenanceHash.Equals(state.CandidateMaintenanceSha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Product provenance differs from the active update state.");
        VerifyFileHash(candidateInfo, state.CandidateSourceInfoSha256);
        VerifyStagedProducts(root, candidate);
        if (!state.IntegrationReady || !string.IsNullOrEmpty(state.AuxiliaryRotationStatus) || !AuxiliaryProductsMatch(root, candidate))
            throw new IOException("Auxiliary products or their registration have not been confirmed.");
        var bin = Path.Combine(root, "bin");
        if (string.IsNullOrEmpty(state.RotationCliBackup) || string.IsNullOrEmpty(state.RotationMaintenanceBackup)
            || string.IsNullOrEmpty(state.RotationHookBackup))
            throw new IOException("Product rotation has not completed for all products.");
        using var guards = new OldProductGuards(bin, state.RotationCliBackup, state.RotationMaintenanceBackup, old);
        VerifyFileHash(Path.Combine(bin, "prunlet.exe"), candidate.CliHash);
        VerifyFileHash(Path.Combine(bin, "prunlet-maintenance.exe"), candidate.MaintenanceHash);
        VerifyFileHash(Path.Combine(bin, "prunlet-hook.exe"), candidate.HookHash);
        using var hook = OpenHookReadGuard(Path.Combine(bin, state.RotationHookBackup), old.HookHash);
        using var budgetGuards = StartupUpdateBudget.WithGuards(guards.Cli.SafeFileHandle,
            guards.Maintenance.SafeFileHandle, hook.SafeFileHandle);
        var installedInfo = Path.Combine(root, "source-info.json");
        var previousInfoHash = HashFile(previousInfo);
        string? installedInfoHash;
        try { installedInfoHash = HashFile(installedInfo); }
        catch (FileNotFoundException) { installedInfoHash = null; }
        var alreadyCommitted = string.Equals(installedInfoHash, state.CandidateSourceInfoSha256, StringComparison.OrdinalIgnoreCase);
        string[] warnings = [];
        if (!state.MigrationComplete)
        {
            if (!string.Equals(installedInfoHash, previousInfoHash, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Migration completion is not recorded and installed provenance is not the old provenance; all state was preserved.");
            var service = new DeletionService(PrunletConfig.Load(configPath));
            if (state.Phase == "switching")
            {
                state.Phase = "migrating";
                WriteState(root, state);
            }
            var migration = service.MigrateRecoveryStorage(apply: true, ifNeeded: true);
            if (!migration.RegistryReady) throw new IOException("Registry recovery migration is not ready; the candidate and state were preserved.");
            warnings = migration.Warnings.ToArray();
            state.MigrationComplete = true;
            state.MigrationFileComplete = migration.Complete;
            WriteState(root, state);
        }
        if (state.Phase != "migrating") throw new IOException("Candidate provenance cannot be committed outside migration.");
        if (!alreadyCommitted && installedInfoHash is not null
            && !installedInfoHash.Equals(previousInfoHash, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Installed provenance differs from both the old and candidate provenance.");
        CommitCandidateProvenance(root, candidateInfo, state.CandidateSourceInfoSha256, previousInfoHash, installedInfoHash, state);
        state.Phase = "idle";
        WriteState(root, state);
        return new MigrationOutcome(true, state.MigrationFileComplete, warnings);
    }

    private static void CommitCandidateProvenance(string root, string source, string candidateHash, string oldHash, string? installedHash,
        UpdateState state)
    {
        var destination = Path.Combine(root, "source-info.json");
        var temporary = Path.Combine(root, "source-info.candidate.json");
        var backup = Path.Combine(root, ".prunlet-update-stage", "previous-source-info-original.json");
        string? backupHash;
        try { backupHash = HashFile(backup); }
        catch (FileNotFoundException) { backupHash = null; }
        if (installedHash is not null && installedHash.Equals(oldHash, StringComparison.OrdinalIgnoreCase)
            && backupHash is not null && !string.IsNullOrEmpty(state.PriorStageCommit)
            && (backupHash.Equals(state.PriorPreviousInfoSha256, StringComparison.OrdinalIgnoreCase)
                || backupHash.Equals(candidateHash, StringComparison.OrdinalIgnoreCase)))
        {
            var sourceBytes = new FileInfo(source).Length;
            StartupUpdateBudget.Ensure(root, sourceBytes);
            using (var handle = NativeFiles.OpenBackup(source))
            using (var input = new FileStream(handle, FileAccess.Read))
                WriteKnownStageProduct(root, state, "previous-source-info-original.json", backup, input,
                    input.Length, candidateHash, state.PriorPreviousInfoSha256);
            NativeFiles.RejectNamedStreams(backup);
            using (var original = NativeFiles.OpenMoveEntry(backup))
            using (var parent = NativeFiles.OpenMoveParent(root))
                NativeFiles.MoveNoReplace(original, parent, Path.GetFileName(temporary));
            backupHash = null;
        }
        if (backupHash is not null && !backupHash.Equals(oldHash, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Original provenance backup differs from the old provenance and was preserved.");
        if (string.Equals(installedHash, candidateHash, StringComparison.OrdinalIgnoreCase))
        {
            if (backupHash is null) throw new IOException("Candidate provenance lacks its original backup; all files were preserved.");
            return;
        }
        if (installedHash is null && backupHash is null)
            throw new IOException("Installed provenance and its original backup are both missing; all files were preserved.");
        if (installedHash is not null && backupHash is not null)
            throw new IOException("An unexpected original provenance backup was preserved.");
        try { VerifyFileHash(temporary, candidateHash); }
        catch (FileNotFoundException)
        {
            using var handle = NativeFiles.OpenBackup(source);
            NativeFiles.Verify(handle, source);
            NativeFiles.VerifySingleLink(handle);
            using var input = new FileStream(handle, FileAccess.Read);
            StartupUpdateBudget.Ensure(root, input.Length);
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                4096, FileOptions.WriteThrough))
            {
                input.CopyTo(output);
                output.Flush(flushToDisk: true);
            }
            VerifyFileHash(temporary, candidateHash);
        }
        if (installedHash is null) File.Move(temporary, destination);
        else File.Replace(temporary, destination, backup);
        VerifyFileHash(destination, candidateHash);
        StartupUpdateBudget.Ensure(root, 0);
    }

    internal sealed record PreviousCleanupOutcome(string Status, string[] Warnings);

    internal static PreviousCleanupOutcome CleanupPreviousProducts(string configPath)
    {
        var root = InstallationRoot(configPath);
        var stage = Path.Combine(root, ".prunlet-update-stage");
        var process = Environment.ProcessPath ?? throw new IOException("Cannot identify the candidate executable.");
        if (!PathPolicy.Resolve(process, allowMissing: false).Equals(Path.Combine(stage, "prunlet.exe"), StringComparison.Ordinal))
            throw new IOException("Previous-product cleanup must run from the fixed candidate executable.");
        using var stageParents = PathPolicy.PinDirectories(stage);
        using var mutexes = new InstallationMutexes(root);
        var state = ReadState(root) ?? throw new InvalidDataException("Update state is missing.");
        if (state.Phase != "idle" || state.StageCleanup != "pending")
            throw new IOException("Previous-product cleanup is not ready.");
        VerifyStageOwner(stage, root, state.CandidateCommit);
        var candidate = ReadProvenance(Path.Combine(root, "source-info.json"));
        var old = ReadProvenance(Path.Combine(stage, "previous-source-info.json"));
        if (!candidate.Commit.Equals(state.CandidateCommit, StringComparison.OrdinalIgnoreCase)
            || !old.Commit.Equals(state.OldCommit, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Product provenance differs from the active update state.");
        VerifyFileHash(Path.Combine(root, "source-info.json"), state.CandidateSourceInfoSha256);
        var service = new DeletionService(PrunletConfig.Load(configPath));
        var warnings = new List<string>();
        if (state.RotationCliBackup != "prunlet.previous.exe") warnings.Add("An unusual CLI backup was retained: " + state.RotationCliBackup);
        if (state.RotationMaintenanceBackup != "prunlet-maintenance.previous.exe") warnings.Add("An unusual maintenance backup was retained: " + state.RotationMaintenanceBackup);
        if (state.RotationHookBackup != "prunlet-hook.previous.exe") warnings.Add("An unusual hook backup was retained: " + state.RotationHookBackup);
        CleanupPrevious(root, state, service, "prunlet.previous.exe", old.CliHash,
            () => state.CleanupCli, value => state.CleanupCli = value, warnings);
        CleanupPrevious(root, state, service, "prunlet-maintenance.previous.exe", old.MaintenanceHash,
            () => state.CleanupMaintenance, value => state.CleanupMaintenance = value, warnings);
        CleanupPrevious(root, state, service, "prunlet-hook.previous.exe", old.HookHash,
            () => state.CleanupHook, value => state.CleanupHook = value, warnings);
        var outcomes = new[] { state.CleanupCli, state.CleanupMaintenance, state.CleanupHook };
        var status = outcomes.Contains("attempting", StringComparer.Ordinal) ? "ambiguous"
            : outcomes.Contains("pending", StringComparer.Ordinal) ? "cleanup_pending" : "updated";
        return new PreviousCleanupOutcome(status, warnings.ToArray());
    }

    private static void CleanupPrevious(string root, UpdateState state, DeletionService service, string name, string hash,
        Func<string> getStatus, Action<string> setStatus, List<string> warnings)
    {
        if (getStatus() == "done") return;
        if (getStatus() == "attempting")
        {
            warnings.Add("An earlier cleanup outcome is uncertain and will not be retried: " + name);
            return;
        }
        // 別ストリームを含む内容の所有を確認できないため、旧製品も自動清掃しない。
        warnings.Add("Previous product was retained until its complete contents can be proven owned: " + name);
    }

    // 旧プロセスが実行中なら書込みguardを取得できない。名前の置換中も同じ実体を保持する。
    internal static FileStream OpenOldGuard(string path, string expectedHash)
    {
        var handle = CreateFileW(@"\\?\" + PathPolicy.FileSystemAbsolute(path), GenericReadWrite, ShareReadDelete,
            IntPtr.Zero, OpenExisting, OpenReparsePoint, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            if (error == SharingViolation) throw new OldProductInUseException(path);
            throw new IOException($"Cannot guard old product {path} (Win32 {error}).");
        }
        try
        {
            NativeFiles.Verify(handle, path);
            NativeFiles.VerifySingleLink(handle);
            var stream = new FileStream(handle, FileAccess.ReadWrite);
            var actual = Convert.ToHexString(SHA256.HashData(stream));
            if (!actual.Equals(expectedHash, StringComparison.OrdinalIgnoreCase))
            {
                stream.Dispose();
                throw new InvalidDataException("Old product contents do not match installed provenance: " + path);
            }
            stream.Position = 0;
            return stream;
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    // hookの短時間実行を妨げず旧実体を保持し、切替後のpreviousを同じhandleで確認する。
    internal static FileStream OpenHookReadGuard(string path, string expectedHash)
    {
        var handle = NativeFiles.OpenHardlinkReadGuard(path);
        try
        {
            NativeFiles.Verify(handle, path);
            NativeFiles.VerifySingleLink(handle);
            var stream = new FileStream(handle, FileAccess.Read);
            if (!Convert.ToHexString(SHA256.HashData(stream)).Equals(expectedHash, StringComparison.OrdinalIgnoreCase))
            {
                stream.Dispose();
                throw new InvalidDataException("Old hook contents do not match installed provenance: " + path);
            }
            stream.Position = 0;
            return stream;
        }
        catch { handle.Dispose(); throw; }
    }

    internal sealed class OldProductInUseException(string path) : IOException("Old product is in use: " + path);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint desiredAccess, uint shareMode,
        IntPtr securityAttributes, uint creationDisposition, uint flags, IntPtr template);
}
