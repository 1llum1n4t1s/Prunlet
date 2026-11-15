#requires -Version 7.2
# Linux（linux-x64 / linux-arm64）の検証済み tar.gz を R2 へ配信する。prunlet-linux-release.yml の publish job（Environment release）が呼ぶ。
# 公開の順序: tar.gz（create-only の不変キー）→ 公開 URL で照合 → 版マニフェスト（create-only）→ 最新ポインタ →
#   手動取得用の固定名 download/latest/prunlet-linux-<cpu>.tar.gz と .sha256（最後に置換。ポインタ更新後だけ）。
# build job が作った tar.gz の中身（ustar・2 エントリ・manifest・上限）と、隣の .sha256 の内容を、ここでも独立に検査する。
# -CheckOnly は書込みなしの事前検査（署名鍵不要）。認証・署名鍵の環境変数は Publish-PrunletR2.ps1 と同じ。
[CmdletBinding()]
param(
    # prunlet-<runtime>.tar.gz。隣に prunlet-<runtime>.tar.gz.sha256（`<hex>  <asset名>` の1行）があること。
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][ValidateSet('linux-x64', 'linux-arm64')][string]$Runtime,
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
$session = $null; $pin = $null
$phase = 'identity'
try {
    if (![IO.Path]::IsPathFullyQualified($PackagePath)) { Stop-PrunletR2 $phase 'invalid-input' }
    $descriptor = Get-PrunletReleaseDescriptor -Runtime $Runtime -Version $Version
    if ([IO.Path]::GetFileName($PackagePath) -cne $descriptor.AssetName) { Stop-PrunletR2 $phase 'invalid-input' }
    $phase = 'package-verification'
    Assert-PrunletLinuxPackage -Path $PackagePath -Runtime $Runtime -Version $Version -CommitSha $CommitSha
    $phase = 'package-pin'
    $pin = [IO.File]::Open($PackagePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $facts = Get-PrunletReleaseFileFacts $PackagePath
    $sidecar = "$PackagePath.sha256"
    if (!(Test-Path -LiteralPath $sidecar -PathType Leaf)) { Stop-PrunletR2 $phase 'changed' }
    $expectedText = "$($facts.Sha256)  $($descriptor.AssetName)`n"
    if ([IO.File]::ReadAllText($sidecar) -cne $expectedText) { Stop-PrunletR2 $phase 'changed' }
    $spec = New-PrunletReleaseSpec -Runtime $Runtime -Version $Version -CommitSha $CommitSha -DefaultBranch $DefaultBranch -Sha256 $facts.Sha256 -Bytes $facts.Bytes
    $phase = 'plan'
    $session = New-PrunletR2Session -AccountId $AccountId -Bucket $Bucket
    $plan = Get-PrunletRuntimePlan -Session $session -Spec $spec -NoSign:$CheckOnly
    if ($CheckOnly) {
        [ordered]@{ schema = 1; mode = 'check-only'; runtime = $Runtime; version = $Version; decision = $plan.Decision; assetKey = $spec.AssetKey; sha256 = $spec.Sha256; bytes = $spec.Bytes } | ConvertTo-Json -Compress
        return
    }
    $phase = 'publish'
    # 固定名は最新ポインタの更新後に、tar.gz → .sha256 の順で置換する（.sha256 が最後）。
    $fixed = @(
        @{ Key = "download/latest/$($descriptor.AssetName)"; Path = $PackagePath; ContentType = $descriptor.ContentType },
        @{ Key = "download/latest/$($descriptor.AssetName).sha256"; Path = $sidecar; ContentType = 'text/plain; charset=utf-8' }
    )
    $result = Invoke-PrunletRuntimePublication -Session $session -Plan $plan -ArtifactPath $PackagePath -FixedFiles $fixed
    [ordered]@{ schema = 1; mode = 'published'; runtime = $Runtime; version = $Version; decision = $result.Decision; assetKey = $spec.AssetKey; manifestKey = $spec.ManifestKey; pointerKey = $spec.PointerKey; sha256 = $spec.Sha256; bytes = $spec.Bytes; pointerUpdated = $result.PointerUpdated } | ConvertTo-Json -Compress
} catch {
    $safe = Get-PrunletR2SafeFailure $_.Exception
    if ($null -ne $safe) { throw $safe }
    Stop-PrunletR2 $phase 'operation-failed'
} finally { Close-PrunletR2Session $session; if ($null -ne $pin) { $pin.Dispose() } }
