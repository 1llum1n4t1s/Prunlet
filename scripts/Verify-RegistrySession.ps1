param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$MoveExecutablePath,
    [string]$RustProbePath,
    [string]$BuildManifestPath,
    [string]$ExpectedBuildManifestSha256,
    [string]$LegacyRegistryExecutablePath,
    [string]$LatestRegistryExecutablePath,
    [string]$FixtureRoot,
    [switch]$AssertNativeWindows,
    [ValidateSet('Prepare', 'Start', 'Current', 'Run')][string]$Mode = 'Prepare',
    [ValidateSet(-1, 0, 6801)][int]$ExpectedCurrentSoftwareTransactionError = -1
)
$ErrorActionPreference = 'Stop'
$powerShellHostPath = [IO.Path]::GetFullPath((Join-Path $PSHOME 'pwsh.exe'))
if (![IO.File]::Exists($powerShellHostPath)) { throw 'Current PowerShell host executable missing.' }
# 想定する失敗: scope/view混同、生bytes・class・完全ACLの欠落、既存復元先の上書き、
# current Softwareの6801拒否時の変更、60秒超の待機中断、進捗漏れ、切断後の未確定、
# 不正descriptorの受理、セッション未起動の成功扱い、他実行のfixture・出力への書込み。
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'Executable/output/report paths must be absolute.' }
}
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
if (![IO.File]::Exists($ExecutablePath)) { throw 'Executable missing.' }
if ($MoveExecutablePath) {
    if (![IO.Path]::IsPathFullyQualified($MoveExecutablePath)) { throw 'MoveExecutablePath must be absolute.' }
    $MoveExecutablePath = [IO.Path]::GetFullPath($MoveExecutablePath)
    if (![IO.File]::Exists($MoveExecutablePath)) { throw 'MoveExecutablePath missing.' }
}
foreach ($path in @($OutputDirectory, $ReportPath)) {
    Assert-ExternalVerificationPath $path @($repoRoot, $codexRoot)
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { throw 'Create external output/report parents first.' }
}
if ($ReportPath.Equals($OutputDirectory, [StringComparison]::OrdinalIgnoreCase) -or $ReportPath.StartsWith($OutputDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Report must be outside the new output directory.' }
if (Test-Path -LiteralPath $ReportPath) { throw 'Report must be new.' }
$settingsPath = Join-Path $OutputDirectory 'settings.json'
$utf8 = [Text.UTF8Encoding]::new($false)
if ($Mode -eq 'Prepare') {
    if ($RustProbePath) {
        if (!$BuildManifestPath -or !$ExpectedBuildManifestSha256) { throw 'Rust probe requires a fixed same-source build manifest and SHA-256.' }
        $repo = $repoRoot
        . (Join-Path $PSScriptRoot 'recordless-e2e/RustFileProbe.Common.ps1')
        $preparedBuildBinding = Assert-RustFileProbeBinding
    } elseif ($BuildManifestPath -or $ExpectedBuildManifestSha256) { throw 'Build manifest is only accepted with RustProbePath.' }
    if (Test-Path -LiteralPath $OutputDirectory) { throw 'Prepare requires a new output directory.' }
    # capabilityを含む子ファイルは、最初の作成から本人とSYSTEMだけへ公開する。
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($sid); $security.SetAccessRuleProtection($true, $false)
    foreach ($principal in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit', [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    $null = [IO.FileSystemAclExtensions]::CreateDirectory($security, $OutputDirectory)
    foreach ($name in @('RustProbe.Common.ps1','SessionLaunch.ps1','SessionE2E.Common.ps1','SessionLockCases.ps1','Invoke-SessionE2E.ps1','NativeController.ps1','LimitedSession.ps1','ElevatedClient.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('registry-session-e2e\' + $name)) -Destination (Join-Path $OutputDirectory $name)
    }
    foreach ($name in @('FixtureBridge.Common.ps1','SessionFixtures.Common.ps1','RegistryFixtures.Common.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $OutputDirectory $name) }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'integration/configuration-common.ps1') -Destination (Join-Path $OutputDirectory 'configuration-common.ps1')
    $null = [IO.Directory]::CreateDirectory((Join-Path $OutputDirectory 'temp'))
    $null = [IO.Directory]::CreateDirectory((Join-Path $OutputDirectory 'metadata'))
    $oldTemp = $env:TEMP; $oldTmp = $env:TMP
    try {
        $env:TEMP = Join-Path $OutputDirectory 'temp'; $env:TMP = $env:TEMP
        . (Join-Path $OutputDirectory 'SessionE2E.Common.ps1')
        $null = Initialize-PrunletFixtureBinding -ExecutablePath $ExecutablePath -BuildManifestPath $BuildManifestPath -ExpectedBuildManifestSha256 $ExpectedBuildManifestSha256 -SourceRoot $repoRoot
        $fixtureBinding = Get-PrunletFixtureProcessBinding
        $script:ExecutablePath = $ExecutablePath
        $currentConfigPath = Join-Path $OutputDirectory 'current-config.json'
        $script:Config = $currentConfigPath
        $recovery = Join-Path $OutputDirectory 'metadata'
        $init = InvokePrunletCli @('init', '--backup-directory', $recovery)
        Assert ($init.exitCode -eq 0) ('Init failed: ' + $init.stdout + $init.stderr)
        $current = ReadJson $currentConfigPath
        $current.registryScope = 'current'; $null = $current.Remove('registrySessionFile')
        # キーは出力先volumeのroot。従来どおり区切りを'/'にした表記で設定の正規化も確認する。
        $volumeStore = Join-Path $OutputDirectory 'volume-store'
        $current.volumeRecoveryDirectories = @{((Get-VerificationVolumeRoot $volumeStore).Replace('\', '/')) = ($volumeStore + '\')}
        $current.backupDirectory = $recovery.Replace('\', '/') + '/'; $current.allowedRoots = $null
        SaveJson $currentConfigPath $current
        $migration = InvokePrunletCli @('migrate','--apply')
        Assert ($migration.exitCode -eq 0 -and $migration.json.registryReady -and $migration.json.complete) 'Fresh registry namespace preparation failed'
        $normal = $current.Clone(); $normal.registryScope = 'nativeWindows'; $normal.registrySessionFile = Join-Path $OutputDirectory 'native-session.json'
        $nativeConfigPath = Join-Path $OutputDirectory 'config.json'; SaveJson $nativeConfigPath $normal
        # 通常clientと管理者clientはそれぞれ同じAuthIDの明示sessionだけへ接続する。
        $high = $normal.Clone(); $high.registrySessionFile = Join-Path $OutputDirectory 'native-high-session.json'
        $highConfigPath = Join-Path $OutputDirectory 'high-config.json'; SaveJson $highConfigPath $high
        $registryVerificationScriptPath = Join-Path $PSScriptRoot 'Verify-RegistryRecovery.ps1'
        SaveJson $settingsPath @{preparedToken=(Get-SessionFixtureTokenInfo);configFingerprints=@{config=(Get-SessionFixtureFingerprint ([IO.File]::ReadAllText($nativeConfigPath)));highConfig=(Get-SessionFixtureFingerprint ([IO.File]::ReadAllText($highConfigPath)))};executablePath=$ExecutablePath; executableSha256=(Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash; powerShellHostPath=$powerShellHostPath; moveExecutablePath=$MoveExecutablePath; moveExecutableSha256=$(if ($MoveExecutablePath) {(Get-FileHash -LiteralPath $MoveExecutablePath -Algorithm SHA256).Hash} else {$null}); registryVerificationScriptPath=$registryVerificationScriptPath; registryVerificationScriptSha256=(Get-FileHash -LiteralPath $registryVerificationScriptPath -Algorithm SHA256).Hash; config=$nativeConfigPath; highConfig=$highConfigPath; currentConfig=$currentConfigPath; runRelative=('Software\PrunletE2E\' + [guid]::NewGuid().ToString('N')); recovery=$recovery; reportPath=$ReportPath; expectedCurrentSoftwareTransactionError=$ExpectedCurrentSoftwareTransactionError}
    } finally { $env:TEMP = $oldTemp; $env:TMP = $oldTmp }
    $preparedSettings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json -AsHashtable
    $preparedSettings.schema = 2; $preparedSettings.nonce = [guid]::NewGuid().ToString('N')
    $preparedSettings.fixtureLibraryPath = $fixtureBinding.path
    $preparedSettings.fixtureLibrarySha256 = $fixtureBinding.sha256
    $preparedSettings.fixtureManifestPath = $fixtureBinding.manifestPath
    $preparedSettings.fixtureManifestSha256 = $fixtureBinding.manifestHash
    $preparedSettings.fixtureSourceRoot = $repoRoot
    $preparedSettings.candidateRuntime = if ($RustProbePath) { 'rust-libtest' } else { 'unconfigured' }
    $preparedSettings.rustSourceRoot = if ($RustProbePath) { $repoRoot } else { $null }
    $preparedSettings.rustProbePath = $RustProbePath
    $preparedSettings.rustProbeSha256 = if ($RustProbePath) { (Get-FileHash -LiteralPath $RustProbePath -Algorithm SHA256).Hash } else { $null }
    $preparedSettings.buildManifestPath = if ($RustProbePath) { [IO.Path]::GetFullPath($BuildManifestPath) } else { $null }
    $preparedSettings.buildManifestSha256 = if ($RustProbePath) { $preparedBuildBinding.manifestSha256 } else { $null }
    $preparedSettings.sourceFingerprint = if ($RustProbePath) { $preparedBuildBinding.sourceFingerprint } else { $null }
    if ($FixtureRoot) {
        if (![IO.Path]::IsPathFullyQualified($FixtureRoot) -or ![IO.Directory]::Exists($FixtureRoot)) { throw 'FixtureRoot must be an existing absolute directory.' }
        Assert-VerificationDestination $FixtureRoot @($repoRoot,$codexRoot)
    }
    $preparedSettings.fixtureRoot = $FixtureRoot
    $preparedSettings.latestRegistryExecutablePath = $LatestRegistryExecutablePath
    $preparedSettings.latestRegistryExecutableSha256 = if ($LatestRegistryExecutablePath) { (Get-FileHash -LiteralPath $LatestRegistryExecutablePath).Hash } else { $null }
    $preparedSettings.legacyRegistryExecutablePath = $LegacyRegistryExecutablePath
    $preparedSettings.legacyRegistryExecutableSha256 = if ($LegacyRegistryExecutablePath) { (Get-FileHash -LiteralPath $LegacyRegistryExecutablePath).Hash } else { $null }
    $preparedSettings.inputs = @()
    $preparedSettings.inputs += @{path=(Join-Path $PSScriptRoot 'Verification-Fixture.ps1');sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Verification-Fixture.ps1')).Hash}
    foreach ($name in @('FixtureBridge.Common.ps1','RegistryFixtures.Common.ps1','ProtectedRegistryFixtures.Common.ps1','FileFixtures.Common.ps1')) { $path=Join-Path $PSScriptRoot $name; $preparedSettings.inputs += @{path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash} }
    $preparedInputs = @([IO.Directory]::EnumerateFiles($OutputDirectory) | Where-Object { [IO.Path]::GetExtension($_) -eq '.ps1' }) + @($PSCommandPath, (Join-Path $PSScriptRoot 'registry-session-e2e\SessionLaunch.ps1'), $registryVerificationScriptPath, (Join-Path $PSScriptRoot 'Verification-Common.ps1'), $ExecutablePath, $powerShellHostPath)
    $preparedInputs += @($fixtureBinding.path,$fixtureBinding.manifestPath)
    # Current-onlyでもfixture DLLと同じsourceをPrepare時の入力として固定する。
    . (Join-Path $PSScriptRoot 'RustBuildInputs.Common.ps1')
    $preparedInputs += Join-Path $PSScriptRoot 'RustBuildInputs.Common.ps1'
    $preparedInputs += @(Get-PrunletRustInputNames $repoRoot | ForEach-Object { Join-Path $repoRoot $_ })
    # registry runnerが実際に読むWindowsごみ箱検証の依存も同じPrepare入力へ固定する。
    foreach ($name in @('Common.ps1')) {
        $preparedInputs += Join-Path (Join-Path $PSScriptRoot 'recordless-e2e') $name
    }
    $preparedInputs += Join-Path $PSScriptRoot 'registry-session-e2e/RegistryControlCases.ps1'
    foreach ($dependency in @($RustProbePath,$BuildManifestPath,$LegacyRegistryExecutablePath,$LatestRegistryExecutablePath) | Where-Object { $_ }) {
        if (![IO.Path]::IsPathFullyQualified($dependency) -or ![IO.File]::Exists($dependency)) { throw 'Checkpoint dependency must be an existing absolute candidate/baseline path.' }
        $preparedInputs += $dependency
    }
    if ($RustProbePath) {
        $preparedInputs += @(Get-PrunletRustInputNames $repoRoot | ForEach-Object { Join-Path $repoRoot $_ })
        foreach ($name in @('registry-session-e2e/RustProbe.Common.ps1','recordless-e2e/RustFileProbe.Common.ps1','RustBuildInputs.Common.ps1')) { $preparedInputs += Join-Path $PSScriptRoot $name }
        if ((Get-RustFileSourceFingerprint $repoRoot) -cne $preparedBuildBinding.sourceFingerprint) { throw 'Rust inputs changed during Prepare.' }
    }
    if ($MoveExecutablePath) { $preparedInputs += $MoveExecutablePath }
    foreach ($preparedInput in ($preparedInputs | Select-Object -Unique)) {
        $preparedSettings.inputs += @{path=[IO.Path]::GetFullPath($preparedInput);sha256=(Get-FileHash -LiteralPath $preparedInput -Algorithm SHA256).Hash}
    }
    $fixtureManifest = [IO.File]::ReadAllText($fixtureBinding.manifestPath) | ConvertFrom-Json -AsHashtable -Depth 100
    if ((Get-PrunletRustInputSnapshot $repoRoot).fingerprint -cne $fixtureManifest.sourceFingerprint) { throw 'Fixture Rust inputs changed while hashing Prepare dependencies.' }
    if ($RustProbePath -and (Get-RustFileSourceFingerprint $repoRoot) -cne $preparedBuildBinding.sourceFingerprint) { throw 'Rust inputs changed while hashing Prepare dependencies.' }
    SaveJson $settingsPath $preparedSettings
    # manualコマンドは診断互換として保持する。通常の検証起動はStartで同一scopeへ限定する。
    $quote = { param($value) "'" + $value.Replace("'", "''") + "'" }
    $hostCommand = '& ' + (& $quote $powerShellHostPath)
    [ordered]@{
        status='prepared';schema=2;startRequiresAssertNativeWindows=$true
        powerShellHostPath=$powerShellHostPath
        startCommand=($hostCommand + ' -NoProfile -File ' + (& $quote $PSCommandPath) + ' -Mode Start -AssertNativeWindows -ExecutablePath ' + (& $quote $ExecutablePath) + ' -OutputDirectory ' + (& $quote $OutputDirectory) + ' -ReportPath ' + (& $quote $ReportPath))
        currentCommand=($hostCommand + ' -NoProfile -File ' + (& $quote $PSCommandPath) + ' -Mode Current -ExecutablePath ' + (& $quote $ExecutablePath) + ' -OutputDirectory ' + (& $quote $OutputDirectory) + ' -ReportPath ' + (& $quote $ReportPath))
        normalDesktopCommand=($hostCommand + ' -NoProfile -File ' + (& $quote (Join-Path $OutputDirectory 'LimitedSession.ps1')) + ' -SettingsPath ' + (& $quote $settingsPath))
        normalRunDialogCommand=('"' + $powerShellHostPath + '" -NoProfile -File "' + (Join-Path $OutputDirectory 'LimitedSession.ps1') + '" -SettingsPath "' + $settingsPath + '"')
        administratorDesktopCommand=($hostCommand + ' -NoProfile -File ' + (& $quote (Join-Path $OutputDirectory 'NativeController.ps1')) + ' -SettingsPath ' + (& $quote $settingsPath))
        runDialogCommand=('"' + $powerShellHostPath + '" -NoProfile -File "' + (Join-Path $OutputDirectory 'NativeController.ps1') + '" -SettingsPath "' + $settingsPath + '"')
        runCommand=($hostCommand + ' -NoProfile -File ' + (& $quote $PSCommandPath) + ' -Mode Run -ExecutablePath ' + (& $quote $ExecutablePath) + ' -OutputDirectory ' + (& $quote $OutputDirectory) + ' -ReportPath ' + (& $quote $ReportPath))
        outputDirectory=$OutputDirectory
    } | ConvertTo-Json
    exit 0
}
if (![IO.File]::Exists($settingsPath)) { throw 'Run requires a successful Prepare.' }
. (Join-Path $PSScriptRoot 'registry-session-e2e\SessionLaunch.ps1')
$script:LaunchScopeRoot = $OutputDirectory
$settings = OpenPreparedPins $settingsPath
$script:LaunchPrepared=$settings
. (Join-Path $OutputDirectory 'SessionE2E.Common.ps1')
AssertPreparedSettings $settings
# 再指定はPrepare時と同一の場合だけ受け付け、省略時は固定済み値を使う。
foreach ($entry in @(@{name='RustProbePath';actual=$RustProbePath;expected=$settings.rustProbePath},@{name='BuildManifestPath';actual=$BuildManifestPath;expected=$settings.buildManifestPath},@{name='ExpectedBuildManifestSha256';actual=$ExpectedBuildManifestSha256;expected=$settings.buildManifestSha256})) {
    if ($entry.actual -and !$entry.actual.Equals([string]$entry.expected,[StringComparison]::OrdinalIgnoreCase)) { throw ('Prepared candidate selection changed: '+$entry.name) }
}
if ($Mode -in @('Start', 'Run') -and ([string]::IsNullOrWhiteSpace($settings.moveExecutablePath) -or
    [string]::IsNullOrWhiteSpace($settings.rustProbePath) -or [string]::IsNullOrWhiteSpace($settings.legacyRegistryExecutablePath) -or [string]::IsNullOrWhiteSpace($settings.latestRegistryExecutablePath))) {
    throw 'Full native validation requires Prepare -MoveExecutablePath (genuine schema4 baseline), -RustProbePath (same-source test probe), -LegacyRegistryExecutablePath (genuine schema5 baseline), and -LatestRegistryExecutablePath (genuine 1.0.29 producer). No desktop session was launched by this invocation.'
}
$script:LaunchScopeRoot = $OutputDirectory
if ($settings.executablePath -cne $ExecutablePath -or $settings.reportPath -cne $ReportPath -or $settings.executableSha256 -cne (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash) { throw 'Prepared executable/report changed.' }
if ($Mode -eq 'Start') {
    if (!$AssertNativeWindows) { throw 'Start requires explicit -AssertNativeWindows.' }
    StartPreparedDesktopSessions $settings $OutputDirectory $settingsPath
    exit 0
}
if ($Mode -eq 'Current') {
    $currentReport = Join-Path $OutputDirectory 'current-probes-report.json'
    if (Test-Path -LiteralPath $currentReport) { throw 'Current probes already ran; use a new prepared directory.' }
    & (Join-Path $OutputDirectory 'Invoke-SessionE2E.ps1') -ExecutablePath $ExecutablePath -ReportPath $currentReport -CurrentOnly -ExpectedCurrentSoftwareTransactionError $settings.expectedCurrentSoftwareTransactionError
    if (!$?) { exit 1 }
    exit 0
}
foreach ($name in @('controller-ready.json','limited-ready.json')) {
    if (![IO.File]::Exists((Join-Path $OutputDirectory $name))) { throw "Missing explicit desktop session: $name. Run both prepared desktop commands first." }
}
AssertLaunchReady $settings
$runRecord=LaunchProcessRecord; $runRecord.nonce=$settings.nonce
NewLaunchRecord (Join-Path $OutputDirectory 'run-started.json') $runRecord
if ([IO.File]::Exists((Join-Path $OutputDirectory 'start-claim.json'))) {
    AssertLaunchLease $settings
    if (![IO.File]::Exists((Join-Path $OutputDirectory 'start-committed.json'))) { throw 'Start did not commit.' }
    NewLaunchRecord (Join-Path $OutputDirectory 'run-permit.json') $runRecord
}
$oldTemp = $env:TEMP; $oldTmp = $env:TMP
try {
    & (Join-Path $OutputDirectory 'Invoke-SessionE2E.ps1') -ExecutablePath $ExecutablePath -ReportPath $ReportPath -ExpectedCurrentSoftwareTransactionError $settings.expectedCurrentSoftwareTransactionError
    if (!$?) { exit 1 }
} finally { $env:TEMP = $oldTemp; $env:TMP = $oldTmp }
