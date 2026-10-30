[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [switch]$Execute
)
$ErrorActionPreference = 'Stop'
# 想定する失敗: dry-runでの変更、入力順や状態の取り違え、通常rootの永久削除、
# 巨大rootのBin移動、共有リンクの内容・ID・リンク数の破損、操作記録の作成、
# dry-runの完全ACL変更、削除後のBinと残存リンク間の完全ACL不一致、
# 不明結果の再送、PIDLやIDを誤認した別項目への操作、sparseの回収不能。
# 終了時は全fixtureと照合済みBin項目を保持し、残存sparseだけ元の証拠と
# 単独リンク・prefix・割当範囲のゼロをRestoreTinyで検証してから縮小する。
# 証拠不足・競合・曖昧な場所は変更せず、reportに理由と対象を残す。
if (!$Execute) { throw 'Pass -Execute only when this E2E run is explicitly requested.' }
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'Absolute paths required.' }
    if (![IO.Path]::GetPathRoot([IO.Path]::GetFullPath($path)).Equals('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'External D paths required.' }
    Assert-VerificationDestination ([IO.Path]::GetFullPath($path)) @($repo, (Join-Path $env:USERPROFILE '.codex'))
}
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
if (![IO.File]::Exists($ExecutablePath)) { throw 'Candidate executable missing.' }
foreach ($path in @($OutputDirectory, $ReportPath)) {
    if (Test-Path -LiteralPath $path) { throw 'Unused output and report required.' }
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { throw 'Output and report parents must exist.' }
}
if ($ReportPath.StartsWith($OutputDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Report must be outside the unused output directory.' }
$reportProbe = [IO.File]::Open($ReportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$reportProbe.Dispose()
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$script:temp = Join-Path $OutputDirectory 'temp'
$null = [IO.Directory]::CreateDirectory($script:temp)
$oldTemp = $env:TEMP; $oldTmp = $env:TMP
$env:TEMP = $script:temp; $env:TMP = $script:temp
. (Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1')
$script:commands = [Collections.Generic.List[object]]::new()
$results = [Collections.Generic.List[object]]::new()
$helperFiles = @('NativeShellFixture.cs', 'FixtureNative.cs', 'OwnedBinLocator.cs') | ForEach-Object { Join-Path (Join-Path $PSScriptRoot 'recordless-e2e') $_ }

function Assert-SharedSnapshot($Expected, $Actual, [int]$Links, [switch]$WindowsManaged) {
    Assert-R ($Expected.Count -eq 1 -and $Actual.Count -eq 1) 'Expected a single shared file.'
    $fields=if ($WindowsManaged) { @('Id') } else { @('Id', 'Attributes', 'Directory', 'ReparseTag', 'ReparseBase64', 'SecurityBase64') }
    foreach ($field in $fields) {
        Assert-R ($Expected[0].$field -ceq $Actual[0].$field) ('Shared file ' + $field + ' changed.')
    }
    Assert-R ($Actual[0].NumberOfLinks -eq $Links) 'Shared file link count changed unexpectedly.'
    Assert-R (($Expected[0].Streams | ConvertTo-Json -Depth 10 -Compress) -ceq ($Actual[0].Streams | ConvertTo-Json -Depth 10 -Compress)) 'Shared file stream bytes changed.'
}
function Assert-SparseUnchanged($Before, $After) {
    foreach ($field in @('Id', 'SecurityBase64', 'Attributes', 'Length', 'NumberOfLinks', 'AllocationSize', 'CompressedSize')) {
        Assert-R ($Before.$field -ceq $After.$field) ('Sparse ' + $field + ' changed.')
    }
}
function Get-SparseRanges([string]$Path, [long]$Length) {
    # 既存のbounded範囲照会を使い、hole以外の全バイトを読んで比較する。
    $method=[PrunletSparseE2E].GetMethod('QueryRanges',[Reflection.BindingFlags]'NonPublic,Static')
    Assert-R ($null -ne $method) 'Sparse range query unavailable.'
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try {
        $ranges=$method.Invoke($null,[object[]]@($stream.SafeFileHandle,$Length,[ulong]1048576))
        $proofs=[Collections.Generic.List[object]]::new()
        foreach ($range in $ranges) {
            $bytes=[byte[]]::new([int]$range.Length); $stream.Position=$range.Offset; $stream.ReadExactly($bytes)
            $proofs.Add(@{offset=$range.Offset; length=$range.Length; sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))})
        }
        return ,$proofs.ToArray()
    } finally { $stream.Dispose() }
}
function Get-FolderProof([string]$Path) {
    $item=Get-Item -LiteralPath $Path -Force
    return @{id=[Prunlet.RecordlessE2E.FixtureNative]::Identity($Path); attributes=[int]$item.Attributes; security=[Convert]::ToBase64String((Get-Acl -LiteralPath $Path).GetSecurityDescriptorBinaryForm()); children=@(Get-ChildItem -LiteralPath $Path -Force | ForEach-Object Name | Sort-Object)}
}
function New-BinItems([string]$Id, [string[]]$Prior) {
    return @([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($Id) | Where-Object { $_.Pidl -cnotin $Prior })
}
function Test-Mixed([string]$Mode) {
    $script:observed = @{ mode=$Mode; retained=$OutputDirectory; cleanup='All owned fixtures and Bin entries retained; no deletion is retried.' }
    $scope=$null; $session=$null; $sparse=$null; $before=$null; $rootId=$null; $rootPrior=@(); $sparsePrior=@(); $failure=$null
    try {
        $scope = New-ScopeR ('mixed-' + $Mode)
        $ordinary = File-R $scope 'ordinary'
        $ordinary2 = Join-Path $scope.files 'ordinary-second'
        $root = Join-Path $scope.files 'oversize-folder'
        $null = [IO.Directory]::CreateDirectory($root)
        $inside = Join-Path $root 'shared'
        $alias = Join-Path $scope.files 'outside-alias'
        [Prunlet.RecordlessE2E.FixtureNative]::CreateHardlink($ordinary2, $ordinary)
        [Prunlet.RecordlessE2E.FixtureNative]::CreateHardlink($inside, $ordinary)
        [Prunlet.RecordlessE2E.FixtureNative]::CreateHardlink($alias, $ordinary)
        $before = Snapshot-R $alias
        Assert-R ($before[0].NumberOfLinks -eq 4) 'Four shared links required.'
        $prior = [string[]]@(Before-BinR $before)
        $rootId = [Prunlet.RecordlessE2E.FixtureNative]::Identity($root)
        $rootPrior = [string[]]@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($rootId) | ForEach-Object Pidl)
        $sparsePath = Join-Path $root 'huge-sparse'
        $prefix = $utf8.GetBytes('owned sparse prefix; allocated tails must stay zero')
        $script:observed.sparsePath = $sparsePath
        $stream = [IO.FileStream]::new($sparsePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { [PrunletSparseE2E]::MakeSparse($stream.SafeFileHandle); $stream.Write($prefix,0,$prefix.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        $proof = [PrunletSparseE2E]::CaptureProof($sparsePath)
        $sparse = @{ path=$sparsePath; prefix=$prefix; proof=$proof; logical=[long]1099511627776 }
        $sparsePrior = [string[]]@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($proof.Id) | ForEach-Object Pidl)
        $script:observed.sparseInitialProof=$proof
        $stream = [IO.FileStream]::new($sparsePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { $stream.SetLength($sparse.logical); $stream.Flush($true) } finally { $stream.Dispose() }
        $grown = [PrunletSparseE2E]::CaptureProof($sparsePath)
        foreach ($field in @('Id','SecurityBase64','Attributes','NumberOfLinks')) { Assert-R ($proof.$field -ceq $grown.$field) ('Sparse ' + $field + ' changed during creation.') }
        $proof=$grown; $sparse.proof=$proof
        $ranges=Get-SparseRanges $sparsePath $sparse.logical
        $folderProof=Get-FolderProof $root
        $script:observed.fixture = @{ ordinary=$ordinary; ordinarySecond=$ordinary2; folder=$root; inside=$inside; alias=$alias; shared=$before; sparse=$proof; sparseRanges=$ranges; folderProof=$folderProof; priorShared=$prior; priorFolder=$rootPrior; priorSparse=$sparsePrior }
        Assert-R ($proof.Length -eq $sparse.logical -and $proof.NumberOfLinks -eq 1 -and $proof.AllocationSize -le 1MB -and $proof.CompressedSize -le 1MB) 'Sparse shape invalid.'
        $paths = @($ordinary, $ordinary2, $root)
        if ($Mode -eq 'mcp') { $session=Open-McpR $scope; Init-McpR $session; $dry=Call-McpR $session 2 'delete_files' @{paths=$paths; dryRun=$true; recursive=$true}; Assert-R (!$dry.failed) 'MCP dry-run failed.' }
        else { $dry=Delete-R $scope $paths -Recursive -DryRun; Assert-R ($dry.exitCode -eq 0) 'CLI dry-run failed.' }
        $script:observed.dry=$dry
        Assert-WireR $dry $paths @('would_recycle','would_recycle','would_recycle') $true
        Assert-R ($dry.json.items[0].kind -ceq 'file' -and $dry.json.items[1].kind -ceq 'file' -and $dry.json.items[2].kind -ceq 'directory') 'Dry-run kinds changed.'
        Assert-R (@($dry.json.warnings | Where-Object { $_ -match '(?i)dry.run' -and $_ -match '(?i)permanent' }).Count -gt 0) 'Dry-run permanent-deletion warning missing.'
        foreach ($path in @($ordinary,$ordinary2,$inside,$alias)) { Assert-SharedSnapshot $before (Snapshot-R $path) 4 }
        Assert-R (($folderProof | ConvertTo-Json -Depth 10 -Compress) -ceq ((Get-FolderProof $root) | ConvertTo-Json -Depth 10 -Compress)) 'Folder changed during dry-run.'
        Assert-SparseUnchanged $proof ([PrunletSparseE2E]::CaptureProof($sparsePath))
        Assert-R (($ranges | ConvertTo-Json -Depth 10 -Compress) -ceq ((Get-SparseRanges $sparsePath $sparse.logical) | ConvertTo-Json -Depth 10 -Compress)) 'Sparse allocated content changed during dry-run.'
        Assert-R (@(New-BinItems $before[0].Id $prior).Count -eq 0) 'Dry-run created a shared-file Bin item.'
        Assert-R (@(New-BinItems $rootId $rootPrior).Count -eq 0) 'Dry-run created a folder Bin item.'
        Assert-R (@(New-BinItems $proof.Id $sparsePrior).Count -eq 0) 'Dry-run created a sparse Bin item.'
        No-FileRecordsR $scope
        if ($Mode -eq 'mcp') { $result=Call-McpR $session 3 'delete_files' @{paths=$paths; recursive=$true}; $script:observed.delete=$result; Assert-R (!$result.failed) 'MCP delete failed.' }
        else { $result=Delete-R $scope $paths -Recursive; $script:observed.delete=$result; Assert-R ($result.exitCode -eq 0) 'CLI delete failed.' }
        Assert-WireR $result $paths @('recycled','recycled','permanently_deleted')
        Assert-R ($result.json.items[0].kind -ceq 'file' -and $result.json.items[1].kind -ceq 'file' -and $result.json.items[2].kind -ceq 'directory') 'Deletion kinds changed.'
        Assert-R (!(Test-Path -LiteralPath $ordinary) -and !(Test-Path -LiteralPath $ordinary2) -and !(Test-Path -LiteralPath $root)) 'Requested roots remained.'
        Assert-R (@(New-BinItems $rootId $rootPrior).Count -eq 0 -and @(New-BinItems $proof.Id $sparsePrior).Count -eq 0) 'Oversized root or sparse appeared in Bin.'
        $items = @(New-BinItems $before[0].Id $prior)
        $script:observed.binItems = $items
        Assert-R ($items.Count -eq 2 -and @($items | ForEach-Object Pidl | Select-Object -Unique).Count -eq 2) 'Two distinct new PIDLs for the shared identity required.'
        $survivor = Snapshot-R $alias
        $binProofs=[Collections.Generic.List[object]]::new()
        foreach ($item in $items) {
            Assert-R ([Prunlet.RecordlessE2E.FixtureNative]::Identity($item.PhysicalPath) -ceq $before[0].Id) 'Bin identity changed.'
            $binProofs.Add(@{item=$item; snapshot=(Snapshot-R $item.PhysicalPath)})
        }
        $script:observed.survivor=$survivor; $script:observed.binSnapshots=$binProofs
        $script:observed.securityComparison=@{before=$before[0].SecurityBase64; afterAlias=$survivor[0].SecurityBase64; afterBin=@($binProofs | ForEach-Object { $_.snapshot[0].SecurityBase64 }); changed=($before[0].SecurityBase64 -cne $survivor[0].SecurityBase64); note='Windows manages ACLs during Recycle Bin moves; the shared inode ACL may differ from the pre-delete ACL. All surviving aliases must agree.'}
        Assert-SharedSnapshot $before $survivor 3 -WindowsManaged
        foreach ($bin in $binProofs) {
            Assert-SharedSnapshot $before $bin.snapshot 3 -WindowsManaged
            Assert-R ($bin.snapshot[0].SecurityBase64 -ceq $survivor[0].SecurityBase64) 'Bin and surviving alias complete ACL differs.'
        }
        No-FileRecordsR $scope
    } catch { $failure=$_.Exception.ToString(); $script:observed.bodyError=$failure }
    finally {
        if ($session) { try { Close-McpR $session } catch { $script:observed.mcpCloseError=$_.Exception.ToString(); if (!$failure) { $failure=$script:observed.mcpCloseError } } }
        if ($sparse) {
            try {
                $candidates=[Collections.Generic.List[string]]::new()
                if ([IO.File]::Exists($sparse.path)) {
                    Assert-R ([Prunlet.RecordlessE2E.FixtureNative]::Identity($root) -ceq $rootId) 'Original folder identity changed.'
                    $candidates.Add($sparse.path)
                }
                $rootItems=@(New-BinItems $rootId $rootPrior)
                Assert-R ($rootItems.Count -le 1) 'Multiple new folder Bin entries; retained.'
                if ($rootItems.Count -eq 1) {
                    Assert-R ([Prunlet.RecordlessE2E.FixtureNative]::Identity($rootItems[0].PhysicalPath) -ceq $rootId) 'Folder Bin identity changed.'
                    $child=Join-Path $rootItems[0].PhysicalPath 'huge-sparse'
                    if ([IO.File]::Exists($child)) { $candidates.Add($child) }
                }
                $items=@(New-BinItems $sparse.proof.Id $sparsePrior)
                Assert-R ($items.Count -le 1) 'Multiple new sparse Bin entries; retained.'
                if ($items.Count -eq 1) { $candidates.Add($items[0].PhysicalPath) }
                $script:observed.sparseCandidates=@($candidates)
                Assert-R ($candidates.Count -le 1) 'Sparse location is ambiguous; retained.'
                if ($candidates.Count -eq 1) {
                    $tiny=[PrunletSparseE2E]::RestoreTiny($candidates[0],$sparse.proof.Id,$sparse.proof.SecurityBase64,[int]$sparse.proof.Attributes,$sparse.logical,$sparse.prefix,[ulong]1048576)
                    $script:observed.sparseFinalizer=$tiny
                    Assert-R $tiny.Success ('Sparse retained without shrinking: ' + $tiny.Error)
                }
            } catch { $script:observed.finalizerError=$_.Exception.ToString(); if (!$failure) { $failure=$script:observed.finalizerError } }
        } elseif ($script:observed.sparsePath -and [IO.File]::Exists($script:observed.sparsePath)) {
            $script:observed.finalizerError='Sparse creation did not yield original proof; retained without mutation.'
            if (!$failure) { $failure=$script:observed.finalizerError }
        }
        if ($scope) {
            try {
                if ($before) { $script:observed.finalSharedBin=@(New-BinItems $before[0].Id $prior) }
                if ($rootId) { $script:observed.finalFolderBin=@(New-BinItems $rootId $rootPrior) }
                if ($sparse) { $script:observed.finalSparseBin=@(New-BinItems $sparse.proof.Id $sparsePrior) }
                No-FileRecordsR $scope
            } catch { $script:observed.reconciliationError=$_.Exception.ToString(); if (!$failure) { $failure=$script:observed.reconciliationError } }
        }
        $results.Add(@{name=$Mode; passed=(!$failure); error=$failure; observed=$script:observed})
    }
}
try {
    Add-Type -Path $helperFiles -CompilerOptions '/unsafe'
 if (!('PrunletSparseE2E' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'recordless-e2e/SparseFixture.cs') }
    Test-Mixed 'cli'
    Test-Mixed 'mcp'
} catch { $results.Add(@{name='setup'; passed=$false; error=$_.Exception.ToString()}) }
finally {
    try {
        $report=@{suite='oversize-mixed-hardlinks';sparseHelper=@{path=(Join-Path $PSScriptRoot 'recordless-e2e/SparseFixture.cs');sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'recordless-e2e/SparseFixture.cs')).Hash}; executable=$ExecutablePath; executableSha256=(Get-FileHash -LiteralPath $ExecutablePath).Hash; output=$OutputDirectory; temp=$script:temp; passed=@($results | Where-Object passed).Count; failed=@($results | Where-Object {!$_.passed}).Count; results=@($results); commands=@($script:commands); retained='Output fixtures and identified Windows Bin entries are retained for inspection.'}
        Save-R $ReportPath $report
    } finally { $env:TEMP=$oldTemp; $env:TMP=$oldTmp }
}
if ($report.failed -or $results.Count -ne 2) { exit 1 }
