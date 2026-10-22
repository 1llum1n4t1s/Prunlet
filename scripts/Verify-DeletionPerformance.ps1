[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$BaselineExecutablePath,
    [ValidateRange(1, 100)][int]$Iterations = 3,
    [ValidateRange(1, 86400)][int]$ProcessTimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
# 想定する失敗: 削除未完了、復元内容不一致、衝突上書き、小・空・バッファー境界の欠落、ADS欠落、
# 順序バイアス、JSON不正、子プロセス時間超過、リポジトリやCodex homeへの出力混入。
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath, $BaselineExecutablePath) | Where-Object { $_ }) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'All executable and output paths must be absolute.' }
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$report = [IO.Path]::GetFullPath($ReportPath)
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach ($destination in @($outputRoot, $report)) {
    Assert-VerificationDestination $destination @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
}
if (Test-Path -LiteralPath $outputRoot) { throw 'OutputDirectory must be new.' }
if (Test-Path -LiteralPath $report) { throw 'ReportPath must be new.' }
if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($report))) { throw 'Create the external ReportPath parent first.' }
$executables = [ordered]@{ candidate = [IO.Path]::GetFullPath($ExecutablePath) }
if ($BaselineExecutablePath) { $executables.baseline = [IO.Path]::GetFullPath($BaselineExecutablePath) }
foreach ($exe in $executables.Values) { if (![IO.File]::Exists($exe)) { throw "Executable not found: $exe" } }
$null = [IO.Directory]::CreateDirectory($outputRoot)
$results = [Collections.Generic.List[object]]::new()
$utf8 = [Text.UTF8Encoding]::new($false)
function Assert-True([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }

function Invoke-Cli([string]$Executable, [string]$RunRoot, [string[]]$Arguments) {
    # 通常E2Eと同じく検証対象exeを直接起動し、CLI自身のCPU時間を取得する。
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $utf8; $info.StandardErrorEncoding = $utf8
    foreach ($argument in (@('--config', (Join-Path $RunRoot 'config.json')) + $Arguments)) { $info.ArgumentList.Add($argument) }
    $info.WorkingDirectory = $RunRoot
    $info.Environment['TEMP'] = Join-Path $RunRoot 'temp'
    $info.Environment['TMP'] = Join-Path $RunRoot 'temp'
    $info.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = Join-Path $RunRoot 'runtime-cache'
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $timer = [Diagnostics.Stopwatch]::new()
    $peakWorkingSet = 0L; $peakPrivateBytes = 0L; $samples = 0
    try {
        $timer.Start(); $null = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        while (!$process.WaitForExit(10)) {
            if ($timer.Elapsed.TotalSeconds -gt $ProcessTimeoutSeconds) {
                $process.Kill($true); $process.WaitForExit(); throw 'CLI process exceeded timeout.'
            }
            try {
                $process.Refresh()
                $peakWorkingSet = [Math]::Max($peakWorkingSet, $process.PeakWorkingSet64)
                $peakPrivateBytes = [Math]::Max($peakPrivateBytes, $process.PrivateMemorySize64)
                $samples++
            } catch [InvalidOperationException] { } catch [ComponentModel.Win32Exception] { }
        }
        $timer.Stop()
        $cpuMilliseconds = $process.TotalProcessorTime.TotalMilliseconds
        $stdout = $stdoutTask.GetAwaiter().GetResult(); $stderr = $stderrTask.GetAwaiter().GetResult()
        try { $json = $stdout | ConvertFrom-Json -Depth 50 }
        catch { throw "CLI returned invalid JSON: $($_.Exception.Message); stderr: $($stderr.Substring(0, [Math]::Min(2048, $stderr.Length)))" }
        Assert-True ($null -ne $json) 'CLI returned empty JSON.'
        return @{
            exitCode = $process.ExitCode; json = $json
            metrics = @{
                elapsedMilliseconds = $timer.Elapsed.TotalMilliseconds; cpuMilliseconds = $cpuMilliseconds
                sampledPeakWorkingSetBytes = $(if ($samples) { $peakWorkingSet } else { $null })
                sampledPeakPrivateBytes = $(if ($samples) { $peakPrivateBytes } else { $null })
                memorySamples = $samples
            }
            stderr = $stderr.Substring(0, [Math]::Min(2048, $stderr.Length))
        }
    } finally { $process.Dispose() }
}

function New-Fixture([string]$Tree, [string]$Case) {
    $null = [IO.Directory]::CreateDirectory($Tree)
    $files = [Collections.Generic.List[object]]::new()
    $directoryCount = 1
    $count = switch ($Case) { 'shallow-small' { 512 }; 'deep-small' { 128 }; 'schema3-ads' { 128 }; 'buffer-boundaries' { 6 } }
    $sizes = @(0, 1, 1024, 131071, 131072, 131073)
    $directory = $Tree
    if ($Case -eq 'deep-small') {
        foreach ($level in 1..8) { $directory = Join-Path $directory "level-$level"; $null = [IO.Directory]::CreateDirectory($directory); $directoryCount++ }
    }
    for ($index = 0; $index -lt $count; $index++) {
        $size = if ($Case -eq 'buffer-boundaries') { $sizes[$index] } else { 32 }
        $bytes = [byte[]]::new($size)
        # 内容を固定し、新旧・試行間で同じバイト列を使う。
        [Random]::new(1701 + $index).NextBytes($bytes)
        $path = Join-Path $directory ('file-{0:D4}.bin' -f $index)
        [IO.File]::WriteAllBytes($path, $bytes)
        $files.Add(@{ path = $path; bytes = $bytes })
    }
    $streams = [Collections.Generic.List[object]]::new()
    if ($Case -eq 'schema3-ads') {
        $streams.Add(@{ path = $Tree + ':performance'; bytes = $utf8.GetBytes('directory stream 日本語') })
        for ($index = 0; $index -lt $files.Count; $index++) {
            if ($index -lt $sizes.Count) {
                $bytes = [byte[]]::new($sizes[$index]); [Random]::new(2701 + $index).NextBytes($bytes)
            } else { $bytes = $utf8.GetBytes('file stream ' + [IO.Path]::GetFileName($files[$index].path)) }
            $streams.Add(@{ path = $files[$index].path + ':performance'; bytes = $bytes })
        }
        foreach ($stream in $streams) { [IO.File]::WriteAllBytes($stream.path, $stream.bytes) }
    }
    return @{ tree = $Tree; files = $files; streams = $streams; directoryCount = $directoryCount; schema = $(if ($Case -eq 'schema3-ads') { 3 } else { 2 }) }
}
function Assert-Fixture([object]$Fixture) {
    Assert-True ([IO.Directory]::Exists($Fixture.tree)) 'Restored tree is missing.'
    Assert-True (@([IO.Directory]::EnumerateFiles($Fixture.tree, '*', [IO.SearchOption]::AllDirectories)).Count -eq $Fixture.files.Count) 'Restored file count differs.'
    Assert-True ((@([IO.Directory]::EnumerateDirectories($Fixture.tree, '*', [IO.SearchOption]::AllDirectories)).Count + 1) -eq $Fixture.directoryCount) 'Restored directory count differs.'
    foreach ($entry in @($Fixture.files.ToArray()) + @($Fixture.streams.ToArray())) {
        $actual = [Convert]::ToHexString([IO.File]::ReadAllBytes($entry.path))
        Assert-True ($actual -ceq [Convert]::ToHexString($entry.bytes)) "Restored bytes differ: $($entry.path)"
    }
}

foreach ($case in @('shallow-small', 'deep-small', 'schema3-ads', 'buffer-boundaries')) {
    for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
        $order = if ($BaselineExecutablePath -and $iteration % 2 -eq 1) { @('baseline', 'candidate') } else { @($executables.Keys) }
        for ($position = 0; $position -lt $order.Count; $position++) {
            $label = $order[$position]
            $runRoot = Join-Path $outputRoot ("$case-$iteration-$label")
            $row = [ordered]@{ case = $case; iteration = $iteration; order = $position + 1; executableLabel = $label; passed = $false; deletionMetrics = $null }
            try {
                $null = [IO.Directory]::CreateDirectory($runRoot)
                $null = [IO.Directory]::CreateDirectory((Join-Path $runRoot 'temp'))
                $recovery = Join-Path $runRoot 'recovery'; $null = [IO.Directory]::CreateDirectory($recovery)
                [IO.File]::WriteAllText((Join-Path $runRoot 'config.json'), (@{ schema = 1; backupDirectory = $recovery } | ConvertTo-Json), $utf8)
                $fixture = New-Fixture (Join-Path $runRoot 'tree') $case
                Assert-Fixture $fixture
                $response = Invoke-Cli $executables[$label] $runRoot @('delete', '--recursive', '--', $fixture.tree)
                $row.deletionMetrics = $response.metrics
                Assert-True ($response.exitCode -eq 0) "Delete failed: $($response.stderr)"
                Assert-True ($response.json.items.Count -eq ($fixture.files.Count + $fixture.directoryCount) -and @($response.json.items | Where-Object status -ne 'deleted').Count -eq 0) 'Delete status or item count differs.'
                Assert-True (!(Test-Path -LiteralPath $fixture.tree)) 'Original tree still exists after delete.'
                $id = [string]$response.json.operationId
                Assert-True ($id -match '^[a-zA-Z0-9-]+$') 'Invalid operation ID.'
                $manifest = [IO.File]::ReadAllText((Join-Path (Join-Path $recovery $id) 'manifest.json')) | ConvertFrom-Json -Depth 50
                Assert-True ($manifest.schema -eq $fixture.schema) 'Expected schema branch was not exercised.'
                $row.schema = $manifest.schema; $row.fileCount = $fixture.files.Count; $row.streamCount = $fixture.streams.Count
                $row.operationId = $id
                $response = Invoke-Cli $executables[$label] $runRoot @('restore', $id)
                Assert-True ($response.exitCode -eq 0 -and $response.json.items.Count -eq ($fixture.files.Count + $fixture.directoryCount) -and @($response.json.items | Where-Object status -ne 'restored').Count -eq 0) 'Restore status or item count differs.'
                Assert-Fixture $fixture
                # 異なる既存内容を置き、再復元がコピーで上書きしないことを確認する。
                $collision = $fixture.files[0]; $originalBytes = $collision.bytes
                $collision.bytes = $utf8.GetBytes('existing conflict sentinel')
                # CREATE_ALWAYSによるADS消去を避け、既存の主ストリームだけを書き換える。
                $existing = [IO.FileStream]::new($collision.path, [IO.FileMode]::Open, [IO.FileAccess]::Write)
                try { $existing.SetLength($collision.bytes.Length); $existing.Write($collision.bytes) }
                finally { $existing.Dispose() }
                $response = Invoke-Cli $executables[$label] $runRoot @('restore', $id)
                Assert-True ($response.exitCode -ne 0 -and @($response.json.items | Where-Object { $_.path -ceq $collision.path -and $_.status -eq 'conflict' }).Count -eq 1 -and @($response.json.items | Where-Object status -eq 'restored').Count -eq 0) 'Repeat restore did not preserve the existing conflict.'
                Assert-Fixture $fixture
                $collision.bytes = $originalBytes
                $row.passed = $true
            } catch {
                $row.error = $_.Exception.Message
                Write-Warning "$case iteration $iteration $label : $($row.error)"
            } finally { $response = $null; $fixture = $null; $manifest = $null }
            $results.Add($row)
        }
    }
}
$failed = @($results | Where-Object { !$_.passed }).Count
$identities = foreach ($label in $executables.Keys) { @{ label = $label; path = $executables[$label]; sha256 = (Get-FileHash -LiteralPath $executables[$label] -Algorithm SHA256).Hash.ToLowerInvariant() } }
$summary = foreach ($label in $executables.Keys) {
    foreach ($case in @('shallow-small', 'deep-small', 'schema3-ads', 'buffer-boundaries')) {
        $times = @($results | Where-Object { $_.passed -and $_.executableLabel -eq $label -and $_.case -eq $case } | ForEach-Object { $_.deletionMetrics.elapsedMilliseconds } | Sort-Object)
        $median = if (!$times.Count) { $null } elseif ($times.Count % 2) { $times[[int][Math]::Floor($times.Count / 2)] } else { ($times[$times.Count / 2 - 1] + $times[$times.Count / 2]) / 2 }
        @{ executableLabel = $label; case = $case; successfulIterations = $times.Count; medianElapsedMilliseconds = $median }
    }
}
$reportObject = [ordered]@{
    schema = 1; timestampUtc = [DateTimeOffset]::UtcNow.ToString('O'); executables = @($identities)
    outputDirectory = $outputRoot; iterations = $Iterations; processTimeoutSeconds = $ProcessTimeoutSeconds
    passed = $results.Count - $failed; failed = $failed; results = @($results); summary = @($summary)
    metricNotes = 'Only delete --recursive is measured, including CLI startup and recovery persistence. Independent fixtures/config/recovery/temp/bundle cache per trial; no warm-up or OS cache flush. Baseline first on odd iterations, candidate first on even iterations. CPU is CLI TotalProcessorTime; memory is sampled every 10 ms (null when not sampled). Verification and fixture setup are excluded. No performance threshold is asserted.'
    cleanup = 'No cleanup is performed. After checking links and terminated processes, clean only this disposable OutputDirectory with the installed Prunlet. Retain this report and any failure fixtures needed for reproduction.'
}
[IO.File]::WriteAllText($report, ($reportObject | ConvertTo-Json -Depth 15), $utf8)
$reportObject | ConvertTo-Json -Depth 15
if ($failed) { exit 1 }
