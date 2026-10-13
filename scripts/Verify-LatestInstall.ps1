#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [switch]$CheckPublicHead
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $PSScriptRoot 'Install-Prunlet.ps1'
$forbidden = @($repoRoot, (Join-Path $env:USERPROFILE '.codex'))
if ($env:CODEX_HOME) { $forbidden += [IO.Path]::GetFullPath($env:CODEX_HOME) }
foreach ($path in @($OutputDirectory, $ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'Verification paths must be absolute.' }
    $full = [IO.Path]::GetFullPath($path)
    foreach ($root in $forbidden) {
        if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Verification output must be external.' }
    }
    $cursor = $full
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Verification paths cannot traverse links.' }
        if (Test-Path -LiteralPath (Join-Path $cursor '.git')) { throw 'Verification output cannot be in a repository.' }
        $cursor = Split-Path -Parent $cursor
    }
    if (Test-Path -LiteralPath $full) { throw 'Verification destinations must be new.' }
}
New-Item -ItemType Directory -Path $OutputDirectory, (Split-Path -Parent $ReportPath) -Force | Out-Null
$results = [Collections.Generic.List[object]]::new()
function Assert-True([bool]$Value, [string]$Message) { if (!$Value) { throw $Message } }
function Test-Case([string]$Name, [scriptblock]$Action) {
    try { & $Action; $results.Add(@{ name = $Name; passed = $true }) }
    catch { $results.Add(@{ name = $Name; passed = $false; error = $_.ToString() }) }
}
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught) 'Expected installation failure.'
    Assert-True ($caught.ToString() -match $Pattern) "Unexpected failure: $caught"
}
$allowed = Join-Path $OutputDirectory 'allowed'
New-Item -ItemType Directory -Path $allowed | Out-Null
$install = Join-Path $OutputDirectory 'installed'
$fixtureInstalls = [Collections.Generic.List[string]]::new()
$fixtureInstalls.Add($install)
$isolatedCodex = Join-Path $OutputDirectory 'isolated-codex'
$settingsBackup = Join-Path $OutputDirectory 'settings-backup'

# 起こり得る失敗を列挙してから実システムの検証を組み立てる。
$failureConditions = @('初回許可範囲欠落', '無効repository', '外部保存先違反またはリンク', 'ネットワーク取得失敗', '公開HEADに必要ソース欠落', 'ZIP traversal/重複/リンク', 'ビルド失敗', '製品ファイル更新失敗', '登録時既存設定の拒否', 'Codex登録の2ファイル間での書込み失敗', '許可範囲内の作業場所と復元先の検証')
Test-Case 'First install requires explicit allowed roots' {
    Expect-Failure { & $installer -InstallDirectory $install } 'First installation requires'
    Assert-True (!(Test-Path -LiteralPath $install)) 'Initial failure created install files.'
}
Test-Case 'Invalid repository stops before download' {
    Expect-Failure { & $installer -Repository '../Prunlet' -InstallDirectory $install -AllowedRoot $allowed } 'Repository must'
}
Test-Case 'Repository output and linked install paths are refused' {
    Expect-Failure { & $installer -InstallDirectory (Join-Path $repoRoot 'should-not-exist') -AllowedRoot $allowed } 'outside repositories'
    $linked = Join-Path $OutputDirectory 'linked-install'
    New-Item -ItemType Junction -Path $linked -Target $allowed | Out-Null
    try { Expect-Failure { & $installer -InstallDirectory $linked -AllowedRoot $allowed } 'cannot traverse links' }
    finally { Remove-Item -LiteralPath $linked }
}
if ($CheckPublicHead) {
    Test-Case 'Public default branch is queried without clone fallback' {
        $publicInstall = Join-Path $OutputDirectory 'public-install'
        try {
            & $installer -InstallDirectory $publicInstall -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'public-work') | Out-Null
            $publicInfo = Get-Content -LiteralPath (Join-Path $publicInstall 'source-info.json') -Raw | ConvertFrom-Json
            Assert-True ($publicInfo.commitSha -match '^[0-9a-f]{40}$') 'Public installation has no provenance.'
        } catch {
            Assert-True ($_.ToString() -match 'Latest source is not installable; required file missing') "Public lookup failed unexpectedly: $_"
            Assert-True (!(Test-Path -LiteralPath $publicInstall)) 'Incomplete public source mutated installation.'
        }
    }
}

# 本番URLは固定のまま、親スコープのHTTPコマンドだけを置換する。
# CLI/build/配置/登録/ロールバックは実処理を実行する。
$fixtureRoot = Join-Path $OutputDirectory 'fixture'
$source = Join-Path $fixtureRoot 'Prunlet-fixture'
New-Item -ItemType Directory -Path $source, (Join-Path $source 'scripts') | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'src'), (Join-Path $repoRoot 'integration') -Destination $source -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Publish-Prunlet.ps1') -Destination (Join-Path $source 'scripts')
$zipPath = Join-Path $OutputDirectory 'fixture.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($fixtureRoot, $zipPath)
$global:PrunletLatestFixture = @{ sha = ('a' * 40); zip = $zipPath; requests = [Collections.Generic.List[string]]::new(); failDownload = $false; failCopy = $false }
function Invoke-RestMethod {
    param($Uri, $Headers, $TimeoutSec)
    [void]$global:PrunletLatestFixture.requests.Add([string]$Uri)
    Assert-True ($Headers['User-Agent'] -eq 'Prunlet-Latest-Installer' -and $TimeoutSec -gt 0) 'Missing network bounds.'
    switch -Exact ([string]$Uri) {
        'https://api.github.com/repos/1llum1n4t1s/Prunlet' { return @{ default_branch = 'fixture/main' } }
        'https://api.github.com/repos/1llum1n4t1s/Prunlet/commits/fixture%2Fmain' { return @{ sha = $global:PrunletLatestFixture.sha } }
        default { throw "Unexpected metadata URL: $Uri" }
    }
}
function Invoke-WebRequest {
    param($Uri, $Headers, $OutFile, $TimeoutSec)
    [void]$global:PrunletLatestFixture.requests.Add([string]$Uri)
    Assert-True ([string]$Uri -eq ('https://codeload.github.com/1llum1n4t1s/Prunlet/zip/' + $global:PrunletLatestFixture.sha)) 'Download did not pin this resolved HEAD.'
    if ($global:PrunletLatestFixture.failDownload) { throw 'Fixture network failure.' }
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $global:PrunletLatestFixture.zip -Destination $OutFile
}
function Copy-Item {
    [CmdletBinding()]
    param([string[]]$LiteralPath, [string]$Destination, [switch]$Force, [switch]$Recurse)
    if ($global:PrunletLatestFixture.failCopy -and $Destination -eq (Join-Path $install 'bin\codex-pretooluse.ps1')) {
        $global:PrunletLatestFixture.failCopy = $false
        throw 'Fixture product write failure.'
    }
    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
}
function Snapshot-Install {
    $map = @{}
    Get-ChildItem -LiteralPath $install -File -Recurse | ForEach-Object { $map[$_.FullName] = (Get-FileHash -LiteralPath $_.FullName).Hash }
    return $map
}
function Assert-Snapshot($Before) {
    $after = Snapshot-Install
    Assert-True ($Before.Count -eq $after.Count) 'Installed file count changed on failure.'
    foreach ($key in $Before.Keys) { Assert-True ($Before[$key] -eq $after[$key]) "Installed file changed: $key" }
}
$beforeBackups = @(Get-ChildItem -LiteralPath (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Codex\TaskArtifacts\Prunlet') -Directory -Filter 'install-*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
try {
    Test-Case 'Download failure preserves initial boundary' {
        $global:PrunletLatestFixture.failDownload = $true
        try { Expect-Failure { & $installer -InstallDirectory $install -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'network-work') } 'Fixture network failure' }
        finally { $global:PrunletLatestFixture.failDownload = $false }
        Assert-True (!(Test-Path -LiteralPath $install)) 'Download failure created install files.'
    }
    Test-Case 'ZIP traversal is rejected before mutation' {
        $badZip = Join-Path $OutputDirectory 'unsafe.zip'
        $z = [IO.Compression.ZipFile]::Open($badZip, [IO.Compression.ZipArchiveMode]::Create)
        try { [void]$z.CreateEntry('root/../escaped.txt') } finally { $z.Dispose() }
        $global:PrunletLatestFixture.zip = $badZip
        try { Expect-Failure { & $installer -InstallDirectory $install -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'unsafe-work') } 'Unsafe archive path' }
        finally { $global:PrunletLatestFixture.zip = $zipPath }
        Assert-True (!(Test-Path -LiteralPath $install)) 'Unsafe ZIP created install files.'
    }
    Test-Case 'ZIP duplicate paths and symbolic links are rejected' {
        foreach ($kind in @('duplicate', 'link')) {
            $badZip = Join-Path $OutputDirectory "$kind.zip"
            $z = [IO.Compression.ZipFile]::Open($badZip, [IO.Compression.ZipArchiveMode]::Create)
            try {
                $entry = $z.CreateEntry('root/file.txt')
                if ($kind -eq 'duplicate') { [void]$z.CreateEntry('root/FILE.txt') }
                else { $entry.ExternalAttributes = [int](-1577058304) }
            } finally { $z.Dispose() }
            $global:PrunletLatestFixture.zip = $badZip
            try { Expect-Failure { & $installer -InstallDirectory $install -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory "$kind-work") } 'Duplicate archive path|Archive links or special files' }
            finally { $global:PrunletLatestFixture.zip = $zipPath }
        }
        Assert-True (!(Test-Path -LiteralPath $install)) 'Invalid ZIP created install files.'
    }
    Test-Case 'Publish failure preserves initial boundary' {
        $publishScript = Join-Path $source 'scripts\Publish-Prunlet.ps1'
        $originalPublish = [IO.File]::ReadAllText($publishScript)
        $brokenZip = Join-Path $OutputDirectory 'broken-build.zip'
        try {
            Set-Content -LiteralPath $publishScript -Value "param([string]`$OutputDirectory, [string]`$Runtime)`nthrow 'Fixture publish failure.'" -Encoding utf8NoBOM
            [IO.Compression.ZipFile]::CreateFromDirectory($fixtureRoot, $brokenZip)
            $global:PrunletLatestFixture.zip = $brokenZip
            Expect-Failure { & $installer -InstallDirectory $install -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'broken-work') } 'Fixture publish failure'
        } finally { [IO.File]::WriteAllText($publishScript, $originalPublish); $global:PrunletLatestFixture.zip = $zipPath }
        Assert-True (!(Test-Path -LiteralPath $install)) 'Build failure created install files.'
    }
    Test-Case 'Latest fixture builds and installs with isolated Codex registration' {
        & $installer -InstallDirectory $install -AllowedRoot $allowed -RegisterCodex -CodexHome $isolatedCodex -SettingsBackupDirectory $settingsBackup -WorkDirectory (Join-Path $OutputDirectory 'first-work') | Out-Null
        $info = Get-Content -LiteralPath (Join-Path $install 'source-info.json') -Raw | ConvertFrom-Json
        Assert-True ($info.commitSha -eq ('a' * 40)) 'Initial provenance mismatch.'
        Assert-True ($info.executableSha256 -eq (Get-FileHash -LiteralPath (Join-Path $install 'bin\prunlet.exe')).Hash) 'Executable provenance hash mismatch.'
        $toml = Get-Content -LiteralPath (Join-Path $isolatedCodex 'config.toml') -Raw
        $hooks = Get-Content -LiteralPath (Join-Path $isolatedCodex 'hooks.json') -Raw
        Assert-True (!$toml.Contains($repoRoot) -and !$hooks.Contains($repoRoot) -and !$toml.Contains($fixtureRoot) -and !$hooks.Contains($fixtureRoot)) 'Registration references checkout source.'
        Assert-True ($toml.Contains('bin\\prunlet.exe')) 'Registration does not use installed bin.'
        Assert-True (!(Test-Path -LiteralPath (Join-Path $OutputDirectory 'first-work'))) 'Successful work was not cleaned.'
    }
    Test-Case 'Next install resolves new HEAD and preserves config and recovery' {
        $configHash = (Get-FileHash -LiteralPath (Join-Path $install 'config.json')).Hash
        $recoveryMarker = Join-Path $install 'recovery\user-marker.txt'
        Set-Content -LiteralPath $recoveryMarker -Value 'Keep user recovery data.' -Encoding utf8NoBOM
        $markerHash = (Get-FileHash -LiteralPath $recoveryMarker).Hash
        $global:PrunletLatestFixture.sha = 'b' * 40
        & $installer -InstallDirectory $install -RegisterCodex -CodexHome $isolatedCodex -SettingsBackupDirectory $settingsBackup -WorkDirectory (Join-Path $OutputDirectory 'second-work') | Out-Null
        $info = Get-Content -LiteralPath (Join-Path $install 'source-info.json') -Raw | ConvertFrom-Json
        Assert-True ($info.commitSha -eq ('b' * 40)) 'Update reused old HEAD.'
        Assert-True ($configHash -eq (Get-FileHash -LiteralPath (Join-Path $install 'config.json')).Hash) 'Update rewrote config.'
        Assert-True ($markerHash -eq (Get-FileHash -LiteralPath $recoveryMarker).Hash) 'Update rewrote recovery.'
    }
    Test-Case 'Partial product write failure rolls back all product files' {
        $before = Snapshot-Install
        $global:PrunletLatestFixture.sha = 'c' * 40
        $global:PrunletLatestFixture.failCopy = $true
        Expect-Failure { & $installer -InstallDirectory $install -WorkDirectory (Join-Path $OutputDirectory 'rollback-work') } 'Fixture product write failure'
        Assert-Snapshot $before
    }
    Test-Case 'Codex refusal preserves installed products and configuration' {
        $before = Snapshot-Install
        $blockedCodex = Join-Path $OutputDirectory 'blocked-codex'
        New-Item -ItemType Directory -Path $blockedCodex | Out-Null
        $toml = Join-Path $blockedCodex 'config.toml'
        Set-Content -LiteralPath $toml -Value "[features]`nhooks = false`n" -Encoding utf8NoBOM
        $tomlHash = (Get-FileHash -LiteralPath $toml).Hash
        Expect-Failure { & $installer -InstallDirectory $install -RegisterCodex -CodexHome $blockedCodex -SettingsBackupDirectory $settingsBackup -WorkDirectory (Join-Path $OutputDirectory 'refused-work') } 'features.hooks is false'
        Assert-Snapshot $before
        Assert-True ($tomlHash -eq (Get-FileHash -LiteralPath $toml).Hash) 'User hooks policy was changed.'
    }
    Test-Case 'Partial Codex registration failure restores exact profile preimages' {
        foreach ($hookState in @('absent', 'existing')) {
            $partialInstall = Join-Path $OutputDirectory "partial-install-$hookState"
            $fixtureInstalls.Add($partialInstall)
            $partialCodex = Join-Path $OutputDirectory "partial-codex-$hookState"
            $partialSettingsBackup = Join-Path $OutputDirectory "partial-settings-backup-$hookState"
            New-Item -ItemType Directory -Path $partialCodex | Out-Null
            $tomlPath = Join-Path $partialCodex 'config.toml'
            $hooksPath = Join-Path $partialCodex 'hooks.json'
            Set-Content -LiteralPath $tomlPath -Value "# Preserve original TOML bytes.`n" -Encoding utf8NoBOM
            $tomlHash = (Get-FileHash -LiteralPath $tomlPath).Hash
            $hookHash = $null
            if ($hookState -eq 'existing') {
                Set-Content -LiteralPath $hooksPath -Value '{"hooks":{},"userValue":"preserve original bytes"}' -Encoding utf8NoBOM
                $hookHash = (Get-FileHash -LiteralPath $hooksPath).Hash
            }
            # 読取りは許可し、後半のTOML書込みだけを実OSの共有ロックで失敗させる。
            $lock = [IO.File]::Open($tomlPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                Expect-Failure { & $installer -InstallDirectory $partialInstall -AllowedRoot $allowed -RegisterCodex -CodexHome $partialCodex -SettingsBackupDirectory $partialSettingsBackup -WorkDirectory (Join-Path $OutputDirectory "partial-work-$hookState") } 'WriteAllText'
                Assert-True ($tomlHash -eq (Get-FileHash -LiteralPath $tomlPath).Hash) 'Locked TOML was changed.'
                if ($hookState -eq 'existing') { Assert-True ($hookHash -eq (Get-FileHash -LiteralPath $hooksPath).Hash) 'Existing hooks preimage was not restored.' }
                else { Assert-True (!(Test-Path -LiteralPath $hooksPath)) 'Partial registration left newly created hooks.json.' }
                Assert-True (!(Test-Path -LiteralPath $partialInstall)) 'Failed first installation left product, config or empty recovery directories.'
            } finally { $lock.Dispose() }
        }
    }
    Test-Case 'Allowed-root ancestor of work uses actual recovery topology' {
        $probeInstall = Join-Path $OutputDirectory 'probe-install'
        $fixtureInstalls.Add($probeInstall)
        $probeWork = Join-Path $allowed 'probe-work'
        & $installer -InstallDirectory $probeInstall -AllowedRoot $allowed -WorkDirectory $probeWork | Out-Null
        $config = Join-Path $probeInstall 'config.json'
        $probeConfig = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
        Assert-True ($probeConfig.backupDirectory -eq (Join-Path $probeInstall 'recovery')) 'Initial config does not use final recovery directory.'
        & (Join-Path $probeInstall 'bin\prunlet.exe') --config $config operations | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) 'Core rejected actual installed configuration.'
        Assert-True (!(Test-Path -LiteralPath $probeWork)) 'Work inside allowed root was not cleaned.'
    }
} finally {
    Remove-Item Function:\Invoke-RestMethod, Function:\Invoke-WebRequest, Function:\Copy-Item
    Remove-Variable PrunletLatestFixture -Scope Global
    # 検証インストールの更新バックアップだけを検証済み絶対パスから清掃する。
    $backupParent = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Codex\TaskArtifacts\Prunlet'
    Get-ChildItem -LiteralPath $backupParent -Directory -Filter 'install-*' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notin $beforeBackups } | ForEach-Object {
        $manifest = Join-Path $_.FullName 'backup-info.json'
        if (!(Test-Path -LiteralPath $manifest)) { $manifest = Join-Path $_.FullName 'profile-backup-info.json' }
        if ((Test-Path -LiteralPath $manifest) -and ((Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).installDirectory -in $fixtureInstalls) -and !($_.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
    }
    [ordered]@{ verifiedUtc = [DateTimeOffset]::UtcNow.ToString('o'); failureConditions = $failureConditions; results = @($results.ToArray()); passed = !@($results | Where-Object { !$_.passed }).Count; retention = 'Keep this report as reproducible installer verification evidence; delete when superseded.'; reproduce = 'Run scripts/Verify-LatestInstall.ps1 with new external OutputDirectory and ReportPath.' } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM
}
Get-Content -LiteralPath $ReportPath -Raw
if (@($results | Where-Object { !$_.passed }).Count) { throw 'Latest installer verification failed; read the JSON report.' }
