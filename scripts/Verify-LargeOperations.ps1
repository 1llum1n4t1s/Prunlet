[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$BaselineExecutablePath,
    [ValidateRange(32769, 1000000)][int]$FileCount = 32769,
    [ValidateRange(60, 86400)][int]$ProcessTimeoutSeconds = 1800
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'ExecutablePath, OutputDirectory and ReportPath must be absolute.' }
}
if ($BaselineExecutablePath -and ![IO.Path]::IsPathFullyQualified($BaselineExecutablePath)) { throw 'BaselineExecutablePath must be absolute.' }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$report = [IO.Path]::GetFullPath($ReportPath)
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach ($destination in @($outputRoot, $report)) {
    Assert-VerificationDestination $destination @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
}
if (Test-Path -LiteralPath $outputRoot) { throw 'OutputDirectory must be new.' }
if (Test-Path -LiteralPath $report) { throw 'ReportPath must be new.' }
if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($report))) { throw 'Create the external ReportPath parent first.' }
foreach ($exe in @($ExecutablePath, $BaselineExecutablePath) | Where-Object { $_ }) {
    if (![IO.File]::Exists($exe)) { throw "Executable not found: $exe" }
}
$null = [IO.Directory]::CreateDirectory($outputRoot)
$recovery = Join-Path $outputRoot 'recovery'
$config = Join-Path $outputRoot 'config.json'
$tree = Join-Path $outputRoot 'large-tree'
$alias = Join-Path $outputRoot 'special-hardlink.txt'
$metrics = [Collections.Generic.List[object]]::new()
$results = [Collections.Generic.List[object]]::new()
$operations = [Collections.Generic.List[object]]::new()

function Assert-True([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function File-Digest([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Invoke-Cli([string[]]$Arguments, [string]$Executable = $ExecutablePath) {
    # 削除を含む全操作は最初からCMDでCLIへ直接渡す。展開文字を含む経路は実行前に拒否する。
    $argumentsWithConfig = @('--config', $config) + $Arguments
    foreach ($value in @($Executable) + $argumentsWithConfig) {
        if ($value -match '["%&|<>^!\r\n]') { throw 'CLI argument cannot be represented safely in CMD.' }
    }
    $command = '""' + $Executable + '" ' + (($argumentsWithConfig | ForEach-Object { '"' + $_ + '"' }) -join ' ') + '"'
    $info = [Diagnostics.ProcessStartInfo]::new('cmd.exe')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $info.Arguments = '/d /s /c ' + $command
    $info.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = Join-Path $outputRoot 'runtime-cache'
    # CMDの子CLIの計測はPowerShellのProcess APIでPIDを追跡する。
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $timer = [Diagnostics.Stopwatch]::StartNew(); $peakHandles = 0; $peakWorkingSet = 0L; $peakPrivateBytes = 0L
    $cli = $null
    try {
        $null = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        while (!$process.WaitForExit(100)) {
            if ($timer.Elapsed.TotalSeconds -gt $ProcessTimeoutSeconds) { $process.Kill($true); $process.WaitForExit(); throw 'CLI process exceeded timeout.' }
            try {
                if ($null -eq $cli) {
                    $child = Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $process.Id) | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Equals($Executable, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
                    if ($child) { $cli = [Diagnostics.Process]::GetProcessById($child.ProcessId) }
                }
                if ($cli) {
                    $cli.Refresh()
                    $peakHandles = [Math]::Max($peakHandles, $cli.HandleCount)
                    $peakWorkingSet = [Math]::Max($peakWorkingSet, $cli.PeakWorkingSet64)
                    $peakPrivateBytes = [Math]::Max($peakPrivateBytes, $cli.PrivateMemorySize64)
                }
            } catch [System.InvalidOperationException] { } catch [ComponentModel.Win32Exception] { } catch [Microsoft.Management.Infrastructure.CimException] { }
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult(); $stderr = $stderrTask.GetAwaiter().GetResult()
        $json = $null; $parseError = $null
        try { if ($stdout.Trim()) { $json = $stdout | ConvertFrom-Json -Depth 50 } } catch { $parseError = $_.Exception.Message }
        $failure = $null
        if ($process.ExitCode -ne 0 -or $parseError) {
            $failure = @{
                error = ([string]$json.error).Substring(0, [Math]::Min(2048, ([string]$json.error).Length))
                stderr = $stderr.Substring(0, [Math]::Min(2048, $stderr.Length))
                parseError = $parseError
                failedItems = @($json.items | Where-Object { $_.status -eq 'failed' -or $_.error } | Select-Object -First 3 | ForEach-Object { @{ path = $_.path; status = $_.status; error = ([string]$_.error).Substring(0, [Math]::Min(512, ([string]$_.error).Length)) } })
            }
            if ($parseError) { $failure.stdoutPrefix = $stdout.Substring(0, [Math]::Min(1024, $stdout.Length)) }
        }
        $metrics.Add(@{ command = $Arguments -join ' '; executable = $Executable; exitCode = $process.ExitCode; milliseconds = $timer.Elapsed.TotalMilliseconds; sampledPeakHandles = $peakHandles; peakWorkingSetBytes = $peakWorkingSet; sampledPeakPrivateBytes = $peakPrivateBytes; cliSampled = $null -ne $cli; stdoutBytes = [Text.Encoding]::UTF8.GetByteCount($stdout); failure = $failure })
        if ($parseError) { throw "CLI returned invalid JSON: $parseError" }
        return @{ ExitCode = $process.ExitCode; Json = $json; Stderr = $stderr }
    } finally { if ($cli) { $cli.Dispose() }; $process.Dispose() }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try { & $Body; $results.Add(@{ name = $Name; passed = $true; milliseconds = $timer.Elapsed.TotalMilliseconds }) }
    catch { $results.Add(@{ name = $Name; passed = $false; milliseconds = $timer.Elapsed.TotalMilliseconds; error = $_.Exception.Message }); Write-Warning "$Name : $($_.Exception.Message)" }
}
function Fixture-Path([int]$Index) { return Join-Path $tree (('file-{0:D6}-' -f $Index) + ('x' * 120) + '.txt') }
function Assert-FixtureIntact([string]$Prefix = 'content') {
    Assert-True ([IO.Directory]::Exists($tree)) 'Fixture root is missing.'
    Assert-True (@([IO.Directory]::EnumerateFiles($tree)).Count -eq $FileCount) 'Fixture file count differs.'
    # 全ファイルを検証し、復元時の上書きや内容欠落を取り逃さない。
    for ($index = 0; $index -lt $FileCount; $index++) {
        Assert-True ([IO.File]::ReadAllText((Fixture-Path $index)) -ceq "$Prefix $index") "Fixture content differs at $index."
    }
}
function Assert-BaselineRejects([string[]]$Arguments) {
    if (!$BaselineExecutablePath) { return }
    Assert-FixtureIntact
    $result = Invoke-Cli $Arguments $BaselineExecutablePath
    Assert-True ($result.ExitCode -ne 0) 'Baseline unexpectedly accepted the large fixture.'
    Assert-FixtureIntact
}

Test-Case 'create one reusable large fixture and initialize isolated recovery' {
    $null = [IO.Directory]::CreateDirectory($recovery)
    $init = Invoke-Cli @('init', '--backup-directory', $recovery)
    Assert-True ($init.ExitCode -eq 0) 'Initialization failed.'
    $null = [IO.Directory]::CreateDirectory($tree)
    for ($index = 0; $index -lt $FileCount; $index++) { [IO.File]::WriteAllText((Fixture-Path $index), "content $index", [Text.UTF8Encoding]::new($false)) }
    $null = New-Item -ItemType HardLink -Path $alias -Target (Fixture-Path 0)
    Assert-FixtureIntact
}

foreach ($schema in @(3, 2)) {
    Test-Case "schema $schema recursive delete restore conflict purge repeat exceeds 32768 entries and 8 MiB metadata" {
        Assert-True ($results.Count -gt 0 -and @($results | Where-Object { !$_.passed }).Count -eq 0) 'Earlier phase failed; fixture retained without further mutation.'
        if ($schema -eq 2) {
            # 外部名だけを同じCoreで削除し、元の32Kファイルはそのまま再利用する。
            $response = Invoke-Cli @('delete', '--', $alias)
            Assert-True ($response.ExitCode -eq 0 -and ![IO.File]::Exists($alias)) 'Special hardlink removal failed.'
            $aliasOperationId = $response.Json.operationId
            $response = $null
            $response = Invoke-Cli @('purge', $aliasOperationId, '--apply')
            Assert-True ($response.ExitCode -eq 0) 'Alias recovery purge failed.'
            $response = $null
        }
        Assert-BaselineRejects @('delete', '--dry-run', '--recursive', '--', $tree)
        $response = Invoke-Cli @('delete', '--dry-run', '--recursive', '--', $tree)
        Assert-True ($response.ExitCode -eq 0 -and $response.Json.items.Count -eq ($FileCount + 1)) 'Large candidate dry run failed.'
        $response = $null
        Assert-FixtureIntact
        $response = Invoke-Cli @('delete', '--recursive', '--', $tree)
        Assert-True ($response.ExitCode -eq 0 -and ![IO.Directory]::Exists($tree) -and $response.Json.items.Count -eq ($FileCount + 1)) 'Large recursive deletion failed.'
        $id = $response.Json.operationId; $operationRoot = Join-Path $recovery $id
        $response = $null
        $manifestPath = Join-Path $operationRoot 'manifest.json'; $deleteResultPath = Join-Path $operationRoot 'delete-result.json'
        $manifestLength = (Get-Item -LiteralPath $manifestPath).Length; $deleteResultLength = (Get-Item -LiteralPath $deleteResultPath).Length
        Assert-True ($manifestLength -gt 8MB -and $deleteResultLength -gt 8MB) 'Fixture did not exceed both old metadata byte limits.'
        # 巨大DOMを検証スクリプトで重ねて保持せず、先頭のschema fieldだけを確認する。
        $reader = [IO.File]::OpenText($manifestPath)
        try { $prefix = [char[]]::new(256); $length = $reader.Read($prefix, 0, $prefix.Length); $prefixText = [string]::new($prefix, 0, $length) } finally { $reader.Dispose() }
        Assert-True ($prefixText -match ('"schema"\s*:\s*' + $schema + '\b')) 'Expected schema branch was not exercised.'
        $manifestHash = File-Digest $manifestPath
        if ($BaselineExecutablePath) {
            $response = Invoke-Cli @('purge', $id, '--dry-run') $BaselineExecutablePath
            Assert-True ($response.ExitCode -ne 0 -and ![IO.File]::Exists((Join-Path $operationRoot 'purge-intent.json'))) 'Baseline accepted oversized recovery metadata or wrote an intent.'
            $response = $null
            Assert-True ((File-Digest $manifestPath) -ceq $manifestHash) 'Baseline changed candidate manifest.'
        }
        $response = Invoke-Cli @('restore', $id)
        Assert-True ($response.ExitCode -eq 0 -and $response.Json.items.Count -eq ($FileCount + 1)) 'Large restore failed.'
        $response = $null
        Assert-FixtureIntact
        # 全対象を異なる内容へ変更し、同じ内容を書き戻す偽の成功も検出する。
        for ($index = 0; $index -lt $FileCount; $index++) { [IO.File]::WriteAllText((Fixture-Path $index), "existing $index", [Text.UTF8Encoding]::new($false)) }
        $response = Invoke-Cli @('restore', $id)
        Assert-True ($response.ExitCode -ne 0 -and @($response.Json.items | Where-Object status -eq 'restored').Count -eq 0) 'Repeat restore overwrote an existing target.'
        $response = $null
        Assert-FixtureIntact 'existing'
        for ($index = 0; $index -lt $FileCount; $index++) { [IO.File]::WriteAllText((Fixture-Path $index), "content $index", [Text.UTF8Encoding]::new($false)) }
        $response = Invoke-Cli @('purge', $id, '--dry-run')
        Assert-True ($response.ExitCode -eq 0 -and ![IO.File]::Exists((Join-Path $operationRoot 'purge-intent.json'))) 'Large purge inspection failed or mutated metadata.'
        $response = $null
        $response = Invoke-Cli @('purge', $id, '--apply')
        Assert-True ($response.ExitCode -eq 0 -and $response.Json.purgedBytes -gt 0) 'Large purge failed.'
        $response = $null
        Assert-True (@([IO.Directory]::EnumerateFiles($operationRoot, '*.bak')).Count -eq 0) 'Large purge retained recovery copies.'
        $response = Invoke-Cli @('purge', $id, '--apply')
        Assert-True ($response.ExitCode -eq 0 -and $response.Json.purgedBytes -eq 0 -and @($response.Json.items | Where-Object status -eq 'purged').Count -eq 0) 'Large purge repeat was not idempotent.'
        $response = $null
        Assert-True ((File-Digest $manifestPath) -ceq $manifestHash) 'Large lifecycle changed manifest.'
        Assert-FixtureIntact
        $operations.Add(@{ schema = $schema; operationId = $id; entries = $FileCount + 1; manifestBytes = $manifestLength; deleteResultBytes = $deleteResultLength; manifestSha256 = $manifestHash })
    }
}
if (@($results | Where-Object { !$_.passed }).Count -eq 0) {
    Test-Case 'successful large fixture cleanup uses candidate CLI and purges only its own operation' {
        Assert-FixtureIntact
        Assert-True (![IO.File]::Exists($alias)) 'Unexpected special alias remains; fixture retained.'
        $response = Invoke-Cli @('delete', '--recursive', '--', $tree)
        Assert-True ($response.ExitCode -eq 0 -and ![IO.Directory]::Exists($tree)) 'Candidate CLI fixture cleanup failed.'
        $cleanupId = $response.Json.operationId
        $response = $null
        Assert-True ($cleanupId -cmatch '^[0-9a-f]{32}$') 'Cleanup operation ID is invalid.'
        $cleanupOperationRoot = Join-Path $recovery $cleanupId
        Assert-True ([IO.Directory]::Exists($cleanupOperationRoot)) 'Cleanup operation was not recorded in isolated recovery.'
        $response = Invoke-Cli @('purge', $cleanupId, '--apply')
        Assert-True ($response.ExitCode -eq 0 -and @([IO.Directory]::EnumerateFiles($cleanupOperationRoot, '*.bak')).Count -eq 0) 'Candidate CLI cleanup recovery purge failed.'
        $response = $null
        Assert-True (![IO.Directory]::Exists($tree)) 'Large fixture root remains after cleanup.'
    }
}
$failed = @($results | Where-Object { !$_.passed })
$reportObject = [ordered]@{
    timestampUtc = [DateTimeOffset]::UtcNow.ToString('O'); executable = $ExecutablePath; executableSha256 = File-Digest $ExecutablePath
    baselineExecutable = $BaselineExecutablePath; baselineExecutableSha256 = $(if ($BaselineExecutablePath) { File-Digest $BaselineExecutablePath } else { $null })
    outputDirectory = $outputRoot; fileCount = $FileCount; passed = $results.Count - $failed.Count; failed = $failed.Count
    results = @($results); operations = @($operations); processMetrics = @($metrics)
    metricNotes = 'CLI child sampled through CMD every 100 ms; handles/private bytes are sampled maxima. Short processes may not be sampled. No performance threshold is asserted.'
    cleanup = 'Retain this report. After checking links and terminated processes, clean only this disposable OutputDirectory with Prunlet. Failure fixtures are retained for reproduction.'
}
[IO.File]::WriteAllText($report, ($reportObject | ConvertTo-Json -Depth 15), [Text.UTF8Encoding]::new($false))
@{ passed = $reportObject.passed; failed = $reportObject.failed; report = $report } | ConvertTo-Json -Compress
if ($failed.Count) { exit 1 }
