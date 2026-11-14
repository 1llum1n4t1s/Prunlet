#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [string]$BuildManifestPath,
    [string]$ExpectedBuildManifestSha256,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [switch]$CheckPublicHead,
    [string]$FixtureRoot,
    [switch]$UseGitHubCliAuthentication
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
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
. (Join-Path $PSScriptRoot 'Verification-Fixture.ps1')
. (Join-Path $PSScriptRoot 'FixtureBridge.Common.ps1')
. (Join-Path $PSScriptRoot 'FileFixtures.Common.ps1')
$binding = @{ ExecutablePath = $ExecutablePath }
if ($BuildManifestPath) { $binding.BuildManifestPath = $BuildManifestPath }
if ($ExpectedBuildManifestSha256) { $binding.ExpectedBuildManifestSha256 = $ExpectedBuildManifestSha256 }
$null = Initialize-PrunletFixtureBinding @binding
$fileFixtureRun = if ($FixtureRoot) { New-VerificationFixtureRun -FixtureRoot $FixtureRoot -ForbiddenRoots $forbidden -NamePrefix 'installer-files' } else { $null }
$fileFixtureDirectory = if ($fileFixtureRun) { $fileFixtureRun.directory } else { $OutputDirectory }
$fixtureUpdateBackupRoot = Join-Path $OutputDirectory 'update-backups'
$fixtureVolumeStore = Join-Path $OutputDirectory 'volume-stores'
$results = [Collections.Generic.List[object]]::new()
# Windows側でfixture項目だけを照合・復元し、Prunletのファイル記録に依存しない。
$recordlessHelpers = @('FixtureBridge.Common.ps1', 'FileFixtures.Common.ps1') | ForEach-Object { Join-Path $PSScriptRoot $_ }
function Set-FixtureVolumeMap([string]$ConfigPath) {
    $settings = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json -AsHashtable
    $settings.volumeRecoveryDirectories = @{ (Get-VerificationVolumeRoot $fixtureVolumeStore) = $fixtureVolumeStore }
    [IO.File]::WriteAllText($ConfigPath, ($settings | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}
# 実ホストのタスクは一切登録せず、Task Scheduler境界だけをメモリー上で代替する。
# failAfterWriteNameは、その接頭辞のタスクを書いた直後だけ失敗させる（保守→更新の順で登録するため）。
$global:PrunletMaintenanceFixture = @{ tasks = @{}; failAfterWrite = $false; failAfterWriteName = $null }
function Get-ScheduledTask {
    [CmdletBinding()] param([string]$TaskPath)
    if ($TaskPath -cne '\') { throw 'Unexpected maintenance task folder.' }
    foreach ($key in $global:PrunletMaintenanceFixture.tasks.Keys) { [pscustomobject]@{ TaskName = $key; TaskPath = '\' } }
}
function Export-ScheduledTask {
    [CmdletBinding()] param([string]$TaskPath, [string]$TaskName)
    if ($TaskPath -cne '\' -or !$global:PrunletMaintenanceFixture.tasks.ContainsKey($TaskName)) { throw 'Fixture task does not exist.' }
    return $global:PrunletMaintenanceFixture.tasks[$TaskName]
}
function Register-ScheduledTask {
    [CmdletBinding()] param([string]$TaskPath, [string]$TaskName, [string]$Xml, [switch]$Force)
    if ($TaskPath -cne '\') { throw 'Unexpected maintenance task folder.' }
    if ($global:PrunletMaintenanceFixture.tasks.ContainsKey($TaskName) -and !$Force) { throw 'Fixture task already exists.' }
    $global:PrunletMaintenanceFixture.tasks[$TaskName] = $Xml
    if ($global:PrunletMaintenanceFixture.failAfterWrite) {
        $global:PrunletMaintenanceFixture.failAfterWrite = $false
        throw 'Fixture maintenance registration failure.'
    }
    if ($global:PrunletMaintenanceFixture.failAfterWriteName -and $TaskName.StartsWith($global:PrunletMaintenanceFixture.failAfterWriteName, [StringComparison]::Ordinal)) {
        $global:PrunletMaintenanceFixture.failAfterWriteName = $null
        throw 'Fixture update task registration failure.'
    }
}
function Unregister-ScheduledTask {
    [CmdletBinding(SupportsShouldProcess)] param([string]$TaskPath, [string]$TaskName)
    if ($TaskPath -cne '\') { throw 'Unexpected maintenance task folder.' }
    $global:PrunletMaintenanceFixture.tasks.Remove($TaskName)
}
function Assert-True([bool]$Value, [string]$Message) { if (!$Value) { throw $Message } }
function Test-Case([string]$Name, [scriptblock]$Action) {
    $caseClock = [Diagnostics.Stopwatch]::StartNew()
    try { & $Action; $results.Add(@{ name = $Name; passed = $true; elapsedMs = $caseClock.ElapsedMilliseconds }) }
    catch { $results.Add(@{ name = $Name; passed = $false; error = $_.ToString(); position = $_.InvocationInfo.PositionMessage; stack = $_.ScriptStackTrace; elapsedMs = $caseClock.ElapsedMilliseconds }) }
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
$isolatedCodex = Join-Path $OutputDirectory 'isolated-codex'
$settingsBackup = Join-Path $OutputDirectory 'settings-backup'

# 起こり得る失敗を列挙してから実システムの検証を組み立てる。
$failureConditions = @('退役で旧file復元領域や操作記録を作る', '退役が元設定や他の設定を変更する', 'Windowsゴミ箱の退役項目のID/hash不一致', '通常更新で旧領域を再走査する', '復元領域の移行開始後に旧exeへ戻す', '部分保全を移行完了と偽る', 'fixtureが本番専用領域へ書き込む', 'フォルダー未登録の初回導入が拒否される', '旧rootsが削除範囲へ再適用される', '無効repository', '外部保存先違反またはリンク', 'ネットワーク取得失敗', '最新releaseに更新ZIPがない', 'release commitが既定ブランチ外', '取得ZIPとassetのdigest/size不一致', 'ZIP traversal/重複/リンク/欠落/余分なentry', 'package.jsonのcommit・runtime・hash不一致', '未署名・署名者違い・タイムスタンプなしの実行ファイル', 'Codex未登録のPCで更新が永久に延期される', '更新だけの起動がMCPを起動する', '使用中の製品を更新が置き換える', 'Codex登録ありで更新が登録保護を素通りする', '更新タスクが利用者設定・他者のタスクを書き換える', '更新タスク未対応の配布物へ実行できないタスクを登録する', '製品ファイル更新失敗', '登録時既存設定の拒否', 'Codex登録の2ファイル間での書込み失敗', '旧roots内外の作業場所と復元先の検証', '指示登録オプションの組合せ不備', '指示marker重複・不完全・利用者編集', 'guide既存未所有・利用者編集', '指示登録途中での書込み失敗')
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
    Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $linked -AllowedRoot $allowed } 'cannot traverse links'
}
Test-Case 'Update backup root cannot be inside a repository or installation' {
    Expect-Failure { & $installer -UpdateBackupRoot $repoRoot -InstallDirectory $install -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'backup-repo-work') } 'outside repositories'
    Expect-Failure { & $installer -UpdateBackupRoot (Join-Path $install 'updates') -InstallDirectory $install -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'backup-install-work') } 'separate from install'
    Assert-True (!(Test-Path -LiteralPath $install)) 'Invalid update backup root created installation files.'
}
# 本番関数そのものを独立スコープへ読み込み、認証境界の失敗を検証する。
$installerTokens = $null
$installerErrors = $null
$installerAst = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$installerTokens, [ref]$installerErrors)
if ($installerErrors.Count) { throw 'Installer script has parse errors.' }
$githubHelperSource = ($installerAst.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Invoke-PrunletGitHubCli', 'Get-PrunletGitHubApiResponse')
}, $false) | ForEach-Object { $_.Extent.Text }) -join "`n"
$githubHelperBlock = [scriptblock]::Create($githubHelperSource)
Test-Case 'Explicit GitHub CLI authentication fails closed when gh is missing' {
    . $githubHelperBlock
    function Get-Command { param($Name, $CommandType, $ErrorAction) return $null }
    Expect-Failure { Invoke-PrunletGitHubCli 'repos/1llum1n4t1s/Prunlet' } 'requires an existing gh executable'
}
Test-Case 'Explicit GitHub CLI authentication rejects nonzero exit without raw stderr' {
    $pwshPath = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    . $githubHelperBlock
    # PowerShellはgh専用の固定引数を拒否し、実プロセスの非成功を返す。
    function Get-Command { param($Name, $CommandType, $ErrorAction) [pscustomobject]@{ Source = $pwshPath } }
    $caught = $null
    try { Invoke-PrunletGitHubCli 'repos/1llum1n4t1s/Prunlet' | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught -and $caught.ToString() -match '^GitHub CLI request failed \(exit code -?\d+\)\.$') 'Nonzero exit did not return a bounded, sanitized failure.'
}
Test-Case 'Explicit GitHub CLI authentication rejects invalid JSON without raw output' {
    . $githubHelperBlock
    $UseGitHubCliAuthentication = $true
    function Invoke-PrunletGitHubCli { param($Endpoint) return 'private-output-invalid-json' }
    $caught = $null
    try { Get-PrunletGitHubApiResponse 'repos/1llum1n4t1s/Prunlet' | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught -and $caught.ToString() -ceq 'GitHub CLI returned invalid JSON.') 'Invalid JSON was accepted or raw output escaped into the error.'
}
if ($CheckPublicHead) {
    Test-Case 'Public latest release installs only its verified signed package' {
        # 実GitHubの最新releaseを使う。署名済み更新ZIPがあれば導入し、未署名・未添付なら何も書かずに止まることを確認する。
        $publicInstall = Join-Path $OutputDirectory 'public-install'
        try {
            & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $publicInstall -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'public-work') -UseGitHubCliAuthentication:$UseGitHubCliAuthentication | Out-Null
            $publicInfo = Get-Content -LiteralPath (Join-Path $publicInstall 'source-info.json') -Raw | ConvertFrom-Json
            Assert-True ($publicInfo.commitSha -match '^[0-9a-f]{40}$' -and $publicInfo.downloadUrl -match '^https://api\.github\.com/repos/[^/]+/[^/]+/releases/assets/[0-9]+$') 'Public installation has no release provenance.'
            foreach ($name in @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe')) {
                Assert-True ((Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath (Join-Path $publicInstall ('bin\' + $name))).Status -eq 'Valid') "Public installation placed an unsigned executable: $name"
            }
        } catch {
            Assert-True ($_.ToString() -match 'has no unique prunlet-update-|not signed by the Prunlet publisher') "Public lookup failed unexpectedly: $_"
            Assert-True (!(Test-Path -LiteralPath $publicInstall)) 'Refused public release mutated installation.'
        }
    }
}

# 本番URLは固定のまま、親スコープのHTTPコマンドと署名照合だけを置換する。
# 取得・ZIP検証・展開・配置・登録・ロールバックは実処理を実行する。
# 配布物は公開workflowと同じPackage-PrunletUpdate.ps1で、今回のビルド出力と作業ツリーの補助ファイルから作る。
$fixtureRoot = Join-Path $OutputDirectory 'fixture'
$fixtureSource = Join-Path $fixtureRoot 'source'
$fixturePublish = Split-Path -Parent ([IO.Path]::GetFullPath($ExecutablePath))
$fixturePackages = Join-Path $fixtureRoot 'packages'
function New-FixtureSource([string]$Path) {
    # 梱包に必要な補助ファイル（integration\*とscripts\Install-Prunlet.ps1）だけを複製する。
    New-Item -ItemType Directory -Path (Join-Path $Path 'scripts') | Out-Null
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Join-Path $repoRoot 'integration') -Destination $Path -Recurse
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $installer -Destination (Join-Path $Path 'scripts')
    return $Path
}
New-Item -ItemType Directory -Path $fixtureRoot, $fixturePackages | Out-Null
$null = New-FixtureSource $fixtureSource
$fixtureGuideSha256 = (Get-FileHash -LiteralPath (Join-Path $fixtureSource 'integration\PRUNLET.md') -Algorithm SHA256).Hash
Assert-True ($fixtureGuideSha256 -ceq (Get-FileHash -LiteralPath (Join-Path $repoRoot 'integration\PRUNLET.md') -Algorithm SHA256).Hash) 'Fixture guide differs from the current working tree.'
# 実行した検証・導入・梱包・連携元のhashを、製品本文とは別にレポートへ固定する。
$verificationInputFiles = @(@($PSCommandPath, $installer, (Join-Path $repoRoot 'scripts\Package-PrunletUpdate.ps1'), (Join-Path $PSScriptRoot 'Verification-Common.ps1'), (Join-Path $PSScriptRoot 'Verification-Fixture.ps1')) + $recordlessHelpers + @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'integration') -File | ForEach-Object FullName) | Sort-Object -Unique | ForEach-Object {
    @{ path = [IO.Path]::GetRelativePath($repoRoot, $_); sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
})
$fixtureProducts = @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe' | ForEach-Object {
    @{ name = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $fixturePublish $_) -Algorithm SHA256).Hash }
})
$fixtureTag = 'v9.9.9'
$fixtureAssetName = 'prunlet-update-win-x64.zip'
$global:PrunletLatestFixture = @{
    sha = ('a' * 40); source = $fixtureSource; publish = $fixturePublish; packages = @{}; zipOverride = $null
    assetMode = 'normal'; compareStatus = 'ahead'; digestOverride = $null; signature = 'valid'
    requests = [Collections.Generic.List[string]]::new(); signatureChecks = [Collections.Generic.List[string]]::new()
    failDownload = $false; failCopy = $false
}
function New-FixturePackage([string]$Sha, [string]$Source, [string]$Runtime = 'win-x64', [string]$Publish = $fixturePublish) {
    # 同じcommit・補助ファイル・ビルド出力の組は1回だけ梱包する（commitはcaller-assertedで、releaseのcommitと照合される）。
    $key = $Source + '|' + $Sha + '|' + $Runtime + '|' + $Publish
    if (!$global:PrunletLatestFixture.packages.ContainsKey($key)) {
        $output = Join-Path $fixturePackages ('package-' + $global:PrunletLatestFixture.packages.Count + '.zip')
        & (Join-Path $repoRoot 'scripts\Package-PrunletUpdate.ps1') -SourceRoot $Source -PublishDirectory $Publish -OutputPath $output -CommitSha $Sha -DefaultBranch 'fixture/main' -Runtime $Runtime | Out-Null
        $global:PrunletLatestFixture.packages[$key] = $output
    }
    return $global:PrunletLatestFixture.packages[$key]
}
function Get-FixturePackage {
    if ($global:PrunletLatestFixture.zipOverride) { return $global:PrunletLatestFixture.zipOverride }
    return New-FixturePackage $global:PrunletLatestFixture.sha $global:PrunletLatestFixture.source 'win-x64' $global:PrunletLatestFixture.publish
}
function New-ModifiedFixturePackage([string]$Name, [scriptblock]$Change) {
    # 正規の梱包を複製し、ZIPの一部だけを壊した配布物を作る（digest・sizeは壊した後の実物で公開する）。
    $output = Join-Path $fixturePackages ($Name + '.zip')
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath (New-FixturePackage ('a' * 40) $fixtureSource) -Destination $output
    $zip = [IO.Compression.ZipFile]::Open($output, [IO.Compression.ZipArchiveMode]::Update)
    try { & $Change $zip } finally { $zip.Dispose() }
    return $output
}
function Invoke-RestMethod {
    param($Uri, $Headers, $TimeoutSec)
    [void]$global:PrunletLatestFixture.requests.Add([string]$Uri)
    Assert-True ($Headers['User-Agent'] -eq 'Prunlet-Latest-Installer' -and $TimeoutSec -gt 0) 'Missing network bounds.'
    $fixture = $global:PrunletLatestFixture
    switch -Exact ([string]$Uri) {
        'https://api.github.com/repos/1llum1n4t1s/Prunlet' { return [pscustomobject]@{ default_branch = 'fixture/main' } }
        'https://api.github.com/repos/1llum1n4t1s/Prunlet/releases/latest' {
            $assets = @()
            if ($fixture.assetMode -ne 'missing') {
                $package = Get-FixturePackage
                $digest = if ($fixture.digestOverride) { $fixture.digestOverride } else { 'sha256:' + (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant() }
                $assets = @([pscustomobject]@{ id = 4242; name = $fixtureAssetName; state = 'uploaded'; digest = $digest; size = (Get-Item -LiteralPath $package).Length })
            }
            return [pscustomobject]@{ tag_name = $fixtureTag; draft = $false; prerelease = $false; assets = $assets }
        }
        ('https://api.github.com/repos/1llum1n4t1s/Prunlet/git/ref/tags/' + $fixtureTag) { return [pscustomobject]@{ object = [pscustomobject]@{ type = 'commit'; sha = $fixture.sha } } }
        ('https://api.github.com/repos/1llum1n4t1s/Prunlet/compare/' + $fixture.sha + '...fixture%2Fmain?per_page=1') { return [pscustomobject]@{ status = $fixture.compareStatus } }
        default {
            # 起動時更新は、導入済みcommitから最新releaseへの前進も確認する。
            if ([string]$Uri -cmatch '\Ahttps://api\.github\.com/repos/1llum1n4t1s/Prunlet/compare/[0-9a-fA-F]{40}\.\.\.([0-9a-f]{40})\?per_page=1\z' -and $Matches[1] -ceq $fixture.sha) { return [pscustomobject]@{ status = $fixture.compareStatus } }
            throw "Unexpected metadata URL: $Uri"
        }
    }
}
function Invoke-WebRequest {
    param($Uri, $Headers, $OutFile, $TimeoutSec)
    [void]$global:PrunletLatestFixture.requests.Add([string]$Uri)
    Assert-True ([string]$Uri -ceq ('https://github.com/1llum1n4t1s/Prunlet/releases/download/' + $fixtureTag + '/' + $fixtureAssetName)) 'Download did not pin the latest release asset.'
    if ($global:PrunletLatestFixture.failDownload) { throw 'Fixture network failure.' }
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Get-FixturePackage) -Destination $OutFile
}
function Get-AuthenticodeSignature {
    # fixtureのビルドは検証用で署名できないため、署名照合の結果だけを置換する。
    # 'real'では実際のWindows判定（未署名ならNotSigned）をそのまま返す。
    [CmdletBinding()] param([string]$LiteralPath)
    [void]$global:PrunletLatestFixture.signatureChecks.Add($LiteralPath)
    $mode = $global:PrunletLatestFixture.signature
    if ($mode -eq 'real') { return Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $LiteralPath }
    $signerName = if ($mode -eq 'wrongSigner') { 'Fixture Other Publisher' } else { 'Open Source Developer Yuichiro Shinozaki' }
    $certificate = [pscustomobject]@{ SimpleName = $signerName }
    $certificate | Add-Member -MemberType ScriptMethod -Name GetNameInfo -Value { param($Type, $ForIssuer) return $this.SimpleName }
    $timestamp = if ($mode -eq 'noTimestamp') { $null } else { $certificate }
    return [pscustomobject]@{ Status = [Management.Automation.SignatureStatus]::Valid; SignatureType = [Management.Automation.SignatureType]::Authenticode; SignerCertificate = $certificate; TimeStamperCertificate = $timestamp }
}
$baseFixturePackage = New-FixturePackage ('a' * 40) $fixtureSource
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
try {
    Test-Case 'Maintenance XML preserves Unicode paths and limits privileges without shell commands' {
        . (Join-Path $repoRoot 'integration\maintenance-task.ps1')
        $taskExe = Join-Path $OutputDirectory '空白 & name\prunlet.exe'
        $taskConfig = Join-Path $OutputDirectory '空白 & name\設定.json'
        $state = Get-PrunletMaintenanceState $taskExe $taskConfig
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($state.maintenanceExecutable))
        [IO.File]::WriteAllBytes($state.maintenanceExecutable, [byte[]]@(0))
        Register-PrunletMaintenanceTask $state
        $xml = [xml]$global:PrunletMaintenanceFixture.tasks[$state.name]
        Assert-True ($xml.Task.Actions.Exec.Command -ceq $state.maintenanceExecutable -and $xml.Task.Actions.Exec.Arguments -ceq ('--config "' + $taskConfig + '" maintain --apply')) 'Task altered quoted paths or invokes a shell.'
        Assert-True ($xml.Task.Principals.Principal.RunLevel -ceq 'LeastPrivilege' -and $xml.Task.Principals.Principal.LogonType -ceq 'InteractiveToken') 'Task requires elevated or password logon.'
        Assert-True ($xml.Task.Settings.MultipleInstancesPolicy -ceq 'IgnoreNew' -and $xml.Task.Settings.StartWhenAvailable -ceq 'true') 'Task lacks overlap or missed-run policy.'
        Assert-True ($xml.Task.Triggers.CalendarTrigger.ScheduleByDay.DaysInterval -eq 1 -and $xml.Task.Triggers.LogonTrigger.UserId -ceq $state.sid) 'Task lacks daily or logon trigger.'
        $boundary = [Xml.XmlConvert]::ToDateTime($xml.Task.Triggers.CalendarTrigger.StartBoundary, [Xml.XmlDateTimeSerializationMode]::Unspecified)
        Assert-True ($boundary.TimeOfDay -eq [TimeSpan]::FromHours(3) -and $xml.Task.Triggers.CalendarTrigger.Enabled -ceq 'true') 'Daily maintenance is not enabled at 03:00.'
        Assert-True ($xml.Task.Triggers.LogonTrigger.Enabled -ceq 'true' -and $xml.Task.Settings.Enabled -ceq 'true') 'Missed overnight maintenance cannot run at the next logon.'
        Assert-True ($xml.Task.Settings.DisallowStartIfOnBatteries -ceq 'false' -and $xml.Task.Settings.StopIfGoingOnBatteries -ceq 'false') 'Battery operation prevents catch-up maintenance.'
        $global:PrunletMaintenanceFixture.tasks[$state.name] = $global:PrunletMaintenanceFixture.tasks[$state.name].Replace('<Hidden>true</Hidden>', '<Hidden>false</Hidden>')
        $owned = Get-PrunletMaintenanceState $taskExe $taskConfig
        Register-PrunletMaintenanceTask $owned
        Assert-True ($global:PrunletMaintenanceFixture.tasks[$state.name] -ceq $owned.previousXml -and !$owned.attempted) 'Update rewrote an existing task setting.'
        Restore-PrunletMaintenanceTask $owned
        Assert-True ($global:PrunletMaintenanceFixture.tasks[$state.name] -ceq $owned.previousXml) 'Owned task rollback did not restore XML.'
        $missing = Get-PrunletMaintenanceState $taskExe $taskConfig
        $missing.attempted = $true
        $global:PrunletMaintenanceFixture.tasks.Remove($state.name)
        Restore-PrunletMaintenanceTask $missing
        Assert-True ($global:PrunletMaintenanceFixture.tasks[$state.name] -ceq $missing.previousXml) 'Rollback did not restore a missing previous task.'
        $foreign = $owned.previousXml.Replace($state.marker, 'Foreign task')
        $global:PrunletMaintenanceFixture.tasks[$state.name] = $foreign
        Expect-Failure { Get-PrunletMaintenanceState $taskExe $taskConfig } 'not owned'
        Expect-Failure { Register-PrunletMaintenanceTask $owned } 'not owned'
        Expect-Failure { Unregister-PrunletMaintenanceTask $taskExe $taskConfig } 'not owned'
        Assert-True ($global:PrunletMaintenanceFixture.tasks[$state.name] -ceq $foreign) 'Foreign task was modified.'
        $global:PrunletMaintenanceFixture.tasks[$state.name] = $owned.previousXml
        & (Join-Path $repoRoot 'integration\uninstall-maintenance.ps1') -ExecutablePath $taskExe -ConfigPath $taskConfig | Out-Null
        Assert-True (!$global:PrunletMaintenanceFixture.tasks.ContainsKey($state.name)) 'Explicit schedule uninstall retained owned task.'
    }
    Test-Case 'Maintenance schedule uses Gregorian dates under non-Gregorian cultures' {
        . (Join-Path $repoRoot 'integration\maintenance-task.ps1')
        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        $expected = [DateTime]::Today.AddHours(3)
        try {
            foreach ($cultureName in @('th-TH', 'ar-SA')) {
                [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($cultureName)
                $cultureRoot = Join-Path $OutputDirectory ('culture-' + $cultureName)
                $cultureState = Get-PrunletMaintenanceState (Join-Path $cultureRoot 'prunlet.exe') (Join-Path $cultureRoot 'config.json')
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($cultureState.maintenanceExecutable))
                [IO.File]::WriteAllBytes($cultureState.maintenanceExecutable, [byte[]]@(0))
                try {
                    Register-PrunletMaintenanceTask $cultureState
                    $xml = [xml]$global:PrunletMaintenanceFixture.tasks[$cultureState.name]
                    $boundary = [Xml.XmlConvert]::ToDateTime($xml.Task.Triggers.CalendarTrigger.StartBoundary, [Xml.XmlDateTimeSerializationMode]::Unspecified)
                    Assert-True ($boundary.Ticks -eq $expected.Ticks) "Task date changed under $cultureName."
                } finally { $global:PrunletMaintenanceFixture.tasks.Remove($cultureState.name) }
            }
        } finally { [Globalization.CultureInfo]::CurrentCulture = $originalCulture }
    }
    Test-Case 'Download failure preserves initial boundary' {
        $global:PrunletLatestFixture.failDownload = $true
        try { Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'network-work') } 'Fixture network failure' }
        finally { $global:PrunletLatestFixture.failDownload = $false }
        Assert-True (!(Test-Path -LiteralPath $install)) 'Download failure created install files.'
    }
    # 配布物の拒否はすべて初回導入先が作られないこと（製品・設定・タスクを書かないこと）で判定する。
    function Assert-RefusedInstall([string]$Name, [string]$Pattern) {
        Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory ($Name + '-work')) } $Pattern
        Assert-True (!(Test-Path -LiteralPath $install)) "Refused package created install files: $Name"
    }
    Test-Case 'Latest release without its update package stops before download' {
        $downloadsBefore = @($global:PrunletLatestFixture.requests | Where-Object { $_ -like 'https://github.com/*' }).Count
        $global:PrunletLatestFixture.assetMode = 'missing'
        try { Assert-RefusedInstall 'missing-asset' 'has no unique prunlet-update-win-x64\.zip yet' }
        finally { $global:PrunletLatestFixture.assetMode = 'normal' }
        Assert-True (@($global:PrunletLatestFixture.requests | Where-Object { $_ -like 'https://github.com/*' }).Count -eq $downloadsBefore) 'Missing asset still downloaded a package.'
    }
    Test-Case 'Release commit outside the default branch is refused' {
        $global:PrunletLatestFixture.compareStatus = 'diverged'
        try { Assert-RefusedInstall 'diverged-release' 'not on the default branch' }
        finally { $global:PrunletLatestFixture.compareStatus = 'ahead' }
    }
    Test-Case 'Downloaded package must match the published digest' {
        $global:PrunletLatestFixture.digestOverride = 'sha256:' + ('0' * 64)
        try { Assert-RefusedInstall 'digest-mismatch' 'differs from the published release asset' }
        finally { $global:PrunletLatestFixture.digestOverride = $null }
    }
    Test-Case 'Package metadata must name the release commit and runtime' {
        foreach ($variant in @(@{ name = 'other-commit'; zip = (New-FixturePackage ('f' * 40) $fixtureSource) }, @{ name = 'other-runtime'; zip = $null })) {
            if ($variant.name -eq 'other-runtime') {
                # PEのmachineを照合する前にmetadataで止まることを確かめるため、runtimeだけを書き換える。
                $variant.zip = New-ModifiedFixturePackage 'other-runtime' {
                    param($zip)
                    $entry = $zip.GetEntry('package.json')
                    $reader = [IO.StreamReader]::new($entry.Open()); try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    $entry.Delete()
                    $writer = [IO.StreamWriter]::new($zip.CreateEntry('package.json').Open(), [Text.UTF8Encoding]::new($false)); try { $writer.Write($text.Replace('"runtime":"win-x64"', '"runtime":"win-arm64"')) } finally { $writer.Dispose() }
                }
            }
            $global:PrunletLatestFixture.zipOverride = $variant.zip
            try { Assert-RefusedInstall $variant.name 'Package metadata does not match the published release' }
            finally { $global:PrunletLatestFixture.zipOverride = $null }
        }
    }
    Test-Case 'Package traversal, duplicate, link, missing, extra and altered entries are rejected before mutation' {
        $variants = [ordered]@{
            'traversal' = @({ param($zip) [void]$zip.CreateEntry('bin/../escaped.txt') }, 'Unexpected or duplicate package entry')
            'extra' = @({ param($zip) $writer = [IO.StreamWriter]::new($zip.CreateEntry('bin/extra.ps1').Open()); try { $writer.Write('extra') } finally { $writer.Dispose() } }, 'Unexpected or duplicate package entry')
            'duplicate' = @({ param($zip) $writer = [IO.StreamWriter]::new($zip.CreateEntry('bin/PRUNLET.md').Open()); try { $writer.Write('duplicate') } finally { $writer.Dispose() } }, 'Unexpected or duplicate package entry')
            'link' = @({ param($zip) $zip.GetEntry('bin/PRUNLET.md').ExternalAttributes = [int](-1577058304) }, 'links, directories, or special files')
            'missing' = @({ param($zip) $zip.GetEntry('bin/PRUNLET.md').Delete() }, 'missing required entries')
            'altered' = @({
                param($zip)
                $entry = $zip.GetEntry('bin/PRUNLET.md')
                $reader = [IO.StreamReader]::new($entry.Open()); try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $entry.Delete()
                # 長さを保ったまま内容だけを変え、metadataのhash照合で止まることを確かめる。
                $writer = [IO.StreamWriter]::new($zip.CreateEntry('bin/PRUNLET.md').Open(), [Text.UTF8Encoding]::new($false)); try { $writer.Write('X' + $text.Substring(1)) } finally { $writer.Dispose() }
            }, 'Package content differs from its metadata')
        }
        foreach ($name in $variants.Keys) {
            $global:PrunletLatestFixture.zipOverride = New-ModifiedFixturePackage ('bad-' + $name) $variants[$name][0]
            try { Assert-RefusedInstall ('bad-' + $name) $variants[$name][1] }
            finally { $global:PrunletLatestFixture.zipOverride = $null }
        }
    }
    Test-Case 'Unsigned, foreign-signed and untimestamped executables are never placed' {
        # realは実際のWindows判定を使い、検証用ビルド（未署名）がNotSignedで拒否されることを確かめる。
        foreach ($mode in @('real', 'wrongSigner', 'noTimestamp')) {
            $global:PrunletLatestFixture.signature = $mode
            try { Assert-RefusedInstall ('signature-' + $mode) 'not signed by the Prunlet publisher' }
            finally { $global:PrunletLatestFixture.signature = 'valid' }
        }
        Assert-True (!@($global:PrunletMaintenanceFixture.tasks.Values | Where-Object { $_.Contains($install) }).Count) 'Refused signature registered a maintenance task.'
    }
    Test-Case 'Maintenance registration failure rolls back new task and product files' {
        $failedInstall = Join-Path $OutputDirectory 'schedule-failure-install'
        $beforeTaskCount = $global:PrunletMaintenanceFixture.tasks.Count
        $global:PrunletMaintenanceFixture.failAfterWrite = $true
        Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $failedInstall -WorkDirectory (Join-Path $OutputDirectory 'schedule-failure-work') } 'Fixture maintenance registration failure'
        Assert-True ($global:PrunletMaintenanceFixture.tasks.Count -eq $beforeTaskCount) 'Failed installation left a maintenance task.'
        Assert-True (!(Test-Path -LiteralPath $failedInstall)) 'Failed maintenance registration left product files.'
    }
    Test-Case 'Foreign maintenance task blocks installation before product files change' {
        . (Join-Path $repoRoot 'integration\maintenance-task.ps1')
        $foreignInstall = Join-Path $OutputDirectory 'foreign-task-install'
        $state = Get-PrunletMaintenanceState (Join-Path $foreignInstall 'bin\prunlet.exe') (Join-Path $foreignInstall 'config.json')
        $foreign = '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><RegistrationInfo><Description>Foreign task</Description></RegistrationInfo></Task>'
        $global:PrunletMaintenanceFixture.tasks[$state.name] = $foreign
        try {
            Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $foreignInstall -WorkDirectory (Join-Path $OutputDirectory 'foreign-task-work') } 'not owned'
            Assert-True ($global:PrunletMaintenanceFixture.tasks[$state.name] -ceq $foreign) 'Foreign task changed during failed install.'
            Assert-True (!(Test-Path -LiteralPath $foreignInstall)) 'Foreign task conflict created product files.'
        } finally { $global:PrunletMaintenanceFixture.tasks.Remove($state.name) }
    }
    Test-Case 'Latest fixture installs without target registration and protects recovery storage' {
        $global:PrunletLatestFixture.signatureChecks.Clear()
        $firstInstallResult = & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -RegisterCodex -CodexHome $isolatedCodex -SettingsBackupDirectory $settingsBackup -WorkDirectory (Join-Path $OutputDirectory 'first-work') | ConvertFrom-Json -AsHashtable
        Assert-True ($firstInstallResult.status -ceq 'installed' -and $firstInstallResult.recoveryMigration.registryReady -and $firstInstallResult.recoveryMigration.complete) 'Fresh installation did not prepare registry-only recovery storage.'
        $info = Get-Content -LiteralPath (Join-Path $install 'source-info.json') -Raw | ConvertFrom-Json
        Assert-True ($info.commitSha -eq ('a' * 40)) 'Initial provenance mismatch.'
        # 起動時更新（coordinator.rs）が読む10項目と同じ構成で、取得したreleaseのassetとZIPを指すこと。
        $infoFields = @($info.PSObject.Properties.Name)
        Assert-True ($infoFields.Count -eq 10 -and !(Compare-Object $infoFields @('repository', 'defaultBranch', 'commitSha', 'downloadUrl', 'archiveSha256', 'executableSha256', 'maintenanceExecutableSha256', 'hookExecutableSha256', 'auxiliarySha256', 'runtime'))) "Provenance fields differ from startup update: $($infoFields -join ',')"
        Assert-True ($info.downloadUrl -ceq 'https://api.github.com/repos/1llum1n4t1s/Prunlet/releases/assets/4242' -and $info.archiveSha256 -ceq (Get-FileHash -LiteralPath $baseFixturePackage -Algorithm SHA256).Hash -and $info.defaultBranch -ceq 'fixture/main' -and $info.runtime -ceq 'win-x64') 'Provenance does not identify the installed release package.'
        Assert-True (@($info.auxiliarySha256.PSObject.Properties).Count -eq 9) 'Auxiliary provenance is incomplete.'
        foreach ($name in @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe')) {
            Assert-True ((Get-FileHash -LiteralPath (Join-Path $install ('bin\' + $name))).Hash -ceq ($fixtureProducts | Where-Object name -eq $name).sha256) "Installed executable is not the packaged build: $name"
            Assert-True (@($global:PrunletLatestFixture.signatureChecks | Where-Object { [IO.Path]::GetFileName($_) -ceq $name -and !$_.StartsWith($install, [StringComparison]::OrdinalIgnoreCase) }).Count -ge 1) "Signature was not checked before placement: $name"
        }
        Assert-True ($info.executableSha256 -eq (Get-FileHash -LiteralPath (Join-Path $install 'bin\prunlet.exe')).Hash) 'Executable provenance hash mismatch.'
        $toml = Get-Content -LiteralPath (Join-Path $isolatedCodex 'config.toml') -Raw
        $hooks = Get-Content -LiteralPath (Join-Path $isolatedCodex 'hooks.json') -Raw
        Assert-True (!$toml.Contains($repoRoot) -and !$hooks.Contains($repoRoot) -and !$toml.Contains($fixtureRoot) -and !$hooks.Contains($fixtureRoot)) 'Registration references checkout source.'
        Assert-True ($toml.Contains('bin\\prunlet.exe')) 'Registration does not use installed bin.'
        # MCPに頼らない更新タスク: 非表示のconhost経由でpwshの-UpdateOnlyを起動し、保守タスクと時刻をずらす。
        Assert-True ($firstInstallResult.updateTaskRegistered -and $global:PrunletMaintenanceFixture.tasks.ContainsKey($firstInstallResult.updateTaskName)) 'Installation did not register the update task.'
        $updateXml = [xml]$global:PrunletMaintenanceFixture.tasks[$firstInstallResult.updateTaskName]
        $expectedArguments = '--headless pwsh -NoProfile -NonInteractive -File "' + (Join-Path $install 'bin\start-prunlet-mcp.ps1') + '" -UpdateOnly -ExecutablePath "' + (Join-Path $install 'bin\prunlet.exe') + '" -ConfigPath "' + (Join-Path $install 'config.json') + '" -CodexHome "' + $isolatedCodex + '"'
        Assert-True ($updateXml.Task.Actions.Exec.Command -ieq (Join-Path ([Environment]::GetFolderPath('System')) 'conhost.exe') -and $updateXml.Task.Actions.Exec.Arguments -ceq $expectedArguments) "Update task action differs: $($updateXml.Task.Actions.Exec.Arguments)"
        Assert-True ($updateXml.Task.Principals.Principal.RunLevel -ceq 'LeastPrivilege' -and $updateXml.Task.Settings.Hidden -ceq 'true' -and $updateXml.Task.Settings.MultipleInstancesPolicy -ceq 'IgnoreNew' -and $updateXml.Task.Settings.StartWhenAvailable -ceq 'true') 'Update task is elevated, visible, overlapping, or skips missed runs.'
        $updateBoundary = [Xml.XmlConvert]::ToDateTime($updateXml.Task.Triggers.CalendarTrigger.StartBoundary, [Xml.XmlDateTimeSerializationMode]::Unspecified)
        Assert-True ($updateBoundary.TimeOfDay -eq [TimeSpan]::FromMinutes(750) -and $updateXml.Task.Triggers.LogonTrigger.Delay -ceq 'PT10M') 'Update task runs together with maintenance.'
        Assert-True (!(Test-Path -LiteralPath (Join-Path $OutputDirectory 'first-work'))) 'Successful work was not cleaned.'
        Assert-True (!(Test-Path -LiteralPath (Join-Path $isolatedCodex 'AGENTS.md')) -and !(Test-Path -LiteralPath (Join-Path $isolatedCodex 'PRUNLET.md'))) 'Without the flag agent instructions were written.'
        $installedExe = Join-Path $install 'bin\prunlet.exe'
        $installedConfig = Join-Path $install 'config.json'
        $initialSettings = Get-Content -LiteralPath $installedConfig -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($initialSettings.capacityDefaultMigrationVersion -eq 1) 'New installation was not marked migrated.'
        Assert-True (!$initialSettings.ContainsKey('volumeRecoveryDirectories') -or $initialSettings.volumeRecoveryDirectories.Count -eq 0) 'Fresh installation changed default volume placement.'
        Set-FixtureVolumeMap $installedConfig
        $target = Join-Path $fileFixtureDirectory 'unregistered-install-target.txt'
        [IO.File]::WriteAllText($target, 'unregistered install target')
        $targetId = Get-FileFixtureIdentity -Path $target
        $priorPidls = @(foreach ($item in (Find-FileFixtureBinIdentity -ExpectedId $targetId)) { $item.Pidl })
        $deleted = (& $installedExe --config $installedConfig delete -- $target | ConvertFrom-Json)
        Assert-True ($LASTEXITCODE -eq 0 -and ![IO.File]::Exists($target) -and $deleted.items[0].status -eq 'recycled' -and !$deleted.PSObject.Properties['operationId']) 'Installed CLI did not recycle without a file operation record.'
        $binItem = Find-FileFixtureBinNew -ExpectedId $targetId -PriorPidls ([string[]]$priorPidls)
        $null = Restore-FileFixtureOwned -Pidl $binItem.Pidl -PhysicalPath $binItem.PhysicalPath -ExpectedId $targetId -OriginalPath $target -Scope $fileFixtureDirectory
        Assert-True ([IO.File]::ReadAllText($target) -eq 'unregistered install target' -and (Get-FileFixtureIdentity -Path $target) -ceq $targetId) 'Windows restoration of installed CLI item differs.'
        $protected = Join-Path $install 'recovery\protected-install-target.txt'
        [IO.File]::WriteAllText($protected, 'keep recovery storage')
        $null = & $installedExe --config $installedConfig delete -- $protected
        Assert-True ($LASTEXITCODE -ne 0 -and [IO.File]::ReadAllText($protected) -eq 'keep recovery storage') 'Installed CLI deletes from its own recovery storage.'
    }
    Test-Case 'Migration failure preserves the updated executable and foreign storage for explicit resume' {
        . (Join-Path $repoRoot 'integration\maintenance-task.ps1')
        $pendingInstall = Join-Path $OutputDirectory 'migration-pending-install'
        $pendingBin = Join-Path $pendingInstall 'bin'
        $pendingRecovery = Join-Path $pendingInstall 'recovery'
        $foreignRoot = Join-Path $pendingRecovery '.registry-records-v1'
        New-Item -ItemType Directory -Path $pendingBin, $foreignRoot -Force | Out-Null
        $pendingExe = Join-Path $pendingBin 'prunlet.exe'
        [IO.File]::WriteAllText($pendingExe, 'old executable preimage fixture')
        $oldExeHash = (Get-FileHash -LiteralPath $pendingExe).Hash
        $foreign = Join-Path $foreignRoot 'foreign-data.txt'
        [IO.File]::WriteAllText($foreign, 'preserve this unowned namespace')
        $foreignHash = (Get-FileHash -LiteralPath $foreign).Hash
        $pendingConfig = Join-Path $pendingInstall 'config.json'
        $settings = [IO.File]::ReadAllText((Join-Path $install 'config.json')) | ConvertFrom-Json -AsHashtable
        $settings.backupDirectory = $pendingRecovery
        [IO.File]::WriteAllText($pendingConfig, ($settings | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        $configHash = (Get-FileHash -LiteralPath $pendingConfig).Hash
        Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $pendingInstall -WorkDirectory (Join-Path $OutputDirectory 'migration-pending-work') } 'Installation reached recovery migration'
        $pendingInfo = [IO.File]::ReadAllText((Join-Path $pendingInstall 'source-info.json')) | ConvertFrom-Json -AsHashtable
        Assert-True ($pendingInfo.executableSha256 -ceq (Get-FileHash -LiteralPath $pendingExe).Hash -and $pendingInfo.executableSha256 -cne $oldExeHash) 'Migration failure rolled back to the old executable.'
        Assert-True ((Get-FileHash -LiteralPath $pendingConfig).Hash -ceq $configHash -and (Get-FileHash -LiteralPath $foreign).Hash -ceq $foreignHash) 'Migration failure changed configuration or foreign storage.'
        $null = & $pendingExe --help
        Assert-True ($LASTEXITCODE -eq 0) 'Preserved updated executable cannot be used for recovery.'
        $state = Get-PrunletMaintenanceState $pendingExe $pendingConfig
        Assert-True ($global:PrunletMaintenanceFixture.tasks.ContainsKey($state.name)) 'Migration failure removed the registration required by the updated installation.'
    }
    Test-Case 'Next install migrates legacy capacity once and preserves other settings and recovery' {
        $legacyConfigPath = Join-Path $install 'config.json'
        $legacyConfig = Get-Content -LiteralPath $legacyConfigPath -Raw | ConvertFrom-Json
        $legacyConfig.allowedRoots = @((Join-Path $OutputDirectory 'nonexistent-legacy-root'))
        $legacyConfig.PSObject.Properties.Remove('capacityDefaultMigrationVersion')
        $legacyConfig.maxRecoveryBytes = [long]34359738368
        $legacyConfig.retentionDays = 19
        $configAcl = Get-Acl -LiteralPath $legacyConfigPath
        $configAcl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($configAcl.Access)) { [void]$configAcl.RemoveAccessRuleSpecific($rule) }
        $configAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
        $configAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
        Set-Acl -LiteralPath $legacyConfigPath -AclObject $configAcl
        $configSddl = (Get-Acl -LiteralPath $legacyConfigPath).Sddl
        [IO.File]::WriteAllText($legacyConfigPath, ($legacyConfig | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        $configHash = (Get-FileHash -LiteralPath $legacyConfigPath).Hash
        $recoveryMarker = Join-Path $install 'recovery\user-marker.txt'
        Set-Content -LiteralPath $recoveryMarker -Value 'Keep user recovery data.' -Encoding utf8NoBOM
        $markerHash = (Get-FileHash -LiteralPath $recoveryMarker).Hash
        # 壊れた固定gateでもinstallerはackせず、registryReadyを維持してfile破棄だけを保留する。
        $discardGate = Join-Path $install 'recovery\.legacy-file-discard-in-progress'
        Assert-True (!(Test-Path -LiteralPath $discardGate)) 'Discard gate fixture already exists.'
        [IO.File]::WriteAllText($discardGate, 'owned intentionally corrupt uncertainty gate', [Text.UTF8Encoding]::new($false))
        $discardGateHash = (Get-FileHash -LiteralPath $discardGate).Hash
        $global:PrunletLatestFixture.sha = 'b' * 40
        $discardWarnings = @()
        & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -RegisterCodex -CodexHome $isolatedCodex -SettingsBackupDirectory $settingsBackup -WorkDirectory (Join-Path $OutputDirectory 'second-work') -WarningVariable discardWarnings | Out-Null
        Assert-True ((Get-FileHash -LiteralPath $discardGate).Hash -ceq $discardGateHash -and @($discardWarnings | Where-Object { $_.ToString() -match 'Some legacy file recovery data was retained' }).Count -ge 1) 'Installer acknowledged/changed the uncertainty gate or lost the registry-ready incomplete-file warning.'
        $info = Get-Content -LiteralPath (Join-Path $install 'source-info.json') -Raw | ConvertFrom-Json
        Assert-True ($info.commitSha -eq ('b' * 40)) 'Update reused old HEAD.'
        $migrated = Get-Content -LiteralPath $legacyConfigPath -Raw | ConvertFrom-Json
        Assert-True ($migrated.maxRecoveryBytes -eq 1073741824 -and $migrated.capacityDefaultMigrationVersion -eq 1) 'Legacy capacity was not migrated.'
        Assert-True ($migrated.retentionDays -eq 19 -and $migrated.allowedRoots[0] -eq $legacyConfig.allowedRoots[0]) 'Migration changed other settings.'
        Assert-True ((Get-Acl -LiteralPath $legacyConfigPath).Sddl -ceq $configSddl) 'Migration changed configuration ACL.'
        Assert-True ($markerHash -eq (Get-FileHash -LiteralPath $recoveryMarker).Hash) 'Update rewrote recovery.'
    }
    Test-Case 'Later updates preserve explicit capacity after migration' {
        $legacyConfigPath = Join-Path $install 'config.json'
        $settings = Get-Content -LiteralPath $legacyConfigPath -Raw | ConvertFrom-Json
        $settings.maxRecoveryBytes = [long]2147483648
        $json = ($settings | ConvertTo-Json -Depth 20).Replace('"capacityDefaultMigrationVersion"', '"CAPACITYDEFAULTMIGRATIONVERSION"')
        [IO.File]::WriteAllText($legacyConfigPath, $json, [Text.UTF8Encoding]::new($false))
        $configHash = (Get-FileHash -LiteralPath $legacyConfigPath).Hash
        & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -WorkDirectory (Join-Path $OutputDirectory 'post-migration-work') | Out-Null
        Assert-True ($configHash -eq (Get-FileHash -LiteralPath $legacyConfigPath).Hash) 'Update repeated capacity migration.'
    }
    Test-Case 'Config-only installation migrates mixed-case capacity and preserves recovery' {
        $legacyConfigPath = Join-Path $install 'config.json'
        $configOnlyInstall = Join-Path $OutputDirectory 'config-only-install'
        New-Item -ItemType Directory -Path $configOnlyInstall | Out-Null
        $settings = Get-Content -LiteralPath $legacyConfigPath -Raw | ConvertFrom-Json -AsHashtable
        $null = $settings.Remove('capacityDefaultMigrationVersion')
        $null = $settings.Remove('CAPACITYDEFAULTMIGRATIONVERSION')
        $settings.maxRecoveryBytes = [long]34359738368
        $json = ($settings | ConvertTo-Json -Depth 20).Replace('"maxRecoveryBytes"', '"MAXRECOVERYBYTES"')
        $onlyConfig = Join-Path $configOnlyInstall 'config.json'
        [IO.File]::WriteAllText($onlyConfig, $json, [Text.UTF8Encoding]::new($false))
        & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $configOnlyInstall -WorkDirectory (Join-Path $OutputDirectory 'config-only-work') | Out-Null
        $after = Get-Content -LiteralPath $onlyConfig -Raw | ConvertFrom-Json
        Assert-True ($after.maxRecoveryBytes -eq 1073741824 -and $after.capacityDefaultMigrationVersion -eq 1) 'Config-only capacity migration failed.'
    }
    Test-Case 'Unknown setting and locked configuration are preserved without migration' {
        $legacyConfigPath = Join-Path $install 'config.json'
        $settings = Get-Content -LiteralPath $legacyConfigPath -Raw | ConvertFrom-Json -AsHashtable
        $null = $settings.Remove('capacityDefaultMigrationVersion')
        $null = $settings.Remove('CAPACITYDEFAULTMIGRATIONVERSION')
        $settings.maxRecoveryBytes = [long]34359738368
        $original = [IO.File]::ReadAllBytes($legacyConfigPath)
        try {
            $settings.unknownMigrationFixture = @{ nested = @('keep', 42) }
            [IO.File]::WriteAllText($legacyConfigPath, ($settings | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            $before = Snapshot-Install
            Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -WorkDirectory (Join-Path $OutputDirectory 'unknown-setting-work') } 'existing configuration'
            Assert-Snapshot $before
            $null = $settings.Remove('unknownMigrationFixture')
            [IO.File]::WriteAllText($legacyConfigPath, ($settings | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            $before = Snapshot-Install
            $lock = [IO.File]::Open($legacyConfigPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -WorkDirectory (Join-Path $OutputDirectory 'locked-migration-work') } 'Replace'
                Assert-Snapshot $before
            } finally { $lock.Dispose() }
        } finally { [IO.File]::WriteAllBytes($legacyConfigPath, $original) }
    }
    Test-Case 'Registration failure restores exact pre-migration configuration' {
        $legacyConfigPath = Join-Path $install 'config.json'
        $configSddl = (Get-Acl -LiteralPath $legacyConfigPath).Sddl
        $settings = Get-Content -LiteralPath $legacyConfigPath -Raw | ConvertFrom-Json
        $settings.PSObject.Properties.Remove('capacityDefaultMigrationVersion')
        $settings.maxRecoveryBytes = [long]34359738368
        [IO.File]::WriteAllText($legacyConfigPath, ($settings | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($true))
        $before = Snapshot-Install
        $blocked = Join-Path $OutputDirectory 'migration-blocked-codex'
        New-Item -ItemType Directory -Path $blocked | Out-Null
        Set-Content -LiteralPath (Join-Path $blocked 'config.toml') -Value "[features]`nhooks = false`n" -Encoding utf8NoBOM
        Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $install -RegisterCodex -CodexHome $blocked -SettingsBackupDirectory $settingsBackup -WorkDirectory (Join-Path $OutputDirectory 'migration-rollback-work') } 'features.hooks is false'
        Assert-Snapshot $before
        Assert-True ((Get-Acl -LiteralPath $legacyConfigPath).Sddl -ceq $configSddl) 'Migration rollback changed configuration ACL.'
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
        $registeredGuide = [IO.File]::ReadAllText($instructionGuide)
        Assert-True ($registeredGuide.Contains('初回から `sandbox_permissions: "require_escalated"`') -and $registeredGuide.Contains('login: false, sandbox_permissions: "require_escalated"')) 'Guide omits the initial formal sandbox permission request or its CMD example.'
        Assert-True ($registeredGuide.Contains('WindowsのUAC昇格や管理者実行ではない') -and $registeredGuide.Contains('実処理に必要な権限と、対象がサイズ超過で永久削除されるかは予測しない')) 'Guide omits the UAC distinction or dry-run permission limitation.'
        Assert-True ($registeredGuide.Contains('末尾名がWindows予約名の実在する通常ファイルだけ') -and $registeredGuide.Contains('追加確認やShell試行なしで永久削除する') -and $registeredGuide.Contains('予約名の祖先・ディレクトリ・reparse pointはこの例外に含めない') -and $registeredGuide.Contains('would_permanently_delete')) 'Guide omits the reserved regular-file permanent deletion boundary or its dry-run status.'
        Assert-True ($registeredGuide.Contains('同じ削除を自動再送しない') -and $registeredGuide.Contains('状態を照合') -and $registeredGuide.Contains('元の削除許可とホストの承認・管理ポリシーを守る')) 'Guide omits uncertain-state reconciliation or preserves no host policy boundary.'
        $withoutBlock = [regex]::Replace($agentText, '<!-- BEGIN PRUNLET AGENT-INSTRUCTIONS -->\r\n[\s\S]*?\r\n<!-- END PRUNLET AGENT-INSTRUCTIONS -->\r\n', '')
        Assert-True ($withoutBlock -ceq $originalAgentText) 'Existing AGENTS body or newlines changed.'
        $bytes = [IO.File]::ReadAllBytes($instructionAgents)
        Assert-True ($bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) 'UTF8 BOM was removed.'
        Assert-True ((Get-FileHash -LiteralPath $instructionGuide).Hash -eq (Get-FileHash -LiteralPath (Join-Path $instructionInstall 'bin\PRUNLET.md')).Hash) 'Registered guide differs from installed guide.'
        Assert-True ((Get-FileHash -LiteralPath $instructionGuide).Hash -ceq $fixtureGuideSha256) 'Registered guide differs from the source guide snapshot.'
        Assert-True ((Get-FileHash -LiteralPath $trustPath).Hash -eq $trustHash) 'Unrelated host trust data changed.'
    }

    Test-Case 'Custom CLI binding uninstalls with the registered paths and preserves existing content' {
        $customCodex = Join-Path $OutputDirectory 'custom-binding-codex'
        $customProduct = Join-Path $OutputDirectory 'custom-binding-product'
        New-Item -ItemType Directory -Path $customCodex, $customProduct | Out-Null
        $customExe = Join-Path $customProduct 'custom-prunlet.exe'
        $customConfig = Join-Path $customProduct 'custom-config.json'
        Copy-Item -LiteralPath (Join-Path $instructionInstall 'bin\prunlet.exe') -Destination $customExe
        Copy-Item -LiteralPath (Join-Path $instructionInstall 'bin\prunlet-hook.exe') -Destination (Join-Path $customProduct 'prunlet-hook.exe')
        Copy-Item -LiteralPath (Join-Path $instructionInstall 'bin\start-prunlet-mcp.ps1') -Destination (Join-Path $customProduct 'start-prunlet-mcp.ps1')
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
        $legacyInstall = Join-Path $fileFixtureDirectory 'legacy-instruction-install'
        $legacyCodex = Join-Path $OutputDirectory 'legacy-instruction-codex'
        New-Item -ItemType Directory -Path $legacyCodex | Out-Null
        & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $legacyInstall -BackupDirectory (Join-Path $OutputDirectory 'legacy-instruction-recovery') -AllowedRoot $allowed -WorkDirectory (Join-Path $OutputDirectory 'legacy-instruction-base-work') | Out-Null
        $obsoleteBackend = Join-Path $legacyInstall 'bin\codex-pretooluse.ps1'
        [IO.File]::WriteAllText($obsoleteBackend, '# Previous installed PowerShell backend fixture', [Text.UTF8Encoding]::new($false))
        $obsoleteHash = (Get-FileHash -LiteralPath $obsoleteBackend -Algorithm SHA256).Hash
        $obsoleteId = Get-FileFixtureIdentity -Path $obsoleteBackend
        $obsoletePriorPidls = @(foreach ($item in (Find-FileFixtureBinIdentity -ExpectedId $obsoleteId)) { $item.Pidl })
        $legacyConfigPath = Join-Path $legacyInstall 'config.json'
        Set-FixtureVolumeMap $legacyConfigPath
        $mainSettings = Get-Content -LiteralPath $legacyConfigPath -Raw | ConvertFrom-Json -AsHashtable
        $configuredVolumeMap = $mainSettings['volumeRecoveryDirectories']
        $mainSettings.Remove('volumeRecoveryDirectories')
        $mainSettings['VolumeRecoveryDirectories'] = $configuredVolumeMap
        $mainSettings.retentionDays = 13
        $mainSettings.maxRecoveryBytes = 4GB
        [IO.File]::WriteAllText($legacyConfigPath, ($mainSettings | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        & (Join-Path $legacyInstall 'bin\prunlet.exe') --config $legacyConfigPath operations | Out-Null
        Assert-True ($LASTEXITCODE -eq 0 -and !$mainSettings.ContainsKey('volumeRecoveryDirectories') -and $mainSettings.ContainsKey('VolumeRecoveryDirectories')) 'CLI rejected the case-variant volume configuration fixture.'
        $legacyConfigHash = (Get-FileHash -LiteralPath $legacyConfigPath -Algorithm SHA256).Hash
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
        Assert-True ((Get-FileHash -LiteralPath $legacyConfigPath -Algorithm SHA256).Hash -ceq $legacyConfigHash) 'Retirement changed the main configuration.'
        Assert-True (@($legacyResult.retiredProductPaths).Count -eq 1 -and $legacyResult.retiredProductPaths[0] -ceq $obsoleteBackend) 'Installer did not report the retired product path.'
        Assert-True (!(Test-Path -LiteralPath (Join-Path $legacyResult.updateBackupDirectory 'retired-recovery')) -and !(Test-Path -LiteralPath (Join-Path $legacyResult.updateBackupDirectory 'retirement-config.json'))) 'Retirement created legacy file recovery storage.'
        $retired = [IO.File]::ReadAllText((Join-Path $legacyResult.updateBackupDirectory 'retired-products.json')) | ConvertFrom-Json -AsHashtable
        Assert-True (!$retired.ContainsKey('operationId') -and @($retired.items).Count -eq 1 -and $retired.items[0].status -ceq 'recycled' -and $retired.items[0].path -ceq $obsoleteBackend) 'Retirement did not use the recordless file result.'
        $retiredBinItem = Find-FileFixtureBinNew -ExpectedId $obsoleteId -PriorPidls ([string[]]$obsoletePriorPidls)
        $retiredPayload = $retiredBinItem.PhysicalPath
        Assert-True ([IO.Path]::IsPathFullyQualified($retiredPayload) -and ($retiredPayload.Split([char]92) -icontains '$Recycle.Bin')) 'Retirement did not use Windows Recycle Bin.'
        Assert-True ((Get-FileHash -LiteralPath $retiredPayload -Algorithm SHA256).Hash -ceq $obsoleteHash -and (Get-FileFixtureIdentity -Path $retiredPayload) -ceq $obsoleteId) 'Retired backend was copied or its bytes changed.'
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
        Assert-True ($updated.Contains('Windowsのファイル・フォルダー・レジストリ削除では')) 'File-only CLI block did not migrate.'
        $afterBody = [regex]::Replace($updated, '<!-- BEGIN PRUNLET AGENT-INSTRUCTIONS -->[\s\S]*?<!-- END PRUNLET AGENT-INSTRUCTIONS -->\r?\n', '')
        Assert-True ($fileCliBody -ceq $afterBody) 'CLI migration changed the existing body.'
        Assert-True ($updated.Contains($fileCliBinding)) 'CLI migration changed the executable/config binding.'
        $updatedBytes = [IO.File]::ReadAllBytes($fileCliAgents)
        Assert-True ($updatedBytes[0] -eq 0xef -and $updatedBytes[1] -eq 0xbb -and $updatedBytes[2] -eq 0xbf) 'CLI migration changed the BOM.'
    }
    Test-Case 'Independent CMD hook migrates owned routes and preserves unrelated handlers' {
        $exePath = Join-Path $instructionInstall 'bin\prunlet.exe'
        $hookPath = Join-Path $instructionInstall 'bin\prunlet-hook.exe'
        $cfgPath = Join-Path $instructionInstall 'config.json'
        $oldHelper = Join-Path $instructionInstall 'bin\codex-pretooluse.ps1'
        $nativeCommand = 'call "' + $exePath + '" --config "' + $cfgPath + '" hook'
        $cmdPath = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
        $expectedCommand = $cmdPath + ' /d /c call "' + $hookPath + '" --config "' + $cfgPath + '" hook --cli-executable "' + $exePath + '"'
        $legacyCommands = @($nativeCommand, ($cmdPath + ' /d /c ' + $nativeCommand), ($nativeCommand + ' --hook-script "' + $oldHelper + '"'), ('pwsh -NoProfile -NonInteractive -File "' + $oldHelper + '" -ExecutablePath "' + $exePath + '" -ConfigPath "' + $cfgPath + '"'))
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
        $spaceHook = Join-Path $spaceProduct 'prunlet-hook.exe'
        $spaceConfig = Join-Path $spaceProduct 'config space.json'
        Copy-Item -LiteralPath (Join-Path $instructionInstall 'bin\prunlet.exe') -Destination $spaceExe
        Copy-Item -LiteralPath (Join-Path $instructionInstall 'bin\prunlet-hook.exe') -Destination $spaceHook
        Copy-Item -LiteralPath (Join-Path $instructionInstall 'bin\start-prunlet-mcp.ps1') -Destination (Join-Path $spaceProduct 'start-prunlet-mcp.ps1')
        Copy-Item -LiteralPath (Join-Path $instructionInstall 'config.json') -Destination $spaceConfig
        & (Join-Path $instructionInstall 'bin\install-codex.ps1') -ExecutablePath $spaceExe -ConfigPath $spaceConfig -CodexHome $spaceCodex -BackupDirectory $instructionBackup | Out-Null
        $spaceHooks = [IO.File]::ReadAllText((Join-Path $spaceCodex 'hooks.json')) | ConvertFrom-Json
        $spaceCommand = @($spaceHooks.hooks.PreToolUse | ForEach-Object { $_.hooks } | Where-Object { $_.statusMessage -eq 'Prunlet: protected literal deletion' })[0].command
        $spaceExpected = (Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe') + ' /d /c call "' + $spaceHook + '" --config "' + $spaceConfig + '" hook --cli-executable "' + $spaceExe + '"'
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
                        if ($command.StartsWith('del ')) {
                            Assert-True ($parsed.hookSpecificOutput.permissionDecision -eq 'deny' -and !$parsed.hookSpecificOutput.updatedInput) ('Raw deletion was not denied under ' + $shell)
                            $reason = $parsed.hookSpecificOutput.permissionDecisionReason
                            Assert-True ($reason.Contains('sandbox_permissions="require_escalated"') -and $reason.Contains('first real file deletion') -and $reason.Contains('not Windows UAC or administrator elevation')) 'Hook omits the formal initial sandbox permission request or its UAC distinction.'
                            Assert-True ($reason.Contains('A dry-run does not prove real-operation permissions') -and $reason.Contains('Windows Recycle Bin') -and $reason.Contains('registry-reconcile <operationId>')) 'Hook omits dry-run limitations or the file/registry-specific uncertain-state guidance.'
                            Assert-True ($reason.Contains('no Prunlet operation record') -and $reason.Contains('registry-restore <operationId>')) 'Hook still promises file operation records or omits registry restoration.'
                            Assert-True ($reason.Contains('Existing host approvals and policies still apply') -and $reason.Contains('Do not retry a policy-rejected target through another route')) 'Hook no longer preserves host approval and policy boundaries.'
                        }
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
    # guideだけを変えた補助ファイルの組を別sourceとして用意し、同じビルド出力で梱包する。
    $updatedSource = New-FixtureSource (Join-Path $fixtureRoot 'source-updated-guide')
    [IO.File]::AppendAllText((Join-Path $updatedSource 'integration\PRUNLET.md'), "`nFixture guide update.`n", [Text.UTF8Encoding]::new($false))
    $global:PrunletLatestFixture.source = $updatedSource
    $global:PrunletLatestFixture.sha = 'd' * 40
    Test-Case 'Owned guide updates from its previous installed hash' {
        $agentHash = (Get-FileHash -LiteralPath $instructionAgents).Hash
        & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $instructionInstall -RegisterCodex -RegisterAgentInstructions -CodexHome $instructionCodex -SettingsBackupDirectory $instructionBackup -WorkDirectory (Join-Path $OutputDirectory 'instruction-update-work') | Out-Null
        Assert-True ([IO.File]::ReadAllText($instructionGuide).Contains('Fixture guide update.')) 'Owned guide did not update.'
        Assert-True ($agentHash -eq (Get-FileHash -LiteralPath $instructionAgents).Hash) 'Guide update changed existing AGENTS.'
    }
    $lineEndingSource = New-FixtureSource (Join-Path $fixtureRoot 'source-line-ending-guide')
    [IO.File]::AppendAllText((Join-Path $lineEndingSource 'integration\PRUNLET.md'), "`nFixture guide update.`nLine-ending fixture update.`n", [Text.UTF8Encoding]::new($false))
    Test-Case 'Non-managed update accepts a registered guide that differs from the previous bin only by line endings' {
        $installedGuide = Join-Path $instructionInstall 'bin\PRUNLET.md'
        $installedText = [IO.File]::ReadAllText($installedGuide)
        $lfText = $installedText.Replace("`r`n", "`n")
        # 前回binと逆の改行形式で登録済みガイドを置き、本文は変えない。
        $variant = if ($installedText.Contains("`r`n")) { $lfText } else { $lfText.Replace("`n", "`r`n") }
        Assert-True ($variant -cne $installedText) 'Line-ending fixture did not change the registered guide bytes.'
        [IO.File]::WriteAllText($instructionGuide, $variant, [Text.UTF8Encoding]::new($false))
        Assert-True ((Get-FileHash -LiteralPath $instructionGuide).Hash -cne (Get-FileHash -LiteralPath $installedGuide).Hash) 'Line-ending fixture equals the installed guide bytes.'
        $agentHash = (Get-FileHash -LiteralPath $instructionAgents).Hash
        # このケースだけ別fixtureを使い、後続ケースの入力は従来のupdated fixtureへ戻す。
        $global:PrunletLatestFixture.source = $lineEndingSource
        $global:PrunletLatestFixture.sha = 'e' * 40
        try {
            & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $instructionInstall -RegisterCodex -RegisterAgentInstructions -CodexHome $instructionCodex -SettingsBackupDirectory $instructionBackup -WorkDirectory (Join-Path $OutputDirectory 'instruction-line-ending-work') | Out-Null
            Assert-True ([IO.File]::ReadAllText($instructionGuide).Contains('Line-ending fixture update.')) 'Line-ending-only registered guide blocked the non-managed guide update.'
            Assert-True ((Get-FileHash -LiteralPath $instructionGuide).Hash -ceq (Get-FileHash -LiteralPath $installedGuide).Hash) 'Non-managed guide update did not install the verified guide.'
            Assert-True ($agentHash -eq (Get-FileHash -LiteralPath $instructionAgents).Hash) 'Line-ending guide update changed existing AGENTS.'
        } finally {
            # 後続ケースが前提とする「updated fixtureのbinと同じ登録ガイド」へ戻す（登録実物は所有判定を通る状態）。
            $global:PrunletLatestFixture.source = $updatedSource
            $global:PrunletLatestFixture.sha = 'd' * 40
            & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $instructionInstall -RegisterCodex -RegisterAgentInstructions -CodexHome $instructionCodex -SettingsBackupDirectory $instructionBackup -WorkDirectory (Join-Path $OutputDirectory 'instruction-line-ending-restore-work') | Out-Null
        }
        Assert-True (![IO.File]::ReadAllText($instructionGuide).Contains('Line-ending fixture update.') -and (Get-FileHash -LiteralPath $instructionGuide).Hash -ceq (Get-FileHash -LiteralPath $installedGuide).Hash) 'Line-ending case did not restore the updated fixture guide for later cases.'
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
    Test-Case 'Instruction helper treats line-ending-only guide differences as owned in real calls' {
        $lineCodex = Join-Path $OutputDirectory 'instruction-line-ending-helper'
        New-Item -ItemType Directory -Path $lineCodex | Out-Null
        $agentPath = Join-Path $lineCodex 'AGENTS.md'
        $guidePath = Join-Path $lineCodex 'PRUNLET.md'
        [IO.File]::WriteAllText($agentPath, "利用者の本文`n", [Text.UTF8Encoding]::new($false))
        $originalHash = (Get-FileHash -LiteralPath $agentPath).Hash
        $helper = Join-Path $instructionInstall 'bin\install-agent-instructions.ps1'
        $helperParameters = @{ SourceGuidePath = (Join-Path $instructionInstall 'bin\PRUNLET.md'); CodexHome = $lineCodex; BackupDirectory = $instructionBackup }
        & $helper @helperParameters | Out-Null
        $sourceText = [IO.File]::ReadAllText($guidePath)
        $lfText = $sourceText.Replace("`r`n", "`n")
        $variant = if ($sourceText.Contains("`r`n")) { $lfText } else { $lfText.Replace("`n", "`r`n") }
        Assert-True ($variant -cne $sourceText) 'Line-ending fixture did not change the registered guide bytes.'
        # 改行差だけなら所有と判定する。ValidateOnlyは変更不要とし、明示登録の実呼出しは検証済みsourceのバイト列を配置する。
        [IO.File]::WriteAllText($guidePath, $variant, [Text.UTF8Encoding]::new($false))
        $preview = & $helper @helperParameters -ValidateOnly
        Assert-True (!$preview.guideChanged) 'Line-ending-only registered guide was reported as changed.'
        & $helper @helperParameters | Out-Null
        Assert-True ((Get-FileHash -LiteralPath $guidePath).Hash -ceq (Get-FileHash -LiteralPath $helperParameters.SourceGuidePath).Hash) 'Explicit registration did not install the verified guide bytes.'
        # 改行以外の編集はValidateOnly・実呼出しの解除とも拒否して保全する。
        [IO.File]::WriteAllText($guidePath, ($variant + 'Edited body'), [Text.UTF8Encoding]::new($false))
        $editedHash = (Get-FileHash -LiteralPath $guidePath).Hash
        Expect-Failure { & $helper @helperParameters -Uninstall -ValidateOnly } 'edited or belongs'
        Expect-Failure { & $helper @helperParameters -Uninstall } 'edited or belongs'
        Assert-True ($editedHash -ceq (Get-FileHash -LiteralPath $guidePath).Hash) 'Rejected uninstall changed the edited guide.'
        # PreviousGuideSha256なしの実呼出し（uninstall-codex.ps1と同じ形）でも改行差だけなら解除できる。
        [IO.File]::WriteAllText($guidePath, $variant, [Text.UTF8Encoding]::new($false))
        $state = & $helper @helperParameters -Uninstall -ValidateOnly
        Assert-True ($state.instructionsPresent) 'Line-ending-only guide was not recognized as owned.'
        & $helper @helperParameters -Uninstall | Out-Null
        Assert-True (!(Test-Path -LiteralPath $guidePath)) 'Uninstall retained the line-ending-only owned guide.'
        Assert-True ($originalHash -eq (Get-FileHash -LiteralPath $agentPath).Hash) 'Line-ending-only uninstall did not restore original AGENTS bytes.'
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
            foreach ($codeBlock in $codeBlocks) { Assert-True (!$codeBlock.Value.Contains('Windowsのファイル・フォルダー・レジストリ削除では')) 'Agent instruction is inside a Markdown code block.' }
            $outsideCode = [regex]::Replace($html, '(?s)<pre><code.*?</code></pre>', '')
            Assert-True ($outsideCode.Contains('Windowsのファイル・フォルダー・レジストリ削除では')) 'Agent instruction is not rendered outside code examples.'
            Assert-True ($registered.EndsWith($text, [StringComparison]::Ordinal)) 'Registering instructions changed existing body or EOF bytes.'
            & (Join-Path $instructionInstall 'bin\install-agent-instructions.ps1') @helperParameters -Uninstall | Out-Null
            Assert-True ($originalHash -eq (Get-FileHash -LiteralPath $agentPath).Hash) 'Fenced document registration/removal did not restore original bytes.'
        }
    }
    $global:PrunletLatestFixture.source = $fixtureSource
    $managedRepository = Join-Path $OutputDirectory 'managed-git'
    $managedRoot = Join-Path $managedRepository 'runtimé'
    $managedRecovery = Join-Path $managedRoot 'recovery'
    Test-Case 'Managed update accepts only an ignored existing installation and preserves its stage' {
        New-Item -ItemType Directory -Path $managedRoot,$managedRecovery | Out-Null
        Copy-Item -LiteralPath (Join-Path $instructionInstall 'bin') -Destination $managedRoot -Recurse
        Copy-Item -LiteralPath (Join-Path $instructionInstall 'source-info.json') -Destination (Join-Path $managedRoot 'source-info.json')
        & (Join-Path $managedRoot 'bin\prunlet.exe') --config (Join-Path $managedRoot 'config.json') init --backup-directory $managedRecovery | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) 'Managed fixture configuration failed.'
        Set-FixtureVolumeMap (Join-Path $managedRoot 'config.json')
        $stage = Join-Path $managedRoot '.prunlet-update-stage'
        New-Item -ItemType Directory -Path $stage | Out-Null
        $sentinel = Join-Path $stage 'retained-fixture.txt'
        [IO.File]::WriteAllText($sentinel,'Preserve the previous update stage.')
        $stageHash = (Get-FileHash -LiteralPath $sentinel).Hash
        & git -C $managedRepository init --quiet
        Assert-True ($LASTEXITCODE -eq 0) 'Fixture Git init failed.'
        & git -C $managedRepository config core.ignorecase true
        Assert-True ($LASTEXITCODE -eq 0) 'Fixture case-insensitive index setup failed.'
        [IO.File]::WriteAllText((Join-Path $managedRepository '.gitignore'),"runtimé/`n")
        & $installer -UpdateManagedInstallation -ExpectedCommitSha $global:PrunletLatestFixture.sha -InstallDirectory $managedRoot -WorkDirectory (Join-Path $OutputDirectory 'managed-update-work') -UpdateBackupRoot $fixtureUpdateBackupRoot | Out-Null
        Assert-True ((Get-FileHash -LiteralPath $sentinel).Hash -ceq $stageHash) 'Existing update stage changed.'
        Assert-True ((Get-Content -LiteralPath (Join-Path $managedRoot 'source-info.json') -Raw | ConvertFrom-Json).commitSha -ceq $global:PrunletLatestFixture.sha) 'Managed update installed another source.'
    }
    Test-Case 'Normal installation still refuses an ignored installation inside Git' {
        $before = (Get-FileHash -LiteralPath (Join-Path $managedRoot 'source-info.json')).Hash
        Expect-Failure { & $installer -InstallDirectory $managedRoot -WorkDirectory (Join-Path $OutputDirectory 'managed-default-refused') -UpdateBackupRoot $fixtureUpdateBackupRoot } 'repository'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $managedRoot 'source-info.json')).Hash -ceq $before) 'Default refusal changed the installed product.'
    }
    Test-Case 'Registered managed update preserves the existing binding without changing Git excludes' {
        $managedCodex = Join-Path $OutputDirectory 'managed-codex'
        New-Item -ItemType Directory -Path $managedCodex | Out-Null
        $instruction = 'Windowsのファイル・フォルダー・レジストリ削除では、[PRUNLET.md](PRUNLET.md)を読み、Prunlet CLIを最初からCMD（shell=cmd.exe、login=false）で直接実行する。'
        $binding = [ordered]@{executablePath=(Join-Path $managedRoot 'bin\prunlet.exe');configPath=(Join-Path $managedRoot 'config.json')} | ConvertTo-Json -Compress
        $document = "<!-- BEGIN PRUNLET AGENT-INSTRUCTIONS -->`n"+$instruction+"`nPrunlet CLI: "+$binding+"`n<!-- END PRUNLET AGENT-INSTRUCTIONS -->`n"
        $agent = Join-Path $managedCodex 'AGENTS.md'
        [IO.File]::WriteAllText($agent,$document)
        $ignore = Join-Path $managedRepository '.gitignore'
        $originalIgnore = [IO.File]::ReadAllBytes($ignore)
        $priorCodexHome = $env:CODEX_HOME
        try {
            [IO.File]::WriteAllText($ignore,'')
            $env:CODEX_HOME = $managedCodex
            $initialGuide=[IO.File]::ReadAllText((Join-Path $managedRoot 'bin\PRUNLET.md')).Replace("`r`n","`n").Replace("`n","`r`n")
            [IO.File]::WriteAllText((Join-Path $managedCodex 'PRUNLET.md'),$initialGuide,[Text.UTF8Encoding]::new($false))
            & $installer -UpdateManagedInstallation -ExpectedCommitSha $global:PrunletLatestFixture.sha -CodexHome $managedCodex -InstallDirectory $managedRoot -WorkDirectory (Join-Path $OutputDirectory 'managed-registered-work') -UpdateBackupRoot $fixtureUpdateBackupRoot -RegisterCodex -RegisterAgentInstructions | Out-Null
            Assert-True ((Get-FileHash -LiteralPath (Join-Path $managedCodex 'PRUNLET.md')).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $managedRoot 'bin\PRUNLET.md')).Hash) 'Managed guide registration did not install the verified guide.'
            Assert-True ([IO.File]::ReadAllText($ignore) -ceq '') 'Managed update changed Git exclusion rules.'
            Assert-True ([IO.File]::ReadAllText($agent) -ceq $document) 'Managed update changed its registration without a registration request.'
            $before = (Get-FileHash -LiteralPath (Join-Path $managedRoot 'source-info.json')).Hash
            $Repository='1llum1n4t1s/Prunlet'; $Runtime='win-x64'; $CodexHome=$managedCodex
            $script:ForbiddenRoots=@($repoRoot,$managedCodex,(Join-Path $env:USERPROFILE '.codex'))
            foreach ($definition in $installerAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Test-InTree','Assert-PlainPath','Assert-ExternalPath','Test-RegisteredManagedInstallation','Assert-ManagedExistingPath','Read-ManagedInstallationJson','Get-ManagedInstallationSnapshot','Assert-ManagedInstallationSnapshot','Get-GuideRegistrationPreviousHash','Get-ManagedGuideRegistrationHash')},$true)) { . ([scriptblock]::Create($definition.Extent.Text)) }
            $snapshot=Get-ManagedInstallationSnapshot $managedRoot
            $registeredGuide=Join-Path $managedCodex 'PRUNLET.md'
            $guideText=[IO.File]::ReadAllText((Join-Path $managedRoot 'bin\PRUNLET.md')).Replace("`r`n","`n").Replace("`n","`r`n")
            [IO.File]::WriteAllText($registeredGuide,$guideText,[Text.UTF8Encoding]::new($false))
            $guideParameters=@{SourceGuidePath=(Join-Path $repoRoot 'integration\PRUNLET.md');CodexHome=$managedCodex;ExecutablePath=(Join-Path $managedRoot 'bin\prunlet.exe');ConfigPath=(Join-Path $managedRoot 'config.json');PreviousGuideSha256=(Get-ManagedGuideRegistrationHash $snapshot);ValidateOnly=$true}
            & (Join-Path $repoRoot 'integration\install-agent-instructions.ps1') @guideParameters | Out-Null
            [IO.File]::WriteAllText($registeredGuide,($guideText+'Edited body'),[Text.UTF8Encoding]::new($false))
            Expect-Failure { & (Join-Path $repoRoot 'integration\install-agent-instructions.ps1') @guideParameters } 'edited or belongs'
            $guideParameters.PreviousGuideSha256=Get-ManagedGuideRegistrationHash $snapshot
            Expect-Failure { & (Join-Path $repoRoot 'integration\install-agent-instructions.ps1') @guideParameters } 'edited or belongs'
            [IO.File]::WriteAllText($registeredGuide,$guideText.Insert(($guideText.IndexOf('Windows')+1),[string][char]0x200d),[Text.UTF8Encoding]::new($false))
            $guideParameters.PreviousGuideSha256=Get-ManagedGuideRegistrationHash $snapshot
            Expect-Failure { & (Join-Path $repoRoot 'integration\install-agent-instructions.ps1') @guideParameters } 'edited or belongs'
            [IO.File]::WriteAllText($registeredGuide,$guideText,[Text.UTF8Encoding]::new($false))
            foreach ($invalid in @($document.Replace('Prunlet CLI: ','CLI example: '),($document+$document),$document.Replace($instruction,'Unowned instruction'),$document.Replace($instruction,$instruction.Insert(1,[string][char]0x200d)),$document.Replace('prunlet.exe','other.exe'))) {
                [IO.File]::WriteAllText($agent,$invalid)
                Expect-Failure { Assert-ManagedInstallationSnapshot $snapshot } 'Git-ignored'
                Expect-Failure { & $installer -UpdateManagedInstallation -CodexHome $managedCodex -InstallDirectory $managedRoot -WorkDirectory (Join-Path $OutputDirectory ('managed-binding-refused-'+[guid]::NewGuid().ToString('N'))) -UpdateBackupRoot $fixtureUpdateBackupRoot } 'Git-ignored'
                Assert-True ((Get-FileHash -LiteralPath (Join-Path $managedRoot 'source-info.json')).Hash -ceq $before) 'Invalid registration changed installed products.'
            }
        } finally { $env:CODEX_HOME=$priorCodexHome; [IO.File]::WriteAllBytes($ignore,$originalIgnore); [IO.File]::WriteAllText($agent,$document) }
    }
    Test-Case 'Managed update refuses an unknown ignored directory' {
        $unknown = Join-Path $managedRoot 'unknown'
        New-Item -ItemType Directory -Path (Join-Path $unknown 'bin') | Out-Null
        Expect-Failure { & $installer -UpdateManagedInstallation -InstallDirectory $unknown -WorkDirectory (Join-Path $OutputDirectory 'managed-unknown-refused') -UpdateBackupRoot $fixtureUpdateBackupRoot } 'existing installation'
        Assert-True (!(Test-Path -LiteralPath (Join-Path $unknown 'config.json'))) 'Unknown directory was initialized.'
        Expect-Failure { & $installer -UpdateManagedInstallation -InstallDirectory $instructionInstall -WorkDirectory (Join-Path $OutputDirectory 'managed-outside-git-refused') -UpdateBackupRoot $fixtureUpdateBackupRoot } 'inside Git'
    }
    Test-Case 'Managed update rejects tracked files and a nonignored directory before writes' {
        $ignore = Join-Path $managedRepository '.gitignore'
        $originalIgnore = [IO.File]::ReadAllBytes($ignore)
        [IO.File]::WriteAllText($ignore,'')
        Expect-Failure { & $installer -UpdateManagedInstallation -InstallDirectory $managedRoot -WorkDirectory (Join-Path $OutputDirectory 'managed-notignored-refused') -UpdateBackupRoot $fixtureUpdateBackupRoot } 'Git-ignored'
        $tracked = Join-Path $managedRoot 'tracked-sentinel.txt'
        [IO.File]::WriteAllText($tracked,'Tracked source must be preserved.')
        & git -C $managedRepository add -- runtimé/tracked-sentinel.txt
        Assert-True ($LASTEXITCODE -eq 0) 'Fixture index setup failed.'
        try {
            [IO.File]::WriteAllText($ignore,"*`n")
            $before = (Get-FileHash -LiteralPath (Join-Path $managedRoot 'bin\prunlet.exe')).Hash
            Expect-Failure { & $installer -UpdateManagedInstallation -InstallDirectory $managedRoot -WorkDirectory (Join-Path $OutputDirectory 'managed-tracked-refused') -UpdateBackupRoot $fixtureUpdateBackupRoot } 'tracked files'
            Expect-Failure { & $installer -UpdateManagedInstallation -InstallDirectory $managedRoot.ToUpperInvariant() -WorkDirectory (Join-Path $OutputDirectory 'managed-tracked-case-refused') -UpdateBackupRoot $fixtureUpdateBackupRoot } 'tracked files'
            Assert-True ((Get-FileHash -LiteralPath (Join-Path $managedRoot 'bin\prunlet.exe')).Hash -ceq $before) 'Tracked refusal changed the product.'
        } finally {
            & git -C $managedRepository update-index --force-remove -- runtimé/tracked-sentinel.txt
            Assert-True ($LASTEXITCODE -eq 0) 'Fixture index restoration failed.'
            [IO.File]::WriteAllBytes($ignore,$originalIgnore)
        }
    }
    Test-Case 'Managed update pins configuration and refuses linked recovery and Git indirection' {
        $Repository = '1llum1n4t1s/Prunlet'; $Runtime = 'win-x64'; $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
        $script:ForbiddenRoots = @($repoRoot,(Join-Path $env:USERPROFILE '.codex'))
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($installer,[ref]$tokens,[ref]$parseErrors)
        foreach ($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Test-InTree','Assert-PlainPath','Assert-ExternalPath','Test-RegisteredManagedInstallation','Assert-ManagedExistingPath','Read-ManagedInstallationJson','Get-ManagedInstallationSnapshot','Assert-ManagedInstallationSnapshot','Assert-ManagedRecoveryBinding')},$true)) { . ([scriptblock]::Create($definition.Extent.Text)) }
        $snapshot = Get-ManagedInstallationSnapshot $managedRoot
        $configPath = Join-Path $managedRoot 'config.json'
        $original = [IO.File]::ReadAllBytes($configPath)
        $alternate = Join-Path $managedRoot 'alternate-recovery'
        New-Item -ItemType Directory -Path $alternate | Out-Null
        try {
            $document = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
            $document.volumeRecoveryDirectories = @{ (Get-VerificationVolumeRoot $alternate) = $alternate }
            [IO.File]::WriteAllText($configPath,($document | ConvertTo-Json -Depth 20))
            Expect-Failure { Assert-ManagedRecoveryBinding $snapshot } 'changed'
            [IO.File]::WriteAllBytes($configPath,$original)
            $document = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            $document.backupDirectory = $alternate
            [IO.File]::WriteAllText($configPath,($document | ConvertTo-Json -Depth 20))
            Expect-Failure { Assert-ManagedInstallationSnapshot $snapshot } 'changed'
            Expect-Failure { Assert-ManagedRecoveryBinding $snapshot } 'changed'
            $link = Join-Path $managedRoot 'recovery-link'
            New-Item -ItemType Junction -Path $link -Target $managedRecovery | Out-Null
            $document.backupDirectory = $link
            [IO.File]::WriteAllText($configPath,($document | ConvertTo-Json -Depth 20))
            Expect-Failure { Get-ManagedInstallationSnapshot $managedRoot } 'links'
        } finally { [IO.File]::WriteAllBytes($configPath,$original) }
        $guide = Join-Path $managedRoot 'bin\PRUNLET.md'
        $originalGuide = [IO.File]::ReadAllBytes($guide)
        try { [IO.File]::WriteAllText($guide,'Changed auxiliary data'); Expect-Failure { Get-ManagedInstallationSnapshot $managedRoot } 'auxiliary hash' } finally { [IO.File]::WriteAllBytes($guide,$originalGuide) }
        $priorGitDir = $env:GIT_DIR
        try { $env:GIT_DIR=Join-Path $managedRepository '.git'; Expect-Failure { Get-ManagedInstallationSnapshot $managedRoot } 'physical Git' } finally { $env:GIT_DIR=$priorGitDir }
        Expect-Failure { Assert-ManagedExistingPath $repoRoot } 'source or Codex'
    }
    Test-Case 'Expected source commit mismatch stops before replacing managed products' {
        $before = (Get-FileHash -LiteralPath (Join-Path $managedRoot 'source-info.json')).Hash
        Expect-Failure { & $installer -UpdateManagedInstallation -ExpectedCommitSha ('0'*40) -InstallDirectory $managedRoot -WorkDirectory (Join-Path $OutputDirectory 'managed-sha-refused') -UpdateBackupRoot $fixtureUpdateBackupRoot } 'ExpectedCommitSha'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $managedRoot 'source-info.json')).Hash -ceq $before) 'Commit mismatch changed installed provenance.'
    }
    # ---- MCPに頼らない更新（start-prunlet-mcp.ps1 -UpdateOnly）と更新タスク ----
    # 旧版は実行可能なままhashだけを変えた製品（末尾にoverlay）で導入し、今回のビルドを新releaseとして切り替える。
    $oldPublish = Join-Path $fixtureRoot 'old-publish'
    New-Item -ItemType Directory -Path $oldPublish | Out-Null
    foreach ($leaf in @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe')) {
        $copy = Join-Path $oldPublish $leaf
        [IO.File]::Copy((Join-Path $fixturePublish $leaf), $copy)
        $stream = [IO.File]::Open($copy, [IO.FileMode]::Append, [IO.FileAccess]::Write)
        try { $stream.Write([Text.Encoding]::UTF8.GetBytes('Prunlet update-only previous release fixture')) } finally { $stream.Dispose() }
    }
    $oldCommit = '1' * 40
    $newCommit = '2' * 40
    function Install-PreviousRelease([string]$Name, [string]$CodexHome, [switch]$RegisterCodex) {
        $global:PrunletLatestFixture.sha = $oldCommit
        $global:PrunletLatestFixture.source = $fixtureSource
        $global:PrunletLatestFixture.publish = $oldPublish
        $root = Join-Path $OutputDirectory $Name
        $parameters = @{ UpdateBackupRoot = $fixtureUpdateBackupRoot; InstallDirectory = $root; WorkDirectory = (Join-Path $OutputDirectory ($Name + '-work')); CodexHome = $CodexHome }
        if ($RegisterCodex) { $parameters.RegisterCodex = $true; $parameters.SettingsBackupDirectory = $settingsBackup }
        $result = & $installer @parameters | ConvertFrom-Json -AsHashtable
        Assert-True ($result.status -ceq 'installed' -and $result.commitSha -ceq $oldCommit) "Previous release fixture was not installed: $Name"
        Set-FixtureVolumeMap (Join-Path $root 'config.json')
        return $root
    }
    # 公開するcommit・導入済みとして期待するcommit・製品の出所は既定で次releaseだが、導入後の再実行などで変えられる。
    function Publish-NextRelease([string]$Root, [string]$Sha = $newCommit, [string]$Installed = $oldCommit, [string]$Publish = $fixturePublish) {
        # 新releaseを公開し、HTTP取得だけを「検証済みZIPを取得完了の位置へ置く」ことで代替する（Rustの取得は既存hashを再利用する）。
        $global:PrunletLatestFixture.sha = $Sha
        $global:PrunletLatestFixture.source = $fixtureSource
        $global:PrunletLatestFixture.publish = $Publish
        $package = Get-FixturePackage
        $begin = & (Join-Path $Root 'bin\prunlet.exe') --config (Join-Path $Root 'config.json') __begin-published-update $Sha $Installed
        Assert-True ($LASTEXITCODE -eq 0) "Update stage could not be prepared: $begin"
        $state = [IO.File]::ReadAllText((Join-Path $Root '.prunlet-update-state.json')) | ConvertFrom-Json -AsHashtable
        # 適用済みstageの再利用では、前回の配布ZIPが同名で残る。取得完了の位置へ置くfixtureとして上書きする（取得自体は検証しない）。
        [IO.File]::Copy($package, (Join-Path (Join-Path $Root '.prunlet-update-stage') $state.packageName), $true)
        return $package
    }
    function Invoke-UpdateOnly([string]$Root, [string]$CodexHome) {
        & (Join-Path $Root 'bin\start-prunlet-mcp.ps1') -UpdateOnly -ExecutablePath (Join-Path $Root 'bin\prunlet.exe') -ConfigPath (Join-Path $Root 'config.json') -CodexHome $CodexHome
        return $LASTEXITCODE
    }
    # -CodexHomeを渡さない起動（単独アプリとしてのMCPホスト・更新タスク）。実効のCodexHomeは
    # 実PCの~/.codexを読まないよう、検証用の絶対パスをCODEX_HOMEで指定する。
    function Invoke-UpdateOnlyWithoutCodexHome([string]$Root, [string]$EffectiveCodexHome) {
        $previous = $env:CODEX_HOME
        $env:CODEX_HOME = $EffectiveCodexHome
        try {
            & (Join-Path $Root 'bin\start-prunlet-mcp.ps1') -UpdateOnly -ExecutablePath (Join-Path $Root 'bin\prunlet.exe') -ConfigPath (Join-Path $Root 'config.json')
            return $LASTEXITCODE
        } finally { $env:CODEX_HOME = $previous }
    }
    # 起動時更新の出力（延期の警告を含む）と終了コードを両方返す。
    function Invoke-UpdateOnlyCaptured([string]$Root, [string]$CodexHome) {
        # 延期の警告はlauncherが[Console]::Errorへ直接書くため、その間だけ標準エラーをStringWriterへ差し替えて取得する。
        $previousError = [Console]::Error
        $writer = [IO.StringWriter]::new()
        [Console]::SetError($writer)
        try { $text = & (Join-Path $Root 'bin\start-prunlet-mcp.ps1') -UpdateOnly -ExecutablePath (Join-Path $Root 'bin\prunlet.exe') -ConfigPath (Join-Path $Root 'config.json') -CodexHome $CodexHome *>&1 | Out-String; $code = $LASTEXITCODE }
        finally { [Console]::SetError($previousError) }
        return @{ exitCode = $code; text = ($text + $writer.ToString()) }
    }
    # 導入・取得直後の製品へウイルス対策などが一時的に書込み不可の開き方をすると、launcherは正規の延期として
    # 「existing process」で戻る。その一時的な延期だけを短く再試行し、他の結果は最初の1回で判定する。
    function Invoke-UpdateOnlyUntilApplied([string]$Root, [string]$CodexHome, [string]$Commit) {
        for ($attempt = 1; ; $attempt++) {
            $result = Invoke-UpdateOnlyCaptured $Root $CodexHome
            if ((Get-InstalledCommit $Root) -ceq $Commit -or $attempt -ge 5 -or $result.text -notmatch 'existing process is active') { return $result }
            Start-Sleep -Seconds 2
        }
    }
    function Get-InstalledCommit([string]$Root) { return ([IO.File]::ReadAllText((Join-Path $Root 'source-info.json')) | ConvertFrom-Json).commitSha }
    function Get-UpdatePhase([string]$Root) { return ([IO.File]::ReadAllText((Join-Path $Root '.prunlet-update-state.json')) | ConvertFrom-Json).phase }
    Test-Case 'Update-only launcher switches a Codex-less installation to the next release without starting MCP' {
        # ryzenx3dの状況: Codexの登録がなく、MCPが起動されないPC。
        $noCodex = Join-Path $OutputDirectory 'update-only-no-codex'
        $root = Install-PreviousRelease 'update-only-install' $noCodex
        Assert-True (!(Test-Path -LiteralPath $noCodex)) 'Codex-less installation created a Codex home.'
        $package = Publish-NextRelease $root
        $exitCode = Invoke-UpdateOnly $root $noCodex
        Assert-True ($exitCode -eq 0) "Update-only launcher failed: $exitCode"
        Assert-True ((Get-InstalledCommit $root) -ceq $newCommit -and (Get-UpdatePhase $root) -ceq 'idle') 'Update-only launcher did not switch to the next release.'
        foreach ($name in @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe')) {
            Assert-True ((Get-FileHash -LiteralPath (Join-Path $root ('bin\' + $name))).Hash -ceq ($fixtureProducts | Where-Object name -eq $name).sha256) "Update-only switch left a previous product: $name"
        }
        Assert-True (!(Test-Path -LiteralPath $noCodex)) 'Update-only launcher created a Codex home.'
        # 最新を確認できた2回目は何も変えずに正常終了する。
        $before = (Get-FileHash -LiteralPath (Join-Path $root 'source-info.json')).Hash
        Assert-True ((Invoke-UpdateOnly $root $noCodex) -eq 0 -and (Get-FileHash -LiteralPath (Join-Path $root 'source-info.json')).Hash -ceq $before) 'Current update-only check changed the installation.'
    }
    Test-Case 'Installer rerun after a startup update does not stop later startup updates' {
        # 起動時更新で適用済み（stage保持）の配置へ、手動でインストーラーを再実行した後も、
        # 次のreleaseの起動時更新は延期されず適用される。インストーラーは更新状態とstageに触れない。
        $noCodex = Join-Path $OutputDirectory 'update-rerun-no-codex'
        $root = Install-PreviousRelease 'update-rerun-install' $noCodex
        $null = Publish-NextRelease $root
        $first = Invoke-UpdateOnlyUntilApplied $root $noCodex $newCommit
        Assert-True ($first.exitCode -eq 0 -and (Get-InstalledCommit $root) -ceq $newCommit -and (Get-UpdatePhase $root) -ceq 'idle') "The first startup update did not apply (exit $($first.exitCode), commit $(Get-InstalledCommit $root), phase $(Get-UpdatePhase $root)): $($first.text)"
        $statePath = Join-Path $root '.prunlet-update-state.json'
        $stageRoot = Join-Path $root '.prunlet-update-stage'
        Assert-True ((Test-Path -LiteralPath $stageRoot -PathType Container) -and ([IO.File]::ReadAllText($statePath) | ConvertFrom-Json).stageCleanup -ceq 'pending') 'The applied stage was not retained.'
        # 手動導入: 旧overlay製品の別commitで、実際のインストーラーを再実行する。
        $manualCommit = '3' * 40
        $global:PrunletLatestFixture.sha = $manualCommit
        $global:PrunletLatestFixture.source = $fixtureSource
        $global:PrunletLatestFixture.publish = $oldPublish
        $stateBefore = (Get-FileHash -LiteralPath $statePath).Hash
        $stageBefore = (Get-ChildItem -LiteralPath $stageRoot -Recurse -Force -File | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($stageRoot.Length) + '=' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join "`n"
        $rerun = & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $root -WorkDirectory (Join-Path $OutputDirectory 'update-rerun-work') -CodexHome $noCodex | ConvertFrom-Json -AsHashtable
        Assert-True ($rerun.status -ceq 'installed' -and $rerun.commitSha -ceq $manualCommit -and (Get-InstalledCommit $root) -ceq $manualCommit) 'The installer rerun did not install the manual release.'
        Assert-True ((Get-FileHash -LiteralPath $statePath).Hash -ceq $stateBefore) 'The installer rerun changed the update state.'
        $stageAfter = (Get-ChildItem -LiteralPath $stageRoot -Recurse -Force -File | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($stageRoot.Length) + '=' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join "`n"
        Assert-True ($stageAfter -ceq $stageBefore) 'The installer rerun changed the retained update stage.'
        # 次のrelease（今回のビルド）を、手動導入したcommitを導入済みとして公開する。
        $laterCommit = '4' * 40
        $null = Publish-NextRelease $root $laterCommit $manualCommit
        $result = Invoke-UpdateOnlyUntilApplied $root $noCodex $laterCommit
        Assert-True ($result.exitCode -eq 0) "The update after the installer rerun failed: $($result.text)"
        Assert-True ((Get-InstalledCommit $root) -ceq $laterCommit -and (Get-UpdatePhase $root) -ceq 'idle') "The update after the installer rerun did not apply: $($result.text)"
        Assert-True ($result.text -notmatch '(?i)deferred') "The update after the installer rerun was deferred: $($result.text)"
        foreach ($name in @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe')) {
            Assert-True ((Get-FileHash -LiteralPath (Join-Path $root ('bin\' + $name))).Hash -ceq ($fixtureProducts | Where-Object name -eq $name).sha256) "The update after the installer rerun left a previous product: $name"
        }
        Assert-True (!(Test-Path -LiteralPath $noCodex)) 'The update after the installer rerun created a Codex home.'
    }
    Test-Case 'Update-only launcher defers when the maintenance executable is in use' {
        $noCodex = Join-Path $OutputDirectory 'update-busy-no-codex'
        $root = Install-PreviousRelease 'update-busy-install' $noCodex
        $null = Publish-NextRelease $root
        # 書込みを共有しない読取りで保持すると、起動時更新の使用中判定が働く。
        $hold = [IO.File]::Open((Join-Path $root 'bin\prunlet-maintenance.exe'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { Assert-True ((Invoke-UpdateOnly $root $noCodex) -eq 0) 'Busy deferral did not exit normally.' }
        finally { $hold.Dispose() }
        Assert-True ((Get-InstalledCommit $root) -ceq $oldCommit) 'Update-only launcher replaced products that were in use.'
        Assert-True ((Invoke-UpdateOnly $root $noCodex) -eq 0 -and (Get-InstalledCommit $root) -ceq $newCommit) 'Deferred update did not resume after the product was released.'
    }
    Test-Case 'Installer refuses to overwrite products while an update is in progress' {
        $noCodex = Join-Path $OutputDirectory 'installer-phase-no-codex'
        $root = Install-PreviousRelease 'installer-phase-install' $noCodex
        $null = Publish-NextRelease $root
        $statePath = Join-Path $root '.prunlet-update-state.json'
        $original = [IO.File]::ReadAllText($statePath)
        Assert-True ($original.Contains('"phase":"idle"')) 'The fixture state is not idle.'
        # 切替の途中（idle以外）を再現する。導入は製品も更新状態も変えずに拒否される。
        [IO.File]::WriteAllText($statePath, $original.Replace('"phase":"idle"', '"phase":"switching"'), [Text.UTF8Encoding]::new($false))
        $manualCommit = '3' * 40
        $global:PrunletLatestFixture.sha = $manualCommit
        $global:PrunletLatestFixture.source = $fixtureSource
        $global:PrunletLatestFixture.publish = $oldPublish
        $beforeState = (Get-FileHash -LiteralPath $statePath).Hash
        $beforeInfo = (Get-FileHash -LiteralPath (Join-Path $root 'source-info.json')).Hash
        $beforeProducts = (Get-ChildItem -LiteralPath (Join-Path $root 'bin') -File | Sort-Object Name | ForEach-Object { $_.Name + '=' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ';'
        $parameters = @{ UpdateBackupRoot = $fixtureUpdateBackupRoot; InstallDirectory = $root; WorkDirectory = (Join-Path $OutputDirectory 'installer-phase-work'); CodexHome = $noCodex }
        Expect-Failure { & $installer @parameters } 'update is in progress \(phase: switching\)'
        Assert-True ((Get-FileHash -LiteralPath $statePath).Hash -ceq $beforeState -and (Get-FileHash -LiteralPath (Join-Path $root 'source-info.json')).Hash -ceq $beforeInfo) 'The refused installation changed the state or provenance.'
        $afterProducts = (Get-ChildItem -LiteralPath (Join-Path $root 'bin') -File | Sort-Object Name | ForEach-Object { $_.Name + '=' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ';'
        Assert-True ($afterProducts -ceq $beforeProducts) 'The refused installation changed installed products.'
        # idleへ戻れば導入できる（拒否の条件は更新状態のphaseだけ）。
        [IO.File]::WriteAllText($statePath, $original, [Text.UTF8Encoding]::new($false))
        $parameters.WorkDirectory = Join-Path $OutputDirectory 'installer-phase-work-2'
        $rerun = & $installer @parameters | ConvertFrom-Json -AsHashtable
        Assert-True ($rerun.status -ceq 'installed' -and (Get-InstalledCommit $root) -ceq $manualCommit) 'The installer did not install once the update state was idle.'
    }
    Test-Case 'Update-only launcher reports the CLI refusal reason when it defers an update' {
        $noCodex = Join-Path $OutputDirectory 'update-reason-no-codex'
        $root = Install-PreviousRelease 'update-reason-install' $noCodex
        $first = '5' * 40
        $null = Publish-NextRelease $root $first
        # 未適用の候補の所有印が他の導入先を指す（照合が通らない）状態で、さらに次のreleaseが来る。
        $owner = Join-Path $root '.prunlet-update-stage\.prunlet-stage-owner.json'
        $value = [IO.File]::ReadAllText($owner) | ConvertFrom-Json -AsHashtable
        $value.installRoot = 'D:\unowned'
        [IO.File]::WriteAllText($owner, ($value | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $global:PrunletLatestFixture.sha = '6' * 40
        $global:PrunletLatestFixture.source = $fixtureSource
        $global:PrunletLatestFixture.publish = $fixturePublish
        $stateBefore = (Get-FileHash -LiteralPath (Join-Path $root '.prunlet-update-state.json')).Hash
        $result = Invoke-UpdateOnlyCaptured $root $noCodex
        Assert-True ($result.exitCode -eq 0) "A refused begin must defer, not fail the launcher: $($result.text)"
        Assert-True ($result.text -match 'Published update state could not be prepared\.\s+Stage ownership does not match') "The deferral did not carry the CLI refusal reason: $($result.text)"
        Assert-True ((Get-InstalledCommit $root) -ceq $oldCommit -and (Get-FileHash -LiteralPath (Join-Path $root '.prunlet-update-state.json')).Hash -ceq $stateBefore) 'The refused update changed the installation or its state.'
    }
    Test-Case 'Update-only launcher keeps Codex registration protection when Codex is registered' {
        $codex = Join-Path $OutputDirectory 'update-registered-codex'
        $root = Install-PreviousRelease 'update-registered-install' $codex -RegisterCodex
        $null = Publish-NextRelease $root
        # 利用者がPrunletのMCP blockを編集した状態。登録の見直しが必要なので、製品を切り替えずに延期する。
        $tomlPath = Join-Path $codex 'config.toml'
        $edited = [IO.File]::ReadAllText($tomlPath).Replace('startup_timeout_sec = 600', 'startup_timeout_sec = 601')
        Assert-True ($edited -cne [IO.File]::ReadAllText($tomlPath)) 'Registration edit fixture did not change config.toml.'
        [IO.File]::WriteAllText($tomlPath, $edited, [Text.UTF8Encoding]::new($false))
        $tomlHash = (Get-FileHash -LiteralPath $tomlPath).Hash
        Assert-True ((Invoke-UpdateOnly $root $codex) -eq 0) 'Registration deferral did not exit normally.'
        Assert-True ((Get-InstalledCommit $root) -ceq $oldCommit -and (Get-UpdatePhase $root) -ceq 'idle') 'Update-only launcher bypassed changed Codex registration.'
        Assert-True ((Get-FileHash -LiteralPath $tomlPath).Hash -ceq $tomlHash) 'Update-only launcher rewrote the edited Codex registration.'
    }
    Test-Case 'Standalone installation omits CodexHome from the update task and updates without it' {
        # 単独のアプリとしての導入: Codexへ登録せず、CodexHomeにもPrunletの登録がない。
        $absentCodex = Join-Path $OutputDirectory 'standalone-absent-codex'
        $root = Install-PreviousRelease 'standalone-install' $absentCodex
        Assert-True (!(Test-Path -LiteralPath $absentCodex)) 'Standalone installation created a Codex home.'
        . (Join-Path $root 'bin\maintenance-task.ps1')
        $taskState = Get-PrunletUpdateTaskState (Join-Path $root 'bin\prunlet.exe') (Join-Path $root 'config.json') ''
        Assert-True ([bool]$taskState.previousXml) 'Standalone installation did not register the update task.'
        $arguments = ([xml]$taskState.previousXml).Task.Actions.Exec.Arguments
        Assert-True (!$arguments.Contains('-CodexHome')) "Standalone update task still passes CodexHome: $arguments"
        $null = Publish-NextRelease $root
        Assert-True ((Invoke-UpdateOnlyWithoutCodexHome $root $absentCodex) -eq 0) 'Update-only launcher without CodexHome failed.'
        Assert-True ((Get-InstalledCommit $root) -ceq $newCommit -and (Get-UpdatePhase $root) -ceq 'idle') 'Update-only launcher without CodexHome did not switch to the next release.'
        Assert-True (!(Test-Path -LiteralPath $absentCodex)) 'Update-only launcher without CodexHome created a Codex home.'
        # 起動時更新での移行は、既存タスクの-CodexHomeなしを引き継ぐ。
        $after = ([xml]$global:PrunletMaintenanceFixture.tasks[$taskState.name]).Task.Actions.Exec.Arguments
        Assert-True (!$after.Contains('-CodexHome')) "Startup update added CodexHome to the standalone task: $after"
        $preserved = Get-PrunletUpdateTaskState (Join-Path $root 'bin\prunlet.exe') (Join-Path $root 'config.json') (Join-Path $OutputDirectory 'other-codex') -PreserveCodexHome
        Assert-True (!$preserved.arguments.Contains('-CodexHome') -and !$preserved.codexHome) 'PreserveCodexHome did not keep the absent CodexHome.'
    }
    Test-Case 'Launcher without CodexHome still protects a Codex registration in the effective CodexHome' {
        $codex = Join-Path $OutputDirectory 'effective-registered-codex'
        $root = Install-PreviousRelease 'effective-registered-install' $codex -RegisterCodex
        $null = Publish-NextRelease $root
        $tomlPath = Join-Path $codex 'config.toml'
        $edited = [IO.File]::ReadAllText($tomlPath).Replace('startup_timeout_sec = 600', 'startup_timeout_sec = 601')
        Assert-True ($edited -cne [IO.File]::ReadAllText($tomlPath)) 'Registration edit fixture did not change config.toml.'
        [IO.File]::WriteAllText($tomlPath, $edited, [Text.UTF8Encoding]::new($false))
        $tomlHash = (Get-FileHash -LiteralPath $tomlPath).Hash
        Assert-True ((Invoke-UpdateOnlyWithoutCodexHome $root $codex) -eq 0) 'Registration deferral without CodexHome did not exit normally.'
        Assert-True ((Get-InstalledCommit $root) -ceq $oldCommit -and (Get-UpdatePhase $root) -ceq 'idle') 'Launcher without CodexHome bypassed the effective Codex registration.'
        Assert-True ((Get-FileHash -LiteralPath $tomlPath).Hash -ceq $tomlHash) 'Launcher without CodexHome rewrote the edited Codex registration.'
        . (Join-Path $root 'bin\maintenance-task.ps1')
        $taskState = Get-PrunletUpdateTaskState (Join-Path $root 'bin\prunlet.exe') (Join-Path $root 'config.json') $codex
        Assert-True (([xml]$taskState.previousXml).Task.Actions.Exec.Arguments.Contains('-CodexHome "' + $codex + '"')) 'Codex-registered installation did not keep CodexHome in the update task.'
    }
    Test-Case 'Update task is migrated only while owned and removed by explicit schedule uninstall' {
        . (Join-Path $repoRoot 'integration\maintenance-task.ps1')
        $root = Join-Path $OutputDirectory 'update-only-install'
        $exe = Join-Path $root 'bin\prunlet.exe'
        $config = Join-Path $root 'config.json'
        $noCodex = Join-Path $OutputDirectory 'update-only-no-codex'
        $state = Get-PrunletUpdateTaskState $exe $config $noCodex
        Assert-True ([bool]$state.previousXml) 'Installed update task is missing.'
        # 利用者が無効化した所有タスクは、CodexHomeを変えた再登録でも引数だけを移行し、無効化を保持する。
        $disabled = $state.previousXml.Replace('<Enabled>true</Enabled><ScheduleByDay>', '<Enabled>false</Enabled><ScheduleByDay>')
        Assert-True ($disabled -cne $state.previousXml) 'Disabled update task fixture did not change the XML.'
        $global:PrunletMaintenanceFixture.tasks[$state.name] = $disabled
        $moved = Get-PrunletUpdateTaskState $exe $config (Join-Path $OutputDirectory 'moved-codex')
        Register-PrunletUpdateTask $moved
        $migrated = [xml]$global:PrunletMaintenanceFixture.tasks[$state.name]
        Assert-True ($migrated.Task.Actions.Exec.Arguments -ceq $moved.arguments -and $migrated.Task.Triggers.CalendarTrigger.Enabled -ceq 'false') 'Update task migration changed user settings or kept the old launcher arguments.'
        Restore-PrunletUpdateTask $moved
        Assert-True ($global:PrunletMaintenanceFixture.tasks[$state.name] -ceq $disabled) 'Update task rollback did not restore the previous XML.'
        $foreign = $disabled.Replace($state.marker, 'Foreign update task')
        $global:PrunletMaintenanceFixture.tasks[$state.name] = $foreign
        Expect-Failure { Get-PrunletUpdateTaskState $exe $config $noCodex } 'not owned'
        Expect-Failure { Unregister-PrunletUpdateTask $exe $config $noCodex } 'not owned'
        Assert-True ($global:PrunletMaintenanceFixture.tasks[$state.name] -ceq $foreign) 'Foreign update task was modified.'
        $global:PrunletMaintenanceFixture.tasks[$state.name] = $disabled
        $maintenanceName = (Get-PrunletMaintenanceState $exe $config).name
        $removed = & (Join-Path $root 'bin\uninstall-maintenance.ps1') -ExecutablePath $exe -ConfigPath $config | ConvertFrom-Json
        Assert-True ($removed.updateTaskName -ceq $state.name -and !$global:PrunletMaintenanceFixture.tasks.ContainsKey($state.name) -and !$global:PrunletMaintenanceFixture.tasks.ContainsKey($maintenanceName)) 'Schedule uninstall retained the update or maintenance task.'
    }
    Test-Case 'Update task registration failure rolls back both tasks and product files' {
        $failedRoot = Join-Path $OutputDirectory 'update-task-failure-install'
        $beforeTasks = @($global:PrunletMaintenanceFixture.tasks.Keys)
        $global:PrunletLatestFixture.sha = $newCommit
        $global:PrunletLatestFixture.source = $fixtureSource
        $global:PrunletLatestFixture.publish = $fixturePublish
        $global:PrunletMaintenanceFixture.failAfterWriteName = 'Prunlet-Update-'
        try { Expect-Failure { & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $failedRoot -WorkDirectory (Join-Path $OutputDirectory 'update-task-failure-work') -CodexHome (Join-Path $OutputDirectory 'update-task-failure-codex') } 'Fixture update task registration failure' }
        finally { $global:PrunletMaintenanceFixture.failAfterWriteName = $null }
        Assert-True (!@($global:PrunletMaintenanceFixture.tasks.Keys | Where-Object { $beforeTasks -cnotcontains $_ }).Count) 'Failed update task registration left a scheduled task.'
        Assert-True (!(Test-Path -LiteralPath $failedRoot)) 'Failed update task registration left product files.'
    }
    Test-Case 'Edited update task defers the switch while the update state is still idle' {
        $noCodex = Join-Path $OutputDirectory 'update-edited-no-codex'
        $root = Install-PreviousRelease 'update-edited-install' $noCodex
        $null = Publish-NextRelease $root
        . (Join-Path $repoRoot 'integration\maintenance-task.ps1')
        $state = Get-PrunletUpdateTaskState (Join-Path $root 'bin\prunlet.exe') (Join-Path $root 'config.json') $noCodex
        $original = $state.previousXml
        # 利用者が実行先を差し替えたタスク。切替後に所有確認で止まると更新状態がidleへ戻らないため、切替前に延期する。
        $edited = $original.Replace([Security.SecurityElement]::Escape($state.command), 'C:\Users\Public\other.exe')
        Assert-True ($edited -cne $original) 'Edited update task fixture did not change the command.'
        $global:PrunletMaintenanceFixture.tasks[$state.name] = $edited
        try {
            Assert-True ((Invoke-UpdateOnly $root $noCodex) -eq 0) 'Edited task deferral did not exit normally.'
            Assert-True ((Get-InstalledCommit $root) -ceq $oldCommit -and (Get-UpdatePhase $root) -ceq 'idle') 'Edited update task stranded or bypassed the switch.'
            Assert-True ($global:PrunletMaintenanceFixture.tasks[$state.name] -ceq $edited) 'Update rewrote an edited update task.'
        } finally { $global:PrunletMaintenanceFixture.tasks[$state.name] = $original }
        Assert-True ((Invoke-UpdateOnly $root $noCodex) -eq 0 -and (Get-InstalledCommit $root) -ceq $newCommit -and (Get-UpdatePhase $root) -ceq 'idle') 'Update did not resume after the task was restored.'
    }
    Test-Case 'Installer from main skips the update task when the release package predates it' {
        # mainの新しいインストーラーで、更新タスク未対応の配布物を導入する場合。
        # 補助ファイルは更新タスク導入前の最終リリースタグから固定で取る（HEADは導入後に対応済みとなり旧版を表せない）。
        $legacyRevision = 'v1.0.42'
        $legacySource = New-FixtureSource (Join-Path $fixtureRoot 'source-without-update-task')
        foreach ($relative in @('integration/maintenance-task.ps1', 'integration/start-prunlet-mcp.ps1')) {
            # gitの出力はUTF-8。コンソールの文字コード（日本語環境のShift_JISなど）で読むと日本語コメントが
            # 化けて旧版スクリプトが構文エラーになるため、この読取りの間だけUTF-8で受け取る。
            $previousEncoding = [Console]::OutputEncoding
            [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
            try { $text = & git -C $repoRoot show ($legacyRevision + ':' + $relative) }
            finally { [Console]::OutputEncoding = $previousEncoding }
            Assert-True ($LASTEXITCODE -eq 0) "Committed $relative could not be read from tag $legacyRevision (fetch tags if missing)."
            [IO.File]::WriteAllText((Join-Path $legacySource $relative.Replace('/', '\')), (($text -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($false))
        }
        Assert-True (![IO.File]::ReadAllText((Join-Path $legacySource 'integration\maintenance-task.ps1')).Contains('Get-PrunletUpdateTaskState')) 'Legacy fixture already supports the update task.'
        $global:PrunletLatestFixture.sha = 'f' * 40
        $global:PrunletLatestFixture.source = $legacySource
        $global:PrunletLatestFixture.publish = $fixturePublish
        $legacyRoot = Join-Path $OutputDirectory 'legacy-package-install'
        $before = @($global:PrunletMaintenanceFixture.tasks.Keys)
        $result = & $installer -UpdateBackupRoot $fixtureUpdateBackupRoot -InstallDirectory $legacyRoot -WorkDirectory (Join-Path $OutputDirectory 'legacy-package-work') -CodexHome (Join-Path $OutputDirectory 'legacy-package-codex') | ConvertFrom-Json -AsHashtable
        Assert-True ($result.status -ceq 'installed' -and !$result.updateTaskRegistered -and !$result.updateTaskName) 'Installer registered an update task the packaged launcher cannot run.'
        $added = @($global:PrunletMaintenanceFixture.tasks.Keys | Where-Object { $before -cnotcontains $_ })
        Assert-True ($added.Count -eq 1 -and $added[0] -like 'Prunlet-Maintenance-*') "Legacy package registered unexpected tasks: $($added -join ',')"
    }
} finally {
    Remove-Item Function:\Invoke-RestMethod, Function:\Invoke-WebRequest, Function:\Copy-Item, Function:\Get-AuthenticodeSignature
    $fixturePackageHashes = @($global:PrunletLatestFixture.packages.GetEnumerator() | Sort-Object Value | ForEach-Object { @{ key = $_.Key.Replace($fixtureRoot, '<fixture>'); sha256 = (Get-FileHash -LiteralPath $_.Value -Algorithm SHA256).Hash } })
    Remove-Variable PrunletLatestFixture -Scope Global
    Remove-Item Function:\Get-ScheduledTask, Function:\Export-ScheduledTask, Function:\Register-ScheduledTask, Function:\Unregister-ScheduledTask
    Remove-Variable PrunletMaintenanceFixture -Scope Global
    # junctionと更新バックアップも隔離出力内に残し、結果確認後にPrunletで一括清掃する。
    [ordered]@{ fileFixtureRun = $fileFixtureRun; verifiedUtc = [DateTimeOffset]::UtcNow.ToString('o'); fixtureSource = 'update packages built by Package-PrunletUpdate.ps1 from the given build output and current working tree auxiliary files; Authenticode results are substituted except the real-signature refusal case'; fixtureProducts = $fixtureProducts; fixturePackages = $fixturePackageHashes; verificationInputFiles = $verificationInputFiles; fixtureArchiveSha256 = (Get-FileHash -LiteralPath $baseFixturePackage -Algorithm SHA256).Hash; fixtureGuideSha256 = $fixtureGuideSha256; publicHeadChecked = [bool]$CheckPublicHead; publicHeadAuthentication = $(if ($UseGitHubCliAuthentication) { 'github-cli' } else { 'unauthenticated' }); failureConditions = $failureConditions; results = @($results.ToArray()); passed = !@($results | Where-Object { !$_.passed }).Count; retention = 'Keep this report as reproducible installer verification evidence; delete when superseded.'; reproduce = 'Run scripts/Verify-LatestInstall.ps1 with new external OutputDirectory and ReportPath.' } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM
}
Get-Content -LiteralPath $ReportPath -Raw
if (@($results | Where-Object { !$_.passed }).Count) { throw 'Latest installer verification failed; read the JSON report.' }
