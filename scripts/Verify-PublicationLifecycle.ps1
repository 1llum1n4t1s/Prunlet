# 想定する失敗: 実際の完了記録rename失敗を再現できない、generator-only成功をcoverageへ算入する、
# pending本文を権威として公開済み原本のACL改変を迂回する、正当な再試行の永久拒否・attempt増殖、
# owner/descriptor/body改変・未知member・空/部分controlの受入れ、異なるfinalへの上書き、
# 公開済み同一IDのcontrol清掃不能、清掃sharing失敗をデータ復元失敗に変える、doneの早期公開、
# cleanup書込み0byte/partialからの再開不能、durable inventory後のowner/ready片残りの永久拒否、
# cleanup未知fieldの受入れ、部分清掃の再開時に終端commitや原本を変更すること、
# formal完了待ちhintでのmanifest本文再読、hint無視を軽量待機と誤認すること、root binding違反の見逃し、
# 旧flat schema 6の復元前移行漏れ、原本のID/全stream内容/native O/G/D/属性の変化。
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$BaselineExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [ValidateNotNullOrEmpty()][string[]]$CaseFilter = @('*'),
    [ValidateRange(60, 3600)][int]$ProcessTimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
foreach ($path in @($ExecutablePath, $BaselineExecutablePath, $OutputDirectory, $ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'All verification paths must be absolute.' }
}
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
$BaselineExecutablePath = [IO.Path]::GetFullPath($BaselineExecutablePath)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
foreach ($path in @($OutputDirectory, $ReportPath)) {
    Assert-VerificationDestination $path @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
    if (![IO.Path]::GetPathRoot($path).Equals('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'External D: verification output required.' }
    if (Test-Path -LiteralPath $path) { throw 'Unused verification output and report paths required.' }
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { throw 'Create output/report parents first.' }
}
foreach ($path in @($ExecutablePath, $BaselineExecutablePath)) {
    Assert-VerificationDestination $path @()
    if (![IO.File]::Exists($path)) { throw 'Verification executable not found.' }
}
if ([Diagnostics.FileVersionInfo]::GetVersionInfo($BaselineExecutablePath).ProductVersion -notmatch '^1\.0\.15(?:[.+-]|$)') { throw 'Genuine pre-publication 1.0.15 baseline required.' }
if ((Get-FileHash -LiteralPath $BaselineExecutablePath).Hash -ceq (Get-FileHash -LiteralPath $ExecutablePath).Hash) { throw 'Genuine baseline must differ from the candidate executable.' }
$utf8 = [Text.UTF8Encoding]::new($false)
$results = [Collections.Generic.List[object]]::new()
$commands = [Collections.Generic.List[object]]::new()
$generators = [Collections.Generic.List[object]]::new()
$script:AclEvidence = [Collections.Generic.List[object]]::new()
$script:CaseEvidence = $null
$script:CaseRoot = $null
$previousEnvironment = @{}
foreach ($name in @('TEMP', 'TMP', 'DOTNET_BUNDLE_EXTRACT_BASE_DIR')) { $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$tempRoot = Join-Path $OutputDirectory 'temp'
$null = [IO.Directory]::CreateDirectory($tempRoot)
$env:TEMP = $tempRoot; $env:TMP = $tempRoot
$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR = Join-Path $OutputDirectory 'runtime-cache'
$generatorPath = Join-Path $PSScriptRoot 'Verify-RecycleBin.ps1'
$generatorSha = (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash
function Assert-Publication([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Assert-True([bool]$Condition, [string]$Message) { Assert-Publication $Condition $Message }
function Read-PublicationJson([string]$Path) { [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -Depth 100 }
function Save-PublicationJson([string]$Path, $Value) { [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 100), $utf8) }
function Get-PublicationDigest([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function File-Id([string]$Path) { [PrunletVolumeMoveVerificationIdentity]::Read($Path) }

# 必要なC#と純粋snapshot関数だけを取得し、runner全体は実行しない。
$parseTokens = $null; $parseErrors = $null
$generatorAst = [Management.Automation.Language.Parser]::ParseFile($generatorPath, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Generator source has PowerShell parse errors.' }
$nativeStrings = @($generatorAst.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public static class PrunletVolumeMoveVerificationIdentity {') }, $true))
if ($nativeStrings.Count -ne 1) { throw 'Expected one unique native verification C# here-string.' }
if (!('PrunletVolumeMoveVerificationIdentity' -as [type])) { Add-Type -TypeDefinition $nativeStrings[0].Value }
foreach ($name in @('Normalize-RecycleRestoredAclBinary', 'Snapshot-NativeTree', 'Assert-NativeTree')) {
    $functions = @($generatorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true))
    if ($functions.Count -ne 1) { throw "Expected unique snapshot helper $name." }
    . ([scriptblock]::Create($functions[0].Extent.Text))
}
function Invoke-PublicationProcess([string]$Binary, [string[]]$Values, [switch]$Cli) {
    $info = [Diagnostics.ProcessStartInfo]::new($(if ($Cli) { 'cmd.exe' } else { $Binary }))
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $utf8; $info.StandardErrorEncoding = $utf8
    if ($Cli) {
        foreach ($value in @($Binary) + $Values) { if ($value -match '["%&|<>^!\r\n]') { throw 'Unsafe CMD control argument.' } }
        $info.Arguments = '/d /s /c ""' + $Binary + '" ' + (($Values | ForEach-Object { '"' + $_ + '"' }) -join ' ') + '"'
    } else { foreach ($value in $Values) { $info.ArgumentList.Add($value) } }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($ProcessTimeoutSeconds * 1000)) { $process.Kill($true); $process.WaitForExit(); throw 'Publication verification process timed out.' }
        $out = $stdout.GetAwaiter().GetResult(); $err = $stderr.GetAwaiter().GetResult(); $json = $null
        if ($Cli) { try { $json = $out | ConvertFrom-Json -AsHashtable -Depth 100 } catch { } }
        $response = @{ exitCode = $process.ExitCode; json = $json; stdout = $out; stderr = $err; milliseconds = $clock.Elapsed.TotalMilliseconds }
        $commands.Add(@{ case = [IO.Path]::GetFileName($script:CaseRoot); binary = $Binary; arguments = $Values; response = $response })
        return $response
    } finally { $process.Dispose() }
}
function Invoke-PublicationCli($Fixture, [string[]]$Values, [string]$Exe = $ExecutablePath) {
    Invoke-PublicationProcess $Exe (@('--config', $Fixture.configPath) + $Values) -Cli
}
function Get-PublicationAttempts($Fixture) {
    $root = Join-Path $Fixture.recovery '.recycle-records-v1'
    return @(Get-ChildItem -LiteralPath $root -Force -Directory -Filter ('.publication-' + $Fixture.operationId + '-*') | Sort-Object Name)
}
function Get-PublicationInventory([string]$Root) {
    Assert-Publication ([IO.Directory]::Exists($Root)) "Inventory directory is missing: $Root"
    $all = @((Get-Item -LiteralPath $Root -Force)) + @(Get-ChildItem -LiteralPath $Root -Force -Recurse)
    return (ConvertTo-Json -InputObject @($all | Sort-Object FullName | ForEach-Object {
        Assert-Publication (!(($_.Attributes -band [IO.FileAttributes]::ReparsePoint))) 'Publication fixture inventory must not traverse links.'
        @{ path = $_.FullName.Substring($Root.Length); directory = [bool]$_.PSIsContainer; id = File-Id $_.FullName; attributes = [int]$_.Attributes
            nativeSecurity = [Convert]::ToBase64String([PrunletVolumeMoveVerificationIdentity]::ReadSecurity($_.FullName)); hash = $(if (!$_.PSIsContainer) { Get-PublicationDigest $_.FullName } else { $null }) }
    }) -Depth 10 -Compress)
}
function Get-AllPublicationInventory($Fixture) {
    $attempts = @(Get-PublicationAttempts $Fixture)
    return (ConvertTo-Json -InputObject @($attempts | ForEach-Object { @{ name = $_.Name; inventory = Get-PublicationInventory $_.FullName } }) -Depth 10 -Compress)
}
function New-PublicationFixture {
    $generatorOutput = Join-Path $script:CaseRoot 'g'
    $generatorReport = Join-Path $script:CaseRoot 'generator-report.json'
    $response = Invoke-PublicationProcess 'pwsh.exe' @('-NoProfile', '-File', $generatorPath, '-ExecutablePath', $ExecutablePath, '-OutputDirectory', $generatorOutput, '-ReportPath', $generatorReport, '-RetainPublicationFailureFixture', '-CaseFilter', 'stage-ready-conflict-resume-and-published-acl-guard', '-ProcessTimeoutSeconds', [string]$ProcessTimeoutSeconds)
    Assert-Publication ($response.exitCode -eq 0 -and [IO.File]::Exists($generatorReport)) "Failure fixture generator failed: $($response.stdout) $($response.stderr)"
    $report = Read-PublicationJson $generatorReport
    Assert-Publication ($report.passed -eq 1 -and $report.failed -eq 0 -and $report.skipped -eq 0 -and @($report.results).Count -eq 1) 'Generator did not execute exactly the requested failure path.'
    $fixture = $report.results[0].observed
    Assert-Publication ($fixture.fixtureGenerationOnly -eq $true -and $fixture.publishedAclRetained -eq $true) 'Generator result is not an owned post-publication failure fixture.'
    foreach ($field in @('operationId', 'configPath', 'recovery', 'operationDirectory', 'tree', 'changedFile', 'originalSnapshot', 'readyPath', 'intentPath', 'completionPath')) { Assert-Publication (![string]::IsNullOrWhiteSpace($fixture[$field])) "Generator omitted $field." }
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes([IO.Path]::GetFileName($fixture.completionPath)))).ToLowerInvariant().Substring(0, 32)
    $fixture.attemptPath = Join-Path (Join-Path $fixture.recovery '.recycle-records-v1') ('.publication-' + $fixture.operationId + '-' + $key)
    Assert-Publication ([IO.Directory]::Exists($fixture.attemptPath) -and !(Test-Path -LiteralPath $fixture.completionPath)) 'Real failed completion publication has no dedicated attempt or was already final.'
    foreach ($name in @('owner.json', 'body.json', 'ready.json')) { Assert-Publication ([IO.File]::Exists((Join-Path $fixture.attemptPath $name))) "Real completion attempt omitted $name." }
    Assert-Publication (@(Get-PublicationAttempts $fixture).Count -eq 1) 'Completion fixture did not leave exactly one owned authority attempt.'
    $layout = Read-PublicationJson (Join-Path (Join-Path $fixture.recovery '.recycle-records-v1') 'layout.json')
    Assert-Publication ($layout.publicationProtocol -eq 1) 'Fixture typed root does not claim the authority publication protocol.'
    $owner = Read-PublicationJson (Join-Path $fixture.attemptPath 'owner.json')
    $ready = Read-PublicationJson (Join-Path $fixture.attemptPath 'ready.json')
    $body = Join-Path $fixture.attemptPath 'body.json'
    Assert-Publication ($owner.schema -eq 1 -and $owner.operationId -ceq $fixture.operationId -and $owner.namespaceName -ceq [IO.Path]::GetFileName($fixture.attemptPath) -and $owner.finalName -ceq [IO.Path]::GetFileName($fixture.completionPath) -and $owner.documentType -ceq 'receipt' -and $owner.bodyName -ceq 'body.json') 'Real completion owner has an unexpected target or document type.'
    Assert-Publication ($owner.bodyLength -eq (Get-Item -LiteralPath $body).Length -and $owner.bodySha256 -ceq (Get-PublicationDigest $body) -and $owner.rootNonce -ceq $layout.nonce) 'Completion owner does not bind this body and root nonce.'
    Assert-Publication ($ready.schema -eq 1 -and $ready.operationId -ceq $fixture.operationId -and $ready.ownerSha256 -ceq (Get-PublicationDigest (Join-Path $fixture.attemptPath 'owner.json')) -and $ready.bodyLength -eq $owner.bodyLength -and $ready.bodySha256 -ceq $owner.bodySha256 -and $ready.bodyIdentity) 'Completion ready proof does not bind its durable owner and body.'
    $fixture.publicationOwner = $owner
    $fixture.publicationReady = $ready
    $fixture.original = Read-PublicationJson $fixture.originalSnapshot
    $fixture.sourceAtFailure = Snapshot-NativeTree $fixture.tree
    $generators.Add(@{ reportPath = $generatorReport; operationId = $fixture.operationId; fixtureGenerationOnly = $true; coverageCounted = $false; sourceSha256 = $generatorSha })
    $script:CaseEvidence = @{ fixtureReport = $generatorReport; operationId = $fixture.operationId; attemptPath = $fixture.attemptPath }
    return $fixture
}
function Reset-PublicationSourceAcl($Fixture) {
    $rows = @($Fixture.original | Where-Object { $_.relative.TrimStart([char]92) -ceq 'group\0000.bin' })
    Assert-Publication ($rows.Count -eq 1 -and $rows[0].nativeSecurityBase64) 'Original changed-file native ACL evidence is missing or ambiguous.'
    [PrunletVolumeMoveVerificationIdentity]::FixtureDacl($Fixture.changedFile, [Convert]::FromBase64String($rows[0].nativeSecurityBase64))
    $null = Assert-NativeTree $Fixture.tree $Fixture.original
}
function Assert-PublicationControlsCollected($Fixture) {
    Assert-Publication (@(Get-PublicationAttempts $Fixture).Count -eq 0) 'Own publication attempts remained after terminal recovery.'
    Assert-Publication (@(Get-ChildItem -LiteralPath $Fixture.recovery -Force -File -Filter ('recycle-pending-' + $Fixture.operationId + '-*')).Count -eq 0) 'Own flat publication pending files remained.'
    Assert-VerificationClosedRecord $Fixture.recovery $Fixture.operationId 6
    $done = Join-Path (Join-Path $Fixture.recovery '.closed-records-v1') ($Fixture.operationId + '.done.json')
    Assert-Publication ([IO.File]::Exists($done)) 'Terminal control cleanup was not committed complete.'
    $null = Assert-NativeTree $Fixture.tree $Fixture.original
}
function Complete-PublicationRestore($Fixture) {
    $response = Invoke-PublicationCli $Fixture @('restore', $Fixture.operationId)
    Assert-Publication ($response.exitCode -eq 0 -and @($response.json.items).Count -eq 1 -and $response.json.items[0].status -in @('restored', 'already_restored')) "Normal recovery failed: $($response.stdout) $($response.stderr)"
    Assert-PublicationControlsCollected $Fixture
    return $response
}
function Assert-PublicationRejectedUnchanged($Fixture, [object[]]$Source, [string]$Inventory) {
    $response = Invoke-PublicationCli $Fixture @('restore', $Fixture.operationId)
    Assert-Publication ($response.exitCode -ne 0 -and !(Test-Path -LiteralPath $Fixture.completionPath)) 'Invalid publication evidence was accepted as final authority.'
    Assert-Publication ((Get-AllPublicationInventory $Fixture) -ceq $Inventory) 'Rejected publication modified, removed or multiplied control evidence.'
    $null = Assert-NativeTree $Fixture.tree $Source
    return $response
}
function Move-PublicationOwnFixture([string]$Source, [string]$Destination) {
    $sourcePath = [IO.Path]::GetFullPath($Source); $destinationPath = [IO.Path]::GetFullPath($Destination)
    $casePrefix = [IO.Path]::GetFullPath($script:CaseRoot).TrimEnd([char]92) + '\'
    foreach ($path in @($sourcePath, $destinationPath)) {
        Assert-Publication ($path.StartsWith($casePrefix, [StringComparison]::OrdinalIgnoreCase)) 'OwnFixtureMove must stay inside this isolated case.'
        Assert-VerificationDestination $path @()
    }
    $directory = [IO.Directory]::Exists($sourcePath)
    Assert-Publication (($directory -or [IO.File]::Exists($sourcePath)) -and !(Test-Path -LiteralPath $destinationPath) -and [IO.Directory]::Exists([IO.Path]::GetDirectoryName($destinationPath))) 'OwnFixtureMove requires an existing object and unused destination.'
    $identity = File-Id $sourcePath
    $evidence = if ($directory) { Get-PublicationInventory $sourcePath } else { Get-PublicationDigest $sourcePath }
    if ($directory) { [IO.Directory]::Move($sourcePath, $destinationPath) }
    else { [IO.File]::Move($sourcePath, $destinationPath, $false) }
    $movedEvidence = if ($directory) { Get-PublicationInventory $destinationPath } else { Get-PublicationDigest $destinationPath }
    Assert-Publication ((File-Id $destinationPath) -ceq $identity -and $movedEvidence -ceq $evidence -and !(Test-Path -LiteralPath $sourcePath)) 'OwnFixtureMove changed its evidence object or inventory.'
}
function New-PublicationBlockedCleanupFixture {
    $fixture = New-PublicationFixture; Reset-PublicationSourceAcl $fixture
    $ownerPath = Join-Path $fixture.attemptPath 'owner.json'; $readyPath = Join-Path $fixture.attemptPath 'ready.json'
    $ownerId = File-Id $ownerPath; $ownerHash = Get-PublicationDigest $ownerPath
    $readyId = File-Id $readyPath; $readyHash = Get-PublicationDigest $readyPath
    $closed = Join-Path $fixture.recovery '.closed-records-v1'
    $fixture.summaryPath = Join-Path $closed ($fixture.operationId + '.json')
    $fixture.donePath = Join-Path $closed ($fixture.operationId + '.done.json')
    $fixture.cleanupPath = Join-Path $fixture.attemptPath 'cleanup.json'
    $held = [IO.File]::Open($ownerPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $restored = Invoke-PublicationCli $fixture @('restore', $fixture.operationId)
        Assert-Publication ($restored.exitCode -eq 0 -and @($restored.json.items).Count -eq 1 -and $restored.json.items[0].status -in @('restored', 'already_restored')) 'Cleanup interruption fixture did not finish real source restoration.'
        Assert-Publication (@($restored.json.warnings).Count -gt 0 -and [IO.File]::Exists($fixture.summaryPath) -and !(Test-Path -LiteralPath $fixture.donePath)) 'Cleanup sharing did not leave a real committed incomplete terminal cleanup.'
        Assert-Publication ([IO.File]::Exists($fixture.cleanupPath) -and !(Test-Path -LiteralPath (Join-Path $fixture.attemptPath 'body.json'))) 'Real published control cleanup did not flush its durable cleanup inventory.'
        Assert-Publication ((File-Id $ownerPath) -ceq $ownerId -and (Get-PublicationDigest $ownerPath) -ceq $ownerHash -and (File-Id $readyPath) -ceq $readyId -and (Get-PublicationDigest $readyPath) -ceq $readyHash) 'Sharing fixture deleted or rewrote owner/ready before cleanup inventory was established.'
        $cleanup = Read-PublicationJson $fixture.cleanupPath
        $files = @($cleanup.inventory.files)
        Assert-Publication ($cleanup.schema -eq 1 -and $cleanup.preExecution -eq $false -and $cleanup.owner.operationId -ceq $fixture.operationId -and $cleanup.ready.operationId -ceq $fixture.operationId -and $cleanup.ready.ownerSha256 -ceq $ownerHash -and $cleanup.inventory.directoryName -ceq [IO.Path]::GetFileName($fixture.attemptPath) -and $files.Count -eq 2 -and @($files | Where-Object name -notin @('owner.json', 'ready.json')).Count -eq 0) 'Real cleanup does not describe the published owner/ready inventory.'
        foreach ($name in @('owner.json', 'ready.json')) {
            $entry = @($files | Where-Object name -ceq $name); $path = Join-Path $fixture.attemptPath $name
            Assert-Publication ($entry.Count -eq 1 -and $entry[0].identity -and $entry[0].length -eq (Get-Item -LiteralPath $path).Length -and $entry[0].sha256 -ceq (Get-PublicationDigest $path)) 'Real cleanup inventory omitted exact live control bytes.'
        }
        $null = Assert-NativeTree $fixture.tree $fixture.original
        $fixture.summaryDigest = Get-PublicationDigest $fixture.summaryPath
        $script:CaseEvidence.blockedCleanupResponse = $restored
        $script:CaseEvidence.cleanupPath = $fixture.cleanupPath
    } finally { $held.Dispose() }
    Assert-Publication ([IO.File]::Exists($fixture.cleanupPath)) 'Cleanup inventory disappeared before interrupted-cleanup fixture construction.'
    return $fixture
}
function Get-PublicationRequiredFinalHint($Fixture) {
    $closedRoot = Join-Path $Fixture.recovery '.closed-records-v1'
    $path = Join-Path $closedRoot ($Fixture.operationId + '.request.json')
    Assert-Publication ([IO.File]::Exists($path) -and !(Test-Path -LiteralPath $Fixture.completionPath)) 'Real failed final publication did not leave a durable required-final retirement hint.'
    $hint = Read-PublicationJson $path
    $closedLayout = Read-PublicationJson (Join-Path $closedRoot 'layout.json')
    $operationLayout = Read-PublicationJson (Join-Path $Fixture.operationDirectory 'record-layout.json')
    Assert-Publication ($hint.schema -eq 1 -and $hint.kind -ceq 'retire-request' -and $hint.operationId -ceq $Fixture.operationId -and $hint.requiredFinalReceiptName -ceq [IO.Path]::GetFileName($Fixture.completionPath)) 'Real hint did not bind this operation and its required formal final receipt.'
    Assert-Publication ($hint.directoryIdentity -ceq $operationLayout.directoryIdentity -and $hint.metadataRootIdentity -ceq $closedLayout.metadataRootIdentity -and $hint.machineName -ceq $closedLayout.machineName -and $hint.ownerSid -ceq $closedLayout.ownerSid -and $hint.nonce -ceq $closedLayout.nonce -and $hint.nonce) 'Real hint did not bind the operation directory and private closed root.'
    $script:CaseEvidence.retirementHintPath = $path
    return @{ path = $path; value = $hint }
}
function Test-PublicationCase([string]$Name, [scriptblock]$Body) {
    if (!@($CaseFilter | Where-Object { $Name -like $_ }).Count) { return }
    # Shell復元先の長さを検証対象のcontrol状態と混ぜない。意味名はreportへ残す。
    $script:CaseRoot = Join-Path $OutputDirectory ('c' + $results.Count.ToString('000')); $null = [IO.Directory]::CreateDirectory($script:CaseRoot)
    $script:CaseEvidence = @{}; $clock = [Diagnostics.Stopwatch]::StartNew()
    try { & $Body; $results.Add(@{ name = $Name; passed = $true; milliseconds = $clock.Elapsed.TotalMilliseconds; observed = $script:CaseEvidence }) }
    catch { $results.Add(@{ name = $Name; passed = $false; milliseconds = $clock.Elapsed.TotalMilliseconds; error = $_.Exception.Message; location = $_.InvocationInfo.PositionMessage; stack = $_.ScriptStackTrace; observed = $script:CaseEvidence }) }
}

try {
    Test-PublicationCase 'changed-published-acl-does-not-gain-authority-from-pending' {
        $fixture = New-PublicationFixture
        $inventory = Get-AllPublicationInventory $fixture
        $null = Assert-PublicationRejectedUnchanged $fixture $fixture.sourceAtFailure $inventory
        Reset-PublicationSourceAcl $fixture
        $script:CaseEvidence.recovery = Complete-PublicationRestore $fixture
    }
    Test-PublicationCase 'same-attempt-sharing-retry-is-bounded-and-resumes' {
        $fixture = New-PublicationFixture; Reset-PublicationSourceAcl $fixture
        $inventory = Get-AllPublicationInventory $fixture
        $held = [IO.File]::Open((Join-Path $fixture.attemptPath 'body.json'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            foreach ($iteration in 1..2) { $null = Assert-PublicationRejectedUnchanged $fixture $fixture.original $inventory }
        } finally { $held.Dispose() }
        $script:CaseEvidence.recovery = Complete-PublicationRestore $fixture
    }
    foreach ($boundary in @('owner-only', 'body-without-ready')) {
        Test-PublicationCase ($boundary + '-interruption-resumes-through-normal-caller') {
            $fixture = New-PublicationFixture; Reset-PublicationSourceAcl $fixture
            $saved = Join-Path $script:CaseRoot 'retained-unpublished-control'; $null = [IO.Directory]::CreateDirectory($saved)
            [IO.File]::Move((Join-Path $fixture.attemptPath 'ready.json'), (Join-Path $saved 'ready.json'), $false)
            if ($boundary -eq 'owner-only') { [IO.File]::Move((Join-Path $fixture.attemptPath 'body.json'), (Join-Path $saved 'body.json'), $false) }
            $inventory = Get-AllPublicationInventory $fixture
            $maintained = Invoke-PublicationCli $fixture @('maintain', '--apply')
            Assert-Publication ((Get-AllPublicationInventory $fixture) -ceq $inventory -and !(Test-Path -LiteralPath $fixture.completionPath)) 'Maintenance promoted or rewrote an unpublished caller authority.'
            $null = Assert-NativeTree $fixture.tree $fixture.original
            $script:CaseEvidence.retainedUnpublishedEvidence = $saved
            $script:CaseEvidence.recovery = Complete-PublicationRestore $fixture
        }
    }
    foreach ($readyBoundary in @('zero', 'partial')) {
        Test-PublicationCase ('interrupted-ready-' + $readyBoundary + '-requires-current-caller-preflight') {
            $fixture = New-PublicationFixture
            $readyPath = Join-Path $fixture.attemptPath 'ready.json'
            if ($readyBoundary -eq 'zero') { [IO.File]::WriteAllBytes($readyPath, [byte[]]@()) }
            else { [IO.File]::WriteAllText($readyPath, '{"schema":', $utf8) }
            $inventory = Get-AllPublicationInventory $fixture
            $maintained = Invoke-PublicationCli $fixture @('maintain', '--apply')
            Assert-Publication ((Get-AllPublicationInventory $fixture) -ceq $inventory -and !(Test-Path -LiteralPath $fixture.completionPath)) 'Maintenance reconstructed or promoted an interrupted unpublished ready proof.'
            $null = Assert-NativeTree $fixture.tree $fixture.sourceAtFailure
            # ready再構築の許可は古いbodyだけから導かず、今の原本の検証成立が必要。
            $null = Assert-PublicationRejectedUnchanged $fixture $fixture.sourceAtFailure $inventory
            Reset-PublicationSourceAcl $fixture
            $script:CaseEvidence.recovery = Complete-PublicationRestore $fixture
        }
    }
    foreach ($bodyBoundary in @('zero', 'partial')) {
        Test-PublicationCase ('interrupted-body-' + $bodyBoundary + '-without-ready-requires-current-caller-preflight') {
            $fixture = New-PublicationFixture
            [IO.File]::Move((Join-Path $fixture.attemptPath 'ready.json'), (Join-Path $script:CaseRoot 'retained-unpublished-ready.json'), $false)
            $bodyPath = Join-Path $fixture.attemptPath 'body.json'
            if ($bodyBoundary -eq 'zero') { [IO.File]::WriteAllBytes($bodyPath, [byte[]]@()) }
            else { [IO.File]::WriteAllText($bodyPath, '{"schema":', $utf8) }
            $inventory = Get-AllPublicationInventory $fixture
            $maintained = Invoke-PublicationCli $fixture @('maintain', '--apply')
            Assert-Publication ((Get-AllPublicationInventory $fixture) -ceq $inventory -and !(Test-Path -LiteralPath $fixture.completionPath)) 'Maintenance reconstructed or promoted an interrupted body without caller preflight.'
            $null = Assert-NativeTree $fixture.tree $fixture.sourceAtFailure
            $null = Assert-PublicationRejectedUnchanged $fixture $fixture.sourceAtFailure $inventory
            Reset-PublicationSourceAcl $fixture
            $script:CaseEvidence.recovery = Complete-PublicationRestore $fixture
        }
    }
    Test-PublicationCase 'published-ready-final-same-file-id-is-reconciled' {
        $fixture = New-PublicationFixture; Reset-PublicationSourceAcl $fixture
        $body = Join-Path $fixture.attemptPath 'body.json'
        $bodyId = File-Id $body; $bodyHash = Get-PublicationDigest $body
        # 同一bodyを非上書きrenameし、実際に発行済みのowner/readyを残す中断窓を作る。
        [IO.File]::Move($body, $fixture.completionPath, $false)
        Assert-Publication ((File-Id $fixture.completionPath) -ceq $bodyId -and (Get-PublicationDigest $fixture.completionPath) -ceq $bodyHash) 'Same-ID final fixture changed its authority body.'
        $maintained = Invoke-PublicationCli $fixture @('maintain', '--apply')
        Assert-Publication ($maintained.exitCode -eq 0) "Published control reconciliation failed: $($maintained.stdout) $($maintained.stderr)"
        Assert-PublicationControlsCollected $fixture
        $script:CaseEvidence.finalBodyId = $bodyId; $script:CaseEvidence.finalBodySha256 = $bodyHash
    }
    foreach ($cleanupBoundary in @('zero', 'partial')) {
        Test-PublicationCase ('published-same-id-cleanup-' + $cleanupBoundary + '-interruption-resumes') {
            $fixture = New-PublicationFixture; Reset-PublicationSourceAcl $fixture
            $body = Join-Path $fixture.attemptPath 'body.json'; $bodyId = File-Id $body; $bodyHash = Get-PublicationDigest $body
            Move-PublicationOwnFixture $body $fixture.completionPath
            Assert-Publication ((File-Id $fixture.completionPath) -ceq $bodyId -and (Get-PublicationDigest $fixture.completionPath) -ceq $bodyHash) 'Cleanup write interruption fixture did not formally publish the same body object.'
            $cleanupPath = Join-Path $fixture.attemptPath 'cleanup.json'
            Assert-Publication (!(Test-Path -LiteralPath $cleanupPath) -and [IO.File]::Exists((Join-Path $fixture.attemptPath 'owner.json')) -and [IO.File]::Exists((Join-Path $fixture.attemptPath 'ready.json'))) 'Cleanup write interruption requires intact owner/ready and no prior cleanup.'
            if ($cleanupBoundary -eq 'zero') { [IO.File]::WriteAllBytes($cleanupPath, [byte[]]@()) }
            else { [IO.File]::WriteAllText($cleanupPath, '{"schema":', $utf8) }
            # 自作の未完成controlにも既存private controlと同じDACLを設定し、ACL拒否で経路未到達にしない。
            $ownerSecurity = [PrunletVolumeMoveVerificationIdentity]::ReadSecurity((Join-Path $fixture.attemptPath 'owner.json'))
            [PrunletVolumeMoveVerificationIdentity]::FixtureDacl($cleanupPath, $ownerSecurity)
            $expectedDacl = [Security.AccessControl.RawSecurityDescriptor]::new($ownerSecurity, 0).GetSddlForm([Security.AccessControl.AccessControlSections]::Access)
            $actualDacl = [Security.AccessControl.RawSecurityDescriptor]::new([PrunletVolumeMoveVerificationIdentity]::ReadSecurity($cleanupPath), 0).GetSddlForm([Security.AccessControl.AccessControlSections]::Access)
            Assert-Publication ($actualDacl -ceq $expectedDacl) 'Partial cleanup fixture does not have private control DACL parity.'
            $null = Assert-NativeTree $fixture.tree $fixture.original
            $maintained = Invoke-PublicationCli $fixture @('maintain', '--apply')
            Assert-Publication ($maintained.exitCode -eq 0) "Published cleanup write interruption could not resume: $($maintained.stdout) $($maintained.stderr)"
            Assert-PublicationControlsCollected $fixture
            $script:CaseEvidence.formalBodyId = $bodyId; $script:CaseEvidence.formalBodySha256 = $bodyHash
        }
    }
    Test-PublicationCase 'different-file-id-final-collision-is-preserved' {
        $fixture = New-PublicationFixture; Reset-PublicationSourceAcl $fixture
        $body = Join-Path $fixture.attemptPath 'body.json'
        # 内容だけ同じ別実体は、readyに記録した非上書きrenameの証拠にならない。
        [IO.File]::Copy($body, $fixture.completionPath, $false)
        $bodyId = File-Id $body; $finalId = File-Id $fixture.completionPath; $finalHash = Get-PublicationDigest $fixture.completionPath
        Assert-Publication ($bodyId -cne $finalId -and $finalHash -ceq (Get-PublicationDigest $body)) 'Different-ID collision fixture was not created.'
        $inventory = Get-AllPublicationInventory $fixture
        foreach ($iteration in 1..2) {
            $maintained = Invoke-PublicationCli $fixture @('maintain', '--apply')
            Assert-Publication ($maintained.exitCode -ne 0 -or @($maintained.json.warnings).Count -gt 0) 'Different-ID final was accepted as this attempt publication.'
            Assert-Publication (($maintained.stdout + $maintained.stderr) -match 'different File ID') 'Collision did not reach the ready/final File ID comparison.'
            Assert-Publication ((Get-AllPublicationInventory $fixture) -ceq $inventory -and (File-Id $fixture.completionPath) -ceq $finalId -and (Get-PublicationDigest $fixture.completionPath) -ceq $finalHash) 'Collision handling changed pending or final authority evidence.'
            $done = Join-Path (Join-Path $fixture.recovery '.closed-records-v1') ($fixture.operationId + '.done.json')
            Assert-Publication (!(Test-Path -LiteralPath $done)) 'Different-ID collision was marked cleanup-complete.'
            $null = Assert-NativeTree $fixture.tree $fixture.original
        }
        $script:CaseEvidence.retainedReason = 'Different-ID publication collision; both authorities are retained.'
    }
    Test-PublicationCase 'terminal-control-cleanup-sharing-resumes-without-changing-data' {
        $fixture = New-PublicationFixture; Reset-PublicationSourceAcl $fixture
        $ownerPath = Join-Path $fixture.attemptPath 'owner.json'; $readyPath = Join-Path $fixture.attemptPath 'ready.json'
        $ownerId = File-Id $ownerPath; $ownerHash = Get-PublicationDigest $ownerPath
        $readyId = File-Id $readyPath; $readyHash = Get-PublicationDigest $readyPath
        $closedRoot = Join-Path $fixture.recovery '.closed-records-v1'
        $summary = Join-Path $closedRoot ($fixture.operationId + '.json'); $done = Join-Path $closedRoot ($fixture.operationId + '.done.json')
        $held = [IO.File]::Open($ownerPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $restored = Invoke-PublicationCli $fixture @('restore', $fixture.operationId)
            Assert-Publication ($restored.exitCode -eq 0 -and @($restored.json.items).Count -eq 1 -and $restored.json.items[0].status -in @('restored', 'already_restored')) 'Control cleanup sharing changed successful restoration into data failure.'
            Assert-Publication (@($restored.json.warnings).Count -gt 0 -and [IO.File]::Exists($summary) -and !(Test-Path -LiteralPath $done)) 'Control sharing did not retain a committed terminal cleanup with a warning.'
            Assert-Publication ((File-Id $ownerPath) -ceq $ownerId -and (Get-PublicationDigest $ownerPath) -ceq $ownerHash -and (File-Id $readyPath) -ceq $readyId -and (Get-PublicationDigest $readyPath) -ceq $readyHash) 'Interrupted control cleanup removed or rewrote existing control evidence.'
            Assert-Publication (!(Test-Path -LiteralPath (Join-Path $fixture.attemptPath 'body.json'))) 'Authority body was not formally published before cleanup sharing failed.'
            $null = Assert-NativeTree $fixture.tree $fixture.original
            $script:CaseEvidence.blockedCleanupResponse = $restored
            $commitHash = Get-PublicationDigest $summary
        } finally { $held.Dispose() }
        $maintained = Invoke-PublicationCli $fixture @('maintain', '--apply')
        Assert-Publication ($maintained.exitCode -eq 0 -and (Get-PublicationDigest $summary) -ceq $commitHash) 'Terminal cleanup could not resume without rewriting its commit.'
        Assert-PublicationControlsCollected $fixture
    }
    foreach ($deletedControls in @('owner-only', 'ready-only', 'owner-and-ready')) {
        Test-PublicationCase ('durable-cleanup-resumes-after-' + $deletedControls + '-was-removed') {
            $fixture = New-PublicationBlockedCleanupFixture
            $saved = Join-Path $script:CaseRoot 'retained-partial-cleanup-controls'; $null = [IO.Directory]::CreateDirectory($saved)
            $cleanupDigest = Get-PublicationDigest $fixture.cleanupPath; $cleanupId = File-Id $fixture.cleanupPath
            $removed = switch ($deletedControls) { 'owner-only' { @('owner.json') }; 'ready-only' { @('ready.json') }; 'owner-and-ready' { @('owner.json', 'ready.json') } }
            foreach ($name in $removed) { Move-PublicationOwnFixture (Join-Path $fixture.attemptPath $name) (Join-Path $saved $name) }
            Assert-Publication ((Get-PublicationDigest $fixture.cleanupPath) -ceq $cleanupDigest -and (File-Id $fixture.cleanupPath) -ceq $cleanupId -and !(Test-Path -LiteralPath $fixture.donePath)) 'Partial cleanup fixture changed its durable controller or prematurely became done.'
            foreach ($name in @('owner.json', 'ready.json')) { Assert-Publication ((Test-Path -LiteralPath (Join-Path $fixture.attemptPath $name)) -eq ($name -notin $removed)) 'Partial cleanup fixture did not reach the requested control deletion boundary.' }
            $null = Assert-NativeTree $fixture.tree $fixture.original
            $maintained = Invoke-PublicationCli $fixture @('maintain', '--apply')
            Assert-Publication ($maintained.exitCode -eq 0 -and (Get-PublicationDigest $fixture.summaryPath) -ceq $fixture.summaryDigest) 'Durable cleanup did not resume from its exact inventory without rewriting the terminal summary.'
            Assert-PublicationControlsCollected $fixture
            $script:CaseEvidence.retainedRemovedControls = $saved; $script:CaseEvidence.originalCleanupSha256 = $cleanupDigest
        }
    }
    Test-PublicationCase 'unknown-field-in-real-durable-cleanup-is-preserved' {
        $fixture = New-PublicationBlockedCleanupFixture
        $cleanup = Read-PublicationJson $fixture.cleanupPath; $cleanup.unrecognizedPublicationCleanupEvidence = $true
        Save-PublicationJson $fixture.cleanupPath $cleanup
        $inventory = Get-AllPublicationInventory $fixture
        foreach ($iteration in 1..2) {
            $maintained = Invoke-PublicationCli $fixture @('maintain', '--apply')
            Assert-Publication ($maintained.exitCode -ne 0 -or @($maintained.json.warnings).Count -gt 0) 'Unknown durable cleanup field was accepted.'
            Assert-Publication ((Get-AllPublicationInventory $fixture) -ceq $inventory -and !(Test-Path -LiteralPath $fixture.donePath) -and (Get-PublicationDigest $fixture.summaryPath) -ceq $fixture.summaryDigest) 'Invalid cleanup handling changed its real control evidence or terminal commit.'
            $null = Assert-NativeTree $fixture.tree $fixture.original
        }
        $script:CaseEvidence.retainedReason = 'Unknown field in real generated durable cleanup; all control evidence is retained.'
    }
    Test-PublicationCase 'genuine-flat-schema6-restores-directly-through-typed-publication' {
        $fixture = @{ recovery = (Join-Path $script:CaseRoot 'metadata'); configPath = (Join-Path $script:CaseRoot 'config.json'); tree = (Join-Path $script:CaseRoot 'source') }
        $null = [IO.Directory]::CreateDirectory($fixture.recovery); $null = [IO.Directory]::CreateDirectory($fixture.tree)
        foreach ($index in 0..7) { [IO.File]::WriteAllText((Join-Path $fixture.tree ('file-{0:D2}.bin' -f $index)), ('legacy-publication-' + $index), $utf8) }
        $fixture.original = Snapshot-NativeTree $fixture.tree
        $init = Invoke-PublicationCli $fixture @('init', '--backup-directory', $fixture.recovery) $BaselineExecutablePath
        Assert-Publication ($init.exitCode -eq 0) 'Genuine flat fixture init failed.'
        $config = Read-PublicationJson $fixture.configPath
        $config.volumeRecoveryDirectories = @{ 'D:\' = (Join-Path $script:CaseRoot 'volume-store') }
        Save-PublicationJson $fixture.configPath $config
        $paths = Join-Path $script:CaseRoot 'legacy-paths.json'; Save-PublicationJson $paths @($fixture.tree)
        $deleted = Invoke-PublicationCli $fixture @('delete', '--recursive', '--paths-file', $paths) $BaselineExecutablePath
        Assert-Publication ($deleted.exitCode -eq 0 -and @($deleted.json.items).Count -eq 1 -and $deleted.json.items[0].status -eq 'deleted' -and !(Test-Path -LiteralPath $fixture.tree)) 'Genuine flat schema 6 fixture delete failed.'
        $fixture.operationId = $deleted.json.operationId
        $legacy = Join-Path $fixture.recovery $fixture.operationId
        $manifest = Read-PublicationJson (Join-Path $legacy 'recycle-manifest.json')
        Assert-Publication ($manifest.schema -eq 6 -and !(Test-Path -LiteralPath (Join-Path $fixture.recovery '.recycle-records-v1'))) 'Baseline did not produce a genuine flat schema 6 operation.'
        $script:CaseEvidence.operationId = $fixture.operationId
        # maintain等の事前移行を挟まず、利用者の直接restore経路を通す。
        $script:CaseEvidence.recovery = Complete-PublicationRestore $fixture
        Assert-Publication (![IO.Directory]::Exists($legacy)) 'Direct restore left the legacy active record behind.'
        $layout = Read-PublicationJson (Join-Path (Join-Path $fixture.recovery '.recycle-records-v1') 'layout.json')
        Assert-Publication ($layout.publicationProtocol -eq 1) 'Direct restore did not establish typed publication authority.'
    }
    foreach ($damage in @('owner-json', 'descriptor-json', 'owner-binding', 'owner-dependency', 'descriptor-body-id', 'owner-unknown-field', 'descriptor-unknown-field', 'owner-missing', 'body-bytes', 'unknown-member', 'owner-zero', 'owner-partial', 'body-zero', 'body-partial')) {
        Test-PublicationCase ('invalid-control-' + $damage + '-is-preserved') {
            $fixture = New-PublicationFixture; Reset-PublicationSourceAcl $fixture
            $name = switch -Wildcard ($damage) { 'owner-*' { 'owner.json'; break }; 'descriptor-*' { 'ready.json'; break }; 'body-*' { 'body.json'; break }; default { 'unknown-evidence.bin' } }
            $target = Join-Path $fixture.attemptPath $name
            if ($damage -eq 'owner-missing') { [IO.File]::Move($target, (Join-Path $script:CaseRoot 'retained-missing-owner.json'), $false) }
            elseif ($damage -in @('owner-binding', 'owner-dependency')) {
                $owner = Read-PublicationJson $target
                if ($damage -eq 'owner-binding') { $owner.operationDirectoryIdentity = '00000000:0000000000000000' }
                else {
                    Assert-Publication (@($owner.dependencies).Count -gt 0) 'Real completion owner omitted dependencies for dependency-tamper fixture.'
                    $owner.dependencies[0].sha256 = '0' * 64
                }
                Save-PublicationJson $target $owner
                # owner本文hashだけの不一致にせず、binding/依存証拠の検査まで到達させる。
                $readyPath = Join-Path $fixture.attemptPath 'ready.json'; $ready = Read-PublicationJson $readyPath
                $ready.ownerSha256 = Get-PublicationDigest $target; Save-PublicationJson $readyPath $ready
            }
            elseif ($damage -eq 'descriptor-body-id') {
                $ready = Read-PublicationJson $target; $ready.bodyIdentity = '00000000:0000000000000000'; Save-PublicationJson $target $ready
            }
            elseif ($damage.EndsWith('-unknown-field')) {
                $control = Read-PublicationJson $target; $control.unrecognizedPublicationEvidence = $true; Save-PublicationJson $target $control
                if ($damage -eq 'owner-unknown-field') {
                    $readyPath = Join-Path $fixture.attemptPath 'ready.json'; $ready = Read-PublicationJson $readyPath
                    $ready.ownerSha256 = Get-PublicationDigest $target; Save-PublicationJson $readyPath $ready
                }
            }
            elseif ($damage.EndsWith('-zero')) { [IO.File]::WriteAllBytes($target, [byte[]]@()) }
            elseif ($damage.EndsWith('-partial')) { [IO.File]::WriteAllText($target, '{"schema":', $utf8) }
            elseif ($damage -eq 'body-bytes') { [IO.File]::WriteAllText($target, 'modified-publication-body', $utf8) }
            elseif ($damage -eq 'unknown-member') { [IO.File]::WriteAllText($target, 'preserve-unknown-member', $utf8) }
            else { [IO.File]::WriteAllText($target, '{"schema":999}', $utf8) }
            $inventory = Get-AllPublicationInventory $fixture
            $null = Assert-PublicationRejectedUnchanged $fixture $fixture.original $inventory
            # 改変/未知controlは正規の削除対象へ付け替えず、そのまま保持する。
            $script:CaseEvidence.retainedReason = 'Negative control fixture; inspected evidence is intentionally retained.'
            $script:CaseEvidence.modifiedControl = $target
        }
    }
    foreach ($hintBoundary in @('missing-final', 'invalid-root-binding')) {
        Test-PublicationCase ('retirement-hint-' + $hintBoundary + '-does-not-inspect-operation-body') {
            $fixture = New-PublicationFixture; Reset-PublicationSourceAcl $fixture
            $hint = Get-PublicationRequiredFinalHint $fixture
            $hintBytes = [IO.File]::ReadAllBytes($hint.path); $hintId = File-Id $hint.path
            $manifestPath = Join-Path $fixture.operationDirectory 'recycle-manifest.json'
            $manifestBytes = [IO.File]::ReadAllBytes($manifestPath); $manifestId = File-Id $manifestPath
            $originalControls = Get-AllPublicationInventory $fixture
            $attempts = @(Get-PublicationAttempts $fixture)
            Assert-Publication ($attempts.Count -gt 0) 'Hint gate fixture requires a real pending authority namespace.'
            $savedRoot = Join-Path $script:CaseRoot 'h'; $null = [IO.Directory]::CreateDirectory($savedRoot)
            $moved = [Collections.Generic.List[object]]::new()
            try {
                # publication依存hashの検査と、required-final待機gateの本文非読取りを切り離す。
                foreach ($attempt in $attempts) {
                    $saved = Join-Path $savedRoot $attempt.Name
                    Move-PublicationOwnFixture $attempt.FullName $saved
                    $moved.Add(@{ original = $attempt.FullName; saved = $saved })
                }
                Assert-Publication (@(Get-PublicationAttempts $fixture).Count -eq 0) 'Pending publication namespaces remained in the metadata scan scope.'
                $invalid = [byte[]]::new($manifestBytes.Length); [Array]::Fill[byte]($invalid, 32); $invalid[0] = 123
                [IO.File]::WriteAllBytes($manifestPath, $invalid)
                Assert-Publication ((Get-Item -LiteralPath $manifestPath).Length -eq $manifestBytes.Length -and (File-Id $manifestPath) -ceq $manifestId) 'Hint gate fixture changed manifest identity or length.'
                if ($hintBoundary -eq 'invalid-root-binding') {
                    $value = $hint.value
                    Assert-Publication ($value.metadataRootIdentity -cmatch '^[a-f0-9]{8}:[a-f0-9]{16}$') 'Real hint root identity does not use the expected native identity shape.'
                    $first = if ($value.metadataRootIdentity[0] -ceq '0') { '1' } else { '0' }
                    $value.metadataRootIdentity = $first + $value.metadataRootIdentity.Substring(1)
                    Assert-Publication ($value.metadataRootIdentity -cne (Read-PublicationJson $hint.path).metadataRootIdentity -and $value.metadataRootIdentity -cmatch '^[a-f0-9]{8}:[a-f0-9]{16}$') 'Hint tamper did not preserve native identity shape while changing its binding.'
                    Save-PublicationJson $hint.path $value
                }
                $expectedHint = Get-PublicationDigest $hint.path
                $operationInventory = Get-PublicationInventory $fixture.operationDirectory
                foreach ($iteration in 1..2) {
                    $maintained = Invoke-PublicationCli $fixture @('maintain', '--apply')
                    $warnings = @($maintained.json.warnings) -join "`n"
                    if ($hintBoundary -eq 'missing-final') {
                        $expected = 'Retirement hint ' + $fixture.operationId + ' is waiting for formal receipt ' + $hint.value.requiredFinalReceiptName + '; the operation body was not inspected.'
                        Assert-Publication ($maintained.exitCode -eq 1 -and $maintained.json.complete -eq $false -and $maintained.json.budgetSatisfied -eq $true -and $maintained.json.capacityKnown -eq $true -and $maintained.json.recordAuditRequested -eq $false -and $warnings.Contains($expected) -and @($maintained.json.warnings | Where-Object { $_ -cne $expected }).Count -eq 0) 'Required-final waiting did not reach the explicit lightweight hint gate with only its pending warning.'
                    } else {
                        Assert-Publication ($warnings.Contains('Retirement hint root binding is invalid.') -and !$warnings.Contains('the operation body was not inspected.')) 'Root binding tamper did not reach its dedicated hint-binding rejection gate.'
                        $allowed = @(
                            ('Retirement request ' + $fixture.operationId + '.request.json was retained: Retirement hint root binding is invalid.'),
                            ('Closed record ' + $fixture.operationId + '.request.json could not be fully reconciled and was retained: Retirement hint root binding is invalid.'),
                            'Recovery capacity is unknown because some data is busy or cannot be safely inspected.'
                        )
                        Assert-Publication ($maintained.exitCode -eq 1 -and $maintained.json.capacityKnown -eq $false -and $maintained.json.recordAuditRequested -eq $false -and @($maintained.json.warnings).Count -eq 3 -and @($maintained.json.warnings | Where-Object { $_ -cnotin $allowed }).Count -eq 0) 'Invalid hint emitted an unrelated diagnostic instead of only its binding rejection.'
                    }
                    Assert-Publication ($warnings -notmatch '(?i)(Recycle metadata JSON|Recycle manifest|Operation manifest|Operation body).*(invalid|corrupt|parse|cannot|failed)|(?:invalid|corrupt|parse|cannot|failed).*(Recycle metadata JSON|Recycle manifest|Operation manifest)') 'Required-final hint handling inspected or diagnosed the deliberately invalid operation body.'
                    Assert-Publication (!(Test-Path -LiteralPath $fixture.completionPath) -and (File-Id $hint.path) -ceq $hintId -and (Get-PublicationDigest $hint.path) -ceq $expectedHint -and (Get-PublicationInventory $fixture.operationDirectory) -ceq $operationInventory -and @(Get-PublicationAttempts $fixture).Count -eq 0) 'Hint waiting changed source metadata, rewrote its request or reconstructed authority controls.'
                    foreach ($entry in $moved) { Assert-Publication ([IO.Directory]::Exists($entry.saved) -and !(Test-Path -LiteralPath $entry.original)) 'Hint gate escaped its isolated publication-control boundary.' }
                    $null = Assert-NativeTree $fixture.tree $fixture.original
                }
                $script:CaseEvidence.hintGate = $hintBoundary
            } finally {
                [IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
                [IO.File]::WriteAllBytes($hint.path, $hintBytes)
                foreach ($entry in $moved) { Move-PublicationOwnFixture $entry.saved $entry.original }
            }
            Assert-Publication ((File-Id $manifestPath) -ceq $manifestId -and (File-Id $hint.path) -ceq $hintId -and (Get-AllPublicationInventory $fixture) -ceq $originalControls) 'Hint gate fixture rollback changed the original evidence identities or authority controls.'
            $script:CaseEvidence.recovery = Complete-PublicationRestore $fixture
            Assert-Publication (!(Test-Path -LiteralPath $hint.path)) 'Normal recovery left its required-final retirement request behind.'
        }
    }
} finally {
    foreach ($name in $previousEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process') }
}
if (!$results.Count) { $results.Add(@{ name = 'case-filter-matched-no-cases'; passed = $false; error = 'CaseFilter matched no publication lifecycle cases.' }) }
if ($CaseFilter.Count -eq 1 -and $CaseFilter[0] -ceq '*' -and $results.Count -ne 34) { $results.Add(@{ name = 'default-coverage-count'; passed = $false; error = 'Expected all 34 publication lifecycle cases.' }) }
$report = @{ schema = 1; passed = @($results | Where-Object passed -eq $true).Count; failed = @($results | Where-Object passed -ne $true).Count
    results = @($results); expectedDefaultCases = 34; caseFilter = $CaseFilter; fixtureGenerators = @($generators); generatorOnlyCountedAsCoverage = $false; commands = @($commands); aclEvidence = @($script:AclEvidence)
    sourceSha256 = Get-PublicationDigest $PSCommandPath; generatorSourceSha256 = $generatorSha; executablePath = $ExecutablePath; executableSha256 = Get-PublicationDigest $ExecutablePath
    baselineExecutablePath = $BaselineExecutablePath; baselineExecutableSha256 = Get-PublicationDigest $BaselineExecutablePath; retainedDirectory = $OutputDirectory }
Save-PublicationJson $ReportPath $report
$report | Select-Object passed, failed | ConvertTo-Json
if ($report.failed) { exit 1 }
