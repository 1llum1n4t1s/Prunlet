#requires -Version 7.0
# Windows版の配布用更新ZIP（win-x64・win-arm64）を、署名付きでローカル生成する。
#
# SimplySignの署名はGitHub Actionsでは行えないため、Apple Silicon版と同じく
# リリース担当者の機械でビルド・署名・梱包・検証までを行う。生成したZIPは
# GitHub Releaseの下書きへ添付し、公開後にrelease workflowが同じZIPを検証して
# 既存のR2へ配置する（docs/distribution.md）。このスクリプトはGitHub・R2へ送信しない。
#
# 例: pwsh -NoProfile -File .\scripts\Publish-PrunletWindows.ps1 -OutputDirectory D:\tmp\prunlet-release-1.0.43 -CommitSha <40桁SHA>
[CmdletBinding()]
param(
    # 未使用の外部絶対パス。runtimeごとのビルド出力とZIPをこの下に作る。
    [Parameter(Mandatory)][string]$OutputDirectory,
    # リリースするコミット。チェックアウトのHEADと一致し、既定ブランチに含まれている必要がある。
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$CommitSha,
    [ValidateSet('win-x64', 'win-arm64')][string[]]$Runtime = @('win-x64', 'win-arm64'),
    [string]$DefaultBranch = 'main',
    [string]$Repository = '1llum1n4t1s/Prunlet'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot 'Signing.Common.ps1')

if (![IO.Path]::IsPathFullyQualified($OutputDirectory)) { throw 'OutputDirectory must be absolute.' }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputRoot) { throw 'OutputDirectory must not exist yet; use a new directory.' }
if ($DefaultBranch -notmatch '^[A-Za-z0-9._/-]+$') { throw 'DefaultBranch is not a supported branch name.' }

# 署名ツールと証明書を最初に確認し、SimplySign未接続ならビルド前に止める。
$null = Find-PrunletSignTool
$null = Get-PrunletSigningCertificate

# 公開するコミットのクリーンなチェックアウトだけを受け付ける（release workflowの旧検査と同じ条件）。
$head = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -cne $CommitSha) { throw 'Checkout HEAD differs from CommitSha.' }
$dirty = & git -C $repoRoot status --porcelain --untracked-files=all
if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'Checkout has uncommitted or untracked files.' }
& git -C $repoRoot fetch --quiet origin $DefaultBranch
if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch the default branch.' }
& git -C $repoRoot merge-base --is-ancestor $CommitSha ('refs/remotes/origin/' + $DefaultBranch)
if ($LASTEXITCODE -ne 0) { throw 'CommitSha is not on the default branch.' }

$manifestText = [IO.File]::ReadAllText((Join-Path $repoRoot 'Cargo.toml'))
$versionMatches = [regex]::Matches($manifestText, '(?ms)^\[package\]\s*\r?\n(?:(?!\[)[^\r\n]*\r?\n)*?version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"')
if ($versionMatches.Count -ne 1) { throw 'Cargo package version is missing or unsupported.' }
$version = $versionMatches[0].Groups[1].Value

$null = New-Item -ItemType Directory -Path $outputRoot
$results = [Collections.Generic.List[object]]::new()
$oldCommit = $env:PRUNLET_SOURCE_COMMIT
try {
    $env:PRUNLET_SOURCE_COMMIT = $CommitSha
    foreach ($rid in $Runtime) {
        $build = Join-Path $outputRoot "build-$rid"
        $publish = Join-Path $build 'publish'
        $package = Join-Path $outputRoot "prunlet-update-$rid.zip"
        & (Join-Path $PSScriptRoot 'Publish-Prunlet.ps1') -OutputDirectory $build -Runtime $rid -Sign | Out-Null
        foreach ($name in @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe')) {
            $product = Join-Path $publish $name
            $productVersion = ([Diagnostics.FileVersionInfo]::GetVersionInfo($product).ProductVersion -split '\+')[0]
            if ($productVersion -cne $version) { throw "Published product version differs: $name $productVersion" }
        }
        & (Join-Path $PSScriptRoot 'Package-PrunletUpdate.ps1') -SourceRoot $repoRoot -PublishDirectory $publish -OutputPath $package -CommitSha $CommitSha -DefaultBranch $DefaultBranch -Runtime $rid -Repository $Repository | Out-Null
        $sha256 = & (Join-Path $PSScriptRoot 'Verify-ReleasePackage.ps1') -PackagePath $package -SourceRoot $repoRoot -PublishDirectory $publish -CommitSha $CommitSha -DefaultBranch $DefaultBranch -Runtime $rid -Repository $Repository -RequireSignature
        if ($sha256 -cnotmatch '^[0-9A-F]{64}$') { throw "Package verification did not return a hash: $rid" }
        $results.Add([ordered]@{ runtime = $rid; path = $package; bytes = (Get-Item -LiteralPath $package).Length; sha256 = $sha256 })
    }
} finally { $env:PRUNLET_SOURCE_COMMIT = $oldCommit }

# 添付直前にもこのsize・SHA-256と一致することを確認する。
[ordered]@{ version = $version; commitSha = $CommitSha; signer = $script:PrunletSignerCommonName; packages = $results } | ConvertTo-Json -Depth 4
