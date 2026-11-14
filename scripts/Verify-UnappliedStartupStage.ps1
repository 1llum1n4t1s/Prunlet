#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$PublishDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$BuildManifestPath,
    [string]$ExpectedBuildManifestSha256
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourceRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
$forbidden = @($sourceRoot, (Join-Path $env:USERPROFILE '.codex'))
if ($env:CODEX_HOME) { $forbidden += $env:CODEX_HOME }
foreach ($destination in @($OutputDirectory, $ReportPath)) {
    Assert-ExternalVerificationPath $destination $forbidden
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
. (Join-Path $PSScriptRoot 'FileFixtures.Common.ps1')
$null = Initialize-PrunletFixtureBinding -ExecutablePath $ExecutablePath -BuildManifestPath $BuildManifestPath -ExpectedBuildManifestSha256 $ExpectedBuildManifestSha256

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
# stateもstageもない、導入済み（commit b）だけの配置を作る。
function New-InstalledRoot([string]$Name) {
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
    return $root
}
function New-Fixture([string]$Name) {
    $root = New-InstalledRoot $Name
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
function Get-StageZips([string]$Root) { return @(Get-ChildItem -LiteralPath (Stage-Path $Root) -Filter 'package*.zip' -File -Force | ForEach-Object Name | Sort-Object) }
function Get-Snapshot([string]$Root) {
    $snapshot = [ordered]@{}
    foreach ($item in @(Get-Item -LiteralPath $Root) + @(Get-ChildItem -LiteralPath $Root -Force -Recurse | Sort-Object FullName)) {
        $key = $item.FullName.Substring($Root.Length)
        $snapshot[$key] = @{ attributes = [string]$item.Attributes; identity = if ($item.PSIsContainer) { '' } else { Get-FileFixtureIdentity -Path $item.FullName }; length = if ($item.PSIsContainer) { 0 } else { $item.Length }; hash = if ($item.PSIsContainer) { '' } else { (Get-FileHash -LiteralPath $item.FullName).Hash } }
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
# 未適用候補をCoreで切替・統合・確認・移行まで進め、旧製品を保持した適用済みstage（cleanup_pending）にする。
function Complete-Update([string]$Root) {
    $applied = Invoke-Cli $Root @('__apply-startup-update') -NewCandidate
    Assert-True ($applied.status -eq 'integration_required') 'Prepared candidate did not reach the real product switch.'
    Invoke-Cli $Root @('__apply-startup-integration') -NewCandidate | Out-Null
    Invoke-Cli $Root @('__confirm-startup-integration') -NewCandidate | Out-Null
    $completed = Invoke-Cli $Root @('__apply-startup-update') -NewCandidate
    Assert-True ($completed.status -eq 'cleanup_pending' -and $completed.phase -eq 'idle') 'Core finalization did not reach the previous-product retention state.'
}
function New-AppliedFixture([string]$Name) {
    $root = New-Fixture $Name
    Invoke-Cli $root @('__begin-published-update', $commits[3], $commits[2]) | Out-Null
    Set-Package $root $commits[3]; Prepare-Package $root $commits[3]
    Complete-Update $root
    $state = Read-Json (State-Path $root)
    Assert-True ($state.migrationComplete -and $state.stageCleanup -eq 'pending' -and $state.candidateCommit -eq $commits[3]) 'Applied fixture did not retain its stage.'
    return $root
}
# 手動導入（Install-Prunlet.ps1）を模擬する。3製品を別hashへ差し替え、source-info.jsonは
# インストーラーと同じConvertTo-Json整形（CRLF・別commit・別archive hash）で書き直す。更新状態とstageには触れない。
function Install-ManualRelease([string]$Root, [string]$Commit, [string]$Tag) {
    $hashes = @{}
    foreach ($leaf in @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe')) {
        $path = Join-Path $Root ('bin\' + $leaf)
        $stream = [IO.File]::Open($path, [IO.FileMode]::Append, [IO.FileAccess]::Write)
        try { $stream.Write($utf8.GetBytes('Prunlet isolated manual install fixture ' + $Tag)) } finally { $stream.Dispose() }
        $hashes[$leaf] = (Get-FileHash -LiteralPath $path).Hash
    }
    $current = Read-Json (Join-Path $Root 'source-info.json')
    $info = [ordered]@{
        repository = $current.repository; defaultBranch = $current.defaultBranch; commitSha = $Commit; downloadUrl = $(if ($current.ContainsKey('downloadUrl')) { $current.downloadUrl } else { 'https://api.github.com/repos/1llum1n4t1s/Prunlet/releases/assets/1' })
        archiveSha256 = ($Tag.PadRight(64, '9')).ToUpperInvariant(); executableSha256 = $hashes['prunlet.exe']
        maintenanceExecutableSha256 = $hashes['prunlet-maintenance.exe']; hookExecutableSha256 = $hashes['prunlet-hook.exe']
        auxiliarySha256 = $current.auxiliarySha256; runtime = $current.runtime
    }
    $info | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'source-info.json') -Encoding utf8NoBOM
    return $hashes
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
            $stageIdentities[$relative] = Get-FileFixtureIdentity -Path (Join-Path (Stage-Path $root) $relative)
        }
        Invoke-Cli $root @('__begin-published-update', $commits[3], $commits[2]) | Out-Null
        $state = Read-Json (State-Path $root)
        Assert-True ($state.cacheBaseline.commit -eq $commits[0]) 'Old cache baseline is not separate from installed provenance.'
        Set-Package $root $commits[3]; Prepare-Package $root $commits[3]; Prepare-Package $root $commits[3]
        $state = Read-Json (State-Path $root)
        foreach ($slot in @('slotCli', 'slotMaintenance', 'slotHook')) { Assert-True ($state[$slot].generation -eq $oldState[$slot].generation) 'Verified nonexecuting slot was not reused.' }
        foreach ($relative in $stageIdentities.Keys) { Assert-True ((Get-FileFixtureIdentity -Path (Join-Path (Stage-Path $root) $relative)) -ceq $stageIdentities[$relative]) 'Known staged file was replaced instead of updating its main stream.' }
        Assert-True ((Get-Snapshot (Join-Path $root 'bin')) -ceq $live) 'Preparation changed installed products.'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $root 'source-info.json')).Hash -ceq $installed) 'Preparation changed installed provenance.'
        $guide = Join-Path (Stage-Path $root) 'integration\PRUNLET.md'
        Assert-True ((Get-FileHash -LiteralPath $guide).Hash -ceq $packages[$commits[3]].manifest.files['bin/PRUNLET.md'].sha256) 'Known staged guide was not updated.'
        # 実CLIの切替から後段のCore統合・移行・旧製品保持まで確認し、実ホスト登録は行わない。
        $applied = Invoke-Cli $root @('__apply-startup-update') -NewCandidate
        Assert-True ($applied.status -eq 'integration_required' -and $applied.phase -eq 'switching') 'Prepared cache did not reach the real product switch.'
        $state = Read-Json (State-Path $root)
        Assert-True ($null -eq $state.cacheBaseline) 'The cache baseline survived the switch into the switching phase.'
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
    Test-Case 'Applied stage survives a manual install and the next release updates from the stage own provenance' {
        $root = New-AppliedFixture 'manual-after-apply'; $stage = Stage-Path $root
        $manualCommit = 'f' * 40
        $stageIdentities = @{}
        foreach ($relative in @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe', 'source-info.json', 'integration\PRUNLET.md', 'scripts\Install-Prunlet.ps1')) { $stageIdentities[$relative] = Get-FileFixtureIdentity -Path (Join-Path $stage $relative) }
        $stateBefore = Read-Json (State-Path $root)
        $manual = Install-ManualRelease $root $manualCommit 'm1'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $root 'source-info.json')).Hash -cne $stateBefore.candidateSourceInfoSha256) 'Manual install fixture did not change installed provenance bytes.'
        Assert-True ([IO.File]::ReadAllText((Join-Path $root 'source-info.json')).Contains("`r`n")) 'Manual install fixture is not the installer pretty-printed form.'
        $live = Get-Snapshot (Join-Path $root 'bin'); $installed = (Get-FileHash -LiteralPath (Join-Path $root 'source-info.json')).Hash
        $began = Invoke-Cli $root @('__begin-published-update', $commits[4], $manualCommit)
        Assert-True ($began.status -eq 'ready' -and (@($began.warnings) -join ' ') -match 're-verified by its own recorded provenance') 'Begin did not re-verify the stage by its own provenance after a manual install.'
        $state = Read-Json (State-Path $root)
        Assert-True ($state.priorStageCommit -eq $commits[3] -and $null -eq $state.cacheBaseline -and $state.candidateCommit -eq $commits[4]) 'Prior stage provenance is not the retained stage commit.'
        Set-Package $root $commits[4]; Prepare-Package $root $commits[4]; Prepare-Package $root $commits[4]
        foreach ($relative in $stageIdentities.Keys) { Assert-True ((Get-FileFixtureIdentity -Path (Join-Path $stage $relative)) -ceq $stageIdentities[$relative]) ('Stage file was replaced instead of updating its main stream: ' + $relative) }
        Assert-True ((Get-Snapshot (Join-Path $root 'bin')) -ceq $live) 'Begin or preparation changed installed products.'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $root 'source-info.json')).Hash -ceq $installed) 'Begin or preparation changed installed provenance.'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $stage 'integration\PRUNLET.md')).Hash -ceq $packages[$commits[4]].manifest.files['bin/PRUNLET.md'].sha256) 'Staged guide was not updated to the next release.'
        $applied = Invoke-Cli $root @('__apply-startup-update') -NewCandidate
        Assert-True ($applied.status -eq 'integration_required') 'Prepared candidate did not reach the real product switch.'
        $state = Read-Json (State-Path $root)
        Assert-True ($state.oldCommit -eq $manualCommit -and $state.candidateCommit -eq $commits[4]) 'Switch did not use the manually installed commit as the baseline.'
        foreach ($leaf in @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe')) { Assert-True ((Get-FileHash -LiteralPath (Join-Path $root ('bin\' + $leaf))).Hash -ceq $packages[$commits[4]].manifest.files['bin/' + $leaf].sha256) 'Live executable did not switch to the new package.' }
        Invoke-Cli $root @('__apply-startup-integration') -NewCandidate | Out-Null
        Invoke-Cli $root @('__confirm-startup-integration') -NewCandidate | Out-Null
        $completed = Invoke-Cli $root @('__apply-startup-update') -NewCandidate
        Assert-True ($completed.status -eq 'cleanup_pending' -and $completed.phase -eq 'idle') 'Core finalization did not complete after the manual install.'
        Assert-True ((Read-Json (Join-Path $root 'source-info.json')).commitSha -eq $commits[4]) 'Installed provenance did not advance to the next release.'
        foreach ($leaf in @('prunlet', 'prunlet-maintenance', 'prunlet-hook')) {
            $previous = (Get-FileHash -LiteralPath (Join-Path $root ('bin\' + $leaf + '.previous.exe'))).Hash
            Assert-True ($previous -ceq $manual[$leaf + '.exe']) ('The retained previous product is not the manually installed one: ' + $leaf)
        }
    }
    Test-Case 'Unapplied candidate resumes at the same commit after a manual install' {
        $root = New-Fixture 'resume-manual-install'
        Invoke-Cli $root @('__begin-published-update', $commits[3], $commits[2]) | Out-Null
        Set-Package $root $commits[3]; Prepare-Package $root $commits[3]
        $manualCommit = 'f' * 40
        $null = Install-ManualRelease $root $manualCommit 'm2'
        $installed = (Get-FileHash -LiteralPath (Join-Path $root 'source-info.json')).Hash
        $live = Get-Snapshot (Join-Path $root 'bin')
        $began = Invoke-Cli $root @('__begin-published-update', $commits[3], $manualCommit)
        Assert-True ($began.status -eq 'existing' -and (@($began.warnings) -join ' ') -match 'recorded again') 'Resuming the same commit after a manual install was not reported.'
        $state = Read-Json (State-Path $root)
        Assert-True ($state.preparedInstalledSourceInfoSha256 -ceq $installed) 'The installed provenance baseline was not recorded again under the installation mutex.'
        Assert-True ((Get-Snapshot (Join-Path $root 'bin')) -ceq $live -and (Get-FileHash -LiteralPath (Join-Path $root 'source-info.json')).Hash -ceq $installed) 'Resuming changed installed products or provenance.'
        Complete-Update $root
        Assert-True ((Read-Json (State-Path $root)).oldCommit -eq $manualCommit) 'Switch did not use the manually installed commit as the baseline.'
    }
    foreach ($kind in @('product', 'source-info', 'previous-auxiliary', 'previous-source-info', 'owner', 'state-hash')) {
        Test-Case ('Applied stage after a manual install still rejects tampering: ' + $kind) {
            $root = New-AppliedFixture ('manual-reject-' + $kind); $stage = Stage-Path $root
            $null = Install-ManualRelease $root ('f' * 40) 'm3'
            switch ($kind) {
                product { [IO.File]::AppendAllText((Join-Path $stage 'prunlet-maintenance.exe'), 'changed', $utf8) }
                source-info { $path = Join-Path $stage 'source-info.json'; $value = Read-Json $path; $value.runtime = 'win-arm64'; Write-Json $path $value }
                previous-auxiliary { $first = @(Get-ChildItem -LiteralPath (Join-Path $stage 'previous-auxiliary') -File | Sort-Object Name)[0]; [IO.File]::AppendAllText($first.FullName, 'changed', $utf8) }
                previous-source-info { [IO.File]::AppendAllText((Join-Path $stage 'previous-source-info.json'), ' ', $utf8) }
                owner { $owner = Join-Path $stage '.prunlet-stage-owner.json'; $value = Read-Json $owner; $value.installRoot = 'D:\unowned'; Write-Json $owner $value }
                state-hash { $path = State-Path $root; $value = Read-Json $path; $value.candidateSourceInfoSha256 = 'A' * 64; Write-Json $path $value }
            }
            $expected = switch ($kind) {
                owner { 'ownership' }
                default { 'do not match the confirmed provenance' }
            }
            Assert-RejectedUnchanged $root @('__begin-published-update', $commits[4], ('f' * 40)) $expected
        }
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
    foreach ($kind in @('hash', 'ads', 'directory-ads', 'link', 'marker', 'state', 'unknown-provenance', 'cleanup-done', 'rotation-orphan', 'prior-orphan')) {
        Test-Case ('Unsafe old cache is preserved: ' + $kind) {
            $root = New-Fixture ('reject-' + $kind); $stage = Stage-Path $root
            switch ($kind) {
                hash { [IO.File]::AppendAllText((Join-Path $stage 'integration\PRUNLET.md'), 'changed', $utf8) }
                ads { [IO.File]::WriteAllText((Join-Path $stage 'prunlet.exe') + ':fixture', 'retained', $utf8) }
                directory-ads { [IO.File]::WriteAllText($stage + ':fixture', 'retained', $utf8) }
                link { New-Item -ItemType HardLink -Path (Join-Path $root 'outside-alias.exe') -Target (Join-Path $stage 'prunlet.exe') | Out-Null }
                marker { $owner = Join-Path $stage '.prunlet-stage-owner.json'; $value = Read-Json $owner; $value.installRoot = 'D:\unowned'; Write-Json $owner $value }
                state { $path = State-Path $root; $value = Read-Json $path; $value.unknownFixtureField = 1; Write-Json $path $value }
                unknown-provenance { $path = Join-Path $stage 'source-info.json'; $value = Read-Json $path; $value.userNote = 'retain this unknown field'; Write-Json $path $value }
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
                unknown-provenance { 'unknown|unsupported|provenance' }
                cleanup-done { 'incomplete or active provenance' }
                rotation-orphan { 'incomplete or active provenance|malformed|inconsistent' }
                prior-orphan { 'incomplete or active provenance|malformed|inconsistent' }
            }
            Assert-RejectedUnchanged $root @('__begin-published-update', $commits[3], $commits[2]) $expected
        }
    }
    Test-Case 'Unknown stage entries are retained untouched and do not stop the update' {
        $root = New-Fixture 'unknown-entries'; $stage = Stage-Path $root
        $orphan = 'package-' + ('0123456789abcdef' * 2) + '.zip'
        [IO.File]::WriteAllText((Join-Path $stage 'unowned.txt'), 'retain this file', $utf8)
        New-Item -ItemType Directory -Path (Join-Path $stage 'notes') | Out-Null
        [IO.File]::WriteAllText((Join-Path $stage 'notes\memo.txt'), 'retain this directory entry', $utf8)
        [IO.File]::WriteAllText((Join-Path $stage $orphan), 'orphan zip', $utf8)
        $retained = @('unowned.txt', 'notes\memo.txt', $orphan)
        $before = @{}
        foreach ($relative in $retained) { $path = Join-Path $stage $relative; $before[$relative] = @{ hash = (Get-FileHash -LiteralPath $path).Hash; identity = Get-FileFixtureIdentity -Path $path } }
        $live = Get-Snapshot (Join-Path $root 'bin')
        $began = Invoke-Cli $root @('__begin-published-update', $commits[3], $commits[2])
        Assert-True ($began.status -eq 'ready') 'An unknown stage entry stopped the next release.'
        Set-Package $root $commits[3]; Prepare-Package $root $commits[3]
        foreach ($relative in $retained) {
            $path = Join-Path $stage $relative
            Assert-True ((Get-FileHash -LiteralPath $path).Hash -ceq $before[$relative].hash -and (Get-FileFixtureIdentity -Path $path) -ceq $before[$relative].identity) ('An unknown stage entry was changed: ' + $relative)
        }
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $stage 'integration\PRUNLET.md')).Hash -ceq $packages[$commits[3]].manifest.files['bin/PRUNLET.md'].sha256) 'Known staged guide was not updated beside unknown entries.'
        Assert-True ((Get-Snapshot (Join-Path $root 'bin')) -ceq $live) 'Unknown entries changed live products.'
    }
    Test-Case 'Next release after an interrupted package download resumes the recorded package name' {
        $root = New-InstalledRoot 'interrupted-download'; $stage = Stage-Path $root
        Invoke-Cli $root @('__begin-published-update', $commits[3], $commits[1]) | Out-Null
        # 取得失敗（途中書込み）をstateとstageで再現する。HTTP取得は行わない。
        $state = Read-Json (State-Path $root)
        $zipName = 'package-' + [guid]::NewGuid().ToString('N') + '.zip'
        [IO.File]::WriteAllBytes((Join-Path $stage $zipName), [byte[]](1..64))
        $state.packageName = $zipName; $state.packageStatus = 'writing'; Write-Json (State-Path $root) $state
        $identity = Get-FileFixtureIdentity -Path (Join-Path $stage $zipName)
        $live = Get-Snapshot (Join-Path $root 'bin')
        $began = Invoke-Cli $root @('__begin-published-update', $commits[4], $commits[1])
        Assert-True ($began.status -eq 'ready') 'A writing package stopped the next release.'
        $state = Read-Json (State-Path $root)
        Assert-True ($state.candidateCommit -eq $commits[4] -and $state.packageName -ceq $zipName -and $state.packageStatus -eq 'writing') 'The recorded writing package was not carried to the next release.'
        Assert-True ($null -ne $state.cacheBaseline) 'The replaced stage has no recorded baseline.'
        Set-Package $root $commits[4]; Prepare-Package $root $commits[4]
        Assert-True (((Get-StageZips $root) -join ',') -ceq $zipName) 'An orphan package was left in the stage.'
        Assert-True ((Get-FileFixtureIdentity -Path (Join-Path $stage $zipName)) -ceq $identity) 'The recorded package file was replaced instead of rewritten in place.'
        Assert-True ((Get-Snapshot (Join-Path $root 'bin')) -ceq $live) 'The next release changed live products.'
    }
    Test-Case 'Cache-baseline candidate followed by another release is replaced from its own recorded baseline' {
        $root = New-Fixture 'chain-cache'; $stage = Stage-Path $root
        Invoke-Cli $root @('__begin-published-update', $commits[3], $commits[2]) | Out-Null
        Set-Package $root $commits[3]; Prepare-Package $root $commits[3]
        $began = Invoke-Cli $root @('__begin-published-update', $commits[4], $commits[2])
        Assert-True ($began.status -eq 'ready') 'A cache-baseline candidate stopped the next release.'
        $state = Read-Json (State-Path $root)
        Assert-True ($state.candidateCommit -eq $commits[4] -and $state.cacheBaseline.commit -eq $commits[3]) 'The replaced candidate is not the recorded baseline.'
        Set-Package $root $commits[4]; Prepare-Package $root $commits[4]
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $stage 'integration\PRUNLET.md')).Hash -ceq $packages[$commits[4]].manifest.files['bin/PRUNLET.md'].sha256) 'The staged guide was not updated to the next release.'
        Assert-True (@(Get-StageZips $root).Count -eq 1) 'An orphan package was left in the stage.'
    }
    foreach ($manualInstall in @($false, $true)) {
        $suffix = if ($manualInstall) { ' after a manual install' } else { '' }
        Test-Case ('Prepared applied-stage candidate followed by another release keeps its prior provenance and reaches the real switch' + $suffix) {
            $root = New-AppliedFixture ('chain-prior' + $(if ($manualInstall) { '-manual' } else { '' }))
            Invoke-Cli $root @('__begin-published-update', $commits[4], $commits[3]) | Out-Null
            $first = Read-Json (State-Path $root)
            Assert-True ($first.priorStageCommit -eq $commits[3] -and $null -eq $first.cacheBaseline) 'The candidate after an applied stage has no prior provenance.'
            # 候補を準備しても切替が延期され、未適用のままさらに次のreleaseが来る。
            Set-Package $root $commits[4]; Prepare-Package $root $commits[4]
            $installedCommit = $commits[3]
            if ($manualInstall) { $installedCommit = 'f' * 40; $null = Install-ManualRelease $root $installedCommit 'm5' }
            $next = '9' * 40
            if (!$packages.ContainsKey($next)) { New-Package $next }
            $began = Invoke-Cli $root @('__begin-published-update', $next, $installedCommit)
            Assert-True ($began.status -eq 'ready') 'A prepared candidate with prior provenance stopped the next release.'
            $state = Read-Json (State-Path $root)
            Assert-True ($state.candidateCommit -eq $next -and $state.priorStageCommit -eq $commits[3] -and $state.priorStageInfoSha256 -ceq $first.priorStageInfoSha256 -and $null -ne $state.cacheBaseline) 'Prior provenance was not carried beside the new baseline.'
            Set-Package $root $next; Prepare-Package $root $next
            Complete-Update $root
            $state = Read-Json (State-Path $root)
            Assert-True ($null -eq $state.cacheBaseline -and $state.phase -eq 'idle' -and (Read-Json (Join-Path $root 'source-info.json')).commitSha -eq $next) 'The chained candidate did not apply cleanly.'
            if ($manualInstall) { Assert-True ($state.oldCommit -eq $installedCommit) 'The switch did not use the manually installed commit as the baseline.' }
        }
    }
    Test-Case 'An interrupted product slot is resumed under its recorded generation' {
        $root = New-Fixture 'slot-writing'
        $path = State-Path $root; $value = Read-Json $path; $generation = $value.slotCli.generation; $value.slotCli.status = 'writing'; Write-Json $path $value
        $slotFile = Join-Path $root ('.prunlet-update-slots\slot-cli-' + $generation + '.bin')
        # 書込み途中で止まった部分ファイル（書く長さ以下）を再現する。旧fixtureの製品は新製品より長いため、先頭だけ残す。
        $partial = [IO.File]::ReadAllBytes($slotFile)[0..999]
        [IO.File]::WriteAllBytes($slotFile, [byte[]]$partial)
        $identity = Get-FileFixtureIdentity -Path $slotFile
        $began = Invoke-Cli $root @('__begin-published-update', $commits[3], $commits[2])
        Assert-True ($began.status -eq 'ready') 'A writing slot stopped the next release.'
        Set-Package $root $commits[3]; Prepare-Package $root $commits[3]
        $state = Read-Json (State-Path $root)
        Assert-True ($state.slotCli.generation -ceq $generation -and $state.slotCli.status -eq 'ready') 'The writing slot was not resumed under its recorded generation.'
        Assert-True ((Get-FileFixtureIdentity -Path $slotFile) -ceq $identity -and (Get-FileHash -LiteralPath $slotFile).Hash -ceq $packages[$commits[3]].manifest.files['bin/prunlet.exe'].sha256) 'The writing slot was not rewritten in place.'
        Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $root '.prunlet-update-slots') -Filter 'slot-cli-*.bin').Count -eq 1) 'An orphan slot was left behind.'
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
    Test-Case 'Orphaned applied-stage provenance cannot be mixed into an unapplied cache baseline' {
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
        sourceInputs = @('Cargo.toml', 'Cargo.lock', 'src\rust\update\coordinator.rs', 'src\rust\update\state.rs', 'src\rust\update\slot.rs', 'src\rust\update\download.rs', 'src\rust\update\package.rs', 'scripts\Package-PrunletUpdate.ps1', 'scripts\Verify-ReleasePackage.ps1') | ForEach-Object { @{ path = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $sourceRoot $_)).Hash } }
        packages = @($packages.Keys | Sort-Object | ForEach-Object { @{ commit = $_; path = $packages[$_].path; sha256 = $packages[$_].hash; bytes = $packages[$_].bytes; verification = $packages[$_].verified } })
        scope = 'Real CLI begin/prepare; fixed new candidate Core apply/integration/confirm/migration and existing cleanup_pending retention; next release preparation. Applied stage reuse and same-commit resume after a manual install, and tamper rejection after it. Interrupted package download, applied-stage (prepared, with and without a manual install) and cache-baseline candidates followed by another release (including the real switch), unknown stage entries retained untouched, and a writing product slot resumed under its recorded generation. Local real ZIP delivery replaces HTTP only; no old candidate execution or actual host registration.'
        passed = $results.Count - $failed; failed = $failed; cases = @($results); invocations = @($invocations)
        retainedOutputDirectory = $OutputDirectory
    }
    Write-Json $ReportPath $report
}
if (@($results | Where-Object { !$_.passed }).Count) { exit 1 }
