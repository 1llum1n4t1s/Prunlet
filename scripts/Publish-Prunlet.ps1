[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [string]$TargetDirectory = $env:PRUNLET_CARGO_TARGET_DIRECTORY,
    [switch]$IncludeVerificationProbe,
    # 配布用にprunlet.exe・prunlet-maintenance.exeへAuthenticode署名する。SimplySignへの
    # ログインが必要なため、リリース担当者のWindows機（Publish-PrunletWindows.ps1）だけで使う。
    [switch]$Sign
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot 'RustBuildInputs.Common.ps1')
if ($Sign) {
    . (Join-Path $PSScriptRoot 'Signing.Common.ps1')
    if ($IncludeVerificationProbe) { throw 'Signed release builds cannot include verification probes.' }
    # 長いビルドの後で失敗しないよう、署名ツールと証明書を先に確認する。
    $null = Find-PrunletSignTool
    $null = Get-PrunletSigningCertificate
}
if (-not [IO.Path]::IsPathFullyQualified($OutputDirectory)) { throw 'OutputDirectory must be absolute.' }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$targetRoot = if ($TargetDirectory) {
    if (-not [IO.Path]::IsPathFullyQualified($TargetDirectory)) { throw 'TargetDirectory must be absolute.' }
    [IO.Path]::GetFullPath($TargetDirectory)
} else { Join-Path $outputRoot 'cargo-target' }
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
foreach ($path in @($outputRoot, $targetRoot)) {
    foreach ($forbiddenRoot in @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))) {
        if ($path.Equals($forbiddenRoot, [StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($forbiddenRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Build output and Cargo target must be outside the repository and Codex home.'
        }
    }
    $ancestor = $path
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Build output and Cargo target cannot traverse links.' }
            if (Test-Path -LiteralPath (Join-Path $ancestor '.git')) { throw 'Build output and Cargo target cannot be inside a repository.' }
        }
        $ancestor = Split-Path -Parent $ancestor
    }
}
$publish = Join-Path $outputRoot 'publish'
$tempRoot = Join-Path $outputRoot 'temp'
foreach ($other in @($publish, $tempRoot)) {
    if ($targetRoot.Equals($other, [StringComparison]::OrdinalIgnoreCase) -or $targetRoot.StartsWith($other.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $other.StartsWith($targetRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Cargo target must be separate from publish and temporary directories.' }
}
$manifestPath = Join-Path $outputRoot 'build-manifest.json'
if (Test-Path -LiteralPath $manifestPath) { throw 'Build manifest already exists; use a new output directory.' }
foreach ($path in @($targetRoot, $tempRoot, $publish)) {
    if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Build output cannot traverse links.' }
    if (Test-Path -LiteralPath $path -PathType Container) {
        if (@(Get-ChildItem -LiteralPath $path -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Build output cannot contain links.' }
    }
}
New-Item -ItemType Directory -Path $targetRoot, $tempRoot, $publish -Force | Out-Null
$cargo = Get-Command cargo.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if (!$cargo) { $cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe' }
if (!(Test-Path -LiteralPath $cargo -PathType Leaf)) { throw 'Rust and Cargo are required to build the latest source.' }
$target = if ($Runtime -eq 'win-arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
# 入力集合とCargo設定の存在・hashをビルド前後で照合する。
$before = Get-PrunletRustInputSnapshot $repoRoot
$environmentBefore = @(Get-PrunletCargoEnvironmentInputs $repoRoot)
$toolchain = Get-PrunletRustToolchain $repoRoot
$manifestText = [IO.File]::ReadAllText((Join-Path $repoRoot 'Cargo.toml'))
$versionMatches = [regex]::Matches($manifestText, '(?ms)^\[package\]\s*\r?\n(?:(?!\[)[^\r\n]*\r?\n)*?version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"')
if ($versionMatches.Count -ne 1) { throw 'Cargo package version is missing or unsupported.' }
$version = $versionMatches[0].Groups[1].Value
$commit = $env:PRUNLET_SOURCE_COMMIT
if (!$commit -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $gitCommit = & git -C $repoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { $commit = [string]$gitCommit }
}
if ($commit -cnotmatch '^[0-9a-fA-F]{40}$') { $commit = 'development' }
$probeArtifact = $null
# Cargo と子プロセスの一時出力をビルド専用の外部領域へ隔離する。
$oldTarget = $env:CARGO_TARGET_DIR; $oldTemp = $env:TEMP; $oldTmp = $env:TMP
try {
    $env:CARGO_TARGET_DIR = $targetRoot; $env:TEMP = $tempRoot; $env:TMP = $tempRoot
    Push-Location -LiteralPath $repoRoot
    try {
        & $cargo build --locked --release --target $target --bin prunlet --bin prunlet-maintenance
        if ($LASTEXITCODE -ne 0) { throw "Publish failed: $LASTEXITCODE" }
        if ($IncludeVerificationProbe) {
            # 検証だけが使う独立crateであり、製品配布ZIPには含めない。
            & $cargo build --locked --release --target $target -p prunlet-fixtures -p prunlet-support
            if ($LASTEXITCODE -ne 0) { throw "Verification fixture build failed: $LASTEXITCODE" }
            # CargoのJSONからlibtest実行ファイルだけを特定し、製品入口へテスト機能を入れない。
            $messages = @(& $cargo test --locked --release --lib --no-run --target $target --message-format=json)
            if ($LASTEXITCODE -ne 0) { throw "Verification probe build failed: $LASTEXITCODE" }
            $artifacts = @($messages | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.reason -eq 'compiler-artifact' -and $_.target.name -eq 'prunlet' -and $_.profile.test -and $_.executable })
            if ($artifacts.Count -ne 1) { throw 'Expected exactly one libtest executable.' }
            $probeArtifact = [IO.Path]::GetFullPath([string]$artifacts[0].executable)
            $releaseRoot = [IO.Path]::GetFullPath((Join-Path $targetRoot "$target\release"))
            if (!$probeArtifact.StartsWith($releaseRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Verification probe is outside the Cargo release directory.' }
        }
    } finally { Pop-Location }
} finally { $env:CARGO_TARGET_DIR = $oldTarget; $env:TEMP = $oldTemp; $env:TMP = $oldTmp }
foreach ($name in @('prunlet.exe', 'prunlet-maintenance.exe')) {
    $artifact = Join-Path $targetRoot "$target\release\$name"
    $artifactHash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $artifact -Destination (Join-Path $publish $name)
    if ((Get-FileHash -LiteralPath (Join-Path $publish $name) -Algorithm SHA256).Hash -cne $artifactHash -or (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash -cne $artifactHash) { throw "Published product differs from the Cargo artifact: $name" }
}
$exe = Join-Path $publish 'prunlet.exe'
$maintenanceExe = Join-Path $publish 'prunlet-maintenance.exe'
$hookExe = Join-Path $publish 'prunlet-hook.exe'
$signing = $null
if ($Sign) {
    # hookの複製より前に署名する。署名ごとにタイムスタンプが変わるため、hookを別に
    # 署名するとCLIとhookのhashが一致しなくなる（更新ZIPは同一hashを要求する）。
    $unsigned = [ordered]@{}
    foreach ($product in @($exe, $maintenanceExe)) { $unsigned[[IO.Path]::GetFileName($product)] = (Get-FileHash -LiteralPath $product -Algorithm SHA256).Hash.ToLowerInvariant() }
    $signing = Invoke-PrunletAuthenticodeSign @($exe, $maintenanceExe)
    $signing['unsignedSha256'] = $unsigned
}
# hook は CLI と同一実体の複製で、入口名から動作を限定する。
Copy-Item -LiteralPath $exe -Destination $hookExe
$probe = $null
$verificationTools = $null
if ($IncludeVerificationProbe) {
    $probePath = Join-Path $publish 'prunlet-verification.exe'
    Copy-Item -LiteralPath $probeArtifact -Destination $probePath
    $probe = [ordered]@{ relativePath = 'publish/prunlet-verification.exe'; sha256 = (Get-FileHash -LiteralPath $probePath -Algorithm SHA256).Hash.ToLowerInvariant() }
    if ($probe.sha256 -cne (Get-FileHash -LiteralPath $probeArtifact -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Verification probe differs from the Cargo artifact.' }
    $verificationTools = [ordered]@{}
    foreach ($name in @('prunlet_fixtures.dll', 'prunlet-support.exe')) {
        $artifact = Join-Path $targetRoot "$target\release\$name"
        $destination = Join-Path $publish $name
        $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        Copy-Item -LiteralPath $artifact -Destination $destination
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash -or (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash) { throw "Verification artifact differs from Cargo output: $name" }
        $verificationTools[$name] = [ordered]@{ relativePath = "publish/$name"; sha256 = $hash }
    }
}
$after = Get-PrunletRustInputSnapshot $repoRoot
$environmentAfter = @(Get-PrunletCargoEnvironmentInputs $repoRoot)
if ($before.fingerprint -cne $after.fingerprint -or (ConvertTo-Json -InputObject $environmentBefore -Depth 5 -Compress) -cne (ConvertTo-Json -InputObject $environmentAfter -Depth 5 -Compress)) { throw 'Rust source or Cargo environment configuration changed during build.' }
$products = [ordered]@{}
foreach ($product in @($exe, $maintenanceExe, $hookExe)) { $products[[IO.Path]::GetFileName($product)] = (Get-FileHash -LiteralPath $product -Algorithm SHA256).Hash.ToLowerInvariant() }
if ($Sign) {
    # 複製後のhookも署名済みCLIと同一で、署名が有効なことを確認する。
    if ($products['prunlet-hook.exe'] -cne $products['prunlet.exe']) { throw 'Signed hook differs from the signed CLI.' }
    $null = Assert-PrunletAuthenticodeSigned $hookExe
}
$record = [ordered]@{
    schema = 1; sourceCommit = $commit; runtime = $Runtime; version = $version
    sourceFingerprint = $before.fingerprint; sourceFingerprintAlgorithm = 'sha256-relative-path-tab-content-sha256-v1'; sources = $before.sources
    build = [ordered]@{ toolchain = $toolchain; target = $target; targetDirectory = $targetRoot; profile = 'release'; sourceCommit = $commit; cargoEnvironmentInputs = $environmentBefore }
    product = [ordered]@{ relativePath = 'publish/prunlet.exe'; sha256 = $products['prunlet.exe'] }; products = $products; probe = $probe; verificationTools = $verificationTools
}
# 署名時だけ、署名者と署名前のhashを記録する。productsは署名後の配布物のhash。
if ($signing) { $record['signing'] = $signing }
[IO.File]::WriteAllText($manifestPath, ($record | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
[ordered]@{ executable = $exe; maintenanceExecutable = $maintenanceExe; hookExecutable = $hookExe; runtime = $Runtime; sha256 = $products['prunlet.exe'].ToUpperInvariant(); maintenanceSha256 = $products['prunlet-maintenance.exe'].ToUpperInvariant(); hookSha256 = $products['prunlet-hook.exe'].ToUpperInvariant(); bytes = (Get-Item -LiteralPath $exe).Length; manifestPath = $manifestPath } | ConvertTo-Json
