#requires -Version 7.2
# Apple Silicon（osx-arm64）の署名・公証済み ZIP の署名付きマニフェストを発行する。prunlet-mac-release.yml（workflow_dispatch）が呼ぶ。
#
# 前提と信頼の範囲（重要）:
#   ZIP は CI ではビルドしていない。実機の Mac で既存の scripts/Publish-PrunletMac.sh が作った ZIP を、
#   scripts/Send-PrunletMacPackage.ps1 が不変キー releases/1llum1n4t1s/prunlet/<commit>/osx-arm64/<sha256>.zip へ置く。
#   ここでは、dispatch の入力（sha256・bytes）で R2 の実物を取得し、長さ・SHA-256 と ZIP の 2 項目・manifest.json の
#   版・commit・runtime を、チェックアウトした HEAD の値と照合してから署名する。つまり CI は「自分でビルドしていない物」に
#   署名する。Developer ID の署名・公証の検証はクライアント側（起動時更新）の責任で、ここでは行わない。
# 公開の順序は他 runtime と同じ（ZIP は既に置かれているので照合だけ）: 照合 → 版マニフェスト（create-only）→ 最新ポインタ。
# -CheckOnly は書込みなしの事前検査（署名鍵不要）。
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$Sha256,
    [Parameter(Mandatory)][long]$Bytes,
    [Parameter(Mandatory)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$CommitSha,
    [Parameter(Mandatory)][string]$DefaultBranch,
    [string]$AccountId = $env:PRUNLET_R2_ACCOUNT_ID,
    [string]$Bucket = $(if ($env:PRUNLET_R2_BUCKET) { $env:PRUNLET_R2_BUCKET } else { 'prunlet-updates' }),
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'R2Distribution.Common.ps1')
. (Join-Path $PSScriptRoot 'PrunletPackage.Common.ps1')
$session = $null
$phase = 'identity'
try {
    $spec = New-PrunletReleaseSpec -Runtime 'osx-arm64' -Version $Version -CommitSha $CommitSha -DefaultBranch $DefaultBranch -Sha256 $Sha256 -Bytes $Bytes
    $phase = 'plan'
    $session = New-PrunletR2Session -AccountId $AccountId -Bucket $Bucket
    # R2 の実物（認証付き GET）を取得し、入力の長さ・SHA-256 と ZIP の中身を照合する。
    $phase = 'package-verification'
    $object = Read-PrunletR2Object -Session $session -Key $spec.AssetKey -MaxBytes 64MB
    if ($object.Status -ne 200) { Stop-PrunletR2 $phase 'unavailable-before-http' }
    $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($object.Bytes)).ToLowerInvariant()
    if ($object.Bytes.Length -ne $Bytes -or $actual -cne $Sha256) { Stop-PrunletR2 $phase 'body-mismatch' }
    Assert-PrunletMacPackage -Bytes $object.Bytes -Version $Version -CommitSha $CommitSha
    $phase = 'plan'
    $plan = Get-PrunletRuntimePlan -Session $session -Spec $spec -NoSign:$CheckOnly
    if ($CheckOnly) {
        [ordered]@{ schema = 1; mode = 'check-only'; runtime = 'osx-arm64'; version = $Version; decision = $plan.Decision; assetKey = $spec.AssetKey; sha256 = $spec.Sha256; bytes = $spec.Bytes } | ConvertTo-Json -Compress
        return
    }
    $phase = 'publish'
    $result = Invoke-PrunletRuntimePublication -Session $session -Plan $plan -ReuseRemoteArtifact
    [ordered]@{ schema = 1; mode = 'published'; runtime = 'osx-arm64'; version = $Version; decision = $result.Decision; assetKey = $spec.AssetKey; manifestKey = $spec.ManifestKey; pointerKey = $spec.PointerKey; sha256 = $spec.Sha256; bytes = $spec.Bytes; pointerUpdated = $result.PointerUpdated } | ConvertTo-Json -Compress
} catch {
    $safe = Get-PrunletR2SafeFailure $_.Exception
    if ($null -ne $safe) { throw $safe }
    Stop-PrunletR2 $phase 'operation-failed'
} finally { Close-PrunletR2Session $session }
