# 製品exeと同じsource fingerprintのcfg(test) Rust Coreだけを境界probeとして使う。
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'registry-session-e2e/RustProbe.Common.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'RustBuildInputs.Common.ps1')

function Get-RustFileSourceFingerprint([string]$SourceRoot) {
    $names=@(Get-PrunletRustInputNames $SourceRoot)
    $text=[Text.StringBuilder]::new()
    foreach($name in $names) {
        $path=Join-Path $SourceRoot $name
        Assert-VerificationDestination $path @()
        $item=Get-Item -LiteralPath $path -Force
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Source fingerprint requires plain source files.' }
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $null=$text.Append($name).Append("`t").Append($hash).Append("`n")
    }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($text.ToString()))).ToLowerInvariant()
}

function Assert-RustFileProbeBinding {
    foreach($path in @($ExecutablePath,$RustProbePath,$BuildManifestPath)) {
        if(![IO.Path]::IsPathFullyQualified($path) -or ![IO.File]::Exists($path)) { throw 'Existing absolute product/probe/build-manifest paths are required.' }
        Assert-VerificationDestination $path @()
    }
    if($ExpectedBuildManifestSha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'ExpectedBuildManifestSha256 is required.' }
    $stream=[IO.File]::Open($BuildManifestPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if($stream.Length -gt 4MB) { throw 'Build manifest is too large.' }
        $actual=(Get-FileHash -InputStream $stream -Algorithm SHA256).Hash
        if($actual -cne $ExpectedBuildManifestSha256.ToUpperInvariant()) { throw 'Fixed build manifest SHA-256 changed.' }
        $stream.Position=0;$reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true,4096,$true)
        try {$manifest=$reader.ReadToEnd()|ConvertFrom-Json -AsHashtable -Depth 40} finally {$reader.Dispose()}
    } finally {$stream.Dispose()}
    if($manifest.schema -ne 1 -or $manifest.sourceFingerprintAlgorithm -cne 'sha256-relative-path-tab-content-sha256-v1') { throw 'Unsupported Rust build provenance manifest.' }
    $candidateHash=(Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $probeHash=(Get-FileHash -LiteralPath $RustProbePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if($candidateHash -cne $manifest.product.sha256 -or $probeHash -cne $manifest.probe.sha256) { throw 'Product/probe bytes differ from their same-source build manifest.' }
    $fingerprint=Get-RustFileSourceFingerprint $repo
    if($fingerprint -cne $manifest.sourceFingerprint) { throw 'Product/probe build source fingerprint differs from current Rust Core; rebuild both before verification.' }
    Assert-RustProbe $RustProbePath
    $script:RustFileBuild=@{manifestPath=$BuildManifestPath;manifestSha256=$actual;candidateSha256=$candidateHash;probeSha256=$probeHash;sourceFingerprint=$fingerprint;sourceCommit=$manifest.sourceCommit;runtime=$manifest.runtime;sources=$manifest.sources;build=$manifest.build}
    return $script:RustFileBuild
}

function Get-RustFileProbeSourceHashes {
    $scriptsRoot=Split-Path $PSScriptRoot -Parent
    foreach($relative in @('recordless-e2e/RustFileProbe.Common.ps1','registry-session-e2e/RustProbe.Common.ps1','RustBuildInputs.Common.ps1','Verification-Common.ps1')) {
        $path=Join-Path $scriptsRoot $relative
        Assert-VerificationDestination $path @()
        @{path=$path;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
    }
}

function Invoke-RustFileContract([string]$Case,[string]$FixturePath) {
    if((Get-RustFileSourceFingerprint $repo) -cne $script:RustFileBuild.sourceFingerprint) { throw 'Rust source changed during file verification.' }
    $probeRoot=Join-Path $OutputDirectory ('rust-'+$Case+'-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($probeRoot)
    $resultPath=Join-Path $probeRoot 'result.json'
    $request=@{case=$Case;fixtureRoot=$FixturePath;resultPath=$resultPath}
    $script:Config=''
    $info=New-RustProbeStartInfo $RustProbePath 'files_contract' $request $probeRoot
    $process=[Diagnostics.Process]::Start($info)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(!$process.WaitForExit(180000)) {$process.Kill($true);$process.WaitForExit();throw 'Owned Rust file boundary probe timed out; no deletion was resent.'}
        $out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $probeRoot 'stdout.log'),$out,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $probeRoot 'stderr.log'),$err,[Text.UTF8Encoding]::new($false))
        if($process.ExitCode -ne 0 -or ![IO.File]::Exists($resultPath)) { throw ('Rust file boundary probe failed: '+$out+$err) }
        $envelope=[IO.File]::ReadAllText($resultPath)|ConvertFrom-Json -AsHashtable -Depth 60
        if($envelope.runtime -cne 'rust-libtest' -or !$envelope.nativeFileProbe -or $envelope.realNativeScopeVerified -or !$envelope.result.passed -or $envelope.candidateSha256.ToLowerInvariant() -cne $script:RustFileBuild.candidateSha256 -or $envelope.probeSha256.ToLowerInvariant() -cne $script:RustFileBuild.probeSha256) { throw 'Rust file probe did not bind the candidate, probe and actual native assertions.' }
        if((Get-RustFileSourceFingerprint $repo) -cne $script:RustFileBuild.sourceFingerprint) { throw 'Rust source changed during the native file probe.' }
        return $envelope
    } finally {if(!$process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose()}
}
