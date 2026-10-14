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
$fixtureUpdateBackupRoot = Join-Path $OutputDirectory 'update-backups'
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
$failureConditions = @('フォルダー未登録の初回導入が拒否される', '旧rootsが削除範囲へ再適用される', '無効repository', '外部保存先違反またはリンク', 'ネットワーク取得失敗', '公開HEADに必要ソース欠落', 'ZIP traversal/重複/リンク', 'ビルド失敗', '製品ファイル更新失敗', '登録時既存設定の拒否', 'Codex登録の2ファイル間での書込み失敗', '旧roots内外の作業場所と復元先の検証', '指示登録オプションの組合せ不備', '指示marker重複・不完全・利用者編集', 'guide既存未所有・利用者編集', '指示登録途中での書込み失敗')
Test-Case 'Agent instructions require explicit Codex registration' {
    Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -AllowedRoot $allowed -RegisterAgentInstructions } 'requires explicit -RegisterCodex'
}
Test-Case 'Invalid repository stops before download' {
    Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -Repository '../Prunlet' -InstallDirectory $install -AllowedRoot $allowed } 'Repository must'
}
Test-Case 'Repository output and linked install paths are refused' {
    Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory (Join-Path $repoRoot 'should-not-exist') -AllowedRoot $allowed } 'outside repositories'
    $linked = Join-Path $OutputDirectory 'linked-install'
    New-Item -ItemType Junction -Path $linked -Target $allowed | Out-Null
    try { Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $linked -AllowedRoot $allowed } 'cannot traverse links' }
    finally { Remove-Item -LiteralPath $linked }
}
Test-Case 'Update backup root cannot be inside a repository or installation' {
    Expect-Failure { & $installer -UpdateBackupRoot $repoRoot -InstallDirectory $install -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'backup-repo-work') } 'outside repositories'
    Expect-Failure { & $installer -UpdateBackupRoot (Join-Path $install 'updates') -InstallDirectory $install -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'backup-install-work') } 'separate from install'
    Assert-True (!(Test-Path -LiteralPath $install)) 'Invalid update backup root created installation files.'
}
if ($CheckPublicHead) {
    Test-Case 'Public default branch is queried without clone fallback' {
        $publicInstall = Join-Path $OutputDirectory 'public-install'
        try {
            & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $publicInstall -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'public-work') | Out-Null
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
    if ($global:PrunletLatestFixture.failCopy -and $Destination -eq (Join-Path $install 'bin\install-codex.ps1')) {
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
$beforeBackups = @(Get-ChildItem -LiteralPath $fixtureUpdateBackupRoot -Directory -Filter 'install-*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
try {
    Test-Case 'Download failure preserves initial boundary' {
        $global:PrunletLatestFixture.failDownload = $true
        try { Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'network-work') } 'Fixture network failure' }
        finally { $global:PrunletLatestFixture.failDownload = $false }
        Assert-True (!(Test-Path -LiteralPath $install)) 'Download failure created install files.'
    }
    Test-Case 'ZIP traversal is rejected before mutation' {
        $badZip = Join-Path $OutputDirectory 'unsafe.zip'
        $z = [IO.Compression.ZipFile]::Open($badZip, [IO.Compression.ZipArchiveMode]::Create)
        try { [void]$z.CreateEntry('root/../escaped.txt') } finally { $z.Dispose() }
        $global:PrunletLatestFixture.zip = $badZip
        try { Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'unsafe-work') } 'Unsafe archive path' }
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
            try { Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory "$kind-work") } 'Duplicate archive path|Archive links or special files' }
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
            Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'broken-work') } 'Fixture publish failure'
        } finally { [IO.File]::WriteAllText($publishScript, $originalPublish); $global:PrunletLatestFixture.zip = $zipPath }
        Assert-True (!(Test-Path -LiteralPath $install)) 'Build failure created install files.'
    }
    Test-Case 'Latest fixture installs without target registration and protects recovery storage' {
        & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -RegisterCodex -CodexHome $isolatedCodex -SettingsBackupDirectory $settingsBackup -WorkDirectory (Join-Path $OutputDirectory 'first-work') | Out-Null
        $info = Get-Content -LiteralPath (Join-Path $install 'source-info.json') -Raw | ConvertFrom-Json
        Assert-True ($info.commitSha -eq ('a' * 40)) 'Initial provenance mismatch.'
        Assert-True ($info.executableSha256 -eq (Get-FileHash -LiteralPath (Join-Path $install 'bin\prunlet.exe')).Hash) 'Executable provenance hash mismatch.'
        $toml = Get-Content -LiteralPath (Join-Path $isolatedCodex 'config.toml') -Raw
        $hooks = Get-Content -LiteralPath (Join-Path $isolatedCodex 'hooks.json') -Raw
        Assert-True (!$toml.Contains($repoRoot) -and !$hooks.Contains($repoRoot) -and !$toml.Contains($fixtureRoot) -and !$hooks.Contains($fixtureRoot)) 'Registration references checkout source.'
        Assert-True ($toml.Contains('bin\\prunlet.exe')) 'Registration does not use installed bin.'
        Assert-True (!(Test-Path -LiteralPath (Join-Path $OutputDirectory 'first-work'))) 'Successful work was not cleaned.'
        Assert-True (!(Test-Path -LiteralPath (Join-Path $isolatedCodex 'AGENTS.md')) -and !(Test-Path -LiteralPath (Join-Path $isolatedCodex 'PRUNLET.md'))) 'Without the flag agent instructions were written.'
        $installedExe = Join-Path $install 'bin\prunlet.exe'
        $installedConfig = Join-Path $install 'config.json'
        $target = Join-Path $OutputDirectory 'unregistered-install-target.txt'
        [IO.File]::WriteAllText($target, 'unregistered install target')
        $deleted = (& $installedExe --config $installedConfig delete -- $target | ConvertFrom-Json)
        Assert-True ($LASTEXITCODE -eq 0 -and ![IO.File]::Exists($target)) 'Installed CLI requires target registration.'
        $restored = (& $installedExe --config $installedConfig restore $deleted.operationId | ConvertFrom-Json)
        Assert-True ($LASTEXITCODE -eq 0 -and [IO.File]::ReadAllText($target) -eq 'unregistered install target') 'Installed unrestricted restore differs.'
        $protected = Join-Path $install 'recovery\protected-install-target.txt'
        [IO.File]::WriteAllText($protected, 'keep recovery storage')
        $null = & $installedExe --config $installedConfig delete -- $protected
        Assert-True ($LASTEXITCODE -ne 0 -and [IO.File]::ReadAllText($protected) -eq 'keep recovery storage') 'Installed CLI deletes from its own recovery storage.'
    }
    Test-Case 'Next install resolves new HEAD and preserves legacy config and recovery' {
        $legacyConfigPath = Join-Path $install 'config.json'
        $legacyConfig = Get-Content -LiteralPath $legacyConfigPath -Raw | ConvertFrom-Json
        $legacyConfig.allowedRoots = @((Join-Path $OutputDirectory 'nonexistent-legacy-root'))
        [IO.File]::WriteAllText($legacyConfigPath, ($legacyConfig | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        $configHash = (Get-FileHash -LiteralPath $legacyConfigPath).Hash
        $recoveryMarker = Join-Path $install 'recovery\user-marker.txt'
        Set-Content -LiteralPath $recoveryMarker -Value 'Keep user recovery data.' -Encoding utf8NoBOM
        $markerHash = (Get-FileHash -LiteralPath $recoveryMarker).Hash
        $global:PrunletLatestFixture.sha = 'b' * 40
        & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -RegisterCodex -CodexHome $isolatedCodex -SettingsBackupDirectory $settingsBackup -WorkDirectory (Join-Path $OutputDirectory 'second-work') | Out-Null
        $info = Get-Content -LiteralPath (Join-Path $install 'source-info.json') -Raw | ConvertFrom-Json
        Assert-True ($info.commitSha -eq ('b' * 40)) 'Update reused old HEAD.'
        Assert-True ($configHash -eq (Get-FileHash -LiteralPath (Join-Path $install 'config.json')).Hash) 'Update rewrote config.'
        Assert-True ($markerHash -eq (Get-FileHash -LiteralPath $recoveryMarker).Hash) 'Update rewrote recovery.'
    }
    Test-Case 'Partial product write failure rolls back all product files' {
        $before = Snapshot-Install
        $global:PrunletLatestFixture.sha = 'c' * 40
        $global:PrunletLatestFixture.failCopy = $true
        Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -WorkDirectory (Join-Path $OutputDirectory 'rollback-work') } 'Fixture product write failure'
        Assert-Snapshot $before
    }
    Test-Case 'Codex refusal preserves installed products and configuration' {
        $before = Snapshot-Install
        $blockedCodex = Join-Path $OutputDirectory 'blocked-codex'
        New-Item -ItemType Directory -Path $blockedCodex | Out-Null
        $toml = Join-Path $blockedCodex 'config.toml'
        Set-Content -LiteralPath $toml -Value "[features]`nhooks = false`n" -Encoding utf8NoBOM
        $tomlHash = (Get-FileHash -LiteralPath $toml).Hash
        Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -RegisterCodex -CodexHome $blockedCodex -SettingsBackupDirectory $settingsBackup -WorkDirectory (Join-Path $OutputDirectory 'refused-work') } 'features.hooks is false'
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
                Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $partialInstall -AllowedRoot $allowed -RegisterCodex -CodexHome $partialCodex -SettingsBackupDirectory $partialSettingsBackup -WorkDirectory (Join-Path $OutputDirectory "partial-work-$hookState") } 'WriteAllText'
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
        & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $probeInstall -AllowedRoot $allowed -WorkDirectory $probeWork | Out-Null
        $config = Join-Path $probeInstall 'config.json'
        $probeConfig = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
        Assert-True ($probeConfig.backupDirectory -eq (Join-Path $probeInstall 'recovery')) 'Initial config does not use final recovery directory.'
        & (Join-Path $probeInstall 'bin\prunlet.exe') --config $config operations | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) 'Core rejected actual installed configuration.'
        Assert-True (!(Test-Path -LiteralPath $probeWork)) 'Work inside allowed root was not cleaned.'
    }
    $instructionInstall = Join-Path $OutputDirectory 'instruction-install'
    $fixtureInstalls.Add($instructionInstall)
    $instructionCodex = Join-Path $OutputDirectory 'instruction-codex'
    $instructionBackup = Join-Path $OutputDirectory 'instruction-backup'
    New-Item -ItemType Directory -Path $instructionCodex | Out-Null
    $instructionAgents = Join-Path $instructionCodex 'AGENTS.md'
    $instructionGuide = Join-Path $instructionCodex 'PRUNLET.md'
    $originalAgentText = "# Existing contract`r`nKeep this body.`r`n`r`n## Lessons`r`nExisting lessons.`r`n"
    [IO.File]::WriteAllText($instructionAgents, $originalAgentText, [Text.UTF8Encoding]::new($true))
    $originalAgentHash = (Get-FileHash -LiteralPath $instructionAgents).Hash
    $trustPath = Join-Path $instructionCodex 'unrelated-trust-fixture.json'
    [IO.File]::WriteAllText($trustPath, '{"trusted":false,"keep":true}', [Text.UTF8Encoding]::new($false))
    $trustHash = (Get-FileHash -LiteralPath $trustPath).Hash
    Test-Case 'Instruction opt-in preserves BOM/body and prepends before Lessons' {
        & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $instructionInstall -AllowedRoot $allowed -RegisterCodex -RegisterAgentInstructions -CodexHome $instructionCodex -SettingsBackupDirectory $instructionBackup -WorkDirectory (Join-Path $OutputDirectory 'instruction-first-work') | Out-Null
        $agentText = [IO.File]::ReadAllText($instructionAgents)
        Assert-True ($agentText.StartsWith('<!-- BEGIN PRUNLET AGENT-INSTRUCTIONS -->', [StringComparison]::Ordinal)) 'Owned block is not at the document beginning.'
        Assert-True ($agentText.IndexOf('BEGIN PRUNLET AGENT-INSTRUCTIONS') -lt $agentText.IndexOf('## Lessons')) 'Owned block is not before Lessons.'
        Assert-True ($agentText.Contains('Prunlet CLIを最初からCMD（shell=cmd.exe、login=false）で直接実行する。')) 'Instruction does not select the CLI first.'
        $bindingMatch = [regex]::Match($agentText, '(?m)^Prunlet CLI: (\{[^\r\n]*\})\r?$')
        Assert-True $bindingMatch.Success 'Installed CLI binding is absent.'
        $binding = $bindingMatch.Groups[1].Value | ConvertFrom-Json
        Assert-True ($binding.executablePath -ceq (Join-Path $instructionInstall 'bin\prunlet.exe') -and $binding.configPath -ceq (Join-Path $instructionInstall 'config.json')) 'CLI binding does not refer to the installed product.'
        Assert-True ([IO.File]::ReadAllText($instructionGuide).Contains('--paths-file')) 'Guide omits literal paths-file input.'
        $withoutBlock = [regex]::Replace($agentText, '<!-- BEGIN PRUNLET AGENT-INSTRUCTIONS -->\r\n[\s\S]*?\r\n<!-- END PRUNLET AGENT-INSTRUCTIONS -->\r\n', '')
        Assert-True ($withoutBlock -ceq $originalAgentText) 'Existing AGENTS body or newlines changed.'
        $bytes = [IO.File]::ReadAllBytes($instructionAgents)
        Assert-True ($bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) 'UTF8 BOM was removed.'
        Assert-True ((Get-FileHash -LiteralPath $instructionGuide).Hash -eq (Get-FileHash -LiteralPath (Join-Path $instructionInstall 'bin\PRUNLET.md')).Hash) 'Registered guide differs from installed guide.'
        Assert-True ((Get-FileHash -LiteralPath $trustPath).Hash -eq $trustHash) 'Unrelated host trust data changed.'
    }

    Test-Case 'Custom CLI binding uninstalls with the registered paths and preserves existing content' {
        $customCodex = Join-Path $OutputDirectory 'custom-binding-codex'
        $customProduct = Join-Path $OutputDirectory 'custom-binding-product'
        New-Item -ItemType Directory -Path $customCodex, $customProduct | Out-Null
        $customExe = Join-Path $customProduct 'custom-prunlet.exe'
        $customConfig = Join-Path $customProduct 'custom-config.json'
        Copy-Item -LiteralPath (Join-Path $instructionInstall 'bin\prunlet.exe') -Destination $customExe
        Copy-Item -LiteralPath (Join-Path $instructionInstall 'config.json') -Destination $customConfig
        $customAgents = Join-Path $customCodex 'AGENTS.md'
        [IO.File]::WriteAllText($customAgents, $originalAgentText, [Text.UTF8Encoding]::new($true))
        $original = (Get-FileHash -LiteralPath $customAgents).Hash
        $customHooks = Join-Path $customCodex 'hooks.json'
        [IO.File]::WriteAllText($customHooks, '{"userValue":"keep","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo keep-custom-hook"}]}]}}')
        $customParameters = @{ ExecutablePath = $customExe; ConfigPath = $customConfig; CodexHome = $customCodex; BackupDirectory = $instructionBackup }
        & (Join-Path $instructionInstall 'bin\install-codex.ps1') @customParameters | Out-Null
        & (Join-Path $instructionInstall 'bin\install-agent-instructions.ps1') @customParameters | Out-Null
        $text = [IO.File]::ReadAllText($customAgents)
        $binding = [regex]::Match($text, '(?m)^Prunlet CLI: (\{[^\r\n]*\})\r?$').Groups[1].Value | ConvertFrom-Json
        Assert-True ($binding.executablePath -ceq $customExe -and $binding.configPath -ceq $customConfig) 'Custom CLI paths were not registered.'
        & (Join-Path $instructionInstall 'bin\uninstall-codex.ps1') @customParameters | Out-Null
        Assert-True ((Get-FileHash -LiteralPath $customAgents).Hash -eq $original) 'Custom uninstall changed the existing AGENTS bytes.'
        Assert-True (!(Test-Path -LiteralPath (Join-Path $customCodex 'PRUNLET.md'))) 'Custom uninstall retained the owned guide.'
        $remaining = [IO.File]::ReadAllText($customHooks) | ConvertFrom-Json
        Assert-True ($remaining.userValue -ceq 'keep' -and $remaining.hooks.PreToolUse.Count -eq 1 -and $remaining.hooks.PreToolUse[0].hooks[0].command -ceq 'echo keep-custom-hook') 'Custom uninstall changed the unrelated hook.'
        Assert-True (Test-Path -LiteralPath $customExe -PathType Leaf) 'Uninstall removed the custom executable.'
        Assert-True (Test-Path -LiteralPath $customConfig -PathType Leaf) 'Uninstall removed the custom config.'
    }
    Test-Case 'Owned MCP-first instructions upgrade to CLI binding without changing the body' {
        $legacyInstall = Join-Path $OutputDirectory 'legacy-instruction-install'
        $fixtureInstalls.Add($legacyInstall)
        $legacyCodex = Join-Path $OutputDirectory 'legacy-instruction-codex'
        New-Item -ItemType Directory -Path $legacyCodex | Out-Null
        & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $legacyInstall -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'legacy-instruction-base-work') | Out-Null
        $obsoleteBackend = Join-Path $legacyInstall 'bin\codex-pretooluse.ps1'
        [IO.File]::WriteAllText($obsoleteBackend, '# Previous installed PowerShell backend fixture', [Text.UTF8Encoding]::new($false))
        $obsoleteHash = (Get-FileHash -LiteralPath $obsoleteBackend -Algorithm SHA256).Hash
        $legacyGuide = "<!-- Prunlet managed agent instructions -->`n# Previous guide`nUse Prunlet MCP first.`n"
        $legacyBytes = [Text.UTF8Encoding]::new($false).GetBytes($legacyGuide)
        [IO.File]::WriteAllBytes((Join-Path $legacyInstall 'bin\PRUNLET.md'), $legacyBytes)
        [IO.File]::WriteAllBytes((Join-Path $legacyCodex 'PRUNLET.md'), $legacyBytes)
        $legacyBlock = "<!-- BEGIN PRUNLET AGENT-INSTRUCTIONS -->`r`n" + 'Windowsのファイル削除では、[PRUNLET.md](PRUNLET.md)を読み、Prunlet MCPの`delete_files`を最初から使う。' + "`r`n<!-- END PRUNLET AGENT-INSTRUCTIONS -->`r`n"
        $legacyAgents = Join-Path $legacyCodex 'AGENTS.md'
        [IO.File]::WriteAllText($legacyAgents, $legacyBlock + $originalAgentText, [Text.UTF8Encoding]::new($true))
        $legacyResult = & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $legacyInstall -RegisterCodex -RegisterAgentInstructions -CodexHome $legacyCodex -SettingsBackupDirectory $instructionBackup -WorkDirectory (Join-Path $OutputDirectory 'legacy-instruction-upgrade-work') | ConvertFrom-Json
        Assert-True (@($legacyResult).Count -eq 1 -and $legacyResult.requiresHookTrust) 'Installer must emit one result including the hook trust requirement.'
        Assert-True (!(Test-Path -LiteralPath $obsoleteBackend)) 'Upgrade retained the obsolete backend.'
        $retiredManifests = @(Get-ChildItem -LiteralPath (Join-Path $legacyResult.updateBackupDirectory 'retired-recovery') -Filter 'manifest.json' -File -Recurse)
        Assert-True ($retiredManifests.Count -eq 1) 'Retirement has no unique recovery operation.'
        $retired = [IO.File]::ReadAllText($retiredManifests[0].FullName) | ConvertFrom-Json
        Assert-True ($retired.items[0].path -ieq $obsoleteBackend -and $retired.items[0].sha256 -ieq $obsoleteHash) 'Retirement manifest does not match the old backend.'
        $retiredCopy = Join-Path $retiredManifests[0].DirectoryName '0000.bak'
        Assert-True ((Get-FileHash -LiteralPath $retiredCopy -Algorithm SHA256).Hash -eq $obsoleteHash) 'Obsolete backend recovery copy is not verified.'
        $updated = [IO.File]::ReadAllText($legacyAgents)
        Assert-True ($updated.Contains('Prunlet CLIを最初からCMD（shell=cmd.exe、login=false）で直接実行する。')) 'Legacy instructions did not migrate.'
        Assert-True (!$updated.Contains('Prunlet MCPの`delete_files`を最初から使う。')) 'Legacy normal route survived migration.'
        $remaining = [regex]::Replace($updated, '^<!-- BEGIN PRUNLET AGENT-INSTRUCTIONS -->\r\n[\s\S]*?\r\n<!-- END PRUNLET AGENT-INSTRUCTIONS -->\r\n', '')
        Assert-True ($remaining -ceq $originalAgentText) 'Legacy migration changed the existing body.'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $legacyCodex 'PRUNLET.md')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $legacyInstall 'bin\PRUNLET.md')).Hash) 'Legacy guide did not migrate from the previous installed hash.'
        $before = (Get-FileHash -LiteralPath $legacyAgents).Hash
        & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $legacyInstall -RegisterCodex -RegisterAgentInstructions -CodexHome $legacyCodex -SettingsBackupDirectory $instructionBackup -WorkDirectory (Join-Path $OutputDirectory 'legacy-instruction-repeat-work') | Out-Null
        Assert-True ((Get-FileHash -LiteralPath $legacyAgents).Hash -eq $before) 'Migrated instructions were not idempotent.'
    }
    Test-Case 'File-only CLI instructions migrate to folder route without changing binding or body' {
        $fileCliHome = Join-Path $OutputDirectory 'file-cli-codex'
        New-Item -ItemType Directory -Path $fileCliHome | Out-Null
        $fileCliAgents = Join-Path $fileCliHome 'AGENTS.md'
        $fileCliGuide = Join-Path $fileCliHome 'PRUNLET.md'
        $fileCliBinding = 'Prunlet CLI: ' + ([ordered]@{ executablePath = (Join-Path $instructionInstall 'bin\prunlet.exe'); configPath = (Join-Path $instructionInstall 'config.json') } | ConvertTo-Json -Compress)
        $fileCliBody = "# Existing user body
Preserve this content.
"
        $fileCliOld = "<!-- BEGIN PRUNLET AGENT-INSTRUCTIONS -->
Windowsのファイル削除では、[PRUNLET.md](PRUNLET.md)を読み、Prunlet CLIを最初からCMD（shell=cmd.exe、login=false）で直接実行する。
" + $fileCliBinding + "
<!-- END PRUNLET AGENT-INSTRUCTIONS -->
" + $fileCliBody
        [IO.File]::WriteAllText($fileCliAgents, $fileCliOld, [Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText($fileCliGuide, "<!-- Prunlet managed agent instructions -->
# Previous file-only guide
", [Text.UTF8Encoding]::new($false))
        $fileCliOldHash = (Get-FileHash -LiteralPath $fileCliGuide -Algorithm SHA256).Hash
        & (Join-Path $repoRoot 'integration\install-agent-instructions.ps1') -SourceGuidePath (Join-Path $instructionInstall 'bin\PRUNLET.md') -PreviousGuideSha256 $fileCliOldHash -ExecutablePath (Join-Path $instructionInstall 'bin\prunlet.exe') -ConfigPath (Join-Path $instructionInstall 'config.json') -CodexHome $fileCliHome -BackupDirectory (Join-Path $OutputDirectory 'file-cli-migration-backup') | Out-Null
        $updated = [IO.File]::ReadAllText($fileCliAgents)
        Assert-True ($updated.Contains('Windowsのファイル・フォルダー削除では')) 'File-only CLI block did not migrate.'
        $afterBody = [regex]::Replace($updated, '<!-- BEGIN PRUNLET AGENT-INSTRUCTIONS -->[\s\S]*?<!-- END PRUNLET AGENT-INSTRUCTIONS -->\r?\n', '')
        Assert-True ($fileCliBody -ceq $afterBody) 'CLI migration changed the existing body.'
        Assert-True ($updated.Contains($fileCliBinding)) 'CLI migration changed the executable/config binding.'
        $updatedBytes = [IO.File]::ReadAllBytes($fileCliAgents)
        Assert-True ($updatedBytes[0] -eq 0xef -and $updatedBytes[1] -eq 0xbb -and $updatedBytes[2] -eq 0xbf) 'CLI migration changed the BOM.'
    }
    Test-Case 'Explicit CMD hook migrates three owned routes and preserves unrelated handlers' {
        $exePath = Join-Path $instructionInstall 'bin\prunlet.exe'
        $cfgPath = Join-Path $instructionInstall 'config.json'
        $oldHelper = Join-Path $instructionInstall 'bin\codex-pretooluse.ps1'
        $nativeCommand = 'call "' + $exePath + '" --config "' + $cfgPath + '" hook'
        $cmdPath = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
        $expectedCommand = $cmdPath + ' /d /c ' + $nativeCommand
        $legacyCommands = @($nativeCommand, ($nativeCommand + ' --hook-script "' + $oldHelper + '"'), ('pwsh -NoProfile -NonInteractive -File "' + $oldHelper + '" -ExecutablePath "' + $exePath + '" -ConfigPath "' + $cfgPath + '"'))
        $route = 0
        foreach ($legacyCommand in $legacyCommands) {
            $migrationCodex = Join-Path $OutputDirectory ('native-hook-migration-codex-' + $route++)
            New-Item -ItemType Directory -Path $migrationCodex | Out-Null
            $migrationHooks = Join-Path $migrationCodex 'hooks.json'
            $unrelated = @{ matcher = 'Bash'; hooks = @(@{ type = 'command'; command = 'echo keep-user-hook' }) }
            $document = @{ userValue = 'keep'; hooks = @{ PreToolUse = @(@{ matcher = '^(Bash|exec_command|functions\.exec_command)$'; hooks = @(@{ type = 'command'; timeout = 10; statusMessage = 'Prunlet: protected literal deletion'; command = $legacyCommand }) }, $unrelated) } }
            [IO.File]::WriteAllText($migrationHooks, ($document | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            $registration = @{ ExecutablePath = $exePath; ConfigPath = $cfgPath; CodexHome = $migrationCodex; BackupDirectory = $instructionBackup }
            & (Join-Path $instructionInstall 'bin\install-codex.ps1') @registration | Out-Null
            $migrated = [IO.File]::ReadAllText($migrationHooks) | ConvertFrom-Json
            Assert-True ($migrated.hooks.PreToolUse[0].hooks[0].command -ceq $expectedCommand) 'Owned route did not migrate to explicit CMD entry.'
            Assert-True ($migrated.userValue -ceq 'keep' -and $migrated.hooks.PreToolUse[1].hooks[0].command -ceq 'echo keep-user-hook') 'Migration altered an unrelated handler.'
            $before = (Get-FileHash -LiteralPath $migrationHooks).Hash
            & (Join-Path $instructionInstall 'bin\install-codex.ps1') @registration | Out-Null
            Assert-True ((Get-FileHash -LiteralPath $migrationHooks).Hash -eq $before) 'Explicit CMD registration was not idempotent.'
            $unchanged = [IO.File]::ReadAllText($migrationHooks)
            foreach ($kind in @('timeout', 'type', 'matcher')) {
                $migrated = $unchanged | ConvertFrom-Json
                switch ($kind) {
                    'timeout' { $migrated.hooks.PreToolUse[0].hooks[0].timeout = 11 }
                    'type' { $migrated.hooks.PreToolUse[0].hooks[0].type = 'user-edited' }
                    'matcher' { $migrated.hooks.PreToolUse[0].matcher = 'user-edited' }
                }
                [IO.File]::WriteAllText($migrationHooks, ($migrated | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
                $edited = (Get-FileHash -LiteralPath $migrationHooks).Hash
                Expect-Failure { & (Join-Path $instructionInstall 'bin\install-codex.ps1') @registration } 'was edited'
                Assert-True ((Get-FileHash -LiteralPath $migrationHooks).Hash -eq $edited) 'Edited handler was changed.'
            }
        }
    }
    Test-Case 'Hook registration rejects PowerShell expansion paths before changing Codex files' {
        $specialRoot = Join-Path $OutputDirectory 'hook-expansion-paths'
        New-Item -ItemType Directory -Path $specialRoot | Out-Null
        foreach ($configName in @('config$dollar.json', 'config`tick.json')) {
            $specialConfig = Join-Path $specialRoot $configName
            Copy-Item -LiteralPath (Join-Path $instructionInstall 'config.json') -Destination $specialConfig
            $specialHome = Join-Path $specialRoot ($configName + '-home')
            New-Item -ItemType Directory -Path $specialHome | Out-Null
            [IO.File]::WriteAllText((Join-Path $specialHome 'config.toml'), "# User-owned configuration`r`n[features]`r`nhooks = true`r`n", [Text.UTF8Encoding]::new($true))
            [IO.File]::WriteAllText((Join-Path $specialHome 'hooks.json'), '{"userValue":"preserve","hooks":{"PreToolUse":[]}}', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $specialHome 'AGENTS.md'), $originalAgentText, [Text.UTF8Encoding]::new($true))
            $before = @{}
            Get-ChildItem -LiteralPath $specialHome -File | ForEach-Object { $before[$_.FullName] = (Get-FileHash -LiteralPath $_.FullName).Hash }
            Expect-Failure { & (Join-Path $instructionInstall 'bin\install-codex.ps1') -ExecutablePath (Join-Path $instructionInstall 'bin\prunlet.exe') -ConfigPath $specialConfig -CodexHome $specialHome -BackupDirectory $instructionBackup } 'expansion characters'
            Assert-True (@(Get-ChildItem -LiteralPath $specialHome -File).Count -eq $before.Count) 'Rejected hook registration added Codex files.'
            foreach ($file in $before.Keys) { Assert-True ((Get-FileHash -LiteralPath $file).Hash -eq $before[$file]) 'Rejected expansion path changed Codex bytes.' }
        }
    }
    Test-Case 'Registered hook starts from inherited PowerShell and CMD and denies raw deletion' {
        $hooks = [IO.File]::ReadAllText((Join-Path $instructionCodex 'hooks.json')) | ConvertFrom-Json
        $registeredCommand = @($hooks.hooks.PreToolUse | ForEach-Object { $_.hooks } | Where-Object { $_.statusMessage -eq 'Prunlet: protected literal deletion' })[0].command
        # 空白配置も手書きcommandではなく、本物の登録builderを通す。
        $spaceProduct = Join-Path $OutputDirectory 'runtime space'
        $spaceCodex = Join-Path $OutputDirectory 'space-hook-codex'
        New-Item -ItemType Directory -Path $spaceProduct, $spaceCodex | Out-Null
        $spaceExe = Join-Path $spaceProduct 'prunlet.exe'
        $spaceConfig = Join-Path $spaceProduct 'config space.json'
        Copy-Item -LiteralPath (Join-Path $instructionInstall 'bin\prunlet.exe') -Destination $spaceExe
        Copy-Item -LiteralPath (Join-Path $instructionInstall 'config.json') -Destination $spaceConfig
        & (Join-Path $instructionInstall 'bin\install-codex.ps1') -ExecutablePath $spaceExe -ConfigPath $spaceConfig -CodexHome $spaceCodex -BackupDirectory $instructionBackup | Out-Null
        $spaceHooks = [IO.File]::ReadAllText((Join-Path $spaceCodex 'hooks.json')) | ConvertFrom-Json
        $spaceCommand = @($spaceHooks.hooks.PreToolUse | ForEach-Object { $_.hooks } | Where-Object { $_.statusMessage -eq 'Prunlet: protected literal deletion' })[0].command
        $spaceExpected = (Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe') + ' /d /c call "' + $spaceExe + '" --config "' + $spaceConfig + '" hook'
        Assert-True ($spaceCommand -ceq $spaceExpected) 'Space-path registration did not quote the installed exe and config exactly.'
        $launchVariants = @(@{ name = 'standard'; command = $registeredCommand }, @{ name = 'spaces'; command = $spaceCommand })
        $sentinel = Join-Path $allowed 'registered-hook-sentinel.txt'
        [IO.File]::WriteAllText($sentinel, 'Hook must not execute deletion.', [Text.UTF8Encoding]::new($false))
        $sentinelHash = (Get-FileHash -LiteralPath $sentinel).Hash
        $cmdPath = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
        $powerShellPath = (Get-Process -Id $PID).Path
        foreach ($variant in $launchVariants) {
            $registeredCommand = $variant.command
            foreach ($shell in @('PowerShell', 'CMD')) {
                foreach ($command in @(('del "' + $sentinel + '"'), 'echo harmless')) {
                    $event = @{ hook_event_name = 'PreToolUse'; tool_name = 'Bash'; tool_input = @{ command = $command } } | ConvertTo-Json -Depth 8 -Compress
                    $start = [Diagnostics.ProcessStartInfo]::new()
                    $start.FileName = if ($shell -eq 'CMD') { $cmdPath } else { $powerShellPath }
                    if ($shell -eq 'CMD') { $start.Arguments = '/d /c "' + $registeredCommand + '"' }
                    else {
                        foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', $registeredCommand)) { $start.ArgumentList.Add($argument) }
                    }
                    $start.UseShellExecute = $false
                    $start.CreateNoWindow = $true
                    $start.RedirectStandardInput = $true
                    $start.RedirectStandardOutput = $true
                    $start.RedirectStandardError = $true
                    $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
                    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
                    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
                    $runner = [Diagnostics.Process]::new()
                    $runner.StartInfo = $start
                    try {
                        Assert-True ($runner.Start()) 'Registered hook shell did not start.'
                        $outputTask = $runner.StandardOutput.ReadToEndAsync()
                        $errorTask = $runner.StandardError.ReadToEndAsync()
                        $runner.StandardInput.Write($event)
                        $runner.StandardInput.Close()
                        Assert-True ($runner.WaitForExit(10000)) 'Registered hook shell timed out.'
                        $output = $outputTask.GetAwaiter().GetResult()
                        $errorText = $errorTask.GetAwaiter().GetResult()
                        Assert-True ($runner.ExitCode -eq 0) ('Registered hook failed under ' + $variant.name + '/' + $shell + ': ' + $errorText)
                        $parsed = $output | ConvertFrom-Json -Depth 20
                        if ($command.StartsWith('del ')) { Assert-True ($parsed.hookSpecificOutput.permissionDecision -eq 'deny' -and !$parsed.hookSpecificOutput.updatedInput) ('Raw deletion was not denied under ' + $shell) }
                        else { Assert-True (!$parsed.hookSpecificOutput) ('Ordinary command was blocked under ' + $shell) }
                        Assert-True ((Get-FileHash -LiteralPath $sentinel).Hash -eq $sentinelHash) 'Hook caused a deletion or changed its sentinel.'
                    } finally { $runner.Dispose() }
                }
            }
        }
    }
    Test-Case 'Instruction registration is idempotent' {
        $agentHash = (Get-FileHash -LiteralPath $instructionAgents).Hash
        $guideHash = (Get-FileHash -LiteralPath $instructionGuide).Hash
        & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $instructionInstall -RegisterCodex -RegisterAgentInstructions -CodexHome $instructionCodex -SettingsBackupDirectory $instructionBackup -WorkDirectory (Join-Path $OutputDirectory 'instruction-idempotent-work') | Out-Null
        Assert-True ($agentHash -eq (Get-FileHash -LiteralPath $instructionAgents).Hash -and $guideHash -eq (Get-FileHash -LiteralPath $instructionGuide).Hash) 'Idempotent instruction registration rewrote contents.'
    }
    $updatedZip = Join-Path $OutputDirectory 'updated-guide-fixture.zip'
    $fixtureGuide = Join-Path $source 'integration\PRUNLET.md'
    [byte[]]$originalGuideBytes = [IO.File]::ReadAllBytes($fixtureGuide)
    try {
        [IO.File]::AppendAllText($fixtureGuide, "`nFixture guide update.`n", [Text.UTF8Encoding]::new($false))
        [IO.Compression.ZipFile]::CreateFromDirectory($fixtureRoot, $updatedZip)
    } finally { [IO.File]::WriteAllBytes($fixtureGuide, $originalGuideBytes) }
    $global:PrunletLatestFixture.zip = $updatedZip
    $global:PrunletLatestFixture.sha = 'd' * 40
    Test-Case 'Owned guide updates from its previous installed hash' {
        $agentHash = (Get-FileHash -LiteralPath $instructionAgents).Hash
        & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $instructionInstall -RegisterCodex -RegisterAgentInstructions -CodexHome $instructionCodex -SettingsBackupDirectory $instructionBackup -WorkDirectory (Join-Path $OutputDirectory 'instruction-update-work') | Out-Null
        Assert-True ([IO.File]::ReadAllText($instructionGuide).Contains('Fixture guide update.')) 'Owned guide did not update.'
        Assert-True ($agentHash -eq (Get-FileHash -LiteralPath $instructionAgents).Hash) 'Guide update changed existing AGENTS.'
    }
    Test-Case 'Update without instruction flag preserves existing edited guide' {
        [byte[]]$original = [IO.File]::ReadAllBytes($instructionGuide)
        try {
            [IO.File]::AppendAllText($instructionGuide, 'User edit preserved without opt-in.', [Text.UTF8Encoding]::new($false))
            $agentHash = (Get-FileHash -LiteralPath $instructionAgents).Hash
            $guideHash = (Get-FileHash -LiteralPath $instructionGuide).Hash
            & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $instructionInstall -RegisterCodex -CodexHome $instructionCodex -SettingsBackupDirectory $instructionBackup -WorkDirectory (Join-Path $OutputDirectory 'instruction-no-flag-work') | Out-Null
            Assert-True ($agentHash -eq (Get-FileHash -LiteralPath $instructionAgents).Hash -and $guideHash -eq (Get-FileHash -LiteralPath $instructionGuide).Hash) 'Update without the flag touched agent instructions.'
        } finally { [IO.File]::WriteAllBytes($instructionGuide, $original) }
    }
    Test-Case 'Edited instructions and guide reject install and uninstall before writes' {
        $paths = @($instructionAgents, $instructionGuide, (Join-Path $instructionCodex 'config.toml'), (Join-Path $instructionCodex 'hooks.json'))
        foreach ($kind in @('block', 'guide')) {
            $target = if ($kind -eq 'block') { $instructionAgents } else { $instructionGuide }
            [byte[]]$original = [IO.File]::ReadAllBytes($target)
            try {
                if ($kind -eq 'block') {
                    $beforeEdit = [IO.File]::ReadAllText($target)
                    $afterEdit = $beforeEdit.Replace('Prunlet CLIを最初からCMD（shell=cmd.exe、login=false）で直接実行する。', '利用者が編集した内容。')
                    Assert-True ($afterEdit -cne $beforeEdit) 'Edited-block fixture did not alter the managed instruction.'
                    [IO.File]::WriteAllText($target, $afterEdit, [Text.UTF8Encoding]::new($true))
                }
                else { [IO.File]::AppendAllText($target, 'User guide edit.', [Text.UTF8Encoding]::new($false)) }
                $hashes = @{}; foreach ($path in $paths) { $hashes[$path] = (Get-FileHash -LiteralPath $path).Hash }
                Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $instructionInstall -RegisterCodex -RegisterAgentInstructions -CodexHome $instructionCodex -SettingsBackupDirectory $instructionBackup -WorkDirectory (Join-Path $OutputDirectory "edited-$kind-work") } 'was edited'
                Expect-Failure { & (Join-Path $instructionInstall 'bin\uninstall-codex.ps1') -CodexHome $instructionCodex -BackupDirectory $instructionBackup } 'was edited'
                foreach ($path in $paths) { Assert-True ($hashes[$path] -eq (Get-FileHash -LiteralPath $path).Hash) 'Edited profile changed despite rejection.' }
            } finally { [IO.File]::WriteAllBytes($target, $original) }
        }
    }
    Test-Case 'Instruction write failure rolls back MCP hooks and four profile files' {
        $lockedInstall = Join-Path $OutputDirectory 'instruction-locked-install'
        $fixtureInstalls.Add($lockedInstall)
        $lockedCodex = Join-Path $OutputDirectory 'instruction-locked-codex'
        New-Item -ItemType Directory -Path $lockedCodex | Out-Null
        $lockedAgents = Join-Path $lockedCodex 'AGENTS.md'
        [IO.File]::WriteAllText($lockedAgents, "Keep original contract.`n", [Text.UTF8Encoding]::new($false))
        $agentHash = (Get-FileHash -LiteralPath $lockedAgents).Hash
        $lock = [IO.File]::Open($lockedAgents, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $lockedInstall -AllowedRoot $allowed -RegisterCodex -RegisterAgentInstructions -CodexHome $lockedCodex -SettingsBackupDirectory $instructionBackup -WorkDirectory (Join-Path $OutputDirectory 'instruction-locked-work') } 'WriteAllBytes'
            Assert-True ($agentHash -eq (Get-FileHash -LiteralPath $lockedAgents).Hash) 'Locked original AGENTS changed.'
            foreach ($name in @('PRUNLET.md','hooks.json','config.toml')) { Assert-True (!(Test-Path -LiteralPath (Join-Path $lockedCodex $name))) "Failed registration left $name." }
            Assert-True (!(Test-Path -LiteralPath $lockedInstall)) 'Instruction failure left initial products/config/recovery.'
        } finally { $lock.Dispose() }
    }
    Test-Case 'Malformed markers and unowned guides are preserved' {
        $helper = Join-Path $instructionInstall 'bin\install-agent-instructions.ps1'
        foreach ($kind in @('duplicate','incomplete','unowned-guide')) {
            $invalidCodex = Join-Path $OutputDirectory "instruction-invalid-$kind"
            New-Item -ItemType Directory -Path $invalidCodex | Out-Null
            $badAgents = Join-Path $invalidCodex 'AGENTS.md'
            $badGuide = Join-Path $invalidCodex 'PRUNLET.md'
            if ($kind -eq 'unowned-guide') { [IO.File]::WriteAllText($badGuide, 'User-owned guide.') }
            else { [IO.File]::WriteAllText($badAgents, $(if ($kind -eq 'duplicate') { '<!-- BEGIN PRUNLET AGENT-INSTRUCTIONS --><!-- BEGIN PRUNLET AGENT-INSTRUCTIONS -->' } else { '<!-- BEGIN PRUNLET AGENT-INSTRUCTIONS' })) }
            $before = @{}; Get-ChildItem -LiteralPath $invalidCodex -File | ForEach-Object { $before[$_.FullName] = (Get-FileHash -LiteralPath $_.FullName).Hash }
            Expect-Failure { & $helper -SourceGuidePath (Join-Path $instructionInstall 'bin\PRUNLET.md') -CodexHome $invalidCodex -BackupDirectory $instructionBackup } 'Duplicate or incomplete|no owned agent'
            foreach ($path in $before.Keys) { Assert-True ($before[$path] -eq (Get-FileHash -LiteralPath $path).Hash) 'Invalid instruction files were changed.' }
        }
    }
    Test-Case 'Instruction uninstall restores original AGENTS bytes and removes owned guide' {
        & (Join-Path $instructionInstall 'bin\uninstall-codex.ps1') -CodexHome $instructionCodex -BackupDirectory $instructionBackup | Out-Null
        Assert-True ((Get-FileHash -LiteralPath $instructionAgents).Hash -eq $originalAgentHash) 'Uninstall did not restore exact original AGENTS bytes.'
        Assert-True (!(Test-Path -LiteralPath $instructionGuide)) 'Uninstall retained owned guide.'
        Assert-True (![IO.File]::ReadAllText((Join-Path $instructionCodex 'config.toml')).Contains('[mcp_servers.prunlet]')) 'Uninstall retained owned MCP entry.'
        Assert-True ((Get-FileHash -LiteralPath $trustPath).Hash -eq $trustHash) 'Uninstall changed unrelated host trust data.'
        # ガイドもmarkerもないときは従来の解除を冪等に実行する。
        & (Join-Path $instructionInstall 'bin\uninstall-codex.ps1') -CodexHome $instructionCodex -BackupDirectory $instructionBackup | Out-Null
        Assert-True ((Get-FileHash -LiteralPath $instructionAgents).Hash -eq $originalAgentHash) 'Legacy uninstall changed unrelated AGENTS.'
    }
    Test-Case 'Instruction roundtrip preserves BOM encodings and no-Lessons EOF bytes' {
        foreach ($kind in @('utf8','utf16','utf32')) {
            $encodingCodex = Join-Path $OutputDirectory "instruction-encoding-$kind"
            New-Item -ItemType Directory -Path $encodingCodex | Out-Null
            $agentPath = Join-Path $encodingCodex 'AGENTS.md'
            $encoding = switch ($kind) {
                'utf8' { [Text.UTF8Encoding]::new($false) }
                'utf16' { [Text.UnicodeEncoding]::new($false, $true) }
                'utf32' { [Text.UTF32Encoding]::new($true, $true) }
            }
            [IO.File]::WriteAllText($agentPath, "利用者の本文`n末尾に改行なし", $encoding)
            $originalHash = (Get-FileHash -LiteralPath $agentPath).Hash
            $helperParameters = @{ SourceGuidePath = (Join-Path $instructionInstall 'bin\PRUNLET.md'); CodexHome = $encodingCodex; BackupDirectory = $instructionBackup }
            & (Join-Path $instructionInstall 'bin\install-agent-instructions.ps1') @helperParameters | Out-Null
            & (Join-Path $instructionInstall 'bin\install-agent-instructions.ps1') @helperParameters -Uninstall | Out-Null
            Assert-True ($originalHash -eq (Get-FileHash -LiteralPath $agentPath).Hash) 'Instruction roundtrip changed original encoding or EOF.'
        }
    }
    Test-Case 'Prepended instructions stay outside EOF fences and fake Lessons code examples' {
        foreach ($kind in @('fence-eof', 'fake-lessons')) {
            $fencedCodex = Join-Path $OutputDirectory "instruction-fenced-$kind"
            New-Item -ItemType Directory -Path $fencedCodex | Out-Null
            $agentPath = Join-Path $fencedCodex 'AGENTS.md'
            $text = if ($kind -eq 'fence-eof') { "# Existing contract`n`n" + '```powershell' + "`nWrite-Output 'example'`n" + '```' }
                else { "# Existing contract`r`n`r`n" + '```markdown' + "`r`n## Lessons`r`nExample section in a code fence.`r`n" + '```' + "`r`nExisting body outside the example." }
            [IO.File]::WriteAllText($agentPath, $text, [Text.UTF8Encoding]::new($true))
            $originalHash = (Get-FileHash -LiteralPath $agentPath).Hash
            $helperParameters = @{ SourceGuidePath = (Join-Path $instructionInstall 'bin\PRUNLET.md'); CodexHome = $fencedCodex; BackupDirectory = $instructionBackup }
            & (Join-Path $instructionInstall 'bin\install-agent-instructions.ps1') @helperParameters | Out-Null
            $registered = [IO.File]::ReadAllText($agentPath)
            Assert-True ($registered.StartsWith('<!-- BEGIN PRUNLET AGENT-INSTRUCTIONS -->', [StringComparison]::Ordinal)) 'Owned block was inserted inside existing Markdown.'
            $html = (ConvertFrom-Markdown -InputObject $registered).Html
            $codeBlocks = [regex]::Matches($html, '(?s)<pre><code.*?</code></pre>')
            foreach ($codeBlock in $codeBlocks) { Assert-True (!$codeBlock.Value.Contains('Windowsのファイル・フォルダー削除では')) 'Agent instruction is inside a Markdown code block.' }
            $outsideCode = [regex]::Replace($html, '(?s)<pre><code.*?</code></pre>', '')
            Assert-True ($outsideCode.Contains('Windowsのファイル・フォルダー削除では')) 'Agent instruction is not rendered outside code examples.'
            Assert-True ($registered.EndsWith($text, [StringComparison]::Ordinal)) 'Registering instructions changed existing body or EOF bytes.'
            & (Join-Path $instructionInstall 'bin\install-agent-instructions.ps1') @helperParameters -Uninstall | Out-Null
            Assert-True ($originalHash -eq (Get-FileHash -LiteralPath $agentPath).Hash) 'Fenced document registration/removal did not restore original bytes.'
        }
    }
    $global:PrunletLatestFixture.zip = $zipPath
} finally {
    Remove-Item Function:\Invoke-RestMethod, Function:\Invoke-WebRequest, Function:\Copy-Item
    Remove-Variable PrunletLatestFixture -Scope Global
    # 検証インストールの更新バックアップだけを検証済み絶対パスから清掃する。
    $backupParent = $fixtureUpdateBackupRoot
    Get-ChildItem -LiteralPath $backupParent -Directory -Filter 'install-*' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notin $beforeBackups } | ForEach-Object {
        $manifest = Join-Path $_.FullName 'backup-info.json'
        if (!(Test-Path -LiteralPath $manifest)) { $manifest = Join-Path $_.FullName 'profile-backup-info.json' }
        if ((Test-Path -LiteralPath $manifest) -and ((Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).installDirectory -in $fixtureInstalls) -and !($_.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
    }
    [ordered]@{ verifiedUtc = [DateTimeOffset]::UtcNow.ToString('o'); failureConditions = $failureConditions; results = @($results.ToArray()); passed = !@($results | Where-Object { !$_.passed }).Count; retention = 'Keep this report as reproducible installer verification evidence; delete when superseded.'; reproduce = 'Run scripts/Verify-LatestInstall.ps1 with new external OutputDirectory and ReportPath.' } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM
}
Get-Content -LiteralPath $ReportPath -Raw
if (@($results | Where-Object { !$_.passed }).Count) { throw 'Latest installer verification failed; read the JSON report.' }
