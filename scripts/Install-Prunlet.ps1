#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Repository = '1llum1n4t1s/Prunlet',
    [string]$InstallDirectory = (Join-Path $env:USERPROFILE '.local\Prunlet'),
    # 出荷済み呼出しの互換引数。対象フォルダーの制限には使わない。
    [string[]]$AllowedRoot,
    [string]$BackupDirectory,
    [string]$WorkDirectory,
    [string]$UpdateBackupRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Codex\TaskArtifacts\Prunlet'),
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [switch]$RegisterCodex,
    [switch]$RegisterAgentInstructions,
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [string]$SettingsBackupDirectory,
    [switch]$PrepareStartupUpdate,
    [switch]$UseGitHubCliAuthentication,
    [switch]$UpdateManagedInstallation,
    [ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedCommitSha
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-PrunletGitHubCli([string]$Endpoint) {
    $command = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$command) { throw 'GitHub CLI authentication requires an existing gh executable.' }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $command.Source
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('api', '--hostname', 'github.com', '--method', 'GET', $Endpoint)) { $start.ArgumentList.Add($argument) }
    # 親のデバッグ設定による認証情報の出力と、対話待ちを避ける。
    [void]$start.Environment.Remove('GH_DEBUG')
    $start.Environment['GH_PROMPT_DISABLED'] = '1'
    $start.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $start.Environment['GH_PAGER'] = 'cat'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        try { [void]$process.Start() } catch { throw 'GitHub CLI could not be started.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(60000)) {
            try { $process.Kill($true) } catch { }
            throw 'GitHub CLI request timed out after 60 seconds.'
        }
        $output = $stdout.GetAwaiter().GetResult()
        # stderrは回収だけを行い、認証関連の生出力を例外や記録へ転載しない。
        [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "GitHub CLI request failed (exit code $($process.ExitCode))." }
        return $output
    } finally { $process.Dispose() }
}
function Get-PrunletGitHubApiResponse([string]$Endpoint) {
    if (!$UseGitHubCliAuthentication) {
        return Invoke-RestMethod -Uri ("https://api.github.com/" + $Endpoint) -Headers $headers -TimeoutSec 60
    }
    $json = Invoke-PrunletGitHubCli $Endpoint
    try { $response = ConvertFrom-Json -InputObject $json -ErrorAction Stop } catch { throw 'GitHub CLI returned invalid JSON.' }
    if ($null -eq $response -or $response -isnot [pscustomobject]) { throw 'GitHub CLI returned an invalid API response.' }
    return $response
}

function Test-InTree([string]$Path, [string]$Root) {
    $Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}
function Assert-PlainPath([string]$Path, [string]$Name) {
    if (![IO.Path]::IsPathFullyQualified($Path)) { throw "$Name must be an absolute path." }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if (!$full -or $full -eq [IO.Path]::GetPathRoot($Path).TrimEnd('\', '/')) { throw "$Name cannot be a filesystem root." }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Name cannot traverse links: $cursor" }
        }
        $cursor = Split-Path -Parent $cursor
    }
    return $full
}
function Assert-ExternalPath([string]$Path, [string]$Name) {
    $full = Assert-PlainPath $Path $Name
    foreach ($forbidden in $script:ForbiddenRoots) {
        if (Test-InTree $full $forbidden) { throw "$Name must be outside repositories and Codex home: $full" }
    }
    $cursor = $full
    while ($cursor) {
        if ((Test-Path -LiteralPath (Join-Path $cursor '.git')) -or (Test-Path -LiteralPath (Join-Path $cursor 'Cargo.toml')) -or (Test-Path -LiteralPath (Join-Path $cursor 'src\Prunlet\Prunlet.csproj'))) { throw "$Name cannot be inside a repository: $full" }
        $cursor = Split-Path -Parent $cursor
    }
    return $full
}
function New-TrackedDirectory([string]$Path) {
    $full = Assert-ExternalPath $Path 'Installation directory'
    $missing = [Collections.Generic.List[string]]::new()
    $cursor = $full
    while (!(Test-Path -LiteralPath $cursor)) {
        $missing.Add($cursor)
        $cursor = Split-Path -Parent $cursor
    }
    if (!(Test-Path -LiteralPath $cursor -PathType Container)) { throw "Directory ancestor is a file: $cursor" }
    for ($index = $missing.Count - 1; $index -ge 0; $index--) {
        $directory = $missing[$index]
        if (Test-Path -LiteralPath $directory -PathType Container) { continue }
        New-Item -ItemType Directory -Path $directory | Out-Null
        $createdDirectories.Add(@{ path = $directory; createdUtcTicks = (Get-Item -LiteralPath $directory).CreationTimeUtc.Ticks })
    }
}
function Test-RegisteredManagedInstallation([string]$Root) {
    $effectiveHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    if (!(Assert-PlainPath $CodexHome 'CodexHome').Equals((Assert-PlainPath $effectiveHome 'Effective CodexHome'),[StringComparison]::OrdinalIgnoreCase)) { return $false }
    $document = Assert-PlainPath (Join-Path $CodexHome 'AGENTS.md') 'Existing CLI registration'
    if (!(Test-Path -LiteralPath $document -PathType Leaf)) { return $false }
    $text = [IO.File]::ReadAllText($document)
    if ([regex]::Matches($text,'BEGIN PRUNLET AGENT-INSTRUCTIONS').Count -ne 1 -or [regex]::Matches($text,'END PRUNLET AGENT-INSTRUCTIONS').Count -ne 1) { return $false }
    $block = [regex]::Matches($text,'(?ms)^<!-- BEGIN PRUNLET AGENT-INSTRUCTIONS -->\r?\n(.*?)^<!-- END PRUNLET AGENT-INSTRUCTIONS -->\r?$')
    if ($block.Count -ne 1 -or $block[0].Index -ne 0) { return $false }
    $line = [regex]::Matches($block[0].Groups[1].Value,'(?m)^Prunlet CLI: (\{[^\r\n]*\})\r?$')
    if ($line.Count -ne 1) { return $false }
    try {
        $binding = $line[0].Groups[1].Value | ConvertFrom-Json -ErrorAction Stop
        $instruction = 'Windowsのファイル・フォルダー・レジストリ削除では、[PRUNLET.md](PRUNLET.md)を読み、Prunlet CLIを最初からCMD（shell=cmd.exe、login=false）で直接実行する。'
        $canonical = $instruction + "`nPrunlet CLI: " + ([ordered]@{executablePath=$binding.executablePath;configPath=$binding.configPath} | ConvertTo-Json -Compress) + "`n"
        if (![string]::Equals($block[0].Groups[1].Value.Replace("`r`n","`n"),$canonical,[StringComparison]::Ordinal)) { return $false }
        $executable = Assert-PlainPath ([string]$binding.executablePath) 'Registered CLI'
        $configuration = Assert-PlainPath ([string]$binding.configPath) 'Registered configuration'
        return $executable.Equals((Join-Path $Root 'bin\prunlet.exe'),[StringComparison]::OrdinalIgnoreCase) -and $configuration.Equals((Join-Path $Root 'config.json'),[StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}
function Assert-ManagedExistingPath([string]$Path,[switch]$RegisteredInstallation,[switch]$RequireGit) {
    $full = Assert-PlainPath $Path 'Managed installation path'
    foreach ($forbidden in $script:ForbiddenRoots) {
        if (Test-InTree $full $forbidden) { throw 'Managed installation cannot use a source or Codex directory.' }
    }
    if (!(Test-Path -LiteralPath $full -PathType Container)) { throw 'Managed installation directories must already exist.' }
    $repositories = [Collections.Generic.List[string]]::new()
    $cursor = $full
    while ($cursor) {
        if ((Test-Path -LiteralPath (Join-Path $cursor 'Cargo.toml')) -or (Test-Path -LiteralPath (Join-Path $cursor 'src\Prunlet\Prunlet.csproj'))) { throw 'Managed installation cannot be inside a source tree.' }
        if (Test-Path -LiteralPath (Join-Path $cursor '.git')) { $repositories.Add($cursor) }
        $cursor = Split-Path -Parent $cursor
    }
    if ($RequireGit -and !$repositories.Count) { throw 'Managed update mode requires an existing installation inside Git.' }
    if ($repositories.Count -gt 1) { throw 'Nested Git repositories are unsupported for managed installation.' }
    if ($repositories.Count) {
        foreach ($variable in @('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','GIT_LITERAL_PATHSPECS')) {
            if ([Environment]::GetEnvironmentVariable($variable)) { throw 'Managed installation requires the physical Git repository and index.' }
        }
        $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $gitRoot = $repositories[0]
        $actual = & $git.Source --no-optional-locks --literal-pathspecs -c core.fsmonitor=false -C $gitRoot rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or !$actual -or !(Assert-PlainPath ([string]$actual) 'Git root').Equals($gitRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Managed installation Git repository could not be verified.' }
        & $git.Source --no-optional-locks -c core.fsmonitor=false -C $gitRoot check-ignore --no-index -q -- $full 2>$null
        if ($LASTEXITCODE -ne 0 -and !($LASTEXITCODE -eq 1 -and $RegisteredInstallation)) { throw 'Managed installation path must be Git-ignored or match its existing CLI registration.' }
        $indexStart = [Diagnostics.ProcessStartInfo]::new($git.Source)
        $indexStart.UseShellExecute = $false; $indexStart.CreateNoWindow = $true
        $indexStart.RedirectStandardOutput = $true; $indexStart.RedirectStandardError = $true
        $indexStart.StandardOutputEncoding = [Text.UTF8Encoding]::new($false,$true)
        foreach ($argument in @('--no-optional-locks','-c','core.fsmonitor=false','-C',$gitRoot,'ls-files','-z')) { $indexStart.ArgumentList.Add($argument) }
        $indexProcess = [Diagnostics.Process]::Start($indexStart)
        try {
            $indexError = $indexProcess.StandardError.ReadToEndAsync()
            $indexText = $indexProcess.StandardOutput.ReadToEnd()
            $indexProcess.WaitForExit(); [void]$indexError.GetAwaiter().GetResult()
            if ($indexProcess.ExitCode -ne 0) { throw 'Managed installation path contains tracked files or an unverifiable index.' }
            foreach ($entry in $indexText.Split([char]0,[StringSplitOptions]::RemoveEmptyEntries)) {
                $trackedPath = [IO.Path]::GetFullPath((Join-Path $gitRoot $entry))
                if (Test-InTree $trackedPath $full) { throw 'Managed installation path contains tracked files or an unverifiable index.' }
            }
        } finally { $indexProcess.Dispose() }
    }
    return $full
}
function Read-ManagedInstallationJson([string]$Path) {
    [void](Assert-PlainPath $Path 'Managed installation file')
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Managed update requires an existing installation and configuration.' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $reader = [IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)
    try { $value = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop } finally { $reader.Dispose() }
    return @{ value=$value; hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) }
}
function Get-ManagedInstallationSnapshot([string]$Root) {
    $rootPath = Assert-PlainPath $Root 'Managed installation root'
    $registered = Test-RegisteredManagedInstallation $rootPath
    $full = Assert-ManagedExistingPath $rootPath -RegisteredInstallation:$registered -RequireGit
    [void](Assert-ManagedExistingPath (Join-Path $full 'bin') -RegisteredInstallation:$registered)
    $configuration = Read-ManagedInstallationJson (Join-Path $full 'config.json')
    $provenance = Read-ManagedInstallationJson (Join-Path $full 'source-info.json')
    $info = $provenance.value
    if (![string]::Equals($info.repository,$Repository,[StringComparison]::OrdinalIgnoreCase) -or ![string]::Equals($info.runtime,$Runtime,[StringComparison]::Ordinal) -or $info.commitSha -notmatch '^[0-9a-fA-F]{40}$' -or $configuration.value.schema -ne 1) { throw 'Managed installation metadata does not match the requested product.' }
    $recoveryPath = Assert-PlainPath ([string]$configuration.value.backupDirectory) 'Managed recovery'
    $recovery = if (Test-InTree $recoveryPath $full) { Assert-ManagedExistingPath $recoveryPath -RegisteredInstallation:$registered } else { Assert-ExternalPath $recoveryPath 'Configured backupDirectory' }
    if ((Test-InTree $full $recovery) -or (Test-InTree $recovery (Join-Path $full 'bin'))) { throw 'Managed recovery overlaps installed products.' }
    $hashes = [ordered]@{}
    foreach ($entry in @(@('prunlet.exe','executableSha256'),@('prunlet-maintenance.exe','maintenanceExecutableSha256'),@('prunlet-hook.exe','hookExecutableSha256'))) {
        $path = Assert-PlainPath (Join-Path $full ('bin\'+$entry[0])) 'Managed product'
        $expected = [string]$info.($entry[1])
        if ($expected -notmatch '^[0-9a-fA-F]{64}$' -or !(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $expected) { throw 'Managed installation product hash mismatch.' }
        $hashes[$entry[0]] = $expected.ToUpperInvariant()
    }
    foreach ($name in @('Install-Prunlet.ps1','start-prunlet-mcp.ps1','configuration-common.ps1','maintenance-task.ps1','uninstall-maintenance.ps1','install-codex.ps1','uninstall-codex.ps1','install-agent-instructions.ps1','PRUNLET.md')) {
        $relative = 'bin\'+$name
        $path = Assert-PlainPath (Join-Path $full $relative) 'Managed auxiliary product'
        $expected = [string]$info.auxiliarySha256.($relative)
        if ($expected -notmatch '^[0-9a-fA-F]{64}$' -or !(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $expected) { throw 'Managed installation auxiliary hash mismatch.' }
        $hashes[$relative] = $expected.ToUpperInvariant()
    }
    if (Test-Path -LiteralPath (Join-Path $full 'bin\codex-pretooluse.ps1')) { throw 'Unowned retired backend was preserved; managed update cannot replace it.' }
    return [ordered]@{ root=$full; recovery=$recovery; registered=$registered; configHash=$configuration.hash; sourceInfoHash=$provenance.hash; products=$hashes }
}
function Assert-ManagedInstallationSnapshot($Snapshot) {
    $current = Get-ManagedInstallationSnapshot $Snapshot.root
    if (![string]::Equals(($current | ConvertTo-Json -Depth 5 -Compress),($Snapshot | ConvertTo-Json -Depth 5 -Compress),[StringComparison]::Ordinal)) { throw 'Managed installation or recovery configuration changed; nothing was replaced.' }
}
# 登録helperへ渡すPreviousGuideSha256を決める。管理モード・非管理モードで共通に使う。
# 前回のbin\PRUNLET.mdと登録済みガイドが改行形式（CRLF/LF）の差だけなら登録実物のhashを、
# それ以外（未登録・本文差・厳密UTF-8として読めない）は前回binのhashを返す。
# 本文が一致する改行差だけを認識し、編集済み本文の拒否は登録helperに委ねる。
function Get-GuideRegistrationPreviousHash([byte[]]$PreviousBytes) {
    $expected = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($PreviousBytes))
    $current = Assert-PlainPath (Join-Path $CodexHome 'PRUNLET.md') 'Registered guide'
    if (!(Test-Path -LiteralPath $current -PathType Leaf)) { return $expected }
    $currentBytes = [IO.File]::ReadAllBytes($current)
    $utf8 = [Text.UTF8Encoding]::new($false,$true)
    try {
        $previousText = $utf8.GetString($PreviousBytes).Replace("`r`n","`n")
        $currentText = $utf8.GetString($currentBytes).Replace("`r`n","`n")
    } catch { return $expected }
    if ([string]::Equals($previousText,$currentText,[StringComparison]::Ordinal)) {
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($currentBytes))
    }
    return $expected
}
function Get-ManagedGuideRegistrationHash($Snapshot) {
    $previous = Assert-PlainPath (Join-Path $Snapshot.root 'bin\PRUNLET.md') 'Managed guide'
    $expected = $Snapshot.products['bin\PRUNLET.md']
    $previousBytes = [IO.File]::ReadAllBytes($previous)
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($previousBytes)) -ine $expected) { throw 'Managed installation auxiliary hash mismatch.' }
    return Get-GuideRegistrationPreviousHash $previousBytes
}
function Assert-ManagedRecoveryBinding($Snapshot,[string]$ExpectedConfigHash = $Snapshot.configHash) {
    $registered = Test-RegisteredManagedInstallation $Snapshot.root
    [void](Assert-ManagedExistingPath $Snapshot.root -RegisteredInstallation:$registered -RequireGit)
    $configuration = Read-ManagedInstallationJson (Join-Path $Snapshot.root 'config.json')
    if ($configuration.hash -ine $ExpectedConfigHash) { throw 'Managed recovery configuration changed; migration was not started.' }
    $recoveryPath = Assert-PlainPath ([string]$configuration.value.backupDirectory) 'Managed recovery'
    $recovery = if (Test-InTree $recoveryPath $Snapshot.root) { Assert-ManagedExistingPath $recoveryPath -RegisteredInstallation:$registered } else { Assert-ExternalPath $recoveryPath 'Configured backupDirectory' }
    if (!$recovery.Equals($Snapshot.recovery,[StringComparison]::OrdinalIgnoreCase)) { throw 'Managed recovery configuration changed; migration was not started.' }
}
# 公開済み最新releaseを解決する。起動時更新（start-prunlet-mcp.ps1のGet-LatestReleaseInfo）と
# 同じ条件で、安定版・タグが既定ブランチ上のcommitを指すこと・runtimeの更新ZIPが一意で
# digestとsizeを持つことを確認する。GitHub Releaseの発行者を信頼する点も同じ。
function Get-LatestPrunletRelease {
    $metadata = Get-PrunletGitHubApiResponse "repos/$Repository"
    $branch = [string]$metadata.default_branch
    if (!$branch -or $branch -cnotmatch '^[A-Za-z0-9._/-]+$' -or $branch.Contains('..') -or $branch.StartsWith('/') -or $branch.EndsWith('/')) { throw 'GitHub did not return a valid default branch.' }
    $release = Get-PrunletGitHubApiResponse "repos/$Repository/releases/latest"
    $tag = [string]$release.tag_name
    if (!$tag -or $release.draft -or $release.prerelease) { throw 'GitHub did not return a published stable release.' }
    if ($tag -cnotmatch '\Av?[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9.-]+)?\z') { throw 'Published release tag is invalid.' }
    $target = (Get-PrunletGitHubApiResponse "repos/$Repository/git/ref/tags/$tag").object
    for ($depth = 0; $depth -lt 8; $depth++) {
        $sha = [string]$target.sha
        if ($sha -cnotmatch '^[0-9a-f]{40}$') { throw 'Release tag has an invalid object SHA.' }
        if ($target.type -ceq 'commit') {
            $comparison = Get-PrunletGitHubApiResponse ("repos/$Repository/compare/$sha..." + [Uri]::EscapeDataString($branch) + '?per_page=1')
            if ($comparison.status -cnotin @('ahead', 'identical')) { throw 'Release commit is not on the default branch.' }
            $name = 'prunlet-update-' + $Runtime + '.zip'
            $assets = @($release.assets | Where-Object { $_.name -ceq $name -and $_.state -ceq 'uploaded' })
            # 公開直後は配布workflowの承認・完了前でassetがまだない。何も書き込まずに止める。
            if ($assets.Count -ne 1) { throw "The latest release $tag has no unique $name yet; retry after its release workflow finishes. Nothing was installed." }
            $asset = $assets[0]
            if ([string]$asset.digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or [long]$asset.size -le 0 -or [long]$asset.size -gt 536870912) { throw 'Published package digest or size is invalid.' }
            if ([long]$asset.id -le 0) { throw 'Published package identity is invalid.' }
            return [ordered]@{ branch = $branch; tag = $tag; commit = $sha; assetName = $name; assetId = [long]$asset.id; assetBytes = [long]$asset.size; assetSha256 = ([string]$asset.digest).Substring(7).ToUpperInvariant() }
        }
        if ($target.type -cne 'tag') { throw 'Release tag does not identify a commit.' }
        $target = (Get-PrunletGitHubApiResponse "repos/$Repository/git/tags/$sha").object
    }
    throw 'Release tag nesting exceeds the supported depth.'
}

# 配布ZIPに含まれる12製品。配置先（bin\…）とZIP内の名前（bin/…）は1対1で対応する。
$script:PackageExecutables = @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe')
$script:PackageAuxiliary = @('Install-Prunlet.ps1', 'start-prunlet-mcp.ps1', 'configuration-common.ps1', 'maintenance-task.ps1', 'uninstall-maintenance.ps1', 'install-codex.ps1', 'uninstall-codex.ps1', 'install-agent-instructions.ps1', 'PRUNLET.md')
# 配布物の署名者。Signing.Common.ps1と同じ値で、インストーラー単体でも照合できるよう直接持つ。
$script:PackageSignerCommonName = 'Open Source Developer Yuichiro Shinozaki'

# 取得したZIPを、何も実行する前に検証してから展開する。
# 検証範囲: 固定のentry集合・リンクなし・サイズ上限、package.json（製品・schema・取得元・既定ブランチ・
# releaseのcommit・runtime・12製品のhash/長さ）、展開後の実体hash、CLIとhookの同一性、PEのmachine、
# 実行ファイルのAuthenticode（Valid・署名者・タイムスタンプ）。
function Expand-VerifiedPackage([string]$Archive, [string]$Destination, $Release) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        [void]$expected.Add('package.json')
        foreach ($name in @($script:PackageExecutables + $script:PackageAuxiliary)) { [void]$expected.Add('bin/' + $name) }
        $entries = [Collections.Generic.Dictionary[string, IO.Compression.ZipArchiveEntry]]::new([StringComparer]::Ordinal)
        $caseFolded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if (!$expected.Contains($name) -or !$caseFolded.Add($name)) { throw "Unexpected or duplicate package entry: $name" }
            $mode = ($entry.ExternalAttributes -shr 16) -band 0xf000
            if ($mode -notin @(0, 0x8000) -or ($entry.ExternalAttributes -band 0x410)) { throw "Package links, directories, or special files are forbidden: $name" }
            $limit = if ($name.EndsWith('.exe', [StringComparison]::Ordinal)) { 256MB } elseif ($name -ceq 'package.json') { 64KB } else { 4MB }
            if ($entry.Length -lt 1 -or $entry.Length -gt $limit) { throw "Package entry size is invalid: $name" }
            $entries.Add($name, $entry)
        }
        if ($entries.Count -ne $expected.Count) { throw 'Release package is missing required entries.' }
        $reader = [IO.StreamReader]::new($entries['package.json'].Open(), [Text.UTF8Encoding]::new($false, $true))
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable -ErrorAction Stop } finally { $reader.Dispose() }
        if ($manifest -isnot [Collections.IDictionary] -or $manifest['product'] -cne 'Prunlet' -or $manifest['schema'] -ne 1 -or
            $manifest['repository'] -cne $Repository -or $manifest['defaultBranch'] -cne $Release.branch -or
            [string]$manifest['commitSha'] -cne $Release.commit -or $manifest['runtime'] -cne $Runtime -or
            $manifest['files'] -isnot [Collections.IDictionary] -or $manifest['files'].Count -ne ($expected.Count - 1)) {
            throw 'Package metadata does not match the published release.'
        }
        New-Item -ItemType Directory -Path (Join-Path $Destination 'bin') | Out-Null
        $hashes = [ordered]@{}
        foreach ($name in @($script:PackageExecutables + $script:PackageAuxiliary)) {
            $key = 'bin/' + $name
            if (@($manifest['files'].Keys) -cnotcontains $key) { throw "Package metadata is missing: $key" }
            $item = $manifest['files'][$key]
            if ($item -isnot [Collections.IDictionary] -or [string]$item['sha256'] -cnotmatch '^[0-9A-F]{64}$' -or [long]$item['bytes'] -ne $entries[$key].Length) { throw "Package metadata is invalid: $key" }
            $path = Join-Path $Destination ('bin\' + $name)
            $source = $entries[$key].Open()
            try {
                $file = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $source.CopyTo($file) } finally { $file.Dispose() }
            } finally { $source.Dispose() }
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            if ($hash -cne [string]$item['sha256'] -or (Get-Item -LiteralPath $path).Length -ne [long]$item['bytes']) { throw "Package content differs from its metadata: $key" }
            $hashes[$name] = $hash
        }
        if ($hashes['prunlet.exe'] -cne $hashes['prunlet-hook.exe']) { throw 'The hook host must match the CLI binary.' }
        $machine = if ($Runtime -eq 'win-x64') { 0x8664 } else { 0xaa64 }
        foreach ($name in $script:PackageExecutables) {
            $path = Join-Path $Destination ('bin\' + $name)
            $bytes = [IO.File]::ReadAllBytes($path)
            if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw "Package executable is not a PE file: $name" }
            $offset = [BitConverter]::ToUInt32($bytes, 0x3c)
            if ($offset -lt 64 -or $offset -gt $bytes.Length - 6 -or [BitConverter]::ToUInt32($bytes, [int]$offset) -ne 0x00004550 -or [BitConverter]::ToUInt16($bytes, [int]$offset + 4) -ne $machine) { throw "Package executable does not match ${Runtime}: $name" }
            # 未署名・署名者違い・タイムスタンプなしの実行ファイルは配置も実行もしない。
            $signature = Get-AuthenticodeSignature -LiteralPath $path
            $signer = if ($signature.SignerCertificate) { $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) } else { '' }
            if ($signature.Status -ne 'Valid' -or $signer -cne $script:PackageSignerCommonName -or !$signature.TimeStamperCertificate) { throw "Package executable is not signed by the Prunlet publisher (status $($signature.Status)): $name" }
        }
        return $hashes
    } finally { $zip.Dispose() }
}



# 配布物の補助ファイルが更新タスクに対応しているかを、実物の構文木で判定する。
# maintenance-task.ps1が登録・復元の関数を定義し、start-prunlet-mcp.ps1が-UpdateOnlyを受け付ける場合だけ真。
function Test-PackageSupportsUpdateTask([string]$PackageBin) {
    $definitions = @{}
    foreach ($name in @('maintenance-task.ps1', 'start-prunlet-mcp.ps1')) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PackageBin $name), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { return $false }
        $definitions[$name] = $ast
    }
    $functions = @($definitions['maintenance-task.ps1'].FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object Name)
    foreach ($required in @('Get-PrunletUpdateTaskState', 'Register-PrunletUpdateTask', 'Restore-PrunletUpdateTask')) {
        if ($functions -cnotcontains $required) { return $false }
    }
    $launcherParameters = $definitions['start-prunlet-mcp.ps1'].ParamBlock
    return [bool]($launcherParameters -and @($launcherParameters.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'UpdateOnly' }).Count)
}

if (!$IsWindows) { throw 'Prunlet installation requires Windows and PowerShell 7.' }
if ($PrepareStartupUpdate) { throw 'Startup preparation is not part of manual installation. Use the registered MCP startup entry to verify and prepare a published release package.' }
if ($RegisterAgentInstructions -and !$RegisterCodex) { throw 'RegisterAgentInstructions requires explicit -RegisterCodex.' }
if ($Repository -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$') { throw 'Repository must be a GitHub owner/repository name.' }
$nativeArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
if ($nativeArchitecture -eq 'Arm64' -and !$PSBoundParameters.ContainsKey('Runtime')) { throw 'On Windows ARM64 explicitly choose -Runtime win-arm64 (or win-x64 for emulation).' }
if ($nativeArchitecture -notin @('X64', 'Arm64')) { throw "Unsupported Windows architecture: $nativeArchitecture" }
$runId = 'install-' + [Guid]::NewGuid().ToString('N')
$ForbiddenRoots = @((Assert-PlainPath $CodexHome 'CodexHome'), (Join-Path $env:USERPROFILE '.codex'))
if ($env:CODEX_HOME) { $ForbiddenRoots += Assert-PlainPath $env:CODEX_HOME 'CODEX_HOME' }
$scriptParent = Split-Path -Parent $PSScriptRoot
if ((Test-Path -LiteralPath (Join-Path $scriptParent 'Cargo.toml')) -or (Test-Path -LiteralPath (Join-Path $scriptParent 'src\Prunlet\Prunlet.csproj'))) { $ForbiddenRoots += $scriptParent }
$managedInstallation = if ($UpdateManagedInstallation) { Get-ManagedInstallationSnapshot $InstallDirectory } else { $null }
$InstallDirectory = if ($managedInstallation) { $managedInstallation.root } else { Assert-ExternalPath $InstallDirectory 'InstallDirectory' }

if (!$WorkDirectory) {
    $WorkDirectory = Join-Path ([IO.Path]::GetTempPath()) "Codex\Prunlet\$runId"
}
$WorkDirectory = Assert-ExternalPath $WorkDirectory 'WorkDirectory'
if ((Test-InTree $WorkDirectory $InstallDirectory) -or (Test-InTree $InstallDirectory $WorkDirectory)) {
    throw 'WorkDirectory and InstallDirectory must be separate trees.'
}
if (Test-Path -LiteralPath $WorkDirectory) { throw 'WorkDirectory must be a new directory owned by this installation.' }
if (Test-Path -LiteralPath $InstallDirectory -PathType Leaf) { throw 'InstallDirectory is a file.' }
$configPath = Join-Path $InstallDirectory 'config.json'
$existingConfig = Test-Path -LiteralPath $configPath -PathType Leaf

if (!$BackupDirectory) { $BackupDirectory = if ($managedInstallation) { $managedInstallation.recovery } else { Join-Path $InstallDirectory 'recovery' } }
$BackupDirectory = Assert-PlainPath $BackupDirectory 'BackupDirectory'
$BackupDirectory = if ($managedInstallation -and ([IO.Path]::GetFullPath($BackupDirectory).TrimEnd('\','/')).Equals($managedInstallation.recovery,[StringComparison]::OrdinalIgnoreCase)) { $managedInstallation.recovery } else { Assert-ExternalPath $BackupDirectory 'BackupDirectory' }
if ($existingConfig) {
    [void](Assert-PlainPath $configPath 'ConfigPath')
    $existing = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    $effectiveBackup = if ($managedInstallation) { $managedInstallation.recovery } else { Assert-ExternalPath $existing.backupDirectory 'Configured backupDirectory' }
} else { $effectiveBackup = $BackupDirectory }
if ((Test-InTree $effectiveBackup $WorkDirectory) -or (Test-InTree $WorkDirectory $effectiveBackup)) { throw 'WorkDirectory and recovery backup must be separate trees.' }
$UpdateBackupRoot = Assert-ExternalPath $UpdateBackupRoot 'UpdateBackupRoot'
$updateBackup = Assert-ExternalPath (Join-Path $UpdateBackupRoot $runId) 'UpdateBackupDirectory'
if ((Test-InTree $updateBackup $InstallDirectory) -or (Test-InTree $InstallDirectory $updateBackup) -or (Test-InTree $updateBackup $WorkDirectory) -or (Test-InTree $WorkDirectory $updateBackup)) { throw 'Update backup must be separate from install and work directories.' }
if ((Test-InTree $updateBackup $effectiveBackup) -or (Test-InTree $effectiveBackup $updateBackup)) { throw 'Update backup must be separate from recovery data.' }
if ($RegisterCodex -and $SettingsBackupDirectory) { $SettingsBackupDirectory = Assert-ExternalPath $SettingsBackupDirectory 'SettingsBackupDirectory' }
$products = @('bin\prunlet.exe', 'bin\prunlet-maintenance.exe', 'bin\prunlet-hook.exe', 'bin\Install-Prunlet.ps1', 'bin\start-prunlet-mcp.ps1', 'bin\configuration-common.ps1', 'bin\maintenance-task.ps1', 'bin\uninstall-maintenance.ps1', 'bin\install-codex.ps1', 'bin\uninstall-codex.ps1', 'bin\install-agent-instructions.ps1', 'bin\PRUNLET.md', 'source-info.json')
$retiredProducts = @('bin\codex-pretooluse.ps1')
$previousGuidePath = Join-Path $InstallDirectory 'bin\PRUNLET.md'
# 非管理モードでも、前回binと登録済みガイドが改行差だけなら登録実物のhashをPreviousに使う（管理モードと同じ判定）。
$previousGuideSha256 = if ($managedInstallation -and $RegisterAgentInstructions) { Get-ManagedGuideRegistrationHash $managedInstallation } elseif (Test-Path -LiteralPath $previousGuidePath -PathType Leaf) { if ($RegisterAgentInstructions) { Get-GuideRegistrationPreviousHash ([IO.File]::ReadAllBytes($previousGuidePath)) } else { (Get-FileHash -LiteralPath $previousGuidePath -Algorithm SHA256).Hash } } else { $null }
foreach ($relative in @($products + $retiredProducts)) {
    $target = Assert-PlainPath (Join-Path $InstallDirectory $relative) 'Installed product path'
    if (Test-Path -LiteralPath $target -PathType Container) { throw "Installed product path is a directory: $target" }
    if ((Test-InTree $effectiveBackup $target) -or (Test-InTree $target $effectiveBackup)) { throw 'Product files and recovery backup must be separate.' }
}
$headers = @{ 'User-Agent' = 'Prunlet-Latest-Installer'; 'Accept' = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
$mutexKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($InstallDirectory.ToLowerInvariant())))
$globalInstallationMutex = [Threading.Mutex]::new($false, ('Global\Prunlet-Install-' + $mutexKey))
$installationMutex = [Threading.Mutex]::new($false, ('Local\Prunlet-Install-' + $mutexKey))
$globalMutexAcquired = $false
$mutexAcquired = $false
$createdWork = $false
$changed = [Collections.Generic.List[string]]::new()
$saved = @{}
$createdDirectories = [Collections.Generic.List[object]]::new()
$createdConfig = $null
$migratedConfig = $null
$profileSnapshot = [Collections.Generic.List[object]]::new()
$registrationStarted = $false
$maintenanceState = $null
$maintenanceStarted = $false
$updateTaskState = $null
$updateTaskStarted = $false
$retiredProductPaths = [Collections.Generic.List[string]]::new()
$storageMigrationStarted = $false
$storageMigration = $null
$migrationJson = $null
try {
    try { $globalMutexAcquired = $globalInstallationMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $globalMutexAcquired = $true }
    if (!$globalMutexAcquired) { throw 'Another Prunlet installation is already running for this directory.' }
    try { $mutexAcquired = $installationMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mutexAcquired = $true }
    if (!$mutexAcquired) { throw 'Another Prunlet installation is already running for this directory.' }
    if ($managedInstallation) { Assert-ManagedInstallationSnapshot $managedInstallation }
    # 既定ブランチのHEADではなく、署名済みの更新ZIPを持つ公開済み最新releaseを導入する。
    # ソースのビルドをしないため、Rust・MSVC・Windows SDKは不要。
    $release = Get-LatestPrunletRelease
    $branch = $release.branch
    $sha = $release.commit
    if ($ExpectedCommitSha -and $sha -ine $ExpectedCommitSha) { throw 'The latest release commit differs from ExpectedCommitSha; nothing was installed.' }

    New-Item -ItemType Directory -Path $WorkDirectory | Out-Null
    $createdWork = $true
    # ZIP本体はREST APIの枠を使わない公開URLから取得し、APIが返したsizeとdigestで照合する（起動時更新と同じ）。
    $archive = Join-Path $WorkDirectory $release.assetName
    Invoke-WebRequest -Uri ("https://github.com/$Repository/releases/download/" + [Uri]::EscapeDataString($release.tag) + '/' + $release.assetName) -Headers @{ 'User-Agent' = 'Prunlet-Latest-Installer' } -OutFile $archive -TimeoutSec 300 | Out-Null
    $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ((Get-Item -LiteralPath $archive).Length -ne $release.assetBytes -or $archiveHash -cne $release.assetSha256) { throw 'Downloaded package differs from the published release asset; nothing was installed.' }
    $packageRoot = Join-Path $WorkDirectory 'package'
    $packageHashes = Expand-VerifiedPackage $archive $packageRoot $release
    $packageBin = Join-Path $packageRoot 'bin'
    # 起動時更新と同じ形の取得元情報にする（downloadUrlはreleaseのasset API、archiveSha256はZIP全体）。
    $downloadUrl = "https://api.github.com/repos/$Repository/releases/assets/$($release.assetId)"
    if ($RegisterAgentInstructions) {
        $instructionParameters = @{ SourceGuidePath = (Join-Path $packageBin 'PRUNLET.md'); CodexHome = $CodexHome; BackupDirectory = $(if ($SettingsBackupDirectory) { $SettingsBackupDirectory } else { $updateBackup }); PreviousGuideSha256 = $previousGuideSha256; ExecutablePath = (Join-Path $InstallDirectory 'bin\prunlet.exe'); ConfigPath = $configPath }
        & (Join-Path $packageBin 'install-agent-instructions.ps1') @instructionParameters -ValidateOnly | Out-Null
    }
    # 所有していない既存タスクは製品ファイルを書き換える前に拒否する。
    . (Join-Path $packageBin 'maintenance-task.ps1')
    $maintenanceState = Get-PrunletMaintenanceState (Join-Path $InstallDirectory 'bin\prunlet.exe') $configPath
    # 更新タスクは、導入する配布物の補助ファイルが対応している場合だけ登録する。このインストーラーは
    # mainから取得されるため、最新releaseより新しいことがある。呼び出し元の関数ではなく配布物の実物で判定する。
    $updateTaskState = if (Test-PackageSupportsUpdateTask $packageBin) { Get-PrunletUpdateTaskState (Join-Path $InstallDirectory 'bin\prunlet.exe') $configPath $CodexHome } else { $null }
    $exe = Join-Path $packageBin 'prunlet.exe'
    $maintenanceExe = Join-Path $packageBin 'prunlet-maintenance.exe'
    $hookExe = Join-Path $packageBin 'prunlet-hook.exe'
    # 初期設定も外部作業場所で検証する。既存設定の移行は配置後に行う。
    $newConfig = Join-Path $WorkDirectory 'config.json'
    if (!$existingConfig) {
        # 最終的な復元先の安全性をCoreに検査させる。
        # 今回作ったディレクトリだけを追跡し、失敗時に空のものを戻す。
        New-TrackedDirectory $effectiveBackup
        $probeArgs = @('--config', $newConfig, 'init', '--backup-directory', $effectiveBackup)
        & $exe @probeArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Prunlet rejected the initial configuration.' }
    } else {
        & $exe --config $configPath validate-config | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Prunlet rejected the existing configuration; it was preserved.' }
    }
    $auxiliaryHashes = [ordered]@{}
    foreach ($name in $script:PackageAuxiliary) { $auxiliaryHashes['bin\' + $name] = $packageHashes[$name] }
    # 起動時更新（coordinator.rsのsource_info）が書く10項目と同じ構成にし、次回以降の自動更新が引き継げるようにする。
    $provenance = [ordered]@{ repository = $Repository; defaultBranch = $branch; commitSha = $sha.ToLowerInvariant(); downloadUrl = $downloadUrl; archiveSha256 = $archiveHash.ToUpperInvariant(); executableSha256 = $packageHashes['prunlet.exe']; maintenanceExecutableSha256 = $packageHashes['prunlet-maintenance.exe']; hookExecutableSha256 = $packageHashes['prunlet-hook.exe']; auxiliarySha256 = $auxiliaryHashes; runtime = $Runtime }
    $provenance | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $WorkDirectory 'source-info.json') -Encoding utf8NoBOM

    if ($managedInstallation) { Assert-ManagedInstallationSnapshot $managedInstallation }
    # 製品ファイルと設定原本を保全する。復元領域の移行は更新の最後にCoreへ委ねる。
    foreach ($relative in @($products + $retiredProducts)) {
        $target = Join-Path $InstallDirectory $relative
        [void](Assert-PlainPath $target 'Installed product path')
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $copy = Join-Path $updateBackup $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $copy) -Force | Out-Null
            Copy-Item -LiteralPath $target -Destination $copy
            if ((Get-FileHash -LiteralPath $copy).Hash -ne (Get-FileHash -LiteralPath $target).Hash) { throw "Update backup verification failed: $relative" }
            $saved[$relative] = $copy
        }
    }
    if ($saved.Count) {
        [ordered]@{ purpose = 'Restore product files after this update; config and recovery are excluded.'; installDirectory = $InstallDirectory; savedFiles = @($saved.Keys); cleanup = 'Delete after confirming this installation works.' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $updateBackup 'backup-info.json') -Encoding utf8NoBOM
    }
    if ($managedInstallation) { Assert-ManagedInstallationSnapshot $managedInstallation } else { New-TrackedDirectory (Join-Path $InstallDirectory 'bin') }
    foreach ($relative in $products) {
        $inputPath = if ($relative -eq 'source-info.json') { Join-Path $WorkDirectory $relative } else { Join-Path $packageBin ([IO.Path]::GetFileName($relative)) }
        $target = Join-Path $InstallDirectory $relative
        [void]$changed.Add($relative)
        Copy-Item -LiteralPath $inputPath -Destination $target -Force
        if ((Get-FileHash -LiteralPath $inputPath).Hash -ne (Get-FileHash -LiteralPath $target).Hash) { throw "Installed file verification failed: $relative" }
    }
    if (!$existingConfig) {
        # CreateNewで並行作成された設定も上書きしない。
        $stream = [IO.File]::Open($configPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $createdConfig = @{ createdUtcTicks = (Get-Item -LiteralPath $configPath).CreationTimeUtc.Ticks; sha256 = $null }
        try { $bytes = [IO.File]::ReadAllBytes($newConfig); $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
        $createdConfig.sha256 = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    }
    if ($existingConfig) {
        [void](Assert-PlainPath $configPath 'Capacity migration configuration')
        # 読込経路は変更せず、正式更新時だけ一度移行する。未知の設定もJSON木で保持する。
        $originalBytes = [IO.File]::ReadAllBytes($configPath)
        $originalHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($originalBytes))
        if ($managedInstallation -and $originalHash -ine $managedInstallation.configHash) { throw 'Managed recovery configuration changed; migration was not started.' }
        $nodeOptions = [Text.Json.Nodes.JsonNodeOptions]::new()
        $nodeOptions.PropertyNameCaseInsensitive = $true
        $settings = [Text.Json.Nodes.JsonNode]::Parse([Text.Encoding]::UTF8.GetString($originalBytes).TrimStart([char]0xfeff), $nodeOptions, [Text.Json.JsonDocumentOptions]::new())
        if ($settings -isnot [Text.Json.Nodes.JsonObject]) { throw 'Configuration must be a JSON object.' }
        $migrationVersion = $settings['capacityDefaultMigrationVersion']
        if ($null -eq $migrationVersion -or $migrationVersion.GetValue[int]() -lt 1) {
            $settings['maxRecoveryBytes'] = [Text.Json.Nodes.JsonValue]::Create([long]1073741824)
            $settings['capacityDefaultMigrationVersion'] = [Text.Json.Nodes.JsonValue]::Create([int]1)
            $candidate = Join-Path $WorkDirectory 'migrated-config.json'
            [IO.File]::WriteAllText($candidate, $settings.ToJsonString(), [Text.UTF8Encoding]::new($false))
            & $exe --config $candidate validate-config | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Prunlet rejected the migrated configuration; the original was preserved.' }
            $originalHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($originalBytes))
            $migrationBackup = Join-Path $updateBackup 'config-before-capacity-migration.json'
            New-Item -ItemType Directory -Path $updateBackup -Force | Out-Null
            [IO.File]::WriteAllBytes($migrationBackup, $originalBytes)
            $temporaryConfig = Join-Path $InstallDirectory ('config-migration-' + [guid]::NewGuid().ToString('N') + '.json')
            try {
                [IO.File]::Copy($candidate, $temporaryConfig, $false)
                # 通常の書込みを排除し、検証した原本だけを原子的に置換する。
                $guard = [IO.File]::Open($configPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
                try {
                    if ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ne $originalHash) { throw 'Configuration changed during capacity migration; it was preserved.' }
                    $migratedHash = (Get-FileHash -LiteralPath $temporaryConfig -Algorithm SHA256).Hash
                    [IO.File]::Replace($temporaryConfig, $configPath, [Management.Automation.Language.NullString]::Value)
                    $migratedConfig = @{ backup = $migrationBackup; sha256 = $migratedHash }
                } finally { $guard.Dispose() }
            } finally {
                if (Test-Path -LiteralPath $temporaryConfig -PathType Leaf) { Remove-Item -LiteralPath $temporaryConfig }
            }
        }
    }
    if ($RegisterCodex) {
        # 連携側の2ファイル書込みを一つの操作として戻せるよう、呼出し前のバイト列を保全する。
        $profileFiles = @('hooks.json', 'config.toml')
        if ($RegisterAgentInstructions) { $profileFiles += @('AGENTS.md', 'PRUNLET.md') }
        foreach ($fileName in $profileFiles) {
            $target = Assert-PlainPath (Join-Path $CodexHome $fileName) 'Codex configuration path'
            if (Test-Path -LiteralPath $target -PathType Container) { throw "Codex configuration path is a directory: $target" }
            $existed = Test-Path -LiteralPath $target -PathType Leaf
            $backup = $null
            $originalHash = $null
            if ($existed) {
                $backup = Join-Path $updateBackup ('codex-profile\' + $fileName)
                New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
                [IO.File]::WriteAllBytes($backup, [IO.File]::ReadAllBytes($target))
                $originalHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
            }
            $profileSnapshot.Add([ordered]@{ target = $target; existed = $existed; backup = $backup; sha256 = $originalHash })
        }
        New-Item -ItemType Directory -Path $updateBackup -Force | Out-Null
        [ordered]@{ purpose = 'Restore Codex profile files if registration fails.'; installDirectory = $InstallDirectory; files = @($profileSnapshot.ToArray()); restore = 'For an originally existing file copy its backup to target; for an originally absent file remove the newly created target after reviewing it.'; retention = 'Keep until installation and Codex registration are verified; delete this installation backup when no recovery is required.' } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $updateBackup 'profile-backup-info.json') -Encoding utf8NoBOM
        $registration = @{ ExecutablePath = (Join-Path $InstallDirectory 'bin\prunlet.exe'); ConfigPath = $configPath; CodexHome = $CodexHome }
        if ($SettingsBackupDirectory) { $registration.BackupDirectory = $SettingsBackupDirectory }
        # 既存連携スクリプトの任意キー処理には呼出し元のStrictModeを伝播させない。
        $registrationStarted = $true
        & { Set-StrictMode -Off; & (Join-Path $InstallDirectory 'bin\install-codex.ps1') @registration } | Out-Null
        if ($RegisterAgentInstructions) {
            $instructionParameters.SourceGuidePath = Join-Path $InstallDirectory 'bin\PRUNLET.md'
            & (Join-Path $InstallDirectory 'bin\install-agent-instructions.ps1') @instructionParameters | Out-Null
        }
    }
    # Codex連携とは独立した製品機能として、無操作時もログイン中に日次保守する。
    New-Item -ItemType Directory -Path $updateBackup -Force | Out-Null
    if ($maintenanceState.previousXml) { [IO.File]::WriteAllText((Join-Path $updateBackup 'maintenance-task.xml'), $maintenanceState.previousXml, [Text.Encoding]::Unicode) }
    [ordered]@{ purpose = 'Restore the owned maintenance task if this installation fails.'; installDirectory = $InstallDirectory; taskName = $maintenanceState.name; taskPath = '\'; existed = [bool]$maintenanceState.previousXml; previousXml = $(if ($maintenanceState.previousXml) { 'maintenance-task.xml' } else { $null }); restore = 'First verify current task ownership using maintenance-task.ps1; restore previous XML if existed, otherwise unregister only the owned task.' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $updateBackup 'maintenance-task-backup-info.json') -Encoding utf8NoBOM
    $maintenanceStarted = $true
    Register-PrunletMaintenanceTask $maintenanceState
    if ($updateTaskState) {
        # CodexがMCPを起動しないPCでも最新releaseへ追従させる更新タスク（start-prunlet-mcp.ps1 -UpdateOnly）。
        if ($updateTaskState.previousXml) { [IO.File]::WriteAllText((Join-Path $updateBackup 'update-task.xml'), $updateTaskState.previousXml, [Text.Encoding]::Unicode) }
        [ordered]@{ purpose = 'Restore the owned update task if this installation fails.'; installDirectory = $InstallDirectory; taskName = $updateTaskState.name; taskPath = '\'; existed = [bool]$updateTaskState.previousXml; previousXml = $(if ($updateTaskState.previousXml) { 'update-task.xml' } else { $null }); restore = 'First verify current task ownership using maintenance-task.ps1; restore previous XML if existed, otherwise unregister only the owned task.' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $updateBackup 'update-task-backup-info.json') -Encoding utf8NoBOM
        $updateTaskStarted = $true
        Register-PrunletUpdateTask $updateTaskState
    }
    # 廃止したバックエンドも記録なしのCore経路でWindowsのゴミ箱へ渡す。
    foreach ($relative in $retiredProducts) {
        $target = Assert-PlainPath (Join-Path $InstallDirectory $relative) 'Retired product path'
        if (!(Test-Path -LiteralPath $target -PathType Leaf)) { continue }
        $installedExe = Join-Path $InstallDirectory 'bin\prunlet.exe'
        [void]$changed.Add($relative)
        $retirementJson = & $installedExe --config $configPath delete -- $target
        if ($LASTEXITCODE -ne 0) { throw 'Prunlet could not retire the obsolete hook backend; recovery data was preserved.' }
        $retirement = $retirementJson | ConvertFrom-Json -AsHashtable
        if (@($retirement.items).Count -ne 1 -or @($retirement.items | Where-Object status -ne 'recycled').Count -or (Test-Path -LiteralPath $target)) { throw 'Retired product recycling was not confirmed.' }
        $retiredProductPaths.Add($target)
        $retirementJson | Set-Content -LiteralPath (Join-Path $updateBackup 'retired-products.json') -Encoding utf8NoBOM
    }
    # 移行開始後は旧exeへ戻さない。移行済み領域も同じ新版で再開できる状態を残す。
    if ($managedInstallation) {
        $expectedConfiguration = if ($migratedConfig) { $migratedConfig.sha256 } else { $managedInstallation.configHash }
        Assert-ManagedRecoveryBinding $managedInstallation $expectedConfiguration
    }
    $storageMigrationStarted = $true
    $migrationJson = & (Join-Path $InstallDirectory 'bin\prunlet.exe') --config $configPath migrate --apply --if-needed
    $migrationExitCode = $LASTEXITCODE
    $storageMigration = $migrationJson | ConvertFrom-Json -AsHashtable
    if ($migrationExitCode -ne 0 -or !$storageMigration.registryReady -or @($storageMigration.operations | Where-Object status -eq 'failed').Count) {
        throw 'Recovery storage migration is incomplete. Installed products were retained; resume with the installed CLI migrate --apply.'
    }
    if (!$storageMigration.complete) { Write-Warning 'Some legacy file recovery data was retained. Review the migration result before retrying migrate --apply; normal maintenance does not scan it.' }
    [ordered]@{ status = 'installed'; installDirectory = $InstallDirectory; configPath = $configPath; repository = $Repository; defaultBranch = $branch; releaseTag = $release.tag; commitSha = $sha; sourceInfoPath = (Join-Path $InstallDirectory 'source-info.json'); updateBackupDirectory = $updateBackup; maintenanceTaskName = $maintenanceState.name; updateTaskName = $(if ($updateTaskState) { $updateTaskState.name } else { $null }); updateTaskRegistered = [bool]$updateTaskState; retiredProductPaths = @($retiredProductPaths.ToArray()); recoveryMigration = $storageMigration; codexRegistered = [bool]$RegisterCodex; agentInstructionsRegistered = [bool]$RegisterAgentInstructions; requiresHookTrust = [bool]$RegisterCodex } | ConvertTo-Json -Depth 12
} catch {
    $originalError = $_
    if ($storageMigrationStarted) {
        throw "Installation reached recovery migration: $originalError. The updated executables, configuration, and registrations were preserved; retry the installed CLI migrate --apply. Migration result: $migrationJson"
    }
    $rollbackErrors = [Collections.Generic.List[string]]::new()
    if ($migratedConfig) {
        try {
            [void](Assert-PlainPath $configPath 'Capacity migration rollback path')
            $rollbackConfig = Join-Path $InstallDirectory ('config-rollback-' + [guid]::NewGuid().ToString('N') + '.json')
            try {
                [IO.File]::Copy($migratedConfig.backup, $rollbackConfig, $false)
                $guard = [IO.File]::Open($configPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
                try {
                    if ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ne $migratedConfig.sha256) { throw 'Migrated configuration changed; it was preserved.' }
                    [IO.File]::Replace($rollbackConfig, $configPath, [Management.Automation.Language.NullString]::Value)
                } finally { $guard.Dispose() }
            } finally { if (Test-Path -LiteralPath $rollbackConfig -PathType Leaf) { Remove-Item -LiteralPath $rollbackConfig } }
        } catch { $rollbackErrors.Add("Capacity configuration: $_") }
    }
    if ($updateTaskStarted) {
        try { Restore-PrunletUpdateTask $updateTaskState } catch { $rollbackErrors.Add("Update task: $_") }
    }
    if ($maintenanceStarted) {
        try { Restore-PrunletMaintenanceTask $maintenanceState } catch { $rollbackErrors.Add("Maintenance task: $_") }
    }
    if ($registrationStarted) {
        foreach ($profile in $profileSnapshot) {
            try {
                $target = Assert-PlainPath $profile.target 'Codex rollback path'
                if ($profile.existed) {
                    # 未変更のロック中ファイルには書き込まない。
                    if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $profile.sha256) { continue }
                    [IO.File]::WriteAllBytes($target, [IO.File]::ReadAllBytes($profile.backup))
                    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $profile.sha256) { throw 'Restored content hash differs from the preimage.' }
                } elseif (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target }
                elseif (Test-Path -LiteralPath $target) { throw 'Configuration path became a directory.' }
            } catch { $rollbackErrors.Add("Codex profile ${target}: $_") }
        }
    }
    # 連携やタスクを戻せない場合は、残った登録が指す実行ファイルを消さず保全する。
    if ($rollbackErrors.Count) { throw "Installation failed: $originalError. Installed products were retained because registration rollback failed. Recover registrations from ${updateBackup}: $($rollbackErrors -join '; ')" }
    foreach ($relative in $changed) {
        try {
            $target = Assert-PlainPath (Join-Path $InstallDirectory $relative) 'Rollback path'
            if ($saved.ContainsKey($relative)) { Copy-Item -LiteralPath $saved[$relative] -Destination $target -Force } elseif (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target }
        } catch { [void]$rollbackErrors.Add("${relative}: $_") }
    }
    if ($createdConfig) {
        try {
            [void](Assert-PlainPath $configPath 'New configuration rollback path')
            if (Test-Path -LiteralPath $configPath -PathType Leaf) {
                $configItem = Get-Item -LiteralPath $configPath
                if ($configItem.CreationTimeUtc.Ticks -ne $createdConfig.createdUtcTicks -or !$createdConfig.sha256 -or (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ne $createdConfig.sha256) { throw 'New configuration was changed or replaced; it was preserved.' }
                Remove-Item -LiteralPath $configPath
            }
        } catch { $rollbackErrors.Add("New configuration ${configPath}: $_") }
    }
    for ($index = $createdDirectories.Count - 1; $index -ge 0; $index--) {
        try {
            $directory = $createdDirectories[$index]
            $target = Assert-ExternalPath $directory.path 'Created directory rollback path'
            if ((Test-Path -LiteralPath $target -PathType Container) -and (Get-Item -LiteralPath $target).CreationTimeUtc.Ticks -eq $directory.createdUtcTicks -and !(Get-ChildItem -LiteralPath $target -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $target }
        } catch { $rollbackErrors.Add("Created directory ${target}: $_") }
    }
    if ($rollbackErrors.Count) { throw "Installation failed: $originalError. Rollback requires recovery from ${updateBackup}: $($rollbackErrors -join '; ')" }
    throw $originalError
} finally {
    if ($createdWork) {
        try {
            [void](Assert-ExternalPath $WorkDirectory 'WorkDirectory cleanup')
            # 展開元にリンクがないことを再検査して今回の専用作業場所だけ清掃する。
            if (@(Get-ChildItem -LiteralPath $WorkDirectory -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Work directory contains links; automatic cleanup stopped.' }
            Remove-Item -LiteralPath $WorkDirectory -Recurse -Force
        } catch { Write-Warning "Temporary files retained at ${WorkDirectory}: $_" }
    }
    if ($mutexAcquired) { $installationMutex.ReleaseMutex() }
    $installationMutex.Dispose()
    if ($globalMutexAcquired) { $globalInstallationMutex.ReleaseMutex() }
    $globalInstallationMutex.Dispose()
}
