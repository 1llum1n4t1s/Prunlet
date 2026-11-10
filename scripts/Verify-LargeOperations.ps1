[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$FixtureRoot,
    [string]$RustProbePath,
    [string]$BuildManifestPath,
    [string]$ExpectedBuildManifestSha256,
    [switch]$LegacyCopyVerification,
    [ValidateRange(32769,65535)][int]$FileCount = 32769,
    [ValidateRange(60,86400)][int]$ProcessTimeoutSeconds = 1800
)
$ErrorActionPreference = 'Stop'
if ($LegacyCopyVerification) { throw 'Legacy copy/restore verification was retired. Use Verify-FileRecordMigration.ps1 for genuine old-runtime fixtures.' }
# 大規模ケースの明示実行入口。通常E2Eや性能比較の一部として暗黙には起動しない。
$arguments = @{
    ExecutablePath=$ExecutablePath; OutputDirectory=$OutputDirectory; ReportPath=$ReportPath
    Large=$true; LargeFileCount=$FileCount; CaseFilter=@('cli-large-native-recordless-windows-roundtrip')
    ProcessTimeoutSeconds=[Math]::Min($ProcessTimeoutSeconds,3600)
}
foreach ($name in @('RustProbePath','BuildManifestPath','ExpectedBuildManifestSha256','FixtureRoot')) {
    if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name]=$PSBoundParameters[$name] }
}
& (Join-Path $PSScriptRoot 'Verify-RecordlessFiles.ps1') @arguments
exit $LASTEXITCODE
