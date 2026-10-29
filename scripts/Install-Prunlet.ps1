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
    [switch]$PrepareStartupUpdate
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
        if ((Test-Path -LiteralPath (Join-Path $cursor '.git')) -or (Test-Path -LiteralPath (Join-Path $cursor 'src\Prunlet\Prunlet.csproj'))) { throw "$Name cannot be inside a repository: $full" }
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
function Expand-CheckedArchive([string]$Archive, [string]$Destination) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $roots = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        [long]$total = 0
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            $segments = $name.TrimEnd('/').Split('/')
            if (!$name -or $name.Contains('\') -or $name.StartsWith('/') -or $segments.Count -lt 1) { throw "Unsafe archive path: $name" }
            foreach ($segment in $segments) {
                if (!$segment -or $segment -in @('.', '..') -or $segment -match '[:\x00-\x1f<>"|?*]' -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw "Unsafe archive path: $name" }
            }
            if (!$names.Add($name.TrimEnd('/'))) { throw "Duplicate archive path: $name" }
            $mode = ($entry.ExternalAttributes -shr 16) -band 0xf000
            if ($mode -notin @(0, 0x8000, 0x4000) -or ($entry.ExternalAttributes -band 0x400)) { throw "Archive links or special files are forbidden: $name" }
            [void]$roots.Add($segments[0])
            $total += $entry.Length
            if ($total -gt 256MB -or $zip.Entries.Count -gt 20000) { throw 'Source archive exceeds installation limits.' }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $name.Replace('/', [IO.Path]::DirectorySeparatorChar)))
            if (!(Test-InTree $target $Destination)) { throw "Archive path escapes source directory: $name" }
        }
        if ($roots.Count -ne 1) { throw 'Source archive must contain exactly one top-level directory.' }
        # 全エントリを検査してから展開し、GitHubの単一ルートを使う。
        [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
        $rootName = @($roots)[0]
        $root = Join-Path $Destination $rootName
        if (!(Test-Path -LiteralPath $root -PathType Container)) { throw 'Source archive root is not a directory.' }
        foreach ($required in @('src\Prunlet\Prunlet.csproj', 'scripts\Install-Prunlet.ps1', 'scripts\Publish-Prunlet.ps1', 'integration\start-prunlet-mcp.ps1', 'integration\configuration-common.ps1', 'integration\maintenance-task.ps1', 'integration\uninstall-maintenance.ps1', 'integration\install-codex.ps1', 'integration\uninstall-codex.ps1', 'integration\install-agent-instructions.ps1', 'integration\PRUNLET.md')) {
            if (!(Test-Path -LiteralPath (Join-Path $root $required) -PathType Leaf)) { throw "Latest source is not installable; required file missing: $required. Publish the source to the repository default branch first." }
        }
        return $root
    } finally { $zip.Dispose() }
}



if (!$IsWindows) { throw 'Prunlet installation requires Windows and PowerShell 7.' }
if ($PrepareStartupUpdate) { throw 'Source-build startup preparation is no longer supported. Use the registered MCP startup entry to verify and prepare a published release package.' }
if ($RegisterAgentInstructions -and !$RegisterCodex) { throw 'RegisterAgentInstructions requires explicit -RegisterCodex.' }
if ($Repository -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$') { throw 'Repository must be a GitHub owner/repository name.' }
$nativeArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
if ($nativeArchitecture -eq 'Arm64' -and !$PSBoundParameters.ContainsKey('Runtime')) { throw 'On Windows ARM64 explicitly choose -Runtime win-arm64 (or win-x64 for emulation).' }
if ($nativeArchitecture -notin @('X64', 'Arm64')) { throw "Unsupported Windows architecture: $nativeArchitecture" }
$runId = 'install-' + [Guid]::NewGuid().ToString('N')
$ForbiddenRoots = @((Assert-PlainPath $CodexHome 'CodexHome'), (Join-Path $env:USERPROFILE '.codex'))
if ($env:CODEX_HOME) { $ForbiddenRoots += Assert-PlainPath $env:CODEX_HOME 'CODEX_HOME' }
$scriptParent = Split-Path -Parent $PSScriptRoot
if (Test-Path -LiteralPath (Join-Path $scriptParent 'src\Prunlet\Prunlet.csproj')) { $ForbiddenRoots += $scriptParent }
$InstallDirectory = Assert-ExternalPath $InstallDirectory 'InstallDirectory'

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

if (!$BackupDirectory) { $BackupDirectory = Join-Path $InstallDirectory 'recovery' }
$BackupDirectory = Assert-ExternalPath $BackupDirectory 'BackupDirectory'
if ($existingConfig) {
    [void](Assert-PlainPath $configPath 'ConfigPath')
    $existing = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    $effectiveBackup = Assert-ExternalPath $existing.backupDirectory 'Configured backupDirectory'
} else { $effectiveBackup = $BackupDirectory }
if ((Test-InTree $effectiveBackup $WorkDirectory) -or (Test-InTree $WorkDirectory $effectiveBackup)) { throw 'WorkDirectory and recovery backup must be separate trees.' }
$UpdateBackupRoot = Assert-ExternalPath $UpdateBackupRoot 'UpdateBackupRoot'
$updateBackup = Assert-ExternalPath (Join-Path $UpdateBackupRoot $runId) 'UpdateBackupDirectory'
if ((Test-InTree $updateBackup $InstallDirectory) -or (Test-InTree $InstallDirectory $updateBackup) -or (Test-InTree $updateBackup $WorkDirectory) -or (Test-InTree $WorkDirectory $updateBackup)) { throw 'Update backup must be separate from install and work directories.' }
if ((Test-InTree $updateBackup $effectiveBackup) -or (Test-InTree $effectiveBackup $updateBackup)) { throw 'Update backup must be separate from recovery data.' }
if ($RegisterCodex -and $SettingsBackupDirectory) { $SettingsBackupDirectory = Assert-ExternalPath $SettingsBackupDirectory 'SettingsBackupDirectory' }
if (!(Get-Command dotnet -ErrorAction SilentlyContinue)) { throw '.NET 10 SDK is required. Install the SDK and run this installer again.' }
$sdks = @(& dotnet --list-sdks)
if ($LASTEXITCODE -ne 0 -or !($sdks | Where-Object { $_ -match '^10\.' })) { throw '.NET 10 SDK is required; an installed runtime alone cannot build latest source.' }
$products = @('bin\prunlet.exe', 'bin\prunlet-maintenance.exe', 'bin\prunlet-hook.exe', 'bin\Install-Prunlet.ps1', 'bin\start-prunlet-mcp.ps1', 'bin\configuration-common.ps1', 'bin\maintenance-task.ps1', 'bin\uninstall-maintenance.ps1', 'bin\install-codex.ps1', 'bin\uninstall-codex.ps1', 'bin\install-agent-instructions.ps1', 'bin\PRUNLET.md', 'source-info.json')
$retiredProducts = @('bin\codex-pretooluse.ps1')
$previousGuidePath = Join-Path $InstallDirectory 'bin\PRUNLET.md'
$previousGuideSha256 = if (Test-Path -LiteralPath $previousGuidePath -PathType Leaf) { (Get-FileHash -LiteralPath $previousGuidePath -Algorithm SHA256).Hash } else { $null }
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
$retiredProductPaths = [Collections.Generic.List[string]]::new()
$storageMigrationStarted = $false
$storageMigration = $null
$migrationJson = $null
try {
    try { $globalMutexAcquired = $globalInstallationMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $globalMutexAcquired = $true }
    if (!$globalMutexAcquired) { throw 'Another Prunlet installation is already running for this directory.' }
    try { $mutexAcquired = $installationMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mutexAcquired = $true }
    if (!$mutexAcquired) { throw 'Another Prunlet installation is already running for this directory.' }
    $metadata = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository" -Headers $headers -TimeoutSec 60
    $branch = [string]$metadata.default_branch
    if (!$branch) { throw 'GitHub did not return a default branch.' }
    $head = Invoke-RestMethod -Uri ("https://api.github.com/repos/$Repository/commits/" + [Uri]::EscapeDataString($branch)) -Headers $headers -TimeoutSec 60
    $sha = [string]$head.sha
    if ($sha -cnotmatch '^[0-9a-f]{40}$') { throw 'GitHub did not return a valid commit SHA.' }


    New-Item -ItemType Directory -Path $WorkDirectory | Out-Null
    $createdWork = $true
    $downloadUrl = "https://codeload.github.com/$Repository/zip/$sha"
    $archive = Join-Path $WorkDirectory 'source.zip'
    Invoke-WebRequest -Uri $downloadUrl -Headers @{ 'User-Agent' = 'Prunlet-Latest-Installer' } -OutFile $archive -TimeoutSec 120 | Out-Null
    $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    $sourceRoot = Expand-CheckedArchive $archive (Join-Path $WorkDirectory 'source')
    if ($RegisterAgentInstructions) {
        $instructionParameters = @{ SourceGuidePath = (Join-Path $sourceRoot 'integration\PRUNLET.md'); CodexHome = $CodexHome; BackupDirectory = $(if ($SettingsBackupDirectory) { $SettingsBackupDirectory } else { $updateBackup }); PreviousGuideSha256 = $previousGuideSha256; ExecutablePath = (Join-Path $InstallDirectory 'bin\prunlet.exe'); ConfigPath = $configPath }
        & (Join-Path $sourceRoot 'integration\install-agent-instructions.ps1') @instructionParameters -ValidateOnly | Out-Null
    }
    # 所有していない既存タスクは製品ファイルを書き換える前に拒否する。
    . (Join-Path $sourceRoot 'integration\maintenance-task.ps1')
    $maintenanceState = Get-PrunletMaintenanceState (Join-Path $InstallDirectory 'bin\prunlet.exe') $configPath
    $buildRoot = Join-Path $WorkDirectory 'build'
    & (Join-Path $sourceRoot 'scripts\Publish-Prunlet.ps1') -OutputDirectory $buildRoot -Runtime $Runtime | Out-Null
    $exe = Join-Path $buildRoot 'publish\prunlet.exe'
    if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Build did not produce prunlet.exe.' }
    $maintenanceExe = Join-Path $buildRoot 'publish\prunlet-maintenance.exe'
    if (!(Test-Path -LiteralPath $maintenanceExe -PathType Leaf)) { throw 'Build did not produce prunlet-maintenance.exe.' }
    $hookExe = Join-Path $buildRoot 'publish\prunlet-hook.exe'
    if (!(Test-Path -LiteralPath $hookExe -PathType Leaf)) { throw 'Build did not produce prunlet-hook.exe.' }
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
    foreach ($relative in $products | Where-Object { $_ -notin @('bin\prunlet.exe', 'bin\prunlet-maintenance.exe', 'bin\prunlet-hook.exe', 'source-info.json') }) {
        $source = if ($relative -eq 'bin\Install-Prunlet.ps1') { Join-Path $sourceRoot 'scripts\Install-Prunlet.ps1' } else { Join-Path $sourceRoot ('integration\' + [IO.Path]::GetFileName($relative)) }
        $auxiliaryHashes[$relative] = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    }
    $provenance = [ordered]@{ repository = $Repository; defaultBranch = $branch; commitSha = $sha; downloadUrl = $downloadUrl; archiveSha256 = $archiveHash; executableSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash; maintenanceExecutableSha256 = (Get-FileHash -LiteralPath $maintenanceExe -Algorithm SHA256).Hash; hookExecutableSha256 = (Get-FileHash -LiteralPath $hookExe -Algorithm SHA256).Hash; auxiliarySha256 = $auxiliaryHashes; installedUtc = [DateTimeOffset]::UtcNow.ToString('o'); runtime = $Runtime }
    $provenance | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $WorkDirectory 'source-info.json') -Encoding utf8NoBOM

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
    New-TrackedDirectory (Join-Path $InstallDirectory 'bin')
    foreach ($relative in $products) {
        $inputPath = if ($relative -in @('bin\prunlet.exe', 'bin\prunlet-maintenance.exe', 'bin\prunlet-hook.exe')) { Join-Path (Join-Path $buildRoot 'publish') ([IO.Path]::GetFileName($relative)) } elseif ($relative -eq 'source-info.json') { Join-Path $WorkDirectory $relative } elseif ($relative -eq 'bin\Install-Prunlet.ps1') { Join-Path $sourceRoot 'scripts\Install-Prunlet.ps1' } else { Join-Path $sourceRoot ('integration\' + [IO.Path]::GetFileName($relative)) }
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
    $storageMigrationStarted = $true
    $migrationJson = & (Join-Path $InstallDirectory 'bin\prunlet.exe') --config $configPath migrate --apply --if-needed
    $migrationExitCode = $LASTEXITCODE
    $storageMigration = $migrationJson | ConvertFrom-Json -AsHashtable
    if ($migrationExitCode -ne 0 -or !$storageMigration.registryReady -or @($storageMigration.operations | Where-Object status -eq 'failed').Count) {
        throw 'Recovery storage migration is incomplete. Installed products were retained; resume with the installed CLI migrate --apply.'
    }
    if (!$storageMigration.complete) { Write-Warning 'Some legacy file recovery data was retained. Review the migration result before retrying migrate --apply; normal maintenance does not scan it.' }
    [ordered]@{ status = 'installed'; installDirectory = $InstallDirectory; configPath = $configPath; repository = $Repository; defaultBranch = $branch; commitSha = $sha; sourceInfoPath = (Join-Path $InstallDirectory 'source-info.json'); updateBackupDirectory = $updateBackup; maintenanceTaskName = $maintenanceState.name; retiredProductPaths = @($retiredProductPaths.ToArray()); recoveryMigration = $storageMigration; codexRegistered = [bool]$RegisterCodex; agentInstructionsRegistered = [bool]$RegisterAgentInstructions; requiresHookTrust = [bool]$RegisterCodex } | ConvertTo-Json -Depth 12
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
