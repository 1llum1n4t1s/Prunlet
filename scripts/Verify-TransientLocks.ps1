[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$TemporaryDirectory
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
if (!$TemporaryDirectory) { $TemporaryDirectory = Join-Path $OutputDirectory 'temp' }
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath, $TemporaryDirectory)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'All paths must be absolute.' }
    Assert-VerificationDestination ([IO.Path]::GetFullPath($path)) @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
    if ($path -match '["%&|<>^!\r\n]') { throw 'Unsafe CMD path.' }
}
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$report = [IO.Path]::GetFullPath($ReportPath)
foreach ($destination in @($outputRoot, $report, $TemporaryDirectory)) {
    if (![IO.Path]::GetPathRoot($destination).Equals('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Verification output must be on D:.' }
}
if (![IO.File]::Exists($ExecutablePath)) { throw 'Executable not found.' }
if ((Test-Path -LiteralPath $outputRoot) -or (Test-Path -LiteralPath $report)) { throw 'OutputDirectory and ReportPath must be new.' }
if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($report))) { throw 'Create the report parent first.' }
$null = [IO.Directory]::CreateDirectory($outputRoot)
$env:TEMP = [IO.Path]::GetFullPath($TemporaryDirectory); $env:TMP = $env:TEMP
$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR = Join-Path $outputRoot 'runtime-cache'
$null = [IO.Directory]::CreateDirectory($env:TEMP)
$results = [Collections.Generic.List[object]]::new()
$commands = [Collections.Generic.List[object]]::new()
$binaryHash = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()

# 想定する失敗: 60秒を超える調停待機の打ち切り、fixtureによる本番専用領域への書込み、
# rename拒否後の元tree・ID・hash・属性の変更、成功後のpayload/復元の別ID化・非消費、
# schema 4 intent/payloadの欠落、読み取り専用移動の属性変更・不要な再試行。
# 待機進捗の終了時までのバッファリング、繰返し・取得通知の欠落、無競合時の不要な出力、
# MCPのtokenなし通知・token型変更・進捗逆行・stdout結果JSONへの診断混入。
# 新規renameはone-shotであり、旧コピー経路のdelete-pending再試行とは区別する。
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PrunletTransientLockFixture {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandleEx(Microsoft.Win32.SafeHandles.SafeFileHandle file, int kind, byte[] data, uint size);
    public static string Identity(string path) {
        using (var handle = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            byte[] data = new byte[24];
            if (!GetFileInformationByHandleEx(handle, 18, data, 24)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            return BitConverter.ToString(data).Replace("-", "");
        }
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FreeLibrary(IntPtr module);
}
'@
function Assert-True([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Digest([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Save-Json([string]$Path, [object]$Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false)) }
function File-Id([string]$Path) { [PrunletTransientLockFixture]::Identity($Path) }
function Manifests { @(Get-ChildItem -LiteralPath $script:Recovery -Filter move-manifest.json -Recurse -File) }
function Payloads { if ([IO.Directory]::Exists($script:Store)) { @(Get-ChildItem -LiteralPath $script:Store -Filter '*.entry' -Recurse -Force) } }
function Receive-Lines($Reader, [ref]$Pending, $Lines, $Timer) {
    while ($null -ne $Pending.Value -and $Pending.Value.IsCompleted) {
        $line = $Pending.Value.GetAwaiter().GetResult()
        if ($null -eq $line) { $Pending.Value = $null; break }
        $Lines.Add(@{ text = $line; milliseconds = $Timer.Elapsed.TotalMilliseconds })
        $Pending.Value = $Reader.ReadLineAsync()
    }
}
function Assert-LockMessages($Lines) {
    $waiting = @($Lines | Where-Object { $_.text -cmatch '^\[prunlet\] Waiting for recovery lock \([0-9]+\.[0-9]s elapsed\)\.$' })
    $acquired = @($Lines | Where-Object { $_.text -cmatch '^\[prunlet\] Recovery lock acquired after [0-9]+\.[0-9]s\.$' })
    Assert-True ($waiting.Count -ge 2 -and $acquired.Count -eq 1 -and $Lines.Count -eq $waiting.Count + 1) 'Expected repeated waiting messages and one acquired message only.'
    Assert-True ($Lines[-1].text -ceq $acquired[0].text) 'Acquired message must follow all waiting messages.'
    Assert-True ($waiting[0].milliseconds -lt $script:Evidence.releaseMilliseconds -and $waiting[1].milliseconds -lt $script:Evidence.releaseMilliseconds) 'Waiting messages were not received before lock release.'
}
function Invoke-Cli([string[]]$Arguments, [scriptblock]$Tick = {}, [int]$TimeoutSeconds = 75) {
    $values = @('--config', $script:Config) + $Arguments
    foreach ($value in @($ExecutablePath) + $values) { if ($value -match '["%&|<>^!\r\n]') { throw 'Unsafe CMD argument.' } }
    $number = $commands.Count
    $stdoutPath = Join-Path $script:CaseRoot "command-$number.stdout.json"
    $stderrPath = Join-Path $script:CaseRoot "command-$number.stderr.txt"
    $info = [Diagnostics.ProcessStartInfo]::new('cmd.exe')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $info.Arguments = '/d /s /c ""' + $ExecutablePath + '" ' + (($values | ForEach-Object { '"' + $_ + '"' }) -join ' ') + '"'
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $started = $false; $recorded = $false
    try {
        $null = $process.Start()
        $started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderrLines = [Collections.Generic.List[object]]::new()
        $stderrPending = $process.StandardError.ReadLineAsync()
        while (!$process.WaitForExit(25)) {
            Receive-Lines $process.StandardError ([ref]$stderrPending) $stderrLines $timer
            & $Tick $timer.Elapsed.TotalMilliseconds
            if ($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw 'CLI exceeded timeout.' }
        }
        while ($null -ne $stderrPending) { Receive-Lines $process.StandardError ([ref]$stderrPending) $stderrLines $timer }
        $raw = $stdout.GetAwaiter().GetResult(); $errorText = ($stderrLines | ForEach-Object text) -join [Environment]::NewLine
        [IO.File]::WriteAllText($stdoutPath, $raw); [IO.File]::WriteAllText($stderrPath, $errorText)
        $entry = @{ case = [IO.Path]::GetFileName($script:CaseRoot); arguments = $Arguments; exitCode = $process.ExitCode; milliseconds = $timer.Elapsed.TotalMilliseconds; stdout = $stdoutPath; stderr = $stderrPath }
        $commands.Add($entry)
        $recorded = $true
        $json = if ($raw.Trim()) { $raw | ConvertFrom-Json -Depth 40 } else { $null }
        return @{ ExitCode = $process.ExitCode; Json = $json; Milliseconds = $entry.milliseconds; StderrLines = @($stderrLines) }
    } catch {
        if ($started -and !$recorded) {
            if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            [IO.File]::WriteAllText($stdoutPath, $stdout.GetAwaiter().GetResult())
            while ($null -ne $stderrPending) { Receive-Lines $process.StandardError ([ref]$stderrPending) $stderrLines $timer }
            [IO.File]::WriteAllText($stderrPath, (($stderrLines | ForEach-Object text) -join [Environment]::NewLine))
            $commands.Add(@{ case = [IO.Path]::GetFileName($script:CaseRoot); arguments = $Arguments; exitCode = $process.ExitCode; milliseconds = $timer.Elapsed.TotalMilliseconds; stdout = $stdoutPath; stderr = $stderrPath; harnessError = $_.Exception.Message })
        }
        throw
    } finally {
        if ($started -and !$process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $script:Evidence = @{}
    try {
        $script:CaseRoot = Join-Path $outputRoot $Name
        $script:Recovery = Join-Path $script:CaseRoot 'recovery'
        $script:Config = Join-Path $script:CaseRoot 'config.json'
        $script:Store = Join-Path $script:CaseRoot 'volume-store'
        Assert-VerificationDestination $script:CaseRoot @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
        $null = [IO.Directory]::CreateDirectory($script:Recovery)
        $init = Invoke-Cli @('init', '--backup-directory', $script:Recovery)
        $script:Evidence.initMilliseconds = $init.Milliseconds
        Assert-True ($init.ExitCode -eq 0) 'Fixture initialization failed.'
        $configuration = [IO.File]::ReadAllText($script:Config) | ConvertFrom-Json -AsHashtable
        $configuration.volumeRecoveryDirectories = @{ 'D:\' = $script:Store }
        Save-Json $script:Config $configuration
        & $Body
        $results.Add(@{ name = $Name; passed = $true; milliseconds = $timer.Elapsed.TotalMilliseconds; evidence = $script:Evidence })
    } catch {
        $results.Add(@{ name = $Name; passed = $false; milliseconds = $timer.Elapsed.TotalMilliseconds; error = $_.Exception.Message; evidence = $script:Evidence })
        Write-Warning "$Name : $($_.Exception.Message)"
    }
}
function Assert-MovePayload([string]$SourceHash, [string]$RootId = $script:Evidence.sourceId, [string]$Relative = '') {
    $manifests = @(Manifests)
    Assert-True ($manifests.Count -eq 1) 'Expected exactly one operation manifest.'
    $manifest = [IO.File]::ReadAllText($manifests[0].FullName) | ConvertFrom-Json
    Assert-True ($manifest.schema -eq 4 -and @($manifest.entries).Count -eq 1) 'Expected one schema 4 root entry.'
    $entry = $manifest.entries[0]
    $payload = Join-Path (Join-Path $entry.storeRoot $manifest.operationId) $entry.payloadName
    Assert-True ($payload.StartsWith($script:Store + '\', [StringComparison]::OrdinalIgnoreCase)) 'Payload escaped isolated volume store.'
    Assert-True ($entry.identity.fileId -ceq $RootId.Substring(16) -and $entry.identity.volumeSerialNumber -eq [BitConverter]::ToUInt64([Convert]::FromHexString($RootId), 0) -and (File-Id $payload) -ceq $RootId) 'Root file identity changed during move.'
    $bytes = if ($Relative) { Join-Path $payload $Relative } else { $payload }
    Assert-True ((Digest $bytes) -ceq $SourceHash -and (File-Id $bytes) -ceq $script:Evidence.sourceId) 'Moved bytes or file identity differ.'
    Assert-True (@(Get-ChildItem -LiteralPath $script:Recovery -Filter manifest.json -Recurse -File).Count -eq 0) 'New deletion generated a legacy copy manifest.'
    $script:Evidence.move = @{ path = $payload; sha256 = Digest $bytes; rootId = File-Id $payload; manifest = $manifests[0].FullName }
}
foreach ($longWait in @($false, $true)) {
    $name = if ($longWait) { 'maintenance-lock-long-wait-released' } else { 'maintenance-lock-released' }
    Test-Case $name {
        $source = Join-Path $script:CaseRoot 'source.txt'; [IO.File]::WriteAllText($source, 'maintenance contention fixture')
        $hash = Digest $source; $script:Evidence.sourceId = File-Id $source; $script:Evidence.sourceSha256 = $hash
        $script:Evidence.plannedHoldMilliseconds = if ($longWait) {
            # 起動時間を見込んでも旧60秒上限を超えるまで保持する。
            [Math]::Max(65000, $script:Evidence.initMilliseconds * 2 + 62000)
        } else { [Math]::Max(10000, $script:Evidence.initMilliseconds * 2 + 2000) }
        $timeoutSeconds = [int][Math]::Ceiling($script:Evidence.plannedHoldMilliseconds / 1000) + 30
        $script:HeldLock = [IO.FileStream]::new((Join-Path $script:Recovery 'maintenance.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $result = Invoke-Cli @('delete', '--', $source) {
                param($milliseconds)
                if ($longWait -and $script:HeldLock -and $milliseconds -ge 61000 -and !$script:Evidence.checkedBeyondSixtySeconds) {
                    $script:Evidence.checkedBeyondSixtySeconds = $milliseconds
                    Assert-True (!$process.HasExited) 'CLI exited while the coordination lock was still held beyond 60 seconds.'
                    Assert-True ([IO.File]::Exists($source) -and (Digest $source) -ceq $hash -and (File-Id $source) -ceq $script:Evidence.sourceId) 'Coordination wait changed the source beyond 60 seconds.'
                    Assert-True (@(Manifests).Count -eq 0 -and @(Payloads).Count -eq 0) 'Coordination wait changed move state beyond 60 seconds.'
                }
                if ($script:HeldLock -and $milliseconds -ge $script:Evidence.plannedHoldMilliseconds) {
                    Assert-True ($stderrLines.Count -ge 2) 'Repeated CLI wait messages must arrive while the lock is still held.'
                    $script:Evidence.releaseMilliseconds = $milliseconds
                    $script:Evidence.cliAliveBeforeRelease = !$process.HasExited
                    $script:Evidence.manifestCountBeforeRelease = @(Manifests).Count
                    Assert-True ($script:Evidence.cliAliveBeforeRelease -and $script:Evidence.manifestCountBeforeRelease -eq 0) 'CLI must still be alive without a manifest before lock release.'
                    Assert-True ([IO.File]::Exists($source) -and (Digest $source) -ceq $hash -and (File-Id $source) -ceq $script:Evidence.sourceId) 'Coordination wait changed the source before release.'
                    $script:Evidence.payloadCountBeforeRelease = @(Payloads).Count
                    Assert-True ($script:Evidence.payloadCountBeforeRelease -eq 0) 'Coordination wait created move payload before lock release.'
                    $script:HeldLock.Dispose(); $script:HeldLock = $null
                }
            } $timeoutSeconds
            $script:Evidence.cliMilliseconds = $result.Milliseconds
            if ($longWait) { Assert-True ($script:Evidence.checkedBeyondSixtySeconds -ge 61000) 'CLI did not remain alive beyond 60 seconds.' }
            Assert-True ($script:Evidence.releaseMilliseconds -ge $script:Evidence.plannedHoldMilliseconds -and $script:Evidence.cliAliveBeforeRelease -and $script:Evidence.manifestCountBeforeRelease -eq 0) 'CLI did not wait before manifest creation.'
            Assert-True ($result.ExitCode -eq 0 -and ![IO.File]::Exists($source)) 'Released coordination lock did not allow deletion.'
            $script:Evidence.stderrLines = $result.StderrLines
            Assert-LockMessages $result.StderrLines
            Assert-MovePayload $hash
        } finally { if ($script:HeldLock) { $script:HeldLock.Dispose(); $script:HeldLock = $null } }
    }
}
Test-Case 'maintenance-lock-uncontended-quiet' {
    $source = Join-Path $script:CaseRoot 'source.txt'; [IO.File]::WriteAllText($source, 'uncontended fixture')
    $hash = Digest $source; $script:Evidence.sourceId = File-Id $source
    $result = Invoke-Cli @('delete', '--', $source)
    Assert-True ($result.ExitCode -eq 0 -and ![IO.File]::Exists($source) -and $result.StderrLines.Count -eq 0) 'Uncontended CLI deletion should succeed without stderr diagnostics.'
    Assert-MovePayload $hash
}
foreach ($tokenCase in @('string', 'number', 'absent')) {
    Test-Case "mcp-maintenance-lock-$tokenCase" {
        $source = Join-Path $script:CaseRoot 'source.txt'; [IO.File]::WriteAllText($source, 'MCP coordination fixture')
        $hash = Digest $source; $script:Evidence.sourceId = File-Id $source
        $token = if ($tokenCase -eq 'string') { 'lock-progress-token' } else { [long]123 }
        $stdoutLines = [Collections.Generic.List[object]]::new()
        $stderrLines = [Collections.Generic.List[object]]::new()
        $stdoutPath = Join-Path $script:CaseRoot 'mcp.stdout.jsonl'
        $stderrPath = Join-Path $script:CaseRoot 'mcp.stderr.txt'
        $info = [Diagnostics.ProcessStartInfo]::new('cmd.exe')
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $info.Arguments = '/d /s /c ""' + $ExecutablePath + '" --config "' + $script:Config + '" mcp"'
        $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $started = $false; $stdoutPending = $null; $stderrPending = $null; $script:HeldLock = $null
        try {
            $null = $process.Start(); $started = $true
            $stderrPending = $process.StandardError.ReadLineAsync()
            $process.StandardInput.WriteLine((@{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2025-11-25'; capabilities = @{}; clientInfo = @{ name = 'prunlet-lock-e2e'; version = 'development' } } } | ConvertTo-Json -Depth 10 -Compress))
            $process.StandardInput.Flush()
            $initialize = $process.StandardOutput.ReadLineAsync()
            Assert-True ($initialize.Wait(10000)) 'MCP initialization timed out.'
            $initialized = $initialize.GetAwaiter().GetResult()
            $stdoutLines.Add(@{ text = $initialized; milliseconds = $timer.Elapsed.TotalMilliseconds })
            Assert-True (($initialized | ConvertFrom-Json).id -eq 1) 'MCP initialization response differs.'
            $process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
            $script:HeldLock = [IO.FileStream]::new((Join-Path $script:Recovery 'maintenance.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $parameters = @{ name = 'delete_files'; arguments = @{ paths = @($source) } }
            if ($tokenCase -ne 'absent') { $parameters._meta = @{ progressToken = $token } }
            $process.StandardInput.WriteLine((@{ jsonrpc = '2.0'; id = 2; method = 'tools/call'; params = $parameters } | ConvertTo-Json -Depth 10 -Compress))
            $process.StandardInput.Flush()
            $stdoutPending = $process.StandardOutput.ReadLineAsync()
            $holdStarted = $timer.Elapsed.TotalMilliseconds
            $response = $null
            while ($null -eq $response) {
                Receive-Lines $process.StandardOutput ([ref]$stdoutPending) $stdoutLines $timer
                Receive-Lines $process.StandardError ([ref]$stderrPending) $stderrLines $timer
                $responses = @($stdoutLines | ForEach-Object { $_.text | ConvertFrom-Json -Depth 40 } | Where-Object { $_.id -eq 2 })
                if ($responses.Count -gt 0) { $response = $responses[0]; break }
                if ($script:HeldLock -and $timer.Elapsed.TotalMilliseconds - $holdStarted -ge 7500) {
                    Assert-True (!$process.HasExited -and $stderrLines.Count -ge 2) 'MCP wait diagnostics must arrive before lock release.'
                    $beforeRelease = @($stdoutLines | ForEach-Object { $_.text | ConvertFrom-Json -Depth 40 } | Where-Object { $_.method -eq 'notifications/progress' })
                    if ($tokenCase -eq 'absent') { Assert-True ($beforeRelease.Count -eq 0) 'MCP sent progress without a token.' }
                    else { Assert-True ($beforeRelease.Count -ge 2) 'MCP progress notifications must arrive before lock release.' }
                    Assert-True ([IO.File]::Exists($source) -and (Digest $source) -ceq $hash -and (File-Id $source) -ceq $script:Evidence.sourceId -and @(Manifests).Count -eq 0 -and @(Payloads).Count -eq 0) 'MCP lock wait changed source or move state.'
                    $script:Evidence.releaseMilliseconds = $timer.Elapsed.TotalMilliseconds
                    $script:HeldLock.Dispose(); $script:HeldLock = $null
                }
                if ($process.HasExited -or $timer.Elapsed.TotalSeconds -gt 30) { throw 'MCP lock request exited early or exceeded timeout.' }
                Start-Sleep -Milliseconds 25
            }
            Assert-True ($null -eq $script:HeldLock -and !$response.result.isError -and $null -ne $response.result.structuredContent.operationId -and ![IO.File]::Exists($source)) 'MCP delete did not complete successfully after lock release.'
            $process.StandardInput.Close()
            Assert-True ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'MCP did not shut down cleanly.'
            while ($null -ne $stdoutPending) { Receive-Lines $process.StandardOutput ([ref]$stdoutPending) $stdoutLines $timer }
            while ($null -ne $stderrPending) { Receive-Lines $process.StandardError ([ref]$stderrPending) $stderrLines $timer }
            Assert-LockMessages $stderrLines
            $messages = @($stdoutLines | ForEach-Object { $_.text | ConvertFrom-Json -Depth 40 })
            $notifications = @($messages | Where-Object { $_.method -eq 'notifications/progress' })
            Assert-True (@($messages | Where-Object { $_.id -eq 2 }).Count -eq 1 -and $messages.Count -eq 2 + $notifications.Count -and $messages[-1].id -eq 2) 'MCP stdout contained unexpected messages, duplicate results, or progress after completion.'
            if ($tokenCase -eq 'absent') { Assert-True ($notifications.Count -eq 0) 'MCP sent progress without a token.' }
            else {
                Assert-True ($notifications.Count -eq $stderrLines.Count) 'MCP progress and stderr message counts differ.'
                $previous = 0
                for ($i = 0; $i -lt $notifications.Count; $i++) {
                    $notification = $notifications[$i]
                    Assert-True ($notification.jsonrpc -eq '2.0' -and $null -eq $notification.id -and $notification.params.progressToken -ceq $token -and $notification.params.progressToken.GetType() -eq $token.GetType()) 'MCP progress token value or type changed.'
                    Assert-True ($notification.params.progress -gt $previous -and $notification.params.PSObject.Properties.Name -notcontains 'total' -and $notification.params.message -ceq $stderrLines[$i].text) 'MCP progress is not monotonic or its message differs.'
                    $previous = $notification.params.progress
                }
            }
            $script:Evidence.stderrLines = @($stderrLines)
            $script:Evidence.progressNotifications = $notifications
            $script:Evidence.result = $response
            Assert-MovePayload $hash
        } finally {
            if ($script:HeldLock) { $script:HeldLock.Dispose(); $script:HeldLock = $null }
            if ($started) {
                if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() }
                while ($null -ne $stdoutPending) { Receive-Lines $process.StandardOutput ([ref]$stdoutPending) $stdoutLines $timer }
                while ($null -ne $stderrPending) { Receive-Lines $process.StandardError ([ref]$stderrPending) $stderrLines $timer }
                [IO.File]::WriteAllText($stdoutPath, (($stdoutLines | ForEach-Object text) -join [Environment]::NewLine))
                [IO.File]::WriteAllText($stderrPath, (($stderrLines | ForEach-Object text) -join [Environment]::NewLine))
                $commands.Add(@{ case = [IO.Path]::GetFileName($script:CaseRoot); arguments = @('mcp'); exitCode = $process.ExitCode; milliseconds = $timer.Elapsed.TotalMilliseconds; stdout = $stdoutPath; stderr = $stderrPath })
            }
            $process.Dispose()
        }
    }
}
foreach ($persistent in @($false, $true)) {
    $name = if ($persistent) { 'loaded-dll-held-through-rename' } else { 'loaded-dll-released-before-rename' }
    Test-Case $name {
        $tree = Join-Path $script:CaseRoot 'tree'; $parent = Join-Path $tree 'nested'
        $null = [IO.Directory]::CreateDirectory($parent)
        $source = Join-Path $parent 'fixture.dll'
        [IO.File]::Copy((Join-Path $env:WINDIR 'System32\version.dll'), $source)
        $sourceAttributes = [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Archive
        [IO.File]::SetAttributes($source, $sourceAttributes)
        $hash = Digest $source; $script:Evidence.sourceId = File-Id $source; $script:Evidence.sourceSha256 = $hash
        $treeId = File-Id $tree; $parentId = File-Id $parent
        $script:Module = [PrunletTransientLockFixture]::LoadLibraryExW($source, [IntPtr]::Zero, 1)
        Assert-True ($script:Module -ne [IntPtr]::Zero) "LoadLibraryExW failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        try {
            if (!$persistent) {
                Assert-True ([PrunletTransientLockFixture]::FreeLibrary($script:Module)) 'FreeLibrary failed.'
                $script:Module = [IntPtr]::Zero
            }
            $script:Evidence.loadedDuringRequest = $persistent
            $result = Invoke-Cli @('delete', '--recursive', '--', $tree) {} 25
            $script:Evidence.cliMilliseconds = $result.Milliseconds
            if ($result.ExitCode -ne 0) {
                Assert-True $persistent 'Released DLL still prevented rename.'
                $script:Evidence.renameOutcome = 'rejected-with-source-preserved'
                Assert-True ([IO.Directory]::Exists($tree) -and [IO.Directory]::Exists($parent) -and [IO.File]::Exists($source) -and (Digest $source) -ceq $hash -and (File-Id $source) -ceq $script:Evidence.sourceId) 'Held DLL or its parent directories were lost.'
                Assert-True ((File-Id $tree) -ceq $treeId -and (File-Id $parent) -ceq $parentId -and (File-Id $source) -ceq $script:Evidence.sourceId) 'Rejected rename changed original identities.'
                Assert-True ([IO.File]::GetAttributes($source) -eq $sourceAttributes -and @(Payloads).Count -eq 0) 'Rejected rename changed attributes or left a payload.'
                $manifests = @(Manifests)
                Assert-True ($manifests.Count -eq 1) 'Rejected rename must preserve its persisted move intent.'
                $intent = [IO.File]::ReadAllText($manifests[0].FullName) | ConvertFrom-Json
                Assert-True ($intent.schema -eq 4 -and $intent.entries[0].identity.fileId -ceq $treeId.Substring(16)) 'Rejected rename intent identity differs.'
            } else {
                $script:Evidence.renameOutcome = 'moved'
                Assert-True (![IO.Directory]::Exists($tree)) 'Successful rename retained original tree.'
                Assert-MovePayload $hash $treeId 'nested\fixture.dll'
                $payload = $script:Evidence.move.path
                Assert-True ((File-Id (Join-Path $payload 'nested')) -ceq $parentId -and [IO.File]::GetAttributes((Join-Path $payload 'nested\fixture.dll')) -eq $sourceAttributes) 'Moved DLL parent identity or attributes changed.'
                # 復元もフォルダーrename。ロード状態を維持したまま同一実体で往復する。
                $restored = Invoke-Cli @('restore', $result.Json.operationId) {} 25
                Assert-True ($restored.ExitCode -eq 0 -and ![IO.Directory]::Exists($payload)) 'Restore failed or did not consume payload.'
                Assert-True ((File-Id $tree) -ceq $treeId -and (File-Id $parent) -ceq $parentId -and (File-Id $source) -ceq $script:Evidence.sourceId -and (Digest $source) -ceq $hash -and [IO.File]::GetAttributes($source) -eq $sourceAttributes) 'DLL restore changed identity, bytes or attributes.'
            }
        } finally {
            if ($script:Module -ne [IntPtr]::Zero) {
                $released = [PrunletTransientLockFixture]::FreeLibrary($script:Module); $script:Module = [IntPtr]::Zero
                Assert-True $released 'Final FreeLibrary failed.'
            }
        }
    }
}
Test-Case 'readonly-deletes-and-restores-with-original-attributes' {
    $source = Join-Path $script:CaseRoot 'readonly.txt'; [IO.File]::WriteAllText($source, 'readonly fixture')
    [IO.File]::SetAttributes($source, [IO.FileAttributes]::ReadOnly)
    $hash = Digest $source; $script:Evidence.sourceId = File-Id $source; $script:Evidence.sourceSha256 = $hash
    $script:Evidence.sourceAttributes = [int][IO.File]::GetAttributes($source)
    $result = Invoke-Cli @('delete', '--', $source) {} 15
    $script:Evidence.cliMilliseconds = $result.Milliseconds
    Assert-True ($result.ExitCode -eq 0 -and @($result.Json.items).Count -eq 1 -and $result.Json.items[0].status -eq 'deleted' -and $result.Json.items[0].path -ceq $source -and ![IO.File]::Exists($source)) 'Read-only deletion did not report the expected deleted item.'
    Assert-MovePayload $hash
    $script:Evidence.payloadAttributes = [int][IO.File]::GetAttributes($script:Evidence.move.path)
    Assert-True ($script:Evidence.payloadAttributes -eq $script:Evidence.sourceAttributes) 'Read-only move changed original attributes.'
    $manifests = @(Manifests)
    $deleteResults = @(Get-ChildItem -LiteralPath $script:Recovery -Filter delete-result.json -Recurse -File)
    Assert-True ($manifests.Count -eq 1 -and $deleteResults.Count -eq 1 -and $manifests[0].DirectoryName -ceq $deleteResults[0].DirectoryName) 'Expected one manifest and one result in the same operation directory.'
    $persistedResult = [IO.File]::ReadAllText($deleteResults[0].FullName) | ConvertFrom-Json
    Assert-True (@($persistedResult.items).Count -eq 1 -and $persistedResult.items[0].status -eq 'deleted' -and $persistedResult.items[0].path -ceq $source) 'Persisted read-only result does not contain the expected deleted item.'
    # CLI起動時間を除く。25ms間隔の観測では即時完了を取り逃がすため、永続化した両記録の時刻を使う。
    $manifestWrittenUtc = $manifests[0].LastWriteTimeUtc
    $resultWrittenUtc = $deleteResults[0].LastWriteTimeUtc
    $phaseMilliseconds = ($resultWrittenUtc - $manifestWrittenUtc).TotalMilliseconds
    $script:Evidence.deletionPhaseTiming = @{ source = 'persisted-metadata-last-write-utc'; manifestWrittenUtc = $manifestWrittenUtc.ToString('O'); resultWrittenUtc = $resultWrittenUtc.ToString('O'); milliseconds = $phaseMilliseconds }
    Assert-True ($phaseMilliseconds -ge 0 -and $phaseMilliseconds -lt 5000) 'Read-only deletion should complete without transient retries; metadata interval must be nonnegative and below 5000ms.'
    $restored = Invoke-Cli @('restore', $result.Json.operationId) {} 15
    $script:Evidence.restoredAttributes = [int][IO.File]::GetAttributes($source)
    $script:Evidence.restoredId = File-Id $source
    $script:Evidence.payloadExistsAfterRestore = Test-Path -LiteralPath $script:Evidence.move.path
    Assert-True ($restored.ExitCode -eq 0 -and [IO.File]::Exists($source) -and (File-Id $source) -ceq $script:Evidence.sourceId -and (Digest $source) -ceq $hash -and [IO.File]::GetAttributes($source) -eq [IO.FileAttributes]::ReadOnly -and !(Test-Path -LiteralPath $script:Evidence.move.path)) 'Read-only restore changed identity, content or attributes, or retained payload.'
}
$passed = @($results | Where-Object passed).Count; $failed = $results.Count - $passed
Save-Json $report @{ purpose = 'post-fix-transient-lock-e2e'; executable = $ExecutablePath; executableSha256 = $binaryHash; outputDirectory = $outputRoot; passed = $passed; failed = $failed; cases = @($results); commands = @($commands) }
Write-Output $report
Write-Output "passed=$passed failed=$failed"
if ($failed) { exit 1 }
