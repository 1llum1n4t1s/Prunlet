#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SourceGuidePath = (Join-Path $PSScriptRoot 'PRUNLET.md'),
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [string]$BackupDirectory = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Codex\TaskArtifacts\Prunlet\agent-instructions-' + [Guid]::NewGuid().ToString('N'))),
    [string]$PreviousGuideSha256,
    [switch]$Uninstall,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'configuration-common.ps1')

function Assert-AgentFilePath([string]$Path) {
    $full = Resolve-Absolute $Path 'Agent instructions path'
    $cursor = $full
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Agent instructions paths cannot traverse links: $cursor" }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    if (Test-Path -LiteralPath $full -PathType Container) { throw "Agent instructions path is a directory: $full" }
    return $full
}
function Get-BytesHash([byte[]]$Bytes) {
    if ($null -eq $Bytes) { $Bytes = [byte[]]::new(0) }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}
function Read-AgentDocument([string]$Path) {
    [byte[]]$bytes = [byte[]]::new(0)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { $bytes = [IO.File]::ReadAllBytes($Path) }
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $prefixLength = 0
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) { $encoding = [Text.UTF32Encoding]::new($false, $false, $true); $prefixLength = 4 }
    elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xfe -and $bytes[3] -eq 0xff) { $encoding = [Text.UTF32Encoding]::new($true, $false, $true); $prefixLength = 4 }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) { $prefixLength = 3 }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe) { $encoding = [Text.UnicodeEncoding]::new($false, $false, $true); $prefixLength = 2 }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xfe -and $bytes[1] -eq 0xff) { $encoding = [Text.UnicodeEncoding]::new($true, $false, $true); $prefixLength = 2 }
    [byte[]]$prefix = if ($prefixLength) { $bytes[0..($prefixLength - 1)] } else { @() }
    return @{ bytes = $bytes; text = $encoding.GetString($bytes, $prefixLength, $bytes.Length - $prefixLength); encoding = $encoding; prefix = $prefix }
}
function Encode-AgentDocument($Document, [string]$Text) { return ,([byte[]]($Document.prefix + $Document.encoding.GetBytes($Text))) }

$CodexHome = Resolve-Absolute $CodexHome 'CodexHome'
$BackupDirectory = Assert-ExternalBackup $BackupDirectory $CodexHome
$agentPath = Assert-AgentFilePath (Join-Path $CodexHome 'AGENTS.md')
$guidePath = Assert-AgentFilePath (Join-Path $CodexHome 'PRUNLET.md')
$document = Read-AgentDocument $agentPath
$begin = '<!-- BEGIN PRUNLET AGENT-INSTRUCTIONS -->'
$end = '<!-- END PRUNLET AGENT-INSTRUCTIONS -->'
$instruction = 'Windowsのファイル削除では、[PRUNLET.md](PRUNLET.md)を読み、Prunlet MCPの`delete_files`を最初から使う。'
$guideHeader = '<!-- Prunlet managed agent instructions -->'
$begins = [regex]::Matches($document.text, 'BEGIN PRUNLET AGENT-INSTRUCTIONS')
$ends = [regex]::Matches($document.text, 'END PRUNLET AGENT-INSTRUCTIONS')
$owned = $begins.Count -gt 0 -or $ends.Count -gt 0
$guideExists = Test-Path -LiteralPath $guidePath -PathType Leaf
$blockMatch = $null
if ($owned) {
    if ($begins.Count -ne 1 -or $ends.Count -ne 1) { throw 'Duplicate or incomplete Prunlet agent instruction markers; existing instructions were preserved.' }
    $pattern = [regex]::Escape($begin) + '(?<newline>\r\n|\n|\r)' + [regex]::Escape($instruction) + '\k<newline>' + [regex]::Escape($end) + '\k<newline>'
    $blockMatch = [regex]::Match($document.text, $pattern)
    if (!$blockMatch.Success) { throw 'The Prunlet agent instruction block was edited or is incomplete; it was preserved.' }
    if (!$guideExists) { throw 'Owned agent instructions have no PRUNLET.md guide; review before changing registration.' }
} elseif ($guideExists) { throw 'An existing PRUNLET.md has no owned agent instruction block; it was preserved.' }

if (!$owned -and $Uninstall) {
    if ($ValidateOnly) { return @{ instructionsPresent = $false } }
    return @{ status = 'unchanged'; instructionsPresent = $false }
}
$SourceGuidePath = Assert-AgentFilePath $SourceGuidePath
if (!(Test-Path -LiteralPath $SourceGuidePath -PathType Leaf)) { throw 'SourceGuidePath does not exist.' }
[byte[]]$sourceBytes = [IO.File]::ReadAllBytes($SourceGuidePath)
if (![IO.File]::ReadAllText($SourceGuidePath).StartsWith($guideHeader, [StringComparison]::Ordinal)) { throw 'Source guide has no Prunlet ownership header.' }
$sourceHash = Get-BytesHash $sourceBytes
if ($guideExists) {
    $guideHash = Get-BytesHash ([IO.File]::ReadAllBytes($guidePath))
    if ($guideHash -cne $sourceHash -and (!$PreviousGuideSha256 -or $guideHash -ine $PreviousGuideSha256)) { throw 'PRUNLET.md was edited or belongs to another registration; it was preserved.' }
    if (![IO.File]::ReadAllText($guidePath).StartsWith($guideHeader, [StringComparison]::Ordinal)) { throw 'Existing PRUNLET.md has no Prunlet ownership header.' }
}
if ($Uninstall) { $updatedText = $document.text.Remove($blockMatch.Index, $blockMatch.Length) }
elseif ($owned) { $updatedText = $document.text }
else {
    $newlineMatch = [regex]::Match($document.text, '\r\n|\n|\r')
    $newline = if ($newlineMatch.Success) { $newlineMatch.Value } else { [Environment]::NewLine }
    $block = $begin + $newline + $instruction + $newline + $end + $newline
    # 文書先頭なら既存のコード例や末尾の未閉鎖フェンスへ指示が入り込まない。
    # BOMは別に保持し、既存本文のバイト列と末尾の改行は変更しない。
    $updatedText = $block + $document.text
}
if ($ValidateOnly) { return @{ instructionsPresent = $owned; agentPath = $agentPath; guidePath = $guidePath } }
[byte[]]$updatedAgent = Encode-AgentDocument $document $updatedText
$changes = [Collections.Generic.List[object]]::new()
if ((Get-BytesHash $updatedAgent) -cne (Get-BytesHash $document.bytes)) { $changes.Add(@{ target = $agentPath; bytes = $updatedAgent; remove = $false }) }
if ($Uninstall) { $changes.Add(@{ target = $guidePath; bytes = $null; remove = $true }) }
elseif (!$guideExists -or $guideHash -cne $sourceHash) { $changes.Add(@{ target = $guidePath; bytes = $sourceBytes; remove = $false }) }
if (!$changes.Count) { return @{ status = 'unchanged'; instructionsPresent = $true; agentPath = $agentPath; guidePath = $guidePath } }
$snapshots = [Collections.Generic.List[object]]::new()
$changed = [Collections.Generic.List[object]]::new()
$backupRoot = Join-Path $BackupDirectory ('agent-instructions-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($backupRoot) | Out-Null
foreach ($change in $changes) {
    $existed = Test-Path -LiteralPath $change.target -PathType Leaf
    $backup = $null; $hash = $null
    if ($existed) {
        $backup = Join-Path $backupRoot ([IO.Path]::GetFileName($change.target))
        [IO.File]::WriteAllBytes($backup, [IO.File]::ReadAllBytes($change.target))
        $hash = Get-BytesHash ([IO.File]::ReadAllBytes($backup))
    }
    $snapshots.Add(@{ target = $change.target; existed = $existed; backup = $backup; sha256 = $hash })
}
[IO.File]::WriteAllText((Join-Path $backupRoot 'backup-info.json'), (@{ files = @($snapshots.ToArray()); restore = 'Restore originally existing targets from their byte-preserving backups; remove newly created targets after reviewing current contents.'; retention = 'Keep until instruction registration or removal is verified; delete this backup when no recovery is required.' } | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
try {
    [IO.Directory]::CreateDirectory($CodexHome) | Out-Null
    foreach ($change in $changes) {
        [void](Assert-AgentFilePath $change.target)
        $changed.Add($change)
        if ($change.remove) { Remove-Item -LiteralPath $change.target }
        else { [IO.File]::WriteAllBytes($change.target, $change.bytes) }
    }
} catch {
    $original = $_
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($snapshot in $snapshots | Where-Object { $_.target -in $changed.target }) {
        try {
            [void](Assert-AgentFilePath $snapshot.target)
            if ($snapshot.existed) {
                if ((Test-Path -LiteralPath $snapshot.target -PathType Leaf) -and (Get-BytesHash ([IO.File]::ReadAllBytes($snapshot.target))) -ceq $snapshot.sha256) { continue }
                [IO.File]::WriteAllBytes($snapshot.target, [IO.File]::ReadAllBytes($snapshot.backup))
            } elseif (Test-Path -LiteralPath $snapshot.target -PathType Leaf) { Remove-Item -LiteralPath $snapshot.target }
        } catch { $errors.Add("$($snapshot.target): $_") }
    }
    if ($errors.Count) { throw "Agent instruction update failed: $original. Restore files from ${backupRoot}: $($errors -join '; ')" }
    throw $original
}
@{ status = $(if ($Uninstall) { 'uninstalled' } else { 'installed' }); instructionsPresent = !$Uninstall; agentPath = $agentPath; guidePath = $guidePath; backupRoot = $backupRoot }
