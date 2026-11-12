[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$ExpectedExecutableSha256,
    [string]$BuildManifestPath,
    [string]$ExpectedBuildManifestSha256,
    [Parameter(Mandatory)][string]$ExpectedSid,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][switch]$AssertNativeWindows
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
. (Join-Path $PSScriptRoot 'FixtureBridge.Common.ps1')
. (Join-Path $PSScriptRoot 'ProtectedRegistryFixtures.Common.ps1')
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'Absolute paths required.' }
}
foreach ($path in @($OutputDirectory, $ReportPath)) {
    Assert-ExternalVerificationPath $path @($repo)
    if (Test-Path -LiteralPath $path) { throw 'Unused output/report required.' }
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { throw 'Output/report parent must exist.' }
}
if ((Get-FileHash -LiteralPath $ExecutablePath).Hash -cne $ExpectedExecutableSha256) { throw 'Executable hash differs.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (!$AssertNativeWindows -or $identity.User.Value -cne $ExpectedSid -or !$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Explicit native Windows scope and the fixed elevated caller are required before fixture creation.'
}
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$script:temp = Join-Path $OutputDirectory 'temp'
$null = [IO.Directory]::CreateDirectory($script:temp)
$env:TEMP = $script:temp; $env:TMP = $script:temp
. (Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1')
$null = Initialize-PrunletFixtureBinding -ExecutablePath $ExecutablePath -BuildManifestPath $BuildManifestPath -ExpectedBuildManifestSha256 $ExpectedBuildManifestSha256
$script:commands = [Collections.Generic.List[object]]::new()
$script:observed = @{}
$results = [Collections.Generic.List[object]]::new()
$relative = 'SOFTWARE\PrunletE2E\' + [guid]::NewGuid().ToString('N')
$logical = 'HKEY_LOCAL_MACHINE\' + $relative
$bases = @{}; $mcp = $null; $cleanup = @(); $completed = $false
$sentinels = @{ '32' = [byte[]]@(32, 0, 255, 1); '64' = [byte[]]@(64, 0, 255, 2) }
$report = [ordered]@{
    scope = 'Explicit native Windows; isolated HKLM SOFTWARE GUID in both WOW64 views'
    executablePath = $ExecutablePath; executableSha256 = $ExpectedExecutableSha256
    callerSid = $identity.User.Value; fixture = $logical
    sourceHashes = @(@($PSCommandPath, (Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1'), (Join-Path $PSScriptRoot 'Verification-Common.ps1'), (Join-Path $PSScriptRoot 'ProtectedRegistryFixtures.Common.ps1'), (Join-Path $PSScriptRoot 'FixtureBridge.Common.ps1')) | ForEach-Object { @{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash} })
    status = 'running'; results = @(); cleanup = @(); error = $null
}
function Read-Sentinel([string]$View, [string]$Name = 'selected') {
    $key = $bases[$View].OpenSubKey($relative, $false)
    try {
        Assert-R ($null -ne $key) 'Fixture key disappeared.'
        if ($key.GetValueNames() -cnotcontains $Name) { return $null }
        Assert-R ($key.GetValueKind($Name) -eq [Microsoft.Win32.RegistryValueKind]::Binary) 'Fixture type changed.'
        return ,([byte[]]$key.GetValue($Name))
    } finally { if ($key) { $key.Dispose() } }
}
function Assert-Sentinel([string]$View, [bool]$Present) {
    $actual = Read-Sentinel $View
    if ($Present) { Assert-R ($null -ne $actual -and [Convert]::ToBase64String($actual) -ceq [Convert]::ToBase64String($sentinels[$View])) "View $View selected bytes changed." }
    else { Assert-R ($null -eq $actual) "View $View selected value remains." }
    $other = Read-Sentinel $View 'untouched'
    Assert-R ($null -ne $other -and [Convert]::ToBase64String($other) -ceq [Convert]::ToBase64String($sentinels[$View])) "View $View sibling bytes changed."
}
try {
    $scope = New-ScopeR 'view-operations'
    $migration = Invoke-R $scope @('migrate','--apply')
    Assert-R ($migration.exitCode -eq 0) 'Fresh registry storage initialization failed.'
    foreach ($view in @('32','64')) {
        $registryView = if ($view -eq '32') { [Microsoft.Win32.RegistryView]::Registry32 } else { [Microsoft.Win32.RegistryView]::Registry64 }
        $bases[$view] = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $registryView)
        $existing = $bases[$view].OpenSubKey($relative)
        if ($existing) { $existing.Dispose(); throw 'GUID fixture unexpectedly exists.' }
        $key = $bases[$view].CreateSubKey($relative, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [Microsoft.Win32.RegistryOptions]::Volatile)
        try { foreach ($name in @('selected','untouched')) { $key.SetValue($name, $sentinels[$view], [Microsoft.Win32.RegistryValueKind]::Binary) } }
        finally { $key.Dispose() }
    }
    Assert-Sentinel '32' $true; Assert-Sentinel '64' $true
    $refused = Invoke-R $scope @('registry-delete','--view','32','--access-mode','backupRestore','--value-name','selected','--',$logical)
    Assert-R ($refused.exitCode -ne 0 -and $refused.stdout -match '64') 'CLI must refuse unsupported protected 32-bit access.'
    Assert-Sentinel '32' $true; Assert-Sentinel '64' $true
    $results.Add(@{name='cli-backup-restore-32-refused-without-changing-either-view';passed=$true})
    $deleted = Invoke-R $scope @('registry-delete','--view','64','--access-mode','backupRestore','--value-name','selected','--',$logical)
    Assert-R ($deleted.exitCode -eq 0 -and $deleted.json.items[0].status -ceq 'deleted') 'CLI backupRestore deletion failed.'
    Assert-Sentinel '32' $true; Assert-Sentinel '64' $false
    $restored = Invoke-R $scope @('registry-restore',$deleted.json.operationId,'--access-mode','backupRestore')
    Assert-R ($restored.exitCode -eq 0 -and $restored.json.items[0].status -ceq 'restored') 'CLI backupRestore restoration failed.'
    Assert-Sentinel '32' $true; Assert-Sentinel '64' $true
    $results.Add(@{name='cli-backup-restore-64-preserves-32-view';passed=$true;operationId=$deleted.json.operationId})
    $mcp = Start-R $ExecutablePath $scope.config @('mcp') -Streaming
    $mcp.transcript = [Collections.Generic.List[object]]::new()
    Init-McpR $mcp
    $processBefore = (Get-ProtectedFixtureProcessPrivileges ([uint32]$mcp.process.Id))
    foreach ($name in @('SeBackupPrivilege','SeRestorePrivilege')) {
        Assert-R ($processBefore[$name] -ne 'absent' -and ([Convert]::ToUInt32($processBefore[$name].Substring(2),16) -band 2) -eq 0) 'MCP process must begin with backup/restore privileges present but disabled.'
    }
    $refused = Call-McpR $mcp 2 'delete_registry' @{path=$logical;view='32';valueName='selected';accessMode='backupRestore'}
    Assert-R ($refused.failed -and ($refused.response | ConvertTo-Json -Depth 20 -Compress) -match '64') 'MCP must refuse unsupported protected 32-bit access.'
    Assert-Sentinel '32' $true; Assert-Sentinel '64' $true
    $results.Add(@{name='mcp-backup-restore-32-refused-without-changing-either-view';passed=$true})
    $deleted = Call-McpR $mcp 3 'delete_registry' @{path=$logical;view='64';valueName='selected';accessMode='backupRestore'}
    Assert-R (!$deleted.failed -and $deleted.json.items[0].status -ceq 'deleted') 'MCP backupRestore deletion failed.'
    Assert-Sentinel '32' $true; Assert-Sentinel '64' $false
    $restored = Call-McpR $mcp 4 'restore_registry' @{operationId=$deleted.json.operationId;accessMode='backupRestore'}
    Assert-R (!$restored.failed -and $restored.json.items[0].status -ceq 'restored') 'MCP backupRestore restoration failed.'
    Assert-Sentinel '32' $true; Assert-Sentinel '64' $true
    $results.Add(@{name='mcp-backup-restore-64-view-separated';passed=$true;operationId=$deleted.json.operationId})
    $normal = Call-McpR $mcp 5 'delete_registry' @{path=$logical;view='64';valueName='selected';dryRun=$true}
    Assert-R (!$normal.failed -and $normal.json.items[0].status -ceq 'would_delete') 'Normal follow-up request failed.'
    $processAfter = (Get-ProtectedFixtureProcessPrivileges ([uint32]$mcp.process.Id))
    foreach ($name in $processBefore.Keys) { Assert-R ($processBefore[$name] -ceq $processAfter[$name]) "MCP process privilege leaked: $name" }
    $report.processPrivileges = @{before=$processBefore;after=$processAfter;normalFollowup=$normal}
    Assert-Sentinel '32' $true; Assert-Sentinel '64' $true
    $report.mcpTranscript = @($mcp.transcript.ToArray())
    Close-McpR $mcp; $mcp = $null
    # 拒否fixtureを別方式で清掃せず、両viewのvolatile GUIDをhive unloadまで保持する。
    Assert-R ((Get-FileHash -LiteralPath $ExecutablePath).Hash -ceq $ExpectedExecutableSha256) 'Executable changed during verification.'
    $completed = $true; $report.status = 'passed'
} catch { $report.status = 'failed'; $report.error = $_.Exception.ToString() }
finally {
    if ($mcp) { try { $report.mcpTranscript = @($mcp.transcript.ToArray()); Close-McpR $mcp } catch { $report.status='failed'; $report.shutdownError=$_.Exception.Message } }
    foreach ($base in $bases.Values) { $base.Dispose() }
    $identity.Dispose()
    $report.results = @($results.ToArray()); $report.cleanup = $cleanup
    $report.commands = @($script:commands.ToArray()); $report.observed = $script:observed
    $report.retainedFixture = $logical
    $report.retention = 'Both views contain dedicated volatile GUID fixtures. No cleanup deletion or retry is performed; they expire at hive unload.'
    Save-R $ReportPath $report
}
@{status=$report.status;passed=$results.Count;reportPath=$ReportPath;retainedFixture=$report.retainedFixture} | ConvertTo-Json -Compress
if ($report.status -ne 'passed') { exit 1 }
