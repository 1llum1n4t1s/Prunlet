[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$AssemblyPath,[Parameter(Mandatory)][string]$ExpectedAssemblySha256,[Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop'
# 失敗モデル: Shell未到達、無関係aliasの書込み抑止、誤った対象ID、内容/ACL/リンク損傷、曖昧結果の再送。
$repo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent));. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach($path in @($ExecutablePath,$AssemblyPath,$OutputDirectory,$ReportPath)){if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute paths required'}}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory);$ReportPath=[IO.Path]::GetFullPath($ReportPath)
foreach($path in @($OutputDirectory,$ReportPath)){
 Assert-VerificationDestination $path @($repo,(Join-Path $env:USERPROFILE '.codex'))
 if(![IO.Path]::GetPathRoot($path).Equals('D:\',[StringComparison]::OrdinalIgnoreCase)){throw 'External D output required'}
 if(Test-Path -LiteralPath $path){throw 'Unused output and report required'}
 if(![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))){throw 'Existing parent required'}
}
if(![IO.File]::Exists($ExecutablePath)-or![IO.File]::Exists($AssemblyPath)){throw 'Candidate exe and assembly required'}
if((Get-FileHash -LiteralPath $AssemblyPath).Hash-cne$ExpectedAssemblySha256){throw 'Candidate assembly hash mismatch'}
$exeHash=(Get-FileHash -LiteralPath $ExecutablePath).Hash
$hostScript=Join-Path $PSScriptRoot 'recordless-e2e/OversizeRecycledHardlinkHost.ps1';$common=Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1';. $common
$helperFiles=@('NativeShellFixture.cs','FixtureNative.cs','OwnedBinLocator.cs')|ForEach-Object {Join-Path (Join-Path $PSScriptRoot 'recordless-e2e') $_}
$sources=@(@($PSCommandPath,$hostScript,$common,(Join-Path $PSScriptRoot 'Verify-RecycleBin.ps1'))+$helperFiles|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}})
$null=[IO.Directory]::CreateDirectory($OutputDirectory);$script:temp=Join-Path $OutputDirectory 'temp';$null=[IO.Directory]::CreateDirectory($script:temp)
$oldTemp=$env:TEMP;$oldTmp=$env:TMP;$env:TEMP=$script:temp;$env:TMP=$script:temp
$script:commands=[Collections.Generic.List[object]]::new();$script:observed=@{};$state=@{passed=$false;fixtureDisposition='retained; do not retry uncertain deletion'}
try {
 Add-Type -Path $helperFiles -CompilerOptions '/unsafe'
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Verify-RecycleBin.ps1'),[ref]$tokens,[ref]$errors)
 $definitions=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.StringConstantExpressionAst]-and$n.Value.Contains('public static class PrunletSparseE2E {')},$true))
 Assert-R ($errors.Count-eq0-and$definitions.Count-eq1) 'Sparse helper source ambiguous';Add-Type -TypeDefinition $definitions[0].Value
 $scope=New-ScopeR 'mixed-independent';$state.scope=$scope.root
 $small=Join-Path $scope.files 'recycled-small.txt';$alias=Join-Path $scope.files 'external-alias.txt'
 [IO.File]::WriteAllText($small,'independent recycled hardlink fixture',$utf8)
 [Prunlet.RecordlessE2E.FixtureNative]::CreateHardlink($alias,$small)
 $smallBefore=Snapshot-R $small;$aliasBefore=Snapshot-R $alias
 Assert-R ($smallBefore[0].Id-ceq$aliasBefore[0].Id-and$smallBefore[0].NumberOfLinks-eq2-and$aliasBefore[0].NumberOfLinks-eq2) 'Fixture hardlink identity mismatch'
 $priorSmall=Before-BinR $smallBefore;$state.small=@{path=$small;before=$smallBefore;prior=$priorSmall};$state.alias=@{path=$alias;before=$aliasBefore}
 $root=Join-Path $scope.files 'huge-root';$null=[IO.Directory]::CreateDirectory($root)
 $child=Join-Path $root 'small.txt';[IO.File]::WriteAllText($child,'unrelated huge root child',$utf8)
 $rootBefore=Snapshot-R $root;$rootPrior=Before-BinR $rootBefore;$childBefore=Snapshot-R $child;$childPrior=Before-BinR $childBefore
 $sparse=Join-Path $root 'huge-sparse';$prefix=$utf8.GetBytes('unrelated owned sparse');$length=[long]1099511627776
 $stream=[IO.FileStream]::new($sparse,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{[PrunletSparseE2E]::MakeSparse($stream.SafeFileHandle);$stream.Write($prefix,0,$prefix.Length);$stream.SetLength($length);$stream.Flush($true)}finally{$stream.Dispose()}
 $proof=[PrunletSparseE2E]::CaptureProof($sparse)
 Assert-R ($proof.Length-eq$length-and$proof.NumberOfLinks-eq1-and$proof.AllocationSize-le1MB-and$proof.CompressedSize-le1MB) 'Invalid sparse fixture'
 $sparsePrior=[string[]]@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($proof.Id)|ForEach-Object Pidl)
 $state.huge=@{path=$root;before=$rootBefore;prior=$rootPrior;childBefore=$childBefore;childPrior=$childPrior;sparsePath=$sparse;sparse=$proof;sparsePrefix=[Convert]::ToBase64String($prefix);sparsePrior=$sparsePrior}
 $observed=& $hostScript -AssemblyPath $AssemblyPath -ExpectedAssemblySha256 $ExpectedAssemblySha256 -ConfigPath $scope.config -SmallPath $small -AliasPath $alias -HugeRoot $root -ExpectedFileId $aliasBefore[0].FileId -ExpectedVolume $aliasBefore[0].VolumeSerialNumber;$state.checkpoint=$observed
 Assert-R ($observed.sizeReported-and$observed.attempted-and$observed.allowed-and$observed.sourceAbsent-and$observed.identityMatched-and!$observed.error) 'Alias write-open failed during pinned unrelated child'
 Assert-R (!$observed.reportedError-and@($observed.result.Items).Count-eq2) 'Core batch failed or returned wrong item count'
 Assert-R ($observed.result.Items[0].Path-ceq$small-and$observed.result.Items[0].Status-ceq'recycled'-and![IO.File]::Exists($small)) 'Small file was not recycled'
 Assert-R ($observed.result.Items[1].Path-ceq$root-and$observed.result.Items[1].Status-ceq'permanently_deleted'-and![IO.Directory]::Exists($root)) 'Huge root was not permanently deleted'
 $bin=[Prunlet.RecordlessE2E.OwnedBinLocator]::FindNew($smallBefore[0].Id,$priorSmall);$state.newBin=$bin
 $state.binProof=Assert-SnapshotR $bin.PhysicalPath $smallBefore -WindowsManagedBin
 $state.aliasAfter=Assert-SnapshotR $alias $aliasBefore -WindowsManagedBin
 $state.securityComparison=@{note='Windows Bin movement may change the original ACL; the Bin object and surviving alias must have identical owner/group/DACL descriptor bytes after movement';before=$smallBefore[0].SecurityBase64;bin=$state.binProof[0].SecurityBase64;alias=$state.aliasAfter[0].SecurityBase64;changed=($smallBefore[0].SecurityBase64-cne$state.binProof[0].SecurityBase64);afterEqual=($state.binProof[0].SecurityBase64-ceq$state.aliasAfter[0].SecurityBase64)}
 Assert-R $state.securityComparison.afterEqual 'Bin object and external alias owner/group/DACL descriptor bytes differ after Windows movement'
 foreach($member in @(@{id=$rootBefore[0].Id;prior=$rootPrior},@{id=$childBefore[0].Id;prior=$childPrior},@{id=$proof.Id;prior=$sparsePrior})) {
  $new=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($member.id)|Where-Object {$_.Pidl-notin$member.prior});Assert-R ($new.Count-eq0) 'Unexpected huge-root Bin entry'
 }
 No-FileRecordsR $scope
 foreach($source in $sources){Assert-R ((Get-FileHash -LiteralPath $source.path).Hash-ceq$source.sha256) 'Verification source changed'}
 Assert-R ((Get-FileHash -LiteralPath $AssemblyPath).Hash-ceq$ExpectedAssemblySha256-and(Get-FileHash -LiteralPath $ExecutablePath).Hash-ceq$exeHash) 'Candidate changed'
 $state.fixtureDisposition='recycled owned small file and surviving alias retained; huge root deleted; output retained for separately verified cleanup';$state.passed=$true
} catch {$state.error=$_.Exception.ToString();$state.stack=$_.ScriptStackTrace}
finally {
 $report=@{suite='oversize-recycled-hardlink-independence';executable=$ExecutablePath;executableSha256=$exeHash;assembly=$AssemblyPath;assemblySha256=$ExpectedAssemblySha256;sources=$sources;result=$state;commands=@($script:commands);retained=$OutputDirectory;passed=[int]$state.passed;failed=[int](!$state.passed)}
 try{$bytes=$utf8.GetBytes((ConvertTo-Json -InputObject $report -Depth 100));$stream=[IO.FileStream]::new($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}}finally{$env:TEMP=$oldTemp;$env:TMP=$oldTmp}
}
if(!$state.passed){throw 'Mixed oversize verification failed; inspect report and retain uncertain fixtures'}
