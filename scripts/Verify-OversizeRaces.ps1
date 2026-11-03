[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$ExecutablePath,
 [Parameter(Mandatory)][string]$RustProbePath,
 [Parameter(Mandatory)][string]$BuildManifestPath,
 [Parameter(Mandatory)][string]$ExpectedBuildManifestSha256,
 [Parameter(Mandatory)][string]$OutputDirectory,
 [Parameter(Mandatory)][string]$ReportPath,
 [Parameter(Mandatory)][string]$FixtureRoot
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
. (Join-Path $PSScriptRoot 'recordless-e2e/RustFileProbe.Common.ps1')
foreach($path in @($OutputDirectory,$ReportPath,$FixtureRoot)) {
 if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute output, report and fixture paths required'}
 Assert-VerificationDestination $path @($repo,(Join-Path $env:USERPROFILE '.codex'))
 if(Test-Path -LiteralPath $path){throw 'Unused output, report and fixture paths required'}
 if(![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))){throw 'Existing parent required'}
}
foreach($path in @($OutputDirectory,$ReportPath)) {if(![IO.Path]::GetPathRoot($path).Equals('D:\',[StringComparison]::OrdinalIgnoreCase)){throw 'External D output required'}}
$null=Assert-RustFileProbeBinding
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$null=[IO.Directory]::CreateDirectory($FixtureRoot)
$results=[Collections.Generic.List[object]]::new()
$oldTemp=$env:TEMP;$oldTmp=$env:TMP
try {
 $env:TEMP=Join-Path $OutputDirectory 'temp';$env:TMP=$env:TEMP;$null=[IO.Directory]::CreateDirectory($env:TEMP)
 foreach($mode in @('replace','lock')) {
  $item=@{name=('actual-size-refusal-'+$mode);passed=$false;skipped=$false};$results.Add($item)
  try {
   $fixture=Join-Path $FixtureRoot $mode;$null=[IO.Directory]::CreateDirectory($fixture)
   $probe=Invoke-RustFileContract ('file-oversize-'+$mode+'-root') $fixture
   if(!$probe.result.actualWindowsSizeRefusal -or $probe.result.checkpointCount -ne 1 -or $probe.result.result.items[0].status -cne 'ambiguous'){throw 'Actual size-only refusal and protected race outcome were not verified'}
   $item.probe=$probe;$item.passed=$true
  }catch {$item.error=$_.Exception.ToString();$item.stack=$_.ScriptStackTrace}
 }
} finally {
 $env:TEMP=$oldTemp;$env:TMP=$oldTmp
 $report=@{sources=@(Get-RustFileProbeSourceHashes)+@(@{path=$PSCommandPath;sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash});suite='oversize-race';runtime='rust';sameSourceBuild=$script:RustFileBuild;results=@($results);passed=@($results|Where-Object passed).Count;failed=@($results|Where-Object {!$_.passed}).Count;skipped=0;actualSizeRefusalCases=2;syntheticHRESULTCases=0;retained=@($OutputDirectory,$FixtureRoot);cleanup='Verified owned sparse files are shortened only after complete bounded native identity/security/allocation-content proof; other fixtures retained.'}
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 80));$file=[IO.FileStream]::new($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$file.Write($bytes);$file.Flush($true)}finally{$file.Dispose()}
}
if($results.Count -ne 2 -or @($results|Where-Object {!$_.passed}).Count){throw 'Actual oversized root race verification failed; retain uncertain fixtures and inspect report'}