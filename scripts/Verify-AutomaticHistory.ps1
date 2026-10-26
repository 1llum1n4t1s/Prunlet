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
    DOTNET_BUNDLE_EXTRACT_BASE_DIR = Join-Path $outputRoot 'runtime-cache'
}
. (Join-Path $PSScriptRoot 'HistoryVerification-Common.ps1')
# 自動化固有の失敗: 既圧縮の再hash、通常deleteによる過去全履歴の走査、
# 新規purge履歴の圧縮漏れ、copy容量との混同、unsafe skipの警告欠落、手動purgeの即圧縮。
function History-Result($Response, [string]$Id) {
    Assert-True ($null -ne $Response.Json.historyCompaction) 'Maintenance did not report historyCompaction.'
    $operations = @($Response.Json.historyCompaction.operations | Where-Object operationId -eq $Id)
    Assert-True ($operations.Count -eq 1) 'History operation was not reported exactly once.'
    return $operations[0]
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
        $applied = Invoke-Cli @('maintain', '--apply')
        Assert-True ($applied.ExitCode -eq 0) 'Terminal history maintenance failed.'
        Assert-VerificationClosedRecord $script:Recovery $history.Id $schema
        Assert-True (!(Test-Path -LiteralPath $history.Source)) 'Retiring purged history recreated its original.'
        Assert-True ($applied.Json.purgedBytes -eq 0 -and $applied.Json.retainedBytesBefore -eq 0 -and $applied.Json.retainedBytesAfter -eq 0) 'Metadata retirement was counted as copy capacity.'
        $closed = Snapshot $script:Recovery
        $again = Invoke-Cli @('maintain', '--apply')
        Assert-True ($again.ExitCode -eq 0 -and (Snapshot $script:Recovery) -ceq $closed -and !(Test-Path -LiteralPath $history.Source)) 'Repeated maintenance changed terminal history or recreated its original.'
        Assert-VerificationClosedRecord $script:Recovery $history.Id $schema
    }
}
Test-Case 'delete-preserves-legacy-until-explicit-maintain' {
    $legacy = New-History
    $legacyBefore = Snapshot $legacy.Directory
    $live = New-History -Live
    Set-Expired $live
    $liveBefore = Snapshot $live.Directory
    $next = Join-Path $script:CaseRoot 'next.txt'; [IO.File]::WriteAllText($next, 'next deletion')
    $deleted = Invoke-Cli @('delete', '--', $next)
    Assert-True ($deleted.ExitCode -eq 0 -and ![IO.File]::Exists($next)) 'Triggering delete failed.'
    Assert-True ((Snapshot $live.Directory) -ceq $liveBefore -and (Snapshot $legacy.Directory) -ceq $legacyBefore) 'Schema 6 delete unexpectedly maintained legacy records.'
    $maintained = Invoke-Cli @('maintain', '--apply')
    Assert-True ($maintained.ExitCode -eq 0 -and $maintained.Json.purgedBytes -gt 0 -and !(Test-Path -LiteralPath $live.Source)) 'Explicit maintenance did not reclaim the expired payload.'
    Assert-VerificationClosedRecord $script:Recovery $legacy.Id 1
    Assert-VerificationClosedRecord $script:Recovery $live.Id 1
    $restored = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0 -and [IO.File]::ReadAllText($next) -ceq 'next deletion') 'Legacy maintenance damaged the schema 6 fixture.'
}
Test-Case 'manual-purge-closes-terminal-history' {
    $history = New-History -Live
    $purged = Invoke-Cli @('purge', $history.Id, '--apply')
    Assert-True ($purged.ExitCode -eq 0 -and !(Test-Path -LiteralPath $history.Source)) 'Manual purge failed or recreated its original.'
    Assert-VerificationClosedRecord $script:Recovery $history.Id 1
    $before = Snapshot $script:Recovery
    $again = Invoke-Cli @('purge', $history.Id, '--apply')
    Assert-True ($again.ExitCode -eq 0 -and $again.Json.lifecycleState -eq 'closed' -and @($again.Json.items).Count -eq 1 -and $again.Json.items[0].status -eq 'closed' -and (Snapshot $script:Recovery) -ceq $before -and !(Test-Path -LiteralPath $history.Source)) 'Repeated purge did not explicitly preserve the closed operation.'
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
        $first = Invoke-Cli @('compact-history', '--apply')
        Assert-True ($first.ExitCode -eq 0 -and @($first.Json.operations | Where-Object { $_.operationId -eq $history.Id -and $_.status -eq 'compacted' }).Count -eq 1) 'Could not explicitly prepare compressed fixture.'
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
Test-Case 'mcp-delete-preserves-legacy-until-explicit-maintain' {
    $legacy = New-History
    $legacyBefore = Snapshot $legacy.Directory
    $live = New-History -Live
    Set-Expired $live
    $liveBefore = Snapshot $live.Directory
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
        $expectedTools = @('delete_files', 'restore_files', 'delete_registry', 'restore_registry', 'reconcile_registry', 'list_operations')
        $actualTools = @($tools.result.tools | ForEach-Object name)
        Assert-True ($actualTools.Count -eq $expectedTools.Count -and @(Compare-Object $expectedTools $actualTools).Count -eq 0) 'MCP tool contract changed.'
        $deleted = Rpc @{jsonrpc='2.0'; id=3; method='tools/call'; params=@{name='delete_files'; arguments=@{paths=@($next)}}}
        Assert-True (!$deleted.result.isError -and ![IO.File]::Exists($next)) 'MCP delete failed.'
        Assert-True ((Snapshot $live.Directory) -ceq $liveBefore) 'Schema 6 MCP delete maintained the legacy payload.'
        Assert-True ((Snapshot $legacy.Directory) -ceq $legacyBefore) 'MCP delete compacted old history.'
        $maintained = Invoke-Cli @('maintain', '--apply')
        Assert-True ($maintained.ExitCode -eq 0 -and $maintained.Json.purgedBytes -gt 0 -and !(Test-Path -LiteralPath $live.Source)) 'Explicit maintenance did not reclaim the expired MCP fixture.'
        Assert-VerificationClosedRecord $script:Recovery $legacy.Id 1
        Assert-VerificationClosedRecord $script:Recovery $live.Id 1
    } finally {
        $process.StandardInput.Close()
        if (!$process.WaitForExit(10000)) { $process.Kill($true); $process.WaitForExit() }
        $stderr = $running.Stderr.GetAwaiter().GetResult()
        $commands.Add(@{ case = [IO.Path]::GetFileName($script:CaseRoot); arguments = @('mcp'); exitCode = $process.ExitCode; stderr = $stderr })
        $process.Dispose()
    }
}
$passed = @($results | Where-Object passed).Count; $failed = $results.Count - $passed
Save-Json $report @{ executable = $ExecutablePath; executableSha256 = (Digest $ExecutablePath); legacyExecutable = $LegacyExecutablePath; legacyExecutableSha256 = (Digest $LegacyExecutablePath); outputDirectory = $outputRoot; passed = $passed; failed = $failed; cases = @($results); commands = @($commands) }
Write-Output $report
Write-Output "passed=$passed failed=$failed"
if ($failed) { exit 1 }
