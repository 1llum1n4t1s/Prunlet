[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$LegacyExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
foreach ($path in @($ExecutablePath, $LegacyExecutablePath, $OutputDirectory, $ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'All paths must be absolute.' }
}
function Assert-CmdPath([string]$Path) {
    if ($Path -cnotmatch '^[A-Za-z]:\\[A-Za-z0-9 _.:\\-]+$') { throw "Scheduled verification requires an ASCII CMD-safe absolute path: $Path" }
}
foreach ($path in @($ExecutablePath, $LegacyExecutablePath, $OutputDirectory, $ReportPath)) { Assert-CmdPath $path }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$report = [IO.Path]::GetFullPath($ReportPath)
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach ($destination in @($outputRoot, $report)) {
    Assert-VerificationDestination $destination @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
}
foreach ($destination in @($outputRoot, $report)) { if ([IO.Path]::GetPathRoot($destination) -ine 'D:\') { throw 'Verification outputs must use the D drive.' } }
if (![IO.File]::Exists($ExecutablePath)) { throw 'Executable not found.' }
if (![IO.File]::Exists($LegacyExecutablePath)) { throw 'Legacy fixture producer not found.' }
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
$script:CliEnvironment = @{
    TEMP = Join-Path $outputRoot 'temp'
    TMP = Join-Path $outputRoot 'temp'
    UseSharedCompilation = 'false'
    MSBUILDDISABLENODEREUSE = '1'
    DOTNET_BUNDLE_EXTRACT_BASE_DIR = Join-Path $outputRoot 'runtime-cache'
}
. (Join-Path $PSScriptRoot 'HistoryVerification-Common.ps1')
# 実装前に列挙した失敗: 登録権限不足、時刻トリガー不発火、CLI引数/環境変数の誤り、
# タスク終了コードと実行時刻の不一致、終端整理せず成功扱い、原データ再作成、記録容量の回収なし、
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
    $before = Snapshot $history.Directory
    $inspection = Invoke-Cli @('compact-history', '--dry-run')
    Assert-True ($inspection.ExitCode -eq 0 -and $inspection.Json.operations[0].status -eq 'eligible') 'Legacy fixture is not eligible.'
    $metadataBytesBefore = (Get-ChildItem -LiteralPath $history.Directory -File | Measure-Object Length -Sum).Sum
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
    Assert-VerificationClosedRecord $script:Recovery $history.Id 1
    Assert-True (!(Test-Path -LiteralPath $history.Source)) 'Scheduled retirement recreated the purged original.'
    $closedFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:Recovery '.closed-records-v1') -File | Where-Object Name -Like ($history.Id + '.*.json'))
    $summaryFile = Get-Item -LiteralPath (Join-Path (Join-Path $script:Recovery '.closed-records-v1') ($history.Id + '.json'))
    $metadataBytesAfter = $summaryFile.Length + ($closedFiles | Measure-Object Length -Sum).Sum
    Assert-True ($metadataBytesBefore - $metadataBytesAfter -gt 400000) 'Scheduled retirement did not reclaim the large active audit metadata.'
    $closedBefore = Snapshot $script:Recovery
    $again = Invoke-Cli @('maintain', '--apply')
    Assert-True ($again.ExitCode -eq 0 -and (Snapshot $script:Recovery) -ceq $closedBefore -and !(Test-Path -LiteralPath $history.Source)) 'Repeated scheduled-result maintenance changed terminal records or original data.'
    Assert-VerificationClosedRecord $script:Recovery $history.Id 1
    $evidence.historyId = $history.Id
    $evidence.metadataBytesBefore = $metadataBytesBefore
    $evidence.metadataBytesAfter = $metadataBytesAfter
    $evidence.metadataBytesReclaimed = $metadataBytesBefore - $metadataBytesAfter
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
Save-Json $report @{ executable = $ExecutablePath; executableSha256 = (Digest $ExecutablePath); legacyExecutable = $LegacyExecutablePath; legacyExecutableSha256 = (Digest $LegacyExecutablePath); outputDirectory = $outputRoot; passed = $passed; failed = $failed; cases = @($results); commands = @($commands); schedule = $evidence; cleanup = $cleanup }
if ($casePassed) { Write-Output 'PASS scheduled-maintain' }
Write-Output $report
Write-Output "passed=$passed failed=$failed"
if ($failed) { exit 1 }
