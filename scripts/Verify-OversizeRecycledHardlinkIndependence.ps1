[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$RustProbePath,[Parameter(Mandatory)][string]$BuildManifestPath,[Parameter(Mandatory)][string]$ExpectedBuildManifestSha256,[Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$ReportPath,[Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference='Stop'
# 失敗モデル: Shell未到達、無関係aliasの書込み抑止、誤った対象ID、内容/ACL/リンク損傷、曖昧結果の再送。
$repo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent));. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
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
$hostScript=Join-Path $PSScriptRoot 'recordless-e2e/OversizeIndependenceHost.ps1';$common=Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1';. $common
$helperFiles=@('FileFixtures.Common.ps1','FixtureBridge.Common.ps1')|ForEach-Object {Join-Path $PSScriptRoot $_}
$sources=@(@($PSCommandPath,$hostScript,$common,(Join-Path $PSScriptRoot 'SparseFixtures.Common.ps1'),(Join-Path $PSScriptRoot 'FileFixtures.Common.ps1'))+$helperFiles|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}})
$sources+=@(Get-RustFileProbeSourceHashes)
$null=[IO.Directory]::CreateDirectory($OutputDirectory);$script:temp=Join-Path $OutputDirectory 'temp';$null=[IO.Directory]::CreateDirectory($script:temp)
$oldTemp=$env:TEMP;$oldTmp=$env:TMP;$env:TEMP=$script:temp;$env:TMP=$script:temp
$script:commands=[Collections.Generic.List[object]]::new();$script:observed=@{};$state=@{passed=$false;fixtureDisposition='retained; do not retry uncertain deletion'}
try {
 $scope=New-ScopeR 'mixed-independent';$state.scope=$scope.root
 $small=Join-Path $scope.files 'recycled-small.txt';$alias=Join-Path $scope.files 'external-alias.txt'
 [IO.File]::WriteAllText($small,'independent recycled hardlink fixture',$utf8)
 (New-FileFixtureHardlink -Link ($alias) -Source ($small) -Scope $scope.files)
 $smallBefore=Snapshot-R $small;$aliasBefore=Snapshot-R $alias
 Assert-R ($smallBefore[0].Id-ceq$aliasBefore[0].Id-and$smallBefore[0].NumberOfLinks-eq2-and$aliasBefore[0].NumberOfLinks-eq2) 'Fixture hardlink identity mismatch'
 $priorSmall=Before-BinR $smallBefore;$state.small=@{path=$small;before=$smallBefore;prior=$priorSmall};$state.alias=@{path=$alias;before=$aliasBefore}
 $root=Join-Path $scope.files 'huge-root';$null=[IO.Directory]::CreateDirectory($root)
 $child=Join-Path $root 'small.txt';[IO.File]::WriteAllText($child,'unrelated huge root child',$utf8)
 $rootBefore=Snapshot-R $root;$rootPrior=Before-BinR $rootBefore;$childBefore=Snapshot-R $child;$childPrior=Before-BinR $childBefore
 $sparse=Join-Path $root 'huge-sparse';$prefix=$utf8.GetBytes('unrelated owned sparse');$length=[long]1099511627776
 $stream=[IO.FileStream]::new($sparse,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{Set-FileFixtureSparse -Handle $stream.SafeFileHandle;$stream.Write($prefix,0,$prefix.Length);$stream.SetLength($length);$stream.Flush($true)}finally{$stream.Dispose()}
 $proof=Get-FileFixtureSparseProof -Path $sparse -Scope $scope.files
 Assert-R ($proof.Length-eq$length-and$proof.NumberOfLinks-eq1-and$proof.AllocationSize-le1MB-and$proof.CompressedSize-le1MB) 'Invalid sparse fixture'
 $sparsePrior=[string[]]@((Find-FileFixtureBinIdentity -ExpectedId ($proof.Id))|ForEach-Object Pidl)
 $state.huge=@{path=$root;before=$rootBefore;prior=$rootPrior;childBefore=$childBefore;childPrior=$childPrior;sparsePath=$sparse;sparse=$proof;sparsePrefix=[Convert]::ToBase64String($prefix);sparsePrior=$sparsePrior}
 $observed=& $hostScript -ExecutablePath $ExecutablePath -RustProbePath $RustProbePath -BuildManifestPath $BuildManifestPath -ExpectedBuildManifestSha256 $ExpectedBuildManifestSha256 -ConfigPath $scope.config -FixtureRoot $scope.files -OutputDirectory $OutputDirectory -Case 'file-recycled-alias-independent';$state.checkpoint=$observed
 Assert-R ($observed.sizeRefusals-eq1-and$observed.aliasWriteOpen-and$observed.aliasIdentityMatched) 'Alias write-open failed during pinned unrelated child'
 Assert-R (@($observed.result['items']).Count-eq2) 'Core batch failed or returned wrong item count'
 Assert-R ($observed.result['items'][0]['path']-ceq$small-and$observed.result['items'][0]['status']-ceq'recycled'-and![IO.File]::Exists($small)) 'Small file was not recycled'
 Assert-R ($observed.result['items'][1]['path']-ceq$root-and$observed.result['items'][1]['status']-ceq'permanently_deleted'-and![IO.Directory]::Exists($root)) 'Huge root was not permanently deleted'
 $bin=(Find-FileFixtureBinNew -ExpectedId ($smallBefore[0].Id) -PriorPidls ($priorSmall));$state.newBin=$bin
 $state.binProof=Assert-SnapshotR $bin.PhysicalPath $smallBefore -WindowsManagedBin
 $state.aliasAfter=Assert-SnapshotR $alias $aliasBefore -WindowsManagedBin
 $state.securityComparison=@{note='Windows Bin movement may change the original ACL; the Bin object and surviving alias must have identical owner/group/DACL descriptor bytes after movement';before=$smallBefore[0].SecurityBase64;bin=$state.binProof[0].SecurityBase64;alias=$state.aliasAfter[0].SecurityBase64;changed=($smallBefore[0].SecurityBase64-cne$state.binProof[0].SecurityBase64);afterEqual=($state.binProof[0].SecurityBase64-ceq$state.aliasAfter[0].SecurityBase64)}
 Assert-R $state.securityComparison.afterEqual 'Bin object and external alias owner/group/DACL descriptor bytes differ after Windows movement'
 foreach($member in @(@{id=$rootBefore[0].Id;prior=$rootPrior},@{id=$childBefore[0].Id;prior=$childPrior},@{id=$proof.Id;prior=$sparsePrior})) {
  $new=@((Find-FileFixtureBinIdentity -ExpectedId ($member.id))|Where-Object {$_.Pidl-notin$member.prior});Assert-R ($new.Count-eq0) 'Unexpected huge-root Bin entry'
 }
 No-FileRecordsR $scope
 foreach($source in $sources){Assert-R ((Get-FileHash -LiteralPath $source.path).Hash-ceq$source.sha256) 'Verification source changed'}
 Assert-R ((Get-RustFileSourceFingerprint $repo)-ceq$buildBinding.sourceFingerprint-and(Get-FileHash -LiteralPath $ExecutablePath).Hash.ToLowerInvariant()-ceq$buildBinding.candidateSha256-and(Get-FileHash -LiteralPath $RustProbePath).Hash.ToLowerInvariant()-ceq$buildBinding.probeSha256) 'Candidate or source changed'
 $state.fixtureDisposition='recycled owned small file and surviving alias retained; huge root deleted; output retained for separately verified cleanup';$state.passed=$true
} catch {$state.error=$_.Exception.ToString();$state.stack=$_.ScriptStackTrace}
finally {
 $report=@{suite='oversize-recycled-hardlink-independence';executable=$ExecutablePath;executableSha256=$exeHash;rustProbePath=$RustProbePath;sameSourceBuild=$buildBinding;fixtureRun=$script:fixtureRun;scope='Actual Shell and same-source cfg(test) Core; CLI/MCP E2E separate';sources=$sources;result=$state;commands=@($script:commands);retained=$OutputDirectory;passed=[int]$state.passed;failed=[int](!$state.passed)}
 try{$bytes=$utf8.GetBytes((ConvertTo-Json -InputObject $report -Depth 100));$stream=[IO.FileStream]::new($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}}finally{$env:TEMP=$oldTemp;$env:TMP=$oldTmp}
}
if(!$state.passed){throw 'Recycled hardlink independence verification failed; inspect report and retain uncertain fixtures'}
