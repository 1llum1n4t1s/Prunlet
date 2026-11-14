[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$RustProbePath,[Parameter(Mandatory)][string]$BuildManifestPath,[Parameter(Mandatory)][string]$ExpectedBuildManifestSha256,[Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$ReportPath,[Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference='Stop'
# 失敗モデル: 実Shell未到達、別rootの直列化、対象入替、共有・リンク先破損、Bin既存項目への干渉、曖昧結果の再送。
$repo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
. (Join-Path $PSScriptRoot 'Verification-Fixture.ps1')
. (Join-Path $PSScriptRoot 'recordless-e2e/RustFileProbe.Common.ps1')
foreach($path in @($ExecutablePath,$RustProbePath,$BuildManifestPath,$OutputDirectory,$ReportPath,$FixtureRoot)){if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute paths required'}}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory);$ReportPath=[IO.Path]::GetFullPath($ReportPath)
foreach($path in @($OutputDirectory,$ReportPath)){
 Assert-ExternalVerificationPath $path @($repo)
 if(Test-Path -LiteralPath $path){throw 'Unused output and report required'}
 if(![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))){throw 'Existing parent required'}
}
$buildBinding=Assert-RustFileProbeBinding
. (Join-Path $PSScriptRoot 'FileFixtures.Common.ps1')
$null=Initialize-PrunletFixtureBinding -ExecutablePath $ExecutablePath -BuildManifestPath $BuildManifestPath -ExpectedBuildManifestSha256 $ExpectedBuildManifestSha256
$script:fixtureRun=New-VerificationFixtureRun -FixtureRoot $FixtureRoot -ForbiddenRoots @($repo,(Join-Path $env:USERPROFILE '.codex'),$OutputDirectory) -NamePrefix 'independence'
$exeHash=(Get-FileHash -LiteralPath $ExecutablePath).Hash
$hostScript=Join-Path $PSScriptRoot 'recordless-e2e/OversizeIndependenceHost.ps1'
$common=Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1';. $common
$helperFiles=@('FileFixtures.Common.ps1','FixtureBridge.Common.ps1')|ForEach-Object {Join-Path $PSScriptRoot $_}
$sources=@(@($PSCommandPath,$hostScript,$common,(Join-Path $PSScriptRoot 'SparseFixtures.Common.ps1'),(Join-Path $PSScriptRoot 'FileFixtures.Common.ps1'))+$helperFiles|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}})
$sources+=@(Get-RustFileProbeSourceHashes)
$null=[IO.Directory]::CreateDirectory($OutputDirectory);$script:temp=Join-Path $OutputDirectory 'temp';$null=[IO.Directory]::CreateDirectory($script:temp)
$oldTemp=$env:TEMP;$oldTmp=$env:TMP;$env:TEMP=$script:temp;$env:TMP=$script:temp
$script:commands=[Collections.Generic.List[object]]::new();$script:observed=@{};$state=@{passed=$false;fixtureDisposition='retained on failure; do not retry uncertain deletion';roots=@();witnesses=@()}
try {
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
  foreach($path in @($root,$small,(Join-Path $root 'external-link'))){$id=(Get-FileFixtureIdentity -Path ($path));$members.Add(@{path=$path;id=$id;prior=[string[]]@((Find-FileFixtureBinIdentity -ExpectedId ($id))|ForEach-Object Pidl)})}
  $sparsePath=Join-Path $root 'huge-sparse';$prefix=$utf8.GetBytes('independent owned sparse '+$i);$length=[long]1099511627776
  $stream=[IO.FileStream]::new($sparsePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  try{Set-FileFixtureSparse -Handle $stream.SafeFileHandle;$stream.Write($prefix,0,$prefix.Length);$stream.SetLength($length);$stream.Flush($true)}finally{$stream.Dispose()}
  $proof=Get-FileFixtureSparseProof -Path $sparsePath -Scope $scope.files
  Assert-R ($proof.Length-eq$length-and$proof.NumberOfLinks-eq1-and$proof.AllocationSize-le1MB-and$proof.CompressedSize-le1MB) 'Invalid sparse fixture'
  $prior=[string[]]@((Find-FileFixtureBinIdentity -ExpectedId ($proof.Id))|ForEach-Object Pidl)
  $members.Add(@{path=$sparsePath;id=$proof.Id;prior=$prior;proof=$proof;prefix=[Convert]::ToBase64String($prefix)})
  $roots.Add($root);$witnesses.Add(@{path=$witness;before=$witnessBefore;prior=$witnessPrior});$state.roots+=@(@{path=$root;before=$rootBefore;sparse=$proof});$state.witnesses+=@(@{path=$witness;before=$witnessBefore;prior=$witnessPrior})
 }
 $state.members=@($members)
 $observed=& $hostScript -ExecutablePath $ExecutablePath -RustProbePath $RustProbePath -BuildManifestPath $BuildManifestPath -ExpectedBuildManifestSha256 $ExpectedBuildManifestSha256 -ConfigPath $scope.config -FixtureRoot $scope.files -OutputDirectory $OutputDirectory -Case 'file-independent-roots';$state.checkpoint=$observed
 Assert-R ($observed.sizeRefusals-eq2-and$observed.parallelShellReady-and$observed.firstPinned-and$observed.secondPinnedWhileFirstHeld-and$observed.firstReleased) 'Independent pin rendezvous failed'
 Assert-R (@($observed.result['items']).Count-eq2) 'Core deletion failed or returned wrong item count'
 for($i=0;$i-lt2;$i++) {Assert-R ($observed.result['items'][$i]['path']-ceq$roots[$i]-and$observed.result['items'][$i]['status']-ceq'permanently_deleted'-and![IO.Directory]::Exists($roots[$i])) 'Unexpected root deletion result'}
 foreach($member in $members){$new=@((Find-FileFixtureBinIdentity -ExpectedId ($member.id))|Where-Object {$_.Pidl-notin$member.prior});Assert-R ($new.Count-eq0) ('Unexpected Bin entry for '+$member.path)}
 foreach($witness in $witnesses){$null=Assert-SnapshotR $witness.path $witness.before;$new=@((Find-FileFixtureBinIdentity -ExpectedId ($witness.before[0].Id))|Where-Object {$_.Pidl-notin$witness.prior});Assert-R ($new.Count-eq0) 'External link target entered Bin'}
 No-FileRecordsR $scope
 foreach($source in $sources){Assert-R ((Get-FileHash -LiteralPath $source.path).Hash-ceq$source.sha256) 'Verification source changed'}
 Assert-R ((Get-RustFileSourceFingerprint $repo)-ceq$buildBinding.sourceFingerprint-and(Get-FileHash -LiteralPath $ExecutablePath).Hash.ToLowerInvariant()-ceq$buildBinding.candidateSha256-and(Get-FileHash -LiteralPath $RustProbePath).Hash.ToLowerInvariant()-ceq$buildBinding.probeSha256) 'Candidate or source changed'
 # 外部リンク先は親の照合後に配置済みCLIで清掃するため保持する。
 $state.fixtureDisposition='deleted roots; owned witness fixtures and output retained for separately verified cleanup';$state.passed=$true
} catch {$state.error=$_.Exception.ToString();$state.stack=$_.ScriptStackTrace}
finally {
 $report=@{suite='oversize-parallel-independence';executable=$ExecutablePath;executableSha256=$exeHash;rustProbePath=$RustProbePath;sameSourceBuild=$buildBinding;fixtureRun=$script:fixtureRun;scope='Actual Shell and same-source cfg(test) Core; CLI/MCP E2E separate';sources=$sources;result=$state;commands=@($script:commands);retained=$OutputDirectory;passed=[int]$state.passed;failed=[int](!$state.passed)}
 try{$bytes=$utf8.GetBytes((ConvertTo-Json -InputObject $report -Depth 100));$stream=[IO.FileStream]::new($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}}finally{$env:TEMP=$oldTemp;$env:TMP=$oldTmp}
}
if(!$state.passed){throw 'Oversize parallel verification failed; inspect report and retain uncertain fixtures'}
