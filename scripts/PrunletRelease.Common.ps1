#requires -Version 7.2
# 配信用の署名付きマニフェスト（schema 1）の組み立て・署名・検証。
#
# 目的: GitHub Release もタグも使わず、R2（https://prunlet.kagayoi.com）を唯一の配布元にする。クライアントは
# 固定の公開鍵で封筒の署名を検証し、payload が指す配布物の長さ・SHA-256 を照合してから適用する。
# このファイルは「配信側の正本」で、署名鍵の秘密部分は環境変数 PRUNLET_RELEASE_SIGNING_KEY（PKCS8 PEM）から
# 実行時にだけ読む。秘密鍵の値はログ・例外・戻り値へ出さない。
#
# 封筒（envelope、UTF-8・BOMなし・compact・キー順固定・16 KiB 以下・キーはこの4つだけ）:
#   {"schema":1,"keyId":"prunlet-release-1","payload":"<base64>","signature":"<base64 DER>"}
# 署名対象は payload を base64 復号した「バイト列そのもの」。署名は ECDSA P-256 + SHA-256 で、署名の形式は
# RFC 3279 の DER（ASN.1 SEQUENCE{r,s}）。.NET の既定（r||s の 64 バイト）ではないので、署名と検証の両方で
# DSASignatureFormat.Rfc3279DerSequence を必ず明示する（openssl dgst -sha256 -verify はこの DER だけを受け付ける）。
#
# payload（UTF-8・BOMなし・compact・時刻を含まない決定的なバイト列。同じ入力なら必ず同じバイトになるので、
# 再実行時は署名ではなく payload のバイト一致で照合できる）:
#   {"schema":1,"product":"Prunlet","repository":"1llum1n4t1s/Prunlet","runtime":"<runtime>","version":"x.y.z",
#    "commit":"<40桁小文字hex>","defaultBranch":"<branch>",
#    "asset":{"name":"<固定名>","key":"<R2キー>","bytes":<整数>,"sha256":"<64桁小文字hex>"}}
Set-StrictMode -Version Latest

# --- 信頼の固定値（本番） ----------------------------------------------------------------------------------
# 鍵整合の関門（Test-PrunletReleaseKeyGate.ps1）は、クライアント側 3 か所（Rust・Install-Prunlet.ps1・
# Install-Prunlet.sh。launcher は定数を持たず、持つ場合だけ検査対象）の同名の定数が、ここの値と同じであることを
# 照合する。マーカー名 PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64 は関門の抽出規則と一致させる（変えない）。
$script:PRUNLET_RELEASE_KEY_ID = 'prunlet-release-1'
$script:PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64 = 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEMIbQQg1ZUrL1G3V5sKqnQm74bz087XUrB5+wnCXOfBnP8kREgm960J5b9S/fT0rUgopgPODpO9/PINkkCFhJbA=='

$script:PrunletReleaseRepository = '1llum1n4t1s/Prunlet'
$script:PrunletReleaseEnvelopeMaxBytes = 16384
# 対象 runtime ごとの固定 asset 名と上限。現クライアントの上限（Windows ZIP は既存 updater の 512 MiB、
# Linux・mac は 64 MiB。Velopack の nupkg は 512 MiB を配信側の上限にする）に合わせる。
$script:PrunletReleaseRuntimes = @('win-x64', 'win-arm64', 'linux-x64', 'linux-arm64', 'osx-arm64', 'velopack-win-x64')

function Stop-PrunletRelease {
    # 例外メッセージは固定語彙だけにして、鍵・入力の生値を混ぜない。
    param([Parameter(Mandatory)][string]$Phase, [Parameter(Mandatory)][string]$Code)
    if ($Phase -cnotmatch '^[a-z0-9-]+$' -or $Code -cnotmatch '^[a-z0-9-]+$') { $Phase = 'release'; $Code = 'operation-failed' }
    $failure = [InvalidOperationException]::new("Prunlet release stopped: phase=$Phase code=$Code")
    $failure.Data['PrunletReleaseSafeFailure'] = $true
    throw $failure
}

function Get-PrunletReleaseTrust {
    # 本番の信頼。テストは別の keyId・公開鍵の同形オブジェクトを明示して渡す（本番の経路へテスト鍵を混ぜない）。
    return [pscustomobject]@{ KeyId = $script:PRUNLET_RELEASE_KEY_ID; PublicKey = $script:PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64 }
}

function Test-PrunletReleaseVersion([string]$Version) { return $Version -cmatch '^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$' }
function ConvertTo-PrunletReleaseVersion([string]$Version) {
    if (!(Test-PrunletReleaseVersion $Version)) { Stop-PrunletRelease 'input' 'invalid-version' }
    return [version]$Version
}

function Get-PrunletReleaseDescriptor {
    # runtime から、固定 asset 名・配布物の拡張子・content type・上限を決める。
    param([Parameter(Mandatory)][string]$Runtime, [Parameter(Mandatory)][string]$Version)
    switch ($Runtime) {
        'win-x64' { $name = 'prunlet-update-win-x64.zip'; $extension = 'zip'; $type = 'application/zip'; $max = 512MB }
        'win-arm64' { $name = 'prunlet-update-win-arm64.zip'; $extension = 'zip'; $type = 'application/zip'; $max = 512MB }
        'osx-arm64' { $name = 'prunlet-update-osx-arm64.zip'; $extension = 'zip'; $type = 'application/zip'; $max = 64MB }
        'linux-x64' { $name = 'prunlet-linux-x64.tar.gz'; $extension = 'tar.gz'; $type = 'application/gzip'; $max = 64MB }
        'linux-arm64' { $name = 'prunlet-linux-arm64.tar.gz'; $extension = 'tar.gz'; $type = 'application/gzip'; $max = 64MB }
        'velopack-win-x64' { $name = "PrunletApp-$Version-full.nupkg"; $extension = 'nupkg'; $type = 'application/octet-stream'; $max = 512MB }
        default { Stop-PrunletRelease 'input' 'invalid-runtime' }
    }
    return [pscustomobject]@{ Runtime = $Runtime; AssetName = $name; Extension = $extension; ContentType = $type; MaxBytes = [long]$max }
}

function New-PrunletReleaseSpec {
    # 配信 1 件（runtime 1 つ）の確定入力。ここで形式を検査し、以後のキー・payload はこの値だけから導く。
    param(
        [Parameter(Mandatory)][string]$Runtime, [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$CommitSha, [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$Sha256, [Parameter(Mandatory)][long]$Bytes,
        [string]$Repository = $script:PrunletReleaseRepository
    )
    if ($Repository -cne $script:PrunletReleaseRepository) { Stop-PrunletRelease 'input' 'invalid-repository' }
    if (!(Test-PrunletReleaseVersion $Version)) { Stop-PrunletRelease 'input' 'invalid-version' }
    if ($CommitSha -cnotmatch '^[0-9a-f]{40}$') { Stop-PrunletRelease 'input' 'invalid-commit' }
    if ($DefaultBranch -cnotmatch '^[A-Za-z0-9._/-]+$' -or $DefaultBranch.Contains('..') -or $DefaultBranch.StartsWith('/') -or $DefaultBranch.EndsWith('/')) { Stop-PrunletRelease 'input' 'invalid-branch' }
    if ($Sha256 -cnotmatch '^[0-9a-f]{64}$') { Stop-PrunletRelease 'input' 'invalid-sha256' }
    $descriptor = Get-PrunletReleaseDescriptor -Runtime $Runtime -Version $Version
    if ($Bytes -le 0 -or $Bytes -gt $descriptor.MaxBytes) { Stop-PrunletRelease 'input' 'invalid-length' }
    $repo = $Repository.ToLowerInvariant()
    # 配布物のキー。win・mac・linux は commit / runtime / sha256 を含む create-only の不変キー（既存形式を拡張）。
    # Velopack は現状維持の velopack/ prefix。
    $key = if ($Runtime -ceq 'velopack-win-x64') { "velopack/$($descriptor.AssetName)" } else { "releases/$repo/$CommitSha/$Runtime/$Sha256.$($descriptor.Extension)" }
    return [pscustomobject]@{
        Repository = $Repository; Runtime = $Runtime; Version = $Version; CommitSha = $CommitSha; DefaultBranch = $DefaultBranch
        AssetName = $descriptor.AssetName; AssetKey = $key; Bytes = $Bytes; Sha256 = $Sha256
        ContentType = $descriptor.ContentType; Extension = $descriptor.Extension
        ManifestKey = "manifests/$Version/$Runtime.json"
        # velopack は feed（releases.win.json）自体が最新ポインタを兼ねるので latest/ は使わない。
        PointerKey = if ($Runtime -ceq 'velopack-win-x64') { $null } else { "latest/$Runtime.json" }
    }
}

function New-PrunletReleasePayloadBytes {
    # 決定的な payload。キー順・空白なし・UTF-8 BOMなし。時刻・乱数は入れない。
    param([Parameter(Mandatory)]$Spec)
    $stream = [IO.MemoryStream]::new()
    $options = [Text.Json.JsonWriterOptions]::new()
    $options.Encoder = [Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
    $options.Indented = $false
    $writer = [Text.Json.Utf8JsonWriter]::new($stream, $options)
    try {
        $writer.WriteStartObject()
        $writer.WriteNumber('schema', [long]1)
        $writer.WriteString('product', 'Prunlet')
        $writer.WriteString('repository', [string]$Spec.Repository)
        $writer.WriteString('runtime', [string]$Spec.Runtime)
        $writer.WriteString('version', [string]$Spec.Version)
        $writer.WriteString('commit', [string]$Spec.CommitSha)
        $writer.WriteString('defaultBranch', [string]$Spec.DefaultBranch)
        $writer.WriteStartObject('asset')
        $writer.WriteString('name', [string]$Spec.AssetName)
        $writer.WriteString('key', [string]$Spec.AssetKey)
        $writer.WriteNumber('bytes', [long]$Spec.Bytes)
        $writer.WriteString('sha256', [string]$Spec.Sha256)
        $writer.WriteEndObject()
        $writer.WriteEndObject()
        $writer.Flush()
        return , $stream.ToArray()
    } finally { $writer.Dispose(); $stream.Dispose() }
}

function Import-PrunletReleasePublicKey([string]$SpkiBase64) {
    $ecdsa = [Security.Cryptography.ECDsa]::Create()
    try {
        $der = [Convert]::FromBase64String($SpkiBase64)
        $read = 0
        $ecdsa.ImportSubjectPublicKeyInfo($der, [ref]$read)
        if ($read -ne $der.Length -or $ecdsa.KeySize -ne 256 -or $ecdsa.ExportParameters($false).Curve.Oid.Value -cne '1.2.840.10045.3.1.7') { throw 'not P-256' }
        return $ecdsa
    } catch { $ecdsa.Dispose(); Stop-PrunletRelease 'signature' 'invalid-public-key' }
}

function New-PrunletReleaseEnvelopeBytes {
    # 署名して封筒を作る。秘密鍵（PKCS8 PEM）は引数か環境変数 PRUNLET_RELEASE_SIGNING_KEY から読み、保持しない。
    param(
        [Parameter(Mandatory)][byte[]]$PayloadBytes,
        [string]$PrivateKeyPem = $env:PRUNLET_RELEASE_SIGNING_KEY,
        [string]$KeyId = $script:PRUNLET_RELEASE_KEY_ID
    )
    if ([string]::IsNullOrWhiteSpace($PrivateKeyPem)) { Stop-PrunletRelease 'signature' 'missing-signing-key' }
    $ecdsa = [Security.Cryptography.ECDsa]::Create()
    try {
        try {
            $ecdsa.ImportFromPem($PrivateKeyPem)
            if ($ecdsa.KeySize -ne 256 -or $ecdsa.ExportParameters($false).Curve.Oid.Value -cne '1.2.840.10045.3.1.7') { throw 'not P-256' }
        } catch { Stop-PrunletRelease 'signature' 'invalid-signing-key' }
        # 署名は DER（Rfc3279DerSequence）。r||s の既定形式にしない。
        $signature = $ecdsa.SignData($PayloadBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence)
    } finally { $ecdsa.Dispose() }
    $stream = [IO.MemoryStream]::new()
    $options = [Text.Json.JsonWriterOptions]::new()
    $options.Encoder = [Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
    $options.Indented = $false
    $writer = [Text.Json.Utf8JsonWriter]::new($stream, $options)
    try {
        $writer.WriteStartObject()
        $writer.WriteNumber('schema', [long]1)
        $writer.WriteString('keyId', $KeyId)
        $writer.WriteString('payload', [Convert]::ToBase64String($PayloadBytes))
        $writer.WriteString('signature', [Convert]::ToBase64String($signature))
        $writer.WriteEndObject()
        $writer.Flush()
        $bytes = $stream.ToArray()
    } finally { $writer.Dispose(); $stream.Dispose() }
    if ($bytes.Length -gt $script:PrunletReleaseEnvelopeMaxBytes) { Stop-PrunletRelease 'signature' 'envelope-too-large' }
    return , $bytes
}

function Read-PrunletReleaseEnvelope {
    # 封筒の厳密な検査と署名検証。成功すると payload のバイト列を返す。失敗は固定語彙の例外。
    # クライアント（後続フェーズ）が実装する検査の参照実装でもある:
    #   16 KiB 以下 / 厳密な UTF-8 / キーがちょうど schema,keyId,payload,signature の4つ（重複なし） / schema==1 /
    #   keyId が固定値 / payload・signature は正規の base64 / 固定公開鍵で DER 署名を検証。
    param([Parameter(Mandatory)][byte[]]$Bytes, $Trust = (Get-PrunletReleaseTrust))
    if ($Bytes.Length -lt 2 -or $Bytes.Length -gt $script:PrunletReleaseEnvelopeMaxBytes) { Stop-PrunletRelease 'envelope' 'invalid-size' }
    $document = $null
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
        $options = [Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 4; $options.AllowTrailingCommas = $false; $options.CommentHandling = [Text.Json.JsonCommentHandling]::Disallow
        $document = [Text.Json.JsonDocument]::Parse($text, $options)
        $root = $document.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'not an object' }
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $values = @{}
        foreach ($property in $root.EnumerateObject()) {
            if (!$names.Add($property.Name)) { throw 'duplicate key' }
            $values[$property.Name] = $property.Value
        }
        if ($names.Count -ne 4 -or !$names.SetEquals([string[]]@('schema', 'keyId', 'payload', 'signature'))) { throw 'unexpected keys' }
        $schema = 0
        if ($values['schema'].ValueKind -ne [Text.Json.JsonValueKind]::Number -or !$values['schema'].TryGetInt32([ref]$schema) -or $schema -ne 1) { throw 'schema' }
        foreach ($name in @('keyId', 'payload', 'signature')) { if ($values[$name].ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'type' } }
        $keyId = $values['keyId'].GetString(); $payloadText = $values['payload'].GetString(); $signatureText = $values['signature'].GetString()
    } catch { Stop-PrunletRelease 'envelope' 'malformed' } finally { if ($null -ne $document) { $document.Dispose() } }
    if ($keyId -cne $Trust.KeyId) { Stop-PrunletRelease 'envelope' 'unknown-key-id' }
    try {
        $payload = [Convert]::FromBase64String($payloadText); $signature = [Convert]::FromBase64String($signatureText)
        if ([Convert]::ToBase64String($payload) -cne $payloadText -or [Convert]::ToBase64String($signature) -cne $signatureText) { throw 'non-canonical base64' }
    } catch { Stop-PrunletRelease 'envelope' 'invalid-base64' }
    $ecdsa = Import-PrunletReleasePublicKey $Trust.PublicKey
    try {
        $valid = $ecdsa.VerifyData($payload, $signature, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence)
    } catch { $valid = $false } finally { $ecdsa.Dispose() }
    if (!$valid) { Stop-PrunletRelease 'signature' 'verification-failed' }
    return [pscustomobject]@{ PayloadBytes = $payload; Envelope = $Bytes }
}

function Read-PrunletReleasePayloadInfo {
    # 署名検証済みの payload から、後退判定に使う最小の項目を厳密に読む（キー集合・型・形式を検査）。
    param([Parameter(Mandatory)][byte[]]$PayloadBytes)
    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse([Text.UTF8Encoding]::new($false, $true).GetString($PayloadBytes))
        $root = $document.RootElement
        $top = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $map = @{}
        foreach ($property in $root.EnumerateObject()) { if (!$top.Add($property.Name)) { throw 'duplicate' }; $map[$property.Name] = $property.Value }
        if (!$top.SetEquals([string[]]@('schema', 'product', 'repository', 'runtime', 'version', 'commit', 'defaultBranch', 'asset'))) { throw 'keys' }
        $version = $map['version'].GetString(); $runtime = $map['runtime'].GetString()
        if ($map['schema'].GetInt32() -ne 1 -or $map['product'].GetString() -cne 'Prunlet' -or !(Test-PrunletReleaseVersion $version) -or $runtime -cnotin $script:PrunletReleaseRuntimes) { throw 'values' }
        return [pscustomobject]@{ Version = [version]$version; VersionText = $version; Runtime = $runtime; Commit = $map['commit'].GetString() }
    } catch { Stop-PrunletRelease 'payload' 'malformed' } finally { if ($null -ne $document) { $document.Dispose() } }
}

function Test-PrunletReleaseBytesEqual([byte[]]$Left, [byte[]]$Right) {
    return [Linq.Enumerable]::SequenceEqual($Left, $Right)
}

function Assert-PrunletReleaseEnvelopeMatches {
    # 既存の封筒が、今回の入力から決まる payload と一致し、署名が有効であること。封筒全体のバイト比較はしない
    # （ECDSA の署名は毎回変わるため）。
    param([Parameter(Mandatory)][byte[]]$EnvelopeBytes, [Parameter(Mandatory)][byte[]]$ExpectedPayload, $Trust = (Get-PrunletReleaseTrust))
    $envelope = Read-PrunletReleaseEnvelope -Bytes $EnvelopeBytes -Trust $Trust
    if (!(Test-PrunletReleaseBytesEqual $envelope.PayloadBytes $ExpectedPayload)) { Stop-PrunletRelease 'payload' 'mismatch' }
    return $envelope
}

function Get-PrunletReleaseFileFacts {
    # 配布物の実ファイルから長さ・SHA-256（小文字hex）を求める。同じ読取り handle で両方を出す。
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { return [pscustomobject]@{ Bytes = $stream.Length; Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() } }
    finally { $stream.Dispose() }
}
