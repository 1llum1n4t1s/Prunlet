$ErrorActionPreference = 'Stop'
$script:PrunletHookMarker = 'Prunlet: protected literal deletion'
function Resolve-Absolute([string]$Path, [string]$Label) {
    if ($Path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+(?:\\|$))') { throw "$Label must be an absolute Windows path." }
    return [IO.Path]::GetFullPath($Path)
}
function Assert-ExternalBackup([string]$Directory, [string]$CodexDirectory) {
    $resolved = Resolve-Absolute $Directory 'BackupDirectory'
    $homeFull = (Resolve-Absolute $CodexDirectory 'CodexHome').TrimEnd('\', '/')
    $repoFull = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\', '/')
    $userCodex = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex')).TrimEnd('\', '/')
    foreach ($forbidden in @($homeFull, $repoFull, $userCodex)) {
        if ($resolved.Equals($forbidden, [StringComparison]::OrdinalIgnoreCase) -or $resolved.StartsWith($forbidden + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'BackupDirectory must be outside CodexHome, the repository and the user .codex directory.' }
    }
    # リパースポイント経由で禁止保存先へ入ることも拒否する。
    $ancestor = $resolved
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'BackupDirectory must not contain a reparse point.' }
        }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    return $resolved
}
function Write-PreservedFile([string]$Path, [string]$Content, [string]$BackupDirectory) {
    $full = Resolve-Absolute $Path 'configuration path'
    $exists = Test-Path -LiteralPath $full
    if ($exists -and [IO.File]::ReadAllText($full) -ceq $Content) { return }
    [IO.Directory]::CreateDirectory($BackupDirectory) | Out-Null
    $recordId = [Guid]::NewGuid().ToString('N')
    $backup = Join-Path $BackupDirectory (([IO.Path]::GetFileName($full)) + '.' + $recordId + '.bak')
    if ($exists) { [IO.File]::Copy($full, $backup, $false) }
    $record = @{ target = $full; existed = $exists; backup = $(if ($exists) { $backup } else { $null }); restore = $(if ($exists) { 'Copy backup to target after reviewing current contents.' } else { 'Remove the newly created target after reviewing current contents.' }); retention = 'Retain until integration is verified; remove only these backup records after no rollback is required.' }
    [IO.File]::WriteAllText((Join-Path $BackupDirectory ($recordId + '.json')), ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
    [IO.File]::WriteAllText($full, $Content, [Text.UTF8Encoding]::new($false))
}
function Read-Hooks([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) { return @{ hooks = @{} } }
    $document = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
    if ($document -isnot [System.Collections.IDictionary] -or ($document.Contains('hooks') -and $document.hooks -isnot [System.Collections.IDictionary])) { throw 'Existing hooks.json has an unsupported structure.' }
    if (!$document.Contains('hooks')) { $document.hooks = @{} }
    return $document
}
function Quote-CommandArgument([string]$Value) {
    if ($Value -match '["%!^&|<>$`\r\n]') { throw 'Hook command paths must not contain quotes, newlines or cmd/PowerShell expansion characters.' }
    return '"' + $Value + '"'
}
function Toml-String([string]$Value) { return ($Value | ConvertTo-Json -Compress) }
function Get-TomlRootKey([string]$Text) {
    $token = [regex]::Match($Text.TrimStart(), '^(?:([A-Za-z0-9_-]+)|''([^'']*)''|"((?:\\.|[^"\\])*)")')
    if (!$token.Success) { return '' }
    if ($token.Groups[1].Success) { return $token.Groups[1].Value }
    if ($token.Groups[2].Success) { return $token.Groups[2].Value }
    $quoted = $token.Groups[3].Value
    # TOMLの8桁Unicode escapeをJSONで読める文字に変換する。
    $quoted = [regex]::Replace($quoted, '\\U([0-9A-Fa-f]{8})', { param($m) [char]::ConvertFromUtf32([Convert]::ToInt32($m.Groups[1].Value, 16)) })
    return ('"' + $quoted + '"' | ConvertFrom-Json)
}
function Assert-SimpleIntegrationToml([string]$Text) {
    if ($Text.Contains('"""') -or $Text.Contains("'''")) { throw 'Multiline TOML strings require manual integration to avoid altering their contents.' }
    foreach ($line in $Text -split '\r?\n') {
        if ($line -match '^[ \t]*\[') {
            $header = ($line -split '#', 2)[0].TrimEnd()
            $rootKey = Get-TomlRootKey ($header.TrimStart().TrimStart('[').TrimStart())
            $featureHeader = $header.TrimStart()
            if ($rootKey -ceq 'features' -and ($featureHeader -cnotmatch '^\[features(?:\.[A-Za-z0-9_-]+)*\]$' -or $featureHeader -cmatch '^\[features\.hooks(?:\.|\])')) { throw 'Noncanonical features table syntax or a hooks table requires manual integration; existing hook settings were preserved.' }
            if ($rootKey -ceq 'mcp_servers' -and $header -cnotmatch '^\[mcp_servers(?:\.[A-Za-z0-9_-]+)*\]$') { throw 'Noncanonical mcp_servers table syntax requires manual integration.' }
        } elseif ($line -notmatch '^[ \t]*(?:#|$)') {
            $rootKey = Get-TomlRootKey $line
            if ($rootKey -cin @('features', 'mcp_servers')) { throw 'Quoted, inline or dotted integration root keys require manual integration; existing settings were preserved.' }
        }
    }
}
function Test-TomlTrailingValues([string]$Text, [int]$Offset) {
    $after = $Text.Substring($Offset)
    $nextTable = [regex]::Match($after, '(?m)^[ \t]*\[')
    $remainder = if ($nextTable.Success) { $after.Substring(0, $nextTable.Index) } else { $after }
    return @($remainder -split '\r?\n' | Where-Object { $_.Trim() -and $_ -notmatch '^[ \t]*#' }).Count -gt 0
}
function Remove-OwnedBlock([string]$Text, [string]$Name) {
    $pattern = '(?m)^# BEGIN PRUNLET ' + [regex]::Escape($Name) + '\r?\n[\s\S]*?^# END PRUNLET ' + [regex]::Escape($Name) + '(?:\r?\n|$)'
    $matches = [regex]::Matches($Text, $pattern)
    if ($matches.Count -gt 1) { throw "Multiple Prunlet $Name blocks found; configuration requires review." }
    if ($matches.Count -eq 1) {
        $block = $matches[0]
        $lines = @($block.Value -split '\r?\n' | Where-Object { $_ -and $_ -notmatch '^# (?:BEGIN|END) PRUNLET ' })
        if ($Name -eq 'MCP' -and ($lines.Count -ne 3 -or $lines[0] -cne '[mcp_servers.prunlet]' -or $lines[1] -notmatch '^command = "' -or $lines[2] -notmatch '^args = \[')) { throw 'Prunlet MCP block was edited; preserve it and review before uninstall.' }
        if ($Name -eq 'MCP') {
            if (Test-TomlTrailingValues $Text ($block.Index + $block.Length)) {
                throw 'User settings follow the Prunlet MCP marker; review before changing registration to preserve their table ownership.'
            }
        }
        if ($Name -eq 'HOOK-FEATURE') {
            if (@($lines | Where-Object { $_ -cne '[features]' -and $_ -cne 'hooks = true' }).Count -or @($lines | Where-Object { $_ -ceq 'hooks = true' }).Count -ne 1) { throw 'Prunlet hook feature block was edited; preserve it and review before uninstall.' }
            if ($lines -contains '[features]') {
                if (Test-TomlTrailingValues $Text ($block.Index + $block.Length)) {
                    # 利用者が追加したfeatures値の所属テーブルを維持する。
                    return $Text.Remove($block.Index, $block.Length).Insert($block.Index, "[features]`n")
                }
            }
        }
        return $Text.Remove($block.Index, $block.Length)
    }
    if ($Text -match ('(?m)^# (?:BEGIN|END) PRUNLET ' + [regex]::Escape($Name))) { throw "Incomplete Prunlet $Name marker; configuration requires review." }
    return $Text
}
