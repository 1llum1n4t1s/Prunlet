[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$AssemblyPath,[Parameter(Mandatory)][string]$ExpectedAssemblySha256,[Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop'
# 失敗モデル: Shell未到達、元名の別ID削除、共有拒否を迂回した削除、部分削除の隠蔽、再送、証拠不一致後のfixture加工。
$repo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
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
if((Get-FileHash -LiteralPath $AssemblyPath).Hash -cne $ExpectedAssemblySha256){throw 'Candidate assembly hash mismatch'}
$hostScript=Join-Path $PSScriptRoot 'recordless-e2e/OversizeCheckpointHost.ps1'
$common=Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1'; . $common
$helperFiles=@('NativeShellFixture.cs','FixtureNative.cs','OwnedBinLocator.cs')|ForEach-Object {Join-Path (Join-Path $PSScriptRoot 'recordless-e2e') $_}
$sources=@(@($PSCommandPath,$hostScript,$common,(Join-Path $PSScriptRoot 'recordless-e2e/SparseFixture.cs'))+$helperFiles|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}})
$exeHash=(Get-FileHash -LiteralPath $ExecutablePath).Hash
$null=[IO.Directory]::CreateDirectory($OutputDirectory);$script:temp=Join-Path $OutputDirectory 'temp';$null=[IO.Directory]::CreateDirectory($script:temp)
$oldTemp=$env:TEMP;$oldTmp=$env:TMP;$env:TEMP=$script:temp;$env:TMP=$script:temp
$script:commands=[Collections.Generic.List[object]]::new();$results=[Collections.Generic.List[object]]::new()
try {
 Add-Type -Path $helperFiles -CompilerOptions '/unsafe'
 Add-Type -Path (Join-Path $PSScriptRoot 'recordless-e2e/SparseFixture.cs')
 foreach($mode in @('replace','lock')) {
  $state=@{mode=$mode;passed=$false;cleanupReady=$false;cleanup='retained for external CLI cleanup'};$results.Add($state)
  try {
   $s=New-ScopeR $mode;$target=Join-Path $s.files 'huge-sparse';$moved=Join-Path $s.files 'moved-sparse';$state.scope=$s.root
   $prefix=$utf8.GetBytes('owned sparse prefix; allocated tails must stay zero');$length=[long]1099511627776
   $stream=[IO.FileStream]::new($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
   try {[PrunletSparseE2E]::MakeSparse($stream.SafeFileHandle);$stream.Write($prefix,0,$prefix.Length);$stream.SetLength($length);$stream.Flush($true)} finally {$stream.Dispose()}
   $before=[PrunletSparseE2E]::CaptureProof($target);$state.before=$before
   Assert-R ($before.Length-eq$length-and$before.NumberOfLinks-eq1-and$before.AllocationSize-le1MB-and$before.CompressedSize-le1MB) 'Invalid sparse fixture'
   $prior=[string[]]@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($before.Id)|ForEach-Object Pidl);$state.priorBin=$prior
   $observed=& $hostScript -AssemblyPath $AssemblyPath -ExpectedAssemblySha256 $ExpectedAssemblySha256 -ConfigPath $s.config -TargetPath $target -MovedPath $moved -Mode $mode
   $state.checkpoint=$observed
   Assert-R ($observed.checkpointCount-eq1-and$observed.phase-ceq'oversize-reported') 'Windows size-only checkpoint not reached once'
   $items=@($observed.result.Items);Assert-R ($items.Count-eq1-and$items[0].Path-ceq$target-and$items[0].Status-ceq'ambiguous') 'Expected ambiguous result'
   Assert-R $observed.reportedError 'CLI/MCP shared error predicate accepted the ambiguous result'
   Assert-R ($items[0].Error-match'(?i)permanently deleted'-and$items[0].Error-match'(?i)not retried') 'Partial deletion or no-retry warning missing'
   $sparsePath=if($mode-ceq'replace'){$moved}else{$target};$after=[PrunletSparseE2E]::CaptureProof($sparsePath);$state.after=$after
   foreach($field in @('Id','SecurityBase64','Attributes','Length')){Assert-R ($before.$field-ceq$after.$field) ('Sparse '+$field+' changed')}
   Assert-R ($after.NumberOfLinks-eq1-and$after.AllocationSize-le1MB-and$after.CompressedSize-le1MB) 'Sparse allocation or link count changed'
   $read=[IO.File]::OpenRead($sparsePath);try{$bytes=[byte[]]::new($prefix.Length);$read.ReadExactly($bytes);Assert-R ([Convert]::ToBase64String($bytes)-ceq[Convert]::ToBase64String($prefix)) 'Sparse prefix changed'}finally{$read.Dispose()}
   $newBin=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($before.Id)|Where-Object {$_.Pidl-notin$prior});$state.newBin=$newBin;Assert-R ($newBin.Count-eq0) 'Sparse identity unexpectedly in Bin'
   if($mode-ceq'replace') {
    $replacement=@($observed.replacement);Assert-R ($replacement.Count-eq1-and$replacement[0].Id-cne$before.Id) 'Replacement identity missing or unchanged'
    $null=Assert-SnapshotR $target $replacement
    $replacementBin=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($replacement[0].Id));$state.replacementBin=$replacementBin;Assert-R ($replacementBin.Count-eq0) 'Replacement identity unexpectedly in Bin'
   } else {Assert-R (![IO.File]::Exists($moved)) 'Unexpected moved path'}
   foreach($source in $sources){Assert-R ((Get-FileHash -LiteralPath $source.path).Hash-ceq$source.sha256) 'Verification source changed'}
   Assert-R ((Get-FileHash -LiteralPath $AssemblyPath).Hash-ceq$ExpectedAssemblySha256-and(Get-FileHash -LiteralPath $ExecutablePath).Hash-ceq$exeHash) 'Candidate changed'
   # helperは排他的handle下でID・ACL・属性・長さ・prefix・全割当範囲を確認し、範囲外のデータを壊さない場合だけ縮小する。
   $tiny=[PrunletSparseE2E]::RestoreTiny($sparsePath,$before.Id,$before.SecurityBase64,[int]$before.Attributes,$length,$prefix,[ulong]1048576);$state.finalizer=$tiny
   Assert-R $tiny.Success ('Sparse retained: '+$tiny.Error)
   $finalProof=[PrunletSparseE2E]::CaptureProof($sparsePath);$state.finalProof=$finalProof
   foreach($field in @('Id','SecurityBase64','Attributes')){Assert-R ($before.$field-ceq$finalProof.$field) ('Final sparse '+$field+' changed')}
   Assert-R ($finalProof.Length-eq$prefix.Length-and$finalProof.NumberOfLinks-eq1-and$finalProof.AllocationSize-le1MB-and$finalProof.CompressedSize-le1MB) 'Final sparse state changed'
   $read=[IO.File]::OpenRead($sparsePath);try{$bytes=[byte[]]::new($prefix.Length);$read.ReadExactly($bytes);Assert-R ([Convert]::ToBase64String($bytes)-ceq[Convert]::ToBase64String($prefix)) 'Final sparse prefix changed'}finally{$read.Dispose()}
   $finalBin=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($before.Id)|Where-Object {$_.Pidl-notin$prior});$state.finalBin=$finalBin;Assert-R ($finalBin.Count-eq0) 'Final sparse identity unexpectedly in Bin'
   $cleanupPaths=@($sparsePath);$cleanupTargets=@(@{path=$sparsePath;id=$before.Id;state=$finalProof})
   if($mode-ceq'replace'){
    $replacementFinal=Assert-SnapshotR $target $replacement
    $finalReplacementBin=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($replacement[0].Id));$state.finalReplacementBin=$finalReplacementBin;Assert-R ($finalReplacementBin.Count-eq0) 'Final replacement identity unexpectedly in Bin'
    $cleanupPaths+=@($target);$cleanupTargets+=@(@{path=$target;id=$replacement[0].Id;state=$replacementFinal})
   }
   $pathFile=Join-Path $s.root 'cleanup-paths.json'
   $json=ConvertTo-Json -InputObject ([string[]]$cleanupPaths) -Compress
   $pathBytes=$utf8.GetBytes($json);$pathStream=[IO.FileStream]::new($pathFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
   try{$pathStream.Write($pathBytes,0,$pathBytes.Length);$pathStream.Flush($true)}finally{$pathStream.Dispose()}
   $state.cleanupPathFile=$pathFile;$state.cleanupTargets=$cleanupTargets;$state.cleanupReady=$true
   $state.passed=$true
  } catch {$state.error=$_.Exception.ToString();$state.stack=$_.ScriptStackTrace}
 }
} finally {
 $report=@{suite='oversize-race';assembly=$AssemblyPath;assemblySha256=$ExpectedAssemblySha256;executable=$ExecutablePath;executableSha256=$exeHash;sources=$sources;results=@($results);passed=@($results|Where-Object passed).Count;failed=@($results|Where-Object {!$_.passed}).Count;commands=@($script:commands);retained=$OutputDirectory}
 try {
  $reportBytes=$utf8.GetBytes((ConvertTo-Json -InputObject $report -Depth 100));$reportStream=[IO.FileStream]::new($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$reportStream.Write($reportBytes,0,$reportBytes.Length);$reportStream.Flush($true)}finally{$reportStream.Dispose()}
 } finally {$env:TEMP=$oldTemp;$env:TMP=$oldTmp}
}
if($results.Count-ne2-or@($results|Where-Object {!$_.passed}).Count){throw 'Oversize race verification incomplete; inspect report and retain uncertain fixtures'}
