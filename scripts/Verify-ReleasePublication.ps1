#requires -Version 7.2
# 配信側（署名付きマニフェスト・R2 への公開順序・鍵整合の関門・Velopack 配信）のオフライン検証。
# 実 R2・実署名・実ネットワークには一切接続しない。偽の HttpClient handler（release-test-fixtures/FakeR2Handler.cs）と、
# scripts/release-test-fixtures/ のテスト用の鍵ペア（keyId prunlet-release-test-1。本番の鍵ではない）だけを使う。
# 確認すること:
#   - 封筒・署名: .NET ECDsa と openssl dgst -sha256 -verify の両方で検証できる DER 署名 / 改ざん・形式違反・別鍵・本番の信頼での拒否
#   - 公開順序: 配布物 → 公開 URL 照合 → 版マニフェスト → 最新ポインタ → 固定名、create-only / ETag 条件付き置換
#   - 後退拒否・同版の照合・payload 不一致・既存マニフェストの署名不正・鍵の取り違えが、R2 への書込み 0 件で失敗すること
#   - 初回配信（latest/・manifests/・フィードがすべて 404）が事前検査・配信とも成功し、404 以外の読取り失敗は「まだ無い」と
#     取り違えずに書込み 0 件で止まること
#   - 鍵整合の関門: 必須の 3 か所（Rust・Install-Prunlet.ps1・Install-Prunlet.sh）すべて一致で成功、不在・不一致・重複で失敗。
#     launcher は定数を持たなくても成功、持つ場合は一致が必要。実リポジトリの定数が本番鍵と一致すること
#   - Linux・mac の配布物の中身の検査、Velopack の配信順序・後退防止、publish-r2.ps1 -DryRun
# 使い方: pwsh -NoProfile -File scripts/Verify-ReleasePublication.ps1 -OutputDirectory <未使用の外部絶対パス>
# 失敗が 1 件でもあれば終了コード 1。skip は件数を別に表示し、成功には数えない。
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (![IO.Path]::IsPathFullyQualified($OutputDirectory)) { throw 'OutputDirectory must be absolute.' }
if (Test-Path -LiteralPath $OutputDirectory) { if (Get-ChildItem -LiteralPath $OutputDirectory -Force | Select-Object -First 1) { throw 'OutputDirectory must be empty.' } } else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }

$fixtures = Join-Path $PSScriptRoot 'release-test-fixtures'
. (Join-Path $PSScriptRoot 'R2Distribution.Common.ps1')
. (Join-Path $PSScriptRoot 'PrunletPackage.Common.ps1')
. (Join-Path $PSScriptRoot 'PrunletReleaseGate.Common.ps1')
. (Join-Path $PSScriptRoot 'velopack/PublishFeed.Common.ps1')
Add-Type -Path (Join-Path $fixtures 'FakeR2Handler.cs') -ErrorAction Stop

$productionTrust = Get-PrunletReleaseTrust
$testPublicKey = ([IO.File]::ReadAllText((Join-Path $fixtures 'test-public-spki.b64'))).Trim()
$testPrivateKey = [IO.File]::ReadAllText((Join-Path $fixtures 'test-signing-private.pem'))
$testTrust = [pscustomobject]@{ KeyId = 'prunlet-release-test-1'; PublicKey = $testPublicKey }
# 以後の既定の信頼をテスト鍵へ差し替える（本番の鍵・本番の経路はこの検証で使わない。本番の信頼は $productionTrust に退避済み）。
function Get-PrunletReleaseTrust { return $script:testTrust }

$script:passed = 0; $script:failed = 0; $script:skipped = 0
function Invoke-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name :: $($_.Exception.Message)" }
}
function Assert-True($Condition, [string]$Message) { if (!$Condition) { throw "assertion failed: $Message" } }
function Assert-Throws([scriptblock]$Body, [string]$Pattern, [string]$Message) {
    $thrown = $null
    try { & $Body } catch { $thrown = $_.Exception }
    if ($null -eq $thrown) { throw "expected a failure matching '$Pattern' but it succeeded ($Message)" }
    $chain = @(); for ($e = $thrown; $null -ne $e; $e = $e.InnerException) { $chain += $e.Message }
    if (($chain -join ' | ') -cnotmatch $Pattern) { throw "failure did not match '$Pattern' ($Message): $($chain -join ' | ')" }
}

$env:CLOUDFLARE_API_TOKEN = 'test-token-not-real'
$env:PRUNLET_R2_ACCOUNT_ID = '0123456789abcdef0123456789abcdef'
Remove-Item Env:PRUNLET_R2_ACCESS_KEY_ID, Env:PRUNLET_R2_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
$accountId = '0123456789abcdef0123456789abcdef'
$commit = ('a' * 40)

function New-TestWorld {
    $handler = [Prunlet.Tests.FakeR2Handler]::new()
    $block = { [Net.Http.HttpClient]::new($handler, $false) }.GetNewClosure()
    $factory = [Func[Net.Http.HttpClient]]$block
    $session = New-PrunletR2Session -AccountId $accountId -Bucket 'prunlet-updates' -ClientFactory $factory
    return [pscustomobject]@{ Handler = $handler; Session = $session }
}
function New-TestArtifact([string]$Name, [int]$Size = 4096) {
    $dir = Join-Path $OutputDirectory ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
    $path = Join-Path $dir $Name
    $bytes = [byte[]]::new($Size); [Random]::new().NextBytes($bytes)
    [IO.File]::WriteAllBytes($path, $bytes)
    return $path
}
function New-TestSpec([string]$Runtime, [string]$Version, [string]$Path, [string]$Commit = $commit) {
    $facts = Get-PrunletReleaseFileFacts $Path
    return New-PrunletReleaseSpec -Runtime $Runtime -Version $Version -CommitSha $Commit -DefaultBranch 'main' -Sha256 $facts.Sha256 -Bytes $facts.Bytes
}
function Seed-Pointer($World, $Spec) {
    $envelope = New-PrunletReleaseEnvelopeBytes -PayloadBytes (New-PrunletReleasePayloadBytes -Spec $Spec) -PrivateKeyPem $testPrivateKey -KeyId $testTrust.KeyId
    $World.Handler.Seed($Spec.PointerKey, $envelope)
    return $envelope
}
function Remove-World($World) { Close-PrunletR2Session $World.Session }
function ConvertFrom-TestBase64Pem([string]$Spki) {
    return "-----BEGIN PUBLIC KEY-----`n" + ($Spki -replace '.{64}', "`$&`n").TrimEnd() + "`n-----END PUBLIC KEY-----`n"
}

# ------------------------------------------------------------------ 署名と封筒 ------------------------------------------------------------------
Invoke-Case 'envelope: test key signs, .NET verifies, schema keys and size' {
    $spec = New-PrunletReleaseSpec -Runtime 'win-x64' -Version '1.2.3' -CommitSha $commit -DefaultBranch 'main' -Sha256 ('b' * 64) -Bytes 12345
    $payload = New-PrunletReleasePayloadBytes -Spec $spec
    $text = [Text.Encoding]::UTF8.GetString($payload)
    Assert-True ($text -ceq '{"schema":1,"product":"Prunlet","repository":"1llum1n4t1s/Prunlet","runtime":"win-x64","version":"1.2.3","commit":"' + $commit + '","defaultBranch":"main","asset":{"name":"prunlet-update-win-x64.zip","key":"releases/1llum1n4t1s/prunlet/' + $commit + '/win-x64/' + ('b' * 64) + '.zip","bytes":12345,"sha256":"' + ('b' * 64) + '"}}') 'payload is compact, ordered and deterministic'
    $envelope = New-PrunletReleaseEnvelopeBytes -PayloadBytes $payload -PrivateKeyPem $testPrivateKey -KeyId $testTrust.KeyId
    Assert-True ($envelope.Length -le 16384) 'envelope size'
    $parsed = [Text.Encoding]::UTF8.GetString($envelope) | ConvertFrom-Json
    Assert-True ((@($parsed.PSObject.Properties.Name) -join ',') -ceq 'schema,keyId,payload,signature') 'envelope keys and order'
    $read = Read-PrunletReleaseEnvelope -Bytes $envelope -Trust $testTrust
    Assert-True (Test-PrunletReleaseBytesEqual $read.PayloadBytes $payload) 'payload bytes round trip'
}
Invoke-Case 'envelope: the committed sample verifies with the test trust (client conformance vector)' {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $fixtures 'sample-envelope.json'))
    $read = Read-PrunletReleaseEnvelope -Bytes $bytes -Trust $testTrust
    $spec = New-PrunletReleaseSpec -Runtime 'win-x64' -Version '1.2.3' -CommitSha $commit -DefaultBranch 'main' -Sha256 ('b' * 64) -Bytes 12345
    Assert-True (Test-PrunletReleaseBytesEqual $read.PayloadBytes (New-PrunletReleasePayloadBytes -Spec $spec)) 'sample payload equals the deterministic payload'
}
Invoke-Case 'envelope: the test-key envelope is rejected by the production trust' {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $fixtures 'sample-envelope.json'))
    Assert-Throws { Read-PrunletReleaseEnvelope -Bytes $bytes -Trust $productionTrust } 'code=unknown-key-id' 'production keyId'
    # keyId だけ本番に書き換えても、署名は本番の公開鍵で検証できない。
    $forged = [Text.Encoding]::UTF8.GetBytes(([Text.Encoding]::UTF8.GetString($bytes)).Replace('prunlet-release-test-1', $productionTrust.KeyId))
    Assert-Throws { Read-PrunletReleaseEnvelope -Bytes $forged -Trust $productionTrust } 'code=verification-failed' 'forged keyId'
}
Invoke-Case 'envelope: tampering, malformed shapes and r||s signatures are rejected' {
    $spec = New-PrunletReleaseSpec -Runtime 'linux-x64' -Version '2.0.0' -CommitSha $commit -DefaultBranch 'main' -Sha256 ('c' * 64) -Bytes 100
    $payload = New-PrunletReleasePayloadBytes -Spec $spec
    $envelope = New-PrunletReleaseEnvelopeBytes -PayloadBytes $payload -PrivateKeyPem $testPrivateKey -KeyId $testTrust.KeyId
    $json = [Text.Encoding]::UTF8.GetString($envelope)
    $obj = $json | ConvertFrom-Json
    function Reject([string]$Text, [string]$Pattern, [string]$Label) { Assert-Throws { Read-PrunletReleaseEnvelope -Bytes ([Text.Encoding]::UTF8.GetBytes($Text)) -Trust $testTrust } $Pattern $Label }
    $badPayload = $payload.Clone(); $badPayload[10] = $badPayload[10] -bxor 1
    Reject ($json.Replace($obj.payload, [Convert]::ToBase64String($badPayload))) 'code=verification-failed' 'payload tamper'
    $sigBytes = [Convert]::FromBase64String($obj.signature); $sigBytes[8] = $sigBytes[8] -bxor 1
    Reject ($json.Replace($obj.signature, [Convert]::ToBase64String($sigBytes))) 'code=verification-failed' 'signature tamper'
    Reject ($json.Replace('"schema":1', '"schema":2')) 'code=malformed' 'schema 2'
    Reject ($json.TrimEnd('}') + ',"extra":1}') 'code=malformed' 'extra key'
    Reject ($json.Replace('"signature"', '"signatures"')) 'code=malformed' 'renamed key'
    Reject ($json.TrimEnd('}') + ',"schema":1}') 'code=malformed' 'duplicate key'
    Reject ('[' + $json + ']') 'code=malformed' 'not an object'
    Reject 'not json' 'code=malformed' 'garbage'
    Reject ($json.Replace('"keyId":"prunlet-release-test-1"', '"keyId":"other"')) 'code=unknown-key-id' 'other keyId'
    # r||s（既定の IEEE P1363 形式）の署名は、DER を要求する検査で拒否される。
    $ecdsa = [Security.Cryptography.ECDsa]::Create(); $ecdsa.ImportFromPem($testPrivateKey)
    $raw = $ecdsa.SignData($payload, [Security.Cryptography.HashAlgorithmName]::SHA256)
    $ecdsa.Dispose()
    Assert-True ($raw.Length -eq 64) 'r||s is 64 bytes'
    Reject ($json.Replace($obj.signature, [Convert]::ToBase64String($raw))) 'code=verification-failed' 'r||s signature'
    Assert-Throws { Read-PrunletReleaseEnvelope -Bytes ([byte[]]::new(16385)) -Trust $testTrust } 'code=invalid-size' 'oversize'
    # 別の鍵で署名した封筒（keyId は同じ）。
    $other = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP256'))
    $otherEnvelope = New-PrunletReleaseEnvelopeBytes -PayloadBytes $payload -PrivateKeyPem $other.ExportPkcs8PrivateKeyPem() -KeyId $testTrust.KeyId
    $other.Dispose()
    Assert-Throws { Read-PrunletReleaseEnvelope -Bytes $otherEnvelope -Trust $testTrust } 'code=verification-failed' 'other key'
}
Invoke-Case 'envelope: openssl dgst -sha256 -verify accepts the DER signature and rejects a tampered payload' {
    $openssl = Get-Command openssl -ErrorAction SilentlyContinue
    if ($null -eq $openssl) { $script:skipped++; Write-Host 'SKIP openssl is not installed'; return }
    $spec = New-PrunletReleaseSpec -Runtime 'osx-arm64' -Version '1.0.1' -CommitSha $commit -DefaultBranch 'main' -Sha256 ('d' * 64) -Bytes 99
    $payload = New-PrunletReleasePayloadBytes -Spec $spec
    $envelope = New-PrunletReleaseEnvelopeBytes -PayloadBytes $payload -PrivateKeyPem $testPrivateKey -KeyId $testTrust.KeyId
    $obj = [Text.Encoding]::UTF8.GetString($envelope) | ConvertFrom-Json
    $work = Join-Path $OutputDirectory 'openssl'; New-Item -ItemType Directory -Path $work | Out-Null
    [IO.File]::WriteAllBytes("$work\payload.bin", [Convert]::FromBase64String($obj.payload))
    [IO.File]::WriteAllBytes("$work\signature.der", [Convert]::FromBase64String($obj.signature))
    [IO.File]::WriteAllText("$work\public.pem", (ConvertFrom-TestBase64Pem $testPublicKey))
    $out = & $openssl.Source dgst -sha256 -verify "$work\public.pem" -signature "$work\signature.der" "$work\payload.bin" 2>&1
    Assert-True ($LASTEXITCODE -eq 0 -and ($out -join '') -match 'Verified OK') "openssl verifies the DER signature ($out)"
    $tampered = [Convert]::FromBase64String($obj.payload); $tampered[0] = $tampered[0] -bxor 1
    [IO.File]::WriteAllBytes("$work\tampered.bin", $tampered)
    $null = & $openssl.Source dgst -sha256 -verify "$work\public.pem" -signature "$work\signature.der" "$work\tampered.bin" 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'openssl rejects the tampered payload'
    # sample-envelope.json（クライアント適合確認用のサンプル）も openssl で検証できる。
    $sample = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $fixtures 'sample-envelope.json'))) | ConvertFrom-Json
    [IO.File]::WriteAllBytes("$work\sample-payload.bin", [Convert]::FromBase64String($sample.payload))
    [IO.File]::WriteAllBytes("$work\sample-signature.der", [Convert]::FromBase64String($sample.signature))
    $null = & $openssl.Source dgst -sha256 -verify "$work\public.pem" -signature "$work\sample-signature.der" "$work\sample-payload.bin" 2>&1
    Assert-True ($LASTEXITCODE -eq 0) 'openssl verifies the committed sample'
}
Invoke-Case 'spec: runtime keys, names and input validation' {
    $s = New-PrunletReleaseSpec -Runtime 'linux-arm64' -Version '1.2.3' -CommitSha $commit -DefaultBranch 'main' -Sha256 ('e' * 64) -Bytes 10
    Assert-True ($s.AssetName -ceq 'prunlet-linux-arm64.tar.gz' -and $s.AssetKey -ceq "releases/1llum1n4t1s/prunlet/$commit/linux-arm64/$('e' * 64).tar.gz") 'linux key'
    Assert-True ($s.ManifestKey -ceq 'manifests/1.2.3/linux-arm64.json' -and $s.PointerKey -ceq 'latest/linux-arm64.json') 'linux manifest and pointer keys'
    $v = New-PrunletReleaseSpec -Runtime 'velopack-win-x64' -Version '1.2.3' -CommitSha $commit -DefaultBranch 'main' -Sha256 ('e' * 64) -Bytes 10
    Assert-True ($v.AssetName -ceq 'PrunletApp-1.2.3-full.nupkg' -and $v.AssetKey -ceq 'velopack/PrunletApp-1.2.3-full.nupkg' -and $null -eq $v.PointerKey) 'velopack key'
    Assert-Throws { New-PrunletReleaseSpec -Runtime 'win-x64' -Version '1.2' -CommitSha $commit -DefaultBranch 'main' -Sha256 ('e' * 64) -Bytes 10 } 'invalid-version' 'version'
    Assert-Throws { New-PrunletReleaseSpec -Runtime 'win-x64' -Version '1.2.3' -CommitSha ('A' * 40) -DefaultBranch 'main' -Sha256 ('e' * 64) -Bytes 10 } 'invalid-commit' 'commit case'
    Assert-Throws { New-PrunletReleaseSpec -Runtime 'osx-x64' -Version '1.2.3' -CommitSha $commit -DefaultBranch 'main' -Sha256 ('e' * 64) -Bytes 10 } 'invalid-runtime' 'runtime'
    Assert-Throws { New-PrunletReleaseSpec -Runtime 'linux-x64' -Version '1.2.3' -CommitSha $commit -DefaultBranch 'main' -Sha256 ('e' * 64) -Bytes (65MB) } 'invalid-length' 'limit'
}

# ------------------------------------------------------------------ 公開順序 ------------------------------------------------------------------
Invoke-Case 'publish win-x64: order, create-only, pointer create-only, public check' {
    $w = New-TestWorld
    try {
        $zip = New-TestArtifact 'package.zip'; $spec = New-TestSpec 'win-x64' '1.2.3' $zip
        $plan = Get-PrunletRuntimePlan -Session $w.Session -Spec $spec -SigningKeyPem $testPrivateKey
        Assert-True ($w.Handler.Puts().Count -eq 0) 'the plan wrote nothing'
        Assert-True ($plan.Decision -ceq 'full') 'decision full'
        $result = Invoke-PrunletRuntimePublication -Session $w.Session -Plan $plan -ArtifactPath $zip
        Assert-True ($result.PointerUpdated) 'pointer updated'
        $puts = $w.Handler.Puts()
        Assert-True (($puts -join '|') -ceq ("PUT $($spec.AssetKey) create-only|PUT manifests/1.2.3/win-x64.json create-only|PUT latest/win-x64.json create-only")) "put order and conditions: $($puts -join '|')"
        $log = @($w.Handler.Log)
        $publicIndex = [array]::IndexOf($log, "PUBLIC $($spec.AssetKey)")
        Assert-True ($publicIndex -gt $log.IndexOf("PUT $($spec.AssetKey) create-only") -and $publicIndex -lt $log.IndexOf('PUT manifests/1.2.3/win-x64.json create-only')) 'public check sits between the asset and the manifest'
        Assert-True (Test-PrunletReleaseBytesEqual $w.Handler.Objects['latest/win-x64.json'].Bytes $w.Handler.Objects['manifests/1.2.3/win-x64.json'].Bytes) 'the pointer carries the manifest envelope'
        $null = Assert-PrunletReleaseEnvelopeMatches -EnvelopeBytes $w.Handler.Objects['latest/win-x64.json'].Bytes -ExpectedPayload (New-PrunletReleasePayloadBytes -Spec $spec)
        Assert-True ($log -contains 'PURGE') 'the fixed-name pointer was purged'
        Assert-True ((@($w.Handler.Log | Where-Object { $_ -like 'PUBLIC latest/*' })).Count -eq 0) 'the pointer is never probed through the public host before it exists'
    } finally { Remove-World $w }
}
Invoke-Case 'publish: re-run with the same build is verify-only and writes nothing' {
    $w = New-TestWorld
    try {
        $zip = New-TestArtifact 'package.zip'; $spec = New-TestSpec 'win-arm64' '1.2.3' $zip
        $null = Invoke-PrunletRuntimePublication -Session $w.Session -Plan (Get-PrunletRuntimePlan -Session $w.Session -Spec $spec -SigningKeyPem $testPrivateKey) -ArtifactPath $zip
        $before = $w.Handler.Puts().Count; $pointerBefore = $w.Handler.Objects['latest/win-arm64.json'].Bytes
        # 署名は毎回変わるが、既存の封筒を使うので封筒は変わらない。
        $plan2 = Get-PrunletRuntimePlan -Session $w.Session -Spec $spec -SigningKeyPem $testPrivateKey
        Assert-True ($plan2.Decision -ceq 'verify-only' -and $plan2.ManifestExisted) 'verify-only with an existing manifest'
        $result = Invoke-PrunletRuntimePublication -Session $w.Session -Plan $plan2 -ArtifactPath $zip
        Assert-True (!$result.PointerUpdated) 'pointer not updated'
        $newPuts = @($w.Handler.Puts() | Select-Object -Skip $before)
        Assert-True ($newPuts.Count -eq 0) "the re-run wrote nothing: $($newPuts -join '|')"
        Assert-True (Test-PrunletReleaseBytesEqual $pointerBefore $w.Handler.Objects['latest/win-arm64.json'].Bytes) 'pointer bytes unchanged'
    } finally { Remove-World $w }
}
Invoke-Case 'publish: a newer published pointer is refused with zero writes' {
    $w = New-TestWorld
    try {
        $zip = New-TestArtifact 'package.zip'
        $newer = New-TestSpec 'win-x64' '1.2.4' (New-TestArtifact 'other.zip')
        $null = Seed-Pointer $w $newer
        $spec = New-TestSpec 'win-x64' '1.2.3' $zip
        Assert-Throws { Get-PrunletRuntimePlan -Session $w.Session -Spec $spec -SigningKeyPem $testPrivateKey } 'code=newer-published' 'rollback'
        Assert-True ($w.Handler.Puts().Count -eq 0) 'no write happened'
    } finally { Remove-World $w }
}
Invoke-Case 'publish: an older pointer is replaced with If-Match, and an unreadable pointer blocks publishing' {
    $w = New-TestWorld
    try {
        $older = New-TestSpec 'win-x64' '1.2.2' (New-TestArtifact 'old.zip'); $null = Seed-Pointer $w $older
        $zip = New-TestArtifact 'package.zip'; $spec = New-TestSpec 'win-x64' '1.2.3' $zip
        $null = Invoke-PrunletRuntimePublication -Session $w.Session -Plan (Get-PrunletRuntimePlan -Session $w.Session -Spec $spec -SigningKeyPem $testPrivateKey) -ArtifactPath $zip
        Assert-True ($w.Handler.Puts() -contains 'PUT latest/win-x64.json if-match') 'conditional replace'
        $read = Read-PrunletReleaseEnvelope -Bytes $w.Handler.Objects['latest/win-x64.json'].Bytes -Trust $testTrust
        Assert-True ((Read-PrunletReleasePayloadInfo -PayloadBytes $read.PayloadBytes).VersionText -ceq '1.2.3') 'new version is the pointer'
        $w.Handler.Seed('latest/win-x64.json', [Text.Encoding]::UTF8.GetBytes('{"broken":true}'))
        $before = $w.Handler.Puts().Count
        Assert-Throws { Get-PrunletRuntimePlan -Session $w.Session -Spec (New-TestSpec 'win-x64' '1.2.9' $zip) -SigningKeyPem $testPrivateKey } 'phase=envelope' 'unreadable pointer'
        Assert-True ($w.Handler.Puts().Count -eq $before) 'no write after the unreadable pointer'
    } finally { Remove-World $w }
}
Invoke-Case 'publish: same version with different content fails before any write' {
    $w = New-TestWorld
    try {
        $first = New-TestArtifact 'a.zip'; $firstSpec = New-TestSpec 'win-x64' '1.2.3' $first
        $null = Invoke-PrunletRuntimePublication -Session $w.Session -Plan (Get-PrunletRuntimePlan -Session $w.Session -Spec $firstSpec -SigningKeyPem $testPrivateKey) -ArtifactPath $first
        $before = $w.Handler.Puts().Count
        $rebuilt = New-TestArtifact 'b.zip'; $rebuiltSpec = New-TestSpec 'win-x64' '1.2.3' $rebuilt
        Assert-Throws { Get-PrunletRuntimePlan -Session $w.Session -Spec $rebuiltSpec -SigningKeyPem $testPrivateKey } 'code=mismatch' 'rebuilt same version'
        Assert-True ($w.Handler.Puts().Count -eq $before) 'no write for the rebuilt artifact'
        # 版マニフェストだけが残っている（ポインタ未更新）状態でも、別内容の同版は失敗する。
        $w2 = New-TestWorld
        try {
            $envelope = New-PrunletReleaseEnvelopeBytes -PayloadBytes (New-PrunletReleasePayloadBytes -Spec $firstSpec) -PrivateKeyPem $testPrivateKey -KeyId $testTrust.KeyId
            $w2.Handler.Seed('manifests/1.2.3/win-x64.json', $envelope)
            Assert-Throws { Get-PrunletRuntimePlan -Session $w2.Session -Spec $rebuiltSpec -SigningKeyPem $testPrivateKey } 'code=mismatch' 'manifest-only state'
            Assert-True ($w2.Handler.Puts().Count -eq 0) 'no write in the manifest-only state'
        } finally { Remove-World $w2 }
    } finally { Remove-World $w }
}
Invoke-Case 'publish: an existing manifest with a bad signature, and a signing key that is not the trusted key, fail with zero writes' {
    $w = New-TestWorld
    try {
        $zip = New-TestArtifact 'package.zip'; $spec = New-TestSpec 'win-x64' '1.2.3' $zip
        $other = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP256'))
        $otherPem = $other.ExportPkcs8PrivateKeyPem(); $other.Dispose()
        $forged = New-PrunletReleaseEnvelopeBytes -PayloadBytes (New-PrunletReleasePayloadBytes -Spec $spec) -PrivateKeyPem $otherPem -KeyId $testTrust.KeyId
        $w.Handler.Seed($spec.ManifestKey, $forged)
        Assert-Throws { Get-PrunletRuntimePlan -Session $w.Session -Spec $spec -SigningKeyPem $testPrivateKey } 'code=verification-failed' 'forged existing manifest'
        Assert-True ($w.Handler.Puts().Count -eq 0) 'no write (forged manifest)'
        $w2 = New-TestWorld
        try {
            # 鍵の取り違え: 署名鍵が信頼する公開鍵と対応しない。署名はできても信頼の検証で書込み前に止まる。
            Assert-Throws { Get-PrunletRuntimePlan -Session $w2.Session -Spec $spec -SigningKeyPem $otherPem } 'code=verification-failed' 'wrong signing key'
            Assert-Throws { Get-PrunletRuntimePlan -Session $w2.Session -Spec $spec -SigningKeyPem '' } 'code=missing-signing-key' 'no signing key'
            Assert-True ($w2.Handler.Puts().Count -eq 0) 'no write (wrong key)'
            # 事前検査だけ（-NoSign）は署名鍵なしで通り、何も書かない。
            $check = Get-PrunletRuntimePlan -Session $w2.Session -Spec $spec -NoSign
            Assert-True ($null -eq $check.Envelope -and $w2.Handler.Puts().Count -eq 0) 'check-only needs no key'
        } finally { Remove-World $w2 }
    } finally { Remove-World $w }
}
Invoke-Case 'publish: a pointer change between the plan and the write is detected and does not overwrite' {
    $w = New-TestWorld
    try {
        $null = Seed-Pointer $w (New-TestSpec 'win-x64' '1.2.0' (New-TestArtifact 'old.zip'))
        $zip = New-TestArtifact 'package.zip'; $spec = New-TestSpec 'win-x64' '1.2.3' $zip
        $plan = Get-PrunletRuntimePlan -Session $w.Session -Spec $spec -SigningKeyPem $testPrivateKey
        $racer = Seed-Pointer $w (New-TestSpec 'win-x64' '1.2.1' (New-TestArtifact 'racer.zip'))
        Assert-Throws { Invoke-PrunletRuntimePublication -Session $w.Session -Plan $plan -ArtifactPath $zip } 'code=concurrent-change' 'concurrent pointer'
        Assert-True (Test-PrunletReleaseBytesEqual $racer $w.Handler.Objects['latest/win-x64.json'].Bytes) 'the other pointer survived'
    } finally { Remove-World $w }
}
Invoke-Case 'publish: a mismatching public URL stops before the manifest and the pointer' {
    $w = New-TestWorld
    try {
        $zip = New-TestArtifact 'package.zip'; $spec = New-TestSpec 'win-x64' '1.2.3' $zip
        $w.Handler.PublicOverrides[$spec.AssetKey] = [byte[]]::new(4096)
        Assert-Throws { Invoke-PrunletRuntimePublication -Session $w.Session -Plan (Get-PrunletRuntimePlan -Session $w.Session -Spec $spec -SigningKeyPem $testPrivateKey) -ArtifactPath $zip } 'phase=public-get code=body-mismatch' 'public mismatch'
        Assert-True (($w.Handler.Puts() -join '|') -ceq "PUT $($spec.AssetKey) create-only") 'only the immutable asset was written'
    } finally { Remove-World $w }
}
Invoke-Case 'publish: an existing immutable asset with other content is not overwritten' {
    $w = New-TestWorld
    try {
        $zip = New-TestArtifact 'package.zip'; $spec = New-TestSpec 'win-x64' '1.2.3' $zip
        $w.Handler.Seed($spec.AssetKey, [byte[]]::new($spec.Bytes))
        Assert-Throws { Invoke-PrunletRuntimePublication -Session $w.Session -Plan (Get-PrunletRuntimePlan -Session $w.Session -Spec $spec -SigningKeyPem $testPrivateKey) -ArtifactPath $zip } 'body-mismatch' 'existing asset'
        Assert-True ($w.Handler.Puts().Count -eq 0) 'nothing was written'
    } finally { Remove-World $w }
}
Invoke-Case 'publish: an unknown-result manifest write stops before the pointer (no resend)' {
    $w = New-TestWorld
    try {
        $zip = New-TestArtifact 'package.zip'; $spec = New-TestSpec 'win-x64' '1.2.3' $zip
        $w.Handler.FailPutContaining = 'manifests/'; $w.Handler.FailPutStatus = 500
        Assert-Throws { Invoke-PrunletRuntimePublication -Session $w.Session -Plan (Get-PrunletRuntimePlan -Session $w.Session -Spec $spec -SigningKeyPem $testPrivateKey) -ArtifactPath $zip } 'code=unknown-no-resend' 'manifest 500'
        Assert-True (@($w.Handler.Puts() | Where-Object { $_ -like 'PUT latest/*' }).Count -eq 0) 'the pointer was not written'
    } finally { Remove-World $w }
}
Invoke-Case 'publish linux: pointer first, then the fixed names with the checksum last' {
    $w = New-TestWorld
    try {
        $tgz = New-TestArtifact 'prunlet-linux-x64.tar.gz'; $spec = New-TestSpec 'linux-x64' '1.2.3' $tgz
        $sidecar = "$tgz.sha256"; [IO.File]::WriteAllText($sidecar, "$($spec.Sha256)  prunlet-linux-x64.tar.gz`n")
        $fixed = @(@{ Key = 'download/latest/prunlet-linux-x64.tar.gz'; Path = $tgz; ContentType = 'application/gzip' }, @{ Key = 'download/latest/prunlet-linux-x64.tar.gz.sha256'; Path = $sidecar; ContentType = 'text/plain; charset=utf-8' })
        $null = Invoke-PrunletRuntimePublication -Session $w.Session -Plan (Get-PrunletRuntimePlan -Session $w.Session -Spec $spec -SigningKeyPem $testPrivateKey) -ArtifactPath $tgz -FixedFiles $fixed
        Assert-True (($w.Handler.Puts() -join '|') -ceq ("PUT $($spec.AssetKey) create-only|PUT manifests/1.2.3/linux-x64.json create-only|PUT latest/linux-x64.json create-only|PUT download/latest/prunlet-linux-x64.tar.gz create-only|PUT download/latest/prunlet-linux-x64.tar.gz.sha256 create-only")) "linux order: $($w.Handler.Puts() -join '|')"
        # 固定名の 2 回目は ETag 条件付きの置換になる（古い版 → 新しい版）。
        $tgz2 = New-TestArtifact 'prunlet-linux-x64.tar.gz'; $spec2 = New-TestSpec 'linux-x64' '1.2.4' $tgz2 -Commit ('f' * 40)
        $fixed2 = @(@{ Key = 'download/latest/prunlet-linux-x64.tar.gz'; Path = $tgz2; ContentType = 'application/gzip' })
        $null = Invoke-PrunletRuntimePublication -Session $w.Session -Plan (Get-PrunletRuntimePlan -Session $w.Session -Spec $spec2 -SigningKeyPem $testPrivateKey) -ArtifactPath $tgz2 -FixedFiles $fixed2
        Assert-True ($w.Handler.Puts() -contains 'PUT download/latest/prunlet-linux-x64.tar.gz if-match') 'fixed name replaced conditionally'
    } finally { Remove-World $w }
}
Invoke-Case 'publish mac: an artifact that is already in R2 is reused, and a missing one fails' {
    $w = New-TestWorld
    try {
        $zip = New-TestArtifact 'prunlet-update-osx-arm64.zip'; $spec = New-TestSpec 'osx-arm64' '1.2.3' $zip
        $plan = Get-PrunletRuntimePlan -Session $w.Session -Spec $spec -SigningKeyPem $testPrivateKey
        Assert-Throws { Invoke-PrunletRuntimePublication -Session $w.Session -Plan $plan -ReuseRemoteArtifact } 'http-rejected' 'missing artifact'
        $w.Handler.Seed($spec.AssetKey, [IO.File]::ReadAllBytes($zip))
        $null = Invoke-PrunletRuntimePublication -Session $w.Session -Plan $plan -ReuseRemoteArtifact
        Assert-True (($w.Handler.Puts() -join '|') -ceq 'PUT manifests/1.2.3/osx-arm64.json create-only|PUT latest/osx-arm64.json create-only') 'only the manifest and pointer were written'
    } finally { Remove-World $w }
}

# ------------------------------------------------------------------ 配布物の中身 ------------------------------------------------------------------
function New-TestLinuxPackage([string]$Path, [string]$Version, [string]$CommitSha, [string]$Runtime, [string[]]$Order = @('prunlet', 'manifest.json'), [switch]$BadHash) {
    $exe = [byte[]]::new(64); [Random]::new().NextBytes($exe)
    $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($exe)).ToLowerInvariant()
    if ($BadHash) { $sha = '0' * 64 }
    $manifest = [Text.Encoding]::UTF8.GetBytes('{"version":"' + $Version + '","commit":"' + $CommitSha + '","runtime":"' + $Runtime + '","bytes":64,"sha256":"' + $sha + '"}' + "`n")
    $file = [IO.File]::Create($Path); $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionLevel]::Optimal)
    $tar = [Formats.Tar.TarWriter]::new($gzip, [Formats.Tar.TarEntryFormat]::Ustar)
    try {
        foreach ($name in $Order) {
            $entry = [Formats.Tar.UstarTarEntry]::new([Formats.Tar.TarEntryType]::RegularFile, $name)
            $entry.DataStream = [IO.MemoryStream]::new($(if ($name -ceq 'prunlet') { $exe } else { $manifest }))
            $tar.WriteEntry($entry)
        }
    } finally { $tar.Dispose(); $gzip.Dispose(); $file.Dispose() }
}
Invoke-Case 'package: linux tar.gz inspection (identity, order, hash)' {
    $dir = Join-Path $OutputDirectory 'pkg-linux'; New-Item -ItemType Directory -Path $dir | Out-Null
    $good = Join-Path $dir 'good.tar.gz'; New-TestLinuxPackage $good '1.2.3' $commit 'linux-x64'
    Assert-PrunletLinuxPackage -Path $good -Runtime 'linux-x64' -Version '1.2.3' -CommitSha $commit
    Assert-Throws { Assert-PrunletLinuxPackage -Path $good -Runtime 'linux-arm64' -Version '1.2.3' -CommitSha $commit } 'identity-mismatch' 'runtime'
    Assert-Throws { Assert-PrunletLinuxPackage -Path $good -Runtime 'linux-x64' -Version '1.2.4' -CommitSha $commit } 'identity-mismatch' 'version'
    Assert-Throws { Assert-PrunletLinuxPackage -Path $good -Runtime 'linux-x64' -Version '1.2.3' -CommitSha ('b' * 40) } 'identity-mismatch' 'commit'
    $swapped = Join-Path $dir 'swapped.tar.gz'; New-TestLinuxPackage $swapped '1.2.3' $commit 'linux-x64' -Order @('manifest.json', 'prunlet')
    Assert-Throws { Assert-PrunletLinuxPackage -Path $swapped -Runtime 'linux-x64' -Version '1.2.3' -CommitSha $commit } 'invalid-archive' 'entry order'
    $bad = Join-Path $dir 'bad.tar.gz'; New-TestLinuxPackage $bad '1.2.3' $commit 'linux-x64' -BadHash
    Assert-Throws { Assert-PrunletLinuxPackage -Path $bad -Runtime 'linux-x64' -Version '1.2.3' -CommitSha $commit } 'executable-mismatch' 'hash'
}
function New-TestMacPackage([byte[]]$Exe, [string]$Version, [string]$CommitSha, [switch]$ExtraEntry) {
    $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Exe)).ToLowerInvariant()
    $manifest = [Text.Encoding]::UTF8.GetBytes('{"protocol":1,"version":"' + $Version + '","commit":"' + $CommitSha + '","runtime":"osx-arm64","bytes":' + $Exe.Length + ',"sha256":"' + $sha + '"}')
    $stream = [IO.MemoryStream]::new()
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        $items = @(@('prunlet', $Exe), @('manifest.json', $manifest)); if ($ExtraEntry) { $items += , @('extra.txt', [byte[]]@(1)) }
        foreach ($item in $items) { $e = $zip.CreateEntry($item[0]); $s = $e.Open(); $s.Write($item[1], 0, $item[1].Length); $s.Dispose() }
    } finally { $zip.Dispose() }
    return , $stream.ToArray()
}
Invoke-Case 'package: mac zip inspection' {
    $header = [byte[]]@(0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1)
    $exe = [byte[]]::new(64); [Array]::Copy($header, $exe, $header.Length)
    Assert-PrunletMacPackage -Bytes (New-TestMacPackage $exe '1.2.3' $commit) -Version '1.2.3' -CommitSha $commit
    Assert-Throws { Assert-PrunletMacPackage -Bytes (New-TestMacPackage $exe '1.2.3' $commit) -Version '1.2.4' -CommitSha $commit } 'identity-mismatch' 'version'
    Assert-Throws { Assert-PrunletMacPackage -Bytes (New-TestMacPackage $exe '1.2.3' $commit -ExtraEntry) -Version '1.2.3' -CommitSha $commit } 'invalid-archive' 'extra entry'
    $notMacho = [byte[]]::new(64)
    Assert-Throws { Assert-PrunletMacPackage -Bytes (New-TestMacPackage $notMacho '1.2.3' $commit) -Version '1.2.3' -CommitSha $commit } 'not-arm64-macho' 'magic'
}

# ------------------------------------------------------------------ 鍵整合の関門 ------------------------------------------------------------------
$gate = Join-Path $PSScriptRoot 'Test-PrunletReleaseKeyGate.ps1'
# 必須の 3 か所（rust・installer-ps1・installer-sh）は既定で試験鍵の定数を持つ。launcher は既定で定数を持たない
# （現在の形: 封筒の検証を Rust の内部コマンドへ任せる）。-Launcher に値を渡したときだけ launcher に定数を書く。
# launcher のファイル自体は常に置き、定数の無い launcher（識別子への言及だけ・リテラル無し）を再現する。
function New-GateTree([string]$Name, [string]$Rust = $testPublicKey, [string]$Launcher = '', [string]$InstallerPs1 = $testPublicKey, [string]$InstallerSh = $testPublicKey, [switch]$NoLauncherFile) {
    $root = Join-Path $OutputDirectory $Name
    foreach ($dir in @('src/rust', 'integration', 'scripts')) { New-Item -ItemType Directory -Path (Join-Path $root $dir) -Force | Out-Null }
    if ($Rust) { [IO.File]::WriteAllText("$root/src/rust/trust.rs", "pub const PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64: &str = `"$Rust`";`n// PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64 is referenced here without a literal`n") }
    $launcherText = "# PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64 is held by Rust; the launcher calls __check-release-manifest`n"
    if ($Launcher) { $launcherText += "`$PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64 = '$Launcher'`n" }
    if (!$NoLauncherFile) { [IO.File]::WriteAllText("$root/integration/start-prunlet-mcp.ps1", $launcherText) }
    if ($InstallerPs1) { [IO.File]::WriteAllText("$root/scripts/Install-Prunlet.ps1", "`$PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64 = '$InstallerPs1'`n") }
    if ($InstallerSh) { [IO.File]::WriteAllText("$root/scripts/Install-Prunlet.sh", "PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64='$InstallerSh'`n") }
    return $root
}
function Get-GateState($Report, [string]$Location) { return @($Report.locations | Where-Object location -ceq $Location)[0].state }
function Invoke-Gate([string]$Root, [string]$Pem = $testPrivateKey) {
    Invoke-PrunletReleaseKeyGate -SourceRoot $Root -Trust $testTrust -PrivateKeyPem $Pem 6>$null
}
Invoke-Case 'gate: the public entry script exposes no way to point the gate at another key or tree' {
    $command = Get-Command $gate
    $own = @($command.Parameters.Keys | Where-Object { $_ -notin [Management.Automation.PSCmdlet]::CommonParameters })
    Assert-True ($own.Count -eq 0) "the entry has no parameters of its own: $($own -join ',')"
}
Invoke-Case 'gate: passes when the three required locations hold the constant and the launcher holds none' {
    $report = (Invoke-Gate (New-GateTree 'gate-ok')) | ConvertFrom-Json
    Assert-True ($report.status -ceq 'passed') 'passed'
    foreach ($name in @('rust', 'installer-ps1', 'installer-sh')) { Assert-True ((Get-GateState $report $name) -ceq 'ok') "$name ok" }
    Assert-True ((Get-GateState $report 'launcher') -ceq 'not-present') 'launcher is reported as not-present, not as a failure'
    Assert-True (@($report.locations | Where-Object required).Count -eq 3 -and @($report.locations).Count -eq 4) 'three required locations and one optional'
    Assert-True (@($report.failures).Count -eq 0) 'no failures'
    # launcher のファイル自体が無い場合も同じ扱い（任意の場所）。
    $report = (Invoke-Gate (New-GateTree 'gate-ok-nolauncher' -NoLauncherFile)) | ConvertFrom-Json
    Assert-True ($report.status -ceq 'passed' -and (Get-GateState $report 'launcher') -ceq 'not-present') 'missing launcher file passes'
}
Invoke-Case 'gate: a launcher that does hold the constant must match the publisher key' {
    $report = (Invoke-Gate (New-GateTree 'gate-launcher-ok' -Launcher $testPublicKey)) | ConvertFrom-Json
    Assert-True ($report.status -ceq 'passed' -and @($report.locations | Where-Object state -ceq 'ok').Count -eq 4) 'a matching launcher constant is checked and accepted'
    $other = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP256'))
    $otherSpki = [Convert]::ToBase64String($other.ExportSubjectPublicKeyInfo()); $other.Dispose()
    Assert-Throws { Invoke-Gate (New-GateTree 'gate-launcher-diff' -Launcher $otherSpki) } 'launcher: differs-from-publisher' 'a stale launcher constant'
    $dup = New-GateTree 'gate-launcher-dup' -Launcher $testPublicKey
    [IO.File]::AppendAllText("$dup/integration/start-prunlet-mcp.ps1", "`$PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64 = '$testPublicKey'`n")
    Assert-Throws { Invoke-Gate $dup } 'launcher: duplicate-definition' 'a duplicated launcher constant'
}
Invoke-Case 'gate: fails for a missing constant, a different key, a duplicate definition and a mismatched signing key' {
    Assert-Throws { Invoke-Gate (New-GateTree 'gate-missing' -InstallerSh '') } 'installer-sh: not-installed' 'missing installer-sh'
    Assert-Throws { Invoke-Gate (New-GateTree 'gate-ps1-missing' -InstallerPs1 '') } 'installer-ps1: not-installed' 'missing installer-ps1'
    Assert-Throws { Invoke-Gate (New-GateTree 'gate-rust-missing' -Rust '') } 'rust: not-installed' 'missing rust'
    $other = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP256'))
    $otherSpki = [Convert]::ToBase64String($other.ExportSubjectPublicKeyInfo()); $otherPem = $other.ExportPkcs8PrivateKeyPem(); $other.Dispose()
    Assert-Throws { Invoke-Gate (New-GateTree 'gate-diff' -InstallerPs1 $otherSpki) } 'installer-ps1: differs-from-publisher' 'different constant'
    Assert-Throws { Invoke-Gate (New-GateTree 'gate-diff-sh' -InstallerSh $otherSpki) } 'installer-sh: differs-from-publisher' 'different sh constant'
    $dup = New-GateTree 'gate-dup'
    [IO.File]::WriteAllText("$dup/src/rust/second.rs", "const PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64: &str = `"$testPublicKey`";`n")
    Assert-Throws { Invoke-Gate $dup } 'rust: duplicate-definition' 'duplicate'
    Assert-Throws { Invoke-Gate (New-GateTree 'gate-key') $otherPem } 'reference: the signing key does not match' 'signing key mismatch'
    Assert-Throws { Invoke-Gate (New-GateTree 'gate-nokey') '' } 'missing-signing-key' 'no signing key'
}
Invoke-Case 'gate: the production constants of the publisher equal the pinned public key' {
    Assert-True ($productionTrust.KeyId -ceq 'prunlet-release-1') 'production keyId'
    Assert-True ($productionTrust.PublicKey -ceq 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEMIbQQg1ZUrL1G3V5sKqnQm74bz087XUrB5+wnCXOfBnP8kREgm960J5b9S/fT0rUgopgPODpO9/PINkkCFhJbA==') 'production public key'
    $ecdsa = Import-PrunletReleasePublicKey $productionTrust.PublicKey; $ecdsa.Dispose()
}
# 実リポジトリのクライアント側の定数を、本番の署名鍵なしで関門に通す。
# 関門が読むファイル（src/rust/**/*.rs・launcher・2 つの installer）を写し、その中の本番の公開鍵の文字列だけを
# 試験鍵へ置き換えてから、試験の信頼で関門を実行する。成功すれば、実ファイルの各場所に定数がちょうど 1 個あり、
# その値が本番の公開鍵と一致していたことになる（違う値なら置き換わらず differs-from-publisher で落ちる）。
Invoke-Case 'gate: the real repository passes with all three required locations holding the production key' {
    $sourceRoot = Split-Path -Parent $PSScriptRoot
    $mirror = Join-Path $OutputDirectory 'gate-real'
    $relatives = [Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'src/rust') -Recurse -File -Filter '*.rs')) { $relatives.Add([IO.Path]::GetRelativePath($sourceRoot, $file.FullName)) }
    foreach ($relative in @('integration/start-prunlet-mcp.ps1', 'scripts/Install-Prunlet.ps1', 'scripts/Install-Prunlet.sh')) { $relatives.Add($relative) }
    foreach ($relative in $relatives) {
        $source = Join-Path $sourceRoot $relative
        if (!(Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        $target = Join-Path $mirror $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        [IO.File]::WriteAllText($target, [IO.File]::ReadAllText($source).Replace($productionTrust.PublicKey, $testPublicKey))
    }
    $report = (Invoke-Gate $mirror) | ConvertFrom-Json
    Assert-True ($report.status -ceq 'passed') 'real repository gate passed'
    foreach ($name in @('rust', 'installer-ps1', 'installer-sh')) { Assert-True ((Get-GateState $report $name) -ceq 'ok') "$name holds the production key" }
    $rustFile = @($report.locations | Where-Object location -ceq 'rust')[0].file
    Write-Host "INFO real repository gate: rust=$rustFile launcher=$(Get-GateState $report 'launcher')"
}

# ------------------------------------------------------------------ Velopack ------------------------------------------------------------------
function New-VelopackDir([string]$Version, [string]$FeedVersion = $Version) {
    $dir = Join-Path $OutputDirectory ('vp-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
    $nupkg = Join-Path $dir "PrunletApp-$Version-full.nupkg"; $bytes = [byte[]]::new(2048); [Random]::new().NextBytes($bytes); [IO.File]::WriteAllBytes($nupkg, $bytes)
    foreach ($name in @("PrunletApp-win-Setup.exe", "PrunletApp-$Version-win-Setup.exe", 'RELEASES', 'assets.win.json')) { [IO.File]::WriteAllText((Join-Path $dir $name), "content $name $Version") }
    [IO.File]::WriteAllText((Join-Path $dir 'releases.win.json'), (@{ Assets = @(@{ PackageId = 'PrunletApp'; Version = $FeedVersion; Type = 'Full'; FileName = "PrunletApp-$FeedVersion-full.nupkg" }) } | ConvertTo-Json -Depth 4))
    return $dir
}
function Invoke-Velopack($World, [string]$Dir, [string]$Version) {
    $files = @(Get-ChildItem -LiteralPath $Dir -File)
    Invoke-PrunletVelopackPublication -Session $World.Session -Files $files -Nupkg (Get-Item -LiteralPath (Join-Path $Dir "PrunletApp-$Version-full.nupkg")) -LocalVersion ([semver]$Version) -Channel 'win' -PackId 'PrunletApp' -CommitSha $commit -DefaultBranch 'main' -SigningKeyPem $testPrivateKey
}
Invoke-Case 'velopack: signed manifest first, then nupkg, feed with conditions, fixed names last' {
    $w = New-TestWorld
    try {
        $vpDir = New-VelopackDir '1.2.3'
        $null = Invoke-Velopack $w $vpDir '1.2.3'
        $puts = @($w.Handler.Puts())
        Assert-True ($puts[0] -ceq 'PUT manifests/1.2.3/velopack-win-x64.json create-only') "manifest is first: $($puts -join '|')"
        Assert-True ($puts[1] -ceq 'PUT velopack/PrunletApp-1.2.3-full.nupkg create-only') 'nupkg follows the manifest'
        $feedIndex = [array]::IndexOf($puts, 'PUT velopack/releases.win.json create-only')
        Assert-True ($feedIndex -gt 1) 'feed after the immutable objects'
        Assert-True ($puts.Count -eq 7 -and $puts[-1] -like 'PUT velopack/RELEASES*') "fixed names are last: $($puts -join '|')"
        $payloadInfo = Read-PrunletReleasePayloadInfo -PayloadBytes (Read-PrunletReleaseEnvelope -Bytes $w.Handler.Objects['manifests/1.2.3/velopack-win-x64.json'].Bytes -Trust $testTrust).PayloadBytes
        Assert-True ($payloadInfo.Runtime -ceq 'velopack-win-x64') 'manifest runtime'
        # 同じ版の再実行は照合だけ（フィード・固定名は置換しない）。
        $before = $w.Handler.Puts().Count
        $null = Invoke-Velopack $w $vpDir '1.2.3'
        Assert-True ($w.Handler.Puts().Count -eq $before) 'the same-version re-run writes nothing'
    } finally { Remove-World $w }
}
Invoke-Case 'velopack: a newer current feed refuses with zero writes, and the same version does not touch fixed names' {
    $w = New-TestWorld
    try {
        $w.Handler.Seed('velopack/releases.win.json', [Text.Encoding]::UTF8.GetBytes((@{ Assets = @(@{ PackageId = 'PrunletApp'; Version = '1.3.0'; Type = 'Full' }) } | ConvertTo-Json -Depth 4)))
        Assert-Throws { Invoke-Velopack $w (New-VelopackDir '1.2.3') '1.2.3' } 'newer version' 'rollback'
        Assert-True ($w.Handler.Puts().Count -eq 0) 'no write on rollback'
    } finally { Remove-World $w }
    $w = New-TestWorld
    try {
        $dir = New-VelopackDir '1.2.3'
        $w.Handler.Seed('velopack/releases.win.json', [IO.File]::ReadAllBytes((Join-Path $dir 'releases.win.json')))
        $null = Invoke-Velopack $w $dir '1.2.3'
        $puts = @($w.Handler.Puts())
        Assert-True ((@($puts | Where-Object { $_ -like '*Setup.exe*' -and $_ -notlike '*1.2.3-win-Setup*' }).Count) -eq 0 -and !($puts -like 'PUT velopack/releases.win.json*')) "fixed names untouched: $($puts -join '|')"
    } finally { Remove-World $w }
}
Invoke-Case 'velopack: publish-r2.ps1 -DryRun passes, shows the manifest first, and refuses a newer feed' {
    $dir = New-VelopackDir '1.2.3'
    $script = Join-Path $PSScriptRoot 'velopack/publish-r2.ps1'
    $out = & pwsh -NoProfile -File $script -PackagesDirectory $dir -CommitSha $commit -DryRun
    Assert-True ($LASTEXITCODE -eq 0) 'dry-run exit code 0'
    $lines = @($out | ForEach-Object { "$_" })
    Assert-True ($lines[1] -like 'create-only*manifests/1.2.3/velopack-win-x64.json*') "manifest line first: $($lines[1])"
    Assert-True ($lines -match 'replace\s+velopack/PrunletApp-win-Setup.exe') 'fixed name listed'
    $newer = Join-Path $OutputDirectory 'newer-feed.json'
    [IO.File]::WriteAllText($newer, (@{ Assets = @(@{ PackageId = 'PrunletApp'; Version = '9.0.0'; Type = 'Full' }) } | ConvertTo-Json -Depth 4))
    $null = & pwsh -NoProfile -File $script -PackagesDirectory $dir -CommitSha $commit -DryRun -CurrentFeedPath $newer 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'dry-run refuses a newer feed'
}

# ------------------------------------------------------------------ 起動元の検査・Velopack の -ManifestOnly ------------------------------------------------------------------
Invoke-Case 'velopack: -ManifestOnly writes only the signed manifest, and the full run afterwards reuses it' {
    $w = New-TestWorld
    try {
        $dir = New-VelopackDir '1.2.3'
        $files = @(Get-ChildItem -LiteralPath $dir -File)
        $nupkg = Get-Item -LiteralPath (Join-Path $dir 'PrunletApp-1.2.3-full.nupkg')
        $null = Invoke-PrunletVelopackPublication -Session $w.Session -Files $files -Nupkg $nupkg -LocalVersion ([semver]'1.2.3') -Channel 'win' -PackId 'PrunletApp' -CommitSha $commit -DefaultBranch 'main' -SigningKeyPem $testPrivateKey -ManifestOnly
        Assert-True (($w.Handler.Puts() -join '|') -ceq 'PUT manifests/1.2.3/velopack-win-x64.json create-only') 'only the manifest was written'
        $null = Invoke-Velopack $w $dir '1.2.3'
        Assert-True (@($w.Handler.Puts() | Where-Object { $_ -like 'PUT manifests/*' }).Count -eq 1) 'the manifest was not written twice'
        Assert-True ($w.Handler.Puts().Count -eq 7) 'the manifest plus the six package objects were written'
    } finally { Remove-World $w }
}
Invoke-Case 'publish: the first publication (latest/, manifests/ and the feed all 404) passes -CheckOnly with zero writes and then publishes every runtime' {
    # 初回の配信では R2 に latest/・manifests/・Velopack のフィードが何も無い（認証付き GET が 404）。
    # 404 は「まだ無い」で、事前検査（workflow の -CheckOnly 相当 = -NoSign）も本番の配信も成功しなければならない。
    $w = New-TestWorld
    try {
        $artifacts = [ordered]@{}
        foreach ($runtime in @('win-x64', 'win-arm64', 'linux-x64', 'linux-arm64', 'osx-arm64')) {
            $name = (Get-PrunletReleaseDescriptor -Runtime $runtime -Version '1.0.0').AssetName
            $path = New-TestArtifact $name; $spec = New-TestSpec $runtime '1.0.0' $path
            $check = Get-PrunletRuntimePlan -Session $w.Session -Spec $spec -NoSign
            Assert-True ($check.Decision -ceq 'full' -and $null -eq $check.Envelope -and !$check.ManifestExisted) "check-only on an empty bucket is a full publication: $runtime"
            $artifacts[$runtime] = @{ Path = $path; Spec = $spec }
        }
        Assert-True ($w.Handler.Puts().Count -eq 0) 'the check-only pass wrote nothing'
        Assert-True (@($w.Handler.Log | Where-Object { $_ -like 'GET latest/*' }).Count -eq 5 -and @($w.Handler.Log | Where-Object { $_ -like 'GET manifests/*' }).Count -eq 5) 'the pointer and the manifest were read (and were absent) for every runtime'
        foreach ($runtime in $artifacts.Keys) {
            $item = $artifacts[$runtime]
            $plan = Get-PrunletRuntimePlan -Session $w.Session -Spec $item.Spec -SigningKeyPem $testPrivateKey
            if ($runtime -ceq 'osx-arm64') {
                # mac は別経路（Send-PrunletMacPackage.ps1）で不変キーへ置かれた ZIP を照合して使う。
                $w.Handler.Seed($item.Spec.AssetKey, [IO.File]::ReadAllBytes($item.Path))
                $result = Invoke-PrunletRuntimePublication -Session $w.Session -Plan $plan -ReuseRemoteArtifact
            } else { $result = Invoke-PrunletRuntimePublication -Session $w.Session -Plan $plan -ArtifactPath $item.Path }
            Assert-True ($result.Decision -ceq 'full' -and $result.PointerUpdated) "first publication of $runtime updated the pointer"
            Assert-True ($w.Handler.Puts() -contains "PUT latest/$runtime.json create-only") "the first pointer of $runtime is create-only"
            $read = Read-PrunletReleaseEnvelope -Bytes $w.Handler.Objects["latest/$runtime.json"].Bytes -Trust $testTrust
            Assert-True ((Read-PrunletReleasePayloadInfo -PayloadBytes $read.PayloadBytes).VersionText -ceq '1.0.0') "the pointer of $runtime is the new version"
        }
        # Velopack: フィード・版マニフェストとも 404 の初回配信。
        $vpDir = New-VelopackDir '1.0.0'
        $null = Invoke-Velopack $w $vpDir '1.0.0'
        Assert-True ($w.Handler.Puts() -contains 'PUT velopack/releases.win.json create-only') 'the first Velopack feed is create-only'
        Assert-True ($w.Handler.Objects.ContainsKey('manifests/1.0.0/velopack-win-x64.json')) 'the first Velopack manifest was written'
    } finally { Remove-World $w }
}
Invoke-Case 'publish: a non-404 read failure of the pointer, the manifest or the feed is not treated as absent (zero writes)' {
    # 「読めないポインタは配信しない」: 404 以外（403・500）は「まだ無い」と区別して止める。
    foreach ($failure in @(@{ Key = 'latest/win-x64.json'; Status = 403 }, @{ Key = 'latest/win-x64.json'; Status = 500 }, @{ Key = 'manifests/1.0.0/win-x64.json'; Status = 500 })) {
        $w = New-TestWorld
        try {
            $w.Handler.FailGetContaining = $failure.Key; $w.Handler.FailGetStatus = $failure.Status
            $spec = New-TestSpec 'win-x64' '1.0.0' (New-TestArtifact 'package.zip')
            Assert-Throws { Get-PrunletRuntimePlan -Session $w.Session -Spec $spec -NoSign } 'code=http-rejected' "check-only with $($failure.Key) $($failure.Status)"
            Assert-Throws { Get-PrunletRuntimePlan -Session $w.Session -Spec $spec -SigningKeyPem $testPrivateKey } 'code=http-rejected' "plan with $($failure.Key) $($failure.Status)"
            Assert-True ($w.Handler.Puts().Count -eq 0) "no write after $($failure.Key) $($failure.Status)"
        } finally { Remove-World $w }
    }
    $w = New-TestWorld
    try {
        $w.Handler.FailGetContaining = 'velopack/releases.win.json'; $w.Handler.FailGetStatus = 500
        Assert-Throws { Invoke-Velopack $w (New-VelopackDir '1.0.0') '1.0.0' } 'code=http-rejected' 'unreadable Velopack feed'
        Assert-True ($w.Handler.Puts().Count -eq 0) 'no write after an unreadable Velopack feed'
    } finally { Remove-World $w }
}
Invoke-Case 'ref: Assert-PrunletReleaseRef accepts only release/<version> at a commit on the default branch' {
    $repo = Join-Path $OutputDirectory 'ref-repo'; New-Item -ItemType Directory -Path $repo | Out-Null
    function Invoke-TestGit([string[]]$GitArguments) {
        $out = & git -C $repo -c user.name=test -c user.email=test@example.invalid @GitArguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git failed: $out" }
        return ($out | Out-String).Trim()
    }
    $null = Invoke-TestGit @('init', '-q', '-b', 'main')
    [IO.File]::WriteAllText((Join-Path $repo 'Cargo.toml'), "[package]`nname = `"x`"`nversion = `"1.2.3`"`n")
    $null = Invoke-TestGit @('add', 'Cargo.toml'); $null = Invoke-TestGit @('commit', '-q', '-m', 'init', '--no-gpg-sign')
    $head = Invoke-TestGit @('rev-parse', 'HEAD')
    $null = Invoke-TestGit @('update-ref', 'refs/remotes/origin/main', 'HEAD')
    $script = Join-Path $PSScriptRoot 'Assert-PrunletReleaseRef.ps1'
    function Invoke-TestRef([string]$RefType, [string]$RefName, [string]$Sha, [string[]]$Extra = @()) {
        $env:GITHUB_REF_TYPE = $RefType; $env:GITHUB_REF_NAME = $RefName; $env:GITHUB_SHA = $Sha; $env:GITHUB_OUTPUT = ''
        try { $out = & pwsh -NoProfile -File $script -SourceRoot $repo -DefaultBranch main @Extra 2>&1; return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out | Out-String) } }
        finally { Remove-Item Env:GITHUB_REF_TYPE, Env:GITHUB_REF_NAME, Env:GITHUB_SHA, Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue }
    }
    $ok = Invoke-TestRef 'branch' 'release/1.2.3' $head
    Assert-True ($ok.Code -eq 0 -and $ok.Out -match '"release":"true"' -and $ok.Out -match '"version":"1.2.3"') "release branch passes: $($ok.Out)"
    Assert-True ((Invoke-TestRef 'branch' 'release/1.2.4' $head).Code -ne 0) 'a branch name that differs from the Cargo.toml version fails'
    Assert-True ((Invoke-TestRef 'tag' 'v1.2.3' $head).Code -ne 0) 'a tag ref fails'
    Assert-True ((Invoke-TestRef 'branch' 'main' $head).Code -ne 0) 'a non-release branch fails'
    Assert-True ((Invoke-TestRef 'branch' 'release/1.2.3' ('0' * 40)).Code -ne 0) 'a different event commit fails'
    $verifyOnly = Invoke-TestRef 'branch' 'main' $head @('-AllowNonRelease')
    Assert-True ($verifyOnly.Code -eq 0 -and $verifyOnly.Out -match '"release":"false"') 'a non-release ref is verification-only with -AllowNonRelease'
    # 既定ブランチに取り込まれていない commit（main の先にある commit）は配信できない。
    [IO.File]::WriteAllText((Join-Path $repo 'extra.txt'), 'x'); $null = Invoke-TestGit @('add', 'extra.txt'); $null = Invoke-TestGit @('commit', '-q', '-m', 'ahead', '--no-gpg-sign')
    $ahead = Invoke-TestGit @('rev-parse', 'HEAD')
    Assert-True ((Invoke-TestRef 'branch' 'release/1.2.3' $ahead).Code -ne 0) 'a commit that is not an ancestor of the default branch fails'
}

Write-Host "passed=$script:passed failed=$script:failed skipped=$script:skipped"
Remove-Item Env:CLOUDFLARE_API_TOKEN, Env:PRUNLET_R2_ACCOUNT_ID -ErrorAction SilentlyContinue
if ($script:failed -ne 0) { exit 1 }
