#requires -Version 7.2
# 配信 workflow（main のコミットに付けた軽量タグ v<版> の push・同じタグ ref での再実行）の起動元を検査し、後続 step へ版・commit・既定ブランチを渡す。
# GitHub Release は使わない。「配信してよい commit か」はこの検査だけで決まる:
#   - ref がタグで、名前が厳密に `v<版>`（v0.0.0 形。先頭ゼロなし）かつ <版> が Cargo.toml の版（x.y.z）と一致する
#   - タグが軽量タグで、いまもこの commit（GITHUB_SHA）を指している（GitHub API で照会する）
#   - チェックアウトの HEAD が GITHUB_SHA と同じ commit（別 commit を黙ってビルドしない）
#   - その commit が既定ブランチ（origin/<既定ブランチ>）の祖先である（main に取り込み済みの commit だけを配信する。要 fetch-depth: 0）
# 環境変数: GITHUB_REF_TYPE・GITHUB_REF_NAME・GITHUB_SHA・GITHUB_REPOSITORY・GH_TOKEN（既定ブランチとタグの照会に使う）・GITHUB_OUTPUT。
# -AllowNonRelease: タグ以外の ref（検証だけの実行）では失敗にせず `release=false` を出力する（Linux の build job 用）。
#   タグの ref では上の検査をすべて無条件に要求する（タグなのに版が合わない実行は失敗）。
#   この場合も版と commit は出力するが、配信側 job はこの出力を使わず ref 条件で skip する。
# 出力（GITHUB_OUTPUT と標準出力の JSON）: release・version・commit・branch。
[CmdletBinding()]
param(
    [string]$SourceRoot = $(if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { Split-Path -Parent $PSScriptRoot }),
    # テスト用: 既定ブランチ名を直接渡す（未指定なら gh api で照会する）。
    [string]$DefaultBranch,
    # テスト用: タグ ref の照会結果（`commit <40桁sha>` の形）を直接渡す（未指定なら gh api で照会する）。
    [string]$TagObject,
    [switch]$AllowNonRelease
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-GitText([string[]]$Arguments) {
    $text = (& git -C $SourceRoot @Arguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments[0]) failed." }
    return $text
}

$cargo = Join-Path $SourceRoot 'Cargo.toml'
$line = Get-Content -LiteralPath $cargo | Where-Object { $_ -cmatch '^version = "' } | Select-Object -First 1
if ($null -eq $line -or !($line -cmatch '^version = "([0-9]+\.[0-9]+\.[0-9]+)"$')) { throw 'Cargo.toml does not hold a x.y.z version.' }
$version = $Matches[1]
$commit = Get-GitText @('rev-parse', 'HEAD')
if ($commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Checkout commit is invalid.' }

$refType = $env:GITHUB_REF_TYPE; $refName = $env:GITHUB_REF_NAME
$isRelease = $refType -ceq 'tag'
if (!$isRelease) {
    if (!$AllowNonRelease) { throw 'The run is not from a version tag (v<version>).' }
    $result = [ordered]@{ release = 'false'; version = $version; commit = $commit; branch = '' }
} else {
    if ($refName -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'The tag name is not a strict v<major>.<minor>.<patch>.' }
    if ($refName -cne "v$version") { throw "The tag name does not match the Cargo.toml version ($version)." }
    if ($commit -cne $env:GITHUB_SHA) { throw 'Checkout differs from the event commit.' }
    # 軽量タグで、いまもこの commit を指すこと（注釈付きタグ・付け替え済みのタグを拒否する）。
    $tagObject = $TagObject
    if (!$tagObject) {
        $tagObject = (& gh api "repos/$env:GITHUB_REPOSITORY/git/ref/tags/$refName" --jq '.object.type + " " + .object.sha' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Could not read the tag ref.' }
    }
    if ($tagObject -cne "commit $commit") { throw 'The tag is not a lightweight tag that points at the event commit.' }
    $branch = $DefaultBranch
    if (!$branch) {
        $branch = (& gh api "repos/$env:GITHUB_REPOSITORY" --jq '.default_branch' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Could not read the default branch.' }
    }
    if ($branch -cnotmatch '^[A-Za-z0-9._/-]+$' -or $branch.Contains('..')) { throw 'Default branch is invalid.' }
    & git -C $SourceRoot merge-base --is-ancestor $commit ('refs/remotes/origin/' + $branch)
    if ($LASTEXITCODE -ne 0) { throw 'The release commit is not on the default branch.' }
    $result = [ordered]@{ release = 'true'; version = $version; commit = $commit; branch = $branch }
}
if ($env:GITHUB_OUTPUT) { foreach ($name in $result.Keys) { "$name=$($result[$name])" >> $env:GITHUB_OUTPUT } }
$result | ConvertTo-Json -Compress
