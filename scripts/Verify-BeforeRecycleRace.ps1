[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$AssemblyPath,[Parameter(Mandatory)][string]$ExpectedAssemblySha256,[Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop'
# 失敗モデル: Shell直前の名前差し替えによる別IDの移動、誤成功、元実体の損傷、証拠不一致後の処分。
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
$sources=@(@($PSCommandPath,$hostScript,$common,(Join-Path $PSScriptRoot 'recordless-e2e/SparseFixture.cs'))+$helperFiles|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}})
$exeHash=(Get-FileHash -LiteralPath $ExecutablePath).Hash
$null=[IO.Directory]::CreateDirectory($OutputDirectory);$script:temp=Join-Path $OutputDirectory 'temp';$null=[IO.Directory]::CreateDirectory($script:temp)
$oldTemp=$env:TEMP;$oldTmp=$env:TMP;$env:TEMP=$script:temp;$env:TMP=$script:temp
$script:commands=[Collections.Generic.List[object]]::new();$script:observed=@{}
$state=@{passed=$false;cleanupReady=$false;boundary='Windows Shell and Core internal checkpoint; not a CLI or MCP process test';cleanup='retained for external CLI cleanup'}
try {
 Add-Type -Path $helperFiles -CompilerOptions '/unsafe'
 Add-Type -Path (Join-Path $PSScriptRoot 'recordless-e2e/SparseFixture.cs')
 $s=New-ScopeR 'before-recycle';$state.scope=$s.root;$target=Join-Path $s.files 'huge-sparse';$moved=Join-Path $s.files 'moved-sparse';$evidence=Join-Path $s.root 'checkpoint-evidence.json';$state.evidencePath=$evidence
 $prefix=$utf8.GetBytes('owned sparse prefix; allocated tails must stay zero');$length=[long]1099511627776
 $stream=[IO.FileStream]::new($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{[PrunletSparseE2E]::MakeSparse($stream.SafeFileHandle);$stream.Write($prefix,0,$prefix.Length);$stream.SetLength($length);$stream.Flush($true)}finally{$stream.Dispose()}
 $before=[PrunletSparseE2E]::CaptureProof($target);$state.before=$before
 Assert-R ($before.Length-eq$length-and$before.NumberOfLinks-eq1-and$before.AllocationSize-le1MB-and$before.CompressedSize-le1MB) 'Invalid sparse fixture'
 $prior=[string[]]@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($before.Id)|ForEach-Object Pidl);$state.priorBin=$prior
 $observed=$null
 try{$observed=& $hostScript -AssemblyPath $AssemblyPath -ExpectedAssemblySha256 $ExpectedAssemblySha256 -ConfigPath $s.config -TargetPath $target -MovedPath $moved -EvidencePath $evidence;$state.checkpoint=$observed}
 catch{$state.hostError=$_.Exception.ToString();$state.hostStack=$_.ScriptStackTrace}
 Assert-R ([IO.File]::Exists($evidence)) 'Checkpoint evidence missing; fixtures retained'
 $checkpoint=[IO.File]::ReadAllText($evidence)|ConvertFrom-Json -Depth 100;$state.checkpointEvidence=$checkpoint
 Assert-R ($checkpoint.phase-ceq'before-recycle'-and$checkpoint.path-ceq$target-and$checkpoint.moved-ceq$moved) 'Checkpoint evidence does not identify this scope'
 $replacement=@($checkpoint.replacement);Assert-R ($replacement.Count-eq1-and$replacement[0].Id-cne$before.Id) 'Replacement identity missing or unchanged'
 $replacementBin=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($replacement[0].Id));$state.replacementBinBeforeRestore=$replacementBin
 $atSource=[IO.File]::Exists($target);$state.replacementAtSource=$atSource
 Assert-R (($replacementBin.Count-eq0-and$atSource)-or($replacementBin.Count-eq1-and!$atSource)) 'Replacement location ambiguous; retained'
 if($replacementBin.Count-eq1){
  $item=$replacementBin[0];$state.shellOutcome='replacement-recycled'
  $state.binSnapshot=Assert-SnapshotR $item.PhysicalPath $replacement -WindowsManagedBin
  $null=[Prunlet.RecordlessE2E.FixtureNative]::RestoreOwned($item.Pidl,$item.PhysicalPath,$replacement[0].Id,$target,$s.files)
  $state.restored=$true
 }else{$state.shellOutcome='replacement-remains-at-source'}
 $replacementFinal=Assert-SnapshotR $target $replacement;$state.replacementFinal=$replacementFinal
 $replacementBinAfter=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($replacement[0].Id));$state.replacementBinAfterRestore=$replacementBinAfter
 Assert-R ($replacementBinAfter.Count-eq0) 'Replacement Bin entry remains after reconciliation'
 $after=[PrunletSparseE2E]::CaptureProof($moved);$state.after=$after
 foreach($field in @('Id','SecurityBase64','Attributes','Length')){Assert-R ($before.$field-ceq$after.$field) ('Sparse '+$field+' changed')}
 Assert-R ($after.NumberOfLinks-eq1-and$after.AllocationSize-le1MB-and$after.CompressedSize-le1MB) 'Sparse allocation or link count changed'
 $read=[IO.File]::OpenRead($moved);try{$bytes=[byte[]]::new($prefix.Length);$read.ReadExactly($bytes);Assert-R ([Convert]::ToBase64String($bytes)-ceq[Convert]::ToBase64String($prefix)) 'Sparse prefix changed'}finally{$read.Dispose()}
 $newBin=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($before.Id)|Where-Object {$_.Pidl-notin$prior});$state.newBin=$newBin;Assert-R ($newBin.Count-eq0) 'Sparse identity unexpectedly in Bin'
 foreach($source in $sources){Assert-R ((Get-FileHash -LiteralPath $source.path).Hash-ceq$source.sha256) 'Verification source changed'}
 Assert-R ((Get-FileHash -LiteralPath $AssemblyPath).Hash-ceq$ExpectedAssemblySha256-and(Get-FileHash -LiteralPath $ExecutablePath).Hash-ceq$exeHash) 'Candidate changed'
 # RestoreTinyは固定handleの全証拠と割当範囲を検査し、確認できた場合だけ縮小する。
 $tiny=[PrunletSparseE2E]::RestoreTiny($moved,$before.Id,$before.SecurityBase64,[int]$before.Attributes,$length,$prefix,[ulong]1048576);$state.finalizer=$tiny
 Assert-R $tiny.Success ('Sparse retained: '+$tiny.Error)
 $finalProof=[PrunletSparseE2E]::CaptureProof($moved);$state.finalProof=$finalProof
 foreach($field in @('Id','SecurityBase64','Attributes')){Assert-R ($before.$field-ceq$finalProof.$field) ('Final sparse '+$field+' changed')}
 Assert-R ($finalProof.Length-eq$prefix.Length-and$finalProof.NumberOfLinks-eq1-and$finalProof.AllocationSize-le1MB-and$finalProof.CompressedSize-le1MB) 'Final sparse state changed'
 $read=[IO.File]::OpenRead($moved);try{$bytes=[byte[]]::new($prefix.Length);$read.ReadExactly($bytes);Assert-R ([Convert]::ToBase64String($bytes)-ceq[Convert]::ToBase64String($prefix)) 'Final sparse prefix changed'}finally{$read.Dispose()}
 $state.finalBin=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($before.Id)|Where-Object {$_.Pidl-notin$prior});Assert-R ($state.finalBin.Count-eq0) 'Final sparse unexpectedly in Bin'
 $replacementFinal=Assert-SnapshotR $target $replacement
 $state.finalReplacementBin=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($replacement[0].Id));Assert-R ($state.finalReplacementBin.Count-eq0) 'Final replacement unexpectedly in Bin'
 $paths=[string[]]@($moved,$target);$pathFile=Join-Path $s.root 'cleanup-paths.json';$bytes=$utf8.GetBytes((ConvertTo-Json -InputObject $paths -Compress))
 $file=[IO.FileStream]::new($pathFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
 $state.cleanupPathFile=$pathFile;$state.cleanupTargets=@(@{path=$moved;id=$before.Id;state=$finalProof},@{path=$target;id=$replacement[0].Id;state=$replacementFinal});$state.cleanupReady=$true
 Assert-R ($null-ne$observed-and$observed.checkpointCount-eq1) 'Core returned no confirmed checkpoint result'
 $items=@($observed.result.Items);Assert-R ($items.Count-eq1-and$items[0].Path-ceq$target) 'Core returned unexpected result';$state.status=$items[0].Status
 Assert-R ($state.shellOutcome-ceq'replacement-remains-at-source'-and$items[0].Status-ceq'ambiguous'-and$observed.reportedError) 'Replacement was processed or Core accepted the uncertain result'
 $state.passed=$true
} catch {$state.error=$_.Exception.ToString();$state.stack=$_.ScriptStackTrace}
finally {
 $report=@{suite='before-recycle-race';assembly=$AssemblyPath;assemblySha256=$ExpectedAssemblySha256;executable=$ExecutablePath;executableSha256=$exeHash;sources=$sources;result=$state;commands=@($script:commands);retained=$OutputDirectory}
 try {$bytes=$utf8.GetBytes((ConvertTo-Json -InputObject $report -Depth 100));$file=[IO.FileStream]::new($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}}
 finally {$env:TEMP=$oldTemp;$env:TMP=$oldTmp}
}
if(!$state.passed){throw 'Before-recycle race verification failed; inspect report and retain uncertain fixtures'}
