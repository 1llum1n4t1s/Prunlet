[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [switch]$Execute
)
$ErrorActionPreference='Stop'
# 想定する失敗: denyが実効せずguardを試せない、DELETE/属性も拒否される、
# 単一rootまたはその内部の2 aliasで失敗、同一batchの不確かな削除を成功と報告、survivorの
# ID・内容・完全ACL破損、操作記録生成、不明結果再送、sparse回収不能。
# 元の完全O/G/Dはdeny設定前にreportへ保存し、denyしたACLも保持する。
# 終了時はfixtureを保持し、残存sparseだけ元の証拠と単独リンク・prefix・
# 割当範囲のゼロをRestoreTinyで照合して縮小する。曖昧なら変更しない。
if (!$Execute) { throw 'Pass -Execute only when this E2E run is explicitly requested.' }
$repo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach ($path in @($ExecutablePath,$OutputDirectory,$ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'Absolute paths required.' }
    $full=[IO.Path]::GetFullPath($path)
    if (![IO.Path]::GetPathRoot($full).Equals('D:\',[StringComparison]::OrdinalIgnoreCase)) { throw 'External D paths required.' }
    Assert-VerificationDestination $full @($repo,(Join-Path $env:USERPROFILE '.codex'))
}
$ExecutablePath=[IO.Path]::GetFullPath($ExecutablePath); $OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory); $ReportPath=[IO.Path]::GetFullPath($ReportPath)
if (![IO.File]::Exists($ExecutablePath)) { throw 'Candidate executable missing.' }
foreach ($path in @($OutputDirectory,$ReportPath)) {
    if (Test-Path -LiteralPath $path) { throw 'Unused output and report required.' }
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { throw 'Output and report parents must exist.' }
}
if ($ReportPath.StartsWith($OutputDirectory.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Report must be outside the unused output directory.' }
$probe=[IO.File]::Open($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None); $probe.Dispose()
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$script:temp=Join-Path $OutputDirectory 'temp'; $null=[IO.Directory]::CreateDirectory($script:temp)
$oldTemp=$env:TEMP; $oldTmp=$env:TMP; $env:TEMP=$script:temp; $env:TMP=$script:temp
. (Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1')
$script:commands=[Collections.Generic.List[object]]::new(); $results=[Collections.Generic.List[object]]::new(); $backups=[Collections.Generic.List[object]]::new()
$helperFiles=@('NativeShellFixture.cs','FixtureNative.cs','OwnedBinLocator.cs') | ForEach-Object { Join-Path (Join-Path $PSScriptRoot 'recordless-e2e') $_ }
function Save-Progress {
    Save-R $ReportPath @{suite='oversize-hardlink-permissions'; executable=$ExecutablePath; executableSha256=(Get-FileHash -LiteralPath $ExecutablePath).Hash; output=$OutputDirectory; temp=$script:temp; executed=$results.Count; passed=@($results | Where-Object passed).Count; failed=@($results | Where-Object {!$_.passed}).Count; aclBackups=@($backups); results=@($results); commands=@($script:commands); retained='All fixture paths and identified Bin entries are retained; inspect ambiguous results without retrying.'}
}
function Shared-Node($Handle) {
    $method=[Prunlet.RecordlessE2E.FixtureNative].GetMethod('ReadNode',[Reflection.BindingFlags]'NonPublic,Static')
    Assert-R ($null -ne $method) 'Native node proof unavailable.'
    return $method.Invoke($null,[object[]]@($Handle))
}
function Shared-Hash($Stream) {
    $Stream.Position=0
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Stream))
}
function New-BinItems([string]$Id,[string[]]$Prior) { return @([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($Id) | Where-Object { $_.Pidl -cnotin $Prior }) }
function Sparse-Fixture([string]$Path,[string]$Root,[string]$RootId,[string[]]$RootPrior) {
    $prefix=$utf8.GetBytes('owned sparse prefix; allocated tails must stay zero')
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { [PrunletSparseE2E]::MakeSparse($stream.SafeFileHandle); $stream.Write($prefix,0,$prefix.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $proof=[PrunletSparseE2E]::CaptureProof($Path)
    $s=@{path=$Path; root=$Root; rootId=$RootId; rootPrior=$RootPrior; proof=$proof; prefix=$prefix; logical=[long]1099511627776; prior=[string[]]@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($proof.Id) | ForEach-Object Pidl)}
    return $s
}
function Grow-Sparse($Sparse) {
    $stream=[IO.FileStream]::new($Sparse.path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { $stream.SetLength($Sparse.logical); $stream.Flush($true) } finally { $stream.Dispose() }
    $grown=[PrunletSparseE2E]::CaptureProof($Sparse.path)
    foreach ($field in @('Id','SecurityBase64','Attributes','NumberOfLinks')) { Assert-R ($Sparse.proof.$field -ceq $grown.$field) ('Sparse ' + $field + ' changed during creation.') }
    Assert-R ($grown.Length -eq $Sparse.logical -and $grown.NumberOfLinks -eq 1 -and $grown.AllocationSize -le 1MB -and $grown.CompressedSize -le 1MB) 'Sparse shape invalid.'
    $Sparse.proof=$grown
}
function Finalize-Sparse($Sparse) {
    $candidates=[Collections.Generic.List[string]]::new()
    if ([IO.File]::Exists($Sparse.path)) {
        Assert-R ([Prunlet.RecordlessE2E.FixtureNative]::Identity($Sparse.root) -ceq $Sparse.rootId) 'Original folder identity changed.'
        $candidates.Add($Sparse.path)
    }
    $roots=@(New-BinItems $Sparse.rootId $Sparse.rootPrior)
    Assert-R ($roots.Count -le 1) 'Multiple folder Bin identities; retained.'
    if ($roots.Count -eq 1) {
        Assert-R ([Prunlet.RecordlessE2E.FixtureNative]::Identity($roots[0].PhysicalPath) -ceq $Sparse.rootId) 'Folder Bin identity changed.'
        $child=Join-Path $roots[0].PhysicalPath 'huge-sparse'
        if ([IO.File]::Exists($child)) { $candidates.Add($child) }
    }
    $items=@(New-BinItems $Sparse.proof.Id $Sparse.prior)
    Assert-R ($items.Count -le 1) 'Multiple sparse Bin identities; retained.'
    if ($items.Count -eq 1) { $candidates.Add($items[0].PhysicalPath) }
    Assert-R ($candidates.Count -le 1) 'Sparse location ambiguous; retained.'
    if ($candidates.Count -eq 0) { return @{path=$Sparse.path; absentFromKnownLocations=$true; folderBin=$roots; sparseBin=$items} }
    $tiny=[PrunletSparseE2E]::RestoreTiny($candidates[0],$Sparse.proof.Id,$Sparse.proof.SecurityBase64,[int]$Sparse.proof.Attributes,$Sparse.logical,$Sparse.prefix,[ulong]1048576)
    if (!$tiny.Success) { throw ('Sparse retained without shrinking: '+$tiny.Error) }
    return $tiny
}
function Probe-Access([string]$Path) {
    return @{readData=[PermissionProbe]::TryAccess($Path,1); execute=[PermissionProbe]::TryAccess($Path,32); delete=[PermissionProbe]::TryAccess($Path,65536); readAttributes=[PermissionProbe]::TryAccess($Path,128)}
}
function Assert-Deny($Probe) {
    Assert-R ($Probe.readData -eq 5 -and $Probe.execute -eq 5 -and $Probe.delete -eq 0 -and $Probe.readAttributes -eq 0) 'Expected read/execute denial and delete/attribute access were not observed.'
}
function Test-Scenario([string]$Mode,[ValidateSet('one','two-roots','same-root')][string]$Scenario) {
    $multiple=($Scenario -eq 'two-roots'); $sameRoot=($Scenario -eq 'same-root')
    $script:observed=@{mode=$Mode; scenario=$Scenario; multipleRoots=$multiple}; $scope=$null; $session=$null; $held=$null; $failure=$null
    $sparseFiles=[Collections.Generic.List[object]]::new(); $roots=[Collections.Generic.List[string]]::new(); $rootProofs=[Collections.Generic.List[object]]::new()
    try {
        $scope=New-ScopeR ($Mode+'-'+$Scenario)
        $count=if($Multiple){2}else{1}
        foreach ($i in 1..$count) {
            $root=Join-Path $scope.files ('root-'+$i); $null=[IO.Directory]::CreateDirectory($root); $roots.Add($root)
            $id=[Prunlet.RecordlessE2E.FixtureNative]::Identity($root)
            $prior=[string[]]@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($id) | ForEach-Object Pidl)
            $rootProofs.Add(@{path=$root; id=$id; prior=$prior})
        }
        $survivor=File-R $scope 'survivor'
        foreach ($root in $roots) { [Prunlet.RecordlessE2E.FixtureNative]::CreateHardlink((Join-Path $root 'shared'),$survivor) }
        if ($sameRoot) { [Prunlet.RecordlessE2E.FixtureNative]::CreateHardlink((Join-Path $roots[0] 'shared-second'),$survivor) }
        $originalLinks=$count+1+[int]$sameRoot
        $original=Snapshot-R $survivor
        Assert-R ($original[0].NumberOfLinks -eq $originalLinks) 'Fixture hardlink count differs.'
        $held=[IO.FileStream]::new($survivor,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $beforeHash=Shared-Hash $held; $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $backup=@{path=$survivor; id=$original[0].Id; originalSecurityBase64=$original[0].SecurityBase64; identitySid=$identity.Value; originalSnapshot=$original; originalContentSha256=$beforeHash; requestedDenyMask=33; note='Restore only after pinning and verifying the exact fixture ID; this script does not change the ACL back.'}
        $backups.Add($backup); Save-Progress
        $acl=Get-Acl -LiteralPath $survivor
        $rule=[Security.AccessControl.FileSystemAccessRule]::new($identity,[Security.AccessControl.FileSystemRights]33,[Security.AccessControl.AccessControlType]::Deny)
        $acl.AddAccessRule($rule); Set-Acl -LiteralPath $survivor -AclObject $acl
        $deniedNode=Shared-Node $held.SafeFileHandle; $denied=Probe-Access $survivor
        $backup.deniedSecurityBase64=$deniedNode.SecurityBase64; $backup.accessProbe=$denied; Save-Progress
        Assert-R ($deniedNode.Id -ceq $original[0].Id -and $deniedNode.NumberOfLinks -eq $originalLinks) 'Deny changed fixture identity or link count.'
        Assert-Deny $denied
        foreach ($index in 0..($count-1)) {
            $root=$roots[$index]; $rp=$rootProofs[$index]
            $s=Sparse-Fixture (Join-Path $root 'huge-sparse') $root $rp.id $rp.prior
            $sparseFiles.Add($s); Grow-Sparse $s
        }
        $paths=[string[]]@($roots)
        $script:observed.fixture=@{roots=$rootProofs; survivor=$survivor; sameRootSecondAlias=$(if($sameRoot){Join-Path $roots[0] 'shared-second'}else{$null}); original=$original; deniedNode=$deniedNode; accessProbe=$denied; sparse=@($sparseFiles)}
        if ($Mode -eq 'mcp') {
            $session=Open-McpR $scope; Init-McpR $session
            $dry=Call-McpR $session 2 'delete_files' @{paths=$paths; dryRun=$true; recursive=$true}
            Assert-R (!$dry.failed) 'MCP dry-run failed.'
        } else { $dry=Delete-R $scope $paths -Recursive -DryRun; Assert-R ($dry.exitCode -eq 0) 'CLI dry-run failed.' }
        $script:observed.dry=$dry; Assert-WireR $dry $paths ([string[]]@($paths | ForEach-Object {'would_recycle'})) $true
        $dryNode=Shared-Node $held.SafeFileHandle
        Assert-R ($dryNode.Id -ceq $deniedNode.Id -and $dryNode.SecurityBase64 -ceq $deniedNode.SecurityBase64 -and $dryNode.NumberOfLinks -eq $deniedNode.NumberOfLinks -and (Shared-Hash $held) -ceq $beforeHash) 'Dry-run changed shared file.'
        foreach ($rp in $rootProofs) {
            Assert-R ([Prunlet.RecordlessE2E.FixtureNative]::Identity($rp.path) -ceq $rp.id) 'Dry-run changed root identity.'
            Assert-R ([Prunlet.RecordlessE2E.FixtureNative]::Identity((Join-Path $rp.path 'shared')) -ceq $original[0].Id) 'Dry-run changed the shared alias identity.'
            Assert-R (@(New-BinItems $rp.id $rp.prior).Count -eq 0) 'Dry-run created a folder Bin item.'
        }
        if ($sameRoot) { Assert-R ([Prunlet.RecordlessE2E.FixtureNative]::Identity((Join-Path $roots[0] 'shared-second')) -ceq $original[0].Id) 'Dry-run changed the second same-root alias identity.' }
        foreach ($s in $sparseFiles) {
            $now=[PrunletSparseE2E]::CaptureProof($s.path)
            foreach ($field in @('Id','SecurityBase64','Attributes','NumberOfLinks','Length','AllocationSize','CompressedSize')) { Assert-R ($now.$field -ceq $s.proof.$field) ('Dry-run changed sparse '+$field) }
            Assert-R (@(New-BinItems $s.proof.Id $s.prior).Count -eq 0) 'Dry-run created a sparse Bin item.'
        }
        Assert-Deny (Probe-Access $survivor); No-FileRecordsR $scope
        if ($Mode -eq 'mcp') {
            $rpc=Rpc-R $session @{jsonrpc='2.0';id=3;method='tools/call';params=@{name='delete_files';arguments=@{paths=$paths;recursive=$true}}}
            $script:observed.delete=$rpc
            Assert-R (!$rpc.error -and $null -ne $rpc.result.structuredContent) 'MCP delete did not return structured result.'
            $response=@{json=$rpc.result.structuredContent}
        } else {
            $response=Delete-R $scope $paths -Recursive; $script:observed.delete=$response
        }
        $after=Shared-Node $held.SafeFileHandle; $afterHash=Shared-Hash $held; $afterProbe=Probe-Access $survivor
        $script:observed.survivor=@{node=$after; sha256=$afterHash; accessProbe=$afterProbe; pathIdentity=[Prunlet.RecordlessE2E.FixtureNative]::Identity($survivor)}
        Assert-R ($after.Id -ceq $original[0].Id -and $script:observed.survivor.pathIdentity -ceq $original[0].Id -and $after.SecurityBase64 -ceq $deniedNode.SecurityBase64 -and $afterHash -ceq $beforeHash) 'Survivor ID, complete ACL or content changed.'
        Assert-Deny $afterProbe
        if ($Mode -eq 'mcp') { Assert-R ([bool]$rpc.result.isError -eq $Multiple) 'MCP error flag differs from expected outcome.' }
        else { Assert-R (($response.exitCode -ne 0) -eq $Multiple) 'CLI exit code differs from expected outcome.' }
        if ($Multiple) {
            Assert-R ($null -ne $response.json -and @($response.json.items).Count -eq 2) 'Two input results required.'
            $firstStatus=$response.json.items[0].status
            Assert-R ($firstStatus -in @('permanently_deleted','ambiguous')) 'Unexpected first root status.'
            $statuses=if($firstStatus -ceq 'permanently_deleted'){@('permanently_deleted','ambiguous')}else{@('ambiguous','permanently_deleted')}
        } else { $statuses=@('permanently_deleted') }
        Assert-WireR $response $paths $statuses
        if ($Multiple) {
            $successIndex=if($statuses[0] -ceq 'permanently_deleted'){0}else{1}
            $ambiguousIndex=1-$successIndex
            $successRoot=$rootProofs[$successIndex]; $ambiguousRoot=$rootProofs[$ambiguousIndex]
            Assert-R ($response.json.items[$ambiguousIndex].error -match '(?i)(prior hardlink deletion|hardlink.*(?:guard|uncertain|confirmed))') 'Ambiguous result did not identify the missing shared-link guard.'
            Assert-R (!(Test-Path -LiteralPath $successRoot.path)) 'Successfully deleted oversized root remained.'
            Assert-R ([IO.Directory]::Exists($ambiguousRoot.path) -and [Prunlet.RecordlessE2E.FixtureNative]::Identity($ambiguousRoot.path) -ceq $ambiguousRoot.id) 'Ambiguous root is missing or its identity changed.'
            $ambiguousAlias=Join-Path $ambiguousRoot.path 'shared'
            Assert-R ([IO.File]::Exists($ambiguousAlias) -and [Prunlet.RecordlessE2E.FixtureNative]::Identity($ambiguousAlias) -ceq $original[0].Id) 'Ambiguous root shared alias is missing or its identity changed.'
            $script:observed.rootOutcomes=@{successIndex=$successIndex; successRoot=$successRoot; ambiguousIndex=$ambiguousIndex; ambiguousRoot=$ambiguousRoot; ambiguousAlias=$ambiguousAlias; sharedIdentity=$original[0].Id}
        } else { Assert-R (!(Test-Path -LiteralPath $roots[0])) 'Oversized root remained.' }
        Assert-R ($after.NumberOfLinks -eq $(if($Multiple){2}else{1})) 'Survivor link count differs.'
        foreach ($rp in $rootProofs) { Assert-R (@(New-BinItems $rp.id $rp.prior).Count -eq 0) 'Oversized folder appeared in Bin.' }
        No-FileRecordsR $scope
    } catch { $failure=$_.Exception.ToString(); $script:observed.bodyError=$failure }
    finally {
        if ($session) { try { Close-McpR $session } catch { $script:observed.mcpCloseError=$_.Exception.ToString(); if(!$failure){$failure=$script:observed.mcpCloseError} } }
        if ($held) { $held.Dispose() }
        $finalizers=[Collections.Generic.List[object]]::new(); $script:observed.sparseFinalizers=$finalizers
        foreach ($s in $sparseFiles) {
            try { $finalizers.Add(@{path=$s.path; result=(Finalize-Sparse $s)}) }
            catch { $errorText=$_.Exception.ToString(); $finalizers.Add(@{path=$s.path; error=$errorText}); if(!$failure){$failure=$errorText} }
        }
        if ($scope) { try { No-FileRecordsR $scope } catch { $script:observed.reconciliationError=$_.Exception.ToString(); if(!$failure){$failure=$script:observed.reconciliationError} } }
        $results.Add(@{name=($Mode+'-'+$Scenario); passed=(!$failure); error=$failure; observed=$script:observed})
        Save-Progress
    }
}
try {
    Add-Type -Path $helperFiles -CompilerOptions '/unsafe'
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class PermissionProbe {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    public static int TryAccess(string path,uint access) {
        using var handle=CreateFileW(path,access,7,IntPtr.Zero,3,0x00200000,IntPtr.Zero);
        return handle.IsInvalid ? Marshal.GetLastWin32Error() : 0;
    }
}
'@
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Verify-RecycleBin.ps1'),[ref]$tokens,[ref]$errors)
    $definitions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('public static class PrunletSparseE2E {')},$true))
    Assert-R ($definitions.Count -eq 1 -and $errors.Count -eq 0) 'Sparse finalizer source ambiguous.'
    if (!('PrunletSparseE2E' -as [type])) { Add-Type -TypeDefinition $definitions[0].Value }
    foreach ($mode in @('cli','mcp')) { Test-Scenario $mode 'one'; Test-Scenario $mode 'two-roots'; Test-Scenario $mode 'same-root' }
} catch { $results.Add(@{name='setup'; passed=$false; error=$_.Exception.ToString()}) }
finally { try { Save-Progress } finally { $env:TEMP=$oldTemp; $env:TMP=$oldTmp } }
if ($results.Count -ne 6 -or @($results | Where-Object {!$_.passed}).Count) { exit 1 }
