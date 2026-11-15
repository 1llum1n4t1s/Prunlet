#requires -Version 7.2
# 実機の Mac で作った署名・公証済みの ZIP（scripts/Publish-PrunletMac.sh の出力 prunlet-update-osx-arm64.zip）を、
# R2 の不変キー releases/1llum1n4t1s/prunlet/<commit>/osx-arm64/<sha256>.zip へ「新規作成のみ」で送る。
# 署名付きマニフェストはここでは発行しない。送信後に表示される sha256・bytes を入力にして、prunlet-mac-release.yml
# （workflow_dispatch、release/<版> の ref）を実行する（CI が R2 の実物を照合して署名マニフェストを発行する）。
#
# Mac の資格情報や署名鍵は不要（R2 への書込みだけ）。認証は CLOUDFLARE_API_TOKEN（R2 書込み権限）または
# S3 互換キー（PRUNLET_R2_ACCESS_KEY_ID / PRUNLET_R2_SECRET_ACCESS_KEY）と PRUNLET_R2_ACCOUNT_ID。値はログへ出さない。
# ZIP の中身（2 項目・manifest.json の版・commit・runtime・実行体の長さと SHA-256）は送信前に独立に検査する。
# Apple の署名・公証の検証はここでも行わない（クライアント側の責任。公証の Accepted は Publish-PrunletMac.sh が確認済み）。
# 同じ sha256 の再送は、既存オブジェクトを照合するだけで上書きしない。
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$CommitSha,
    [Parameter(Mandatory)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version,
    [string]$AccountId = $env:PRUNLET_R2_ACCOUNT_ID,
    [string]$Bucket = $(if ($env:PRUNLET_R2_BUCKET) { $env:PRUNLET_R2_BUCKET } else { 'prunlet-updates' })
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'R2Distribution.Common.ps1')
. (Join-Path $PSScriptRoot 'PrunletPackage.Common.ps1')
$session = $null; $pin = $null
$phase = 'identity'
try {
    if (![IO.Path]::IsPathFullyQualified($PackagePath)) { Stop-PrunletR2 $phase 'invalid-input' }
    $phase = 'package-verification'
    $pin = [IO.File]::Open($PackagePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    if ($pin.Length -le 0 -or $pin.Length -gt 64MB) { Stop-PrunletR2 $phase 'invalid-input' }
    $bytes = [byte[]]::new($pin.Length)
    $pin.ReadExactly($bytes, 0, $bytes.Length)
    Assert-PrunletMacPackage -Bytes $bytes -Version $Version -CommitSha $CommitSha
    $facts = Get-PrunletReleaseFileFacts $PackagePath
    $spec = New-PrunletReleaseSpec -Runtime 'osx-arm64' -Version $Version -CommitSha $CommitSha -DefaultBranch 'main' -Sha256 $facts.Sha256 -Bytes $facts.Bytes
    $phase = 'publish'
    $session = New-PrunletR2Session -AccountId $AccountId -Bucket $Bucket
    $null = Publish-PrunletR2File -Session $session -Key $spec.AssetKey -FilePath $PackagePath -ContentType $spec.ContentType -Immutable
    Assert-PrunletPublicObject -Session $session -Key $spec.AssetKey -Bytes $spec.Bytes -Sha256 $spec.Sha256
    [ordered]@{ schema = 1; runtime = 'osx-arm64'; version = $Version; commit = $CommitSha; key = $spec.AssetKey; sha256 = $spec.Sha256; bytes = $spec.Bytes } | ConvertTo-Json -Compress
} catch {
    $safe = Get-PrunletR2SafeFailure $_.Exception
    if ($null -ne $safe) { throw $safe }
    Stop-PrunletR2 $phase 'operation-failed'
} finally { Close-PrunletR2Session $session; if ($null -ne $pin) { $pin.Dispose() } }
