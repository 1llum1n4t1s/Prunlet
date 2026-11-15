#requires -Version 7.0
# Prunlet の Windows x64 版 Setup（Velopack、ユーザー単位、%LOCALAPPDATA%\PrunletApp へ導入）を梱包する。
# 実行環境: Windows x64（PowerShell 7+、Velopack CLI vpk 1.2.161）。手元または GitHub Actions（windows-latest）。
# 配信先: Cloudflare R2 バケット prunlet-updates の velopack/（公開 URL https://prunlet.kagayoi.com/velopack/）。
# 配信は scripts/velopack/publish-r2.ps1、梱包物の検証は scripts/velopack/verify-windows.ps1 が行う。
#
# 入力は Publish-Prunlet.ps1 の出力 publish\（prunlet.exe・prunlet-maintenance.exe。リリースでは
# Sign-PrunletBuild.ps1 で署名済み）。このスクリプトは cargo を動かさない（署名用 Secrets を渡す step でも
# 依存 crate の build script を走らせないため）。prunlet-hook.exe はルートの外（%LOCALAPPDATA%\Prunlet\hook）へ
# インストール時に複製するので nupkg へ入れない。
#
# lib/app/ へ入れるのは prunlet.exe・prunlet-maintenance.exe・LICENSE だけ（Velopack 管理ファイルは vpk が足す）。
# ps1・PRUNLET.md・hook は同梱しない（共通指示は exe に埋め込み）。
#
# -Sign: vpk が生成する Update.exe（Squirrel.exe）・Setup.exe などを Sigilune で署名する。署名済みの
# prunlet.exe・prunlet-maintenance.exe は Sign-IfNeeded.ps1 が再署名せず通す（ZIP 配布物と同じバイト列を保つ）。
# 手元は `sigilune setup` 済み、CI は SIGILUNE_EMAIL / SIGILUNE_TOTP_URI を渡した step で実行する。
#
# 検証用（本番では使わない）: -PackId / -PackVersion を既定値以外にした梱包は未署名のテスト用で、-Sign と併用できない。
[CmdletBinding()]
param(
    # 空の通常ディレクトリ（絶対パス）。packages\ などを作る。
    [Parameter(Mandatory)][string]$WorkDirectory,
    # prunlet.exe・prunlet-maintenance.exe を含む publish ディレクトリ（絶対パス）。
    [Parameter(Mandatory)][string]$PublishDirectory,
    [switch]$Sign,
    [string]$PackId = 'PrunletApp',
    # 省略時は prunlet.exe の ProductVersion（+ より前）。
    [string]$PackVersion
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

if (!$IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') { throw 'Pack the installer on Windows x64.' }
if ($PackId -notmatch '^[A-Za-z][A-Za-z0-9]*$') { throw 'PackId must be alphanumeric.' }
if ($Sign -and ($PackId -cne 'PrunletApp')) { throw '-Sign cannot be combined with a non-production -PackId (those are for isolated validation packages).' }
foreach ($path in @($WorkDirectory, $PublishDirectory)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'WorkDirectory and PublishDirectory must be absolute paths.' }
}
$work = Get-Item -LiteralPath $WorkDirectory -Force
if (!$work.PSIsContainer -or (Get-ChildItem -LiteralPath $work.FullName -Force | Select-Object -First 1)) {
    throw 'The work directory must be an empty, ordinary directory.'
}
for ($folder = $work; $null -ne $folder; $folder = $folder.Parent) {
    if ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "The work path contains a reparse point: $($folder.FullName)" }
}
$publish = Get-Item -LiteralPath $PublishDirectory -Force
if (!$publish.PSIsContainer) { throw 'PublishDirectory must be a directory.' }

# GitHub Actions では vpk が色付け用のエスケープシーケンスを出し、`\b` の照合が外れるため取り除いてから比べる。
$vpkHelp = (vpk --help | Out-String) -replace "`e\[[0-9;]*m", ''
if ($vpkHelp -notmatch '\bVelopack CLI 1\.2\.161\b') { throw 'Velopack CLI 1.2.161 is required.' }

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$payload = Join-Path $work.FullName 'payload'
$packages = Join-Path $work.FullName 'packages'
$temp = Join-Path $work.FullName 'temp'
New-Item -ItemType Directory -Path $payload, $packages, $temp | Out-Null

# 製品 exe（署名済みの場合はそのバイト列を保つ）と LICENSE だけを入れる。
foreach ($name in @('prunlet.exe', 'prunlet-maintenance.exe')) {
    $source = Join-Path $publish.FullName $name
    if (!(Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing published executable: $name" }
    if ((Get-Item -LiteralPath $source -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Published executable cannot be a link: $name" }
    Copy-Item -LiteralPath $source -Destination (Join-Path $payload $name)
}
$license = Join-Path $repo 'LICENSE'
if (!(Test-Path -LiteralPath $license -PathType Leaf)) { throw 'LICENSE was not found in the repository root.' }
Copy-Item -LiteralPath $license -Destination (Join-Path $payload 'LICENSE')

if (!$PackVersion) {
    $PackVersion = ([Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $payload 'prunlet.exe')).ProductVersion -split '\+')[0]
}
if ($PackVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw "Unsupported pack version: $PackVersion" }
# 本番の版は exe の版と一致していなければならない（クライアントは適用前に同じ照合をする）。
$exeVersion = ([Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $payload 'prunlet.exe')).ProductVersion -split '\+')[0]
if ($PackId -ceq 'PrunletApp' -and $exeVersion -cne $PackVersion) { throw "prunlet.exe version ($exeVersion) differs from the pack version ($PackVersion)." }

$signing = @()
if ($Sign) {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Signing.Common.ps1')
    $sigilune = Find-PrunletSigilune
    # vpk はファイルごとにテンプレートを実行する。1 ファイルずつ直列に処理し（Sigilune は複数ファイルの同時署名で
    # 異常終了した実績がある。docs/distribution.md）、Sign-IfNeeded.ps1 が署名済みの exe を再署名せず、署名後の検証も行う。
    $wrapper = Join-Path $PSScriptRoot 'Sign-IfNeeded.ps1'
    $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $signing = @(
        '--signParallel', '1',
        '--signTemplate', "`"$pwsh`" -NoProfile -NonInteractive -File `"$wrapper`" -SigiluneExe `"$sigilune`" -Path {{file}}"
    )
}

$previousTemp = $env:TEMP; $previousTmp = $env:TMP
$previousEmail = $env:SIGILUNE_EMAIL; $previousTotp = $env:SIGILUNE_TOTP_URI
try {
    if ($Sign) {
        # 署名用の資格情報（SIGILUNE_EMAIL・SIGILUNE_TOTP_URI）は、vpk（第三者の .NET ツール）とその子プロセスへ渡さない。
        # 先に Sigilune のセッションを用意し（有効なキャッシュは再利用し、無ければここで 1 回だけログインする）、
        # そのあと環境変数を外して vpk を動かす。署名ラッパーは、プロセス間で共有されるキャッシュのセッションだけで署名する。
        # セッションが途中で切れたらラッパーの署名が失敗し、vpk pack が止まる（資格情報を渡し直して再ログインはしない）。
        & $sigilune login
        if ($LASTEXITCODE -ne 0) { throw "sigilune login failed with exit code $LASTEXITCODE." }
        $env:SIGILUNE_EMAIL = $null; $env:SIGILUNE_TOTP_URI = $null
    }
    # TEMP/TMP を梱包専用のディレクトリへ向ける（子プロセスの一時ファイル用）。ただし vpk 自身の作業領域は
    # TEMP を見ず %LOCALAPPDATA%\Temp\velopack に作られる（1.2.161 で確認。梱包後は空になる）。
    $env:TEMP = $temp; $env:TMP = $temp
    # ショートカットは作らない（CLI・MCP・フックが主体で、スタートメニューに置くものが無い）。
    # packId は作業フォルダー %LOCALAPPDATA%\Prunlet（Backups 等）と衝突しない名前にする。
    $packOptions = @(
        '--packId', $PackId,
        '--packTitle', 'Prunlet',
        '--packAuthors', 'Kagayoi',
        '--packVersion', $PackVersion,
        '--channel', 'win',
        '--runtime', 'win-x64',
        '--instLocation', 'PerUser',
        '--mainExe', 'prunlet.exe',
        '--packDir', $payload,
        '--outputDir', $packages,
        '--shortcuts', 'None',
        '--noPortable',
        '--delta', 'None'
    )
    vpk pack @packOptions @signing
    $setup = Join-Path $packages "$PackId-win-Setup.exe"
    if (!(Test-Path -LiteralPath $setup -PathType Leaf)) { throw 'Setup executable was not generated.' }
    # 自動更新の更新元（R2）には Setup のほか releases.win.json と full nupkg が必要（Setup だけでは新版を見つけられない）。
    foreach ($required in @('releases.win.json', "$PackId-$PackVersion-full.nupkg")) {
        if (!(Test-Path -LiteralPath (Join-Path $packages $required) -PathType Leaf)) { throw "Update feed file was not generated: $required" }
    }
    # 版付きの不変名の Setup も置く（固定名 Setup は最新版を指す URL として毎回置き換える）。
    Copy-Item -LiteralPath $setup -Destination (Join-Path $packages "$PackId-$PackVersion-win-Setup.exe")
} finally {
    $env:TEMP = $previousTemp; $env:TMP = $previousTmp
    if ($null -ne $previousEmail) { $env:SIGILUNE_EMAIL = $previousEmail }
    if ($null -ne $previousTotp) { $env:SIGILUNE_TOTP_URI = $previousTotp }
}
[ordered]@{
    packId = $PackId; version = $PackVersion; signed = [bool]$Sign
    packages = $packages
    files = @(Get-ChildItem -LiteralPath $packages -File -Force | Sort-Object Name | ForEach-Object { $_.Name })
} | ConvertTo-Json -Depth 4
