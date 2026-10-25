$script:LaunchScopeRoot=$PSScriptRoot
# Prepareが固定した入力を、書込み・renameを許さないread handleで実行終了まで保持する。
function OpenPreparedPins([string]$PreparedSettingsPath) {
 $held=[Collections.Generic.List[IDisposable]]::new()
 try {
  AssertPrivateLaunchRoot
  AssertNoLaunchReparse $PreparedSettingsPath
  $settingsHandle=[IO.File]::Open($PreparedSettingsPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$held.Add($settingsHandle)
  $reader=[IO.StreamReader]::new($settingsHandle,[Text.Encoding]::UTF8,$true,1024,$true)
  try{$prepared=$reader.ReadToEnd()|ConvertFrom-Json -AsHashtable -Depth 90}finally{$reader.Dispose()}
  if($prepared.schema-ne 2){throw 'Prepare schema 2 is required; prepare a new scope.'}
  foreach($inputEntry in $prepared.inputs){
   $inputPath=[string]$inputEntry.path
   if(![IO.Path]::IsPathFullyQualified($inputPath)){throw 'Prepared input must be absolute.'}
   AssertNoLaunchReparse $inputPath
   $handle=[IO.File]::Open($inputPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$held.Add($handle)
   $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($handle));$handle.Position=0
   if($digest-cne$inputEntry.sha256){throw 'Prepared input changed.'}
  }
  $script:LaunchPins=$held
  return $prepared
 }catch{foreach($handle in $held){$handle.Dispose()};throw}
}
function ClosePreparedPins {if($script:LaunchPins){foreach($handle in $script:LaunchPins){$handle.Dispose()};$script:LaunchPins=$null}}
function AssertNoLaunchReparse([string]$Path){
 $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
 while($item){if($item.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Prepared path contains a reparse point.'};$item=if($item-is[IO.FileInfo]){$item.Directory}else{$item.Parent}}
}
function NewLaunchRecord([string]$Path,$Value){
 $pending=$Path+'.'+[guid]::NewGuid().ToString('N')+'.pending'
 $record=[IO.File]::Open($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$bytes=[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 30 -Compress));$record.Write($bytes);$record.Flush($true)}finally{$record.Dispose()}
 # 完成した記録だけを非上書きrenameで公開する。同時claimは一方だけが成功する。
 [IO.File]::Move($pending,$Path,$false)
}
function TestLaunchProcess($Record){
 try{$process=[Diagnostics.Process]::GetProcessById([int]$Record.pid);try{return !$process.HasExited-and$process.StartTime.ToUniversalTime().Ticks-eq[long]$Record.creationTicks}finally{$process.Dispose()}}catch{return $false}
}
function LaunchProcessRecord {return @{pid=$PID;creationTicks=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks}}
function ReadLaunchRecord([string]$Name){return [IO.File]::ReadAllText((Join-Path $script:LaunchScopeRoot $Name))|ConvertFrom-Json -AsHashtable}
function AssertLaunchLease($Prepared,[switch]$RequirePermit){
 if($Prepared.nonce-cnotmatch'^[0-9a-f]{32}$'){throw 'Prepared launch nonce is invalid.'}
 $claimPath=Join-Path $script:LaunchScopeRoot 'start-claim.json'
 if($script:AutomaticLaunchNonce){
  if($script:AutomaticLaunchNonce-cne$Prepared.nonce){throw 'Automatic launch nonce differs.'}
  $script:AutomaticLaunchObserved=$true
 }
 if(![IO.File]::Exists($claimPath)){
  if($script:AutomaticLaunchObserved){throw 'Automatic launch claim disappeared.'}
  return # 自動起動由来でない明示desktop起動だけの診断互換経路。
 }
 # 一度でも自動起動claimを観測したプロセスは、後からmanual経路へ戻さない。
 $script:AutomaticLaunchObserved=$true
 $claim=ReadLaunchRecord 'start-claim.json'
 if($claim.nonce-cne$Prepared.nonce-or[IO.File]::Exists((Join-Path $script:LaunchScopeRoot 'start-cancelled.json'))){throw 'Launch was cancelled or nonce differs.'}
 $commitPath=Join-Path $script:LaunchScopeRoot 'start-committed.json';$permitPath=Join-Path $script:LaunchScopeRoot 'run-permit.json'
 if(![IO.File]::Exists($commitPath)){
  if([DateTime]::UtcNow.Ticks-ge[long]$claim.expiresTicks-or!(TestLaunchProcess $claim)){throw 'Launch request expired or Start caller exited.'}
  if($RequirePermit){throw 'Start has not committed.'};return
 }
 $commit=ReadLaunchRecord 'start-committed.json'
 if($commit.nonce-cne$Prepared.nonce){throw 'Commit nonce differs.'}
 if(![IO.File]::Exists($permitPath)){
  if([DateTime]::UtcNow.Ticks-ge[long]$commit.handoffExpiresTicks){throw 'Run handoff expired.'}
  if($RequirePermit){throw 'Run permit missing.'};return
 }
 $permit=ReadLaunchRecord 'run-permit.json'
 if($permit.nonce-cne$Prepared.nonce-or!(TestLaunchProcess $permit)){throw 'Run caller exited or permit differs.'}
}
function WaitLaunchChange([int]$Milliseconds=1000){
 $watcher=[IO.FileSystemWatcher]::new($script:LaunchScopeRoot,'*.json');$watcher.EnableRaisingEvents=$true
 try{$null=$watcher.WaitForChanged([IO.WatcherChangeTypes]::All,$Milliseconds)}finally{$watcher.Dispose()}
}
function AssertLaunchReady($Prepared){
 $caller=[SessionE2ENative]::TokenInfo()
 AssertLaunchRole $Prepared $false
 foreach($role in @(@{file='limited-ready.json';admin=$false;config=$Prepared.config},@{file='controller-ready.json';admin=$true;config=$Prepared.highConfig})){
  $ready=ReadLaunchRecord $role.file
  $configName=if($role.admin){'highConfig'}else{'config'}
  if([SessionE2ENative]::Fingerprint([IO.File]::ReadAllText($role.config))-cne$Prepared.configFingerprints[$configName]){throw 'Prepared native config changed.'}
  $descriptor=ReadCapability (ReadJson $role.config).registrySessionFile
  if(!$ready.success-or$ready.nonce-cne$Prepared.nonce-or!$ready.tokenInfo-or$ready.tokenInfo.packaged-or$ready.tokenInfo.isAppContainer-or$ready.tokenInfo.isAdministrator-ne$role.admin){throw 'Desktop helper tier/nonce differs.'}
  $server=[SessionLaunchNative]::ProcessInfo([int]$descriptor.serverProcessId)
  if($server.creationFileTime-ne$descriptor.serverCreationTime-or!$server.path.Equals($Prepared.executablePath,[StringComparison]::OrdinalIgnoreCase)){throw 'Actual session process differs.'}
  foreach($field in @('ownerSid','authenticationId','windowsSessionId','isAdministrator','packaged','isAppContainer')){if($server[$field]-cne$ready.tokenInfo[$field]){throw 'Actual server token differs.'}}
  $helperPid=if($role.admin){$ready.controllerPid}else{$ready.pid}
  $actual=[SessionLaunchNative]::ProcessInfo([int]$helperPid)
  foreach($tokenField in @('ownerSid','authenticationId','windowsSessionId','isAdministrator','packaged','isAppContainer')){if($actual[$tokenField]-cne$ready.tokenInfo[$tokenField]){throw 'Desktop helper actual token differs.'}}
  if($actual.creationTicks-ne$ready.creationTicks-or!$actual.path.Equals($Prepared.powerShellHostPath,[StringComparison]::OrdinalIgnoreCase)){throw 'Desktop helper actual process differs.'}
  if($descriptor.authenticationId-cne$actual.authenticationId-or$descriptor.scope.ownerSid-cne$caller.ownerSid-or$descriptor.windowsSessionId-ne$caller.windowsSessionId-or$descriptor.scope.kind-cne'nativeWindows'-or$descriptor.configurationSha256-cne[SessionE2ENative]::Fingerprint([IO.File]::ReadAllText($role.config))-or!$descriptor.executableSha256.Equals($Prepared.executableSha256,[StringComparison]::OrdinalIgnoreCase)-or$ready.sessionPid-ne$descriptor.serverProcessId-or(GetLaunchUtcTicks $descriptor.expiresUtc)-le[DateTime]::UtcNow.AddMinutes(8).Ticks){throw 'Prepared native descriptor differs.'}
  if(!$role.admin-and$actual.authenticationId-cne$caller.authenticationId){throw 'Normal session authentication differs.'}
  if($role.admin-and$actual.authenticationId-ceq$caller.authenticationId){throw 'Administrator session authentication is not distinct.'}
 }
}

function StartPreparedDesktopSessions($Prepared,[string]$ScopeRoot,[string]$PreparedSettingsPath){
 $claim=LaunchProcessRecord;$claim.nonce=$Prepared.nonce;$claim.expiresTicks=[DateTime]::UtcNow.AddMinutes(3).Ticks
 foreach($existing in @('controller-ready.json','limited-ready.json','controller-error.json','limited-error.json','run-started.json','run-permit.json','start-committed.json','start-cancelled.json')){if([IO.File]::Exists((Join-Path $ScopeRoot $existing))){throw 'Scope has prior launch output; prepare a new scope.'}}
 if(@([IO.Directory]::EnumerateFiles($ScopeRoot,'request-*.json')).Count){throw 'Scope has prior fixture requests.'}
 $caller=[SessionE2ENative]::TokenInfo();AssertLaunchRole $Prepared $false;$desktop=[SessionLaunchNative]::DesktopInfo()
 if($caller.isAdministrator-or$caller.isAppContainer){throw 'Start requires a normal caller token.'}
 $explorer=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)) 'explorer.exe'
 if(!$desktop.path.Equals($explorer,[StringComparison]::OrdinalIgnoreCase)-or$desktop.packaged-or$desktop.isAppContainer-or$desktop.isAdministrator){throw 'Desktop shell is not the normal Windows explorer.'}
 foreach($field in @('ownerSid','authenticationId','windowsSessionId')){if($caller[$field]-cne$desktop[$field]){throw 'Desktop shell identity differs from normal caller.'}}
 foreach($launchPath in @($Prepared.powerShellHostPath,$PreparedSettingsPath,(Join-Path $ScopeRoot 'LimitedSession.ps1'),(Join-Path $ScopeRoot 'NativeController.ps1'))){if(![IO.Path]::IsPathFullyQualified($launchPath)-or$launchPath-match'["\x00-\x1f]'){throw 'Unsafe prepared launch path.'};AssertNoLaunchReparse $launchPath}
 NewLaunchRecord (Join-Path $ScopeRoot 'start-claim.json') $claim
 try{
  $shell=New-Object -ComObject Shell.Application
  $hwnd=0;$desktopWindow=$shell.Windows().FindWindowSW(0,0,8,[ref]$hwnd,1)
  if(!$desktopWindow-or[long]$hwnd-ne[long]$desktop.hwnd){throw 'COM desktop window differs from explorer.'}
  $desktopApplication=$desktopWindow.Document.Application
  foreach($role in @(@{script='LimitedSession.ps1';verb='open'},@{script='NativeController.ps1';verb='runas'})){
   AssertLaunchLease $Prepared
   $arguments='-NoProfile -File "'+(Join-Path $ScopeRoot $role.script)+'" -SettingsPath "'+$PreparedSettingsPath+'" -LaunchNonce '+$Prepared.nonce
   # UACの本人同意だけをWindowsへ委ねる。任意コマンド・package側fallbackを持たない。
   $desktopApplication.ShellExecute($Prepared.powerShellHostPath,$arguments,$ScopeRoot,$role.verb,0)
  }
  while(!([IO.File]::Exists((Join-Path $ScopeRoot 'limited-ready.json'))-and[IO.File]::Exists((Join-Path $ScopeRoot 'controller-ready.json')))){
   AssertLaunchLease $Prepared
   foreach($failure in @('limited-error.json','controller-error.json','limited-stopped.json','controller-stopped.json')){if([IO.File]::Exists((Join-Path $ScopeRoot $failure))){throw 'Desktop helper failed before ready.'}}
   WaitLaunchChange
  }
  AssertLaunchLease $Prepared;AssertLaunchReady $Prepared
  NewLaunchRecord (Join-Path $ScopeRoot 'start-committed.json') @{nonce=$Prepared.nonce;handoffExpiresTicks=[DateTime]::UtcNow.AddMinutes(5).Ticks}
  $result=@{status='started';nonce=$Prepared.nonce;normal=ReadLaunchRecord 'limited-ready.json';administrator=ReadLaunchRecord 'controller-ready.json';runPermitRequired=$true;handoffMinutes=5}
  NewLaunchRecord (Join-Path $ScopeRoot 'start-result.json') $result
  $result|ConvertTo-Json -Depth 30
 }catch{
  if(![IO.File]::Exists((Join-Path $ScopeRoot 'start-cancelled.json'))){NewLaunchRecord (Join-Path $ScopeRoot 'start-cancelled.json') @{nonce=$Prepared.nonce;cancelledUtc=[DateTimeOffset]::UtcNow.ToString('O')}}
  foreach($stopName in @('stop-limited.json','stop-controller.json')){if(![IO.File]::Exists((Join-Path $ScopeRoot $stopName))){NewLaunchRecord (Join-Path $ScopeRoot $stopName) @{nonce=$Prepared.nonce}}}
  NewLaunchRecord (Join-Path $ScopeRoot 'start-error.json') @{status='failed';stopRequested=$true;stoppedConfirmed=$false;error=$_.Exception.Message}
  throw
 }
}

function GetLaunchUtcTicks($Value){
 if($Value-is[DateTime]){return $Value.ToUniversalTime().Ticks}
 if($Value-is[DateTimeOffset]){return $Value.UtcTicks}
 return [DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture).UtcTicks
}

function AssertLaunchRole($Prepared,[bool]$Administrator){
 $actual=[SessionE2ENative]::TokenInfo()
 if($actual.isAdministrator-ne$Administrator-or$actual.isAppContainer-or($actual.packaged-and$Administrator)){throw 'Helper actual token tier/package differs.'}
 foreach($field in @('ownerSid','windowsSessionId')){if($actual[$field]-cne$Prepared.preparedToken[$field]){throw 'Prepared caller SID/session differs.'}}
 if(!$Administrator-and$actual.authenticationId-cne$Prepared.preparedToken.authenticationId){throw 'Prepared normal caller AuthID differs.'}
 if($Administrator-and$actual.authenticationId-ceq$Prepared.preparedToken.authenticationId){throw 'Administrator AuthID is not distinct.'}
}

function AssertPrivateLaunchRoot {
 AssertNoLaunchReparse $script:LaunchScopeRoot
 $security=Get-Acl -LiteralPath $script:LaunchScopeRoot
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 if(!$security.AreAccessRulesProtected-or$security.GetOwner([Security.Principal.SecurityIdentifier]).Value-ne$sid){throw 'Prepared scope owner/inheritance differs.'}
 $rules=$security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
 if($rules.Count-ne 2){throw 'Prepared scope private ACL differs.'}
 foreach($rule in $rules){if($rule.IdentityReference.Value-notin@($sid,'S-1-5-18')-or$rule.AccessControlType-ne[Security.AccessControl.AccessControlType]::Allow-or$rule.FileSystemRights-ne[Security.AccessControl.FileSystemRights]::FullControl-or$rule.InheritanceFlags-ne[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'-or$rule.PropagationFlags-ne[Security.AccessControl.PropagationFlags]::None){throw 'Prepared scope private ACL differs.'}}
}
