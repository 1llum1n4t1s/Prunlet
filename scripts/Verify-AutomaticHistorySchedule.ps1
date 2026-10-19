[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'All paths must be absolute.' }
}
function Assert-CmdPath([string]$Path) {
    if ($Path -cnotmatch '^[A-Za-z]:\\[A-Za-z0-9 _.:\\-]+$') { throw "Scheduled verification requires an ASCII CMD-safe absolute path: $Path" }
}
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath)) { Assert-CmdPath $path }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$report = [IO.Path]::GetFullPath($ReportPath)
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach ($destination in @($outputRoot, $report)) {
    Assert-VerificationDestination $destination @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
}
foreach ($destination in @($outputRoot, $report)) { if ([IO.Path]::GetPathRoot($destination) -ine 'D:\') { throw 'Verification outputs must use the D drive.' } }
if (![IO.File]::Exists($ExecutablePath)) { throw 'Executable not found.' }
if ((Test-Path -LiteralPath $outputRoot) -or (Test-Path -LiteralPath $report)) { throw 'OutputDirectory and ReportPath must be new.' }
if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($report))) { throw 'Create the report parent first.' }
$null = [IO.Directory]::CreateDirectory($outputRoot)
$null = [IO.Directory]::CreateDirectory((Join-Path $outputRoot 'temp'))
$results = [Collections.Generic.List[object]]::new()
$commands = [Collections.Generic.List[object]]::new()
$script:CaseRoot = $null; $script:Config = $null; $script:Recovery = $null

# 実装前に列挙した失敗: dry-runの変更、論理量と割当量の混同、hash/schema/IDの変更、
# 非NTFS・未対応圧縮、ReadOnly/暗号化/sparse/未知属性、ADS/hardlink/reparse、破損JSON、
# 不正intent/outcome、未知member・payload・未完履歴、lock競合・処理中の名前差替え、FSCTL失敗。
# このE2EはNTFS上で実行する。非NTFS/EFS/FSCTL失敗の注入は行わない。
function Assert-True([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Digest([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
    finally { $stream.Dispose() }
}
function Save-Json([string]$Path, [object]$Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 50), [Text.UTF8Encoding]::new($false)) }
function Start-Cli([string[]]$Arguments, [switch]$Mcp) {
    $values = @('--config', $script:Config) + $Arguments
    foreach ($value in @($ExecutablePath) + $values) { if ($value -match '["%&|<>^!\r\n]') { throw 'Unsafe CMD argument.' } }
    $info = [Diagnostics.ProcessStartInfo]::new('cmd.exe')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.RedirectStandardInput = [bool]$Mcp
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $info.Arguments = '/d /s /c ""' + $ExecutablePath + '" ' + (($values | ForEach-Object { '"' + $_ + '"' }) -join ' ') + '"'
    $info.Environment['TEMP'] = Join-Path $outputRoot 'temp'; $info.Environment['TMP'] = Join-Path $outputRoot 'temp'
    $info.Environment['UseSharedCompilation'] = 'false'; $info.Environment['MSBUILDDISABLENODEREUSE'] = '1'
    $info.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = Join-Path $outputRoot 'runtime-cache'
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $null = $process.Start()
    if ($Mcp) { return @{ Process = $process; Stderr = $process.StandardError.ReadToEndAsync() } }
    return @{ Process = $process; Stdout = $process.StandardOutput.ReadToEndAsync(); Stderr = $process.StandardError.ReadToEndAsync(); Arguments = $Arguments }
}
function Finish-Cli($Running) {
    $process = $Running.Process
    try {
        if (!$process.WaitForExit(75000)) { $process.Kill($true); $process.WaitForExit(); throw 'CLI timed out.' }
        $raw = $Running.Stdout.GetAwaiter().GetResult(); $errorText = $Running.Stderr.GetAwaiter().GetResult()
        $json = if ($raw.Trim()) { $raw | ConvertFrom-Json -Depth 50 } else { $null }
        $commands.Add(@{ case = [IO.Path]::GetFileName($script:CaseRoot); arguments = $Running.Arguments; exitCode = $process.ExitCode; response = $json; stderr = $errorText })
        return @{ ExitCode = $process.ExitCode; Json = $json }
    } finally { $process.Dispose() }
}
function Invoke-Cli([string[]]$Arguments) { Finish-Cli (Start-Cli $Arguments) }
function New-Case([string]$Name) {
    $script:CaseRoot = Join-Path $outputRoot $Name
    $script:Recovery = Join-Path $script:CaseRoot 'recovery'
    $script:Config = Join-Path $script:CaseRoot 'config.json'
    $null = [IO.Directory]::CreateDirectory($script:Recovery)
    Assert-True ((Invoke-Cli @('init', '--backup-directory', $script:Recovery)).ExitCode -eq 0) 'Initialization failed.'
}
function New-History([int]$Schema = 1, [int]$WarningCount = 1, [switch]$Live) {
    $source = Join-Path $script:CaseRoot 'source.txt'
    [IO.File]::WriteAllText($source, ('history-source' * 100), [Text.UTF8Encoding]::new($false))
    if ($Schema -eq 2) {
        $directory = Join-Path $script:CaseRoot 'source-directory'
        $null = [IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllText((Join-Path $directory 'child.txt'), 'directory history')
        $source = $directory
    }
    if ($Schema -eq 3) { [IO.File]::WriteAllText(($source + ':history-stream'), 'stream history') }
    $arguments = @('delete'); if ($Schema -eq 2) { $arguments += '--recursive' }; $arguments += @('--', $source)
    $deleted = Invoke-Cli $arguments
    Assert-True ($deleted.ExitCode -eq 0) 'Fixture delete failed.'
    $operation = Join-Path $script:Recovery $deleted.Json.operationId
    $manifest = [IO.File]::ReadAllText((Join-Path $operation 'manifest.json')) | ConvertFrom-Json
    Assert-True ($manifest.schema -eq $Schema) 'Fixture schema differs.'
    if (!$Live) {
        $purged = Invoke-Cli @('purge', $deleted.Json.operationId, '--apply')
        Assert-True ($purged.ExitCode -eq 0) 'Fixture purge failed.'
        $deleteResultPath = Join-Path $operation 'delete-result.json'
        $deleteResult = [IO.File]::ReadAllText($deleteResultPath) | ConvertFrom-Json
        # 1値の上限以内で実際の大きい履歴を再現する。manifestやintentのdigestは変更しない。
        $deleteResult.warnings = @((1..$WarningCount) | ForEach-Object { 'history warning ' * 32768 })
        Save-Json $deleteResultPath $deleteResult
    }
    return @{ Id = $deleted.Json.operationId; Directory = $operation; Source = $source }
}
function Snapshot([string]$Root) {
    (@(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + $_.Length + ':' + [int]$_.Attributes + ':' + (Digest $_.FullName) }) -join '|')
}
# 実装前に列挙した失敗: 登録権限不足、時刻トリガー不発火、CLI引数/環境変数の誤り、
# タスク終了コードと実行時刻の不一致、圧縮せず成功扱い、JSON/SHA変更、物理削減なし、
# 同名タスクとの衝突、所有確認なしの解除、失敗時のタスク解除漏れ。
# 手動Start-ScheduledTaskは使わず、隔離した一回限りの時刻トリガーで確認する。
$taskName = 'Prunlet-AutomaticHistory-E2E-' + [guid]::NewGuid().ToString('N')
$taskDescription = 'Prunlet automatic history E2E owner ' + [guid]::NewGuid().ToString('N')
$registered = $false
$casePassed = $false
$caseError = $null
$cleanup = @{ attempted = $false; removed = $false; error = $null }
$evidence = @{ taskName = $taskName; taskPath = '\'; description = $taskDescription }
$taskArguments = $null
$commandInterpreter = Join-Path $env:SystemRoot 'System32\cmd.exe'
try {
    Assert-CmdPath $commandInterpreter
    New-Case 'scheduled-maintain'
    $history = New-History
    $hashes = @{}
    foreach ($file in Get-ChildItem -LiteralPath $history.Directory -File) { $hashes[$file.Name] = Digest $file.FullName }
    $before = Snapshot $history.Directory
    $inspection = Invoke-Cli @('compact-history', '--dry-run')
    Assert-True ($inspection.ExitCode -eq 0 -and $inspection.Json.operations[0].status -eq 'eligible') 'Legacy fixture is not eligible.'
    $physicalBefore = 0L
    foreach ($file in $inspection.Json.operations[0].files) { $physicalBefore += $file.physicalBytesBefore }
    Assert-True ((Snapshot $history.Directory) -ceq $before) 'Preparation dry-run changed history.'
    Assert-True (@(Get-ChildItem -LiteralPath $history.Directory -File | Where-Object { $_.Attributes -band [IO.FileAttributes]::Compressed }).Count -eq 0) 'Fixture is already compressed.'
    $stdoutPath = Join-Path $outputRoot 'scheduled-stdout.json'
    $stderrPath = Join-Path $outputRoot 'scheduled-stderr.txt'
    $tempPath = Join-Path $outputRoot 'temp'
    $runtimePath = Join-Path $outputRoot 'runtime-cache'
    foreach ($path in @($script:Config, $stdoutPath, $stderrPath, $tempPath, $runtimePath)) { Assert-CmdPath $path }
    $command = 'set "TEMP=' + $tempPath + '" && set "TMP=' + $tempPath + '" && set "DOTNET_BUNDLE_EXTRACT_BASE_DIR=' + $runtimePath + '" && set "UseSharedCompilation=false" && set "MSBUILDDISABLENODEREUSE=1" && "' + $ExecutablePath + '" --config "' + $script:Config + '" maintain --apply > "' + $stdoutPath + '" 2> "' + $stderrPath + '"'
    $taskArguments = '/d /s /c "' + $command + '"'
    $action = New-ScheduledTaskAction -Execute $commandInterpreter -Argument $taskArguments -WorkingDirectory $outputRoot
    $triggerAt = (Get-Date).AddSeconds(40)
    $trigger = New-ScheduledTaskTrigger -Once -At $triggerAt
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    # GUID名に対しても、既存がないことを確認し、-Forceによる上書きを行わない。
    Assert-True (@(Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue).Count -eq 0) 'Temporary task name already exists.'
    $null = Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $taskDescription
    $registered = $true
    $evidence.triggerAt = $triggerAt.ToString('O')
    $evidence.user = $identity
    $evidence.execute = $commandInterpreter
    $evidence.arguments = $taskArguments
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $info = $null
    while ($watch.Elapsed.TotalSeconds -lt 180) {
        $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath '\'
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\'
        if ($info.LastRunTime -ge $triggerAt.AddSeconds(-2) -and $task.State -ne 'Running' -and [IO.File]::Exists($stdoutPath)) { break }
        Start-Sleep -Seconds 2
    }
    $evidence.waitSeconds = $watch.Elapsed.TotalSeconds
    $evidence.lastRunTime = $info.LastRunTime.ToString('O')
    $evidence.lastTaskResult = $info.LastTaskResult
    Assert-True ($info.LastRunTime -ge $triggerAt.AddSeconds(-2)) 'The actual time trigger did not run within 180 seconds.'
    Assert-True ($task.State -ne 'Running' -and $info.LastTaskResult -eq 0) "Scheduled task failed or is still running: $($info.LastTaskResult)"
    Assert-True ([IO.File]::Exists($stdoutPath)) 'Scheduled task did not write stdout.'
    $response = [IO.File]::ReadAllText($stdoutPath) | ConvertFrom-Json -Depth 50
    $operations = @($response.historyCompaction.operations | Where-Object operationId -eq $history.Id)
    Assert-True ($operations.Count -eq 1 -and $operations[0].status -eq 'compacted') 'Scheduled maintain did not compact fixture history.'
    Assert-True (@($operations[0].files).Count -eq @($inspection.Json.operations[0].files).Count) 'Scheduled result did not account for every metadata file.'
    $physicalAfter = 0L
    foreach ($file in $operations[0].files) {
        Assert-True ($file.sha256 -ceq $hashes[$file.name] -and (Digest (Join-Path $history.Directory $file.name)) -ceq $hashes[$file.name]) 'Scheduled compression changed metadata SHA-256.'
        Assert-True ($null -ne $file.physicalBytesAfter -and $file.savedBytes -eq ($file.physicalBytesBefore - $file.physicalBytesAfter)) 'Physical byte accounting differs.'
        Assert-True (((Get-Item -LiteralPath (Join-Path $history.Directory $file.name)).Attributes -band [IO.FileAttributes]::Compressed) -ne 0) 'Scheduled metadata is not compressed.'
        $physicalAfter += $file.physicalBytesAfter
    }
    foreach ($name in $hashes.Keys) { Assert-True ((Digest (Join-Path $history.Directory $name)) -ceq $hashes[$name]) 'History member content changed.' }
    Assert-True ($physicalBefore - $physicalAfter -gt 400000) 'Scheduled maintenance did not measurably reduce physical allocation.'
    $evidence.historyId = $history.Id
    $evidence.physicalBytesBefore = $physicalBefore
    $evidence.physicalBytesAfter = $physicalAfter
    $evidence.savedBytes = $physicalBefore - $physicalAfter
    $evidence.response = $response
    $casePassed = $true
} catch {
    $caseError = $_.Exception.Message
    Write-Output "FAIL scheduled-maintain: $caseError"
} finally {
    if ($registered) {
        $cleanup.attempted = $true
        try {
            $owned = Get-ScheduledTask -TaskName $taskName -TaskPath '\'
            Assert-True ($owned.Description -ceq $taskDescription -and @($owned.Actions).Count -eq 1 -and $owned.Actions[0].Execute -ceq $commandInterpreter -and $owned.Actions[0].Arguments -ceq $taskArguments -and $owned.Actions[0].WorkingDirectory -ceq $outputRoot) 'Temporary task ownership changed; refusing to unregister.'
            Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
            Assert-True (@(Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue).Count -eq 0) 'Temporary task remains registered.'
            $cleanup.removed = $true
        } catch {
            $cleanup.error = $_.Exception.Message
            $casePassed = $false
            $caseError = (@($caseError, ('Task cleanup failed: ' + $_.Exception.Message)) | Where-Object { $_ }) -join '; '
            Write-Output "FAIL temporary-task-cleanup: $($_.Exception.Message)"
        }
    }
}
$results.Add(@{ name = 'actual-time-trigger-maintain'; passed = $casePassed; error = $caseError })
$passed = if ($casePassed) { 1 } else { 0 }; $failed = 1 - $passed
Save-Json $report @{ executable = $ExecutablePath; executableSha256 = (Digest $ExecutablePath); outputDirectory = $outputRoot; passed = $passed; failed = $failed; cases = @($results); commands = @($commands); schedule = $evidence; cleanup = $cleanup }
if ($casePassed) { Write-Output 'PASS scheduled-maintain' }
Write-Output $report
Write-Output "passed=$passed failed=$failed"
if ($failed) { exit 1 }