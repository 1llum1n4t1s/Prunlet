#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [string]$TargetDirectory = $env:PRUNLET_CARGO_TARGET_DIRECTORY,
    [ValidatePattern('^[0-9a-fA-F]{40}$')][string]$SourceCommit,
    [switch]$IncludeVerificationProbe
)
$ErrorActionPreference = 'Stop'
# installerと既存検証の互換引数をRustへ渡す。releaseではprobeを要求しない。
$source = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if (!$SourceCommit) {
    $SourceCommit = & git -C $source rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $SourceCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'SourceCommit is required for a source archive.' }
}
$native = @('build', '--source', $source, '--output', $OutputDirectory, '--commit', $SourceCommit.ToLowerInvariant(), '--branch', 'main', '--runtime', $Runtime, '--repository', '1llum1n4t1s/Prunlet')
if ($TargetDirectory) { $native += @('--target-directory', $TargetDirectory) }
if ($IncludeVerificationProbe) { $native += @('--include-verification-probe', 'true') }
& (Join-Path $PSScriptRoot 'Invoke-PrunletRelease.ps1') -SourceRoot $source -OutputDirectory $OutputDirectory -NativeArguments $native
