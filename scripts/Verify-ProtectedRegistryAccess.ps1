[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExpectedSid,
    [Parameter(Mandatory)][string]$ExecutablePath,
    [string]$BuildManifestPath,
    [string]$ExpectedBuildManifestSha256,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][switch]$AssertNativeWindows
)
$ErrorActionPreference = 'Stop'
if (!$AssertNativeWindows) { throw 'Explicit native Windows scope assertion is required.' }
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
. (Join-Path $PSScriptRoot 'FixtureBridge.Common.ps1')
. (Join-Path $PSScriptRoot 'RegistryFixtures.Common.ps1')
. (Join-Path $PSScriptRoot 'ProtectedRegistryFixtures.Common.ps1')
$excludedRoots = @($repoRoot, (Join-Path $env:USERPROFILE '.codex'))
foreach ($path in @($OutputDirectory, $ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'External absolute paths (outside repository and Codex home) are required.' }
    Assert-ExternalVerificationPath $path $excludedRoots
    if (Test-Path -LiteralPath $path) { throw 'Output and report must be new.' }
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { throw 'Create output/report parent directories first.' }
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$outputSecurity = [Security.AccessControl.DirectorySecurity]::new()
$outputSecurity.SetAccessRuleProtection($true, $false)
foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
    $outputSecurity.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
}
Set-Acl -LiteralPath $OutputDirectory -AclObject $outputSecurity
$env:TEMP = Join-Path $OutputDirectory 'temp'; $env:TMP = $env:TEMP
$null = [IO.Directory]::CreateDirectory($env:TEMP)
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$report = [ordered]@{
    scope = 'Explicit native Windows; dedicated volatile GUID fixtures only; no key/value deletion APIs'
    expectedSid = $ExpectedSid; actualSid = $identity.User.Value
    elevatedAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    scriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    helperSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'ProtectedRegistryFixtures.Common.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    startedUtc = [DateTime]::UtcNow.ToString('o'); status = 'running'; cases = @(); fixture = $null
}
$cases = [Collections.Generic.List[object]]::new()
$held = [Collections.Generic.List[object]]::new()
$privileges = $null; $protected = $null; $originalDacl = $null; $relative = $null
$inputLeases = [Collections.Generic.List[object]]::new()
function Require([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Same([byte[]]$Left, [byte[]]$Right) { [Convert]::ToBase64String($Left) -ceq [Convert]::ToBase64String($Right) }
function Record-Open([string]$Name, $Open, [bool]$ExpectedSuccess) {
    $cases.Add([ordered]@{ name = $Name; error = $Open.Error; ntStatus = $Open.Status; grantedAccess = ('0x{0:X8}' -f $Open.GrantedAccess); passed = (($Open.Error -eq 0) -eq $ExpectedSuccess) })
    Require (($Open.Error -eq 0) -eq $ExpectedSuccess) "$Name returned unexpected status $($Open.Status)/$($Open.Error)."
}
try {
    Require ($identity.User.Value -ceq $ExpectedSid) 'Effective SID differs from the fixed input.'
    Require $report.elevatedAdministrator 'An elevated administrator token is required; no fixture was created.'
    $null=Initialize-PrunletFixtureBinding -ExecutablePath $ExecutablePath -BuildManifestPath $BuildManifestPath -ExpectedBuildManifestSha256 $ExpectedBuildManifestSha256
    foreach ($inputPath in @($PSCommandPath, (Join-Path $PSScriptRoot 'ProtectedRegistryFixtures.Common.ps1'), (Join-Path $PSScriptRoot 'RegistryFixtures.Common.ps1'), (Join-Path $PSScriptRoot 'FixtureBridge.Common.ps1'))) {
        $inputLeases.Add([IO.File]::Open($inputPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
    }
    $report.fixtureHelperSourceSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'RegistryFixtures.Common.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    $privileges = Start-ProtectedFixturePrivileges
    $report.privileges = @('SeBackupPrivilege', 'SeRestorePrivilege', 'SeSecurityPrivilege')
    $report.privilegesBefore = $privileges.Before; $report.privilegesEnabled = $privileges.Enabled
    $access = [uint32]0x010F013F
    $softwarePath = '\Registry\User\' + $ExpectedSid + '\Software'
    $software = (Open-ProtectedFixtureKey $null $null $softwarePath 0 $false ([uint32]0x20119)); $held.Add($software)
    Record-Open 'native-software-anchor' $software $true
    Require ((Get-ProtectedFixtureName $software.Handle).Equals($softwarePath, [StringComparison]::OrdinalIgnoreCase)) 'Software resolves outside the asserted native scope.'
    $run = 'Software\PrunletE2E\' + [guid]::NewGuid().ToString('N')
    Initialize-RegistryFixture $false $run
    $relative = $run + '-link-probes'; $report.fixture = 'HKEY_CURRENT_USER\' + $relative
    $root = (New-RegistryFixtureNativeKey $relative $true); $held.Add($root)
    $protected = (New-RegistryFixtureNativeKey ($relative + '\restricted') $true); $held.Add($protected)
    $original = [byte[]]@(17, 0, 255, 42)
    Set-RegistryFixtureValue $protected 'sentinel' 3 $original
    $originalDacl = (Get-RegistryFixtureDacl ($relative + '\restricted') $protected)
    (Set-ProtectedFixtureRestriction $protected.Handle)
    $ordinaryDenied = (Open-ProtectedFixtureKey $null $root.Handle 'restricted' 0 $false $access); $held.Add($ordinaryDenied)
    Record-Open 'normal-access-denied' $ordinaryDenied $false
    Require ($ordinaryDenied.Error -eq 5) 'ACL restriction did not produce the expected access denial.'
    $backup = (Open-ProtectedFixtureKey $null $root.Handle 'restricted' 4 $false $access); $held.Add($backup)
    Record-Open 'backup-restore-ordinary-open' $backup $true
    $raw = (Open-ProtectedFixtureKey $null $root.Handle 'restricted' 12 $true $access); $held.Add($raw)
    Record-Open 'backup-restore-raw-open' $raw $true
    Require (Same ((Get-ProtectedFixtureRead $backup.Handle)) $original) 'Raw data/type mismatch.'
    $security = (Get-ProtectedFixtureSecurity $backup.Handle)
    Require ($security.Length -gt 0) 'Complete security bytes were not read.'
    $report.grantedRights = @{
        querySetReadControl = (($backup.GrantedAccess -band 0x20003) -eq 0x20003)
        delete = (($backup.GrantedAccess -band 0x10000) -ne 0)
        completeSecurity = (($backup.GrantedAccess -band 0x1020000) -eq 0x1020000)
        writeDaclOwner = (($backup.GrantedAccess -band 0xC0000) -eq 0xC0000)
    }
    $transaction = (Start-ProtectedFixtureTransaction)
    try {
        $bound = (Open-ProtectedFixtureKey $transaction $backup.Handle '' 12 $true $access)
        try {
            Record-Open 'backup-restore-empty-relative-transaction-bind' $bound $true
            Require (Same ((Get-ProtectedFixtureSecurity $bound.Handle)) $security) 'Transaction security bytes differ.'
            Require ((Set-ProtectedFixtureValue $bound.Handle ([byte[]]@(1, 2, 3))) -eq 0) 'Transaction write could not be staged.'
            Require (Same ((Get-ProtectedFixtureRead $bound.Handle)) ([byte[]]@(1, 2, 3))) 'Transaction read did not see its write.'
            Require (Same ((Get-ProtectedFixtureRead $backup.Handle)) $original) 'Staged write leaked outside the transaction.'
            Require ((Complete-ProtectedFixtureTransaction $transaction $false) -eq 0) 'Rollback failed.'
        } finally { $bound.Dispose() }
    } finally { $transaction.Dispose() }
    Require (Same ((Get-ProtectedFixtureRead $backup.Handle)) $original) 'Rollback did not preserve original data.'
    Require (Same ((Get-ProtectedFixtureSecurity $backup.Handle)) $security) 'Rollback changed security bytes.'
    $cases.Add(@{ name = 'raw-and-complete-security-stage-rollback'; passed = $true })
    $transaction = (Start-ProtectedFixtureTransaction)
    try {
        $bound = (Open-ProtectedFixtureKey $transaction $root.Handle 'restricted' 4 $false $access)
        try {
            Record-Open 'backup-restore-ordinary-transaction-open' $bound $true
            Require ((Set-ProtectedFixtureValue $bound.Handle ([byte[]]@(4, 5, 6))) -eq 0) 'Conflict write could not be staged.'
            $externalError = (Set-ProtectedFixtureValue $protected.Handle ([byte[]]@(7, 8, 9)))
            $commitError = (Complete-ProtectedFixtureTransaction $transaction $true)
            $cases.Add(@{ name = 'external-write-conflict'; externalError = $externalError; commitError = $commitError; passed = ($externalError -ne 0 -or $commitError -ne 0) })
            Require ($externalError -ne 0 -or $commitError -ne 0) 'External update and conflicting transaction both succeeded.'
            if ($externalError -eq 0) {
                Require (Same ((Get-ProtectedFixtureRead $backup.Handle)) ([byte[]]@(7, 8, 9))) 'The successful external update was not preserved after transaction conflict.'
                $cases.Add(@{ name = 'external-update-preserved-before-fixture-reset'; passed = $true })
            }
        } finally { $bound.Dispose() }
    } finally { $transaction.Dispose() }
    Require ((Set-ProtectedFixtureValue $protected.Handle $original) -eq 0) 'Could not reset isolated sentinel.'
    $missing = (Open-ProtectedFixtureKey $null $root.Handle 'missing' 4 $false $access); $held.Add($missing)
    Record-Open 'missing-path-backup-restore-open' $missing $false
    Require ($missing.Error -eq 2) 'Unexpected missing-path status.'
    $missingAfter = (Open-ProtectedFixtureKey $null $root.Handle 'missing' 0 $false ([uint32]0x20119)); $held.Add($missingAfter)
    Require ($missingAfter.Error -eq 2) 'Missing key was created.'
    $link = (New-RegistryFixtureNativeKey ($relative + '\link') $true $true); $held.Add($link)
    Set-RegistryFixtureValue $link 'SymbolicLinkValue' 6 ([Text.Encoding]::Unicode.GetBytes((Get-ProtectedFixtureName $protected.Handle)))
    $incomplete = (New-RegistryFixtureNativeKey ($relative + '\incomplete') $true $true); $held.Add($incomplete)
    foreach ($name in @('link', 'incomplete')) {
        $leaf = (Open-ProtectedFixtureKey $null $root.Handle $name 4 $false $access); $held.Add($leaf)
        Record-Open "backup-restore-ordinary-rejects-$name" $leaf $false
    }
    $rawLink = (Open-ProtectedFixtureKey $null $root.Handle 'link' 12 $true $access); $held.Add($rawLink)
    Record-Open 'backup-restore-raw-link-inspection' $rawLink $true
    $rawChild = (Open-ProtectedFixtureKey $null $rawLink.Handle 'missing' 12 $true $access); $held.Add($rawChild)
    Record-Open 'backup-restore-held-link-reparse-rejected' $rawChild $false
    Require ($rawChild.Error -eq 4395) 'Held link did not fail with reparse-point-encountered.'
    Require (Same ((Get-ProtectedFixtureRead $backup.Handle)) $original) 'Fixture target raw bytes changed.'
    Require (Same ((Get-ProtectedFixtureSecurity $backup.Handle)) $security) 'Fixture target ACL changed.'
    $report.status = 'passed'
} catch {
    $report.status = 'failed'
    $cause = $_.Exception; while ($cause.InnerException) { $cause = $cause.InnerException }
    $report.error = $cause.ToString()
    $report.unexecuted = 'Execution stopped at the first unmet prerequisite or failed case; later cases were not run.'
} finally {
    if ($originalDacl -and $protected) {
        try { Restore-RegistryFixtureDacl ($relative + '\restricted') $protected $originalDacl; $report.fixtureAclRestored = $true }
        catch { $report.fixtureAclRestored = $false; $report.cleanupError = $_.Exception.Message; $report.status = 'failed' }
    }
    # ひとつの解放が失敗しても残りのleaseとtoken復元を試み、報告を必ず残す。
    $closeErrors = [Collections.Generic.List[string]]::new()
    for ($index = $held.Count - 1; $index -ge 0; $index--) {
        try { $held[$index].Dispose() }
        catch { $closeErrors.Add($_.Exception.Message); $report.status = 'failed' }
    }
    if ($closeErrors.Count) { $report.leaseCloseErrors = @($closeErrors.ToArray()) }
    if ($privileges) {
        try {
            $privileges.Dispose(); $report.privilegesRestored = $privileges.Restored
            if (!$privileges.Restored) { $report.status = 'failed'; $report.privilegeRestoreError = 'Token privilege attributes differ from their original values.' }
        }
        catch { $report.privilegesRestored = $false; $report.privilegeRestoreError = $_.Exception.Message; $report.status = 'failed' }
        $report.privilegesAfter = $privileges.After; $report.privilegeRestoreErrors = @($privileges.RestoreErrors.ToArray())
    }
    foreach ($inputLease in $inputLeases) { $inputLease.Dispose() }
    $identity.Dispose()
    $report.cases = @($cases.ToArray()); $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    $report.retention = 'No deletion was attempted. Retain fixture identity and report for installed CLI cleanup; volatile keys also expire at hive unload.'
    [IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 15), [Text.UTF8Encoding]::new($false))
}
$report | ConvertTo-Json -Depth 15
if ($report.status -ne 'passed') { exit 1 }
