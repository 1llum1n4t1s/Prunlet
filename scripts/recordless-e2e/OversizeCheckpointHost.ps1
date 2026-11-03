[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$ExecutablePath,
 [Parameter(Mandatory)][string]$RustProbePath,
 [Parameter(Mandatory)][string]$BuildManifestPath,
 [Parameter(Mandatory)][string]$ExpectedBuildManifestSha256,
 [Parameter(Mandatory)][string]$OutputDirectory,
 [Parameter(Mandatory)][string]$FixtureRoot,
 [ValidateSet('replace','lock')][string]$Mode='replace'
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Verification-Common.ps1')
. (Join-Path $PSScriptRoot 'RustFileProbe.Common.ps1')
# 本番exeへcheckpointを混ぜず、同じsourceのtest-only Coreで実Windowsサイズ拒否後だけ競合させる。
foreach($path in @($OutputDirectory,$FixtureRoot)){Assert-VerificationDestination $path @($repo);if(![IO.Path]::IsPathFullyQualified($path)-or![IO.Directory]::Exists($path)){throw 'Existing owned absolute probe output/fixture directory required'}}
if(![IO.Path]::GetPathRoot($OutputDirectory).Equals('D:\',[StringComparison]::OrdinalIgnoreCase)){throw 'External D output required'}
$null=Assert-RustFileProbeBinding
Invoke-RustFileContract ('file-oversize-'+$Mode+'-root') $FixtureRoot