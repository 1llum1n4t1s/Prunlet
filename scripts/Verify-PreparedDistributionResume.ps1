#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CurrentPackagePath,
    [Parameter(Mandatory)][string]$ExpectedCurrentPackageSha256,
    [Parameter(Mandatory)][string]$LegacyPackagePath,
    [Parameter(Mandatory)][string]$ExpectedLegacyPackageSha256,
    [Parameter(Mandatory)][string]$LegacyLauncherPath,
    [Parameter(Mandatory)][string]$ExpectedLegacyLauncherSha256,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach($path in @($OutputDirectory,$ReportPath)){Assert-VerificationDestination $path @($repoRoot,(Join-Path $env:USERPROFILE '.codex'));if(Test-Path -LiteralPath $path){throw 'Verification outputs must be fresh.'}}
foreach($pair in @(@($CurrentPackagePath,$ExpectedCurrentPackageSha256),@($LegacyPackagePath,$ExpectedLegacyPackageSha256),@($LegacyLauncherPath,$ExpectedLegacyLauncherSha256))){if((Get-FileHash -LiteralPath $pair[0]).Hash-ine$pair[1]){throw 'Caller-pinned input differs.'}}
$null=New-Item -ItemType Directory -Path $OutputDirectory,(Split-Path $ReportPath -Parent) -Force
$evidence=Join-Path $OutputDirectory 'evidence';$null=New-Item -ItemType Directory -Path $evidence
# 既存のZIP・実プロセス検証helperをそのまま利用し、Core成功の代用品を作らない。
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Verify-RustStartupUpdate.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('Assert-Startup','Read-Package','Start-Mcp','Finish-Mcp')){$node=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$name},$true);if(!$node){throw "Missing helper $name"};Invoke-Expression $node.Extent.Text}
$root=Join-Path $OutputDirectory 'installation';$codex=Join-Path $OutputDirectory 'codex';$backup=Join-Path $OutputDirectory 'registration-backup'
$null=New-Item -ItemType Directory -Path $root,$codex,$backup
$current=Read-Package $CurrentPackagePath $root;$legacy=Read-Package $LegacyPackagePath ''
Assert-Startup ($current.commitSha-ine$legacy.commitSha) 'Two distinct package commits are required.'
$installed=Join-Path $root 'bin/prunlet.exe';$config=Join-Path $root 'config.json';$recovery=Join-Path $root 'recovery';$null=New-Item -ItemType Directory -Path $recovery
$null=& $installed --config $config init --backup-directory $recovery;Assert-Startup ($LASTEXITCODE-eq0) 'Fixture init failed.'
$cap=& $installed --startup-update-protocol|ConvertFrom-Json -AsHashtable;Assert-Startup (@($cap.distributionSources)-ccontains'r2') 'Current real executable must advertise R2.'
$aux=[ordered]@{};foreach($name in $current.files.Keys|Where-Object{!$_.EndsWith('.exe')}){$aux[$name.Replace('/','\')]=$current.files[$name].sha256}
@{repository=$current.repository;defaultBranch=$current.defaultBranch;commitSha=$current.commitSha;downloadUrl='https://api.github.com/repos/1llum1n4t1s/Prunlet/releases/assets/2';archiveSha256=$ExpectedCurrentPackageSha256;executableSha256=$current.files['bin/prunlet.exe'].sha256;maintenanceExecutableSha256=$current.files['bin/prunlet-maintenance.exe'].sha256;hookExecutableSha256=$current.files['bin/prunlet-hook.exe'].sha256;auxiliarySha256=$aux;runtime=$current.runtime}|ConvertTo-Json -Depth 8 -Compress|Set-Content (Join-Path $root 'source-info.json') -Encoding utf8NoBOM
[IO.File]::WriteAllText((Join-Path $codex 'config.toml'),"[features]`nhooks = true`n",[Text.UTF8Encoding]::new($false))
& (Join-Path $root 'bin/install-codex.ps1') -ExecutablePath $installed -ConfigPath $config -CodexHome $codex -BackupDirectory $backup|Out-Null
$statePath=Join-Path $root '.prunlet-update-state.json';$stage=Join-Path $root '.prunlet-update-stage'
$null=& $installed --config $config __begin-published-update $legacy.commitSha $current.commitSha;Assert-Startup ($LASTEXITCODE-eq0) 'Fixture begin failed.'
Copy-Item -LiteralPath $LegacyPackagePath -Destination (Join-Path $stage 'package.zip')
$transport=Join-Path $OutputDirectory 'transport.json'
@{repository=$current.repository;branch=$legacy.defaultBranch;commit=$legacy.commitSha;hash=$ExpectedLegacyPackageSha256.ToLowerInvariant();bytes=(Get-Item $LegacyPackagePath).Length}|ConvertTo-Json|Set-Content $transport -Encoding utf8NoBOM
$driver=Join-Path $OutputDirectory 'launcher-fixture.ps1'
# 事前idle検査の後に実MCPが出現する競合を、旧sourceの単一checkpointで固定する。
# 旧launcherの分岐・Coreは置換しない。派生sourceの差分とSHAも結果に残す。
$oldText=[IO.File]::ReadAllText($LegacyLauncherPath);$oldAst=[Management.Automation.Language.Parser]::ParseFile($LegacyLauncherPath,[ref]$tokens,[ref]$errors)
$coordinator=$oldAst.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Invoke-UpdateCoordinator'},$true)
if(!$coordinator){throw 'Legacy coordinator checkpoint not found.'}
$checkpoint="`n    & `$global:PrunletPreparedFixtureCallback`n"
$derived=$oldText.Insert($coordinator.Body.Extent.StartOffset+1,$checkpoint)
$oldLauncherFixture=Join-Path $OutputDirectory 'legacy-launcher-checkpoint.ps1'
[IO.File]::WriteAllText($oldLauncherFixture,$derived,[Text.UTF8Encoding]::new($false))
@'
param($Launcher,$Transport,$Executable,$Config,$Codex)
$ErrorActionPreference='Stop';$fixture=Get-Content $Transport -Raw|ConvertFrom-Json -AsHashtable
function Invoke-RestMethod {
 param($Uri,$Headers,$TimeoutSec)
 $base='https://api.github.com/repos/'+$fixture.repository
 switch -Regex ([string]$Uri){
  ('^'+[regex]::Escape($base)+'$'){return @{default_branch=$fixture.branch}}
  ('^'+[regex]::Escape($base+'/releases/latest')+'$'){return @{tag_name='fixture-current';draft=$false;prerelease=$false;assets=@(@{name='prunlet-update-win-x64.zip';state='uploaded';digest=('sha256:'+$fixture.hash);size=$fixture.bytes;id=1})}}
  ('^'+[regex]::Escape($base+'/git/ref/tags/fixture-current')+'$'){return @{object=@{sha=$fixture.commit;type='commit'}}}
  ('^'+[regex]::Escape($base+'/compare/')){return @{status='ahead'}}
  default{throw "Unexpected fixture API $Uri"}
 }
}
$global:PrunletPreparedFixtureHeld=$null
$global:PrunletPreparedFixtureCallback={
 if($global:PrunletPreparedFixtureHeld){return}
 $start=[Diagnostics.ProcessStartInfo]::new($Executable);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
 $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 foreach($arg in @('--config',$Config,'mcp')){$start.ArgumentList.Add($arg)}
 $p=[Diagnostics.Process]::new();$p.StartInfo=$start;if(!$p.Start()){throw 'Post-preflight real MCP failed to start.'}
 $global:PrunletPreparedFixtureHeld=$p
 $p.StandardInput.WriteLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"post-preflight-holder","version":"1"}}}');$p.StandardInput.Flush()
 $reply=$p.StandardOutput.ReadLineAsync();if(!$reply.Wait(30000)-or!$reply.Result){throw 'Post-preflight real MCP failed to initialize.'}
}
try{& $Launcher -ExecutablePath $Executable -ConfigPath $Config -CodexHome $Codex}
finally{if($global:PrunletPreparedFixtureHeld){$p=$global:PrunletPreparedFixtureHeld;$p.StandardInput.Close();if(!$p.WaitForExit(30000)){throw 'Post-preflight holder did not finish.'};$p.Dispose()}}
'@|Set-Content $driver -Encoding utf8NoBOM
$pwsh=(Get-Command pwsh -CommandType Application|Select-Object -First 1).Source
$held=$null;$completed=$false;$results=[Collections.Generic.List[object]]::new()
try{
 $oldArgs=@('-NoProfile','-File',$driver,'-Launcher',$oldLauncherFixture,'-Transport',$transport,'-Executable',$installed,'-Config',$config,'-Codex',$codex)
 $oldError=Finish-Mcp (Start-Mcp $pwsh $oldArgs) 'old-launcher'
 $state=Get-Content $statePath -Raw|ConvertFrom-Json;Assert-Startup ($state.phase-ceq'idle'-and$oldError-match'defer') 'Legacy launcher did not leave the prepared candidate deferred.'
 $infoPath=Join-Path $stage 'source-info.json';$infoHash=(Get-FileHash $infoPath).Hash;$url='https://api.github.com/repos/'+$current.repository+'/releases/assets/1'
 Assert-Startup ((Get-Content $infoPath -Raw|ConvertFrom-Json).downloadUrl-ceq$url) 'Legacy launcher did not bind the GH source.'
 $results.Add(@{name='actual legacy launcher prepares GH stage with R2-capable installed CLI';passed=$true})
 $newLauncher=Join-Path $repoRoot 'integration/start-prunlet-mcp.ps1'
 Assert-Startup ((Get-FileHash $newLauncher).Hash-ceq$current.files['bin/start-prunlet-mcp.ps1'].sha256) 'Current package and new launcher source differ.'
 $newArgs=@('-NoProfile','-File',$driver,'-Launcher',$newLauncher,'-Transport',$transport,'-Executable',$installed,'-Config',$config,'-Codex',$codex)
 $null=Finish-Mcp (Start-Mcp $pwsh $newArgs) 'new-launcher'
 $state=Get-Content $statePath -Raw|ConvertFrom-Json
 Assert-Startup ($state.phase-ceq'idle'-and$state.migrationComplete-and$state.integrationReady) 'New R2-default launcher did not finalize the existing GH stage.'
 Assert-Startup ((Get-FileHash (Join-Path $root 'source-info.json')).Hash-ceq$infoHash-and(Get-Content (Join-Path $root 'source-info.json') -Raw|ConvertFrom-Json).downloadUrl-ceq$url) 'Resume changed its prepared distribution bytes.'
 Assert-Startup ((Get-FileHash $installed).Hash-ceq$legacy.files['bin/prunlet.exe'].sha256) 'Final executable differs from authenticated package.'
 $results.Add(@{name='actual R2-default launcher inherits GH before retrieval and finalizes without rebinding';passed=$true});$completed=$true
}finally{
 if($held){$held.process.StandardInput.Close();$null=$held.process.WaitForExit(30000);$held.process.Dispose()}
 @{passed=$completed;results=@($results.ToArray());currentPackageSha256=$ExpectedCurrentPackageSha256;legacyPackageSha256=$ExpectedLegacyPackageSha256;legacyLauncherSha256=$ExpectedLegacyLauncherSha256;derivedLegacyLauncherSha256=(Get-FileHash $oldLauncherFixture).Hash;timingCheckpoint=$checkpoint;relationIsMetadataFixture=$true;note='Both packages contain real executables. Legacy source has only one post-preflight timing checkpoint starting a real MCP. GitHub release/ancestry answers are a fixture; this is not a public ancestry assertion or live R2 success.';liveR2HttpVerified=$false}|ConvertTo-Json -Depth 6|Set-Content $ReportPath -Encoding utf8NoBOM
}
if(!$completed){throw 'Prepared distribution resume verification failed.'}
