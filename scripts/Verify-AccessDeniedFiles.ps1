[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$RustProbePath,[Parameter(Mandatory)][string]$BuildManifestPath,[Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedBuildManifestSha256,[Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
. (Join-Path $PSScriptRoot 'FileFixtures.Common.ps1')
$null=Initialize-PrunletFixtureBinding -ExecutablePath $ExecutablePath -BuildManifestPath $BuildManifestPath -ExpectedBuildManifestSha256 $ExpectedBuildManifestSha256
foreach ($path in @($ExecutablePath,$RustProbePath,$BuildManifestPath,$OutputDirectory,$ReportPath)) { if (![IO.Path]::IsPathFullyQualified($path)) { throw 'Absolute paths required.' } }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
if ($ReportPath.Equals($OutputDirectory.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or $ReportPath.StartsWith($OutputDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'ReportPath must be outside OutputDirectory.' }
foreach ($path in @($OutputDirectory, $ReportPath)) {
    Assert-VerificationDestination $path @($repo, (Join-Path $env:USERPROFILE '.codex'))
    if ([IO.Path]::GetPathRoot($path) -ine 'D:\' -or (Test-Path -LiteralPath $path)) { throw 'Unused external D output required.' }
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { throw 'Output parent must exist.' }
}
. (Join-Path $PSScriptRoot 'recordless-e2e/RustFileProbe.Common.ps1')
$buildBinding=Assert-RustFileProbeBinding
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$volumeRoot = [IO.Path]::GetPathRoot($OutputDirectory)
$settingEnvelope=Invoke-RustFileContract 'file-immediate-delete-setting' $OutputDirectory
$setting=$settingEnvelope.result
if (!$setting.confirmed) { throw 'Candidate Rust Core could not confirm immediate-delete configuration; no deletion fixtures were created or deleted.' }
function Assert-CurrentImmediateSettingA {
    $current=Invoke-RustFileContract 'file-immediate-delete-setting' $OutputDirectory
    if(!$current.result.confirmed -or $current.result.sid -cne $setting.sid -or $current.result.volume -cne $setting.volume) { throw 'Effective user or immediate-delete volume setting changed; deletion stopped.' }
    return $current
}
$preconditions = @{ outputDirectory = $OutputDirectory; reportPath = $ReportPath; settingProbePath = $OutputDirectory; volumeRoot = $volumeRoot; sid = $setting.sid; volume = $setting.volume; immediateDeleteConfirmed = $true; nativeProbe=$settingEnvelope }
$script:fixtureRun = $null
$script:temp = Join-Path $OutputDirectory 'temp'; $null = [IO.Directory]::CreateDirectory($script:temp)
$oldTemp = $env:TEMP; $oldTmp = $env:TMP; $env:TEMP = $script:temp; $env:TMP = $script:temp
$common = Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1'; . $common
$script:commands = [Collections.Generic.List[object]]::new(); $results = [Collections.Generic.List[object]]::new()
$helpers = @('FileFixtures.Common.ps1', 'SparseFixtures.Common.ps1', 'FixtureBridge.Common.ps1') | ForEach-Object { Join-Path $PSScriptRoot $_ }
$sources = @(@($PSCommandPath, $common, (Join-Path $PSScriptRoot 'Verification-Common.ps1')) + $helpers | ForEach-Object { @{ path = $_; sha256 = (Get-FileHash -LiteralPath $_).Hash } })
$sources+=@(Get-RustFileProbeSourceHashes)
try {
    foreach ($transport in @('cli', 'mcp')) { foreach ($mode in @('pending-root', 'pending-child', 'acl-preflight')) {
        $name = "$transport-$mode"; $script:observed = @{}; $holder = $null; $parentHolder = $null; $session = $null; $binRoots = @()
        try {
            # 実効user/volume設定を変えず、fixture作成前とCLI/MCP要求前に同じ候補Coreで再照合する。
            $script:observed.settingBeforeFixture=Assert-CurrentImmediateSettingA
            $s = New-ScopeR ($name + '-' + [guid]::NewGuid().ToString('N')) -HostVolume
            $target = [IO.Path]::GetFullPath((File-R $s 'tree/registry.json.bak.10')); $tree = [IO.Path]::GetDirectoryName($target); $sibling = File-R $s 'unrelated'
            $before = Snapshot-R $target; $siblingBefore = Snapshot-R $sibling
            # 設定の原子的固定はできない。予期しない回収も自分の実体だけを識別し、自動復元しない。
            $binRoots = @(@{ path = $target; kind = 'file'; id = $before[0].Id; prior = Before-BinR $before }, @{ path = $sibling; kind = 'file'; id = $siblingBefore[0].Id; prior = Before-BinR $siblingBefore })
            if ($mode -eq 'pending-child') { $treeBefore = Snapshot-R $tree; $binRoots += @{ path = $tree; kind = 'directory'; id = $treeBefore[0].Id; prior = Before-BinR $treeBefore } }
            $script:observed.binTracking = @{ roots = $binRoots; newItems = @(); identificationErrors = @(); automaticRecovery = $false; scope = 'Only Bin entries whose path and native identity can be inspected are matched. The existing locator may omit inaccessible entries; zero matches do not prove complete absence.' }
            $holder = (New-FileFixtureAccessLease -Path $target -Scope $s.files -WritableAcl:($mode -eq 'acl-preflight'))
            $heldBefore = $holder.State(); $script:observed.before = $heldBefore; $script:observed.target = $target; $script:observed.retained = $s.root
            Assert-R (!$heldBefore.deletePending -and $heldBefore.id -ceq $before[0].Id) 'Initial fixed identity/pending state mismatch'
            if ($mode -eq 'acl-preflight') {
                $parentHolder = (New-FileFixtureAccessLease -Path $tree -Scope $s.files -WritableAcl); $parentHolder.DenyDelete($true); $holder.DenyDelete($false)
                $setup = $holder.State(); $script:observed.setup = $setup
                Assert-R (!$setup.deletePending -and $setup.security -cne $heldBefore.security) 'DACL fixture was not isolated from pending deletion'
                $openError = (Get-FileFixtureOpenError -Path $target -Access 0x10080); $script:observed.setupDeleteOpenError = $openError
                Assert-R ($openError -eq 5) 'DACL fixture did not reject the production DELETE|READ_ATTRIBUTES rights'
            }
            $paths = if ($mode -eq 'pending-child') { @($tree) } elseif ($mode -eq 'acl-preflight') { @($sibling, $target) } else { @($target) }
            $script:observed.settingBeforeDeletion=Assert-CurrentImmediateSettingA
            if ($transport -eq 'cli') {
                $response = Delete-R $s $paths -Recursive; $script:observed.response = $response
                Assert-R ($response.exitCode -ne 0) 'Expected deletion failure was successful'
                $text = if ($mode -eq 'acl-preflight') { $response.json.error } else { $response.json.items[0].error }
                $body = $response.json
            } else {
                $session = Open-McpR $s; Init-McpR $session
                $response = Rpc-R $session @{ jsonrpc = '2.0'; id = 2; method = 'tools/call'; params = @{ name = 'delete_files'; arguments = @{ paths = @($paths); recursive = $true } } }
                $script:observed.response = $response
                Assert-R ($response.result.isError -and $response.result.content.Count -eq 1) 'MCP non-success was not preserved'
                $wire = $response.result.content[0].text
                if ($mode -eq 'acl-preflight') { $text = $wire; $body = $null } else { $body = $wire | ConvertFrom-Json -AsHashtable -Depth 30; $text = $body.items[0].error }
                Close-McpR $session; $session = $null
            }
            $after = $holder.State(); $script:observed.after = $after
            Assert-R ($after.id -ceq $heldBefore.id) 'The observed fixed identity changed'
            Assert-R ($text.Contains('native error 5') -and $text.Contains('error 5 alone does not identify the cause')) 'Native access denial or qualified explanation missing'
            if ($mode -eq 'acl-preflight') {
                Assert-R (!$after.deletePending -and $text.Contains('original targets were retained') -and !$text.Contains('Windows accepted a deletion request')) 'Preflight denial was misreported as accepted deletion'
                $holder.Dispose(); $holder = $null; $parentHolder.Dispose(); $parentHolder = $null
                $script:observed.restored = Assert-SnapshotR $target $before
            } else {
                Assert-WireR @{ json = $body } $paths @('ambiguous')
                Assert-R ($after.deletePending -and $after.security -ceq $heldBefore.security) 'Pending deletion was not observed with unchanged security'
                Assert-R ($text.Contains('Windows accepted a deletion request for the previously fixed object') -and $text.Contains('after Prunlet closed its deletion handle') -and $text.Contains($target)) 'Post-disposition stage or entry name missing'
                $script:observed.attributesOpenError = (Get-FileFixtureOpenError -Path $target -Access 0x80)
                $script:observed.securityOpenError = (Get-FileFixtureOpenError -Path $target -Access 0x20000)
                Assert-R ($script:observed.attributesOpenError -eq 5 -and $script:observed.securityOpenError -eq 5) 'Pending deletion did not reproduce native access denial'
                $holder.Dispose(); $holder = $null
                $absent = (Get-FileFixtureOpenError -Path $target -Access 0x80); $script:observed.afterReleaseOpenError = $absent
                Assert-R ($absent -in @(2, 3)) 'The pending name did not disappear after its holder was released'
            }
            $script:observed.siblingAfter = Assert-SnapshotR $sibling $siblingBefore
            No-FileRecordsR $s
            $results.Add(@{ name = $name; passed = $true; observed = $script:observed })
        } catch { $results.Add(@{ name = $name; passed = $false; error = $_.Exception.Message; stack = $_.ScriptStackTrace; observed = $script:observed }) }
        finally {
            $newItems = @(); $identificationErrors = @()
            $reportedRecycled = @()
            if ($script:observed.response) {
                $returned = $script:observed.response.json
                if (!$returned -and $script:observed.response.result.content) {
                    try { $returned = $script:observed.response.result.content[0].text | ConvertFrom-Json -AsHashtable -Depth 30 } catch { $returned = $null }
                }
                $reportedRecycled = @($returned.items | Where-Object status -eq 'recycled' | ForEach-Object path)
            }
            foreach ($root in $binRoots) {
                try {
                    $new = @((Find-FileFixtureBinIdentity -ExpectedId ($root.id)) | Where-Object { $_.Pidl -notin $root.prior })
                    foreach ($item in $new) { $newItems += @{ originalPath = $root.path; kind = $root.kind; nativeId = $root.id; physicalPath = $item.PhysicalPath } }
                    if (!$new.Count -and $root.path -in $reportedRecycled) { $identificationErrors += ($root.path + ': recycling was reported but no new owned Bin identity could be located; retained without recovery') }
                    if ($new.Count -gt 1) { $identificationErrors += ($root.path + ': multiple new owned Bin entries; retained without recovery') }
                } catch { $identificationErrors += ($root.path + ': ' + $_.Exception.Message) }
            }
            if ($script:observed.binTracking) { $script:observed.binTracking.newItems = $newItems; $script:observed.binTracking.identificationErrors = $identificationErrors }
            if ($newItems.Count -or $identificationErrors.Count) {
                $caseResult = $results[$results.Count - 1]; $caseResult.passed = $false
                $caseResult.error = [string]$caseResult.error + ' Unexpected owned Bin entries or incomplete identification; inspect binTracking. No recovery or deletion was attempted.'
            }
            if ($session) { Close-McpR $session }
            foreach ($lease in @($holder,$parentHolder)) {
                if (!$lease) { continue }
                try { $lease.Dispose() }
                catch {
                    $caseResult = $results[$results.Count - 1]; $caseResult.passed = $false
                    $caseResult.error = [string]$caseResult.error + ' Fixture lease release failed; do not resend: ' + $_.Exception.Message
                }
                if ($lease.ReleaseState -eq 'unknown') {
                    if (!$script:observed.unknownLeaseReleases) { $script:observed.unknownLeaseReleases = [Collections.Generic.List[object]]::new() }
                    $script:observed.unknownLeaseReleases.Add(@{leaseId=$lease.LastLeaseId;state='unknown';resubmitted=$false})
                }
            }
        }
    } }
} finally {
    $report = @{ suite = 'access-denied-pending-and-dacl'; executablePath = $ExecutablePath; executableSha256 = (Get-FileHash -LiteralPath $ExecutablePath).Hash; rustProbePath=$RustProbePath; sameSourceBuild=$buildBinding; preconditions = $preconditions; sources = $sources; expectedCount = 6; executedCount = $results.Count; passed = @($results | Where-Object passed).Count; failed = @($results | Where-Object { !$_.passed }).Count; results = @($results); commands = @($script:commands); retained = $OutputDirectory }
    Save-R $ReportPath $report; $env:TEMP = $oldTemp; $env:TMP = $oldTmp
}
$report | Select-Object passed, failed, expectedCount, executedCount | ConvertTo-Json -Compress
if ($report.failed -or $report.executedCount -ne $report.expectedCount) { exit 1 }
