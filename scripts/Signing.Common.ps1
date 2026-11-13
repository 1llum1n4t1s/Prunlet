#requires -Version 7.0
# Windows配布物のAuthenticode署名と、その検証を一か所にまとめる。
#
# 署名はSigilune（https://github.com/1llum1n4t1s/Sigilune）で、Certum SimplySignの
# クラウド鍵を使う。SimplySign Desktopは不要で、GitHub Actionsではrelease workflowが
# 承認付きEnvironment `release`のSecrets（SIGILUNE_EMAIL・SIGILUNE_TOTP_URI）を
# 署名stepだけへ渡して実行する。手元ではSigiluneの登録（sigilune setup）を使う。
#
# Sigilune自身も署名後に検証するが、Prunletの配布条件として、Windowsの判定が`Valid`、
# 署名者の共通名、タイムスタンプの存在をここでも独立に確認する。タイムスタンプがないと
# 証明書の有効期限後に既存の配布物まで`Valid`でなくなるため。

# 署名者の共通名。証明書の年次更新でthumbprintが変わっても同じ値で照合できる。
$script:PrunletSignerCommonName = 'Open Source Developer Yuichiro Shinozaki'

function Find-PrunletSigilune {
    # 明示指定（絶対パス）を優先し、なければPATH上のsigilune.exeを使う。
    # PRUNLET_SIGILUNEのほか、他の配布スクリプトと共通のSIGILUNE_EXEも受け付ける。
    foreach ($explicit in @($env:PRUNLET_SIGILUNE, $env:SIGILUNE_EXE)) {
        if (!$explicit) { continue }
        if (![IO.Path]::IsPathFullyQualified($explicit) -or !(Test-Path -LiteralPath $explicit -PathType Leaf)) { throw 'PRUNLET_SIGILUNE / SIGILUNE_EXE must be the absolute path of sigilune.exe.' }
        return $explicit
    }
    $command = Get-Command sigilune.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    # 手元の既定配置（PATHへ追加しない導入）。CIはSigiluneのactionがPATHへ追加する。
    $local = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.local\Sigilune\bin\sigilune.exe'
    if (Test-Path -LiteralPath $local -PathType Leaf) { return $local }
    throw 'Sigilune (sigilune.exe) is required to sign Prunlet. Install it or set PRUNLET_SIGILUNE.'
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

function Invoke-PrunletBuildSigning([string[]]$BuildDirectories) {
    # Publish-Prunlet.ps1の出力（<build>\publish と <build>\build-manifest.json）へ署名する。
    # 全runtimeを同じjob・同じSigiluneセッションで署名し、ログイン（TOTP）は最初の1回だけにする。
    if (!$BuildDirectories.Count) { throw 'No build directories to sign.' }
    $builds = [Collections.Generic.List[object]]::new()
    $targets = [Collections.Generic.List[string]]::new()
    foreach ($directory in $BuildDirectories) {
        if (![IO.Path]::IsPathFullyQualified($directory)) { throw "Build directory must be absolute: $directory" }
        $root = [IO.Path]::GetFullPath($directory)
        $publish = Join-Path $root 'publish'
        $manifestPath = Join-Path $root 'build-manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
        if ($manifest['probe'] -or $manifest['verificationTools']) { throw "Verification builds cannot be signed for release: $root" }
        if ($manifest.Contains('signing')) { throw "Build is already signed: $root" }
        $exe = Join-Path $publish 'prunlet.exe'
        $maintenanceExe = Join-Path $publish 'prunlet-maintenance.exe'
        $hookExe = Join-Path $publish 'prunlet-hook.exe'
        $unsigned = [ordered]@{}
        foreach ($product in @($exe, $maintenanceExe, $hookExe)) {
            $item = Get-Item -LiteralPath $product -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Signing input cannot be a link: $product" }
            $hash = (Get-FileHash -LiteralPath $product -Algorithm SHA256).Hash.ToLowerInvariant()
            # ビルド記録と一致する未署名の出力だけを受け付ける。
            if ($hash -cne $manifest['products'][$item.Name]) { throw "Build output differs from its manifest: $product" }
            if ((Get-AuthenticodeSignature -LiteralPath $product).Status -ne [Management.Automation.SignatureStatus]::NotSigned) { throw "Signing input is already signed or has an invalid signature: $product" }
            $unsigned[$item.Name] = $hash
        }
        $builds.Add([ordered]@{ manifestPath = $manifestPath; manifest = $manifest; exe = $exe; maintenanceExe = $maintenanceExe; hookExe = $hookExe; unsigned = $unsigned })
        # hookはCLIの複製なので署名しない。署名ごとにタイムスタンプが変わるため、
        # 署名済みCLIを複製し直して両者の同一hashを保つ（更新ZIPが要求する）。
        $targets.Add($exe); $targets.Add($maintenanceExe)
    }
    $sigilune = Find-PrunletSigilune
    # 1ファイルずつ署名する。2026-11-13にv1.0.0公開前のSigiluneで確かめたところ、1回の呼出しで
    # 複数ファイルを渡すと、3回中1回はsigntoolがアクセス違反で異常終了し、1回はdlibがtokioの
    # panic（EnterGuardの解放順序違反）を出した。1ファイルずつの呼出しでは問題が出なかった。
    # セッションはプロセス間で共有されるため、呼出しを分けてもログインは増えない。
    # 失敗時は自動再試行せず、残りの署名もしない（署名済み分は呼出し元が出力ごと破棄する）。
    foreach ($target in $targets) {
        # Sigiluneの出力は戻り値へ混ぜず、診断用に表示だけする（呼出し元はJSONを出力するため）。
        & $sigilune sign $target 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw "sigilune sign failed with exit code $LASTEXITCODE for $target." }
    }
    foreach ($build in $builds) {
        Copy-Item -LiteralPath $build.exe -Destination $build.hookExe -Force
        $products = [ordered]@{}
        foreach ($product in @($build.exe, $build.maintenanceExe, $build.hookExe)) {
            $null = Assert-PrunletAuthenticodeSigned $product
            $products[[IO.Path]::GetFileName($product)] = (Get-FileHash -LiteralPath $product -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        if ($products['prunlet-hook.exe'] -cne $products['prunlet.exe']) { throw 'Signed hook differs from the signed CLI.' }
        # productsは署名後の配布物のhashへ更新し、署名前のhashと署名者を記録として残す。
        $build.manifest['products'] = $products
        $build.manifest['product']['sha256'] = $products['prunlet.exe']
        $build.manifest['signing'] = [ordered]@{ tool = 'sigilune'; signer = $script:PrunletSignerCommonName; unsignedSha256 = $build.unsigned }
        [IO.File]::WriteAllText($build.manifestPath, ($build.manifest | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    }
}
