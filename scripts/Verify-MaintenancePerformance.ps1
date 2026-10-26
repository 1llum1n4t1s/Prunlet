# 想定する失敗: 出力先の既存データ/リンクへの侵入、別版・別記録での比較、CLI失敗/timeout、
# dry-run/通常保守による旧記録変更・走査、明示移行による既存ゴミ箱実体消失、
# Windows Bin移動後の内容/File ID/属性/ADSの欠落、未計測CPUの成功扱い。
# 固定の性能閾値は設けず、保守CLIの比較からログオン全体の改善を断定しない。
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$BaselineExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [ValidateRange(1, 100000)][int]$FileCount = 8192,
    [ValidateRange(1, 20)][int]$Iterations = 3
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
foreach ($path in @($ExecutablePath, $BaselineExecutablePath, $OutputDirectory, $ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'All paths must be absolute.' }
}
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
$BaselineExecutablePath = [IO.Path]::GetFullPath($BaselineExecutablePath)
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
foreach ($path in @($outputRoot, $ReportPath)) {
    Assert-VerificationDestination $path @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
    if (![IO.Path]::GetPathRoot($path).Equals('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'External D: output required.' }
    if (Test-Path -LiteralPath $path) { throw 'Output and report must be new.' }
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { throw 'Create output/report parents first.' }
}
# CMDへ渡す制御用パスはASCIIの安全な文字に限定する。fixture名はpaths-fileだけに入れる。
foreach ($path in @($ExecutablePath, $BaselineExecutablePath, $outputRoot, $ReportPath)) {
    if ($path -cnotmatch '^[A-Za-z]:\\[A-Za-z0-9_ .\\-]+$') { throw 'CMD control paths require safe ASCII characters.' }
}
foreach ($path in @($ExecutablePath, $BaselineExecutablePath)) {
    Assert-VerificationDestination $path @()
    if (![IO.File]::Exists($path)) { throw "Executable missing: $path" }
}
$baselineVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($BaselineExecutablePath).ProductVersion
if ($baselineVersion -notmatch '^1\.0\.15(?:[.+-]|$)') { throw "Expected genuine 1.0.15 baseline; found $baselineVersion" }
if ((Get-FileHash -LiteralPath $ExecutablePath).Hash -eq (Get-FileHash -LiteralPath $BaselineExecutablePath).Hash) { throw 'Executables must differ.' }
$null = [IO.Directory]::CreateDirectory($outputRoot)
$utf8 = [Text.UTF8Encoding]::new($false)
$tempRoot = Join-Path $outputRoot 'temp'
$runtimeRoot = Join-Path $outputRoot 'runtime-cache'
foreach ($path in @($tempRoot, $runtimeRoot)) { $null = [IO.Directory]::CreateDirectory($path) }
$configPath = Join-Path $outputRoot 'config.json'
$metadata = Join-Path $outputRoot 'metadata'
$tree = Join-Path $outputRoot 'tree 空白'
$results = [Collections.Generic.List[object]]::new()
$timings = [Collections.Generic.List[object]]::new()
$calls = [Collections.Generic.List[object]]::new()
$binPaths = [Collections.Generic.List[string]]::new()
function Assert-True([bool]$Value, [string]$Message) { if (!$Value) { throw $Message } }
function Save-Json([string]$Path, $Value) { [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 80), $utf8) }
function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 80 }
function Digest([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
$previousTemp = $env:TEMP; $previousTmp = $env:TMP
try {
    $env:TEMP = $tempRoot; $env:TMP = $tempRoot
    . (Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1')
    $helperFiles = @('NativeShellFixture.cs', 'FixtureNative.cs', 'OwnedBinLocator.cs', 'PermissionFixture.cs') | ForEach-Object { Join-Path (Join-Path $PSScriptRoot 'recordless-e2e') $_ }
    Add-Type -Path $helperFiles -CompilerOptions '/unsafe'
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class PrunletMaintenanceEvidence {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFileW(string p,uint a,uint s,IntPtr sa,uint d,uint f,IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle h,int k,byte[] b,uint n);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetKernelObjectSecurity(SafeFileHandle h,uint i,byte[] b,uint n,out uint need);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateJobObjectW(IntPtr a,string n);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(SafeFileHandle j,IntPtr p);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(SafeFileHandle j,int c,out Accounting a,uint n,IntPtr r);
    [StructLayout(LayoutKind.Sequential)] struct Accounting { public long User,Kernel,PeriodUser,PeriodKernel; public uint Faults,Total,Active,Terminated; }
    public static string[] Snapshot(string p) {
        using(var h=CreateFileW(p,0x20080,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
            if(h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            byte[] id=new byte[24]; if(!GetFileInformationByHandleEx(h,18,id,24)) throw new Win32Exception(Marshal.GetLastWin32Error());
            uint n; bool measured=GetKernelObjectSecurity(h,7,null,0,out n); int e=Marshal.GetLastWin32Error();
            if((!measured&&e!=122)||n<20||n>1048576) throw new Win32Exception(e);
            byte[] security=new byte[n]; if(!GetKernelObjectSecurity(h,7,security,n,out n)) throw new Win32Exception(Marshal.GetLastWin32Error());
            Array.Resize(ref security,(int)n); return new[]{Convert.ToHexString(id),Convert.ToBase64String(security)};
        }
    }
    public static SafeFileHandle Bind(IntPtr process) {
        var job=CreateJobObjectW(IntPtr.Zero,null);
        if(job.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        if(!AssignProcessToJobObject(job,process)) { int e=Marshal.GetLastWin32Error(); job.Dispose(); throw new Win32Exception(e); } return job;
    }
    public static double CpuMilliseconds(SafeFileHandle job) {
        Accounting a; if(!QueryInformationJobObject(job,1,out a,(uint)Marshal.SizeOf<Accounting>(),IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return (a.User+a.Kernel)/10000.0;
    }
}
'@
} finally { $env:TEMP = $previousTemp; $env:TMP = $previousTmp }
function Invoke-Cli([string[]]$CliArguments, [string]$Exe = $ExecutablePath) {
    foreach ($argument in $CliArguments) { if ($argument -cnotmatch '^[A-Za-z0-9_ .:\\-]+$') { throw 'Unsafe CMD argument.' } }
    $prefix = Join-Path $outputRoot ('call-' + $calls.Count.ToString('000'))
    $stdoutPath = "$prefix.stdout.json"; $stderrPath = "$prefix.stderr.txt"
    $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\cmd.exe'))
    $info.Arguments = '/d /q'; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.WorkingDirectory = $outputRoot
    $info.Environment['TEMP'] = $tempRoot; $info.Environment['TMP'] = $tempRoot
    $info.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = $runtimeRoot
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info; $job = $null; $child = $null
    try {
        $null = $process.Start()
        $shellOut = $process.StandardOutput.ReadToEndAsync(); $shellErr = $process.StandardError.ReadToEndAsync()
        # stdin投入前にJobへ割当て、CLI子プロセスの終了後もCPU集計を失わない。
        $job = [PrunletMaintenanceEvidence]::Bind($process.Handle)
        $quoted = @(@('--config', $configPath) + $CliArguments | ForEach-Object { '"' + $_ + '"' })
        $command = '@"' + $Exe + '" ' + ($quoted -join ' ') + ' 1>"' + $stdoutPath + '" 2>"' + $stderrPath + '"'
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $process.StandardInput.WriteLine($command)
        $process.StandardInput.WriteLine('exit %errorlevel%'); $process.StandardInput.Close()
        while (!$child -and !$process.HasExited -and $timer.ElapsedMilliseconds -lt 5000) {
            $child = [Prunlet.RecordlessE2E.PermissionFixture]::FindChild($process.Id, $Exe)
            if (!$child) { [Threading.Thread]::Sleep(2) }
        }
        if (!$process.WaitForExit(600000)) { $process.Kill($true); $process.WaitForExit(); throw "CLI timeout: $CliArguments" }
        $timer.Stop()
        $out = [IO.File]::ReadAllText($stdoutPath, $utf8); $err = [IO.File]::ReadAllText($stderrPath, $utf8)
        $call = @{ executable = $Exe; arguments = $CliArguments; exitCode = $process.ExitCode; elapsedMilliseconds = $timer.Elapsed.TotalMilliseconds
            cpuMilliseconds = $(if ($child) { $child.TotalProcessorTime.TotalMilliseconds } else { $null }); cpuVerified = ($null -ne $child); actualCliPid = $(if ($child) { $child.Id } else { $null }); cpuScope = 'Actual CLI TotalProcessorTime'; jobCpuMilliseconds = [PrunletMaintenanceEvidence]::CpuMilliseconds($job); stdoutPath = $stdoutPath; stderrPath = $stderrPath
            shellStdout = $shellOut.GetAwaiter().GetResult(); shellStderr = $shellErr.GetAwaiter().GetResult() }
        $calls.Add($call)
        $json = $null; try { $json = $out | ConvertFrom-Json -AsHashtable -Depth 80 } catch { }
        return @{ ExitCode = $process.ExitCode; Json = $json; Stdout = $out; Stderr = $err; Measurement = $call }
    } finally {
        if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        if ($child) { $child.Dispose() }; if ($job) { $job.Dispose() }; $process.Dispose()
    }
}
function Snapshot-Tree([string]$Root) {
    $entries = @((Get-Item -LiteralPath $Root -Force)) + @(Get-ChildItem -LiteralPath $Root -Recurse -Force)
    $snapshot = foreach ($entry in $entries) {
        Assert-True (!($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Fixture unexpectedly contains a reparse point.'
        $native = [PrunletMaintenanceEvidence]::Snapshot($entry.FullName)
        @{ relative = $entry.FullName.Substring($Root.Length); identity = $native[0]; securityBase64 = $native[1]
            attributes = [int]$entry.Attributes; hash = $(if (!$entry.PSIsContainer) { Digest $entry.FullName } else { $null }) }
    }
    return ,@($snapshot | Sort-Object relative)
}
function Snapshot-Hashes([string]$Root) {
    $hashes = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.json' | Sort-Object FullName) { $hashes[$file.FullName.Substring($Root.Length)] = Digest $file.FullName }
    return (ConvertTo-Json -InputObject $hashes -Compress)
}
function Assert-Call($Call, [string]$Context) { Assert-True ($Call.ExitCode -eq 0 -and $null -ne $Call.Json) "$Context failed: $($Call.Stdout) $($Call.Stderr)" }
function Delete-Tree([string]$Path, [string]$Producer = $ExecutablePath) {
    $list = Join-Path $outputRoot ('paths-' + [guid]::NewGuid().ToString('N') + '.json')
    Save-Json $list @($Path)
    $deleted = Invoke-Cli @('delete', '--recursive', '--paths-file', $list) $Producer
    Assert-Call $deleted 'Delete'
    Assert-True ($deleted.Json.items.Count -eq 1 -and $deleted.Json.items[0].path -ceq $Path -and $deleted.Json.items[0].status -eq 'deleted' -and !(Test-Path -LiteralPath $Path)) 'Delete did not confirm this fixture.'
    $deletedReceipt = Read-Json (Join-Path (Resolve-VerificationOperationDirectory $metadata $deleted.Json.operationId) 'recycle-0000-complete.json')
    $binPaths.Add($deletedReceipt.physicalPath)
    return $deleted.Json.operationId
}
function Median($Values) { $sorted = @($Values | Sort-Object); $n = $sorted.Count; if ($n % 2) { return $sorted[[int][Math]::Floor($n / 2)] }; return ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2 }
# 共通のnative snapshotでdata/全ADS/ID/属性/ACLを検査する。Windows Bin移動時の実ACLはWindowsに任せる。
function Assert-R([bool]$Value, [string]$Message) { Assert-True $Value $Message }
$script:observed = @{}
function Add-Timing([string]$Variant, [int]$Iteration, $Call, [string]$Layout) {
    $diagnostic = $Variant -ceq 'baseline-legacy-diagnostic'
    if ($diagnostic) {
        $j = $Call.Json
        Assert-True ($Call.ExitCode -eq 1 -and $null -ne $j -and !$Call.Stderr.Trim()) 'Baseline expected namespace incompatibility response missing.'
        $keys = @('dryRun','retentionDays','maxRecoveryBytes','retainedBytesBefore','retainedBytesAfter','purgedBytes','plannedPurgeBytes','capacityKnown','budgetSatisfied','complete','historyCompaction','operations','warnings')
        Assert-True ((@($j.Keys | Sort-Object) -join '|') -ceq (@($keys | Sort-Object) -join '|')) 'Unexpected baseline DTO fields.'
        Assert-True ($j.dryRun -and !$j.complete -and $j.capacityKnown -and $j.budgetSatisfied -and $j.retainedBytesBefore -eq $j.retainedBytesAfter -and $j.purgedBytes -eq 0 -and $j.plannedPurgeBytes -eq 0 -and @($j.operations).Count -eq 0) 'Baseline incompatibility changed maintenance semantics.'
        Assert-True (@($j.warnings).Count -eq 1 -and $j.warnings[0] -ceq 'Unknown recovery member .registry-records-v1 was retained and counted against the budget.') 'Unexpected baseline top-level warning.'
        $h = $j.historyCompaction
        Assert-True ((@($h.Keys | Sort-Object) -join '|') -ceq 'dryRun|operations|warnings') 'Unexpected baseline history DTO fields.'
        Assert-True ($h.dryRun -and @($h.operations).Count -eq 1 -and @($h.warnings).Count -eq 2) 'Unexpected baseline history shape.'
        $o = $h.operations[0]
        Assert-True ((@($o.Keys | Sort-Object) -join '|') -ceq 'error|files|operationId|status') 'Unexpected baseline history operation fields.'
        Assert-True ($o.operationId -ceq $operationId -and $o.status -ceq 'retained' -and $null -eq $o.error -and @($o.files).Count -eq 0) 'Baseline did not retain this exact record.'
        $expectedWarnings = @('Unknown recovery member was retained: .registry-records-v1', ('Recycle Bin history operation ' + $operationId + ' was retained; schema 6 receipts remain available for reconciliation.'))
        Assert-True (($h.warnings -join '|') -ceq ($expectedWarnings -join '|')) 'Unexpected baseline history warning.'
    } else { Assert-Call $Call "$Variant maintain dry-run" }
    Assert-True $Call.Measurement.cpuVerified 'Actual CLI TotalProcessorTime was not captured.'
    $timings.Add(@{ variant = $Variant; layout = $Layout; operationId = $operationId; iteration = $Iteration
        elapsedMilliseconds = $Call.Measurement.elapsedMilliseconds; cpuMilliseconds = $Call.Measurement.cpuMilliseconds
        diagnosticOnly = $diagnostic; normalSuccess = !$diagnostic; output = $Call.Json; process = $Call.Measurement })
}
try {
    $null = [IO.Directory]::CreateDirectory($metadata)
    Assert-Call (Invoke-Cli @('init', '--backup-directory', $metadata) $BaselineExecutablePath) 'Baseline init'
    $config = Read-Json $configPath
    $config.volumeRecoveryDirectories = @{ 'D:\' = (Join-Path $outputRoot 'volume-store') }
    Save-Json $configPath $config
    # 旧file記録を作る前に空のregistry領域を正規初期化し、通常保守の実行条件を揃える。
    $ready = Invoke-Cli @('migrate', '--apply'); Assert-Call $ready 'Empty registry readiness initialization'
    Assert-True ($ready.Json.registryReady -and $ready.Json.complete) 'Empty registry was not initialized.'
    $null = [IO.Directory]::CreateDirectory($tree)
    for ($i = 0; $i -lt $FileCount; $i++) { [IO.File]::WriteAllText((Join-Path $tree ('file-{0:000000}.txt' -f $i)), "Prunlet maintenance fixture $i", $utf8) }
    [IO.File]::WriteAllText((Join-Path $tree 'file-000000.txt') + ':maintenance-stream', 'owned alternate stream', $utf8)
    $before = Snapshot-R $tree; Save-Json (Join-Path $outputRoot 'before.json') $before
    $operationId = Delete-Tree $tree $BaselineExecutablePath
    $operationRoot = Resolve-VerificationOperationDirectory $metadata $operationId
    $manifest = Read-Json (Join-Path $operationRoot 'recycle-manifest.json')
    $receipt = Read-Json (Join-Path $operationRoot 'recycle-0000-complete.json')
    Assert-True ($manifest.schema -eq 6 -and $manifest.entries.Count -eq 1 -and $manifest.entries[0].path -ceq $tree) 'Not this genuine schema 6 fixture.'
    Assert-True ($receipt.operationId -ceq $operationId -and $receipt.manifestSha256 -ieq (Digest (Join-Path $operationRoot 'recycle-manifest.json'))) 'Receipt binding differs.'
    $payload = $receipt.physicalPath
    Assert-True ([IO.Path]::IsPathFullyQualified($payload) -and ($payload.Split([char]92) -icontains '$Recycle.Bin')) 'Payload must be in Windows Recycle Bin.'
    Assert-True ($operationRoot -ceq (Join-Path $metadata $operationId)) 'Baseline must create genuine legacy-layout records.'
    $binBefore = Snapshot-R $payload
    $rawBefore = Snapshot-R $operationRoot
    $configHash = Digest $configPath
    $compatibilityHashes = Snapshot-Hashes $metadata
    # 同一の真正な旧記録・ゴミ箱payloadで、順序を反転した対の比較を行う。
    for ($i = 1; $i -le $Iterations; $i++) {
        $order = if ($i % 2) { @('baseline', 'current') } else { @('current', 'baseline') }
        foreach ($label in $order) {
            $exe = if ($label -eq 'baseline') { $BaselineExecutablePath } else { $ExecutablePath }
            $variant = if ($label -eq 'baseline') { 'baseline-legacy-diagnostic' } else { 'current-legacy-alternating' }
            Add-Timing $variant $i (Invoke-Cli @('maintain', '--dry-run') $exe) 'same-genuine-schema6-record-and-bin-payload'
            Assert-True ((Snapshot-Hashes $metadata) -ceq $compatibilityHashes -and (Digest $configPath) -ceq $configHash) 'Alternating dry-run changed metadata/config.'
        }
    }
    $null = Assert-SnapshotR $payload $binBefore
    $null = Assert-SnapshotR $operationRoot $rawBefore
    $results.Add(@{ name = 'alternating-same-legacy-operation-maintain-dry-run'; passed = $true; operationId = $operationId })
    # LIST拒否を実証した旧ディレクトリで、通常一覧/保守が走査しないことを確認する。
    $security = [Prunlet.RecordlessE2E.PermissionFixture]::Security($operationRoot)
    try {
        [Prunlet.RecordlessE2E.PermissionFixture]::DenyDataRead($operationRoot, $security)
        $denied = [Convert]::ToBase64String([Prunlet.RecordlessE2E.PermissionFixture]::Security($operationRoot))
        $enumerationFailed = $false
        try { $null = @([IO.Directory]::EnumerateFileSystemEntries($operationRoot)) } catch { $enumerationFailed = $true }
        Assert-True $enumerationFailed 'Old directory LIST denial was not established.'
        foreach ($arguments in @(@('operations'), @('maintain', '--dry-run'), @('maintain', '--apply'))) {
            $call = Invoke-Cli $arguments; Assert-Call $call 'Normal registry-only operation with denied legacy directory'
            Assert-True ([Convert]::ToBase64String([Prunlet.RecordlessE2E.PermissionFixture]::Security($operationRoot)) -ceq $denied) 'Normal operation changed denied directory ACL.'
        }
    } finally { [Prunlet.RecordlessE2E.PermissionFixture]::SetDacl($operationRoot, $security) }
    $null = Assert-SnapshotR $operationRoot $rawBefore
    $null = Assert-SnapshotR $payload $binBefore
    Assert-True ((Digest $configPath) -ceq $configHash) 'Normal operations changed config.'
    $results.Add(@{ name = 'normal-operations-do-not-enumerate-or-change-legacy'; passed = $true; proof = 'Directory LIST denied and enumeration failure established; operations, maintain --dry-run/--apply succeed; native snapshots unchanged after ACL restoration.' })
    $migration = Invoke-Cli @('migrate', '--apply'); Assert-Call $migration 'Explicit legacy migration'
    $discarded = @($migration.Json.operations | Where-Object path -CEQ $operationRoot)
    Assert-True ($migration.Json.registryReady -and $migration.Json.complete -and $discarded.Count -eq 1 -and $discarded[0].status -ceq 'recycled' -and $null -eq $discarded[0].schema -and !$discarded[0].operationId -and !(Test-Path -LiteralPath $operationRoot)) 'Explicit legacy metadata discard failed.'
    $null = Assert-SnapshotR $payload $binBefore
    $metadataItem = @([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($rawBefore[0].Id))
    Assert-True ($metadataItem.Count -eq 1) 'Discarded metadata root must have one owned Windows Bin identity.'
    $metadataBinBefore = Assert-SnapshotR $metadataItem[0].PhysicalPath $rawBefore -WindowsManagedBin
    $binPaths.Add($metadataItem[0].PhysicalPath)
    Save-Json (Join-Path $outputRoot 'after-discard-bin.json') @{ sourcePayload = (Snapshot-R $payload); discardedMetadata = $metadataBinBefore }
    $results.Add(@{ name = 'explicit-legacy-metadata-root-discard-to-windows-bin'; passed = $true; path = $operationRoot; originalLegacyOperationId = $operationId; measurement = $migration.Measurement; metadataBin = $metadataItem[0]; policy = 'Owned old metadata root is recycled without parsing, hashing, decoding, restoration or bundle conversion. Existing file payload remains managed by Windows Bin.' })
    $postHashes = Snapshot-Hashes $metadata
    for ($i = 1; $i -le $Iterations; $i++) {
        Add-Timing 'current-after-explicit-migration' $i (Invoke-Cli @('maintain', '--dry-run')) 'registry-only-after-legacy-discard'
        Assert-True ((Snapshot-Hashes $metadata) -ceq $postHashes -and (Digest $configPath) -ceq $configHash) 'Post-migration dry-run changed metadata/config.'
    }
    foreach ($round in 1..2) { Assert-Call (Invoke-Cli @('maintain', '--apply')) 'Post-migration maintain apply' }
    $null = Assert-SnapshotR $payload $binBefore
    $null = Assert-SnapshotR $metadataItem[0].PhysicalPath $metadataBinBefore
    $results.Add(@{ name = 'post-migration-registry-only-maintenance'; passed = $true })
} catch {
    $results.Add(@{ name = 'maintenance-performance'; passed = $false; error = $_.Exception.Message; location = $_.InvocationInfo.PositionMessage; stack = $_.ScriptStackTrace })
} finally {
    $medians = foreach ($label in @('baseline-legacy-diagnostic', 'current-legacy-alternating', 'current-after-explicit-migration')) {
        $samples = @($timings | Where-Object variant -EQ $label)
        if ($samples.Count) { @{ variant = $label; samples = $samples.Count; elapsedMilliseconds = Median $samples.elapsedMilliseconds; cpuMilliseconds = Median $samples.cpuMilliseconds } }
    }
    $report = @{ passed = @($results | Where-Object passed -EQ $true).Count; failed = @($results | Where-Object passed -EQ $false).Count
        executablePath = $ExecutablePath; executableSha256 = Digest $ExecutablePath; baselineExecutablePath = $BaselineExecutablePath; baselineSha256 = Digest $BaselineExecutablePath
        baselineVersion = $baselineVersion; fileCount = $FileCount; iterations = $Iterations; results = @($results); timings = @($timings); medians = @($medians); calls = @($calls)
        retainedPaths = @($outputRoot, $ReportPath) + @($binPaths | Where-Object { Test-Path -LiteralPath $_ }); comparisonMode = 'Alternating order per pair on the same genuine 1.0.15 schema6 record and configured-file-count bin payload. Empty registry readiness is initialized before creating the legacy record. Baseline exit1/completefalse is accepted only for the exact .registry-records-v1 incompatibility DTO and warnings, and is diagnostic timing, not normal successful maintenance; no normal speed ratio is inferred. Current normal operations are checked with old directory LIST denied. Explicit migrate --apply is measured separately, recycling the owned old metadata root itself while leaving the existing Windows Bin payload untouched. Both objects remain Windows-managed; no old-data restore or conversion is performed. Current post-migration medians form a separate boundary, without baseline comparison after migration.'; limitation = 'Wall time includes CMD dispatch and child discovery; CPU is actual CLI TotalProcessorTime, with CMD job CPU supplemental. Fresh CLI process, warmed OS caches, other verification processes may run concurrently; no fixed speed threshold; no measurement or claim of total startup/logon speed. Fixtures retained for parent cleanup.' }
    Save-Json $ReportPath $report
    $report | ConvertTo-Json -Depth 10
}
if ($report.failed) { exit 1 }