[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$BaselineExecutablePath,
    [ValidateRange(0, 100000)][int]$ExistingRecoveryFileCount = 0,
    [string[]]$CaseFilter = @('*'),
    [ValidateRange(1, 100)][int]$Iterations = 3,
    [ValidateRange(1, 86400)][int]$ProcessTimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
# 想定する失敗: 削除未完了、復元内容不一致、衝突上書き、小・空・バッファー境界の欠落、ADS欠落、
# 順序バイアス、JSON不正、子プロセス時間超過、リポジトリやCodex homeへの出力混入。
# 移行時の失敗: candidateの旧コピー生成・本番store使用・File ID変化・ACL/通常属性の欠落、
# schemaごとの項目数取り違え、初回復元のroot衝突上書き、消費済み復元による変更内容の巻戻し。
# retentionの事前走査・整理前後走査・厳密予算を省略した測定、File ID取得の子プロセス大量起動も失敗とする。
# seedのschema/件数/容量不一致、計測中のseed整理・内容変化、空のcase選択も失敗とする。
$allCases = @('shallow-small', 'deep-small', 'schema3-ads', 'buffer-boundaries')
$selectedCases = @($allCases | Where-Object { $name = $_; @($CaseFilter | Where-Object { $name -like $_ }).Count -gt 0 })
if (!$selectedCases.Count) { throw 'CaseFilter matched no performance cases.' }
if ($ExistingRecoveryFileCount -gt 0 -and !$BaselineExecutablePath) { throw 'Existing recovery requires the actual legacy BaselineExecutablePath producer.' }
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
    if (![IO.Path]::GetPathRoot($destination).Equals('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Performance verification requires isolated D: output.' }
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

function File-Id([string]$Path) {
    if (!('PrunletPerformanceIdentity' -as [type])) {
        $previousTemp = $env:TEMP; $previousTmp = $env:TMP
        try {
            $env:TEMP = Join-Path $outputRoot 'identity-temp'; $env:TMP = $env:TEMP
            $null = [IO.Directory]::CreateDirectory($env:TEMP)
            # 同一PowerShellプロセス内のP/Invokeを全root・子ファイルで再利用する。
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class PrunletPerformanceIdentity {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int kind, byte[] data, uint size);
    public static string Read(string path) {
        using (var handle = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            byte[] data = new byte[24];
            if (!GetFileInformationByHandleEx(handle, 18, data, 24)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return BitConverter.ToString(data).Replace("-", "");
        }
    }
}
'@
        } finally { $env:TEMP = $previousTemp; $env:TMP = $previousTmp }
    }
    return [PrunletPerformanceIdentity]::Read($Path)
}
function Acl-Permissions($Acl) {
    $rules = @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}' -f $_.IdentityReference.Value, $_.AccessControlType, [long]$_.FileSystemRights, $_.InheritanceFlags, $_.PropagationFlags
    } | Sort-Object)
    return $Acl.Owner + '|' + $Acl.Group + '|' + ($rules -join ';')
}
function Snapshot-Fixture([object]$Fixture) {
    return @(@($Fixture.tree) + @([IO.Directory]::EnumerateFileSystemEntries($Fixture.tree, '*', [IO.SearchOption]::AllDirectories)) | ForEach-Object {
        $acl = Get-Acl -LiteralPath $_
        @{ relative = $_.Substring($Fixture.tree.Length); id = File-Id $_; attributes = [int][IO.File]::GetAttributes($_)
           sddl = $acl.Sddl; permissions = Acl-Permissions $acl }
    })
}
function Assert-Metadata([string]$Root, [object[]]$Snapshot, [switch]$SameObject) {
    foreach ($entry in $Snapshot) {
        $path = $Root + $entry.relative
        Assert-True ([int][IO.File]::GetAttributes($path) -eq $entry.attributes) "Attributes differ: $path"
        if ($SameObject) {
            Assert-True ((File-Id $path) -ceq $entry.id) "File ID changed; copy replacement detected: $path"
            $acl = Get-Acl -LiteralPath $path
            # Windowsが移動rootの継承ACEを明示化しても主体・権利・伝播は維持される。
            if (!$entry.relative) { Assert-True ((Acl-Permissions $acl) -ceq $entry.permissions) "Root ACL permissions differ: $path" }
            else { Assert-True ($acl.Sddl -ceq $entry.sddl) "ACL differs: $path" }
        }
    }
}

function Invoke-Cli([string]$Executable, [string]$RunRoot, [string[]]$Arguments, [string]$ConfigName = 'config.json') {
    # 通常E2Eと同じく検証対象exeを直接起動し、CLI自身のCPU時間を取得する。
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $utf8; $info.StandardErrorEncoding = $utf8
    foreach ($argument in (@('--config', (Join-Path $RunRoot $ConfigName)) + $Arguments)) { $info.ArgumentList.Add($argument) }
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
    [IO.File]::SetAttributes($files[1].path, [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::Archive)
    # 新旧へ同じ明示ACEを与える。ACL保持の契約は同一実体を移動するcandidateで検証する。
    $acl = Get-Acl -LiteralPath $files[1].path
    $principal = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal, [Security.AccessControl.FileSystemRights]::ReadAndExecute, [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $files[1].path -AclObject $acl
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
function Assert-Fixture([object]$Fixture, [string]$Root = $Fixture.tree) {
    Assert-True ([IO.Directory]::Exists($Root)) 'Restored tree is missing.'
    Assert-True (@([IO.Directory]::EnumerateFiles($Root, '*', [IO.SearchOption]::AllDirectories)).Count -eq $Fixture.files.Count) 'Restored file count differs.'
    Assert-True ((@([IO.Directory]::EnumerateDirectories($Root, '*', [IO.SearchOption]::AllDirectories)).Count + 1) -eq $Fixture.directoryCount) 'Restored directory count differs.'
    foreach ($entry in @($Fixture.files.ToArray()) + @($Fixture.streams.ToArray())) {
        $path = $Root + $entry.path.Substring($Fixture.tree.Length)
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $expected = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$entry.bytes))
        Assert-True ($actual -ceq $expected) "Content hash differs: $path"
    }
}

function New-ExistingRecovery([string]$RunRoot, [string]$Recovery, [string]$VolumeStore, [bool]$IsMove) {
    $seeds = [Collections.Generic.List[object]]::new()
    if (!$ExistingRecoveryFileCount) { return }
    $counts = @([int][Math]::Ceiling($ExistingRecoveryFileCount / 2.0), [int][Math]::Floor($ExistingRecoveryFileCount / 2.0))
    # 同じ中央metadataを使い、旧exeには新方式のvolume mapを渡さない。
    [IO.File]::WriteAllText((Join-Path $RunRoot 'legacy-config.json'), (@{ schema = 1; backupDirectory = $Recovery } | ConvertTo-Json), $utf8)
    for ($part = 0; $part -lt $counts.Count; $part++) {
        if (!$counts[$part]) { continue }
        $tree = Join-Path $RunRoot "seed-$part"; $null = [IO.Directory]::CreateDirectory($tree)
        $bytes = $utf8.GetBytes('existing recovery seed 0123456789')
        for ($index = 0; $index -lt $counts[$part]; $index++) {
            [IO.File]::WriteAllBytes((Join-Path $tree ('seed-{0:D6}.bin' -f $index)), $bytes)
        }
        $move = $IsMove -and $part -eq 1
        $producer = if ($move) { $executables.candidate } else { $executables.baseline }
        $configName = if ($move) { 'config.json' } else { 'legacy-config.json' }
        $result = Invoke-Cli $producer $RunRoot @('delete', '--recursive', '--', $tree) $configName
        Assert-True ($result.exitCode -eq 0 -and @($result.json.items | Where-Object status -ne 'deleted').Count -eq 0 -and !(Test-Path -LiteralPath $tree)) 'Existing recovery seed deletion failed.'
        $id = [string]$result.json.operationId
        Assert-True ($id -cmatch '^[a-f0-9]{32}$') 'Invalid seed operation ID.'
        $manifestPath = Join-Path (Join-Path $Recovery $id) $(if ($move) { 'move-manifest.json' } else { 'manifest.json' })
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -Depth 50
        Assert-True ($manifest.schema -eq $(if ($move) { 4 } else { 2 })) 'Existing recovery seed schema differs.'
        $payloads = if ($move) {
            Assert-True ($result.json.items.Count -eq 1 -and $manifest.entries.Count -eq 1) 'Seed move must contain one root.'
            $payload = [string]$result.json.items[0].backupPath
            Assert-True ($payload.StartsWith($VolumeStore.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) 'Seed used a non-fixture volume store.'
            @([IO.Directory]::EnumerateFiles($payload, '*', [IO.SearchOption]::AllDirectories))
        } else {
            Assert-True ($manifest.items.Count -eq $counts[$part] + 1) 'Legacy seed manifest count differs.'
            @($result.json.items | Where-Object kind -eq 'file' | ForEach-Object { [string]$_.backupPath })
        }
        Assert-True ($payloads.Count -eq $counts[$part]) 'Existing recovery seed file count differs.'
        $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        foreach ($path in $payloads) {
            Assert-True ((Get-Item -LiteralPath $path).Length -eq $bytes.Length -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $expectedHash) 'Existing recovery seed content differs.'
        }
        $seeds.Add(@{ operationId = $id; schema = $manifest.schema; fileCount = $payloads.Count; logicalBytes = [long]$payloads.Count * $bytes.Length
            manifestPath = $manifestPath; manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
            payloads = $payloads; payloadHash = $expectedHash; fileBytes = $bytes.Length })
    }
    return $seeds.ToArray()
}
function Assert-ExistingRecovery([object[]]$Seeds) {
    foreach ($seed in $Seeds) {
        Assert-True ([IO.File]::Exists($seed.manifestPath) -and (Get-FileHash -LiteralPath $seed.manifestPath -Algorithm SHA256).Hash -ceq $seed.manifestHash) 'Existing seed manifest was removed or changed.'
        foreach ($path in $seed.payloads) {
            Assert-True ([IO.File]::Exists($path) -and (Get-Item -LiteralPath $path).Length -eq $seed.fileBytes -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $seed.payloadHash) 'Existing seed payload was removed or changed.'
        }
    }
}

foreach ($case in $selectedCases) {
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
                $isMove = $label -eq 'candidate'
                $volumeStore = Join-Path $runRoot 'volume-store'
                $configuration = @{ schema = 1; backupDirectory = $recovery }
                if ($isMove) { $configuration.volumeRecoveryDirectories = @{ ([IO.Path]::GetPathRoot($runRoot)) = $volumeStore } }
                [IO.File]::WriteAllText((Join-Path $runRoot 'config.json'), ($configuration | ConvertTo-Json), $utf8)
                $seeds = @(New-ExistingRecovery $runRoot $recovery $volumeStore $isMove)
                Assert-True ((($seeds | Measure-Object fileCount -Sum).Sum + 0) -eq $ExistingRecoveryFileCount) 'Seed logical file total differs.'
                $seedBytes = [long](($seeds | Measure-Object logicalBytes -Sum).Sum + 0)
                $row.existingRecovery = @($seeds | Select-Object operationId, schema, fileCount, logicalBytes)
                $row.existingRecoveryFileCount = $ExistingRecoveryFileCount; $row.existingRecoveryLogicalBytes = $seedBytes
                $fixture = New-Fixture (Join-Path $runRoot 'tree') $case
                Assert-Fixture $fixture
                $snapshot = Snapshot-Fixture $fixture
                $fixtureBytes = [long](($fixture.files | ForEach-Object { $_.bytes.Length } | Measure-Object -Sum).Sum) + [long](($fixture.streams | ForEach-Object { $_.bytes.Length } | Measure-Object -Sum).Sum)
                Assert-True ($seedBytes + $fixtureBytes -lt 10L * 1024 * 1024 * 1024) 'Fixture exceeds the enabled default recovery budget.'
                Assert-ExistingRecovery $seeds
                $response = Invoke-Cli $executables[$label] $runRoot @('delete', '--recursive', '--', $fixture.tree)
                $row.deletionMetrics = $response.metrics
                Assert-True ($response.exitCode -eq 0) "Delete failed: $($response.stderr)"
                $expectedItems = if ($isMove) { 1 } else { $fixture.files.Count + $fixture.directoryCount }
                Assert-True ($response.json.items.Count -eq $expectedItems -and @($response.json.items | Where-Object status -ne 'deleted').Count -eq 0) 'Delete status or item count differs.'
                Assert-True (!(Test-Path -LiteralPath $fixture.tree)) 'Original tree still exists after delete.'
                Assert-ExistingRecovery $seeds
                $id = [string]$response.json.operationId
                Assert-True ($id -cmatch '^[a-f0-9]{32}$') 'Invalid operation ID.'
                $manifestName = if ($isMove) { 'move-manifest.json' } else { 'manifest.json' }
                $manifest = [IO.File]::ReadAllText((Join-Path (Join-Path $recovery $id) $manifestName)) | ConvertFrom-Json -Depth 50
                $expectedSchema = if ($isMove) { 4 } else { $fixture.schema }
                Assert-True ($manifest.schema -eq $expectedSchema) 'Expected schema branch was not exercised.'
                if ($isMove) {
                    Assert-True ($manifest.entries.Count -eq 1 -and $manifest.entries[0].path -ceq $fixture.tree) 'Move manifest must contain only the input root.'
                    $payload = [string]$response.json.items[0].backupPath
                    $storePrefix = $volumeStore.TrimEnd('\') + '\'
                    Assert-True ($payload.StartsWith($storePrefix, [StringComparison]::OrdinalIgnoreCase)) 'Candidate used a non-fixture volume store.'
                    Assert-True (@([IO.Directory]::EnumerateFiles((Join-Path $recovery $id), '*.bak', [IO.SearchOption]::AllDirectories)).Count -eq 0) 'Candidate produced a legacy recovery copy.'
                    Assert-Fixture $fixture $payload
                    Assert-Metadata $payload $snapshot -SameObject
                    $row.identityVerifiedEntries = $snapshot.Count
                }
                $row.schema = $manifest.schema; $row.fileCount = $fixture.files.Count; $row.streamCount = $fixture.streams.Count
                $row.operationId = $id
                # 初回復元より前にrootと同名のファイルを置き、ディレクトリの上書き・マージを拒否させる。
                $sentinelBytes = $utf8.GetBytes('root restore conflict sentinel')
                [IO.File]::WriteAllBytes($fixture.tree, $sentinelBytes)
                $sentinelId = File-Id $fixture.tree
                $response = Invoke-Cli $executables[$label] $runRoot @('restore', $id)
                Assert-True ($response.exitCode -ne 0 -and @($response.json.items | Where-Object status -eq 'restored').Count -eq 0) 'Initial restore did not reject the occupied root.'
                if ($isMove) { Assert-True ($response.json.items.Count -eq 1 -and $response.json.items[0].status -eq 'conflict') 'Move restore did not report root conflict.' }
                Assert-True ((File-Id $fixture.tree) -ceq $sentinelId -and [Convert]::ToHexString([IO.File]::ReadAllBytes($fixture.tree)) -ceq [Convert]::ToHexString($sentinelBytes)) 'Initial restore changed the root sentinel.'
                if ($isMove) { Assert-Fixture $fixture $payload; Assert-Metadata $payload $snapshot -SameObject }
                # sentinelは削除せず、検証領域内の別名へ保全してから再開する。
                $savedSentinel = Join-Path $runRoot 'retained-root-conflict-sentinel.bin'
                [IO.File]::Move($fixture.tree, $savedSentinel)
                $response = Invoke-Cli $executables[$label] $runRoot @('restore', $id)
                Assert-True ($response.exitCode -eq 0 -and $response.json.items.Count -eq $expectedItems -and @($response.json.items | Where-Object status -ne 'restored').Count -eq 0) 'Restore status or item count differs.'
                Assert-Fixture $fixture
                Assert-ExistingRecovery $seeds
                Assert-Metadata $fixture.tree $snapshot -SameObject:$isMove
                Assert-True ((File-Id $savedSentinel) -ceq $sentinelId -and [Convert]::ToHexString([IO.File]::ReadAllBytes($savedSentinel)) -ceq [Convert]::ToHexString($sentinelBytes)) 'Saved root sentinel changed.'
                if ($isMove) { Assert-True (!(Test-Path -LiteralPath $payload)) 'Consumed move payload still exists after restore.' }
                # 異なる既存内容を置き、再復元がコピーで上書きしないことを確認する。
                $collision = $fixture.files[0]; $originalBytes = $collision.bytes
                $collision.bytes = $utf8.GetBytes('existing conflict sentinel')
                # CREATE_ALWAYSによるADS消去を避け、既存の主ストリームだけを書き換える。
                $existing = [IO.FileStream]::new($collision.path, [IO.FileMode]::Open, [IO.FileAccess]::Write)
                try { $existing.SetLength($collision.bytes.Length); $existing.Write($collision.bytes) }
                finally { $existing.Dispose() }
                $response = Invoke-Cli $executables[$label] $runRoot @('restore', $id)
                if ($isMove) {
                    Assert-True ($response.exitCode -eq 0 -and $response.json.items.Count -eq 1 -and $response.json.items[0].status -eq 'already_restored') 'Consumed move restore did not report already_restored.'
                    Assert-Metadata $fixture.tree $snapshot -SameObject
                } else {
                    Assert-True ($response.exitCode -ne 0 -and @($response.json.items | Where-Object { $_.path -ceq $collision.path -and $_.status -eq 'conflict' }).Count -eq 1 -and @($response.json.items | Where-Object status -eq 'restored').Count -eq 0) 'Legacy repeat restore did not preserve the existing conflict.'
                }
                Assert-Fixture $fixture
                $collision.bytes = $originalBytes
                $row.passed = $true
            } catch {
                $row.error = $_.Exception.Message
                Write-Warning "$case iteration $iteration $label : $($row.error)"
            } finally { $response = $null; $fixture = $null; $manifest = $null; $snapshot = $null; $payload = $null }
            $results.Add($row)
        }
    }
}
$failed = @($results | Where-Object { !$_.passed }).Count
$identities = foreach ($label in $executables.Keys) { @{ label = $label; path = $executables[$label]; sha256 = (Get-FileHash -LiteralPath $executables[$label] -Algorithm SHA256).Hash.ToLowerInvariant() } }
$summary = foreach ($label in $executables.Keys) {
    foreach ($case in $selectedCases) {
        $times = @($results | Where-Object { $_.passed -and $_.executableLabel -eq $label -and $_.case -eq $case } | ForEach-Object { $_.deletionMetrics.elapsedMilliseconds } | Sort-Object)
        $median = if (!$times.Count) { $null } elseif ($times.Count % 2) { $times[[int][Math]::Floor($times.Count / 2)] } else { ($times[$times.Count / 2 - 1] + $times[$times.Count / 2]) / 2 }
        @{ executableLabel = $label; case = $case; successfulIterations = $times.Count; medianElapsedMilliseconds = $median }
    }
}
$reportObject = [ordered]@{
    schema = 1; timestampUtc = [DateTimeOffset]::UtcNow.ToString('O'); executables = @($identities)
    outputDirectory = $outputRoot; iterations = $Iterations; processTimeoutSeconds = $ProcessTimeoutSeconds
    existingRecoveryFileCount = $ExistingRecoveryFileCount; caseFilter = $CaseFilter; selectedCases = $selectedCases
    excludedCases = @($allCases | Where-Object { $_ -notin $selectedCases })
    existingRecoveryNotes = 'Seeding is outside measured deletion. Both labels retain equal logical file counts/bytes in two operations; baseline uses real legacy schema 2, candidate mixes legacy schema 2 and schema 4 (the extra file for odd counts belongs to legacy). Default seven-day retention and 10 GiB budget stay enabled. Seed manifests and every payload hash/length are checked before/after measured deletion and after restore. Seeding warms the CLI/runtime and filesystem caches when enabled; there is no cache flush.'
    passed = $results.Count - $failed; failed = $failed; results = @($results); summary = @($summary)
    metricNotes = 'Only delete --recursive is measured, including CLI startup, retention/capacity scans, strict recovery budget coordination and persistence. Baseline creates schema 2/3 copies; candidate creates one schema 4 root entry and uses only its isolated same-volume store. Default retention and budget remain enabled. Independent fixtures/config/recovery/temp/bundle cache per trial; no extra warm-up or OS cache flush (optional seeding warms caches as described above). Baseline first on odd iterations, candidate first on even iterations. CPU is CLI TotalProcessorTime; memory is sampled every 10 ms (null when not sampled). Fixture setup and verification (hashes, streams, attributes, root conflict, candidate ACL/File ID preservation and consuming restore) are excluded. Legacy restore has no ACL-preservation contract and repeat restore must conflict; candidate repeat restore must report already_restored and preserve changed content. No performance threshold is asserted.'
    cleanup = 'No cleanup is performed. After checking links and terminated processes, clean only this disposable OutputDirectory with the installed Prunlet. Retain this report and any failure fixtures needed for reproduction.'
}
[IO.File]::WriteAllText($report, ($reportObject | ConvertTo-Json -Depth 15), $utf8)
$reportObject | ConvertTo-Json -Depth 15
if ($failed) { exit 1 }
