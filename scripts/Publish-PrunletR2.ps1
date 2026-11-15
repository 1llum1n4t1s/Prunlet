#requires -Version 7.2
# Windows（win-x64 / win-arm64）の署名済み更新 ZIP を R2 へ配信する。
# 公開の順序: ZIP（create-only の不変キー）→ 公開 URL で照合 → 版マニフェスト（create-only）→ 最新ポインタ。
# 署名付きマニフェストの仕様は scripts/PrunletRelease.Common.ps1、R2 の書込み規則は scripts/R2Distribution.Common.ps1。
#
# -CheckOnly: 書込みなしの事前検査（ZIP の生成元・署名の照合、既存の版マニフェストとの一致、最新ポインタの後退判定）。
#   署名鍵（PRUNLET_RELEASE_SIGNING_KEY）は不要。workflow は全 runtime の -CheckOnly を済ませてから、最初の書込みへ進む。
# 認証（環境変数。値はログへ出さない）: CLOUDFLARE_API_TOKEN（優先）または PRUNLET_R2_ACCESS_KEY_ID / PRUNLET_R2_SECRET_ACCESS_KEY、
#   PRUNLET_R2_ACCOUNT_ID、PRUNLET_R2_BUCKET（未設定は prunlet-updates）。署名鍵は PRUNLET_RELEASE_SIGNING_KEY（PKCS8 PEM）。
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$PublishDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$CommitSha,
    [Parameter(Mandatory)][string]$DefaultBranch,
    [Parameter(Mandatory)][ValidateSet('win-x64', 'win-arm64')][string]$Runtime,
    # 配信する版（Cargo.toml の版。release/<版> のブランチ名と一致していること）。
    [Parameter(Mandatory)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version,
    [string]$Repository = '1llum1n4t1s/Prunlet',
    [string]$AccountId = $env:PRUNLET_R2_ACCOUNT_ID,
    [string]$Bucket = $(if ($env:PRUNLET_R2_BUCKET) { $env:PRUNLET_R2_BUCKET } else { 'prunlet-updates' }),
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'R2Distribution.Common.ps1')
$package = $null; $session = $null
$phase = 'identity'
try {
    if ($Repository -cne '1llum1n4t1s/Prunlet' -or ![IO.Path]::IsPathFullyQualified($PackagePath) -or
        ![IO.Path]::IsPathFullyQualified($SourceRoot) -or ![IO.Path]::IsPathFullyQualified($PublishDirectory)) { Stop-PrunletR2 $phase 'invalid-input' }
    $phase = 'package-verification'
    # 公開する実行ファイルは署名済み（署名者・タイムスタンプ付き）であることも必須にする。
    $verified = & (Join-Path $PSScriptRoot 'Verify-ReleasePackage.ps1') -PackagePath $PackagePath -SourceRoot $SourceRoot -PublishDirectory $PublishDirectory -CommitSha $CommitSha -DefaultBranch $DefaultBranch -Runtime $Runtime -Repository $Repository -RequireSignature
    if ($verified -isnot [string] -or $verified -cnotmatch '^[0-9A-F]{64}$') { Stop-PrunletR2 $phase 'verification-failed' }
    # 検証した ZIP を固定し、以後はこの同一ファイルだけを送信・再照合する（読取り共有のまま保持して書換えを拒む）。
    $phase = 'package-pin'
    $package = [IO.File]::Open($PackagePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $facts = Get-PrunletReleaseFileFacts $PackagePath
    if ($facts.Sha256 -cne $verified.ToLowerInvariant()) { Stop-PrunletR2 $phase 'changed' }
    $spec = New-PrunletReleaseSpec -Runtime $Runtime -Version $Version -CommitSha $CommitSha -DefaultBranch $DefaultBranch -Sha256 $facts.Sha256 -Bytes $facts.Bytes -Repository $Repository
    $phase = 'plan'
    $session = New-PrunletR2Session -AccountId $AccountId -Bucket $Bucket
    $plan = Get-PrunletRuntimePlan -Session $session -Spec $spec -NoSign:$CheckOnly
    if ($CheckOnly) {
        [ordered]@{ schema = 1; mode = 'check-only'; runtime = $Runtime; version = $Version; decision = $plan.Decision; assetKey = $spec.AssetKey; sha256 = $spec.Sha256; bytes = $spec.Bytes } | ConvertTo-Json -Compress
        return
    }
    $phase = 'publish'
    $result = Invoke-PrunletRuntimePublication -Session $session -Plan $plan -ArtifactPath $PackagePath
    [ordered]@{ schema = 1; mode = 'published'; runtime = $Runtime; version = $Version; decision = $result.Decision; assetKey = $spec.AssetKey; manifestKey = $spec.ManifestKey; pointerKey = $spec.PointerKey; sha256 = $spec.Sha256; bytes = $spec.Bytes; pointerUpdated = $result.PointerUpdated } | ConvertTo-Json -Compress
} catch {
    $safe = Get-PrunletR2SafeFailure $_.Exception
    if ($null -ne $safe) { throw $safe }
    if ($phase -ceq 'package-verification') { Stop-PrunletR2 $phase 'verification-failed' }
    Stop-PrunletR2 $phase 'operation-failed'
} finally { Close-PrunletR2Session $session; if ($null -ne $package) { $package.Dispose() } }
