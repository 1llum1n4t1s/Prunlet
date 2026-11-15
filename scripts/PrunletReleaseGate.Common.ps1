#requires -Version 7.2
# 鍵整合の関門の本体（scripts/Test-PrunletReleaseKeyGate.ps1 が呼ぶ。仕様・抽出規則はそちらの冒頭を参照）。
# 本体を関数にして、照合先の信頼（-Trust）・ツリー（-SourceRoot）・署名鍵を引数に持たせるのはテストのため。
# 公開入口のスクリプトは、本番の信頼・リポジトリのルート・環境変数の鍵だけで呼ぶ（コマンドラインから差し替えられない）。
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'PrunletRelease.Common.ps1')

function Invoke-PrunletReleaseKeyGate {
    param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)]$Trust, [string]$PrivateKeyPem)
    if (![IO.Path]::IsPathFullyQualified($SourceRoot) -or !(Test-Path -LiteralPath $SourceRoot -PathType Container)) { Stop-PrunletRelease 'gate' 'invalid-source-root' }

    # 試験用の payload。実際の配信とは無関係な固定内容（署名が通るかだけを見る）。
    $spec = New-PrunletReleaseSpec -Runtime 'win-x64' -Version '0.0.1' -CommitSha ('0' * 40) -DefaultBranch 'main' -Sha256 ('0' * 64) -Bytes 1
    $payload = New-PrunletReleasePayloadBytes -Spec $spec
    $envelope = New-PrunletReleaseEnvelopeBytes -PayloadBytes $payload -PrivateKeyPem $PrivateKeyPem -KeyId $Trust.KeyId

    $failures = [Collections.Generic.List[string]]::new()
    $results = [Collections.Generic.List[object]]::new()
    try { $null = Read-PrunletReleaseEnvelope -Bytes $envelope -Trust $Trust } catch { $failures.Add('reference: the signing key does not match the publisher public key') }

    # 必須の 3 か所（Required）は、定数が無ければ not-installed で失敗する。
    # launcher は封筒の検証を Rust の内部コマンド（__check-release-manifest 等）へ任せ、信頼の基点を Rust の 1 か所に
    # 集約したので、定数を持たないのが正しい形。ただし将来だれかが launcher に定数を書き戻した場合に、古い鍵が
    # 黙って残らないよう、持っているなら必須の場所と同じ規則（ちょうど 1 個・本番鍵と一致・封筒を検証できる）で
    # 検査する（任意の場所）。持たないことは失敗にせず、状態 not-present として報告に残す。
    $locations = @(
        @{ Name = 'rust'; Directory = 'src/rust'; Filter = '*.rs'; Required = $true },
        @{ Name = 'installer-ps1'; File = 'scripts/Install-Prunlet.ps1'; Required = $true },
        @{ Name = 'installer-sh'; File = 'scripts/Install-Prunlet.sh'; Required = $true },
        @{ Name = 'launcher'; File = 'integration/start-prunlet-mcp.ps1'; Required = $false }
    )
    $pattern = [regex]::new('PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64[^\r\n"'']*["'']([A-Za-z0-9+/]{100,}={0,2})["'']', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    foreach ($location in $locations) {
        $files = if ($location.ContainsKey('File')) {
            $path = Join-Path $SourceRoot $location.File
            if (Test-Path -LiteralPath $path -PathType Leaf) { , @(Get-Item -LiteralPath $path) } else { , @() }
        } else {
            $root = Join-Path $SourceRoot $location.Directory
            if (Test-Path -LiteralPath $root -PathType Container) { , @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter $location.Filter) } else { , @() }
        }
        $found = [Collections.Generic.List[object]]::new()
        foreach ($file in $files) {
            $text = [IO.File]::ReadAllText($file.FullName)
            foreach ($match in $pattern.Matches($text)) { $found.Add([pscustomobject]@{ File = $file.FullName.Substring($SourceRoot.TrimEnd('\', '/').Length + 1); Value = $match.Groups[1].Value }) }
        }
        $state = 'ok'
        if ($found.Count -eq 0) { $state = $(if ($location.Required) { 'not-installed' } else { 'not-present' }) }
        elseif ($found.Count -gt 1) { $state = 'duplicate-definition' }
        elseif ($found[0].Value -cne $Trust.PublicKey) { $state = 'differs-from-publisher' }
        else {
            # 同じ封筒を、その場所の定数だけで検証する（値が同じでも、鍵として読めること・署名が通ることを確かめる）。
            try { $null = Read-PrunletReleaseEnvelope -Bytes $envelope -Trust ([pscustomobject]@{ KeyId = $Trust.KeyId; PublicKey = $found[0].Value }) } catch { $state = 'verification-failed' }
        }
        # 任意の場所の not-present だけは失敗に数えない（それ以外の状態は必須の場所と同じく失敗）。
        if ($state -cne 'ok' -and $state -cne 'not-present') { $failures.Add("$($location.Name): $state") }
        $results.Add([ordered]@{ location = $location.Name; required = [bool]$location.Required; state = $state; file = $(if ($found.Count -ge 1) { $found[0].File } else { $null }) })
    }

    $report = [ordered]@{
        status = $(if ($failures.Count -eq 0) { 'passed' } else { 'failed' }); keyId = $Trust.KeyId
        publicKeySha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Convert]::FromBase64String($Trust.PublicKey))).ToLowerInvariant()
        locations = $results; failures = $failures
    }
    $json = $report | ConvertTo-Json -Depth 5 -Compress
    if ($failures.Count -ne 0) {
        # 失敗の内容（場所と状態だけ）を出してから止める。R2 へは何も書かない。
        Write-Host $json
        throw "Prunlet release key gate failed: $($failures -join '; ')"
    }
    return $json
}
