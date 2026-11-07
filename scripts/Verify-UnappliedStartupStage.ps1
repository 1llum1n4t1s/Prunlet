#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$PublishDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourceRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
$forbidden = @($sourceRoot, (Join-Path $env:USERPROFILE '.codex'))
if ($env:CODEX_HOME) { $forbidden += $env:CODEX_HOME }
foreach ($destination in @($OutputDirectory, $ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($destination) -or $destination -notmatch '^D:\\') { throw 'Verification output must be an absolute external D path.' }
    Assert-VerificationDestination $destination $forbidden
    if (Test-Path -LiteralPath $destination) { throw 'Verification destinations must be unused.' }
}
foreach ($inputPath in @($ExecutablePath, $PublishDirectory)) {
    if (![IO.Path]::IsPathFullyQualified($inputPath) -or !(Test-Path -LiteralPath $inputPath)) { throw 'Build inputs must be existing absolute paths.' }
}
if ((Get-FileHash -LiteralPath $ExecutablePath).Hash -cne (Get-FileHash -LiteralPath (Join-Path $PublishDirectory 'prunlet.exe')).Hash) { throw 'CLI and published products must be from the same build.' }
New-Item -ItemType Directory -Path $OutputDirectory, (Split-Path -Parent $ReportPath) -Force | Out-Null
$results = [Collections.Generic.List[object]]::new()
$invocations = [Collections.Generic.List[object]]::new()
$utf8 = [Text.UTF8Encoding]::new($false)
$commits = @(('a' * 40), ('b' * 40), ('c' * 40), ('d' * 40), ('e' * 40))
$auxiliary = @('Install-Prunlet.ps1', 'start-prunlet-mcp.ps1', 'configuration-common.ps1', 'maintenance-task.ps1', 'uninstall-maintenance.ps1', 'install-codex.ps1', 'uninstall-codex.ps1', 'install-agent-instructions.ps1', 'PRUNLET.md')
$packages = @{}
if (!('PrunletUnappliedStageIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class PrunletUnappliedStageIdentity {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, byte[] data, uint size);
    public static string Read(string path) {
        using var handle = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
        if (handle.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        byte[] data = new byte[24];
        if (!GetFileInformationByHandleEx(handle, 18, data, 24)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return Convert.ToHexString(data);
    }
}
'@
}

function Assert-True([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Write-Json([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 50 -Compress), $utf8) }
function Read-Json([string]$Path) { return [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -Depth 50 }
function State-Path([string]$Root) { return Join-Path $Root '.prunlet-update-state.json' }
function Stage-Path([string]$Root) { return Join-Path $Root '.prunlet-update-stage' }
function Invoke-Cli([string]$Root, [string[]]$Arguments, [switch]$Reject, [string]$ExpectedError = '', [switch]$NewCandidate) {
    $program = $ExecutablePath
    if ($NewCandidate) {
        $program = Join-Path (Stage-Path $Root) 'prunlet.exe'
        Assert-True ((Get-FileHash -LiteralPath $program).Hash -ceq (Get-FileHash -LiteralPath $ExecutablePath).Hash) 'Only the current verified new candidate may execute.'
    }
    $start = [Diagnostics.ProcessStartInfo]::new($program)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.ArgumentList.Add('--config'); $start.ArgumentList.Add((Join-Path $Root 'config.json'))
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $start.Environment['TEMP'] = $OutputDirectory; $start.Environment['TMP'] = $OutputDirectory
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(60000)) { $process.Kill($true); $process.WaitForExit(); throw 'Isolated CLI exceeded its timeout.' }
        $stdout = $stdoutTask.GetAwaiter().GetResult(); $stderr = $stderrTask.GetAwaiter().GetResult()
        $entry = [ordered]@{ root = $Root; executable = $program; arguments = $Arguments; exitCode = $process.ExitCode; stdout = $stdout; stderr = $stderr }
        $invocations.Add($entry)
        if ($Reject) {
            Assert-True ($process.ExitCode -ne 0) 'Unsafe fixture was unexpectedly accepted.'
            if ($ExpectedError) { Assert-True (($stdout + $stderr) -match $ExpectedError) ('Unexpected refusal reason: ' + $stdout + $stderr) }
        }
        else { Assert-True ($process.ExitCode -eq 0) ('CLI failed: ' + $stderr + $stdout) }
        if ($stdout.Trim()) { return $stdout | ConvertFrom-Json -AsHashtable -Depth 50 }
    } finally { $process.Dispose() }
}

# 旧候補は実行しない。切替だけ今回のビルドとhash一致する新候補を実行する。
function New-Package([string]$Commit) {
    $source = Join-Path $OutputDirectory ('source-' + $Commit.Substring(0, 1))
    New-Item -ItemType Directory -Path (Join-Path $source 'scripts'), (Join-Path $source 'integration') | Out-Null
    foreach ($leaf in $auxiliary) {
        $relative = if ($leaf -eq 'Install-Prunlet.ps1') { 'scripts\' + $leaf } else { 'integration\' + $leaf }
        [IO.File]::Copy((Join-Path $sourceRoot $relative), (Join-Path $source $relative))
    }
    [IO.File]::AppendAllText((Join-Path $source 'integration\PRUNLET.md'), ("`r`n<!-- isolated cache fixture " + $Commit + " -->`r`n"), $utf8)
    $publish = $PublishDirectory
    if ($Commit -eq $commits[0]) {
        # 旧候補は実行しない。未署名PEのoverlayだけを変え、3製品の旧/新hashを区別する。
        $publish = Join-Path $OutputDirectory 'old-publish'
        New-Item -ItemType Directory -Path $publish | Out-Null
        foreach ($leaf in @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe')) {
            $input = Join-Path $PublishDirectory $leaf
            Assert-True ((Get-AuthenticodeSignature -LiteralPath $input).Status -eq 'NotSigned') 'Old overlay fixture requires unsigned build products; signed inputs must not be modified.'
            $output = Join-Path $publish $leaf
            [IO.File]::Copy($input, $output)
            $stream = [IO.File]::Open($output, [IO.FileMode]::Append, [IO.FileAccess]::Write)
            try { $stream.Write($utf8.GetBytes('Prunlet isolated unexecuted old cache fixture')) } finally { $stream.Dispose() }
            Assert-True ((Get-AuthenticodeSignature -LiteralPath $output).Status -eq 'NotSigned') 'Old fixture changed Authenticode status.'
        }
    }
    $zip = Join-Path $OutputDirectory ('package-' + $Commit.Substring(0, 1) + '.zip')
    & (Join-Path $PSScriptRoot 'Package-PrunletUpdate.ps1') -SourceRoot $source -PublishDirectory $publish -OutputPath $zip -CommitSha $Commit -DefaultBranch main -Runtime win-x64 | Out-Null
    $verified = & (Join-Path $PSScriptRoot 'Verify-ReleasePackage.ps1') -PackagePath $zip -SourceRoot $source -PublishDirectory $publish -CommitSha $Commit -DefaultBranch main -Runtime win-x64 -Repository '1llum1n4t1s/Prunlet'
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try { $reader = [IO.StreamReader]::new($archive.GetEntry('package.json').Open()); try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable } finally { $reader.Dispose() } }
    finally { $archive.Dispose() }
    $packages[$Commit] = @{ path = $zip; hash = (Get-FileHash -LiteralPath $zip).Hash; bytes = (Get-Item -LiteralPath $zip).Length; manifest = $manifest; verified = $verified }
}
function New-Fixture([string]$Name) {
    $root = Join-Path $OutputDirectory $Name
    New-Item -ItemType Directory -Path (Join-Path $root 'bin'), (Join-Path $root 'recovery') | Out-Null
    Write-Json (Join-Path $root 'config.json') @{ backupDirectory = (Join-Path $root 'recovery') }
    $package = $packages[$commits[0]]
    $archive = [IO.Compression.ZipFile]::OpenRead($package.path)
    try { foreach ($entry in $archive.Entries) { if ($entry.FullName.StartsWith('bin/')) { [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $root $entry.FullName.Replace('/', '\'))) } } }
    finally { $archive.Dispose() }
    $hashes = @{}
    foreach ($leaf in $auxiliary) { $hashes['bin\' + $leaf] = $package.manifest.files['bin/' + $leaf].sha256 }
    Write-Json (Join-Path $root 'source-info.json') @{
        repository = '1llum1n4t1s/Prunlet'; defaultBranch = 'main'; runtime = 'win-x64'; commitSha = $commits[1]
        archiveSha256 = $package.hash; executableSha256 = $package.manifest.files['bin/prunlet.exe'].sha256
        maintenanceExecutableSha256 = $package.manifest.files['bin/prunlet-maintenance.exe'].sha256
        hookExecutableSha256 = $package.manifest.files['bin/prunlet-hook.exe'].sha256; auxiliarySha256 = $hashes
    }
    Invoke-Cli $root @('__begin-published-update', $commits[0], $commits[1]) | Out-Null
    Set-Package $root $commits[0]
    Prepare-Package $root $commits[0]
    # 手動導入を模擬する。旧候補を適用せず、live製品はそのまま別commitの来歴に進める。
    $info = Read-Json (Join-Path $root 'source-info.json'); $info.commitSha = $commits[2]
    Write-Json (Join-Path $root 'source-info.json') $info
    return $root
}
function Set-Package([string]$Root, [string]$Commit) {
    $state = Read-Json (State-Path $Root)
    # HTTP取得は行わず、検証済み実ZIPをdownload完了境界へ置く。
    [IO.File]::Copy($packages[$Commit].path, (Join-Path (Stage-Path $Root) $state.packageName), $true)
    $state.packageStatus = 'ready'
    $state.packagePreviousSha256 = $packages[$Commit].hash
    $state.packagePreviousBytes = $packages[$Commit].bytes
    Write-Json (State-Path $Root) $state
}
function Prepare-Package([string]$Root, [string]$Commit, [switch]$Reject) {
    $package = $packages[$Commit]
    $result = Invoke-Cli $Root @('__prepare-published-package', '1llum1n4t1s/Prunlet', 'main', $Commit, 'win-x64', $package.hash, [string]$package.bytes, '1') -Reject:$Reject
    if (!$Reject) { Assert-True ($result.status -eq 'prepared') 'Package preparation did not complete.' }
}
function Get-Snapshot([string]$Root) {
    $snapshot = [ordered]@{}
    foreach ($item in @(Get-Item -LiteralPath $Root) + @(Get-ChildItem -LiteralPath $Root -Force -Recurse | Sort-Object FullName)) {
        $key = $item.FullName.Substring($Root.Length)
        $snapshot[$key] = @{ attributes = [string]$item.Attributes; identity = if ($item.PSIsContainer) { '' } else { [PrunletUnappliedStageIdentity]::Read($item.FullName) }; length = if ($item.PSIsContainer) { 0 } else { $item.Length }; hash = if ($item.PSIsContainer) { '' } else { (Get-FileHash -LiteralPath $item.FullName).Hash } }
        foreach ($stream in @(Get-Item -LiteralPath $item.FullName -Stream * | Where-Object Stream -ne ':$DATA')) {
            $streamPath = $item.FullName + ':' + $stream.Stream
            $snapshot[$key + ':' + $stream.Stream] = @{ length = $stream.Length; hash = (Get-FileHash -LiteralPath $streamPath).Hash }
        }
    }
    return $snapshot | ConvertTo-Json -Depth 10 -Compress
}
function Assert-RejectedUnchanged([string]$Root, [string[]]$Arguments, [string]$ExpectedError) {
    $before = Get-Snapshot $Root
    Invoke-Cli $Root $Arguments -Reject -ExpectedError $ExpectedError | Out-Null
    Assert-True ((Get-Snapshot $Root) -ceq $before) 'Rejected input changed stage, state, live products, or named streams.'
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $results.Add(@{ name = $Name; passed = $true }); Write-Host ('PASS ' + $Name) }
    catch { $results.Add(@{ name = $Name; passed = $false; error = $_.Exception.ToString() }); Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}

try {
    New-Package $commits[0]; New-Package $commits[3]; New-Package $commits[4]
    Test-Case 'Unapplied cache survives manual install, Core finalization and next release preparation' {
        $root = New-Fixture 'reuse'
        $live = Get-Snapshot (Join-Path $root 'bin'); $installed = (Get-FileHash -LiteralPath (Join-Path $root 'source-info.json')).Hash
        $oldState = Read-Json (State-Path $root)
        $stageIdentities = @{}
        foreach ($relative in @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe', 'integration\PRUNLET.md')) {
            $stageIdentities[$relative] = [PrunletUnappliedStageIdentity]::Read((Join-Path (Stage-Path $root) $relative))
        }
        Invoke-Cli $root @('__begin-published-update', $commits[3], $commits[2]) | Out-Null
        $state = Read-Json (State-Path $root)
        Assert-True ($state.cacheBaseline.commit -eq $commits[0]) 'Old cache baseline is not separate from installed provenance.'
        Set-Package $root $commits[3]; Prepare-Package $root $commits[3]; Prepare-Package $root $commits[3]
        $state = Read-Json (State-Path $root)
        foreach ($slot in @('slotCli', 'slotMaintenance', 'slotHook')) { Assert-True ($state[$slot].generation -eq $oldState[$slot].generation) 'Verified nonexecuting slot was not reused.' }
        foreach ($relative in $stageIdentities.Keys) { Assert-True ([PrunletUnappliedStageIdentity]::Read((Join-Path (Stage-Path $root) $relative)) -ceq $stageIdentities[$relative]) 'Known staged file was replaced instead of updating its main stream.' }
        Assert-True ((Get-Snapshot (Join-Path $root 'bin')) -ceq $live) 'Preparation changed installed products.'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $root 'source-info.json')).Hash -ceq $installed) 'Preparation changed installed provenance.'
        $guide = Join-Path (Stage-Path $root) 'integration\PRUNLET.md'
        Assert-True ((Get-FileHash -LiteralPath $guide).Hash -ceq $packages[$commits[3]].manifest.files['bin/PRUNLET.md'].sha256) 'Known staged guide was not updated.'
        # 実CLIの切替から後段のCore統合・移行・旧製品保持まで確認し、実ホスト登録は行わない。
        $applied = Invoke-Cli $root @('__apply-startup-update') -NewCandidate
        Assert-True ($applied.status -eq 'integration_required' -and $applied.phase -eq 'switching') 'Prepared cache did not reach the real product switch.'
        $state = Read-Json (State-Path $root)
        Assert-True ($state.oldCommit -eq $commits[2] -and $state.candidateCommit -eq $commits[3]) 'Switch used the cached commit as the installed baseline.'
        foreach ($leaf in @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe')) {
            Assert-True ((Get-FileHash -LiteralPath (Join-Path $root ('bin\' + $leaf))).Hash -ceq $packages[$commits[3]].manifest.files['bin/' + $leaf].sha256) 'Live executable did not switch to the new package.'
            Assert-True ($packages[$commits[0]].manifest.files['bin/' + $leaf].sha256 -cne $packages[$commits[3]].manifest.files['bin/' + $leaf].sha256) 'Executable old/new fixture hashes are identical.'
        }
        # host登録境界を呼ばず、Coreの補助製品・確認・移行・旧製品保持まで通す。
        $integration = Invoke-Cli $root @('__apply-startup-integration') -NewCandidate
        Assert-True ($integration.status -eq 'integration_applied') 'Core auxiliary product integration did not complete.'
        $confirmed = Invoke-Cli $root @('__confirm-startup-integration') -NewCandidate
        Assert-True ($confirmed.status -eq 'integration_confirmed') 'Core integration confirmation did not complete.'
        $completed = Invoke-Cli $root @('__apply-startup-update') -NewCandidate
        Assert-True ($completed.status -eq 'cleanup_pending' -and $completed.phase -eq 'idle' -and $completed.registryReady) 'Core finalization did not reach the documented previous-product retention state.'
        $state = Read-Json (State-Path $root)
        Assert-True ($state.migrationComplete -and (Read-Json (Join-Path $root 'source-info.json')).commitSha -eq $commits[3]) 'Core finalization did not commit the new installed provenance.'
        Assert-True ($state.cleanupCli -eq 'pending' -and $state.cleanupMaintenance -eq 'pending' -and $state.cleanupHook -eq 'pending') 'Core changed the previous-product retention contract.'
        foreach ($leaf in @('prunlet.previous.exe', 'prunlet-maintenance.previous.exe', 'prunlet-hook.previous.exe')) { Assert-True ([IO.File]::Exists((Join-Path $root ('bin\' + $leaf)))) 'Core unexpectedly deleted a retained previous product.' }
        Invoke-Cli $root @('__begin-published-update', $commits[4], $commits[3]) | Out-Null
        Set-Package $root $commits[4]; Prepare-Package $root $commits[4]
        $state = Read-Json (State-Path $root)
        Assert-True ($state.priorStageCommit -eq $commits[3] -and $null -eq $state.cacheBaseline) 'Completed stage did not return to the existing applied-stage reuse path.'
        Assert-True ((Read-Json (Join-Path $root 'source-info.json')).commitSha -eq $commits[3]) 'Next preparation modified the installed commit.'
    }
    Test-Case 'Durable begin state resumes after owner update interruption' {
        $root = New-Fixture 'owner-resume'; $owner = Join-Path (Stage-Path $root) '.prunlet-stage-owner.json'
        $oldOwner = [IO.File]::ReadAllBytes($owner)
        Invoke-Cli $root @('__begin-published-update', $commits[3], $commits[2]) | Out-Null
        # state保存後owner主stream更新前の正確な境界をfixtureで再現する。
        [IO.File]::WriteAllBytes($owner, $oldOwner)
        Invoke-Cli $root @('__begin-published-update', $commits[3], $commits[2]) | Out-Null
        Set-Package $root $commits[3]; Prepare-Package $root $commits[3]
    }
    foreach ($kind in @('hash', 'ads', 'directory-ads', 'link', 'marker', 'state', 'unknown', 'unknown-provenance', 'slot-status', 'cleanup-done', 'rotation-orphan', 'prior-orphan')) {
        Test-Case ('Unsafe old cache is preserved: ' + $kind) {
            $root = New-Fixture ('reject-' + $kind); $stage = Stage-Path $root
            switch ($kind) {
                hash { [IO.File]::AppendAllText((Join-Path $stage 'integration\PRUNLET.md'), 'changed', $utf8) }
                ads { [IO.File]::WriteAllText((Join-Path $stage 'prunlet.exe') + ':fixture', 'retained', $utf8) }
                directory-ads { [IO.File]::WriteAllText($stage + ':fixture', 'retained', $utf8) }
                link { New-Item -ItemType HardLink -Path (Join-Path $root 'outside-alias.exe') -Target (Join-Path $stage 'prunlet.exe') | Out-Null }
                marker { $owner = Join-Path $stage '.prunlet-stage-owner.json'; $value = Read-Json $owner; $value.installRoot = 'D:\unowned'; Write-Json $owner $value }
                state { $path = State-Path $root; $value = Read-Json $path; $value.unknownFixtureField = 1; Write-Json $path $value }
                unknown { [IO.File]::WriteAllText((Join-Path $stage 'unowned.txt'), 'retain this file', $utf8) }
                unknown-provenance { $path = Join-Path $stage 'source-info.json'; $value = Read-Json $path; $value.userNote = 'retain this unknown field'; Write-Json $path $value }
                slot-status { $path = State-Path $root; $value = Read-Json $path; $value.slotCli.status = 'writing'; Write-Json $path $value }
                cleanup-done { $path = State-Path $root; $value = Read-Json $path; $value.cleanupCli = 'done'; Write-Json $path $value }
                rotation-orphan { $path = State-Path $root; $value = Read-Json $path; $value.rotationName = 'prunlet.exe'; Write-Json $path $value }
                prior-orphan { $path = State-Path $root; $value = Read-Json $path; $value.priorCliSha256 = 'A' * 64; Write-Json $path $value }
            }
            $expected = switch ($kind) {
                hash { 'changed staged cache file' }
                ads { 'stream' }
                directory-ads { 'stream' }
                link { 'link' }
                marker { 'ownership' }
                state { 'unknownFixtureField|could not be mapped' }
                unknown { 'unknown stage file' }
                unknown-provenance { 'unknown|unsupported|provenance' }
                slot-status { 'matching ready slot' }
                cleanup-done { 'incomplete or active provenance' }
                rotation-orphan { 'incomplete or active provenance|malformed|inconsistent' }
                prior-orphan { 'incomplete or active provenance|malformed|inconsistent' }
            }
            Assert-RejectedUnchanged $root @('__begin-published-update', $commits[3], $commits[2]) $expected
        }
    }
    Test-Case 'Incomplete staged stream after preparation interruption is preserved' {
        $root = New-Fixture 'partial-stream'
        Invoke-Cli $root @('__begin-published-update', $commits[3], $commits[2]) | Out-Null
        Set-Package $root $commits[3]
        [IO.File]::WriteAllText((Join-Path (Stage-Path $root) 'integration\PRUNLET.md'), 'partial write', $utf8)
        $live = Get-Snapshot (Join-Path $root 'bin')
        Prepare-Package $root $commits[3] -Reject
        # slot/stateの正常な準備進行はあり得るが、不明な実体とliveは保持する。
        Assert-True ([IO.File]::ReadAllText((Join-Path (Stage-Path $root) 'integration\PRUNLET.md')) -ceq 'partial write') 'Uncertain staged stream was overwritten.'
        Assert-True ((Read-Json (Join-Path $root 'source-info.json')).commitSha -eq $commits[2]) 'Uncertain preparation changed installed provenance.'
        Assert-True ((Get-Snapshot (Join-Path $root 'bin')) -ceq $live) 'Uncertain preparation changed live products.'
    }
    Test-Case 'Aggregate budget rejection preserves all existing streams' {
        $root = New-Fixture 'budget'
        Assert-RejectedUnchanged $root @('__check-startup-budget', '2147483648') 'storage budget is exhausted'
    }
    Test-Case 'Cache baseline and applied-stage provenance cannot coexist' {
        $root = New-Fixture 'mixed-baseline'
        Invoke-Cli $root @('__begin-published-update', $commits[3], $commits[2]) | Out-Null
        $path = State-Path $root; $state = Read-Json $path; $state.priorCliSha256 = 'A' * 64; Write-Json $path $state
        Assert-RejectedUnchanged $root @('__begin-published-update', $commits[3], $commits[2]) 'mixes unapplied cache and completed stage provenance'
    }
} catch {
    $results.Add(@{ name = 'Verification harness'; passed = $false; error = $_.Exception.ToString() })
    throw
} finally {
    $failed = @($results | Where-Object { !$_.passed }).Count
    $report = [ordered]@{
        executablePath = $ExecutablePath; executableSha256 = (Get-FileHash -LiteralPath $ExecutablePath).Hash
        verificationScriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath).Hash
        sourceInputs = @('src\Prunlet\Core\StartupUpdateCoordinator.cs', 'scripts\Package-PrunletUpdate.ps1', 'scripts\Verify-ReleasePackage.ps1') | ForEach-Object { @{ path = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $sourceRoot $_)).Hash } }
        packages = @($packages.Keys | Sort-Object | ForEach-Object { @{ commit = $_; path = $packages[$_].path; sha256 = $packages[$_].hash; bytes = $packages[$_].bytes; verification = $packages[$_].verified } })
        scope = 'Real CLI begin/prepare; fixed new candidate Core apply/integration/confirm/migration and existing cleanup_pending retention; next release preparation. Local real ZIP delivery replaces HTTP only; no old candidate execution or actual host registration.'
        passed = $results.Count - $failed; failed = $failed; cases = @($results); invocations = @($invocations)
        retainedOutputDirectory = $OutputDirectory
    }
    Write-Json $ReportPath $report
}
if (@($results | Where-Object { !$_.passed }).Count) { exit 1 }
