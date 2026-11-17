[CmdletBinding()]
param(
    # Standard: 通常の cargo test --locked（lib・bin・結合テスト）。配信前と main/PR の検証で使う。
    # UpdateCfg: 起動時更新の検証用 cfg（prunlet_windows_update_tests）付きの debug ビルドで lib のテストだけを動かす。
    #            この cfg は all(windows, debug_assertions, prunlet_windows_update_tests) の入口とテスト鍵を有効にするため、
    #            製品ビルド・公開には使わない（AGENTS.md の起動時更新の項）。
    [ValidateSet('Standard', 'UpdateCfg')][string]$Mode = 'Standard',
    # Cargo の target と native_* テストの fixture を置く外部の作業領域。未指定なら RUNNER_TEMP、無ければ既定の一時フォルダー。
    [string]$WorkDirectory
)
# Windows の Rust テストをリポジトリ外の出力先で実行する（AGENTS.md「ビルドと検証」の Windows 手順）。
# - Cargo の出力先はリポジトリの外へ隔離する。TEMP/TMP は上書きしない（ランナー・開発機の既定の一時フォルダーを使う）。
# - テストが扱うのは、自分で作った一意の fixture（ゴミ箱への移動を含む）と、プロセス専用のレジストリ
#   ハイブ・自分の揮発キーだけ。ランナーの既存ファイル・ゴミ箱全体・永続的なレジストリは対象にしない。
# - 失敗は終了コードで返す。リトライ・skip・continue-on-error で隠さない。
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$base = if ($WorkDirectory) { $WorkDirectory } elseif ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
if (-not [IO.Path]::IsPathFullyQualified($base)) { throw 'WorkDirectory must be absolute.' }
$base = [IO.Path]::GetFullPath($base)
if ($base.Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase) -or $base.StartsWith($repoRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'WorkDirectory must be outside the repository.'
}
$work = Join-Path $base ('prunlet-tests-' + $Mode.ToLowerInvariant() + '-' + [guid]::NewGuid().ToString('N'))
$targetRoot = Join-Path $work 'cargo-target'
# native_* テストはゴミ箱が有効なボリューム上の fixture を要求する。TEMP が即時削除設定のボリュームだと
# 明示的に失敗するため、呼び出し側が指定していなければ作業領域の下を使う（テストはその下に一意の fixture を作る）。
$recycleRoot = Join-Path $work 'native-recycle'
New-Item -ItemType Directory -Path $targetRoot, $recycleRoot | Out-Null

$cargo = Get-Command cargo.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if (!$cargo) { $cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe' }
if (!(Test-Path -LiteralPath $cargo -PathType Leaf)) { throw 'Rust and Cargo are required.' }

$oldTarget = $env:CARGO_TARGET_DIR; $oldRecycle = $env:PRUNLET_NATIVE_RECYCLE_ROOT; $oldFlags = $env:RUSTFLAGS
try {
    $env:CARGO_TARGET_DIR = $targetRoot
    if (!$env:PRUNLET_NATIVE_RECYCLE_ROOT) { $env:PRUNLET_NATIVE_RECYCLE_ROOT = $recycleRoot }
    Push-Location -LiteralPath $repoRoot
    try {
        if ($Mode -eq 'UpdateCfg') {
            $env:RUSTFLAGS = '--cfg prunlet_windows_update_tests'
            & $cargo test --locked --lib
        } else {
            & $cargo test --locked
        }
        if ($LASTEXITCODE -ne 0) { throw "cargo test ($Mode) failed: $LASTEXITCODE" }
    } finally { Pop-Location }
} finally {
    $env:CARGO_TARGET_DIR = $oldTarget; $env:PRUNLET_NATIVE_RECYCLE_ROOT = $oldRecycle; $env:RUSTFLAGS = $oldFlags
}
# 作業領域（巨大な target を含む）は、ランナーなら使い捨て、手元なら呼び出し側が WorkDirectory ごと消す。
Write-Host "Tests passed ($Mode). Work directory: $work"
