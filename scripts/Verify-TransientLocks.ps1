[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'All paths must be absolute.' }
    Assert-VerificationDestination ([IO.Path]::GetFullPath($path)) @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
    if ($path -match '["%&|<>^!\r\n]') { throw 'Unsafe CMD path.' }
}
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$report = [IO.Path]::GetFullPath($ReportPath)
foreach ($destination in @($outputRoot, $report)) {
    if (![IO.Path]::GetPathRoot($destination).Equals('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Verification output must be on D:.' }
}
if (![IO.File]::Exists($ExecutablePath)) { throw 'Executable not found.' }
if ((Test-Path -LiteralPath $outputRoot) -or (Test-Path -LiteralPath $report)) { throw 'OutputDirectory and ReportPath must be new.' }
if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($report))) { throw 'Create the report parent first.' }
$null = [IO.Directory]::CreateDirectory($outputRoot)
$env:TEMP = Join-Path $outputRoot 'temp'; $env:TMP = $env:TEMP
$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR = Join-Path $outputRoot 'runtime-cache'
$null = [IO.Directory]::CreateDirectory($env:TEMP)
$results = [Collections.Generic.List[object]]::new()
$commands = [Collections.Generic.List[object]]::new()
$binaryHash = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()

# 想定する失敗: 短期競合の即失敗、保持継続時の無限待機、ロード中DLLの即失敗、
# 失敗後の元対象・検証済みコピーの欠損、読み取り専用属性の無断解除。
# バックアップ・identity検証エラーの非再試行は、Core担当の確認範囲とする。
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PrunletTransientLockFixture {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FreeLibrary(IntPtr module);
}
'@
function Assert-True([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Digest([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Save-Json([string]$Path, [object]$Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false)) }
function Manifests { @(Get-ChildItem -LiteralPath $script:Recovery -Filter manifest.json -Recurse -File) }
function Invoke-Cli([string[]]$Arguments, [scriptblock]$Tick = {}, [int]$TimeoutSeconds = 75) {
    $values = @('--config', $script:Config) + $Arguments
    foreach ($value in @($ExecutablePath) + $values) { if ($value -match '["%&|<>^!\r\n]') { throw 'Unsafe CMD argument.' } }
    $number = $commands.Count
    $stdoutPath = Join-Path $script:CaseRoot "command-$number.stdout.json"
    $stderrPath = Join-Path $script:CaseRoot "command-$number.stderr.txt"
    $info = [Diagnostics.ProcessStartInfo]::new('cmd.exe')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $info.Arguments = '/d /s /c ""' + $ExecutablePath + '" ' + (($values | ForEach-Object { '"' + $_ + '"' }) -join ' ') + '"'
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $started = $false; $recorded = $false
    try {
        $null = $process.Start()
        $started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        while (!$process.WaitForExit(25)) {
            & $Tick $timer.Elapsed.TotalMilliseconds
            if ($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw 'CLI exceeded timeout.' }
        }
        $raw = $stdout.GetAwaiter().GetResult(); $errorText = $stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText($stdoutPath, $raw); [IO.File]::WriteAllText($stderrPath, $errorText)
        $entry = @{ case = [IO.Path]::GetFileName($script:CaseRoot); arguments = $Arguments; exitCode = $process.ExitCode; milliseconds = $timer.Elapsed.TotalMilliseconds; stdout = $stdoutPath; stderr = $stderrPath }
        $commands.Add($entry)
        $recorded = $true
        $json = if ($raw.Trim()) { $raw | ConvertFrom-Json -Depth 40 } else { $null }
        return @{ ExitCode = $process.ExitCode; Json = $json; Milliseconds = $entry.milliseconds }
    } catch {
        if ($started -and !$recorded) {
            if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            [IO.File]::WriteAllText($stdoutPath, $stdout.GetAwaiter().GetResult())
            [IO.File]::WriteAllText($stderrPath, $stderr.GetAwaiter().GetResult())
            $commands.Add(@{ case = [IO.Path]::GetFileName($script:CaseRoot); arguments = $Arguments; exitCode = $process.ExitCode; milliseconds = $timer.Elapsed.TotalMilliseconds; stdout = $stdoutPath; stderr = $stderrPath; harnessError = $_.Exception.Message })
        }
        throw
    } finally {
        if ($started -and !$process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $script:Evidence = @{}
    try {
        $script:CaseRoot = Join-Path $outputRoot $Name
        $script:Recovery = Join-Path $script:CaseRoot 'recovery'
        $script:Config = Join-Path $script:CaseRoot 'config.json'
        Assert-VerificationDestination $script:CaseRoot @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
        $null = [IO.Directory]::CreateDirectory($script:Recovery)
        $init = Invoke-Cli @('init', '--backup-directory', $script:Recovery)
        $script:Evidence.initMilliseconds = $init.Milliseconds
        Assert-True ($init.ExitCode -eq 0) 'Fixture initialization failed.'
        & $Body
        $results.Add(@{ name = $Name; passed = $true; milliseconds = $timer.Elapsed.TotalMilliseconds; evidence = $script:Evidence })
    } catch {
        $results.Add(@{ name = $Name; passed = $false; milliseconds = $timer.Elapsed.TotalMilliseconds; error = $_.Exception.Message; evidence = $script:Evidence })
        Write-Warning "$Name : $($_.Exception.Message)"
    }
}
function Assert-Backup([string]$SourceHash) {
    $manifests = @(Manifests)
    Assert-True ($manifests.Count -eq 1) 'Expected exactly one operation manifest.'
    $manifest = [IO.File]::ReadAllText($manifests[0].FullName) | ConvertFrom-Json
    $entry = @($manifest.items | Where-Object { $_.sha256 -eq $SourceHash })
    Assert-True ($entry.Count -eq 1 -and $entry[0].state -eq 'backup_ready') 'Verified backup metadata is missing.'
    $copies = @(Get-ChildItem -LiteralPath $manifests[0].DirectoryName -Filter '*.bak' -File)
    $matching = @($copies | Where-Object { (Digest $_.FullName) -ceq $SourceHash })
    Assert-True ($matching.Count -eq 1) 'Verified backup bytes differ.'
    $script:Evidence.backup = @{ path = $matching[0].FullName; sha256 = Digest $matching[0].FullName; manifest = $manifests[0].FullName; state = $entry[0].state }
}
foreach ($persistent in @($false, $true)) {
    $name = if ($persistent) { 'maintenance-lock-timeout' } else { 'maintenance-lock-released' }
    Test-Case $name {
        $source = Join-Path $script:CaseRoot 'source.txt'; [IO.File]::WriteAllText($source, 'maintenance contention fixture')
        $hash = Digest $source; $script:Evidence.sourceSha256 = $hash
        if (!$persistent) {
            $script:Evidence.plannedHoldMilliseconds = [Math]::Max(10000, $script:Evidence.initMilliseconds * 2 + 2000)
            Assert-True ($script:Evidence.plannedHoldMilliseconds -lt 60000) 'Initialization is too slow to verify transient contention within the 60 second coordination bound.'
        }
        $script:HeldLock = [IO.FileStream]::new((Join-Path $script:Recovery 'maintenance.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $result = Invoke-Cli @('delete', '--', $source) {
                param($milliseconds)
                if (!$persistent -and $script:HeldLock -and $milliseconds -ge $script:Evidence.plannedHoldMilliseconds) {
                    $script:Evidence.releaseMilliseconds = $milliseconds
                    $script:Evidence.cliAliveBeforeRelease = !$process.HasExited
                    $script:Evidence.manifestCountBeforeRelease = @(Manifests).Count
                    Assert-True ($script:Evidence.cliAliveBeforeRelease -and $script:Evidence.manifestCountBeforeRelease -eq 0) 'CLI must still be alive without a manifest before lock release.'
                    $script:HeldLock.Dispose(); $script:HeldLock = $null
                }
            }
            $script:Evidence.cliMilliseconds = $result.Milliseconds
            if ($persistent) {
                Assert-True ($result.ExitCode -ne 0 -and $result.Milliseconds -ge 59000 -and $result.Milliseconds -lt 75000) 'Coordination timeout did not honor the 60 second bound.'
                Assert-True ([IO.File]::Exists($source) -and (Digest $source) -ceq $hash) 'Coordination timeout changed the source.'
                Assert-True (@(Manifests).Count -eq 0) 'Coordination timeout created an operation manifest.'
            } else {
                Assert-True ($script:Evidence.releaseMilliseconds -ge $script:Evidence.plannedHoldMilliseconds -and $script:Evidence.cliAliveBeforeRelease -and $script:Evidence.manifestCountBeforeRelease -eq 0) 'CLI did not wait before manifest creation.'
                Assert-True ($result.ExitCode -eq 0 -and ![IO.File]::Exists($source)) 'Released coordination lock did not allow deletion.'
                Assert-Backup $hash
            }
        } finally { if ($script:HeldLock) { $script:HeldLock.Dispose(); $script:HeldLock = $null } }
    }
}
foreach ($persistent in @($false, $true)) {
    $name = if ($persistent) { 'loaded-dll-timeout' } else { 'loaded-dll-released' }
    Test-Case $name {
        $tree = Join-Path $script:CaseRoot 'tree'; $parent = Join-Path $tree 'nested'
        $null = [IO.Directory]::CreateDirectory($parent)
        $source = Join-Path $parent 'fixture.dll'
        [IO.File]::Copy((Join-Path $env:WINDIR 'System32\version.dll'), $source)
        $hash = Digest $source; $script:Evidence.sourceSha256 = $hash
        $script:Module = [PrunletTransientLockFixture]::LoadLibraryExW($source, [IntPtr]::Zero, 1)
        Assert-True ($script:Module -ne [IntPtr]::Zero) "LoadLibraryExW failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        $script:ManifestSeenAt = $null
        try {
            $result = Invoke-Cli @('delete', '--recursive', '--', $tree) {
                param($milliseconds)
                if ($null -eq $script:ManifestSeenAt -and @(Manifests).Count -gt 0) { $script:ManifestSeenAt = $milliseconds; $script:Evidence.manifestSeenMilliseconds = $milliseconds }
                if (!$persistent -and $null -ne $script:ManifestSeenAt -and $milliseconds -ge $script:ManifestSeenAt + 1000 -and $script:Module -ne [IntPtr]::Zero) {
                    Assert-True ([IO.Directory]::Exists($parent) -and [IO.File]::Exists($source)) 'Loaded DLL or its parent disappeared before release.'
                    Assert-True ([PrunletTransientLockFixture]::FreeLibrary($script:Module)) 'FreeLibrary failed.'
                    $script:Module = [IntPtr]::Zero; $script:Evidence.releaseMilliseconds = $milliseconds
                }
            } 25
            $script:Evidence.cliMilliseconds = $result.Milliseconds
            Assert-Backup $hash
            if ($persistent) {
                Assert-True ($result.ExitCode -ne 0 -and $null -ne $script:ManifestSeenAt -and ($result.Milliseconds - $script:ManifestSeenAt) -ge 9500 -and $result.Milliseconds -lt 25000) 'Loaded DLL did not fail within the deletion retry bound.'
                Assert-True ([IO.Directory]::Exists($tree) -and [IO.Directory]::Exists($parent) -and [IO.File]::Exists($source) -and (Digest $source) -ceq $hash) 'Held DLL or its parent directories were lost.'
            } else {
                Assert-True ($script:Evidence.releaseMilliseconds -ge $script:ManifestSeenAt + 1000) 'DLL was not held through deletion contention.'
                Assert-True ($result.ExitCode -eq 0 -and ![IO.Directory]::Exists($tree)) 'Released DLL did not allow recursive deletion.'
            }
        } finally {
            if ($script:Module -ne [IntPtr]::Zero) {
                $released = [PrunletTransientLockFixture]::FreeLibrary($script:Module); $script:Module = [IntPtr]::Zero
                Assert-True $released 'Final FreeLibrary failed.'
            }
        }
    }
}
Test-Case 'readonly-remains-readonly' {
    $source = Join-Path $script:CaseRoot 'readonly.txt'; [IO.File]::WriteAllText($source, 'readonly fixture')
    [IO.File]::SetAttributes($source, [IO.FileAttributes]::ReadOnly)
    $hash = Digest $source; $script:Evidence.sourceSha256 = $hash
    $result = Invoke-Cli @('delete', '--', $source) {} 15
    $script:Evidence.cliMilliseconds = $result.Milliseconds
    Assert-True ($result.ExitCode -ne 0 -and @($result.Json.items).Count -eq 1 -and $result.Json.items[0].status -eq 'failed' -and $result.Json.items[0].path -ceq $source) 'Read-only deletion did not report the expected failed item.'
    Assert-True ([IO.File]::Exists($source) -and (Digest $source) -ceq $hash -and ([IO.File]::GetAttributes($source) -band [IO.FileAttributes]::ReadOnly) -ne 0) 'Read-only source content or attribute changed.'
    Assert-Backup $hash
    $manifests = @(Manifests)
    $deleteResults = @(Get-ChildItem -LiteralPath $script:Recovery -Filter delete-result.json -Recurse -File)
    Assert-True ($manifests.Count -eq 1 -and $deleteResults.Count -eq 1 -and $manifests[0].DirectoryName -ceq $deleteResults[0].DirectoryName) 'Expected one manifest and one result in the same operation directory.'
    $persistedResult = [IO.File]::ReadAllText($deleteResults[0].FullName) | ConvertFrom-Json
    Assert-True (@($persistedResult.items).Count -eq 1 -and $persistedResult.items[0].status -eq 'failed' -and $persistedResult.items[0].path -ceq $source) 'Persisted read-only result does not contain the expected failed item.'
    # CLI起動時間を除く。25ms間隔の観測では即時失敗を取り逃がすため、永続化した両記録の時刻を使う。
    $manifestWrittenUtc = $manifests[0].LastWriteTimeUtc
    $resultWrittenUtc = $deleteResults[0].LastWriteTimeUtc
    $phaseMilliseconds = ($resultWrittenUtc - $manifestWrittenUtc).TotalMilliseconds
    $script:Evidence.deletionPhaseTiming = @{ source = 'persisted-metadata-last-write-utc'; manifestWrittenUtc = $manifestWrittenUtc.ToString('O'); resultWrittenUtc = $resultWrittenUtc.ToString('O'); milliseconds = $phaseMilliseconds }
    Assert-True ($phaseMilliseconds -ge 0 -and $phaseMilliseconds -lt 5000) 'Read-only deletion phase should fail without transient retries; metadata interval must be nonnegative and below 5000ms.'
}
$passed = @($results | Where-Object passed).Count; $failed = $results.Count - $passed
Save-Json $report @{ purpose = 'post-fix-transient-lock-e2e'; executable = $ExecutablePath; executableSha256 = $binaryHash; outputDirectory = $outputRoot; passed = $passed; failed = $failed; cases = @($results); commands = @($commands) }
Write-Output $report
Write-Output "passed=$passed failed=$failed"
if ($failed) { exit 1 }
