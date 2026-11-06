#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$PublishDirectory,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$CommitSha,
    [Parameter(Mandatory)][string]$DefaultBranch,
    [Parameter(Mandatory)][ValidateSet('win-x64', 'win-arm64')][string]$Runtime,
    [string]$Repository = '1llum1n4t1s/Prunlet'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# commitとbranchは呼出し元の申告であり、既定branchのHEADやbuild来歴を証明しない。
if ($DefaultBranch -notmatch '^[A-Za-z0-9._/-]+$' -or $DefaultBranch.Contains('..') -or $DefaultBranch.StartsWith('/') -or $DefaultBranch.EndsWith('/')) {
    throw 'DefaultBranch is not a supported branch name.'
}
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Repository must be owner/name.' }

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class PrunletPackageNative {
    [StructLayout(LayoutKind.Sequential)]
    struct FileInfo {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
        public uint VolumeSerial, SizeHigh, SizeLow, NumberOfLinks, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo info);
    public static SafeFileHandle Open(string path, bool directory) {
        uint access = directory ? 0x80u : 0x80000000u;
        uint share = directory ? 3u : 1u;
        uint flags = 0x00200000u | (directory ? 0x02000000u : 0u);
        var handle = CreateFileW(@"\\?\" + path, access, share, IntPtr.Zero, 3, flags, IntPtr.Zero);
        if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error, "Cannot open package input: " + path); }
        if (!GetFileInformationByHandle(handle, out var info)) { int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error, "Cannot inspect package input: " + path); }
        if ((info.Attributes & 0x400u) != 0 || (((info.Attributes & 0x10u) != 0) != directory) || (!directory && info.NumberOfLinks != 1)) {
            handle.Dispose(); throw new InvalidOperationException("Package input is a reparse point, wrong type, or multiply linked: " + path);
        }
        return handle;
    }
}
'@

function Get-LocalAbsolute([string]$Path, [string]$Label) {
    if (![IO.Path]::IsPathFullyQualified($Path)) { throw "$Label must be absolute." }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) { throw "$Label must be a local drive path without alternate streams." }
    return $full
}
function Test-InTree([string]$Path, [string]$Root) {
    $base = $Root.TrimEnd('\')
    return $Path.Equals($base, [StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Pin-Directory([string]$Path) {
    $drive = [IO.Path]::GetPathRoot($Path)
    $cursor = $drive
    foreach ($part in @('') + @($Path.Substring($drive.Length).Split('\', [StringSplitOptions]::RemoveEmptyEntries))) {
        if ($part) { $cursor = Join-Path $cursor $part }
        if (!$pins.ContainsKey($cursor)) { $pins.Add($cursor, [PrunletPackageNative]::Open($cursor, $true)) }
    }
}
function Open-Input([string]$Path) {
    Pin-Directory ([IO.Path]::GetDirectoryName($Path))
    $handle = [PrunletPackageNative]::Open($Path, $false)
    try { return [IO.FileStream]::new($handle, [IO.FileAccess]::Read) } catch { $handle.Dispose(); throw }
}
function Get-StreamHash([IO.FileStream]$Stream) {
    $Stream.Position = 0
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Stream))
    $Stream.Position = 0
    return $hash
}
function Assert-Machine([IO.FileStream]$Stream, [string]$ExpectedRuntime) {
    $reader = [IO.BinaryReader]::new($Stream, [Text.Encoding]::UTF8, $true)
    try {
        if ($Stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) { throw 'Product is not a PE executable.' }
        $Stream.Position = 0x3c
        $offset = $reader.ReadUInt32()
        if ($offset -gt $Stream.Length - 6) { throw 'Product has an invalid PE header offset.' }
        $Stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw 'Product has an invalid PE signature.' }
        $machine = $reader.ReadUInt16()
        $expected = if ($ExpectedRuntime -eq 'win-x64') { 0x8664 } else { 0xaa64 }
        if ($machine -ne $expected) { throw "Product PE architecture does not match $ExpectedRuntime." }
    } finally { $reader.Dispose(); $Stream.Position = 0 }
}

$source = Get-LocalAbsolute $SourceRoot 'SourceRoot'
$publish = Get-LocalAbsolute $PublishDirectory 'PublishDirectory'
$output = Get-LocalAbsolute $OutputPath 'OutputPath'
if ([IO.Path]::GetExtension($output) -ine '.zip') { throw 'OutputPath must name a .zip file.' }
if ([IO.Path]::GetFileName($output) -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { throw 'OutputPath cannot use a Windows device name.' }
if ((Test-InTree $output $source) -or (Test-InTree $output $publish)) { throw 'OutputPath must be outside the source and publish trees.' }

# ZIP名は固定し、ユーザー入力をエントリ名として受け取らない。
$inputs = [ordered]@{
    'bin/prunlet.exe' = (Join-Path $publish 'prunlet.exe')
    'bin/prunlet-maintenance.exe' = (Join-Path $publish 'prunlet-maintenance.exe')
    'bin/prunlet-hook.exe' = (Join-Path $publish 'prunlet-hook.exe')
    'bin/Install-Prunlet.ps1' = (Join-Path $source 'scripts\Install-Prunlet.ps1')
    'bin/start-prunlet-mcp.ps1' = (Join-Path $source 'integration\start-prunlet-mcp.ps1')
    'bin/configuration-common.ps1' = (Join-Path $source 'integration\configuration-common.ps1')
    'bin/maintenance-task.ps1' = (Join-Path $source 'integration\maintenance-task.ps1')
    'bin/uninstall-maintenance.ps1' = (Join-Path $source 'integration\uninstall-maintenance.ps1')
    'bin/install-codex.ps1' = (Join-Path $source 'integration\install-codex.ps1')
    'bin/uninstall-codex.ps1' = (Join-Path $source 'integration\uninstall-codex.ps1')
    'bin/install-agent-instructions.ps1' = (Join-Path $source 'integration\install-agent-instructions.ps1')
    'bin/PRUNLET.md' = (Join-Path $source 'integration\PRUNLET.md')
}
$names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if (!$names.Add('package.json')) { throw 'Duplicate package metadata name.' }
foreach ($name in $inputs.Keys) {
    if ($name -notmatch '^bin/[A-Za-z0-9._-]+$' -or !$names.Add($name)) { throw "Invalid or duplicate package entry: $name" }
}

$pins = [Collections.Generic.Dictionary[string, Microsoft.Win32.SafeHandles.SafeFileHandle]]::new([StringComparer]::OrdinalIgnoreCase)
$streams = [Collections.Generic.List[IO.FileStream]]::new()
$created = $false
try {
    Pin-Directory $source
    Pin-Directory $publish
    Pin-Directory ([IO.Path]::GetDirectoryName($output))
    $files = [ordered]@{}
    foreach ($name in $inputs.Keys) {
        $stream = Open-Input $inputs[$name]
        $streams.Add($stream)
        if ($name.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { Assert-Machine $stream $Runtime }
        $files[$name] = [ordered]@{ sha256 = Get-StreamHash $stream; bytes = $stream.Length }
    }
    if ($files['bin/prunlet.exe'].sha256 -cne $files['bin/prunlet-hook.exe'].sha256) { throw 'The hook host must match the CLI binary.' }
    $metadata = [ordered]@{
        product = 'Prunlet'; schema = 1; repository = $Repository; defaultBranch = $DefaultBranch
        commitSha = $CommitSha; commitVerification = 'caller-asserted'; runtime = $Runtime; files = $files
    }
    $metadataBytes = [Text.UTF8Encoding]::new($false).GetBytes(($metadata | ConvertTo-Json -Depth 6 -Compress))
    $outputStream = [IO.FileStream]::new($output, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $created = $true
    try {
        $zip = [IO.Compression.ZipArchive]::new($outputStream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $entry = $zip.CreateEntry('package.json', [IO.Compression.CompressionLevel]::Optimal)
            $target = $entry.Open()
            try { $target.Write($metadataBytes) } finally { $target.Dispose() }
            $index = 0
            foreach ($name in $inputs.Keys) {
                $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
                $target = $entry.Open()
                try { $streams[$index].CopyTo($target) } finally { $target.Dispose() }
                $index++
            }
        } finally { $zip.Dispose() }
        $outputStream.Flush($true)
        $outputStream.Position = 0
        $packageHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($outputStream))
    } finally { $outputStream.Dispose() }
    [ordered]@{ status = 'created'; path = $output; sha256 = $packageHash; commitSha = $CommitSha; commitVerification = 'caller-asserted'; runtime = $Runtime; warning = 'Commit, default branch, and build provenance were not verified.' } | ConvertTo-Json -Compress
} catch {
    if ($created) { Write-Warning "An incomplete package was preserved at $output." }
    throw
} finally {
    foreach ($stream in $streams) { $stream.Dispose() }
    foreach ($pin in $pins.Values) { $pin.Dispose() }
}
