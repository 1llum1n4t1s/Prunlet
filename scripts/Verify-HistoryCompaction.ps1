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
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$report = [IO.Path]::GetFullPath($ReportPath)
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach ($destination in @($outputRoot, $report)) {
    Assert-VerificationDestination $destination @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
}
if (![IO.File]::Exists($ExecutablePath)) { throw 'Executable not found.' }
if ((Test-Path -LiteralPath $outputRoot) -or (Test-Path -LiteralPath $report)) { throw 'OutputDirectory and ReportPath must be new.' }
if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($report))) { throw 'Create the report parent first.' }
$null = [IO.Directory]::CreateDirectory($outputRoot)
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
function Start-Cli([string[]]$Arguments) {
    $values = @('--config', $script:Config) + $Arguments
    foreach ($value in @($ExecutablePath) + $values) { if ($value -match '["%&|<>^!\r\n]') { throw 'Unsafe CMD argument.' } }
    $info = [Diagnostics.ProcessStartInfo]::new('cmd.exe')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $info.Arguments = '/d /s /c ""' + $ExecutablePath + '" ' + (($values | ForEach-Object { '"' + $_ + '"' }) -join ' ') + '"'
    $info.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = Join-Path $outputRoot 'runtime-cache'
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $null = $process.Start()
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
function Wait-CompressionStart($Running, [string]$Directory) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (!$Running.Process.HasExited -and $watch.ElapsedMilliseconds -lt 20000) {
        # 排他writeプローブを開くとcompactorの事前固定を妨げるため、圧縮開始を属性で観測する。
        if (@(Get-ChildItem -LiteralPath $Directory -File | Where-Object { $_.Attributes -band [IO.FileAttributes]::Compressed }).Count -gt 0) { return }
        Start-Sleep -Milliseconds 2
    }
    throw 'Did not observe compression start.'
}
function Assert-Skipped($History, [string]$Before) {
    $response = Invoke-Cli @('compact-history', '--apply')
    Assert-True ($response.ExitCode -eq 0 -and @($response.Json.operations).Count -eq 1 -and $response.Json.operations[0].status -eq 'skipped' -and $response.Json.warnings.Count -gt 0) 'Unsafe operation was not skipped with a warning.'
    Assert-True ((Snapshot $History.Directory) -ceq $Before) 'Skipped operation changed.'
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { New-Case $Name; & $Body; $results.Add(@{ name = $Name; passed = $true }); Write-Output "PASS $Name" }
    catch { $results.Add(@{ name = $Name; passed = $false; error = $_.Exception.Message }); Write-Output "FAIL ${Name}: $($_.Exception.Message)" }
}

Test-Case 'empty-dry-run-no-lock-created' {
    $before = Snapshot $script:Recovery
    $response = Invoke-Cli @('compact-history')
    Assert-True ($response.ExitCode -eq 0 -and $response.Json.dryRun -and @($response.Json.operations).Count -eq 0) 'Empty dry-run failed.'
    Assert-True ((Snapshot $script:Recovery) -ceq $before) 'Dry-run created a recovery member.'
}
foreach ($schema in @(1, 2, 3)) {
    Test-Case "schema-$schema-compression-hash-idempotence-old-id" {
        $history = New-History -Schema $schema
        $before = Snapshot $history.Directory
        $dry = Invoke-Cli @('compact-history')
        $explicitDry = Invoke-Cli @('compact-history', '--dry-run')
        Assert-True ($dry.ExitCode -eq 0 -and $explicitDry.ExitCode -eq 0 -and $dry.Json.operations[0].status -eq 'eligible') 'Dry-run did not recognize valid history.'
        Assert-True ((Snapshot $history.Directory) -ceq $before) 'Dry-run changed bytes, attributes, or membership.'
        foreach ($file in $dry.Json.operations[0].files) { Assert-True ($null -eq $file.physicalBytesAfter -and $null -eq $file.savedBytes) 'Dry-run invented savings.' }
        $hashes = @{}; foreach ($file in Get-ChildItem -LiteralPath $history.Directory -File) { $hashes[$file.Name] = Digest $file.FullName }
        $applied = Invoke-Cli @('compact-history', '--apply')
        Assert-True ($applied.ExitCode -eq 0 -and $applied.Json.operations[0].status -eq 'compacted') 'Compression failed.'
        $saved = 0L
        foreach ($file in $applied.Json.operations[0].files) {
            Assert-True ($file.sha256 -ceq $hashes[$file.name] -and $file.savedBytes -eq ($file.physicalBytesBefore - $file.physicalBytesAfter)) 'Digest or byte accounting differs.'
            Assert-True ((Digest (Join-Path $history.Directory $file.name)) -ceq $hashes[$file.name]) 'Metadata content changed.'
            Assert-True (((Get-Item -LiteralPath (Join-Path $history.Directory $file.name)).Attributes -band [IO.FileAttributes]::Compressed) -ne 0) 'Metadata is not compressed.'
            $saved += $file.savedBytes
        }
        Assert-True ($saved -gt 400000) 'Compressible history did not reduce physical allocation.'
        $again = Invoke-Cli @('compact-history', '--apply')
        Assert-True ($again.ExitCode -eq 0 -and @($again.Json.operations[0].files | Where-Object status -ne 'already_compressed').Count -eq 0) 'Compression was not idempotent.'
        Assert-True ((Get-Item -LiteralPath (Join-Path $history.Directory 'operation.lock')).Length -eq 0) 'Operation lock changed.'
        $restore = Invoke-Cli @('restore', $history.Id)
        Assert-True ($restore.ExitCode -eq 1 -and $restore.Json.error -match 'scheduled for purge') 'Old ID restore no longer reports its original purge state.'
        $purgeAgain = Invoke-Cli @('purge', $history.Id, '--apply')
        Assert-True ($purgeAgain.ExitCode -eq 0) 'Old ID purge no longer works.'
        foreach ($name in $hashes.Keys) { Assert-True ((Digest (Join-Path $history.Directory $name)) -ceq $hashes[$name]) 'Existing audit metadata changed after purge.' }
    }
}
Test-Case 'live-payload-retained-and-restorable' {
    $history = New-History -Live
    Assert-Skipped $history (Snapshot $history.Directory)
    $restore = Invoke-Cli @('restore', $history.Id)
    Assert-True ($restore.ExitCode -eq 0 -and [IO.File]::ReadAllText($history.Source) -ceq ('history-source' * 100)) 'Skipped live recovery no longer restores.'
}
Test-Case 'unknown-member-retained' {
    $history = New-History
    [IO.File]::WriteAllText((Join-Path $history.Directory 'unknown.json'), '{}')
    Assert-Skipped $history (Snapshot $history.Directory)
}
Test-Case 'duplicate-json-property-retained' {
    $history = New-History
    $path = Join-Path $history.Directory 'manifest.json'
    $json = [IO.File]::ReadAllText($path)
    [IO.File]::WriteAllText($path, ('{"schema":1,' + $json.TrimStart().Substring(1)))
    Assert-Skipped $history (Snapshot $history.Directory)
}
Test-Case 'intent-hash-mismatch-retained' {
    $history = New-History
    $path = Join-Path $history.Directory 'purge-intent.json'
    $intent = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $intent.manifestSha256 = '0' * 64; Save-Json $path $intent
    Assert-Skipped $history (Snapshot $history.Directory)
}
Test-Case 'outcome-operation-id-mismatch-retained' {
    $history = New-History
    $path = Join-Path $history.Directory 'delete-result.json'
    $outcome = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $outcome.operationId = [guid]::NewGuid().ToString('N'); Save-Json $path $outcome
    Assert-Skipped $history (Snapshot $history.Directory)
}
Test-Case 'missing-successful-purge-outcome-retained' {
    $history = New-History
    $path = @(Get-ChildItem -LiteralPath $history.Directory -Filter 'purge-result-*.json' -File)[0].FullName
    $outcome = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $outcome.items[0].status = 'failed'; $outcome.items[0].error = 'fixture failure'; Save-Json $path $outcome
    Assert-Skipped $history (Snapshot $history.Directory)
}
Test-Case 'readonly-metadata-retained' {
    $history = New-History
    $path = Join-Path $history.Directory 'manifest.json'
    [IO.File]::SetAttributes($path, [IO.File]::GetAttributes($path) -bor [IO.FileAttributes]::ReadOnly)
    Assert-Skipped $history (Snapshot $history.Directory)
}
Test-Case 'metadata-ads-retained' {
    $history = New-History
    $path = (Join-Path $history.Directory 'manifest.json') + ':extra'
    [IO.File]::WriteAllText($path, 'metadata ADS')
    Assert-Skipped $history (Snapshot $history.Directory)
    Assert-True ([IO.File]::ReadAllText($path) -ceq 'metadata ADS') 'ADS changed.'
}
Test-Case 'metadata-hardlink-retained' {
    $history = New-History
    $path = Join-Path $history.Directory 'manifest.json'
    $null = New-Item -ItemType HardLink -Path (Join-Path $script:CaseRoot 'manifest-link.json') -Target $path
    Assert-Skipped $history (Snapshot $history.Directory)
}
Test-Case 'operation-junction-not-followed' {
    $outside = Join-Path $script:CaseRoot 'outside'
    $null = [IO.Directory]::CreateDirectory($outside)
    [IO.File]::WriteAllText((Join-Path $outside 'manifest.json'), 'outside data')
    $id = [guid]::NewGuid().ToString('N')
    $null = New-Item -ItemType Junction -Path (Join-Path $script:Recovery $id) -Target $outside
    $before = Snapshot $outside
    $response = Invoke-Cli @('compact-history', '--apply')
    Assert-True ($response.ExitCode -eq 0 -and $response.Json.operations[0].status -eq 'skipped' -and (Snapshot $outside) -ceq $before) 'Operation junction was followed or changed.'
}
Test-Case 'sparse-metadata-retained' {
    $history = New-History
    $path = Join-Path $history.Directory 'manifest.json'
    & fsutil sparse setflag $path | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Could not mark fixture sparse.'
    Assert-Skipped $history (Snapshot $history.Directory)
}
Test-Case 'operation-lock-busy-retained' {
    $history = New-History
    $before = Snapshot $history.Directory
    $lock = [IO.File]::Open((Join-Path $history.Directory 'operation.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $response = Invoke-Cli @('compact-history', '--apply')
        Assert-True ($response.ExitCode -eq 0 -and $response.Json.operations[0].status -eq 'skipped') 'Busy operation was not retained.'
    } finally { $lock.Dispose() }
    Assert-True ((Snapshot $history.Directory) -ceq $before) 'Busy operation changed.'
}
Test-Case 'metadata-writer-busy-retained' {
    $history = New-History
    $before = Snapshot $history.Directory
    $writer = [IO.File]::Open((Join-Path $history.Directory 'manifest.json'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try {
        $response = Invoke-Cli @('compact-history', '--apply')
        Assert-True ($response.ExitCode -eq 0 -and $response.Json.operations[0].status -eq 'skipped') 'Writable metadata was not retained.'
    } finally { $writer.Dispose() }
    Assert-True ((Snapshot $history.Directory) -ceq $before) 'Busy metadata changed.'
}
Test-Case 'coordination-lock-waits-without-changing-history' {
    $history = New-History
    $before = Snapshot $history.Directory
    $lock = [IO.File]::Open((Join-Path $script:Recovery 'maintenance.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $running = Start-Cli @('compact-history', '--apply')
    try {
        Start-Sleep -Milliseconds 400
        Assert-True (!$running.Process.HasExited -and (Snapshot $history.Directory) -ceq $before) 'Coordination lock did not block compression.'
    } finally { $lock.Dispose() }
    $response = Finish-Cli $running
    Assert-True ($response.ExitCode -eq 0 -and $response.Json.operations[0].status -eq 'compacted') 'Compression did not resume after coordination lock release.'
}
Test-Case 'held-handles-prevent-metadata-and-ancestor-replacement' {
    $history = New-History -WarningCount 128
    $path = Join-Path $history.Directory 'delete-result.json'
    $running = Start-Cli @('compact-history', '--apply')
    try {
        Wait-CompressionStart $running $history.Directory
        $renamed = $false
        try { [IO.File]::Move($path, $path + '.replacement'); $renamed = $true } catch [IO.IOException] { }
        Assert-True (!$renamed) 'Held metadata could be renamed.'
        try { [IO.Directory]::Move($history.Directory, $history.Directory + '-replacement'); $renamed = $true } catch [IO.IOException] { }
        Assert-True (!$renamed) 'Pinned operation directory could be renamed.'
    } finally {
        $response = Finish-Cli $running
    }
    Assert-True ($response.ExitCode -eq 0 -and $response.Json.operations[0].status -eq 'compacted') 'Compression failed after rejected replacement attempts.'
}
Test-Case 'membership-race-reported-as-partial-failure' {
    $history = New-History -WarningCount 128
    $unknown = Join-Path $history.Directory 'race-unknown.txt'
    $hashes = @{}; foreach ($file in Get-ChildItem -LiteralPath $history.Directory -File) { $hashes[$file.Name] = Digest $file.FullName }
    $running = Start-Cli @('compact-history', '--apply')
    try {
        Wait-CompressionStart $running $history.Directory
        [IO.File]::WriteAllText($unknown, 'unknown race data')
    } finally { $response = Finish-Cli $running }
    Assert-True ($response.ExitCode -eq 1 -and $response.Json.operations[0].status -eq 'failed' -and $response.Json.operations[0].error -match 'membership changed') 'Partial failure was not reported through status and exit code.'
    Assert-True ([IO.File]::ReadAllText($unknown) -ceq 'unknown race data') 'Unknown racing member changed.'
    foreach ($name in $hashes.Keys) { Assert-True ((Digest (Join-Path $history.Directory $name)) -ceq $hashes[$name]) 'Partial compression changed metadata bytes.' }
}
Test-Case 'large-manifest-and-intent-streaming-validation' {
    $id = [guid]::NewGuid().ToString('N')
    $directory = Join-Path $script:Recovery $id
    $null = [IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllBytes((Join-Path $directory 'operation.lock'), [byte[]]::new(0))
    $manifestPath = Join-Path $directory 'manifest.json'
    $intentPath = Join-Path $directory 'purge-intent.json'
    $outcomePath = Join-Path $directory ('purge-result-' + [guid]::NewGuid().ToString('N') + '.json')
    $timestamp = [DateTimeOffset]::UtcNow.ToString('O')
    $emptyHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]::new(0))).ToLowerInvariant()
    $quotedPrefix = $script:CaseRoot | ConvertTo-Json -Compress
    $wirePrefix = $quotedPrefix.Substring(1, $quotedPrefix.Length - 2) + '\\large-source-'
    $manifestWriter = [IO.StreamWriter]::new($manifestPath, $false, [Text.UTF8Encoding]::new($false))
    $outcomeWriter = [IO.StreamWriter]::new($outcomePath, $false, [Text.UTF8Encoding]::new($false))
    try {
        $manifestWriter.Write('{"schema":2,"operationId":"' + $id + '","createdUtc":"' + $timestamp + '","items":[')
        $outcomeWriter.Write('{"operationId":"' + $id + '","dryRun":false,"purgedBytes":0,"warnings":[],"items":[')
        for ($index = 0; $index -lt 90000; $index++) {
            if ($index) { $manifestWriter.Write(','); $outcomeWriter.Write(',') }
            $wirePath = '"' + $wirePrefix + $index + '.txt"'
            $manifestWriter.Write('{"path":' + $wirePath + ',"kind":"file","treeRoot":null,"state":"backup_ready","sha256":"' + $emptyHash + '","size":0}')
            $outcomeWriter.Write('{"path":' + $wirePath + ',"kind":"file","status":"already_purged"}')
        }
        $manifestWriter.Write(']}'); $outcomeWriter.Write(']}')
    } finally { $manifestWriter.Dispose(); $outcomeWriter.Dispose() }
    $manifestHash = Digest $manifestPath
    $intentWriter = [IO.StreamWriter]::new($intentPath, $false, [Text.UTF8Encoding]::new($false))
    try {
        $intentWriter.Write('{"schema":1,"operationId":"' + $id + '","createdUtc":"' + $timestamp + '","manifestSha256":"' + $manifestHash + '","targets":[')
        for ($index = 0; $index -lt 90000; $index++) {
            if ($index) { $intentWriter.Write(',') }
            $intentWriter.Write('{"index":' + $index + ',"sha256":"' + $emptyHash + '","size":0}')
        }
        $intentWriter.Write(']}')
    } finally { $intentWriter.Dispose() }
    Assert-True ((Get-Item -LiteralPath $manifestPath).Length -gt 8MB -and (Get-Item -LiteralPath $intentPath).Length -gt 8MB) 'Large metadata fixture did not exceed the old size boundary.'
    $hashes = @{}; foreach ($file in Get-ChildItem -LiteralPath $directory -File) { $hashes[$file.Name] = Digest $file.FullName }
    $response = Invoke-Cli @('compact-history', '--apply')
    Assert-True ($response.ExitCode -eq 0 -and $response.Json.operations[0].status -eq 'compacted') 'Large manifest or intent failed validation/compression.'
    foreach ($name in $hashes.Keys) { Assert-True ((Digest (Join-Path $directory $name)) -ceq $hashes[$name]) 'Large metadata bytes changed.' }
}
Test-Case 'invalid-cli-options-rejected' {
    foreach ($arguments in @(@('compact-history', '--dry-run', '--apply'), @('compact-history', '--force'))) {
        $response = Invoke-Cli $arguments
        Assert-True ($response.ExitCode -eq 1 -and $response.Json.error -match 'Use compact-history') 'Invalid CLI options were accepted.'
    }
}

$passed = @($results | Where-Object passed).Count; $failed = $results.Count - $passed
Save-Json $report @{ executable = $ExecutablePath; executableSha256 = (Digest $ExecutablePath); outputDirectory = $outputRoot; passed = $passed; failed = $failed; cases = @($results); commands = @($commands) }
Write-Output $report
Write-Output "passed=$passed failed=$failed"
if ($failed) { exit 1 }
