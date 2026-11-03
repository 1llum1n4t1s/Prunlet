#requires -Version 7.0
# endpoint注入は公開publisherへ露出させず、検証時だけHttpClientを内部へ渡す。
Set-StrictMode -Version Latest

function Stop-PrunletR2 {
    param(
        [ValidateSet('identity','package-verification','package-pin','credentials','s3-head','s3-put','s3-existing','public-get')][string]$Phase,
        [ValidateSet('invalid-input','verification-failed','pin-failed','changed','unavailable-before-http','request-failed','http-rejected','body-mismatch','unknown-no-resend','transport-unknown','operation-failed')][string]$Code,
        [ValidateRange(0,599)][int]$HttpStatus = 0
    )
    $message = "R2 publisher stopped: phase=$Phase code=$Code"
    if ($HttpStatus -ge 100) { $message += " httpStatus=$HttpStatus" }
    $failure = [InvalidOperationException]::new($message)
    $failure.Data['PrunletR2SafeFailure'] = $true
    throw $failure
}

function Get-PrunletR2SafeFailure([Exception]$Failure) {
    # 生の例外・responseは通さず、このモジュールが生成した固定語彙だけを継承する。
    for ($depth = 0; $null -ne $Failure -and $depth -lt 8; $depth++) {
        if ($Failure.Data['PrunletR2SafeFailure'] -eq $true -and $Failure.Message -cmatch '^R2 publisher stopped: phase=(identity|package-verification|package-pin|credentials|s3-head|s3-put|s3-existing|public-get) code=(invalid-input|verification-failed|pin-failed|changed|unavailable-before-http|request-failed|http-rejected|body-mismatch|unknown-no-resend|transport-unknown|operation-failed)( httpStatus=[1-5][0-9]{2})?$') {
            # inner exceptionを引き継がない。
            $safe = [InvalidOperationException]::new($Failure.Message)
            $safe.Data['PrunletR2SafeFailure'] = $true
            return $safe
        }
        $Failure = $Failure.InnerException
    }
    return $null
}

function Get-PrunletR2Hash([IO.Stream]$Stream) {
    $Stream.Position = 0
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Stream)).ToLowerInvariant() }
    finally { $Stream.Position = 0 }
}

function Get-PrunletR2Hmac([byte[]]$Key, [string]$Text) {
    $hmac = [Security.Cryptography.HMACSHA256]::new($Key)
    try { return ,$hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) }
    finally { $hmac.Dispose() }
}

function Get-PrunletR2Authorization {
    param([string]$Method, [uri]$Uri, [Collections.IDictionary]$Headers, [string]$PayloadHash,
        [string]$Timestamp, [string]$AccessKey, [string]$SecretKey,
        [string]$Region = 'auto', [string]$Service = 's3')
    # 製品keyはASCIIの固定構文のみ。S3のpath正規化やquery変形は行わない。
    if ($Uri.Query -or $Timestamp -cnotmatch '^\d{8}T\d{6}Z$') { throw 'Invalid signing input.' }
    [string[]]$names = @($Headers.Keys | ForEach-Object { $_.ToLowerInvariant() })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $canonicalHeaders = ($names | ForEach-Object { $_ + ':' + ([regex]::Replace([string]$Headers[$_], '\s+', ' ').Trim()) + "`n" }) -join ''
    $signedHeaders = $names -join ';'
    $canonical = $Method + "`n" + $Uri.AbsolutePath + "`n`n" + $canonicalHeaders + "`n" + $signedHeaders + "`n" + $PayloadHash
    $canonicalHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
    $date = $Timestamp.Substring(0, 8)
    $scope = "$date/$Region/$Service/aws4_request"
    $toSign = "AWS4-HMAC-SHA256`n$Timestamp`n$scope`n$canonicalHash"
    $dateKey = Get-PrunletR2Hmac ([Text.Encoding]::UTF8.GetBytes('AWS4' + $SecretKey)) $date
    $regionKey = Get-PrunletR2Hmac $dateKey $Region
    $serviceKey = Get-PrunletR2Hmac $regionKey $Service
    $signingKey = Get-PrunletR2Hmac $serviceKey 'aws4_request'
    try { $signature = [Convert]::ToHexString((Get-PrunletR2Hmac $signingKey $toSign)).ToLowerInvariant() }
    finally { foreach ($key in @($dateKey, $regionKey, $serviceKey, $signingKey)) { [Array]::Clear($key) } }
    return "AWS4-HMAC-SHA256 Credential=$AccessKey/$scope, SignedHeaders=$signedHeaders, Signature=$signature"
}

function New-PrunletR2Client {
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.AutomaticDecompression = [Net.DecompressionMethods]::None
    $handler.UseCookies = $false
    $client = [Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    return $client
}

function New-PrunletR2Request {
    param([string]$Method, [uri]$Uri, [string]$PayloadHash, [string]$AccessKey, [string]$SecretKey, [switch]$CreateOnly)
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture)
    $headers = @{host = $Uri.Host; 'x-amz-content-sha256' = $PayloadHash; 'x-amz-date' = $timestamp}
    if ($CreateOnly) { $headers['if-none-match'] = '*' }
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Uri)
    try {
        foreach ($name in $headers.Keys) { [void]$request.Headers.TryAddWithoutValidation($name, $headers[$name]) }
        $auth = Get-PrunletR2Authorization $Method $Uri $headers $PayloadHash $timestamp $AccessKey $SecretKey
        [void]$request.Headers.TryAddWithoutValidation('Authorization', $auth)
        return $request
    } catch { $request.Dispose(); throw 'Cannot construct R2 request.' }
}

function Send-PrunletR2Request([Net.Http.HttpClient]$Client, [Net.Http.HttpRequestMessage]$Request, [string]$Phase) {
    try { return $Client.SendAsync($Request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult() }
    catch { if ($Phase -ceq 's3-put') { Stop-PrunletR2 $Phase 'unknown-no-resend' }; Stop-PrunletR2 $Phase 'transport-unknown' }
}

function Assert-PrunletR2Body {
    param([Net.Http.HttpResponseMessage]$Response, [long]$ExpectedBytes, [string]$ExpectedHash, [string]$Phase)
    $status = [int]$Response.StatusCode
    if ($status -ne 200) { Stop-PrunletR2 $Phase 'http-rejected' $status }
    if ($null -ne $Response.Content.Headers.ContentLength -and $Response.Content.Headers.ContentLength -ne $ExpectedBytes) { Stop-PrunletR2 $Phase 'body-mismatch' $status }
    if (@($Response.Content.Headers.ContentEncoding).Count -ne 0) { Stop-PrunletR2 $Phase 'body-mismatch' $status }
    $stream = $null; $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $deadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(10))
    try {
        $stream = $Response.Content.ReadAsStreamAsync($deadline.Token).GetAwaiter().GetResult()
        $buffer = [byte[]]::new(65536); [long]$total = 0
        while (($count = $stream.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token).GetAwaiter().GetResult()) -ne 0) {
            if ($count -gt $ExpectedBytes - $total) { throw 'Object exceeds expected length.' }
            $hash.AppendData($buffer, 0, $count); $total += $count
        }
        if ($total -ne $ExpectedBytes -or [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant() -cne $ExpectedHash) { throw 'Object bytes or SHA-256 differ.' }
    } catch { Stop-PrunletR2 $Phase 'body-mismatch' $status }
    finally { if ($null -ne $stream) { $stream.Dispose() }; $hash.Dispose(); $deadline.Dispose() }
}

function Invoke-PrunletR2Distribution {
    param([IO.FileStream]$Package, [string]$ExpectedHash, [string]$Repository, [string]$CommitSha,
        [string]$Runtime, [string]$AccountId, [string]$Bucket, [Net.Http.HttpClient]$Client)
    if ($Repository -ine '1llum1n4t1s/Prunlet' -or $CommitSha -notmatch '^[0-9a-fA-F]{40}$' -or
        $Runtime -cnotin @('win-x64', 'win-arm64') -or $AccountId -cnotmatch '^[0-9a-f]{32}$' -or
        $Bucket -cnotmatch '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' -or $ExpectedHash -cnotmatch '^[0-9a-f]{64}$') { Stop-PrunletR2 'identity' 'invalid-input' }
    if (!$Package.CanRead -or !$Package.CanSeek -or $Package.Length -le 0 -or (Get-PrunletR2Hash $Package) -cne $ExpectedHash) { Stop-PrunletR2 'package-pin' 'changed' }
    $accessKey = [Environment]::GetEnvironmentVariable('PRUNLET_R2_ACCESS_KEY_ID')
    $secretKey = [Environment]::GetEnvironmentVariable('PRUNLET_R2_SECRET_ACCESS_KEY')
    if ([string]::IsNullOrWhiteSpace($accessKey) -or [string]::IsNullOrWhiteSpace($secretKey) -or $accessKey -cnotmatch '^[A-Za-z0-9]+$' -or $secretKey -match '[\r\n]') { Stop-PrunletR2 'credentials' 'unavailable-before-http' }
    $commit = $CommitSha.ToLowerInvariant(); $repo = $Repository.ToLowerInvariant()
    $key = "releases/$repo/$commit/$Runtime/$ExpectedHash.zip"
    $objectUri = [uri]"https://$AccountId.r2.cloudflarestorage.com/$Bucket/$key"
    $publicUri = [uri]"https://prunlet.kagayoi.com/$key"
    $emptyHash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    $put = $null; $response = $null; $request = $null
    [long]$bytes = $Package.Length; $reused = $false
    $phase = 's3-head'
    try {
        $request = New-PrunletR2Request 'HEAD' $objectUri $emptyHash $accessKey $secretKey
        $response = Send-PrunletR2Request $Client $request $phase
        $status = [int]$response.StatusCode
        $response.Dispose(); $response = $null; $request.Dispose(); $request = $null
        if ($status -eq 404) {
            $phase = 's3-put'
            $put = New-PrunletR2Request 'PUT' $objectUri $ExpectedHash $accessKey $secretKey -CreateOnly
            $Package.Position = 0
            $put.Content = [Net.Http.StreamContent]::new($Package, 65536)
            $put.Content.Headers.ContentLength = $bytes
            $put.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/zip')
            $response = Send-PrunletR2Request $Client $put $phase
            $status = [int]$response.StatusCode
            $response.Dispose(); $response = $null
            if ($status -eq 412) { $reused = $true }
            elseif ($status -ge 400 -and $status -lt 500) { Stop-PrunletR2 $phase 'http-rejected' $status }
            elseif ($status -ne 200) { Stop-PrunletR2 $phase 'unknown-no-resend' $status }
        } elseif ($status -eq 200) { $reused = $true }
        else { Stop-PrunletR2 $phase 'http-rejected' $status }
        # ETag/checksumではなく既存objectそのものを検証する。競合412も同じ経路。
        $phase = 's3-existing'
        $request = New-PrunletR2Request 'GET' $objectUri $emptyHash $accessKey $secretKey
        $response = Send-PrunletR2Request $Client $request $phase
        Assert-PrunletR2Body $response $bytes $ExpectedHash $phase
        $response.Dispose(); $response = $null; $request.Dispose(); $request = $null
        $phase = 'public-get'
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $publicUri)
        $response = Send-PrunletR2Request $Client $request $phase
        Assert-PrunletR2Body $response $bytes $ExpectedHash $phase
        if ($Package.Length -ne $bytes -or (Get-PrunletR2Hash $Package) -cne $ExpectedHash) { Stop-PrunletR2 'package-pin' 'changed' }
        return [ordered]@{schema = 1; repository = $Repository; commitSha = $commit; runtime = $Runtime; objectKey = $key; publicUrl = $publicUri.AbsoluteUri; sha256 = $ExpectedHash; bytes = $bytes; reused = $reused; verified = $true}
    } catch { $safe = Get-PrunletR2SafeFailure $_.Exception; if ($null -ne $safe) { throw $safe }; Stop-PrunletR2 $phase 'operation-failed' }
    finally {
        if ($null -ne $response) { $response.Dispose() }; if ($null -ne $request) { $request.Dispose() }; if ($null -ne $put) { $put.Dispose() }
        $accessKey = $null; $secretKey = $null
    }
}
