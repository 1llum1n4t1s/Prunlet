# 検証用出力先の共通ガード。絶対パスへの正規化と実行順は呼び出し元で維持する。
function Assert-VerificationDestination([string]$Destination, [string[]]$ForbiddenRoots) {
    foreach ($forbidden in $ForbiddenRoots) {
        if ($Destination.Equals($forbidden, [StringComparison]::OrdinalIgnoreCase) -or $Destination.StartsWith($forbidden.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Verification output must be external.' }
    }
    $ancestor = $Destination
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Verification output must not traverse links.' }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
}

# 新旧exeが生成したactive記録だけを解決する。終端履歴をactiveとして扱わない。
function Resolve-VerificationOperationDirectory([string]$Recovery, [string]$OperationId) {
    if ($OperationId -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid verification operation ID.' }
    $typed = Join-Path (Join-Path $Recovery '.recycle-records-v1') $OperationId
    $legacy = Join-Path $Recovery $OperationId
    $closed = Join-Path (Join-Path $Recovery '.closed-records-v1') ($OperationId + '.json')
    if ([IO.File]::Exists($closed)) { throw "Operation $OperationId is closed; active metadata must not be used." }
    if ([IO.Directory]::Exists($typed) -and [IO.Directory]::Exists($legacy)) { throw 'Verification operation has ambiguous active locations.' }
    if ([IO.Directory]::Exists($typed)) { return $typed }
    if ([IO.Directory]::Exists($legacy)) { return $legacy }
    throw "Active verification operation $OperationId was not found."
}

# closedは操作を再実行しない明示結果。旧exeのalready_restoredも非0件を必須にする。
function Assert-VerificationRepeatedRestore($Response, [string]$OperationId, [int]$ExpectedCount) {
    if ($Response.ExitCode -ne 0 -or $Response.Json.operationId -cne $OperationId) { throw 'Repeated restore failed or changed operation ID.' }
    $items = @($Response.Json.items)
    if ($ExpectedCount -lt 1 -or @($items | Where-Object { !$_.path -or !$_.kind }).Count) { throw 'Repeated restore omitted original input evidence.' }
    if ($Response.Json.lifecycleState -eq 'closed') {
        if ($items.Count -ne $ExpectedCount -or $Response.Json.originalSchema -ne 6 -or !$Response.Json.terminalReason -or @($items | Where-Object status -ne 'closed').Count) { throw 'Closed restore omitted terminal evidence or input outcomes.' }
    } elseif ($items.Count -ne $ExpectedCount -or @($items | Where-Object status -ne 'already_restored').Count) { throw 'Repeated restore omitted input outcomes or was not idempotent.' }
}
function Assert-VerificationClosedRecord([string]$Recovery, [string]$OperationId, [int]$OriginalSchema) {
    $closed = Join-Path (Join-Path $Recovery '.closed-records-v1') ($OperationId + '.json')
    if (![IO.File]::Exists($closed)) { throw 'Expected committed closed operation summary.' }
    $summary = [IO.File]::ReadAllText($closed) | ConvertFrom-Json -AsHashtable -Depth 100
    if ($summary.schema -ne 1 -or $summary.operationId -cne $OperationId -or $summary.originalSchema -ne $OriginalSchema -or !$summary.terminalReason -or @($summary.entries).Count -lt 1 -or @($summary.entries).Count -gt 256 -or @($summary.entries | Where-Object { !$_.path -or !$_.kind }).Count) { throw 'Closed summary lost its terminal operation evidence.' }
    if ([IO.Directory]::Exists((Join-Path $Recovery $OperationId)) -or [IO.Directory]::Exists((Join-Path (Join-Path $Recovery '.recycle-records-v1') $OperationId))) { throw 'Terminal operation retained its active metadata directory.' }
}
