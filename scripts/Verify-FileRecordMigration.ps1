[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExecutablePath,[string]$LegacyExecutablePath,[string]$MoveExecutablePath,[string]$BaselineExecutablePath,[string]$AssemblyPath,[Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$ReportPath,[ValidateNotNullOrEmpty()][string[]]$CaseFilter=@('*'))
# 旧ファイルは所有確認したrootを直接Windowsゴミ箱へ渡す。詳細な失敗仮説とE2Eは専用suiteへ集約する。
$entryScriptPath=$PSCommandPath
. (Join-Path $PSScriptRoot 'recordless-e2e/LegacyDiscardSuite.ps1')
if($script:legacyDiscardFailed){exit 1};exit 0
