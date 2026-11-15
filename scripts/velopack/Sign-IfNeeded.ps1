#requires -Version 7.0
# vpk pack の --signTemplate から 1 ファイルずつ呼ばれる署名ラッパー。
#
# 目的: 既に Sigilune で署名済みの prunlet.exe・prunlet-maintenance.exe を vpk に再署名させず、
# ZIP 配布物と Velopack の nupkg で同じバイト列を保つ（署名のたびにタイムスタンプが変わるため）。
# 署名者 CN・タイムスタンプ付きの Valid ならそのまま通し、それ以外（Update.exe・Setup.exe など vpk 自身の
# 生成物）だけを署名する。署名後は Signing.Common.ps1 の検査（Valid・CN・タイムスタンプ）を独立に通す。
# 失敗は終了コード 1 で返し、vpk pack を止める（呼び出し側が配信へ進まない）。
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SigiluneExe,
    [Parameter(Mandatory)][string]$Path
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
try {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Signing.Common.ps1')
    if (![IO.Path]::IsPathFullyQualified($SigiluneExe) -or !(Test-Path -LiteralPath $SigiluneExe -PathType Leaf)) { throw 'SigiluneExe must be the absolute path of sigilune.exe.' }
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File to sign was not found: $Path" }
    $existing = Get-AuthenticodeSignature -LiteralPath $Path
    if ($existing.Status -eq [Management.Automation.SignatureStatus]::Valid -and $existing.TimeStamperCertificate -and
        $existing.SignerCertificate -and
        $existing.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ceq $script:PrunletSignerCommonName) {
        Write-Host "already signed, kept as is: $([IO.Path]::GetFileName($Path))"
        exit 0
    }
    # Sigilune の出力は診断用に表示だけする。--replace は不完全・別署名の既存署名を置き換える。
    & $SigiluneExe sign --replace $Path 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "sigilune sign failed with exit code $LASTEXITCODE for $Path." }
    $null = Assert-PrunletAuthenticodeSigned $Path
    Write-Host "signed: $([IO.Path]::GetFileName($Path))"
    exit 0
} catch {
    [Console]::Error.WriteLine("Sign-IfNeeded failed: $($_.Exception.Message)")
    exit 1
}
