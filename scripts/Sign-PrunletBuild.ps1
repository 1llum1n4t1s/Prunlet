#requires -Version 7.0
# Publish-Prunlet.ps1のビルド出力（runtimeごとの出力ディレクトリ）へ、Sigiluneで署名する。
#
# release workflowでは、Rustのビルド（依存crateのbuild scriptを含む）に署名用Secretsを
# 見せないよう、ビルドとは別のstepでこのスクリプトだけへSIGILUNE_EMAIL・SIGILUNE_TOTP_URIを渡す。
# 全runtimeを同じSigiluneセッションで署名し、ログイン（TOTP）を1回にする。
#
# 例: pwsh -NoProfile -File .\scripts\Sign-PrunletBuild.ps1 -BuildDirectory D:\tmp\build-win-x64, D:\tmp\build-win-arm64
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$BuildDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Signing.Common.ps1')
Invoke-PrunletBuildSigning $BuildDirectory
[ordered]@{ status = 'signed'; signer = $script:PrunletSignerCommonName; buildDirectories = $BuildDirectory } | ConvertTo-Json -Compress
