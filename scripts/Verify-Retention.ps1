[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$RustProbePath,
    [string]$BuildManifestPath,
    [string]$ExpectedBuildManifestSha256,
    [switch]$LegacyCopyVerification
)
$ErrorActionPreference = 'Stop'
if ($LegacyCopyVerification) { throw 'Legacy file retention/restore verification was retired. Use Verify-FileRecordMigration.ps1 for genuine old-runtime fixtures.' }
# 保持制御はregistry専用。Windowsごみ箱の除外はrecordless suiteで検証する。
$arguments = @{
    ExecutablePath=$ExecutablePath; OutputDirectory=$OutputDirectory; ReportPath=$ReportPath
    CaseFilter=@('operations-explicit-purge-and-expiry','capacity-single-oversized-then-normal-budget')
}
foreach ($name in @('RustProbePath','BuildManifestPath','ExpectedBuildManifestSha256')) {
    if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name]=$PSBoundParameters[$name] }
}
& (Join-Path $PSScriptRoot 'Verify-RegistryRecovery.ps1') @arguments
exit $LASTEXITCODE
