#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][string]$SourceRoot,
    # 今回のビルド出力。省略した場合（CIで添付済みZIPだけを検証する場合）は、実行ファイルを
    # ビルドと照合できない代わりに、署名・署名者・版・machineをZIPの中身から確認する。
    [string]$PublishDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$CommitSha,
    [Parameter(Mandatory)][string]$DefaultBranch,
    [Parameter(Mandatory)][ValidateSet('win-x64', 'win-arm64')][string]$Runtime,
    [Parameter(Mandatory)][string]$Repository,
    # 実行ファイルに有効なAuthenticode署名（署名者・タイムスタンプ付き）を要求する。
    [switch]$RequireSignature,
    # PublishDirectoryを省略する場合に必須。実行ファイルの製品版と照合する（例: 1.0.43）。
    [string]$ExpectedVersion,
    # PublishDirectoryを省略する場合に必須。実行ファイルを取り出して検査する、未使用の絶対パス。
    # 呼出し元が用意・清掃する（このスクリプトは削除しない）。
    [string]$ExtractDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$fromBuild = [bool]$PublishDirectory
if (!$fromBuild) {
    # ビルドとの照合がない場合は、署名と版の確認を省略させない。
    if (!$RequireSignature) { throw 'Verifying a package without PublishDirectory requires -RequireSignature.' }
    if ($ExpectedVersion -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'ExpectedVersion must be a release version such as 1.2.3.' }
    if (!$ExtractDirectory -or ![IO.Path]::IsPathFullyQualified($ExtractDirectory) -or (Test-Path -LiteralPath $ExtractDirectory)) { throw 'ExtractDirectory must be an unused absolute path.' }
}
if ($RequireSignature) { . (Join-Path $PSScriptRoot 'Signing.Common.ps1') }
$executables = @('bin/prunlet.exe', 'bin/prunlet-maintenance.exe', 'bin/prunlet-hook.exe')

# アップデーターが受け取るファイルと、今回のビルド・sourceを照合する。
$inputs = [ordered]@{
    'bin/prunlet.exe' = if ($fromBuild) { Join-Path $PublishDirectory 'prunlet.exe' } else { $null }
    'bin/prunlet-maintenance.exe' = if ($fromBuild) { Join-Path $PublishDirectory 'prunlet-maintenance.exe' } else { $null }
    'bin/prunlet-hook.exe' = if ($fromBuild) { Join-Path $PublishDirectory 'prunlet-hook.exe' } else { $null }
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
    if ($packageStream.Length -lt 1 -or $packageStream.Length -gt 512MB) { throw 'Package exceeds the existing Windows updater size limit.' }
    $archive = [IO.Compression.ZipArchive]::new($packageStream, [IO.Compression.ZipArchiveMode]::Read, $true)
    try {
        $entries = [Collections.Generic.Dictionary[string, IO.Compression.ZipArchiveEntry]]::new([StringComparer]::Ordinal)
        $caseFolded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            # 公開済みWindowsクライアントのサイズ・外部属性制約も送信前に照合する。
            $limit = if ($entry.FullName.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { 256MB } else { 4MB }
            if ($entry.Length -gt $limit -or ($entry.ExternalAttributes -band 0x400) -ne 0 -or (($entry.ExternalAttributes -shr 16) -band 0xf000) -eq 0xa000) {
                throw "Package entry is unsupported by existing Windows updaters: $($entry.FullName)"
            }
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
            $entry = $entries[$name]
            if ($entry.Length -ne $item['bytes']) { throw "Package size differs: $name" }
            $entryStream = $entry.Open()
            try { $entryHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($entryStream)) }
            finally { $entryStream.Dispose() }
            if ($entryHash -cne $item['sha256']) { throw "Package hash differs: $name" }
            if ($inputs[$name]) {
                # ビルド出力・sourceとの照合。
                $source = Get-Item -LiteralPath $inputs[$name]
                if ($source.Length -ne $item['bytes']) { throw "Package size differs: $name" }
                if ((Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash -cne $item['sha256']) { throw "Package hash differs: $name" }
            }
        }
        if ($manifest['files']['bin/prunlet.exe']['sha256'] -cne $manifest['files']['bin/prunlet-hook.exe']['sha256']) { throw 'The hook host must match the CLI binary.' }
        if ($RequireSignature) {
            if ($fromBuild) {
                # ビルド出力はZIPとhashが一致済みなので、同じ実体の署名を確認する。
                foreach ($name in $executables) { $null = Assert-PrunletAuthenticodeSigned $inputs[$name] }
            } else {
                # ZIPから取り出した実体で、署名・PEのmachine・製品版を確認する。
                $null = New-Item -ItemType Directory -Path $ExtractDirectory
                $expectedMachine = if ($Runtime -eq 'win-x64') { 0x8664 } else { 0xaa64 }
                foreach ($name in $executables) {
                    $path = Join-Path $ExtractDirectory ([IO.Path]::GetFileName($name))
                    $entryStream = $entries[$name].Open()
                    try {
                        $file = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                        try { $entryStream.CopyTo($file) } finally { $file.Dispose() }
                    } finally { $entryStream.Dispose() }
                    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $manifest['files'][$name]['sha256']) { throw "Extracted executable differs: $name" }
                    $bytes = [IO.File]::ReadAllBytes($path)
                    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw "Package executable is not a PE file: $name" }
                    $offset = [BitConverter]::ToUInt32($bytes, 0x3c)
                    if ($offset -lt 64 -or $offset -gt $bytes.Length - 6 -or [BitConverter]::ToUInt32($bytes, $offset) -ne 0x00004550 -or [BitConverter]::ToUInt16($bytes, $offset + 4) -ne $expectedMachine) {
                        throw "Package executable does not match ${Runtime}: $name"
                    }
                    $version = ([Diagnostics.FileVersionInfo]::GetVersionInfo($path).ProductVersion -split '\+')[0]
                    if ($version -cne $ExpectedVersion) { throw "Package executable version differs: $name $version" }
                    $null = Assert-PrunletAuthenticodeSigned $path
                }
            }
        }
    } finally { $archive.Dispose() }
    $packageStream.Position = 0
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($packageStream))
} finally { $packageStream.Dispose() }
