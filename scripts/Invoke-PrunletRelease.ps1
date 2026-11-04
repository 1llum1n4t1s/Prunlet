#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string[]]$NativeArguments
)
$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'The Windows release engine requires Windows.' }
# 互換入口で共用するSDK起動bridge。JSON・ZIP・署名・HTTP・来歴はRustが処理する。
foreach ($value in @($SourceRoot, $OutputDirectory)) {
    if (![IO.Path]::IsPathFullyQualified($value) -or $value -notmatch '^[A-Za-z]:\\' -or $value.Substring(2).Contains(':')) { throw 'Release paths must be absolute local drive paths without alternate streams.' }
}
$source = [IO.Path]::GetFullPath($SourceRoot)
$output = [IO.Path]::GetFullPath($OutputDirectory)
if ($output.Equals($source, [StringComparison]::OrdinalIgnoreCase) -or $output.StartsWith($source.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'OutputDirectory must be outside source.' }
foreach ($deny in @($env:CODEX_HOME, (Join-Path $env:USERPROFILE '.codex'))) {
    if ($deny -and ($output.Equals($deny.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or $output.StartsWith($deny.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))) { throw 'OutputDirectory must be outside Codex home.' }
}
$bootstrap = Join-Path $output 'release-engine'
$temp = Join-Path $output 'temp'
foreach ($path in @($source, $output, $bootstrap, $temp)) {
    for ($ancestor = $path; $ancestor; $ancestor = Split-Path $ancestor -Parent) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'SDK paths must use plain directories.' }
        }
    }
}
$toolchainPath = Join-Path $source 'rust-toolchain.toml'
$toolchainItem = Get-Item -LiteralPath $toolchainPath -Force
if ($toolchainItem.PSIsContainer -or ($toolchainItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The toolchain file must be plain.' }
$channel = [regex]::Match([IO.File]::ReadAllText($toolchainPath), '(?m)^channel\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"\s*$').Groups[1].Value
if (!$channel) { throw 'An exact Rust toolchain is required.' }
New-Item -ItemType Directory -Path $bootstrap, $temp -Force | Out-Null
$cargoCommand = Get-Command cargo -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$cargo = if ($cargoCommand) { $cargoCommand.Source } else { Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe' }
$names = @('CARGO_TARGET_DIR', 'TEMP', 'TMP', 'RUSTUP_TOOLCHAIN', 'CARGO_ENCODED_RUSTFLAGS')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $env:CARGO_TARGET_DIR = $bootstrap
    $env:TEMP = $temp; $env:TMP = $temp
    $env:RUSTUP_TOOLCHAIN = $channel
    $env:CARGO_ENCODED_RUSTFLAGS = '-C' + [char]31 + 'target-feature=+crt-static'
    & $cargo build --manifest-path (Join-Path $source 'Cargo.toml') --locked --release --bin prunlet-release
    if ($LASTEXITCODE -ne 0) { throw 'Release engine bootstrap failed.' }
    & (Join-Path $bootstrap 'release\prunlet-release.exe') @NativeArguments
    if ($LASTEXITCODE -ne 0) { throw 'Rust release command failed.' }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
}
