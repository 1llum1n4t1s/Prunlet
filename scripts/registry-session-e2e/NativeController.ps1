param([Parameter(Mandatory)][string]$SettingsPath,[ValidatePattern('^[0-9a-f]{32}$')][string]$LaunchNonce)
$script:AutomaticLaunchNonce=$LaunchNonce
. (Join-Path $PSScriptRoot 'SessionE2E.Common.ps1')
$settings=ReadJson $SettingsPath;$script:ExecutablePath=$settings.executablePath;$script:Config=$settings.highConfig;$script:RunRelative=$settings.runRelative
AssertPreparedSettings $settings
$powerShellHostPath=[IO.Path]::GetFullPath((Join-Path $PSHOME 'pwsh.exe'))
Assert ([IO.File]::Exists($powerShellHostPath)) 'Current PowerShell host executable missing'
Assert ($powerShellHostPath.Equals($settings.powerShellHostPath,[StringComparison]::OrdinalIgnoreCase)) 'Controller PowerShell host differs from Prepare; use the prepared absolute desktop command'
$session=$null;$adminClient=$null;$ownsRoot=$false
function StartOwnedClient([switch]$Cleanup){
 $info=[Diagnostics.ProcessStartInfo]::new($powerShellHostPath)
 $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WorkingDirectory=$PSScriptRoot
 foreach($argument in @('-NoProfile','-File',(Join-Path $PSScriptRoot 'ElevatedClient.ps1'),'-SettingsPath',$SettingsPath)){$info.ArgumentList.Add($argument)}
 if($script:AutomaticLaunchObserved-or$script:AutomaticLaunchNonce){
  $info.ArgumentList.Add('-LaunchNonce');$info.ArgumentList.Add($settings.nonce)
 }
 if($Cleanup){$info.ArgumentList.Add('-Cleanup')}
 $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$null=$process.Start();return $process
}
$currentOperations=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
try{
 LoadFixture
 $tokenInfo=[SessionE2ENative]::TokenInfo();AssertLaunchRole $settings $true
 $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
 Assert ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Start this fixture controller explicitly from an administrator desktop shell'
 Assert (![SessionE2ENative]::Packaged()) 'Controller remains packaged; no fixture created'
 $existingRoot=[PrunletRegistryE2E]::Open($script:RunRelative,64)
 if($existingRoot){$existingRoot.Dispose();throw 'Prepared native run root already exists; no fixture mutation allowed'}
 $privilege=[PrunletRegistryE2E]::EnableSecurity();Assert $privilege 'Native fixture controller lacks SeSecurityPrivilege'
 AssertLaunchLease $settings
 $session=Child @('registry-session','--minutes','30','--assert-native-windows')
 $stderr=$session.StandardError.ReadToEndAsync();$readyLine=$session.StandardOutput.ReadLineAsync()
 if(!$readyLine.Wait(30000)){throw 'Session readiness timeout'}
 $ready=$readyLine.GetAwaiter().GetResult()|ConvertFrom-Json -AsHashtable
 Assert ($ready.status-eq'registry_session_ready') ('Session readiness: '+$ready.error)
 $descriptor=ReadCapability (ReadJson $settings.highConfig).registrySessionFile
 Assert ($descriptor.authenticationId-ceq$tokenInfo.authenticationId) 'Administrator helper and session AuthID differ'
 SaveJson (Join-Path $PSScriptRoot 'controller-ready.json') @{success=$true;nonce=$settings.nonce;creationTicks=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks;controllerPid=$PID;powerShellHostPath=$powerShellHostPath;tokenInfo=$tokenInfo;authenticationId=$descriptor.authenticationId;sessionPid=$session.Id;packaged=$false;securityPrivilege=$privilege;scope=$ready.scope;expiresUtc=$ready.expiresUtc;sessionFile=$ready.sessionFile}
 while([IO.File]::Exists((Join-Path $PSScriptRoot 'start-claim.json'))-and![IO.File]::Exists((Join-Path $PSScriptRoot 'run-permit.json'))){AssertLaunchLease $settings;WaitLaunchChange}
 AssertLaunchLease $settings -RequirePermit
 $stop=$false
 while(!$stop){
  AssertLaunchLease $settings -RequirePermit
  if([IO.File]::Exists((Join-Path $PSScriptRoot 'stop-controller.json'))){break}
  foreach($file in [IO.Directory]::EnumerateFiles($PSScriptRoot,'request-*.json')){
   $request=ReadJson $file;$reply=Join-Path $PSScriptRoot ('reply-'+$request.id+'.json');if([IO.File]::Exists($reply)){continue}
   try{
    AssertLaunchLease $settings -RequirePermit
    Assert ($request.nonce-ceq$settings.nonce-and[long]$request.expiresTicks-gt[DateTime]::UtcNow.Ticks) 'Stale fixture request'
    $d=$request.data;$result=$null
    if($d.ContainsKey('leaf')){Assert ($d.leaf-match'^[a-z][a-z0-9-]{0,60}$') 'Unsafe fixture leaf'}
    switch($request.action){
     'start-admin-clients'{
      Assert ($null-eq$adminClient) 'Administrator clients already started'
      $adminClient=StartOwnedClient;$result=@{started=$true;pid=$adminClient.Id}
     }
     'admin-client-state'{
      Assert ($null-ne$adminClient) 'Administrator clients were not started'
      $result=@{finished=$adminClient.HasExited;exitCode=$(if($adminClient.HasExited){$adminClient.ExitCode}else{$null})}
     }
     'cleanup'{
      Assert ($null-eq$adminClient-or$adminClient.HasExited) 'Administrator clients still running; preserve fixture'
      $root=[PrunletRegistryE2E]::Open($script:RunRelative,64)
      if(!$root){$result=@{exitCode=0;alreadyAbsent=$true};break};$root.Dispose()
      Assert $ownsRoot 'Existing native root is not owned by this controller; preserve it'
      $cleanup=StartOwnedClient -Cleanup
      try{Assert ($cleanup.WaitForExit(180000)) 'Core fixture cleanup timeout';$result=@{exitCode=$cleanup.ExitCode}}finally{$cleanup.Dispose()}
     }
     'create'{
      Assert ($d.leaf-match'^[a-z][a-z0-9-]{0,60}$') 'Unsafe fixture leaf'
      if(!$ownsRoot){[SessionE2ENative]::CreateRunRoot($script:RunRelative);$ownsRoot=$true}
      $relative=$script:RunRelative+'\'+$d.leaf
      [SessionE2ENative]::CreateClass($relative,'Prunlet session 日本語 class')
      $k=[PrunletRegistryE2E]::Create($relative,64)
      try{[PrunletRegistryE2E]::Set($k,'',1,[Text.Encoding]::Unicode.GetBytes("default-value`0"));[PrunletRegistryE2E]::Set($k,'raw-日本語😀',0x1234,[byte[]]@(0,255,128,1,0));[PrunletRegistryE2E]::Set($k,'binary',3,[byte[]]@(0,255,17,128))}finally{$k.Dispose()}
      if($d.tree){$child=[PrunletRegistryE2E]::Create($relative+'\child\empty',64);$child.Dispose();[PrunletRegistryE2E]::SetLowIntegrityFixture($relative,64)}
      $result=@{path='HKEY_CURRENT_USER\'+$relative;leaf=$d.leaf}
     }
     'observe'{
      $relative=if($d.leaf){$script:RunRelative+'\'+$d.leaf}else{$script:RunRelative}
      $k=[PrunletRegistryE2E]::Open($relative,64,$true)
      if(!$k){$result=@{exists=$false}}else{try{$result=@{exists=$true;name=[SessionE2ENative]::Name($k);keyClass=[SessionE2ENative]::Class($k);snapshot=@([PrunletRegistryE2E]::Snapshot($relative,64));values=@{} };foreach($n in $k.GetValueNames()){$result.values[$n]=[PrunletRegistryE2E]::Value($k,$n)}}finally{$k.Dispose()}}
     }
     'set-collision'{
      Assert $ownsRoot 'No owned native fixture root'
      $relative=$script:RunRelative+'\'+$d.leaf;$k=[PrunletRegistryE2E]::Create($relative,64)
      try{[PrunletRegistryE2E]::Set($k,$d.valueName,3,[byte[]]@(99,98,97))}finally{$k.Dispose()};$result=@{created=$true}
     }
     'current-delete'{
      Assert $ownsRoot 'No owned native fixture root'
      Assert ($d.leaf-eq'oldscope-record') 'Current-scope fixture is not the assigned unique leaf'
      $currentPath=Join-Path $PSScriptRoot 'native-current-config.json';$currentData=ReadJson $settings.highConfig;$currentData.registryScope='current';$null=$currentData.Remove('registrySessionFile');SaveJson $currentPath $currentData
      $r=InvokePrunletCli @('registry-delete','--view','64','--value-name=binary','--',('HKEY_CURRENT_USER\'+$script:RunRelative+'\'+$d.leaf)) $currentPath
      Assert ($r.exitCode-eq 0-and$r.json.operationId) ('Native current setup: '+$r.stdout+$r.stderr);$null=$currentOperations.Add($r.json.operationId);$result=$r
     }
     'current-restore'{
      Assert ($currentOperations.Contains($d.operationId)) 'Unowned current-scope operation'
      $result=InvokePrunletCli @('restore',$d.operationId) (Join-Path $PSScriptRoot 'native-current-config.json')
     }
     'stop'{$stop=$true;$result=@{stopping=$true}}
     default{throw 'Unknown native controller action'}
    }
    SaveJson $reply @{success=$true;result=$result}
   }catch{SaveJson $reply @{success=$false;error=$_.Exception.Message}}
  }
  if(!$stop){WaitLaunchChange}
 }
}catch{SaveJson (Join-Path $PSScriptRoot 'controller-error.json') @{success=$false;error=$_.Exception.Message;pid=$PID;powerShellHostPath=$powerShellHostPath;tokenInfo=$tokenInfo};exit 1}
finally{
 if($adminClient){if(!$adminClient.HasExited){$adminClient.Kill($true);$adminClient.WaitForExit()};$adminClient.Dispose()}
 if($session){if(!$session.HasExited){$session.Kill($true);$session.WaitForExit()};$session.Dispose()}
 ClosePreparedPins
 SaveJson (Join-Path $PSScriptRoot 'controller-stopped.json') @{sessionStopped=$true;controllerPid=$PID}
}
