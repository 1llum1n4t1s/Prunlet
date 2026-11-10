param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$RustProbePath,[Parameter(Mandatory)][string]$BuildManifestPath,[Parameter(Mandatory)][string]$ExpectedBuildManifestSha256,[Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string]$FixtureRoot,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
# runnerが固定した同一source証拠をprobe実行直前にも照合する。
$binding=Assert-RustFileProbeBinding
$script:Config=$ConfigPath
$resultPath=Join-Path $OutputDirectory ('independence-probe-'+[guid]::NewGuid().ToString('N')+'.json')
$request=@{case='file-independent-roots';fixtureRoot=$FixtureRoot;configSha256=(Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash;resultPath=$resultPath}
$info=New-RustProbeStartInfo $RustProbePath 'files_contract' $request $OutputDirectory
$process=[Diagnostics.Process]::Start($info)
try{
 $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
 if(!$process.WaitForExit(180000)){$process.Kill($true);$process.WaitForExit();throw 'Core probe timed out; inspect fixture and Bin, never resend deletion'}
 $out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
 [IO.File]::WriteAllText(($resultPath+'.stdout.txt'),$out,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText(($resultPath+'.stderr.txt'),$err,[Text.UTF8Encoding]::new($false))
 if($process.ExitCode-ne0-or![IO.File]::Exists($resultPath)){throw ('Core probe failed: '+$out+$err)}
 $envelope=[IO.File]::ReadAllText($resultPath)|ConvertFrom-Json -AsHashtable -Depth 80
 if($envelope.runtime-cne'rust-libtest'-or!$envelope.nativeFileProbe-or!$envelope.result.passed-or$envelope.candidateSha256.ToLowerInvariant()-cne$binding.candidateSha256-or$envelope.probeSha256.ToLowerInvariant()-cne$binding.probeSha256){throw 'Core probe candidate, scope or outcome differs'}
 if((Get-RustFileSourceFingerprint $repo)-cne$binding.sourceFingerprint){throw 'Core source changed during verification'}
 return $envelope.result
}finally{if(!$process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose()}
