[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$ExecutablePath,
 [Parameter(Mandatory)][string]$RustProbePath,
 [Parameter(Mandatory)][string]$BuildManifestPath,
 [Parameter(Mandatory)][string]$ExpectedBuildManifestSha256,
 [Parameter(Mandatory)][string]$OutputDirectory,
 [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$codexRoot=if($env:CODEX_HOME){[IO.Path]::GetFullPath($env:CODEX_HOME)}else{Join-Path $env:USERPROFILE '.codex'}
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
. (Join-Path $PSScriptRoot 'FixtureBridge.Common.ps1')
. (Join-Path $PSScriptRoot 'FileFixtures.Common.ps1')
. (Join-Path $PSScriptRoot 'recordless-e2e/RustFileProbe.Common.ps1')
foreach($path in @($ExecutablePath,$RustProbePath,$BuildManifestPath,$OutputDirectory,$ReportPath)){
 if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute paths are required.'}
}
foreach($path in @($OutputDirectory,$ReportPath)){
 Assert-VerificationDestination $path @($repo,$codexRoot)
 Assert-ExternalVerificationPath $path @($repo,$codexRoot)
 if((Test-Path -LiteralPath $path)-or![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))){throw 'New external output and report with existing parents are required.'}
}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory);$ReportPath=[IO.Path]::GetFullPath($ReportPath)
if($ReportPath.Equals($OutputDirectory,[StringComparison]::OrdinalIgnoreCase)-or$ReportPath.StartsWith($OutputDirectory.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Report must be outside the output directory.'}
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$environmentTemp=Join-Path $OutputDirectory 'temp';$null=[IO.Directory]::CreateDirectory($environmentTemp)
$oldTemp=$env:TEMP;$oldTmp=$env:TMP;$env:TEMP=$environmentTemp;$env:TMP=$environmentTemp
$pins=[Collections.Generic.List[IDisposable]]::new()
try {
$binding=Assert-RustFileProbeBinding
$null=Initialize-PrunletFixtureBinding -ExecutablePath $ExecutablePath -BuildManifestPath $BuildManifestPath -ExpectedBuildManifestSha256 $ExpectedBuildManifestSha256 -SourceRoot $repo
try {
 foreach($path in @($ExecutablePath,$RustProbePath,$BuildManifestPath)+@(Get-PrunletRustInputNames $repo|ForEach-Object {Join-Path $repo $_})){
  $pins.Add([IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
 }
 if((Get-RustFileSourceFingerprint $repo)-cne$binding.sourceFingerprint-or(Get-FileHash -LiteralPath $ExecutablePath).Hash.ToLowerInvariant()-cne$binding.candidateSha256-or(Get-FileHash -LiteralPath $RustProbePath).Hash.ToLowerInvariant()-cne$binding.probeSha256-or(Get-FileHash -LiteralPath $BuildManifestPath).Hash-ine$binding.manifestSha256){throw 'Prepared candidate, probe, manifest or source changed while pinning.'}
}catch{foreach($pin in $pins){$pin.Dispose()};throw}
$utf8=[Text.UTF8Encoding]::new($false);$results=[Collections.Generic.List[object]]::new()
function Assert-True([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
function Save-Json([string]$Path,$Value){[IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Value -Depth 80),$utf8)}
function Start-Child([string[]]$Arguments){
 $info=[Diagnostics.ProcessStartInfo]::new($ExecutablePath);$info.UseShellExecute=$false;$info.CreateNoWindow=$true
 $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 $info.StandardInputEncoding=$utf8;$info.StandardOutputEncoding=$utf8;$info.StandardErrorEncoding=$utf8
 $info.Environment['TEMP']=$script:Temp;$info.Environment['TMP']=$script:Temp
 foreach($arg in @('--config',$script:Config)+$Arguments){$info.ArgumentList.Add($arg)}
 $p=[Diagnostics.Process]::Start($info);$session=@{Process=$p;Out=$p.StandardOutput.ReadToEndAsync();FirstErr=$p.StandardError.ReadLineAsync()}
 $script:Sessions.Add($session);return $session
}
function Complete-Child($Session){
 $p=$Session.Process;$p.StandardInput.Close()
 if(!$p.WaitForExit(120000)){throw 'Owned process timed out; do not resend its request.'}
 $out=$Session.Out.GetAwaiter().GetResult();$first=$Session.FirstErr.GetAwaiter().GetResult();$err=$(if($null-ne$first){$first+[Environment]::NewLine}else{''})+$p.StandardError.ReadToEnd()
 $Session.Completed=@{pid=$p.Id;exitCode=$p.ExitCode;stdout=$out;stderr=$err;json=$(if($out.Trim()){$out|ConvertFrom-Json -AsHashtable -Depth 80}else{$null})}
 return $Session.Completed
}
function Start-Delete([string]$Path,[bool]$Recursive){
 $list=Join-Path $script:CaseRoot ('paths-'+[guid]::NewGuid().ToString('N')+'.json');Save-Json $list @($Path)
 $args=@('delete');if($Recursive){$args+='--recursive'};Start-Child ($args+@('--paths-file',$list))
}
function Assert-Deleted($Result,[string]$Path){
 Assert-True ($Result.exitCode-eq0-and$Result.json.items.Count-eq1-and$Result.json.items[0].path-ceq$Path-and$Result.json.items[0].status-cin@('recycled','permanently_deleted')-and![IO.File]::Exists($Path)-and![IO.Directory]::Exists($Path)) ('Shipping CLI did not confirm deletion of the expected target: '+$Result.stderr+' '+$Result.stdout)
}
function Start-Claim([string]$Path){
 $signal=Join-Path $script:CaseRoot 'claim-ready.txt';$result=Join-Path $script:CaseRoot 'claim-result.json'
 $request=@{fixtureRoot=$Path;signalPath=$signal;resultPath=$result;configSha256=(Get-FileHash -LiteralPath $script:Config -Algorithm SHA256).Hash}
 $info=New-RustProbeStartInfo $RustProbePath 'files_contract' $request $script:CaseRoot
 # 共通request固定処理をそのまま使い、選択するtest名だけを限定変更する。
 $info.ArgumentList[1]='verification::coordination_hold';$info.RedirectStandardInput=$true
 $p=[Diagnostics.Process]::Start($info);$stderr=$p.StandardError.ReadToEndAsync();$lines=[Collections.Generic.List[string]]::new()
 $claim=@{Process=$p;Err=$stderr;Lines=$lines;Released=$false;Result=$result}
 $script:Claims.Add($claim)
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($clock.ElapsedMilliseconds-lt30000){
  $remaining=30000-[int]$clock.ElapsedMilliseconds;$read=$p.StandardOutput.ReadLineAsync()
  if(!$read.Wait($remaining)){throw 'Claim probe readiness timed out.'}
  $line=$read.GetAwaiter().GetResult();if($null-eq$line){throw 'Claim probe exited before readiness.'}
  $lines.Add($line);if($line.Contains('PRUNLET_COORDINATION_HELD ')){break}
 }
 Assert-True ([IO.File]::Exists($signal)) 'Claim ready signal missing.'
 $proof=[IO.File]::ReadAllLines($signal);Assert-True ($proof.Count-eq2-and[int]$proof[0]-eq$p.Id-and$proof[1]-ceq$Path) 'Claim signal does not identify the owned process and target.'
 return $claim
}
function Release-Claim($Claim){
 if($Claim.Released){throw 'Claim release was already attempted.'}
 $Claim.Released=$true;$Claim.Process.StandardInput.WriteLine('release');$Claim.Process.StandardInput.Close()
 if(!$Claim.Process.WaitForExit(30000)){throw 'Claim release did not complete.'}
 $tail=$Claim.Process.StandardOutput.ReadToEnd();$err=$Claim.Err.GetAwaiter().GetResult()
 $Claim.FinalStdout=($Claim.Lines -join "`n")+"`n"+$tail;$Claim.FinalStderr=$err
 Assert-True ($Claim.Process.ExitCode-eq0-and[IO.File]::Exists($Claim.Result)) ('Core claim probe failed: '+$tail+$err)
 $report=[IO.File]::ReadAllText($Claim.Result)|ConvertFrom-Json -AsHashtable -Depth 80
 Assert-True ($report.nativeFileProbe-and$report.result.passed-and$report.result.released-and$report.candidateSha256.ToLowerInvariant()-ceq$binding.candidateSha256-and$report.probeSha256.ToLowerInvariant()-ceq$binding.probeSha256) 'Core claim proof or candidate binding differs.'
 return $report
}
function Test-Case([string]$Name,[scriptblock]$Body){
 $script:CaseRoot=Join-Path $OutputDirectory $Name;$null=[IO.Directory]::CreateDirectory($script:CaseRoot)
 $script:Scope=Join-Path $script:CaseRoot 'scope';$script:Recovery=Join-Path $script:CaseRoot 'metadata';$script:Temp=Join-Path $script:CaseRoot 'temp'
 foreach($path in @($script:Scope,$script:Recovery,$script:Temp)){$null=[IO.Directory]::CreateDirectory($path)}
 $script:Config=Join-Path $script:CaseRoot 'config.json';$script:Sessions=[Collections.Generic.List[object]]::new();$script:Claims=[Collections.Generic.List[object]]::new();$script:Evidence=@{};$configPin=$null
 try{
  $init=Complete-Child (Start-Child @('init','--backup-directory',$script:Recovery));Assert-True ($init.exitCode-eq0) ('Init failed: '+$init.stderr)
  $config=[IO.File]::ReadAllText($script:Config)|ConvertFrom-Json -AsHashtable -Depth 80;$volumeStore=Join-Path $script:CaseRoot 'volume-store';$config.volumeRecoveryDirectories=@{(Get-VerificationVolumeRoot $volumeStore)=$volumeStore};Save-Json $script:Config $config
  $configPin=[IO.File]::Open($script:Config,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  & $Body
  $results.Add(@{name=$Name;passed=$true;evidence=$script:Evidence})
 }catch{$results.Add(@{name=$Name;passed=$false;error=$_.Exception.ToString();location=$_.ScriptStackTrace;evidence=$script:Evidence});Write-Warning ($Name+': '+$_.Exception.Message)}
 finally{
  $claimEvidence=[Collections.Generic.List[object]]::new()
  foreach($claim in $script:Claims){
   try{
    if(!$claim.Process.HasExited){if(!$claim.Released){$claim.Released=$true;try{$claim.Process.StandardInput.WriteLine('release');$claim.Process.StandardInput.Close()}catch{}};if(!$claim.Process.WaitForExit(5000)){$claim.Process.Kill($true);$claim.Process.WaitForExit()}}
    $claimEvidence.Add(@{pid=$claim.Process.Id;exitCode=$claim.Process.ExitCode;stdout=$(if($claim.FinalStdout){$claim.FinalStdout}else{$claim.Lines -join "`n"});stderr=$(if($claim.FinalStderr){$claim.FinalStderr}else{$claim.Err.GetAwaiter().GetResult()});resultPath=$claim.Result;resultExists=[IO.File]::Exists($claim.Result)})
   }catch{$claimEvidence.Add(@{captureError=$_.Exception.ToString()})}finally{$claim.Process.Dispose()}
  }
  $script:Evidence.claims=@($claimEvidence)
  $captured=[Collections.Generic.List[object]]::new()
  foreach($session in $script:Sessions){
   try{
    if(!$session.Process.HasExited){$session.Process.Kill($true);$session.Process.WaitForExit()}
    if($session.ContainsKey('Lines')){
     Pump-Mcp $session
     $captured.Add(@{pid=$session.Process.Id;exitCode=$session.Process.ExitCode;rawLines=@($session.RawLines);messages=@($session.Lines);stderr=$session.Err.GetAwaiter().GetResult()})
    }elseif($session.Completed){$captured.Add($session.Completed)}
    else{
     $first=$session.FirstErr.GetAwaiter().GetResult();$stderr=$(if($null-ne$first){$first+[Environment]::NewLine}else{''})+$session.Process.StandardError.ReadToEnd()
     $captured.Add(@{pid=$session.Process.Id;exitCode=$session.Process.ExitCode;stdout=$session.Out.GetAwaiter().GetResult();stderr=$stderr})
    }
   }catch{$captured.Add(@{captureError=$_.Exception.ToString()})}finally{$session.Process.Dispose()}
  }
  $script:Evidence.processes=@($captured)
  try{$script:Evidence.finalScopeSnapshot=Get-FileFixtureSnapshot -Path $script:Scope}catch{$script:Evidence.finalScopeSnapshotError=$_.Exception.ToString()}
  if($configPin){$configPin.Dispose()}
 }
}
foreach($relation in @('same','parent-child','child-parent')){
 Test-Case ('process-claims-'+$relation) {
  $tree=Join-Path $script:Scope 'tree';$null=[IO.Directory]::CreateDirectory($tree)
  $child=Join-Path $tree 'child.txt';$independent=Join-Path $script:Scope 'independent.txt'
  [IO.File]::WriteAllText($child,'owned child',$utf8);[IO.File]::WriteAllText($independent,'owned independent',$utf8)
  $held=if($relation-eq'parent-child'){$tree}else{$child};$target=if($relation-eq'child-parent'){$tree}else{$child}
  $before=Get-FileFixtureSnapshot -Path $child;$claim=Start-Claim $held
  $conflict=Start-Delete $target ($relation-eq'child-parent');$other=Start-Delete $independent $false
  Assert-True ($conflict.FirstErr.Wait(30000)-and$conflict.FirstErr.GetAwaiter().GetResult()-match'Waiting for recovery lock') 'Shipping CLI did not reach the held claim.'
  $otherResult=Complete-Child $other;Assert-Deleted $otherResult $independent
  Assert-True (!$conflict.Process.HasExited-and[IO.File]::Exists($child)) 'Conflicting shipping CLI did not remain waiting with original intact.'
  $after=Get-FileFixtureSnapshot -Path $child;Assert-True (($before|ConvertTo-Json -Depth 80 -Compress)-ceq($after|ConvertTo-Json -Depth 80 -Compress)) 'Waiting request changed the held fixture.'
  $core=Release-Claim $claim;$done=Complete-Child $conflict;Assert-Deleted $done $target
  Assert-True ($done.stderr-match'Waiting for recovery lock') 'Shipping CLI did not report its claim wait.'
  $script:Evidence=@{relation=$relation;coreProbe=$core;shippingIndependent=$otherResult;shippingConflict=$done;independentCompletedWhileClaimHeld=$true}
 }
}
function Send-Mcp($Session,$Message){$Session.Process.StandardInput.WriteLine(($Message|ConvertTo-Json -Depth 30 -Compress));$Session.Process.StandardInput.Flush()}
function Pump-Mcp($Session){
 while($null-ne$Session.Pending-and$Session.Pending.IsCompleted){
  $line=$Session.Pending.GetAwaiter().GetResult();if($null-eq$line){$Session.Pending=$null;break}
  $Session.RawLines.Add($line);$Session.Lines.Add(($line|ConvertFrom-Json -AsHashtable -Depth 80));$Session.Pending=$Session.Process.StandardOutput.ReadLineAsync()
 }
}
function Wait-Mcp($Session,[scriptblock]$Condition,[int]$Timeout=30000){
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($true){Pump-Mcp $Session;if(&$Condition){return};if($clock.ElapsedMilliseconds-ge$Timeout){throw 'MCP response or progress timed out.'};if($Session.Pending){$null=$Session.Pending.Wait([Math]::Max(1,[Math]::Min(250,$Timeout-[int]$clock.ElapsedMilliseconds)))}else{throw 'Unexpected MCP EOF.'}}
}
function Start-Mcp{
 $info=[Diagnostics.ProcessStartInfo]::new($ExecutablePath);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 $info.StandardInputEncoding=$utf8;$info.StandardOutputEncoding=$utf8;$info.StandardErrorEncoding=$utf8;$info.Environment['TEMP']=$script:Temp;$info.Environment['TMP']=$script:Temp
 foreach($a in @('--config',$script:Config,'mcp')){$info.ArgumentList.Add($a)}
 $p=[Diagnostics.Process]::Start($info);$s=@{Process=$p;Err=$p.StandardError.ReadToEndAsync();Pending=$p.StandardOutput.ReadLineAsync();Lines=[Collections.Generic.List[object]]::new();RawLines=[Collections.Generic.List[string]]::new()}
 $script:Sessions.Add($s);Send-Mcp $s @{jsonrpc='2.0';id=1;method='initialize';params=@{protocolVersion='2024-11-05';capabilities=@{};clientInfo=@{name='concurrency-e2e';version='1'}}}
 Wait-Mcp $s {@($s.Lines|Where-Object {$_.id-eq1-and$_.result}).Count-eq1};Send-Mcp $s @{jsonrpc='2.0';method='notifications/initialized'};return $s
}
function Send-DeleteMcp($Session,[int]$Id,[string]$Path,$Token=$null){
 $params=@{name='delete_files';arguments=@{paths=@($Path)}};if($null-ne$Token){$params._meta=@{progressToken=$Token}}
 Send-Mcp $Session @{jsonrpc='2.0';id=$Id;method='tools/call';params=$params}
}
function Finish-Mcp($Session,[int[]]$Ids,[hashtable]$Tokens){
 $Session.Process.StandardInput.Close()
 Wait-Mcp $Session {$null-eq$Session.Pending} 120000
 # 後続のassertが失敗しても、受信済みの実応答を報告へ残す。
 $script:Evidence.shippingMcp=@{rawLines=@($Session.RawLines);lines=@($Session.Lines);exitCode=$(if($Session.Process.HasExited){$Session.Process.ExitCode}else{$null})}
 Assert-True ($Session.Process.WaitForExit(10000)-and$Session.Process.ExitCode-eq0) 'MCP EOF drain failed.'
 $closed=@{};$counts=@{}
 foreach($message in $Session.Lines){
  if($null-ne$message.id){if($message.id-ne1){Assert-True ($Ids-contains[int]$message.id-and!$closed.ContainsKey([int]$message.id)) 'Unexpected or duplicate MCP response.'};$closed[[int]$message.id]=$true}
  elseif($message.method-ceq'notifications/progress'){$key=$message.params.progressToken|ConvertTo-Json -Compress;Assert-True ($Tokens.ContainsKey($key)-and!$closed.ContainsKey($Tokens[$key])) 'Unexpected progress token or notification after final response.';$counts[$key]=1+[int]$counts[$key]}
 }
 foreach($id in $Ids){Assert-True $closed.ContainsKey($id) ('Missing MCP response '+$id)}
 return @{rawLines=@($Session.RawLines);lines=@($Session.Lines);progress=$counts;exitCode=$Session.Process.ExitCode;stderr=$Session.Err.GetAwaiter().GetResult()}
}
function Assert-McpDeleted($Reply,[string]$Path){
 Assert-True (!$Reply.error-and!$Reply.result.isError-and$Reply.result.structuredContent.items.Count-eq1-and$Reply.result.structuredContent.items[0].path-ceq$Path-and$Reply.result.structuredContent.items[0].status-cin@('recycled','permanently_deleted')-and![IO.File]::Exists($Path)-and![IO.Directory]::Exists($Path)) 'MCP did not confirm deletion of the expected target.'
}
Test-Case 'mcp-token-isolation-and-final-response' {
 $tree=Join-Path $script:Scope 'held';$null=[IO.Directory]::CreateDirectory($tree);$a=Join-Path $tree 'a.txt';$b=Join-Path $tree 'b.txt'
 [IO.File]::WriteAllText($a,'owned A',$utf8);[IO.File]::WriteAllText($b,'owned B',$utf8)
 $claim=Start-Claim $tree;$mcp=Start-Mcp;Send-DeleteMcp $mcp 10 $a 'first-token';Send-DeleteMcp $mcp 11 $b 42
 Wait-Mcp $mcp {@($mcp.Lines|Where-Object {$_.method-ceq'notifications/progress'-and$_.params.progressToken-ceq'first-token'}).Count-ge1-and@($mcp.Lines|Where-Object {$_.method-ceq'notifications/progress'-and$_.params.progressToken-is[long]-and$_.params.progressToken-eq42}).Count-ge1}
 Assert-True (@($mcp.Lines|Where-Object {$_.id-in@(10,11)}).Count-eq0-and[IO.File]::Exists($a)-and[IO.File]::Exists($b)) 'MCP requests completed or mutated targets before claim release.'
 $core=Release-Claim $claim;$transcript=Finish-Mcp $mcp @(10,11) @{ '"first-token"'=10;'42'=11 }
 foreach($entry in @(@{id=10;path=$a},@{id=11;path=$b})){$reply=@($transcript.lines|Where-Object {$_.id-eq$entry.id})[0];Assert-McpDeleted $reply $entry.path}
 Assert-True (![IO.File]::Exists($a)-and![IO.File]::Exists($b)) 'MCP source remains after recycled results.'
 $script:Evidence=@{coreProbe=$core;shippingMcp=$transcript}
}
Test-Case 'mcp-request-validation-errors-release-dispatch' {
 $source=Join-Path $script:Scope 'after-validation.txt';$rejected=Join-Path $script:Scope 'rejected-input.txt'
 [IO.File]::WriteAllText($source,'owned',$utf8);[IO.File]::WriteAllText($rejected,'owned',$utf8)
 $before=Get-FileFixtureSnapshot -Path $source;$rejectedBefore=Get-FileFixtureSnapshot -Path $rejected;$mcp=Start-Mcp
 $invalid=@(@{paths=@()},@{paths='wrong'},@{paths=@($rejected);unknown=$true},@{paths=@($rejected);recursive='wrong'})
 for($i=0;$i-lt4;$i++){Send-Mcp $mcp @{jsonrpc='2.0';id=(20+$i);method='tools/call';params=@{name='delete_files';arguments=$invalid[$i]}}}
 Wait-Mcp $mcp {@($mcp.Lines|Where-Object {$_.id-in@(20,21,22,23)}).Count-eq4}
 foreach($entry in @($mcp.Lines|Where-Object {$_.id-in@(20,21,22,23)})){Assert-True ($entry.error.code-eq-32602) 'Invalid request did not fail validation.'}
 $after=Get-FileFixtureSnapshot -Path $source;Assert-True (($before|ConvertTo-Json -Depth 80 -Compress)-ceq($after|ConvertTo-Json -Depth 80 -Compress)) 'Invalid requests changed the fifth target.'
 $rejectedAfter=Get-FileFixtureSnapshot -Path $rejected;Assert-True (($rejectedBefore|ConvertTo-Json -Depth 80 -Compress)-ceq($rejectedAfter|ConvertTo-Json -Depth 80 -Compress)) 'Invalid requests changed their fixture.'
 Send-DeleteMcp $mcp 24 $source
 $transcript=Finish-Mcp $mcp @(20,21,22,23,24) @{}
 $reply=@($transcript.lines|Where-Object {$_.id-eq24})[0]
 Assert-McpDeleted $reply $source
 $script:Evidence=@{shippingMcp=$transcript;validationErrors=4;before=$before;afterErrors=$after;rejectedBefore=$rejectedBefore;rejectedAfter=$rejectedAfter}
}
Test-Case 'mcp-backend-failures-release-dispatch' {
 $sources=@(0..3|ForEach-Object {Join-Path $script:Scope ('failure-'+$_+'.txt')});$success=Join-Path $script:Scope 'after-backend-errors.txt'
 foreach($path in @($sources)+@($success)){[IO.File]::WriteAllText($path,'owned',$utf8)}
 $sourceBefore=@{};foreach($path in @($sources)+@($success)){$sourceBefore[$path]=Get-FileFixtureSnapshot -Path $path}
 $mcp=Start-Mcp;$parked=Join-Path $script:CaseRoot 'metadata-parked'
 $original=[IO.Path]::GetFullPath((Join-Path $script:CaseRoot 'metadata'))
 Assert-True ($script:Recovery-ceq$original-and[IO.Directory]::Exists($original)-and!(Test-Path -LiteralPath $parked)) 'Unexpected metadata boundary.'
 Assert-VerificationDestination $original @($repo,$codexRoot);Assert-VerificationDestination $parked @($repo,$codexRoot)
 $metadataBefore=Get-FileFixtureSnapshot -Path $original;$moved=$false
 try{
  [IO.Directory]::Move($original,$parked);$moved=$true
  for($i=0;$i-lt4;$i++){Send-DeleteMcp $mcp (30+$i) $sources[$i]}
  Wait-Mcp $mcp {@($mcp.Lines|Where-Object {$_.id-in@(30,31,32,33)}).Count-eq4}
  foreach($entry in @($mcp.Lines|Where-Object {$_.id-in@(30,31,32,33)})){Assert-True (!$entry.error-and[bool]$entry.result.isError-and$entry.result.content[0].text) 'Backend error was not returned by a valid request.'}
  foreach($path in @($sources)+@($success)){$after=Get-FileFixtureSnapshot -Path $path;Assert-True (($sourceBefore[$path]|ConvertTo-Json -Depth 80 -Compress)-ceq($after|ConvertTo-Json -Depth 80 -Compress)) 'Backend failure changed a fixture.'}
  $metadataParked=Get-FileFixtureSnapshot -Path $parked;Assert-True (($metadataBefore|ConvertTo-Json -Depth 80 -Compress)-ceq($metadataParked|ConvertTo-Json -Depth 80 -Compress)) 'Backend failure changed parked metadata.'
  Assert-True (![IO.Directory]::Exists($original)) 'Backend failure recreated metadata.'
 }finally{if($moved){if(Test-Path -LiteralPath $original){throw 'Unexpected metadata replacement; parked source retained.'};[IO.Directory]::Move($parked,$original)}}
 $metadataRestored=Get-FileFixtureSnapshot -Path $original;Assert-True (($metadataBefore|ConvertTo-Json -Depth 80 -Compress)-ceq($metadataRestored|ConvertTo-Json -Depth 80 -Compress)) 'Metadata did not return unchanged.'
 Send-DeleteMcp $mcp 34 $success
 $transcript=Finish-Mcp $mcp @(30,31,32,33,34) @{}
 $reply=@($transcript.lines|Where-Object {$_.id-eq34})[0]
 Assert-McpDeleted $reply $success
 $script:Evidence=@{shippingMcp=$transcript;backendErrors=4;sourceBefore=$sourceBefore;metadataBefore=$metadataBefore;metadataAfterRestore=$metadataRestored}
}
$passed=@($results|Where-Object {$_.passed}).Count;$failed=@($results|Where-Object {!$_.passed}).Count
Save-Json $ReportPath @{schema=1;scope='Deterministic Core claim probe and separate shipping CLI/MCP processes';binding=$binding;passed=$passed;failed=$failed;results=@($results);retainedDirectory=$OutputDirectory;coverageNote='Recordless file E2E separately covers all-preflight preservation, input order, hardlinks and process worker cap; this runner does not report the removed legacy suite as executed.'}
if($failed){exit 1}
} finally { foreach($pin in $pins){$pin.Dispose()};$env:TEMP=$oldTemp;$env:TMP=$oldTmp }
