#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][string]$SourceRoot,
    # 省略時は添付済みの署名付きZIPだけを検証する（Verify-ReleasePackage.ps1の同名引数を参照）。
    [string]$PublishDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$CommitSha,
    [Parameter(Mandatory)][string]$DefaultBranch,
    [Parameter(Mandatory)][ValidateSet('win-x64', 'win-arm64')][string]$Runtime,
    [string]$Repository = '1llum1n4t1s/Prunlet',
    [switch]$RequireSignature,
    [string]$ExpectedVersion,
    [string]$ExtractDirectory,
    [string]$AccountId = $env:PRUNLET_R2_ACCOUNT_ID,
    [string]$Bucket = $(if ($env:PRUNLET_R2_BUCKET) { $env:PRUNLET_R2_BUCKET } else { 'prunlet-updates' })
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'R2Distribution.Common.ps1')
$package = $null; $client = $null
$phase = 'identity'
try {
    if ($Repository -cne '1llum1n4t1s/Prunlet' -or ![IO.Path]::IsPathFullyQualified($PackagePath) -or
        ![IO.Path]::IsPathFullyQualified($SourceRoot) -or ($PublishDirectory -and ![IO.Path]::IsPathFullyQualified($PublishDirectory))) { Stop-PrunletR2 $phase 'invalid-input' }
    $phase = 'package-verification'
    $verifyArguments = @{ PackagePath = $PackagePath; SourceRoot = $SourceRoot; CommitSha = $CommitSha; DefaultBranch = $DefaultBranch; Runtime = $Runtime; Repository = $Repository }
    if ($PublishDirectory) { $verifyArguments['PublishDirectory'] = $PublishDirectory }
    if ($RequireSignature) { $verifyArguments['RequireSignature'] = $true }
    if ($ExpectedVersion) { $verifyArguments['ExpectedVersion'] = $ExpectedVersion }
    if ($ExtractDirectory) { $verifyArguments['ExtractDirectory'] = $ExtractDirectory }
    $verified = & (Join-Path $PSScriptRoot 'Verify-ReleasePackage.ps1') @verifyArguments
    if ($verified -isnot [string] -or $verified -cnotmatch '^[0-9A-F]{64}$') { Stop-PrunletR2 $phase 'verification-failed' }
    # 検証したZIPを固定し、以後はこの同一streamだけを送信・再照合する。
    $phase = 'package-pin'
    $package = [IO.File]::Open($PackagePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $client = New-PrunletR2Client
    $result = Invoke-PrunletR2Distribution -Package $package -ExpectedHash $verified.ToLowerInvariant() -Repository $Repository -CommitSha $CommitSha -Runtime $Runtime -AccountId $AccountId -Bucket $Bucket -Client $client
    $result | ConvertTo-Json -Compress
} catch {
    $safe = Get-PrunletR2SafeFailure $_.Exception
    if ($null -ne $safe) { throw $safe }
    if ($phase -ceq 'package-verification') { Stop-PrunletR2 $phase 'verification-failed' }
    Stop-PrunletR2 $phase 'operation-failed'
}
finally { if ($null -ne $client) { $client.Dispose() }; if ($null -ne $package) { $package.Dispose() } }
