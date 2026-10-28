[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$AssemblyPath,[Parameter(Mandatory)][string]$ExpectedAssemblySha256,[Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop'
# 失敗モデル: Shell直前に元名を別IDへ差し替えた後、別実体が移動される、結果が実体と食い違う、証拠不一致後に処分する。
$repo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent));. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach($p in @($ExecutablePath,$AssemblyPath,$OutputDirectory,$ReportPath)){if(![IO.Path]::IsPathFullyQualified($p)){throw 'Absolute paths required'}}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory);$ReportPath=[IO.Path]::GetFullPath($ReportPath)
foreach($p in @($OutputDirectory,$ReportPath)){
 if(![IO.Path]::GetPathRoot($p).Equals('D:\',[StringComparison]::OrdinalIgnoreCase)){throw 'External D output required'}
 if(@($p.Split('\')|Where-Object {$_ -ieq 'artifacts'}).Count){throw 'Output must not use an artifacts directory'}
 Assert-VerificationDestination $p @($repo,(Join-Path $env:USERPROFILE '.codex'))
 if(Test-Path -LiteralPath $p){throw 'Unused output and report required'}
 if(![IO.Directory]::Exists([IO.Path]::GetDirectoryName($p))){throw 'Existing parent required'}
}
if(!(Test-Path -LiteralPath $ExecutablePath -PathType Leaf)-or!(Test-Path -LiteralPath $AssemblyPath -PathType Leaf)){throw 'Candidate exe and assembly required'}
if((Get-FileHash -LiteralPath $AssemblyPath).Hash-cne$ExpectedAssemblySha256){throw 'Candidate assembly hash mismatch'}
$hostScript=Join-Path $PSScriptRoot 'recordless-e2e/BeforeRecycleCheckpointHost.ps1';$common=Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1';. $common
$helperFiles=@('NativeShellFixture.cs','FixtureNative.cs','OwnedBinLocator.cs')|ForEach-Object {Join-Path (Join-Path $PSScriptRoot 'recordless-e2e') $_}
$sources=@(@($PSCommandPath,$hostScript,$common)+$helperFiles|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}});$exeHash=(Get-FileHash -LiteralPath $ExecutablePath).Hash
$null=[IO.Directory]::CreateDirectory($OutputDirectory);$script:temp=Join-Path $OutputDirectory 'temp';$null=[IO.Directory]::CreateDirectory($script:temp)
$oldTemp=$env:TEMP;$oldTmp=$env:TMP;$env:TEMP=$script:temp;$env:TMP=$script:temp
$script:commands=[Collections.Generic.List[object]]::new();$script:observed=@{}
$state=@{passed=$false;evidenceVerified=$false;cleanupReady=$false;boundary='Small-file Windows Shell and Core internal checkpoint; not a CLI or MCP process test';cleanup='retained for external CLI cleanup'}
try {
 Add-Type -Path $helperFiles -CompilerOptions '/unsafe'
 $s=New-ScopeR 'before-recycle-small';$state.scope=$s.root;$target=Join-Path $s.files 'original-small';$moved=Join-Path $s.files 'moved-original';$evidence=Join-Path $s.root 'checkpoint-evidence.json';$state.evidencePath=$evidence
 $originalBytes=$utf8.GetBytes('before-recycle original small fixture')
 $file=[IO.FileStream]::new($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$file.Write($originalBytes,0,$originalBytes.Length);$file.Flush($true)}finally{$file.Dispose()}
 $original=@(Snapshot-R $target);Assert-R ($original.Count-eq1-and!$original[0].Directory) 'Original fixture snapshot invalid';$state.originalBefore=$original
 $originalPrior=[string[]]@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($original[0].Id)|ForEach-Object Pidl);$state.originalPriorBin=$originalPrior
 $observed=$null
 try{$observed=& $hostScript -AssemblyPath $AssemblyPath -ExpectedAssemblySha256 $ExpectedAssemblySha256 -ConfigPath $s.config -TargetPath $target -MovedPath $moved -EvidencePath $evidence;$state.checkpoint=$observed}
 catch{$state.hostError=$_.Exception.ToString();$state.hostStack=$_.ScriptStackTrace}
 Assert-R ([IO.File]::Exists($evidence)) 'Checkpoint evidence missing; fixtures retained'
 $checkpoint=[IO.File]::ReadAllText($evidence)|ConvertFrom-Json -Depth 100;$state.checkpointEvidence=$checkpoint
 Assert-R ($checkpoint.phase-ceq'before-recycle'-and$checkpoint.path-ceq$target-and$checkpoint.moved-ceq$moved) 'Checkpoint evidence does not identify this scope'
 $replacement=@($checkpoint.replacement);Assert-R ($replacement.Count-eq1-and!$replacement[0].Directory-and$replacement[0].Id-cne$original[0].Id) 'Replacement identity missing or unchanged'
 # checkpoint時に元名へ作成したファイルは同一volume上で生存しており、そのIDは既存Bin実体と共存できない。
 $fixtures=@(@{name='original';path=$moved;before=$original;prior=$originalPrior},@{name='replacement';path=$target;before=$replacement;prior=[string[]]@()})
 $state.fixtures=$fixtures;$state.shellProcessed=@()
 foreach($fixture in $fixtures){
  $id=$fixture.before[0].Id;$fixture.id=$id;$fixture.presentBeforeRestore=[IO.File]::Exists($fixture.path)
  $fixture.newBin=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($id)|Where-Object {$_.Pidl-notin$fixture.prior})
  Assert-R (($fixture.newBin.Count-eq0-and$fixture.presentBeforeRestore)-or($fixture.newBin.Count-eq1-and!$fixture.presentBeforeRestore)) ($fixture.name+' location ambiguous; retained')
  if($fixture.newBin.Count-eq1){
   $item=$fixture.newBin[0];$state.shellProcessed+=@($fixture.name)
   $fixture.binSnapshot=Assert-SnapshotR $item.PhysicalPath $fixture.before -WindowsManagedBin
   $null=[Prunlet.RecordlessE2E.FixtureNative]::RestoreOwned($item.Pidl,$item.PhysicalPath,$id,$fixture.path,$s.files);$fixture.restored=$true
  }else{$fixture.restored=$false}
  if($fixture.restored){
   # Windows復元では継承状態を変更し得るため、内容・ID・属性の照合とACL差分を別々に記録する。
   $fixture.final=Assert-SnapshotR $fixture.path $fixture.before -WindowsManagedRestore
   $fixture.restoredAcl=@{before=$fixture.before[0].SecurityBase64;after=$fixture.final[0].SecurityBase64;exact=($fixture.before[0].SecurityBase64-ceq$fixture.final[0].SecurityBase64)}
  }else{$fixture.final=Assert-SnapshotR $fixture.path $fixture.before}
  $fixture.finalBin=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($id)|Where-Object {$_.Pidl-notin$fixture.prior})
  Assert-R ($fixture.finalBin.Count-eq0) ($fixture.name+' Bin entry remains after reconciliation')
 }
 foreach($source in $sources){Assert-R ((Get-FileHash -LiteralPath $source.path).Hash-ceq$source.sha256) 'Verification source changed'}
 Assert-R ((Get-FileHash -LiteralPath $AssemblyPath).Hash-ceq$ExpectedAssemblySha256-and(Get-FileHash -LiteralPath $ExecutablePath).Hash-ceq$exeHash) 'Candidate changed'
 # 両実体の全stream・ID・ACL・属性を再照合した場合だけ、親が処分する入力を用意する。
 foreach($fixture in $fixtures){
  if($fixture.restored){
   $current=Assert-SnapshotR $fixture.path $fixture.before -WindowsManagedRestore
   Assert-R ($current[0].SecurityBase64-ceq$fixture.restoredAcl.after) ($fixture.name+' ACL changed after restoration')
   $fixture.final=$current
  }else{$fixture.final=Assert-SnapshotR $fixture.path $fixture.before}
  $fixture.finalBin=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($fixture.id)|Where-Object {$_.Pidl-notin$fixture.prior});Assert-R ($fixture.finalBin.Count-eq0) ($fixture.name+' final Bin state changed')
 }
 $paths=[string[]]@($moved,$target);$pathFile=Join-Path $s.root 'cleanup-paths.json';$bytes=$utf8.GetBytes((ConvertTo-Json -InputObject $paths -Compress))
 $file=[IO.FileStream]::new($pathFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
 $state.cleanupPathFile=$pathFile;$state.cleanupTargets=@($fixtures|ForEach-Object {@{path=$_.path;id=$_.id;state=$_.final}});$state.cleanupReady=$true
 Assert-R ($null-ne$observed-and$observed.checkpointCount-eq1) 'Core returned no confirmed checkpoint result'
 $items=@($observed.result.Items);Assert-R ($items.Count-eq1-and$items[0].Path-ceq$target) 'Core returned unexpected result'
 $state.status=$items[0].Status;$state.reportedError=$observed.reportedError
 $state.successOnReplacement=($items[0].Status-ceq'recycled'-and'replacement'-in$state.shellProcessed)
 $state.replacementMoved=('replacement'-in$state.shellProcessed)
 $state.shellSideEffect=if($state.replacementMoved){'Windows Shell moved the replacement fixture; this side effect was not prevented and the fixture was restored by ID.'}else{'No replacement fixture move was observed.'}
 $state.evidenceVerified=$true
 Assert-R ($items[0].Status-ceq'ambiguous'-and$observed.reportedError) 'Core did not report the changed Shell source as ambiguous and non-success'
 $state.passed=$true
} catch {$state.error=$_.Exception.ToString();$state.stack=$_.ScriptStackTrace}
finally {
 $report=@{suite='before-recycle-small-race';assembly=$AssemblyPath;assemblySha256=$ExpectedAssemblySha256;executable=$ExecutablePath;executableSha256=$exeHash;sources=$sources;result=$state;commands=@($script:commands);retained=$OutputDirectory}
 try{$bytes=$utf8.GetBytes((ConvertTo-Json -InputObject $report -Depth 100));$file=[IO.FileStream]::new($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}}
 finally{$env:TEMP=$oldTemp;$env:TMP=$oldTmp}
}
if(!$state.passed){throw 'Small-file race failed or evidence incomplete; inspect report and retain uncertain fixtures'}
