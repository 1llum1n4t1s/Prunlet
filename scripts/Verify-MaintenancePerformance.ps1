# 想定する失敗: 出力先の既存データ/リンクへの侵入、別版・別記録での比較、CLI失敗/timeout、
# dry-runによるmetadata変更、保守によるschema 6実体消失、復元先の上書き、
# 復元時の内容/File ID/属性/完全O/G/D bytesの変化、未計測CPUを成功扱いすること。
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
if ($baselineVersion -notmatch '^1\.0\.14(?:[.+-]|$)') { throw "Expected genuine installed 1.0.14 baseline; found $baselineVersion" }
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
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info; $job = $null
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
        if (!$process.WaitForExit(600000)) { $process.Kill($true); $process.WaitForExit(); throw "CLI timeout: $CliArguments" }
        $timer.Stop()
        $out = [IO.File]::ReadAllText($stdoutPath, $utf8); $err = [IO.File]::ReadAllText($stderrPath, $utf8)
        $call = @{ executable = $Exe; arguments = $CliArguments; exitCode = $process.ExitCode; elapsedMilliseconds = $timer.Elapsed.TotalMilliseconds
            cpuMilliseconds = [PrunletMaintenanceEvidence]::CpuMilliseconds($job); cpuScope = 'CMD job including CLI child'; stdoutPath = $stdoutPath; stderrPath = $stderrPath
            shellStdout = $shellOut.GetAwaiter().GetResult(); shellStderr = $shellErr.GetAwaiter().GetResult() }
        $calls.Add($call)
        $json = $null; try { $json = $out | ConvertFrom-Json -AsHashtable -Depth 80 } catch { }
        return @{ ExitCode = $process.ExitCode; Json = $json; Stdout = $out; Stderr = $err; Measurement = $call }
    } finally {
        if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        if ($job) { $job.Dispose() }; $process.Dispose()
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
function Delete-Tree([string]$Path) {
    $list = Join-Path $outputRoot ('paths-' + [guid]::NewGuid().ToString('N') + '.json')
    Save-Json $list @($Path)
    $deleted = Invoke-Cli @('delete', '--recursive', '--paths-file', $list)
    Assert-Call $deleted 'Delete'
    Assert-True ($deleted.Json.items.Count -eq 1 -and $deleted.Json.items[0].path -ceq $Path -and $deleted.Json.items[0].status -eq 'deleted' -and !(Test-Path -LiteralPath $Path)) 'Delete did not confirm this fixture.'
    $deletedReceipt = Read-Json (Join-Path (Join-Path $metadata $deleted.Json.operationId) 'recycle-0000-complete.json')
    $binPaths.Add($deletedReceipt.physicalPath)
    return $deleted.Json.operationId
}
function Median($Values) { $sorted = @($Values | Sort-Object); $n = $sorted.Count; if ($n % 2) { return $sorted[[int][Math]::Floor($n / 2)] }; return ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2 }
try {
    $null = [IO.Directory]::CreateDirectory($metadata)
    Assert-Call (Invoke-Cli @('init', '--backup-directory', $metadata)) 'Init'
    $config = Read-Json $configPath
    $config.volumeRecoveryDirectories = @{ 'D:\' = (Join-Path $outputRoot 'volume-store') }
    Save-Json $configPath $config
    $null = [IO.Directory]::CreateDirectory($tree)
    for ($i = 0; $i -lt $FileCount; $i++) { [IO.File]::WriteAllText((Join-Path $tree ('file-{0:000000}.txt' -f $i)), "Prunlet maintenance fixture $i", $utf8) }
    $before = Snapshot-Tree $tree; Save-Json (Join-Path $outputRoot 'before.json') $before
    Assert-True ($before.Count -eq $FileCount + 1) 'Fixture file count differs.'
    $operationId = Delete-Tree $tree
    $operationRoot = Join-Path $metadata $operationId
    $manifest = Read-Json (Join-Path $operationRoot 'recycle-manifest.json')
    $receipt = Read-Json (Join-Path $operationRoot 'recycle-0000-complete.json')
    Assert-True ($manifest.schema -eq 6 -and $manifest.entries.Count -eq 1 -and $manifest.entries[0].path -ceq $tree) 'Not this schema 6 fixture.'
    Assert-True ($receipt.operationId -ceq $operationId -and $receipt.manifestSha256 -ieq (Digest (Join-Path $operationRoot 'recycle-manifest.json'))) 'Receipt binding differs.'
    $payload = $receipt.physicalPath
    Assert-True ([IO.Path]::IsPathFullyQualified($payload) -and ($payload.Split([char]92) -icontains '$Recycle.Bin')) 'Payload must be in Windows Recycle Bin.'
    $payloadIdentity = [PrunletMaintenanceEvidence]::Snapshot($payload)[0]
    Assert-True ($payloadIdentity -ceq $before[0].identity) 'Bin root identity differs.'
    $hashes = Snapshot-Hashes $metadata; $configHash = Digest $configPath
    for ($i = 1; $i -le $Iterations; $i++) {
        $order = if ($i % 2) { @('baseline', 'current') } else { @('current', 'baseline') }
        foreach ($label in $order) {
            $exe = if ($label -eq 'baseline') { $BaselineExecutablePath } else { $ExecutablePath }
            $call = Invoke-Cli @('maintain', '--dry-run') $exe; Assert-Call $call "$label maintain dry-run"
            $timings.Add(@{ variant = $label; iteration = $i; elapsedMilliseconds = $call.Measurement.elapsedMilliseconds; cpuMilliseconds = $call.Measurement.cpuMilliseconds; output = $call.Json; process = $call.Measurement })
            Assert-True ((Snapshot-Hashes $metadata) -ceq $hashes -and (Digest $configPath) -ceq $configHash) 'Dry-run changed metadata/config.'
            Assert-True (([PrunletMaintenanceEvidence]::Snapshot($payload)[0]) -ceq $payloadIdentity) 'Dry-run changed bin identity.'
        }
    }
    $results.Add(@{ name = 'alternating-maintain-dry-run'; passed = $true })
    $operationHashes = Snapshot-Hashes $operationRoot
    for ($i = 1; $i -le 2; $i++) {
        Assert-Call (Invoke-Cli @('maintain', '--apply')) 'Maintain apply'
        Assert-True ((Snapshot-Hashes $operationRoot) -ceq $operationHashes -and ([PrunletMaintenanceEvidence]::Snapshot($payload)[0]) -ceq $payloadIdentity) 'Apply changed schema 6 record/bin identity.'
    }
    $results.Add(@{ name = 'maintain-apply-twice-retains-schema6'; passed = $true })
    $null = [IO.Directory]::CreateDirectory($tree)
    $conflictBefore = Snapshot-Tree $tree
    $conflict = Invoke-Cli @('restore', $operationId)
    Assert-True ($conflict.ExitCode -ne 0 -and (ConvertTo-Json -InputObject (Snapshot-Tree $tree) -Depth 10 -Compress) -ceq (ConvertTo-Json -InputObject $conflictBefore -Depth 10 -Compress)) 'Conflicting restore overwrote the target.'
    Assert-True (([PrunletMaintenanceEvidence]::Snapshot($payload)[0]) -ceq $payloadIdentity) 'Conflicting restore lost bin root identity.'
    $conflictOperationId = Delete-Tree $tree
    $restored = Invoke-Cli @('restore', $operationId); Assert-Call $restored 'Restore'
    Assert-True ($restored.Json.items[0].status -eq 'restored' -and !(Test-Path -LiteralPath $payload)) 'Restore result/payload differs.'
    $after = Snapshot-Tree $tree; Save-Json (Join-Path $outputRoot 'after.json') $after
    Assert-True ((ConvertTo-Json -InputObject $before -Depth 10 -Compress) -ceq (ConvertTo-Json -InputObject $after -Depth 10 -Compress)) 'Restored tree content/ID/attributes/full ACL differs.'
    $results.Add(@{ name = 'non-overwriting-restore-full-tree'; passed = $true; operationId = $operationId; conflictOperationId = $conflictOperationId })
} catch {
    $results.Add(@{ name = 'maintenance-performance'; passed = $false; error = $_.Exception.Message; location = $_.InvocationInfo.PositionMessage; stack = $_.ScriptStackTrace })
} finally {
    $medians = foreach ($label in @('baseline', 'current')) {
        $samples = @($timings | Where-Object variant -EQ $label)
        if ($samples.Count) { @{ variant = $label; samples = $samples.Count; elapsedMilliseconds = Median $samples.elapsedMilliseconds; cpuMilliseconds = Median $samples.cpuMilliseconds } }
    }
    $report = @{ passed = @($results | Where-Object passed -EQ $true).Count; failed = @($results | Where-Object passed -EQ $false).Count
        executablePath = $ExecutablePath; executableSha256 = Digest $ExecutablePath; baselineExecutablePath = $BaselineExecutablePath; baselineSha256 = Digest $BaselineExecutablePath
        baselineVersion = $baselineVersion; fileCount = $FileCount; iterations = $Iterations; results = @($results); timings = @($timings); medians = @($medians); calls = @($calls)
        retainedPaths = @($outputRoot, $ReportPath) + @($binPaths | Where-Object { Test-Path -LiteralPath $_ }); limitation = 'CPU includes CMD overhead; CLI timings do not measure total logon performance. Fixtures are retained for parent cleanup.' }
    Save-Json $ReportPath $report
    $report | ConvertTo-Json -Depth 10
}
if ($report.failed) { exit 1 }
