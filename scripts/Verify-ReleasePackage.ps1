#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$PublishDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$CommitSha,
    [Parameter(Mandatory)][string]$DefaultBranch,
    [Parameter(Mandatory)][ValidateSet('win-x64', 'win-arm64')][string]$Runtime,
    [Parameter(Mandatory)][string]$Repository
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# アップデーターが受け取るファイルと、今回のビルド・sourceを照合する。
$inputs = [ordered]@{
    'bin/prunlet.exe' = (Join-Path $PublishDirectory 'prunlet.exe')
    'bin/prunlet-maintenance.exe' = (Join-Path $PublishDirectory 'prunlet-maintenance.exe')
    'bin/prunlet-hook.exe' = (Join-Path $PublishDirectory 'prunlet-hook.exe')
    'bin/Install-Prunlet.ps1' = (Join-Path $SourceRoot 'scripts\Install-Prunlet.ps1')
    'bin/start-prunlet-mcp.ps1' = (Join-Path $SourceRoot 'integration\start-prunlet-mcp.ps1')
    'bin/configuration-common.ps1' = (Join-Path $SourceRoot 'integration\configuration-common.ps1')
    'bin/maintenance-task.ps1' = (Join-Path $SourceRoot 'integration\maintenance-task.ps1')
    'bin/uninstall-maintenance.ps1' = (Join-Path $SourceRoot 'integration\uninstall-maintenance.ps1')
    'bin/install-codex.ps1' = (Join-Path $SourceRoot 'integration\install-codex.ps1')
    'bin/uninstall-codex.ps1' = (Join-Path $SourceRoot 'integration\uninstall-codex.ps1')
    'bin/install-agent-instructions.ps1' = (Join-Path $SourceRoot 'integration\install-agent-instructions.ps1')
    'bin/PRUNLET.md' = (Join-Path $SourceRoot 'integration\PRUNLET.md')
}
$expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
[void]$expected.Add('package.json')
foreach ($name in $inputs.Keys) { [void]$expected.Add($name) }

$packageStream = [IO.File]::Open($PackagePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $archive = [IO.Compression.ZipArchive]::new($packageStream, [IO.Compression.ZipArchiveMode]::Read, $true)
    try {
        $entries = [Collections.Generic.Dictionary[string, IO.Compression.ZipArchiveEntry]]::new([StringComparer]::Ordinal)
        $caseFolded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            if (!$expected.Contains($entry.FullName) -or !$caseFolded.Add($entry.FullName)) {
                throw "Unexpected or duplicate package entry: $($entry.FullName)"
            }
            $entries.Add($entry.FullName, $entry)
        }
        if ($entries.Count -ne $expected.Count) { throw 'Release package is missing required entries.' }
        $manifestEntry = $entries['package.json']
        if ($manifestEntry.Length -lt 1 -or $manifestEntry.Length -gt 65536) { throw 'Package metadata size is invalid.' }
        $reader = [IO.StreamReader]::new($manifestEntry.Open(), [Text.UTF8Encoding]::new($false, $true))
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable } finally { $reader.Dispose() }
        if ($manifest -isnot [Collections.IDictionary] -or $manifest['product'] -cne 'Prunlet' -or
            $manifest['schema'] -ne 1 -or $manifest['repository'] -cne $Repository -or
            $manifest['defaultBranch'] -cne $DefaultBranch -or $manifest['commitSha'] -cne $CommitSha -or
            $manifest['commitVerification'] -cne 'caller-asserted' -or $manifest['runtime'] -cne $Runtime -or
            $manifest['files'] -isnot [Collections.IDictionary] -or $manifest['files'].Count -ne $inputs.Count) {
            throw 'Package metadata does not match the release inputs.'
        }
        foreach ($name in $inputs.Keys) {
            if (@($manifest['files'].Keys) -cnotcontains $name) { throw "Package metadata is missing: $name" }
            $item = $manifest['files'][$name]
            if ($item -isnot [Collections.IDictionary] -or $item['sha256'] -cnotmatch '^[0-9A-F]{64}$') {
                throw "Package metadata is invalid: $name"
            }
            $source = Get-Item -LiteralPath $inputs[$name]
            $entry = $entries[$name]
            if ($source.Length -ne $item['bytes'] -or $entry.Length -ne $item['bytes']) {
                throw "Package size differs: $name"
            }
            $sourceHash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
            $entryStream = $entry.Open()
            try { $entryHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($entryStream)) }
            finally { $entryStream.Dispose() }
            if ($sourceHash -cne $item['sha256'] -or $entryHash -cne $item['sha256']) {
                throw "Package hash differs: $name"
            }
        }
    } finally { $archive.Dispose() }
    $packageStream.Position = 0
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($packageStream))
} finally { $packageStream.Dispose() }
