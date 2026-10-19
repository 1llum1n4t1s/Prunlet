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
# 自動化固有の失敗: 既圧縮の再hash、通常deleteによる過去全履歴の走査、
# 新規purge履歴の圧縮漏れ、copy容量との混同、unsafe skipの警告欠落、手動purgeの即圧縮。
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { New-Case $Name; & $Body; $results.Add(@{ name = $Name; passed = $true }); Write-Output "PASS $Name" }
    catch { $results.Add(@{ name = $Name; passed = $false; error = $_.Exception.Message }); Write-Output "FAIL ${Name}: $($_.Exception.Message)" }
}
function History-Result($Response, [string]$Id) {
    Assert-True ($null -ne $Response.Json.historyCompaction) 'Maintenance did not report historyCompaction.'
    $operations = @($Response.Json.historyCompaction.operations | Where-Object operationId -eq $Id)
    Assert-True ($operations.Count -eq 1) 'History operation was not reported exactly once.'
    return $operations[0]
}
function Assert-Compressed([string]$Directory) {
    $metadata = @(Get-ChildItem -LiteralPath $Directory -File | Where-Object Name -ne 'operation.lock')
    Assert-True ($metadata.Count -gt 0) 'Metadata fixture is empty.'
    foreach ($file in $metadata) { Assert-True (($file.Attributes -band [IO.FileAttributes]::Compressed) -ne 0) "Metadata was not compressed: $($file.Name)" }
}
function Assert-Retained($History, [string]$Before) {
    $response = Invoke-Cli @('maintain', '--apply')
    $operation = History-Result $response $History.Id
    Assert-True ($operation.status -eq 'skipped' -and @($response.Json.historyCompaction.warnings).Count -gt 0) 'Unsafe history was not retained with a warning.'
    Assert-True ((Snapshot $History.Directory) -ceq $Before) 'Unsafe history bytes, attributes, or members changed.'
}
function Set-Expired($History) {
    $path = Join-Path $History.Directory 'manifest.json'
    $manifest = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $manifest.createdUtc = [DateTimeOffset]::UtcNow.AddDays(-8).ToString('O')
    Save-Json $path $manifest
}

foreach ($schema in @(1, 2, 3)) {
    Test-Case "schema-$schema-maintain-dry-run-apply-repeat" {
        $history = New-History -Schema $schema
        $before = Snapshot $history.Directory
        $rootBefore = Snapshot $script:Recovery
        foreach ($arguments in @(@('maintain'), @('maintain', '--dry-run'))) {
            $dry = Invoke-Cli $arguments
            Assert-True ($dry.ExitCode -eq 0 -and $dry.Json.dryRun -and $dry.Json.historyCompaction.dryRun) 'Maintenance dry-run failed.'
            $operation = History-Result $dry $history.Id
            Assert-True ($operation.status -eq 'eligible') 'Legacy uncompressed history was not eligible.'
            Assert-True ((Snapshot $script:Recovery) -ceq $rootBefore) 'Dry-run changed recovery bytes, attributes, or members.'
        }
        $hashes = @{}; foreach ($file in Get-ChildItem -LiteralPath $history.Directory -File) { $hashes[$file.Name] = Digest $file.FullName }
        $applied = Invoke-Cli @('maintain', '--apply')
        $operation = History-Result $applied $history.Id
        Assert-True ($applied.ExitCode -eq 0 -and $operation.status -eq 'compacted') 'Automatic history compression failed.'
        $saved = 0L
        foreach ($file in $operation.files) {
            Assert-True ($file.sha256 -ceq $hashes[$file.name] -and $file.savedBytes -eq ($file.physicalBytesBefore - $file.physicalBytesAfter)) 'Metadata digest or physical byte accounting differs.'
            Assert-True ((Digest (Join-Path $history.Directory $file.name)) -ceq $hashes[$file.name]) 'Metadata content changed.'
            $saved += $file.savedBytes
        }
        Assert-True ($saved -gt 400000) 'History did not reduce physical allocation.'
        Assert-True ($applied.Json.purgedBytes -eq 0 -and $applied.Json.retainedBytesBefore -eq 0 -and $applied.Json.retainedBytesAfter -eq 0) 'Metadata savings were counted as copy capacity.'
        Assert-Compressed $history.Directory
        $compressed = Snapshot $history.Directory
        $again = Invoke-Cli @('maintain', '--apply')
        $operation = History-Result $again $history.Id
        Assert-True ($again.ExitCode -eq 0 -and $operation.status -eq 'skipped_compressed' -and @($operation.files).Count -eq 0) 'Already compressed history did not take the automatic fast path.'
        Assert-True ((Snapshot $history.Directory) -ceq $compressed) 'Repeated maintenance changed history.'
        # 手動圧縮は既圧縮でも従来の完全検証を返す。
        $manual = Invoke-Cli @('compact-history', '--apply')
        Assert-True ($manual.ExitCode -eq 0 -and $manual.Json.operations[0].status -eq 'compacted' -and @($manual.Json.operations[0].files).Count -gt 0) 'Manual compaction lost its full validation result.'
    }
}
Test-Case 'delete-compresses-newly-expired-only' {
    $legacy = New-History
    $legacyBefore = Snapshot $legacy.Directory
    $live = New-History -Live
    Set-Expired $live
    $next = Join-Path $script:CaseRoot 'next.txt'; [IO.File]::WriteAllText($next, 'next deletion')
    $deleted = Invoke-Cli @('delete', '--', $next)
    Assert-True ($deleted.ExitCode -eq 0 -and ![IO.File]::Exists($next)) 'Triggering delete failed.'
    Assert-True (@(Get-ChildItem -LiteralPath $live.Directory -File -Filter '*.bak').Count -eq 0) 'Expired recovery payload was not purged.'
    Assert-Compressed $live.Directory
    Assert-True ((Snapshot $legacy.Directory) -ceq $legacyBefore) 'Ordinary delete scanned/compacted previously purged history.'
    $maintained = Invoke-Cli @('maintain', '--apply')
    Assert-True ((History-Result $maintained $legacy.Id).status -eq 'compacted') 'Scheduled maintenance did not catch up legacy history.'
    Assert-Compressed $legacy.Directory
}
Test-Case 'manual-purge-leaves-history-uncompressed' {
    $history = New-History
    Assert-True (@(Get-ChildItem -LiteralPath $history.Directory -File | Where-Object { $_.Attributes -band [IO.FileAttributes]::Compressed }).Count -eq 0) 'Manual purge immediately compressed history.'
}
Test-Case 'live-payload-retained-and-restorable' {
    $history = New-History -Live
    Assert-Retained $history (Snapshot $history.Directory)
    $restore = Invoke-Cli @('restore', $history.Id)
    Assert-True ($restore.ExitCode -eq 0 -and [IO.File]::ReadAllText($history.Source) -ceq ('history-source' * 100)) 'Retained live payload no longer restores.'
}
foreach ($kind in @('unknown-member', 'readonly', 'ads', 'hardlink', 'invalid-json', 'intent-hash')) {
    Test-Case "$kind-retained" {
        $history = New-History
        $path = Join-Path $history.Directory 'manifest.json'
        switch ($kind) {
            'unknown-member' { [IO.File]::WriteAllText((Join-Path $history.Directory 'unknown.json'), '{}') }
            'readonly' { [IO.File]::SetAttributes($path, [IO.File]::GetAttributes($path) -bor [IO.FileAttributes]::ReadOnly) }
            'ads' { [IO.File]::WriteAllText(($path + ':extra'), 'history ADS') }
            'hardlink' { $null = New-Item -ItemType HardLink -Path (Join-Path $script:CaseRoot 'manifest-link.json') -Target $path }
            'invalid-json' { [IO.File]::WriteAllText($path, '{') }
            'intent-hash' {
                $intentPath = Join-Path $history.Directory 'purge-intent.json'
                $intent = [IO.File]::ReadAllText($intentPath) | ConvertFrom-Json
                $intent.manifestSha256 = '0' * 64; Save-Json $intentPath $intent
            }
        }
        Assert-Retained $history (Snapshot $history.Directory)
        if ($kind -eq 'ads') { Assert-True ([IO.File]::ReadAllText(($path + ':extra')) -ceq 'history ADS') 'Metadata ADS changed.' }
    }
}

foreach ($kind in @('unknown-member', 'ads', 'hardlink', 'readonly')) {
    Test-Case "already-compressed-$kind-still-validated" {
        $history = New-History
        $first = Invoke-Cli @('maintain', '--apply')
        Assert-True ((History-Result $first $history.Id).status -eq 'compacted') 'Could not prepare compressed fixture.'
        $path = Join-Path $history.Directory 'manifest.json'
        switch ($kind) {
            'unknown-member' { [IO.File]::WriteAllText((Join-Path $history.Directory 'unknown.json'), '{}') }
            'ads' { [IO.File]::WriteAllText(($path + ':extra'), 'history ADS') }
            'hardlink' { $null = New-Item -ItemType HardLink -Path (Join-Path $script:CaseRoot 'manifest-link.json') -Target $path }
            'readonly' { [IO.File]::SetAttributes($path, [IO.File]::GetAttributes($path) -bor [IO.FileAttributes]::ReadOnly) }
        }
        Assert-Retained $history (Snapshot $history.Directory)
    }
}
Test-Case 'mcp-delete-compresses-newly-expired-only' {
    $legacy = New-History
    $legacyBefore = Snapshot $legacy.Directory
    $live = New-History -Live
    Set-Expired $live
    $next = Join-Path $script:CaseRoot 'mcp-next.txt'; [IO.File]::WriteAllText($next, 'MCP deletion')
    $running = Start-Cli @('mcp') -Mcp
    $process = $running.Process
    try {
        function Rpc([object]$Request) {
            $process.StandardInput.WriteLine(($Request | ConvertTo-Json -Depth 20 -Compress))
            $process.StandardInput.Flush()
            $read = $process.StandardOutput.ReadLineAsync()
            if (!$read.Wait(15000)) { throw 'MCP response timed out.' }
            if ($null -eq $read.Result) { throw 'MCP closed output unexpectedly.' }
            $response = $read.Result | ConvertFrom-Json -Depth 40
            Assert-True ($response.id -eq $Request.id) 'MCP response id differs.'
            $commands.Add(@{ case = [IO.Path]::GetFileName($script:CaseRoot); request = $Request; response = $response })
            return $response
        }
        $initialized = Rpc @{jsonrpc='2.0'; id=1; method='initialize'; params=@{protocolVersion='2025-11-25'; capabilities=@{}; clientInfo=@{name='automatic-history-e2e'; version='development'}}}
        Assert-True ($initialized.result.protocolVersion -eq '2025-11-25') 'MCP version negotiation failed.'
        $process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
        $tools = Rpc @{jsonrpc='2.0'; id=2; method='tools/list'; params=@{}}
        Assert-True ($tools.result.tools.Count -eq 3 -and @($tools.result.tools | Where-Object name -eq 'compact_history').Count -eq 0) 'MCP tool contract changed.'
        $deleted = Rpc @{jsonrpc='2.0'; id=3; method='tools/call'; params=@{name='delete_files'; arguments=@{paths=@($next)}}}
        Assert-True (!$deleted.result.isError -and ![IO.File]::Exists($next)) 'MCP delete failed.'
        Assert-True (@(Get-ChildItem -LiteralPath $live.Directory -File -Filter '*.bak').Count -eq 0) 'MCP did not purge the expired copy.'
        Assert-Compressed $live.Directory
        Assert-True ((Snapshot $legacy.Directory) -ceq $legacyBefore) 'MCP delete compacted old history.'
    } finally {
        $process.StandardInput.Close()
        if (!$process.WaitForExit(10000)) { $process.Kill($true); $process.WaitForExit() }
        $stderr = $running.Stderr.GetAwaiter().GetResult()
        $commands.Add(@{ case = [IO.Path]::GetFileName($script:CaseRoot); arguments = @('mcp'); exitCode = $process.ExitCode; stderr = $stderr })
        $process.Dispose()
    }
}
$passed = @($results | Where-Object passed).Count; $failed = $results.Count - $passed
Save-Json $report @{ executable = $ExecutablePath; executableSha256 = (Digest $ExecutablePath); outputDirectory = $outputRoot; passed = $passed; failed = $failed; cases = @($results); commands = @($commands) }
Write-Output $report
Write-Output "passed=$passed failed=$failed"
if ($failed) { exit 1 }