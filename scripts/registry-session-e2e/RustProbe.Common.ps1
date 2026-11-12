# Rust候補をC# assemblyへ置き換えず、cfg(test)だけを持つRust libtestを実行する。
function Assert-RustProbe([string]$ProbePath) {
    if (![IO.Path]::IsPathFullyQualified($ProbePath) -or ![IO.File]::Exists($ProbePath)) { throw 'RustProbePath must be an existing absolute Rust libtest executable.' }
    $info=[Diagnostics.ProcessStartInfo]::new($ProbePath);$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.ArgumentList.Add('--list')
    $process=[Diagnostics.Process]::Start($info)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(15000)) { $process.Kill($true);throw 'Rust verification capability probe timed out.' }
        $text=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $text -notmatch '(?m)^verification::checkpoint: test\r?$' -or $text -notmatch '(?m)^verification::native_contract: test\r?$') { throw ('The supplied probe is not the Rust candidate libtest with native verification entry points: '+$errorText) }
    } finally { $process.Dispose() }
}
function Assert-RegistryRustBinding {
    if (!$script:RegistryBuildBinding) { return }
    if ((Get-RustFileSourceFingerprint $repo) -cne $script:RegistryBuildBinding.sourceFingerprint -or
        (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $script:RegistryBuildBinding.candidateSha256 -or
        (Get-FileHash -LiteralPath $RustProbePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $script:RegistryBuildBinding.probeSha256 -or
        (Get-FileHash -LiteralPath $BuildManifestPath -Algorithm SHA256).Hash -ine $script:RegistryBuildBinding.manifestSha256) { throw 'Registry verification product, probe, manifest or source changed.' }
}
function New-RustProbeStartInfo([string]$ProbePath,[string]$TestName,[hashtable]$Request,[string]$Root) {
    Assert-RegistryRustBinding
    if ($TestName -notin @('checkpoint','native_contract','files_contract','snapshot_publication','legacy_discard','owned_markers')) { throw 'Unknown Rust verification entry point.' }
    if (![IO.Path]::IsPathFullyQualified($Root)) { throw 'Rust verification requires an absolute output scope.' }
    $rootPath=[IO.Path]::GetFullPath($Root)
    # ドライブ文字は問わず、通常のドライブ絶対パス（UNC・デバイスパス不可）の既存scopeに限る。
    # リポジトリ・Codex homeの外であることはRust側（bin/verification.rs）も同じ条件で検査する。
    # このファイルは出力先へ複製して使われるため、共通helperが読み込まれている場合だけ追加で照合する。
    if ($rootPath -notmatch '^[A-Za-z]:\\' -or ![IO.Directory]::Exists($rootPath)) { throw 'Rust verification requires a fixed existing external scope (ordinary drive-absolute path outside repository and Codex home).' }
    if (Get-Command Assert-ExternalVerificationPath -CommandType Function -ErrorAction SilentlyContinue) { Assert-ExternalVerificationPath $rootPath @($repo) }
    $item=Get-Item -LiteralPath $rootPath -Force
    while($item){if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Rust verification output must not pass through a reparse point.'};$item=$item.Parent}
    $Request.schema=1;$Request.rootPath=$rootPath;$Request.candidatePath=$ExecutablePath
    $Request.candidateSha256=(Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash
    $Request.expectedProbeSha256=(Get-FileHash -LiteralPath $ProbePath -Algorithm SHA256).Hash
    $Request.configPath=if($script:Config){$script:Config}else{''}
    $requestPath=Join-Path $rootPath ('rust-request-'+[guid]::NewGuid().ToString('N')+'.json')
    [IO.File]::WriteAllText($requestPath,($Request|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    $info=[Diagnostics.ProcessStartInfo]::new($ProbePath);$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($argument in @('--exact',('verification::'+$TestName),'--ignored','--nocapture','--test-threads=1')) { $info.ArgumentList.Add($argument) }
    $info.Environment['PRUNLET_VERIFICATION_REQUEST']=$requestPath
    $info.Environment['PRUNLET_VERIFICATION_REQUEST_SHA256']=(Get-FileHash -LiteralPath $requestPath -Algorithm SHA256).Hash
    $info.Environment['TEMP']=Join-Path $rootPath 'temp';$info.Environment['TMP']=$info.Environment['TEMP']
    $null=[IO.Directory]::CreateDirectory($info.Environment['TEMP'])
    return $info
}
function Invoke-RustNativeContract([string]$Case,[string]$FixturePath) {
    $resultPath=Join-Path $script:CaseRoot 'rust-native-contract-result.json'
    $request=@{case=$Case;fixtureRelative=$FixturePath;resultPath=$resultPath}
    $info=New-RustProbeStartInfo $RustProbePath 'native_contract' $request $script:CaseRoot
    $process=[Diagnostics.Process]::Start($info)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(120000)) { $process.Kill($true);throw 'Rust native API verification timed out.' }
        $out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $script:CaseRoot 'rust-native-contract.stdout.log'),$out)
        [IO.File]::WriteAllText((Join-Path $script:CaseRoot 'rust-native-contract.stderr.log'),$err)
        if ($process.ExitCode -ne 0 -or ![IO.File]::Exists($resultPath)) { throw ('Rust native API contract failed without success substitution: '+$out+$err) }
        $result=[IO.File]::ReadAllText($resultPath)|ConvertFrom-Json -AsHashtable -Depth 80
        if ($result.runtime -cne 'rust-libtest' -or !$result.realNativeScopeVerified -or !$result.result.passed -or ($script:RegistryBuildBinding -and ($result.candidateSha256.ToLowerInvariant() -cne $script:RegistryBuildBinding.candidateSha256 -or $result.probeSha256.ToLowerInvariant() -cne $script:RegistryBuildBinding.probeSha256))) { throw 'Rust native contract did not confirm its actual assertions and candidate binding.' }
        Assert-RegistryRustBinding
        return $result
    } finally { if(!$process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose() }
}
function Stop-RustRegistryCheckpoint([string]$Id,[string]$Phase,[string]$Action,[string]$Event) {
    $signal=Join-Path $script:CaseRoot 'owned-checkpoint.txt'
    $request=@{eventName=$Event;checkpoint=$Phase;operationId=$Id;action=$Action;signalPath=$signal;resultPath=(Join-Path $script:CaseRoot 'unused-checkpoint-result.json')}
    $info=New-RustProbeStartInfo $RustProbePath 'checkpoint' $request $script:CaseRoot
    $process=[Diagnostics.Process]::Start($info);$stderr=$process.StandardError.ReadToEndAsync()
    $lines=[Collections.Generic.List[string]]::new();$clock=[Diagnostics.Stopwatch]::StartNew();$notified=$false
    try {
        while ($lines.Count -lt 128) {
            $remaining=60000-[int]$clock.ElapsedMilliseconds
            if ($remaining -le 0) { throw 'Rust registry durable checkpoint was not reached within the bound.' }
            $line=$process.StandardOutput.ReadLineAsync()
            if (!$line.Wait($remaining)) { throw 'Rust registry durable checkpoint notification timed out.' }
            $value=$line.GetAwaiter().GetResult()
            if ($null -eq $value) { throw ('Rust registry public operation ended before selected checkpoint: '+($lines -join "`n")+$stderr.GetAwaiter().GetResult()) }
            $lines.Add($value)
            if ($value.Contains('PRUNLET_VERIFICATION_CHECKPOINT')) { $notified=$true;break }
        }
        if (!$notified -or ![IO.File]::Exists($signal)) { throw 'Rust durable checkpoint signal missing.' }
        $saved=[IO.File]::ReadAllLines($signal)
        if ($saved.Count -ne 3 -or $saved[0] -cne $Phase -or $saved[1] -cne $Id -or [int]$saved[2] -ne $process.Id) { throw 'Rust checkpoint signal did not bind phase, operation and owned process.' }
        Assert-RegistryRustBinding
        $process.Kill($true);if(!$process.WaitForExit(10000)){throw 'Owned Rust checkpoint process did not exit.'}
        Save-Json (Join-Path $script:CaseRoot 'checkpoint-evidence.json') @{event=$Event;checkpoint=$Phase;operationId=$Id;pid=$process.Id;actualRustProbeSha256=(Get-FileHash -LiteralPath $RustProbePath).Hash;actualCandidateSha256=(Get-FileHash -LiteralPath $ExecutablePath).Hash;scope='Rust candidate-source cfg(test) public API; actual durable event; owned child crash followed by actual shipping CLI';shippingBinaryHasFaultInjection=$false}
    } finally {
        if(!$process.HasExited){$process.Kill($true);$process.WaitForExit()}
        $tail=$process.StandardOutput.ReadToEnd()
        [IO.File]::WriteAllText((Join-Path $script:CaseRoot 'checkpoint.stdout.txt'),(($lines -join "`n")+"`n"+$tail))
        [IO.File]::WriteAllText((Join-Path $script:CaseRoot 'checkpoint.stderr.txt'),$stderr.GetAwaiter().GetResult())
        $process.Dispose()
    }
}
