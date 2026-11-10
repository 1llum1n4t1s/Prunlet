[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [ValidateNotNullOrEmpty()][string[]]$CaseFilter = @('*'),
    [string]$RustProbePath,
    [string]$BuildManifestPath,
    [string]$ExpectedBuildManifestSha256,
    [string]$FixtureRoot,
    [string]$CaseSensitiveSetupHelperPath,
    [ValidateRange(1,3600)][int]$ProcessTimeoutSeconds = 240,
    [switch]$LegacyCopyVerification
)
$ErrorActionPreference = 'Stop'
# 廃止済みの旧file復元検証へは戻さない。真正旧exeの移行検証は専用suiteを使う。
if ($LegacyCopyVerification) { throw 'Legacy copy/restore verification was retired. Use Verify-FileRecordMigration.ps1 for genuine old-runtime fixtures.' }
$arguments = @{
    ExecutablePath = $ExecutablePath; OutputDirectory = $OutputDirectory; ReportPath = $ReportPath
    CaseFilter = $CaseFilter; ProcessTimeoutSeconds = $ProcessTimeoutSeconds
}
foreach ($name in @('RustProbePath','BuildManifestPath','ExpectedBuildManifestSha256','FixtureRoot','CaseSensitiveSetupHelperPath')) {
    if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name] = $PSBoundParameters[$name] }
}
& (Join-Path $PSScriptRoot 'Verify-RecordlessFiles.ps1') @arguments
exit $LASTEXITCODE
