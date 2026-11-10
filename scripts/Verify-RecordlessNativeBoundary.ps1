[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$RustProbePath,[Parameter(Mandatory)][string]$BuildManifestPath,[Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedBuildManifestSha256,[Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop'
# 想定する失敗: copied-mask鏡検証、別assembly、READ_DATA要求によるdelete可/read不可拒否、
# DELETE名前pin不足、pin解放後のrename拒否、ACL修復失敗、原本native証拠の欠落。
$repo=Split-Path $PSScriptRoot -Parent;. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach($path in @($ExecutablePath,$RustProbePath,$BuildManifestPath,$OutputDirectory,$ReportPath)){if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute paths required'}}
foreach($path in @($OutputDirectory,$ReportPath)){Assert-VerificationDestination $path @($repo,(Join-Path $env:USERPROFILE '.codex'));if(![IO.Path]::GetPathRoot($path).Equals('D:\',[StringComparison]::OrdinalIgnoreCase)-or(Test-Path -LiteralPath $path)){throw 'Unused external D output required'}}
. (Join-Path $PSScriptRoot 'recordless-e2e/RustFileProbe.Common.ps1')
$buildBinding=Assert-RustFileProbeBinding
. (Join-Path $PSScriptRoot 'FileFixtures.Common.ps1')
$null=Initialize-PrunletFixtureBinding -ExecutablePath $ExecutablePath -BuildManifestPath $BuildManifestPath -ExpectedBuildManifestSha256 $ExpectedBuildManifestSha256
$null=[IO.Directory]::CreateDirectory($OutputDirectory);$script:temp=Join-Path $OutputDirectory 'temp';$null=[IO.Directory]::CreateDirectory($script:temp);$oldTemp=$env:TEMP;$oldTmp=$env:TMP;$env:TEMP=$script:temp;$env:TMP=$script:temp
$common=Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1';. $common
# 共通assertの入力は同一processの独立fixture DLLで取得する。
function Snapshot-R([string]$Path){Get-FileFixtureSnapshot -Path $Path}
$results=[Collections.Generic.List[object]]::new();$sources=@($PSCommandPath,$common,(Join-Path $PSScriptRoot 'FileFixtures.Common.ps1'))
try{
 foreach($kind in @('file','directory','child','read-denied-delete-allowed')){
  $facts=@{};$pin=$null;$aclLease=$null;$path=$null;$moved=$null
  try{
   $scope=Join-Path $OutputDirectory $kind;$null=[IO.Directory]::CreateDirectory($scope);$path=Join-Path $scope 'source';$moved=Join-Path $scope 'moved'
   if($kind-ceq'directory'){$null=[IO.Directory]::CreateDirectory($path);[IO.File]::WriteAllText((Join-Path $path 'child'),'directory child')}else{if($kind-ceq'child'){$parent=Join-Path $scope 'parent';$null=[IO.Directory]::CreateDirectory($parent);$path=Join-Path $parent 'source';$moved=Join-Path $parent 'moved'};[IO.File]::WriteAllText($path,'same native object/data')}
   $before=Snapshot-R $path;$legacyId=Get-FileFixtureLegacyIdentity -Path $path;$facts.before=$before;$facts.sourcePath=$path;$facts.movedPath=$moved;$null=[IO.Directory]::CreateDirectory((Join-Path $scope 'metadata'))
   if($kind-ceq'read-denied-delete-allowed'){$aclLease=New-FileFixtureAccessLease -Path $path -Scope $scope -WritableAcl -ExpectedId $before[0].Id -ExpectedSecurityBase64 $before[0].SecurityBase64;$aclLease.DenyRead();$facts.readDataError=Get-FileFixtureOpenError -Path $path -Access 1;Assert-R ($facts.readDataError-eq5) 'Read-denied fixture did not produce native ERROR_ACCESS_DENIED'}
   $probe=Invoke-RustFileContract ('file-root-pin-'+$kind) $scope
   $facts.probe=$probe;$result=$probe.result
   Assert-R ($result.kind-ceq$kind-and$result.source-ceq$path-and$result.moved-ceq$moved-and$result.originalId-ceq$legacyId) 'Core probe did not bind the exact fixture and original identity'
   Assert-R (($result.grantedAccess-band0x10080)-eq0x10080-and($result.grantedAccess-band0x20001)-eq0-and$result.renameWhileHeldError-eq32-and$result.renameAfterReleaseSucceeded) 'Core pin access or rename behavior differed'
   Assert-R ((Get-FileFixtureIdentity -Path $moved)-ceq$before[0].Id) 'Fixture identity changed before ACL restoration'
   if($aclLease){$aclLease.Dispose()}
   $facts.after=Assert-SnapshotR $moved $before;$results.Add(@{name=$kind;passed=$true;observed=$facts})
  }catch{$results.Add(@{name=$kind;passed=$false;error=$_.Exception.ToString();observed=$facts})}
  finally{if($pin){$pin.Dispose()};if($aclLease-and$aclLease.ReleaseState-ceq'open'){try{$aclLease.Dispose()}catch{$facts.aclRelease=@{state=$aclLease.ReleaseState;leaseId=$aclLease.LastLeaseId;resubmitted=$false};$results.Add(@{name=$kind+'-fixture-acl-finalizer';passed=$false;error=$_.Exception.ToString()})}}elseif($aclLease-and$aclLease.ReleaseState-ceq'unknown'){$facts.aclRelease=@{state='unknown';leaseId=$aclLease.LastLeaseId;resubmitted=$false}}}
 }
}finally{
 $report=@{suite='actual-production-recordless-rootpin';executablePath=$ExecutablePath;rustProbePath=$RustProbePath;sameSourceBuild=$buildBinding;actualMethod='Rust files::recordless::prepare';sourceSha256=(Get-FileHash $PSCommandPath).Hash;sources=@($sources|ForEach-Object {@{path=$_;sha256=(Get-FileHash $_).Hash}});expectedCount=4;executedCount=$results.Count;passed=@($results|Where-Object passed).Count;failed=@($results|Where-Object {!$_.passed}).Count;results=@($results);retained=$OutputDirectory;scope='Same-source cfg(test) Rust Core preflight; separate from shipping CLI/MCP; own file/directory/child only, no Shell/Bin mutation.'};if($results.Count-ne4){$report.failed++;$report.countMismatch=$true};Save-R $ReportPath $report;$env:TEMP=$oldTemp;$env:TMP=$oldTmp
}
$report|Select-Object passed,failed,expectedCount,executedCount|ConvertTo-Json;if($report.failed){exit 1}
