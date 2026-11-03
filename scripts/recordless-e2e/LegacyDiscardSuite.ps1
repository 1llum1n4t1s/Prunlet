$ErrorActionPreference='Stop'
# 先に定義する失敗: 所有外root/registry信号の破棄、旧本文の解釈・bundle生成、DRの変更、
# StoreKey/8KiB markerのbinding迂回、旧rootの通常走査、gate前dispatch・中断後の暗黙再送、
# Shell直前の旧対象差替えによる別IDの誤廃棄・誤成功・不確実gateの早期解除。
$verificationRoot=Split-Path $PSScriptRoot -Parent;$repo=Split-Path $verificationRoot -Parent
. (Join-Path $verificationRoot 'Verification-Common.ps1')
. (Join-Path $verificationRoot 'Verification-Fixture.ps1')
$script:fixtureRun=$null;if($FixtureRoot){$script:fixtureRun=New-VerificationFixtureRun -FixtureRoot $FixtureRoot -ForbiddenRoots @($repo,(Join-Path $env:USERPROFILE '.codex')) -NamePrefix 'legacy-discard'}
$script:legacyRecordFixtureRun=$null;if($LegacyRecordFixtureRoot){$script:legacyRecordFixtureRun=New-VerificationFixtureRun -FixtureRoot $LegacyRecordFixtureRoot -ForbiddenRoots @($repo,(Join-Path $env:USERPROFILE '.codex'),$OutputDirectory) -NamePrefix 'legacy-records'}
foreach($path in @($ExecutablePath,$LegacyExecutablePath,$MoveExecutablePath,$BaselineExecutablePath,$OutputDirectory,$ReportPath)){if(!$path-or![IO.Path]::IsPathFullyQualified($path)){throw 'Candidate, old producers, output and report must be absolute'}}
foreach($path in @($OutputDirectory,$ReportPath)){Assert-VerificationDestination $path @($repo,(Join-Path $env:USERPROFILE '.codex'));if(![IO.Path]::GetPathRoot($path).Equals('D:\',[StringComparison]::OrdinalIgnoreCase)-or(Test-Path -LiteralPath $path)){throw 'Unused external D output/report required'};if(![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))){throw 'Output parent missing'}}
if($AssemblyPath-and(![IO.Path]::IsPathFullyQualified($AssemblyPath)-or![IO.File]::Exists($AssemblyPath))){throw 'Synthetic fixture assembly must be an existing absolute path'}
$producerRecords=@()
if($ProducerProvenancePath){if(![IO.Path]::IsPathFullyQualified($ProducerProvenancePath)){throw 'Producer provenance path must be absolute'};$record=Get-Content -LiteralPath $ProducerProvenancePath -Raw|ConvertFrom-Json -AsHashtable;if($record.schema-ne1){throw 'Unsupported producer provenance schema'};$producerRecords=@($record.producers)}
$producerPins=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($producer in @(@{path=$LegacyExecutablePath;version='1.0.9'},@{path=$MoveExecutablePath;version='1.0.11'},@{path=$BaselineExecutablePath;version='1.0.15'})){
 if(![IO.File]::Exists($producer.path)){throw 'Old producer missing'}
 $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($producer.path).ProductVersion
 if($version-notmatch('^'+[regex]::Escape($producer.version)+'(?:[.+-]|$)')){throw 'Old producer version differs'}
 $pin=@{path=$producer.path;version=$version;expectedVersion=$producer.version;sha256=(Get-FileHash -LiteralPath $producer.path).Hash;origin=@{classification='unverified-origin';distributionAuthenticated=$false}}
 $matches=@($producerRecords|Where-Object {$_.path-eq$producer.path});if($matches.Count-gt1){throw 'Duplicate producer provenance'}
 if($matches.Count){
  $entry=$matches[0]
  if($entry.sha256-ne$pin.sha256-or$entry.version-ne$version){throw 'Pinned producer path/version/hash differs'}
  if($entry.classification-cnotin@('unverified-origin','retained-source-only-build')){throw 'Producer origin needs independently verified evidence; version alone is not release authentication'}
  if($entry.evidencePath){
   if(![IO.Path]::IsPathFullyQualified($entry.evidencePath)-or(Get-FileHash -LiteralPath $entry.evidencePath).Hash-ne$entry.evidenceSha256){throw 'Producer provenance evidence changed'}
   $checkpoint=Get-Content -LiteralPath $entry.evidencePath -Raw|ConvertFrom-Json -AsHashtable
   if($entry.classification-ceq'retained-source-only-build'-and($checkpoint.deployReason-notmatch'(?i)source-only'-or($checkpoint.prePublish.cliSha256-ne$pin.sha256-and$checkpoint.finalHost.cliSha256-ne$pin.sha256))){throw 'Source-only checkpoint does not bind this retained executable'}
  }elseif($entry.classification-cne'unverified-origin'){throw 'Retained source-only producer needs a matching checkpoint'}
  $pin.origin=@{classification=$entry.classification;distributionAuthenticated=$false;evidencePath=$entry.evidencePath;evidenceSha256=$entry.evidenceSha256;note=$entry.note}
 }
 $producerPins.Add($producer.path,$pin)
}
$legacyProducerBuildRecord=$null
if($LegacyProducerBuildRecordPath){
 if(![IO.Path]::IsPathFullyQualified($LegacyProducerBuildRecordPath)){throw 'Historical producer record path must be absolute'}
 $legacyProducerBuildRecord=Get-Content -LiteralPath $LegacyProducerBuildRecordPath -Raw|ConvertFrom-Json -AsHashtable
 if($legacyProducerBuildRecord.kind-cne'historical-source-rebuild'-or$legacyProducerBuildRecord.sourceCommit-notmatch'^[a-fA-F0-9]{40}$'-or$legacyProducerBuildRecord.archiveSha256-notmatch'^[a-fA-F0-9]{64}$'-or$legacyProducerBuildRecord.executableSha256-cne(Get-FileHash -LiteralPath $LegacyExecutablePath).Hash){throw 'Historical producer source/executable binding differs'}
 if(![IO.Path]::IsPathFullyQualified($legacyProducerBuildRecord.archivePath)-or(Get-FileHash -LiteralPath $legacyProducerBuildRecord.archivePath).Hash-ne$legacyProducerBuildRecord.archiveSha256){throw 'Historical producer archive differs'}
 $producerPins[$LegacyExecutablePath].origin=@{classification='historical-source-rebuild';distributionAuthenticated=$false;buildRecord=$legacyProducerBuildRecord;buildRecordPath=$LegacyProducerBuildRecordPath;buildRecordSha256=(Get-FileHash -LiteralPath $LegacyProducerBuildRecordPath).Hash}

}
$moveProducerBuildRecord=$null
if($MoveProducerBuildRecordPath){
 if(![IO.Path]::IsPathFullyQualified($MoveProducerBuildRecordPath)){throw 'Historical move producer record path must be absolute'}
 $moveProducerBuildRecord=Get-Content -LiteralPath $MoveProducerBuildRecordPath -Raw|ConvertFrom-Json -AsHashtable
 if($moveProducerBuildRecord.kind-cne'historical-source-rebuild'-or$moveProducerBuildRecord.sourceCommit-notmatch'^[a-fA-F0-9]{40}$'-or$moveProducerBuildRecord.archiveSha256-notmatch'^[a-fA-F0-9]{64}$'-or$moveProducerBuildRecord.executableSha256-cne(Get-FileHash -LiteralPath $MoveExecutablePath).Hash){throw 'Historical move producer source/executable binding differs'}
 if(![IO.Path]::IsPathFullyQualified($moveProducerBuildRecord.archivePath)-or(Get-FileHash -LiteralPath $moveProducerBuildRecord.archivePath).Hash-ne$moveProducerBuildRecord.archiveSha256){throw 'Historical move producer archive differs'}
 $producerPins[$MoveExecutablePath].origin=@{classification='historical-source-rebuild';distributionAuthenticated=$false;buildRecord=$moveProducerBuildRecord;buildRecordPath=$MoveProducerBuildRecordPath;buildRecordSha256=(Get-FileHash -LiteralPath $MoveProducerBuildRecordPath).Hash}
}
$null=[IO.Directory]::CreateDirectory($OutputDirectory);$script:temp=Join-Path $OutputDirectory 'temp';$null=[IO.Directory]::CreateDirectory($script:temp);$oldTemp=$env:TEMP;$oldTmp=$env:TMP;$env:TEMP=$script:temp;$env:TMP=$script:temp
$helperFiles=@('NativeShellFixture.cs','FixtureNative.cs','OwnedBinLocator.cs','PermissionFixture.cs')|ForEach-Object {Join-Path $PSScriptRoot $_}
$common=Join-Path $PSScriptRoot 'Common.ps1';. $common
$hostScript=Join-Path $PSScriptRoot 'LegacyDiscardCheckpointHost.ps1'
. (Join-Path $PSScriptRoot 'RustFileProbe.Common.ps1')
$buildBinding=Assert-RustFileProbeBinding
. (Join-Path $PSScriptRoot 'LegacyDiscardRustProbe.Common.ps1')
$suiteArtifactPins=Open-LegacyArtifactPinsM
try {
$suiteArtifactsAtStart=Assert-LegacyArtifactPinsM $suiteArtifactPins
$assemblyHash=if($AssemblyPath){(Get-FileHash -LiteralPath $AssemblyPath).Hash}else{$null}
$sources=@($entryScriptPath,$PSCommandPath,$common,$hostScript,(Join-Path $PSScriptRoot 'LegacyDiscardRustProbe.Common.ps1'))+$helperFiles;$initialSources=@($sources|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}})
$initialSources+=@(Get-RustFileProbeSourceHashes)
$results=[Collections.Generic.List[object]]::new();$script:commands=[Collections.Generic.List[object]]::new();$catalog=[Collections.Generic.List[string]]::new();$excluded=[Collections.Generic.List[string]]::new()
# metadataはDへ残し、明示fixture volumeのpayload/owned storeだけを分離する。
$script:baseNewScopeM=${function:New-ScopeR}
function New-ScopeR([string]$Name,[switch]$HostVolume,[switch]$ImmediateVolume){
 $scope=& $script:baseNewScopeM $Name -HostVolume:$HostVolume -ImmediateVolume:$ImmediateVolume
 $settings=Get-Content -LiteralPath $scope.config -Raw|ConvertFrom-Json -AsHashtable
 if($script:legacyRecordFixtureRun){
  $targetRoot=Join-Path $script:legacyRecordFixtureRun.directory $Name
  $scope.metadata=Join-Path $targetRoot 'metadata';$scope.store=Join-Path $targetRoot 'store'
  $null=[IO.Directory]::CreateDirectory($scope.metadata);Set-PrivateM $scope.metadata -Directory
  $settings.backupDirectory=$scope.metadata;$settings.volumeRecoveryDirectories=@{}
  $settings.volumeRecoveryDirectories[[IO.Path]::GetPathRoot($scope.metadata)]=$scope.store
 }
 $volume=[IO.Path]::GetPathRoot($scope.files)
 if($script:fixtureRun-and!$settings.volumeRecoveryDirectories.ContainsKey($volume)){$settings.volumeRecoveryDirectories[$volume]=Join-Path (Split-Path $scope.files -Parent) 'store'}
 Save-R $scope.config $settings
 return $scope
}
function Case-M([string]$Name,[scriptblock]$Body){$catalog.Add($Name);if(!@($CaseFilter|Where-Object {$Name-like$_}).Count){$excluded.Add($Name);return};$script:observed=@{fixtureAuthority='synthetic-owned-boundary-model'};$clock=[Diagnostics.Stopwatch]::StartNew();try{&$Body;$results.Add(@{name=$Name;passed=$true;observed=$script:observed;elapsedMs=$clock.ElapsedMilliseconds})}catch{$results.Add(@{name=$Name;passed=$false;error=$_.Exception.ToString();stack=$_.ScriptStackTrace;observed=$script:observed;elapsedMs=$clock.ElapsedMilliseconds})}}
function New-LegacyM([int]$Schema,[string]$Name,$Scope=$null){
 $s=if($Scope){$Scope}else{New-ScopeR $Name};$file=File-R $s 'original/data.bin' 97;if($Schema-eq3){[IO.File]::WriteAllText($file+':legacy-stream','legacy ADS',$utf8)};$source=if($Schema-eq1){$file}else{Split-Path $file};$before=Snapshot-R $source
 $legacy=$s.Clone();$legacy.config=Join-Path $s.root 'legacy-config.json';$config=Get-Content -LiteralPath $s.config -Raw|ConvertFrom-Json -AsHashtable;$null=$config.Remove('capacityDefaultMigrationVersion');if($Schema-lt4){$null=$config.Remove('volumeRecoveryDirectories')};Save-R $legacy.config $config
 $exe=if($Schema-lt4){$LegacyExecutablePath}elseif($Schema-eq4){$MoveExecutablePath}else{$BaselineExecutablePath};$paths=Join-Path $s.root 'legacy-paths.json';Save-R $paths @($source);$arguments=@('delete');if($Schema-ne1){$arguments+='--recursive'};$arguments+=@('--paths-file',$paths);$pin=$producerPins[$exe];$stream=[IO.File]::Open($exe,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{Assert-R ((Get-FileHash -InputStream $stream).Hash-eq$pin.sha256) 'Pinned old producer changed';$deleted=Invoke-R $legacy $arguments -Exe $exe;$stream.Position=0;Assert-R ((Get-FileHash -InputStream $stream).Hash-eq$pin.sha256) 'Old producer changed during fixture generation'}finally{$stream.Dispose()}
 Assert-R ($deleted.exitCode-eq0-and$deleted.json.operationId-and!(Test-Path -LiteralPath $source)) 'Old runtime fixture generation failed';$id=$deleted.json.operationId;$record=Join-Path $s.metadata $id;$manifestName=if($Schema-lt4){'manifest.json'}elseif($Schema-eq4){'move-manifest.json'}else{'recycle-manifest.json'};$manifest=Join-Path $record $manifestName;$document=Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json -AsHashtable -Depth 100
 Assert-R ($document.schema-eq$Schema) 'Old runtime generated schema differs';$fixture=@{scope=$s;schema=$Schema;id=$id;record=$record;manifest=$manifest;document=$document;source=$source;original=$before;recordProof=(Snapshot-R $record);legacy=$legacy;producer=$exe}
 if($Schema-eq4){$fixture.storeRoot=$document.entries[0].storeRoot;$fixture.storeProof=Snapshot-R $fixture.storeRoot}
 if($Schema-eq6){$receipt=Get-Content -LiteralPath (Join-Path $record 'recycle-0000-complete.json') -Raw|ConvertFrom-Json -AsHashtable;$fixture.binReceipt=$receipt;$fixture.binProof=Snapshot-R $receipt.physicalPath}
 $script:observed.fixtureAuthority=$pin.origin.classification;$script:observed.schemaAuthority='old-runtime-generated';$script:observed.producerPin=$pin;$script:observed.schemaGeneration=@{expectedSchema=$Schema;observedSchema=$document.schema;passed=$true};$script:observed.producerBuildRecord=$(if($Schema-lt4){$legacyProducerBuildRecord}else{$null});$script:observed.fixture=@{schema=$Schema;operationId=$id;source=$source;record=$record;producer=$exe;producerVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($exe).ProductVersion;producerSha256=(Get-FileHash -LiteralPath $exe).Hash};return $fixture
}
function Proof-M([string]$Path){$proof=Snapshot-R $Path;return @{path=$Path;before=$proof;prior=(Before-BinR $proof)}}
function Assert-BinM($Proof){
 Assert-R (!(Test-Path -LiteralPath $Proof.path)) 'Legacy discard left its original root present';$item=[Prunlet.RecordlessE2E.OwnedBinLocator]::FindNew($Proof.before[0].Id,[string[]]$Proof.prior)
 $after=Assert-SnapshotR $item.PhysicalPath $Proof.before -WindowsManagedBin
 if(!$script:observed.ContainsKey('binItems')){$script:observed.binItems=[Collections.Generic.List[object]]::new()};$script:observed.binItems.Add(@{original=$Proof.path;item=$item;before=$Proof.before;after=$after;windowsSecurityManaged=$true})
 Assert-R (!@($after|Where-Object {$_.Relative-match'original-permissions\.json|README\.txt|\.prunlet-file-migration-'}).Count) 'Discard materialized a legacy bundle or sidecar';return $item
}
function Assert-ApplyM($Response,[switch]$Partial){Assert-R ($Response.exitCode-eq0-and$Response.json.registryReady-and!$Response.json.dryRun) 'Discard response did not leave registry available';if(!$Partial){Assert-R $Response.json.complete 'Owned legacy discard was not complete'};Assert-R (!@($Response.json.operations|Where-Object {$_.bundlePath}).Count) 'Removed bundle contract leaked into discard response'}
function Get-LegacyDryPathsM($Scope){
 $paths=@($Scope.root,$Scope.metadata,$Scope.store,($Scope.store+'.restore'),$Scope.files)
 $settings=Get-Content -LiteralPath $Scope.config -Raw|ConvertFrom-Json -AsHashtable
 foreach($value in $settings.volumeRecoveryDirectories.Values){$paths+=@($value,($value+'.restore'))}
 $roots=[Collections.Generic.List[string]]::new()
 foreach($path in @($paths|Where-Object {$_}|ForEach-Object {[IO.Path]::GetFullPath($_).TrimEnd('\')}|Sort-Object Length)){
  if(!@($roots|Where-Object {$path.Equals($_,[StringComparison]::OrdinalIgnoreCase)-or$path.StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){$roots.Add($path)}
 }
 return @($roots)
}
function Assert-DryM($Scope){
 $before=@(Get-LegacyDryPathsM $Scope|ForEach-Object {$exists=Test-Path -LiteralPath $_;@{path=$_;exists=$exists;snapshot=$(if($exists){Snapshot-R $_}else{$null})}})
 $r=Invoke-R $Scope @('migrate');$script:observed.preview=$r
 Assert-R ($r.exitCode-eq0-and$r.json.dryRun) 'Migration preview failed'
 foreach($entry in $before){
  Assert-R ((Test-Path -LiteralPath $entry.path)-eq$entry.exists) ('Dry-run changed target existence: '+$entry.path)
  if($entry.exists){$null=Assert-SnapshotR $entry.path $entry.snapshot}
 }
 $script:observed.dryRunComparedPaths=@($before|ForEach-Object {$_.path})
 Assert-R (!(Test-Path -LiteralPath (Join-Path $Scope.metadata '.legacy-file-discard-in-progress'))) 'Dry-run created discard gate'
}
function Set-PrivateM([string]$Path,[switch]$Directory){
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
 $item=if($Directory){[IO.DirectoryInfo]::new($Path)}else{[IO.FileInfo]::new($Path)}
 $owner=[IO.FileSystemAclExtensions]::GetAccessControl($item,[Security.AccessControl.AccessControlSections]::Owner).GetOwner([Security.Principal.SecurityIdentifier])
 Assert-R ($owner-eq$sid) 'Private fixture owner differs from the current user'
 # fixtureのDACLだけを更新し、Owner・Group・SACLは変更しない。
 $acl=[IO.FileSystemAclExtensions]::GetAccessControl($item,[Security.AccessControl.AccessControlSections]::Access)
 $acl.SetAccessRuleProtection($true,$false)
 foreach($rule in @($acl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]))){$acl.RemoveAccessRuleSpecific($rule)}
 foreach($who in @($sid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){
  $rule=if($Directory){[Security.AccessControl.FileSystemAccessRule]::new($who,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)}else{[Security.AccessControl.FileSystemAccessRule]::new($who,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow)}
  $acl.AddAccessRule($rule)
 }
 [IO.FileSystemAclExtensions]::SetAccessControl($item,$acl)
}
function Host-M($Scope,[string]$Action,[string]$Phase='',[string]$Target=''){
 if($Action-ceq'Checkpoint'){
  $run=Start-LegacyRustM $Scope $Action $Phase $Target
  try{Wait-LegacyRustCheckpointM $run $Phase $Target;$run.child.Kill($true);$run.child.WaitForExit();$script:observed.checkpoint=@{phase=$Phase;target=$Target;pid=$run.child.Id;runtime='rust-libtest';sameSourceBuild=$buildBinding;artifactsAtStart=$run.artifactsAtStart;artifactsAtCheckpoint=$run.artifactsAtCheckpoint}}finally{Close-LegacyRustM $run};return
 }
 if(!$AssemblyPath){throw 'FixtureAssemblyPath is required only for synthetic typed-root marker models; it is not the Rust candidate runtime.'}
 $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 foreach($argument in @('-NoProfile','-File',$hostScript,'-AssemblyPath',$AssemblyPath,'-ExpectedAssemblySha256',$assemblyHash,'-ConfigPath',$Scope.config,'-Action',$Action)){$info.ArgumentList.Add($argument)}
 $info.Environment['TEMP']=$script:temp;$info.Environment['TMP']=$script:temp
 $child=[Diagnostics.Process]::Start($info);$stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
 try{Assert-R ($child.WaitForExit(60000)-and$child.ExitCode-eq0) ('Synthetic ownership marker preparation failed: '+$stderr.GetAwaiter().GetResult());$script:observed.fixtureHelper=@{runtime='dotnet-reflection';authority='synthetic-owned-marker-only';assemblyPath=$AssemblyPath;assemblySha256=$assemblyHash};return ($stdout.GetAwaiter().GetResult()|ConvertFrom-Json)}finally{if(!$child.HasExited){$child.Kill($true);$child.WaitForExit()};$child.Dispose()}
}
function Invoke-SwapHostM($Fixture,$Original,$Replacement,[string]$Parked){
 $scope=$Fixture.scope;$run=Start-LegacyRustM $scope 'Swap' 'shell.ready' $Fixture.record
 try{
  Wait-LegacyRustCheckpointM $run 'shell.ready' $Fixture.record
  $null=Assert-SnapshotR $Fixture.record $Original.before;$null=Assert-SnapshotR $Replacement.path $Replacement.before;Assert-R (!(Test-Path -LiteralPath $Parked)) 'Parked original destination occupied'
  [Prunlet.RecordlessE2E.FixtureNative]::MoveOwned($Fixture.record,$Parked,$Original.before[0].Id,$scope.metadata);$null=Assert-SnapshotR $Parked $Original.before
  [Prunlet.RecordlessE2E.FixtureNative]::MoveOwned($Replacement.path,$Fixture.record,$Replacement.before[0].Id,$scope.metadata);$null=Assert-SnapshotR $Fixture.record $Replacement.before
  $script:observed.swap=@{checkpoint='shell.ready';pid=$run.child.Id;runtime='rust-libtest';sameSourceBuild=$buildBinding;originalId=$Original.before[0].Id;parked=$Parked;replacementId=$Replacement.before[0].Id;target=$Fixture.record}
  return (Complete-LegacyRustM $run)
 }finally{Close-LegacyRustM $run}
}
function Invoke-MutationHostM($Scope,[string]$Target,[scriptblock]$Mutation){
 $run=Start-LegacyRustM $Scope 'Swap' 'shell.ready' $Target
 try{Wait-LegacyRustCheckpointM $run 'shell.ready' $Target;&$Mutation;return (Complete-LegacyRustM $run)}finally{Close-LegacyRustM $run}
}
try {
 Add-Type -Path $helperFiles -CompilerOptions '/unsafe'
 foreach($schema in @(1,2,3,4,6)) {Case-M ('genuine-schema'+$schema+'-roots-discarded-without-materialization') {
  $f=New-LegacyM $schema ('schema'+$schema);$record=Proof-M $f.record;$store=if($schema-eq4){Proof-M $f.storeRoot}else{$null};$storeParent=if($store){Split-Path $f.storeRoot}else{$null};$parentId=if($store){[Prunlet.RecordlessE2E.FixtureNative]::Identity($storeParent)}else{$null}
  Assert-DryM $f.scope;$applied=Invoke-R $f.scope @('migrate','--apply');$script:observed.apply=$applied;Assert-ApplyM $applied;$null=Assert-BinM $record;if($store){$null=Assert-BinM $store;Assert-R ((Test-Path -LiteralPath $storeParent)-and[Prunlet.RecordlessE2E.FixtureNative]::Identity($storeParent)-ceq$parentId) 'Owned discard removed the private base'}
  Assert-R (!(Test-Path -LiteralPath $f.source)) 'Discard restored an individual original source';if($schema-eq6){$null=Assert-SnapshotR $f.binReceipt.physicalPath $f.binProof}
  $again=Invoke-R $f.scope @('migrate','--apply');Assert-ApplyM $again;Assert-R (!@($again.json.operations|Where-Object status -EQ 'recycled').Count) 'Completed discard was resent'
 }}
 Case-M 'other-config-storekey-and-private-base-preserved' {
  $one=New-LegacyM 4 'shared-store-one';$second=New-ScopeR 'shared-store-two';$settings=Get-Content -LiteralPath $second.config -Raw|ConvertFrom-Json -AsHashtable;$sharedVolume=[IO.Path]::GetPathRoot($one.source);$sharedBase=Split-Path $one.storeRoot;$settings.volumeRecoveryDirectories[$sharedVolume]=$sharedBase;Save-R $second.config $settings;$two=New-LegacyM 4 'unused' $second;$before=Snapshot-R $two.storeRoot;$privateId=[Prunlet.RecordlessE2E.FixtureNative]::Identity($sharedBase)
  $target=Proof-M $one.storeRoot;$r=Invoke-R $one.scope @('migrate','--apply');Assert-ApplyM $r;$null=Assert-BinM $target;$null=Assert-SnapshotR $two.storeRoot $before;Assert-R ([Prunlet.RecordlessE2E.FixtureNative]::Identity($sharedBase)-ceq$privateId) 'Shared private base changed'
 }
 Case-M 'owned-restore-store-boundary-model-preserves-current-source' {
  $script:observed.fixtureAuthority='synthetic-dotnet-ownership-marker-boundary-model';$script:observed.notClaimed='Restore store ownership marker model, not a genuine released legacy restore-store producer.';$s=New-ScopeR 'restore-store';$current=File-R $s 'current-source';$source=Snapshot-R $current;$roots=@(Host-M $s 'CreateRestoreRoot');Assert-R ($roots.Count-eq1) 'Synthetic restore ownership model root missing';[IO.File]::WriteAllText((Join-Path $roots[0] 'opaque-owned-body'),'owned restore-store test data',$utf8);$proof=Proof-M $roots[0];$r=Invoke-R $s @('migrate','--apply');Assert-ApplyM $r;$null=Assert-BinM $proof;$null=Assert-SnapshotR $current $source;Assert-R (Test-Path -LiteralPath ($s.store+'.restore')) 'Restore private base was discarded'
 }
 foreach($mixed in @($false,$true)){Case-M ('typed-file-roots-'+$(if($mixed){'registry-signals-preserved'}else{'discarded-without-reading-body'})) {
  $script:observed.fixtureAuthority='synthetic-dotnet-ownership-marker-boundary-model';$script:observed.notClaimed='This model uses current Core-owned root markers, not a genuine released legacy producer or legacy-schema compatibility fixture.';$s=New-ScopeR ('typed-'+$mixed);$roots=@(Host-M $s 'CreateTypedRoots');Assert-R ($roots.Count-eq2) 'Synthetic typed roots were not prepared';$proofs=@();foreach($root in $roots){[IO.File]::WriteAllText((Join-Path $root 'opaque-file-owned-body'),'not json; no parser should consume this',$utf8);if($mixed){[IO.File]::WriteAllText((Join-Path $root 'registry-owned-signal'),'protected',$utf8)};$proofs+=,(Proof-M $root)}
  $r=Invoke-R $s @('migrate','--apply');Assert-ApplyM $r -Partial:$mixed;foreach($proof in $proofs){if($mixed){$null=Assert-SnapshotR $proof.path $proof.before}else{$null=Assert-BinM $proof}}
 }}
 Case-M 'broken-file-manifest-body-is-not-read' {
  $f=New-LegacyM 1 'unreadable-body';[IO.File]::WriteAllText($f.manifest,'{broken old file body',$utf8);$recordId=[Prunlet.RecordlessE2E.FixtureNative]::Identity($f.record);$prior=[string[]]@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($recordId)|ForEach-Object Pidl);$security=[Prunlet.RecordlessE2E.PermissionFixture]::Security($f.manifest)
  try{[Prunlet.RecordlessE2E.PermissionFixture]::DenyDataRead($f.manifest,$security);Assert-R ([Prunlet.RecordlessE2E.PermissionFixture]::ReadDataError($f.manifest)-eq5) 'File body read denial was not established';$r=Invoke-R $f.scope @('migrate','--apply');$script:observed.apply=$r;Assert-ApplyM $r;Assert-R (!(Test-Path -LiteralPath $f.record)) 'Unreadable old file record was retained';$item=[Prunlet.RecordlessE2E.OwnedBinLocator]::FindNew($recordId,$prior);$script:observed.binItem=$item}
  finally{$body=if(Test-Path -LiteralPath $f.manifest){$f.manifest}elseif($item){Join-Path $item.PhysicalPath 'manifest.json'}else{$null};if($body){[Prunlet.RecordlessE2E.PermissionFixture]::SetDacl($body,$security)}}
 }
 Case-M 'registry-signal-mixed-with-file-marker-is-preserved' {
  $f=New-LegacyM 1 'mixed-signals';[IO.File]::WriteAllText((Join-Path $f.record 'registry-owned-sentinel'),'registry protection signal',$utf8);$before=Snapshot-R $f.record;$r=Invoke-R $f.scope @('migrate','--apply');Assert-ApplyM $r -Partial;Assert-R (!$r.json.complete) 'Mixed registry/file candidate was treated as complete';$null=Assert-SnapshotR $f.record $before;Assert-R ((Invoke-R $f.scope @('operations')).exitCode-eq0) 'Mixed retained file record blocked registry listing'
 }
 Case-M 'reserved-old-prefixes-discarded-without-body-interpretation' {
  $s=New-ScopeR 'reserved';Set-PrivateM $s.metadata -Directory;$paths=@();foreach($prefix in @('.legacy-file-migration-','.prunlet-file-migration-')){$path=Join-Path $s.metadata ($prefix+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($path);[IO.File]::WriteAllText((Join-Path $path 'opaque'),'broken reserved body',$utf8);$paths+=,(Proof-M $path)};Assert-DryM $s;$r=Invoke-R $s @('migrate','--apply');Assert-ApplyM $r;foreach($proof in $paths){$null=Assert-BinM $proof}
 }
 Case-M 'unknown-unowned-root-is-preserved' {
  $s=New-ScopeR 'unknown';$path=Join-Path $s.metadata ([guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($path);[IO.File]::WriteAllText((Join-Path $path 'unknown'),'unowned; no file marker',$utf8);$before=Snapshot-R $path;$r=Invoke-R $s @('migrate','--apply');Assert-ApplyM $r -Partial;Assert-R (!$r.json.complete) 'Unknown root was reported complete';$null=Assert-SnapshotR $path $before
 }
 foreach($damage in @('ownerSid','metadataRoot','rootFileId','oversized')) {Case-M ('store-marker-'+$damage+'-is-preserved') {
  $f=New-LegacyM 4 ('marker-'+$damage);$marker=Join-Path $f.storeRoot 'store.json';$body=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json -AsHashtable
  if($damage-ceq'oversized'){[IO.File]::WriteAllText($marker,('x'*8193),$utf8)}else{$body[$damage]=if($damage-ceq'ownerSid'){'S-1-5-18'}elseif($damage-ceq'metadataRoot'){Join-Path $f.scope.root 'another-config-root'}else{'00000000000000000000000000000000'};Save-R $marker $body}
  $before=Snapshot-R $f.storeRoot;$r=Invoke-R $f.scope @('migrate','--apply');Assert-ApplyM $r -Partial;Assert-R (!$r.json.complete) 'Invalid owned-store marker was accepted';$null=Assert-SnapshotR $f.storeRoot $before;Assert-R (Test-Path -LiteralPath $f.scope.store) 'Invalid store caused private-base deletion'
 }}
 Case-M 'state-version-zero-reassessed-to-discard-policy-two' {
  $s=New-ScopeR 'state-v0';Assert-ApplyM (Invoke-R $s @('migrate','--apply'));$statePath=Join-Path $s.metadata '.registry-records-v1/storage-migration-v1.json';$state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json -AsHashtable;$null=$state.Remove('legacyFilePolicyVersion');Save-R $statePath $state
  $f=New-LegacyM 1 'unused' $s;$proof=Proof-M $f.record;$r=Invoke-R $s @('migrate','--apply','--if-needed');Assert-ApplyM $r;$null=Assert-BinM $proof;Assert-R ((Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json).legacyFilePolicyVersion-eq2) 'Legacy assessment did not move from absent policy version to version 2'
 }
 Case-M 'if-needed-checks-newly-online-owned-store-without-central-rescan' {
  $s=New-ScopeR 'online-later';Assert-ApplyM (Invoke-R $s @('migrate','--apply'));$f=New-LegacyM 4 'unused' $s;$store=Proof-M $f.storeRoot;$centralBefore=Snapshot-R $f.record
  $r=Invoke-R $s @('migrate','--apply','--if-needed');Assert-ApplyM $r;$null=Assert-BinM $store;$null=Assert-SnapshotR $f.record $centralBefore
  $central=Proof-M $f.record;$again=Invoke-R $s @('migrate','--apply');Assert-ApplyM $again;$null=Assert-BinM $central
 }
 Case-M 'normal-file-list-maintain-do-not-walk-old-file-roots' {
  $s=New-ScopeR 'normal-no-walk';Assert-ApplyM (Invoke-R $s @('migrate','--apply'));$old=Join-Path $s.metadata ([guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($old);[IO.File]::WriteAllText((Join-Path $old 'manifest.json'),'opaque old manifest',$utf8);$security=[Prunlet.RecordlessE2E.PermissionFixture]::Security($old);$before=Snapshot-R $old
  try{[Prunlet.RecordlessE2E.PermissionFixture]::DenyDataRead($old,$security);$denied=$false;try{$null=@([IO.Directory]::EnumerateFileSystemEntries($old))}catch{$denied=$true};Assert-R $denied 'Old-root directory read denial was not established'
   foreach($arguments in @(@('operations'),@('maintain','--apply'))){$r=Invoke-R $s $arguments;Assert-R ($r.exitCode-eq0) 'Normal registry operation walked old file root'}
   $file=File-R $s 'current-file';$proof=Snapshot-R $file;$prior=Before-BinR $proof;$deleted=Delete-R $s @($file);Assert-WireR $deleted @($file) @('recycled');Assert-R ($deleted.exitCode-eq0) 'Normal file delete walked old file root';$item=[Prunlet.RecordlessE2E.OwnedBinLocator]::FindNew($proof[0].Id,$prior);$script:observed.currentFileBin=$item;$null=Assert-SnapshotR $item.PhysicalPath $proof -WindowsManagedBin
  }finally{[Prunlet.RecordlessE2E.PermissionFixture]::SetDacl($old,$security)};$null=Assert-SnapshotR $old $before
 }
 Case-M 'owned-volume-root-with-registry-signal-is-preserved' {
  $f=New-LegacyM 4 'store-registry-signal';$signal=Join-Path $f.storeRoot 'registry-owned-signal';[IO.File]::WriteAllText($signal,'protected registry signal before migration',$utf8);$proof=Proof-M $f.storeRoot
  $r=Invoke-R $f.scope @('migrate','--apply');$script:observed.apply=$r;$null=Assert-SnapshotR $f.storeRoot $proof.before;Assert-R (@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($proof.before[0].Id)|Where-Object {$_.Pidl-notin$proof.prior}).Count-eq0) 'Registry-bearing owned store moved to Bin'
  $item=@($r.json.operations|Where-Object {$_.path-ceq$f.storeRoot});Assert-R ($r.exitCode-eq1-and$r.json.registryReady-and!$r.json.dryRun-and!$r.json.complete-and$item.Count-eq1-and$item[0].status-ceq'failed'-and$item[0].error-match'(?i)registry') 'Registry-bearing owned store was not rejected'
 }
 Case-M 'discard-shell-ready-added-registry-signal-retains-gate' {
  $f=New-LegacyM 4 'late-store-registry-signal';$prior=Proof-M $f.storeRoot;$signal=Join-Path $f.storeRoot 'registry-late-signal';$gate=Join-Path $f.scope.metadata '.legacy-file-discard-in-progress'
  $result=Invoke-MutationHostM $f.scope $f.storeRoot {Assert-R (!(Test-Path -LiteralPath $signal)) 'Late signal destination occupied';[IO.File]::WriteAllText($signal,'protected late registry signal',$utf8);$script:observed.lateSignalBefore=Snapshot-R $f.storeRoot};$script:observed.migration=$result;$before=$script:observed.lateSignalBefore
  Assert-R (!(Test-Path -LiteralPath $f.storeRoot)) 'Late-signal store remained in original location; retained for inspection';$matches=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($prior.before[0].Id)|Where-Object {$_.Pidl-notin$prior.prior});$script:observed.lateSignalBin=$matches;Assert-R ($matches.Count-eq1) 'Late-signal store Bin identity missing or ambiguous; retained'
  $item=$matches[0];$bin=Assert-SnapshotR $item.PhysicalPath $before -WindowsManagedBin;$null=[Prunlet.RecordlessE2E.FixtureNative]::RestoreOwned($item.Pidl,$item.PhysicalPath,$prior.before[0].Id,$f.storeRoot,(Split-Path $f.storeRoot));$after=Assert-SnapshotR $f.storeRoot $before -WindowsManagedRestore
  $beforeByRelative=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);foreach($node in $before){$beforeByRelative.Add($node.Relative,$node)};$script:observed.lateSignalRestore=@{item=$item;bin=$bin;restored=$after;securityDiff=@($after|ForEach-Object {$old=$beforeByRelative[$_.Relative];@{relative=$_.Relative;before=$old.SecurityBase64;after=$_.SecurityBase64;equal=($old.SecurityBase64-ceq$_.SecurityBase64)}})}
  Assert-R (([IO.File]::ReadAllText($signal,$utf8))-ceq'protected late registry signal') 'Restored late registry signal content changed';$operation=@($result.operations|Where-Object {$_.path-ceq$f.storeRoot});Assert-R ($result.registryReady-and!$result.complete-and$operation.Count-eq1-and$operation[0].status-ceq'ambiguous'-and$operation[0].error-match'(?i)registry') 'Late registry signal did not produce ambiguous outcome'
  Assert-R ([IO.File]::Exists($gate)-and[IO.FileInfo]::new($gate).Length-eq0) 'Late registry signal did not retain gate';$gateBefore=Snapshot-R $gate;$restored=Snapshot-R $f.storeRoot
  foreach($args in @(@('migrate','--apply'),@('migrate','--apply','--if-needed'))){$blocked=Invoke-R $f.scope $args;Assert-ApplyM $blocked -Partial;Assert-R (!$blocked.json.complete-and($blocked.json.warnings-join' ')-match'(?i)retry-legacy-discard') 'Late signal gate did not block automatic replay';$null=Assert-SnapshotR $gate $gateBefore;$null=Assert-SnapshotR $f.storeRoot $restored}
  Assert-R ((Invoke-R $f.scope @('operations')).exitCode-eq0) 'Late signal gate blocked registry listing'
 }
 Case-M 'discard-gate-lease-denies-external-rename' {
  $f=New-LegacyM 1 'gate-rename';$proof=Proof-M $f.record;$gate=Join-Path $f.scope.metadata '.legacy-file-discard-in-progress';$renamed=Join-Path $f.scope.metadata '.legacy-gate-rename-attempt'
  $result=Invoke-MutationHostM $f.scope $f.record {
   Assert-R ([IO.File]::Exists($gate)-and!(Test-Path -LiteralPath $renamed)) 'Gate or rename destination state invalid';$beforeId=[Prunlet.RecordlessE2E.FixtureNative]::Identity($gate);$beforeLength=[IO.FileInfo]::new($gate).Length;$failure=$null
   try{[IO.File]::Move($gate,$renamed)}catch{$failure=$_.Exception;while($failure.InnerException){$failure=$failure.InnerException}}
   $script:observed.gateRename=@{source=$gate;destination=$renamed;failure=$(if($failure){$failure.ToString()}else{$null});hresult=$(if($failure){$failure.HResult}else{$null});id=$beforeId;length=$beforeLength}
   Assert-R ($failure-and(($failure.HResult-band 0xffff)-eq32)) 'External gate rename did not fail with ERROR_SHARING_VIOLATION';Assert-R (!(Test-Path -LiteralPath $renamed)) 'Gate rename destination unexpectedly exists';Assert-R ([IO.File]::Exists($gate)-and[Prunlet.RecordlessE2E.FixtureNative]::Identity($gate)-ceq$beforeId-and[IO.FileInfo]::new($gate).Length-eq$beforeLength) 'Gate identity or length changed while held'
  };$script:observed.migration=$result;$operation=@($result.operations|Where-Object {$_.path-ceq$f.record});Assert-R ($result.registryReady-and$result.complete-and$operation.Count-eq1-and$operation[0].status-ceq'recycled') 'Discard did not complete after denied gate rename';Assert-R (!(Test-Path -LiteralPath $gate)-and!(Test-Path -LiteralPath $renamed)) 'Completed discard left gate or rename target';$null=Assert-BinM $proof
 }
 Case-M 'discard-shell-ready-swapped-identity-remains-uncertain' {
  $f=New-LegacyM 1 'swap-shell-ready';$original=Proof-M $f.record;$parked=Join-Path $f.scope.metadata '.legacy-swap-original';$replacementPath=Join-Path $f.scope.metadata '.legacy-swap-replacement';$null=[IO.Directory]::CreateDirectory($replacementPath);[IO.File]::WriteAllText((Join-Path $replacementPath 'replacement.txt'),'owned replacement fixture',$utf8);$replacement=Proof-M $replacementPath
  Assert-R ($original.before[0].Id-cne$replacement.before[0].Id) 'Replacement must have a distinct native ID';$result=Invoke-SwapHostM $f $original $replacement $parked;$script:observed.migration=$result
  $null=Assert-SnapshotR $parked $original.before;Assert-R (@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($original.before[0].Id)|Where-Object {$_.Pidl-notin$original.prior}).Count-eq0) 'Original was unexpectedly sent to Bin'
  $replacementItems=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($replacement.before[0].Id)|Where-Object {$_.Pidl-notin$replacement.prior});$script:observed.replacementBin=$replacementItems
  if(Test-Path -LiteralPath $f.record){Assert-R ($replacementItems.Count-eq0) 'Replacement exists both at target and in Bin; retained';$after=Assert-SnapshotR $f.record $replacement.before}
  else{
   Assert-R ($replacementItems.Count-eq1) 'Replacement is absent and its Bin identity is missing or ambiguous; retained';$item=$replacementItems[0];$bin=Assert-SnapshotR $item.PhysicalPath $replacement.before -WindowsManagedBin
   $null=[Prunlet.RecordlessE2E.FixtureNative]::RestoreOwned($item.Pidl,$item.PhysicalPath,$replacement.before[0].Id,$f.record,$f.scope.metadata);$after=Assert-SnapshotR $f.record $replacement.before -WindowsManagedRestore
   $beforeByRelative=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);foreach($node in $replacement.before){$beforeByRelative.Add($node.Relative,$node)};$script:observed.replacementRestore=@{item=$item;bin=$bin;restored=$after;securityDiff=@($after|ForEach-Object {$old=$beforeByRelative[$_.Relative];@{relative=$_.Relative;before=$old.SecurityBase64;after=$_.SecurityBase64;equal=($old.SecurityBase64-ceq$_.SecurityBase64)}})}
  }
  $operation=@($result.operations|Where-Object {$_.path-ceq$f.record});Assert-R ($result.registryReady-and!$result.complete-and$operation.Count-eq1-and$operation[0].status-ceq'ambiguous') 'Swapped Shell result did not remain ambiguous'
  $gate=Join-Path $f.scope.metadata '.legacy-file-discard-in-progress';Assert-R ([IO.File]::Exists($gate)-and[IO.FileInfo]::new($gate).Length-eq0) 'Uncertain discard gate not retained';$gateBefore=Snapshot-R $gate;$replacementAfter=Snapshot-R $f.record
  foreach($args in @(@('migrate','--apply'),@('migrate','--apply','--if-needed'))){$blocked=Invoke-R $f.scope $args;Assert-ApplyM $blocked -Partial;Assert-R (!$blocked.json.complete-and($blocked.json.warnings-join' ')-match'(?i)retry-legacy-discard') 'Automatic retry was not blocked';$null=Assert-SnapshotR $gate $gateBefore;$null=Assert-SnapshotR $parked $original.before;$null=Assert-SnapshotR $f.record $replacementAfter}
  foreach($args in @(@('operations'),@('maintain','--apply'))){Assert-R ((Invoke-R $f.scope $args).exitCode-eq0) 'Uncertain file gate blocked registry processing'}
 }
 foreach($phase in @('gate.flushed','shell.returned')){Case-M ('discard-'+$phase+'-crash-blocks-automatic-resend') {
  $f=New-LegacyM 1 ('checkpoint-'+$phase.Replace('.','-'));$proof=Proof-M $f.record;Host-M $f.scope 'Checkpoint' $phase $f.record;$gate=Join-Path $f.scope.metadata '.legacy-file-discard-in-progress'
  Assert-R ([IO.File]::Exists($gate)-and[IO.FileInfo]::new($gate).Length-eq0) 'Actual private empty uncertainty gate was not durable';$gateBefore=Snapshot-R $gate
  if($phase-ceq'gate.flushed'){$null=Assert-SnapshotR $f.record $proof.before;Assert-R (@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($proof.before[0].Id)).Count-eq@($proof.prior).Count) 'Shell dispatched before gate checkpoint'}else{$null=Assert-BinM $proof}
  foreach($blockedArgs in @(@('migrate','--apply'),@('migrate','--apply','--if-needed'))){$blocked=Invoke-R $f.scope $blockedArgs;$script:observed.blocked=$blocked;Assert-ApplyM $blocked -Partial;Assert-R (!$blocked.json.complete-and($blocked.json.warnings-join' ')-match'(?i)retry-legacy-discard') 'Uncertain discard did not require explicit acknowledgement';$null=Assert-SnapshotR $gate $gateBefore}
  if($phase-ceq'gate.flushed'){$null=Assert-SnapshotR $f.record $proof.before}else{Assert-R (!(Test-Path -LiteralPath $f.record)) 'Blocked resume recreated legacy source'}
  foreach($args in @(@('operations'),@('maintain','--apply'))){Assert-R ((Invoke-R $f.scope $args).exitCode-eq0) 'Uncertain file gate blocked registry processing'}
  $acknowledged=Invoke-R $f.scope @('migrate','--apply','--retry-legacy-discard');$script:observed.acknowledged=$acknowledged;Assert-ApplyM $acknowledged;Assert-R (!(Test-Path -LiteralPath $gate)) 'Acknowledged successful discard left its gate';if($phase-ceq'gate.flushed'){$null=Assert-BinM $proof}
  Assert-R (@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($proof.before[0].Id)).Count-eq(@($proof.prior).Count+1)) 'Acknowledged replay duplicated or lost the original root'
 }}
 Case-M 'invalid-discard-gate-is-preserved-even-with-explicit-ack' {
  $f=New-LegacyM 1 'invalid-gate';$gate=Join-Path $f.scope.metadata '.legacy-file-discard-in-progress';[IO.File]::WriteAllText($gate,'not an empty gate',$utf8);Set-PrivateM $gate;$gateBefore=Snapshot-R $gate;$recordBefore=Snapshot-R $f.record
  $invalid=Invoke-R $f.scope @('migrate','--retry-legacy-discard');Assert-R ($invalid.exitCode-ne0) 'Explicit retry acknowledgement was accepted without --apply';$null=Assert-SnapshotR $gate $gateBefore;$null=Assert-SnapshotR $f.record $recordBefore
  foreach($args in @(@('migrate','--apply'),@('migrate','--apply','--retry-legacy-discard'))){$r=Invoke-R $f.scope $args;Assert-ApplyM $r -Partial;Assert-R (!$r.json.complete) 'Invalid gate was accepted';$null=Assert-SnapshotR $gate $gateBefore;$null=Assert-SnapshotR $f.record $recordBefore}
  Assert-R ((Invoke-R $f.scope @('operations')).exitCode-eq0) 'Invalid file gate blocked registry listing'
 }
 Case-M 'unavailable-configured-volume-is-reported-without-fallback' {
  $s=New-ScopeR 'unavailable-volume';$letter=@('Z','Y','X','W','V','U'|Where-Object {!(Test-Path -LiteralPath ($_+':\'))}|Select-Object -First 1);Assert-R ($letter.Count-eq1) 'No unused drive letter available for unavailable-volume model';$settings=Get-Content -LiteralPath $s.config -Raw|ConvertFrom-Json -AsHashtable;$settings.volumeRecoveryDirectories[($letter[0]+':\')]=Join-Path $s.root 'unavailable-store';Save-R $s.config $settings
  $source=File-R $s 'must-remain';$before=Snapshot-R $source;$r=Invoke-R $s @('migrate','--apply');$script:observed.response=$r;$script:observed.environment='Unused drive-letter configuration; no actual volume detach or remount is claimed';Assert-ApplyM $r -Partial;Assert-R (!$r.json.complete-and($r.json.warnings-join' ')-match'(?i)unavailable') 'Unavailable store did not remain explicit';$null=Assert-SnapshotR $source $before
 }
} finally {
 $expectedCatalogCount=28;$selected=@($catalog|Where-Object {$name=$_;@($CaseFilter|Where-Object {$name-like$_}).Count})
 if($catalog.Count-ne$expectedCatalogCount-or$results.Count-ne$selected.Count){$results.Add(@{name='suite-case-count';passed=$false;error='Discard case catalog or execution count mismatch'})}
 $suiteArtifactsAtEnd=Assert-LegacyArtifactPinsM $suiteArtifactPins
 $report=@{suite='explicit-legacy-file-discard';artifactsAtStart=$suiteArtifactsAtStart;artifactsAtEnd=$suiteArtifactsAtEnd;fixtureRun=$script:fixtureRun;legacyRecordFixtureRun=$script:legacyRecordFixtureRun;managementOutputRoot=$OutputDirectory;legacyRecordsAreDisposableFixtureTargets=[bool]$script:legacyRecordFixtureRun;policyVersion=2;producerPins=@($producerPins.Values);legacyProducerBuildRecord=$legacyProducerBuildRecord;moveProducerBuildRecord=$moveProducerBuildRecord;fixtureAuthorityContract='Old runtime schema production and producer origin are separate evidence. Version/path/hash pins identify the bytes used; missing provenance is unverified-origin, not released-binary. Historical source rebuild and retained source-only build are explicitly distinguished. Catalog names beginning genuine-schema are stable case IDs and do not authenticate a distribution. .NET marker fixtures are synthetic ownership models, not historical schema producers.';legacyGuarantee='Owned old roots move directly to Windows Recycle Bin; no bundle, sidecar, copied payload or individual legacy restore guarantee';sources=$initialSources;executablePath=$ExecutablePath;executableSha256=(Get-FileHash -LiteralPath $ExecutablePath).Hash;candidateRuntime='rust';sameSourceBuild=$buildBinding;fixtureHelperAssemblyPath=$AssemblyPath;fixtureHelperAssemblySha256=$assemblyHash;expectedCatalogCount=$expectedCatalogCount;actualCatalogCount=$catalog.Count;selectedExpectedCount=$selected.Count;executedCount=$results.Count;caseFilter=$CaseFilter;excluded=@($excluded);coverage=$(if($excluded.Count){'selected-subset'}else{'full-discard-suite'});passed=@($results|Where-Object passed).Count;failed=@($results|Where-Object {!$_.passed}).Count;results=@($results);commands=@($script:commands);retained=$OutputDirectory;unverified=@('Actual offline volume detach/remount and a second physical volume require a separate real environment; unavailable-drive model and late-created owned root are distinguished.','Registry raw-data/native transaction preservation is verified by the separate registry/native session suites.','Bin entries are intentionally retained as the direct discard output; no legacy file restore helper or ACL sidecar is exercised.')}
 Save-R $ReportPath $report;$env:TEMP=$oldTemp;$env:TMP=$oldTmp
}
} finally {foreach($record in $suiteArtifactPins.records){$record.stream.Dispose()}}
$report|Select-Object passed,failed,expectedCatalogCount,actualCatalogCount,selectedExpectedCount,executedCount|ConvertTo-Json
$script:legacyDiscardFailed=[bool]$report.failed
