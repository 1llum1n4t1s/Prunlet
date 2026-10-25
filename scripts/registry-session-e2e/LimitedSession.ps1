param([Parameter(Mandatory)][string]$SettingsPath)
. (Join-Path $PSScriptRoot 'SessionE2E.Common.ps1')
$s=ReadJson $SettingsPath;$script:ExecutablePath=$s.executablePath;$script:Config=$s.config;$p=$null
AssertPreparedSettings $s
$powerShellHostPath=[IO.Path]::GetFullPath((Join-Path $PSHOME 'pwsh.exe'))
Assert ([IO.File]::Exists($powerShellHostPath)) 'Current PowerShell host executable missing'
Assert ($powerShellHostPath.Equals($s.powerShellHostPath,[StringComparison]::OrdinalIgnoreCase)) 'Normal PowerShell host differs from Prepare; use the prepared absolute desktop command'
$script:RunRelative=$s.runRelative
try{
 LoadFixture;$tokenInfo=[SessionE2ENative]::TokenInfo()
 Assert (!$tokenInfo.packaged) 'Normal desktop helper remains packaged; no fixture created'
 Assert (!$tokenInfo.isAppContainer) 'Normal desktop helper is AppContainer; no fixture created'
 $p=Child @('registry-session','--minutes','30','--assert-native-windows')
 $e=$p.StandardError.ReadToEndAsync();$r=$p.StandardOutput.ReadLineAsync();if(!$r.Wait(30000)){throw 'Limited session readiness timeout'}
 $ready=$r.GetAwaiter().GetResult()|ConvertFrom-Json -AsHashtable;Assert ($ready.status-eq'registry_session_ready') ('Limited readiness: '+$ready.error)
 $descriptor=ReadCapability (ReadJson $s.config).registrySessionFile
 Assert ($descriptor.authenticationId-ceq$tokenInfo.authenticationId) 'Normal helper and session AuthID differ'
 SaveJson (Join-Path $PSScriptRoot 'limited-ready.json') @{success=$true;pid=$PID;powerShellHostPath=$powerShellHostPath;tokenInfo=$tokenInfo;sessionPid=$p.Id;scope=$ready.scope;expiresUtc=$ready.expiresUtc;sessionFile=$ready.sessionFile;authenticationId=$descriptor.authenticationId}
 while(![IO.File]::Exists((Join-Path $PSScriptRoot 'stop-limited.json'))-and!$p.HasExited){Start-Sleep -Milliseconds 200}
}catch{SaveJson (Join-Path $PSScriptRoot 'limited-error.json') @{error=$_.Exception.Message;powerShellHostPath=$powerShellHostPath;tokenInfo=$tokenInfo};exit 1}
finally{if($p){if(!$p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()};SaveJson (Join-Path $PSScriptRoot 'limited-stopped.json') @{sessionStopped=$true;helperPid=$PID}}
