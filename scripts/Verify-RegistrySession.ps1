param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$MoveExecutablePath,
    [string]$AssemblyPath,
    [string]$LegacyRegistryExecutablePath,
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
    Assert-VerificationDestination $path @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
    if (![IO.Path]::GetPathRoot($path).Equals('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Session verification requires external D: output.' }
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { throw 'Create external output/report parents first.' }
}
if ($ReportPath.Equals($OutputDirectory, [StringComparison]::OrdinalIgnoreCase) -or $ReportPath.StartsWith($OutputDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Report must be outside the new output directory.' }
if (Test-Path -LiteralPath $ReportPath) { throw 'Report must be new.' }
$settingsPath = Join-Path $OutputDirectory 'settings.json'
$utf8 = [Text.UTF8Encoding]::new($false)
if ($Mode -eq 'Prepare') {
    if (Test-Path -LiteralPath $OutputDirectory) { throw 'Prepare requires a new output directory.' }
    # capabilityを含む子ファイルは、最初の作成から本人とSYSTEMだけへ公開する。
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($sid); $security.SetAccessRuleProtection($true, $false)
    foreach ($principal in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit', [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    $null = [IO.FileSystemAclExtensions]::CreateDirectory($security, $OutputDirectory)
    foreach ($name in @('SessionLaunch.ps1','SessionLaunchNative.cs','SessionE2E.Common.ps1','SessionLockCases.ps1','Invoke-SessionE2E.ps1','NativeController.ps1','LimitedSession.ps1','ElevatedClient.ps1','FixtureNative.cs','SessionFixture.cs')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('registry-session-e2e\' + $name)) -Destination (Join-Path $OutputDirectory $name)
    }
    $null = [IO.Directory]::CreateDirectory((Join-Path $OutputDirectory 'temp'))
    $null = [IO.Directory]::CreateDirectory((Join-Path $OutputDirectory 'metadata'))
    $oldTemp = $env:TEMP; $oldTmp = $env:TMP
    try {
        $env:TEMP = Join-Path $OutputDirectory 'temp'; $env:TMP = $env:TEMP
        . (Join-Path $OutputDirectory 'SessionE2E.Common.ps1')
        $script:ExecutablePath = $ExecutablePath
        $currentConfigPath = Join-Path $OutputDirectory 'current-config.json'
        $script:Config = $currentConfigPath
        $recovery = Join-Path $OutputDirectory 'metadata'
        $init = InvokePrunletCli @('init', '--backup-directory', $recovery)
        Assert ($init.exitCode -eq 0) ('Init failed: ' + $init.stdout + $init.stderr)
        $current = ReadJson $currentConfigPath
        $current.registryScope = 'current'; $null = $current.Remove('registrySessionFile')
        $current.volumeRecoveryDirectories = @{'D:/' = ((Join-Path $OutputDirectory 'volume-store') + '\')}
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
        if (!('SessionE2ENative' -as [type])) { Add-Type -Path (Join-Path $OutputDirectory 'SessionFixture.cs') }
        SaveJson $settingsPath @{preparedToken=[SessionE2ENative]::TokenInfo();configFingerprints=@{config=[SessionE2ENative]::Fingerprint([IO.File]::ReadAllText($nativeConfigPath));highConfig=[SessionE2ENative]::Fingerprint([IO.File]::ReadAllText($highConfigPath))};executablePath=$ExecutablePath; executableSha256=(Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash; powerShellHostPath=$powerShellHostPath; moveExecutablePath=$MoveExecutablePath; moveExecutableSha256=$(if ($MoveExecutablePath) {(Get-FileHash -LiteralPath $MoveExecutablePath -Algorithm SHA256).Hash} else {$null}); registryVerificationScriptPath=$registryVerificationScriptPath; registryVerificationScriptSha256=(Get-FileHash -LiteralPath $registryVerificationScriptPath -Algorithm SHA256).Hash; config=$nativeConfigPath; highConfig=$highConfigPath; currentConfig=$currentConfigPath; runRelative=('Software\PrunletE2E\' + [guid]::NewGuid().ToString('N')); recovery=$recovery; reportPath=$ReportPath; expectedCurrentSoftwareTransactionError=$ExpectedCurrentSoftwareTransactionError}
    } finally { $env:TEMP = $oldTemp; $env:TMP = $oldTmp }
    $preparedSettings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json -AsHashtable
    $preparedSettings.schema = 2; $preparedSettings.nonce = [guid]::NewGuid().ToString('N')
    $preparedSettings.assemblyPath = $AssemblyPath
    $preparedSettings.assemblySha256 = if ($AssemblyPath) { (Get-FileHash -LiteralPath $AssemblyPath).Hash } else { $null }
    $preparedSettings.legacyRegistryExecutablePath = $LegacyRegistryExecutablePath
    $preparedSettings.legacyRegistryExecutableSha256 = if ($LegacyRegistryExecutablePath) { (Get-FileHash -LiteralPath $LegacyRegistryExecutablePath).Hash } else { $null }
    $preparedSettings.inputs = @()
    $preparedInputs = @([IO.Directory]::EnumerateFiles($OutputDirectory) | Where-Object { [IO.Path]::GetExtension($_) -in @('.ps1','.cs') }) + @($PSCommandPath, (Join-Path $PSScriptRoot 'registry-session-e2e\SessionLaunch.ps1'), $registryVerificationScriptPath, (Join-Path $PSScriptRoot 'Verification-Common.ps1'), $ExecutablePath, $powerShellHostPath)
    # registry runnerが実際に読むWindowsごみ箱検証の依存も同じPrepare入力へ固定する。
    foreach ($name in @('Common.ps1','NativeShellFixture.cs','FixtureNative.cs','OwnedBinLocator.cs','PermissionFixture.cs','RegistryCheckpointHost.ps1')) {
        $preparedInputs += Join-Path (Join-Path $PSScriptRoot 'recordless-e2e') $name
    }
    $preparedInputs += Join-Path $PSScriptRoot 'registry-session-e2e/RegistryControlCases.ps1'
    foreach ($dependency in @($AssemblyPath,$LegacyRegistryExecutablePath) | Where-Object { $_ }) {
        if (![IO.Path]::IsPathFullyQualified($dependency) -or ![IO.File]::Exists($dependency)) { throw 'Checkpoint dependency must be an existing absolute candidate/baseline path.' }
        $preparedInputs += $dependency
    }
    if ($MoveExecutablePath) { $preparedInputs += $MoveExecutablePath }
    foreach ($preparedInput in ($preparedInputs | Select-Object -Unique)) {
        $preparedSettings.inputs += @{path=[IO.Path]::GetFullPath($preparedInput);sha256=(Get-FileHash -LiteralPath $preparedInput -Algorithm SHA256).Hash}
    }
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
if ($Mode -in @('Start', 'Run') -and [string]::IsNullOrWhiteSpace($settings.moveExecutablePath)) {
    throw 'Full native validation requires Prepare -MoveExecutablePath with the genuine schema4 baseline. No desktop session was launched.'
}
if (!('SessionE2ENative' -as [type])) { Add-Type -Path (Join-Path $OutputDirectory 'SessionFixture.cs') }
if (!('SessionLaunchNative' -as [type])) { Add-Type -Path (Join-Path $OutputDirectory 'SessionLaunchNative.cs') }
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
    if (!$?) { exit 1 }; exit 0
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
