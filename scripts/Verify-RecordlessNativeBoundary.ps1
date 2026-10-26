[CmdletBinding()]
param([Parameter(Mandatory)][string]$AssemblyPath,[Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedAssemblySha256,[Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop'
# 想定する失敗: copied-mask鏡検証、別assembly、READ_DATA要求によるdelete可/read不可拒否、
# DELETE名前pin不足、pin解放後のrename拒否、ACL修復失敗、原本native証拠の欠落。
$repo=Split-Path $PSScriptRoot -Parent;. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach($path in @($AssemblyPath,$OutputDirectory,$ReportPath)){if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute paths required'}}
foreach($path in @($OutputDirectory,$ReportPath)){Assert-VerificationDestination $path @($repo,(Join-Path $env:USERPROFILE '.codex'));if(![IO.Path]::GetPathRoot($path).Equals('D:\',[StringComparison]::OrdinalIgnoreCase)-or(Test-Path -LiteralPath $path)){throw 'Unused external D output required'}}
if((Get-FileHash $AssemblyPath).Hash-ine$ExpectedAssemblySha256){throw 'Actual production assembly SHA mismatch'}
$null=[IO.Directory]::CreateDirectory($OutputDirectory);$script:temp=Join-Path $OutputDirectory 'temp';$null=[IO.Directory]::CreateDirectory($script:temp);$oldTemp=$env:TEMP;$oldTmp=$env:TMP;$env:TEMP=$script:temp;$env:TMP=$script:temp
$helperFiles=@('NativeShellFixture.cs','FixtureNative.cs','OwnedBinLocator.cs','PermissionFixture.cs')|ForEach-Object {Join-Path (Join-Path $PSScriptRoot 'recordless-e2e') $_};. (Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1')
$results=[Collections.Generic.List[object]]::new();$sources=@($PSCommandPath)+$helperFiles
try{
 Add-Type -Path $helperFiles -CompilerOptions '/unsafe'
 $assembly=[Reflection.Assembly]::LoadFrom($AssemblyPath);$native=$assembly.GetType('Prunlet.Core.NativeFiles',$true);$method=$native.GetMethod('OpenRecordlessPreflight',[Reflection.BindingFlags]'NonPublic,Static');Assert-R ($null-ne$method) 'Actual production root pin method missing'
 foreach($kind in @('file','directory','child','read-denied-delete-allowed')){
  $facts=@{};$pin=$null;$restoreDacl=$null;$path=$null;$moved=$null
  try{
   $scope=Join-Path $OutputDirectory $kind;$null=[IO.Directory]::CreateDirectory($scope);$path=Join-Path $scope 'source';$moved=Join-Path $scope 'moved'
   if($kind-ceq'directory'){$null=[IO.Directory]::CreateDirectory($path);[IO.File]::WriteAllText((Join-Path $path 'child'),'directory child')}else{if($kind-ceq'child'){$parent=Join-Path $scope 'parent';$null=[IO.Directory]::CreateDirectory($parent);$path=Join-Path $parent 'source';$moved=Join-Path $parent 'moved'};[IO.File]::WriteAllText($path,'same native object/data')}
   $before=Snapshot-R $path;$facts.before=$before;$facts.sourcePath=$path;$facts.movedPath=$moved
   if($kind-ceq'read-denied-delete-allowed'){$restoreDacl=[Convert]::FromBase64String($before[0].SecurityBase64);[Prunlet.RecordlessE2E.PermissionFixture]::DenyDataRead($path,$restoreDacl);$facts.readDataError=[Prunlet.RecordlessE2E.PermissionFixture]::ReadDataError($path);Assert-R ($facts.readDataError-eq5) 'Read-denied fixture did not produce native ERROR_ACCESS_DENIED'}
   $pin=$method.Invoke($null,[object[]]@([string]$path));$facts.grantedAccess=[Prunlet.RecordlessE2E.PermissionFixture]::GrantedAccess($pin);$facts.requestedRightsVerified=(($facts.grantedAccess-band0x10080)-eq0x10080-and($facts.grantedAccess-band0x20001)-eq0);Assert-R $facts.requestedRightsVerified 'Actual production pin access does not match DELETE|READ_ATTRIBUTES without data/security read'
   $facts.renameWhileHeldSucceeded=$false;try{if($kind-ceq'directory'){[IO.Directory]::Move($path,$moved)}else{[IO.File]::Move($path,$moved)};$facts.renameWhileHeldSucceeded=$true}catch{$facts.renameWhileHeldHResult=$_.Exception.InnerException.HResult;if(!$facts.renameWhileHeldHResult){$facts.renameWhileHeldHResult=$_.Exception.HResult}}
   Assert-R (!$facts.renameWhileHeldSucceeded-and($facts.renameWhileHeldHResult-band0xffff)-eq32) 'Actual production pin did not reject rename with ERROR_SHARING_VIOLATION'
   $pin.Dispose();$pin=$null;if($kind-ceq'directory'){[IO.Directory]::Move($path,$moved)}else{[IO.File]::Move($path,$moved)};$facts.renameAfterReleaseSucceeded=$true
   if($restoreDacl){[Prunlet.RecordlessE2E.PermissionFixture]::SetDacl($moved,$restoreDacl);$restoreDacl=$null}
   $facts.after=Assert-SnapshotR $moved $before;$results.Add(@{name=$kind;passed=$true;observed=$facts})
  }catch{$results.Add(@{name=$kind;passed=$false;error=$_.Exception.ToString();observed=$facts})}
  finally{if($pin){$pin.Dispose()};if($restoreDacl){$target=if([IO.File]::Exists($path)){$path}else{$moved};try{[Prunlet.RecordlessE2E.PermissionFixture]::SetDacl($target,$restoreDacl)}catch{$results.Add(@{name=$kind+'-fixture-acl-finalizer';passed=$false;error=$_.Exception.ToString()})}}}
 }
}finally{
 $report=@{suite='actual-production-recordless-rootpin';assemblyPath=$AssemblyPath;assemblySha256=(Get-FileHash $AssemblyPath).Hash;actualMethod='Prunlet.Core.NativeFiles.OpenRecordlessPreflight';sourceSha256=(Get-FileHash $PSCommandPath).Hash;sources=@($sources|ForEach-Object {@{path=$_;sha256=(Get-FileHash $_).Hash}});expectedCount=4;executedCount=$results.Count;passed=@($results|Where-Object passed).Count;failed=@($results|Where-Object {!$_.passed}).Count;results=@($results);retained=$OutputDirectory;scope='Actual production method via reflection; own file/directory/child only; no Shell/CLI/Bin/volume/registry mutation.'};if($results.Count-ne4){$report.failed++;$report.countMismatch=$true};Save-R $ReportPath $report;$env:TEMP=$oldTemp;$env:TMP=$oldTmp
}
$report|Select-Object passed,failed,expectedCount,executedCount|ConvertTo-Json;if($report.failed){exit 1}
