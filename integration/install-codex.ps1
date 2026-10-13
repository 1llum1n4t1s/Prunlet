param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$HookPath,
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [string]$BackupDirectory = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Codex\TaskArtifacts\Prunlet\integration-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')))
)
. (Join-Path $PSScriptRoot 'configuration-common.ps1')
$CodexHome = Resolve-Absolute $CodexHome 'CodexHome'
$BackupDirectory = Assert-ExternalBackup $BackupDirectory $CodexHome
foreach ($pair in @(@($ExecutablePath, 'ExecutablePath'), @($ConfigPath, 'ConfigPath'))) {
    $resolved = Resolve-Absolute $pair[0] $pair[1]
    if (!(Test-Path -LiteralPath $resolved -PathType Leaf)) { throw ($pair[1] + ' does not exist.') }
}
$ExecutablePath = Resolve-Absolute $ExecutablePath 'ExecutablePath'
$ConfigPath = Resolve-Absolute $ConfigPath 'ConfigPath'
if ($HookPath) { $HookPath = Resolve-Absolute $HookPath 'legacy HookPath' }
$prunletConfig = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json -AsHashtable
if ($prunletConfig.schema -ne 1 -or !$prunletConfig.allowedRoots.Count -or !$prunletConfig.backupDirectory) { throw 'Initialize a valid Prunlet config before registering integration.' }
$hooksPath = Join-Path $CodexHome 'hooks.json'
$tomlPath = Join-Path $CodexHome 'config.toml'
$hooks = Read-Hooks $hooksPath
$command = 'call ' + (Quote-CommandArgument $ExecutablePath) + ' --config ' + (Quote-CommandArgument $ConfigPath) + ' hook'
$legacyPaths = @((Join-Path ([IO.Path]::GetDirectoryName($ExecutablePath)) 'codex-pretooluse.ps1'))
if ($HookPath) { $legacyPaths += $HookPath }
$knownCommands = @($command)
foreach ($legacyPath in $legacyPaths) {
    $knownCommands += 'call ' + (Quote-CommandArgument $ExecutablePath) + ' --config ' + (Quote-CommandArgument $ConfigPath) + ' hook --hook-script ' + (Quote-CommandArgument $legacyPath)
    $knownCommands += 'pwsh -NoProfile -NonInteractive -File ' + (Quote-CommandArgument $legacyPath) + ' -ExecutablePath ' + (Quote-CommandArgument $ExecutablePath) + ' -ConfigPath ' + (Quote-CommandArgument $ConfigPath)
}
$handler = @{ type = 'command'; command = $command; timeout = 10; statusMessage = $script:PrunletHookMarker }
$groups = @($hooks.hooks.PreToolUse | Where-Object { $null -ne $_ })
$owned = @($groups | ForEach-Object { $_.hooks } | Where-Object { $_.statusMessage -eq $script:PrunletHookMarker })
if ($owned.Count -gt 1) { throw 'Multiple Prunlet hook handlers found; review before installation.' }
$matcher = '^(Bash|exec_command|functions\.exec_command)$'
$hookChanged = !$owned.Count
if ($owned.Count -eq 1) {
    $ownerGroup = @($groups | Where-Object { @($_.hooks | Where-Object { $_.statusMessage -eq $script:PrunletHookMarker }).Count })
    if ($ownerGroup.Count -ne 1 -or $ownerGroup[0].matcher -cne $matcher -or $owned[0].type -cne 'command' -or $owned[0].timeout -ne 10 -or $owned[0].Keys.Count -ne 4 -or $knownCommands -cnotcontains $owned[0].command) { throw 'Existing Prunlet hook was edited; its registration was preserved.' }
    $hookChanged = $owned[0].command -cne $command
    # 出荷済みの正確な管理commandだけをnative exeの入口へ移す。
    $owned[0].command = $command
} else {
    $groups += @{ matcher = $matcher; hooks = @($handler) }
    $hooks.hooks.PreToolUse = $groups
}
$toml = if (Test-Path -LiteralPath $tomlPath) { [IO.File]::ReadAllText($tomlPath) } else { '' }
Assert-SimpleIntegrationToml $toml
$newline = if ($toml.Contains("`r`n")) { "`r`n" } else { "`n" }
$mcpBlock = (@('# BEGIN PRUNLET MCP', '[mcp_servers.prunlet]', ('command = ' + (Toml-String $ExecutablePath)), ('args = [' + (Toml-String '--config') + ', ' + (Toml-String $ConfigPath) + ', ' + (Toml-String 'mcp') + ']'), '# END PRUNLET MCP') -join $newline) + $newline
$withoutMcp = Remove-OwnedBlock $toml 'MCP'
if ($withoutMcp -match '(?im)^[ \t]*\[[ \t]*["'']?mcp_servers["'']?[ \t]*\.[ \t]*["'']?prunlet["'']?(?:[ \t]*\.|[ \t]*\])' -or $withoutMcp -match '(?im)^[ \t]*["'']?mcp_servers["'']?[ \t]*(?:=|\.[ \t]*["'']?prunlet["'']?[ \t]*\.)') { throw 'An existing or unsupported mcp_servers.prunlet entry requires review; it was not overwritten.' }
$parentMcp = [regex]::Match($withoutMcp, '(?m)^\[mcp_servers\][ \t]*(?:#[^\r\n]*)?\r?\n(?:(?!^\[)[\s\S])*')
if ($parentMcp.Success -and @($parentMcp.Value -split '\r?\n' | Where-Object { (Get-TomlRootKey $_) -ceq 'prunlet' }).Count) { throw 'An existing inline mcp_servers.prunlet entry requires review; it was not overwritten.' }
if ($withoutMcp -cne $toml -and !$toml.Contains($mcpBlock)) { throw 'Existing Prunlet MCP block differs; uninstall it before changing registration.' }
if ($withoutMcp -ceq $toml) { $toml = $toml.TrimEnd("`r", "`n") + $newline + $newline + $mcpBlock }
# features.hooksが明示falseのときは利用者の設定を勝手に反転しない。
$featureTable = [regex]::Match($toml, '(?m)^[ \t]*\[features\][ \t]*(?:#[^\r\n]*)?\r?\n(?:(?!^[ \t]*\[)[\s\S])*')
if ($featureTable.Success) {
    $hookLines = @($featureTable.Value -split '\r?\n' | Where-Object { (Get-TomlRootKey $_) -ceq 'hooks' })
    if ($hookLines.Count -gt 1 -or ($hookLines.Count -eq 1 -and $hookLines[0] -cnotmatch '^[ \t]*hooks[ \t]*=[ \t]*(true|false)[ \t]*(?:#[^\r\n]*)?$')) { throw 'Unsupported or duplicate features.hooks syntax; existing setting was preserved.' }
    $flag = [regex]::Match($featureTable.Value, '(?m)^[ \t]*hooks[ \t]*=[ \t]*(true|false)[ \t]*(?:#[^\r\n]*)?\r?$')
    if ($flag.Success -and $flag.Groups[1].Value -eq 'false') { throw 'features.hooks is false; explicitly enable hooks before installation.' }
    if (!$flag.Success) {
        if ($featureTable.Value -match '(?m)^[ \t]*["'']?hooks["'']?[ \t]*=') { throw 'Unsupported features.hooks syntax; review before installation.' }
        $insertion = '# BEGIN PRUNLET HOOK-FEATURE' + $newline + 'hooks = true' + $newline + '# END PRUNLET HOOK-FEATURE' + $newline
        $headerEnd = $featureTable.Index + $featureTable.Value.IndexOf("`n") + 1
        $toml = $toml.Insert($headerEnd, $insertion)
    }
} elseif ($toml -match '(?m)^[ \t]*(features[ \t]*=|features\.["'']?hooks["'']?[ \t]*=|\[["'']features["'']\])') {
    throw 'Unsupported features syntax; review before installation.'
} else {
    $toml += $newline + '# BEGIN PRUNLET HOOK-FEATURE' + $newline + '[features]' + $newline + 'hooks = true' + $newline + '# END PRUNLET HOOK-FEATURE' + $newline
}
# 両設定の内容を先に構成し、衝突があれば書込み前に停止する。
if ($hookChanged) { Write-PreservedFile $hooksPath ($hooks | ConvertTo-Json -Depth 100) $BackupDirectory }
Write-PreservedFile $tomlPath $toml $BackupDirectory
@{ status = 'installed'; codexHome = $CodexHome; backupRoot = $BackupDirectory; requiresHookTrust = $true; message = 'Review and trust the Prunlet hook through Codex /hooks. Trust settings were not changed.' } | ConvertTo-Json -Compress
