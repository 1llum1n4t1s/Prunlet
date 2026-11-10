[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$ExpectedExecutableSha256,
    [Parameter(Mandatory)][Alias('ProbeExecutablePath')][string]$RustProbePath,
    [Parameter(Mandatory)][Alias('ExpectedProbeExecutableSha256')][string]$ExpectedRustProbeSha256,
    [Parameter(Mandatory)][string]$BuildManifestPath,
    [Parameter(Mandatory)][string]$ExpectedBuildManifestSha256,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
. (Join-Path $PSScriptRoot 'recordless-e2e/RustFileProbe.Common.ps1')
foreach($path in @($ExecutablePath,$RustProbePath,$OutputDirectory,$ReportPath)){
    if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute executable, probe and output paths are required.'}
}
foreach($pair in @(@($ExecutablePath,$ExpectedExecutableSha256),@($RustProbePath,$ExpectedRustProbeSha256))){
    if(![IO.File]::Exists($pair[0]) -or $pair[1] -notmatch '^[0-9a-fA-F]{64}$' -or !(Get-FileHash -LiteralPath $pair[0]).Hash.Equals($pair[1],[StringComparison]::OrdinalIgnoreCase)){throw 'Candidate or test-only Rust probe hash differs.'}
}
foreach($path in @($OutputDirectory,$ReportPath)){
    Assert-VerificationDestination $path @($repo,(Join-Path $env:USERPROFILE '.codex'))
    if(![IO.Path]::GetPathRoot($path).Equals('D:\',[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $path) -or ![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))){throw 'Unused external D: output and an existing parent are required.'}
}
$buildBinding=Assert-RustFileProbeBinding
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$metadata=Join-Path $OutputDirectory 'metadata';$null=[IO.Directory]::CreateDirectory($metadata)
$script:Config=Join-Path $OutputDirectory 'config.json'
$utf8=[Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($script:Config,(@{schema=1;allowedRoots=@();backupDirectory=$metadata;retentionDays=7;maxRecoveryBytes=1073741824}|ConvertTo-Json -Depth 5),$utf8)
$resultPath=Join-Path $OutputDirectory 'rust-snapshot-publication-result.json'
$info=New-RustProbeStartInfo $RustProbePath 'snapshot_publication' @{action='snapshot-publication';resultPath=$resultPath} $OutputDirectory
$process=$null
try{
    $process=[Diagnostics.Process]::Start($info);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    if(!$process.WaitForExit(120000)){$process.Kill($true);$process.WaitForExit();throw 'Rust snapshot publication probe timed out.'}
    $out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'probe.stdout.log'),$out,$utf8);[IO.File]::WriteAllText((Join-Path $OutputDirectory 'probe.stderr.log'),$err,$utf8)
    if($process.ExitCode -ne 0 -or ![IO.File]::Exists($resultPath)){throw ('Rust snapshot publication probe failed: '+$out+$err)}
    $envelope=[IO.File]::ReadAllText($resultPath)|ConvertFrom-Json -Depth 50 -AsHashtable
    if($envelope.runtime -cne 'rust-libtest' -or !$envelope.syntheticMetadataOnly -or $envelope.realNativeScopeVerified -or !$envelope.result.passed -or $envelope.result.passedCount -ne 3 -or $envelope.result.failed -ne 0){throw 'Probe did not prove all three metadata-only boundaries.'}
    if(!(Get-FileHash -LiteralPath $ExecutablePath).Hash.Equals($ExpectedExecutableSha256,[StringComparison]::OrdinalIgnoreCase) -or !(Get-FileHash -LiteralPath $RustProbePath).Hash.Equals($ExpectedRustProbeSha256,[StringComparison]::OrdinalIgnoreCase)){throw 'Candidate or probe changed during verification.'}
    $report=@{suite='registry-snapshot-publication-boundary';runtime='rust-libtest';sameSourceBuild=$buildBinding;executablePath=$ExecutablePath;executableSha256=$ExpectedExecutableSha256;rustProbePath=$RustProbePath;rustProbeSha256=$ExpectedRustProbeSha256;passed=3;failed=0;cases=$envelope.result.cases;metadata=$metadata;scope='Synthetic metadata only; no registry transaction or native-session E2E.';shippingBinaryHasFaultInjection=$false}
    [IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 50),$utf8)
    @{passed=3;failed=0;reportPath=$ReportPath;scope=$report.scope}|ConvertTo-Json
}catch{
    [IO.File]::WriteAllText($ReportPath,(@{suite='registry-snapshot-publication-boundary';runtime='rust-libtest';passed=0;failed=1;error=$_.Exception.ToString();metadata=$metadata}|ConvertTo-Json -Depth 20),$utf8)
    throw
}finally{
    if($process){if(!$process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose()}
}