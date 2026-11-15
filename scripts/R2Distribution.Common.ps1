#requires -Version 7.2
# Prunlet の R2（バケット prunlet-updates、公開 https://prunlet.kagayoi.com）への配信の共通層。
# 転送・署名（S3 互換 SigV4 / Cloudflare API トークンからの鍵導出）は、同梱の共有コピー
# scripts/velopack/R2Transfer.Core.cs（Kagayoi.R2.Transfer）を使う。共有コピーは他リポジトリと同一なので編集しない。
# テストが注入できるよう、HttpClient の生成は session の ClientFactory 経由に統一する（公開入口のスクリプトには
# 注入用のスイッチを足さない）。
#
# 公開の順序（runtime ごと）: 配布物（create-only）→ 公開 URL で照合 → 版マニフェスト（create-only）→
#   最新ポインタ（ETag 条件付き置換）→ 固定名（Linux の手動取得用。最後に置換）。
# 書込みの前に、署名・既存の版マニフェスト・最新ポインタ（後退）の検査をすべて読取りだけで済ませる。
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'PrunletRelease.Common.ps1')
. (Join-Path $PSScriptRoot 'velopack/R2Distribution.Common.ps1')

$script:PrunletPublicBase = 'https://prunlet.kagayoi.com'

function Stop-PrunletR2 {
    # R2 の公開層の失敗は固定語彙（phase・code・httpStatus）だけを持つ例外にする。
    param([Parameter(Mandatory)][string]$Phase, [Parameter(Mandatory)][string]$Code, [ValidateRange(0, 599)][int]$HttpStatus = 0)
    if ($Phase -cnotmatch '^[a-z0-9-]+$' -or $Code -cnotmatch '^[a-z0-9-]+$') { $Phase = 'release'; $Code = 'operation-failed'; $HttpStatus = 0 }
    $message = "R2 publisher stopped: phase=$Phase code=$Code"
    if ($HttpStatus -ge 100) { $message += " httpStatus=$HttpStatus" }
    $failure = [InvalidOperationException]::new($message)
    $failure.Data['PrunletR2SafeFailure'] = $true
    throw $failure
}

function Get-PrunletR2SafeFailure([Exception]$Failure) {
    # 生の例外・response は通さず、このリポジトリの層が作った固定語彙（Prunlet 側・共有コピー側）だけを継承する。
    for ($depth = 0; $null -ne $Failure -and $depth -lt 8; $depth++) {
        if ($Failure.Data['PrunletR2SafeFailure'] -eq $true -and $Failure.Message -cmatch '^R2 publisher stopped: phase=[a-z0-9-]+ code=[a-z0-9-]+( httpStatus=[1-5][0-9]{2})?$') {
            $safe = [InvalidOperationException]::new($Failure.Message); $safe.Data['PrunletR2SafeFailure'] = $true; return $safe
        }
        if ($Failure.Data['PrunletReleaseSafeFailure'] -eq $true -and $Failure.Message -cmatch '^Prunlet release stopped: phase=[a-z0-9-]+ code=[a-z0-9-]+$') {
            $safe = [InvalidOperationException]::new($Failure.Message); $safe.Data['PrunletReleaseSafeFailure'] = $true; return $safe
        }
        if ($Failure.Data['R2DistributionSafe'] -eq $true -and $Failure.Message -cmatch '^R2 transfer stopped: phase=[a-z-]+ code=[a-z-]+( httpStatus=[1-5][0-9]{2})?$') {
            $safe = [InvalidOperationException]::new($Failure.Message); $safe.Data['R2DistributionSafe'] = $true; return $safe
        }
        $Failure = $Failure.InnerException
    }
    return $null
}

function New-PrunletR2Session {
    # 認証は環境変数から。CLOUDFLARE_API_TOKEN（Environment `release` の Secret。R2 書込み＋purge 権限）を優先し、
    # 無ければ従来の S3 互換キー（PRUNLET_R2_ACCESS_KEY_ID / PRUNLET_R2_SECRET_ACCESS_KEY）を使う。値はログへ出さない。
    # アカウント ID は秘密ではないが推測で固定せず、従来どおり PRUNLET_R2_ACCOUNT_ID（Secret / 引数）から受け取る。
    param(
        [string]$AccountId = $env:PRUNLET_R2_ACCOUNT_ID,
        [string]$Bucket = $(if ($env:PRUNLET_R2_BUCKET) { $env:PRUNLET_R2_BUCKET } else { 'prunlet-updates' }),
        [Func[Net.Http.HttpClient]]$ClientFactory,
        [string]$PublicBase = $script:PrunletPublicBase
    )
    if ($AccountId -cnotmatch '^[0-9a-f]{32}$' -or $Bucket -cnotmatch '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$') { Stop-PrunletR2 'identity' 'invalid-input' }
    if ($PublicBase -cnotmatch '^https://[a-z0-9.-]+$') { Stop-PrunletR2 'identity' 'invalid-input' }
    if ($null -eq $ClientFactory) { $ClientFactory = [Func[Net.Http.HttpClient]]{ New-R2DistributionClient } }
    $token = $env:CLOUDFLARE_API_TOKEN
    $accessKey = $env:PRUNLET_R2_ACCESS_KEY_ID
    $secretKey = $env:PRUNLET_R2_SECRET_ACCESS_KEY
    $mode = if (![string]::IsNullOrWhiteSpace($token)) { 'token' } elseif (![string]::IsNullOrWhiteSpace($accessKey) -and ![string]::IsNullOrWhiteSpace($secretKey)) { 's3' } else { $null }
    if ($null -eq $mode) { Stop-PrunletR2 'credentials' 'unavailable-before-http' }
    $client = $ClientFactory.Invoke()
    try {
        $credentials = if ($mode -ceq 'token') {
            Get-R2DistributionCredentials -Client $client -AccountId $AccountId -ApiToken $token -AccessKeyId '' -SecretAccessKey ''
        } else {
            Get-R2DistributionCredentials -Client $client -AccountId $AccountId -ApiToken '' -AccessKeyId $accessKey -SecretAccessKey $secretKey
        }
    } catch { $client.Dispose(); throw }
    return [pscustomobject]@{
        Mode = $mode; AccountId = $AccountId; Bucket = $Bucket; PublicBase = $PublicBase.TrimEnd('/')
        ClientFactory = $ClientFactory; Client = $client; Credentials = $credentials
        ApiToken = $token; AccessKeyId = $accessKey; SecretAccessKey = $secretKey
    }
}

function Close-PrunletR2Session($Session) {
    if ($null -ne $Session -and $null -ne $Session.Client) { $Session.Client.Dispose() }
}

function Read-PrunletR2Object {
    # 認証付き GET（公開ホストの CDN を経由しない）。404 は Status=404・Bytes=$null。200 以外の失敗は例外。
    # 公開 URL を事前に叩いて 404 をキャッシュさせないため、存在確認はここ（S3 API）で行う。
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Key, [long]$MaxBytes = 1MB)
    $address = [Kagayoi.R2.Transfer]::ObjectAddress($Session.AccountId, $Session.Bucket, $Key)
    $request = New-R2DistributionRequest -Method GET -Uri $address.Uri -CanonicalPath $address.Path -PayloadHash ([Kagayoi.R2.Transfer]::EmptyHash) -Credentials $Session.Credentials
    try {
        $response = Send-R2DistributionRequest -Client $Session.Client -Request $request -Phase 's3-read'
        try {
            $status = [int]$response.StatusCode
            if ($status -eq 404) { return [pscustomobject]@{ Status = 404; Bytes = $null; ETag = '' } }
            if ($status -ne 200) { Stop-PrunletR2 's3-read' 'http-rejected' $status }
            $length = $response.Content.Headers.ContentLength
            if ($null -ne $length -and $length -gt $MaxBytes) { Stop-PrunletR2 's3-read' 'body-mismatch' $status }
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            if ($bytes.Length -gt $MaxBytes) { Stop-PrunletR2 's3-read' 'body-mismatch' $status }
            $etag = if ($null -ne $response.Headers.ETag) { $response.Headers.ETag.ToString() } else { '' }
            return [pscustomobject]@{ Status = 200; Bytes = $bytes; ETag = $etag }
        } finally { $response.Dispose() }
    } finally { $request.Dispose() }
}

function Write-PrunletR2Bytes {
    # メモリ上の小さなオブジェクトを PUT する。IfMatch が空なら create-only（If-None-Match: *）、あれば ETag 条件付き置換。
    # 戻り値: 'written'（200）| 'exists'（create-only で 412）| 'changed'（条件付き置換で 412）。
    # 結果不明の失敗（転送エラー・5xx）は再送せず例外にする。
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][byte[]]$Bytes,
        [string]$ContentType = 'application/json', [string]$CacheControl = 'no-cache, must-revalidate', [string]$IfMatch)
    $address = [Kagayoi.R2.Transfer]::ObjectAddress($Session.AccountId, $Session.Bucket, $Key)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    $headers = @{ 'cache-control' = $CacheControl }
    if ([string]::IsNullOrEmpty($IfMatch)) { $headers['if-none-match'] = '*' } else { $headers['if-match'] = $IfMatch }
    $request = New-R2DistributionRequest -Method PUT -Uri $address.Uri -CanonicalPath $address.Path -PayloadHash $hash -Credentials $Session.Credentials -ExtraHeaders $headers
    try {
        $request.Content = [Net.Http.ByteArrayContent]::new($Bytes)
        $request.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType)
        $response = Send-R2DistributionRequest -Client $Session.Client -Request $request -Phase 's3-put'
        try {
            $status = [int]$response.StatusCode
            if ($status -eq 200) { return 'written' }
            if ($status -eq 412) { return $(if ([string]::IsNullOrEmpty($IfMatch)) { 'exists' } else { 'changed' }) }
            if ($status -ge 400 -and $status -lt 500) { Stop-PrunletR2 's3-put' 'http-rejected' $status }
            Stop-PrunletR2 's3-put' 'unknown-no-resend' $status
        } finally { $response.Dispose() }
    } finally { $request.Dispose() }
}

function Publish-PrunletR2File {
    # 実ファイルの配信（共有コピーの PublishObject）。Immutable は create-only で、既存と内容が違えば上書きせず失敗する。
    # 同じ読取り handle で hash・送信・最終照合まで行う。client は呼出しごとに生成・破棄される。
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$FilePath,
        [string]$ContentType = 'application/octet-stream', [string]$CacheControl, [switch]$Immutable, [string]$ExpectedETag)
    if ([string]::IsNullOrEmpty($CacheControl)) { $CacheControl = if ($Immutable) { 'public, max-age=31536000, immutable' } else { 'no-cache, must-revalidate' } }
    $expectedBound = ![string]::IsNullOrEmpty($ExpectedETag)
    $token = $null; $access = $null; $secret = $null; $accessBound = $false
    if ($Session.Mode -ceq 'token') { $token = $Session.ApiToken } else { $access = $Session.AccessKeyId; $secret = $Session.SecretAccessKey; $accessBound = $true }
    try {
        $result = [Kagayoi.R2.Transfer]::PublishObject($Session.AccountId, $Session.Bucket, [IO.Path]::GetFullPath($FilePath), $Key, $token, $access, $secret,
            $CacheControl, $ContentType, $Immutable.IsPresent, $ExpectedETag, $expectedBound, $accessBound, $accessBound, $Session.ClientFactory)
        return [pscustomobject]@{ Key = $result.Key; ETag = $result.ETag; SHA256 = $result.SHA256; Size = $result.Size; Changed = $result.Changed }
    } catch { throw [Kagayoi.R2.Transfer]::SafeFailure($_.Exception) }
}

function Assert-PrunletR2Remote {
    # 認証付き GET で、オブジェクトの長さと SHA-256 を照合する（ETag は使わない。実体そのものを検証する）。
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][long]$Bytes, [Parameter(Mandatory)][string]$Sha256)
    $address = [Kagayoi.R2.Transfer]::ObjectAddress($Session.AccountId, $Session.Bucket, $Key)
    try { return Assert-R2DistributionRemote -Client $Session.Client -Uri $address.Uri -CanonicalPath $address.Path -Credentials $Session.Credentials -Size $Bytes -Hash $Sha256 -ExpectedETag '' }
    catch { throw [Kagayoi.R2.Transfer]::SafeFailure($_.Exception, 'verify') }
}

function Assert-PrunletPublicObject {
    # 公開 URL（Cloudflare 経由・リダイレクト無効）から取り直し、長さと SHA-256 を照合する。
    # 公開ドメイン未設定・誤設定のまま最新ポインタだけを進めないための確認。
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][long]$Bytes, [Parameter(Mandatory)][string]$Sha256)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, [uri]"$($Session.PublicBase)/$Key")
    $response = $null; $stream = $null
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $deadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(30))
    try {
        $response = Send-R2DistributionRequest -Client $Session.Client -Request $request -Phase 'public-get' -CancellationToken $deadline.Token
        $status = [int]$response.StatusCode
        if ($status -ne 200) { Stop-PrunletR2 'public-get' 'http-rejected' $status }
        if ($null -ne $response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -ne $Bytes) { Stop-PrunletR2 'public-get' 'body-mismatch' $status }
        if (@($response.Content.Headers.ContentEncoding).Count -ne 0) { Stop-PrunletR2 'public-get' 'body-mismatch' $status }
        try {
            $stream = $response.Content.ReadAsStreamAsync($deadline.Token).GetAwaiter().GetResult()
            $buffer = [byte[]]::new(65536); [long]$total = 0
            while (($count = $stream.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token).GetAwaiter().GetResult()) -ne 0) {
                if ($count -gt $Bytes - $total) { throw 'exceeds' }
                $hash.AppendData($buffer, 0, $count); $total += $count
            }
            if ($total -ne $Bytes -or [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant() -cne $Sha256) { throw 'differs' }
        } catch { Stop-PrunletR2 'public-get' 'body-mismatch' $status }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }; if ($null -ne $response) { $response.Dispose() }
        $request.Dispose(); $hash.Dispose(); $deadline.Dispose()
    }
}

function Clear-PrunletPublicCache {
    # 固定名（最新ポインタ・Linux の固定名）だけ purge する。版付きはキーが一意なので不要。
    # purge は best effort（固定名は no-cache で配るため）。失敗は警告にとどめ、配信自体は失敗にしない。
    # S3 互換キーだけの実行（token なし）では purge できないので何もしない。
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string[]]$Keys)
    if ($Session.Mode -cne 'token') { return }
    try {
        $zoneName = ([uri]$Session.PublicBase).Host -replace '^[^.]+\.', ''
        $api = 'https://api.cloudflare.com/client/v4'
        $lookup = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, [uri]"$api/zones?name=$zoneName")
        $lookup.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Session.ApiToken)
        $response = $Session.Client.SendAsync($lookup).GetAwaiter().GetResult()
        $zoneId = ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json).result[0].id
        $response.Dispose(); $lookup.Dispose()
        $files = @($Keys | ForEach-Object { "$($Session.PublicBase)/$_" })
        $purge = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, [uri]"$api/zones/$zoneId/purge_cache")
        $purge.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Session.ApiToken)
        $purge.Content = [Net.Http.StringContent]::new((@{ files = $files } | ConvertTo-Json -Compress), [Text.Encoding]::UTF8, 'application/json')
        $response = $Session.Client.SendAsync($purge).GetAwaiter().GetResult()
        $ok = [int]$response.StatusCode -eq 200
        $response.Dispose(); $purge.Dispose()
        if (!$ok) { throw 'purge rejected' }
    } catch { Write-Warning 'Uploaded, but the cache purge of the fixed-name objects failed.' }
}

function Get-PrunletRuntimePlan {
    # 書込みの前の検査（読取りだけ）。ここで失敗すれば R2 に何も置かない。
    #  1. 既存の版マニフェスト: あれば署名が有効で payload が今回の入力と一致すること（再実行の照合。封筒のバイト比較はしない）。
    #  2. 最新ポインタ: 読めなければ配信しない（404 だけが「まだ無い」）。現行が今回より新しければ失敗、
    #     同じ版なら payload の一致だけを確認して verify-only、古い（または無い）なら full。
    #  3. 版マニフェストが未作成なら、ここで署名し、信頼する公開鍵で検証できることを確認する（鍵の取り違えを書込み前に止める）。
    #     -NoSign（事前検査だけ）では署名しない（署名鍵を渡さずに実行できる）。
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Spec, $Trust = (Get-PrunletReleaseTrust), [string]$SigningKeyPem = $env:PRUNLET_RELEASE_SIGNING_KEY, [switch]$NoSign)
    $payload = New-PrunletReleasePayloadBytes -Spec $Spec
    $manifest = Read-PrunletR2Object -Session $Session -Key $Spec.ManifestKey -MaxBytes $script:PrunletReleaseEnvelopeMaxBytes
    $envelope = $null
    if ($manifest.Status -eq 200) {
        $null = Assert-PrunletReleaseEnvelopeMatches -EnvelopeBytes $manifest.Bytes -ExpectedPayload $payload -Trust $Trust
        $envelope = $manifest.Bytes
    }
    $decision = 'full'; $pointerETag = ''
    if ($null -ne $Spec.PointerKey) {
        $pointer = Read-PrunletR2Object -Session $Session -Key $Spec.PointerKey -MaxBytes $script:PrunletReleaseEnvelopeMaxBytes
        if ($pointer.Status -eq 200) {
            $current = Read-PrunletReleaseEnvelope -Bytes $pointer.Bytes -Trust $Trust
            $info = Read-PrunletReleasePayloadInfo -PayloadBytes $current.PayloadBytes
            if ($info.Runtime -cne $Spec.Runtime) { Stop-PrunletR2 'pointer' 'runtime-mismatch' }
            $ours = ConvertTo-PrunletReleaseVersion $Spec.Version
            if ($info.Version -gt $ours) { Stop-PrunletR2 'pointer' 'newer-published' }
            if ($info.Version -eq $ours) {
                if (!(Test-PrunletReleaseBytesEqual $current.PayloadBytes $payload)) { Stop-PrunletR2 'pointer' 'payload-mismatch' }
                $decision = 'verify-only'
            }
            $pointerETag = $pointer.ETag
            if ($decision -ceq 'full' -and ([string]::IsNullOrEmpty($pointerETag) -or $pointerETag.StartsWith('W/', [StringComparison]::Ordinal))) { Stop-PrunletR2 'pointer' 'missing-strong-etag' }
        }
    }
    if ($null -eq $envelope -and !$NoSign) {
        $envelope = New-PrunletReleaseEnvelopeBytes -PayloadBytes $payload -PrivateKeyPem $SigningKeyPem -KeyId $Trust.KeyId
        $null = Assert-PrunletReleaseEnvelopeMatches -EnvelopeBytes $envelope -ExpectedPayload $payload -Trust $Trust
        $manifestExisted = $false
    } else { $manifestExisted = $null -ne $envelope }
    return [pscustomobject]@{ Spec = $Spec; PayloadBytes = $payload; Envelope = $envelope; ManifestExisted = $manifestExisted; Decision = $decision; PointerETag = $pointerETag }
}

function Publish-PrunletVersionManifest {
    # 版マニフェスト manifests/<版>/<runtime>.json を create-only で置く（既存なら Plan で照合済みなので置かない）。
    # 別の実行に先を越された（412）場合は、既存を読み直して署名と payload を照合し、その封筒を使う（上書きしない）。
    # 置いた後は認証付き GET で実体を照合し、使う封筒のバイト列を返す（最新ポインタの中身になる）。
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Plan, $Trust = (Get-PrunletReleaseTrust))
    $spec = $Plan.Spec
    if ($null -eq $Plan.Envelope) { Stop-PrunletR2 'signature' 'not-signed' }
    $envelope = $Plan.Envelope
    if (!$Plan.ManifestExisted) {
        Write-Host "  create-only $($spec.ManifestKey)"
        $state = Write-PrunletR2Bytes -Session $Session -Key $spec.ManifestKey -Bytes $envelope -CacheControl 'public, max-age=31536000, immutable'
        if ($state -ceq 'exists') {
            $raced = Read-PrunletR2Object -Session $Session -Key $spec.ManifestKey -MaxBytes $script:PrunletReleaseEnvelopeMaxBytes
            if ($raced.Status -ne 200) { Stop-PrunletR2 'manifest' 'unreadable' }
            $null = Assert-PrunletReleaseEnvelopeMatches -EnvelopeBytes $raced.Bytes -ExpectedPayload $Plan.PayloadBytes -Trust $Trust
            $envelope = $raced.Bytes
        }
    }
    $envelopeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($envelope)).ToLowerInvariant()
    $null = Assert-PrunletR2Remote -Session $Session -Key $spec.ManifestKey -Bytes $envelope.Length -Sha256 $envelopeHash
    return , $envelope
}

function Invoke-PrunletRuntimePublication {
    # Get-PrunletRuntimePlan の結果に従い、書込みを順に行う。
    #  配布物（create-only）→ 公開 URL で照合 → 版マニフェスト（create-only。既存なら照合済み）→ 最新ポインタ → 固定名。
    # -ArtifactPath は配布物の実ファイル（長さ・SHA-256 は Spec と一致を確認）。-ReuseRemoteArtifact（mac）は、別経路で
    # 不変キーへ置かれた実物を、長さ・SHA-256 で照合して使う（置かれていなければ失敗）。
    # -FixedFiles は Linux の手動取得用の固定名（@{Key;Path;ContentType}）。最新ポインタの更新後に、この順で置換する。
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Plan, [string]$ArtifactPath, [switch]$ReuseRemoteArtifact,
        [object[]]$FixedFiles = @(), $Trust = (Get-PrunletReleaseTrust))
    $spec = $Plan.Spec
    if ($null -eq $Plan.Envelope) { Stop-PrunletR2 'signature' 'not-signed' }
    if ($ReuseRemoteArtifact) {
        $null = Assert-PrunletR2Remote -Session $Session -Key $spec.AssetKey -Bytes $spec.Bytes -Sha256 $spec.Sha256
    } else {
        $facts = Get-PrunletReleaseFileFacts $ArtifactPath
        if ($facts.Bytes -ne $spec.Bytes -or $facts.Sha256 -cne $spec.Sha256) { Stop-PrunletR2 'package-pin' 'changed' }
        Write-Host "  create-only $($spec.AssetKey)"
        $null = Publish-PrunletR2File -Session $Session -Key $spec.AssetKey -FilePath $ArtifactPath -ContentType $spec.ContentType -Immutable
    }
    Assert-PrunletPublicObject -Session $Session -Key $spec.AssetKey -Bytes $spec.Bytes -Sha256 $spec.Sha256

    $envelope = Publish-PrunletVersionManifest -Session $Session -Plan $Plan -Trust $Trust
    $envelopeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($envelope)).ToLowerInvariant()

    if ($Plan.Decision -ceq 'verify-only') {
        Write-Host '  skipped pointer and fixed-name objects (the latest pointer already has this version)'
        return [pscustomobject]@{ Runtime = $spec.Runtime; Version = $spec.Version; Decision = 'verify-only'; PointerUpdated = $false }
    }
    Write-Host "  replace     $($spec.PointerKey)"
    $state = Write-PrunletR2Bytes -Session $Session -Key $spec.PointerKey -Bytes $envelope -IfMatch $Plan.PointerETag
    if ($state -ceq 'changed') { Stop-PrunletR2 'pointer' 'concurrent-change' 412 }
    if ($state -ceq 'exists') { Stop-PrunletR2 'pointer' 'concurrent-change' 412 }
    $null = Assert-PrunletR2Remote -Session $Session -Key $spec.PointerKey -Bytes $envelope.Length -Sha256 $envelopeHash

    $purgeKeys = @($spec.PointerKey)
    foreach ($fixed in $FixedFiles) {
        Write-Host "  replace     $($fixed.Key)"
        $null = Publish-PrunletR2File -Session $Session -Key $fixed.Key -FilePath $fixed.Path -ContentType $fixed.ContentType
        $purgeKeys += $fixed.Key
    }
    Clear-PrunletPublicCache -Session $Session -Keys $purgeKeys
    return [pscustomobject]@{ Runtime = $spec.Runtime; Version = $spec.Version; Decision = 'full'; PointerUpdated = $true }
}
