param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$MoveExecutablePath,
    [ValidateSet('Prepare', 'Current', 'Run')][string]$Mode = 'Prepare',
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
    foreach ($name in @('SessionE2E.Common.ps1','SessionLockCases.ps1','Invoke-SessionE2E.ps1','NativeController.ps1','LimitedSession.ps1','ElevatedClient.ps1','FixtureNative.cs','SessionFixture.cs')) {
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
        $normal = $current.Clone(); $normal.registryScope = 'nativeWindows'; $normal.registrySessionFile = Join-Path $OutputDirectory 'native-session.json'
        $nativeConfigPath = Join-Path $OutputDirectory 'config.json'; SaveJson $nativeConfigPath $normal
        # 通常clientと管理者clientはそれぞれ同じAuthIDの明示sessionだけへ接続する。
        $high = $normal.Clone(); $high.registrySessionFile = Join-Path $OutputDirectory 'native-high-session.json'
        $highConfigPath = Join-Path $OutputDirectory 'high-config.json'; SaveJson $highConfigPath $high
        $registryVerificationScriptPath = Join-Path $PSScriptRoot 'Verify-RegistryRecovery.ps1'
        SaveJson $settingsPath @{executablePath=$ExecutablePath; executableSha256=(Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash; powerShellHostPath=$powerShellHostPath; moveExecutablePath=$MoveExecutablePath; moveExecutableSha256=$(if ($MoveExecutablePath) {(Get-FileHash -LiteralPath $MoveExecutablePath -Algorithm SHA256).Hash} else {$null}); registryVerificationScriptPath=$registryVerificationScriptPath; registryVerificationScriptSha256=(Get-FileHash -LiteralPath $registryVerificationScriptPath -Algorithm SHA256).Hash; config=$nativeConfigPath; highConfig=$highConfigPath; currentConfig=$currentConfigPath; runRelative=('Software\PrunletE2E\' + [guid]::NewGuid().ToString('N')); recovery=$recovery; reportPath=$ReportPath; expectedCurrentSoftwareTransactionError=$ExpectedCurrentSoftwareTransactionError}
    } finally { $env:TEMP = $oldTemp; $env:TMP = $oldTmp }
    # 通常sessionと管理者controllerは利用者が別々に明示起動する。自動昇格・タスク登録をしない。
    $quote = { param($value) "'" + $value.Replace("'", "''") + "'" }
    $hostCommand = '& ' + (& $quote $powerShellHostPath)
    [ordered]@{
        status='awaiting_explicit_desktop_sessions'
        powerShellHostPath=$powerShellHostPath
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
$settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json -AsHashtable
if ($settings.executablePath -cne $ExecutablePath -or $settings.reportPath -cne $ReportPath -or $settings.executableSha256 -cne (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash) { throw 'Prepared executable/report changed.' }
if ($Mode -eq 'Current') {
    $currentReport = Join-Path $OutputDirectory 'current-probes-report.json'
    if (Test-Path -LiteralPath $currentReport) { throw 'Current probes already ran; use a new prepared directory.' }
    & (Join-Path $OutputDirectory 'Invoke-SessionE2E.ps1') -ExecutablePath $ExecutablePath -ReportPath $currentReport -CurrentOnly -ExpectedCurrentSoftwareTransactionError $settings.expectedCurrentSoftwareTransactionError
    if (!$?) { exit 1 }; exit 0
}
foreach ($name in @('controller-ready.json','limited-ready.json')) {
    if (![IO.File]::Exists((Join-Path $OutputDirectory $name))) { throw "Missing explicit desktop session: $name. Run both prepared desktop commands first." }
}
if (Test-Path -LiteralPath (Join-Path $OutputDirectory 'run-started.json')) { throw 'Run directory already consumed; Prepare a new directory.' }
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'run-started.json'), '{"started":true}', $utf8)
$oldTemp = $env:TEMP; $oldTmp = $env:TMP
try {
    & (Join-Path $OutputDirectory 'Invoke-SessionE2E.ps1') -ExecutablePath $ExecutablePath -ReportPath $ReportPath -ExpectedCurrentSoftwareTransactionError $settings.expectedCurrentSoftwareTransactionError
    if (!$?) { exit 1 }
} finally { $env:TEMP = $oldTemp; $env:TMP = $oldTmp }
