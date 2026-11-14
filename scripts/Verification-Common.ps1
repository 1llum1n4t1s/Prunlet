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

# 検証の出力・report・TEMP・fixtureが「外部」かを確認する。
# 開発者固有のドライブ文字には依存させず、次だけを要求する。未使用・親の実在・volume照合などは呼出元が続けて検査する。
# - 通常のドライブ絶対パス（X:\始まり）であること。UNC・\\?\等のデバイスパスは拒否する。
# - ForbiddenRoots（通常はリポジトリ）・~/.codex・CODEX_HOMEの外であり、既存の祖先がreparse pointでないこと。
function Assert-ExternalVerificationPath([string]$Path, [string[]]$ForbiddenRoots) {
    if ([string]::IsNullOrWhiteSpace($Path) -or ![IO.Path]::IsPathFullyQualified($Path) -or $Path -notmatch '^[A-Za-z]:\\') { throw 'Verification paths must be ordinary drive-absolute paths outside the repository and Codex home; device and UNC paths are unsupported.' }
    $full = [IO.Path]::GetFullPath($Path)
    $roots = @($ForbiddenRoots | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_) })
    if ($env:USERPROFILE) { $roots += [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex')) }
    if ($env:CODEX_HOME) { $roots += [IO.Path]::GetFullPath($env:CODEX_HOME) }
    Assert-VerificationDestination $full $roots
}

# パスが属するvolumeのroot（例: 'E:\'）を返す。設定のvolumeRecoveryDirectoriesのキーに使う。
function Get-VerificationVolumeRoot([string]$Path) {
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
    if ($root -notmatch '^[A-Za-z]:\\$') { throw 'Verification volume must be an ordinary drive root.' }
    return $root.ToUpperInvariant()
}

# 指定パスとは別volumeの、準備済み固定ドライブのrootを返す。見つからなければ$null。
# クロスvolumeの検証だけに使い、返したvolumeには何も作らない。
function Get-VerificationOtherFixedVolumeRoot([string]$Path) {
    $own = Get-VerificationVolumeRoot $Path
    $ownId = $null
    try { $ownId = @(Get-Volume -FilePath $own -ErrorAction Stop)[0].UniqueId } catch { $ownId = $null }
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -ne [IO.DriveType]::Fixed -or !$drive.IsReady) { continue }
        $root = $drive.RootDirectory.FullName.ToUpperInvariant()
        if ($root -notmatch '^[A-Za-z]:\\$' -or $root -ceq $own) { continue }
        # substなどで同じvolumeを別ドライブ文字に見せている場合は除外する。
        if ($ownId) {
            try { if (@(Get-Volume -FilePath $root -ErrorAction Stop)[0].UniqueId -ceq $ownId) { continue } } catch { continue }
        }
        return $root
    }
    return $null
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
