[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][string]$LegacyExecutablePath,
    [string[]]$CaseFilter = @('hardlink-batch-*', 'hardlink-two-aliases-same-batch'),
    [switch]$IncludeConcurrencyRegression,
    [ValidateRange(1000, 100000)][int]$HeavyFileCount = 10000,
    [ValidateRange(90, 1800)][int]$ProcessTimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
# 実装前の失敗条件: 一部aliasだけの削除、共有ACL/属性/ADS/ID/別名数の欠落、
# 連結成分の分断、非上書き違反、部分再開・冪等性の不成立、外部ACL改変の見逃し、
# 未ready stageへのACL再適用、旧schema6の推測復元、通常の独立削除の直列化。
# 共通のfixture作成・CLI/MCP実プロセス・native ID/O/G/D・owned gateは既存検証へ集約する。
# 元のhardlink-two-aliases-same-batchはallDeleted/fullsnapshot復元を要求し、期待を緩和しない。
$runner = Join-Path $PSScriptRoot 'Verify-ConcurrentDeletion.ps1'
if (![IO.File]::Exists($runner)) { throw 'Concurrent deletion verification runner is missing.' }
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath, $LegacyExecutablePath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'All executable/output/report paths must be absolute.' }
}
if (![IO.File]::Exists($LegacyExecutablePath)) { throw 'A genuine pre-feature executable is required for legacy fixtures.' }
$filters = @($CaseFilter)
if ($IncludeConcurrencyRegression) {
    $filters += @('process-claims-*', 'mcp-independent-completes-before-heavy-request-and-exception-drain', 'mcp-nondeletion-tool-waits-for-pending-delete', 'batch-preflight-all-unchanged')
}
& $runner -ExecutablePath $ExecutablePath -OutputDirectory $OutputDirectory -ReportPath $ReportPath `
    -LegacyHardlinkExecutablePath $LegacyExecutablePath -CaseFilter $filters `
    -HeavyFileCount $HeavyFileCount -ProcessTimeoutSeconds $ProcessTimeoutSeconds
