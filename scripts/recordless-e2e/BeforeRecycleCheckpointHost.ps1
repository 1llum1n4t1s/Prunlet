[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$ExecutablePath,
 [Parameter(Mandatory)][string]$RustProbePath,
 [Parameter(Mandatory)][string]$BuildManifestPath,
 [Parameter(Mandatory)][string]$ExpectedBuildManifestSha256,
 [Parameter(Mandatory)][string]$OutputDirectory,
 [Parameter(Mandatory)][string]$ReportPath,
 [Parameter(Mandatory)][string]$FixtureRoot,
 [Parameter(Mandatory)][ValidateSet('replace','alias','attributes','large')][string[]]$Modes,
 [Parameter(Mandatory)][string]$Suite,
 [Parameter(Mandatory)][string]$CallerPath
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Verification-Common.ps1')
. (Join-Path $PSScriptRoot 'RustFileProbe.Common.ps1')
# 実Shell直前の既存cfg(test) checkpointを使い、製品runtimeへ検証hookを追加しない。
foreach($path in @($OutputDirectory,$ReportPath,$FixtureRoot)) {
 if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute output, report and fixture paths required'}
 Assert-VerificationDestination $path @($repo,(Join-Path $env:USERPROFILE '.codex'))
 if(Test-Path -LiteralPath $path){throw 'Unused output, report and fixture paths required'}
 if(![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))){throw 'Existing parent required'}
}
foreach($path in @($OutputDirectory,$ReportPath)){if(![IO.Path]::GetPathRoot($path).Equals('D:\',[StringComparison]::OrdinalIgnoreCase)){throw 'External D output required'}}
$null=Assert-RustFileProbeBinding
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$null=[IO.Directory]::CreateDirectory($FixtureRoot)
$sources=@(Get-RustFileProbeSourceHashes)+@(@($PSCommandPath,$CallerPath)|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}})
$results=[Collections.Generic.List[object]]::new()
$oldTemp=$env:TEMP;$oldTmp=$env:TMP
try {
 $env:TEMP=Join-Path $OutputDirectory 'temp';$env:TMP=$env:TEMP;$null=[IO.Directory]::CreateDirectory($env:TEMP)
 foreach($mode in $Modes) {
  $item=@{name=('before-recycle-'+$mode);passed=$false;skipped=$false};$results.Add($item)
  try {
   $fixture=Join-Path $FixtureRoot $mode;$null=[IO.Directory]::CreateDirectory($fixture)
   $probe=Invoke-RustFileContract ('file-before-recycle-'+$mode) $fixture
   $value=$probe.result
   if($value.checkpointCount -ne 1 -or !$value.originalPreserved -or !$value.replacementPreserved -or $value.result.items.Count -ne 1 -or $value.result.items[0].status -cne 'ambiguous'){throw 'Changed Shell source was not verified as ambiguous with both identities preserved'}
   if($mode -ceq 'large' -and (!$value.largeSparse -or $value.logicalSizeBefore -ne 1TB -or $value.allocationSizeBefore -gt 1MB -or !$value.boundedOwnedSparseCleanup.resizedOwnedFixture -or $value.replacement.actualWindowsSizeRefusal -cne $true -or $value.replacement.retainedAtSource -cne $true -or $null -ne $value.replacement.destination -or $value.replacement.sourcePath -cne $value.result.items[0].path)){throw 'Actual Windows size refusal, same-ID replacement retained at source, and bounded owned finalization not verified'}
   foreach($source in $sources){if((Get-FileHash -LiteralPath $source.path).Hash -cne $source.sha256){throw 'Verification source changed'}}
   $item.probe=$probe;$item.passed=$true
  }catch {$item.error=$_.Exception.ToString();$item.stack=$_.ScriptStackTrace}
 }
}finally {
 $env:TEMP=$oldTemp;$env:TMP=$oldTmp
 $report=@{suite=$Suite;runtime='rust';sameSourceBuild=$script:RustFileBuild;sources=$sources;results=@($results);passed=@($results|Where-Object passed).Count;failed=@($results|Where-Object {!$_.passed}).Count;skipped=0;retained=@($OutputDirectory,$FixtureRoot);scope='Actual Windows Shell plus candidate-source test-only Core; separate from shipping CLI/MCP E2E';cleanup='Originals, aliases and replacement Bin items retained without deletion retry. Only the exact owned sparse original is shortened after bounded identity/security/allocation/content proof. Windows-managed Bin ACL changes are recorded separately.'}
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 80));$file=[IO.FileStream]::new($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$file.Write($bytes);$file.Flush($true)}finally{$file.Dispose()}
}
if($results.Count -ne $Modes.Count -or @($results|Where-Object {!$_.passed}).Count){throw 'Before-recycle native verification failed; retain fixtures and inspect report'}
