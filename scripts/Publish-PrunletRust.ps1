#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [string]$TargetDirectory = $env:PRUNLET_CARGO_TARGET_DIRECTORY,
    [ValidatePattern('^[0-9a-fA-F]{40}$')][string]$SourceCommit,
    [switch]$IncludeVerificationProbe
)
$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'Use Publish-PrunletMac.sh on macOS.' }
$repoRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$forbidden = @($repoRoot, (Join-Path $env:USERPROFILE '.codex'))
if ($env:CODEX_HOME) { $forbidden += [IO.Path]::GetFullPath($env:CODEX_HOME) }
. (Join-Path $PSScriptRoot 'RustBuildInputs.Common.ps1')
function Get-SourceFingerprint {
    $paths = @(Get-PrunletRustInputNames $repoRoot)
    $sources = @($paths | ForEach-Object { $item = Get-Item -LiteralPath (Join-Path $repoRoot $_) -Force; if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Build source cannot be a link.' }; [ordered]@{ path = $_; sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } })
    $text = [Text.StringBuilder]::new()
    foreach ($entry in $sources) { [void]$text.Append($entry.path).Append([char]9).Append($entry.sha256).Append([char]10) }
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($text.ToString()))).ToLowerInvariant()
    return @{ fingerprint = $digest; sources = $sources }
}
function Assert-BuildPath([string]$Value) {
    if (![IO.Path]::IsPathFullyQualified($Value)) { throw 'Build paths must be absolute.' }
    $full = [IO.Path]::GetFullPath($Value)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) { throw 'Build paths must use a local drive without alternate streams.' }
    foreach ($deny in $forbidden) {
        if ($full.Equals($deny, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($deny.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Build output must be outside the repository and Codex home.' }
    }
    $ancestor = $full
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Build paths cannot traverse links.' }
            if (!$item.PSIsContainer) { throw 'Build paths must be directories.' }
        }
        $ancestor = Split-Path $ancestor -Parent
    }
    return $full
}
$outputRoot = Assert-BuildPath $OutputDirectory
if (!$TargetDirectory) { $TargetDirectory = Join-Path $outputRoot 'cargo-target' }
$TargetDirectory = Assert-BuildPath $TargetDirectory
$publish = Join-Path $outputRoot 'publish'
$temp = Assert-BuildPath (Join-Path $outputRoot 'temp')
$publish = Assert-BuildPath $publish
foreach ($name in @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe')) {
    if (Test-Path -LiteralPath (Join-Path $publish $name)) { throw "Publish output is occupied: $name. Choose a fresh OutputDirectory." }
}
New-Item -ItemType Directory -Path $publish, $TargetDirectory, $temp -Force | Out-Null
$cargoCommand = Get-Command cargo -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$cargo = if ($cargoCommand) { $cargoCommand.Source } else { Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe' }
if (!(Test-Path -LiteralPath $cargo -PathType Leaf)) { throw 'The Rust toolchain specified in rust-toolchain.toml and the MSVC C++ build tools including Windows SDK are required.' }
$target = if ($Runtime -eq 'win-arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
$names = @('CARGO_TARGET_DIR', 'CARGO_ENCODED_RUSTFLAGS', 'RUSTUP_TOOLCHAIN', 'TEMP', 'TMP', 'PRUNLET_SOURCE_COMMIT')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$buildKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($TargetDirectory.ToLowerInvariant())))
$buildMutex = [Threading.Mutex]::new($false, ('Global\Prunlet-RustPublish-' + $buildKey))
$ownsBuildMutex = $false
try {
    # Cargoのlockはcargo終了時に解放されるため、copy/hash/manifest確定まで同じ成果物を固定する。
    try { $ownsBuildMutex = $buildMutex.WaitOne([TimeSpan]::FromMinutes(10)) } catch [Threading.AbandonedMutexException] { $ownsBuildMutex = $true }
    if (!$ownsBuildMutex) { throw 'Another publisher still owns this Cargo target directory.' }
    $sourceBefore = Get-SourceFingerprint
    $toolchain = Get-PrunletRustToolchain $repoRoot
    $cargoEnvironmentBefore = @(Get-PrunletCargoEnvironmentInputs $repoRoot)
    $cargoEnvironmentJson = $cargoEnvironmentBefore | ConvertTo-Json -Depth 4 -Compress
    $env:RUSTUP_TOOLCHAIN = $toolchain
    $env:CARGO_TARGET_DIR = $TargetDirectory
    $env:CARGO_ENCODED_RUSTFLAGS = '-C' + [char]0x1f + 'target-feature=+crt-static'
    $env:TEMP = $temp; $env:TMP = $temp
    if ($SourceCommit) { $env:PRUNLET_SOURCE_COMMIT = $SourceCommit.ToLowerInvariant() }
    Push-Location $repoRoot
    try {
        $cargoVersion = & $cargo --version
        if ($LASTEXITCODE -ne 0 -or $cargoVersion -cnotmatch ('^cargo ' + [regex]::Escape($toolchain) + '(?:\s|$)')) { throw "Rust toolchain $toolchain is required." }
        & $cargo build --manifest-path (Join-Path $repoRoot 'Cargo.toml') --locked --release --target $target --bin prunlet --bin prunlet-maintenance
        if ($LASTEXITCODE -ne 0) { throw "Rust publish failed: $LASTEXITCODE. Verify the Rust target and MSVC $Runtime build tools are installed." }
    } finally { Pop-Location }
    $expectedVersion = (Get-Content -LiteralPath (Join-Path $repoRoot 'Cargo.toml') -Raw | Select-String -Pattern '(?m)^version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"').Matches.Groups[1].Value
    foreach ($name in @('prunlet.exe', 'prunlet-maintenance.exe')) {
        $product = Join-Path $TargetDirectory "$target\release\$name"
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($product).ProductVersion
        if (($version -split '\+')[0] -cne $expectedVersion) { throw "PE ProductVersion differs: $name $version" }
        if ($SourceCommit -and $version -cne ($expectedVersion + '+' + $SourceCommit.ToLowerInvariant())) { throw "PE source commit differs: $name $version" }
        Copy-Item -LiteralPath $product -Destination (Join-Path $publish $name)
    }
    # hookは同じCLI実体を名前で限定する。更新用manifestの同一hash契約を維持する。
    Copy-Item -LiteralPath (Join-Path $publish 'prunlet.exe') -Destination (Join-Path $publish 'prunlet-hook.exe')
    if ((Get-SourceFingerprint).fingerprint -cne $sourceBefore.fingerprint) { throw 'Source changed while products were built; outputs were retained and are not verified.' }
    if (((Get-PrunletCargoEnvironmentInputs $repoRoot) | ConvertTo-Json -Depth 4 -Compress) -cne $cargoEnvironmentJson) { throw 'Cargo environment configuration changed while products were built.' }
    if ($IncludeVerificationProbe) {
        $verification = Assert-BuildPath (Join-Path $outputRoot 'verification')
        New-Item -ItemType Directory -Path $verification -Force | Out-Null
        $probe = Join-Path $verification 'prunlet-libtest.exe'
        $manifest = Join-Path $outputRoot 'build-manifest.json'
        if ((Test-Path -LiteralPath $probe) -or (Test-Path -LiteralPath $manifest)) { throw 'Verification outputs already exist; use a fresh OutputDirectory.' }
        Push-Location $repoRoot
        try {
            $messages = @(& $cargo test --manifest-path (Join-Path $repoRoot 'Cargo.toml') --lib --no-run --locked --release --target $target --message-format=json-render-diagnostics)
            if ($LASTEXITCODE -ne 0) { throw "Rust verification probe build failed: $LASTEXITCODE" }
        } finally { Pop-Location }
        $artifacts = @($messages | ForEach-Object { $message = $_ | ConvertFrom-Json; if ($message.reason -eq 'compiler-artifact' -and $message.profile.test -and $message.executable -and $message.target.name -eq 'prunlet') { $message.executable } })
        if ($artifacts.Count -ne 1) { throw 'Expected exactly one libtest verification executable.' }
        Copy-Item -LiteralPath $artifacts[0] -Destination $probe
        if ($Runtime -eq 'win-x64' -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -eq 'Arm64') {
            $listing = @(& $probe --list)
            if ($LASTEXITCODE -ne 0) { throw 'Verification probe listing failed.' }
            foreach ($name in @('verification::checkpoint', 'verification::native_contract', 'verification::files_contract')) { if (!($listing | Where-Object { $_.StartsWith($name, [StringComparison]::Ordinal) })) { throw "Verification probe is missing: $name" } }
        }
        if ((Get-SourceFingerprint).fingerprint -cne $sourceBefore.fingerprint) { throw 'Source changed while probe was built; outputs were retained and are not verified.' }
        if (((Get-PrunletCargoEnvironmentInputs $repoRoot) | ConvertTo-Json -Depth 4 -Compress) -cne $cargoEnvironmentJson) { throw 'Cargo environment configuration changed while probe was built.' }
        $commit = if ($SourceCommit) { $SourceCommit.ToLowerInvariant() } else { ([Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $publish 'prunlet.exe')).ProductVersion -split '\+')[-1] }
        if ($commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Build manifest requires an identified source commit.' }
        $profileOverrides = [ordered]@{}; Get-ChildItem Env:CARGO_PROFILE_RELEASE_* | Sort-Object Name | ForEach-Object { $profileOverrides[$_.Name] = $_.Value }
        $record = [ordered]@{ build = [ordered]@{ toolchain = $toolchain; cargoVersion = $cargoVersion; target = $target; profile = 'release'; profileOverrides = $profileOverrides; rustflags = @('-C', 'target-feature=+crt-static'); sourceCommit = $commit; cargoEnvironmentInputs = $cargoEnvironmentBefore }; schema = 1; sourceCommit = $commit; runtime = $Runtime; sourceFingerprint = $sourceBefore.fingerprint; sourceFingerprintAlgorithm = 'sha256-relative-path-tab-content-sha256-v1'; sources = $sourceBefore.sources; product = [ordered]@{ relativePath = 'publish/prunlet.exe'; sha256 = (Get-FileHash -LiteralPath (Join-Path $publish 'prunlet.exe') -Algorithm SHA256).Hash.ToLowerInvariant() }; probe = [ordered]@{ relativePath = 'verification/prunlet-libtest.exe'; sha256 = (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash.ToLowerInvariant() } }
        [IO.File]::WriteAllText($manifest, ($record | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    if ($ownsBuildMutex) { $buildMutex.ReleaseMutex() }
    $buildMutex.Dispose()
}
$exe = Join-Path $publish 'prunlet.exe'; $maintenance = Join-Path $publish 'prunlet-maintenance.exe'; $hook = Join-Path $publish 'prunlet-hook.exe'
[ordered]@{ executable = $exe; maintenanceExecutable = $maintenance; hookExecutable = $hook; runtime = $Runtime; sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash; maintenanceSha256 = (Get-FileHash -LiteralPath $maintenance -Algorithm SHA256).Hash; hookSha256 = (Get-FileHash -LiteralPath $hook -Algorithm SHA256).Hash; bytes = (Get-Item -LiteralPath $exe).Length } | ConvertTo-Json
