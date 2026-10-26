# 失敗条件を先に固定する: 別fixtureのBin操作、同名置換、stream/IDの喪失、外部操作後のOGD/属性変更、
# 不確かな不在の採用、未知metadataの清掃、未commit証拠の再利用、commit後のSource書込み、
# dry-runの変更、subset/未実行/境界未捕捉を全件成功へ数えることを拒否する。
[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$ExecutablePath,
 [Parameter(Mandatory)][string]$BaselineExecutablePath,
 [string]$MoveExecutablePath,
 [string]$LegacyCopyExecutablePath,
 [string]$PriorTypedExecutablePath,
 [string]$PriorTypedExecutableSha256,
 [Parameter(Mandatory)][string]$OutputDirectory,
 [Parameter(Mandatory)][string]$ReportPath,
 [ValidateNotNullOrEmpty()][string[]]$CaseFilter=@('*'),
 [switch]$Large,
 [ValidateRange(100,60000)][int]$LargeFileCount=32769
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
$utf8=[Text.UTF8Encoding]::new($false)
foreach($path in @($ExecutablePath,$BaselineExecutablePath,$OutputDirectory,$ReportPath)+@($MoveExecutablePath,$LegacyCopyExecutablePath,$PriorTypedExecutablePath|Where-Object {$_})){
 if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute input/output paths required'}
}
if([IO.Path]::GetPathRoot($OutputDirectory)-cne'D:\'-or[IO.Path]::GetPathRoot($ReportPath)-cne'D:\'){throw 'Isolated external D output and report paths required'}
Assert-VerificationDestination $OutputDirectory @([IO.Path]::GetFullPath((Split-Path $PSScriptRoot)),(Join-Path $env:USERPROFILE '.codex'))
Assert-VerificationDestination $ReportPath @([IO.Path]::GetFullPath((Split-Path $PSScriptRoot)),(Join-Path $env:USERPROFILE '.codex'))
if([IO.Directory]::Exists($OutputDirectory)-or[IO.File]::Exists($OutputDirectory)){throw 'Unused external output directory required'}
foreach($parent in @((Split-Path $OutputDirectory),(Split-Path $ReportPath))){if(![IO.Directory]::Exists($parent)){throw 'Create external output/report parents first'}}
if([Diagnostics.FileVersionInfo]::GetVersionInfo($BaselineExecutablePath).ProductVersion-notmatch'^1\.0\.15(?:[.+-]|$)'){throw 'Genuine 1.0.15 baseline required'}
if($MoveExecutablePath-and[Diagnostics.FileVersionInfo]::GetVersionInfo($MoveExecutablePath).ProductVersion-notmatch'^1\.0\.11(?:[.+-]|$)'){throw 'Genuine 1.0.11 move producer required'}
function Selected-External([string]$Name){return @($CaseFilter|Where-Object {$Name-like$_}).Count-gt0}
$requirements=@(
 @{names=@('schema4-whole-container-absence-closes','schema4-payload-only-empty-container-closes','schema4-unknown-child-preserved','schema4-replacement-container-preserved','schema4-container-ads-preserved','schema4-unfinished-restore-preserved','schema4-negative-cache-and-delete-access-auto-recovery','schema4-before-delete-metadata-change','schema4-after-delete-resumes','schema4-after-delete-source-reappears','schema4-after-delete-bin-reappears','schema6-true87-nested-metadata-directory','handoff-schema4-purge-complete-closes','handoff-schema4-malformed-complete-cache-and-repair');value=$MoveExecutablePath;label='MoveExecutablePath (genuine 1.0.11)'},
 @{names=@('legacy-schema1-normal-terminal','legacy-schema2-normal-terminal','legacy-schema3-normal-terminal');value=$LegacyCopyExecutablePath;label='LegacyCopyExecutablePath (genuine 1.0.9)'},
 @{names=@('schema6-prior-typed-no-hint-closes');value=$PriorTypedExecutablePath;label='PriorTypedExecutablePath and exact prior-build SHA'}
)
foreach($requirement in $requirements){if(@($requirement.names|Where-Object {Selected-External $_}).Count-and!$requirement.value){throw ('Selected cases require '+$requirement.label)}}
if(Selected-External 'schema6-prior-typed-no-hint-closes'){if($PriorTypedExecutableSha256-cnotmatch'^[a-fA-F0-9]{64}$'-or(Get-FileHash -LiteralPath $PriorTypedExecutablePath).Hash-cne$PriorTypedExecutableSha256.ToUpperInvariant()){throw 'Exact frozen prior typed executable SHA required'}}
if($LegacyCopyExecutablePath-and[Diagnostics.FileVersionInfo]::GetVersionInfo($LegacyCopyExecutablePath).ProductVersion-notmatch'^1\.0\.9(?:[.+-]|$)'){throw 'Genuine 1.0.9 copy producer required'}
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$env:TEMP=Join-Path $OutputDirectory 'temp';$env:TMP=$env:TEMP;$null=[IO.Directory]::CreateDirectory($env:TEMP)
$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR=Join-Path $OutputDirectory 'runtime-cache'
$nativeFiles=@((Join-Path $PSScriptRoot 'external-unavailable-e2e/NativeShellFixture.cs'),(Join-Path $PSScriptRoot 'external-unavailable-e2e/FixtureNative.cs'))
Add-Type -Path $nativeFiles -CompilerOptions '/unsafe'
$results=[Collections.Generic.List[object]]::new();$commands=[Collections.Generic.List[object]]::new();$registered=[Collections.Generic.List[string]]::new();$excluded=[Collections.Generic.List[string]]::new()
function Assert-External([bool]$Condition,[string]$Message){if(!$Condition){throw $Message}}
function Invoke-ExternalCli([string]$Exe,[string]$Config,[string[]]$Arguments){
 foreach($value in @($Exe,$Config)+$Arguments){if($value-match'[\s"&|<>^%!()]'){throw 'Unsafe CMD control argument; real targets must use paths-file'}}
 $info=[Diagnostics.ProcessStartInfo]::new('cmd.exe');$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.StandardOutputEncoding=$utf8;$info.StandardErrorEncoding=$utf8
 $info.Arguments='/d /c '+$Exe+' --config '+$Config+' '+($Arguments-join' ')
 $process=[Diagnostics.Process]::Start($info);$clock=[Diagnostics.Stopwatch]::StartNew()
 try{
  $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();if(!$process.WaitForExit(240000)){$process.Kill($true);$process.WaitForExit();throw 'External-unavailable CLI timeout'}
  $text=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult();$json=$null;try{$json=$text|ConvertFrom-Json -AsHashtable -Depth 100}catch{}
  $response=@{exitCode=$process.ExitCode;stdout=$text;stderr=$errorText;json=$json;milliseconds=$clock.Elapsed.TotalMilliseconds}
  $commands.Add(@{exe=$Exe;config=$Config;arguments=$Arguments;response=$response});return $response
 }finally{$process.Dispose()}
}
function New-ExternalScope([string]$Name,[string]$Producer){
 $root=Join-Path $OutputDirectory $Name;$null=[IO.Directory]::CreateDirectory($root)
 $scope=@{root=$root;files=(Join-Path $root 'files');metadata=(Join-Path $root 'metadata');config=(Join-Path $root 'config.json')}
 $null=[IO.Directory]::CreateDirectory($scope.files);$null=[IO.Directory]::CreateDirectory($scope.metadata)
 $r=Invoke-ExternalCli $Producer $scope.config @('init','--backup-directory',$scope.metadata);Assert-External ($r.exitCode-eq0) ('Producer init failed: '+$r.stdout+$r.stderr)
 $config=[IO.File]::ReadAllText($scope.config)|ConvertFrom-Json -AsHashtable -Depth 100
 $config.volumeRecoveryDirectories=@{'D:/'=(Join-Path $root 'volume-store')};[IO.File]::WriteAllText($scope.config,($config|ConvertTo-Json -Depth 100),$utf8)
 return $scope
}
function Get-ExternalSnapshot([string]$Path){return ,@([Prunlet.ExternalUnavailableE2E.FixtureNative]::SnapshotTree($Path))}
function Assert-ExternalSnapshot([string]$Path,[object[]]$Expected,[switch]$DataOnly){
 $actual=Get-ExternalSnapshot $Path
 Assert-External ($actual.Count-eq$Expected.Count) 'External fixture member count changed'
 for($index=0;$index-lt$Expected.Count;$index++){
  $before=$Expected[$index];$after=$actual[$index]
  foreach($field in @('Relative','Id','VolumeSerialNumber','FileId','Directory','NumberOfLinks')){Assert-External ($before.$field-ceq$after.$field) ('External fixture native evidence changed: '+$field+' '+$after.Relative)}
  Assert-External (($before.Streams|ConvertTo-Json -Depth 10 -Compress)-ceq($after.Streams|ConvertTo-Json -Depth 10 -Compress)) ('External fixture all-stream bytes changed: '+$after.Relative)
  if(!$DataOnly){foreach($field in @('SecurityBase64','Attributes')){Assert-External ($before.$field-ceq$after.$field) ('Core changed external fixture '+$field+' '+$after.Relative)}}
 }
 return ,$actual
}
function Get-ExternalMetadata([string]$Root,[string]$ExcludePath){
 return @((Get-ChildItem -Force -LiteralPath $Root -File -Recurse|Where-Object {!$ExcludePath-or$_.FullName-cne$ExcludePath}|Sort-Object FullName)|ForEach-Object {$_.FullName.Substring($Root.Length)+'='+[Prunlet.ExternalUnavailableE2E.FixtureNative]::Identity($_.FullName)+'='+$_.Length+'='+(Get-FileHash -LiteralPath $_.FullName).Hash})-join"`n"
}
function Get-ExternalNamespace([string]$Root){return @((Get-ChildItem -Force -LiteralPath $Root -Recurse|Sort-Object FullName)|ForEach-Object {$_.FullName.Substring($Root.Length)+'='+$_.PSIsContainer})-join"`n"}
function New-ExternalBinFixture([string]$Name,[string]$Producer,[int]$FileCount=3,[switch]$SingleFile,[switch]$HardlinkAlias){
 $scope=New-ExternalScope $Name $Producer;$source=Join-Path $scope.files 'original-tree';if($SingleFile){$source=Join-Path $scope.files 'original-file.txt';[IO.File]::WriteAllText($source,'external-single-file',$utf8);[IO.File]::WriteAllText(($source+':fixture.ads'),'external ADS bytes',$utf8)}else{$null=[IO.Directory]::CreateDirectory($source)
 foreach($index in 0..($FileCount-1)){$path=Join-Path $source ('file-{0:D6}.txt'-f$index);[IO.File]::WriteAllText($path,('external-fixture-'+$index),$utf8);if($index-eq0){[IO.File]::WriteAllText(($path+':fixture.ads'),'external ADS bytes',$utf8)}}
 [IO.File]::WriteAllText(($source+':directory.ads'),'external directory ADS',$utf8)
 }
 $alias=$null;if($HardlinkAlias){Assert-External ([bool]$SingleFile) 'Hardlink fixture requires a single-file root';$aliasParent=Join-Path $scope.files 'hardlink-alias-parent';$null=[IO.Directory]::CreateDirectory($aliasParent);$alias=Join-Path $aliasParent 'alias.txt';[Prunlet.ExternalUnavailableE2E.FixtureNative]::CreateHardlink($alias,$source)}
 $before=Get-ExternalSnapshot $source;$paths=Join-Path $scope.root 'paths.json';[IO.File]::WriteAllText($paths,(ConvertTo-Json -InputObject @($source)),$utf8)
 $deleted=Invoke-ExternalCli $Producer $scope.config @('delete','--recursive','--paths-file',$paths)
 Assert-External ($deleted.exitCode-eq0-and$deleted.json.operationId-and@($deleted.json.items).Count-eq1-and$deleted.json.items[0].status-ceq'deleted'-and![IO.Directory]::Exists($source)) ('Genuine producer recycle failed: '+$deleted.stdout+$deleted.stderr)
 $id=$deleted.json.operationId;$record=Resolve-VerificationOperationDirectory $scope.metadata $id
 $manifest=[IO.File]::ReadAllText((Join-Path $record 'recycle-manifest.json'))|ConvertFrom-Json -AsHashtable -Depth 100
 $receiptPath=Join-Path $record 'recycle-0000-complete.json';$receipt=[IO.File]::ReadAllText($receiptPath)|ConvertFrom-Json -AsHashtable -Depth 100
 Assert-External ($manifest.schema-eq6-and$manifest.operationId-ceq$id-and$manifest.entries[0].path-ceq$source-and$receipt.operationId-ceq$id-and$receipt.action-ceq'recycle'-and$receipt.phase-ceq'complete'-and$receipt.identity.fileId-ceq$before[0].FileId-and$receipt.identity.volumeSerialNumber-eq$before[0].VolumeSerialNumber-and$receipt.manifestSha256-ceq(Get-FileHash -LiteralPath (Join-Path $record 'recycle-manifest.json')).Hash.ToLowerInvariant()) 'Created fixture receipt is not bound to its real producer, ID and manifest'
 $bin=Assert-ExternalSnapshot $receipt.physicalPath $before -DataOnly
 $script:ExternalEvidence.createdFixture=@{operationId=$id;producer=$Producer;source=$source;record=$record;receipt=$receipt;original=$before;bin=$bin}
 return @{scope=$scope;ownedRoot=$scope.root;id=$id;source=$source;before=$before;binBefore=$bin;receipt=$receipt;record=$record;receiptPath=$receiptPath;producer=$Producer;alias=$alias;alternate=(Join-Path $scope.files 'retained-external-tree')}
}
function Move-ExternalFixtureOutOfBin($Fixture){
 $null=[Prunlet.ExternalUnavailableE2E.FixtureNative]::RestoreOwned($Fixture.receipt.pidl,$Fixture.receipt.physicalPath,$Fixture.before[0].Id,$Fixture.source,$Fixture.ownedRoot)
 $restored=Assert-ExternalSnapshot $Fixture.source $Fixture.before -DataOnly
 [Prunlet.ExternalUnavailableE2E.FixtureNative]::MoveOwned($Fixture.source,$Fixture.alternate,$Fixture.before[0].Id,$Fixture.scope.root)
 $postExternal=Get-ExternalSnapshot $Fixture.alternate;$null=Assert-ExternalSnapshot $Fixture.alternate $restored
 Assert-External (![IO.Directory]::Exists($Fixture.source)-and![IO.File]::Exists($Fixture.receipt.physicalPath)-and![IO.Directory]::Exists($Fixture.receipt.physicalPath)) 'External setup retained an original or recorded Bin path'
 $Fixture.postExternal=$postExternal
 $script:ExternalEvidence.externalBoundary=@{original=$Fixture.before;bin=$Fixture.binBefore;restored=$restored;postExternal=$postExternal;ogdChangedByShell=(@($Fixture.before|ForEach-Object SecurityBase64)-join'|')-cne(@($restored|ForEach-Object SecurityBase64)-join'|');alternate=$Fixture.alternate;receipt=$Fixture.receipt}
}
function Invoke-ExternalDelete([string]$Exe,$Scope,[string[]]$Paths,[switch]$NonRecursive){
 $file=Join-Path $Scope.root ('paths-'+[guid]::NewGuid().ToString('N')+'.json');[IO.File]::WriteAllText($file,(ConvertTo-Json -InputObject $Paths),$utf8)
 $args=@('delete');if(!$NonRecursive){$args+='--recursive'};$args+=@('--paths-file',$file)
 $r=Invoke-ExternalCli $Exe $Scope.config $args;Assert-External ($r.exitCode-eq0-and$r.json.operationId-and@($r.json.items).Count-eq$Paths.Count-and@($r.json.items|Where-Object status -ne 'deleted').Count-eq0) ('Genuine producer delete failed: '+$r.stdout+$r.stderr);return $r
}
function New-ExternalTrackedSource([string]$Name,[string]$Producer,[string]$Source){
 $scope=New-ExternalScope $Name $Producer;$before=Get-ExternalSnapshot $Source;$r=Invoke-ExternalDelete $Producer $scope @($Source);$id=$r.json.operationId;$record=Resolve-VerificationOperationDirectory $scope.metadata $id
 $receipt=[IO.File]::ReadAllText((Join-Path $record 'recycle-0000-complete.json'))|ConvertFrom-Json -AsHashtable -Depth 100
 Assert-External ($receipt.identity.fileId-ceq$before[0].FileId-and$receipt.identity.volumeSerialNumber-eq$before[0].VolumeSerialNumber) 'Nested metadata producer receipt changed native identity'
 $bin=Assert-ExternalSnapshot $receipt.physicalPath $before -DataOnly
 return @{scope=$scope;ownedRoot=$OutputDirectory;source=$Source;before=$before;id=$id;record=$record;receipt=$receipt;binBefore=$bin;alternate=$null}
}
function New-ExternalMoveFixture([string]$Name,[switch]$WholeContainer,[switch]$NoExternal){
 $scope=New-ExternalScope $Name $MoveExecutablePath;$source=Join-Path $scope.files 'original-tree';$null=[IO.Directory]::CreateDirectory($source)
 [IO.File]::WriteAllText((Join-Path $source 'data.txt'),'genuine-schema4-external-data',$utf8);[IO.File]::WriteAllText((Join-Path $source 'data.txt:fixture.ads'),'schema4 ADS',$utf8)
 $before=Get-ExternalSnapshot $source;$r=Invoke-ExternalDelete $MoveExecutablePath $scope @($source);$record=Join-Path $scope.metadata $r.json.operationId
 $manifest=[IO.File]::ReadAllText((Join-Path $record 'move-manifest.json'))|ConvertFrom-Json -AsHashtable -Depth 100
 Assert-External ($manifest.schema-eq4-and$manifest.entries.Count-eq1-and$manifest.entries[0].identity.fileId-ceq$before[0].FileId) 'Genuine11 did not produce a bound schema4 manifest'
 $container=Join-Path $manifest.entries[0].storeRoot $manifest.operationId;$payload=Join-Path $container $manifest.entries[0].payloadName
 $fixture=@{scope=$scope;source=$source;before=$before;id=$manifest.operationId;record=$record;manifest=$manifest;container=$container;containerProof=(Get-ExternalSnapshot $container);payload=$payload;alternate=(Join-Path $scope.files 'retained-schema4-payload')}
 $null=Assert-ExternalSnapshot $payload $before -DataOnly
 if(!$NoExternal){
  if($WholeContainer){$park=Join-Path $scope.files 'retained-whole-container';[Prunlet.ExternalUnavailableE2E.FixtureNative]::MoveOwned($container,$park,$fixture.containerProof[0].Id,$scope.root);$fixture.alternate=Join-Path $park $manifest.entries[0].payloadName;$fixture.extraRetained=@{path=$park;proof=(Get-ExternalSnapshot $park)}}
  else{[Prunlet.ExternalUnavailableE2E.FixtureNative]::MoveOwned($payload,$fixture.alternate,$before[0].Id,$scope.root)}
  $fixture.postExternal=Get-ExternalSnapshot $fixture.alternate;$null=Assert-ExternalSnapshot $fixture.alternate $before -DataOnly
 }
 $script:ExternalEvidence.schema4Fixture=@{id=$fixture.id;manifest=$manifest;container=$container;containerProof=$fixture.containerProof;payload=$payload;alternate=$fixture.alternate;original=$before}
 return $fixture
}
function Assert-ExternalPreserved($Fixture){
 $closed=Join-Path (Join-Path $Fixture.scope.metadata '.closed-records-v1') ($Fixture.id+'.json')
 Assert-External ((Test-Path -LiteralPath $Fixture.record)-and!(Test-Path -LiteralPath $closed)) 'An unsafe/live/incomplete record was falsely closed'
 if($Fixture.postExternal){$null=Assert-ExternalSnapshot $Fixture.alternate $Fixture.postExternal}
 $script:ExternalEvidence.falsePositiveCloseCount=0
}
function Assert-ExternalStableRetention($Fixture){
 $recordBefore=Get-ExternalMetadata $Fixture.record;$recordNames=Get-ExternalNamespace $Fixture.record
 $first=Invoke-ExternalCli $ExecutablePath $Fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.firstMaintenance=$first;Assert-ExternalPreserved $Fixture
 Assert-External ((Get-ExternalMetadata $Fixture.record)-ceq$recordBefore-and(Get-ExternalNamespace $Fixture.record)-ceq$recordNames) 'First retained assessment changed original record IDs/bytes or membership'
 $before=Get-ExternalMetadata $Fixture.scope.metadata;$names=Get-ExternalNamespace $Fixture.scope.metadata
 $next=Invoke-ExternalCli $ExecutablePath $Fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.repeatedMaintenance=$next
 Assert-External ((Get-ExternalMetadata $Fixture.scope.metadata)-ceq$before-and(Get-ExternalNamespace $Fixture.scope.metadata)-ceq$names) 'An unchanged retained record was rewritten or accumulated metadata'
 Assert-ExternalPreserved $Fixture
}
function Start-ExternalProcess($Scope,[string[]]$Arguments){
 foreach($value in @($ExecutablePath,$Scope.config)+$Arguments){if($value-match'[\s"&|<>^%!()]'){throw 'Unsafe CMD boundary argument'}}
 $info=[Diagnostics.ProcessStartInfo]::new('cmd.exe');$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.StandardOutputEncoding=$utf8;$info.StandardErrorEncoding=$utf8
 $info.Arguments='/d /c '+$ExecutablePath+' --config '+$Scope.config+' '+($Arguments-join' ');$p=[Diagnostics.Process]::Start($info)
 return @{process=$p;stdout=$p.StandardOutput.ReadToEndAsync();stderr=$p.StandardError.ReadToEndAsync()}
}
function Finish-ExternalProcess($Session){
 if(!$Session.process.WaitForExit(240000)){$Session.process.Kill($true);$Session.process.WaitForExit();throw 'Boundary process timeout'}
 $text=$Session.stdout.GetAwaiter().GetResult();$json=$null;try{$json=$text|ConvertFrom-Json -AsHashtable -Depth 100}catch{}
 return @{exitCode=$Session.process.ExitCode;stdout=$text;stderr=$Session.stderr.GetAwaiter().GetResult();json=$json}
}
function Read-ExternalSharedJson([string]$Path){
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite-bor[IO.FileShare]::Delete));try{$reader=[IO.StreamReader]::new($stream,$utf8);try{return $reader.ReadToEnd()|ConvertFrom-Json -AsHashtable -Depth 100}finally{$reader.Dispose()}}finally{$stream.Dispose()}
}
function Capture-ExternalBoundary([string]$Name,[string]$Boundary,[switch]$Schema4){
 $attempts=[Collections.Generic.List[object]]::new();$script:ExternalEvidence.boundaryAttempts=$attempts
 foreach($attempt in 1..3){
  $fixture=if($Schema4){New-ExternalMoveFixture ($Name+'-'+$attempt)}else{$f=New-ExternalBinFixture ($Name+'-'+$attempt) $ExecutablePath;Move-ExternalFixtureOutOfBin $f;$f}
  $closed=Join-Path $fixture.scope.metadata '.closed-records-v1';$summary=Join-Path $closed ($fixture.id+'.json');$intent=Join-Path $closed ($fixture.id+'.intent.json')
  $expected=if($Boundary-ceq'summary'){$summary}elseif($Boundary-ceq'container-deleted'){$fixture.container}else{$intent};$mode=if($Boundary-ceq'container-deleted'){'deleted'}else{'exact'}
  $gate=[Prunlet.ExternalUnavailableE2E.OwnedBoundaryGate]::new($fixture.scope.root,$expected,$ExecutablePath,$mode);$session=$null;$held=$null;$observed=$false
  try{
   if($Boundary-ceq'summary'){$held=[IO.File]::Open((Join-Path $fixture.record 'recycle-manifest.json'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}
   $session=Start-ExternalProcess $fixture.scope @('maintain','--apply');$gate.Bind($session.process)
   $observed=$gate.Wait(30000)-and$gate.Suspended-and!$gate.Error
   if($Boundary-ceq'summary'){$observed=$observed-and(Test-Path -LiteralPath $summary)-and(Test-Path -LiteralPath $fixture.record)-and!(Test-Path -LiteralPath (Join-Path $closed ($fixture.id+'.done.json')))}
   else{$observed=$observed-and(Test-Path -LiteralPath $intent)-and!(Test-Path -LiteralPath $summary)}
   if($Boundary-ceq'container-deleted'){$observed=$observed-and![IO.Directory]::Exists($fixture.container)}
   if($observed){$document=Read-ExternalSharedJson $(if($Boundary-ceq'summary'){$summary}else{$intent});Assert-External ($document.operationId-ceq$fixture.id-and$document.terminalReason-ceq'externally_unavailable') 'Gate captured the wrong lifecycle operation/reason';if($Boundary-cne'summary'){Assert-External ($document.ContainsKey('volumes')-and$document.volumes.Count-eq0) 'External intent retained postcommit volume work or omitted its explicit volume inventory'};$fixture.durableDocument=$document;$gate.KillOwned()}else{$gate.Resume()}
   $response=Finish-ExternalProcess $session;$attempts.Add(@{attempt=$attempt;scope=$fixture.scope.root;observed=$observed;processId=$gate.OwnedProcessId;suspends=$gate.SuspendCount;resumes=$gate.ResumeCount;path=$gate.ObservedPath;error=$gate.Error;response=$response})
   if($observed){return $fixture}
  }finally{if($session){if(!$session.process.HasExited){$gate.KillOwned();$session.process.Kill($true);$session.process.WaitForExit()};$session.process.Dispose()};$gate.Dispose();if($held){$held.Dispose()}}
 }
 throw 'Actual lifecycle boundary was not observed in three fresh fixtures; no interruption success is claimed'
}
function Capture-StandardHandoff([string]$Name,[switch]$Schema4){
 $attempts=[Collections.Generic.List[object]]::new();$script:ExternalEvidence.handoffAttempts=$attempts
 foreach($attempt in 1..3){
  $fixture=if($Schema4){New-ExternalMoveFixture ($Name+'-'+$attempt) -NoExternal}else{New-ExternalBinFixture ($Name+'-'+$attempt) $ExecutablePath}
  $witness=Join-Path $fixture.scope.files 'handoff-witness.txt';[IO.File]::WriteAllText($witness,'unrequested data must survive normal retirement',$utf8);$fixture.witness=$witness;$fixture.witnessProof=Get-ExternalSnapshot $witness
  if($Schema4){$seed=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.liveCandidateSeed=$seed;Assert-External ($seed.exitCode-eq0-and(Test-Path -LiteralPath $fixture.payload)) 'Live genuine4 candidate seeding failed'}
  $request=Join-Path (Join-Path $fixture.scope.metadata '.closed-records-v1') ($fixture.id+'.request.json');Assert-External (Test-Path -LiteralPath $request) 'Standard handoff requires a real existing external locator hint'
  $hint=[IO.File]::ReadAllText($request)|ConvertFrom-Json -AsHashtable -Depth 100;Assert-External ($hint.kind-ceq'external-unavailable-request'-and$hint.externalUnavailable.locators.Count-eq1) 'Handoff seed is not a genuine eligible external locator hint'
  $seedBinding=@{identity=[Prunlet.ExternalUnavailableE2E.FixtureNative]::LegacyIdentity($request);length=[IO.FileInfo]::new($request).Length;sha256=(Get-FileHash -LiteralPath $request).Hash.ToLowerInvariant()}
  $receiptName=if($Schema4){'purge-0000-complete.json'}else{'restore-0000-complete.json'};$complete=Join-Path $fixture.record $receiptName
  # C6は正式receipt公開だけでなく、その本物publication controlのcleanup完了後を捕捉する。
  # malformed fixtureが残存publisherのhash拒否へ逸れることを避け、通常terminal validatorを直接検査する。
  $expected=$complete;$mode='exact'
  if(!$Schema4){$key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($receiptName))).ToLowerInvariant().Substring(0,32);$expected=Join-Path (Split-Path $fixture.record) ('.publication-'+$fixture.id+'-'+$key);$mode='deleted'}
  $gate=[Prunlet.ExternalUnavailableE2E.OwnedBoundaryGate]::new($fixture.scope.root,$expected,$ExecutablePath,$mode);$session=$null;$captured=$false
  try{
   $arguments=if($Schema4){@('purge',$fixture.id,'--apply')}else{@('restore',$fixture.id)}
   $session=Start-ExternalProcess $fixture.scope $arguments;$gate.Bind($session.process)
   $captured=$gate.Wait(30000)-and$gate.Suspended-and!$gate.Error-and(Test-Path -LiteralPath $complete)-and!(Test-Path -LiteralPath (Join-Path (Split-Path $request) ($fixture.id+'.json')))-and!(Test-Path -LiteralPath (Join-Path (Split-Path $request) ($fixture.id+'.intent.json')))
   if(!$Schema4){$captured=$captured-and!(Test-Path -LiteralPath $expected)}
   if($captured){
    $receipt=Read-ExternalSharedJson $complete;$manifest=Join-Path $fixture.record $(if($Schema4){'move-manifest.json'}else{'recycle-manifest.json'})
    Assert-External ($receipt.operationId-ceq$fixture.id-and$receipt.index-eq0-and$receipt.phase-ceq'complete'-and$receipt.action-ceq$(if($Schema4){'purge'}else{'restore'})-and$receipt.manifestSha256-ceq(Get-FileHash -LiteralPath $manifest).Hash.ToLowerInvariant()) 'Handoff gate did not capture a fully flushed genuine bound completion receipt'
    $gate.KillOwned();$fixture.complete=$complete;$fixture.completeBytes=[IO.File]::ReadAllBytes($complete);$fixture.completeId=[Prunlet.ExternalUnavailableE2E.FixtureNative]::Identity($complete);$fixture.request=$request;$fixture.terminalReason=if($Schema4){'purged'}else{'restored'};$fixture.originalSchema=if($Schema4){4}else{6}
    $boundaryHint=[IO.File]::ReadAllText($request)|ConvertFrom-Json -AsHashtable -Depth 100
    $pending=@(Get-ChildItem -Force -LiteralPath (Split-Path $request)|Where-Object {$_.Name.StartsWith($fixture.id+'.')-and$_.Name.Contains('.pending-')}|ForEach-Object {@{name=$_.Name;identity=[Prunlet.ExternalUnavailableE2E.FixtureNative]::LegacyIdentity($_.FullName);length=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}})
    $boundaryFacts=@{noConflictingPending=($pending.Count-eq0);operationBound=($boundaryHint.operationId-ceq$fixture.id);rootBound=($boundaryHint.metadataRootIdentity-ceq$hint.metadataRootIdentity);directoryBound=($boundaryHint.directoryIdentity-ceq$hint.directoryIdentity);ownerBound=($boundaryHint.ownerSid-ceq$hint.ownerSid-and$boundaryHint.machineName-ceq$hint.machineName);expectedKind=($boundaryHint.kind-ceq$(if($Schema4){'external-unavailable-request'}else{'retire-request'}))}
    if(!$Schema4){$boundaryFacts.requiredFinalReceipt=($boundaryHint.requiredFinalReceiptName-ceq$receiptName);$boundaryFacts.exactPredecessor=($boundaryHint.previousRequestIdentity-ceq$seedBinding.identity-and$boundaryHint.previousRequestLength-eq$seedBinding.length-and$boundaryHint.previousRequestSha256-ceq$seedBinding.sha256)}
    else{$boundaryFacts.externalAuthorityBindingsUnchanged=((Normalize-ExternalRequestBindings $boundaryHint)-ceq(Normalize-ExternalRequestBindings $hint))}
    $script:ExternalEvidence.handoffBoundary=@{seedHint=$hint;seedBinding=$seedBinding;currentHint=$boundaryHint;pending=$pending;namespace=(Get-ExternalNamespace $fixture.scope.metadata);facts=$boundaryFacts}
    foreach($condition in $boundaryFacts.Keys){Assert-External $boundaryFacts[$condition] ('Actual stopped handoff boundary violated '+$condition)}
    if($Schema4){Assert-External (!(Test-Path -LiteralPath $fixture.source)-and!(Test-Path -LiteralPath $fixture.payload)) 'Formal normal purge did not consume exactly the owned fixture payload'}else{$fixture.restoredProof=Assert-ExternalSnapshot $fixture.source $fixture.before}
    $script:ExternalEvidence.genuineHandoff=@{receipt=$receipt;receiptId=$fixture.completeId;receiptLength=$fixture.completeBytes.Length;receiptSha256=(Get-FileHash -LiteralPath $complete).Hash;hint=$boundaryHint;expected=$expected;witness=$fixture.witnessProof;restored=$fixture.restoredProof}
   }else{$gate.Resume()}
   $response=Finish-ExternalProcess $session;$attempts.Add(@{attempt=$attempt;scope=$fixture.scope.root;captured=$captured;ownedPid=$gate.OwnedProcessId;suspends=$gate.SuspendCount;resumes=$gate.ResumeCount;path=$gate.ObservedPath;error=$gate.Error;response=$response})
   if($captured){return $fixture}
  }finally{if($session){if(!$session.process.HasExited){$gate.KillOwned();$session.process.Kill($true);$session.process.WaitForExit()};$session.process.Dispose()};$gate.Dispose()}
 }
 throw 'Genuine completed caller before standard retirement was not captured in three fresh fixtures; no handoff success is claimed'
}
function Assert-StandardData($Fixture){
 $null=Assert-ExternalSnapshot $Fixture.witness $Fixture.witnessProof
 if($Fixture.originalSchema-eq6){$null=Assert-ExternalSnapshot $Fixture.source $Fixture.restoredProof}
 else{Assert-External (!(Test-Path -LiteralPath $Fixture.source)-and!(Test-Path -LiteralPath $Fixture.payload)) 'Normal purge recreated or replaced its consumed fixture payload'}
}
function Assert-StandardClosed($Fixture){
 $closed=Join-Path $Fixture.scope.metadata '.closed-records-v1';$summaryPath=Join-Path $closed ($Fixture.id+'.json');$done=Join-Path $closed ($Fixture.id+'.done.json')
 Assert-External ((Test-Path -LiteralPath $summaryPath)-and(Test-Path -LiteralPath $done)-and!(Test-Path -LiteralPath $Fixture.record)-and!(Test-Path -LiteralPath $Fixture.request)) 'Existing external hint blocked completed standard terminal cleanup'
 $summary=[IO.File]::ReadAllText($summaryPath)|ConvertFrom-Json -AsHashtable -Depth 100
 Assert-External ($summary.operationId-ceq$Fixture.id-and$summary.originalSchema-eq$Fixture.originalSchema-and$summary.terminalReason-ceq$Fixture.terminalReason-and$summary.entries.Count-eq1-and$summary.entries[0].path-ceq$Fixture.source) 'A formal name bypassed the standard validator or changed the standard terminal reason'
 $script:ExternalEvidence.standardSummary=$summary;Assert-StandardData $Fixture
}
function Normalize-ExternalRequestBindings($Document){
 $copy=($Document|ConvertTo-Json -Depth 100 -Compress)|ConvertFrom-Json -AsHashtable -Depth 100
 foreach($field in @('previousRequestIdentity','previousRequestLength','previousRequestSha256')){$null=$copy.Remove($field)}
 foreach($field in @('diagnostic','retryFingerprint','retryPath','retryReason','retryAttempts','retryAfterUtc')){$null=$copy.externalUnavailable.Remove($field)}
 return $copy|ConvertTo-Json -Depth 100 -Compress
}
function Assert-ExternalClosed($Fixture,[int]$Schema=6){
 $summaryPath=Join-Path (Join-Path $Fixture.scope.metadata '.closed-records-v1') ($Fixture.id+'.json');$done=Join-Path (Split-Path $summaryPath) ($Fixture.id+'.done.json')
 Assert-External ((Test-Path -LiteralPath $summaryPath)-and(Test-Path -LiteralPath $done)-and!(Test-Path -LiteralPath $Fixture.record)-and!(Test-Path -LiteralPath (Join-Path (Join-Path $Fixture.scope.metadata '.recycle-records-v1') $Fixture.id))) 'External absence did not complete metadata retirement'
 $summary=[IO.File]::ReadAllText($summaryPath)|ConvertFrom-Json -AsHashtable -Depth 100
 Assert-External ($summary.operationId-ceq$Fixture.id-and$summary.originalSchema-eq$Schema-and$summary.terminalReason-ceq'externally_unavailable'-and@($summary.entries).Count-eq1-and$summary.entries[0].path-ceq$Fixture.source) 'Closed external-unavailable summary changed its provenance or input'
 $null=Assert-ExternalSnapshot $Fixture.alternate $Fixture.postExternal
 if($Fixture.extraRetained){$null=Assert-ExternalSnapshot $Fixture.extraRetained.path $Fixture.extraRetained.proof}
 $script:ExternalEvidence.summary=$summary
}
function Test-ExternalCase([string]$Name,[scriptblock]$Body,[switch]$RequiresLarge){
 if($registered.Contains($Name)){throw 'Duplicate external-unavailable case name'};$registered.Add($Name)
 if(!(Selected-External $Name)-or($RequiresLarge-and!$Large)){$excluded.Add($Name);return}
 $script:ExternalEvidence=@{};$clock=[Diagnostics.Stopwatch]::StartNew()
 try{&$Body;$results.Add(@{name=$Name;passed=$true;milliseconds=$clock.Elapsed.TotalMilliseconds;observed=$script:ExternalEvidence})}catch{$results.Add(@{name=$Name;passed=$false;error=$_.Exception.ToString();location=$_.InvocationInfo.PositionMessage;scriptStackTrace=$_.ScriptStackTrace;milliseconds=$clock.Elapsed.TotalMilliseconds;observed=$script:ExternalEvidence})}
}
foreach($producerKind in @('old15','current')){
 Test-ExternalCase ('schema6-'+$producerKind+'-external-absence-closes') {
  $producer=if($producerKind-ceq'old15'){$BaselineExecutablePath}else{$ExecutablePath}
  $fixture=New-ExternalBinFixture ('positive-'+$producerKind) $producer
  $script:ExternalEvidence.operationId=$fixture.id;Move-ExternalFixtureOutOfBin $fixture
  $before=Get-ExternalMetadata $fixture.scope.metadata;$names=Get-ExternalNamespace $fixture.scope.metadata
  $dry=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--dry-run','--audit-records');$script:ExternalEvidence.dryRun=$dry
  Assert-External ($dry.json.recordAuditRequested-eq$true-and(Get-ExternalMetadata $fixture.scope.metadata)-ceq$before-and(Get-ExternalNamespace $fixture.scope.metadata)-ceq$names) 'External-unavailable audit dry-run did not execute or changed metadata'
  $null=Assert-ExternalSnapshot $fixture.alternate $fixture.postExternal
  $maintained=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.maintenance=$maintained
  Assert-External ($maintained.exitCode-eq0) ('External-unavailable maintenance failed: '+$maintained.stdout+$maintained.stderr)
  Assert-ExternalClosed $fixture
  $restore=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('restore',$fixture.id);$script:ExternalEvidence.closedRestore=$restore
  Assert-External ($restore.exitCode-eq0-and$restore.json.lifecycleState-ceq'closed'-and$restore.json.terminalReason-ceq'externally_unavailable'-and@($restore.json.items).Count-eq1-and$restore.json.items[0].status-ceq'closed') 'Closed external-unavailable restore lost its explicit reason or status'
  $null=Assert-ExternalSnapshot $fixture.alternate $fixture.postExternal
 }
}
Test-ExternalCase 'schema6-prior-typed-no-hint-closes' {
 $fixture=New-ExternalBinFixture 'prior-typed-no-hint' $PriorTypedExecutablePath
 $request=Join-Path (Join-Path $fixture.scope.metadata '.closed-records-v1') ($fixture.id+'.request.json')
 Assert-External (!(Test-Path -LiteralPath $request)-and$fixture.record.Contains('.recycle-records-v1')) 'Prior typed producer unexpectedly created an external hint or flat record'
 Move-ExternalFixtureOutOfBin $fixture;$r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.maintenance=$r
 Assert-External ($r.exitCode-eq0) 'Genuine prior typed record could not be assessed';Assert-ExternalClosed $fixture
}
foreach($targetKind in @('file','directory')){
 Test-ExternalCase ('schema6-true87-nested-metadata-'+$targetKind) {
  # directoryはShell外部restoreでC6 private ACLを壊さないよう、真正C4の通常metadataを使う。
  # dataXはcopy形式にせず、真正11の同一ID rename→新版の正規restoreで保持する。
  $inner=if($targetKind-ceq'directory'){New-ExternalMoveFixture ('true87-inner-'+$targetKind) -NoExternal}else{New-ExternalBinFixture ('true87-inner-'+$targetKind) $ExecutablePath}
  $source=if($targetKind-ceq'file'){Join-Path $inner.record 'recycle-manifest.json'}else{$inner.record}
  $outerProducer=if($targetKind-ceq'file'){$BaselineExecutablePath}else{$ExecutablePath}
  $outer=New-ExternalTrackedSource ('true87-outer-'+$targetKind) $outerProducer $source
  $script:ExternalEvidence.nestedMetadataSetup=@{innerId=$inner.id;innerOriginalSchema=$(if($targetKind-ceq'directory'){4}else{6});innerDataBefore=$inner.before;source=$source;outerId=$outer.id;outerMetadataBefore=$outer.before;outerReceipt=$outer.receipt;outerBinBefore=$outer.binBefore}
  $hint=Join-Path $outer.scope.files 'lookup-hint.txt';[IO.File]::WriteAllText($hint,'own lookup hint',$utf8)
  $beforeLookup=[Prunlet.ExternalUnavailableE2E.FixtureNative]::Lookup($hint,$outer.before[0]);Assert-External ($beforeLookup.Found-and$beforeLookup.Error-eq0) 'Valid generated metadata ID was not live before consumption'
  $null=[Prunlet.ExternalUnavailableE2E.FixtureNative]::RestoreOwned($outer.receipt.pidl,$outer.receipt.physicalPath,$outer.before[0].Id,$outer.source,$OutputDirectory)
  $null=Assert-ExternalSnapshot $outer.source $outer.before -DataOnly
  $restored=Invoke-ExternalCli $ExecutablePath $inner.scope.config @('restore',$inner.id);$script:ExternalEvidence.innerRestore=$restored
  Assert-External ($restored.exitCode-eq0-and$restored.json.items[0].status-ceq'restored'-and!(Test-Path -LiteralPath $source)) 'Inner normal lifecycle did not consume the genuinely restored metadata; no ACL workaround is allowed'
  $null=Assert-ExternalSnapshot $inner.source $inner.before -DataOnly
  $afterLookup=[Prunlet.ExternalUnavailableE2E.FixtureNative]::Lookup($hint,$outer.before[0]);Assert-External (!$afterLookup.Found-and$afterLookup.Error-eq87) 'Consumed genuine metadata ID did not produce the required actual OpenByID 87'
  $outer.alternate=$inner.source;$outer.postExternal=Get-ExternalSnapshot $inner.source
  $script:ExternalEvidence.true87=@{source=$source;metadataBefore=$outer.before;beforeLookup=$beforeLookup;afterLookup=$afterLookup;innerData=$outer.postExternal;receipt=$outer.receipt}
  $r=Invoke-ExternalCli $ExecutablePath $outer.scope.config @('maintain','--apply');$script:ExternalEvidence.outerMaintenance=$r;Assert-External ($r.exitCode-eq0) 'Independent Bin fallback did not close the genuinely consumed metadata record';Assert-ExternalClosed $outer
 }
}
foreach($kind in @('whole-container','payload-only')){
 $caseName=if($kind-ceq'whole-container'){'schema4-whole-container-absence-closes'}else{'schema4-payload-only-empty-container-closes'}
 Test-ExternalCase $caseName {
  $fixture=New-ExternalMoveFixture $kind -WholeContainer:($kind-ceq'whole-container')
  $before=Get-ExternalMetadata $fixture.scope.metadata;$containerBefore=[IO.Directory]::Exists($fixture.container)
  $dry=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--dry-run','--audit-records');$script:ExternalEvidence.dryRun=$dry
  Assert-External ($dry.json.recordAuditRequested-eq$true-and(Get-ExternalMetadata $fixture.scope.metadata)-ceq$before-and[IO.Directory]::Exists($fixture.container)-eq$containerBefore) 'Schema4 dry-run changed metadata or its empty container'
  $r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.maintenance=$r
  Assert-External ($r.exitCode-eq0-and![IO.Directory]::Exists($fixture.container)) 'Genuine4 external cleanup failed or retained its owned empty container';Assert-ExternalClosed $fixture 4
 }
}
foreach($fault in @('unknown-child','replacement-container','container-ads')){
 Test-ExternalCase ('schema4-'+$fault+'-preserved') {
  $fixture=New-ExternalMoveFixture ('c4-'+$fault)
  switch($fault){
   'unknown-child' {[IO.File]::WriteAllText((Join-Path $fixture.container 'unknown.txt'),'do not delete unknown data',$utf8)}
   'replacement-container' {$saved=Join-Path $fixture.scope.files 'retained-original-container';[Prunlet.ExternalUnavailableE2E.FixtureNative]::MoveOwned($fixture.container,$saved,$fixture.containerProof[0].Id,$fixture.scope.root);$null=[IO.Directory]::CreateDirectory($fixture.container);Assert-External ([Prunlet.ExternalUnavailableE2E.FixtureNative]::Identity($fixture.container)-cne$fixture.containerProof[0].Id) 'Replacement container did not change ID'}
   'container-ads' {[IO.File]::WriteAllText(($fixture.container+':unknown.ads'),'retained container ADS',$utf8)}
  }
  $container=Get-ExternalSnapshot $fixture.container;Assert-ExternalStableRetention $fixture;$null=Assert-ExternalSnapshot $fixture.container $container
 }
}
Test-ExternalCase 'schema4-unfinished-restore-preserved' {
 $captured=$false;$attempts=[Collections.Generic.List[object]]::new();$script:ExternalEvidence.restoreAttempts=$attempts
 foreach($attempt in 1..3){
  $fixture=New-ExternalMoveFixture ('c4-unfinished-'+$attempt) -NoExternal;$intent=Join-Path $fixture.record 'restore-0000-intent.json'
  $gate=[Prunlet.ExternalUnavailableE2E.OwnedBoundaryGate]::new($fixture.scope.root,$intent,$ExecutablePath,'exact');$session=$null
  try{
   $session=Start-ExternalProcess $fixture.scope @('restore',$fixture.id);$gate.Bind($session.process)
   $captured=$gate.Wait(30000)-and$gate.Suspended-and!$gate.Error-and(Test-Path -LiteralPath $intent)-and(Test-Path -LiteralPath $fixture.payload)-and!(Test-Path -LiteralPath $fixture.source)
   if($captured){$script:ExternalEvidence.actualRestoreIntent=Read-ExternalSharedJson $intent;$gate.KillOwned()}else{$gate.Resume()};$response=Finish-ExternalProcess $session;$attempts.Add(@{attempt=$attempt;captured=$captured;response=$response;scope=$fixture.scope.root;gateError=$gate.Error})
  }finally{if($session){if(!$session.process.HasExited){$gate.KillOwned();$session.process.Kill($true);$session.process.WaitForExit()};$session.process.Dispose()};$gate.Dispose()}
  if(!$captured){continue}
  [Prunlet.ExternalUnavailableE2E.FixtureNative]::MoveOwned($fixture.payload,$fixture.alternate,$fixture.before[0].Id,$fixture.scope.root);$fixture.postExternal=Get-ExternalSnapshot $fixture.alternate
  Assert-ExternalStableRetention $fixture;break
 }
 Assert-External $captured 'Actual unfinished C4 restore boundary was not caught in three fresh fixtures'
}
Test-ExternalCase 'schema4-negative-cache-and-delete-access-auto-recovery' {
 $fixture=New-ExternalMoveFixture 'c4-negative-cache';$held=[Prunlet.ExternalUnavailableE2E.FixtureNative]::HoldNoDelete($fixture.container);$manifest=Join-Path $fixture.record 'move-manifest.json';$bytes=[IO.File]::ReadAllBytes($manifest);$poisoned=$false
 try{
  $first=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.firstNegative=$first;Assert-ExternalPreserved $fixture
  $request=Join-Path (Join-Path $fixture.scope.metadata '.closed-records-v1') ($fixture.id+'.request.json');Assert-External (Test-Path -LiteralPath $request) 'Legacy C4 bootstrap did not persist a bounded negative candidate before returning the sharing failure';$marker=[IO.File]::ReadAllText($request)|ConvertFrom-Json -AsHashtable -Depth 100
  Assert-External ($marker.kind-ceq'external-unavailable-request'-and$marker.externalUnavailable.diagnostic) 'Busy DELETE-open did not create a bounded negative candidate'
  $bad=[byte[]]$bytes.Clone();$bad[0]=[byte][char]'?';$id=[Prunlet.ExternalUnavailableE2E.FixtureNative]::Identity($manifest);[IO.File]::WriteAllBytes($manifest,$bad);$poisoned=$true
  Assert-External ([Prunlet.ExternalUnavailableE2E.FixtureNative]::Identity($manifest)-ceq$id-and[IO.FileInfo]::new($manifest).Length-eq$bytes.Length) 'Negative body poison changed identity or length'
  # poisonはNative ChangeTokenを変える。最初の再評価は正当なlight failure＋新fingerprint保存となる。
  $oldRequestId=[Prunlet.ExternalUnavailableE2E.FixtureNative]::LegacyIdentity($request);$oldRequestLength=[IO.FileInfo]::new($request).Length;$oldRequestSha=(Get-FileHash -LiteralPath $request).Hash.ToLowerInvariant()
  $oldDocument=[IO.File]::ReadAllText($request)|ConvertFrom-Json -AsHashtable -Depth 100
  $recordBefore=Get-ExternalMetadata $fixture.record;$othersBefore=Get-ExternalMetadata $fixture.scope.metadata $request;$namespaceBefore=Get-ExternalNamespace $fixture.scope.metadata
  $script:ExternalEvidence.poisonBaseline=@{record=$recordBefore;otherMetadata=$othersBefore;namespace=$namespaceBefore;manifestId=$id;manifestLength=[IO.FileInfo]::new($manifest).Length;manifestSha256=(Get-FileHash -LiteralPath $manifest).Hash;requestSha256=$oldRequestSha;requestIdentity=$oldRequestId;requestLength=$oldRequestLength;request=$oldDocument}
  $transition=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.changedTokenScan=$transition
  $newDocument=[IO.File]::ReadAllText($request)|ConvertFrom-Json -AsHashtable -Depth 100
  $oldFingerprint=$oldDocument.externalUnavailable.retryFingerprint;$newFingerprint=$newDocument.externalUnavailable.retryFingerprint
  $oldNormalized=($oldDocument|ConvertTo-Json -Depth 100 -Compress)|ConvertFrom-Json -AsHashtable -Depth 100;$newNormalized=($newDocument|ConvertTo-Json -Depth 100 -Compress)|ConvertFrom-Json -AsHashtable -Depth 100
  foreach($document in @($oldNormalized,$newNormalized)){foreach($field in @('previousRequestIdentity','previousRequestLength','previousRequestSha256')){$null=$document.Remove($field)};foreach($field in @('diagnostic','retryFingerprint','retryPath','retryReason','retryAttempts','retryAfterUtc')){$null=$document.externalUnavailable.Remove($field)}}
  $transitionEvidence=@{
   fingerprintChanged=($oldFingerprint-cne$newFingerprint-and$newFingerprint-cmatch'^[a-f0-9]{64}$');busyDiagnosticUnchanged=($newDocument.externalUnavailable.diagnostic-ceq$oldDocument.externalUnavailable.diagnostic)
   authoritativeBindingsUnchanged=(($oldNormalized|ConvertTo-Json -Depth 100 -Compress)-ceq($newNormalized|ConvertTo-Json -Depth 100 -Compress))
   predecessorMatches=($newDocument.previousRequestIdentity-ceq$oldRequestId-and$newDocument.previousRequestLength-eq$oldRequestLength-and$newDocument.previousRequestSha256-ceq$oldRequestSha)
   recordUnchanged=((Get-ExternalMetadata $fixture.record)-ceq$recordBefore);otherMetadataUnchanged=((Get-ExternalMetadata $fixture.scope.metadata $request)-ceq$othersBefore);namespaceUnchanged=((Get-ExternalNamespace $fixture.scope.metadata)-ceq$namespaceBefore)
   oldRequestSha256=$oldRequestSha;newRequestSha256=(Get-FileHash -LiteralPath $request).Hash.ToLowerInvariant();oldFingerprint=$oldFingerprint;newFingerprint=$newFingerprint
  }
  $script:ExternalEvidence.changedTokenTransition=$transitionEvidence
  $script:ExternalEvidence.changedTokenPayload=Get-ExternalSnapshot $fixture.alternate
  Assert-ExternalPreserved $fixture
  foreach($condition in @('fingerprintChanged','busyDiagnosticUnchanged','authoritativeBindingsUnchanged','predecessorMatches','recordUnchanged','otherMetadataUnchanged','namespaceUnchanged')){Assert-External $transitionEvidence[$condition] ('Changed-token light failure violated '+$condition)}
  $before=Get-ExternalMetadata $fixture.scope.metadata;$names=Get-ExternalNamespace $fixture.scope.metadata
  foreach($round in 1..2){$r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence['negativeScan'+$round]=$r;$facts=@{canonicalNoBodyDiagnostic=($r.stdout+$r.stderr).Contains('Unchanged negative probe; operation bodies and Bin subtree were not inspected.');metadataUnchanged=((Get-ExternalMetadata $fixture.scope.metadata)-ceq$before);namespaceUnchanged=((Get-ExternalNamespace $fixture.scope.metadata)-ceq$names)};$script:ExternalEvidence['negativeScanFacts'+$round]=$facts;foreach($condition in $facts.Keys){Assert-External $facts[$condition] ('Unchanged negative probe violated '+$condition)};Assert-ExternalPreserved $fixture}
  $r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('restore',$fixture.id);$script:ExternalEvidence.explicitPoisonRestore=$r;Assert-External ($r.exitCode-ne0-and(Get-ExternalMetadata $fixture.scope.metadata)-ceq$before) 'Explicit restore skipped strong validation or changed rejected evidence'
  [IO.File]::WriteAllBytes($manifest,$bytes);$poisoned=$false
 }finally{if($poisoned-and[IO.File]::Exists($manifest)){[IO.File]::WriteAllBytes($manifest,$bytes)};$held.Dispose()}
 $r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.autoRecovery=$r;Assert-External ($r.exitCode-eq0) 'DELETE-open capability change did not trigger automatic strong recovery';Assert-ExternalClosed $fixture 4
}
foreach($boundary in @('before-delete-metadata-change','after-delete-resumes','after-delete-source-reappears','after-delete-bin-reappears')){
 Test-ExternalCase ('schema4-'+$boundary) {
  $fixture=Capture-ExternalBoundary ('c4-boundary-'+$boundary) $(if($boundary-ceq'before-delete-metadata-change'){'intent'}else{'container-deleted'}) -Schema4
  Assert-External ($fixture.durableDocument.externalEmptyContainers.Count-eq1-and$fixture.durableDocument.volumes.Count-eq0) 'Real C4 intent omitted its private empty-container plan or retained postcommit volume work'
  if($boundary-ceq'before-delete-metadata-change'){
   $member=Join-Path $fixture.record 'delete-result.json';$bytes=[IO.File]::ReadAllBytes($member);$bad=[byte[]]$bytes.Clone();$bad[0]=[byte][char]'?';[IO.File]::WriteAllBytes($member,$bad)
   try{$before=Get-ExternalMetadata $fixture.record;$r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.resume=$r;Assert-ExternalPreserved $fixture;Assert-External ([IO.Directory]::Exists($fixture.container)-and(Get-ExternalMetadata $fixture.record)-ceq$before) 'Precommit changed metadata allowed empty-container deletion'}finally{[IO.File]::WriteAllBytes($member,$bytes)}
  }elseif($boundary-ceq'after-delete-source-reappears'){
   $null=[IO.Directory]::CreateDirectory($fixture.source);[IO.File]::WriteAllText((Join-Path $fixture.source 'new-user.txt'),'preserve reappeared source',$utf8);$current=Get-ExternalSnapshot $fixture.source
   $r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.resume=$r;Assert-ExternalPreserved $fixture;$null=Assert-ExternalSnapshot $fixture.source $current
  }elseif($boundary-ceq'after-delete-bin-reappears'){
   $aux=New-ExternalScope 'c4-after-delete-bin-aux' $ExecutablePath;$r=Invoke-ExternalDelete $ExecutablePath $aux @($fixture.alternate);$auxRecord=Resolve-VerificationOperationDirectory $aux.metadata $r.json.operationId;$receipt=[IO.File]::ReadAllText((Join-Path $auxRecord 'recycle-0000-complete.json'))|ConvertFrom-Json -AsHashtable -Depth 100
   Assert-External ($receipt.identity.fileId-ceq$fixture.before[0].FileId) 'Reappeared Bin fixture does not have the genuinely tracked payload ID'
   $fixture.alternate=$receipt.physicalPath;$fixture.postExternal=Get-ExternalSnapshot $fixture.alternate;$null=Assert-ExternalSnapshot $fixture.alternate $fixture.before -DataOnly;$script:ExternalEvidence.binReappearance=@{operationId=$r.json.operationId;receipt=$receipt;proof=$fixture.postExternal}
   $r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.resume=$r;Assert-ExternalPreserved $fixture
  }else{$r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.resume=$r;Assert-External ($r.exitCode-eq0) 'After-delete precommit interruption did not resume with fresh absence proof';Assert-ExternalClosed $fixture 4}
 }
}
foreach($fault in @('bin-live','original-different-id','unknown-member','missing-complete-receipt','tampered-volume-guid','unknown-stage')){
 Test-ExternalCase ('schema6-'+$fault+'-preserved') {
  $fixture=New-ExternalBinFixture ('c6-negative-'+$fault) $ExecutablePath
  if($fault-cne'bin-live'){Move-ExternalFixtureOutOfBin $fixture}
  switch($fault){
   'original-different-id' {$null=[IO.Directory]::CreateDirectory($fixture.source);[IO.File]::WriteAllText((Join-Path $fixture.source 'user.txt'),'current source must survive',$utf8);$current=Get-ExternalSnapshot $fixture.source;Assert-External ($current[0].Id-cne$fixture.before[0].Id) 'Reappeared original did not change ID'}
   'unknown-member' {[IO.File]::WriteAllText((Join-Path $fixture.record 'unknown-authority.bin'),'unknown retained bytes',$utf8)}
   'missing-complete-receipt' {[Prunlet.ExternalUnavailableE2E.FixtureNative]::MoveOwned($fixture.receiptPath,(Join-Path $fixture.scope.files 'retained-real-complete.json'),[Prunlet.ExternalUnavailableE2E.FixtureNative]::Identity($fixture.receiptPath),$fixture.scope.root)}
   'tampered-volume-guid' {$path=Join-Path (Join-Path $fixture.scope.metadata '.closed-records-v1') ($fixture.id+'.request.json');$value=[IO.File]::ReadAllText($path)|ConvertFrom-Json -AsHashtable -Depth 100;$old=$value.externalUnavailable.locators[0].volume.volumeName;$index=$old.IndexOf('{')+1;$replacement=$(if($old[$index]-eq'0'){'1'}else{'0'});$value.externalUnavailable.locators[0].volume.volumeName=$old.Substring(0,$index)+$replacement+$old.Substring($index+1);[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 100),$utf8);$script:ExternalEvidence.volumeTestScope='tampered genuine provenance; not an actual offline-volume measurement'}
   'unknown-stage' {$path=Join-Path (Join-Path $fixture.scope.metadata '.closed-records-v1') ($fixture.id+'.request.json');$value=[IO.File]::ReadAllText($path)|ConvertFrom-Json -AsHashtable -Depth 100;$stages=@($value.externalUnavailable.locators[0].stagePaths|Where-Object {$_.StartsWith($fixture.scope.root+'\',[StringComparison]::OrdinalIgnoreCase)});Assert-External ($stages.Count-ge1) 'Candidate has no fixture-owned configured stage path';$stage=$stages[0];Assert-VerificationDestination $stage @();$null=[IO.Directory]::CreateDirectory($stage);[IO.File]::WriteAllText((Join-Path $stage 'unknown.txt'),'unknown stage data must survive',$utf8);$stageProof=Get-ExternalSnapshot $stage;$script:ExternalEvidence.stage=@{path=$stage;proof=$stageProof;authority='deliberately untrusted owned stage, no fabricated receipt'}}
  }
  Assert-ExternalStableRetention $fixture
  if($fault-ceq'bin-live'){$null=Assert-ExternalSnapshot $fixture.receipt.physicalPath $fixture.binBefore}
  if($fault-ceq'original-different-id'){$null=Assert-ExternalSnapshot $fixture.source $current}
  if($fault-ceq'unknown-stage'){$null=Assert-ExternalSnapshot $stage $stageProof}
 }
}
Test-ExternalCase 'schema6-source-parent-access-denied-preserved' {
 $fixture=New-ExternalBinFixture 'source-parent-access-denied' $ExecutablePath;Move-ExternalFixtureOutOfBin $fixture;$originalAcl=Get-Acl -LiteralPath $fixture.scope.files
 try{
  $denied=Get-Acl -LiteralPath $fixture.scope.files;$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
  $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::ReadData,[Security.AccessControl.InheritanceFlags]::None,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Deny);$denied.AddAccessRule($rule);Set-Acl -LiteralPath $fixture.scope.files -AclObject $denied
  $fixture.postExternal=Get-ExternalSnapshot $fixture.alternate;$script:ExternalEvidence.aclSetupBaseline=$fixture.postExternal
  $afterSddl=(Get-Acl -LiteralPath $fixture.scope.files).Sddl;$probe=$null;$code=$null
  try{$probe=[Prunlet.ExternalUnavailableE2E.FixtureNative]::HoldNoDelete($fixture.scope.files)}catch{$errorValue=$_.Exception;while($errorValue.InnerException){$errorValue=$errorValue.InnerException};if($errorValue-is[ComponentModel.Win32Exception]){$code=$errorValue.NativeErrorCode}}finally{if($probe){$probe.Dispose()}}
  Assert-External ($code-eq5) 'Owned parent DACL did not produce actual current-token access denied (5)';$script:ExternalEvidence.nativeDeniedCode=$code
  Assert-ExternalStableRetention $fixture;Assert-External ((Get-Acl -LiteralPath $fixture.scope.files).Sddl-ceq$afterSddl) 'Core rewrote a denied parent ACL'
 }finally{Set-Acl -LiteralPath $fixture.scope.files -AclObject $originalAcl}
 $script:ExternalEvidence.aclTeardown=Assert-ExternalSnapshot $fixture.alternate $fixture.postExternal -DataOnly
}
Test-ExternalCase 'schema6-mixed-live-batch-is-preserved' {
 $scope=New-ExternalScope 'mixed-live' $ExecutablePath;$first=Join-Path $scope.files 'first.txt';$second=Join-Path $scope.files 'second.txt';[IO.File]::WriteAllText($first,'external first',$utf8);[IO.File]::WriteAllText($second,'live second',$utf8)
 $before=Get-ExternalSnapshot $first;$r=Invoke-ExternalDelete $ExecutablePath $scope @($first,$second);$record=Resolve-VerificationOperationDirectory $scope.metadata $r.json.operationId;$receipt=[IO.File]::ReadAllText((Join-Path $record 'recycle-0000-complete.json'))|ConvertFrom-Json -AsHashtable -Depth 100;$live=[IO.File]::ReadAllText((Join-Path $record 'recycle-0001-complete.json'))|ConvertFrom-Json -AsHashtable -Depth 100
 $fixture=@{scope=$scope;ownedRoot=$scope.root;id=$r.json.operationId;record=$record;source=$first;before=$before;receipt=$receipt;alternate=(Join-Path $scope.files 'retained-first.txt')};Move-ExternalFixtureOutOfBin $fixture;$liveProof=Get-ExternalSnapshot $live.physicalPath
 Assert-ExternalStableRetention $fixture;$null=Assert-ExternalSnapshot $live.physicalPath $liveProof
}
foreach($mode in @('nested-bin','hardlink-alias-bin')){
 Test-ExternalCase ('schema6-'+$mode+'-is-preserved') {
  $fixture=New-ExternalBinFixture ('bin-location-'+$mode) $ExecutablePath -SingleFile:($mode-ceq'hardlink-alias-bin') -HardlinkAlias:($mode-ceq'hardlink-alias-bin');Move-ExternalFixtureOutOfBin $fixture
  $aux=New-ExternalScope ('aux-'+$mode) $ExecutablePath
  if($mode-ceq'nested-bin'){$carrier=Join-Path $fixture.scope.files 'carrier';$null=[IO.Directory]::CreateDirectory($carrier);$inside=Join-Path $carrier 'nested-original';[Prunlet.ExternalUnavailableE2E.FixtureNative]::MoveOwned($fixture.alternate,$inside,$fixture.before[0].Id,$fixture.scope.root);$outer=Invoke-ExternalDelete $ExecutablePath $aux @($carrier);$outerRecord=Resolve-VerificationOperationDirectory $aux.metadata $outer.json.operationId;$receipt=[IO.File]::ReadAllText((Join-Path $outerRecord 'recycle-0000-complete.json'))|ConvertFrom-Json -AsHashtable;$fixture.alternate=Join-Path $receipt.physicalPath 'nested-original'}
  else{$carrier=Split-Path $fixture.alias;$outer=Invoke-ExternalDelete $ExecutablePath $aux @($carrier);$outerRecord=Resolve-VerificationOperationDirectory $aux.metadata $outer.json.operationId;$receipt=[IO.File]::ReadAllText((Join-Path $outerRecord 'recycle-0000-complete.json'))|ConvertFrom-Json -AsHashtable;Assert-External ([Prunlet.ExternalUnavailableE2E.FixtureNative]::Identity((Join-Path $receipt.physicalPath 'alias.txt'))-ceq$fixture.before[0].Id) 'Different Bin item does not contain the genuine shared alias'}
  $fixture.postExternal=Get-ExternalSnapshot $fixture.alternate;$outerProof=Get-ExternalSnapshot $receipt.physicalPath;$script:ExternalEvidence.auxiliaryBin=@{operationId=$outer.json.operationId;receipt=$receipt;proof=$outerProof}
  Assert-ExternalStableRetention $fixture;$null=Assert-ExternalSnapshot $receipt.physicalPath $outerProof
 }
}
foreach($boundary in @('intent','summary')){
 Test-ExternalCase ('schema6-'+$boundary+'-source-reappearance-nonoverwrite') {
  $fixture=Capture-ExternalBoundary ('c6-boundary-'+$boundary) $boundary
  $null=[IO.Directory]::CreateDirectory($fixture.source);[IO.File]::WriteAllText((Join-Path $fixture.source 'new-user.txt'),'new user-owned source',$utf8);$current=Get-ExternalSnapshot $fixture.source
  $r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.resume=$r
  if($boundary-ceq'intent'){Assert-ExternalPreserved $fixture}else{Assert-External ($r.exitCode-eq0) 'Committed metadata cleanup did not resume';Assert-ExternalClosed $fixture;$again=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('restore',$fixture.id);Assert-External ($again.exitCode-eq0-and$again.json.lifecycleState-ceq'closed') 'Closed restore attempted a new restore'}
  $null=Assert-ExternalSnapshot $fixture.source $current;$null=Assert-ExternalSnapshot $fixture.alternate $fixture.postExternal
 }
}
Test-ExternalCase 'closed-external-summary-expires-without-touching-data' {
 $fixture=New-ExternalBinFixture 'summary-expiry' $ExecutablePath;Move-ExternalFixtureOutOfBin $fixture;$r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');Assert-External ($r.exitCode-eq0) 'Expiry setup did not close';Assert-ExternalClosed $fixture
 $closed=Join-Path $fixture.scope.metadata '.closed-records-v1';$path=Join-Path $closed ($fixture.id+'.json');$done=Join-Path $closed ($fixture.id+'.done.json');$c=[IO.File]::ReadAllText($fixture.scope.config)|ConvertFrom-Json;$past=[Text.Json.JsonSerializer]::Serialize[DateTimeOffset]([DateTimeOffset]::UtcNow.AddDays(-([int]$c.retentionDays+1)))
 $text=[regex]::Replace([IO.File]::ReadAllText($path),'("closedUtc"\s*:\s*)"[^"]*"',{param($m)$m.Groups[1].Value+$past});[IO.File]::WriteAllText($path,$text,$utf8);$digest=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant();$text=[regex]::Replace([IO.File]::ReadAllText($done),'("summarySha256"\s*:\s*)"[^"]*"',{param($m)$m.Groups[1].Value+'"'+$digest+'"'});[IO.File]::WriteAllText($done,$text,$utf8)
 $r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.expiry=$r;Assert-External ($r.exitCode-eq0-and!(Test-Path -LiteralPath $path)-and!(Test-Path -LiteralPath $done)) 'Cleaned external terminal history did not expire';$null=Assert-ExternalSnapshot $fixture.alternate $fixture.postExternal
}
foreach($schema in 1..3){
 Test-ExternalCase ('legacy-schema'+$schema+'-normal-terminal') {
  $scope=New-ExternalScope ('legacy-'+$schema) $LegacyCopyExecutablePath;$config=[IO.File]::ReadAllText($scope.config)|ConvertFrom-Json -AsHashtable;$null=$config.Remove('volumeRecoveryDirectories');$null=$config.Remove('capacityDefaultMigrationVersion');[IO.File]::WriteAllText($scope.config,($config|ConvertTo-Json -Depth 100),$utf8)
  $dir=Join-Path $scope.files 'source';$null=[IO.Directory]::CreateDirectory($dir);$file=Join-Path $dir 'data.txt';[IO.File]::WriteAllText($file,'legacy data retained',$utf8);if($schema-eq3){[IO.File]::WriteAllText(($file+':legacy.ads'),'legacy ADS retained',$utf8)};$source=if($schema-eq1){$file}else{$dir};$before=Get-ExternalSnapshot $source
  # 真正9の既存generatorと同じASCII単一対象の入口を使う。新版のpaths-file対応を仮定しない。
  $legacyArgs=@('delete');if($schema-ne1){$legacyArgs+='--recursive'};$legacyArgs+=@('--',$source)
  $r=Invoke-ExternalCli $LegacyCopyExecutablePath $scope.config $legacyArgs;Assert-External ($r.exitCode-eq0-and$r.json.operationId-and!(Test-Path -LiteralPath $source)) 'Genuine9 legacy producer failed'
  $record=Join-Path $scope.metadata $r.json.operationId;$manifest=[IO.File]::ReadAllText((Join-Path $record 'manifest.json'))|ConvertFrom-Json -AsHashtable;Assert-External ($manifest.schema-eq$schema) 'Genuine9 fixture did not produce the requested copy schema'
  $maintained=Invoke-ExternalCli $ExecutablePath $scope.config @('maintain','--apply');Assert-External (Test-Path -LiteralPath $record) 'Legacy provenance-limited copy record was falsely externally retired'
  $restored=Invoke-ExternalCli $ExecutablePath $scope.config @('restore',$r.json.operationId);$script:ExternalEvidence.restore=$restored;Assert-External ($restored.exitCode-eq0-and$restored.json.items[0].status-ceq'restored') 'Existing ordinary copy restore/terminal behavior regressed'
  $actual=Get-ExternalSnapshot $source;Assert-External ($actual.Count-eq$before.Count) 'Legacy restored tree member count changed';for($i=0;$i-lt$before.Count;$i++){Assert-External (($actual[$i].Streams|ConvertTo-Json -Depth 10 -Compress)-ceq($before[$i].Streams|ConvertTo-Json -Depth 10 -Compress)) 'Legacy stream bytes changed'}
  $script:ExternalEvidence.legacy=@{schema=$schema;maintenance=$maintained;original=$before;restored=$actual;scope='legacy copy changes native IDs by contract; stream bytes are compared'}
 }
}
Test-ExternalCase 'mcp-list-and-closed-restore-external-reason' {
 $fixture=New-ExternalBinFixture 'mcp-closed' $ExecutablePath;Move-ExternalFixtureOutOfBin $fixture;$r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');Assert-External ($r.exitCode-eq0) 'MCP setup did not close';Assert-ExternalClosed $fixture
 $listed=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('operations');$script:ExternalEvidence.cliOperations=$listed;$row=@($listed.json.operations|Where-Object operationId -eq $fixture.id);Assert-External ($listed.exitCode-eq0-and$row.Count-eq1-and$row[0].terminalReason-ceq'externally_unavailable') 'CLI operations omitted the closed external reason'
 $info=[Diagnostics.ProcessStartInfo]::new('cmd.exe');$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.Arguments='/d /c '+$ExecutablePath+' --config '+$fixture.scope.config+' mcp';$process=[Diagnostics.Process]::Start($info);$stderr=$process.StandardError.ReadToEndAsync();$transcript=[Collections.Generic.List[object]]::new()
 try{
  foreach($request in @(@{jsonrpc='2.0';id=1;method='initialize';params=@{protocolVersion='2025-11-25';capabilities=@{};clientInfo=@{name='external-e2e';version='1'}}},@{jsonrpc='2.0';id=2;method='tools/call';params=@{name='list_operations';arguments=@{}}},@{jsonrpc='2.0';id=3;method='tools/call';params=@{name='restore_files';arguments=@{operationId=$fixture.id}}})){
   if($request.id-eq2){$process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')};$process.StandardInput.WriteLine(($request|ConvertTo-Json -Depth 20 -Compress));$process.StandardInput.Flush();$matched=$null
   foreach($line in 1..64){$read=$process.StandardOutput.ReadLineAsync();if(!$read.Wait(30000)){throw 'MCP response timeout'};$text=$read.GetAwaiter().GetResult();Assert-External (![string]::IsNullOrEmpty($text)) 'MCP closed stdout';$reply=$text|ConvertFrom-Json -AsHashtable -Depth 100;$transcript.Add($reply);if($reply.id-eq$request.id){$matched=$reply;break}}
   Assert-External ($matched-and!$matched.error) 'MCP did not return its matching response'
   if($request.id-eq2){$rows=@($matched.result.structuredContent.operations|Where-Object operationId -eq $fixture.id);Assert-External (!$matched.result.isError-and$rows.Count-eq1-and$rows[0].terminalReason-ceq'externally_unavailable') 'MCP list omitted terminal provenance'}
   if($request.id-eq3){$result=$matched.result.structuredContent;Assert-External (!$matched.result.isError-and$result.lifecycleState-ceq'closed'-and$result.terminalReason-ceq'externally_unavailable'-and$result.items[0].status-ceq'closed') 'MCP closed restore changed external reason/status'}
  }
  $process.StandardInput.Close();Assert-External ($process.WaitForExit(30000)-and$process.ExitCode-eq0) 'MCP did not finish cleanly at EOF';$script:ExternalEvidence.mcpStderr=$stderr.GetAwaiter().GetResult()
 }finally{if(!$process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose();$script:ExternalEvidence.mcpTranscript=@($transcript)}
 $null=Assert-ExternalSnapshot $fixture.alternate $fixture.postExternal
}
foreach($kind in @('schema4','schema6')){
 $normalName=if($kind-ceq'schema4'){'handoff-schema4-purge-complete-closes'}else{'handoff-schema6-restore-complete-closes'}
 Test-ExternalCase $normalName {
  $fixture=Capture-StandardHandoff ('handoff-normal-'+$kind) -Schema4:($kind-ceq'schema4')
  $r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.handoffMaintenance=$r
  Assert-External ($r.exitCode-eq0) 'A fully validated real completion did not resume its genuine bound retirement request';Assert-StandardClosed $fixture
 }
 $malformedName=if($kind-ceq'schema4'){'handoff-schema4-malformed-complete-cache-and-repair'}else{'handoff-schema6-malformed-complete-preserved-and-repair'}
 Test-ExternalCase $malformedName {
  $fixture=Capture-StandardHandoff ('handoff-malformed-'+$kind) -Schema4:($kind-ceq'schema4');$poisoned=$false
  try{
   $bad=[byte[]]$fixture.completeBytes.Clone();$bad[0]=[byte][char]'?';[IO.File]::WriteAllBytes($fixture.complete,$bad);$poisoned=$true
   Assert-External ([Prunlet.ExternalUnavailableE2E.FixtureNative]::Identity($fixture.complete)-ceq$fixture.completeId-and[IO.FileInfo]::new($fixture.complete).Length-eq$fixture.completeBytes.Length) 'Malformed completion changed its real file ID or length'
   $recordPoisoned=Get-ExternalMetadata $fixture.record
   $first=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.firstMalformedHandoff=$first
   $presence=@{requestPresent=(Test-Path -LiteralPath $fixture.request);recordPresent=(Test-Path -LiteralPath $fixture.record);summaryAbsent=!(Test-Path -LiteralPath (Join-Path (Split-Path $fixture.request) ($fixture.id+'.json')));intentAbsent=!(Test-Path -LiteralPath (Join-Path (Split-Path $fixture.request) ($fixture.id+'.intent.json')))};$script:ExternalEvidence.firstMalformedPresence=$presence
   foreach($condition in $presence.Keys){Assert-External $presence[$condition] ('Malformed completion falsely established terminal authority: '+$condition)}
   $oldDocument=[IO.File]::ReadAllText($fixture.request)|ConvertFrom-Json -AsHashtable -Depth 100
   if($kind-ceq'schema6'){
    $stable=Get-ExternalMetadata $fixture.scope.metadata;$stableNames=Get-ExternalNamespace $fixture.scope.metadata
    $facts=@{standardRequest=($oldDocument.kind-ceq'retire-request');requiredReceipt=($oldDocument.requiredFinalReceiptName-ceq'restore-0000-complete.json');recordUnchanged=((Get-ExternalMetadata $fixture.record)-ceq$recordPoisoned);invalidJsonRejected=($first.stdout+$first.stderr).Contains('Recycle metadata JSON is invalid')}
    $script:ExternalEvidence.firstMalformedMarker=$oldDocument;$script:ExternalEvidence.firstMalformedFacts=$facts
    Assert-StandardData $fixture;foreach($condition in $facts.Keys){Assert-External $facts[$condition] ('Malformed standard C6 completion violated '+$condition)}
    foreach($round in 1..2){$r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$facts=@{invalidJsonRejected=($r.stdout+$r.stderr).Contains('Recycle metadata JSON is invalid');metadataUnchanged=((Get-ExternalMetadata $fixture.scope.metadata)-ceq$stable);namespaceUnchanged=((Get-ExternalNamespace $fixture.scope.metadata)-ceq$stableNames);noSummary=!(Test-Path -LiteralPath (Join-Path (Split-Path $fixture.request) ($fixture.id+'.json')));noIntent=!(Test-Path -LiteralPath (Join-Path (Split-Path $fixture.request) ($fixture.id+'.intent.json')))};$script:ExternalEvidence['standardMalformedScan'+$round]=@{response=$r;facts=$facts};Assert-StandardData $fixture;foreach($condition in $facts.Keys){Assert-External $facts[$condition] ('Malformed standard C6 preservation violated '+$condition)}}
    $withheld=Join-Path $fixture.scope.root 'owned-completion-withheld.json';[IO.File]::Move($fixture.complete,$withheld)
    try{
     $missingMetadata=Get-ExternalMetadata $fixture.scope.metadata;$missingNames=Get-ExternalNamespace $fixture.scope.metadata
     $r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$facts=@{metadataUnchanged=((Get-ExternalMetadata $fixture.scope.metadata)-ceq$missingMetadata);namespaceUnchanged=((Get-ExternalNamespace $fixture.scope.metadata)-ceq$missingNames);noSummary=!(Test-Path -LiteralPath (Join-Path (Split-Path $fixture.request) ($fixture.id+'.json')));noIntent=!(Test-Path -LiteralPath (Join-Path (Split-Path $fixture.request) ($fixture.id+'.intent.json')));receiptIdentityPreserved=([Prunlet.ExternalUnavailableE2E.FixtureNative]::Identity($withheld)-ceq$fixture.completeId)}
     $script:ExternalEvidence.missingStandardCompletion=@{response=$r;facts=$facts};Assert-StandardData $fixture;foreach($condition in $facts.Keys){Assert-External $facts[$condition] ('Missing standard C6 completion violated '+$condition)}
    }finally{[IO.File]::Move($withheld,$fixture.complete)}
   }else{
   $firstFacts=@{requestIsExternal=($oldDocument.kind-ceq'external-unavailable-request');formalFailureDiagnostic=$oldDocument.externalUnavailable.diagnostic.StartsWith('Standard terminal validation was retained: ');recordUnchanged=((Get-ExternalMetadata $fixture.record)-ceq$recordPoisoned);noSummary=!(Test-Path -LiteralPath (Join-Path (Split-Path $fixture.request) ($fixture.id+'.json')));noIntent=!(Test-Path -LiteralPath (Join-Path (Split-Path $fixture.request) ($fixture.id+'.intent.json')))}
   $script:ExternalEvidence.firstMalformedFacts=$firstFacts;$script:ExternalEvidence.firstMalformedMarker=$oldDocument
   Assert-StandardData $fixture;foreach($condition in $firstFacts.Keys){Assert-External $firstFacts[$condition] ('Malformed formal completion violated '+$condition)}
   # 二つ目の不正bytesも本物receiptの同じID/長さだけに書き、正当なtoken再評価を一度確認する。
   $oldId=[Prunlet.ExternalUnavailableE2E.FixtureNative]::LegacyIdentity($fixture.request);$oldLength=[IO.FileInfo]::new($fixture.request).Length;$oldSha=(Get-FileHash -LiteralPath $fixture.request).Hash.ToLowerInvariant()
   $bad[0]=[byte][char]'!';[IO.File]::WriteAllBytes($fixture.complete,$bad);$recordPoisoned=Get-ExternalMetadata $fixture.record;$others=Get-ExternalMetadata $fixture.scope.metadata $fixture.request;$names=Get-ExternalNamespace $fixture.scope.metadata
   $changed=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.changedMalformedHandoff=$changed
   $newDocument=[IO.File]::ReadAllText($fixture.request)|ConvertFrom-Json -AsHashtable -Depth 100
   $facts=@{fingerprintChanged=($newDocument.externalUnavailable.retryFingerprint-cne$oldDocument.externalUnavailable.retryFingerprint);formalFailureDiagnostic=$newDocument.externalUnavailable.diagnostic.StartsWith('Standard terminal validation was retained: ');authorityBindingsUnchanged=((Normalize-ExternalRequestBindings $oldDocument)-ceq(Normalize-ExternalRequestBindings $newDocument));predecessorMatches=($newDocument.previousRequestIdentity-ceq$oldId-and$newDocument.previousRequestLength-eq$oldLength-and$newDocument.previousRequestSha256-ceq$oldSha);recordUnchanged=((Get-ExternalMetadata $fixture.record)-ceq$recordPoisoned);otherMetadataUnchanged=((Get-ExternalMetadata $fixture.scope.metadata $fixture.request)-ceq$others);namespaceUnchanged=((Get-ExternalNamespace $fixture.scope.metadata)-ceq$names)}
   $script:ExternalEvidence.changedMalformedFacts=$facts;Assert-StandardData $fixture;foreach($condition in $facts.Keys){Assert-External $facts[$condition] ('Changed malformed completion violated '+$condition)}
   $stable=Get-ExternalMetadata $fixture.scope.metadata;$stableNames=Get-ExternalNamespace $fixture.scope.metadata
   foreach($round in 1..2){$r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence['unchangedHandoff'+$round]=$r;$facts=@{canonicalDiagnostic=($r.stdout+$r.stderr).Contains('Unchanged standard terminal probe; operation bodies were not inspected.');metadataUnchanged=((Get-ExternalMetadata $fixture.scope.metadata)-ceq$stable);namespaceUnchanged=((Get-ExternalNamespace $fixture.scope.metadata)-ceq$stableNames);recordPreserved=(Test-Path -LiteralPath $fixture.record);noSummary=!(Test-Path -LiteralPath (Join-Path (Split-Path $fixture.request) ($fixture.id+'.json')))};$script:ExternalEvidence['unchangedHandoffFacts'+$round]=$facts;Assert-StandardData $fixture;foreach($condition in $facts.Keys){Assert-External $facts[$condition] ('Unchanged malformed completion violated '+$condition)}}
   }
   [IO.File]::WriteAllBytes($fixture.complete,$fixture.completeBytes);$poisoned=$false
   Assert-External ([Prunlet.ExternalUnavailableE2E.FixtureNative]::Identity($fixture.complete)-ceq$fixture.completeId-and[IO.FileInfo]::new($fixture.complete).Length-eq$fixture.completeBytes.Length) 'Exact genuine completion correction changed identity/length'
   $r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.correctedHandoff=$r
   Assert-External ($r.exitCode-eq0) 'Corrected genuine completion did not trigger full standard validation again';Assert-StandardClosed $fixture
  }finally{if($poisoned-and[IO.File]::Exists($fixture.complete)){[IO.File]::WriteAllBytes($fixture.complete,$fixture.completeBytes)}}
 }
}
Test-ExternalCase 'schema6-large-one-external-absence-closes' {
 $fixture=New-ExternalBinFixture 'large-once' $ExecutablePath $LargeFileCount;Move-ExternalFixtureOutOfBin $fixture
 $r=Invoke-ExternalCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:ExternalEvidence.large=@{fileCount=$LargeFileCount;maintenance=$r;originalRootId=$fixture.before[0].Id;metadataAfter=(Get-ExternalMetadata $fixture.scope.metadata);scope='one large real record, no repeated namespace benchmark or sparse fixture'}
 Assert-External ($r.exitCode-eq0) 'Large external record failed';Assert-ExternalClosed $fixture
} -RequiresLarge
$expectedDefaultCases=37;$expectedCatalogCases=38
if(!$results.Count){$results.Add(@{name='case-filter-matched-no-cases';passed=$false;error='CaseFilter matched no external-unavailable cases.'})}
$selected=@($registered|Where-Object {$name=$_;(Selected-External $name)-and($Large-or$name-cne'schema6-large-one-external-absence-closes')})
if($registered.Count-ne$expectedCatalogCases-or$results.Count-ne$selected.Count){$results.Add(@{name='coverage-count';passed=$false;error='Registered/selected/executed case counts differ.'})}
$excludedDefault=@($excluded|Where-Object {$_-cne'schema6-large-one-external-absence-closes'})
$report=@{sourceSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;helperSources=@($nativeFiles|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}});executablePath=$ExecutablePath;executableSha256=(Get-FileHash -LiteralPath $ExecutablePath).Hash;baselineExecutablePath=$BaselineExecutablePath;baselineSha256=(Get-FileHash -LiteralPath $BaselineExecutablePath).Hash;additionalProducers=@(@{path=$MoveExecutablePath;sha256=$(if($MoveExecutablePath){(Get-FileHash -LiteralPath $MoveExecutablePath).Hash}else{$null});expected='genuine1.0.11'},@{path=$LegacyCopyExecutablePath;sha256=$(if($LegacyCopyExecutablePath){(Get-FileHash -LiteralPath $LegacyCopyExecutablePath).Hash}else{$null});expected='genuine1.0.9'},@{path=$PriorTypedExecutablePath;sha256=$PriorTypedExecutableSha256;expected='frozen prior typed build'});expectedDefaultCases=$expectedDefaultCases;expectedCatalogCases=$expectedCatalogCases;suiteStage='external-unavailable-full-contract';caseFilter=$CaseFilter;selectedCases=$selected;excludedCases=@($excluded);selectedExpectedCount=$selected.Count;executedCount=$results.Count;coverage=$(if($excludedDefault.Count){'selected-subset'}else{'full-default-suite'});largeRequested=[bool]$Large;largeCoverage=$(if($Large-and(Selected-External 'schema6-large-one-external-absence-closes')){'selected-once'}else{'excluded-not-run'});unverifiedBoundaries=@('Real offline/unmounted volume and VHD management are not performed; the GUID case tampers genuine provenance and is not offline evidence.','One-volume environment cannot create multiple genuine C4 containers in one operation; all-container atomic preflight across volumes remains a separate requirement.');results=@($results);commands=@($commands);passed=@($results|Where-Object passed).Count;failed=@($results|Where-Object {!$_.passed}).Count;retainedDirectory=$OutputDirectory;scope='Windows-managed single owned Bin fixtures; post-external-operation bytes/ID/raw OGD/attributes are the Core preservation baseline; no global Bin cleanup or permanent data deletion'}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 80),$utf8)
$report|Select-Object passed,failed,coverage,selectedExpectedCount,expectedDefaultCases|ConvertTo-Json
if($report.failed){exit 1}
