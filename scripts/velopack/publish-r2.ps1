#requires -Version 7.2
# 梱包・検証済みの Velopack の一式（pack-windows.ps1 の packages\）を Cloudflare R2 の
# バケット prunlet-updates の velopack/（公開 URL https://prunlet.kagayoi.com/velopack/）へ配信する。
# GitHub Release もタグも使わない。nupkg の信頼の基点は、同じ R2 の署名付きマニフェスト
# manifests/<版>/velopack-win-x64.json（asset の長さ・SHA-256 を ECDSA P-256 で署名）で、nupkg より先に置く。
# 規則の本体は同じフォルダーの PublishFeed.Common.ps1（署名マニフェストの仕様は ../PrunletRelease.Common.ps1）。
#
# - 版付きの成果物（*.nupkg、版番号を含む名前）と署名マニフェストは「新規作成のみ」。同じ名前が既にあれば内容を照合し、
#   一致しなければ失敗する（上書きしない）。マニフェストは署名が毎回変わるので、署名の有効性と payload の一致で照合する。
# - 固定名（<packId>-<channel>-Setup.exe、releases.<channel>.json、assets.<channel>.json、RELEASES*）は最新を指すので置き換える。
#   署名マニフェスト → nupkg → releases.<channel>.json（ETag 条件付き）→ 固定名の順。
# - 後退防止: 現行の releases.<channel>.json が今回より新しければ何も置かずに失敗、同じ版なら版付きの照合だけ、
#   読めない場合は配信しない。書込みの前の検査（署名・既存マニフェスト・フィード）はすべて読取りだけで行う。
#
# 認証（環境変数。値はログへ出さない）: CLOUDFLARE_API_TOKEN（優先。Environment `release` の Secret）または
# PRUNLET_R2_ACCESS_KEY_ID / PRUNLET_R2_SECRET_ACCESS_KEY、アカウントは PRUNLET_R2_ACCOUNT_ID、バケットは PRUNLET_R2_BUCKET
# （未設定は prunlet-updates）。署名鍵は PRUNLET_RELEASE_SIGNING_KEY（PKCS8 PEM）。
#
# -DryRun: 実バケットへ接続・書込みをせず、置く予定のファイルと分類・順序・後退防止の判定を表示するだけ（署名鍵も不要）。
#   -CurrentFeedPath（-DryRun 専用）に現行フィード相当の JSON を渡すと、その版で後退防止の判定を行う。
# 実行は、リリース workflow（Environment release）または本人の明示の依頼があるときだけ。
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagesDirectory,
    # releases.<channel>.json の <channel>。
    [string]$Channel = 'win',
    [string]$PackId = 'PrunletApp',
    # 署名マニフェストに入れる、タグ v<版> の commit（40桁小文字hex）と既定ブランチ。
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$CommitSha,
    [string]$DefaultBranch = 'main',
    [switch]$DryRun,
    [string]$CurrentFeedPath,
    # 署名マニフェストだけを置く（残りの一式は、同じ引数で -ManifestOnly なしの再実行で置く。マニフェストは既存として照合される）。
    [switch]$ManifestOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'PublishFeed.Common.ps1')

$Prefix = 'velopack'
$BaseUrl = 'https://prunlet.kagayoi.com/velopack/'
$Bucket = if ($env:PRUNLET_R2_BUCKET) { $env:PRUNLET_R2_BUCKET } else { 'prunlet-updates' }

if (![IO.Path]::IsPathFullyQualified($PackagesDirectory)) { throw 'Specify an absolute path to the packages directory.' }
if ($Channel -notmatch '^[a-z0-9-]+$') { throw 'Channel must be lowercase alphanumeric (and hyphens).' }
if ($PackId -notmatch '^[A-Za-z][A-Za-z0-9]*$') { throw 'PackId must be alphanumeric.' }
if ($CurrentFeedPath -and !$DryRun) { throw '-CurrentFeedPath is only for -DryRun.' }
$packagesRoot = Get-Item -LiteralPath $PackagesDirectory -Force
if (!$packagesRoot.PSIsContainer) { throw 'The packages path must be a directory.' }
$files = @(Get-ChildItem -LiteralPath $packagesRoot.FullName -File -Force)
if ($files | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw 'The packages directory cannot contain links.' }
if ($files.Name -notcontains "releases.$Channel.json") { throw "Missing required file: releases.$Channel.json" }
$nupkgs = @($files | Where-Object { $_.Name -match "^$([regex]::Escape($PackId))-.+-full\.nupkg$" })
if ($nupkgs.Count -ne 1) { throw 'The packages directory must contain exactly one full nupkg.' }
$nupkg = $nupkgs[0]
$localVersion = [semver]($nupkg.Name -replace "^$([regex]::Escape($PackId))-", '' -replace '-full\.nupkg$', '')
foreach ($required in @("$PackId-$Channel-Setup.exe", "$PackId-$localVersion-$Channel-Setup.exe")) {
    if ($files.Name -notcontains $required) { throw "Missing required file: $required" }
}

if ($DryRun) {
    $remote = $null; $source = 'not read (dry-run without -CurrentFeedPath)'
    if ($CurrentFeedPath) { $remote = Get-PrunletVelopackFeedVersion (Get-Content -LiteralPath $CurrentFeedPath -Raw) $PackId; $source = "$CurrentFeedPath => $(if ($null -eq $remote) { 'no Full version' } else { $remote })" }
    $decision = Get-PrunletVelopackDecision $localVersion $remote
    Write-Host "dry-run: bucket=$Bucket prefix=$Prefix/ local=$localVersion current feed: $source decision=$decision"
    Write-Host ('{0,-12} manifests/{1}/velopack-win-x64.json (signed manifest, before the packages)' -f 'create-only', $localVersion)
    foreach ($item in (Get-PrunletVelopackPlan $files $decision)) {
        Write-Host ('{0,-12} {1}/{2}' -f $(if ($item.Immutable) { 'create-only' } else { 'replace' }), $Prefix, $item.File.Name)
    }
    if ($decision -eq 'verify-only') { Write-Host 'skipped      fixed-name objects (the feed already has this version)' }
    return
}

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'R2Distribution.Common.ps1')
$session = $null
try {
    $session = New-PrunletR2Session -Bucket $Bucket
    $result = Invoke-PrunletVelopackPublication -Session $session -Files $files -Nupkg $nupkg -LocalVersion $localVersion -Channel $Channel -PackId $PackId -CommitSha $CommitSha -DefaultBranch $DefaultBranch -ManifestOnly:$ManifestOnly
    if ($ManifestOnly) { Write-Host "Published the signed manifest only (decision=$($result.Decision))" } else { Write-Host "Published to $BaseUrl (decision=$($result.Decision))" }
} finally { Close-PrunletR2Session $session }
