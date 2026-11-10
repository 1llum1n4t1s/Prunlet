param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$CodexHome
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:StartupUpdateReady = $true
$script:UseAuthenticatedUpdateApi = $false

. (Join-Path $PSScriptRoot 'configuration-common.ps1')
# job handleをPowerShellプロセスの終了まで保持し、入口終了時に子も終了させる。
function Start-PrunletMcpJob {
    if ([IntPtr]::Size -ne 8) { throw 'Prunlet MCP requires a 64-bit process.' }
    $create = New-PrunletNativeDelegate kernel32.dll CreateJobObjectW ([IntPtr]) @([IntPtr], [string])
    $set = New-PrunletNativeDelegate kernel32.dll SetInformationJobObject ([int]) @([IntPtr], [int], [IntPtr], [uint32])
    $assign = New-PrunletNativeDelegate kernel32.dll AssignProcessToJobObject ([int]) @([IntPtr], [IntPtr])
    $current = New-PrunletNativeDelegate kernel32.dll GetCurrentProcess ([IntPtr]) @()
    $close = New-PrunletNativeDelegate kernel32.dll CloseHandle ([int]) @([IntPtr])
    $name = 'Local\Prunlet.McpLauncher.' + [guid]::NewGuid().ToString('N')
    $job = $create.Invoke([IntPtr]::Zero, $name)
    $createError = [Runtime.InteropServices.Marshal]::GetLastPInvokeError()
    if ($job -eq [IntPtr]::Zero) { throw [ComponentModel.Win32Exception]::new($createError) }
    $limits = [Runtime.InteropServices.Marshal]::AllocHGlobal(144)
    try {
        if ($createError -eq 183) { throw 'Prunlet MCP launcher job name already exists.' }
        [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(144), 0, $limits, 144)
        # 通常の子は終了時に停止する。明示キューworkerだけが作成時に離脱を指定する。
        [Runtime.InteropServices.Marshal]::WriteInt32($limits, 16, (0x2000 -bor 0x0800)) # KILL_ON_JOB_CLOSE | BREAKAWAY_OK
        if (!$set.Invoke($job, 9, $limits, 144)) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastPInvokeError()) }
        if (!$assign.Invoke($job, $current.Invoke())) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastPInvokeError()) }
        $script:PrunletMcpJobHandle = $job
        $script:PrunletMcpJobName = $name
        $job = [IntPtr]::Zero
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($limits)
        if ($job -ne [IntPtr]::Zero) { [void]$close.Invoke($job) }
    }
}

function Read-StartupState([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) { return @{ product = 'Prunlet'; schema = 1; phase = 'idle' } }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Startup update state is not an ordinary file.' }
    $state = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
    if ($state.product -cne 'Prunlet' -or $state.schema -ne 1 -or !$state.ContainsKey('epoch') -or $state.epoch -ne 1 -or $state.phase -notin @('idle', 'switching', 'migrating', 'cleanup')) { throw 'Startup update state is invalid or incomplete.' }
    return $state
}

function Invoke-StageCleanup([string]$Executable, [string]$Config) {
    $output = & $Executable --config $Config __cleanup-startup-stage
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw 'Startup update stage cleanup was not confirmed; it was preserved.' }
    $result = $output | ConvertFrom-Json -AsHashtable
    if ($result.status -ceq 'retained') { throw 'Prunlet retained its update stage because its complete contents could not be proven owned.' }
    if ($result.status -notin @('recycled', 'permanently_deleted', 'already_cleaned')) { throw 'Startup update stage cleanup returned an unknown result.' }
}

function Test-StageCleanupReady([hashtable]$State) {
    if (!$State.ContainsKey('stageCleanup') -or $State.stageCleanup -cne 'pending') { return $false }
    if (!$State.ContainsKey('candidateCliSha256') -or !$State.candidateCliSha256) { return $true }
    foreach ($name in @('cleanupCli', 'cleanupMaintenance', 'cleanupHook')) {
        if (!$State.ContainsKey($name) -or $State[$name] -cne 'done') { return $false }
    }
    return $true
}

function Test-ProductsIdle([string]$Executable) {
    $handles = [Collections.Generic.List[IO.FileStream]]::new()
    try {
        foreach ($path in @($Executable, (Join-Path ([IO.Path]::GetDirectoryName($Executable)) 'prunlet-maintenance.exe'))) {
            $handles.Add([IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Write, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete)))
        }
        return $true
    } catch [IO.IOException] { return $false }
    finally { foreach ($handle in $handles) { $handle.Dispose() } }
}

function Get-UpdateApi([string]$Endpoint) {
    $headers = @{ 'User-Agent' = 'Prunlet-Latest-Installer'; 'Accept' = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if (!$script:UseAuthenticatedUpdateApi) {
        try { return Invoke-RestMethod -Uri ('https://api.github.com/' + $Endpoint) -Headers $headers -TimeoutSec 8 }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $response = $_.Exception.Response
            $remaining = $null
            # 未認証primary枠切れだけを切り替え、Retry-After付きや通常の権限拒否は再送しない。
            if ($response.StatusCode -ne 403 -or $response.Headers.Contains('Retry-After') -or
                !$response.Headers.TryGetValues('X-RateLimit-Remaining', [ref]$remaining) -or
                (@($remaining) -join ',') -cne '0') { throw }
            $script:UseAuthenticatedUpdateApi = $true
        }
    }
    $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$gh) { throw 'GitHub anonymous API rate limit exceeded and GitHub CLI is unavailable.' }
    $start = [Diagnostics.ProcessStartInfo]::new($gh.Source)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    foreach ($arg in @('api', '--hostname', 'github.com', '--method', 'GET', '--header', 'Accept: application/vnd.github+json', '--header', 'X-GitHub-Api-Version: 2022-11-28', $Endpoint)) { $start.ArgumentList.Add($arg) }
    # 既存認証はghの内部だけで使い、対話とデバッグを無効にする。
    [void]$start.Environment.Remove('GH_DEBUG')
    [void]$start.Environment.Remove('GH_FORCE_TTY')
    $start.Environment['GH_PAGER'] = 'cat'
    $start.Environment['NO_COLOR'] = '1'
    $start.Environment['GH_PROMPT_DISABLED'] = '1'
    $start.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $process = [Diagnostics.Process]::Start($start)
    try {
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(8000)) {
            try { $process.Kill($true) } catch { }
            throw 'GitHub CLI update request timed out.'
        }
        [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'GitHub CLI update request failed; existing authentication may be unavailable.' }
        try { return ConvertFrom-Json -InputObject $stdout.GetAwaiter().GetResult() -ErrorAction Stop }
        catch { throw 'GitHub CLI returned invalid update metadata.' }
    } finally { $process.Dispose() }
}

function Get-LatestReleaseInfo([string]$Repository, [string]$Runtime) {
    if ($Repository -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$') { throw 'Installed repository is invalid.' }
    if ($Runtime -cnotin @('win-x64', 'win-arm64')) { throw 'Installed runtime is unsupported.' }
    $metadata = Get-UpdateApi "repos/$Repository"
    $branch = [string]$metadata.default_branch
    if (!$branch) { throw 'GitHub did not return a default branch.' }
    $release = Get-UpdateApi "repos/$Repository/releases/latest"
    $tag = [string]$release.tag_name
    if (!$tag -or $release.draft -or $release.prerelease) { throw 'GitHub did not return a published stable release.' }
    if ($tag -cnotmatch '\Av?[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9.-]+)?\z') { throw 'Published release tag is invalid.' }
    $reference = Get-UpdateApi "repos/$Repository/git/ref/tags/$tag"
    $target = $reference.object
    for ($depth = 0; $depth -lt 8; $depth++) {
        $sha = [string]$target.sha
        if ($sha -cnotmatch '^[0-9a-f]{40}$') { throw 'Release tag has an invalid object SHA.' }
        if ($target.type -ceq 'commit') {
            $comparison = Get-UpdateApi ("repos/$Repository/compare/$sha..." + [Uri]::EscapeDataString($branch) + '?per_page=1')
            if ($comparison.status -cnotin @('ahead', 'identical')) { throw 'Release commit is not on the default branch.' }
            $name = 'prunlet-update-' + $Runtime + '.zip'
            $assets = @($release.assets | Where-Object { $_.name -ceq $name -and $_.state -ceq 'uploaded' })
            if ($assets.Count -ne 1) { throw 'A unique published package for this runtime is unavailable.' }
            $asset = $assets[0]
            if ([string]$asset.digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or [long]$asset.size -le 0 -or [long]$asset.size -gt 536870912) { throw 'Published package digest or size is invalid.' }
            if ([long]$asset.id -le 0) { throw 'Published package identity is invalid.' }
            # GitHub Releaseの発行者を信頼する。digestは転送内容の照合であり、独立したbuild来歴証明ではない。
            return @{ commit = $sha; branch = $branch; tag = $tag; assetSha256 = ([string]$asset.digest).Substring(7); assetBytes = [long]$asset.size; assetId = [long]$asset.id }
        }
        if ($target.type -cne 'tag') { throw 'Release tag does not identify a commit.' }
        $annotated = Get-UpdateApi "repos/$Repository/git/tags/$sha"
        $target = $annotated.object
    }
    throw 'Release tag nesting exceeds the supported depth.'
}

function Get-LatestCommit([string]$Repository, [string]$Runtime, [string]$InstalledCommit, [hashtable]$ReleaseInfo = $null) {
    if ($InstalledCommit -cnotmatch '^[0-9a-fA-F]{40}$') { throw 'Installed commit is invalid.' }
    $release = if ($null -eq $ReleaseInfo) { Get-LatestReleaseInfo $Repository $Runtime } else { $ReleaseInfo }
    if ($release.commit -ine $InstalledCommit) {
        $comparison = Get-UpdateApi "repos/$Repository/compare/$InstalledCommit...$($release.commit)?per_page=1"
        if ($comparison.status -cne 'ahead') { throw 'Published release does not descend from the installed commit.' }
    }
    return $release.commit
}

function Invoke-CandidateProbe([string]$Executable, [string[]]$Arguments, [int]$ExpectedExit) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (!$process.Start()) { throw 'Candidate executable did not start.' }
        $process.StandardInput.Close()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(15000)) { $process.Kill($true); $process.WaitForExit(); throw 'Candidate startup probe timed out.' }
        if ($process.ExitCode -ne $ExpectedExit) { throw 'Candidate executable did not return the expected startup result.' }
        $null = $errorOutput.GetAwaiter().GetResult()
        return $output.GetAwaiter().GetResult()
    } finally { $process.Dispose() }
}

function Test-CandidateExecutables([string]$Stage) {
    $protocol = (Invoke-CandidateProbe (Join-Path $Stage 'prunlet.exe') @('--startup-update-protocol') 0) | ConvertFrom-Json -AsHashtable
    if ($protocol.protocol -ne 1 -or $protocol.storageEpoch -ne 1) { throw 'Published candidate has an incompatible update or storage protocol.' }
    $null = Invoke-CandidateProbe (Join-Path $Stage 'prunlet-maintenance.exe') @('--help') 2
    $hook = (Invoke-CandidateProbe (Join-Path $Stage 'prunlet-hook.exe') @('--help') 0) | ConvertFrom-Json -AsHashtable
    if ($hook.hookSpecificOutput.permissionDecision -cne 'deny') { throw 'Published hook did not return a fail-closed response.' }
}

function Open-CandidateGuards([string]$Stage, [string]$StatePath) {
    $guards = [Collections.Generic.List[IO.FileStream]]::new()
    try {
        $stageFull = [IO.Path]::GetFullPath($Stage)
        $state = Read-StartupState $StatePath
        $files = [ordered]@{
            'prunlet.exe' = 'executableSha256'
            'prunlet-maintenance.exe' = 'maintenanceExecutableSha256'
            'prunlet-hook.exe' = 'hookExecutableSha256'
        }
        $auxiliary = [ordered]@{
            'scripts\Install-Prunlet.ps1' = 'bin\Install-Prunlet.ps1'
            'integration\start-prunlet-mcp.ps1' = 'bin\start-prunlet-mcp.ps1'
            'integration\configuration-common.ps1' = 'bin\configuration-common.ps1'
            'integration\maintenance-task.ps1' = 'bin\maintenance-task.ps1'
            'integration\uninstall-maintenance.ps1' = 'bin\uninstall-maintenance.ps1'
            'integration\install-codex.ps1' = 'bin\install-codex.ps1'
            'integration\uninstall-codex.ps1' = 'bin\uninstall-codex.ps1'
            'integration\install-agent-instructions.ps1' = 'bin\install-agent-instructions.ps1'
            'integration\PRUNLET.md' = 'bin\PRUNLET.md'
        }
        $relativeNames = @('source-info.json', '.prunlet-stage-owner.json') + @($files.Keys) + @($auxiliary.Keys)
        foreach ($relative in $relativeNames) {
            $path = [IO.Path]::GetFullPath((Join-Path $stageFull $relative))
            if (!$path.StartsWith($stageFull.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Candidate path escaped its stage.' }
            $cursor = $path
            while ($cursor -and $cursor.StartsWith($stageFull, [StringComparison]::OrdinalIgnoreCase)) {
                $item = Get-Item -LiteralPath $cursor -Force
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Candidate paths cannot traverse links.' }
                if ($cursor.Equals($stageFull, [StringComparison]::OrdinalIgnoreCase)) { break }
                $cursor = [IO.Path]::GetDirectoryName($cursor)
            }
            $item = Get-Item -LiteralPath $path -Force
            if ($item.PSIsContainer) { throw 'A candidate product is not a file.' }
            $guards.Add([IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
        }
        $infoGuard = $guards[0]
        $reader = [IO.StreamReader]::new($infoGuard, [Text.Encoding]::UTF8, $true, 4096, $true)
        try { $info = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable } finally { $reader.Dispose() }
        if (!$state.ContainsKey('candidateCommit') -or $info.commitSha -ine $state.candidateCommit) { throw 'Candidate commit does not match the update state.' }
        if ($state.ContainsKey('candidateSourceInfoSha256') -and $state.candidateSourceInfoSha256) {
            $infoGuard.Position = 0
            if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($infoGuard)) -ine $state.candidateSourceInfoSha256) { throw 'Candidate provenance changed.' }
        }
        $ownerReader = [IO.StreamReader]::new($guards[1], [Text.Encoding]::UTF8, $true, 4096, $true)
        try { $owner = $ownerReader.ReadToEnd() | ConvertFrom-Json -AsHashtable } finally { $ownerReader.Dispose() }
        if ($owner.product -cne 'Prunlet' -or $owner.schema -ne 1 -or $owner.epoch -ne 1 -or $owner.candidateCommit -ine $state.candidateCommit -or $owner.installRoot -ine [IO.Path]::GetDirectoryName($stageFull)) { throw 'Candidate stage ownership is invalid.' }
        $index = 2
        foreach ($relative in $files.Keys) {
            $expected = [string]$info[$files[$relative]]
            if ($expected -cnotmatch '^[A-Fa-f0-9]{64}$' -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($guards[$index])) -ine $expected) { throw "Candidate product changed: $relative" }
            $index++
        }
        foreach ($relative in $auxiliary.Keys) {
            $expected = [string]$info.auxiliarySha256[$auxiliary[$relative]]
            if ($expected -cnotmatch '^[A-Fa-f0-9]{64}$' -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($guards[$index])) -ine $expected) { throw "Candidate integration changed: $relative" }
            $index++
        }
        return ,$guards
    } catch {
        foreach ($guard in $guards) { $guard.Dispose() }
        throw
    }
}

function Open-RegistrationGuards([string]$Executable, [string]$Config, [string]$Codex, [string]$Stage) {
    $guards = [Collections.Generic.List[IO.FileStream]]::new()
    $bin = [IO.Path]::GetDirectoryName($Executable)
    $root = [IO.Path]::GetDirectoryName($bin)
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))
    $global = [Threading.Mutex]::new($false, ('Global\Prunlet-Install-' + $key))
    $local = [Threading.Mutex]::new($false, ('Local\Prunlet-Install-' + $key))
    $ownsGlobal = $false; $ownsLocal = $false
    try {
        try { $ownsGlobal = $global.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsGlobal = $true }
        if (!$ownsGlobal) { throw 'Another Prunlet installation is running.' }
        try { $ownsLocal = $local.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsLocal = $true }
        if (!$ownsLocal) { throw 'Another Prunlet installation is running.' }
        foreach ($name in @('hooks.json', 'config.toml', 'AGENTS.md', 'PRUNLET.md')) {
            $path = Join-Path $Codex $name
            if ($name -in @('AGENTS.md', 'PRUNLET.md') -and !(Test-Path -LiteralPath $path)) { continue }
            $item = Get-Item -LiteralPath $path -Force
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Codex registration is not an ordinary file.' }
            $guards.Add([IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
        }
        # ValidateOnlyは保存しないため、導入先の外にある検証用の名前だけを指定する。
        $validationBackup = Join-Path ([IO.Path]::GetTempPath()) 'Prunlet-Registration-Validation'
        $registration = @{ ExecutablePath = $Executable; ConfigPath = $Config; CodexHome = $Codex; BackupDirectory = $validationBackup }
        $preview = & (Join-Path $bin 'install-codex.ps1') @registration -ValidateOnly
        if ($preview.hookChanged -or $preview.mcpChanged) { throw 'Codex registration changed and requires review; its settings were preserved.' }
        return ,$guards
    } catch {
        foreach ($guard in $guards) { $guard.Dispose() }
        throw
    } finally {
        if ($ownsLocal) { $local.ReleaseMutex() }
        if ($ownsGlobal) { $global.ReleaseMutex() }
        $local.Dispose(); $global.Dispose()
    }
}

function Invoke-Integration([string]$Candidate, [string]$Stage, [string]$Config, [string]$Codex, [string]$Executable) {
    $applied = & $Candidate --config $Config __apply-startup-integration
    if ($LASTEXITCODE -ne 0 -or ($applied | ConvertFrom-Json -AsHashtable).status -cne 'integration_applied') { throw 'Prunlet auxiliary products were not updated.' }
    $bin = [IO.Path]::GetDirectoryName($Executable)
    $backup = Join-Path $Stage 'registration-backup'
    if (!(Test-Path -LiteralPath $backup)) { New-Item -ItemType Directory -Path $backup | Out-Null }
    $root = [IO.Path]::GetDirectoryName($bin)
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))
    $global = [Threading.Mutex]::new($false, ('Global\Prunlet-Install-' + $key))
    $local = [Threading.Mutex]::new($false, ('Local\Prunlet-Install-' + $key))
    $ownsGlobal = $false; $ownsLocal = $false; $guards = $null
    try {
        try { $ownsGlobal = $global.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsGlobal = $true }
        if (!$ownsGlobal) { throw 'Another Prunlet installation is running.' }
        try { $ownsLocal = $local.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsLocal = $true }
        if (!$ownsLocal) { throw 'Another Prunlet installation is running.' }
        $guards = Open-RegistrationGuards $Executable $Config $Codex $Stage
        $oldInfo = [IO.File]::ReadAllText((Join-Path $Stage 'previous-source-info.json')) | ConvertFrom-Json -AsHashtable
        $oldGuideHash = [string]$oldInfo.auxiliarySha256['bin\PRUNLET.md']
        $agent = @{
            SourceGuidePath = (Join-Path $Stage 'integration\PRUNLET.md')
            PreviousGuideSha256 = $oldGuideHash
            ExecutablePath = $Executable
            ConfigPath = $Config
            CodexHome = $Codex
            BackupDirectory = $backup
            StartupUpdate = $true
        }
        $agentHelper = Join-Path $bin 'install-agent-instructions.ps1'
        $agentState = & $agentHelper @agent -ValidateOnly
        if (!$agentState.ContainsKey('instructionsPresent') -or !$agentState.ContainsKey('agentChanged') -or !$agentState.ContainsKey('guideChanged')) { throw 'Agent instruction validation is incompatible.' }
        if ($agentState.instructionsPresent -and ($agentState.agentChanged -or $agentState.guideChanged)) {
            throw 'Agent instructions require an update; concurrent edits must be preserved.'
        }
        # 所有タスクの設定を維持し、更新途中でも元のXMLを確認できるようにする。
        . (Join-Path $bin 'maintenance-task.ps1')
        $maintenance = Get-PrunletMaintenanceState $Executable $Config
        if ($maintenance.previousXml) {
            $taskBackup = Join-Path $backup 'maintenance-task.xml'
            if (!(Test-Path -LiteralPath $taskBackup)) {
                $xmlBytes = [Text.Encoding]::Unicode.GetBytes($maintenance.previousXml)
                $budget = & $Candidate --config $Config __check-startup-budget ($xmlBytes.Length + [Text.Encoding]::Unicode.GetPreamble().Length)
                if ($LASTEXITCODE -ne 0 -or ($budget | ConvertFrom-Json -AsHashtable).status -cne 'available') { throw 'Maintenance task backup would exceed the update storage budget.' }
                $output = [IO.File]::Open($taskBackup, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $output.Write([Text.Encoding]::Unicode.GetPreamble()); $output.Write($xmlBytes); $output.Flush($true) }
                finally { $output.Dispose() }
            }
            Register-PrunletMaintenanceTask $maintenance
        }
        # coordinatorが同じmutexを取得できるよう、登録の確定後に解放する。
        $local.ReleaseMutex(); $ownsLocal = $false
        $global.ReleaseMutex(); $ownsGlobal = $false
        $confirmed = & $Candidate --config $Config __confirm-startup-integration
        if ($LASTEXITCODE -ne 0 -or ($confirmed | ConvertFrom-Json -AsHashtable).status -cne 'integration_confirmed') { throw 'Prunlet integration could not be confirmed.' }
    } finally {
        if ($guards) { foreach ($guard in $guards) { $guard.Dispose() } }
        if ($ownsLocal) { $local.ReleaseMutex() }
        if ($ownsGlobal) { $global.ReleaseMutex() }
        $local.Dispose(); $global.Dispose()
    }
}

function Invoke-UpdateCoordinator([string]$Stage, [string]$Config, [string]$Codex, [string]$Executable) {
    if (!$script:StartupUpdateReady) { throw 'Prunlet startup updates are disabled until safe stage reuse is implemented and verified.' }
    $candidate = Join-Path $Stage 'prunlet.exe'
    if (!(Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'The prepared update executable is missing; the update was preserved.' }
    $root = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($Executable))
    $candidateGuards = Open-CandidateGuards $Stage (Join-Path $root '.prunlet-update-state.json')
    try {
    Test-CandidateExecutables $Stage
    $guards = Open-RegistrationGuards $Executable $Config $Codex $Stage
    try {
        $state = Read-StartupState (Join-Path $root '.prunlet-update-state.json')
        if ($state.phase -ceq 'idle' -and (!$state.ContainsKey('candidateCliSha256') -or !$state.candidateCliSha256)) {
            # 候補の登録仕様が変更を要する場合は、製品を切り替える前に延期する。
            $candidateHelper = Join-Path $Stage 'integration\install-codex.ps1'
            $validationBackup = Join-Path ([IO.Path]::GetTempPath()) 'Prunlet-Registration-Validation'
            $preview = & $candidateHelper -ExecutablePath $Executable -ConfigPath $Config -CodexHome $Codex -BackupDirectory $validationBackup -ValidateOnly
            if (!$preview.ContainsKey('hookChanged') -or !$preview.ContainsKey('mcpChanged')) { throw 'Candidate Codex validation is incompatible.' }
            if ($preview.hookChanged -or $preview.mcpChanged) { throw 'The candidate changes Codex registration and requires review; the installed products were preserved.' }
            $oldInfo = [IO.File]::ReadAllText((Join-Path $root 'source-info.json')) | ConvertFrom-Json -AsHashtable
            $candidateAgent = Join-Path $Stage 'integration\install-agent-instructions.ps1'
            $agentPreview = & $candidateAgent -SourceGuidePath (Join-Path $Stage 'integration\PRUNLET.md') -PreviousGuideSha256 ([string]$oldInfo.auxiliarySha256['bin\PRUNLET.md']) -ExecutablePath $Executable -ConfigPath $Config -CodexHome $Codex -BackupDirectory $validationBackup -ValidateOnly
            if (!$agentPreview.ContainsKey('instructionsPresent') -or !$agentPreview.ContainsKey('agentChanged') -or !$agentPreview.ContainsKey('guideChanged')) { throw 'Candidate agent instruction validation is incompatible.' }
            if ($agentPreview.instructionsPresent -and ($agentPreview.agentChanged -or $agentPreview.guideChanged)) {
                throw 'The candidate changes agent instructions and requires review; the installed products were preserved.'
            }
        }
        $output = & $candidate --config $Config __apply-startup-update
        $exitCode = $LASTEXITCODE
        $result = $output | ConvertFrom-Json -AsHashtable
        if ($exitCode -eq 0 -and $result.status -ceq 'integration_required') {
            # 最初の確認から連携確定まで、登録内容の同じread guardを保持する。
            Invoke-Integration $candidate $Stage $Config $Codex $Executable
            $output = & $candidate --config $Config __apply-startup-update
            $exitCode = $LASTEXITCODE
            $result = $output | ConvertFrom-Json -AsHashtable
        }
        if ($exitCode -ne 0 -and $result.status -cne 'deferred') { throw 'The startup update did not complete; the update was preserved.' }
        if ($result.status -ceq 'deferred') {
            $reason = if ($result.ContainsKey('error')) { [string]$result.error } elseif ($result.ContainsKey('warnings') -and $result.warnings) { $result.warnings -join '; ' } else { 'The current products could not be safely switched.' }
            [Console]::Error.WriteLine('Prunlet update was deferred: ' + $reason)
        }
        return $result
    } finally { foreach ($guard in $guards) { $guard.Dispose() } }
    } finally { foreach ($guard in $candidateGuards) { $guard.Dispose() } }
}

try {
    Start-PrunletMcpJob
    foreach ($path in @($ExecutablePath, $ConfigPath, $CodexHome)) {
        if (![IO.Path]::IsPathFullyQualified($path)) { throw 'Prunlet MCP paths must be absolute.' }
    }
    $ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    $CodexHome = [IO.Path]::GetFullPath($CodexHome)
    $bin = [IO.Path]::GetDirectoryName($ExecutablePath)
    $root = [IO.Path]::GetDirectoryName($bin)
    $managed = $root -and [IO.Path]::GetFileName($ExecutablePath).Equals('prunlet.exe', [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($bin).Equals('bin', [StringComparison]::OrdinalIgnoreCase) -and $ConfigPath.Equals((Join-Path $root 'config.json'), [StringComparison]::OrdinalIgnoreCase)
    if ($managed) {
        $statePath = Join-Path $root '.prunlet-update-state.json'
        $stage = Join-Path $root '.prunlet-update-stage'
        $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))
        $mutex = [Threading.Mutex]::new($false, ('Global\Prunlet-Startup-' + $key))
        $acquired = $false
        $cleanupTried = $false
        try {
            try { $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(8)) } catch [Threading.AbandonedMutexException] { $acquired = $true }
            if (!$acquired) { throw 'Another Prunlet startup update did not finish.' }
            $state = Read-StartupState $statePath
            if (@(Get-ChildItem -LiteralPath $root -Filter '.prunlet-update-state.*.pending' -File -Force -ErrorAction Stop).Count) {
                [Console]::Error.WriteLine('Prunlet preserved an unpublished update-state file after an interrupted update; inspect it before cleanup.')
            }
            if ($state.phase -cne 'idle') {
                $result = Invoke-UpdateCoordinator $stage $ConfigPath $CodexHome $ExecutablePath
                if ($result.status -notin @('updated', 'cleanup_pending')) { throw 'The interrupted Prunlet update still requires recovery.' }
                $state = Read-StartupState $statePath
            }
            if ($state.ContainsKey('stageCleanup') -and $state.stageCleanup -ceq 'attempting') {
                [Console]::Error.WriteLine('Prunlet retained an uncertain update stage; automatic cleanup was not retried.')
            } else {
                $sourceInfo = [IO.File]::ReadAllText((Join-Path $root 'source-info.json')) | ConvertFrom-Json -AsHashtable
                if ($sourceInfo.runtime -notin @('win-x64', 'win-arm64')) { throw 'Installed Prunlet runtime is unknown.' }
                # 通信不能時は短い照会期限で現在版へ戻し、同一SHAならビルドを起動しない。
                $release = Get-LatestReleaseInfo ([string]$sourceInfo.repository) ([string]$sourceInfo.runtime)
                $latest = Get-LatestCommit ([string]$sourceInfo.repository) ([string]$sourceInfo.runtime) ([string]$sourceInfo.commitSha) $release
                if ($latest -ieq $sourceInfo.commitSha) {
                    # 最新を確認できたため、配置内容には触れない。
                } elseif (!(Test-ProductsIdle $ExecutablePath)) {
                    [Console]::Error.WriteLine('Prunlet update was deferred while an existing process is active.')
                } else {
                    if (!$script:StartupUpdateReady) { throw 'Prunlet startup updates are disabled until safe stage reuse is implemented and verified.' }
                    $begin = & $ExecutablePath --config $ConfigPath __begin-published-update $release.commit $sourceInfo.commitSha
                    if ($LASTEXITCODE -ne 0 -or ($begin | ConvertFrom-Json -AsHashtable).status -notin @('ready', 'existing')) { throw 'Published update state could not be prepared.' }
                    $beginResult = $begin | ConvertFrom-Json -AsHashtable
                    if ($beginResult.ContainsKey('warnings')) { foreach ($warning in $beginResult.warnings) { [Console]::Error.WriteLine('Prunlet update: ' + $warning) } }
                    $received = & $ExecutablePath --config $ConfigPath __download-published-package $sourceInfo.repository $release.commit $release.assetId $release.assetSha256 $release.assetBytes $release.tag
                    if ($LASTEXITCODE -ne 0 -or ($received | ConvertFrom-Json -AsHashtable).status -cne 'downloaded') { throw 'Published package download was not confirmed.' }
                    $prepared = & $ExecutablePath --config $ConfigPath __prepare-published-package $sourceInfo.repository $release.branch $release.commit $sourceInfo.runtime $release.assetSha256 $release.assetBytes $release.assetId
                    if ($LASTEXITCODE -ne 0) { throw 'Published package preparation did not complete.' }
                    $result = $prepared | ConvertFrom-Json -AsHashtable
                    if ($result.ContainsKey('warnings')) { foreach ($warning in $result.warnings) { [Console]::Error.WriteLine('Prunlet update: ' + $warning) } }
                    if ($result.status -ceq 'prepared') {
                        $result = Invoke-UpdateCoordinator $stage $ConfigPath $CodexHome $ExecutablePath
                        if ($result.status -notin @('updated', 'cleanup_pending', 'deferred')) { throw 'Prunlet startup update returned an unknown state.' }
                        $state = Read-StartupState $statePath
                        if ($state.phase -cne 'idle') { throw 'Prunlet startup update has not finished.' }
                    } elseif ($result.status -cne 'current') { throw 'Prunlet startup preparation returned an unknown state.' }
                }
            }
        } catch {
            $state = Read-StartupState $statePath
            if ($state.phase -cne 'idle') { throw }
            [Console]::Error.WriteLine('Prunlet startup update was deferred: ' + $_.Exception.Message)
        } finally {
            if ($acquired) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
    $env:PRUNLET_MCP_LAUNCHER_JOB = $script:PrunletMcpJobName
    & $ExecutablePath --config $ConfigPath mcp
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine('Prunlet MCP could not start safely: ' + $_.Exception.Message)
    exit 1
}
