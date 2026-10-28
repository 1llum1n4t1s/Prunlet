[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$AssemblyPath,[Parameter(Mandatory)][string]$ExpectedAssemblySha256,[Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop'
# 失敗モデル: 実Shell未到達、別rootの直列化、対象入替、共有・リンク先破損、Bin既存項目への干渉、曖昧結果の再送。
$repo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
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
$hostScript=Join-Path $PSScriptRoot 'recordless-e2e/OversizeParallelIndependenceHost.ps1'
$common=Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1';. $common
$helperFiles=@('NativeShellFixture.cs','FixtureNative.cs','OwnedBinLocator.cs')|ForEach-Object {Join-Path (Join-Path $PSScriptRoot 'recordless-e2e') $_}
$sources=@(@($PSCommandPath,$hostScript,$common,(Join-Path $PSScriptRoot 'Verify-RecycleBin.ps1'))+$helperFiles|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}})
$null=[IO.Directory]::CreateDirectory($OutputDirectory);$script:temp=Join-Path $OutputDirectory 'temp';$null=[IO.Directory]::CreateDirectory($script:temp)
$oldTemp=$env:TEMP;$oldTmp=$env:TMP;$env:TEMP=$script:temp;$env:TMP=$script:temp
$script:commands=[Collections.Generic.List[object]]::new();$script:observed=@{};$state=@{passed=$false;fixtureDisposition='retained on failure; do not retry uncertain deletion';roots=@();witnesses=@()}
try {
 Add-Type -Path $helperFiles -CompilerOptions '/unsafe'
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Verify-RecycleBin.ps1'),[ref]$tokens,[ref]$errors)
 $definitions=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.StringConstantExpressionAst]-and$n.Value.Contains('public static class PrunletSparseE2E {')},$true))
 Assert-R ($errors.Count-eq0-and$definitions.Count-eq1) 'Sparse helper source ambiguous';Add-Type -TypeDefinition $definitions[0].Value
 $scope=New-ScopeR 'independent';$state.scope=$scope.root
 $roots=[Collections.Generic.List[string]]::new();$witnesses=[Collections.Generic.List[object]]::new();$members=[Collections.Generic.List[object]]::new()
 for($i=0;$i-lt2;$i++){
  $root=Join-Path $scope.files ('root-'+$i);$witness=Join-Path $scope.files ('witness-'+$i)
  $null=[IO.Directory]::CreateDirectory($root);$null=[IO.Directory]::CreateDirectory($witness)
  $marker=Join-Path $witness 'marker.txt';[IO.File]::WriteAllText($marker,'external witness '+$i,$utf8)
  $witnessBefore=Snapshot-R $witness;$witnessPrior=Before-BinR $witnessBefore
  $null=New-Item -ItemType Junction -Path (Join-Path $root 'external-link') -Target $witness
  $small=Join-Path $root 'small.txt';[IO.File]::WriteAllText($small,'independent fixture '+$i,$utf8)
  $rootBefore=Snapshot-R $root
  foreach($path in @($root,$small,(Join-Path $root 'external-link'))){$id=[Prunlet.RecordlessE2E.FixtureNative]::Identity($path);$members.Add(@{path=$path;id=$id;prior=[string[]]@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($id)|ForEach-Object Pidl)})}
  $sparsePath=Join-Path $root 'huge-sparse';$prefix=$utf8.GetBytes('independent owned sparse '+$i);$length=[long]1099511627776
  $stream=[IO.FileStream]::new($sparsePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  try{[PrunletSparseE2E]::MakeSparse($stream.SafeFileHandle);$stream.Write($prefix,0,$prefix.Length);$stream.SetLength($length);$stream.Flush($true)}finally{$stream.Dispose()}
  $proof=[PrunletSparseE2E]::CaptureProof($sparsePath)
  Assert-R ($proof.Length-eq$length-and$proof.NumberOfLinks-eq1-and$proof.AllocationSize-le1MB-and$proof.CompressedSize-le1MB) 'Invalid sparse fixture'
  $prior=[string[]]@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($proof.Id)|ForEach-Object Pidl)
  $members.Add(@{path=$sparsePath;id=$proof.Id;prior=$prior;proof=$proof;prefix=[Convert]::ToBase64String($prefix)})
  $roots.Add($root);$witnesses.Add(@{path=$witness;before=$witnessBefore;prior=$witnessPrior});$state.roots+=@(@{path=$root;before=$rootBefore;sparse=$proof});$state.witnesses+=@(@{path=$witness;before=$witnessBefore;prior=$witnessPrior})
 }
 $state.members=@($members)
 $observed=& $hostScript -AssemblyPath $AssemblyPath -ExpectedAssemblySha256 $ExpectedAssemblySha256 -ConfigPath $scope.config -TargetPaths ([string[]]$roots.ToArray());$state.checkpoint=$observed
 Assert-R ($observed.checkpointCount-eq2-and$observed.secondPinned-and$observed.firstReleased-and!$observed.failure) 'Independent pin rendezvous failed'
 Assert-R (!$observed.reportedError-and@($observed.result.Items).Count-eq2) 'Core deletion failed or returned wrong item count'
 for($i=0;$i-lt2;$i++) {Assert-R ($observed.result.Items[$i].Path-ceq$roots[$i]-and$observed.result.Items[$i].Status-ceq'permanently_deleted'-and![IO.Directory]::Exists($roots[$i])) 'Unexpected root deletion result'}
 foreach($member in $members){$new=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($member.id)|Where-Object {$_.Pidl-notin$member.prior});Assert-R ($new.Count-eq0) ('Unexpected Bin entry for '+$member.path)}
 foreach($witness in $witnesses){$null=Assert-SnapshotR $witness.path $witness.before;$new=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($witness.before[0].Id)|Where-Object {$_.Pidl-notin$witness.prior});Assert-R ($new.Count-eq0) 'External link target entered Bin'}
 No-FileRecordsR $scope
 foreach($source in $sources){Assert-R ((Get-FileHash -LiteralPath $source.path).Hash-ceq$source.sha256) 'Verification source changed'}
 Assert-R ((Get-FileHash -LiteralPath $AssemblyPath).Hash-ceq$ExpectedAssemblySha256-and(Get-FileHash -LiteralPath $ExecutablePath).Hash-ceq$exeHash) 'Candidate changed'
 # 外部リンク先は親の照合後に配置済みCLIで清掃するため保持する。
 $state.fixtureDisposition='deleted roots; owned witness fixtures and output retained for separately verified cleanup';$state.passed=$true
} catch {$state.error=$_.Exception.ToString();$state.stack=$_.ScriptStackTrace}
finally {
 $report=@{suite='oversize-parallel-independence';executable=$ExecutablePath;executableSha256=$exeHash;assembly=$AssemblyPath;assemblySha256=$ExpectedAssemblySha256;sources=$sources;result=$state;commands=@($script:commands);retained=$OutputDirectory;passed=[int]$state.passed;failed=[int](!$state.passed)}
 try{$bytes=$utf8.GetBytes((ConvertTo-Json -InputObject $report -Depth 100));$stream=[IO.FileStream]::new($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}}finally{$env:TEMP=$oldTemp;$env:TMP=$oldTmp}
}
if(!$state.passed){throw 'Oversize parallel verification failed; inspect report and retain uncertain fixtures'}
