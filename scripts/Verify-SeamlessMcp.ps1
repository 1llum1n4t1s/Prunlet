#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    # 正規Publishした、同じproxy/backend ABIを持つ隔離検証用の世代A。
    [Parameter(Mandatory)][string]$PriorPackagePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$LauncherPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'integration/start-prunlet-mcp.ps1'),
    [ValidateRange(5, 120)][int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
$cases = [Collections.Generic.List[object]]::new()
$raw = [Collections.Generic.List[object]]::new()
$sessions = [Collections.Generic.List[object]]::new()
$retainedTerminalWorkers = [Collections.Generic.List[object]]::new()
$protocolEvidence = [Collections.Generic.List[object]]::new()
$started = [DateTimeOffset]::UtcNow
$expectedCaseCount = 16
$driverShaAtStart = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
$fatal = $null
$reportDestinationValidated = $false

function Assert-S([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Assert-PlainS([string]$Path) {
    Assert-S ([IO.Path]::IsPathFullyQualified($Path)) "Absolute path required: $Path"
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            Assert-S (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Reparse path refused: $current"
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}
function Hash-S([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function New-CleanupGateS([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Flush($true) } finally { $stream.Dispose() }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetSecurityDescriptorSddlForm("O:${sid}D:P(A;;FA;;;${sid})(A;;FA;;;SY)", [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Access)
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($Path), $acl)
}
function Tree-BytesS([string]$Root) {
    Assert-PlainS $Root
    $entries = @(
        Get-ChildItem -LiteralPath $Root -Force -Recurse | Sort-Object FullName | ForEach-Object {
            Assert-S (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Unexpected link in owned generation snapshot.'
            $relative = [IO.Path]::GetRelativePath($Root, $_.FullName)
            if ($_.PSIsContainer) { [ordered]@{ path = $relative; kind = 'directory' } }
            else { [ordered]@{ path = $relative; kind = 'file'; bytes = $_.Length; sha256 = Hash-S $_.FullName } }
        }
    )
    return ConvertTo-Json -InputObject $entries -Depth 5 -Compress
}
function Write-JsonS([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 50), $utf8) }
function Start-S([string]$Exe, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($Exe)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardInputEncoding = $utf8
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    $info.Environment['TEMP'] = Join-Path $OutputDirectory 'temp'
    $info.Environment['TMP'] = Join-Path $OutputDirectory 'temp'
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    $session = @{ process = $process; stderr = $process.StandardError.ReadToEndAsync(); executable = $Exe; arguments = $Arguments }
    $sessions.Add($session)
    return $session
}
function Invoke-S([string]$Exe, [string[]]$Arguments) {
    $session = Start-S $Exe $Arguments
    $stdout = $session.process.StandardOutput.ReadToEndAsync()
    $session.process.StandardInput.Close()
    Assert-S ($session.process.WaitForExit($TimeoutSeconds * 1000)) 'CLI deadline exceeded; fixture retained.'
    Assert-S ($stdout.Wait(1000) -and $session.stderr.Wait(1000)) 'CLI output did not close.'
    $result = @{ exitCode = $session.process.ExitCode; stdout = $stdout.Result; stderr = $session.stderr.Result }
    $raw.Add(@{ transport = 'cli'; executable = $Exe; arguments = $Arguments; result = $result })
    return $result
}
function Prepare-S($Fixture) {
    $response = Invoke-S $ExecutablePath @('--config', $Fixture.config, '__prepare-mcp-proxy')
    Assert-S ($response.exitCode -eq 0) "Prepare failed: stdout=$($response.stdout); stderr=$($response.stderr)"
    $prepared = $response.stdout | ConvertFrom-Json -AsHashtable
    Assert-S ($prepared.protocol -eq 1 -and $prepared.status -ceq 'prepared') 'Invalid prepare result.'
    Assert-S ((Hash-S $prepared.executablePath) -eq $Fixture.candidateHash) 'Prepared host hash mismatch.'
    return $prepared
}
function Send-S($Session, [int]$Id, [string]$Method, $Parameters) {
    $request = @{ jsonrpc = '2.0'; id = $Id; method = $Method; params = $Parameters }
    $raw.Add(@{ transport = 'stdio'; direction = 'request'; proxyPid = $Session.process.Id; message = $request })
    $Session.process.StandardInput.WriteLine(($request | ConvertTo-Json -Compress -Depth 30))
    $Session.process.StandardInput.Flush()
}
function Read-S($Session, [int]$Id, $FirstRead = $null) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $read = if ($null -ne $FirstRead) { $FirstRead } else { $Session.process.StandardOutput.ReadLineAsync() }
        $FirstRead = $null
        Assert-S ($read.Wait([Math]::Max(1, [int]($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds))) 'MCP deadline exceeded; request must not be resent.'
        $line = $read.GetAwaiter().GetResult()
        Assert-S ($null -ne $line) 'MCP stdout ended before response.'
        $response = $line | ConvertFrom-Json -AsHashtable -Depth 50
        $raw.Add(@{ transport = 'stdio'; direction = 'response'; proxyPid = $Session.process.Id; message = $response })
        if ($response.ContainsKey('id') -and $response.id -eq $Id) {
            Assert-S (!$response.ContainsKey('error')) "MCP protocol error: $line"
            if ($response.result -is [Collections.IDictionary]) {
                Assert-S (!$response.result.ContainsKey('isError') -or !$response.result.isError) "MCP tool failure: $line"
            }
            return $response.result
        }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'MCP response deadline exceeded.'
}
function Call-S($Session, [int]$Id, [string]$Method, $Parameters) { Send-S $Session $Id $Method $Parameters; return Read-S $Session $Id }
function Child-S($Session, [string]$ExpectedHash) {
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Session.process.Id)")
    $raw.Add(@{
        transport = 'process-snapshot'; proxyPid = $Session.process.Id
        children = @($children | ForEach-Object { @{ processId = [int]$_.ProcessId; name = $_.Name; path = $_.ExecutablePath; commandLine = $_.CommandLine } })
    })
    $backends = @($children | Where-Object { $_.Name -ieq 'prunlet.exe' -and $_.CommandLine -match '(?:^|\s)"?mcp"?\s*$' })
    Assert-S ($backends.Count -eq 1) "Expected exactly one persistent MCP backend, found $($backends.Count) among $($children.Count) direct children."
    $child = $backends[0]
    Assert-S ($child.ExecutablePath.StartsWith($OutputDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) 'Child escaped the fixture.'
    $hash = Hash-S $child.ExecutablePath
    Assert-S ($hash -eq $ExpectedHash) 'Backend generation hash mismatch.'
    return @{ processId = [int]$child.ProcessId; path = $child.ExecutablePath; sha256 = $hash; creationDate = $child.CreationDate.ToString('o') }
}
function Case-S([string]$Name, [scriptblock]$Body) {
    $case = [ordered]@{ name = $Name; passed = $false; observed = @{}; error = $null }
    $cases.Add($case)
    try { & $Body $case; $case.passed = $true } catch { $case.error = $_.Exception.Message }
}
function Retained-TerminalS($Fixture, $Job, $Worker, $State, [string]$ExpectedStatus) {
    Assert-S ($State.jobId -ceq $Job.jobId -and $State.status -ceq $ExpectedStatus) 'Queue terminal state changed on read-only recheck.'
    Assert-S ($State.workerProcessId -eq $Job.workerProcessId -and !$Worker.HasExited) 'Terminal result is not served by the original retained worker.'
    Assert-S ($State.retentionSeconds -eq 3600 -and $null -ne $State.expiresUtc) 'Queue terminal result omitted its one-hour retention contract.'
    $expiry = [DateTimeOffset]$State.expiresUtc
    Assert-S ($expiry -gt [DateTimeOffset]::UtcNow -and $expiry -le [DateTimeOffset]::UtcNow.AddSeconds(3605)) 'Queue terminal retention expiry is outside its expected future window.'
    $retained = @{
        jobId = $Job.jobId; workerProcessId = $Job.workerProcessId; installationRoot = $Fixture.root
        configPath = $Fixture.config; status = $State.status; retentionSeconds = $State.retentionSeconds; expiresUtc = $State.expiresUtc
        reason = 'Product retains terminal queue results for one hour. Worker is left alive; no kill or shortened retention seam is used.'
    }
    $retainedTerminalWorkers.Add($retained)
    return $retained
}
function New-FixtureS([string]$Name) {
    $root = Join-Path $OutputDirectory $Name
    $null = [IO.Directory]::CreateDirectory((Join-Path $root 'bin'))
    foreach ($entry in $package.files.Keys) {
        Copy-Item -LiteralPath (Join-Path $packageRoot $entry) -Destination (Join-Path $root $entry)
    }
    $fixture = @{ root = $root; config = Join-Path $root 'config.json'; candidateHash = $candidateHash }
    $backup = Join-Path $root 'backup'
    $null = [IO.Directory]::CreateDirectory($backup)
    $init = Invoke-S $ExecutablePath @('--config', $fixture.config, 'init', '--backup-directory', $backup)
    Assert-S ($init.exitCode -eq 0) "Fixture init failed: stdout=$($init.stdout); stderr=$($init.stderr)"
    Set-GenerationS $fixture $true
    $migration = Invoke-S $ExecutablePath @('--config', $fixture.config, 'migrate', '--apply', '--if-needed')
    Assert-S ($migration.exitCode -eq 0) "Empty fixture migration failed: stdout=$($migration.stdout); stderr=$($migration.stderr)"
    return $fixture
}
function Set-GenerationS($Fixture, [bool]$Candidate) {
    $source = if ($Candidate) { $ExecutablePath } else { Join-Path $packageRoot 'bin/prunlet.exe' }
    Copy-Item -LiteralPath $source -Destination (Join-Path $Fixture.root 'bin/prunlet.exe') -Force
    Copy-Item -LiteralPath $source -Destination (Join-Path $Fixture.root 'bin/prunlet-hook.exe') -Force
    $cliHash = Hash-S $source
    $auxiliary = [ordered]@{}
    foreach ($entry in $package.files.Keys) {
        if (!$entry.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { $auxiliary[$entry.Replace('/', '\')] = $package.files[$entry].sha256 }
    }
    $provenance = [ordered]@{
        repository = $package.repository; defaultBranch = $package.defaultBranch; commitSha = $package.commitSha
        runtime = $package.runtime; executableSha256 = $cliHash; hookExecutableSha256 = $cliHash
        maintenanceExecutableSha256 = $package.files['bin/prunlet-maintenance.exe'].sha256
        auxiliarySha256 = $auxiliary; archiveSha256 = $archiveHash; installedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Write-JsonS (Join-Path $Fixture.root 'source-info.json') $provenance
}

try {
    Assert-S $IsWindows 'This verifier requires native Windows.'
    foreach ($path in @($ExecutablePath, $PriorPackagePath, $OutputDirectory, $ReportPath, $LauncherPath)) { Assert-PlainS $path }
    $ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
    $PriorPackagePath = [IO.Path]::GetFullPath($PriorPackagePath)
    $OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
    $ReportPath = [IO.Path]::GetFullPath($ReportPath)
    $LauncherPath = [IO.Path]::GetFullPath($LauncherPath)
    Assert-S (Test-Path -LiteralPath $LauncherPath -PathType Leaf) 'LauncherPath must be an existing launcher script.'
    Assert-S ($OutputDirectory -match '^D:\\' -and $ReportPath -match '^D:\\') 'Fixture and report require external D: paths.'
    $repository = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
    foreach ($path in @($OutputDirectory, $ReportPath)) {
        Assert-S (!$path.StartsWith($repository + '\', [StringComparison]::OrdinalIgnoreCase)) 'Repository output refused.'
        Assert-S (!$path.StartsWith('D:\Dev\Secret\', [StringComparison]::OrdinalIgnoreCase)) 'Secret directory refused.'
    }
    Assert-S (!(Test-Path -LiteralPath $OutputDirectory)) 'OutputDirectory must be unused.'
    Assert-S (!(Test-Path -LiteralPath $ReportPath)) 'ReportPath must be unused.'
    Assert-S (Test-Path -LiteralPath (Split-Path -Parent $OutputDirectory) -PathType Container) 'Output parent must exist.'
    Assert-S (Test-Path -LiteralPath (Split-Path -Parent $ReportPath) -PathType Container) 'Report parent must exist.'
    $reportDestinationValidated = $true
    $null = [IO.Directory]::CreateDirectory($OutputDirectory)
    $null = [IO.Directory]::CreateDirectory((Join-Path $OutputDirectory 'temp'))
    $candidateHash = Hash-S $ExecutablePath
    $archiveHash = Hash-S $PriorPackagePath
    $packageRoot = Join-Path $OutputDirectory 'prior-package'
    $null = [IO.Directory]::CreateDirectory($packageRoot)
    $zip = [IO.Compression.ZipFile]::OpenRead($PriorPackagePath)
    try {
        $metadata = @($zip.Entries | Where-Object FullName -CEQ 'package.json')
        Assert-S ($metadata.Count -eq 1) 'Package metadata missing or duplicated.'
        $reader = [IO.StreamReader]::new($metadata[0].Open(), $utf8)
        try { $package = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable -Depth 20 } finally { $reader.Dispose() }
        Assert-S ($package.product -ceq 'Prunlet' -and $package.schema -eq 1 -and $package.runtime -ceq 'win-x64') 'Expected a normally packaged win-x64 Rust generation A.'
        Assert-S ($package.files.Count -eq 12 -and $zip.Entries.Count -eq 13) 'Unexpected package member count.'
        foreach ($name in $package.files.Keys) {
            Assert-S ($name -cmatch '^bin/[A-Za-z0-9._-]+$') "Unsafe archive entry: $name"
            $entries = @($zip.Entries | Where-Object FullName -CEQ $name)
            Assert-S ($entries.Count -eq 1) "Package entry missing or duplicated: $name"
            $target = Join-Path $packageRoot $name
            $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $target, $false)
            Assert-S ((Hash-S $target) -eq $package.files[$name].sha256 -and (Get-Item -LiteralPath $target).Length -eq $package.files[$name].bytes) "Package content mismatch: $name"
        }
    } finally { $zip.Dispose() }
    $oldHash = Hash-S (Join-Path $packageRoot 'bin/prunlet.exe')
    Assert-S ($oldHash -ne $candidateHash) 'Prior and candidate executables must differ.'
    foreach ($generation in @(@{ name = 'A'; path = Join-Path $packageRoot 'bin/prunlet.exe' }, @{ name = 'B'; path = $ExecutablePath })) {
        $probe = Invoke-S $generation.path @('--startup-update-protocol')
        Assert-S ($probe.exitCode -eq 0) "Generation $($generation.name) protocol inspection failed: stdout=$($probe.stdout); stderr=$($probe.stderr)"
        $protocol = $probe.stdout | ConvertFrom-Json -AsHashtable
        Assert-S ($protocol.ContainsKey('mcpProxy') -and $protocol.mcpProxy -eq 2 -and $protocol.ContainsKey('mcpBackendLease') -and $protocol.mcpBackendLease -eq 1) "Generation $($generation.name) requires mcpProxy 2 and mcpBackendLease 1; public legacy packages are not compatible with this full driver."
        $protocolEvidence.Add(@{ generation = $generation.name; executablePath = $generation.path; sha256 = Hash-S $generation.path; protocol = $protocol })
    }
    $fixture = New-FixtureS 'handover'
    $prepared = Prepare-S $fixture
    Set-GenerationS $fixture $false
    $proxy = Start-S $prepared.executablePath @('--config', $fixture.config, '__mcp-proxy')
    Case-S 'same-stdio-generation-A-to-B' {
        param($case)
        $proxyId = $proxy.process.Id
        $null = Call-S $proxy 1 'initialize' @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'seamless-verifier'; version = '1' } }
        $proxy.process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
        $proxy.process.StandardInput.Flush()
        $toolsA = Call-S $proxy 2 'tools/list' @{}
        Assert-S (@($toolsA.tools | Where-Object name -CEQ 'list_operations').Count -eq 1) 'Prior backend omitted list_operations.'
        $null = Call-S $proxy 3 'tools/call' @{ name = 'list_operations'; arguments = @{} }
        $old = Child-S $proxy $oldHash
        $oldProcess = [Diagnostics.Process]::GetProcessById($old.processId)
        try {
            $write = [IO.FileStream]::new((Join-Path $fixture.root 'bin/prunlet.exe'), [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            $write.Dispose()
            Set-GenerationS $fixture $true
            $null = Call-S $proxy 4 'tools/list' @{}
            $null = Call-S $proxy 5 'tools/call' @{ name = 'list_operations'; arguments = @{} }
            $new = Child-S $proxy $candidateHash
            Assert-S ($new.processId -ne $old.processId) 'Backend PID did not change.'
            Assert-S ($oldProcess.WaitForExit($TimeoutSeconds * 1000)) 'Prior backend did not exit after stdin EOF.'
            Assert-S (!$proxy.process.HasExited -and $proxy.process.Id -eq $proxyId) 'Proxy connection was replaced.'
            $case.observed = @{ proxyPid = $proxyId; prior = $old; candidate = $new; canonicalWritableWhileIdle = $true; priorExited = $true }
        } finally { $oldProcess.Dispose() }
    }
    foreach ($scope in @('Global', 'Local')) {
        Case-S "$scope-installation-mutex-defers-request" {
            param($case)
            $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($fixture.root.ToLowerInvariant())))
            $mutex = [Threading.Mutex]::new($false, "$scope\Prunlet-Install-$key")
            $held = $false
            try {
                $held = $mutex.WaitOne(0)
                Assert-S $held 'Could not own fixture installation mutex.'
                $before = Child-S $proxy $candidateHash
                $id = if ($scope -ceq 'Global') { 6 } else { 7 }
                Send-S $proxy $id 'tools/list' @{}
                $read = $proxy.process.StandardOutput.ReadLineAsync()
                Assert-S (!$read.Wait(1200)) 'Request responded while installation mutex was held.'
                $during = Child-S $proxy $candidateHash
                Assert-S ($during.processId -eq $before.processId) 'Backend changed during installation lock.'
                $mutex.ReleaseMutex(); $held = $false
                $null = Read-S $proxy $id $read
                $case.observed = @{ mutex = "$scope\Prunlet-Install-$key"; noResponseWhileHeld = $true; continuedAfterRelease = $true }
            } finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
        }
    }
    $proxy.process.StandardInput.Close()
    Assert-S ($proxy.process.WaitForExit($TimeoutSeconds * 1000)) 'Proxy did not exit after client EOF.'
    Case-S 'pending-queue-survives-generation-handover-and-cancels' {
        param($case)
        $queueFixture = New-FixtureS 'queue-handover'
        $queueHost = Prepare-S $queueFixture
        Set-GenerationS $queueFixture $false
        $queueProxy = Start-S $queueHost.executablePath @('--config', $queueFixture.config, '__mcp-proxy')
        $target = Join-Path $queueFixture.root 'locked-child.txt'
        [IO.File]::WriteAllText($target, 'owned queue handover fixture', $utf8)
        $releaseName = 'Local\Prunlet-Seamless-Test-' + [guid]::NewGuid().ToString('N')
        $release = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $releaseName)
        $pathBytes = [Convert]::ToBase64String($utf8.GetBytes($target))
        # cancelが失敗した場合も、holderを存続させてfixtureの削除を防ぐ。
        $holderCode = @"
`$ErrorActionPreference='Stop'
`$path=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$pathBytes'))
`$event=[Threading.EventWaitHandle]::OpenExisting('$releaseName')
`$lock=[IO.FileStream]::new(`$path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try { [Console]::Out.WriteLine('READY'); [Console]::Out.Flush(); `$null=`$event.WaitOne() } finally { `$lock.Dispose(); `$event.Dispose() }
"@
        $holder = Start-S (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($holderCode)))
        $null = $sessions.Remove($holder)
        $cancelled = $false
        $worker = $null
        $case.observed.holderPid = $holder.process.Id
        $case.observed.holderReleaseEvent = $releaseName
        $case.observed.target = $target
        try {
            $ready = $holder.process.StandardOutput.ReadLineAsync()
            Assert-S ($ready.Wait($TimeoutSeconds * 1000) -and $ready.Result -ceq 'READY') 'Queue fixture holder did not become ready.'
            $null = Call-S $queueProxy 101 'initialize' @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'seamless-queue-verifier'; version = '1' } }
            $queueProxy.process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
            $queueProxy.process.StandardInput.Flush()
            $accepted = Call-S $queueProxy 102 'tools/call' @{ name = 'delete_files'; arguments = @{ action = 'enqueue'; paths = @($target) } }
            $job = $accepted.structuredContent
            $case.observed.accepted = $job
            Assert-S ($job.status -ceq 'pending' -and $job.workerProcessId -gt 0) 'Old generation did not accept a pending queue job.'
            $worker = [Diagnostics.Process]::GetProcessById([int]$job.workerProcessId)
            $old = Child-S $queueProxy $oldHash
            $case.observed.prior = $old
            Set-GenerationS $queueFixture $true
            $state = Call-S $queueProxy 103 'tools/call' @{ name = 'delete_files'; arguments = @{ action = 'status'; jobId = $job.jobId } }
            $case.observed.candidate = Child-S $queueProxy $candidateHash
            Assert-S ($state.structuredContent.jobId -ceq $job.jobId -and $state.structuredContent.status -ceq 'pending') 'New generation could not read the pending old job.'
            Assert-S (!$worker.HasExited -and $state.structuredContent.workerProcessId -eq $job.workerProcessId) 'Generation handover stopped or replaced the queue worker.'
            $response = Call-S $queueProxy 104 'tools/call' @{ name = 'delete_files'; arguments = @{ action = 'cancel'; jobId = $job.jobId } }
            Assert-S ($response.structuredContent.status -ceq 'cancelled') 'New generation could not cancel the old job.'
            $cancelled = $true
            $case.observed.cancelled = $response.structuredContent
            $null = $release.Set()
            Assert-S ($holder.process.WaitForExit($TimeoutSeconds * 1000)) 'Fixture holder did not release.'
            Assert-S ([IO.File]::ReadAllText($target) -ceq 'owned queue handover fixture') 'Cancelled fixture content changed.'
            $queueProxy.process.StandardInput.Close()
            Assert-S ($queueProxy.process.WaitForExit($TimeoutSeconds * 1000)) 'Queue proxy did not close after EOF.'
            $recheck = Invoke-S (Join-Path $queueFixture.root 'bin/prunlet.exe') @('--config', $queueFixture.config, 'delete-queue-status', $job.jobId)
            Assert-S ($recheck.exitCode -eq 0) 'CLI could not recheck the retained cancelled queue result.'
            $terminal = $recheck.stdout | ConvertFrom-Json -AsHashtable -Depth 30
            $case.observed.retainedTerminalWorker = Retained-TerminalS $queueFixture $job $worker $terminal 'cancelled'
            $case.observed.holderExitedNormally = $true
        } finally {
            if ($cancelled) { $null = $release.Set() }
            else { $case.observed.retainedHolderReason = 'Cancel not confirmed. Keep holder alive; cancel the recorded job before releasing its event or stopping holder.' }
            if ($worker) { $worker.Dispose() }
            $release.Dispose()
            $holder.process.Dispose()
        }
    }
    Case-S 'real-managed-wrapper-eof-preserves-queue-worker' {
        param($case)
        $managed = New-FixtureS 'managed-wrapper-queue'
        $installedExe = Join-Path $managed.root 'bin/prunlet.exe'
        $codex = Join-Path $managed.root 'fixture-codex-home'
        $null = [IO.Directory]::CreateDirectory($codex)
        $installedLauncher = Join-Path $managed.root 'bin/start-prunlet-mcp.ps1'
        Copy-Item -LiteralPath $LauncherPath -Destination $installedLauncher -Force
        $infoPath = Join-Path $managed.root 'source-info.json'
        $info = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json -AsHashtable
        $info.auxiliarySha256['bin\start-prunlet-mcp.ps1'] = Hash-S $installedLauncher
        Write-JsonS $infoPath $info
        $transportPath = Join-Path $managed.root 'transport.json'
        $transportCalls = Join-Path $managed.root 'transport-calls.jsonl'
        Write-JsonS $transportPath @{
            repository = $package.repository; branch = $package.defaultBranch; commit = $package.commitSha.ToLowerInvariant()
            hash = $archiveHash.ToLowerInvariant(); bytes = (Get-Item -LiteralPath $PriorPackagePath).Length
        }
        $bootstrap = Join-Path $managed.root 'launcher-fixture.ps1'
        # HTTP metadataだけを固定する。managed proxy準備、起動、EOF処理は実launcherへ任せる。
        [IO.File]::WriteAllText($bootstrap, @'
param([string]$Launcher,[string]$Transport,[string]$Calls,[string]$Executable,[string]$Config,[string]$Codex)
$ErrorActionPreference='Stop'
$fixture=Get-Content -LiteralPath $Transport -Raw|ConvertFrom-Json -AsHashtable
function Invoke-RestMethod {
    param($Uri,$Headers,$TimeoutSec)
    [IO.File]::AppendAllText($Calls, ((@{uri=[string]$Uri}|ConvertTo-Json -Compress)+[Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    $base='https://api.github.com/repos/'+$fixture.repository
    switch -Regex ([string]$Uri) {
        ('^'+[regex]::Escape($base)+'$') {return @{default_branch=$fixture.branch}}
        ('^'+[regex]::Escape($base+'/releases/latest')+'$') {return @{tag_name='fixture-current';draft=$false;prerelease=$false;assets=@(@{name='prunlet-update-win-x64.zip';state='uploaded';digest=('sha256:'+$fixture.hash);size=$fixture.bytes;id=1})}}
        ('^'+[regex]::Escape($base+'/git/ref/tags/fixture-current')+'$') {return @{object=@{sha=$fixture.commit;type='commit'}}}
        ('^'+[regex]::Escape($base+'/compare/')+'.*') {return @{status='identical'}}
        default {throw "Unexpected fixture API request: $Uri"}
    }
}
& $Launcher -ExecutablePath $Executable -ConfigPath $Config -CodexHome $Codex
exit $LASTEXITCODE
'@, $utf8)
        $target = Join-Path $managed.root 'wrapper-locked-child.txt'
        [IO.File]::WriteAllText($target, 'owned wrapper EOF queue fixture', $utf8)
        $releaseName = 'Local\Prunlet-Seamless-Wrapper-Test-' + [guid]::NewGuid().ToString('N')
        $release = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $releaseName)
        $pathBytes = [Convert]::ToBase64String($utf8.GetBytes($target))
        $holderCode = @"
`$ErrorActionPreference='Stop'
`$path=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$pathBytes'))
`$event=[Threading.EventWaitHandle]::OpenExisting('$releaseName')
`$lock=[IO.FileStream]::new(`$path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try { [Console]::Out.WriteLine('READY'); [Console]::Out.Flush(); `$null=`$event.WaitOne() } finally { `$lock.Dispose(); `$event.Dispose() }
"@
        $holder = Start-S (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($holderCode)))
        $null = $sessions.Remove($holder)
        $worker = $null
        $lockReleased = $false
        $case.observed = @{
            holderPid = $holder.process.Id; holderReleaseEvent = $releaseName; target = $target
            launcherPath = $LauncherPath; launcherSha256 = Hash-S $LauncherPath
            managedRoot = $managed.root; transportCallsPath = $transportCalls
            transportFixture = 'Read-only GitHub metadata returns the installed commit. Actual managed launcher/proxy/worker lifetime code is unchanged.'
        }
        try {
            $ready = $holder.process.StandardOutput.ReadLineAsync()
            Assert-S ($ready.Wait($TimeoutSeconds * 1000) -and $ready.Result -ceq 'READY') 'Wrapper queue holder did not become ready.'
            $wrapper = Start-S (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile', '-File', $bootstrap, '-Launcher', $LauncherPath, '-Transport', $transportPath, '-Calls', $transportCalls, '-Executable', $installedExe, '-Config', $managed.config, '-Codex', $codex)
            $case.observed.wrapperPid = $wrapper.process.Id
            $null = Call-S $wrapper 201 'initialize' @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'seamless-wrapper-queue-verifier'; version = '1' } }
            $wrapper.process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
            $wrapper.process.StandardInput.Flush()
            $accepted = Call-S $wrapper 202 'tools/call' @{ name = 'delete_files'; arguments = @{ action = 'enqueue'; paths = @($target) } }
            $job = $accepted.structuredContent
            $case.observed.accepted = $job
            Assert-S ($job.status -ceq 'pending' -and $job.workerProcessId -gt 0) 'Wrapper did not accept a pending queue job.'
            $worker = [Diagnostics.Process]::GetProcessById([int]$job.workerProcessId)
            $proxyChildren = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($wrapper.process.Id)" | Where-Object { $_.CommandLine -match '__mcp-proxy' })
            Assert-S ($proxyChildren.Count -eq 1) 'Managed launcher did not start the generation proxy.'
            Assert-S ($proxyChildren[0].ExecutablePath.StartsWith((Join-Path $managed.root '.prunlet-mcp-generations') + '\', [StringComparison]::OrdinalIgnoreCase)) 'Wrapper proxy escaped managed generation cache.'
            Assert-S ((Hash-S $proxyChildren[0].ExecutablePath) -eq $candidateHash) 'Wrapper proxy product hash mismatch.'
            $case.observed.proxy = @{ processId = [int]$proxyChildren[0].ProcessId; path = $proxyChildren[0].ExecutablePath; sha256 = Hash-S $proxyChildren[0].ExecutablePath }
            $wrapper.process.StandardInput.Close()
            Assert-S ($wrapper.process.WaitForExit($TimeoutSeconds * 1000)) 'Real wrapper did not exit after client EOF.'
            Assert-S ($wrapper.process.ExitCode -eq 0) 'Real wrapper exited unsuccessfully.'
            Assert-S (!$worker.HasExited) 'Real wrapper EOF terminated the independent queue worker.'
            Assert-S ($wrapper.stderr.Wait(1000)) 'Wrapper stderr did not close.'
            Assert-S ($wrapper.stderr.Result -notmatch 'startup update was deferred') 'Metadata fixture did not complete the managed startup check.'
            Assert-S ((Get-Content -LiteralPath $transportCalls).Count -eq 4) 'Expected four read-only GitHub metadata fixture calls.'
            $case.observed.workerAliveAfterWrapperExit = $true
            $null = $release.Set()
            $lockReleased = $true
            Assert-S ($holder.process.WaitForExit($TimeoutSeconds * 1000)) 'Wrapper fixture holder did not release.'
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
            do {
                $statusResult = Invoke-S $installedExe @('--config', $managed.config, 'delete-queue-status', $job.jobId)
                Assert-S ($statusResult.exitCode -eq 0) 'CLI could not read the wrapper queue job.'
                $state = $statusResult.stdout | ConvertFrom-Json -AsHashtable -Depth 30
                if ($state.status -cnotin @('pending', 'running')) { break }
                Start-Sleep -Milliseconds 1000
            } while ([DateTimeOffset]::UtcNow -lt $deadline)
            $case.observed.terminal = $state
            Assert-S ($state.status -ceq 'completed') 'Wrapper queue job did not complete after holder release.'
            $items = @($state.result.items)
            Assert-S ($items.Count -eq 1 -and $items[0].path -ceq $target -and $items[0].status -cin @('recycled', 'permanently_deleted')) 'Queue final result did not confirm the owned fixture deletion.'
            Assert-S (![IO.File]::Exists($target)) 'Completed wrapper queue fixture remains at its source path.'
            $recheck = Invoke-S $installedExe @('--config', $managed.config, 'delete-queue-status', $job.jobId)
            Assert-S ($recheck.exitCode -eq 0) 'CLI could not recheck the retained completed queue result.'
            $terminal = $recheck.stdout | ConvertFrom-Json -AsHashtable -Depth 30
            $case.observed.retainedTerminalWorker = Retained-TerminalS $managed $job $worker $terminal 'completed'
            $case.observed.holderExitedNormally = $true
        } finally {
            if (!$lockReleased) { $case.observed.retainedHolderReason = 'Wrapper EOF/worker survival not confirmed. Keep holder alive and cancel the recorded job before releasing its event or stopping holder.' }
            if ($worker) { $worker.Dispose() }
            $release.Dispose()
            $holder.process.Dispose()
        }
    }
    Case-S 'backend-request-lease-survives-own-proxy-hardkill' {
        param($case)
        $leased = New-FixtureS 'backend-lease-proxy-hardkill'
        $preparedLease = Prepare-S $leased
        $canonical = Join-Path $leased.root 'bin/prunlet.exe'
        $target = Join-Path $leased.root 'owned-hardkill-lease-target.txt'
        [IO.File]::WriteAllText($target, 'owned backend lease hardkill fixture', $utf8)
        $lockPath = Join-Path $leased.root 'backup/maintenance.lock'
        $maintenance = $null
        $backend = $null
        $requestSent = $false
        $case.observed = @{ target = $target; maintenanceLock = $lockPath; installationRoot = $leased.root; clientOutcome = 'request-not-sent'; requestResent = $false }
        try {
            $write = [IO.FileStream]::new($canonical, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            $write.Dispose()
            $maintenance = [IO.FileStream]::new($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $killProxy = Start-S $preparedLease.executablePath @('--config', $leased.config, '__mcp-proxy')
            $case.observed.proxyPid = $killProxy.process.Id
            $null = Call-S $killProxy 301 'initialize' @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'seamless-hardkill-lease-verifier'; version = '1' } }
            $killProxy.process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
            $killProxy.process.StandardInput.Flush()
            $token = 'owned-hardkill-lease-progress'
            Send-S $killProxy 302 'tools/call' @{ name = 'delete_files'; arguments = @{ paths = @($target) }; _meta = @{ progressToken = $token } }
            $requestSent = $true
            $case.observed.clientOutcome = 'unknown-after-send; never resend; inspect original target and OS bin'
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
            $blockedProgress = $false
            do {
                $read = $killProxy.process.StandardOutput.ReadLineAsync()
                Assert-S ($read.Wait([Math]::Max(1, [int]($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds))) 'No bounded recovery-lock progress notification; original request must not be resent.'
                $line = $read.GetAwaiter().GetResult()
                Assert-S ($null -ne $line) 'Proxy stdout ended before recovery-lock progress.'
                $message = $line | ConvertFrom-Json -AsHashtable -Depth 50
                $raw.Add(@{ transport = 'stdio'; direction = 'response'; proxyPid = $killProxy.process.Id; message = $message })
                Assert-S (!$message.ContainsKey('id') -or $message.id -ne 302) 'Delete completed or failed before the required recovery-lock pause.'
                if ($message.ContainsKey('method') -and $message.method -ceq 'notifications/progress' -and $message.params.progressToken -ceq $token -and $message.params.message -match 'Waiting for recovery lock') {
                    $blockedProgress = $true
                    $case.observed.blockedProgress = $message
                    break
                }
            } while ([DateTimeOffset]::UtcNow -lt $deadline)
            Assert-S $blockedProgress 'Required recovery-lock progress was not observed.'
            $child = Child-S $killProxy $candidateHash
            $case.observed.backend = $child
            $backend = [Diagnostics.Process]::GetProcessById($child.processId)
            $null = $backend.Handle
            Assert-S ($killProxy.process.MainModule.FileName.Equals($preparedLease.executablePath, [StringComparison]::OrdinalIgnoreCase)) 'Refusing to kill a proxy outside the owned prepared generation.'
            $killProxy.process.Kill()
            Assert-S ($killProxy.process.WaitForExit($TimeoutSeconds * 1000)) 'Owned proxy did not exit after hardkill.'
            Assert-S (!$backend.HasExited) 'Backend exited while its recovery lock was still held.'
            $sharingError = $null
            $write = $null
            try { $write = [IO.FileStream]::new($canonical, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete) }
            catch { $sharingError = $_.Exception.GetBaseException().HResult -band 0xffff }
            finally { if ($write) { $write.Dispose() } }
            $case.observed.canonicalWriteErrorWhileBackendPending = $sharingError
            Assert-S ($sharingError -in @(32, 33)) 'Pending backend did not retain the canonical product write-denying lease after proxy exit.'
            $maintenance.Dispose(); $maintenance = $null
            Assert-S ($backend.WaitForExit($TimeoutSeconds * 1000)) 'Backend did not finish naturally after recovery-lock release.'
            $write = [IO.FileStream]::new($canonical, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            $write.Dispose()
            Assert-S (![IO.File]::Exists($target)) 'Owned target remains after backend completion.'
            $case.observed.backendExitedNaturally = $true
            $case.observed.canonicalWritableAfterBackendExit = $true
            $case.observed.targetAbsentAfterBackendExit = $true
            $case.observed.resultScope = 'Client result unavailable after disconnect. Poststate confirms absence and lease lifetime; recycled/permanently_deleted DTO was not received.'
        } finally {
            if ($maintenance) { $maintenance.Dispose() }
            if ($backend) {
                if (!$backend.HasExited) { $case.observed.backendExitedDuringFinalDrain = $backend.WaitForExit($TimeoutSeconds * 1000) }
                if (!$backend.HasExited) { $case.observed.retainedBackendReason = 'Original request remains unconfirmed. Backend is not killed; inspect recorded target/OS bin without automatic resend.' }
                $backend.Dispose()
            }
            $case.observed.requestSent = $requestSent
        }
    }
    $cacheFixture = New-FixtureS 'unused-generation-maintenance'
    Case-S 'owned-unused-generation-maintenance' {
        param($case)
        $cacheHost = Prepare-S $cacheFixture
        Set-GenerationS $cacheFixture $false
        $cacheProxy = Start-S $cacheHost.executablePath @('--config', $cacheFixture.config, '__mcp-proxy')
        $oldBackend = $null
        $newBackend = $null
        try {
            $null = Call-S $cacheProxy 401 'initialize' @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'seamless-cache-maintenance-verifier'; version = '1' } }
            $cacheProxy.process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
            $cacheProxy.process.StandardInput.Flush()
            $null = Call-S $cacheProxy 402 'tools/list' @{}
            $oldChild = Child-S $cacheProxy $oldHash
            $oldBackend = [Diagnostics.Process]::GetProcessById($oldChild.processId)
            $null = $oldBackend.Handle
            Set-GenerationS $cacheFixture $true
            $null = Call-S $cacheProxy 403 'tools/list' @{}
            $newChild = Child-S $cacheProxy $candidateHash
            $newBackend = [Diagnostics.Process]::GetProcessById($newChild.processId)
            $null = $newBackend.Handle
            Assert-S ($oldBackend.WaitForExit($TimeoutSeconds * 1000)) 'Cache fixture generation A backend did not exit after handover.'
            $cacheProxy.process.StandardInput.Close()
            Assert-S ($cacheProxy.process.WaitForExit($TimeoutSeconds * 1000)) 'Cache fixture proxy did not exit after EOF.'
            Assert-S ($newBackend.WaitForExit($TimeoutSeconds * 1000)) 'Cache fixture generation B backend did not exit after EOF.'
            $cacheRoot = Join-Path $cacheFixture.root '.prunlet-mcp-generations'
            $unused = Join-Path $cacheRoot $oldHash
            $current = Join-Path $cacheRoot $candidateHash
            $before = Tree-BytesS $cacheRoot
            $currentBefore = Tree-BytesS $current
            $cacheOwnerBefore = Hash-S (Join-Path $cacheRoot '.prunlet-mcp-owner.json')
            $canonical = Join-Path $cacheFixture.root 'bin/prunlet.exe'
            $dry = Invoke-S $canonical @('--config', $cacheFixture.config, 'mcp-cache-maintain')
            Assert-S ($dry.exitCode -eq 0) "Cache maintenance dry-run failed: $($dry.stdout); $($dry.stderr)"
            $dryJson = $dry.stdout | ConvertFrom-Json -AsHashtable -Depth 30
            Assert-S ($dryJson.dryRun -eq $true) 'Cache maintenance default was not dry-run.'
            $eligible = @($dryJson.items | Where-Object { $_.path -ieq $unused })
            $retained = @($dryJson.items | Where-Object { $_.path -ieq $current })
            Assert-S ($eligible.Count -eq 1 -and $eligible[0].status -ceq 'would_recycle') 'Unused generation A was not eligible for maintenance.'
            Assert-S ($retained.Count -eq 1 -and $retained[0].status -ceq 'retained' -and $retained[0].reason -ceq 'current generation') 'Current generation B was not explicitly retained.'
            Assert-S ((Tree-BytesS $cacheRoot) -ceq $before) 'Maintenance dry-run changed cache entries or bytes.'
            $applied = Invoke-S $canonical @('--config', $cacheFixture.config, 'mcp-cache-maintain', '--apply')
            Assert-S ($applied.exitCode -eq 0) "Cache maintenance apply failed: $($applied.stdout); $($applied.stderr)"
            $applyJson = $applied.stdout | ConvertFrom-Json -AsHashtable -Depth 30
            Assert-S ($applyJson.dryRun -eq $false) 'Cache apply returned dry-run.'
            $removed = @($applyJson.items | Where-Object { $_.path -ieq $unused })
            Assert-S ($removed.Count -eq 1 -and $removed[0].ContainsKey('result')) 'Cache apply omitted the nested file Core result for generation A.'
            $coreItems = @($removed[0].result.items)
            Assert-S ($coreItems.Count -eq 1 -and $coreItems[0].path -ieq $unused -and $coreItems[0].status -cin @('recycled', 'permanently_deleted')) 'Nested Core result did not confirm the unused generation deletion.'
            Assert-S (![IO.Directory]::Exists($unused)) 'Unused generation A remains after maintenance apply.'
            Assert-S ((Tree-BytesS $current) -ceq $currentBefore -and (Hash-S (Join-Path $cacheRoot '.prunlet-mcp-owner.json')) -eq $cacheOwnerBefore) 'Maintenance changed current generation B or the cache owner marker.'
            $case.observed = @{ installationRoot = $cacheFixture.root; generationA = $oldChild; generationB = $newChild; dryRun = $dryJson; applied = $applyJson; dryRunPreservedAllBytes = $true; currentGenerationPreservedAllBytes = $true }
        } finally {
            if ($oldBackend) { $oldBackend.Dispose() }
            if ($newBackend) { $newBackend.Dispose() }
        }
    }
    Case-S 'cleanup-interruption-gate-blocks-repeat-apply' {
        param($case)
        Set-GenerationS $cacheFixture $false
        try {
            $oldPrepared = Invoke-S (Join-Path $cacheFixture.root 'bin/prunlet.exe') @('--config', $cacheFixture.config, '__prepare-mcp-proxy')
            Assert-S ($oldPrepared.exitCode -eq 0) 'Failed to create the owned unused generation for interrupted-cleanup inspection.'
            $oldPreparedJson = $oldPrepared.stdout | ConvertFrom-Json -AsHashtable
            Assert-S ((Hash-S $oldPreparedJson.executablePath) -eq $oldHash) 'Unused generation fixture has the wrong hash.'
        } finally { Set-GenerationS $cacheFixture $true }
        $cacheRoot = Join-Path $cacheFixture.root '.prunlet-mcp-generations'
        $gate = Join-Path $cacheRoot '.prunlet-mcp-cleanup-in-progress'
        $canonical = Join-Path $cacheFixture.root 'bin/prunlet.exe'
        # 削除開始後の中断に残る固定gateを隔離fixtureで再現する。
        New-CleanupGateS $gate
        $before = Tree-BytesS $cacheRoot
        $dry = Invoke-S $canonical @('--config', $cacheFixture.config, 'mcp-cache-maintain')
        Assert-S ($dry.exitCode -eq 0) 'Cleanup gate dry-run inspection failed.'
        $dryJson = $dry.stdout | ConvertFrom-Json -AsHashtable -Depth 30
        Assert-S ($dryJson.cleanupBlocked -eq $true) 'Existing cleanup gate was not reported as blocked.'
        $attempts = @()
        foreach ($attempt in 1..2) {
            $result = Invoke-S $canonical @('--config', $cacheFixture.config, 'mcp-cache-maintain', '--apply')
            Assert-S ($result.exitCode -ne 0) 'Existing cleanup gate permitted apply.'
            Assert-S ((Tree-BytesS $cacheRoot) -ceq $before) 'Blocked cleanup changed or resent the original generation.'
            $attempts += $result
        }
        $combined = Invoke-S $canonical @('--config', $cacheFixture.config, 'mcp-cache-maintain', '--apply', '--ack-interrupted-cleanup')
        Assert-S ($combined.exitCode -ne 0 -and (Tree-BytesS $cacheRoot) -ceq $before) 'Combined ack/apply was not refused without changes.'
        $generationsBefore = @(Get-ChildItem -LiteralPath $cacheRoot -Directory | ForEach-Object { Tree-BytesS $_.FullName }) | ConvertTo-Json -Compress
        $ack = Invoke-S $canonical @('--config', $cacheFixture.config, 'mcp-cache-maintain', '--ack-interrupted-cleanup')
        Assert-S ($ack.exitCode -eq 0 -and ![IO.File]::Exists($gate)) "Explicit cleanup acknowledgement failed: $($ack.stdout); $($ack.stderr)"
        $generationsAfter = @(Get-ChildItem -LiteralPath $cacheRoot -Directory | ForEach-Object { Tree-BytesS $_.FullName }) | ConvertTo-Json -Compress
        Assert-S ($generationsBefore -ceq $generationsAfter) 'Acknowledgement deleted or changed a generation.'
        $case.observed = @{ gate = $gate; dryRun = $dryJson; attempts = $attempts; combinedRefused = $combined; acknowledgement = $ack; generationsPreserved = $true }
    }
    foreach ($invalidGate in @('nonempty', 'ads', 'acl', 'hardlink')) {
        Case-S "cleanup-ack-refuses-$invalidGate-gate" {
            param($case)
            $fixture = New-FixtureS "cleanup-gate-$invalidGate"
            $null = Prepare-S $fixture
            $cache = Join-Path $fixture.root '.prunlet-mcp-generations'
            $gate = Join-Path $cache '.prunlet-mcp-cleanup-in-progress'
            New-CleanupGateS $gate
            if ($invalidGate -ceq 'nonempty') { [IO.File]::WriteAllText($gate, 'unexpected', $utf8) }
            elseif ($invalidGate -ceq 'ads') { [IO.File]::WriteAllText($gate + ':unexpected', 'unexpected', $utf8) }
            elseif ($invalidGate -ceq 'hardlink') { $null = New-Item -ItemType HardLink -Path ($gate + '.alias') -Target $gate }
            else {
                $acl = [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($gate))
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('Everyone', 'Read', 'Allow'))
                [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($gate), $acl)
            }
            $before = Tree-BytesS $cache
            $securityBefore = [Convert]::ToBase64String([IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($gate)).GetSecurityDescriptorBinaryForm())
            $result = Invoke-S (Join-Path $fixture.root 'bin/prunlet.exe') @('--config', $fixture.config, 'mcp-cache-maintain', '--ack-interrupted-cleanup')
            Assert-S ($result.exitCode -ne 0 -and [IO.File]::Exists($gate) -and (Tree-BytesS $cache) -ceq $before) 'Malformed cleanup gate was acknowledged or changed.'
            Assert-S ([Convert]::ToBase64String([IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($gate)).GetSecurityDescriptorBinaryForm()) -ceq $securityBefore) 'Rejected cleanup acknowledgement changed the gate security.'
            if ($invalidGate -ceq 'ads') { Assert-S ([IO.File]::ReadAllText($gate + ':unexpected', $utf8) -ceq 'unexpected') 'Rejected cleanup acknowledgement changed the gate ADS.' }
            $case.observed = @{ gate = $gate; result = $result; malformedGateRetained = $true }
        }
    }
    Case-S 'same-config-and-alternate-config-protect-generations' {
        param($case)
        $canonical = Join-Path $cacheFixture.root 'bin/prunlet.exe'
        $cacheRoot = Join-Path $cacheFixture.root '.prunlet-mcp-generations'
        $generationPath = Join-Path $cacheRoot $candidateHash
        $alternate = Join-Path $cacheFixture.root 'alternate.json'
        Copy-Item -LiteralPath $cacheFixture.config -Destination $alternate
        $before = Tree-BytesS $cacheRoot
        $configBefore = Hash-S $cacheFixture.config
        $alternateBefore = Hash-S $alternate
        $results = [Collections.Generic.List[object]]::new()
        foreach ($configPath in @($cacheFixture.config, $alternate)) {
            $refused = Invoke-S $canonical @('--config', $configPath, 'delete', '--dry-run', '--recursive', '--', $generationPath)
            Assert-S ($refused.exitCode -ne 0) 'Generic delete accepted a managed MCP runtime generation.'
            Assert-S (($refused.stdout + $refused.stderr) -match 'MCP runtime generations are protected') 'Generic delete failed without the required runtime-generation protection reason.'
            Assert-S ((Tree-BytesS $cacheRoot) -ceq $before) 'Refused generic delete changed generation bytes or entries.'
            Assert-S ((Hash-S $cacheFixture.config) -eq $configBefore -and (Hash-S $alternate) -eq $alternateBefore) 'Refused generic delete changed either configuration.'
            $results.Add(@{ configPath = $configPath; result = $refused })
        }
        $case.observed = @{ canonicalExecutable = $canonical; target = $generationPath; refusals = @($results.ToArray()); allCacheBytesPreserved = $true; configsPreserved = $true }
    }
    foreach ($kind in @('shadow', 'owner', 'junction')) {
        Case-S "$kind-refused-without-repair" {
            param($case)
            $isolated = New-FixtureS ('tamper-' + $kind)
            if ($kind -ceq 'junction') {
                $target = Join-Path $isolated.root 'owned-link-target'
                $null = [IO.Directory]::CreateDirectory($target)
                $sentinel = Join-Path $target 'sentinel.txt'
                [IO.File]::WriteAllText($sentinel, 'retained link target', $utf8)
                $link = Join-Path $isolated.root '.prunlet-mcp-generations'
                $null = New-Item -ItemType Junction -Path $link -Target $target
                $before = Hash-S $sentinel
                $result = Invoke-S $ExecutablePath @('--config', $isolated.config, '__prepare-mcp-proxy')
                Assert-S ($result.exitCode -ne 0) 'Generation junction was accepted.'
                Assert-S ((Hash-S $sentinel) -eq $before -and @(Get-ChildItem -LiteralPath $target -Force).Count -eq 1) 'Link target changed.'
                $case.observed = @{ target = $target; sentinelSha256 = $before; preserved = $true }
            } else {
                $hostInfo = Prepare-S $isolated
                $target = if ($kind -ceq 'shadow') { $hostInfo.executablePath } else { Join-Path (Split-Path -Parent $hostInfo.executablePath) '.prunlet-mcp-owner.json' }
                if ($kind -ceq 'shadow') {
                    $stream = [IO.File]::Open($target, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                    try { $stream.Position = $stream.Length - 1; $value = $stream.ReadByte(); $stream.Position--; $stream.WriteByte($value -bxor 1); $stream.Flush($true) } finally { $stream.Dispose() }
                } else { [IO.File]::WriteAllText($target, '{"product":"foreign-owner"}', $utf8) }
                $before = Hash-S $target
                $result = Invoke-S $ExecutablePath @('--config', $isolated.config, '__prepare-mcp-proxy')
                Assert-S ($result.exitCode -ne 0) "Tampered $kind was accepted."
                Assert-S ((Hash-S $target) -eq $before) "Tampered $kind was rewritten."
                $case.observed = @{ path = $target; retainedSha256 = $before; preserved = $true }
            }
        }
    }
} catch { $fatal = $_.Exception.Message }
finally {
    foreach ($session in $sessions) {
        try {
            if (!$session.process.HasExited) {
                $session.process.StandardInput.Close()
                if (!$session.process.WaitForExit(3000)) {
                    # このdriverが起動した直接のプロセスだけを停止し、子やqueue workerはkillしない。
                    $session.process.Kill()
                    $null = $session.process.WaitForExit(3000)
                }
            }
            if ($session.stderr.Wait(1000)) { $raw.Add(@{ transport = 'stderr'; processId = $session.process.Id; text = $session.stderr.Result }) }
        } catch { $raw.Add(@{ cleanupError = $_.Exception.Message }) }
        finally { $session.process.Dispose() }
    }
}
$driverSourceUnchanged = (Hash-S $PSCommandPath) -ceq $driverShaAtStart
$report = [ordered]@{
    startedUtc = $started.ToString('o'); completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    passed = ($null -eq $fatal -and $driverSourceUnchanged -and @($cases | Where-Object { !$_.passed }).Count -eq 0 -and $cases.Count -eq $expectedCaseCount)
    expectedCaseCount = $expectedCaseCount; driverSha256 = $driverShaAtStart; driverSourceUnchanged = $driverSourceUnchanged
    fatalError = $fatal; cases = @($cases.ToArray()); invocations = @($raw.ToArray())
    candidateExecutablePath = $ExecutablePath; priorPackagePath = $PriorPackagePath
    generationProtocols = @($protocolEvidence.ToArray())
    retainedTerminalWorkers = @($retainedTerminalWorkers.ToArray())
    retainedOutputDirectory = $OutputDirectory
    limitations = @(
        'Generation A and B are normal Publish builds of compatible source snapshots. Caller establishes each source/build provenance; this driver verifies distinct executable hashes and mcpProxy 2/mcpBackendLease 1 for both. Neither fixture is claimed to be a published release. No version change or byte patch is used here.',
        'PriorPackagePath denotes compatible generation A, not public Rust release 1.0.30 compatibility. Archive members are checked against package.json, not a release signature.',
        'Generation B fixture provenance uses B CLI/hook with generation A package maintenance and auxiliary products. This tests proxy generation handover, not an installer or full package update.',
        'An unanswered read-only request under the installation mutex proves response deferral; backend execution itself has no test observation seam.',
        'The hardkill case kills only its own proxy after real recovery-lock progress, and never resends the delete. Backend result DTO cannot be recovered from that client connection; absence and write-lease lifetime are checked separately. Backend crash/no-replay and other inflight drain cases remain untested here.',
        'The real managed launcher case fixtures read-only GitHub metadata only; it does not validate a network response or an actual startup update. Its queue fixture, the hardkill target, and one owned unused cache generation are explicitly deleted by the product; other output is retained.',
        'Terminal queue workers are intentionally retained for the product one-hour result retention period. This driver checks terminal state, expiry, worker identity and read-only requery; dedicated queue retention tests cover expiry behavior.',
        'Parallel requests, retention, ACL attack races, and other existing queue EOF contracts remain covered by their dedicated drivers. No general output cleanup or Recycle Bin cleanup is performed.'
    )
}
if ($reportDestinationValidated) {
    Assert-PlainS $ReportPath
    Assert-S (!(Test-Path -LiteralPath $ReportPath)) 'Report destination already exists; refusing overwrite.'
    Write-JsonS $ReportPath $report
}
[ordered]@{ passed = $report.passed; passedCases = @($cases | Where-Object passed).Count; failedCases = @($cases | Where-Object { !$_.passed }).Count; fatalError = $fatal; reportPath = $ReportPath; retainedOutputDirectory = $OutputDirectory } | ConvertTo-Json -Compress
if (!$report.passed) { exit 1 }
