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
# 導入・CI・更新packageは従来の入口と出力DTOを使い、実ビルドだけをRustへ接続する。
& (Join-Path $PSScriptRoot 'Publish-PrunletRust.ps1') @PSBoundParameters
