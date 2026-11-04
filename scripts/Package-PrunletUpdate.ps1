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
# 公開済みの引数を保つ互換bridge。処理本体と検証は共通Rustエンジンだけを使う。
$native = @('package', '--source', $SourceRoot, '--publish', $PublishDirectory, '--package', $OutputPath, '--commit', $CommitSha, '--branch', $DefaultBranch, '--runtime', $Runtime, '--repository', $Repository)
& (Join-Path $PSScriptRoot 'Invoke-PrunletRelease.ps1') -SourceRoot $SourceRoot -OutputDirectory (Split-Path ([IO.Path]::GetFullPath($PublishDirectory)) -Parent) -NativeArguments $native
