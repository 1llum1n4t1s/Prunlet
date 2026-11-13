#requires -Version 7.0
# Windows配布物のAuthenticode署名と、その検証を一か所にまとめる。
#
# 署名はCertumのクラウド署名（SimplySign）を使う。SimplySign Desktopへのログインと
# スマートフォンのトークンが必要なため、GitHub Actionsでは署名できない。署名は
# リリース担当者のWindows機で`Publish-PrunletWindows.ps1`から行い、CIは署名済みZIPの
# 検証だけを行う。
#
# 署名者の確認では、Windowsが証明書チェーンを`Valid`と判定することに加えて、
# 署名者の共通名とタイムスタンプの存在も必須にする。タイムスタンプがないと、証明書の
# 有効期限が切れた時点で既存の配布物まで`Valid`でなくなり、公開済みクライアントが
# 受け付けない（NotSigned/Valid以外を拒否する）状態になるため。

# 署名者の共通名。証明書の年次更新でthumbprintが変わっても同じ値で照合できる。
$script:PrunletSignerCommonName = 'Open Source Developer Yuichiro Shinozaki'
# RFC 3161タイムスタンプ。証明書の発行元（Certum）のサーバーを使う。
$script:PrunletTimestampUrl = 'http://time.certum.pl'

function Find-PrunletSignTool {
    # Windows SDKはビルドにも必須なので、同じSDKのsigntoolを使う。PATHには依存しない。
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (!(Test-Path -LiteralPath $kits -PathType Container)) { throw 'Windows SDK is required to sign Prunlet (Windows Kits\10\bin was not found).' }
    $hostArch = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [Runtime.InteropServices.Architecture]::Arm64) { 'arm64' } else { 'x64' }
    $candidates = @(Get-ChildItem -LiteralPath $kits -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName "$hostArch\signtool.exe" } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if (!$candidates.Count) { throw "signtool.exe for $hostArch was not found in the Windows SDK." }
    return $candidates[0]
}

function Get-PrunletSigningCertificate {
    # SimplySign Desktopが接続済みなら、クラウド上の証明書がCurrentUser\Myに見える。
    $now = Get-Date
    $certs = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object {
        $_.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ceq $script:PrunletSignerCommonName -and
        $_.HasPrivateKey -and $_.NotBefore -le $now -and $_.NotAfter -gt $now
    })
    if (!$certs.Count) { throw "Signing certificate (CN=$script:PrunletSignerCommonName) was not found. Start SimplySign Desktop and log in with the token." }
    # 更新直後は新旧が並ぶことがあるため、期限が最も遅いものを使う。thumbprintで指定して曖昧さを避ける。
    return ($certs | Sort-Object NotAfter -Descending | Select-Object -First 1)
}

function Assert-PrunletAuthenticodeSigned([string]$Path) {
    # 署名者・チェーン・タイムスタンプがすべて揃っていることを確認する。
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) { throw "Authenticode signature is not valid ($($signature.Status)): $Path" }
    if ($signature.SignatureType -ne [Management.Automation.SignatureType]::Authenticode) { throw "Signature is not an embedded Authenticode signature: $Path" }
    $signer = $signature.SignerCertificate
    if (!$signer -or $signer.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne $script:PrunletSignerCommonName) {
        throw "Unexpected Authenticode signer: $Path"
    }
    if (!$signature.TimeStamperCertificate) { throw "Authenticode signature has no timestamp: $Path" }
    return $signature
}

function Invoke-PrunletAuthenticodeSign([string[]]$Paths) {
    # 1回のsigntool呼出しでまとめて署名し、SimplySignのトークン確認を最小限にする。
    if (!$Paths.Count) { throw 'No files to sign.' }
    foreach ($path in $Paths) {
        if (![IO.Path]::IsPathFullyQualified($path) -or !(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Signing input must be an existing absolute file: $path" }
        # 二重署名を避け、ビルド直後の未署名ファイルだけを受け付ける。
        if ((Get-AuthenticodeSignature -LiteralPath $path).Status -ne [Management.Automation.SignatureStatus]::NotSigned) { throw "Signing input is already signed or has an invalid signature: $path" }
    }
    $signTool = Find-PrunletSignTool
    $cert = Get-PrunletSigningCertificate
    $arguments = @('sign', '/sha1', $cert.Thumbprint, '/fd', 'SHA256', '/tr', $script:PrunletTimestampUrl, '/td', 'SHA256') + $Paths
    # signtoolの出力は戻り値へ混ぜず、診断用に表示だけする（呼出し元はJSONを出力するため）。
    & $signTool @arguments 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "signtool failed with exit code $LASTEXITCODE. Connect SimplySign Desktop (vava Connect-SimplySign.ps1) and retry with a new output directory." }
    foreach ($path in $Paths) { $null = Assert-PrunletAuthenticodeSigned $path }
    return [ordered]@{ signer = $script:PrunletSignerCommonName; thumbprint = $cert.Thumbprint; timestampUrl = $script:PrunletTimestampUrl }
}
