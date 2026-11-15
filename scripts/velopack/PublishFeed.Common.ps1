#requires -Version 7.2
# Velopack の一式（pack-windows.ps1 の packages\）の配信規則。publish-r2.ps1 とテストが共有する。
# 配信先は R2 の velopack/（公開 https://prunlet.kagayoi.com/velopack/）のまま。署名付きの版マニフェスト
# manifests/<版>/velopack-win-x64.json を先に置き、その後に nupkg・フィード・固定名を置く。
#
# 順序: 署名マニフェスト（create-only）→ 版付き（nupkg・版付き Setup。create-only）→ releases.<channel>.json
#       （ETag 条件付き置換）→ 固定名 Setup → assets → RELEASES。フィードの書込みが成功した後にだけ固定名を置換する。
# 後退防止: 配信の前に R2 の現行 releases.<channel>.json を認証付きで読み、
#   現行の最新版 > 今回 → 何も置かずに失敗 / 同じ → 版付きは照合だけ・固定名は置換しない / 古い・無い → 通常どおり。
#   現行のフィードを読めない（404 以外の失敗・解釈不能）場合は配信しない。
Set-StrictMode -Version Latest

function Test-PrunletVelopackImmutable([IO.FileInfo]$File) {
    return $File.Extension -eq '.nupkg' -or $File.Name -match '\d+\.\d+\.\d+'
}
function Get-PrunletVelopackOrder([IO.FileInfo]$File) {
    if (Test-PrunletVelopackImmutable $File) { return 0 }
    if ($File.Name -like 'releases.*.json') { return 1 }
    if ($File.Name -like 'assets.*.json') { return 3 }
    if ($File.Name -like 'RELEASES*') { return 4 }
    return 2
}
function Get-PrunletVelopackFeedVersion([string]$Json, [string]$PackId) {
    try { $feed = $Json | ConvertFrom-Json -ErrorAction Stop } catch { throw 'The current feed is not valid JSON; not publishing.' }
    if (!($feed.PSObject.Properties.Name -contains 'Assets')) { throw 'The current feed has no Assets; not publishing.' }
    $versions = @($feed.Assets | Where-Object { $_.Type -eq 'Full' -and $_.PackageId -ceq $PackId } | ForEach-Object { [semver]$_.Version })
    if (!$versions.Count) { return $null }
    return ($versions | Sort-Object | Select-Object -Last 1)
}
function Get-PrunletVelopackDecision($Local, $Remote) {
    if ($null -eq $Remote) { return 'full' }
    if ($Remote -gt $Local) { throw "The current feed already has a newer version ($Remote > $Local); refusing to roll the feed back." }
    if ($Remote -eq $Local) { return 'verify-only' }
    return 'full'
}
function Get-PrunletVelopackPlan([IO.FileInfo[]]$Files, [string]$Decision) {
    foreach ($file in @($Files | Sort-Object @{ Expression = { Get-PrunletVelopackOrder $_ } }, Name)) {
        $immutable = Test-PrunletVelopackImmutable $file
        if (!$immutable -and $Decision -eq 'verify-only') { continue }
        [pscustomobject]@{ File = $file; Immutable = $immutable }
    }
}

function Invoke-PrunletVelopackPublication {
    param(
        [Parameter(Mandatory)]$Session, [Parameter(Mandatory)][IO.FileInfo[]]$Files, [Parameter(Mandatory)][IO.FileInfo]$Nupkg,
        [Parameter(Mandatory)][semver]$LocalVersion, [Parameter(Mandatory)][string]$Channel, [Parameter(Mandatory)][string]$PackId,
        [Parameter(Mandatory)][string]$CommitSha, [Parameter(Mandatory)][string]$DefaultBranch,
        [string]$SigningKeyPem = $env:PRUNLET_RELEASE_SIGNING_KEY, $Trust = (Get-PrunletReleaseTrust),
        # 署名マニフェストだけを置いて止める（workflow が「マニフェスト → 一式」を別 step で見せるため）。
        # 検査（既存マニフェスト・フィードの後退判定）は同じ内容で先に行う。
        [switch]$ManifestOnly
    )
    # 署名付きマニフェストは 3 要素の厳密な版（x.y.z）だけを扱う（prerelease の版は配信しない）。
    $facts = Get-PrunletReleaseFileFacts $Nupkg.FullName
    $spec = New-PrunletReleaseSpec -Runtime 'velopack-win-x64' -Version $LocalVersion.ToString() -CommitSha $CommitSha -DefaultBranch $DefaultBranch -Sha256 $facts.Sha256 -Bytes $facts.Bytes
    if ($spec.AssetName -cne $Nupkg.Name) { Stop-PrunletR2 'identity' 'invalid-input' }

    # --- 書込み前の検査（読取りだけ） ---
    # 既存の版マニフェストとの一致（署名・payload）。未作成なら署名して信頼鍵で検証する。
    $plan = Get-PrunletRuntimePlan -Session $Session -Spec $spec -Trust $Trust -SigningKeyPem $SigningKeyPem
    # 現行フィード（認証付き GET。公開ホストの CDN を経由しない）。読んだ ETag は置換時の If-Match に使う。
    $feed = Read-PrunletR2Object -Session $Session -Key "velopack/releases.$Channel.json" -MaxBytes 4MB
    $remote = $null; $feedETag = ''
    if ($feed.Status -eq 200) {
        $remote = Get-PrunletVelopackFeedVersion ([Text.UTF8Encoding]::new($false, $true).GetString($feed.Bytes)) $PackId
        $feedETag = $feed.ETag
    }
    $decision = Get-PrunletVelopackDecision $LocalVersion $remote
    Write-Host "local=$LocalVersion current feed=$(if ($null -eq $remote) { 'none' } else { $remote }) decision=$decision"

    # --- 書込み ---
    $null = Publish-PrunletVersionManifest -Session $Session -Plan $plan -Trust $Trust
    if ($ManifestOnly) { return [pscustomobject]@{ Decision = $decision; Version = $LocalVersion.ToString(); ManifestOnly = $true } }
    foreach ($item in (Get-PrunletVelopackPlan $Files $decision)) {
        $file = $item.File
        $cacheControl = if ($item.Immutable) { 'public, max-age=31536000, immutable' } else { 'no-cache, must-revalidate' }
        $contentType = switch ($file.Extension.ToLowerInvariant()) {
            '.json' { 'application/json'; break }
            '.exe' { 'application/vnd.microsoft.portable-executable'; break }
            default { if ($file.Name -like 'RELEASES*') { 'text/plain; charset=utf-8' } else { 'application/octet-stream' } }
        }
        Write-Host "  upload velopack/$($file.Name) ($(if ($item.Immutable) { 'create-only' } else { 'replace' }))"
        $arguments = @{ Session = $Session; Key = "velopack/$($file.Name)"; FilePath = $file.FullName; ContentType = $contentType; CacheControl = $cacheControl }
        if ($item.Immutable) { $arguments.Immutable = $true }
        # フィードは、判定のために読んだ版と同じものだけを置き換える（後退防止の判定を書込みまで有効に保つ）。
        if ($file.Name -ceq "releases.$Channel.json" -and $feedETag) { $arguments.ExpectedETag = $feedETag }
        $null = Publish-PrunletR2File @arguments
    }
    if ($decision -eq 'verify-only') { Write-Host 'Fixed-name objects were not replaced (the feed already has this version).' }
    return [pscustomobject]@{ Decision = $decision; Version = $LocalVersion.ToString() }
}
