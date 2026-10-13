param(
    [string]$ExecutablePath = (Join-Path $PSScriptRoot 'prunlet.exe'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.json'),
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [string]$BackupDirectory = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Codex\TaskArtifacts\Prunlet\integration-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')))
)
. (Join-Path $PSScriptRoot 'configuration-common.ps1')
$CodexHome = Resolve-Absolute $CodexHome 'CodexHome'
$BackupDirectory = Assert-ExternalBackup $BackupDirectory $CodexHome
$hooksPath = Join-Path $CodexHome 'hooks.json'
$tomlPath = Join-Path $CodexHome 'config.toml'
$toml = if (Test-Path -LiteralPath $tomlPath) { [IO.File]::ReadAllText($tomlPath) } else { '' }
Assert-SimpleIntegrationToml $toml
$updatedToml = Remove-OwnedBlock (Remove-OwnedBlock $toml 'MCP') 'HOOK-FEATURE'
# 利用者が編集した指示やガイドは、MCP・フックを変更する前に検査して保持する。
$agentHelper = Join-Path $PSScriptRoot 'install-agent-instructions.ps1'
$agentParameters = @{ CodexHome = $CodexHome; BackupDirectory = $BackupDirectory; SourceGuidePath = (Join-Path $PSScriptRoot 'PRUNLET.md'); ExecutablePath = $ExecutablePath; ConfigPath = $ConfigPath; Uninstall = $true }
if (Test-Path -LiteralPath $agentHelper -PathType Leaf) {
    $agentState = & $agentHelper @agentParameters -ValidateOnly
    if ($agentState.instructionsPresent) { & $agentHelper @agentParameters | Out-Null }
}
if (Test-Path -LiteralPath $hooksPath) {
    $hooks = Read-Hooks $hooksPath
    $groups = @(); $changed = $false
    foreach ($group in @($hooks.hooks.PreToolUse | Where-Object { $null -ne $_ })) {
        $remaining = @($group.hooks | Where-Object { $_.statusMessage -ne $script:PrunletHookMarker })
        if ($remaining.Count -ne @($group.hooks).Count) {
            $changed = $true
            if ($remaining.Count) { $group.hooks = $remaining; $groups += $group }
        } else { $groups += $group }
    }
    if ($changed) { $hooks.hooks.PreToolUse = $groups; Write-PreservedFile $hooksPath ($hooks | ConvertTo-Json -Depth 100) $BackupDirectory }
}
if ($updatedToml -cne $toml) { Write-PreservedFile $tomlPath $updatedToml $BackupDirectory }
@{ status = 'uninstalled'; codexHome = $CodexHome; backupRoot = $BackupDirectory; message = 'Executable, deletion backup and Prunlet config were retained.' } | ConvertTo-Json -Compress
