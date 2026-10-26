param([Parameter(Mandatory)][string]$SettingsPath,[switch]$Cleanup,[ValidatePattern('^[0-9a-f]{32}$')][string]$LaunchNonce)
$script:AutomaticLaunchNonce=$LaunchNonce
. (Join-Path $PSScriptRoot 'SessionE2E.Common.ps1')
$s=ReadJson $SettingsPath;$script:ExecutablePath=$s.executablePath;$script:Config=$s.highConfig
AssertPreparedSettings $s
$results=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[scriptblock]$Body){try{&$Body;$results.Add(@{name=$Name;passed=$true})}catch{$results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message})}}
try{
 $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());Assert ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Explicit client not admin'
 AssertLaunchLease $s -RequirePermit
 if($Cleanup){
  $r=InvokePrunletCli @('registry-delete','--view','64','--recursive','--',('HKEY_CURRENT_USER\'+$s.runRelative))
  SaveJson (Join-Path $PSScriptRoot 'cleanup-result.json') $r
  Assert ($r.exitCode-eq 0-and$r.json.operationId) 'Unique native fixture cleanup failed'
 }else{
  foreach($transport in @('cli','mcp')){
   Check ('elevated-'+$transport+'-class-full-security-roundtrip') {
    $leaf='key-'+$transport;$f=NativeRequest 'create' @{leaf=$leaf;tree=$true};$before=NativeRequest 'observe' @{leaf=$leaf}
    $p=$null
    try{
     if($transport-eq'cli'){
      $dry=InvokePrunletCli @('registry-delete','--dry-run','--view','64','--recursive','--',$f.path)
      Assert ($dry.exitCode-eq 0-and$dry.stdout-match'would_delete') 'Full-key CLI dry-run failed'
      Assert (($before.snapshot-join"`n")-ceq((NativeRequest 'observe' @{leaf=$leaf}).snapshot-join"`n")) 'Full-key CLI dry-run changed complete raw/security snapshot'
      $nonrecursive=InvokePrunletCli @('registry-delete','--view','64','--',$f.path)
      Assert ($nonrecursive.exitCode-ne 0) 'Nonrecursive CLI accepted a key with descendants'
      Assert (($before.snapshot-join"`n")-ceq((NativeRequest 'observe' @{leaf=$leaf}).snapshot-join"`n")) 'Nonrecursive CLI refusal changed complete raw/security snapshot'
      $d=InvokePrunletCli @('registry-delete','--view','64','--recursive','--',$f.path);Assert ($d.exitCode-eq 0-and$d.json.operationId) ('Elevated CLI delete: '+$d.stdout+$d.stderr);$id=$d.json.operationId
      Assert (!(NativeRequest 'observe' @{leaf=$leaf}).exists) 'Deleted native key remains'
      $r=InvokePrunletCli @('restore',$id);Assert ($r.exitCode-eq 0) ('Elevated CLI restore: '+$r.stdout+$r.stderr)
      $again=InvokePrunletCli @('restore',$id);Assert ($again.exitCode-eq 0-and$again.stdout-match'already_restored') 'Consumed CLI restore result'
      $raw=@{dryrun=$dry;nonrecursive=$nonrecursive;delete=$d;restore=$r;again=$again}
     }else{
      $p=McpStart
      $dry=McpCall $p 'delete_registry' @{path=$f.path;view='64';recursive=$true;dryRun=$true}
      Assert (!$dry.result.isError-and($dry|ConvertTo-Json -Depth 50)-match'would_delete') 'Full-key MCP dry-run failed'
      Assert (($before.snapshot-join"`n")-ceq((NativeRequest 'observe' @{leaf=$leaf}).snapshot-join"`n")) 'Full-key MCP dry-run changed complete raw/security snapshot'
      $nonrecursive=McpCall $p 'delete_registry' @{path=$f.path;view='64'}
      Assert $nonrecursive.result.isError 'Nonrecursive MCP accepted a key with descendants'
      Assert (($before.snapshot-join"`n")-ceq((NativeRequest 'observe' @{leaf=$leaf}).snapshot-join"`n")) 'Nonrecursive MCP refusal changed complete raw/security snapshot'
      $d=McpCall $p 'delete_registry' @{path=$f.path;view='64';recursive=$true};$data=McpData $d
      Assert (!$d.result.isError-and$data.operationId) ('Elevated MCP delete: '+($d|ConvertTo-Json -Depth 30));$id=$data.operationId
      Assert (!(NativeRequest 'observe' @{leaf=$leaf}).exists) 'MCP-deleted native key remains'
      $r=McpCall $p 'restore_registry' @{operationId=$id};Assert (!$r.result.isError) 'Elevated MCP restore failure'
      $again=McpCall $p 'restore_registry' @{operationId=$id};Assert (!$again.result.isError-and($again|ConvertTo-Json -Depth 30)-match'already_restored') 'Consumed MCP restore result'
      $raw=@{dryrun=$dry;nonrecursive=$nonrecursive;delete=$d;restore=$r;again=$again}
     }
     $after=NativeRequest 'observe' @{leaf=$leaf};Assert (($before.snapshot-join"`n")-ceq($after.snapshot-join"`n")) 'Full owner/group/DACL/SACL/raw snapshot mismatch';Assert ($before.keyClass-ceq$after.keyClass) 'Registry key class mismatch'
     Assert (![IO.File]::Exists((Join-Path (Join-Path $s.recovery '.registry-records-v1') ($id+'\registry-snapshot.json')))) 'Restored snapshot not consumed'
     $rec=InvokePrunletCli @('registry-reconcile',$id);Assert ($rec.exitCode-eq 0-and$rec.json.items[0].status-eq'restored') 'Reconcile restored mismatch'
     SaveJson (Join-Path $PSScriptRoot ($leaf+'-result.json')) @{operationId=$id;raw=$raw;before=$before;after=$after;reconcile=$rec}
    }finally{if($p){McpStop $p}}
   }
  }
  Check 'administrator-default-hkcu-registry-recovery-suite' {
   Assert (![string]::IsNullOrWhiteSpace($s.moveExecutablePath)) 'Full default HKCU suite requires Prepare -MoveExecutablePath with the genuine schema4 baseline'
   Assert (![string]::IsNullOrWhiteSpace($s.assemblyPath)-and![string]::IsNullOrWhiteSpace($s.legacyRegistryExecutablePath)) 'Full registry checkpoint suite requires the prepared candidate DLL and genuine schema5 baseline'
   $suiteOutput=Join-Path $PSScriptRoot 'registry-default';$suiteReport=Join-Path $PSScriptRoot 'registry-default-report.json'
   $hostPath=[IO.Path]::GetFullPath((Join-Path $PSHOME 'pwsh.exe'))
   Assert ($hostPath.Equals($s.powerShellHostPath,[StringComparison]::OrdinalIgnoreCase)) 'Administrator client host differs from Prepare'
   $info=[Diagnostics.ProcessStartInfo]::new($hostPath);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WorkingDirectory=$PSScriptRoot
   $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.StandardOutputEncoding=$utf8;$info.StandardErrorEncoding=$utf8
   $info.Environment['TEMP']=$env:TEMP;$info.Environment['TMP']=$env:TMP
   foreach($argument in @('-NoProfile','-File',$s.registryVerificationScriptPath,'-ExecutablePath',$s.executablePath,'-MoveExecutablePath',$s.moveExecutablePath,'-RegistryFixtureRoot','HKCU\Software\PrunletE2E','-OutputDirectory',$suiteOutput,'-ReportPath',$suiteReport)){$info.ArgumentList.Add($argument)}
   if($s.assemblyPath){$info.ArgumentList.Add('-AssemblyPath');$info.ArgumentList.Add($s.assemblyPath)}
   if($s.legacyRegistryExecutablePath){$info.ArgumentList.Add('-LegacyRegistryExecutablePath');$info.ArgumentList.Add($s.legacyRegistryExecutablePath)}
   $suite=[Diagnostics.Process]::new();$suite.StartInfo=$info
   try{
    $null=$suite.Start();$stdout=$suite.StandardOutput.ReadToEndAsync();$stderr=$suite.StandardError.ReadToEndAsync()
    Assert ($suite.WaitForExit(600000)) 'Default HKCU registry suite timeout'
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'registry-default.stdout.log'),$stdout.GetAwaiter().GetResult(),$utf8)
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'registry-default.stderr.log'),$stderr.GetAwaiter().GetResult(),$utf8)
    Assert ($suite.ExitCode-eq 0) 'Default HKCU registry suite process failed'
    $report=ReadJson $suiteReport
    Assert ($report.failed-eq 0-and$report.skipped-eq 0-and$report.excludedCount-eq 0-and$report.passed-ge 37-and$report.passed-eq$report.results.Count) 'Default HKCU registry suite is incomplete or failed'
    Assert (@($report.results|Where-Object {$_.name-like'registry-control-*'-or$_.name-like'registry-publication-*'}).Count-eq12) 'Registry crash/control coverage was incomplete'
    Assert ($report.registryFixtureRoot-ceq'HKEY_CURRENT_USER\Software\PrunletE2E'-and$report.createdFixture-and$report.cleanup.attempted-and!$report.cleanup.remainingRegistryPath-and!$report.cleanup.error) 'Default HKCU fixture/preflight/cleanup was not verified'
    Assert ($report.preflight.Count-eq 2-and@($report.preflight|Where-Object {!$_.Available}).Count-eq 0-and@($report.preflight|Where-Object {$_.View-eq 32}).Count-eq 1-and@($report.preflight|Where-Object {$_.View-eq 64}).Count-eq 1) 'Default HKCU transaction preflight failed'
   }finally{if(!$suite.HasExited){$suite.Kill($true);$suite.WaitForExit()};$suite.Dispose()}
  }
  SaveJson (Join-Path $PSScriptRoot 'elevated-client-results.json') @{results=@($results);passed=@($results|Where-Object passed).Count;failed=@($results|Where-Object {!$_.passed}).Count}
 }
}catch{SaveJson (Join-Path $PSScriptRoot $(if($Cleanup){'cleanup-error.json'}else{'elevated-client-error.json'})) @{error=$_.Exception.Message};exit 1}
