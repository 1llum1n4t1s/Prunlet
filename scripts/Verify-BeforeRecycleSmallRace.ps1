[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$ExecutablePath,
 [Parameter(Mandatory)][string]$RustProbePath,
 [Parameter(Mandatory)][string]$BuildManifestPath,
 [Parameter(Mandatory)][string]$ExpectedBuildManifestSha256,
 [Parameter(Mandatory)][string]$OutputDirectory,
 [Parameter(Mandatory)][string]$ReportPath,
 [Parameter(Mandatory)][string]$FixtureRoot
)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'recordless-e2e/BeforeRecycleCheckpointHost.ps1') @PSBoundParameters -Modes @('replace','alias','attributes') -Suite 'before-recycle-small-race' -CallerPath $PSCommandPath