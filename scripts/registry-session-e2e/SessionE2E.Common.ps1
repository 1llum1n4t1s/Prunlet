$ErrorActionPreference='Stop'
if ([IO.File]::Exists((Join-Path $PSScriptRoot 'settings.json')) -and !$script:LaunchPins) {
 . (Join-Path $PSScriptRoot 'SessionLaunch.ps1')
 $script:LaunchPrepared=OpenPreparedPins (Join-Path $PSScriptRoot 'settings.json')
}

$utf8=[Text.UTF8Encoding]::new($false)
$env:TEMP=Join-Path $PSScriptRoot 'temp';$env:TMP=$env:TEMP
$env:RTK_TEE_DIR=Join-Path $PSScriptRoot 'temp';$env:RTK_LOG_DIR=$env:RTK_TEE_DIR
$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR=Join-Path $PSScriptRoot 'runtime-cache'
function SaveJson([string]$Path,$Data){
 $pending=$Path+'.'+[guid]::NewGuid().ToString('N')+'.pending';$stage='write'
 try{[IO.File]::WriteAllText($pending,($Data|ConvertTo-Json -Depth 90),$utf8);$stage='publish';[IO.File]::Move($pending,$Path,$true)}
 catch{
  # 一意replyの初回公開でも失敗し得るため、対象が不明な共有違反をreader競合と決め付けない。
  # 本文やcapabilityは記録せず、元pendingを保全して次の原因切分けに必要な位置だけ返す。
  $failure=$_;$cause=$failure.Exception;while($cause.InnerException){$cause=$cause.InnerException}
  function PublicationFileState([string]$File){try{$info=[IO.FileInfo]::new($File);if($info.Exists){return 'present,length='+$info.Length};return 'absent'}catch{return 'unavailable:'+ $_.Exception.GetType().Name}}
  $detail='Session JSON publication failed; stage='+$stage+'; source='+$pending+'; destination='+$Path+'; hresult='+$cause.HResult+'; win32='+($cause.HResult-band 0xffff)+'; sourceState='+(PublicationFileState $pending)+'; destinationState='+(PublicationFileState $Path)+'; stack='+$failure.ScriptStackTrace+'; error='+$cause.Message
  throw [IO.IOException]::new($detail,$cause)
 }
}
function ReadJson([string]$Path){[IO.File]::ReadAllText($Path)|ConvertFrom-Json -AsHashtable -Depth 90}
function ReadCapability([string]$Path){$f=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite-bor[IO.FileShare]::Delete));try{$r=[IO.StreamReader]::new($f);return ($r.ReadToEnd()|ConvertFrom-Json -AsHashtable -Depth 20)}finally{$f.Dispose()}}
function SavePrivateJson([string]$Path,$Data){
 SaveJson $Path $Data;$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
 $sd=[Security.AccessControl.FileSecurity]::new();$sd.SetOwner($sid);$sd.SetAccessRuleProtection($true,$false)
 foreach($s in @($sid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){$sd.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($s,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))}
 Set-Acl -LiteralPath $Path -AclObject $sd
}
function Assert([bool]$Condition,[string]$Message){if(!$Condition){throw $Message}}
function AssertPreparedSettings($Settings){
 $security=Get-Acl -LiteralPath $PSScriptRoot
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 Assert $security.AreAccessRulesProtected 'Run directory ACL inheritance was enabled'
 Assert ($security.GetOwner([Security.Principal.SecurityIdentifier]).Value-eq$sid) 'Run directory owner changed'
 $rules=$security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
 Assert ($rules.Count-eq 2) 'Run directory private ACL changed'
 foreach($rule in $rules){Assert ($rule.IdentityReference.Value-in@($sid,'S-1-5-18')-and$rule.AccessControlType-eq[Security.AccessControl.AccessControlType]::Allow-and$rule.FileSystemRights-eq[Security.AccessControl.FileSystemRights]::FullControl-and$rule.InheritanceFlags-eq[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'-and$rule.PropagationFlags-eq[Security.AccessControl.PropagationFlags]::None) 'Run directory private ACL changed'}
 Assert ([IO.Path]::IsPathFullyQualified($Settings.executablePath)-and[IO.File]::Exists($Settings.executablePath)) 'Prepared executable missing'
 Assert ($Settings.executableSha256-ceq(Get-FileHash -LiteralPath $Settings.executablePath -Algorithm SHA256).Hash) 'Prepared executable changed'
 Assert ([IO.Path]::IsPathFullyQualified($Settings.registryVerificationScriptPath)-and[IO.File]::Exists($Settings.registryVerificationScriptPath)) 'Registry verification script missing'
 Assert ($Settings.registryVerificationScriptSha256-ceq(Get-FileHash -LiteralPath $Settings.registryVerificationScriptPath -Algorithm SHA256).Hash) 'Registry verification script changed after Prepare'
 if($Settings.moveExecutablePath){Assert ([IO.Path]::IsPathFullyQualified($Settings.moveExecutablePath)-and[IO.File]::Exists($Settings.moveExecutablePath)) 'Move baseline executable missing';Assert ($Settings.moveExecutableSha256-ceq(Get-FileHash -LiteralPath $Settings.moveExecutablePath -Algorithm SHA256).Hash) 'Move baseline executable changed after Prepare'}
 foreach($dependency in @(@{path=$Settings.assemblyPath;hash=$Settings.assemblySha256},@{path=$Settings.legacyRegistryExecutablePath;hash=$Settings.legacyRegistryExecutableSha256})){if($dependency.path){Assert ([IO.Path]::IsPathFullyQualified($dependency.path)-and[IO.File]::Exists($dependency.path)) 'Prepared registry checkpoint dependency missing';Assert ($dependency.hash-ceq(Get-FileHash -LiteralPath $dependency.path -Algorithm SHA256).Hash) 'Prepared registry checkpoint dependency changed'}}
 Assert ($Settings.runRelative-match'^Software\\PrunletE2E\\[0-9a-f]{32}$') 'Unsafe prepared fixture scope'
 foreach($name in @('config','highConfig','currentConfig','recovery')){
  $path=[IO.Path]::GetFullPath($Settings[$name]);Assert ($path.StartsWith($PSScriptRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) 'Prepared path escaped run directory'
 }
 Assert ((ReadJson $Settings.currentConfig).registryScope-eq'current') 'Default current config changed scope'
 foreach($name in @('config','highConfig')){Assert ((ReadJson $Settings[$name]).registryScope-eq'nativeWindows') 'Native session scope was not explicitly selected'}
}
function Child([string[]]$Arguments,[string]$Config=$script:Config){
 $i=[Diagnostics.ProcessStartInfo]::new($script:ExecutablePath);$i.UseShellExecute=$false;$i.CreateNoWindow=$true
 $i.RedirectStandardInput=$true;$i.RedirectStandardOutput=$true;$i.RedirectStandardError=$true
 $i.StandardInputEncoding=$utf8;$i.StandardOutputEncoding=$utf8;$i.StandardErrorEncoding=$utf8
 $i.WorkingDirectory=$PSScriptRoot;$i.Environment['TEMP']=$env:TEMP;$i.Environment['TMP']=$env:TMP
 $i.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR']=Join-Path $PSScriptRoot 'runtime-cache'
 foreach($a in @('--config',$Config)+$Arguments){$i.ArgumentList.Add($a)}
 $p=[Diagnostics.Process]::new();$p.StartInfo=$i;$null=$p.Start();return $p
}
function InvokePrunletCli([string[]]$Arguments,[string]$Config=$script:Config){
 $p=Child $Arguments $Config
 try{$o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync();$p.StandardInput.Close()
  if(!$p.WaitForExit(180000)){$p.Kill($true);throw 'CLI timeout'}
  $out=$o.GetAwaiter().GetResult();$err=$e.GetAwaiter().GetResult();$j=$null
  try{$j=$out|ConvertFrom-Json -AsHashtable -Depth 90}catch{}
  if($p.ExitCode-eq 0-and$Arguments[0]-in@('registry-delete','restore','registry-reconcile')){foreach($item in $j.items){Assert ($item.kind-in@('registry-key','registry-value')) 'CLI registry result kind missing/incorrect'}}
  return @{exitCode=$p.ExitCode;stdout=$out;stderr=$err;json=$j;arguments=$Arguments}
 }finally{$p.Dispose()}
}
function McpStart {
 $p=Child @('mcp');$script:RpcId=0
 $reply=Rpc $p 'initialize' @{protocolVersion='2024-11-05';capabilities=@{};clientInfo=@{name='native-session-e2e';version='1'}}
 Assert ($null-ne$reply.result) 'MCP initialize rejected'
 $p.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}');$p.StandardInput.Flush()
 return $p
}
function Rpc($p,[string]$Method,$Params){
 $script:RpcId++;$id=$script:RpcId
 $request=@{jsonrpc='2.0';id=$id;method=$Method;params=$Params}|ConvertTo-Json -Depth 30 -Compress
 $p.StandardInput.WriteLine($request);$p.StandardInput.Flush()
 for($n=0;$n-lt 256;$n++){$t=$p.StandardOutput.ReadLineAsync();if(!$t.Wait(180000)){throw 'MCP timeout'};$line=$t.GetAwaiter().GetResult();if(!$line){throw 'MCP closed'};$r=$line|ConvertFrom-Json -AsHashtable -Depth 90;if($r.id-eq$id){return $r}}
 throw 'MCP notification limit'
}
function McpCall($p,[string]$Name,$Arguments){$r=Rpc $p 'tools/call' @{name=$Name;arguments=$Arguments};if(!$r.result.isError-and$Name-in@('delete_registry','restore_registry','reconcile_registry')){foreach($item in (McpData $r).items){Assert ($item.kind-in@('registry-key','registry-value')) 'MCP registry result kind missing/incorrect'}};return $r}
function McpData($Reply){
 if($Reply.result.structuredContent){return $Reply.result.structuredContent}
 foreach($c in $Reply.result.content){if($c.type-eq'text'){try{return ($c.text|ConvertFrom-Json -AsHashtable -Depth 90)}catch{}}}
 return $null
}
function McpStop($p){$p.StandardInput.Close();if(!$p.WaitForExit(15000)){$p.Kill($true);throw 'MCP shutdown timeout'};Assert ($p.ExitCode-eq 0) 'MCP shutdown exit';$p.Dispose()}
function LoadFixture{
 if(!('PrunletRegistryE2E'-as[type])){Add-Type -Path (Join-Path $PSScriptRoot 'FixtureNative.cs')}
 if(!('SessionE2ENative'-as[type])){Add-Type -Path (Join-Path $PSScriptRoot 'SessionFixture.cs')}
 if(!('SessionLaunchNative'-as[type])){Add-Type -Path (Join-Path $PSScriptRoot 'SessionLaunchNative.cs')}
 [PrunletRegistryE2E]::Configure($false,$script:RunRelative)
}
function NativeRequest([string]$Action,$Data=@{}){
 if($script:LaunchPrepared){AssertLaunchLease $script:LaunchPrepared -RequirePermit}
 $id=[guid]::NewGuid().ToString('N');$request=Join-Path $PSScriptRoot ('request-'+$id+'.json');$reply=Join-Path $PSScriptRoot ('reply-'+$id+'.json')
 # 発行途中のJSONをcontrollerが読まないよう、完成した一意ファイルを公開する。
 $pending=Join-Path $PSScriptRoot ('pending-'+$id+'.json')
 SaveJson $pending @{action=$Action;data=$Data;id=$id;nonce=(ReadJson (Join-Path $PSScriptRoot 'settings.json')).nonce;expiresTicks=[DateTime]::UtcNow.AddMinutes(3).Ticks};[IO.File]::Move($pending,$request)
 $sw=[Diagnostics.Stopwatch]::StartNew();while(![IO.File]::Exists($reply)){if($sw.Elapsed.TotalSeconds-gt 200){throw 'Native controller timeout'};Start-Sleep -Milliseconds 150}
 $r=ReadJson $reply;Assert $r.success ('Native controller: '+$r.error);return $r.result
}

function RegistryOperationDirectories([string]$Root){$namespace=Join-Path $Root '.registry-records-v1';if([IO.Directory]::Exists($namespace)){return @([IO.Directory]::EnumerateDirectories($namespace))};return @()}
