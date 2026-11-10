# 固定した同buildのRust migrationだけを中断する。.NET補助は所有marker生成に限定する。
function Open-LegacyArtifactPinsM {
 $records=[Collections.Generic.List[object]]::new()
 try{
  foreach($item in @(@{path=$ExecutablePath;expected=$buildBinding.candidateSha256},@{path=$RustProbePath;expected=$buildBinding.probeSha256},@{path=$BuildManifestPath;expected=$buildBinding.manifestSha256})){
   $stream=[IO.File]::Open($item.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
   $records.Add(@{path=$item.path;expected=$item.expected;stream=$stream})
  }
  $pins=@{records=$records};$null=Assert-LegacyArtifactPinsM $pins;return $pins
 }catch{foreach($record in $records){$record.stream.Dispose()};throw}
}
function Assert-LegacyArtifactPinsM($Pins) {
 $observed=@(foreach($record in $Pins.records){
  $record.stream.Position=0;$hash=(Get-FileHash -InputStream $record.stream -Algorithm SHA256).Hash
  if(!$hash.Equals($record.expected,[StringComparison]::OrdinalIgnoreCase)-or!(Get-FileHash -LiteralPath $record.path -Algorithm SHA256).Hash.Equals($record.expected,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixed migration product/probe/build-manifest changed before execution or checkpoint.'}
  @{path=$record.path;sha256=$hash}
 })
 return ,$observed
}
function Start-LegacyRustM($Scope,[string]$Action,[string]$Phase,[string]$Target) {
 if((Get-RustFileSourceFingerprint $repo)-cne$buildBinding.sourceFingerprint){throw 'Rust migration source changed; rebuild product and probe.'}
 $pins=Open-LegacyArtifactPinsM
 $child=$null
 try{
 $token=[guid]::NewGuid().ToString('N');$signal=Join-Path $Scope.root ('discard-'+$token+'.signal');$result=Join-Path $Scope.root ('discard-'+$token+'.result.json')
 $script:Config=$Scope.config
 $info=New-RustProbeStartInfo $RustProbePath 'legacy_discard' @{action=$Action;checkpoint=$Phase;fixtureRoot=$Target;signalPath=$signal;resultPath=$result} $Scope.root
 $atStart=Assert-LegacyArtifactPinsM $pins
 $child=[Diagnostics.Process]::Start($info)
 return @{artifactPins=$pins;artifactsAtStart=$atStart;artifactsAtCheckpoint=$null;child=$child;stderr=$child.StandardError.ReadToEndAsync();stdout=$null;signal=$signal;result=$result;scope=$Scope;prefix=[Collections.Generic.List[string]]::new()}
 }catch{
  if($child){if(!$child.HasExited){$child.Kill($true);$child.WaitForExit()};$child.Dispose()}
  foreach($record in $pins.records){$record.stream.Dispose()};throw
 }
}
function Wait-LegacyRustCheckpointM($Run,[string]$Phase,[string]$Target) {
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($true){
  $line=$Run.child.StandardOutput.ReadLineAsync();$remaining=[Math]::Max(1,60000-[int]$clock.ElapsedMilliseconds)
  if(!$line.Wait($remaining)){throw 'Rust legacy migration checkpoint notification timed out.'}
  $text=$line.GetAwaiter().GetResult();if($null-eq$text){throw ('Rust migration ended before checkpoint: '+$Run.stderr.GetAwaiter().GetResult())}
  $Run.prefix.Add($text);if($text.Contains('PRUNLET_LEGACY_DISCARD_CHECKPOINT')){break}
  if($clock.ElapsedMilliseconds-ge60000){throw 'Rust migration did not reach selected checkpoint.'}
 }
 $Run.artifactsAtCheckpoint=Assert-LegacyArtifactPinsM $Run.artifactPins
 $lines=[IO.File]::ReadAllLines($Run.signal)
 Assert-R ($lines.Count-eq3-and$lines[0]-ceq$Phase-and$lines[1]-ceq$Target-and[int]$lines[2]-eq$Run.child.Id) 'Rust checkpoint signal phase/path/PID binding differs'
 $Run.stdout=$Run.child.StandardOutput.ReadToEndAsync()
}
function Complete-LegacyRustM($Run) {
 $event=[Threading.EventWaitHandle]::OpenExisting('Local\PrunletLegacyDiscard-'+$Run.child.Id)
 try{$null=$event.Set()}finally{$event.Dispose()}
 Assert-R ($Run.child.WaitForExit(60000)) 'Rust migration did not complete after continuation'
 Assert-R ($Run.child.ExitCode-eq0) ('Rust migration probe failed: '+$Run.stderr.GetAwaiter().GetResult())
 $envelope=Get-Content -LiteralPath $Run.result -Raw|ConvertFrom-Json -AsHashtable -Depth 100
 Assert-R ($envelope.runtime-ceq'rust-libtest'-and$envelope.nativeFileProbe-and!$envelope.realNativeScopeVerified-and$envelope.candidateSha256-eq$buildBinding.candidateSha256-and$envelope.probeSha256-eq$buildBinding.probeSha256) 'Rust migration result runtime/build binding differs'
 return $envelope.result
}
function Close-LegacyRustM($Run) {
 if(!$Run.child.HasExited){$Run.child.Kill($true);$Run.child.WaitForExit()}
 if(!$Run.stdout){$Run.stdout=$Run.child.StandardOutput.ReadToEndAsync()}
 try{Save-R ($Run.signal+'.process.json') @{runtime='rust-libtest';sameSourceBuild=$buildBinding;artifactsAtStart=$Run.artifactsAtStart;artifactsAtCheckpoint=$Run.artifactsAtCheckpoint;pid=$Run.child.Id;exitCode=$Run.child.ExitCode;stdout=($Run.prefix-join"`n")+"`n"+$Run.stdout.GetAwaiter().GetResult();stderr=$Run.stderr.GetAwaiter().GetResult()}}finally{$Run.child.Dispose();foreach($record in $Run.artifactPins.records){$record.stream.Dispose()}}
}
