#requires -Version 7.0
# pack-windows.ps1 の出力 packages\ を、配信前に検証する（Velopack 検証）。
# 本検査は、クライアント（src/ の適用前検査）が nupkg に課す条件と同じ内容を、配信側でも先に通すためのもの。
# ここで通らない一式は配信しない（配信すると、全利用者の更新が適用前に拒否される）。
#
# 検査:
# - 必須ファイル（固定名 Setup・版付き Setup・full nupkg・releases.<channel>.json）と、フィードの Full 資産
#   （版・FileName・SHA256・Size）が nupkg の実物と一致すること。
# - nupkg のエントリ集合: lib/app/ は許可集合（prunlet.exe・prunlet-maintenance.exe・Squirrel.exe・Velopack 管理ファイル・LICENSE）
#   だけで、prunlet.exe と Squirrel.exe がちょうど 1 つずつ。lib/app/ の外は nupkg の定型（nuspec・メタデータ）だけ。
#   ps1・PRUNLET.md・prunlet-hook.exe などの余分なエントリは拒否。
# - lib/app/ の全 PE（.exe・.dll）: PE の machine が x64、-RequireSignature なら Authenticode が Valid・
#   署名者 CN Open Source Developer Yuichiro Shinozaki・タイムスタンプ付き。
# - prunlet.exe・prunlet-maintenance.exe: 版リソースの製品名が Prunlet、製品版（+ より前）が nupkg の版と一致。
# - -RequireSignature なら Setup（固定名・版付き）も署名者・タイムスタンプ付きの Valid。
# - nupkg の SHA-256 を `<hex>  <file名>` で -ReleaseAssetsDirectory へ書く（GitHub Release へ添付し、クライアントが
#   R2 から取得した nupkg と照合する基点。R2 へ上げる nupkg と同一物）。packages\ には書かない（配信物に混ぜない）。
#
# 失敗は例外で止まる。成功すると結果の JSON を 1 つ出力する。
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagesDirectory,
    [Parameter(Mandatory)][string]$ExpectedVersion,
    # SHA-256 ファイルの出力先（空の新規ディレクトリ、または存在しない絶対パス）。
    [Parameter(Mandatory)][string]$ReleaseAssetsDirectory,
    # nupkg 内の PE を一時的に展開する作業ディレクトリ（絶対パス）。省略時は $env:RUNNER_TEMP（CI）。
    # 手元では必ず指定する（C の TEMP を使わない）。展開物（prunlet-velopack-verify-<guid>）は残すので、手元では呼び出し側が清掃する。
    [string]$ScratchDirectory = $env:RUNNER_TEMP,
    [string]$PackId = 'PrunletApp',
    [string]$Channel = 'win',
    [switch]$RequireSignature
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Signing.Common.ps1')

foreach ($path in @($PackagesDirectory, $ReleaseAssetsDirectory)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'PackagesDirectory and ReleaseAssetsDirectory must be absolute paths.' }
}
if ($ExpectedVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw "Unsupported version: $ExpectedVersion" }
if ($PackId -notmatch '^[A-Za-z][A-Za-z0-9]*$') { throw 'PackId must be alphanumeric.' }
$packages = Get-Item -LiteralPath $PackagesDirectory -Force
if (!$packages.PSIsContainer) { throw 'The packages path must be a directory.' }
$files = @(Get-ChildItem -LiteralPath $packages.FullName -File -Force)
if ($files | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw 'The packages directory cannot contain links.' }

$nupkgName = "$PackId-$ExpectedVersion-full.nupkg"
$setupName = "$PackId-$Channel-Setup.exe"
$versionedSetupName = "$PackId-$ExpectedVersion-$Channel-Setup.exe"
foreach ($required in @($setupName, $versionedSetupName, $nupkgName, "releases.$Channel.json")) {
    if ($files.Name -notcontains $required) { throw "Missing required file: $required" }
}
# 配信する nupkg は 1 つだけ（古い版の取り残しを検出する）。
if (@($files | Where-Object { $_.Name -like '*.nupkg' }).Count -ne 1) { throw 'The packages directory must contain exactly one nupkg (the full package of this version).' }
$nupkg = Join-Path $packages.FullName $nupkgName

# フィードの Full 資産と nupkg の実物が一致すること。
$feed = Get-Content -LiteralPath (Join-Path $packages.FullName "releases.$Channel.json") -Raw | ConvertFrom-Json
$assets = @($feed.Assets | Where-Object { $_.Type -eq 'Full' })
if ($assets.Count -ne 1 -or $assets[0].PackageId -cne $PackId -or $assets[0].Version -cne $ExpectedVersion -or $assets[0].FileName -cne $nupkgName) {
    throw 'releases.<channel>.json must list exactly the Full package of this version.'
}
$nupkgItem = Get-Item -LiteralPath $nupkg
$nupkgSha256 = (Get-FileHash -LiteralPath $nupkg -Algorithm SHA256).Hash.ToLowerInvariant()
if ([long]$assets[0].Size -ne $nupkgItem.Length -or ([string]$assets[0].SHA256).ToLowerInvariant() -cne $nupkgSha256) {
    throw 'The feed size or SHA-256 differs from the nupkg.'
}

# エントリ集合。lib/app/ の許可名は、vpk 1.2.161 が実際に作る一式で確かめた値（docs/verification.md）。
$allowedApp = @('prunlet.exe', 'prunlet-maintenance.exe', 'Squirrel.exe', 'Prunlet_ExecutionStub.exe', 'LICENSE', 'sq.version')
# lib/app/ の外（クライアントの src/rust/app_update/trust.rs `check_entries` と同じ集合。大文字小文字は区別しない）。
# OPC のコアプロパティ（package/services/metadata/core-properties/ 直下の *.psmdcp）も許可する。現行の vpk の実物には出ない。
# フォルダーのエントリは lib・lib/app・_rels・package 以下の 4 つだけ。
$allowedOutside = @('[Content_Types].xml', '_rels/.rels', 'setup.ico', "$PackId.nuspec")
$allowedFolders = @('lib/', 'lib/app/', '_rels/', 'package/', 'package/services/', 'package/services/metadata/', 'package/services/metadata/core-properties/')
$psmdcpPattern = '(?i)^package/services/metadata/core-properties/[^/]+\.psmdcp$'
$expectedProducts = @('prunlet.exe', 'prunlet-maintenance.exe')
if (!$ScratchDirectory -or ![IO.Path]::IsPathFullyQualified($ScratchDirectory) -or !(Test-Path -LiteralPath $ScratchDirectory -PathType Container)) {
    throw 'Specify -ScratchDirectory as an existing absolute directory (it defaults to RUNNER_TEMP in CI).'
}
$temp = Join-Path $ScratchDirectory ('prunlet-velopack-verify-' + [Guid]::NewGuid().ToString('N'))
$verified = [Collections.Generic.List[string]]::new()
$archive = [IO.Compression.ZipFile]::OpenRead($nupkg)
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    $appNames = [Collections.Generic.List[string]]::new()
    $seenNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $nuspecCount = 0
    foreach ($entry in $archive.Entries) {
        $name = $entry.FullName
        if ($name -match '(^|/)\.\.(/|$)' -or $name.StartsWith('/') -or $name.Contains('\') -or $name.Contains(':') -or $name.Length -eq 0) { throw "Unsafe nupkg entry name: $name" }
        if (!$seenNames.Add($name)) { throw "Duplicate nupkg entry: $name" }
        if ($name.EndsWith('/')) {
            if ($allowedFolders -notcontains $name) { throw "Unexpected folder entry in the nupkg: $name" }
            continue
        }
        if ("$PackId.nuspec" -ieq $name) { $nuspecCount++ }
        if ($name.StartsWith('lib/app/', [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $name.Substring('lib/app/'.Length)
            # lib/app/ 直下のフラットな集合だけを許す（サブディレクトリ・余分なファイルは拒否）。
            if ($relative.Contains('/') -or $allowedApp -notcontains $relative) { throw "Unexpected entry in lib/app/: $relative" }
            $appNames.Add($relative)
        } elseif ($allowedOutside -notcontains $name -and $name -notmatch $psmdcpPattern) {
            throw "Unexpected nupkg entry outside lib/app/: $name"
        }
    }
    if ($nuspecCount -ne 1) { throw 'The nupkg must contain exactly one package manifest (.nuspec).' }
    foreach ($required in @('prunlet.exe', 'Squirrel.exe')) {
        if (@($appNames | Where-Object { $_ -ieq $required }).Count -ne 1) { throw "The nupkg must contain exactly one lib/app/$required." }
    }
    foreach ($required in $expectedProducts) {
        if (@($appNames | Where-Object { $_ -ieq $required }).Count -ne 1) { throw "The nupkg must contain exactly one lib/app/$required." }
    }

    foreach ($entry in @($archive.Entries | Where-Object { $_.FullName -match '(?i)^lib/app/[^/]+\.(exe|dll)$' })) {
        $leaf = $entry.FullName.Substring('lib/app/'.Length)
        $extracted = Join-Path $temp ([Guid]::NewGuid().ToString('N') + '.bin')
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $extracted)
        # PE の machine（x64 = 0x8664）。
        $bytes = [IO.File]::ReadAllBytes($extracted)
        if ($bytes.Length -lt 0x40 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw "$leaf is not a PE file." }
        $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
        if ($peOffset -lt 0 -or $peOffset + 6 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $peOffset) -ne 0x00004550) { throw "$leaf has an invalid PE header." }
        if ([BitConverter]::ToUInt16($bytes, $peOffset + 4) -ne 0x8664) { throw "$leaf is not an x64 executable." }
        if ($RequireSignature) {
            $null = Assert-PrunletAuthenticodeSigned $extracted
        }
        if ($expectedProducts -contains $leaf.ToLowerInvariant()) {
            $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($extracted)
            if ($info.ProductName -cne 'Prunlet') { throw "$leaf has an unexpected product name: $($info.ProductName)" }
            if (($info.ProductVersion -split '\+')[0] -cne $ExpectedVersion) { throw "$leaf product version ($($info.ProductVersion)) differs from the package version ($ExpectedVersion)." }
        }
        $verified.Add($leaf)
    }
} finally {
    $archive.Dispose()
    # 展開した PE は prunlet-velopack-verify-<guid> に残す。削除は行わない（CI は job 終了で消え、手元は呼び出し側が
    # 所定の手順で清掃する。削除手段を持たないことで、手元の検証が意図しない場所を消さない）。
}

if ($RequireSignature) {
    foreach ($setup in @($setupName, $versionedSetupName)) {
        $null = Assert-PrunletAuthenticodeSigned (Join-Path $packages.FullName $setup)
    }
}

# GitHub Release へ添付する nupkg の SHA-256（R2 へ上げる nupkg と同一物）。
if (Test-Path -LiteralPath $ReleaseAssetsDirectory) {
    if (Get-ChildItem -LiteralPath $ReleaseAssetsDirectory -Force | Select-Object -First 1) { throw 'ReleaseAssetsDirectory must be empty.' }
} else {
    New-Item -ItemType Directory -Path $ReleaseAssetsDirectory | Out-Null
}
$hashFile = Join-Path $ReleaseAssetsDirectory "$nupkgName.sha256"
[IO.File]::WriteAllText($hashFile, "$nupkgSha256  $nupkgName`n", [Text.UTF8Encoding]::new($false))

[ordered]@{
    status = 'verified'; packId = $PackId; version = $ExpectedVersion; signatureChecked = [bool]$RequireSignature
    nupkg = $nupkgName; nupkgSha256 = $nupkgSha256; hashFile = $hashFile
    appEntries = @($appNames | Sort-Object); verifiedExecutables = @($verified | Sort-Object)
} | ConvertTo-Json -Depth 4
