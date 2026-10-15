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
