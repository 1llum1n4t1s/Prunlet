# 削除fixtureだけを明示した通常ディレクトリへ分離する。設定・一時JSON・reportは呼出し元に残す。
function New-VerificationFixtureRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FixtureRoot,
        [Parameter(Mandatory)][string[]]$ForbiddenRoots,
        [ValidatePattern('^[a-zA-Z0-9-]+$')][string]$NamePrefix = 'fixture'
    )
    if (![IO.Path]::IsPathFullyQualified($FixtureRoot) -or $FixtureRoot -notmatch '^[A-Za-z]:\\') { throw 'FixtureRoot must be an ordinary drive-absolute path; device and UNC paths are unsupported.' }
    $root = [IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\')
    if ($root.Length -le 3 -or $root -cne $FixtureRoot.TrimEnd('\')) { throw 'FixtureRoot must be a canonical non-volume-root directory.' }
    if ($env:CODEX_HOME) { $ForbiddenRoots += [IO.Path]::GetFullPath($env:CODEX_HOME) }
    Assert-VerificationDestination $root $ForbiddenRoots
    if (![IO.Directory]::Exists($root)) { throw 'FixtureRoot must already exist.' }
    $volume = @(Get-Volume -FilePath ($root + '\') -ErrorAction Stop)
    if ($volume.Count -ne 1 -or $volume[0].FileSystemType -ne 'NTFS' -or !$volume[0].UniqueId) { throw 'FixtureRoot must resolve to one NTFS volume.' }
    $run = Join-Path $root ($NamePrefix + '-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $run) { throw 'Fixture run directory must be unused.' }
    $null = [IO.Directory]::CreateDirectory($run)
    Assert-VerificationDestination $run $ForbiddenRoots
    $actual = @(Get-Volume -FilePath ($run + '\') -ErrorAction Stop)
    if ($actual.Count -ne 1 -or $actual[0].UniqueId -cne $volume[0].UniqueId) { throw 'Fixture run volume changed.' }
    [pscustomobject]@{ root = $root; directory = $run; volume = $volume[0].UniqueId }
}
