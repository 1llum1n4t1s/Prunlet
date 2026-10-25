param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$ReportPath,[switch]$CurrentOnly,[ValidateSet(-1,0,6801)][int]$ExpectedCurrentSoftwareTransactionError=-1)
. (Join-Path $PSScriptRoot 'SessionE2E.Common.ps1')
. (Join-Path $PSScriptRoot 'SessionLockCases.ps1')
$settingsPath=Join-Path $PSScriptRoot 'settings.json';$settings=ReadJson $settingsPath
AssertPreparedSettings $settings
$script:ExecutablePath=$settings.executablePath;$script:Config=$settings.config;$script:RunRelative=$settings.runRelative
$recovery=$settings.recovery;$configData=ReadJson $script:Config
$results=[Collections.Generic.List[object]]::new();$started=$false
function Check([string]$Name,[scriptblock]$Body){$sw=[Diagnostics.Stopwatch]::StartNew();try{&$Body;$results.Add(@{name=$Name;passed=$true;milliseconds=$sw.ElapsedMilliseconds})}catch{$results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message;milliseconds=$sw.ElapsedMilliseconds});Write-Warning ($Name+': '+$_.Exception.Message)}}
function Same($A,$B){(($A.snapshot-join"`n")-ceq($B.snapshot-join"`n"))-and$A.keyClass-ceq$B.keyClass}
try{
 LoadFixture
 if(!$CurrentOnly){$started=$true;foreach($readyFile in @('controller-ready.json','limited-ready.json')){
  $ready=ReadJson (Join-Path $PSScriptRoot $readyFile)
  Assert ($ready.success-and$ready.scope.kind-eq'nativeWindows') ('Explicit native session not ready: '+$readyFile)
  Assert ([DateTimeOffset]::Parse($ready.expiresUtc)-gt[DateTimeOffset]::UtcNow.AddMinutes(8)) 'Explicit session too near expiry; prepare new sessions'
 }
 $clientToken=[SessionE2ENative]::TokenInfo();$normalReady=ReadJson (Join-Path $PSScriptRoot 'limited-ready.json');$adminReady=ReadJson (Join-Path $PSScriptRoot 'controller-ready.json')
 $normalDescriptor=ReadCapability $configData.registrySessionFile;$adminDescriptor=ReadCapability (ReadJson $settings.highConfig).registrySessionFile
 foreach($entry in @(@{ready=$normalReady;descriptor=$normalDescriptor;config=$settings.config},@{ready=$adminReady;descriptor=$adminDescriptor;config=$settings.highConfig})){
  Assert ($entry.ready.authenticationId-ceq$entry.descriptor.authenticationId-and$entry.ready.tokenInfo.authenticationId-ceq$entry.descriptor.authenticationId) 'Desktop helper/session AuthID mismatch'
  Assert ($entry.descriptor.scope.ownerSid-ceq$clientToken.ownerSid-and$entry.descriptor.windowsSessionId-eq$clientToken.windowsSessionId) 'Desktop session SID/Windows session differs from client'
  Assert ($entry.descriptor.configurationSha256-ceq[SessionE2ENative]::Fingerprint([IO.File]::ReadAllText($entry.config))) 'Desktop session config fingerprint differs'
  Assert ($entry.descriptor.executableSha256.Equals($settings.executableSha256,[StringComparison]::OrdinalIgnoreCase)) 'Desktop session executable differs'
  Assert ($entry.ready.sessionPid-eq$entry.descriptor.serverProcessId-and$entry.ready.powerShellHostPath.Equals($settings.powerShellHostPath,[StringComparison]::OrdinalIgnoreCase)) 'Desktop session process/host differs'
 }
 Assert ($normalDescriptor.authenticationId-ceq$clientToken.authenticationId) ('Normal session AuthID '+$normalDescriptor.authenticationId+' differs from actual client '+$clientToken.authenticationId+'; no fixture was created')
 Assert ($adminReady.tokenInfo.isAdministrator-and$adminDescriptor.authenticationId-cne$clientToken.authenticationId) 'Administrator session must have its distinct administrator AuthID for this two-role verification'
 SaveJson (Join-Path $PSScriptRoot 'session-role-preflight.json') @{clientToken=$clientToken;normalToken=$normalReady.tokenInfo;administratorToken=$adminReady.tokenInfo;normalAuthenticationId=$normalDescriptor.authenticationId;administratorAuthenticationId=$adminDescriptor.authenticationId;fixtureMutationStarted=$false}
 }
 Check 'current-software-cli-mcp-dryrun-preserves-existing-value' {
  $before=[SessionE2ENative]::CurrentSoftwareValueDigest()
  $metadataBefore=@(Get-ChildItem -LiteralPath $recovery -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash})-join"`n"
  $currentConfig=$settings.currentConfig;$oldConfig=$script:Config
  $target='HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer';$p=$null
  try{
   $script:Config=$currentConfig
   $cli=InvokePrunletCli @('registry-delete','--dry-run','--view','64','--value-name=ShellState','--',$target)
   $cliError=if($cli.exitCode-eq 0){0}elseif(($cli.stdout+$cli.stderr)-match'6801'){6801}else{-2}
   Assert ($cliError-in@(0,6801)-and($ExpectedCurrentSoftwareTransactionError-eq -1-or$cliError-eq$ExpectedCurrentSoftwareTransactionError)) 'Current Software CLI dry-run transaction outcome differs from expectation'
   if($cliError-eq 0){Assert ($cli.stdout-match'would_delete') 'Successful CLI dry-run did not identify the existing value'}
   Assert ($before-ceq[SessionE2ENative]::CurrentSoftwareValueDigest()) 'CLI dry-run changed existing value'
   $p=McpStart;$mcp=McpCall $p 'delete_registry' @{path=$target;view='64';valueName='ShellState';dryRun=$true}
   $mcpText=$mcp|ConvertTo-Json -Depth 50
   $mcpError=if(!$mcp.result.isError){0}elseif($mcpText-match'6801'){6801}else{-2}
   Assert ($mcpError-eq$cliError) 'Current Software MCP dry-run differs from CLI transaction outcome'
   if($mcpError-eq 0){Assert ($mcpText-match'would_delete') 'Successful MCP dry-run did not identify the existing value'}
   Assert ($before-ceq[SessionE2ENative]::CurrentSoftwareValueDigest()) 'MCP dry-run changed existing value'
  }finally{if($p){McpStop $p};$script:Config=$oldConfig}
  $metadataAfter=@(Get-ChildItem -LiteralPath $recovery -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash})-join"`n"
  Assert ($metadataBefore-ceq$metadataAfter) 'Rejected current dry-run changed metadata'
  $script:CurrentProbeError=$cliError
  SaveJson (Join-Path $PSScriptRoot 'current-software-dryrun-result.json') @{cli=$cli;mcp=$mcp;valueDigest=$before;valueUnchanged=$true;metadataUnchanged=$true;privateFixtureCreated=$false;observedTransactionError=$cliError;expectedTransactionError=$ExpectedCurrentSoftwareTransactionError;unsupported6801Covered=($cliError-eq 6801)}
 }
 Check 'normal-hook-subprocess-refuses-registry-delete-without-rewrite' {
  $before=[SessionE2ENative]::CurrentSoftwareValueDigest();$responses=@()
  foreach($tool in @('Bash','exec_command','functions.exec_command')){
   $inputObject=@{cwd=$PSScriptRoot};$inputObject[$(if($tool-eq'Bash'){'command'}else{'cmd'})]='Remove-ItemProperty -LiteralPath HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer -Name ShellState'
   $event=@{hook_event_name='PreToolUse';tool_name=$tool;tool_input=$inputObject}|ConvertTo-Json -Depth 10 -Compress
   $p=Child @('hook')
   try{
    $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.StandardInput.Write($event);$p.StandardInput.Close()
    Assert ($p.WaitForExit(15000)) 'Hook subprocess timeout'
    $stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult();$reply=$stdout|ConvertFrom-Json -AsHashtable -Depth 30
    Assert ($p.ExitCode-eq 0-and$reply.hookSpecificOutput.permissionDecision-ceq'deny'-and!$reply.hookSpecificOutput.updatedInput-and$reply.hookSpecificOutput.permissionDecisionReason-match'(?i)prunlet') 'Hook did not refuse with CLI guidance'
    $responses+=@{tool=$tool;exitCode=$p.ExitCode;stdout=$stdout;stderr=$stderr}
   }finally{if(!$p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}
  }
  Assert ($before-ceq[SessionE2ENative]::CurrentSoftwareValueDigest()) 'Hook subprocess changed existing value'
  SaveJson (Join-Path $PSScriptRoot 'normal-hook-result.json') @{responses=$responses;valueUnchanged=$true;commandsWereStdinOnly=$true}
 }
 if($CurrentOnly){if(@($results|Where-Object {!$_.passed}).Count){exit 1};exit 0}
 foreach($transport in @('cli','mcp')){
  foreach($valueName in @('','raw-日本語😀')){
   Check ($transport+'-value-'+$(if($valueName){'raw'}else{'default'})+'-dryrun-roundtrip') {
    $leaf=$transport+'-'+$(if($valueName){'raw'}else{'default'});$f=NativeRequest 'create' @{leaf=$leaf};$before=NativeRequest 'observe' @{leaf=$leaf};$p=$null
    try{
     if($transport-eq'cli'){
      $opts=@('registry-delete','--view','64',('--value-name='+$valueName));$dry=InvokePrunletCli ($opts+@('--dry-run','--',$f.path));Assert ($dry.exitCode-eq 0) ('CLI dryrun: '+$dry.stdout+$dry.stderr);Assert (Same $before (NativeRequest 'observe' @{leaf=$leaf})) 'Dry-run mutated native source'
      $d=InvokePrunletCli ($opts+@('--',$f.path));Assert ($d.exitCode-eq 0-and$d.json.operationId) ('CLI delete: '+$d.stdout+$d.stderr);$id=$d.json.operationId
      $absent=NativeRequest 'observe' @{leaf=$leaf};Assert (!$absent.values.ContainsKey($valueName)) 'Native value not deleted'
      $r=InvokePrunletCli @('restore',$id);Assert ($r.exitCode-eq 0) ('CLI restore: '+$r.stdout+$r.stderr)
      $again=InvokePrunletCli @('restore',$id);Assert ($again.exitCode-eq 0-and$again.stdout-match'already_restored') 'CLI consumed restore'
     }else{
      $p=McpStart;$a=@{path=$f.path;view='64';valueName=$valueName;dryRun=$true};$dry=McpCall $p 'delete_registry' $a;Assert (!$dry.result.isError) ('MCP dryrun: '+($dry|ConvertTo-Json -Depth 30));Assert (Same $before (NativeRequest 'observe' @{leaf=$leaf})) 'MCP dry-run mutated native source'
      $a.dryRun=$false;$d=McpCall $p 'delete_registry' $a;$data=McpData $d;Assert (!$d.result.isError-and$data.operationId) ('MCP delete: '+($d|ConvertTo-Json -Depth 30));$id=$data.operationId
      $absent=NativeRequest 'observe' @{leaf=$leaf};Assert (!$absent.values.ContainsKey($valueName)) 'MCP native value not deleted'
      $r=McpCall $p 'restore_registry' @{operationId=$id};Assert (!$r.result.isError) ('MCP restore: '+($r|ConvertTo-Json -Depth 30))
      $again=McpCall $p 'restore_registry' @{operationId=$id};Assert (!$again.result.isError-and($again|ConvertTo-Json -Depth 30)-match'already_restored') 'MCP consumed restore'
     }
     $after=NativeRequest 'observe' @{leaf=$leaf};Assert (Same $before $after) 'Native raw/class/full-security roundtrip mismatch'
     $rec=InvokePrunletCli @('registry-reconcile',$id);Assert ($rec.exitCode-eq 0-and$rec.json.items[0].status-eq'restored') 'CLI reconcile restored value mismatch'
     if($p){$mrec=McpCall $p 'reconcile_registry' @{operationId=$id};Assert (!$mrec.result.isError-and(McpData $mrec).items[0].status-eq'restored') 'MCP reconcile restored value mismatch'}else{$mrec=$null}
     Assert (Same $after (NativeRequest 'observe' @{leaf=$leaf})) 'Reconcile mutated registry'
     SaveJson (Join-Path $PSScriptRoot ($leaf+'-result.json')) @{operationId=$id;dryrun=$dry;delete=$d;restore=$r;again=$again;before=$before;after=$after;reconcile=$rec;mcpReconcile=$mrec}
    }finally{if($p){McpStop $p}}
   }
  }
 }
 Assert (@($results|Where-Object {$_.name-eq'cli-value-default-dryrun-roundtrip'-and$_.passed}).Count-eq 1-and@($results|Where-Object {$_.name-eq'mcp-value-default-dryrun-roundtrip'-and$_.passed}).Count-eq 1) 'Normal CLI and MCP successful roundtrips are mandatory before negative cases'
 Check 'normal-clients-reject-administrator-session-authid-without-mutation' {
  $f=NativeRequest 'create' @{leaf='different-logon'};$before=NativeRequest 'observe' @{leaf='different-logon'};$oldConfig=$script:Config;$p=$null
  try{
   $script:Config=$settings.highConfig
   $cli=InvokePrunletCli @('registry-delete','--view','64','--value-name=binary','--',$f.path)
   Assert ($cli.exitCode-ne 0-and($cli.stdout+$cli.stderr)-match'Registry session is expired or its scope, executable, or Windows logon differs') 'CLI did not reject the administrator session at the Windows-logon guard'
   Assert (Same $before (NativeRequest 'observe' @{leaf='different-logon'})) 'Cross-logon CLI rejection changed fixture'
   $p=McpStart;$mcp=McpCall $p 'delete_registry' @{path=$f.path;view='64';valueName='binary'}
   Assert ($mcp.result.isError-and($mcp|ConvertTo-Json -Depth 50)-match'Registry session is expired or its scope, executable, or Windows logon differs') 'MCP did not reject the administrator session at the Windows-logon guard'
   Assert (Same $before (NativeRequest 'observe' @{leaf='different-logon'})) 'Cross-logon MCP rejection changed fixture'
   SaveJson (Join-Path $PSScriptRoot 'different-logon-rejection.json') @{cli=$cli;mcp=$mcp;before=$before;after=(NativeRequest 'observe' @{leaf='different-logon'});clientAuthenticationId=$clientToken.authenticationId;serverAuthenticationId=$adminDescriptor.authenticationId}
  }finally{if($p){McpStop $p};$script:Config=$oldConfig}
 }
 Check 'normal-client-key-privilege-denied-without-server-authority' {
  $f=NativeRequest 'create' @{leaf='denied-key';tree=$true};$b=NativeRequest 'observe' @{leaf='denied-key'}
  $r=InvokePrunletCli @('registry-delete','--view','64','--recursive','--',$f.path);Assert ($r.exitCode-ne 0) 'Normal CLI borrowed native-server key privileges';Assert ($r.stdout-match'SeSecurityPrivilege|Complete registry-key ACL preservation') 'Normal CLI did not reach effective-token privilege gate';Assert (Same $b (NativeRequest 'observe' @{leaf='denied-key'})) 'CLI denied key changed'
  $p=McpStart;try{$m=McpCall $p 'delete_registry' @{path=$f.path;view='64';recursive=$true};Assert $m.result.isError 'Normal MCP borrowed native-server privileges';Assert (($m|ConvertTo-Json -Depth 30)-match'SeSecurityPrivilege|Complete registry-key ACL preservation') 'Normal MCP did not reach effective-token privilege gate';Assert (Same $b (NativeRequest 'observe' @{leaf='denied-key'})) 'MCP denied key changed'}finally{McpStop $p}
  SaveJson (Join-Path $PSScriptRoot 'normal-key-denials.json') @{cli=$r;mcp=$m;before=$b;after=(NativeRequest 'observe' @{leaf='denied-key'})}
 }
 Check 'value-restore-conflict-preserves-existing-and-snapshot' {
  $leaf='restore-conflict';$f=NativeRequest 'create' @{leaf=$leaf};$before=NativeRequest 'observe' @{leaf=$leaf}
  $d=InvokePrunletCli @('registry-delete','--view','64','--value-name=binary','--',$f.path);Assert ($d.exitCode-eq 0-and$d.json.operationId) 'Conflict setup delete failed';$id=$d.json.operationId
  $payload=Join-Path $recovery ($id+'\registry-snapshot.json');$digest=(Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash
  $null=NativeRequest 'set-collision' @{leaf=$leaf;valueName='binary'};$collision=NativeRequest 'observe' @{leaf=$leaf}
  $r=InvokePrunletCli @('restore',$id);Assert ($r.exitCode-ne 0) 'Conflict restore accepted';Assert (Same $collision (NativeRequest 'observe' @{leaf=$leaf})) 'Conflict restore changed existing native value';Assert ((Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash-ceq$digest) 'Conflict restore consumed/changed backup'
  $drop=InvokePrunletCli @('registry-delete','--view','64','--value-name=binary','--',$f.path);Assert ($drop.exitCode-eq 0-and$drop.json.operationId) 'Collision cleanup by new Core failed'
  $final=InvokePrunletCli @('restore',$id);Assert ($final.exitCode-eq 0) 'Restore after collision removal failed';Assert (Same $before (NativeRequest 'observe' @{leaf=$leaf})) 'Conflict final raw/security mismatch'
  SaveJson (Join-Path $PSScriptRoot 'restore-conflict-result.json') @{operationId=$id;collisionBackupOperationId=$drop.json.operationId;delete=$d;rejectedRestore=$r;collisionDelete=$drop;restore=$final;before=$before;collision=$collision;after=(NativeRequest 'observe' @{leaf=$leaf})}
 }
 Check 'value-payload-tamper-refused-without-consumption' {
  $leaf='payload-tamper';$f=NativeRequest 'create' @{leaf=$leaf};$before=NativeRequest 'observe' @{leaf=$leaf}
  $d=InvokePrunletCli @('registry-delete','--view','64','--value-name=binary','--',$f.path);Assert ($d.exitCode-eq 0-and$d.json.operationId) 'Tamper setup delete failed';$id=$d.json.operationId
  $payload=Join-Path $recovery ($id+'\registry-snapshot.json');$original=[IO.File]::ReadAllBytes($payload);$absent=NativeRequest 'observe' @{leaf=$leaf}
  try{
   $bytes=[byte[]]::new($original.Length+1);[Array]::Copy($original,$bytes,$original.Length);$bytes[-1]=32;[IO.File]::WriteAllBytes($payload,$bytes)
   $r=InvokePrunletCli @('restore',$id);Assert ($r.exitCode-ne 0) 'Changed payload accepted';Assert (Same $absent (NativeRequest 'observe' @{leaf=$leaf})) 'Rejected tamper changed source';Assert ([IO.File]::Exists($payload)) 'Rejected tamper consumed payload'
  }finally{[IO.File]::WriteAllBytes($payload,$original)}
  $final=InvokePrunletCli @('restore',$id);Assert ($final.exitCode-eq 0) 'Original payload restore failed';Assert (Same $before (NativeRequest 'observe' @{leaf=$leaf})) 'Original payload roundtrip mismatch'
  SaveJson (Join-Path $PSScriptRoot 'payload-tamper-result.json') @{operationId=$id;rejectedRestore=$r;restore=$final;before=$before;after=(NativeRequest 'observe' @{leaf=$leaf})}
 }
 Check 'native-record-current-scope-restore-rejected' {
  $leaf='scope-record';$f=NativeRequest 'create' @{leaf=$leaf};$before=NativeRequest 'observe' @{leaf=$leaf}
  $d=InvokePrunletCli @('registry-delete','--view','64','--value-name=binary','--',$f.path);Assert ($d.exitCode-eq 0-and$d.json.operationId) 'Scope record setup delete failed';$id=$d.json.operationId;$absent=NativeRequest 'observe' @{leaf=$leaf}
  $currentData=ReadJson $script:Config;$currentData.registryScope='current';$null=$currentData.Remove('registrySessionFile');$currentConfig=Join-Path $PSScriptRoot 'current-config.json';SaveJson $currentConfig $currentData
  $r=InvokePrunletCli @('restore',$id) $currentConfig;Assert ($r.exitCode-ne 0-and$r.stdout-match'scope differs') 'Native saved record accepted in current scope or unrelated rejection';Assert (Same $absent (NativeRequest 'observe' @{leaf=$leaf})) 'Wrong-scope restore changed native fixture'
  $final=InvokePrunletCli @('restore',$id);Assert ($final.exitCode-eq 0) 'Native restore after current refusal failed';Assert (Same $before (NativeRequest 'observe' @{leaf=$leaf})) 'Native restore final raw mismatch'
  SaveJson (Join-Path $PSScriptRoot 'current-scope-rejection-result.json') @{operationId=$id;rejectedRestore=$r;restore=$final;before=$before;after=(NativeRequest 'observe' @{leaf=$leaf})}
 }
 Check 'old-current-record-native-session-restore-rejected' {
  $leaf='oldscope-record';$null=NativeRequest 'create' @{leaf=$leaf};$before=NativeRequest 'observe' @{leaf=$leaf}
  $d=NativeRequest 'current-delete' @{leaf=$leaf};$id=$d.json.operationId;$absent=NativeRequest 'observe' @{leaf=$leaf};$opRoot=Join-Path $recovery $id
  $manifest=ReadJson (Join-Path $opRoot 'registry-manifest.json');$snapshot=ReadJson (Join-Path $opRoot 'registry-snapshot.json');Assert ($null-eq$manifest.scope-and$null-eq$snapshot.scope) 'Current-scope fixture unexpectedly has native scope'
  $digests=@{};foreach($file in [IO.Directory]::EnumerateFiles($opRoot)){$digests[[IO.Path]::GetFileName($file)]=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}
  $r=InvokePrunletCli @('restore',$id);Assert ($r.exitCode-ne 0-and$r.stdout-match'scope differs') 'Old unknown scope accepted in native session or unrelated rejection';Assert (Same $absent (NativeRequest 'observe' @{leaf=$leaf})) 'Native old-scope refusal changed source'
  Assert (@([IO.Directory]::EnumerateFiles($opRoot)).Count-eq$digests.Count) 'Old-scope refusal created metadata';foreach($file in [IO.Directory]::EnumerateFiles($opRoot)){Assert ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash-ceq$digests[[IO.Path]::GetFileName($file)]) 'Old-scope refusal changed metadata'}
  $final=NativeRequest 'current-restore' @{operationId=$id};Assert ($final.exitCode-eq 0) 'Same current Core restore failed';Assert (Same $before (NativeRequest 'observe' @{leaf=$leaf})) 'Old current restore final raw mismatch'
  SaveJson (Join-Path $PSScriptRoot 'oldscope-rejection-result.json') @{operationId=$id;delete=$d;rejectedNativeRestore=$r;currentRestore=$final;before=$before;after=(NativeRequest 'observe' @{leaf=$leaf});metadataUnchanged=$true}
 }
 foreach($negative in @('expired','badnonce-size','badscope-kind','badscope-machine','badconfig','badpeer-descriptor','offline')){
  Check ('session-reject-'+$negative+'-unchanged') {
   $leaf='negative-'+$negative;$f=NativeRequest 'create' @{leaf=$leaf};$before=NativeRequest 'observe' @{leaf=$leaf}
   $descriptor=ReadCapability $configData.registrySessionFile
   Assert ($descriptor.authenticationId-ceq$clientToken.authenticationId) 'Negative case baseline has the wrong client AuthID'
   Assert ([SessionE2ENative]::Fingerprint([IO.File]::ReadAllText($script:Config))-ceq$descriptor.configurationSha256) 'Harness config fingerprint differs before negative mutation'
   $testConfig=Join-Path $PSScriptRoot ($negative+'-config.json');$testData=(ReadJson $script:Config);$testData.registrySessionFile=Join-Path $PSScriptRoot ($negative+'-session.json');SaveJson $testConfig $testData
   $descriptor.configurationSha256=[SessionE2ENative]::Fingerprint([IO.File]::ReadAllText($testConfig))
   switch($negative){
    'expired'{$descriptor.expiresUtc=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('O')}
    'badnonce-size'{$descriptor.capability='AA=='}
    'badscope-kind'{$descriptor.scope.kind='current'}
    'badscope-machine'{$descriptor.scope.machineId=$(if($descriptor.scope.machineId-ne('0'*64)){'0'*64}else{'1'*64})}
    'badconfig'{$descriptor.configurationSha256='0'*64}
    'badpeer-descriptor'{$descriptor.serverProcessId=$PID}
    'offline'{$descriptor.pipeName='prunlet-registry-'+[guid]::NewGuid().ToString('N')}
   }
   SavePrivateJson $testData.registrySessionFile $descriptor
   $count=@([IO.Directory]::EnumerateDirectories($recovery)).Count
   $r=InvokePrunletCli @('registry-delete','--view','64','--value-name=binary','--',$f.path) $testConfig
   Assert ($r.exitCode-ne 0) ('Negative descriptor accepted: '+$negative);Assert (Same $before (NativeRequest 'observe' @{leaf=$leaf})) 'Negative descriptor changed native fixture';Assert (@([IO.Directory]::EnumerateDirectories($recovery)).Count-eq$count) 'Rejected session created a recovery operation'
   $expectedReason=switch($negative){
    'expired'{'Registry session is expired or its scope, executable, or Windows logon differs'}
    'badnonce-size'{'Registry session capability has an invalid size'}
    'badscope-kind'{'Registry scope identity is invalid'}
    'badscope-machine'{'Registry session challenge or execution scope differs from the capability file'}
    'badconfig'{'Registry session configuration or operation identity differs'}
    'badpeer-descriptor'{'Registry session server process differs from the capability owner'}
    'offline'{'Native registry session communication failed'}
   }
   Assert (($r.stdout+$r.stderr)-match[regex]::Escape($expectedReason)) ('Negative case reached a different guard: '+$negative+' expected '+$expectedReason)
   SaveJson (Join-Path $PSScriptRoot ($negative+'-rejection.json')) @{result=$r;expectedReason=$expectedReason;before=$before;after=(NativeRequest 'observe' @{leaf=$leaf});descriptorContentsLogged=$false;hmacValidationTested=$false}
  }
 }
 Check 'session-reject-different-executable-peer-unchanged' {
  $before=NativeRequest 'observe';$descriptor=ReadCapability $configData.registrySessionFile
  $pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$descriptor.pipeName,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous,[Security.Principal.TokenImpersonationLevel]::Impersonation)
  try{$pipe.Connect(5000);$head=[byte[]]::new(4);$task=$pipe.ReadExactlyAsync($head).AsTask();Assert ($task.Wait(10000)) 'Bad-peer reply timeout';$task.GetAwaiter().GetResult();$size=[BitConverter]::ToInt32($head,0);Assert ($size-gt 0-and$size-lt 65536) 'Bad-peer frame size';$body=[byte[]]::new($size);$pipe.ReadExactly($body);$reply=[Text.Encoding]::UTF8.GetString($body)|ConvertFrom-Json -AsHashtable;Assert ($reply.kind-eq'error'-and$reply.error-match'Registry session requires the same executable and Windows logon') 'Different executable peer did not reach the executable/logon guard';Assert (Same $before (NativeRequest 'observe')) 'Bad peer changed native fixture';SaveJson (Join-Path $PSScriptRoot 'badpeer-executable-rejection.json') @{kind=$reply.kind;error=$reply.error;unchanged=$true}}finally{$pipe.Dispose()}
 }
 Check 'cli-shared-lock-over-60s-resumes' {$r=TestCliLock;SaveJson (Join-Path $PSScriptRoot 'cli-shared-lock-result.json') $r}
 Check 'mcp-shared-lock-over-60s-token-and-no-postfinal-progress' {$r=TestMcpLock;SaveJson (Join-Path $PSScriptRoot 'mcp-shared-lock-result.json') $r}
 Check 'accepted-client-disconnect-completes-and-reconciles' {$r=TestDisconnectedClient;SaveJson (Join-Path $PSScriptRoot 'disconnect-reconcile-result.json') $r}
 Check 'explicit-desktop-administrator-clients' {
  $null=NativeRequest 'start-admin-clients'
  $sw=[Diagnostics.Stopwatch]::StartNew()
  do{$state=NativeRequest 'admin-client-state';if(!$state.finished){Assert ($sw.Elapsed.TotalSeconds-lt 600) 'Explicit administrator clients timeout';Start-Sleep -Milliseconds 200}}while(!$state.finished)
  Assert ($state.exitCode-eq 0) 'Explicit administrator client process failed'
  $e=ReadJson (Join-Path $PSScriptRoot 'elevated-client-results.json');foreach($r in $e.results){$results.Add($r)};Assert ($e.failed-eq 0-and$e.passed-eq 3) 'Full key roundtrips/default HKCU suite incomplete'
 }
 Check 'readonly-private-namespace-observation' {
  $k=[PrunletRegistryE2E]::Open($script:RunRelative,64);$o=@{packaged=[SessionE2ENative]::Packaged();exists=($null-ne$k);privateWritesPerformed=$false}
  if($k){try{$o.name=[SessionE2ENative]::Name($k);$o.keyClass=[SessionE2ENative]::Class($k)}finally{$k.Dispose()}}
  SaveJson (Join-Path $PSScriptRoot 'private-readonly-observation.json') $o
 }
}catch{$results.Add(@{name='orchestration';passed=$false;error=$_.Exception.Message})}
finally{
 if($started){
  Check 'native-fixture-cleanup-via-core' {$c=NativeRequest 'cleanup';Assert ($c.exitCode-eq 0) 'Native fixture cleanup failed';Assert (!(NativeRequest 'observe').exists) 'Native run root remains'}
  try{$null=NativeRequest 'stop'}catch{$results.Add(@{name='controller-stop';passed=$false;error=$_.Exception.Message})}
 }
 if(!$CurrentOnly){SaveJson (Join-Path $PSScriptRoot 'stop-limited.json') @{stop=$true}}
 if(!$CurrentOnly){Check 'explicit-desktop-session-processes-stopped' {
  foreach($name in @('controller-stopped.json','limited-stopped.json')){
   $sw=[Diagnostics.Stopwatch]::StartNew();$path=Join-Path $PSScriptRoot $name
   while(![IO.File]::Exists($path)){Assert ($sw.Elapsed.TotalSeconds-lt 20) ('Explicit desktop session did not stop: '+$name);Start-Sleep -Milliseconds 150}
   Assert ((ReadJson $path).sessionStopped) ('Explicit desktop session remains: '+$name)
  }
 }}
 $report=@{utc=[DateTimeOffset]::UtcNow;executablePath=$script:ExecutablePath;executableSha256=(Get-FileHash -LiteralPath $script:ExecutablePath -Algorithm SHA256).Hash;fixtureRoot=('HKEY_CURRENT_USER\'+$script:RunRelative);outputDirectory=$PSScriptRoot;results=@($results);passed=@($results|Where-Object passed).Count;failed=@($results|Where-Object {!$_.passed}).Count;notTested=@('wrong-valid-size-nonce-HMAC','disconnect-reconcile','samepath-private-native-different-values')}
 if(@($results|Where-Object {$_.name-eq'accepted-client-disconnect-completes-and-reconciles'-and$_.passed}).Count){$report.notTested=@($report.notTested|Where-Object {$_-ne'disconnect-reconcile'})}
 if($CurrentOnly){$report.notTested=@('Native session suite was not run by Mode Current.');$report.mode='current-only'}else{$report.mode='full-native-session'}
 $report.currentSoftwareTransactionError=$script:CurrentProbeError
 if($script:CurrentProbeError-ne 6801){$report.notTested+='Current Software 6801 refusal was not exercised in this process context.'}
 SaveJson $ReportPath $report;$report|Select-Object passed,failed,fixtureRoot,notTested|ConvertTo-Json -Depth 10
}
if(@($results|Where-Object {!$_.passed}).Count){exit 1};exit 0
