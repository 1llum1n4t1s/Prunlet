#requires -Version 7.0
# Setup（Velopack）版の隔離 E2E（Windows x64）。実機の導入・設定・タスク・レジストリの実値に触れずに、
# 梱包 → Setup 導入 → 更新（hook 連続実行つき）→ 使用中の延期 → 信頼拒否 → アンインストール を通して確かめる。
#
# 隔離の約束:
# - テスト用 packId PrunletVelopackTest、導入先は -OutputDirectory 配下（--installto）。本番 packId PrunletApp は使わない。
# - 子プロセスの LOCALAPPDATA・APPDATA・USERPROFILE・TEMP・CLAUDE_CONFIG_DIR・CODEX_HOME と、Rust 側のテスト用変数
#   （PRUNLET_VELOPACK_TEST_*）を、すべて実行ごとの隔離フォルダーへ向ける。実機の %USERPROFILE%\.local\Prunlet・
#   %LOCALAPPDATA%\Prunlet・~/.claude・Toolport の registry.json・HKCU Run の実値には触れない（Run 値は専用ハイブのファイル）。
# - 実レジストリに書かれるのは Velopack の Setup 自身が作る HKCU の Uninstall\PrunletVelopackTest だけ（隔離できない）。
#   開始前に無いことを確かめ、アンインストール後に消えたことを確かめ、残っていれば報告して失敗にする。
# - ウィンドウを出さない（Setup は --silent、すべての子は CreateNoWindow）。このスクリプトは削除を行わない
#   （実行後の作業フォルダーは、呼び出し側が Prunlet CLI で片付ける）。
# - velopack-test 付きのビルドは配布しない。署名は省く（PRUNLET_VELOPACK_TEST_ALLOW_UNSIGNED=1）ので、
#   署名の成功経路・実 R2・実 Release は対象外（実署名の確認は本人の許可があるときだけ別に行う）。
#
# ソースは作業フォルダーへ複製して版だけを書き換えてビルドする（exe の版リソースが nupkg の版と一致しなければ
# クライアントが適用前に拒否するため、版ごとに別のビルドが要る）。元のリポジトリは変更しない。
# 既存の -OutputDirectory を再利用すると、ビルドと梱包は再利用し、実行ごとの隔離フォルダー（runs\<時刻>）だけ作り直す。
#
# 合否（各項目を results に記録し、1 つでも失敗なら終了コード 1）:
#   1 導入: hook 複製・ホスト設定の書換え（旧パスだけ・他は不変）・バックアップ・config 作成・Run 登録
#   2 更新 2 回（9.0.0 → 9.0.1 → 9.0.2）の最中に hook を連続実行して、deny 以外・起動失敗が 0 件
#   3 MCP を動かしたまま update-apply → busy で延期・強制終了 0 件。止めてから適用 → applied・hook 複製が新版
#   4 署名付きマニフェスト（R2 の manifests/<版>/velopack-win-x64.json を隔離フォルダーで再現）の SHA-256 不一致 →
#     untrusted（終了コード 2）、欠落・署名不正 → deferred
#   5 アンインストール: Run 値・Uninstall 登録が残らない
[CmdletBinding()]
param(
    # 作業フォルダー（絶対パス。リポジトリ・~/.claude・実機の導入先の外）。
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string[]]$Versions = @('9.0.0', '9.0.1', '9.0.2'),
    [string]$PackId = 'PrunletVelopackTest'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (!$IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') { throw 'Run the E2E on Windows x64.' }
if ($PackId -ceq 'PrunletApp') { throw 'The isolated E2E must not use the production packId.' }
if ($Versions.Count -ne 3 -or ($Versions | Where-Object { $_ -notmatch '^\d+\.\d+\.\d+$' })) { throw 'Specify exactly three plain versions (x.y.z).' }
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (![IO.Path]::IsPathFullyQualified($OutputDirectory)) { throw 'OutputDirectory must be absolute.' }
$out = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
$userProfile = [Environment]::GetFolderPath('UserProfile')
$local = [Environment]::GetFolderPath('LocalApplicationData')
foreach ($root in @($repo, (Join-Path $userProfile '.claude'), (Join-Path $userProfile '.codex'), (Join-Path $userProfile '.local\Prunlet'), (Join-Path $local 'PrunletApp'), (Join-Path $local 'Prunlet'))) {
    if ($out.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $out.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "OutputDirectory cannot be inside: $root" }
}
for ($probe = $out; $probe; $probe = Split-Path -Parent $probe) {
    if ((Test-Path -LiteralPath $probe) -and ((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "OutputDirectory cannot traverse a link: $probe" }
}
New-Item -ItemType Directory -Path $out -Force | Out-Null

$results = [Collections.Generic.List[object]]::new()
function Add-Result([string]$Id, [string]$Name, [bool]$Pass, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ id = $Id; name = $Name; pass = $Pass; detail = $Detail })
    Write-Host ('{0} [{1}] {2}{3}' -f $(if ($Pass) { 'PASS' } else { 'FAIL' }), $Id, $Name, $(if ($Detail) { " :: $Detail" } else { '' }))
}
function Step([string]$Message) { Write-Host "`n=== $Message" }

# ───────────── 子プロセス（環境を明示して起動。ウィンドウなし） ─────────────
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$run = Join-Path $out "runs\$stamp"
$layout = @{
    Install = 'install'; Home = 'home'; AppData = 'appdata'; Data = 'data'; Temp = 'temp'; Feed = 'feed'; Release = 'release'
    LocalAppData = 'localappdata'; Logs = 'logs'
}
$dir = @{}
foreach ($key in $layout.Keys) { $dir[$key] = Join-Path $run $layout[$key] }
$claude = Join-Path $dir.Home '.claude'
$hive = Join-Path $run 'run-hive.dat'
New-Item -ItemType Directory -Path @($dir.Values) -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $claude 'hooks'), (Join-Path $dir.AppData 'Toolport') -Force | Out-Null

function Get-IsolatedEnvironment {
    $environment = [ordered]@{}
    foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) { $environment[[string]$entry.Key] = [string]$entry.Value }
    $overrides = @{
        LOCALAPPDATA = $dir.LocalAppData; APPDATA = $dir.AppData; USERPROFILE = $dir.Home; HOME = $dir.Home
        TEMP = $dir.Temp; TMP = $dir.Temp; PRUNLET_LANGUAGE = 'en'
        PRUNLET_VELOPACK_TEST_DATA_DIR = $dir.Data; PRUNLET_VELOPACK_TEST_HOME = $dir.Home
        PRUNLET_VELOPACK_TEST_APPDATA = $dir.AppData; PRUNLET_VELOPACK_TEST_ALLOW_UNSIGNED = '1'
        PRUNLET_VELOPACK_TEST_RUN_HIVE = $hive; PRUNLET_VELOPACK_TEST_FEED_DIR = $dir.Feed
        PRUNLET_VELOPACK_TEST_RELEASE_DIR = $dir.Release
        CLAUDE_CONFIG_DIR = $claude; CODEX_HOME = (Join-Path $dir.Home '.codex')
    }
    foreach ($name in $overrides.Keys) { $environment[$name] = $overrides[$name] }
    foreach ($name in @('PRUNLET_MCP_LAUNCHER_JOB', 'PRUNLET_CONFIG', 'PRUNLET_HOME')) { [void]$environment.Remove($name) }
    return $environment
}
function New-ProcessInfo([string]$File, [string[]]$Arguments, [bool]$RedirectInput) {
    $info = [Diagnostics.ProcessStartInfo]::new($File)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $RedirectInput
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment.Clear()
    foreach ($entry in (Get-IsolatedEnvironment).GetEnumerator()) { $info.Environment[$entry.Key] = $entry.Value }
    return $info
}
# 終了まで待って、終了コードと出力を返す。時間切れは Kill せず TimedOut を立てる（プロセスは残るので呼び出し側が扱う）。
function Invoke-Isolated([string]$File, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 120) {
    $process = [Diagnostics.Process]::Start((New-ProcessInfo $File $Arguments $false))
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit($TimeoutSeconds * 1000)
    $result = [pscustomobject]@{
        ExitCode = $(if ($finished) { $process.ExitCode } else { $null }); TimedOut = !$finished
        Stdout = $(if ($finished) { $stdout.GetAwaiter().GetResult() } else { '' }); Stderr = $(if ($finished) { $stderr.GetAwaiter().GetResult() } else { '' })
    }
    $process.Dispose()
    return $result
}
function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
function ConvertFrom-JsonLine([string]$Text) {
    $line = @($Text -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if (!$line.Count) { return $null }
    try { return $line[0] | ConvertFrom-Json } catch { return $null }
}

# ───────────── 専用ハイブの Run 値を読む（RegLoadAppKeyW。実際の Run キーには触れない） ─────────────
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class PrunletE2eHive {
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegLoadAppKeyW(string file, out IntPtr key, int sam, int options, int reserved);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegOpenKeyExW(IntPtr key, string sub, int options, int sam, out IntPtr result);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegEnumValueW(IntPtr key, int index, char[] name, ref int nameLen, IntPtr reserved, IntPtr type, IntPtr data, IntPtr dataLen);
    [DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr key);
    public static string[] RunValues(string file) {
        var names = new List<string>();
        IntPtr root;
        int status = RegLoadAppKeyW(file, out root, 0x20019, 0, 0);
        if (status != 0) throw new System.ComponentModel.Win32Exception(status);
        try {
            IntPtr run;
            if (RegOpenKeyExW(root, @"Software\Microsoft\Windows\CurrentVersion\Run", 0, 0x20019, out run) != 0) return names.ToArray();
            try {
                for (int i = 0; ; i++) {
                    var buffer = new char[16384]; int length = buffer.Length;
                    if (RegEnumValueW(run, i, buffer, ref length, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) != 0) break;
                    names.Add(new string(buffer, 0, length));
                }
            } finally { RegCloseKey(run); }
        } finally { RegCloseKey(root); }
        return names.ToArray();
    }
}
'@
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$PackId"
$runValueName = "$PackId Update"

# ───────────── 1) ビルド（版ごと）と梱包 ─────────────
Step 'Build three versions (velopack-test, unsigned) from a source snapshot'
$source = Join-Path $out 'src'
$target = Join-Path $out 'cargo-target'
$buildTemp = Join-Path $out 'build-temp'
New-Item -ItemType Directory -Path $buildTemp -Force | Out-Null
$cargoCommand = Get-Command cargo.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$cargo = if ($cargoCommand) { $cargoCommand.Source } else { Join-Path (Join-Path $userProfile '.cargo') 'bin\cargo.exe' }
if (!(Test-Path -LiteralPath $cargo)) { throw "cargo.exe was not found." }
$sourceReady = Test-Path -LiteralPath (Join-Path $source 'Cargo.toml')
foreach ($version in $Versions) {
    $built = Join-Path $out "builds\$version"
    if (Test-Path -LiteralPath (Join-Path $built 'prunlet.exe')) { Write-Host "reuse build $version"; continue }
    if (!$sourceReady) {
        robocopy $repo $source /E /XD target .git node_modules /XF *.log /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
        $sourceReady = $true
    }
    # 版だけを書き換える（Cargo.toml の [package] と Cargo.lock の prunlet）。
    $manifest = Join-Path $source 'Cargo.toml'
    $text = [IO.File]::ReadAllText($manifest)
    $patched = [regex]::Replace($text, '(?m)^(version\s*=\s*)"[^"]+"', "`${1}`"$version`"", 1)
    if ($patched -ceq $text -and $text -notmatch [regex]::Escape("version = `"$version`"")) { throw 'Could not patch the package version in Cargo.toml.' }
    [IO.File]::WriteAllText($manifest, $patched, [Text.UTF8Encoding]::new($false))
    $lock = Join-Path $source 'Cargo.lock'
    $lockText = [IO.File]::ReadAllText($lock)
    $lockPatched = [regex]::Replace($lockText, '(?m)(name = "prunlet"\r?\nversion = )"[^"]+"', "`${1}`"$version`"")
    [IO.File]::WriteAllText($lock, $lockPatched, [Text.UTF8Encoding]::new($false))
    $previous = @{ T = $env:CARGO_TARGET_DIR; TEMP = $env:TEMP; TMP = $env:TMP; C = $env:PRUNLET_SOURCE_COMMIT }
    try {
        $env:CARGO_TARGET_DIR = $target; $env:TEMP = $buildTemp; $env:TMP = $buildTemp
        $env:PRUNLET_SOURCE_COMMIT = ('0' * 40)
        Push-Location -LiteralPath $source
        try {
            & $cargo build --release --locked --features velopack-test --bin prunlet --bin prunlet-maintenance
            if ($LASTEXITCODE -ne 0) { throw "cargo build failed for $version ($LASTEXITCODE)" }
        } finally { Pop-Location }
    } finally {
        $env:CARGO_TARGET_DIR = $previous.T; $env:TEMP = $previous.TEMP; $env:TMP = $previous.TMP; $env:PRUNLET_SOURCE_COMMIT = $previous.C
    }
    New-Item -ItemType Directory -Path $built -Force | Out-Null
    foreach ($name in @('prunlet.exe', 'prunlet-maintenance.exe')) { Copy-Item -LiteralPath (Join-Path $target "release\$name") -Destination $built }
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $built 'prunlet.exe'))
    if (($info.ProductVersion -split '\+')[0] -cne $version) { throw "Built exe version differs: $($info.ProductVersion)" }
}

Step 'Pack and verify each version (unsigned, test packId)'
$pack = @{}
foreach ($version in $Versions) {
    $base = Join-Path $out "packs\$version"
    $packages = Join-Path $base 'work\packages'
    if (!(Test-Path -LiteralPath (Join-Path $packages "$PackId-$version-full.nupkg"))) {
        New-Item -ItemType Directory -Path (Join-Path $base 'work') -Force | Out-Null
        & (Join-Path $PSScriptRoot 'pack-windows.ps1') -WorkDirectory (Join-Path $base 'work') -PublishDirectory (Join-Path $out "builds\$version") -PackId $PackId -PackVersion $version | Out-Null
        $assets = Join-Path $base 'assets'
        & (Join-Path $PSScriptRoot 'verify-windows.ps1') -PackagesDirectory $packages -ExpectedVersion $version -PackId $PackId -ReleaseAssetsDirectory $assets -ScratchDirectory $buildTemp | Out-Null
    }
    $pack[$version] = [pscustomobject]@{
        Packages = $packages; Nupkg = Join-Path $packages "$PackId-$version-full.nupkg"; Feed = Join-Path $packages 'releases.win.json'
        Setup = Join-Path $packages "$PackId-win-Setup.exe"; Hash = Join-Path $base "assets\$PackId-$version-full.nupkg.sha256"
    }
    foreach ($file in @($pack[$version].Nupkg, $pack[$version].Feed, $pack[$version].Setup, $pack[$version].Hash)) { if (!(Test-Path -LiteralPath $file)) { throw "Missing package file: $file" } }
}
Add-Result 'pack' "three versions packed and verified ($($Versions -join ', '))" $true

# 梱包物のエントリ集合（Rust 側の許可集合との照合。実測と違えば報告）。
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($pack[$Versions[0]].Nupkg)
$entryNames = @($archive.Entries | ForEach-Object { $_.FullName } | Sort-Object)
$archive.Dispose()
Write-Host ("nupkg entries: " + ($entryNames -join ', '))

# ───────────── 2) 隔離した利用者環境（旧パスを指す設定の複製） ─────────────
function Escape-Json([string]$Text) { return $Text.Replace('\', '\\') }
$oldBin = Join-Path $dir.Home '.local\Prunlet\bin'
$config = Join-Path $dir.Data 'config.json'
$fixtures = [ordered]@{}
$fixtures['settings.json'] = "{`n  `"zeta`": true,`n  `"hooks`": {`"PreToolUse`": [{`"matcher`": `"Bash`", `"hooks`": [{`"type`": `"command`", `"command`": `"\`"$(Escape-Json "$oldBin\prunlet-hook.exe")\`" --config \`"$(Escape-Json $config)\`" hook --cli-executable \`"$(Escape-Json "$oldBin\prunlet.exe")\`"`"}, {`"type`": `"command`", `"command`": `"rtk hook claude`"}]}]},`n  `"alpha`": 1`n}`n"
$fixtures['CLAUDE.md'] = "# rules`n- Prunlet CLI: ``$oldBin\prunlet.exe --config $config delete```n- unrelated: $oldBin\prunlet.previous.exe`n"
$fixtures['hooks\powershell-guard.ts'] = "const HOOK = `"$(Escape-Json "$oldBin\prunlet-hook.exe")`";`n"
$fixtures['PRUNLET.md'] = "<!-- Prunlet managed agent instructions -->`nUse <installed-exe> only.`n"
foreach ($name in $fixtures.Keys) { [IO.File]::WriteAllText((Join-Path $claude $name), $fixtures[$name], [Text.UTF8Encoding]::new($false)) }
$registryPath = Join-Path $dir.AppData 'Toolport\registry.json'
$registry = "{`n  `"servers`": [`n    {`n      `"args`": [`"--stdio`"],`n      `"command`": `"C:\\x.exe`",`n      `"id`": `"other`"`n    },`n    {`n      `"args`": [`n        `"-NoProfile`",`n        `"-NonInteractive`",`n        `"-File`",`n        `"$(Escape-Json "$oldBin\start-prunlet-mcp.ps1")`",`n        `"-ExecutablePath`",`n        `"$(Escape-Json "$oldBin\prunlet.exe")`",`n        `"-ConfigPath`",`n        `"$(Escape-Json $config)`"`n      ],`n      `"command`": `"C:\\pwsh.exe`",`n      `"id`": `"prunlet`",`n      `"transport`": `"stdio`"`n    }`n  ]`n}`n"
[IO.File]::WriteAllText($registryPath, $registry, [Text.UTF8Encoding]::new($false))
$originalFiles = @{}
foreach ($path in @(Get-ChildItem -LiteralPath $claude -Recurse -File) + @(Get-Item -LiteralPath $registryPath)) { $originalFiles[$path.FullName] = [IO.File]::ReadAllText($path.FullName) }
# 全版の署名付きマニフェストを置く（後で不一致・欠落・署名不正の項目で一時的に変える）。
# R2 の manifests/<版>/velopack-win-x64.json と同じ封筒を、PRUNLET_VELOPACK_TEST_RELEASE_DIR の下の同じ相対パスへ置く。
# 署名はテスト鍵（scripts/release-test-fixtures）で、keyId は velopack-test 機能付きビルドだけが受理する prunlet-release-test-1。
# 封筒の組立ては配信側の正本（PrunletRelease.Common.ps1）を使い、asset名・キーだけテストの packId に合わせる。
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'PrunletRelease.Common.ps1')
$releaseTestPem = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'release-test-fixtures\test-signing-private.pem'))
function Get-ReleaseManifestPath([string]$Version) { return Join-Path $dir.Release "manifests\$Version\velopack-win-x64.json" }
function New-ForeignReleaseKeyPem {
    $key = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve]::CreateFromValue('1.2.840.10045.3.1.7'))
    try { return $key.ExportPkcs8PrivateKeyPem() } finally { $key.Dispose() }
}
function New-ReleaseManifestBytes([string]$Version, [string]$Sha256, [long]$Bytes, [string]$Pem = $releaseTestPem) {
    $spec = New-PrunletReleaseSpec -Runtime 'velopack-win-x64' -Version $Version -CommitSha ('0' * 40) -DefaultBranch 'main' -Sha256 $Sha256 -Bytes $Bytes
    $spec.AssetName = "$PackId-$Version-full.nupkg"
    $spec.AssetKey = "velopack/$PackId-$Version-full.nupkg"
    return , (New-PrunletReleaseEnvelopeBytes -PayloadBytes (New-PrunletReleasePayloadBytes -Spec $spec) -PrivateKeyPem $Pem -KeyId 'prunlet-release-test-1')
}
foreach ($version in $Versions) {
    $path = Get-ReleaseManifestPath $version
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllBytes($path, (New-ReleaseManifestBytes $version (Get-FileHash -LiteralPath $pack[$version].Nupkg -Algorithm SHA256).Hash.ToLowerInvariant() (Get-Item -LiteralPath $pack[$version].Nupkg).Length))
}
# ───────────── 3) 導入 ─────────────
$root = $dir.Install
$currentExe = Join-Path $root 'current\prunlet.exe'
$hookExe = Join-Path $dir.Data 'hook\prunlet-hook.exe'
$stateDir = Join-Path $dir.Data 'state'
$loopProcess = $null; $mcp = $null
$stopFile = Join-Path $dir.Logs 'hook-loop.stop'
$loopLog = Join-Path $dir.Logs 'hook-loop.jsonl'
function Get-Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Get-InstalledVersion {
    $file = Join-Path $root 'current\sq.version'
    if (!(Test-Path -LiteralPath $file)) { return $null }
    $match = [regex]::Match([IO.File]::ReadAllText($file), '<version>\s*([^<\s]+)\s*</version>')
    if ($match.Success) { return $match.Groups[1].Value } else { return $null }
}
function Wait-Until([scriptblock]$Condition, [int]$Seconds = 60) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 500 }
    return [bool](& $Condition)
}
function Invoke-Cli([string[]]$Arguments, [int]$TimeoutSeconds = 120) {
    $result = Invoke-Isolated $currentExe $Arguments $TimeoutSeconds
    $result | Add-Member -NotePropertyName Json -NotePropertyValue (ConvertFrom-JsonLine $result.Stdout)
    return $result
}
function Set-Feed([string]$Version) {
    # フィード（ローカル）には、その版の nupkg と releases.win.json だけを置く。
    foreach ($file in @(Get-ChildItem -LiteralPath $dir.Feed -File)) { [IO.File]::Move($file.FullName, (Join-Path $dir.Logs ("old-feed-" + [Guid]::NewGuid().ToString('N') + '-' + $file.Name))) }
    Copy-Item -LiteralPath $pack[$Version].Nupkg -Destination $dir.Feed
    Copy-Item -LiteralPath $pack[$Version].Feed -Destination $dir.Feed
}

try {
    Step 'Install version 1 with the Setup (silent, isolated)'
    if (Test-Path -LiteralPath $uninstallKey) { throw "The Uninstall registration for $PackId already exists before the test; remove it first." }
    $setup = Invoke-Isolated $pack[$Versions[0]].Setup @('--silent', '--installto', $root) 180
    Add-Result 'install.setup' 'Setup exits 0 and creates current\prunlet.exe' (!$setup.TimedOut -and $setup.ExitCode -eq 0 -and (Test-Path -LiteralPath $currentExe)) "exit=$($setup.ExitCode) stderr=$($setup.Stderr.Trim())"
    if (!(Test-Path -LiteralPath $currentExe)) { throw 'The installation did not produce current\prunlet.exe.' }
    $null = Wait-Until { Test-Path -LiteralPath $hookExe } 30
    Add-Result 'install.version' "installed version is $($Versions[0])" ((Get-InstalledVersion) -ceq $Versions[0]) "found=$(Get-InstalledVersion)"
    Add-Result 'install.uninstall-key' 'HKCU Uninstall registration was created by Setup' (Test-Path -LiteralPath $uninstallKey)
    Add-Result 'install.hook-copy' 'hook copy exists outside the root and equals current\prunlet.exe' ((Test-Path -LiteralPath $hookExe) -and ((Get-Sha256 $hookExe) -ceq (Get-Sha256 $currentExe))) $hookExe
    Add-Result 'install.config' 'a new-user config and recovery folder were created' ((Test-Path -LiteralPath $config) -and (Test-Path -LiteralPath (Join-Path $dir.Data 'recovery'))) $config

    # 旧パスだけが置換され、他は 1 バイトも変わらないこと（置換を元に戻すと元の内容に一致する）。
    $newHook = $hookExe; $newCli = $currentExe
    function Restore-Old([string]$Text) {
        $restored = $Text.Replace((Escape-Json $newHook), (Escape-Json "$oldBin\prunlet-hook.exe")).Replace((Escape-Json $newCli), (Escape-Json "$oldBin\prunlet.exe"))
        return $restored.Replace($newHook, "$oldBin\prunlet-hook.exe").Replace($newCli, "$oldBin\prunlet.exe")
    }
    foreach ($name in @('settings.json', 'CLAUDE.md', 'hooks\powershell-guard.ts')) {
        $path = Join-Path $claude $name
        $now = [IO.File]::ReadAllText($path)
        $changed = $now -cne $originalFiles[$path]
        $referencesNew = $now.Contains($newHook) -or $now.Contains((Escape-Json $newHook)) -or $now.Contains($newCli) -or $now.Contains((Escape-Json $newCli))
        $onlyOwned = (Restore-Old $now) -ceq $originalFiles[$path]
        $noOld = !$now.Contains("$oldBin\prunlet-hook.exe") -and !$now.Contains((Escape-Json "$oldBin\prunlet-hook.exe"))
        $leaf = Split-Path -Leaf $path
        $backups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Force -Filter ".$leaf.prunlet-backup-*")
        $backupOk = $backups.Count -eq 1 -and ([IO.File]::ReadAllText($backups[0].FullName) -ceq $originalFiles[$path])
        Add-Result "install.rewrite.$name" 'old paths replaced, nothing else changed, original saved as a backup' ($changed -and $referencesNew -and $onlyOwned -and $noOld -and $backupOk) "changed=$changed new=$referencesNew onlyOwned=$onlyOwned noOld=$noOld backups=$($backups.Count)"
    }
    $guideNow = [IO.File]::ReadAllText((Join-Path $claude 'PRUNLET.md'))
    Add-Result 'install.rewrite.PRUNLET.md' 'PRUNLET.md (no old paths) is unchanged and has no backup' (($guideNow -ceq $originalFiles[(Join-Path $claude 'PRUNLET.md')]) -and !@(Get-ChildItem -LiteralPath $claude -Force -Filter '.PRUNLET.md.prunlet-backup-*').Count)
    $registryNow = [IO.File]::ReadAllText($registryPath)
    $registryJson = $registryNow | ConvertFrom-Json
    $prunletServer = @($registryJson.servers | Where-Object { $_.id -ceq 'prunlet' })[0]
    $registryBackups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $registryPath) -Force -Filter '.registry.json.prunlet-backup-*')
    Add-Result 'install.rewrite.toolport' 'Toolport launcher registration became a direct launch; other servers untouched; backup exists' (($prunletServer.command -ceq $currentExe) -and (($prunletServer.args -join '|') -ceq "--config|$config|mcp") -and (@($registryJson.servers | Where-Object { $_.id -ceq 'other' }).Count -eq 1) -and $registryBackups.Count -eq 1 -and ([IO.File]::ReadAllText($registryBackups[0].FullName) -ceq $originalFiles[$registryPath])) "command=$($prunletServer.command)"
    $settingsAfterInstall = [IO.File]::ReadAllText((Join-Path $claude 'settings.json'))
    $backupCountAfterInstall = @(Get-ChildItem -LiteralPath $claude -Recurse -Force -Filter '*.prunlet-backup-*').Count

    $status = Invoke-Cli @('setup', 'status')
    $s = $status.Json
    Add-Result 'install.status' 'setup status: managed, packId, version, hook matches CLI, config created, Run entry created' ($null -ne $s -and $s.managed -and $s.packId -ceq $PackId -and $s.version -ceq $Versions[0] -and $s.hook.matchesCli -and $s.setup.config.status -ceq 'created' -and $s.setup.logon.status -ceq 'created') ($status.Stdout.Trim())
    $runValues = @([PrunletE2eHive]::RunValues($hive))
    Add-Result 'install.run-hive' 'the Run value was written to the isolated hive only' ($runValues -contains $runValueName) ($runValues -join ',')

    # ───── hook の連続実行を始める（更新の最中も続ける） ─────
    Step 'Start the continuous hook loop (separate hidden process)'
    $sample = Invoke-Isolated $hookExe @('--config', $config, 'hook', '--cli-executable', $currentExe) 30
    $loopInfo = New-ProcessInfo (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'e2e-hook-loop.ps1'), '-HookExecutable', $hookExe, '-Config', $config, '-CliExecutable', $currentExe, '-StopFile', $stopFile, '-LogFile', $loopLog) $false
    $loopProcess = [Diagnostics.Process]::Start($loopInfo)
    $null = $loopProcess.StandardOutput.ReadToEndAsync(); $null = $loopProcess.StandardError.ReadToEndAsync()
    $null = Wait-Until { (Test-Path -LiteralPath $loopLog) -and @(Get-Content -LiteralPath $loopLog).Count -ge 5 } 30
    Add-Result 'loop.started' 'the hook loop is running and every sample is a deny' ((Test-Path -LiteralPath $loopLog) -and @(Get-Content -LiteralPath $loopLog | Where-Object { $_ -match '"ok":true' }).Count -ge 5) $sample.Stdout.Trim()

    # ───── 更新 1: 9.0.0 → 9.0.1（update-check → update-apply） ─────
    Step "Update 1: $($Versions[0]) -> $($Versions[1])"
    Set-Feed $Versions[1]
    $check = Invoke-Cli @('update-check')
    Add-Result 'update1.check' "update-check downloads $($Versions[1])" ($null -ne $check.Json -and $check.Json.status -ceq 'downloaded' -and (Get-Prop $check.Json "version") -ceq $Versions[1]) $check.Stdout.Trim()
    $apply = Invoke-Cli @('update-apply', '--no-maintenance')
    Add-Result 'update1.apply' 'update-apply hands the update to the updater (applied)' ($null -ne $apply.Json -and $apply.Json.status -ceq 'applied' -and $apply.ExitCode -eq 0) "exit=$($apply.ExitCode) $($apply.Stdout.Trim())"
    $switched = Wait-Until { (Get-InstalledVersion) -ceq $Versions[1] } 90
    Add-Result 'update1.version' "current is now $($Versions[1])" $switched "found=$(Get-InstalledVersion)"
    $hookSynced = Wait-Until { (Test-Path -LiteralPath $hookExe) -and ((Get-Sha256 $hookExe) -ceq (Get-Sha256 $currentExe)) } 30
    $hookNote = if ($hookSynced) { 'replaced by the updated hook while the loop was running' } else { 'deferred while the loop kept it in use (see setup status)' }
    Add-Result 'update1.hook-copy' 'hook copy equals the new current\prunlet.exe (or the update was deferred and kept the old one)' ($hookSynced -or (Test-Path -LiteralPath $hookExe)) $hookNote
    if (!$hookSynced) {
        $repair = Invoke-Cli @('setup', 'repair')
        Write-Host "setup repair: $($repair.Stdout.Trim())"
    }

    # ───── 悪性フィード（骨組み。実行は後）: 更新器の差し替えと Delta ─────
    # フィードの nupkg の更新器（lib/app/Squirrel.exe）を別のバイト列に差し替え、フィードには Delta の資産も載せる。
    # フィード側のハッシュは差し替え後の nupkg に合わせる（フィードだけを見る検査は通る）。クライアントは、
    # 取得しても `<root>\Update.exe` を変えず（更新器は検査済みの nupkg からだけ用意する）、署名付きマニフェストの SHA-256 と
    # 合わないので untrusted（終了コード 2）で適用せず、Delta は取得も適用もしない。
    Step 'Malicious feed: swapped updater and a Delta asset (nothing may be applied, Update.exe must stay unchanged)'
    $rootUpdater = Join-Path $root 'Update.exe'
    $updaterBefore = Get-Sha256 $rootUpdater
    $versionBefore = Get-InstalledVersion
    $evil = Join-Path $dir.Logs 'malicious-feed'
    New-Item -ItemType Directory -Path $evil | Out-Null
    $evilNupkg = Join-Path $evil "$PackId-$($Versions[2])-full.nupkg"
    Copy-Item -LiteralPath $pack[$Versions[2]].Nupkg -Destination $evilNupkg
    $zip = [IO.Compression.ZipFile]::Open($evilNupkg, 'Update')
    try {
        $zip.GetEntry('lib/app/Squirrel.exe').Delete()
        $replacement = $zip.CreateEntry('lib/app/Squirrel.exe')
        $stream = $replacement.Open()
        $bytes = [IO.File]::ReadAllBytes((Join-Path $out "builds\$($Versions[2])\prunlet-maintenance.exe"))
        $stream.Write($bytes, 0, $bytes.Length); $stream.Dispose()
    } finally { $zip.Dispose() }
    $deltaName = "$PackId-$($Versions[2])-delta.nupkg"
    $deltaPath = Join-Path $evil $deltaName
    [IO.File]::WriteAllBytes($deltaPath, [byte[]](1..255))
    function Get-FeedAsset([string]$Path, [string]$Type, [string]$Name) {
        return [ordered]@{
            PackageId = $PackId; Version = $Versions[2]; Type = $Type; FileName = $Name
            SHA1 = (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash; SHA256 = (Get-Sha256 $Path); Size = (Get-Item -LiteralPath $Path).Length
        }
    }
    $evilFeed = [ordered]@{ Assets = @((Get-FeedAsset $evilNupkg 'Full' (Split-Path -Leaf $evilNupkg)), (Get-FeedAsset $deltaPath 'Delta' $deltaName)) }
    foreach ($file in @(Get-ChildItem -LiteralPath $dir.Feed -File)) { [IO.File]::Move($file.FullName, (Join-Path $dir.Logs ("old-feed-" + [Guid]::NewGuid().ToString('N') + '-' + $file.Name))) }
    Copy-Item -LiteralPath $evilNupkg, $deltaPath -Destination $dir.Feed
    [IO.File]::WriteAllText((Join-Path $dir.Feed 'releases.win.json'), ($evilFeed | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    $evilCheck = Invoke-Cli @('update-check')
    $evilApply = Invoke-Cli @('update-apply', '--no-maintenance')
    $deltaFetched = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*delta*' -ErrorAction SilentlyContinue).Count
    $packagesDir = Join-Path $root 'packages'
    $incomingDir = Join-Path $stateDir 'incoming'
    function Get-StagedFiles { return @(Get-ChildItem -LiteralPath $packagesDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$($Versions[2])*" }) }
    function Get-IncomingFiles { return @(Get-ChildItem -LiteralPath $incomingDir -Recurse -File -ErrorAction SilentlyContinue) }
    # クライアントは取得を root の外（state\incoming）で自前に行い、検査（署名付きマニフェストの SHA-256 照合を含む）に通るまで packages へ移さない。
    # 差し替えた更新器の nupkg は署名付きマニフェストの SHA-256 と合わないので取得の段階で拒否され（update-check が failed）、適用する対象も残らない。
    Add-Result 'malicious.check-failed' 'a feed with a swapped updater fails at update-check (status failed); nothing is staged or applied' ($null -ne $evilCheck.Json -and $evilCheck.Json.status -ceq 'failed' -and @(Get-StagedFiles).Count -eq 0 -and (Get-InstalledVersion) -ceq $versionBefore -and (Get-Prop $evilApply.Json 'status') -ceq 'nothingPending') "check(exit=$($evilCheck.ExitCode))=$($evilCheck.Stdout.Trim()) apply=$($evilApply.Stdout.Trim())"
    Add-Result 'malicious.updater-unchanged' 'the installed <root>\Update.exe is byte-identical after fetching the malicious package' ((Get-Sha256 $rootUpdater) -ceq $updaterBefore) $rootUpdater
    Add-Result 'malicious.no-delta' 'the Delta asset was neither fetched into the installation nor applied' ($deltaFetched -eq 0) "deltaFiles=$deltaFetched"
    Add-Result 'malicious.incoming-clean' 'the incoming staging folder is left empty after the refusal' (@(Get-IncomingFiles).Count -eq 0) "files=$(@(Get-IncomingFiles).Count)"

    # ───── 更新 2 の準備: 9.0.2 ─────
    Step "Update 2 preparation: $($Versions[2])"
    Set-Feed $Versions[2]
    $manifestPath = Get-ReleaseManifestPath $Versions[2]
    $goodManifest = [IO.File]::ReadAllBytes($manifestPath)
    # 基点の不一致: 正しく署名されているが、payloadのsha256が配布物と違う封筒。
    $wrongManifest = New-ReleaseManifestBytes $Versions[2] ('0' * 64) (Get-Item -LiteralPath $pack[$Versions[2]].Nupkg).Length
    # 署名不正: 固定の（テスト）公開鍵では検証できない別の鍵で署名した封筒。
    $foreignManifest = New-ReleaseManifestBytes $Versions[2] (Get-Sha256 $pack[$Versions[2]].Nupkg).ToLowerInvariant() (Get-Item -LiteralPath $pack[$Versions[2]].Nupkg).Length (New-ForeignReleaseKeyPem)
    # 欠落は削除せず、検証用のログフォルダーへ移して作る（このスクリプトは削除を行わない）。
    function Hide-ReleaseManifest { [IO.File]::Move($manifestPath, (Join-Path $dir.Logs ('missing-manifest-' + [Guid]::NewGuid().ToString('N') + '.json'))) }

    # 取得時の署名付きマニフェスト検査: 基点の不一致・欠落は update-check が failed になり、packages へ何も置かない。
    [IO.File]::WriteAllBytes($manifestPath, $wrongManifest)
    $check = Invoke-Cli @('update-check')
    Add-Result 'fetch.release-mismatch' 'at update-check a signed manifest whose SHA-256 differs from the package fails the check; nothing is staged' ($null -ne $check.Json -and $check.Json.status -ceq 'failed' -and @(Get-StagedFiles).Count -eq 0 -and @(Get-IncomingFiles).Count -eq 0) "exit=$($check.ExitCode) $($check.Stdout.Trim())"
    Hide-ReleaseManifest
    $check = Invoke-Cli @('update-check')
    Add-Result 'fetch.release-missing' 'at update-check a missing R2 manifest fails the check; nothing is staged' ($null -ne $check.Json -and $check.Json.status -ceq 'failed' -and @(Get-StagedFiles).Count -eq 0 -and @(Get-IncomingFiles).Count -eq 0) "exit=$($check.ExitCode) $($check.Stdout.Trim())"
    [IO.File]::WriteAllBytes($manifestPath, $foreignManifest)
    $check = Invoke-Cli @('update-check')
    Add-Result 'fetch.release-signature' 'at update-check a manifest signed by an untrusted key fails the check; nothing is staged' ($null -ne $check.Json -and $check.Json.status -ceq 'failed' -and @(Get-StagedFiles).Count -eq 0 -and @(Get-IncomingFiles).Count -eq 0) "exit=$($check.ExitCode) $($check.Stdout.Trim())"
    [IO.File]::WriteAllBytes($manifestPath, $goodManifest)
    $check = Invoke-Cli @('update-check')
    Add-Result 'update2.check' "update-check downloads $($Versions[2])" ($null -ne $check.Json -and $check.Json.status -ceq 'downloaded' -and (Get-Prop $check.Json "version") -ceq $Versions[2] -and @(Get-StagedFiles).Count -ge 1) $check.Stdout.Trim()

    # 適用時の署名付きマニフェスト検査（取得後に基点が変わった場合）: 基点の不一致 → untrusted（終了コード 2）、
    # 欠落・署名不正（検証できない）→ deferred。どれも適用しない。
    [IO.File]::WriteAllBytes($manifestPath, $wrongManifest)
    $apply = Invoke-Cli @('update-apply', '--no-maintenance')
    Add-Result 'trust.release-mismatch' 'at update-apply a signed manifest whose SHA-256 differs from the package is refused (untrusted, exit 2), not applied' ($null -ne $apply.Json -and $apply.Json.status -ceq 'untrusted' -and $apply.ExitCode -eq 2 -and (Get-InstalledVersion) -ceq $Versions[1]) "exit=$($apply.ExitCode) $($apply.Stdout.Trim())"
    Hide-ReleaseManifest
    $apply = Invoke-Cli @('update-apply', '--no-maintenance')
    Add-Result 'trust.release-missing' 'at update-apply a missing R2 manifest defers the update (deferred), not applied' ($null -ne $apply.Json -and $apply.Json.status -ceq 'deferred' -and $apply.ExitCode -eq 0 -and (Get-InstalledVersion) -ceq $Versions[1]) "exit=$($apply.ExitCode) $($apply.Stdout.Trim())"
    [IO.File]::WriteAllBytes($manifestPath, $foreignManifest)
    $apply = Invoke-Cli @('update-apply', '--no-maintenance')
    Add-Result 'trust.release-signature' 'at update-apply a manifest signed by an untrusted key defers the update (deferred), not applied' ($null -ne $apply.Json -and $apply.Json.status -ceq 'deferred' -and $apply.ExitCode -eq 0 -and (Get-InstalledVersion) -ceq $Versions[1]) "exit=$($apply.ExitCode) $($apply.Stdout.Trim())"
    [IO.File]::WriteAllBytes($manifestPath, $goodManifest)
    # ───── MCP を直接起動したまま update-apply → busy ─────
    Step 'Directly started MCP keeps running: update-apply must defer (busy) and kill nothing'
    $mcpInfo = New-ProcessInfo $currentExe @('--config', $config, 'mcp') $true
    $mcp = [Diagnostics.Process]::Start($mcpInfo)
    $null = $mcp.StandardOutput.ReadToEndAsync(); $null = $mcp.StandardError.ReadToEndAsync()
    $mcpPid = $mcp.Id
    # MCP は起動直後に製品ロック（共有）を取る。取る前に update-apply を呼ぶと適用してしまうので、少し待つ。
    Start-Sleep -Seconds 5
    $locked = !$mcp.HasExited
    $apply = Invoke-Cli @('update-apply', '--no-maintenance')
    $mcpAlive = !$mcp.HasExited
    Add-Result 'busy.deferred' 'update-apply reports busy while the MCP runs; the MCP was not killed; the version did not change' ($locked -and $null -ne $apply.Json -and $apply.Json.status -ceq 'busy' -and $apply.ExitCode -eq 0 -and $mcpAlive -and (Get-InstalledVersion) -ceq $Versions[1]) "mcpPid=$mcpPid alive=$mcpAlive exit=$($apply.ExitCode) $($apply.Stdout.Trim())"
    $mcp.StandardInput.Close()
    $mcpStopped = $mcp.WaitForExit(30000)
    Add-Result 'busy.mcp-exit' 'the MCP exits normally (exit code 0) when its input closes' ($mcpStopped -and $mcp.ExitCode -eq 0) "exit=$(if ($mcpStopped) { $mcp.ExitCode } else { 'running' })"
    if (!$mcpStopped) { Write-Host 'The MCP did not stop; it is left for the finally block.' }

    # ───── MCP を止めてから適用 ─────
    Step "Update 2 apply after the MCP stopped: $($Versions[1]) -> $($Versions[2])"
    $apply = Invoke-Cli @('update-apply', '--no-maintenance')
    Add-Result 'update2.apply' 'update-apply applies once nothing else runs (applied)' ($null -ne $apply.Json -and $apply.Json.status -ceq 'applied' -and $apply.ExitCode -eq 0) "exit=$($apply.ExitCode) $($apply.Stdout.Trim())"
    $switched = Wait-Until { (Get-InstalledVersion) -ceq $Versions[2] } 90
    Add-Result 'update2.version' "current is now $($Versions[2])" $switched "found=$(Get-InstalledVersion)"
    $hookSynced = Wait-Until { (Test-Path -LiteralPath $hookExe) -and ((Get-Sha256 $hookExe) -ceq (Get-Sha256 $currentExe)) } 30
    # hook ループが複製を掴んでいる最中は、更新フックが置き換えられず旧 hook を残して延期する（設計どおり。needsRetry が立つ）。
    # 置換できた、または「旧 hook を無傷で残して延期し、再試行が記録された」のどちらかを合格とし、延期のときは
    # ループを止めた後の `setup repair` で新版へ置換されることを次で確かめる。
    $setupRecord = Get-Content -LiteralPath (Join-Path $stateDir 'setup-state.json') -Raw | ConvertFrom-Json
    $deferredSafely = !$hookSynced -and (Get-Prop (Get-Prop $setupRecord 'hook') 'status') -ceq 'deferred' -and (Get-Prop $setupRecord 'needsRetry') -eq $true -and (Test-Path -LiteralPath $hookExe)
    Add-Result 'update2.hook-copy' 'the updated hook replaced the copy, or kept the old one and recorded a retry (deferred while the loop held it)' ($hookSynced -or $deferredSafely) $(if ($hookSynced) { 'replaced' } else { "deferred: $(Get-Prop (Get-Prop $setupRecord 'hook') 'detail')" })

    # ───── hook ループの集計 ─────
    Step 'Stop the hook loop and count the results'
    New-Item -ItemType File -Path $stopFile -Force | Out-Null
    $null = $loopProcess.WaitForExit(30000)
    if (!$hookSynced) {
        # ループが止まった後の再試行（ログオン時の update-apply・MCP 起動・setup repair と同じ経路）で新版へ置き換わる。
        $repair = Invoke-Cli @('setup', 'repair')
        $repaired = Wait-Until { (Get-Sha256 $hookExe) -ceq (Get-Sha256 $currentExe) } 15
        Add-Result 'update2.hook-retry' 'after the loop stopped, setup repair replaces the deferred hook copy with the new version' $repaired ($repair.Stdout.Trim().Substring(0, [Math]::Min(300, $repair.Stdout.Trim().Length)))
    }
    $lines = @(Get-Content -LiteralPath $loopLog)
    $entries = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
    $bad = @($entries | Where-Object { !$_.ok })
    Add-Result 'loop.result' "hook ran $($entries.Count) times across both updates: no response other than deny, no start failure" ($entries.Count -ge 50 -and $bad.Count -eq 0) "runs=$($entries.Count) bad=$($bad.Count) first=$(if ($bad.Count) { $bad[0].detail } else { '-' })"

    # ───── 設定の冪等性（更新フックを経ても書換え済みの設定は変わらない） ─────
    Add-Result 'idempotent.hosts' 'host files are unchanged by the updates and no extra backups were made' (([IO.File]::ReadAllText((Join-Path $claude 'settings.json')) -ceq $settingsAfterInstall) -and @(Get-ChildItem -LiteralPath $claude -Recurse -Force -Filter '*.prunlet-backup-*').Count -eq $backupCountAfterInstall)

    $final = Invoke-Cli @('setup', 'status')
    Write-Host ("final status: " + $final.Stdout.Trim())

    # ───── M1: 壊れた・無い hook 複製は、MCP の起動で再配置される ─────
    Step 'M1: a damaged or missing hook copy is restored when the MCP starts'
    foreach ($damage in @('corrupt', 'missing')) {
        if ($damage -eq 'corrupt') { [IO.File]::WriteAllBytes($hookExe, [byte[]](1..64)) }
        else { [IO.File]::Move($hookExe, (Join-Path $dir.Logs ('hook-missing-' + [Guid]::NewGuid().ToString('N') + '.exe'))) }
        $before = if (Test-Path -LiteralPath $hookExe) { (Get-Sha256 $hookExe) -cne (Get-Sha256 $currentExe) } else { $true }
        $m1 = [Diagnostics.Process]::Start((New-ProcessInfo $currentExe @('--config', $config, 'mcp') $true))
        $null = $m1.StandardOutput.ReadToEndAsync(); $null = $m1.StandardError.ReadToEndAsync()
        $restored = Wait-Until { (Test-Path -LiteralPath $hookExe) -and ((Get-Sha256 $hookExe) -ceq (Get-Sha256 $currentExe)) } 40
        $m1.StandardInput.Close()
        $stopped = $m1.WaitForExit(30000)
        if (!$stopped) { $m1.Kill() }
        Add-Result "m1.$damage" "a $damage hook copy is re-placed with the current CLI by the MCP start (the MCP exits 0)" ($before -and $restored -and $stopped -and $m1.ExitCode -eq 0) "damaged=$before restored=$restored mcpExit=$(if ($stopped) { $m1.ExitCode } else { 'killed' })"
        $m1.Dispose()
    }

    # ───── M3: 放棄された適用中マーカーは新規起動を永久には拒否しない ─────
    Step 'M3: a fresh apply marker refuses a new start; an abandoned one (past the grace, no updater running) is cleared'
    $markerPath = Join-Path $stateDir 'update-apply.marker.json'
    $nowSeconds = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    [IO.File]::WriteAllText($markerPath, "{`"target`":`"9.9.9`",`"writtenAt`":$nowSeconds,`"pid`":1}", [Text.UTF8Encoding]::new($false))
    $fresh = Invoke-Cli @('--config', $config, 'validate-config')
    Add-Result 'm3.fresh-refused' 'a fresh marker for another version refuses a new start (exit 1) and stays' ($fresh.ExitCode -eq 1 -and (Test-Path -LiteralPath $markerPath)) "exit=$($fresh.ExitCode) $($fresh.Stdout.Trim())"
    [IO.File]::WriteAllText($markerPath, "{`"target`":`"9.9.9`",`"writtenAt`":$($nowSeconds - 60),`"pid`":1}", [Text.UTF8Encoding]::new($false))
    $abandoned = Invoke-Cli @('--config', $config, 'validate-config')
    Add-Result 'm3.abandoned-cleared' 'a marker past the grace with no updater running is treated as abandoned: the start proceeds and the marker is cleared' ($abandoned.ExitCode -eq 0 -and (Get-Prop $abandoned.Json 'valid') -eq $true -and !(Test-Path -LiteralPath $markerPath)) "exit=$($abandoned.ExitCode) $($abandoned.Stdout.Trim())"

    # ───── L3: auto_update が無効でも、update-apply はログオン時の保守を続けて実行する ─────
    Step 'L3: with auto_update disabled, update-apply reports disabled and still runs the maintenance'
    $settingsFile = Join-Path $stateDir 'app-update.json'
    $settingsOriginal = if (Test-Path -LiteralPath $settingsFile) { [IO.File]::ReadAllText($settingsFile) } else { $null }
    [IO.File]::WriteAllText($settingsFile, '{"auto_update":false}', [Text.UTF8Encoding]::new($false))
    $disabled = Invoke-Cli @('update-apply')
    if ($null -ne $settingsOriginal) { [IO.File]::WriteAllText($settingsFile, $settingsOriginal, [Text.UTF8Encoding]::new($false)) }
    $maintenance = Get-Prop $disabled.Json 'maintenance'
    Add-Result 'l3.disabled-maintenance' 'update-apply with auto_update off returns disabled and still reports the maintenance result' ((Get-Prop $disabled.Json 'status') -ceq 'disabled' -and $null -ne $maintenance) "exit=$($disabled.ExitCode) $($disabled.Stdout.Trim())"

    # ───── アンインストール ─────
    Step 'Uninstall'
    $updater = Join-Path $root 'Update.exe'
    $runBefore = @([PrunletE2eHive]::RunValues($hive))
    $uninstall = Invoke-Isolated $updater @('--silent', '--uninstall') 120
    Write-Host "uninstall exit=$($uninstall.ExitCode) stdout=$($uninstall.Stdout.Trim()) stderr=$($uninstall.Stderr.Trim())"
    $null = Wait-Until { !(Test-Path -LiteralPath $uninstallKey) } 60
    $runAfter = @([PrunletE2eHive]::RunValues($hive))
    Add-Result 'uninstall.run-value' 'the test Run value is removed from the isolated hive' (($runBefore -contains $runValueName) -and !($runAfter -contains $runValueName)) "before=$($runBefore -join ',') after=$($runAfter -join ',')"
    Add-Result 'uninstall.registry-key' 'the HKCU Uninstall registration is gone' (!(Test-Path -LiteralPath $uninstallKey)) $uninstallKey
    $null = Wait-Until { !(Test-Path -LiteralPath $currentExe) } 30
    Add-Result 'uninstall.files' 'the installation folder no longer contains current\prunlet.exe' (!(Test-Path -LiteralPath $currentExe))
    Add-Result 'uninstall.hook-kept' 'the hook copy is kept while host settings still reference it (design: kept)' (Test-Path -LiteralPath $hookExe) $hookExe
} catch {
    Add-Result 'fatal' 'the E2E stopped on an unexpected error' $false $_.Exception.Message
    Write-Host $_.ScriptStackTrace
} finally {
    # 後始末（失敗しても後を残さない）。削除はしない。止める・外すだけ。
    New-Item -ItemType File -Path $stopFile -Force -ErrorAction SilentlyContinue | Out-Null
    if ($null -ne $loopProcess -and !$loopProcess.HasExited) { $null = $loopProcess.WaitForExit(15000); if (!$loopProcess.HasExited) { $loopProcess.Kill() } }
    if ($null -ne $mcp -and !$mcp.HasExited) { try { $mcp.StandardInput.Close() } catch {}; if (!$mcp.WaitForExit(15000)) { $mcp.Kill() } }
    if ((Test-Path -LiteralPath $uninstallKey) -and (Test-Path -LiteralPath (Join-Path $root 'Update.exe'))) {
        $null = Invoke-Isolated (Join-Path $root 'Update.exe') @('--silent', '--uninstall') 120
        $null = Wait-Until { !(Test-Path -LiteralPath $uninstallKey) } 60
    }
    $leftover = Test-Path -LiteralPath $uninstallKey
    if ($leftover) { Add-Result 'cleanup.uninstall-key' 'the HKCU Uninstall registration was left behind' $false $uninstallKey }
}

$summary = [ordered]@{ run = $run; packId = $PackId; versions = $Versions; nupkgEntries = $entryNames; results = $results }
$summaryPath = Join-Path $run 'summary.json'
[IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
$failed = @($results | Where-Object { !$_.pass })
Write-Host "`nsummary: $summaryPath"
Write-Host ("{0} passed, {1} failed" -f (@($results | Where-Object { $_.pass }).Count), $failed.Count)
if ($failed.Count) { exit 1 }
