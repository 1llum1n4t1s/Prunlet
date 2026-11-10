[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$LegacyMcpWrapperPath,
    [ValidateRange(10, 300)][int]$CompletionTimeoutSeconds = 60,
    [ValidateRange(2, 30)][int]$AcceptanceTimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'Windows PowerShell 7 is required.' }
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
$repo = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
foreach ($path in @($ExecutablePath, $ConfigPath, $OutputDirectory, $ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'Absolute paths are required.' }
    # CMDの展開が生じるパスは、実行前に拒否する。
    if ($path -match '[%！!"\r\n]') { throw 'Paths must be representable literally in CMD.' }
}
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
foreach ($path in @($ExecutablePath, $ConfigPath)) {
    Assert-VerificationDestination $path @()
    if (![IO.File]::Exists($path)) { throw "Required input missing: $path" }
}
if ($PSBoundParameters.ContainsKey('LegacyMcpWrapperPath')) {
    if (!$LegacyMcpWrapperPath -or ![IO.Path]::IsPathFullyQualified($LegacyMcpWrapperPath)) { throw 'Legacy MCP wrapper path must be absolute.' }
    $LegacyMcpWrapperPath = [IO.Path]::GetFullPath($LegacyMcpWrapperPath)
    Assert-VerificationDestination $LegacyMcpWrapperPath @()
    if (![IO.File]::Exists($LegacyMcpWrapperPath)) { throw 'Legacy MCP wrapper must be a plain file.' }
    $legacyItem = Get-Item -LiteralPath $LegacyMcpWrapperPath -Force
    if ($legacyItem.PSIsContainer -or ($legacyItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Legacy MCP wrapper must be a plain file.' }
}
foreach ($path in @($OutputDirectory, $ReportPath)) {
    Assert-VerificationDestination $path @($repo, (Join-Path $env:USERPROFILE '.codex'))
    if (![IO.Path]::GetPathRoot($path).Equals('D:\', [StringComparison]::OrdinalIgnoreCase) -or
        (Test-Path -LiteralPath $path) -or ![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) {
        throw 'Unused external D: output with an existing parent is required.'
    }
}
if ($ReportPath.StartsWith($OutputDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Report parent must already exist independently of the new output directory.'
}
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$temp = Join-Path $OutputDirectory 'temp'
$metadata = Join-Path $OutputDirectory 'metadata'
$null = [IO.Directory]::CreateDirectory($temp)
$null = [IO.Directory]::CreateDirectory($metadata)
$fixtureConfig = Join-Path $OutputDirectory 'config.json'
$utf8 = [Text.UTF8Encoding]::new($false)
$config = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json -AsHashtable
$config.backupDirectory = $metadata
$config.volumeRecoveryDirectories = @{}
$config.registryScope = 'current'
$config.registrySessionFile = $null
[IO.File]::WriteAllText($fixtureConfig, ($config | ConvertTo-Json -Depth 30), $utf8)
$cases = [Collections.Generic.List[object]]::new()
$invocations = [Collections.Generic.List[object]]::new()
$ownedJobs = [Collections.Generic.List[object]]::new()
$workerExecutables = @{}
$workerCleanup = [Collections.Generic.List[object]]::new()
$started = [DateTimeOffset]::UtcNow
$exeHash = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash

function Assert-Q([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}

function Invoke-Q([string[]]$Arguments, [int]$TimeoutSeconds = 15) {
    foreach ($argument in $Arguments) {
        if ($argument -match '[%！!"\r\n]') { throw 'Unsafe CMD argument.' }
    }
    $quoted = @($ExecutablePath, '--config', $fixtureConfig) + $Arguments |
        ForEach-Object { '"' + $_ + '"' }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $start.Arguments = '/d /v:off /s /c "' + ($quoted -join ' ') + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    $start.Environment['TEMP'] = $temp
    $start.Environment['TMP'] = $temp
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $entry = [ordered]@{ arguments = $Arguments; exitCode = $null; elapsedMs = $null; stdout = ''; stderr = ''; json = $null; timedOut = $false }
    $invocations.Add($entry)
    try {
        Assert-Q ($process.Start()) 'CLI process did not start.'
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
            # 受付の成否が不明なので、同じ削除を再送しない。専用CMD/CLIだけを停止する。
            $entry.timedOut = $true
            $process.Kill($true)
            $process.WaitForExit()
        }
        $entry.elapsedMs = $watch.ElapsedMilliseconds
        $entry.exitCode = $process.ExitCode
        Assert-Q ($stdout.Wait(5000)) 'CLI exited but stdout did not reach EOF; a descendant may have inherited its pipe. Do not resend deletion.'
        Assert-Q ($stderr.Wait(5000)) 'CLI exited but stderr did not reach EOF; a descendant may have inherited its pipe. Do not resend deletion.'
        $entry.stdout = $stdout.GetAwaiter().GetResult()
        $entry.stderr = $stderr.GetAwaiter().GetResult()
        Assert-Q (!$entry.timedOut) 'CLI timed out; deletion outcome unknown. Never resend this request.'
        $entry.json = $entry.stdout | ConvertFrom-Json -AsHashtable -Depth 50
        return $entry
    } finally { $process.Dispose() }
}

function Get-StateQ([string]$JobId) {
    $response = Invoke-Q @('delete-queue-status', $JobId)
    Assert-Q ($response.json.jobId -ceq $JobId) 'Status returned a different job ID.'
    Assert-Q ($response.json.status -cin @('pending', 'running', 'completed', 'failed', 'ambiguous', 'unavailable', 'cancelled')) 'Unknown queue status.'
    return $response
}

function Wait-TerminalQ([string]$JobId) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($CompletionTimeoutSeconds)
    do {
        $response = Get-StateQ $JobId
        if ($response.json.status -cnotin @('pending', 'running')) { return $response }
        Start-Sleep -Milliseconds 1000
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'Queue did not reach a terminal state within the bounded test timeout; do not resend.'
}

function New-FixtureQ([string]$Name) {
    $root = Join-Path $OutputDirectory $Name
    $null = [IO.Directory]::CreateDirectory($root)
    $child = Join-Path $root 'locked.txt'
    $content = 'owned deferred queue fixture: ' + $Name
    [IO.File]::WriteAllText($child, $content, $utf8)
    return @{ root = $root; child = $child; content = $content }
}

function Enqueue-LockedQ($Fixture) {
    $response = Invoke-Q @('delete-queue', '--recursive', '--', $Fixture.root) $AcceptanceTimeoutSeconds
    Assert-Q ($response.exitCode -eq 0) 'Enqueue failed.'
    Assert-Q ($response.json.jobId -cmatch '^[a-f0-9]{32}$') 'Enqueue omitted a valid job ID.'
    $ownedJobs.Add($response.json)
    Assert-Q ($response.json.status -ceq 'pending') 'Locked fixture was not accepted as pending.'
    Assert-Q ($response.elapsedMs -lt ($AcceptanceTimeoutSeconds * 1000)) 'Enqueue waited for deletion instead of accepting promptly.'
    $state = Get-StateQ $response.json.jobId
    Assert-Q ($state.json.status -cin @('pending', 'running')) 'Locked fixture unexpectedly reached a terminal state.'
    Assert-Q ([IO.File]::Exists($Fixture.child)) 'Locked fixture disappeared before release.'
    return $response.json
}

function Run-CaseQ([string]$Name, [scriptblock]$Body) {
    $case = [ordered]@{ name = $Name; passed = $false; observed = @{}; error = $null }
    $cases.Add($case)
    try { & $Body $case; $case.passed = $true }
    catch { $case.error = $_.Exception.Message }
}

function Invoke-McpQ($Session, [int]$Id, [string]$Method, [hashtable]$Parameters) {
    $request = @{ jsonrpc = '2.0'; id = $Id; method = $Method; params = $Parameters }
    $Session.process.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 30 -Compress))
    $Session.process.StandardInput.Flush()
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
    do {
        $read = $Session.process.StandardOutput.ReadLineAsync()
        Assert-Q ($read.Wait([Math]::Max(1, [int]($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds))) 'MCP response timed out; never resend the request.'
        $line = $read.GetAwaiter().GetResult()
        Assert-Q ($null -ne $line) 'MCP exited before responding.'
        $message = $line | ConvertFrom-Json -AsHashtable -Depth 50
        $invocations.Add(@{ transport = 'stdio-mcp'; request = $request; response = $message })
        if ($message.ContainsKey('id') -and $message.id -eq $Id) {
            Assert-Q (!$message.error) 'MCP returned a protocol error.'
            return $message.result
        }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'MCP response deadline exceeded.'
}

function Stop-OwnedWorkerQ($Job) {
    $cleanup = [ordered]@{ jobId = $Job.jobId; workerProcessId = $Job.workerProcessId; status = 'not-stopped'; error = $null }
    $workerCleanup.Add($cleanup)
    $worker = $null
    try {
        Assert-Q ($Job.workerProcessId -gt 0 -and $Job.workerProcessId -ne $PID) 'Invalid owned worker PID.'
        try { $worker = [Diagnostics.Process]::GetProcessById([int]$Job.workerProcessId) }
        catch [ArgumentException] { $cleanup.status = 'already-exited'; return }
        $null = $worker.Handle
        Assert-Q ($worker.StartTime.ToUniversalTime() -ge $started.UtcDateTime.AddSeconds(-1)) 'Worker PID was reused by an older process.'
        $expectedExecutable = if ($workerExecutables.ContainsKey($Job.jobId)) { $workerExecutables[$Job.jobId] } else { $ExecutablePath }
        Assert-Q ($worker.MainModule.FileName.Equals($expectedExecutable, [StringComparison]::OrdinalIgnoreCase)) 'Worker executable changed; retained.'
        $state = Get-StateQ $Job.jobId
        Assert-Q ($state.json.workerProcessId -eq $Job.workerProcessId -and $state.json.status -cne 'unavailable') 'Original job no longer owns this worker PID; retained.'
        $worker.Kill()
        Assert-Q ($worker.WaitForExit(10000)) 'Owned worker did not exit during cleanup.'
        $cleanup.status = 'stopped-owned-worker'
    } catch { $cleanup.error = $_.Exception.Message }
    finally { if ($worker) { $worker.Dispose() } }
}

try {
    Run-CaseQ 'eight-workers-accepted-ninth-refused-without-deletion' {
        param($case)
        $fixtures = [Collections.Generic.List[object]]::new()
        $held = [Collections.Generic.List[IO.FileStream]]::new()
        $jobs = [Collections.Generic.List[object]]::new()
        $cancelled = [Collections.Generic.List[object]]::new()
        try {
            foreach ($index in 1..9) {
                $fixture = New-FixtureQ ('capacity-' + $index)
                $fixtures.Add($fixture)
                $held.Add([IO.FileStream]::new($fixture.child, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
                if ($index -le 8) { $jobs.Add((Enqueue-LockedQ $fixture)) }
            }
            $case.observed.accepted = @($jobs.ToArray())
            $rejected = Invoke-Q @('delete-queue', '--recursive', '--', $fixtures[8].root)
            $case.observed.ninthResponse = $rejected
            # 想定外に受理された場合も、今回のworkerを保全のため停止対象にする。
            if ($rejected.json.jobId -and $rejected.json.workerProcessId -gt 0) {
                $jobs.Add($rejected.json); $ownedJobs.Add($rejected.json)
            }
            Assert-Q ($rejected.exitCode -ne 0 -and $rejected.json.error -match 'maximum 8 workers') 'Ninth queue request was not rejected by the worker limit.'
            foreach ($fixture in $fixtures) { Assert-Q ([IO.File]::ReadAllText($fixture.child) -ceq $fixture.content) 'Worker limit changed an input fixture.' }
            foreach ($job in $jobs) {
                $response = Invoke-Q @('delete-queue-cancel', $job.jobId)
                $cancelled.Add($response.json)
                Assert-Q ($response.exitCode -eq 0 -and $response.json.status -ceq 'cancelled') 'Pending capacity job was not cancelled.'
                $state = Get-StateQ $job.jobId
                Assert-Q ($state.json.status -ceq 'cancelled') 'Cancelled capacity job did not retain its result.'
            }
            $case.observed.cancelled = @($cancelled.ToArray())
        } finally {
            # ロック解除前に今回の専用workerを止め、検証失敗でもfixtureを削除させない。
            foreach ($job in $jobs) { Stop-OwnedWorkerQ $job }
            foreach ($stream in $held) { $stream.Dispose() }
        }
        foreach ($fixture in $fixtures) { Assert-Q ([IO.File]::ReadAllText($fixture.child) -ceq $fixture.content) 'Cancelled capacity fixture changed after release.' }
    }
    Run-CaseQ 'aggregate-snapshot-4097-entries-refused-without-change' {
        param($case)
        $roots = @((Join-Path $OutputDirectory 'entry-limit-a'), (Join-Path $OutputDirectory 'entry-limit-b'))
        $counts = @(2046, 2047)
        $expected = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        $held = [Collections.Generic.List[IO.FileStream]]::new()
        $unexpectedJob = $null
        try {
            foreach ($index in 0..1) {
                $null = [IO.Directory]::CreateDirectory($roots[$index])
                foreach ($number in 1..$counts[$index]) {
                    $file = Join-Path $roots[$index] ('child-' + $number.ToString('D4') + '.txt')
                    $content = 'entry-limit fixture ' + $index + ':' + $number
                    [IO.File]::WriteAllText($file, $content, $utf8)
                    $expected.Add($file, $content)
                }
                $held.Add([IO.FileStream]::new((Join-Path $roots[$index] 'child-0001.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
            }
            $case.observed.snapshotEntryCounts = @(2048, 2049)
            $case.observed.aggregateEntries = 4097
            $response = Invoke-Q (@('delete-queue', '--recursive', '--') + $roots) 120
            $case.observed.response = $response
            if ($response.json.jobId -and $response.json.workerProcessId -gt 0) {
                $unexpectedJob = $response.json; $ownedJobs.Add($unexpectedJob)
            }
            Assert-Q ($response.exitCode -ne 0 -and $response.json.error -match 'total limit of 4096') 'Aggregate 4097-entry snapshot was not rejected by the total entry limit.'
        } finally {
            if ($unexpectedJob) { Stop-OwnedWorkerQ $unexpectedJob }
            foreach ($stream in $held) { $stream.Dispose() }
        }
        foreach ($index in 0..1) {
            $actual = @([IO.Directory]::EnumerateFileSystemEntries($roots[$index]))
            Assert-Q ($actual.Count -eq $counts[$index]) 'Entry-limit rejection changed directory membership.'
            foreach ($file in $actual) {
                Assert-Q ($expected.ContainsKey($file) -and [IO.File]::ReadAllText($file) -ceq $expected[$file]) 'Entry-limit rejection changed a filename or file content.'
            }
        }
        $case.observed.unchangedFiles = $expected.Count
    }
    Run-CaseQ 'locked-child-completes-after-release' {
        param($case)
        $fixture = New-FixtureQ 'complete-after-release'
        $held = [IO.FileStream]::new($fixture.child, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $job = Enqueue-LockedQ $fixture
            $case.observed.accepted = $job
            # 受付直後はworkerのProbeより先に応答するため、理由が公開されるまで照会する。
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
            do {
                $waiting = Get-StateQ $job.jobId
                Assert-Q ($waiting.json.status -ceq 'pending') 'Locked child did not remain pending while its wait reason was published.'
                if ($waiting.json.waitReason) { break }
                Start-Sleep -Milliseconds 1000
            } while ([DateTimeOffset]::UtcNow -lt $deadline)
            $case.observed.waiting = $waiting.json
            Assert-Q ($waiting.json.waitReason -match 'sharing or lock violation' -and
                $waiting.json.waitReason.Contains($fixture.child, [StringComparison]::OrdinalIgnoreCase)) 'Pending wait reason omitted the sharing violation or locked child path.'
        }
        finally { $held.Dispose() }
        $result = Wait-TerminalQ $job.jobId
        $case.observed.terminal = $result.json
        Assert-Q ($result.exitCode -eq 0 -and $result.json.status -ceq 'completed') 'Unlocked deletion did not complete successfully.'
        Assert-Q ($result.json.ContainsKey('waitReason') -and $null -eq $result.json.waitReason) 'Completed job retained or omitted its waitReason field instead of returning null.'
        $items = @($result.json.result.items)
        Assert-Q ($items.Count -eq 1 -and $items[0].path -ceq $fixture.root -and
            $items[0].status -cin @('recycled', 'permanently_deleted')) 'Completed job omitted its successful file result.'
        Assert-Q (![IO.Directory]::Exists($fixture.root)) 'Completed target remains at its original path.'
    }
    Run-CaseQ 'added-child-stops-and-preserves-target' {
        param($case)
        $fixture = New-FixtureQ 'changed-during-wait'
        $added = Join-Path $fixture.root 'added-after-enqueue.txt'
        $held = [IO.FileStream]::new($fixture.child, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $job = Enqueue-LockedQ $fixture
            $case.observed.accepted = $job
            [IO.File]::WriteAllText($added, 'new child must survive', $utf8)
        } finally { $held.Dispose() }
        $result = Wait-TerminalQ $job.jobId
        $case.observed.terminal = $result.json
        Assert-Q ($result.json.status -ceq 'failed') 'Changed target did not fail closed.'
        Assert-Q ([IO.File]::ReadAllText($fixture.child) -ceq $fixture.content) 'Original child was lost or changed.'
        Assert-Q ([IO.File]::ReadAllText($added) -ceq 'new child must survive') 'Added child was lost or changed.'
        # 終端結果の照会は削除の再要求ではない。再照会後も保全を確認する。
        $again = Get-StateQ $job.jobId
        $case.observed.repeatedStatus = $again.json
        Assert-Q ($again.json.status -ceq 'failed' -and [IO.File]::Exists($added) -and [IO.File]::Exists($fixture.child)) 'Failed job retried automatically or lost its terminal state.'
    }
    Run-CaseQ 'root-replaced-during-maintenance-lock-wait-is-preserved' {
        param($case)
        $fixture = New-FixtureQ 'replace-during-maintenance-wait'
        $original = Join-Path $OutputDirectory 'original-root-moved-by-test'
        $held = [IO.FileStream]::new($fixture.child, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $maintenance = $null
        $replacementInjected = $false
        $replacement = Join-Path $fixture.root 'replacement-must-survive.txt'
        try {
            $job = Enqueue-LockedQ $fixture
            $case.observed.accepted = $job
            $maintenance = [IO.FileStream]::new((Join-Path $metadata 'maintenance.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $held.Dispose(); $held = $null
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
            do {
                $state = Get-StateQ $job.jobId
                if ($state.json.status -ceq 'running') { break }
                Assert-Q ($state.json.status -ceq 'pending') 'Job stopped before entering maintenance-lock wait.'
                Start-Sleep -Milliseconds 1000
            } while ([DateTimeOffset]::UtcNow -lt $deadline)
            Assert-Q ($state.json.status -ceq 'running') 'Job did not start while the maintenance lock was held.'
            # 今回作成した通常ディレクトリ同士だけを同じ外部作業領域内で移動する。
            Assert-Q (![IO.Directory]::Exists($original)) 'Moved-root destination already exists.'
            try {
                [IO.Directory]::Move($fixture.root, $original)
                $replacementInjected = $true
            } catch {
                $native = $_.Exception.GetBaseException().HResult -band 0xffff
                if ($native -notin @(5, 32, 33)) { throw }
                $case.observed.rootReplacementPrevented = $true
                $case.observed.rootReplacementError = $_.Exception.GetBaseException().Message
                Assert-Q (![IO.Directory]::Exists($original) -and ![IO.File]::Exists($replacement)) 'Denied replacement still changed fixture locations.'
                Assert-Q ([IO.File]::ReadAllText($fixture.child) -ceq $fixture.content) 'Pinned root changed while replacement was denied.'
            }
            $case.observed.replacementInjected = $replacementInjected
            if ($replacementInjected) {
                $null = [IO.Directory]::CreateDirectory($fixture.root)
                [IO.File]::WriteAllText($replacement, 'replacement created while queue waits for coordination', $utf8)
            }
        } finally {
            if ($held) { $held.Dispose() }
            if ($maintenance) { $maintenance.Dispose() }
        }
        $terminal = Wait-TerminalQ $job.jobId
        $case.observed.terminal = $terminal.json
        if ($replacementInjected) {
            Assert-Q ($terminal.json.status -cin @('failed', 'ambiguous')) 'Replaced root was not stopped after coordination wait.'
            Assert-Q ([IO.File]::ReadAllText((Join-Path $original 'locked.txt')) -ceq $fixture.content) 'Moved original was changed or deleted.'
            Assert-Q ([IO.File]::ReadAllText($replacement) -ceq 'replacement created while queue waits for coordination') 'Replacement root was changed or deleted.'
            $again = Get-StateQ $job.jobId
            Assert-Q ($again.json.status -ceq $terminal.json.status -and [IO.File]::Exists($replacement)) 'Failed or ambiguous job retried after source replacement.'
        } else {
            Assert-Q ($terminal.exitCode -eq 0 -and $terminal.json.status -ceq 'completed') 'Pinned original did not complete after the maintenance lock was released.'
            Assert-Q (![IO.Directory]::Exists($fixture.root) -and ![IO.Directory]::Exists($original) -and ![IO.File]::Exists($replacement)) 'Pinned-root final locations or replacement absence differ.'
        }
    }
    Run-CaseQ 'own-worker-exit-is-unavailable-without-resend' {
        param($case)
        $fixture = New-FixtureQ 'worker-disappears'
        $held = [IO.FileStream]::new($fixture.child, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $worker = $null
        try {
            $job = Enqueue-LockedQ $fixture
            $case.observed.accepted = $job
            Assert-Q ($job.workerProcessId -gt 0 -and $job.workerProcessId -ne $PID) 'Missing dedicated worker PID.'
            $worker = [Diagnostics.Process]::GetProcessById([int]$job.workerProcessId)
            # PIDの再利用から他プロセスを止めないようhandleを先に保持する。
            $null = $worker.Handle
            Assert-Q ($worker.StartTime.ToUniversalTime() -ge $started.UtcDateTime.AddSeconds(-1)) 'Worker predates this test.'
            Assert-Q ($worker.MainModule.FileName.Equals($ExecutablePath, [StringComparison]::OrdinalIgnoreCase)) 'Worker executable does not match the candidate.'
            $worker.Kill()
            Assert-Q ($worker.WaitForExit(10000)) 'Owned worker did not exit.'
        } finally {
            if ($worker) { $worker.Dispose() }
            $held.Dispose()
        }
        $first = Get-StateQ $job.jobId
        $second = Get-StateQ $job.jobId
        $case.observed.statusAfterExit = @($first.json, $second.json)
        Assert-Q ($first.json.status -ceq 'unavailable' -and $second.json.status -ceq 'unavailable') 'Disappeared worker did not remain unavailable.'
        Assert-Q (!!$first.json.error -and !!$second.json.error) 'Unknown outcome omitted its explanation.'
        Assert-Q ([IO.File]::ReadAllText($fixture.child) -ceq $fixture.content) 'Status query resent deletion after worker exit.'
    }
    function Invoke-RegisteredWrapperQ($case, [bool]$Legacy) {
        # 実際の管理配置を隔離領域に再現し、source-infoを置かず通信前に更新を延期する。
        $prefix = if ($Legacy) { 'legacy-registered' } else { 'registered' }
        $installRoot = Join-Path $OutputDirectory ($prefix + '-install')
        $bin = Join-Path $installRoot 'bin'
        $codexHome = Join-Path $OutputDirectory ($prefix + '-codex-home')
        $backup = Join-Path $OutputDirectory ($prefix + '-backup')
        $null = [IO.Directory]::CreateDirectory($bin)
        $null = [IO.Directory]::CreateDirectory($codexHome)
        $copiedExe = Join-Path $bin 'prunlet.exe'
        $copiedConfig = Join-Path $installRoot 'config.json'
        $sourceHook = Join-Path ([IO.Path]::GetDirectoryName($ExecutablePath)) 'prunlet-hook.exe'
        Assert-Q ([IO.File]::Exists($sourceHook)) 'The candidate build does not contain prunlet-hook.exe.'
        [IO.File]::Copy($ExecutablePath, $copiedExe, $false)
        [IO.File]::Copy($sourceHook, (Join-Path $bin 'prunlet-hook.exe'), $false)
        [IO.File]::Copy($fixtureConfig, $copiedConfig, $false)
        $wrapperSource = if ($Legacy) { $LegacyMcpWrapperPath } else { Join-Path $repo 'integration\start-prunlet-mcp.ps1' }
        [IO.File]::Copy($wrapperSource, (Join-Path $bin 'start-prunlet-mcp.ps1'), $false)
        [IO.File]::Copy((Join-Path $repo 'integration\configuration-common.ps1'), (Join-Path $bin 'configuration-common.ps1'), $false)
        $case.observed.wrapperSource = $wrapperSource
        $case.observed.wrapperSha256 = (Get-FileHash -LiteralPath $wrapperSource -Algorithm SHA256).Hash
        Assert-Q ((Get-FileHash -LiteralPath $copiedExe -Algorithm SHA256).Hash -ceq $exeHash) 'Copied executable differs from the candidate.'
        $registration = & (Join-Path $repo 'integration\install-codex.ps1') -ExecutablePath $copiedExe -ConfigPath $copiedConfig -CodexHome $codexHome -BackupDirectory $backup
        $case.observed.registration = $registration | ConvertFrom-Json -AsHashtable
        Assert-Q ($case.observed.registration.status -ceq 'installed') 'Isolated registration failed.'
        $toml = [IO.File]::ReadAllText((Join-Path $codexHome 'config.toml'))
        $block = [regex]::Matches($toml, '(?ms)^# BEGIN PRUNLET MCP\r?\n\[mcp_servers\.prunlet\]\r?\ncommand = (?<command>"(?:\\.|[^"\\])*")\r?\nargs = (?<args>\[(?:\s*"(?:\\.|[^"\\])*"\s*(?:,\s*"(?:\\.|[^"\\])*"\s*)*)?\])\r?\nstartup_timeout_sec = 600\r?\n# END PRUNLET MCP\r?$')
        Assert-Q ($block.Count -eq 1) 'Generated MCP registration is not the expected JSON-compatible TOML block.'
        # 登録値だけをJSONとして復号し、PowerShell式として評価しない。
        $command = $block[0].Groups['command'].Value | ConvertFrom-Json
        $arguments = @($block[0].Groups['args'].Value | ConvertFrom-Json)
        $expectedArgs = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $bin 'start-prunlet-mcp.ps1'), '-ExecutablePath', $copiedExe, '-ConfigPath', $copiedConfig, '-CodexHome', $codexHome)
        Assert-Q ($command -ceq 'pwsh' -and $arguments.Count -eq $expectedArgs.Count) 'Generated MCP command or argument count differs.'
        for ($index = 0; $index -lt $expectedArgs.Count; $index++) {
            Assert-Q ($arguments[$index] -is [string] -and $arguments[$index] -ceq $expectedArgs[$index]) 'Generated MCP arguments differ from the isolated registration.'
        }
        $case.observed.command = $command
        $case.observed.arguments = $arguments
        $fixture = New-FixtureQ ($prefix + '-wrapper-locked')
        $held = [IO.FileStream]::new($fixture.child, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $process = [Diagnostics.Process]::new()
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $command
        foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardInputEncoding = $utf8
        $start.StandardOutputEncoding = $utf8
        $start.StandardErrorEncoding = $utf8
        $start.Environment['TEMP'] = $temp
        $start.Environment['TMP'] = $temp
        $process.StartInfo = $start
        $session = @{ process = $process }
        $launched = $false
        $job = $null
        $finished = $false
        $output = $null
        $errors = $null
        try {
            $launched = $process.Start()
            Assert-Q $launched 'Registered MCP wrapper did not start.'
            $errors = $process.StandardError.ReadToEndAsync()
            $null = Invoke-McpQ $session 101 'initialize' @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'registered-queue-e2e'; version = '1' } }
            $process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
            $process.StandardInput.Flush()
            $accepted = Invoke-McpQ $session 102 'tools/call' @{ name = 'delete_files'; arguments = @{ action = 'enqueue'; paths = @($fixture.root); recursive = $true } }
            $job = $accepted.structuredContent
            $case.observed.response = $accepted
            $case.observed.accepted = $job
            if ($job.jobId -cmatch '^[a-f0-9]{32}$' -and $job.workerProcessId -gt 0) {
                $workerExecutables[$job.jobId] = $copiedExe
                $ownedJobs.Add($job)
            }
            if ($Legacy) {
                $content = @($accepted.content)
                Assert-Q ($accepted.isError -eq $true -and $null -eq $job -and $content.Count -eq 1 -and $content[0].type -ceq 'text' -and $content[0].text -ceq 'Reconnect to the installed Prunlet MCP launcher before enqueuing; deletion was not started') 'Legacy wrapper enqueue was not rejected with the expected reconnect instruction and no job or worker ID.'
                Assert-Q ([IO.File]::ReadAllText($fixture.child) -ceq $fixture.content) 'Legacy wrapper rejection changed the locked target.'
            } else {
                Assert-Q (!$accepted.isError -and $job.jobId -cmatch '^[a-f0-9]{32}$' -and $job.workerProcessId -gt 0 -and $job.status -ceq 'pending') 'Registered MCP did not acknowledge a pending job with its worker.'
            }
            $process.StandardInput.Close()
            $output = $process.StandardOutput.ReadToEndAsync()
            Assert-Q ($process.WaitForExit(15000)) 'Registered wrapper did not exit after stdin EOF; do not resend.'
            $case.observed.wrapperExitCode = $process.ExitCode
            Assert-Q ($output.Wait(5000) -and $errors.Wait(5000)) 'Registered wrapper exited without pipe EOF; do not resend.'
            $case.observed.stdoutEof = $true
            $case.observed.stderrEof = $true
            $case.observed.wrapperStdoutAfterAck = $output.GetAwaiter().GetResult()
            $case.observed.wrapperStderr = $errors.GetAwaiter().GetResult()
            Assert-Q ($process.ExitCode -eq 0) 'Registered wrapper exited unsuccessfully after stdin EOF.'
            Assert-Q ($case.observed.wrapperStderr -match 'Prunlet startup update was deferred:' -and $case.observed.wrapperStderr -match 'source-info\.json') 'Expected offline startup update deferral was not recorded.'
            if ($Legacy) {
                Assert-Q ([IO.File]::ReadAllText($fixture.child) -ceq $fixture.content) 'Legacy wrapper rejection changed the target after EOF.'
                $finished = $true
                return
            }
            $waiting = Get-StateQ $job.jobId
            $case.observed.waitingAfterWrapperExit = $waiting.json
            Assert-Q ($waiting.exitCode -eq 0 -and $waiting.json.status -ceq 'pending' -and $waiting.json.workerProcessId -eq $job.workerProcessId) 'Original worker did not remain pending after wrapper exit.'
            Assert-Q ([IO.File]::ReadAllText($fixture.child) -ceq $fixture.content) 'Locked target changed before release.'
            $held.Dispose(); $held = $null
            $terminal = Wait-TerminalQ $job.jobId
            $case.observed.terminal = $terminal.json
            Assert-Q ($terminal.exitCode -eq 0 -and $terminal.json.status -ceq 'completed' -and $terminal.json.jobId -ceq $job.jobId -and $terminal.json.workerProcessId -eq $job.workerProcessId) 'Original queued worker did not complete after release.'
            $items = @($terminal.json.result.items)
            Assert-Q ($items.Count -eq 1 -and $items[0].path -ceq $fixture.root -and $items[0].status -cin @('recycled', 'permanently_deleted')) 'Completed registered job omitted its successful file result.'
            Assert-Q (![IO.Directory]::Exists($fixture.root)) 'Completed registered target remains at its original path.'
            $finished = $true
        } finally {
            # 失敗時は解除前に所有を照合してworkerを止め、fixtureと観測結果を保持する。
            if (!$finished -and $job -and $workerExecutables.ContainsKey($job.jobId)) { Stop-OwnedWorkerQ $job }
            if ($held) { $held.Dispose() }
            if ($launched) {
                if (!$process.HasExited) {
                    try { $process.StandardInput.Close() } catch { }
                    if (!$process.WaitForExit(5000)) { $process.Kill(); $process.WaitForExit(); $case.observed.wrapperForcedStop = $true }
                }
                if (!$case.observed.Contains('wrapperExitCode')) { $case.observed.wrapperExitCode = $process.ExitCode }
                if ($errors -and $errors.Wait(5000) -and !$case.observed.Contains('wrapperStderr')) { $case.observed.wrapperStderr = $errors.GetAwaiter().GetResult() }
                if ($output -and $output.Wait(5000) -and !$case.observed.Contains('wrapperStdoutAfterAck')) { $case.observed.wrapperStdoutAfterAck = $output.GetAwaiter().GetResult() }
            }
            $process.Dispose()
        }
    }
    Run-CaseQ 'registered-wrapper-eof-keeps-queued-worker' { param($case) Invoke-RegisteredWrapperQ $case $false }
    if ($LegacyMcpWrapperPath) {
        Run-CaseQ 'legacy-registered-wrapper-rejects-enqueue' { param($case) Invoke-RegisteredWrapperQ $case $true }
    }
    Run-CaseQ 'stdio-mcp-enqueue-status-and-cancel' {
        param($case)
        $fixture = New-FixtureQ 'mcp-cancelled'
        $held = [IO.FileStream]::new($fixture.child, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = [Diagnostics.ProcessStartInfo]::new()
        $process.StartInfo.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $process.StartInfo.Arguments = '/d /v:off /s /c ""' + $ExecutablePath + '" --config "' + $fixtureConfig + '" mcp"'
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardInput = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $process.StartInfo.StandardOutputEncoding = $utf8
        $process.StartInfo.StandardErrorEncoding = $utf8
        $process.StartInfo.Environment['TEMP'] = $temp
        $process.StartInfo.Environment['TMP'] = $temp
        $session = @{ process = $process }
        $launched = $false
        try {
            $launched = $process.Start()
            Assert-Q $launched 'MCP did not start.'
            $errors = $process.StandardError.ReadToEndAsync()
            $null = Invoke-McpQ $session 1 'initialize' @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'deferred-delete-e2e'; version = '1' } }
            $process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
            $process.StandardInput.Flush()
            $accepted = Invoke-McpQ $session 2 'tools/call' @{ name = 'delete_files'; arguments = @{ action = 'enqueue'; paths = @($fixture.root); recursive = $true } }
            Assert-Q (!$accepted.isError -and $accepted.structuredContent.status -ceq 'pending') 'MCP failed to accept the locked fixture.'
            $job = $accepted.structuredContent
            $ownedJobs.Add($job)
            $case.observed.accepted = $job
            $state = Invoke-McpQ $session 3 'tools/call' @{ name = 'delete_files'; arguments = @{ action = 'status'; jobId = $job.jobId } }
            Assert-Q (!$state.isError -and $state.structuredContent.jobId -ceq $job.jobId -and $state.structuredContent.status -ceq 'pending') 'MCP status did not find its pending job.'
            Assert-Q ([IO.File]::Exists($fixture.child)) 'MCP deleted a locked child.'
            $cancelled = Invoke-McpQ $session 4 'tools/call' @{ name = 'delete_files'; arguments = @{ action = 'cancel'; jobId = $job.jobId } }
            $case.observed.cancelled = $cancelled
            Assert-Q (!$cancelled.isError -and $cancelled.structuredContent.status -ceq 'cancelled') 'MCP cancellation failed.'
            $held.Dispose(); $held = $null
            $after = Invoke-McpQ $session 5 'tools/call' @{ name = 'delete_files'; arguments = @{ action = 'status'; jobId = $job.jobId } }
            Assert-Q (!$after.isError -and $after.structuredContent.status -ceq 'cancelled') 'MCP cancellation did not persist.'
            Assert-Q ([IO.File]::ReadAllText($fixture.child) -ceq $fixture.content) 'Cancelled target changed.'
        } finally {
            if ($held) { $held.Dispose() }
            if ($launched) {
                $process.StandardInput.Close()
                if (!$process.WaitForExit(15000)) { $process.Kill($true); $process.WaitForExit(); $case.observed.mcpForcedStop = $true }
                $case.observed.mcpExitCode = $process.ExitCode
                $case.observed.mcpStderr = $errors.GetAwaiter().GetResult()
            }
            $process.Dispose()
        }
        Assert-Q (!$case.observed.mcpForcedStop -and $case.observed.mcpExitCode -eq 0) 'MCP failed to exit normally after EOF.'
    }
} finally {
    # 結果保持用workerも枠を使うため、今回受理した専用workerだけを閉じる。
    foreach ($job in $ownedJobs) {
        if (@($workerCleanup | Where-Object { $_.jobId -ceq $job.jobId -and $_.status -in @('stopped-owned-worker', 'already-exited') }).Count -eq 0) { Stop-OwnedWorkerQ $job }
    }
    $report = [ordered]@{
        executablePath = $ExecutablePath; executableSha256 = $exeHash; sourceConfigPath = $ConfigPath; legacyMcpWrapperPath = $LegacyMcpWrapperPath
        fixtureConfigPath = $fixtureConfig; outputDirectory = $OutputDirectory
        startedAtUtc = $started; finishedAtUtc = [DateTimeOffset]::UtcNow
        passed = @($cases | Where-Object passed).Count; failed = @($cases | Where-Object { !$_.passed }).Count
        cases = @($cases.ToArray()); invocations = @($invocations.ToArray()); workerCleanup = @($workerCleanup.ToArray())
        unverified = @('ambiguous outcome after deletion has started (no deterministic fault injection)', 'Windows Recycle Bin content and restoration', 'queue retention expiry and process restart')
        retained = @(@{ path = $OutputDirectory; reason = 'Failed-closed fixtures, CLI JSON, and isolated metadata retained for review. No unrelated Recycle Bin items were touched.' })
    }
    if (!$LegacyMcpWrapperPath) { $report.unverified += 'legacy MCP wrapper with the candidate executable (LegacyMcpWrapperPath not supplied)' }
    [IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 60), $utf8)
}
[pscustomobject]$report | Select-Object passed, failed, outputDirectory | ConvertTo-Json
if ($report.failed -gt 0) { exit 1 }
