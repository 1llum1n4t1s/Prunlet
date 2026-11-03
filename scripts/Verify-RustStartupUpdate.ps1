#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedPackageSha256,
    [Parameter(Mandatory)][string]$PriorPackagePath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedPriorPackageSha256,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [ValidateSet('github','r2')][string]$DistributionSource = 'github'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach ($path in @($OutputDirectory,$ReportPath)) {
    Assert-VerificationDestination $path @($repoRoot, (Join-Path $env:USERPROFILE '.codex'))
    if (Test-Path -LiteralPath $path) { throw 'Startup verification outputs must be new.' }
}
if ((Get-FileHash -LiteralPath $PackagePath).Hash -ine $ExpectedPackageSha256 -or (Get-FileHash -LiteralPath $PriorPackagePath).Hash -ine $ExpectedPriorPackageSha256) { throw 'A caller-pinned package hash differs.' }
New-Item -ItemType Directory -Path $OutputDirectory, (Split-Path $ReportPath -Parent) -Force | Out-Null
$evidence = Join-Path $OutputDirectory 'evidence'
$root = Join-Path $OutputDirectory 'installation'
$codex = Join-Path $OutputDirectory 'codex'
$backup = Join-Path $OutputDirectory 'registration-backup'
New-Item -ItemType Directory -Path $evidence, $root, $codex, $backup | Out-Null
$results = [Collections.Generic.List[object]]::new()
$oldProcess = $null
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class PrunletStartupFixtureIdentity {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle h, int type, byte[] value, uint length);
    public static string Get(string path) {
        using var h=File.OpenHandle(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);
        var value=new byte[24];
        if(!GetFileInformationByHandleEx(h,18,value,24)) throw new System.ComponentModel.Win32Exception();
        return Convert.ToHexString(value);
    }
}
'@
function Assert-Startup([bool]$Condition,[string]$Message) { if (!$Condition) { throw $Message } }
function Case([string]$Name,[scriptblock]$Body) { try { & $Body; $results.Add(@{name=$Name;passed=$true}) } catch { $results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message;stack=$_.ScriptStackTrace}); throw } }
function Read-Package([string]$Path,[string]$Destination) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $zip.Entries) { if (!$names.Add($entry.FullName) -or ($entry.FullName -cne 'package.json' -and $entry.FullName -cnotmatch '^bin/[A-Za-z0-9._-]+$')) { throw 'Unsafe or duplicate package entry.' } }
        $entry = $zip.GetEntry('package.json'); if (!$entry) { throw 'Package manifest missing.' }
        $reader = [IO.StreamReader]::new($entry.Open()); try { $manifest=$reader.ReadToEnd()|ConvertFrom-Json -AsHashtable } finally { $reader.Dispose() }
        Assert-Startup ($manifest.product -ceq 'Prunlet' -and $manifest.schema -eq 1 -and $manifest.runtime -ceq 'win-x64' -and $names.Count -eq ($manifest.files.Count+1)) 'Package identity or runtime is invalid.'
        foreach ($name in $manifest.files.Keys) {
            $item=$manifest.files[$name]; $entry=$zip.GetEntry($name); Assert-Startup ($null -ne $entry -and $entry.Length -eq $item.bytes) "Package product size differs: $name"
            $input=$entry.Open();try{$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($input))}finally{$input.Dispose()}
            Assert-Startup ($hash -ceq $item.sha256) "Package product hash differs: $name"
            if ($Destination) { $target=Join-Path $Destination $name; New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force|Out-Null; $input=$entry.Open();$output=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write);try{$input.CopyTo($output);$output.Flush($true)}finally{$output.Dispose();$input.Dispose()} }
        }
        return $manifest
    } finally { $zip.Dispose() }
}
function Invoke-StartupCli([string]$Exe,[string[]]$Arguments,[int]$ExpectedExit=0) {
    $output = & $Exe --config $script:config @Arguments
    $code = $LASTEXITCODE
    Assert-Startup ($code -eq $ExpectedExit) "CLI exit $code differs from $ExpectedExit for $($Arguments[0]): $output"
    return ($output | ConvertFrom-Json -AsHashtable)
}
function Get-PrepareArguments {
    $arguments=@('__prepare-published-package',$candidate.repository,$candidate.defaultBranch,$candidate.commitSha,'win-x64',$ExpectedPackageSha256,[string](Get-Item $PackagePath).Length,'1')
    if($DistributionSource -ceq 'r2'){$arguments+='r2'}
    return $arguments
}
function Assert-StartupCliRejected([string]$Name,[string[]]$Arguments) {
    $stateHash=(Get-FileHash $statePath).Hash;$infoPath=Join-Path $stage 'source-info.json';$infoHash=(Get-FileHash $infoPath).Hash
    $text=& $ExecutablePath --config $config @Arguments 2>&1;$code=$LASTEXITCODE
    Assert-Startup ($code -ne 0) "Invalid distribution request succeeded: $Name"
    Assert-Startup ((Get-FileHash $statePath).Hash -ceq $stateHash -and (Get-FileHash $infoPath).Hash -ceq $infoHash) "Rejected distribution request changed its state: $Name"
    [IO.File]::AppendAllText((Join-Path $evidence 'distribution-rejections.jsonl'),((@{name=$Name;exitCode=$code;arguments=$Arguments;output=($text|Out-String)}|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
}
function Start-Mcp([string]$Exe,[string[]]$Arguments) {
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$Exe;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($a in $Arguments){$start.ArgumentList.Add($a)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$start;Assert-Startup ($p.Start()) 'MCP process did not start.'
    $stderr=$p.StandardError.ReadToEndAsync()
    $p.StandardInput.WriteLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"Prunlet-startup-verifier","version":"1"}}}')
    $p.StandardInput.Flush()
    return @{process=$p;stderr=$stderr;response=$p.StandardOutput.ReadLineAsync()}
}
function Finish-Mcp($Run,[string]$Name) {
    $p=$Run.process
    try {
        Assert-Startup ($Run.response.Wait(60000)) "MCP initialize timed out: $Name"
        $line=$Run.response.Result;Assert-Startup ([bool]$line) "MCP returned no initialize response: $Name"
        $reply=$line|ConvertFrom-Json -AsHashtable;Assert-Startup ($reply.id -eq 1 -and $reply.ContainsKey('result')) "MCP initialize failed: $Name $line"
        $p.StandardInput.Close();Assert-Startup ($p.WaitForExit(30000)) "MCP did not finish after EOF: $Name"
        $errorText=$Run.stderr.Result
        [IO.File]::WriteAllText((Join-Path $evidence "$Name.stdout.json"),$line,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $evidence "$Name.stderr.txt"),$errorText,[Text.UTF8Encoding]::new($false))
        Assert-Startup ($p.ExitCode -eq 0) "MCP process failed: $Name $errorText"
        return $errorText
    } finally {if(!$p.HasExited){$p.StandardInput.Close()};$p.Dispose()}
}
try {
    $prior=Read-Package $PriorPackagePath $root
    $candidate=Read-Package $PackagePath ''
    $expectedUrl='https://prunlet.kagayoi.com/releases/'+$candidate.repository.ToLowerInvariant()+'/'+$candidate.commitSha.ToLowerInvariant()+'/win-x64/'+$ExpectedPackageSha256.ToLowerInvariant()+'.zip'
    Assert-Startup ($candidate.commitSha -ine $prior.commitSha) 'Use packages from distinct genuine old and candidate commits.'
    Assert-Startup ($candidate.files['bin/prunlet.exe'].sha256 -ceq (Get-FileHash -LiteralPath $ExecutablePath).Hash) 'Candidate package is not the supplied Rust product.'
    $bin=Join-Path $root 'bin';$installed=Join-Path $bin 'prunlet.exe';$config=Join-Path $root 'config.json'
    $recovery=Join-Path $root 'recovery';New-Item -ItemType Directory -Path $recovery|Out-Null
    $null=& $ExecutablePath --config $config init --backup-directory $recovery
    Assert-Startup ($LASTEXITCODE -eq 0) 'Fixture init failed.'
    $aux=[ordered]@{};foreach($name in $prior.files.Keys|Where-Object{!$_.EndsWith('.exe')}){$aux[$name.Replace('/','\')]=$prior.files[$name].sha256}
    $provenance=[ordered]@{repository=$prior.repository;defaultBranch=$prior.defaultBranch;commitSha=$prior.commitSha;downloadUrl='https://api.github.com/repos/1llum1n4t1s/Prunlet/releases/assets/700561676';archiveSha256=$ExpectedPriorPackageSha256.ToUpperInvariant();executableSha256=$prior.files['bin/prunlet.exe'].sha256;maintenanceExecutableSha256=$prior.files['bin/prunlet-maintenance.exe'].sha256;hookExecutableSha256=$prior.files['bin/prunlet-hook.exe'].sha256;auxiliarySha256=$aux;runtime=$prior.runtime}
    $provenance|ConvertTo-Json -Depth 8 -Compress|Set-Content -LiteralPath (Join-Path $root 'source-info.json') -Encoding utf8NoBOM
    [IO.File]::WriteAllText((Join-Path $codex 'config.toml'),"[features]`nhooks = true`n",[Text.UTF8Encoding]::new($false))
    & (Join-Path $bin 'install-codex.ps1') -ExecutablePath $installed -ConfigPath $config -CodexHome $codex -BackupDirectory $backup|Out-Null
    $bootstrap=Join-Path $OutputDirectory 'launcher-fixture.ps1';$transport=Join-Path $OutputDirectory 'transport.json'
    @{repository=$candidate.repository;branch=$candidate.defaultBranch;commit=$candidate.commitSha;hash=$ExpectedPackageSha256.ToLowerInvariant();bytes=(Get-Item -LiteralPath $PackagePath).Length}|ConvertTo-Json|Set-Content -LiteralPath $transport -Encoding utf8NoBOM
    $launcher=Join-Path $repoRoot 'integration/start-prunlet-mcp.ps1'
    @'
param([string]$Launcher,[string]$Transport,[string]$Executable,[string]$Config,[string]$Codex)
$ErrorActionPreference='Stop'
$fixture=Get-Content -LiteralPath $Transport -Raw|ConvertFrom-Json -AsHashtable
function Invoke-RestMethod {
    param($Uri,$Headers,$TimeoutSec)
    $base='https://api.github.com/repos/'+$fixture.repository
    switch -Regex ([string]$Uri) {
        ('^'+[regex]::Escape($base)+'$') {return @{default_branch=$fixture.branch}}
        ('^'+[regex]::Escape($base+'/releases/latest')+'$') {return @{tag_name='fixture-current';draft=$false;prerelease=$false;assets=@(@{name='prunlet-update-win-x64.zip';state='uploaded';digest=('sha256:'+$fixture.hash);size=$fixture.bytes;id=1})}}
        ('^'+[regex]::Escape($base+'/git/ref/tags/fixture-current')+'$') {return @{object=@{sha=$fixture.commit;type='commit'}}}
        ('^'+[regex]::Escape($base+'/compare/')+'.*') {return @{status='ahead'}}
        default {throw "Unexpected fixture API request: $Uri"}
    }
}
& $Launcher -ExecutablePath $Executable -ConfigPath $Config -CodexHome $Codex
exit $LASTEXITCODE
'@|Set-Content -LiteralPath $bootstrap -Encoding utf8NoBOM
    $pwsh=(Get-Command pwsh -CommandType Application|Select-Object -First 1).Source
    $launchArgs=@('-NoProfile','-File',$bootstrap,'-Launcher',$launcher,'-Transport',$transport,'-Executable',$installed,'-Config',$config,'-Codex',$codex)
    $stage=Join-Path $root '.prunlet-update-stage';$statePath=Join-Path $root '.prunlet-update-state.json'
    Case 'Old MCP process defers the actual launcher and preserves products' {
        $script:oldProcess=Start-Mcp $installed @('--config',$config,'mcp')
        Assert-Startup ($oldProcess.response.Wait(30000)) 'Old MCP did not initialize.'
        $run=Start-Mcp $pwsh $launchArgs;$errorText=Finish-Mcp $run 'old-mcp-deferred'
        Assert-Startup ($errorText -match 'deferred.*existing process') 'Launcher did not report old-process deferral.'
        Assert-Startup ((Get-FileHash -LiteralPath $installed).Hash -ceq $prior.files['bin/prunlet.exe'].sha256) 'Deferred update changed old products.'
        $oldProcess.process.StandardInput.Close();Assert-Startup ($oldProcess.process.WaitForExit(30000)) 'Old MCP did not finish after EOF.';$oldProcess.process.Dispose();$script:oldProcess=$null
    }
    $prepareCase = if($DistributionSource -ceq 'r2'){'R2 preparation records the fixed URI; legacy CLI refuses rebinding without changes'}else{'Rust package preparation remains readable by the genuine previous CLI'}
    Case $prepareCase {
        $result=Invoke-StartupCli $ExecutablePath @('__begin-published-update',$candidate.commitSha,$prior.commitSha)
        Assert-Startup ($result.status -eq 'ready') 'Begin did not prepare a stage.'
        Copy-Item -LiteralPath $PackagePath -Destination (Join-Path $stage 'package.zip')
        $download=@('__download-published-package',$candidate.repository,$candidate.commitSha,'1',$ExpectedPackageSha256,[string](Get-Item $PackagePath).Length)
        if($DistributionSource -ceq 'r2'){$download+=@('r2','win-x64')}
        $downloaded=Invoke-StartupCli $ExecutablePath $download
        Assert-Startup ($downloaded.cacheReused -eq $true) 'The caller-pinned fixture cache was not reused.'
        $result=Invoke-StartupCli $ExecutablePath (Get-PrepareArguments)
        Assert-Startup ($result.status -eq 'prepared') 'Rust package preparation failed.'
        if($DistributionSource -ceq 'r2'){
            $expectedUrl='https://prunlet.kagayoi.com/releases/'+$candidate.repository.ToLowerInvariant()+'/'+$candidate.commitSha.ToLowerInvariant()+'/win-x64/'+$ExpectedPackageSha256.ToLowerInvariant()+'.zip'
            $info=Join-Path $stage 'source-info.json';$before=(Get-FileHash $info).Hash
            Assert-Startup ((Get-Content $info -Raw|ConvertFrom-Json).downloadUrl -ceq $expectedUrl) 'R2 provenance URI differs.'
            $rejected=& $installed --config $config __prepare-published-package $candidate.repository $candidate.defaultBranch $candidate.commitSha win-x64 $ExpectedPackageSha256 ([string](Get-Item $PackagePath).Length) 1 2>&1
            Assert-Startup ($LASTEXITCODE -ne 0 -and (Get-FileHash $info).Hash -ceq $before) 'Legacy prepare rebound the R2 stage.'
            $rejected|Out-String|Set-Content (Join-Path $evidence 'legacy-r2-rebind-rejected.txt')
        }else{
            $previousPrepare=Invoke-StartupCli $installed (Get-PrepareArguments)
            Assert-Startup ($previousPrepare.status -eq 'prepared') 'The previous CLI could not resume the Rust-prepared package.'
        }
        $state=Get-Content $statePath -Raw|ConvertFrom-Json;Assert-Startup ($state.slotCli.status -eq 'ready' -and $state.slotMaintenance.status -eq 'ready' -and $state.slotHook.status -eq 'ready') 'Prepared product slots are not ready.'
    }
    Case 'Repeated package preparation reuses the same verified slot objects' {
        $infoPath=Join-Path $stage 'source-info.json';$originalInfoBytes=[IO.File]::ReadAllBytes($infoPath)
        try {
        $info=Get-Content $infoPath -Raw|ConvertFrom-Json -AsHashtable
        $keys=@($info.Keys);[Array]::Reverse($keys);$equivalent=[ordered]@{};foreach($key in $keys){$equivalent[$key]=$info[$key]}
        $json=($equivalent|ConvertTo-Json -Depth 8 -Compress).Replace('1llum1n4t1s','\u0031llum1n4t1s')
        [IO.File]::WriteAllText($infoPath,$json,[Text.UTF8Encoding]::new($false));$infoHash=(Get-FileHash $infoPath).Hash
        # 別selectorを持つ次launcherでも、取得前に検証済stageの配布先へ戻る。
        $oppositeDownload=@('__download-published-package',$candidate.repository,$candidate.commitSha,'1',$ExpectedPackageSha256,[string](Get-Item $PackagePath).Length)
        $oppositePrepare=@('__prepare-published-package',$candidate.repository,$candidate.defaultBranch,$candidate.commitSha,'win-x64',$ExpectedPackageSha256,[string](Get-Item $PackagePath).Length,'1')
        if($DistributionSource -ceq 'github'){$oppositeDownload+=@('r2','win-x64');$oppositePrepare+='r2'}
        $inherited=Invoke-StartupCli $ExecutablePath $oppositeDownload
        Assert-Startup ($inherited.cacheReused -eq $true) 'Prepared stage did not inherit its verified cache.'
        $null=Invoke-StartupCli $ExecutablePath $oppositePrepare
        Assert-Startup ((Get-FileHash $infoPath).Hash -ceq $infoHash) 'Changing selectors rewrote equivalent prepared provenance.'
        $size=[string](Get-Item $PackagePath).Length
        foreach($bad in @(
            @{name='unknown selector';args=@($candidate.repository,$candidate.commitSha,'1',$ExpectedPackageSha256,$size,'unknown','win-x64')},
            @{name='fork cannot select R2';args=@('fork/Prunlet',$candidate.commitSha,'1',$ExpectedPackageSha256,$size,'r2','win-x64')},
            @{name='repository query';args=@(($candidate.repository+'?x=1'),$candidate.commitSha,'1',$ExpectedPackageSha256,$size,'r2','win-x64')},
            @{name='invalid commit';args=@($candidate.repository,'not-a-commit','1',$ExpectedPackageSha256,$size,'r2','win-x64')},
            @{name='runtime query';args=@($candidate.repository,$candidate.commitSha,'1',$ExpectedPackageSha256,$size,'r2','win-x64?x=1')},
            @{name='unsupported runtime';args=@($candidate.repository,$candidate.commitSha,'1',$ExpectedPackageSha256,$size,'r2','osx-arm64')},
            @{name='digest mismatch';args=@($candidate.repository,$candidate.commitSha,'1',('0'*64),$size,'r2','win-x64')},
            @{name='length mismatch';args=@($candidate.repository,$candidate.commitSha,'1',$ExpectedPackageSha256,'1','r2','win-x64')}
        )){Assert-StartupCliRejected $bad.name (@('__download-published-package')+$bad.args)}
        $saved=[IO.File]::ReadAllBytes($infoPath)
        try{$tampered=Get-Content $infoPath -Raw|ConvertFrom-Json -AsHashtable;$tampered.downloadUrl='https://prunlet.kagayoi.com/releases/unknown.zip?x=1';$tampered|ConvertTo-Json -Depth 8 -Compress|Set-Content $infoPath -Encoding utf8NoBOM
            Assert-StartupCliRejected 'unknown staged URL' $oppositeDownload
        }finally{[IO.File]::WriteAllBytes($infoPath,$saved)}
        $before=Get-Content $statePath -Raw|ConvertFrom-Json -AsHashtable;$ids=@{}
        foreach($entry in @(@('cli','slotCli'),@('maintenance','slotMaintenance'),@('hook','slotHook'))){$slot=Join-Path $root ('.prunlet-update-slots/slot-'+$entry[0]+'-'+$before[$entry[1]].generation+'.bin');$ids[$entry[1]]=[PrunletStartupFixtureIdentity]::Get($slot)}
        $null=Invoke-StartupCli $ExecutablePath (Get-PrepareArguments)
        Assert-Startup ((Get-FileHash $infoPath).Hash -ceq $infoHash) 'Repeated prepare rewrote a semantically equivalent JSON representation.'
        $after=Get-Content $statePath -Raw|ConvertFrom-Json -AsHashtable
        foreach($entry in @(@('cli','slotCli'),@('maintenance','slotMaintenance'),@('hook','slotHook'))){$slot=Join-Path $root ('.prunlet-update-slots/slot-'+$entry[0]+'-'+$after[$entry[1]].generation+'.bin');Assert-Startup ($after[$entry[1]].generation -ceq $before[$entry[1]].generation -and [PrunletStartupFixtureIdentity]::Get($slot) -ceq $ids[$entry[1]]) 'Repeated prepare replaced a ready slot object.'}
        } finally { [IO.File]::WriteAllBytes($infoPath,$originalInfoBytes) }
    }
    Case 'Storage budget counts file and directory ADS and rejects without changes' {
        $slots=Join-Path $root '.prunlet-update-slots'
        $used=[long](Get-ChildItem -LiteralPath $stage,$slots -Recurse -File|Measure-Object -Property Length -Sum).Sum+(Get-Item $statePath).Length
        $reserve=[long]2147483648-$used-1
        $available=Invoke-StartupCli $ExecutablePath @('__check-startup-budget',[string]$reserve);Assert-Startup ($available.status -eq 'available') 'Baseline budget calculation did not match the known fixture.'
        $unknown=Join-Path $stage 'unknown-capacity-fixture';[IO.File]::WriteAllBytes($unknown,[byte[]]@(1))
        [IO.File]::WriteAllBytes(($unknown+':named-stream'),[byte[]]@(2,3))
        [IO.File]::WriteAllBytes(($stage+':directory-stream'),[byte[]]@(4,5))
        $stateHash=(Get-FileHash $statePath).Hash;$oldHash=(Get-FileHash $installed).Hash
        $failure=Invoke-StartupCli $ExecutablePath @('__check-startup-budget',[string]$reserve) 1
        Assert-Startup ($failure.error -match 'budget|capacity') 'ADS capacity was not included.'
        Assert-Startup ((Get-FileHash $statePath).Hash -ceq $stateHash -and (Get-FileHash $installed).Hash -ceq $oldHash -and [IO.File]::ReadAllBytes(($stage+':directory-stream')).Length -eq 2) 'Capacity rejection changed state, products, or unknown ADS.'
    }
    $registrationCase=if($DistributionSource -ceq 'r2'){'Legacy launcher preserves R2 stage and user-edited registration when rebinding is rejected'}else{'User-edited registration blocks product switching and preserves bytes'}
    Case $registrationCase {
        $hooks=Join-Path $codex 'hooks.json';$saved=[IO.File]::ReadAllBytes($hooks)
        $preparedInfoHash=(Get-FileHash (Join-Path $stage 'source-info.json')).Hash
        try {
            [IO.File]::WriteAllText($hooks,([Text.Encoding]::UTF8.GetString($saved).Replace('prunlet-hook.exe','user-edited-hook.exe')),[Text.UTF8Encoding]::new($false));$changed=(Get-FileHash $hooks).Hash
            $errorText=Finish-Mcp (Start-Mcp $pwsh $launchArgs) 'changed-registration'
            $reason=if($DistributionSource -ceq 'r2'){'Published package preparation did not complete\.'}else{'registration.*changed|hook was edited|requires review'}
            Assert-Startup ($errorText -match $reason) 'Changed registration or R2 rebinding was not rejected.'
            Assert-Startup ((Get-FileHash (Join-Path $stage 'source-info.json')).Hash -ceq $preparedInfoHash) 'Rejected legacy preparation changed the selected R2 source.'
            Assert-Startup ((Get-FileHash $hooks).Hash -ceq $changed -and (Get-FileHash $installed).Hash -ceq $prior.files['bin/prunlet.exe'].sha256) 'Update overwrote edited registration or current products.'
        } finally {[IO.File]::WriteAllBytes($hooks,$saved)}
    }
    $candidateExe=Join-Path $stage 'prunlet.exe'
    Case 'Loaded old binary defers Core switching and retains idle state' {
        $script:oldProcess=Start-Mcp $installed @('--config',$config,'mcp');Assert-Startup ($oldProcess.response.Wait(30000)) 'Old MCP did not initialize.'
        $result=Invoke-StartupCli $candidateExe @('__apply-startup-update') 1;Assert-Startup ($result.status -eq 'deferred') 'Core did not defer a loaded old binary.'
        Assert-Startup ((Get-Content $statePath -Raw|ConvertFrom-Json).phase -eq 'idle') 'Deferred preflight started switching.'
        $oldProcess.process.StandardInput.Close();Assert-Startup ($oldProcess.process.WaitForExit(30000)) 'Old MCP did not finish.';$oldProcess.process.Dispose();$script:oldProcess=$null
    }
    Case 'Core product switch is resumable before integration confirmation' {
        $first=Invoke-StartupCli $candidateExe @('__apply-startup-update');Assert-Startup ($first.status -eq 'integration_required') 'First switch did not stop at integration.'
        $before=Get-Content $statePath -Raw|ConvertFrom-Json -AsHashtable
        $second=Invoke-StartupCli $candidateExe @('__apply-startup-update');Assert-Startup ($second.status -eq 'integration_required') 'Interrupted switch did not resume.'
        $after=Get-Content $statePath -Raw|ConvertFrom-Json -AsHashtable
        foreach($name in @('rotationCliBackup','rotationMaintenanceBackup','rotationHookBackup')){Assert-Startup ($before[$name] -ceq $after[$name]) 'Resume rotated an already-switched product again.'}
    }
    Case 'Actual launcher confirms integration, migrates, and preserves previous products' {
        $hooksBefore=(Get-FileHash (Join-Path $codex 'hooks.json')).Hash;$configBefore=(Get-FileHash $config).Hash
        $null=Finish-Mcp (Start-Mcp $pwsh $launchArgs) 'resumed-finalize'
        $state=Get-Content $statePath -Raw|ConvertFrom-Json
        Assert-Startup ($state.phase -eq 'idle' -and $state.integrationReady -and $state.migrationComplete) 'Launcher did not finalize the real Rust update.'
        if($DistributionSource -ceq 'r2'){Assert-Startup ((Get-Content (Join-Path $root 'source-info.json') -Raw|ConvertFrom-Json).downloadUrl -ceq $expectedUrl) 'Finalized R2 provenance URI differs.'}
        Assert-Startup ((Get-FileHash $config).Hash -ceq $configBefore -and (Get-FileHash (Join-Path $codex 'hooks.json')).Hash -ceq $hooksBefore) 'Finalization changed config or existing registration.'
        foreach($leaf in @('prunlet.exe','prunlet-maintenance.exe','prunlet-hook.exe')){Assert-Startup ((Get-FileHash (Join-Path $bin $leaf)).Hash -ceq $candidate.files[('bin/'+$leaf)].sha256) "Installed Rust product differs: $leaf"}
        Assert-Startup (Test-Path -LiteralPath (Join-Path $bin $state.rotationCliBackup)) 'Old CLI backup was not retained.'
        $result=Invoke-StartupCli $candidateExe @('__apply-startup-update');Assert-Startup ($result.status -eq 'cleanup_pending') 'Retained previous product cleanup was reported incorrectly.'
    }
    Case 'Unknown interrupted replacement is preserved without automatic retry' {
        $bytes=[IO.File]::ReadAllBytes($statePath)
        try {$state=Get-Content $statePath -Raw|ConvertFrom-Json -AsHashtable;$state.phase='switching';$state.migrationComplete=$false;$state.migrationFileComplete=$null;$state.rotationName='prunlet.exe';$state.rotationStatus='ambiguous';$state.rotationCandidateSha256=$candidate.files['bin/prunlet.exe'].sha256;$state.rotationPriorSha256='';$state.rotationBackupName=$state.rotationCliBackup;$state|ConvertTo-Json -Depth 8 -Compress|Set-Content $statePath -Encoding utf8NoBOM
            $before=(Get-FileHash $installed).Hash;$result=Invoke-StartupCli $candidateExe @('__apply-startup-update') 1
            Assert-Startup ((Get-FileHash $installed).Hash -ceq $before -and $result.error -match 'uncertain|ambiguous') 'An ambiguous replacement was retried.'
        }finally{[IO.File]::WriteAllBytes($statePath,$bytes)}
    }
} finally {
    if($oldProcess){$oldProcess.process.StandardInput.Close();$null=$oldProcess.process.WaitForExit(30000);$oldProcess.process.Dispose()}
    [ordered]@{passed=($results.Count -eq 9 -and !@($results|Where-Object{!$_.passed}).Count);results=@($results.ToArray());distributionSource=$DistributionSource;cacheReused=$true;liveR2HttpVerified=$false;legacyMutualResumeVerified=($DistributionSource -ceq 'github');candidatePackageSha256=$ExpectedPackageSha256;priorPackageSha256=$ExpectedPriorPackageSha256;fixtureSource='genuine prior published package and caller-pinned Rust candidate; GitHub metadata is a fixture; URL records the selected distribution, not network history';outputDirectory=$OutputDirectory;retention='Keep isolated installation, binaries, state, registration, and process evidence for diagnosis. No production install or Codex configuration was changed.'}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM
}
$report=Get-Content $ReportPath -Raw|ConvertFrom-Json
$report.results|Select-Object name,passed,error|ConvertTo-Json
if(!$report.passed){throw 'Rust startup update verification failed.'}
