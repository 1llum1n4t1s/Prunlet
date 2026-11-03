param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'scripts\Verification-Common.ps1')
foreach($path in @($ExecutablePath,$SourceRoot,$OutputDirectory,$ReportPath)){if(![IO.Path]::IsPathFullyQualified($path)){throw 'Current-context verification requires absolute paths'}}
foreach($path in @($OutputDirectory,$ReportPath)){
 Assert-VerificationDestination $path @($SourceRoot,(Join-Path $env:USERPROFILE '.codex'))
 if(![IO.Path]::GetPathRoot($path).Equals('D:\',[StringComparison]::OrdinalIgnoreCase)-or(Test-Path -LiteralPath $path)){throw 'Current-context verification requires unused external D: output'}
}
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$env:TEMP=Join-Path $OutputDirectory 'temp';$env:TMP=$env:TEMP;$null=[IO.Directory]::CreateDirectory($env:TEMP)
$utf8=[Text.UTF8Encoding]::new($false)
$fixtureSource=Join-Path $SourceRoot 'scripts\Verify-RegistryRecovery.ps1'
$match=[regex]::Matches([IO.File]::ReadAllText($fixtureSource),"(?s)\`$nativeSource = @'\r?\n(.*?)\r?\n'@")
if($match.Count-ne1){throw 'Native fixture source extraction was not unique'}
Add-Type -TypeDefinition $match[0].Groups[1].Value
Add-Type -TypeDefinition @'
using System;using System.ComponentModel;using System.Runtime.InteropServices;using Microsoft.Win32;
public static class CurrentCandidateObservation {
 [DllImport("advapi32.dll")]static extern int RegGetKeySecurity(IntPtr key,uint info,byte[] bytes,ref uint count);
 [DllImport("ntdll.dll")]static extern int NtQueryKey(IntPtr key,int kind,byte[] bytes,uint count,out uint required);
 public static string Security7(RegistryKey key){uint size=0;int error=RegGetKeySecurity(key.Handle.DangerousGetHandle(),7,null,ref size);if(error!=0&&error!=122)throw new Win32Exception(error);byte[] bytes=new byte[size];error=RegGetKeySecurity(key.Handle.DangerousGetHandle(),7,bytes,ref size);if(error!=0)throw new Win32Exception(error);return Convert.ToBase64String(bytes);}
 public static string Name(RegistryKey key){uint count=0;NtQueryKey(key.Handle.DangerousGetHandle(),3,null,0,out count);if(count<4||count>131072)throw new Exception("Invalid key name size");byte[] bytes=new byte[count];int status=NtQueryKey(key.Handle.DangerousGetHandle(),3,bytes,count,out count);if(status<0)throw new Exception("NtQueryKey "+status);return System.Text.Encoding.Unicode.GetString(bytes,4,BitConverter.ToInt32(bytes,0));}
}
'@
function Save([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 60),$utf8)}
function Assert([bool]$Condition,[string]$Message){if(!$Condition){throw $Message}}
function StartCandidate([string[]]$Arguments,[string]$InputText=''){
 $info=[Diagnostics.ProcessStartInfo]::new($ExecutablePath);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 foreach($value in @('--config',$script:Config)+$Arguments){$info.ArgumentList.Add($value)}
 $process=[Diagnostics.Process]::Start($info)
 try{$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync();if($InputText){$process.StandardInput.Write($InputText)};$process.StandardInput.Close();if(!$process.WaitForExit(30000)){$process.Kill($true);throw 'Current-context candidate timed out'};return @{exitCode=$process.ExitCode;stdout=$out.GetAwaiter().GetResult();stderr=$err.GetAwaiter().GetResult()}}
 finally{if(!$process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose()}
}
function Metadata {
 @((Get-ChildItem -LiteralPath $metadata -Recurse -File -Force|Sort-Object FullName)|ForEach-Object{$_.FullName.Substring($metadata.Length)+':'+(Get-FileHash -LiteralPath $_.FullName).Hash})-join"`n"
}
function Observe([string]$Relative,[int]$View){
 $key=[PrunletRegistryE2E]::Open($Relative,$View)
 if(!$key){return @{relative=$Relative;view=$View;exists=$false}}
 try{$values=@();foreach($name in ($key.GetValueNames()|Sort-Object -CaseSensitive)){$values+=@{name=$name;raw=[PrunletRegistryE2E]::Value($key,$name)}};return @{relative=$Relative;view=$View;exists=$true;nativeName=[CurrentCandidateObservation]::Name($key);security7=[CurrentCandidateObservation]::Security7($key);lastWrite=[PrunletRegistryE2E]::KeyLastWrite($key);values=$values}}
 finally{$key.Dispose()}
}
$relative='Software\PrunletE2E\'+[guid]::NewGuid().ToString('N')
[PrunletRegistryE2E]::Configure($false,$relative)
$preflight=@([PrunletRegistryE2E]::PreflightKtm(64),[PrunletRegistryE2E]::PreflightKtm(32))
Assert (@($preflight|Where-Object{$_.NativeError-ne6801}).Count-eq0) 'Current-only refusal fixture requires read-only 6801 in both views; no fixture was created'
$metadata=Join-Path $OutputDirectory 'metadata';$null=[IO.Directory]::CreateDirectory($metadata)
$script:Config=Join-Path $OutputDirectory 'config.json'
$init=StartCandidate @('init','--backup-directory',$metadata);Assert ($init.exitCode-eq0) 'Current candidate init failed'
$migrate=StartCandidate @('migrate','--apply');$migrated=$migrate.stdout|ConvertFrom-Json -AsHashtable
Assert ($migrate.exitCode-eq0-and$migrated.registryReady) 'Current registry namespace was not prepared'
$checks=[Collections.Generic.List[object]]::new();$cases=[Collections.Generic.List[object]]::new()
foreach($transport in @('cli','mcp')){foreach($view in @(64,32)){foreach($dry in @($true,$false)){
 $name=$transport+'-'+$view+'-'+$(if($dry){'dry'}else{'actual'});$path=$relative+'\'+$name
 $existing=[PrunletRegistryE2E]::Open($path,$view);if($existing){$existing.Dispose();throw 'Unique current fixture already exists'}
 $key=[PrunletRegistryE2E]::Create($path,$view)
 try{[PrunletRegistryE2E]::Set($key,'sentinel',3,[byte[]](0,1,127,128,251,255))}finally{$key.Dispose()}
 $cases.Add(@{name=$name;transport=$transport;view=$view;dry=$dry;relative=$path;path=('HKEY_CURRENT_USER\'+$path)})
}}}
$before=@($cases|ForEach-Object{Observe $_.relative $_.view});Save (Join-Path $OutputDirectory 'before.json') $before
$metadataBefore=Metadata
foreach($case in $cases){
 if($case.transport-eq'cli'){
  $arguments=@('registry-delete','--view',[string]$case.view,'--value-name=sentinel');if($case.dry){$arguments+='--dry-run'};$arguments+=@('--',$case.path)
  $process=StartCandidate $arguments;$data=$process.stdout|ConvertFrom-Json -AsHashtable
  $valid=$process.exitCode-ne0-and$data.items[0].status-ceq'failed'-and$data.items[0].error-match'6801'-and!$data.operationId
 }else{
  $request=@{jsonrpc='2.0';id=2;method='tools/call';params=@{name='delete_registry';arguments=@{path=$case.path;view=[string]$case.view;valueName='sentinel';dryRun=$case.dry}}}
  $wire=@('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}','{"jsonrpc":"2.0","method":"notifications/initialized"}',($request|ConvertTo-Json -Depth 20 -Compress),'{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_operations","arguments":{}}}')-join"`n"
  $process=StartCandidate @('mcp') ($wire+"`n")
  $frames=@($process.stdout-split"`n"|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -AsHashtable -Depth 60});$reply=@($frames|Where-Object{$_.id-eq2})[0];$data=$reply.result.structuredContent;$operations=@($frames|Where-Object{$_.id-eq3})[0]
  $valid=$process.exitCode-eq0-and$reply.result.isError-and$data.items[0].status-ceq'failed'-and$data.items[0].error-match'6801'-and!$data.operationId-and!$operations.result.isError-and$operations.result.structuredContent.operations.Count-eq0
 }
 $after=Observe $case.relative $case.view;$original=@($before|Where-Object{$_.relative-ceq$case.relative})[0]
 $same=($original|ConvertTo-Json -Depth 25 -Compress)-ceq($after|ConvertTo-Json -Depth 25 -Compress)
 $noRecords=(Metadata)-ceq$metadataBefore
 $checks.Add(@{name=$case.name;passed=($valid-and$same-and$noRecords);transport=$case.transport;view=$case.view;dryRun=$case.dry;response=$process;result=$data;originalPreserved=$same;noRecords=$noRecords;nativeSuccessVerified=$false})
 Save (Join-Path $OutputDirectory ($case.name+'.json')) $checks[-1]
}
$after=@($cases|ForEach-Object{Observe $_.relative $_.view});Save (Join-Path $OutputDirectory 'after.json') $after
$failed=@($checks|Where-Object{!$_.passed}).Count
$report=@{passed=$checks.Count-$failed;failed=$failed;candidate=$ExecutablePath;candidateSha256=(Get-FileHash $ExecutablePath).Hash;preflight=$preflight;checks=@($checks);remainingRegistryPath=('HKEY_CURRENT_USER\'+$relative);cleanup='Retained owned fixture; current context is 6801. No alternate delete or automatic resubmission.';scope='Current-context refusal only; raw value/last-write/owner/group/DACL preserved. SACL and native success require the formal native suite.';nativeSuccessVerified=$false}
Save $ReportPath $report
@{passed=$report.passed;failed=$failed;report=$ReportPath;remainingRegistryPath=$report.remainingRegistryPath}|ConvertTo-Json
if($failed){exit 1}
