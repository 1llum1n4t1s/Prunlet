[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][Alias('BaselineMoveExecutablePath')][string]$MoveExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [switch]$PauseForWindowInspection
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
# 想定する失敗: PE種別の誤り、GUIからの通常削除、shell解釈、所有外タスクの変更、
# 移行時の設定消失、保守の未実行、通常保守によるゴミ箱内の検証物変更、終了コードの欠落、fixture外への書込み。
$utf8 = [Text.UTF8Encoding]::new($false)
$results = [Collections.Generic.List[object]]::new()
$states = [Collections.Generic.List[object]]::new()
$taskExitCodes = [ordered]@{}
$invocation = 0
$fixtureEvidence = [ordered]@{}
$script:observed = @{}
$oldTemp = $env:TEMP; $oldTmp = $env:TMP
function Assert-True([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Save-Json([string]$Path, $Value) { [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 80), $utf8) }
function Read-Json([string]$Path) { [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -Depth 80 }
function Digest([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Get-MaintenanceFileProof([string]$Path) {
    Assert-NoReparse $Path
    $nodes=[Prunlet.RecordlessE2E.FixtureNative]::SnapshotTree($Path)
    Assert-True ($nodes.Count-eq1-and!$nodes[0].Directory) 'Maintenance native proof expects one ordinary file'
    $node=$nodes[0]
    return [ordered]@{id=$node.Id;nativeOgd=$node.SecurityBase64;attributes=$node.Attributes;streams=@($node.Streams|ForEach-Object {[ordered]@{name=$_.Name;length=$_.Length;sha256=$_.Sha256}})}
}
function Assert-MaintenanceFileProof([string]$Path, $Expected) {
    $actual = Get-MaintenanceFileProof $Path
    Assert-True (($actual | ConvertTo-Json -Depth 10 -Compress) -ceq ($Expected | ConvertTo-Json -Depth 10 -Compress)) "Native file identity/streams/O/G/D/attributes changed: $Path"
    return $actual
}
function Assert-NoReparse([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            Assert-True (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Reparse path refused: $cursor"
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}
function Run-Case([string]$Name, [scriptblock]$Body) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try { & $Body; $results.Add(@{ name = $Name; passed = $true; milliseconds = $timer.ElapsedMilliseconds }) }
    catch { $results.Add(@{ name = $Name; passed = $false; error = $_.Exception.Message; milliseconds = $timer.ElapsedMilliseconds }); throw }
}
function Invoke-Binary([string]$Binary, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($Binary)
    $info.CreateNoWindow = $true
    $info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true; $info.WorkingDirectory = $OutputDirectory
    $info.Environment['TEMP'] = $env:TEMP; $info.Environment['TMP'] = $env:TMP
    if (($Arguments -contains 'delete' -or $Arguments -contains 'migrate') -and ($Binary -ceq $ExecutablePath -or $Binary -ceq $MoveExecutablePath)) {
        foreach($value in @($Binary)+$Arguments){Assert-True ($value-notmatch'["%!^\r\n]') 'Unsafe CMD deletion argument'}
        $info.FileName='cmd.exe';$info.Arguments='/d /s /c ""'+$Binary+'" '+(($Arguments|ForEach-Object {'"'+$_+'"'})-join' ')+'"'
    } else { foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) } }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    try {
        $null = $process.Start(); $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(180000)) { $process.Kill($true); $process.WaitForExit(); throw 'Process timeout.' }
        $out = $stdout.GetAwaiter().GetResult(); $err = $stderr.GetAwaiter().GetResult()
        $script:invocation++
        $result = @{ binary = $Binary; arguments = $Arguments; pid = $process.Id; exitCode = $process.ExitCode; stdout = $out; stderr = $err }
        Save-Json (Join-Path $OutputDirectory ('process-{0:D3}.json' -f $script:invocation)) $result
        return $result
    } finally { $process.Dispose() }
}
function Invoke-Cli([string[]]$Arguments) { Invoke-Binary $ExecutablePath (@('--config', $config) + $Arguments) }
function Get-Subsystem([string]$Path) {
    $stream = [IO.File]::OpenRead($Path); $reader = [IO.BinaryReader]::new($stream)
    try {
        Assert-True ($reader.ReadUInt16() -eq 0x5a4d) 'Missing DOS header.'
        $stream.Position = 0x3c; $offset = $reader.ReadInt32(); $stream.Position = $offset
        Assert-True ($reader.ReadUInt32() -eq 0x4550) 'Missing PE header.'
        $stream.Position = $offset + 24 + 68; return $reader.ReadUInt16()
    } finally { $reader.Dispose(); $stream.Dispose() }
}
function New-Operation([string]$Name, [string]$Content, [switch]$LegacyMove) {
    $path = Join-Path $fixture $Name; [IO.File]::WriteAllText($path, $Content, $utf8)
    $originalProof = Get-MaintenanceFileProof $path
    $recordlessBefore=[Prunlet.RecordlessE2E.FixtureNative]::SnapshotTree($path)
    $prior=[string[]]@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($recordlessBefore[0].Id)|ForEach-Object Pidl)
    # 破棄移行対象は真正な旧exeでschema 4を作る。新版の新規削除は記録なし方式。
    $generator = if ($LegacyMove) { $MoveExecutablePath } else { $ExecutablePath }
    $generatorConfig = $config
    if ($LegacyMove) {
        $legacySettings = Read-Json $config
        $null = $legacySettings.Remove('capacityDefaultMigrationVersion')
        $generatorConfig = Join-Path $fixture 'legacy-config.json'
        Save-Json $generatorConfig $legacySettings
    }
    $pathsFile=Join-Path $fixture ('paths-'+[guid]::NewGuid().ToString('N')+'.json');Save-Json $pathsFile @($path)
    $deleted = Invoke-Binary $generator @('--config', $generatorConfig, 'delete', '--paths-file', $pathsFile)
    Assert-True ($deleted.exitCode -eq 0 -and ![IO.File]::Exists($path)) "Delete failed: $($deleted.stderr)"
    $wire=$deleted.stdout|ConvertFrom-Json -AsHashtable -Depth 80
    if(!$LegacyMove){
        Assert-True (!$wire.ContainsKey('operationId')-and$wire.items[0].status-ceq'recycled') 'Current file deletion requires no Prunlet operation record'
        $item=[Prunlet.RecordlessE2E.OwnedBinLocator]::FindNew($recordlessBefore[0].Id,$prior)
        return @{source=$path;content=$Content;payload=$item.PhysicalPath;binItem=$item;originalProof=$originalProof;recordlessBefore=$recordlessBefore;payloadProof=(Get-MaintenanceFileProof $item.PhysicalPath)}
    }
    $id=$wire.operationId
    $root = Resolve-VerificationOperationDirectory $metadata $id
    $manifestPath = Join-Path $root ($(if ($LegacyMove) { 'move-manifest.json' } else { 'recycle-manifest.json' }))
    $manifest = Read-Json $manifestPath
    Assert-True ($manifest.schema -eq $(if ($LegacyMove) { 4 } else { 6 }) -and $manifest.entries.Count -eq 1) 'Unexpected recovery schema or entry count.'
    $entry = $manifest.entries[0]
    if ($LegacyMove) {
        $payload = Join-Path (Join-Path $entry.storeRoot $id) $entry.payloadName
        Assert-True ($payload.StartsWith($store + '\', [StringComparison]::OrdinalIgnoreCase) -and [IO.File]::Exists($payload)) 'Legacy payload escaped fixture or is missing.'
    }
    $payloadProof = Get-MaintenanceFileProof $payload
    Assert-True ($originalProof.id -ceq $payloadProof.id -and ($originalProof.streams | ConvertTo-Json -Depth 5 -Compress) -ceq ($payloadProof.streams | ConvertTo-Json -Depth 5 -Compress)) 'Fixture generation changed native identity or stream bytes.'
    return @{ id = $id; root = $root; manifestPath = $manifestPath; payload = $payload; source = $path; content = $Content; originalProof = $originalProof; payloadProof = $payloadProof; rawRootId = [Prunlet.RecordlessE2E.FixtureNative]::Identity($root); storeRoot = $entry.storeRoot }
}
function Restore-WindowsTaskFixture($Operation){$item=$Operation.binItem;$null=[Prunlet.RecordlessE2E.FixtureNative]::RestoreOwned($item.Pidl,$item.PhysicalPath,$item.NativeId,$Operation.source,$fixture);return ,(Assert-SnapshotR $Operation.source $Operation.recordlessBefore -WindowsSecurity)}
function Assert-LegacyTaskDiscard(){
    $proofs = foreach($discarded in $script:LegacyDiscardedRoots){
        $now=[Prunlet.RecordlessE2E.FixtureNative]::SnapshotTree($discarded.item.PhysicalPath)
        Assert-True (($now|ConvertTo-Json -Depth 30 -Compress)-ceq($discarded.proof|ConvertTo-Json -Depth 30 -Compress)) 'Registry-only task changed an owned discarded legacy root in Windows Bin'
        @{path=$discarded.path;item=$discarded.item;proof=$now}
    }
    return ,@($proofs)
}
function Export-FixtureTask($State) { Export-ScheduledTask -TaskPath '\' -TaskName $State.name -ErrorAction Stop }
function Set-FixtureSetting([xml]$Document, [string]$Name, [string]$Value) {
    $namespace = [Xml.XmlNamespaceManager]::new($Document.NameTable)
    $namespace.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
    $settings = $Document.SelectSingleNode('/t:Task/t:Settings', $namespace)
    Assert-True ($null -ne $settings) 'Fixture task has no Settings element.'
    $element = $settings.SelectSingleNode(('t:' + $Name), $namespace)
    if (!$element) {
        # TaskSchedulerは既定値の要素を省略するため、欠損時だけ同じ名前空間で補う。
        $element = $Document.CreateElement($Name, $settings.NamespaceURI)
        $null = $settings.AppendChild($element)
    }
    $element.InnerText = $Value
}
function Set-FixtureTask($State, [xml]$Document) {
    Assert-PrunletMaintenanceOwned $State $Document.OuterXml
    Register-ScheduledTask -TaskPath '\' -TaskName $State.name -Xml $Document.OuterXml -Force -ErrorAction Stop | Out-Null
}
function Wait-TaskFinished($State, [datetime]$PreviousRun) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $task = Get-ScheduledTask -TaskPath '\' -TaskName $State.name -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskPath '\' -TaskName $State.name -ErrorAction Stop
        if ($task.State -notin @('Running', 'Queued') -and $info.LastRunTime -gt $PreviousRun) { return [long]$info.LastTaskResult }
        Start-Sleep -Milliseconds 200
    } while ($timer.Elapsed.TotalSeconds -lt 180)
    throw "Task did not finish: $($State.name)"
}
function Run-LockedTask($State, [string]$Phase, [string]$Command) {
    Assert-PrunletMaintenanceOwned $State (Export-FixtureTask $State)
    $lock = [IO.File]::Open((Join-Path $metadata 'maintenance.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $previous = (Get-ScheduledTaskInfo -TaskName $State.name -TaskPath '\').LastRunTime
    try {
        Start-ScheduledTask -TaskPath '\' -TaskName $State.name -ErrorAction Stop
        $timer = [Diagnostics.Stopwatch]::StartNew(); $observed = @()
        do {
            $observed = @(Get-CimInstance Win32_Process -Filter "Name = '$([IO.Path]::GetFileName($Command))'" | Where-Object {
                $_.ExecutablePath -ceq $Command -and $_.CommandLine -and $_.CommandLine.Contains($config)
            })
            if ($observed.Count) { break }
            Start-Sleep -Milliseconds 200
        } while ($timer.Elapsed.TotalSeconds -lt 30)
        Assert-True ($observed.Count -eq 1) "Expected one waiting task process: $Phase"
        $evidence = @{ phase = $Phase; pid = [int]$observed[0].ProcessId; taskName = $State.name; command = $Command; arguments = $State.arguments; inspectionRequested = [bool]$PauseForWindowInspection }
        Save-Json (Join-Path $OutputDirectory ($Phase + '.json')) $evidence
        Write-Host ("Inspection phase {0}: PID {1}, task {2}" -f $Phase, $evidence.pid, $State.name)
        if ($PauseForWindowInspection) {
            $signal = Join-Path $OutputDirectory ('continue-' + $Phase + '.signal'); $timer.Restart()
            while (![IO.File]::Exists($signal) -and $timer.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 200 }
            Assert-True ([IO.File]::Exists($signal)) "Window inspection signal timed out: $signal"
        } else { Start-Sleep -Seconds 1 }
        Assert-True ((Get-ScheduledTask -TaskName $State.name -TaskPath '\').State -eq 'Running') 'Task did not remain blocked on maintenance lock.'
        Assert-True ($null -ne (Get-Process -Id $evidence.pid -ErrorAction SilentlyContinue)) 'Observed task process exited before lock release.'
    } finally { $lock.Dispose() }
    $code = Wait-TaskFinished $State $previous; $taskExitCodes[$Phase] = $code
    Assert-True ($code -eq 0) "Task failed: $Phase ($code)"
}
$failure = $null; $prepared = $false
try {
    Assert-True ($IsWindows) 'Windows is required.'
    foreach ($path in @($ExecutablePath, $MoveExecutablePath, $OutputDirectory, $ReportPath)) { Assert-True ([IO.Path]::IsPathFullyQualified($path)) 'Absolute paths required.'; Assert-NoReparse $path }
    $MoveExecutablePath = [IO.Path]::GetFullPath($MoveExecutablePath)
    Assert-True ([IO.File]::Exists($MoveExecutablePath)) 'MoveExecutablePath must be an existing pre-migration schema 4 executable.'
    $ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath); $OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory); $ReportPath = [IO.Path]::GetFullPath($ReportPath)
    Assert-True ($OutputDirectory.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase)) 'D volume fixture required.'
    $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Assert-True ($ReportPath.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase)) 'External D volume report required.'
    foreach ($forbidden in @($repo, (Join-Path $env:USERPROFILE '.codex'))) {
        foreach ($destination in @($OutputDirectory, $ReportPath)) { Assert-True (!$destination.StartsWith($forbidden.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -and $destination -ine $forbidden) 'External output required.' }
    }
    Assert-True (!(Test-Path -LiteralPath $OutputDirectory)) 'OutputDirectory must be new.'
    Assert-True ([IO.Directory]::Exists([IO.Path]::GetDirectoryName($OutputDirectory))) 'Output parent must exist.'
    Assert-True ([IO.Directory]::Exists([IO.Path]::GetDirectoryName($ReportPath)) -or $ReportPath.StartsWith($OutputDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) 'Report parent must exist or belong to new output.'
    Assert-True (!(Test-Path -LiteralPath $ReportPath)) 'ReportPath must be new.'
    $null = [IO.Directory]::CreateDirectory($OutputDirectory)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ReportPath)); $prepared = $true
    $env:TEMP = Join-Path $OutputDirectory 'temp'; $env:TMP = $env:TEMP; $null = [IO.Directory]::CreateDirectory($env:TEMP)
    $fixture = Join-Path $OutputDirectory ('日本語 空白 & fixture-' + [guid]::NewGuid().ToString('N')); $null = [IO.Directory]::CreateDirectory($fixture)
    $config = Join-Path $fixture '設定 & config.json'; $metadata = Join-Path $fixture 'metadata'; $store = Join-Path $fixture 'volume-store'
    $null = [IO.Directory]::CreateDirectory($metadata)
    $helper = Join-Path ([IO.Path]::GetDirectoryName($ExecutablePath)) 'prunlet-maintenance.exe'
    . (Join-Path $repo 'integration/maintenance-task.ps1')
    . (Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1')
    if(!('Prunlet.RecordlessE2E.FixtureNative'-as[type])){Add-Type -Path @('NativeShellFixture.cs','FixtureNative.cs','OwnedBinLocator.cs'|ForEach-Object {Join-Path (Join-Path $PSScriptRoot 'recordless-e2e') $_}) -CompilerOptions '/unsafe'}
    Run-Case 'pe-subsystems' { Assert-True ((Get-Subsystem $ExecutablePath) -eq 3) 'CLI must use console subsystem.'; Assert-True ((Get-Subsystem $helper) -eq 2) 'Maintenance helper must use GUI subsystem.' }
    Run-Case 'cli-init-roundtrip' {
        $init = Invoke-Cli @('init', '--backup-directory', $metadata); Assert-True ($init.exitCode -eq 0) "Init failed: $($init.stderr)"
        $settings = Read-Json $config; $settings.volumeRecoveryDirectories = @{ 'D:\' = $store }; $settings.retentionDays = 30; $settings.maxRecoveryBytes = 10737418240; Save-Json $config $settings
        $script:LegacyFixture = New-Operation 'legacy-discard.txt' 'owned legacy discard content' -LegacyMove
        $legacyRoots = @($script:LegacyFixture.storeRoot, $script:LegacyFixture.root)
        $beforeRoots = @{};foreach($path in $legacyRoots){$beforeRoots[$path]=[Prunlet.RecordlessE2E.FixtureNative]::SnapshotTree($path)}
        $migration=Invoke-Cli @('migrate','--apply');$fixtureEvidence.explicitMigration=$migration
        $migrationResult=$migration.stdout|ConvertFrom-Json -AsHashtable -Depth 80
        Assert-True ($migration.exitCode-eq0-and$migrationResult.registryReady-and$migrationResult.complete) 'Initial registry readiness/legacy discard incomplete'
        $script:LegacyDiscardedRoots = foreach($path in $legacyRoots){
            $operation=@($migrationResult.operations|Where-Object path -CEQ $path)
            Assert-True ($operation.Count-eq1-and$operation[0].status-ceq'recycled'-and!$operation[0].operationId-and$null-eq$operation[0].schema-and!(Test-Path -LiteralPath $path)) 'Owned legacy storage/metadata root was not recycled'
            $item=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($beforeRoots[$path][0].Id))
            Assert-True ($item.Count-eq1) 'Discarded legacy root must have one owned Windows Bin identity'
            $proof=Assert-SnapshotR $item[0].PhysicalPath $beforeRoots[$path] -WindowsManagedBin
            @{path=$path;item=$item[0];proof=$proof}
        }
        $fixtureEvidence.legacyDiscardedRoots=$script:LegacyDiscardedRoots
        $roundtrip=New-Operation '往復 & file.txt' 'CLI roundtrip 日本語'
        $fixtureEvidence.initialWindowsRoundtrip=Restore-WindowsTaskFixture $roundtrip
    }
    Run-Case 'gui-rejects-other-commands' {
        $sentinel = Join-Path $fixture 'sentinel.txt'; [IO.File]::WriteAllText($sentinel, 'unchanged', $utf8); $before = Digest $sentinel
        $configHash = Digest $config
        foreach ($command in @('delete', 'migrate', 'registry-delete', 'mcp', 'registry-session', 'purge', 'init', 'compact-history', 'restore', 'status')) {
            $lastArgument = if ($command -in @('delete', 'restore')) { $sentinel } else { '--apply' }
            $call = Invoke-Binary $helper @('--config', $config, $command, $lastArgument)
            Assert-True ($call.exitCode -eq 2 -and (Digest $sentinel) -ceq $before -and (Digest $config) -ceq $configHash) "GUI accepted/changed data for $command"
        }
        foreach ($arguments in @(@('maintain', '--apply'), @('--config', $config, 'maintain'), @('--config', $config, 'maintain', '--apply', 'extra'))) {
            Assert-True ((Invoke-Binary $helper $arguments).exitCode -eq 2) 'GUI accepted invalid maintain arguments.'
        }
    }
    $state = Get-PrunletMaintenanceState $ExecutablePath $config
    Assert-True (!$state.previousXml) 'Unique fixture task already exists.'; $states.Add($state)
    Run-Case 'missing-helper-registration-refused' {
        $missingCli = Join-Path $fixture 'missing-binaries/prunlet.exe'; $missing = Get-PrunletMaintenanceState $missingCli $config
        Assert-True (!$missing.previousXml) 'Missing-helper fixture task already exists.'; $states.Add($missing)
        $rejected = $false; try { Register-PrunletMaintenanceTask $missing } catch { $rejected = $true }
        Assert-True ($rejected -and !(Get-PrunletMaintenanceState $missingCli $config).previousXml) 'Missing helper registered a task.'
    }
    Run-Case 'legacy-task-baseline' {
        Register-PrunletMaintenanceTask $state
        $legacy = [xml](Export-FixtureTask $state); $legacy.Task.Actions.Exec.Command = $ExecutablePath
        $legacy.Task.Triggers.CalendarTrigger.StartBoundary = [DateTime]::Today.AddHours(4.5).ToString('yyyy-MM-ddTHH:mm:ss')
        Set-FixtureSetting $legacy 'Hidden' 'false'; Set-FixtureSetting $legacy 'Enabled' 'false'; Set-FixtureTask $state $legacy
        $script:baseline = [xml](Export-FixtureTask $state)
        $enabled = [xml]$script:baseline.OuterXml; Set-FixtureSetting $enabled 'Enabled' 'true'; Set-FixtureTask $state $enabled
        Run-LockedTask $state 'legacy-console' $ExecutablePath
        $fixtureEvidence.afterInitialConsole=Assert-LegacyTaskDiscard
        Assert-True ((Read-Json $config).retentionDays-eq30) 'Initial task changed retention configuration'
        Set-FixtureTask $state $script:baseline
    }
    Run-Case 'migration-preserves-task-definition' {
        $migration = Get-PrunletMaintenanceState $ExecutablePath $config; Register-PrunletMaintenanceTask $migration
        $migrated = [xml](Export-FixtureTask $state)
        Assert-True ($migrated.Task.Actions.Exec.Command -ceq $helper) 'Migration did not use helper.'
        foreach ($section in @('Triggers', 'Principals', 'Settings')) { Assert-True ($script:baseline.Task.$section.OuterXml -ceq $migrated.Task.$section.OuterXml) "Migration changed $section" }
        $migrated.Task.Actions.Exec.Command = $ExecutablePath
        Assert-True ($migrated.OuterXml -ceq $script:baseline.OuterXml) 'Migration changed fields other than command.'
        $before = Export-FixtureTask $state; Register-PrunletMaintenanceTask (Get-PrunletMaintenanceState $ExecutablePath $config)
        Assert-True ((Export-FixtureTask $state) -ceq $before) 'GUI task registration was not idempotent.'
    }
    Run-Case 'edited-and-unowned-task-refused' {
        $owned = Export-FixtureTask $state
        foreach ($kind in @('action', 'owner')) {
            try {
                $edited = [xml]$owned
                if ($kind -eq 'action') { $edited.Task.Actions.Exec.Arguments += ' extra' } else { $edited.Task.RegistrationInfo.Description = 'Unowned fixture marker' }
                Register-ScheduledTask -TaskPath '\' -TaskName $state.name -Xml $edited.OuterXml -Force -ErrorAction Stop | Out-Null
                $actual = Export-FixtureTask $state; $rejected = $false
                try { $null = Get-PrunletMaintenanceState $ExecutablePath $config } catch { $rejected = $true }
                Assert-True ($rejected -and (Export-FixtureTask $state) -ceq $actual) "Edited $kind task was accepted or changed."
            } finally {
                # このループで直前に編集した固有fixtureだけを元へ戻す。
                Assert-True ((Export-FixtureTask $state) -ceq $actual) 'Fixture changed concurrently; refusing restoration.'
                Register-ScheduledTask -TaskPath '\' -TaskName $state.name -Xml $owned -Force -ErrorAction Stop | Out-Null
            }
        }
    }
    Run-Case 'gui-task-registry-only-maintenance-and-windows-restore' {
        $fresh=New-Operation 'fresh & file.txt' 'fresh content 日本語'
        $fixtureEvidence.beforeGuiLegacyDiscard=Assert-LegacyTaskDiscard
        $settings=Read-Json $config;Assert-True ($settings.retentionDays-eq30) 'Pre-GUI retention changed';$settings.retentionDays=7;Save-Json $config $settings
        $enabled=[xml](Export-FixtureTask $state);Set-FixtureSetting $enabled 'Enabled' 'true';Set-FixtureTask $state $enabled
        Run-LockedTask $state 'gui-maintenance' $helper
        $fixtureEvidence.afterGuiLegacyDiscard=Assert-LegacyTaskDiscard
        $fixtureEvidence.afterGuiFresh=Assert-MaintenanceFileProof $fresh.payload $fresh.payloadProof
        $fixtureEvidence.restoredFresh=Restore-WindowsTaskFixture $fresh
        Assert-True ([IO.File]::ReadAllText($fresh.source)-ceq$fresh.content-and![IO.File]::Exists($fresh.payload)) 'Windows fixture restore failed after registry-only task'
    }
    Run-Case 'gui-missing-config-exit-code' {
        $missingConfig = Join-Path $fixture ('absent-' + [guid]::NewGuid().ToString('N') + '.json')
        $missingState = Get-PrunletMaintenanceState $ExecutablePath $missingConfig; Assert-True (!$missingState.previousXml) 'Missing-config fixture already exists.'; $states.Add($missingState)
        Register-PrunletMaintenanceTask $missingState
        $previous = (Get-ScheduledTaskInfo -TaskName $missingState.name -TaskPath '\').LastRunTime
        Start-ScheduledTask -TaskName $missingState.name -TaskPath '\'
        $code = Wait-TaskFinished $missingState $previous; $taskExitCodes['missing-config'] = $code
        Assert-True ($code -eq 1 -and ![IO.File]::Exists($missingConfig)) "Missing config task exit: $code"
        Assert-True ((Invoke-Binary $helper @('--config', $missingConfig, 'maintain', '--apply')).exitCode -eq 1) 'Direct GUI missing config must exit 1.'
    }
} catch { $failure = $_.Exception.Message; Write-Warning $failure }
finally {
    foreach ($ownedState in $states) {
        try {
            $current = Get-PrunletMaintenanceState $ownedState.executable $ownedState.config
            if ($current.previousXml) {
                Assert-PrunletMaintenanceOwned $ownedState $current.previousXml
                Stop-ScheduledTask -TaskPath '\' -TaskName $ownedState.name -ErrorAction Stop
                $null = Unregister-PrunletMaintenanceTask $ownedState.executable $ownedState.config
                Assert-True (!(Get-PrunletMaintenanceState $ownedState.executable $ownedState.config).previousXml) 'Fixture task remained registered.'
            }
        } catch { $results.Add(@{ name = 'fixture-task-cleanup'; passed = $false; task = $ownedState.name; error = $_.Exception.Message }); if (!$failure) { $failure = $_.Exception.Message } }
    }
    $env:TEMP = $oldTemp; $env:TMP = $oldTmp
    if ($prepared) {
        $binaryHashes = [ordered]@{}
        foreach ($binary in @($ExecutablePath, $MoveExecutablePath, $helper)) { if ($binary -and [IO.File]::Exists($binary)) { $binaryHashes[$binary] = Digest $binary } }
        $passed = @($results | Where-Object passed).Count; $failed = @($results | Where-Object { !$_.passed }).Count
        if ($failure -and $failed -eq 0) { $failed = 1 }
        Save-Json $ReportPath @{ passed = $passed; failed = $failed; error = $failure; results = @($results.ToArray()); binarySha256 = $binaryHashes; taskExitCodes = $taskExitCodes; fixtureEvidence = $fixtureEvidence; windowInspectionRequested = [bool]$PauseForWindowInspection; unverified = @('Real Windows restart/logon', 'ARM64 execution'); retained = $OutputDirectory }
        Write-Host "passed=$passed failed=$failed report=$ReportPath"
    }
}
if ($failure) { exit 1 }
exit 0
