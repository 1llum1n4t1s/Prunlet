[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$LegacyExecutablePath
)
$ErrorActionPreference = 'Stop'
if (-not [IO.Path]::IsPathFullyQualified($OutputDirectory) -or -not [IO.Path]::IsPathFullyQualified($ReportPath)) { throw 'Verification paths must be absolute.' }
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach ($destination in @($outputRoot, [IO.Path]::GetFullPath($ReportPath))) {
    if (-not [IO.Path]::IsPathFullyQualified($destination)) { throw 'Verification paths must be absolute.' }
    Assert-VerificationDestination $destination @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
}
if (Test-Path -LiteralPath $outputRoot) { throw 'OutputDirectory must be new, not an existing directory.' }
if (Test-Path -LiteralPath $ReportPath) { throw 'ReportPath must be new.' }
$null = New-Item -ItemType Directory -Path $outputRoot
$script:Scope = Join-Path $outputRoot 'scope'
$script:Recovery = Join-Path $outputRoot 'recovery'
$script:Config = Join-Path $outputRoot 'config.json'
$null = New-Item -ItemType Directory -Path $script:Scope, $script:Recovery
$script:Results = [Collections.Generic.List[object]]::new()
$script:SymbolicRestoreEvidence = [Collections.Generic.List[object]]::new()

function Assert-True([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function New-File([string]$Name, [string]$Content = 'Prunlet fixture') {
    $path = Join-Path $script:Scope $Name
    [IO.File]::WriteAllText($path, $Content, [Text.UTF8Encoding]::new($false))
    return $path
}
function Start-ProcessInfo([string]$FileName, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($FileName)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $info.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = Join-Path $outputRoot 'runtime-cache'
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $null = $process.Start()
    return $process
}
function Invoke-ProcessJson([string]$FileName, [string[]]$Arguments, [string]$InputText = '') {
    $process = Start-ProcessInfo $FileName $Arguments
    try {
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if ($InputText) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
        if (!$process.WaitForExit(30000)) { $process.Kill($true); throw 'Subprocess exceeded 30 seconds.' }
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        $json = if ($stdout.Trim()) { $stdout | ConvertFrom-Json -Depth 100 } else { $null }
        return @{ ExitCode = $process.ExitCode; Json = $json; Stderr = $stderr }
    } finally { $process.Dispose() }
}
function Invoke-Prunlet([string[]]$Arguments) { return Invoke-ProcessJson $ExecutablePath (@('--config', $script:Config) + $Arguments) }
function Write-ProtocolInput([Diagnostics.Process]$Process, [string]$Text) {
    $write = $Process.StandardInput.WriteAsync($Text)
    Assert-True ($write.Wait(5000)) 'Protocol input write exceeded 5 seconds.'
    $null = $write.GetAwaiter().GetResult()
    $flush = $Process.StandardInput.FlushAsync()
    Assert-True ($flush.Wait(5000)) 'Protocol input flush exceeded 5 seconds.'
    $null = $flush.GetAwaiter().GetResult()
}
function Read-ProtocolResponse([Diagnostics.Process]$Process) {
    $read = $Process.StandardOutput.ReadLineAsync()
    Assert-True ($read.Wait(5000)) 'Protocol response exceeded 5 seconds with stdin open.'
    $line = $read.GetAwaiter().GetResult()
    Assert-True ($null -ne $line) 'Protocol output closed before its response.'
    return $line | ConvertFrom-Json -Depth 30
}
function Complete-McpSession([Diagnostics.Process]$Process, [object]$ErrorTask) {
    $remaining = $Process.StandardOutput.ReadToEndAsync()
    $Process.StandardInput.Close()
    Assert-True ($Process.WaitForExit(5000) -and $Process.ExitCode -eq 0) 'MCP did not exit successfully on EOF.'
    Assert-True (!$remaining.GetAwaiter().GetResult()) 'MCP emitted an unexpected extra response.'
    Assert-True (!$ErrorTask.GetAwaiter().GetResult()) 'MCP wrote unexpected stderr.'
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        # 改竄・リンクを残すケースを隔離し、次のケースの容量検査へ持ち込まない。
        $script:Recovery = Join-Path $outputRoot ('case-recovery-' + $script:Results.Count)
        $null = [IO.Directory]::CreateDirectory($script:Recovery)
        if ([IO.File]::Exists($script:Config)) {
            $configuration = [IO.File]::ReadAllText($script:Config) | ConvertFrom-Json
            $configuration.backupDirectory = $script:Recovery
            [IO.File]::WriteAllText($script:Config, ($configuration | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        }
        & $Body; $script:Results.Add(@{ name = $Name; passed = $true; milliseconds = $timer.Elapsed.TotalMilliseconds })
    }
    catch { $script:Results.Add(@{ name = $Name; passed = $false; milliseconds = $timer.Elapsed.TotalMilliseconds; error = $_.Exception.Message }); Write-Warning "$Name : $($_.Exception.Message)" }
}
function Hook([string]$Command, [string]$ToolName = 'Bash', [string]$Field = 'command') {
    $event = @{ hook_event_name = 'PreToolUse'; tool_name = $ToolName; tool_input = @{ $Field = $Command; cwd = $script:Scope } } | ConvertTo-Json -Depth 8 -Compress
    $result = Invoke-ProcessJson $ExecutablePath @('--config', $script:Config, 'hook') $event
    Assert-True ($result.ExitCode -eq 0) 'Hook process failed.'
    return $result.Json
}
function Assert-Rejected([string[]]$Arguments, [string]$UntouchedPath, [string]$Context = '') {
    $result = Invoke-Prunlet $Arguments
    Assert-True ($result.ExitCode -ne 0) ("Operation unexpectedly succeeded ($Context; $($Arguments -join ' ')): " + ($result.Json | ConvertTo-Json -Depth 30 -Compress))
    if ($UntouchedPath) { Assert-True ([IO.File]::Exists($UntouchedPath)) 'Original file was lost.' }
}
function File-Digest([string]$Path) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path))).ToLowerInvariant()
}
function New-TreeFixture([string]$Name) {
    $root = Join-Path $script:Scope $Name
    $nested = Join-Path $root '日本語 nested'
    $empty = Join-Path $nested 'empty leaf'
    $null = New-Item -ItemType Directory -Path $empty -Force
    $first = Join-Path $root 'first.bin'
    $second = Join-Path $nested 'second.txt'
    [IO.File]::WriteAllBytes($first, [byte[]](0, 1, 127, 128, 255, 13, 10))
    [IO.File]::WriteAllText($second, 'recursive 日本語 bytes', [Text.UTF8Encoding]::new($false))
    return @{ Root = $root; Nested = $nested; Empty = $empty; Files = @($first, $second); Hashes = @((File-Digest $first), (File-Digest $second)) }
}
function Assert-TreeIntact([object]$Tree) {
    Assert-True ([IO.Directory]::Exists($Tree.Empty)) 'Empty descendant directory was lost.'
    for ($index = 0; $index -lt $Tree.Files.Count; $index++) {
        Assert-True ([IO.File]::Exists($Tree.Files[$index]) -and (File-Digest $Tree.Files[$index]) -ceq $Tree.Hashes[$index]) 'Tree file bytes changed.'
    }
}
function Write-InputFile([string]$Name, [string]$Json) {
    $path = Join-Path $outputRoot $Name
    [IO.File]::WriteAllText($path, $Json, [Text.UTF8Encoding]::new($false))
    return $path
}
function Write-PathsFile([string]$Name, [string[]]$Paths) {
    return Write-InputFile $Name (ConvertTo-Json -InputObject @($Paths) -Compress)
}
function New-SymbolicFixture([string]$Path, [string]$Target) {
    try { $null = New-Item -ItemType SymbolicLink -Path $Path -Target $Target }
    catch {
        # リンク作成権限がない環境では、新規fixtureだけを管理者へ委任する。
        $helper = Join-Path $outputRoot ('create-link-fixture-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $body = "$" + "ErrorActionPreference='Stop'; New-Item -ItemType SymbolicLink -Path '" + $Path.Replace("'", "''") + "' -Target '" + $Target.Replace("'", "''") + "' | Out-Null"
        [IO.File]::WriteAllText($helper, $body, [Text.UTF8Encoding]::new($false))
        $elevated = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', ('"' + $helper + '"')) -Verb RunAs -WindowStyle Hidden -PassThru -Wait
        Assert-True ($elevated.ExitCode -eq 0 -and ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Elevated link fixture creation failed.'
    }
}
function Enable-CaseSensitiveFixture([string]$Path) {
    $helper = Join-Path $outputRoot ('enable-case-fixture-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $body = "& fsutil.exe file SetCaseSensitiveInfo '" + $Path.Replace("'", "''") + "' enable; if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }"
    [IO.File]::WriteAllText($helper, $body, [Text.UTF8Encoding]::new($false))
    $elevated = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-File',('"' + $helper + '"')) -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    Assert-True ($elevated.ExitCode -eq 0) 'Cannot enable case-sensitive fixture.'
    Assert-True (Get-CaseSensitiveFixtureFlag $Path) ('Case-sensitive fixture flag remained disabled after fsutil exit 0: ' + $Path)
}
function Get-CaseSensitiveFixtureFlag([string]$Path) {
    if (!('PrunletVerificationDirectoryFlags' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class PrunletVerificationDirectoryFlags {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int informationClass, out uint flags, uint size);
    public static bool IsCaseSensitive(string path) {
        using (var handle = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!GetFileInformationByHandleEx(handle, 23, out var flags, 4)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return (flags & 1) != 0;
        }
    }
}
'@
    }
    return [PrunletVerificationDirectoryFlags]::IsCaseSensitive($Path)
}
function Enable-CaseSensitiveOperationFixture([string]$Path) {
    Assert-True ([IO.Path]::GetDirectoryName($Path) -ceq $script:Recovery -and [IO.Path]::GetFileName($Path) -cmatch '^[a-f0-9]{32}$') 'Case-sensitive operation fixture must be inside this run recovery directory.'
    Assert-True ([IO.Directory]::Exists($Path) -and !((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Operation fixture directory must not be a link.'
    $stash = Join-Path $outputRoot ('case-operation-stash-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $stash
    $moved = [Collections.Generic.List[object]]::new()
    try {
        # fsutilは非空ディレクトリの設定に失敗しても終了コード0を返すため、fixtureの記録だけを一時退避する。
        foreach ($file in [IO.Directory]::EnumerateFileSystemEntries($Path)) {
            Assert-True ([IO.File]::Exists($file) -and !((Get-Item -LiteralPath $file -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Operation fixture contains an unexpected member.'
            $saved = Join-Path $stash ([IO.Path]::GetFileName($file))
            [IO.File]::Move($file, $saved)
            $moved.Add(@{ Original = $file; Saved = $saved })
        }
        Enable-CaseSensitiveFixture $Path
    } finally {
        foreach ($file in $moved) { [IO.File]::Move($file.Saved, $file.Original) }
    }
    Assert-True (Get-CaseSensitiveFixtureFlag $Path) 'Restored operation fixture lost the case-sensitive flag.'
}
function Invoke-ElevatedPrunletRestore([string]$OperationId) {
    Assert-True ($OperationId -cmatch '^[a-f0-9]{32}$') 'Elevated restore requires a recorded operation ID.'
    $stdoutPath = Join-Path $outputRoot ('elevated-restore-' + $OperationId + '.json')
    $stderrPath = Join-Path $outputRoot ('elevated-restore-' + $OperationId + '.stderr.txt')
    foreach ($path in @($ExecutablePath, $script:Config, $stdoutPath, $stderrPath)) {
        Assert-True ([IO.Path]::IsPathFullyQualified($path) -and $path -notmatch '["%&|<>^!\r\n]') 'Elevated CMD path cannot be represented safely.'
    }
    # 通常と同じCLI/CoreをCMDから起動し、復元に必要な既存のOS特権だけを利用する。
    $command = '""' + $ExecutablePath + '" --config "' + $script:Config + '" restore "' + $OperationId + '" > "' + $stdoutPath + '" 2> "' + $stderrPath + '""'
    $process = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/d /s /c ' + $command) -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    $json = if ([IO.File]::Exists($stdoutPath) -and [IO.File]::ReadAllText($stdoutPath).Trim()) { [IO.File]::ReadAllText($stdoutPath) | ConvertFrom-Json -Depth 100 } else { $null }
    $stderr = if ([IO.File]::Exists($stderrPath)) { [IO.File]::ReadAllText($stderrPath) } else { '' }
    return @{ ExitCode = $process.ExitCode; Json = $json; Stderr = $stderr }
}
function Restore-SymbolicFixture([string]$OperationId, [string]$Link, [string]$Target, [string]$TargetHash) {
    $restored = Invoke-Prunlet @('restore', $OperationId)
    if ($restored.ExitCode -eq 0) {
        $script:SymbolicRestoreEvidence.Add(@{ operationId = $OperationId; nonelevatedExitCode = 0; usedElevation = $false })
        return $restored
    }
    $errors = @($restored.Json.items | ForEach-Object { $_.error }) -join ' '
    Assert-True ($errors -match 'privilege|特権') ('Unexpected nonelevated symbolic restore failure: ' + ($restored.Json | ConvertTo-Json -Depth 30 -Compress))
    Assert-True (!(Test-Path -LiteralPath $Link) -and (File-Digest $Target) -ceq $TargetHash) 'Privilege rejection left a link or changed its target.'
    $elevated = Invoke-ElevatedPrunletRestore $OperationId
    $script:SymbolicRestoreEvidence.Add(@{ operationId = $OperationId; nonelevatedExitCode = $restored.ExitCode; nonelevatedError = $errors; usedElevation = $true; elevatedExitCode = $elevated.ExitCode })
    return $elevated
}
function New-PurgeFixture([string]$Name, [int]$Count = 1) {
    $files = @(); $contents = @()
    for ($index = 0; $index -lt $Count; $index++) {
        $content = "purge fixture $Name $index 日本語"
        $files += New-File "$Name-$index.txt" $content
        $contents += $content
    }
    $deleted = Invoke-Prunlet (@('delete', '--') + $files)
    Assert-True ($deleted.ExitCode -eq 0 -and $deleted.Json.items.Count -eq $Count) 'Purge fixture deletion failed.'
    $root = Join-Path $script:Recovery $deleted.Json.operationId
    $backups = @(for ($index = 0; $index -lt $Count; $index++) { Join-Path $root ('{0:D4}.bak' -f $index) })
    return @{ Id = $deleted.Json.operationId; Root = $root; Files = $files; Contents = $contents; Backups = $backups }
}
function Assert-PurgeRejected([object]$Fixture) {
    $members = @([IO.Directory]::EnumerateFileSystemEntries($Fixture.Root) | Sort-Object)
    $digests = @{}; foreach ($backup in $Fixture.Backups) { $digests[$backup] = File-Digest $backup }
    $result = Invoke-Prunlet @('purge', $Fixture.Id, '--apply')
    Assert-True ($result.ExitCode -ne 0) 'Unsafe purge unexpectedly succeeded.'
    Assert-True (($members -join '|') -ceq (@([IO.Directory]::EnumerateFileSystemEntries($Fixture.Root) | Sort-Object) -join '|')) 'Rejected purge changed operation members.'
    foreach ($backup in $Fixture.Backups) { Assert-True ((File-Digest $backup) -ceq $digests[$backup]) 'Rejected purge changed recovery bytes.' }
}
function New-PartialPurgeFixture([int]$Schema = 1, [string]$State = 'failed') {
    # 実デバイス障害を起こさず、旧版が永続化した途中失敗の状態を隔離して再現する。
    $id = [guid]::NewGuid().ToString('N')
    $root = Join-Path $script:Recovery $id
    $null = [IO.Directory]::CreateDirectory($root)
    [IO.File]::WriteAllBytes((Join-Path $root 'operation.lock'), [byte[]]@())
    $items = @(); $backups = @(); $files = @()
    foreach ($index in 0..2) {
        $path = New-File "partial-$id-$index.txt" "original $index"
        $backup = Join-Path $root ('{0:D4}.bak' -f $index)
        [IO.File]::WriteAllText($backup, @('', 'partial bytes', 'verified recovery bytes')[$index], [Text.UTF8Encoding]::new($false))
        $entry = [ordered]@{ path = $path; state = $(if ($index -eq 2) { 'backup_ready' } else { $State }); size = $(if ($index -eq 2) { (Get-Item -LiteralPath $backup).Length } else { 85220 }); sha256 = $(if ($index -eq 2) { File-Digest $backup } else { $null }) }
        if ($Schema -ge 2) { $entry.kind = 'file'; $entry.treeRoot = $null }
        if ($Schema -eq 3) {
            $entry.streams = $null
            if ($index -eq 2) { $entry.streams = @(@{ name = ''; offset = 0; size = $entry.size; sha256 = $entry.sha256 }) }
            $entry.reparseTag = $null; $entry.linkDirectory = $false; $entry.caseSensitive = $false
        }
        $items += $entry; $backups += $backup; $files += $path
    }
    $manifest = @{ schema = $Schema; operationId = $id; createdUtc = [DateTimeOffset]::UtcNow.ToString('O'); items = $items }
    [IO.File]::WriteAllText((Join-Path $root 'manifest.json'), ($manifest | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    return @{ Id = $id; Root = $root; Backups = $backups; Files = $files }
}
function Write-PartialPurgeIntent([object]$Fixture) {
    $manifestPath = Join-Path $Fixture.Root 'manifest.json'
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -Depth 20
    $targets = @(foreach ($index in 0..1) { @{ index = $index; sha256 = File-Digest $Fixture.Backups[$index]; size = (Get-Item -LiteralPath $Fixture.Backups[$index]).Length } })
    $intent = @{ schema = 2; operationId = $Fixture.Id; manifestSha256 = File-Digest $manifestPath; createdUtc = [DateTimeOffset]::UtcNow.ToString('O'); targets = @(@{ index = 2; sha256 = $manifest.items[2].sha256; size = $manifest.items[2].size }); incompleteTargets = $targets }
    [IO.File]::WriteAllText((Join-Path $Fixture.Root 'purge-intent.json'), ($intent | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}

Test-Case 'init' {
    $result = Invoke-Prunlet @('init', '--backup-directory', $script:Recovery)
    Assert-True ($result.ExitCode -eq 0 -and [IO.File]::Exists($script:Config)) 'Init failed.'
}
Test-Case 'init never overwrites config' { Assert-Rejected @('init', '--allowed-root', $script:Scope, '--backup-directory', $script:Recovery) $script:Config }
if ($LegacyExecutablePath) {
    Test-Case 'new file-only schema 1 operation restores and purges through legacy executable' {
        Assert-True ([IO.Path]::IsPathFullyQualified($LegacyExecutablePath) -and [IO.File]::Exists($LegacyExecutablePath)) 'Legacy executable must be an existing absolute path.'
        $file = New-File 'legacy-executable-roundtrip.bin' 'new schema 1 bytes 日本語'
        $hash = File-Digest $file
        $deleted = Invoke-Prunlet @('delete', '--', $file)
        Assert-True ($deleted.ExitCode -eq 0 -and ![IO.File]::Exists($file)) 'New file-only deletion failed.'
        $operationRoot = Join-Path $script:Recovery $deleted.Json.operationId
        $manifestPath = Join-Path $operationRoot 'manifest.json'
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -Depth 30
        Assert-True ($manifest.schema -eq 1 -and !$manifest.items[0].PSObject.Properties['kind'] -and !$manifest.items[0].PSObject.Properties['treeRoot']) 'New file-only manifest expanded the legacy wire schema.'
        $manifestHash = File-Digest $manifestPath
        $restored = Invoke-ProcessJson $LegacyExecutablePath @('--config', $script:Config, 'restore', $deleted.Json.operationId)
        Assert-True ($restored.ExitCode -eq 0 -and (File-Digest $file) -ceq $hash) 'Legacy executable could not restore the new schema 1 operation.'
        $purged = Invoke-ProcessJson $LegacyExecutablePath @('--config', $script:Config, 'purge', $deleted.Json.operationId, '--apply')
        Assert-True ($purged.ExitCode -eq 0 -and @($purged.Json.items | Where-Object status -eq 'purged').Count -eq 1 -and @([IO.Directory]::EnumerateFiles($operationRoot, '*.bak')).Count -eq 0) 'Legacy executable could not purge the new schema 1 operation.'
        Assert-True ((File-Digest $file) -ceq $hash -and (File-Digest $manifestPath) -ceq $manifestHash -and [IO.File]::Exists((Join-Path $operationRoot 'operation.lock'))) 'Legacy compatibility changed source bytes or retained metadata.'
    }
}
Test-Case 'schema 1 omitted null stale and overlapping legacy roots do not restrict targets' {
    $original = [IO.File]::ReadAllBytes($script:Config)
    try {
        $variants = @(
            @{ schema = 1; backupDirectory = $script:Recovery },
            @{ schema = 1; allowedRoots = $null; backupDirectory = $script:Recovery },
            @{ schema = 1; allowedRoots = @((Join-Path $outputRoot 'missing-legacy-root')); backupDirectory = $script:Recovery },
            @{ schema = 1; allowedRoots = @($outputRoot); backupDirectory = $script:Recovery }
        )
        $index = 0
        foreach ($variant in $variants) {
            [IO.File]::WriteAllText($script:Config, ($variant | ConvertTo-Json -Depth 10))
            $bytes = [IO.File]::ReadAllBytes($script:Config)
            $file = Join-Path $outputRoot ('legacy-unrestricted-' + $index++ + '.txt')
            [IO.File]::WriteAllText($file, 'legacy config content')
            $deleted = Invoke-Prunlet @('delete', '--', $file)
            Assert-True ($deleted.ExitCode -eq 0 -and ![IO.File]::Exists($file)) 'Legacy roots still restrict local deletion.'
            $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
            Assert-True ($restored.ExitCode -eq 0 -and [IO.File]::ReadAllText($file) -eq 'legacy config content') 'Legacy roots still restrict restore.'
            Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($script:Config)) -ceq [Convert]::ToBase64String($bytes)) 'Reading a legacy config rewrote it.'
        }
    } finally { [IO.File]::WriteAllBytes($script:Config, $original) }
}
Test-Case 'CLI Unicode/spaces delete and restore preserve bytes and timestamp' {
    $file = New-File '日本語 with spaces.txt' '復元するbytes 🐈'
    $hash = (Get-FileHash -LiteralPath $file).Hash
    $time = [IO.File]::GetLastWriteTimeUtc($file)
    $result = Invoke-Prunlet @('delete', '--', $file)
    Assert-True ($result.ExitCode -eq 0 -and ![IO.File]::Exists($file)) 'Delete failed.'
    Assert-True ($result.Json.items[0].status -eq 'deleted') 'Delete status is incorrect.'
    $restored = Invoke-Prunlet @('restore', $result.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0 -and (Get-FileHash -LiteralPath $file).Hash -eq $hash) 'Restore hash differs.'
    Assert-True ([IO.File]::GetLastWriteTimeUtc($file) -eq $time) 'Restore timestamp differs.'
}
Test-Case 'paths-file deletes and restores literal Unicode spaces from read-only input outside scope' {
    $file = New-File "paths 日本語 [literal]'s 😀.txt" 'JSON paths preserve bytes 🐈'
    $hash = File-Digest $file; $time = [IO.File]::GetLastWriteTimeUtc($file)
    $inputFile = Write-PathsFile 'readonly-paths.json' @($file)
    $inputHash = File-Digest $inputFile
    [IO.File]::SetAttributes($inputFile, [IO.FileAttributes]::ReadOnly)
    try {
        $dry = Invoke-Prunlet @('delete', '--dry-run', '--paths-file', $inputFile)
        Assert-True ($dry.ExitCode -eq 0 -and $dry.Json.items[0].status -eq 'would_delete' -and [IO.File]::Exists($file)) 'Paths-file dry run changed source.'
        $deleted = Invoke-Prunlet @('delete', '--paths-file', $inputFile)
        Assert-True ($deleted.ExitCode -eq 0 -and $deleted.Json.items[0].status -eq 'deleted' -and ![IO.File]::Exists($file)) 'Paths-file delete failed.'
        Assert-True ((File-Digest $inputFile) -ceq $inputHash -and ([IO.File]::GetAttributes($inputFile) -band [IO.FileAttributes]::ReadOnly)) 'Read-only paths input changed.'
        $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
        Assert-True ($restored.ExitCode -eq 0 -and (File-Digest $file) -ceq $hash -and [IO.File]::GetLastWriteTimeUtc($file) -eq $time) 'Paths-file restore differs.'
    } finally { [IO.File]::SetAttributes($inputFile, [IO.FileAttributes]::Normal) }
}
Test-Case 'paths-file rejects malformed encoding structure paths counts and ambiguous arguments before mutation' {
    $file = New-File 'paths-rejected-source.txt'
    $outside = Write-InputFile 'paths-outside-source.txt' 'outside source'
    $hash = File-Digest $file
    $recoveryCount = @([IO.Directory]::EnumerateDirectories($script:Recovery)).Count
    $fixtures = @(
        @{ Name = 'empty'; Json = '[]' }, @{ Name = 'object'; Json = '{}' }, @{ Name = 'null'; Json = 'null' },
        @{ Name = 'nonstring'; Json = '[1]' }, @{ Name = 'null-entry'; Json = '[null]' }, @{ Name = 'malformed'; Json = '["unterminated' },
        @{ Name = 'relative'; Json = (ConvertTo-Json -InputObject @($file, 'relative.txt') -Compress) },
        @{ Name = 'device'; Json = (ConvertTo-Json -InputObject @($file, ('\\.\' + $file)) -Compress) },
        @{ Name = 'duplicate'; Json = (ConvertTo-Json -InputObject @($file, $file) -Compress) },
        @{ Name = 'recovery'; Json = (ConvertTo-Json -InputObject @($file, (Join-Path $script:Recovery 'protected-input.txt')) -Compress) },
        @{ Name = 'over-count'; Json = (ConvertTo-Json -InputObject @(1..257 | ForEach-Object { $file }) -Compress) }
    )
    foreach ($fixture in $fixtures) {
        $inputFile = Write-InputFile ('paths-reject-' + $fixture.Name + '.json') $fixture.Json
        Assert-Rejected @('delete', '--paths-file', $inputFile) $file
        Assert-True ((File-Digest $file) -ceq $hash) ('Source changed for ' + $fixture.Name)
    }
    $invalidUtf8 = Join-Path $outputRoot 'paths-invalid-utf8.json'; [IO.File]::WriteAllBytes($invalidUtf8, [byte[]](0x5b, 0x22, 0xc3, 0x28, 0x22, 0x5d))
    Assert-Rejected @('delete', '--paths-file', $invalidUtf8) $file
    $oversized = Write-InputFile 'paths-oversized.json' (' ' * (1024 * 1024 + 1))
    Assert-Rejected @('delete', '--paths-file', $oversized) $file
    $validInput = Write-PathsFile 'paths-argument-validation.json' @($file)
    foreach ($arguments in @(
        @('delete', '--paths-file', $validInput, '--', $file),
        @('delete', '--paths-file', $validInput, '--paths-file', $validInput),
        @('delete', '--dry-run', '--dry-run', '--paths-file', $validInput),
        @('delete', '--paths-file')
    )) { Assert-Rejected $arguments $file }
    Assert-True ((File-Digest $file) -ceq $hash -and [IO.File]::ReadAllText($outside) -ceq 'outside source') 'Invalid input changed sources.'
    Assert-True (@([IO.Directory]::EnumerateDirectories($script:Recovery)).Count -eq $recoveryCount) 'Rejected paths input created recovery operations.'
}
Test-Case 'paths-file rejects ADS hardlinks and link ancestors without deleting source' {
    $file = New-File 'paths-input-safety-source.txt'
    $adsInput = Write-PathsFile 'paths-ads-input.json' @($file); [IO.File]::WriteAllText($adsInput + ':custom', 'input ADS')
    Assert-Rejected @('delete', '--paths-file', $adsInput) $file
    Assert-True ([IO.File]::ReadAllText($adsInput + ':custom') -ceq 'input ADS') 'Input ADS changed.'
    $linkedInput = Write-PathsFile 'paths-hardlink-input.json' @($file)
    $null = New-Item -ItemType HardLink -Path (Join-Path $outputRoot 'paths-hardlink-alias.json') -Target $linkedInput
    Assert-Rejected @('delete', '--paths-file', $linkedInput) $file
    $inputRoot = Join-Path $outputRoot 'paths-input-root'; $null = New-Item -ItemType Directory -Path $inputRoot
    $realInput = Join-Path $inputRoot 'input.json'; [IO.File]::WriteAllText($realInput, (ConvertTo-Json -InputObject @($file) -Compress))
    $aliasRoot = Join-Path $outputRoot 'paths-input-junction'; $null = New-Item -ItemType Junction -Path $aliasRoot -Target $inputRoot
    Assert-Rejected @('delete', '--paths-file', (Join-Path $aliasRoot 'input.json')) $file
}
Test-Case 'paths-file input handle closes before deleting that same input file' {
    $inputFile = Join-Path $script:Scope 'self-listed-input.json'
    [IO.File]::WriteAllText($inputFile, (ConvertTo-Json -InputObject @($inputFile) -Compress), [Text.UTF8Encoding]::new($false))
    $hash = File-Digest $inputFile
    $deleted = Invoke-Prunlet @('delete', '--paths-file', $inputFile)
    Assert-True ($deleted.ExitCode -eq 0 -and ![IO.File]::Exists($inputFile)) 'Paths input remained locked during deletion.'
    $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0 -and (File-Digest $inputFile) -ceq $hash) 'Self-listed input did not restore.'
}
Test-Case 'long path existing and missing dry runs differ and real delete restores bytes and timestamp' {
    $directory = $script:Scope
    foreach ($index in 1..8) { $directory = Join-Path $directory ('long-' + $index + '-' + ('x' * 64)); $null = New-Item -ItemType Directory -Path $directory }
    $file = Join-Path $directory '長い path.txt'; [IO.File]::WriteAllText($file, 'long path recovery bytes', [Text.UTF8Encoding]::new($false))
    Assert-True ($file.Length -gt 260) 'Long path fixture did not exceed MAX_PATH.'
    Assert-True ($file.Length -gt 512) 'Long path fixture did not exercise handle-path buffer expansion.'
    $hash = File-Digest $file; $time = [IO.File]::GetLastWriteTimeUtc($file)
    $recoveryCount = @([IO.Directory]::EnumerateDirectories($script:Recovery)).Count
    $dry = Invoke-Prunlet @('delete', '--dry-run', '--', $file)
    $missing = Invoke-Prunlet @('delete', '--dry-run', '--', (Join-Path $directory 'missing.txt'))
    Assert-True ($dry.ExitCode -eq 0 -and $dry.Json.items[0].status -eq 'would_delete' -and $missing.ExitCode -eq 0 -and $missing.Json.items[0].status -eq 'already_absent') 'Long-path existence was misclassified.'
    Assert-True ((File-Digest $file) -ceq $hash -and @([IO.Directory]::EnumerateDirectories($script:Recovery)).Count -eq $recoveryCount) 'Long-path dry run changed source or recovery.'
    $deleted = Invoke-Prunlet @('delete', '--', $file)
    Assert-True ($deleted.ExitCode -eq 0 -and $deleted.Json.items[0].status -eq 'deleted' -and ![IO.File]::Exists($file)) 'Long-path deletion failed.'
    $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0 -and (File-Digest $file) -ceq $hash -and [IO.File]::GetLastWriteTimeUtc($file) -eq $time) 'Long-path recovery differs.'
}
Test-Case 'literal brackets remain literal' {
    $file = New-File '[literal].txt'
    $result = Invoke-Prunlet @('delete', '--', $file)
    Assert-True ($result.ExitCode -eq 0 -and ![IO.File]::Exists($file)) 'Literal brackets were rejected.'
}
Test-Case 'dry run never changes source or backup' {
    $file = New-File 'dry.txt'
    $before = @(Get-ChildItem -LiteralPath $script:Recovery -Force).Count
    $result = Invoke-Prunlet @('delete', '--dry-run', '--', $file)
    Assert-True ($result.ExitCode -eq 0 -and [IO.File]::Exists($file)) 'Dry run changed source.'
    Assert-True (@(Get-ChildItem -LiteralPath $script:Recovery -Force).Count -eq $before) 'Dry run created backup.'
}
Test-Case 'missing and repeated deletion are explicit no-ops' {
    $file = Join-Path $script:Scope 'missing.txt'
    $result = Invoke-Prunlet @('delete', '--', $file)
    Assert-True ($result.ExitCode -eq 0 -and $result.Json.items[0].status -eq 'already_absent') 'Missing status differs.'
}
Test-Case 'multi-file deletion' {
    $one = New-File 'batch1.txt'; $two = New-File 'batch2.txt'
    $result = Invoke-Prunlet @('delete', '--', $one, $two)
    Assert-True ($result.ExitCode -eq 0 -and ![IO.File]::Exists($one) -and ![IO.File]::Exists($two) -and $result.Json.items.Count -eq 2) 'Batch failed.'
}
Test-Case 'files outside former root delete and restore without registration' {
    $file = New-File 'preflight.txt'
    $outside = Join-Path $outputRoot 'outside.txt'; [IO.File]::WriteAllText($outside, 'outside')
    $hash = File-Digest $file
    $result = Invoke-Prunlet @('delete', '--', $file, $outside)
    Assert-True ($result.ExitCode -eq 0 -and ![IO.File]::Exists($file) -and ![IO.File]::Exists($outside)) 'Local targets still depend on registered roots.'
    $restored = Invoke-Prunlet @('restore', $result.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0 -and (File-Digest $file) -ceq $hash -and [IO.File]::ReadAllText($outside) -eq 'outside') 'Unrestricted restore differs.'
}
Test-Case 'recovery directory targets reject the whole preflight batch' {
    $file = New-File 'recovery-preflight-source.txt'
    $protected = Join-Path $script:Recovery 'protected-source.txt'
    [IO.File]::WriteAllText($protected, 'keep recovery data')
    Assert-Rejected @('delete', '--', $file, $protected) $file
    Assert-True ([IO.File]::ReadAllText($protected) -eq 'keep recovery data') 'Recovery directory source changed.'
}
Test-Case 'relative path rejected' { Assert-Rejected @('delete', '--', 'relative.txt') '' }
# パス表記で拒否・誤判定する失敗を先に列挙する: slash/extended拒否、実体重複、復元先侵入、旧記録書換え、短縮名への復元。
Test-Case 'slash and extended local targets preserve bytes time and physical recovery paths' {
    foreach ($format in @('slash', 'extended')) {
        $file = New-File ('canonical-' + $format + '.txt') 'canonical target bytes'
        $hash = File-Digest $file; $time = [IO.File]::GetLastWriteTimeUtc($file)
        $argument = if ($format -eq 'slash') { $file.Replace('\', '/') } else { '\\?\' + $file }
        $dry = Invoke-Prunlet @('delete', '--dry-run', '--', $argument)
        Assert-True ($dry.ExitCode -eq 0 -and $dry.Json.items[0].status -eq 'would_delete') 'Ordinary path spelling was refused.'
        $deleted = Invoke-Prunlet @('delete', '--', $argument)
        Assert-True ($deleted.ExitCode -eq 0 -and ![IO.File]::Exists($file) -and $deleted.Json.items[0].path -ceq $file) 'Target was not recorded using its physical path.'
        $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
        Assert-True ($restored.ExitCode -eq 0 -and (File-Digest $file) -ceq $hash -and [IO.File]::GetLastWriteTimeUtc($file) -eq $time) 'Canonical-path recovery differs.'
        $missing = Invoke-Prunlet @('delete', '--dry-run', '--', (($file + '.missing').Replace('\', '/')))
        Assert-True ($missing.ExitCode -eq 0 -and $missing.Json.items[0].status -eq 'already_absent') 'Missing target was not resolved through its physical parent.'
    }
}
Test-Case 'equivalent target spellings cannot duplicate files or enter recovery storage' {
    $file = New-File 'canonical-duplicate.txt'
    $hash = File-Digest $file
    $count = @([IO.Directory]::EnumerateDirectories($script:Recovery)).Count
    $inputFile = Write-PathsFile 'canonical-duplicates.json' @($file, ('\\?\' + $file))
    Assert-Rejected @('delete', '--paths-file', $inputFile) $file
    $protected = Join-Path $script:Recovery 'canonical-protected.txt'
    [IO.File]::WriteAllText($protected, 'keep physical recovery bytes')
    foreach ($alias in @($protected.Replace('\', '/'), ('\\?\' + $protected))) {
        Assert-Rejected @('delete', '--', $alias) $protected
    }
    Assert-True ((File-Digest $file) -ceq $hash -and [IO.File]::ReadAllText($protected) -eq 'keep physical recovery bytes' -and @([IO.Directory]::EnumerateDirectories($script:Recovery)).Count -eq $count) 'Canonical preflight changed bytes or operation count.'
}
Test-Case 'paths-file spelling and backup spelling resolve without changing source data' {
    $configPath = Join-Path $outputRoot 'canonical-config.json'
    $init = Invoke-ProcessJson $ExecutablePath @('--config', $configPath, 'init', '--backup-directory', ('\\?\' + $script:Recovery))
    Assert-True ($init.ExitCode -eq 0 -and $init.Json.backupDirectory -ceq $script:Recovery) 'Init did not store the physical backup path.'
    foreach ($format in @('slash', 'extended')) {
        $file = New-File ('canonical-input-' + $format + '.txt') 'input canonical bytes'
        $hash = File-Digest $file
        $inputFile = Write-PathsFile ('canonical-input-' + $format + '.json') @($file)
        $inputAlias = if ($format -eq 'slash') { $inputFile.Replace('\', '/') } else { '\\?\' + $inputFile }
        $deleted = Invoke-ProcessJson $ExecutablePath @('--config', $configPath, 'delete', '--paths-file', $inputAlias)
        Assert-True ($deleted.ExitCode -eq 0 -and ![IO.File]::Exists($file)) 'Paths-file spelling failed.'
        $restored = Invoke-ProcessJson $ExecutablePath @('--config', $configPath, 'restore', $deleted.Json.operationId)
        Assert-True ($restored.ExitCode -eq 0 -and (File-Digest $file) -ceq $hash) 'Paths-file canonical recovery differs.'
    }
}
Test-Case 'legacy schema 1 target spelling remains unchanged during physical restore and purge' {
    $file = New-File 'legacy-canonical-target.txt' 'legacy target bytes'
    $hash = File-Digest $file
    $deleted = Invoke-Prunlet @('delete', '--', $file)
    Assert-True ($deleted.ExitCode -eq 0) 'Legacy fixture deletion failed.'
    $manifestPath = Join-Path $script:Recovery ($deleted.Json.operationId + '\manifest.json')
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 30
    $manifest.items[0].path = $file.Substring(0, 1).ToLowerInvariant() + $file.Substring(1)
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 30))
    $manifestHash = File-Digest $manifestPath
    $deleteResultPath = Join-Path $script:Recovery ($deleted.Json.operationId + '\delete-result.json')
    $deleteResult = Get-Content -LiteralPath $deleteResultPath -Raw | ConvertFrom-Json -Depth 30
    $deleteResult.items[0].path = $manifest.items[0].path
    [IO.File]::WriteAllText($deleteResultPath, ($deleteResult | ConvertTo-Json -Depth 30))
    $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0 -and (File-Digest $file) -ceq $hash -and (File-Digest $manifestPath) -ceq $manifestHash) 'Legacy manifest was changed or restored incorrectly.'
    $purged = Invoke-Prunlet @('purge', $deleted.Json.operationId, '--apply')
    Assert-True ($purged.ExitCode -eq 0 -and (File-Digest $manifestPath) -ceq $manifestHash -and (File-Digest $file) -ceq $hash) 'Legacy physical purge changed source or manifest.'
}
Test-Case '8.3 parent spelling records and restores the physical long path' {
    $file = New-File 'short-alias-canonical-long-filename.txt' 'short name target bytes'
    $fso = New-Object -ComObject Scripting.FileSystemObject
    try { $shortDirectory = [string]$fso.GetFolder($script:Scope).ShortPath } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($fso) }
    Assert-True (!$shortDirectory.Equals($script:Scope, [StringComparison]::OrdinalIgnoreCase)) 'This volume does not provide an 8.3 parent fixture.'
    $alias = Join-Path $shortDirectory ([IO.Path]::GetFileName($file))
    $hash = File-Digest $file
    $deleted = Invoke-Prunlet @('delete', '--', $alias)
    Assert-True ($deleted.ExitCode -eq 0 -and ![IO.File]::Exists($file) -and $deleted.Json.items[0].path -ceq $file) 'Short-name target was refused or recorded as an alias.'
    $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0 -and (File-Digest $file) -ceq $hash) 'Short-name target did not restore to the long physical path.'
    $duplicates = Write-PathsFile 'short-name-duplicate.json' @($file, $alias)
    Assert-Rejected @('delete', '--paths-file', $duplicates) $file
    $fso = New-Object -ComObject Scripting.FileSystemObject
    try { $shortRecovery = [string]$fso.GetFolder($script:Recovery).ShortPath } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($fso) }
    $protected = Join-Path $script:Recovery 'short-name-protected.txt'; [IO.File]::WriteAllText($protected, 'keep short recovery')
    Assert-Rejected @('delete', '--', (Join-Path $shortRecovery 'short-name-protected.txt')) $protected
}
Test-Case 'wildcard rejected' { Assert-Rejected @('delete', '--', (Join-Path $script:Scope '*.txt')) '' }
Test-Case 'nonempty directory requires explicit recursive opt-in' {
    $tree = New-TreeFixture 'directory-no-recursive'
    $count = @([IO.Directory]::EnumerateDirectories($script:Recovery)).Count
    Assert-Rejected @('delete', '--', $tree.Root) ''
    Assert-TreeIntact $tree
    Assert-True (@([IO.Directory]::EnumerateDirectories($script:Recovery)).Count -eq $count) 'Missing recursive opt-in created a recovery operation.'
}
Test-Case 'empty directory delete and restore without recursive opt-in' {
    $root = Join-Path $script:Scope 'empty directory 日本語'; $null = New-Item -ItemType Directory -Path $root
    $deleted = Invoke-Prunlet @('delete', '--', $root)
    Assert-True ($deleted.ExitCode -eq 0 -and ![IO.Directory]::Exists($root)) 'Empty directory deletion failed.'
    $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0 -and [IO.Directory]::Exists($root) -and @([IO.Directory]::EnumerateFileSystemEntries($root)).Count -eq 0) 'Empty directory restoration failed.'
}
Test-Case 'recursive paths-file dry-run preserves tree and creates no recovery operation' {
    $tree = New-TreeFixture 'directory-dry-run'
    $inputFile = Write-PathsFile 'directory-dry-run.json' @($tree.Root)
    $count = @([IO.Directory]::EnumerateDirectories($script:Recovery)).Count
    $dry = Invoke-Prunlet @('delete', '--recursive', '--dry-run', '--paths-file', $inputFile)
    Assert-True ($dry.ExitCode -eq 0 -and $dry.Json.dryRun) 'Recursive dry-run failed.'
    Assert-TreeIntact $tree
    Assert-True (@([IO.Directory]::EnumerateDirectories($script:Recovery)).Count -eq $count) 'Recursive dry-run created a recovery operation.'
}
Test-Case 'recursive CLI flag ordering is equivalent and duplicate flags are rejected' {
    $tree = New-TreeFixture 'directory-cli-flags'
    $count = @([IO.Directory]::EnumerateDirectories($script:Recovery)).Count
    $first = Invoke-Prunlet @('delete', '--recursive', '--dry-run', '--', $tree.Root)
    $reverse = Invoke-Prunlet @('delete', '--dry-run', '--recursive', '--', $tree.Root)
    Assert-True ($first.ExitCode -eq 0 -and $reverse.ExitCode -eq 0 -and $first.Json.dryRun -and $reverse.Json.dryRun) 'CLI recursive flag order changed dry-run outcome.'
    Assert-True (($first.Json.items | ConvertTo-Json -Depth 20 -Compress) -ceq ($reverse.Json.items | ConvertTo-Json -Depth 20 -Compress)) 'CLI recursive flag order changed planned items.'
    foreach ($arguments in @(@('delete', '--recursive', '--recursive', '--', $tree.Root), @('delete', '--recursive', '--dry-run', '--dry-run', '--', $tree.Root))) {
        Assert-Rejected $arguments ''
    }
    Assert-TreeIntact $tree
    Assert-True (@([IO.Directory]::EnumerateDirectories($script:Recovery)).Count -eq $count) 'Flag validation or dry-run created recovery data.'
}
Test-Case 'recursive CLI deletion restores exact binary bytes and empty subdirectories' {
    $tree = New-TreeFixture 'directory-roundtrip'
    $deleted = Invoke-Prunlet @('delete', '--recursive', '--', $tree.Root)
    Assert-True ($deleted.ExitCode -eq 0 -and ![IO.Directory]::Exists($tree.Root)) 'Recursive tree deletion failed.'
    $operationRoot = Join-Path $script:Recovery $deleted.Json.operationId
    $manifest = [IO.File]::ReadAllText((Join-Path $operationRoot 'manifest.json')) | ConvertFrom-Json -Depth 30
    Assert-True ($manifest.schema -eq 2 -and @($manifest.items | Where-Object kind -eq 'directory').Count -eq 3 -and @($manifest.items | Where-Object kind -eq 'file').Count -eq 2) 'Directory manifest did not persist all tree entries.'
    Assert-True (@(Get-ChildItem -LiteralPath $operationRoot -Filter '*.bak').Count -eq 2) 'File recovery copies do not match tree files.'
    $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0) 'Recursive tree restoration failed.'
    Assert-TreeIntact $tree
}
Test-Case 'recursive deletion refuses overlapping roots before mutation' {
    $tree = New-TreeFixture 'directory-overlap'
    foreach ($paths in @(@($tree.Root, $tree.Files[0]), @($tree.Nested, $tree.Root))) {
        Assert-Rejected (@('delete', '--recursive', '--') + $paths) ''
        Assert-TreeIntact $tree
    }
}
Test-Case 'recursive deletion protects recovery directory and its ancestor' {
    $sentinel = Join-Path $script:Recovery 'directory-protection.txt'; [IO.File]::WriteAllText($sentinel, 'keep recovery')
    foreach ($root in @($script:Recovery, $outputRoot)) {
        Assert-Rejected @('delete', '--recursive', '--', $root) $sentinel
        Assert-True ([IO.File]::ReadAllText($sentinel) -ceq 'keep recovery' -and [IO.File]::Exists($script:Config)) 'Protected ancestor deletion changed recovery or config.'
    }
}
Test-Case 'nested locked file prevents deletion of every tree member' {
    $tree = New-TreeFixture 'directory-locked'
    $lock = [IO.File]::Open($tree.Files[1], [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Assert-Rejected @('delete', '--recursive', '--', $tree.Root) $tree.Files[0]
        Assert-True ([IO.File]::Exists($tree.Files[1]) -and [IO.Directory]::Exists($tree.Empty)) 'Locked tree was partially deleted.'
    } finally { $lock.Dispose() }
    Assert-TreeIntact $tree
}
Test-Case 'recursive junction deletion restores link without traversing external target' {
    $tree = New-TreeFixture 'directory-junction'
    $target = Join-Path $outputRoot 'directory-junction-target'; $null = New-Item -ItemType Directory -Path $target
    $file = Join-Path $target 'keep.txt'; [IO.File]::WriteAllText($file, 'external linked target')
    $link = Join-Path $tree.Nested 'link'; $null = New-Item -ItemType Junction -Path $link -Target $target
    $hash = File-Digest $file
    $deleted = Invoke-Prunlet @('delete', '--recursive', '--', $tree.Root)
    Assert-True ($deleted.ExitCode -eq 0 -and ![IO.Directory]::Exists($tree.Root)) 'Recursive junction deletion failed.'
    Assert-True ((File-Digest $file) -ceq $hash) 'Recursive traversal changed linked target.'
    $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0 -and ((Get-Item -LiteralPath $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Junction was not restored as a link.'
    Assert-TreeIntact $tree
    Assert-True ((File-Digest $file) -ceq $hash -and (File-Digest (Join-Path $link 'keep.txt')) -ceq $hash) 'Restored junction target differs.'
}
Test-Case 'recursive ADS and hardlink deletion restores bytes and preserves external names' {
    foreach ($kind in @('ads', 'hardlink')) {
        $tree = New-TreeFixture ('directory-' + $kind)
        if ($kind -eq 'ads') { [IO.File]::WriteAllText($tree.Files[1] + ':custom', 'keep ADS') }
        else { $alias = Join-Path $outputRoot 'directory-hardlink-alias.txt'; $null = New-Item -ItemType HardLink -Path $alias -Target $tree.Files[1] }
        $deleted = Invoke-Prunlet @('delete', '--recursive', '--', $tree.Root)
        Assert-True ($deleted.ExitCode -eq 0 -and ![IO.Directory]::Exists($tree.Root)) 'Special recursive deletion failed.'
        if ($kind -eq 'hardlink') { Assert-True ((File-Digest $alias) -ceq $tree.Hashes[1]) 'Deletion changed external hardlink bytes.' }
        $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
        Assert-True ($restored.ExitCode -eq 0) 'Special recursive restore failed.'
        Assert-TreeIntact $tree
        if ($kind -eq 'ads') { Assert-True ([IO.File]::ReadAllText($tree.Files[1] + ':custom') -ceq 'keep ADS') 'Nested ADS changed.' }
        else { Assert-True ((File-Digest $alias) -ceq $tree.Hashes[1]) 'Restore changed external hardlink bytes.' }
    }
}
Test-Case 'directory ADS roundtrip restores stream bytes and every tree member' {
    $tree = New-TreeFixture 'directory-own-ADS'
    [IO.File]::WriteAllText($tree.Nested + ':custom', 'keep directory ADS')
    $streamBytes = [byte[]](0, 255, 13, 10, 128, 42)
    [IO.File]::WriteAllBytes($tree.Root + ':binary', $streamBytes)
    $deleted = Invoke-Prunlet @('delete', '--recursive', '--', $tree.Root)
    Assert-True ($deleted.ExitCode -eq 0 -and ![IO.Directory]::Exists($tree.Root)) 'Directory ADS deletion failed.'
    $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0) 'Directory ADS restore failed.'
    Assert-TreeIntact $tree
    Assert-True ([IO.File]::ReadAllText($tree.Nested + ':custom') -ceq 'keep directory ADS') 'Directory ADS changed.'
    Assert-True ([Convert]::ToHexString([IO.File]::ReadAllBytes($tree.Root + ':binary')) -ceq [Convert]::ToHexString($streamBytes)) 'Root directory ADS bytes changed.'
    $operationRoot = Join-Path $script:Recovery $deleted.Json.operationId
    $manifestPath = Join-Path $operationRoot 'manifest.json'; $manifestHash = File-Digest $manifestPath
    $purged = Invoke-Prunlet @('purge', $deleted.Json.operationId, '--apply')
    Assert-True ($purged.ExitCode -eq 0 -and @([IO.Directory]::EnumerateFiles($operationRoot, '*.bak')).Count -eq 0 -and (File-Digest $manifestPath) -ceq $manifestHash) 'Special directory purge did not retain immutable manifest and remove copies.'
    Assert-TreeIntact $tree
    Assert-True ([IO.File]::ReadAllText($tree.Nested + ':custom') -ceq 'keep directory ADS' -and [Convert]::ToHexString([IO.File]::ReadAllBytes($tree.Root + ':binary')) -ceq [Convert]::ToHexString($streamBytes)) 'Special purge changed restored directory streams.'
}
Test-Case 'directory restore conflict never overwrites descendant file' {
    $tree = New-TreeFixture 'directory-restore-conflict'
    $deleted = Invoke-Prunlet @('delete', '--recursive', '--', $tree.Root)
    Assert-True ($deleted.ExitCode -eq 0 -and ![IO.Directory]::Exists($tree.Root)) 'Conflict fixture deletion failed.'
    $null = New-Item -ItemType Directory -Path $tree.Nested -Force
    [IO.File]::WriteAllText($tree.Files[1], 'new occupant')
    Assert-Rejected @('restore', $deleted.Json.operationId) $tree.Files[1]
    Assert-True ([IO.File]::ReadAllText($tree.Files[1]) -ceq 'new occupant') 'Directory restore overwrote existing file.'
    Assert-True ([IO.File]::Exists($tree.Files[0]) -and (File-Digest $tree.Files[0]) -ceq $tree.Hashes[0]) 'Unconflicted sibling did not restore.'
    $siblingHash = File-Digest $tree.Files[0]
    Move-Item -LiteralPath $tree.Files[1] -Destination (Join-Path $outputRoot 'directory-conflict-occupant.txt')
    $retried = Invoke-Prunlet @('restore', $deleted.Json.operationId)
    Assert-True ($retried.ExitCode -eq 1 -and @($retried.Json.items | Where-Object { $_.path -ceq $tree.Files[0] -and $_.status -eq 'conflict' }).Count -eq 1 -and @($retried.Json.items | Where-Object { $_.path -ceq $tree.Files[1] -and $_.status -eq 'restored' }).Count -eq 1) 'Retry did not recover the missing file while reporting the existing sibling conflict.'
    Assert-True ((File-Digest $tree.Files[0]) -ceq $siblingHash) 'Retry changed already-restored sibling bytes.'
    Assert-TreeIntact $tree
}
foreach ($kind in @('metadata', 'ancestor')) {
    Test-Case "directory restore refuses linked $kind" {
        $tree = New-TreeFixture ('directory-restore-link-' + $kind)
        $deleted = Invoke-Prunlet @('delete', '--recursive', '--', $tree.Root)
        Assert-True ($deleted.ExitCode -eq 0 -and ![IO.Directory]::Exists($tree.Root)) 'Linked restore fixture deletion failed.'
        if ($kind -eq 'metadata') {
            $manifest = Join-Path (Join-Path $script:Recovery $deleted.Json.operationId) 'manifest.json'
            $saved = Join-Path $outputRoot 'directory-linked-manifest.json'
            Move-Item -LiteralPath $manifest -Destination $saved
            New-SymbolicFixture $manifest $saved
        } else {
            $target = Join-Path $outputRoot 'directory-restore-linked-target'; $null = New-Item -ItemType Directory -Path $target
            $null = New-Item -ItemType Junction -Path $tree.Root -Target $target
        }
        Assert-Rejected @('restore', $deleted.Json.operationId) ''
        Assert-True (![IO.File]::Exists($tree.Files[0]) -and ![IO.File]::Exists($tree.Files[1])) 'Linked restore wrote source files.'
        if ($kind -eq 'ancestor') { Assert-True (@([IO.Directory]::EnumerateFileSystemEntries($target)).Count -eq 0) 'Restore wrote through linked ancestor.' }
    }
}
Test-Case 'empty deletion rejected' { Assert-Rejected @('delete', '--') '' }
Test-Case 'ADS path rejected' {
    $file = New-File 'ads-path.txt'; Assert-Rejected @('delete', '--', ($file + ':stream')) $file
}
Test-Case 'file ADS roundtrip restores named stream bytes' {
    $file = New-File 'ads-content.txt'; [IO.File]::WriteAllText($file + ':custom', 'preserve stream')
    $hash = File-Digest $file
    $bytes = [byte[]](0, 128, 255, 13, 10); [IO.File]::WriteAllBytes($file + ':binary', $bytes)
    $deleted = Invoke-Prunlet @('delete', '--', $file)
    Assert-True ($deleted.ExitCode -eq 0 -and ![IO.File]::Exists($file)) 'File ADS deletion failed.'
    if ($LegacyExecutablePath) {
        $operationRoot = Join-Path $script:Recovery $deleted.Json.operationId
        $manifestHash = File-Digest (Join-Path $operationRoot 'manifest.json')
        $backupHash = File-Digest (Join-Path $operationRoot '0000.bak')
        foreach ($command in @(@('restore', $deleted.Json.operationId), @('purge', $deleted.Json.operationId, '--apply'))) {
            $legacy = Invoke-ProcessJson $LegacyExecutablePath (@('--config', $script:Config) + $command)
            Assert-True ($legacy.ExitCode -ne 0 -and ![IO.File]::Exists($file) -and (File-Digest (Join-Path $operationRoot 'manifest.json')) -ceq $manifestHash -and (File-Digest (Join-Path $operationRoot '0000.bak')) -ceq $backupHash) 'Legacy executable mutated unsupported schema 3 operation.'
        }
    }
    $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0 -and (File-Digest $file) -ceq $hash) 'File ADS restore failed.'
    Assert-True ([IO.File]::ReadAllText($file + ':custom') -eq 'preserve stream') 'Alternate data stream changed.'
    Assert-True ([Convert]::ToHexString([IO.File]::ReadAllBytes($file + ':binary')) -ceq [Convert]::ToHexString($bytes)) 'File ADS binary bytes changed.'
}
foreach ($kind in @('file', 'directory')) {
Test-Case "$kind ADS trailing space and dot names remain distinct through delete restore and purge" {
    $target = if ($kind -eq 'file') { New-File 'ads-exact-file.txt' 'unnamed content' } else {
        $tree = New-TreeFixture 'ads-exact-directory'; $tree.Root
    }
    $names = @('same', 'same ', 'same.', ' ', '.', '..', '$DATA', '日本😀 ')
    $streamPath = { param($name) '\\?\' + $target + ':' + $name + ':$DATA' }
    foreach ($name in $names) { [IO.File]::WriteAllText((& $streamPath $name), ('exact:' + $name), [Text.UTF8Encoding]::new($false)) }
    $arguments = @('delete'); if ($kind -eq 'directory') { $arguments += '--recursive' }
    $before = @([IO.Directory]::EnumerateDirectories($script:Recovery)).Count
    $dry = Invoke-Prunlet ($arguments + @('--dry-run', '--', $target))
    Assert-True ($dry.ExitCode -eq 0 -and (Test-Path -LiteralPath $target) -and @([IO.Directory]::EnumerateDirectories($script:Recovery)).Count -eq $before) 'Exact stream dry-run mutated data.'
    $deleted = Invoke-Prunlet ($arguments + @('--', $target))
    Assert-True ($deleted.ExitCode -eq 0 -and !(Test-Path -LiteralPath $target)) 'Exact stream deletion failed.'
    $operationRoot = Join-Path $script:Recovery $deleted.Json.operationId
    $manifestPath = Join-Path $operationRoot 'manifest.json'
    $manifestHash = File-Digest $manifestPath
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -Depth 40
    $entry = $manifest.items | Where-Object path -CEQ $target
    $savedNames = @($entry.streams | Where-Object name -CNE '' | ForEach-Object name)
    Assert-True ($savedNames.Count -eq $names.Count) 'Exact stream manifest count differs.'
    foreach ($name in $names) { Assert-True ($savedNames -ccontains $name) 'Exact stream manifest name changed.' }
    $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0) 'Exact stream restore failed.'
    if ($kind -eq 'directory') { Assert-TreeIntact $tree } else { Assert-True ([IO.File]::ReadAllText($target) -ceq 'unnamed content') 'Unnamed stream changed.' }
    foreach ($name in $names) { Assert-True ([IO.File]::ReadAllText((& $streamPath $name)) -ceq ('exact:' + $name)) 'Distinct stream bytes changed.' }
    [IO.File]::WriteAllText((& $streamPath 'same '), 'existing conflict')
    $conflict = Invoke-Prunlet @('restore', $deleted.Json.operationId)
    Assert-True ($conflict.ExitCode -eq 1 -and [IO.File]::ReadAllText((& $streamPath 'same ')) -ceq 'existing conflict' -and [IO.File]::ReadAllText((& $streamPath 'same')) -ceq 'exact:same') 'Restore overwrote an exact stream conflict.'
    foreach ($apply in @($false, $true, $true)) {
        $purgeArgs = @('purge', $deleted.Json.operationId); if ($apply) { $purgeArgs += '--apply' }
        $purged = Invoke-Prunlet $purgeArgs
        Assert-True ($purged.ExitCode -eq 0 -and @($purged.Json.warnings).Count -eq 0 -and (File-Digest $manifestPath) -ceq $manifestHash) 'Exact stream purge failed or changed manifest.'
    }
    foreach ($name in $names) { Assert-True ([IO.File]::ReadAllText((& $streamPath $name)) -ceq $(if ($name -ceq 'same ') { 'existing conflict' } else { 'exact:' + $name })) 'Purge changed restored streams.' }
}
}
Test-Case 'locked source is preserved' {
    $file = New-File 'locked.txt'; $lock = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Assert-Rejected @('delete', '--', $file) $file } finally { $lock.Dispose() }
}
Test-Case 'special source dry run and locked batch preserve every source' {
    $file = New-File 'special-preflight.txt' 'special source'
    [IO.File]::WriteAllText($file + ':custom', 'stream source')
    $locked = New-File 'special-preflight-locked.txt' 'locked source'
    $before = @([IO.Directory]::EnumerateDirectories($script:Recovery)).Count
    $dry = Invoke-Prunlet @('delete', '--dry-run', '--', $file)
    Assert-True ($dry.ExitCode -eq 0 -and [IO.File]::ReadAllText($file + ':custom') -ceq 'stream source' -and @([IO.Directory]::EnumerateDirectories($script:Recovery)).Count -eq $before) 'Special dry run mutated source or recovery.'
    $lock = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Assert-Rejected @('delete', '--', $file, $locked) $file } finally { $lock.Dispose() }
    Assert-True ([IO.File]::ReadAllText($file) -ceq 'special source' -and [IO.File]::ReadAllText($file + ':custom') -ceq 'stream source') 'Special preflight partially deleted a source.'
}
Test-Case 'special backup corruption rejects whole restore and purge before mutation' {
    $first = New-File 'special-corrupt-first.txt' 'first source'
    $second = New-File 'special-corrupt-second.txt' 'second source'
    [IO.File]::WriteAllText($second + ':custom', 'second stream')
    $deleted = Invoke-Prunlet @('delete', '--', $first, $second)
    Assert-True ($deleted.ExitCode -eq 0) 'Special corruption fixture deletion failed.'
    $root = Join-Path $script:Recovery $deleted.Json.operationId
    $manifest = [IO.File]::ReadAllText((Join-Path $root 'manifest.json')) | ConvertFrom-Json -Depth 40
    Assert-True ($manifest.schema -eq 3) 'Special operation did not use schema 3.'
    $backups = @([IO.Directory]::EnumerateFiles($root) | Where-Object { [IO.Path]::GetExtension($_) -in @('.bak', '.bin') } | Sort-Object)
    Assert-True ($backups.Count -eq 2) 'Special recovery copy count differs.'
    $bytes = [IO.File]::ReadAllBytes($backups[1]); $bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 1
    [IO.File]::WriteAllBytes($backups[1], $bytes)
    $hashes = @($backups | ForEach-Object { File-Digest $_ })
    Assert-Rejected @('restore', $deleted.Json.operationId) ''
    Assert-True (![IO.File]::Exists($first) -and ![IO.File]::Exists($second)) 'Restore wrote an earlier source before detecting corrupt special copy.'
    Assert-Rejected @('purge', $deleted.Json.operationId, '--apply') ''
    for ($index = 0; $index -lt $backups.Count; $index++) { Assert-True ((File-Digest $backups[$index]) -ceq $hashes[$index]) 'Purge deleted an earlier copy before detecting corrupt special copy.' }
    Assert-True (![IO.File]::Exists((Join-Path $root 'purge-intent.json'))) 'Corrupt special purge wrote an intent.'
}
Test-Case 'special manifest stream metadata rejects malicious names bounds and overlapping slices' {
    foreach ($kind in @('stream-name', 'stream-overlap', 'stream-size', 'stream-hash', 'unexpected-kind')) {
        $first = New-File ("special-manifest-$kind-first.txt") 'first bytes'
        $second = New-File ("special-manifest-$kind-second.txt") 'second bytes'
        [IO.File]::WriteAllText($second + ':custom', 'stream bytes')
        $deleted = Invoke-Prunlet @('delete', '--', $first, $second)
        Assert-True ($deleted.ExitCode -eq 0) 'Special manifest fixture deletion failed.'
        $root = Join-Path $script:Recovery $deleted.Json.operationId
        $path = Join-Path $root 'manifest.json'
        $manifest = [IO.File]::ReadAllText($path) | ConvertFrom-Json -Depth 40
        $entry = $manifest.items[1]
        switch ($kind) {
            'stream-name' { $entry.streams[1].name = '..\escape' }
            'stream-overlap' { $entry.streams[1].offset = 0 }
            'stream-size' { $entry.streams[1].size = [long]::MaxValue }
            'stream-hash' { $entry.streams[1].sha256 = ('0' * 64) }
            'unexpected-kind' { $entry.kind = 'unknown-link' }
        }
        [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        $backups = @([IO.Directory]::EnumerateFiles($root) | Where-Object { [IO.Path]::GetExtension($_) -in @('.bak', '.bin') } | Sort-Object)
        Assert-True ($backups.Count -eq 2) 'Special manifest recovery copy count differs.'
        $hashes = @($backups | ForEach-Object { File-Digest $_ })
        Assert-Rejected @('restore', $deleted.Json.operationId) '' $kind
        Assert-True (![IO.File]::Exists($first) -and ![IO.File]::Exists($second)) "Invalid stream manifest partially restored source ($kind)."
        Assert-Rejected @('purge', $deleted.Json.operationId, '--apply') '' $kind
        for ($index = 0; $index -lt $backups.Count; $index++) { Assert-True ((File-Digest $backups[$index]) -ceq $hashes[$index]) 'Invalid stream manifest changed recovery copy.' }
    }
}
Test-Case 'schema 3 required entry and stream keys cannot silently default during restore or purge' {
    foreach ($field in @('kind', 'treeRoot', 'caseSensitive', 'reparseTag', 'linkDirectory', 'streams', 'stream.name', 'stream.offset', 'stream.size', 'stream.sha256')) {
        $file = New-File ("required-$($field.Replace('.', '-')).txt") 'required metadata source'
        [IO.File]::WriteAllText($file + ':custom', 'required stream bytes')
        $deleted = Invoke-Prunlet @('delete', '--', $file)
        Assert-True ($deleted.ExitCode -eq 0) 'Required metadata fixture deletion failed.'
        $root = Join-Path $script:Recovery $deleted.Json.operationId; $path = Join-Path $root 'manifest.json'
        $manifest = [IO.File]::ReadAllText($path) | ConvertFrom-Json -Depth 40
        Assert-True ($manifest.schema -eq 3) 'Required metadata fixture must use schema 3.'
        if ($field.StartsWith('stream.')) { $manifest.items[0].streams[1].PSObject.Properties.Remove($field.Substring(7)) }
        else { $manifest.items[0].PSObject.Properties.Remove($field) }
        [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        $backup = Join-Path $root '0000.bak'; $hash = File-Digest $backup
        Assert-Rejected @('restore', $deleted.Json.operationId) '' $field
        Assert-True (![IO.File]::Exists($file)) "Missing required key restored source ($field)."
        Assert-Rejected @('purge', $deleted.Json.operationId, '--apply') '' $field
        Assert-True ((File-Digest $backup) -ceq $hash -and ![IO.File]::Exists((Join-Path $root 'purge-intent.json'))) "Missing required key purged source ($field)."
    }
}
Test-Case 'missing true directory caseSensitive key is rejected before child restoration' {
    $root = Join-Path $script:Scope 'case-missing-key'; $null = New-Item -ItemType Directory -Path $root
    Enable-CaseSensitiveFixture $root
    $upper = Join-Path $root 'Foo'; $lower = Join-Path $root 'foo'
    [IO.File]::WriteAllText($upper, 'upper'); [IO.File]::WriteAllText($lower, 'lower')
    $deleted = Invoke-Prunlet @('delete', '--recursive', '--', $root)
    Assert-True ($deleted.ExitCode -eq 0) 'Case-sensitive required key fixture deletion failed.'
    $operationRoot = Join-Path $script:Recovery $deleted.Json.operationId; $path = Join-Path $operationRoot 'manifest.json'
    $manifest = [IO.File]::ReadAllText($path) | ConvertFrom-Json -Depth 40
    $entry = @($manifest.items | Where-Object { $_.path -ceq $root })[0]
    Assert-True ($entry.caseSensitive) 'Fixture did not record true case-sensitive metadata.'
    $entry.PSObject.Properties.Remove('caseSensitive')
    [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
    $copies = @([IO.Directory]::EnumerateFiles($operationRoot, '*.bak')); $hashes = @($copies | ForEach-Object { File-Digest $_ })
    Assert-Rejected @('restore', $deleted.Json.operationId) '' 'missing true caseSensitive'
    Assert-True (![IO.Directory]::Exists($root)) 'Missing caseSensitive flag created an insensitive parent.'
    Assert-Rejected @('purge', $deleted.Json.operationId, '--apply') '' 'missing true caseSensitive'
    for ($index = 0; $index -lt $copies.Count; $index++) { Assert-True ((File-Digest $copies[$index]) -ceq $hashes[$index]) 'Missing caseSensitive metadata changed recovery copy.' }
}
Test-Case 'case-sensitive existing ancestor preserves two paths-file leaf names and parent flag' {
    $root = Join-Path $script:Scope 'case-leaf-batch'; $null = New-Item -ItemType Directory -Path $root
    Enable-CaseSensitiveFixture $root
    $upper = Join-Path $root 'Foo'; $lower = Join-Path $root 'foo'
    [IO.File]::WriteAllText($upper, 'upper leaf'); [IO.File]::WriteAllText($lower, 'lower leaf')
    $inputPath = Write-PathsFile 'case-leaf-paths.json' @($upper, $lower)
    $deleted = Invoke-Prunlet @('delete', '--paths-file', $inputPath)
    Assert-True ($deleted.ExitCode -eq 0 -and ![IO.File]::Exists($upper) -and ![IO.File]::Exists($lower) -and [IO.Directory]::Exists($root)) 'Case-sensitive leaf batch deletion differs.'
    $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0 -and [IO.File]::ReadAllText($upper) -ceq 'upper leaf' -and [IO.File]::ReadAllText($lower) -ceq 'lower leaf') ('Case-sensitive leaf restore differs: ' + ($restored.Json | ConvertTo-Json -Depth 30 -Compress))
    # 復元された既存の二名に加え、新しい大小名も区別できることを確認する。
    [IO.File]::WriteAllText((Join-Path $root 'Probe'), 'upper probe'); [IO.File]::WriteAllText((Join-Path $root 'probe'), 'lower probe')
    Assert-True ([IO.File]::ReadAllText((Join-Path $root 'Probe')) -ceq 'upper probe' -and [IO.File]::ReadAllText((Join-Path $root 'probe')) -ceq 'lower probe') 'Existing parent case-sensitive flag changed.'
}
Test-Case 'case-sensitive operation storage rejects restore and purge without mutation' {
    $file = New-File 'case-operation-storage.txt' 'storage boundary source'
    [IO.File]::WriteAllText($file + ':custom', 'storage boundary stream')
    $deleted = Invoke-Prunlet @('delete', '--', $file)
    Assert-True ($deleted.ExitCode -eq 0) 'Case-sensitive operation fixture deletion failed.'
    $root = Join-Path $script:Recovery $deleted.Json.operationId
    Enable-CaseSensitiveOperationFixture $root
    $backup = Join-Path $root '0000.bak'; $hash = File-Digest $backup
    $manifest = Join-Path $root 'manifest.json'; $manifestHash = File-Digest $manifest
    Assert-Rejected @('restore', $deleted.Json.operationId) '' 'case-sensitive operation storage'
    Assert-Rejected @('purge', $deleted.Json.operationId, '--apply') '' 'case-sensitive operation storage'
    Assert-True (![IO.File]::Exists($file) -and (File-Digest $backup) -ceq $hash -and (File-Digest $manifest) -ceq $manifestHash -and ![IO.File]::Exists((Join-Path $root 'purge-intent.json'))) 'Case-sensitive storage rejection changed source or recovery.'
}
Test-Case 'symbolic link roundtrip preserves target content' {
    $target = New-File 'link-target.txt'; $link = Join-Path $script:Scope 'link.txt'
    New-SymbolicFixture $link $target
    $hash = File-Digest $target
    $deleted = Invoke-Prunlet @('delete', '--', $link)
    Assert-True ($deleted.ExitCode -eq 0 -and ![IO.File]::Exists($link) -and (File-Digest $target) -ceq $hash) 'Symbolic link deletion changed target.'
    $restored = Restore-SymbolicFixture $deleted.Json.operationId $link $target $hash
    Assert-True ($restored.ExitCode -eq 0) ('Symbolic link restore failed: ' + ($restored.Json | ConvertTo-Json -Depth 30 -Compress) + '; stderr=' + $restored.Stderr)
    Assert-True (((Get-Item -LiteralPath $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -and (File-Digest $link) -ceq $hash -and (File-Digest $target) -ceq $hash) 'Symbolic link restore changed target or link type.'
}
Test-Case 'directory symbolic link roundtrip never traverses target' {
    $targetRoot = Join-Path $outputRoot 'directory-symbolic-target'; $null = New-Item -ItemType Directory -Path $targetRoot
    $target = Join-Path $targetRoot 'keep.txt'; [IO.File]::WriteAllText($target, 'directory symbolic target')
    $link = Join-Path $script:Scope 'directory-symbolic-link'
    New-SymbolicFixture $link $targetRoot
    $hash = File-Digest $target
    $deleted = Invoke-Prunlet @('delete', '--recursive', '--', $link)
    Assert-True ($deleted.ExitCode -eq 0 -and ![IO.Directory]::Exists($link) -and (File-Digest $target) -ceq $hash) 'Directory symbolic deletion traversed target.'
    $restored = Restore-SymbolicFixture $deleted.Json.operationId $link $target $hash
    Assert-True ($restored.ExitCode -eq 0) ('Directory symbolic restore failed: ' + ($restored.Json | ConvertTo-Json -Depth 30 -Compress) + '; stderr=' + $restored.Stderr)
    Assert-True (((Get-Item -LiteralPath $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -and (File-Digest (Join-Path $link 'keep.txt')) -ceq $hash -and (File-Digest $target) -ceq $hash) 'Directory symbolic restore differs.'
    $purged = Invoke-Prunlet @('purge', $deleted.Json.operationId, '--apply')
    Assert-True ($purged.ExitCode -eq 0 -and ![IO.File]::Exists((Join-Path (Join-Path $script:Recovery $deleted.Json.operationId) '0000.bak')) -and (File-Digest $target) -ceq $hash -and ((Get-Item -LiteralPath $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Reparse purge changed link or target.'
}
Test-Case 'hardlink selected names restore independent copies without changing external name' {
    $source = New-File 'hardlink-selected-a.txt' 'shared original'
    $selected = Join-Path $script:Scope 'hardlink-selected-b.txt'; $external = Join-Path $outputRoot 'hardlink-external.txt'
    $null = New-Item -ItemType HardLink -Path $selected -Target $source
    $null = New-Item -ItemType HardLink -Path $external -Target $source
    $hash = File-Digest $external
    $deleted = Invoke-Prunlet @('delete', '--', $source, $selected)
    Assert-True ($deleted.ExitCode -eq 0 -and ![IO.File]::Exists($source) -and ![IO.File]::Exists($selected) -and (File-Digest $external) -ceq $hash) 'Hardlink deletion changed external name.'
    $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0 -and (File-Digest $source) -ceq $hash -and (File-Digest $selected) -ceq $hash -and (File-Digest $external) -ceq $hash) 'Hardlink restoration bytes differ.'
    [IO.File]::WriteAllText($source, 'independent restored content')
    Assert-True ((File-Digest $selected) -ceq $hash -and (File-Digest $external) -ceq $hash) 'Restored copy unexpectedly shares external file identity.'
}
Test-Case 'special link manifest rejects unsupported tags and kind mismatch before restoring files' {
    foreach ($kind in @('tag', 'kind')) {
        $target = New-File ("special-link-manifest-$kind-target.txt") 'external target'
        $first = New-File ("special-link-manifest-$kind-first.txt") 'first bytes'
        $link = Join-Path $script:Scope ("special-link-manifest-$kind-link.txt")
        New-SymbolicFixture $link $target
        $targetHash = File-Digest $target
        $deleted = Invoke-Prunlet @('delete', '--', $first, $link)
        Assert-True ($deleted.ExitCode -eq 0) 'Special link manifest fixture deletion failed.'
        $root = Join-Path $script:Recovery $deleted.Json.operationId; $path = Join-Path $root 'manifest.json'
        $manifest = [IO.File]::ReadAllText($path) | ConvertFrom-Json -Depth 40
        if ($kind -eq 'tag') { $manifest.items[1].reparseTag = 1 } else { $manifest.items[1].kind = 'junction' }
        [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        Assert-Rejected @('restore', $deleted.Json.operationId) ''
        Assert-True (![IO.File]::Exists($first) -and ![IO.File]::Exists($link) -and (File-Digest $target) -ceq $targetHash) 'Invalid reparse manifest partially restored or changed target.'
        Assert-Rejected @('purge', $deleted.Json.operationId, '--apply') ''
        Assert-True ([IO.File]::Exists((Join-Path $root '0000.bak')) -and [IO.File]::Exists((Join-Path $root '0001.bak'))) 'Invalid reparse purge removed copies.'
    }
}
Test-Case 'reparse payload invalid offsets reject restore and purge even when whole-copy hash matches' {
    $target = New-File 'reparse-offset-target.txt' 'external reparse target'
    $first = New-File 'reparse-offset-first.txt' 'first source'
    $link = Join-Path $script:Scope 'reparse-offset-link.txt'; New-SymbolicFixture $link $target
    $targetHash = File-Digest $target
    $deleted = Invoke-Prunlet @('delete', '--', $first, $link)
    Assert-True ($deleted.ExitCode -eq 0) 'Reparse payload fixture deletion failed.'
    $root = Join-Path $script:Recovery $deleted.Json.operationId; $path = Join-Path $root 'manifest.json'
    $manifest = [IO.File]::ReadAllText($path) | ConvertFrom-Json -Depth 40
    $backup = Join-Path $root '0001.bak'; $bytes = [IO.File]::ReadAllBytes($backup)
    Assert-True ($bytes.Length -gt 20 -and $manifest.items[1].kind -eq 'symlink') 'Reparse fixture payload differs.'
    # SYMLINK_REPARSE_BUFFERのSubstituteNameOffsetを範囲外へ変更する。
    $bytes[8] = 255; $bytes[9] = 255; [IO.File]::WriteAllBytes($backup, $bytes)
    $manifest.items[1].sha256 = File-Digest $backup
    [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
    $firstBackup = Join-Path $root '0000.bak'; $firstHash = File-Digest $firstBackup; $invalidHash = File-Digest $backup
    Assert-Rejected @('restore', $deleted.Json.operationId) '' 'invalid raw reparse offset with matching copy hash'
    Assert-Rejected @('purge', $deleted.Json.operationId, '--apply') '' 'invalid raw reparse offset with matching copy hash'
    Assert-True (![IO.File]::Exists($first) -and ![IO.File]::Exists($link) -and (File-Digest $target) -ceq $targetHash -and (File-Digest $firstBackup) -ceq $firstHash -and (File-Digest $backup) -ceq $invalidHash -and ![IO.File]::Exists((Join-Path $root 'purge-intent.json'))) 'Invalid reparse payload changed sources target or recovery.'
}
Test-Case 'junction ancestor rejected without changing target' {
    $targetRoot = Join-Path $outputRoot 'junction-target'; $null = New-Item -ItemType Directory -Path $targetRoot
    $target = Join-Path $targetRoot 'target.txt'; [IO.File]::WriteAllText($target, 'junction fixture')
    $link = Join-Path $script:Scope 'junction'; $null = New-Item -ItemType Junction -Path $link -Target $targetRoot
    Assert-Rejected @('delete', '--', (Join-Path $link 'target.txt')) $target
}
Test-Case 'case-sensitive directory roundtrip preserves distinct Foo and foo names' {
    $caseRoot = Join-Path $script:Scope 'case-sensitive'; $null = New-Item -ItemType Directory -Path $caseRoot
    Enable-CaseSensitiveFixture $caseRoot
    $upper = Join-Path $caseRoot 'Foo'; $lower = Join-Path $caseRoot 'foo'
    [IO.File]::WriteAllText($upper, 'uppercase data'); [IO.File]::WriteAllText($lower, 'lowercase data')
    Assert-True ([IO.File]::ReadAllText($upper) -ceq 'uppercase data') 'Case-sensitive fixture did not distinguish names.'
    $deleted = Invoke-Prunlet @('delete', '--recursive', '--', $caseRoot)
    Assert-True ($deleted.ExitCode -eq 0 -and ![IO.Directory]::Exists($caseRoot)) 'Case-sensitive directory deletion failed.'
    $restored = Invoke-Prunlet @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0 -and [IO.File]::ReadAllText($upper) -ceq 'uppercase data' -and [IO.File]::ReadAllText($lower) -ceq 'lowercase data') 'Case-sensitive distinct names were not restored.'
}
Test-Case 'restore conflict never overwrites' {
    $file = New-File 'conflict.txt' 'original'
    $result = Invoke-Prunlet @('delete', '--', $file)
    [IO.File]::WriteAllText($file, 'new file')
    Assert-Rejected @('restore', $result.Json.operationId) $file
    Assert-True ([IO.File]::ReadAllText($file) -eq 'new file') 'Restore overwrote existing source.'
}
Test-Case 'corrupted recovery copy cannot restore' {
    $file = New-File 'corrupt.txt'; $result = Invoke-Prunlet @('delete', '--', $file)
    $operationRoot = Join-Path $script:Recovery $result.Json.operationId
    $copy = Get-ChildItem -LiteralPath $operationRoot -Filter '*.bak' | Select-Object -First 1
    Assert-True ($null -ne $copy) 'Recovery copy not found.'
    [IO.File]::WriteAllText($copy.FullName, 'tampered')
    Assert-Rejected @('restore', $result.Json.operationId) ''
    Assert-True (![IO.File]::Exists($file)) 'Corrupted content restored.'
}
Test-Case 'restore operation traversal rejected' { Assert-Rejected @('restore', '..\scope') '' }
Test-Case 'duplicate deletion paths rejected before mutation' {
    $file = New-File 'duplicate.txt'; Assert-Rejected @('delete', '--', $file, $file) $file
}
Test-Case 'read-only source failure preserves original' {
    $file = New-File 'read-only.txt'; [IO.File]::SetAttributes($file, [IO.FileAttributes]::ReadOnly)
    try { Assert-Rejected @('delete', '--', $file) $file }
    finally { [IO.File]::SetAttributes($file, [IO.FileAttributes]::Normal) }
}
Test-Case 'manifest recovery-directory target rejected before restore' {
    $file = New-File 'manifest-tamper.txt'; $result = Invoke-Prunlet @('delete', '--', $file)
    $manifestPath = Join-Path (Join-Path $script:Recovery $result.Json.operationId) 'manifest.json'
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -Depth 20
    $outside = Join-Path $script:Recovery 'never-restore-inside-recovery.txt'
    $manifest.items[0].path = $outside
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 20))
    Assert-Rejected @('restore', $result.Json.operationId) ''
    Assert-True (![IO.File]::Exists($outside)) 'Manifest tamper wrote into recovery storage.'
}
Test-Case 'operations lists recorded ids' {
    $file = New-File 'operation-list.txt'
    $deleted = Invoke-Prunlet @('delete', '--', $file)
    Assert-True ($deleted.ExitCode -eq 0) 'Operation list fixture deletion failed.'
    $result = Invoke-Prunlet @('operations')
    Assert-True ($result.ExitCode -eq 0 -and @($result.Json.operations | Where-Object operationId -CEQ $deleted.Json.operationId).Count -eq 1) 'Recorded operation was not listed.'
}

Test-Case 'purge defaults to read-only inspection and apply keeps metadata with idempotent outcome' {
    $fixture = New-PurgeFixture 'purge-complete' 2
    $pending = Join-Path $script:Recovery ('purge-pending-' + $fixture.Id + '-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($pending, '{"operationId":'); $pendingHash = File-Digest $pending
    $members = @([IO.Directory]::EnumerateFileSystemEntries($fixture.Root) | Sort-Object)
    $backupDigests = @{}; foreach ($backup in $fixture.Backups) { $backupDigests[$backup] = File-Digest $backup }
    $manifestPath = Join-Path $fixture.Root 'manifest.json'; $manifestHash = File-Digest $manifestPath
    foreach ($arguments in @(@('purge', $fixture.Id), @('purge', $fixture.Id, '--dry-run'))) {
        $dry = Invoke-Prunlet $arguments
        Assert-True ($dry.ExitCode -eq 0 -and $dry.Json.dryRun -and @($dry.Json.items | Where-Object status -eq 'would_purge').Count -eq 2) 'Purge inspection status differs.'
        Assert-True (($members -join '|') -ceq (@([IO.Directory]::EnumerateFileSystemEntries($fixture.Root) | Sort-Object) -join '|')) 'Purge inspection wrote files.'
        foreach ($backup in $fixture.Backups) { Assert-True ((File-Digest $backup) -ceq $backupDigests[$backup]) 'Purge inspection changed recovery bytes.' }
    }
    $applied = Invoke-Prunlet @('purge', $fixture.Id, '--apply')
    Assert-True ($applied.ExitCode -eq 0 -and !$applied.Json.dryRun -and $applied.Json.purgedBytes -gt 0 -and @($applied.Json.items | Where-Object status -eq 'purged').Count -eq 2) 'Purge apply failed.'
    foreach ($backup in $fixture.Backups) { Assert-True (![IO.File]::Exists($backup)) 'Purge left a recovery copy.' }
    foreach ($name in @('manifest.json', 'operation.lock', 'delete-result.json', 'purge-intent.json')) { Assert-True ([IO.File]::Exists((Join-Path $fixture.Root $name))) 'Purge removed retained metadata.' }
    Assert-True ((File-Digest $manifestPath) -ceq $manifestHash) 'Purge changed manifest.'
    $intent = [IO.File]::ReadAllText((Join-Path $fixture.Root 'purge-intent.json')) | ConvertFrom-Json -Depth 20
    Assert-True ($intent.operationId -ceq $fixture.Id -and $intent.manifestSha256 -ceq $manifestHash -and $intent.targets.Count -eq 2) 'Persisted purge intent differs.'
    $intentHash = File-Digest (Join-Path $fixture.Root 'purge-intent.json')
    $publishedHashes = @{}
    foreach ($record in [IO.Directory]::EnumerateFiles($fixture.Root, 'purge-result-*.json')) {
        $outcome = [IO.File]::ReadAllText($record) | ConvertFrom-Json -Depth 20
        Assert-True ($outcome.operationId -ceq $fixture.Id -and !$outcome.dryRun -and $outcome.items.Count -eq 2) 'Published purge result is not complete JSON.'
        $publishedHashes[$record] = File-Digest $record
    }
    Assert-True ($publishedHashes.Count -eq 1) 'First purge did not publish one complete result.'
    $again = Invoke-Prunlet @('purge', $fixture.Id, '--apply')
    Assert-True ($again.ExitCode -eq 0 -and $again.Json.purgedBytes -eq 0 -and @($again.Json.items | Where-Object status -eq 'already_purged').Count -eq 2) 'Repeated purge was not idempotent.'
    Assert-True ((File-Digest (Join-Path $fixture.Root 'purge-intent.json')) -ceq $intentHash -and (File-Digest $pending) -ceq $pendingHash) 'Purge replaced intent or touched unpublished outside metadata.'
    foreach ($record in $publishedHashes.Keys) { Assert-True ((File-Digest $record) -ceq $publishedHashes[$record]) 'Purge overwrote an existing published result.' }
    $restored = Invoke-Prunlet @('restore', $fixture.Id)
    Assert-True ($restored.ExitCode -ne 0 -and $restored.Json.error -match 'purge') 'Purged operation was reported as restored.'
    foreach ($file in $fixture.Files) { Assert-True (![IO.File]::Exists($file)) 'Purged content was restored.' }
}
Test-Case 'purge resumes a simulated partial on-disk state using persisted matching intent' {
    $fixture = New-PurgeFixture 'purge-resume' 2
    $pending = Join-Path $script:Recovery ('purge-pending-' + $fixture.Id + '-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($pending, '{"items":['); $pendingHash = File-Digest $pending
    $first = Invoke-Prunlet @('purge', $fixture.Id, '--apply')
    Assert-True ($first.ExitCode -eq 0) 'Resume fixture could not create real persisted intent.'
    $intentHash = File-Digest (Join-Path $fixture.Root 'purge-intent.json')
    # 強制終了を使わず、実際の意図記録を残したまま検証済みコピー一個が残る状態を再現する。
    [IO.File]::WriteAllText($fixture.Backups[1], $fixture.Contents[1], [Text.UTF8Encoding]::new($false))
    $inspection = Invoke-Prunlet @('purge', $fixture.Id)
    Assert-True ($inspection.ExitCode -eq 0 -and $inspection.Json.items[0].status -eq 'already_purged' -and $inspection.Json.items[1].status -eq 'would_purge' -and [IO.File]::Exists($fixture.Backups[1])) 'Partial state inspection differs.'
    $continued = Invoke-Prunlet @('purge', $fixture.Id, '--apply')
    Assert-True ($continued.ExitCode -eq 0 -and $continued.Json.items[0].status -eq 'already_purged' -and $continued.Json.items[1].status -eq 'purged' -and ![IO.File]::Exists($fixture.Backups[1])) 'Matching purge intent did not resume safely.'
    Assert-True ((File-Digest (Join-Path $fixture.Root 'purge-intent.json')) -ceq $intentHash) 'Resume changed immutable intent.'
    Assert-True ((File-Digest $pending) -ceq $pendingHash) 'Resume touched unpublished outside metadata.'
}
Test-Case 'purge rejects recovery hash tamper before writing intent' {
    $fixture = New-PurgeFixture 'purge-hash-tamper'
    $bytes = [IO.File]::ReadAllBytes($fixture.Backups[0]); $bytes[0] = $bytes[0] -bxor 1
    [IO.File]::WriteAllBytes($fixture.Backups[0], $bytes)
    Assert-PurgeRejected $fixture
}
Test-Case 'purge preflights every target handle before deleting any recovery copy' {
    $fixture = New-PurgeFixture 'purge-target-locked' 2
    $hashes = @($fixture.Backups | ForEach-Object { File-Digest $_ })
    $lock = [IO.File]::Open($fixture.Backups[1], [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $result = Invoke-Prunlet @('purge', $fixture.Id, '--apply')
        Assert-True ($result.ExitCode -ne 0 -and [IO.File]::Exists($fixture.Backups[0]) -and ![IO.File]::Exists((Join-Path $fixture.Root 'purge-intent.json'))) 'Locked later target caused partial preflight deletion.'
    } finally { $lock.Dispose() }
    for ($index = 0; $index -lt 2; $index++) { Assert-True ((File-Digest $fixture.Backups[$index]) -ceq $hashes[$index]) 'Locked batch changed recovery bytes.' }
}
Test-Case 'purge rejects manifest path tamper before changing backups' {
    $fixture = New-PurgeFixture 'purge-manifest-tamper'
    $manifestPath = Join-Path $fixture.Root 'manifest.json'
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -Depth 20
    $manifest.items[0].path = Join-Path $script:Recovery 'inside-purge-manifest.txt'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 20))
    Assert-PurgeRejected $fixture
}
Test-Case 'purge rejects unknown files child directories and malformed known metadata' {
    foreach ($kind in @('foreign-file', 'child-directory', 'malformed-metadata')) {
        $fixture = New-PurgeFixture ('purge-' + $kind)
        switch ($kind) {
            'foreign-file' { [IO.File]::WriteAllText((Join-Path $fixture.Root 'foreign.txt'), 'foreign bytes') }
            'child-directory' { $null = New-Item -ItemType Directory -Path (Join-Path $fixture.Root 'child') }
            'malformed-metadata' { [IO.File]::WriteAllText((Join-Path $fixture.Root ('restore-result-' + [guid]::NewGuid().ToString('N') + '.json')), '{}') }
        }
        Assert-PurgeRejected $fixture
        if ($kind -eq 'foreign-file') { Assert-True ([IO.File]::ReadAllText((Join-Path $fixture.Root 'foreign.txt')) -ceq 'foreign bytes') 'Foreign file changed.' }
    }
}
Test-Case 'purge rejects backup hardlinks and ADS without touching bytes' {
    foreach ($kind in @('hardlink', 'ADS')) {
        $fixture = New-PurgeFixture ('purge-target-' + $kind)
        if ($kind -eq 'hardlink') { $null = New-Item -ItemType HardLink -Path (Join-Path $outputRoot 'purge-backup-hardlink.bak') -Target $fixture.Backups[0] }
        else { [IO.File]::WriteAllText($fixture.Backups[0] + ':custom', 'backup ADS') }
        Assert-PurgeRejected $fixture
        if ($kind -eq 'ADS') { Assert-True ([IO.File]::ReadAllText($fixture.Backups[0] + ':custom') -ceq 'backup ADS') 'Backup ADS changed.' }
    }
}
Test-Case 'purge rejects a symbolic backup and leaves its displaced verified copy intact' {
    $fixture = New-PurgeFixture 'purge-backup-link'
    $saved = Join-Path $outputRoot 'saved-symbolic-backup.bak'; [IO.File]::Move($fixture.Backups[0], $saved)
    New-SymbolicFixture $fixture.Backups[0] $saved
    $hash = File-Digest $saved
    Assert-PurgeRejected $fixture
    Assert-True ((File-Digest $saved) -ceq $hash) 'Symbolic backup target changed.'
}
Test-Case 'purge rejects metadata ADS before modifying recovery copies' {
    $fixture = New-PurgeFixture 'purge-metadata-ADS'
    $manifestPath = Join-Path $fixture.Root 'manifest.json'; [IO.File]::WriteAllText($manifestPath + ':custom', 'manifest ADS')
    Assert-PurgeRejected $fixture
    Assert-True ([IO.File]::ReadAllText($manifestPath + ':custom') -ceq 'manifest ADS') 'Metadata ADS changed.'
}
Test-Case 'purge rejects operation directory link without following it for deletion' {
    $fixture = New-PurgeFixture 'purge-operation-link'
    $saved = Join-Path $outputRoot 'saved-operation-for-link'; [IO.Directory]::Move($fixture.Root, $saved)
    $null = New-Item -ItemType Junction -Path $fixture.Root -Target $saved
    $backup = Join-Path $saved '0000.bak'; $hash = File-Digest $backup
    $result = Invoke-Prunlet @('purge', $fixture.Id, '--apply')
    Assert-True ($result.ExitCode -ne 0 -and (File-Digest $backup) -ceq $hash -and ![IO.File]::Exists((Join-Path $saved 'purge-intent.json'))) 'Purge followed operation link.'
}
foreach ($partialSchema in 1..3) {
    foreach ($partialState in @('failed', 'already_absent')) {
        Test-Case "schema $partialSchema $partialState partial copies purge explicitly without restoring or changing manifest" {
            $fixture = New-PartialPurgeFixture $partialSchema $partialState
            $manifestPath = Join-Path $fixture.Root 'manifest.json'; $manifestHash = File-Digest $manifestPath
            $hashes = @($fixture.Backups | ForEach-Object { File-Digest $_ })
            $restored = Invoke-Prunlet @('restore', $fixture.Id)
            Assert-True (@($restored.Json.items | Select-Object -First 2 | Where-Object status -eq 'not_backed_up').Count -eq 2) 'Partial copy was offered for restore.'
            $members = @([IO.Directory]::EnumerateFileSystemEntries($fixture.Root) | Sort-Object)
            $dry = Invoke-Prunlet @('purge', $fixture.Id, '--dry-run')
            Assert-True ($dry.ExitCode -eq 0 -and @($dry.Json.items | Where-Object status -eq 'would_purge').Count -eq 3) 'Partial inspection failed.'
            Assert-True (($members -join '|') -ceq (@([IO.Directory]::EnumerateFileSystemEntries($fixture.Root) | Sort-Object) -join '|')) 'Partial inspection wrote metadata.'
            foreach ($index in 0..2) { Assert-True ((File-Digest $fixture.Backups[$index]) -ceq $hashes[$index]) 'Partial inspection changed bytes.' }
            $applied = Invoke-Prunlet @('purge', $fixture.Id, '--apply')
            Assert-True ($applied.ExitCode -eq 0 -and @($applied.Json.items | Where-Object status -eq 'purged').Count -eq 3) 'Partial apply failed.'
            $intent = [IO.File]::ReadAllText((Join-Path $fixture.Root 'purge-intent.json')) | ConvertFrom-Json -Depth 20
            Assert-True ($intent.schema -eq 2 -and $intent.targets.Count -eq 1 -and $intent.incompleteTargets.Count -eq 2) 'Partial intent schema or membership differs.'
            foreach ($index in 0..1) {
                $target = @($intent.incompleteTargets | Where-Object index -eq $index)
                Assert-True ($target.Count -eq 1 -and $target[0].sha256 -ceq $hashes[$index] -and $target[0].size -eq @(0, 13)[$index]) 'Partial intent did not record actual size/hash.'
            }
            foreach ($backup in $fixture.Backups) { Assert-True (![IO.File]::Exists($backup)) 'Partial apply retained a recovery copy.' }
            $again = Invoke-Prunlet @('purge', $fixture.Id, '--apply')
            Assert-True ($again.ExitCode -eq 0 -and $again.Json.purgedBytes -eq 0 -and @($again.Json.items | Where-Object status -eq 'already_purged').Count -eq 3) 'Partial apply was not idempotent.'
            Assert-Rejected @('restore', $fixture.Id) ''
            Assert-True ((File-Digest $manifestPath) -ceq $manifestHash) 'Partial purge rewrote manifest.'
            foreach ($index in 0..2) { Assert-True ([IO.File]::ReadAllText($fixture.Files[$index]) -ceq "original $index") 'Partial operation changed original source.' }
        }
    }
}
Test-Case 'partial purge resumes persisted intent and accepts only matching surviving bytes' {
    $fixture = New-PartialPurgeFixture
    Write-PartialPurgeIntent $fixture
    $displaced = Join-Path $outputRoot 'partial-purge-interrupted-0000.bak'
    [IO.File]::Move($fixture.Backups[0], $displaced)
    $intentHash = File-Digest (Join-Path $fixture.Root 'purge-intent.json')
    $result = Invoke-Prunlet @('purge', $fixture.Id, '--apply')
    Assert-True ($result.ExitCode -eq 0 -and $result.Json.items[0].status -eq 'already_purged' -and $result.Json.items[1].status -eq 'purged') 'Partial purge did not resume.'
    Assert-True ((File-Digest (Join-Path $fixture.Root 'purge-intent.json')) -ceq $intentHash -and [IO.File]::Exists($displaced)) 'Resume rewrote intent or touched displaced fixture.'
    foreach ($kind in @('same-size', 'different-size')) {
        $fixture = New-PartialPurgeFixture
        Write-PartialPurgeIntent $fixture
        [IO.File]::WriteAllText($fixture.Backups[1], $(if ($kind -eq 'same-size') { 'PARTIAL BYTES' } else { 'changed size' }))
        Assert-PurgeRejected $fixture
    }
}
Test-Case 'partial purge rejects unsafe members and never downgrades a corrupt verified backup' {
    foreach ($kind in @('unknown', 'out-of-range', 'directory', 'hardlink', 'ADS', 'link', 'verified-corrupt')) {
        $fixture = New-PartialPurgeFixture
        switch ($kind) {
            'unknown' { [IO.File]::WriteAllText((Join-Path $fixture.Root 'partial.tmp'), 'unknown') }
            'out-of-range' { [IO.File]::WriteAllText((Join-Path $fixture.Root '0003.bak'), 'outside index') }
            'directory' {
                $saved = Join-Path $outputRoot ('partial-directory-displaced-' + $fixture.Id)
                [IO.File]::Move($fixture.Backups[1], $saved)
                $null = [IO.Directory]::CreateDirectory($fixture.Backups[1])
                $fixture.Backups = @($fixture.Backups[0], $fixture.Backups[2])
            }
            'hardlink' { $null = New-Item -ItemType HardLink -Path (Join-Path $outputRoot ('partial-alias-' + $fixture.Id)) -Target $fixture.Backups[1] }
            'ADS' { [IO.File]::WriteAllText($fixture.Backups[1] + ':unexpected', 'ADS') }
            'link' {
                $saved = Join-Path $outputRoot ('partial-displaced-' + $fixture.Id)
                [IO.File]::Move($fixture.Backups[1], $saved)
                New-SymbolicFixture $fixture.Backups[1] $saved
            }
            'verified-corrupt' { [IO.File]::WriteAllText($fixture.Backups[2], 'corrupt verified recovery bytes') }
        }
        Assert-PurgeRejected $fixture
    }
}
Test-Case 'streaming manifest accepts 64 KiB whitespace after a colon without mutation' {
    $fixture = New-PurgeFixture 'metadata-whitespace'
    $manifestPath = Join-Path $fixture.Root 'manifest.json'
    $text = [IO.File]::ReadAllText($manifestPath)
    $text = $text.Insert($text.IndexOf(':') + 1, (' ' * 64KB))
    [IO.File]::WriteAllText($manifestPath, $text, [Text.UTF8Encoding]::new($false))
    $manifestHash = File-Digest $manifestPath; $backupHash = File-Digest $fixture.Backups[0]
    $members = @([IO.Directory]::EnumerateFileSystemEntries($fixture.Root) | Sort-Object)
    $dry = Invoke-Prunlet @('purge', $fixture.Id, '--dry-run')
    Assert-True ($dry.ExitCode -eq 0 -and $dry.Json.items[0].status -eq 'would_purge') 'Valid whitespace spanning reader buffers was rejected.'
    Assert-True ((File-Digest $manifestPath) -ceq $manifestHash -and (File-Digest $fixture.Backups[0]) -ceq $backupHash) 'Whitespace inspection changed fixture bytes.'
    Assert-True (($members -join '|') -ceq (@([IO.Directory]::EnumerateFileSystemEntries($fixture.Root) | Sort-Object) -join '|')) 'Whitespace inspection wrote metadata.'
}
Test-Case 'streaming result accepts large UTF8 escaped error and warning strings across reader buffers' {
    $fixture = New-PurgeFixture 'metadata-large-message'
    $resultPath = Join-Path $fixture.Root 'delete-result.json'
    $result = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json -AsHashtable -Depth 20
    $longText = ('日本語 "quoted" \ path' + "`n`t") * 3000
    Assert-True ($longText.Length -gt 16KB -and $longText.Length -lt 1MB) 'Message fixture is outside the intended valid range.'
    $result.items[0].error = $longText
    $result.warnings = @($longText)
    [IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
    $resultHash = File-Digest $resultPath; $backupHash = File-Digest $fixture.Backups[0]
    $dry = Invoke-Prunlet @('purge', $fixture.Id, '--dry-run')
    Assert-True ($dry.ExitCode -eq 0 -and $dry.Json.items[0].status -eq 'would_purge') 'Valid long UTF8/escaped result messages were rejected.'
    Assert-True ((File-Digest $resultPath) -ceq $resultHash -and (File-Digest $fixture.Backups[0]) -ceq $backupHash -and ![IO.File]::Exists((Join-Path $fixture.Root 'purge-intent.json'))) 'Long-message inspection changed fixture bytes or wrote intent.'
}
foreach ($partialKind in @('directory', 'symlink', 'junction')) {
    Test-Case "schema 3 failed $partialKind partial copy purges without touching original target" {
        $fixture = New-PartialPurgeFixture 3
        $manifestPath = Join-Path $fixture.Root 'manifest.json'
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -AsHashtable -Depth 20
        $entry = $manifest.items[0]
        $entry.kind = $partialKind
        if ($partialKind -eq 'directory') { $entry.treeRoot = $entry.path }
        elseif ($partialKind -eq 'symlink') { $entry.reparseTag = [Convert]::ToUInt32('A000000C', 16) }
        else { $entry.reparseTag = [Convert]::ToUInt32('A0000003', 16); $entry.linkDirectory = $true }
        # failed記録は実体のkindへアクセスせず、manifestに紐づく途中コピーだけを扱う。
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        $manifestHash = File-Digest $manifestPath
        $sourceHashes = @($fixture.Files | ForEach-Object { File-Digest $_ })
        $copyHashes = @($fixture.Backups | ForEach-Object { File-Digest $_ })
        $members = @([IO.Directory]::EnumerateFileSystemEntries($fixture.Root) | Sort-Object)
        $dry = Invoke-Prunlet @('purge', $fixture.Id, '--dry-run')
        Assert-True ($dry.ExitCode -eq 0 -and @($dry.Json.items | Where-Object status -eq 'would_purge').Count -eq 3) 'Non-file partial inspection failed.'
        Assert-True (($members -join '|') -ceq (@([IO.Directory]::EnumerateFileSystemEntries($fixture.Root) | Sort-Object) -join '|')) 'Non-file partial inspection wrote metadata.'
        foreach ($index in 0..2) { Assert-True ((File-Digest $fixture.Backups[$index]) -ceq $copyHashes[$index]) 'Non-file partial inspection changed recovery bytes.' }
        $applied = Invoke-Prunlet @('purge', $fixture.Id, '--apply')
        Assert-True ($applied.ExitCode -eq 0 -and @($applied.Json.items | Where-Object status -eq 'purged').Count -eq 3) 'Non-file partial apply failed.'
        $again = Invoke-Prunlet @('purge', $fixture.Id, '--apply')
        Assert-True ($again.ExitCode -eq 0 -and $again.Json.purgedBytes -eq 0 -and @($again.Json.items | Where-Object status -eq 'already_purged').Count -eq 3) 'Non-file partial repeat was not idempotent.'
        Assert-True ((File-Digest $manifestPath) -ceq $manifestHash) 'Non-file partial purge rewrote manifest.'
        foreach ($index in 0..2) {
            Assert-True (![IO.File]::Exists($fixture.Backups[$index]) -and (File-Digest $fixture.Files[$index]) -ceq $sourceHashes[$index]) 'Non-file partial purge retained recovery bytes or touched original target.'
        }
    }
}
foreach ($streamState in @('failed', 'backup_ready')) {
    Test-Case "schema 3 $streamState 1025 stream records preserve state-specific recovery contract" {
        $fixture = New-PartialPurgeFixture 3
        $manifestPath = Join-Path $fixture.Root 'manifest.json'
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -AsHashtable -Depth 20
        $emptyHash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
        if ($streamState -eq 'failed') {
            $entryIndex = 0; $offset = 0
            $streams = @(@{ name = ''; offset = 0; size = 0; sha256 = $emptyHash })
        } else {
            $entryIndex = 2; $offset = $manifest.items[2].size
            $streams = @($manifest.items[2].streams)
        }
        foreach ($index in 1..1024) { $streams += @{ name = "stream-$index"; offset = $offset; size = 0; sha256 = $emptyHash } }
        $manifest.items[$entryIndex].streams = $streams
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        $manifestHash = File-Digest $manifestPath
        if ($streamState -eq 'backup_ready') {
            Assert-PurgeRejected $fixture
        } else {
            $copyHashes = @($fixture.Backups | ForEach-Object { File-Digest $_ })
            $members = @([IO.Directory]::EnumerateFileSystemEntries($fixture.Root) | Sort-Object)
            $dry = Invoke-Prunlet @('purge', $fixture.Id, '--dry-run')
            Assert-True ($dry.ExitCode -eq 0 -and @($dry.Json.items | Where-Object status -eq 'would_purge').Count -eq 3) 'Failed capture with 1025 stream records was rejected.'
            Assert-True (($members -join '|') -ceq (@([IO.Directory]::EnumerateFileSystemEntries($fixture.Root) | Sort-Object) -join '|')) 'Failed stream inspection wrote metadata.'
            foreach ($index in 0..2) { Assert-True ((File-Digest $fixture.Backups[$index]) -ceq $copyHashes[$index]) 'Failed stream inspection changed recovery bytes.' }
            $applied = Invoke-Prunlet @('purge', $fixture.Id, '--apply')
            Assert-True ($applied.ExitCode -eq 0 -and @($applied.Json.items | Where-Object status -eq 'purged').Count -eq 3) 'Failed capture with 1025 stream records could not purge partial copies.'
            $again = Invoke-Prunlet @('purge', $fixture.Id, '--apply')
            Assert-True ($again.ExitCode -eq 0 -and $again.Json.purgedBytes -eq 0 -and @($again.Json.items | Where-Object status -eq 'already_purged').Count -eq 3) 'Failed stream partial repeat was not idempotent.'
            foreach ($backup in $fixture.Backups) { Assert-True (![IO.File]::Exists($backup)) 'Failed stream partial apply retained a recovery copy.' }
        }
        Assert-True ((File-Digest $manifestPath) -ceq $manifestHash) 'Stream-count validation changed manifest.'
        foreach ($index in 0..2) { Assert-True ([IO.File]::ReadAllText($fixture.Files[$index]) -ceq "original $index") 'Stream-count validation changed original source.' }
    }
}
Test-Case 'streaming metadata rejects duplicate missing truncated excessive depth and oversized tokens before mutation' {
    foreach ($kind in @('duplicate-root', 'duplicate-entry', 'missing-root', 'missing-entry', 'truncated', 'depth', 'oversized-path', 'oversized-token')) {
        $fixture = New-PartialPurgeFixture
        $manifestPath = Join-Path $fixture.Root 'manifest.json'
        $text = [IO.File]::ReadAllText($manifestPath)
        switch ($kind) {
            'duplicate-root' { $text = $text.Insert($text.IndexOf('{') + 1, '"schema":1,') }
            'duplicate-entry' { $text = $text -replace '("path"\s*:)', '"state":"failed",$1' }
            'missing-root' { $value = $text | ConvertFrom-Json -AsHashtable -Depth 20; $null = $value.Remove('createdUtc'); $text = $value | ConvertTo-Json -Depth 20 }
            'missing-entry' { $value = $text | ConvertFrom-Json -AsHashtable -Depth 20; $null = $value.items[0].Remove('state'); $text = $value | ConvertTo-Json -Depth 20 }
            'truncated' { $text = $text.Substring(0, $text.Length - 4) }
            'depth' { $text = '{"items":' + ('[' * 20) + '0' + (']' * 20) + '}' }
            'oversized-path' { $text = $text -replace '("path"\s*:\s*)"[^"]*"', ('$1"' + ('x' * 32769) + '"') }
            'oversized-token' { $text = '{"schema":1,"operationId":"' + ('x' * (2MB)) + '"}' }
        }
        [IO.File]::WriteAllText($manifestPath, $text, [Text.UTF8Encoding]::new($false))
        $hash = File-Digest $manifestPath
        Assert-PurgeRejected $fixture
        Assert-True ((File-Digest $manifestPath) -ceq $hash) 'Rejected streaming metadata was rewritten.'
        Assert-Rejected @('restore', $fixture.Id) ''
        foreach ($index in 0..2) { Assert-True ([IO.File]::ReadAllText($fixture.Files[$index]) -ceq "original $index") 'Malformed metadata changed original source.' }
    }
}
Test-Case 'partial purge rejects malformed incomplete intent membership and hashes' {
    foreach ($kind in @('missing', 'empty', 'duplicate', 'outside-index', 'verified-index', 'wrong-hash', 'wrong-size')) {
        $fixture = New-PartialPurgeFixture
        Write-PartialPurgeIntent $fixture
        $intentPath = Join-Path $fixture.Root 'purge-intent.json'
        $intent = [IO.File]::ReadAllText($intentPath) | ConvertFrom-Json -AsHashtable -Depth 20
        switch ($kind) {
            'missing' { $null = $intent.Remove('incompleteTargets') }
            'empty' { $intent.incompleteTargets = @() }
            'duplicate' { $intent.incompleteTargets = @($intent.incompleteTargets[0], $intent.incompleteTargets[0]) }
            'outside-index' { $intent.incompleteTargets[0].index = 3 }
            'verified-index' { $intent.incompleteTargets[0].index = 2 }
            'wrong-hash' { $intent.incompleteTargets[0].sha256 = '0' * 64 }
            'wrong-size' { $intent.incompleteTargets[0].size = 1 }
        }
        [IO.File]::WriteAllText($intentPath, ($intent | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        $hash = File-Digest $intentPath
        Assert-PurgeRejected $fixture
        Assert-True ((File-Digest $intentPath) -ceq $hash) 'Rejected partial intent was rewritten.'
    }
}
Test-Case 'legacy schema 1 purge intent resumes verified recovery without conversion' {
    $fixture = New-PurgeFixture 'purge-legacy-intent' 2
    $manifestPath = Join-Path $fixture.Root 'manifest.json'
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -Depth 20
    $targets = @(foreach ($index in 0..1) { @{ index = $index; sha256 = $manifest.items[$index].sha256; size = $manifest.items[$index].size } })
    $intent = @{ schema = 1; operationId = $fixture.Id; manifestSha256 = File-Digest $manifestPath; createdUtc = [DateTimeOffset]::UtcNow.ToString('O'); targets = $targets }
    $intentPath = Join-Path $fixture.Root 'purge-intent.json'
    [IO.File]::WriteAllText($intentPath, ($intent | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $intentHash = File-Digest $intentPath
    $displaced = Join-Path $outputRoot 'legacy-purge-interrupted-0000.bak'
    [IO.File]::Move($fixture.Backups[0], $displaced)
    $result = Invoke-Prunlet @('purge', $fixture.Id, '--apply')
    Assert-True ($result.ExitCode -eq 0 -and $result.Json.items[0].status -eq 'already_purged' -and $result.Json.items[1].status -eq 'purged') 'Legacy intent resume failed.'
    Assert-True ((File-Digest $intentPath) -ceq $intentHash -and [IO.File]::Exists($displaced)) 'Legacy intent was converted or displaced fixture changed.'
}
Test-Case 'purge rejects missing backup without intent and preserves displaced fixture copy' {
    $fixture = New-PurgeFixture 'purge-missing-backup'
    $saved = Join-Path $outputRoot 'displaced-purge-fixture.bak'; [IO.File]::Move($fixture.Backups[0], $saved)
    $hash = File-Digest $saved
    $result = Invoke-Prunlet @('purge', $fixture.Id, '--apply')
    Assert-True ($result.ExitCode -ne 0 -and (File-Digest $saved) -ceq $hash -and ![IO.File]::Exists((Join-Path $fixture.Root 'purge-intent.json'))) 'Missing backup was accepted without intent.'
}
Test-Case 'purge requires operation lock and rejects intent that does not match manifest' {
    $fixture = New-PurgeFixture 'purge-locked'
    $lock = [IO.File]::Open((Join-Path $fixture.Root 'operation.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Assert-PurgeRejected $fixture } finally { $lock.Dispose() }
    $fixture = New-PurgeFixture 'purge-intent-mismatch'
    $manifestPath = Join-Path $fixture.Root 'manifest.json'; $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -Depth 20
    $digest = File-Digest $manifestPath; $different = $(if ($digest[0] -eq '0') { '1' } else { '0' }) + $digest.Substring(1)
    $intent = @{ schema = 1; operationId = $fixture.Id; manifestSha256 = $different; createdUtc = [DateTimeOffset]::UtcNow.ToString('O'); targets = @(@{ index = 0; sha256 = $manifest.items[0].sha256; size = $manifest.items[0].size }) }
    $intentPath = Join-Path $fixture.Root 'purge-intent.json'
    [IO.File]::WriteAllText($intentPath, ($intent | ConvertTo-Json -Depth 20)); $intentHash = File-Digest $intentPath
    Assert-PurgeRejected $fixture
    Assert-True ((File-Digest $intentPath) -ceq $intentHash) 'Mismatching existing intent was overwritten.'
    Assert-Rejected @('restore', $fixture.Id) ''
}
Test-Case 'purge rejects operation traversal and ambiguous apply arguments' {
    Assert-Rejected @('purge', '..\scope', '--apply') ''
    Assert-Rejected @('purge', [guid]::NewGuid().ToString('N'), '--apply', '--dry-run') ''
}

Test-Case 'MCP real stdio lifecycle/delete/restore/validation' {
    $process = Start-ProcessInfo $ExecutablePath @('--config', $script:Config, 'mcp')
    try {
        $errTask = $process.StandardError.ReadToEndAsync()
        function Rpc([object]$Request) {
            $process.StandardInput.WriteLine(($Request | ConvertTo-Json -Depth 20 -Compress))
            $process.StandardInput.Flush()
            $read = $process.StandardOutput.ReadLineAsync()
            if (!$read.Wait(10000)) { throw 'MCP response timed out.' }
            if ($null -eq $read.Result) { throw 'MCP closed output unexpectedly.' }
            $response = $read.Result | ConvertFrom-Json -Depth 30
            Assert-True ($response.id -eq $Request.id) 'MCP response id differs.'
            return $response
        }
        $result = Rpc @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{protocolVersion = '2025-11-25'; capabilities = @{}; clientInfo = @{name = 'prunlet-e2e'; version = 'development'}} }
        Assert-True ($result.result.protocolVersion -eq '2025-11-25') 'Version negotiation failed.'
        $process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
        $tools = Rpc @{jsonrpc='2.0';id=2;method='tools/list';params=@{}}
        Assert-True ($tools.result.tools.Count -eq 3) 'MCP tools count differs.'
        $file = New-File '日本語 MCP.txt' 'MCP content'
        $exactStream = '\\?\' + $file + ':trailing :$DATA'
        [IO.File]::WriteAllText($exactStream, 'MCP trailing stream')
        # 削除notificationは副作用を起こさず、次のpingだけに応答する。
        $process.StandardInput.WriteLine((@{jsonrpc='2.0';method='tools/call';params=@{name='delete_files';arguments=@{paths=@($file)}}} | ConvertTo-Json -Depth 10 -Compress))
        $null = Rpc @{jsonrpc='2.0';id=3;method='ping'}
        Assert-True ([IO.File]::Exists($file)) 'MCP notification caused deletion.'
        $deleted = Rpc @{jsonrpc='2.0';id=4;method='tools/call';params=@{name='delete_files';arguments=@{paths=@($file)}}}
        Assert-True (!$deleted.result.isError -and ![IO.File]::Exists($file)) 'MCP delete failed.'
        $restored = Rpc @{jsonrpc='2.0';id=5;method='tools/call';params=@{name='restore_files';arguments=@{operationId=$deleted.result.structuredContent.operationId}}}
        Assert-True (!$restored.result.isError -and [IO.File]::ReadAllText($file) -eq 'MCP content') 'MCP restore failed.'
        Assert-True ([IO.File]::ReadAllText($exactStream) -ceq 'MCP trailing stream') 'MCP trailing stream changed.'
        $bad = Rpc @{jsonrpc='2.0';id=6;method='tools/call';params=@{name='delete_files';arguments=@{paths=@($file);dryRun='false'}}}
        Assert-True ($bad.error.code -eq -32602 -and [IO.File]::Exists($file)) 'Invalid arguments were not rejected.'
        $outside = Rpc @{jsonrpc='2.0';id=7;method='tools/call';params=@{name='delete_files';arguments=@{paths=@((Join-Path $outputRoot 'outside.txt'))}}}
        Assert-True (!$outside.result.isError -and ![IO.File]::Exists((Join-Path $outputRoot 'outside.txt'))) 'MCP still rejects local targets outside former roots.'
        $outsideRestored = Rpc @{jsonrpc='2.0';id=9;method='tools/call';params=@{name='restore_files';arguments=@{operationId=$outside.result.structuredContent.operationId}}}
        Assert-True (!$outsideRestored.result.isError -and [IO.File]::ReadAllText((Join-Path $outputRoot 'outside.txt')) -eq 'outside') 'MCP unrestricted restore differs.'
        $list = Rpc @{jsonrpc='2.0';id=8;method='tools/call';params=@{name='list_operations';arguments=@{}}}
        Assert-True (!$list.result.isError) 'MCP operations failed.'
        $deleteTool = $tools.result.tools | Where-Object name -eq 'delete_files'
        Assert-True ($deleteTool.inputSchema.properties.recursive.type -eq 'boolean') 'MCP recursive schema missing.'
        $tree = New-TreeFixture 'directory-MCP'
        $badRecursive = Rpc @{jsonrpc='2.0';id=10;method='tools/call';params=@{name='delete_files';arguments=@{paths=@($tree.Root);recursive='true'}}}
        Assert-True ($badRecursive.error.code -eq -32602) 'MCP accepted non-boolean recursive.'
        Assert-TreeIntact $tree
        $noRecursive = Rpc @{jsonrpc='2.0';id=11;method='tools/call';params=@{name='delete_files';arguments=@{paths=@($tree.Root)}}}
        Assert-True ($noRecursive.result.isError) 'MCP nonempty directory did not require opt-in.'
        Assert-TreeIntact $tree
        $beforeDry = @([IO.Directory]::EnumerateDirectories($script:Recovery)).Count
        $dryTree = Rpc @{jsonrpc='2.0';id=12;method='tools/call';params=@{name='delete_files';arguments=@{paths=@($tree.Root);recursive=$true;dryRun=$true}}}
        Assert-True (!$dryTree.result.isError -and $dryTree.result.structuredContent.dryRun) 'MCP recursive dry-run failed.'
        Assert-TreeIntact $tree
        Assert-True (@([IO.Directory]::EnumerateDirectories($script:Recovery)).Count -eq $beforeDry) 'MCP tree dry-run created recovery data.'
        $deletedTree = Rpc @{jsonrpc='2.0';id=13;method='tools/call';params=@{name='delete_files';arguments=@{paths=@($tree.Root);recursive=$true}}}
        Assert-True (!$deletedTree.result.isError -and ![IO.Directory]::Exists($tree.Root)) 'MCP recursive deletion failed.'
        $restoredTree = Rpc @{jsonrpc='2.0';id=14;method='tools/call';params=@{name='restore_files';arguments=@{operationId=$deletedTree.result.structuredContent.operationId}}}
        Assert-True (!$restoredTree.result.isError) 'MCP directory restoration failed.'
        Assert-TreeIntact $tree
        $process.StandardInput.Close()
        Assert-True ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'MCP did not stop on EOF.'
        Assert-True (!$errTask.GetAwaiter().GetResult()) 'MCP wrote unexpected errors.'
    } finally { if (!$process.HasExited) { $process.Kill($true) }; $process.Dispose() }
}
Test-Case 'MCP UTF16 limit accepts exact requests rejects overflow and resumes after whitespace' {
    $limit = 1048576
    $process = Start-ProcessInfo $ExecutablePath @('--config', $script:Config, 'mcp')
    try {
        $errTask = $process.StandardError.ReadToEndAsync()
        $ping = '{"jsonrpc":"2.0","id":101,"method":"ping"}'
        $prefix = '{"jsonrpc":"2.0","id":101,"method":"ping","padding":"'
        # 非ASCIIとサロゲートペアで、UTF8バイト数やコードポイント数ではない境界を検査する。
        $unicode = $prefix + '😀' + ('界' * ($limit - $prefix.Length - 4)) + '"}'
        foreach ($request in @($ping.PadRight($limit), $unicode)) {
            Assert-True ($request.Length -eq $limit) 'Exact-limit MCP fixture length differs.'
            Write-ProtocolInput $process ($request + "`n")
            $response = Read-ProtocolResponse $process
            Assert-True ($response.id -eq 101 -and !$response.error) 'MCP rejected an exact-limit request.'
            Write-ProtocolInput $process ($request + " `n" + $ping + "`n")
            $overflow = Read-ProtocolResponse $process
            Assert-True ($null -eq $overflow.id -and $overflow.error.code -eq -32600 -and $overflow.error.message -ceq 'Request exceeds 1 MiB.') 'MCP overflow rejection differs.'
            $next = Read-ProtocolResponse $process
            Assert-True ($next.id -eq 101 -and !$next.error) 'MCP did not resume after oversized input.'
        }
        Write-ProtocolInput $process ((' ' * ($limit + 1)) + "`n" + $ping + "`n")
        $response = Read-ProtocolResponse $process
        Assert-True ($response.id -eq 101 -and !$response.error) 'Oversized whitespace emitted a response or lost the next request.'
        Complete-McpSession $process $errTask
    } finally { if (!$process.HasExited) { $process.Kill($true) }; $process.Dispose() }
}
Test-Case 'MCP accepts LF CR CRLF buffer boundaries blank lines and final EOF request' {
    $process = Start-ProcessInfo $ExecutablePath @('--config', $script:Config, 'mcp')
    try {
        $errTask = $process.StandardError.ReadToEndAsync()
        $ping = '{"jsonrpc":"2.0","id":102,"method":"ping"}'
        # CRを4096文字境界の両側に置き、続くLFが別の行へ漏れないことを確認する。
        $frames = @(
            ($ping.PadRight(4095) + "`r`n")
            ($ping.PadRight(4095) + "`r`n")
            ($ping + "`n")
            ($ping + "`r")
            ($ping + "`r`n")
        )
        foreach ($frame in $frames) {
            Write-ProtocolInput $process $frame
            $response = Read-ProtocolResponse $process
            Assert-True ($response.id -eq 102 -and !$response.error) 'MCP line-ending response differs.'
        }
        Write-ProtocolInput $process ("`n `t`r`n" + $ping)
        $process.StandardInput.Close()
        $response = Read-ProtocolResponse $process
        Assert-True ($response.id -eq 102 -and !$response.error) 'MCP did not handle blank lines and final EOF request.'
        $remaining = $process.StandardOutput.ReadToEndAsync()
        Assert-True ($process.WaitForExit(5000) -and $process.ExitCode -eq 0) 'MCP did not stop at final EOF.'
        Assert-True (!$remaining.GetAwaiter().GetResult() -and !$errTask.GetAwaiter().GetResult()) 'MCP emitted extra output for line endings.'
    } finally { if (!$process.HasExited) { $process.Kill($true) }; $process.Dispose() }
}
Test-Case 'MCP responds to 1024-byte ping while stdin remains open' {
    $process = Start-ProcessInfo $ExecutablePath @('--config', $script:Config, 'mcp')
    try {
        $errTask = $process.StandardError.ReadToEndAsync()
        $ping = '{"jsonrpc":"2.0","id":103,"method":"ping"}'
        $frame = $ping.PadRight(1023) + "`n"
        Assert-True ([Text.Encoding]::UTF8.GetByteCount($frame) -eq 1024) 'Interactive MCP fixture byte length differs.'
        Write-ProtocolInput $process $frame
        $response = Read-ProtocolResponse $process
        Assert-True ($response.id -eq 103 -and !$response.error -and !$process.HasExited) 'MCP failed to respond with stdin open.'
        Complete-McpSession $process $errTask
    } finally { if (!$process.HasExited) { $process.Kill($true) }; $process.Dispose() }
}
Test-Case 'hook UTF16 exact limit passes and overflow denies without waiting for EOF' {
    $limit = 1048576
    $hook = '{"tool_name":"exec_command","tool_input":{"cmd":"echo bounded input"}}'
    $prefix = '{"tool_name":"exec_command","tool_input":{"cmd":"echo bounded input"},"padding":"'
    $unicode = $prefix + '😀' + ('界' * ($limit - $prefix.Length - 4)) + '"}'
    foreach ($request in @($hook.PadRight($limit), $unicode)) {
        Assert-True ($request.Length -eq $limit) 'Exact-limit hook fixture length differs.'
        $result = Invoke-ProcessJson $ExecutablePath @('--config', $script:Config, 'hook') $request
        Assert-True ($result.ExitCode -eq 0 -and $null -ne $result.Json -and !$result.Json.hookSpecificOutput -and !$result.Stderr) 'Hook rejected an exact-limit request.'
    }
    $process = Start-ProcessInfo $ExecutablePath @('--config', $script:Config, 'hook')
    try {
        # EOFを渡さず応答を待ち、超過時の早期終了をbroken pipeの例外に依存せず検査する。
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        Write-ProtocolInput $process ($unicode + ' ')
        Assert-True ($outTask.Wait(5000)) 'Oversized hook input waited for EOF.'
        Assert-True ($process.WaitForExit(5000) -and $process.ExitCode -eq 0) 'Oversized hook process exit differs.'
        $response = $outTask.GetAwaiter().GetResult() | ConvertFrom-Json -Depth 30
        Assert-True ($response.hookSpecificOutput.permissionDecision -ceq 'deny' -and $response.hookSpecificOutput.permissionDecisionReason -ceq 'Prunlet could not inspect the hook input: Hook input exceeds 1 MiB.') 'Oversized hook denial reason differs.'
        Assert-True ($errTask.GetAwaiter().GetResult().Trim() -ceq 'Prunlet hook: Hook input exceeds 1 MiB.') 'Oversized hook stderr differs.'
    } finally { if (!$process.HasExited) { $process.Kill($true) }; $process.Dispose() }
}
Test-Case 'native hook denies raw deletion without replacement or side effects' {
    $file = New-File "日本語 hook's file.txt"
    $command = "Remove-Item -LiteralPath '" + $file.Replace("'", "''") + "' -Force -ErrorAction Stop"
    $result = Hook $command
    Assert-True ($result.hookSpecificOutput.permissionDecision -eq 'deny' -and !$result.hookSpecificOutput.updatedInput) 'Native hook allowed or rewrote raw deletion.'
    Assert-True ($result.hookSpecificOutput.permissionDecisionReason -match 'Prunlet CLI' -and [IO.File]::Exists($file)) 'Native hook lacked guidance or caused deletion.'
}
Test-Case 'native hook denies literal brackets and WhatIf raw deletion without mutation' {
    $file = New-File '[hook].txt'
    $result = Hook "Remove-Item -LiteralPath '$file' -WhatIf"
    Assert-True ($result.hookSpecificOutput.permissionDecision -eq 'deny' -and !$result.hookSpecificOutput.updatedInput -and [IO.File]::Exists($file)) 'Raw WhatIf deletion bypassed hook.'
}
Test-Case 'native hook screens exec_command cmd input without replacing argument shape' {
    $file = New-File 'cmd-shape.txt'; $result = Hook "Remove-Item -LiteralPath '$file'" 'exec_command' 'cmd'
    Assert-True ($result.hookSpecificOutput.permissionDecision -eq 'deny' -and !$result.hookSpecificOutput.updatedInput -and [IO.File]::Exists($file)) 'exec_command raw deletion bypassed hook.'
}
Test-Case 'hook rejects variables and complex pipelines' {
    foreach ($command in @('Remove-Item -LiteralPath $target', 'Get-ChildItem | Remove-Item', "Remove-Item -LiteralPath '$script:Scope\a.txt'; Write-Output done", "Remove-Item -LiteralPath '$script:Scope' -Recurse")) {
        $hookResult=Hook $command
        Assert-True ($hookResult.hookSpecificOutput.permissionDecision -eq 'deny') 'Ambiguous delete was accepted.'
        Assert-True (!$hookResult.hookSpecificOutput.permissionDecisionReason.Contains([char]0xfffd)) 'Hook reason has invalid UTF-8 replacement characters.'
    }
}
Test-Case 'hook never turns an expression or scriptblock into a deletion' {
    $file = New-File 'never-delete-expression.txt'
    foreach ($command in @("`$false -and (Remove-Item -LiteralPath '$file')", "{ Remove-Item -LiteralPath '$file' }")) {
        Assert-True ((Hook $command).hookSpecificOutput.permissionDecision -eq 'deny') 'Nonexecuting expression was rewritten.'
        Assert-True ([IO.File]::Exists($file)) 'Expression source changed.'
    }
}
Test-Case 'hook screens escaped deletion command names' {
    $file=New-File 'escaped-command.txt'
    foreach ($command in @("r``m -LiteralPath '$file'", "Remove``-Item -LiteralPath '$file'")) {
        $result=Hook $command
        Assert-True ($result.hookSpecificOutput.permissionDecision -eq 'deny') 'Escaped deletion passed native inspection.'
        Assert-True ([IO.File]::Exists($file)) 'Hook itself caused deletion.'
    }
}
Test-Case 'native hook screens escaped JSON Unicode without changing source' {
    $file=New-File '日本語😀.txt'
    $event=@{tool_name='Bash';tool_input=@{command="Remove-Item -LiteralPath '$file'"}} | ConvertTo-Json -Depth 8 -Compress -EscapeHandling EscapeNonAscii
    $result=Invoke-ProcessJson $ExecutablePath @('--config',$script:Config,'hook') $event
    Assert-True ($result.ExitCode -eq 0 -and $result.Json.hookSpecificOutput.permissionDecision -eq 'deny' -and !$result.Json.hookSpecificOutput.updatedInput -and [IO.File]::Exists($file)) 'Unicode raw deletion bypassed native hook.'
}
Test-Case 'hook screens PowerShell directory aliases' {
    foreach($alias in @('rd','rmdir')) {
        $result=Hook "$alias -LiteralPath '$script:Scope' -Recurse"
        Assert-True ($result.hookSpecificOutput.permissionDecision -eq 'deny') 'Directory alias bypassed hook.'
    }
}
Test-Case 'hook passes unrelated commands and Prunlet invocation' {
    foreach ($command in @("Write-Output 'Remove-Item is a name'", "& '$ExecutablePath' --help", 'rg --files')) {
        $result = Hook $command; Assert-True (!$result.hookSpecificOutput) 'Unrelated command was blocked.'
    }
}
Test-Case 'native hook screens trailing backslash quotes CMD echo prefixes and conditional deletion' {
    $file = New-File 'native-cmd-boundary-source.txt'
    $deniedCommands = @(
        ('Set-Location "{0}\"; Remove-Item -LiteralPath "{1}"' -f $script:Scope, $file),
        ('cd /d "{0}\" & del "{1}"' -f $script:Scope, $file),
        ('@del "{0}"' -f $file),
        ('if exist "{0}" del "{0}"' -f $file),
        ('if not exist "{0}" @del "{1}"' -f (Join-Path $script:Scope 'native-cmd-missing.txt'), $file)
    )
    foreach ($command in $deniedCommands) {
        $result = Hook $command 'exec_command' 'cmd'
        Assert-True ($result.hookSpecificOutput.permissionDecision -eq 'deny' -and [IO.File]::Exists($file)) 'CMD quoting or prefix hid raw deletion.'
    }
    foreach ($command in @(('echo @del "{0}"' -f $file), ('echo if exist "{0}" del "{0}"' -f $file))) {
        $result = Hook $command 'exec_command' 'cmd'
        Assert-True (!$result.hookSpecificOutput -and [IO.File]::Exists($file)) 'Echo text was treated as deletion.'
    }
}
    Test-Case 'native hook checks quote escape modes without replacement or side effects' {
        $file = New-File 'quote-modes-sentinel.txt'
        foreach ($command in @(
            'Set-Location "C:\work\"; Remove-Item -LiteralPath "C:\work\a.txt"',
            'cd /d "C:\work\" & del C:\work\a.txt',
            'Write-Output "abc`""; Remove-Item -LiteralPath C:\work\a.txt',
            'echo abc`& del C:\work\a.txt',
            'printf "abc\""; rm -- /tmp/prunlet-hook-probe',
            'pwsh -Command ''Write-Output "abc`""; Remove-Item -LiteralPath C:\work\a.txt''',
            'bash -c ''printf "abc\""; rm -- /tmp/prunlet-hook-probe'''
        )) {
            $result = Hook $command
            Assert-True ($result.hookSpecificOutput.permissionDecision -eq 'deny' -and !$result.hookSpecificOutput.updatedInput -and [IO.File]::Exists($file)) 'A quote interpretation hid deletion or caused mutation.'
        }
        foreach ($command in @(
            'echo rm C:\work\a.txt',
            'echo "del C:\work\a.txt"',
            'Write-Output "abc`""',
            'printf "%s\n" "\"rm\""'
        )) {
            $result = Hook $command
            Assert-True (!$result.hookSpecificOutput -and [IO.File]::Exists($file)) 'Quoted deletion text was blocked or sentinel changed.'
        }
    }
Test-Case 'legacy hook script argument is accepted without reading or executing backend' {
    $sentinel = Join-Path $outputRoot 'legacy-backend-executed.txt'
    $backend = Join-Path $outputRoot 'legacy-backend-fixture.ps1'
    [IO.File]::WriteAllText($backend, ("[IO.File]::WriteAllText('" + $sentinel.Replace("'", "''") + "','executed')"))
    $file = New-File 'legacy-hook-source.txt'
    $deleteEvent = @{tool_name='Bash';tool_input=@{command="Remove-Item -LiteralPath '$file'"}} | ConvertTo-Json -Depth 5 -Compress
    $denied = Invoke-ProcessJson $ExecutablePath @('--config',$script:Config,'hook','--hook-script',$backend) $deleteEvent
    Assert-True ($denied.ExitCode -eq 0 -and $denied.Json.hookSpecificOutput.permissionDecision -eq 'deny' -and ![IO.File]::Exists($sentinel) -and [IO.File]::Exists($file)) 'Legacy backend executed or raw deletion passed.'
    $event = @{tool_name='Bash';tool_input=@{command='rg --files'}} | ConvertTo-Json -Depth 5 -Compress
    $result = Invoke-ProcessJson $ExecutablePath @('--config',$script:Config,'hook','--hook-script',(Join-Path $outputRoot 'nonexistent-backend.ps1')) $event
    Assert-True ($result.ExitCode -eq 0 -and !$result.Json.hookSpecificOutput) 'Missing legacy backend affected normal command.'
}
Test-Case 'hook invalid input fails closed' {
    $result = Invoke-ProcessJson $ExecutablePath @('--config',$script:Config,'hook') '{invalid'
    Assert-True ($result.Json.hookSpecificOutput.permissionDecision -eq 'deny') 'Invalid hook input passed.'
}
Test-Case 'isolated install idempotence and uninstall preserve unrelated settings' {
    $homeDirectory = Join-Path $outputRoot 'codex-home'; $backupDirectory = Join-Path $outputRoot 'settings-backup'
    $null = New-Item -ItemType Directory -Path $homeDirectory
    $originalToml = "model = 'existing-model'`n[features]`nhooks = true`n  [features.context_management]`nexperimental_mode = true`n[mcp_servers.other]`ncommand = 'other.exe'`n"
    [IO.File]::WriteAllText((Join-Path $homeDirectory 'config.toml'), $originalToml)
    $originalHooks = @{otherField='preserve';hooks=@{PreToolUse=@(@{matcher='example';hooks=@(@{type='command';command='example';statusMessage='existing'})})}}
    [IO.File]::WriteAllText((Join-Path $homeDirectory 'hooks.json'), ($originalHooks|ConvertTo-Json -Depth 20))
    $install = Join-Path $repoRoot 'integration\install-codex.ps1'
    $installArguments = @('-NoProfile','-File',$install,'-CodexHome',$homeDirectory,'-ExecutablePath',$ExecutablePath,'-ConfigPath',$script:Config,'-BackupDirectory',$backupDirectory)
    $first = Invoke-ProcessJson 'pwsh' $installArguments
    Assert-True ($first.ExitCode -eq 0) ('Install failed: ' + $first.Stderr)
    $installedToml = [IO.File]::ReadAllText((Join-Path $homeDirectory 'config.toml'))
    $installedHooks = [IO.File]::ReadAllText((Join-Path $homeDirectory 'hooks.json'))
    # 実CodexのWindows runnerと同じcmd /C経路で登録commandを起動する。
    $hookDocument = $installedHooks | ConvertFrom-Json -Depth 30
    $registeredCommand = @($hookDocument.hooks.PreToolUse | ForEach-Object { $_.hooks } | Where-Object { $_.statusMessage -eq 'Prunlet: protected literal deletion' })[0].command
    $runnerInfo = [Diagnostics.ProcessStartInfo]::new('cmd.exe')
    $runnerInfo.Arguments = '/d /s /c ' + $registeredCommand
    $runnerInfo.UseShellExecute=$false; $runnerInfo.CreateNoWindow=$true; $runnerInfo.RedirectStandardInput=$true; $runnerInfo.RedirectStandardOutput=$true; $runnerInfo.RedirectStandardError=$true
    $runnerInfo.StandardInputEncoding=[Text.UTF8Encoding]::new($false); $runnerInfo.StandardOutputEncoding=[Text.UTF8Encoding]::new($false); $runnerInfo.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $runner = [Diagnostics.Process]::Start($runnerInfo)
    try {
        $outputTask = $runner.StandardOutput.ReadToEndAsync(); $errorTask=$runner.StandardError.ReadToEndAsync()
        $runner.StandardInput.Write('{"tool_name":"Bash","tool_input":{"command":"Write-Output harmless"}}'); $runner.StandardInput.Close()
        Assert-True ($runner.WaitForExit(10000)) 'Registered hook command timed out.'
        $hookOutput=$outputTask.GetAwaiter().GetResult() | ConvertFrom-Json -Depth 20
        Assert-True ($runner.ExitCode -eq 0 -and !$hookOutput.hookSpecificOutput) ('Registered command failed: ' + $errorTask.GetAwaiter().GetResult())
    } finally { if (!$runner.HasExited) { $runner.Kill($true) }; $runner.Dispose() }
    $second = Invoke-ProcessJson 'pwsh' $installArguments
    Assert-True ($second.ExitCode -eq 0 -and $installedToml -ceq [IO.File]::ReadAllText((Join-Path $homeDirectory 'config.toml')) -and $installedHooks -ceq [IO.File]::ReadAllText((Join-Path $homeDirectory 'hooks.json'))) 'Repeated install changed settings.'
    $uninstalled = Invoke-ProcessJson 'pwsh' @('-NoProfile','-File',(Join-Path $repoRoot 'integration\uninstall-codex.ps1'),'-CodexHome',$homeDirectory,'-BackupDirectory',$backupDirectory)
    Assert-True ($uninstalled.ExitCode -eq 0) ('Uninstall failed: ' + $uninstalled.Stderr)
    Assert-True ($originalToml.TrimEnd() -ceq [IO.File]::ReadAllText((Join-Path $homeDirectory 'config.toml')).TrimEnd()) 'Uninstall changed unrelated TOML.'
    $finalHooks = [IO.File]::ReadAllText((Join-Path $homeDirectory 'hooks.json')) | ConvertFrom-Json -Depth 20
    Assert-True ($finalHooks.otherField -eq 'preserve' -and $finalHooks.hooks.PreToolUse.Count -eq 1 -and $finalHooks.hooks.PreToolUse[0].matcher -eq 'example') 'Uninstall changed unrelated hooks.'
}
Test-Case 'integration rejects spaced conflicting TOML without writes' {
    $index = 0
    foreach ($fixture in @("[ features ]`nhooks = false`n", "[ mcp_servers ]`nprunlet = { command = 'existing.exe', args = [] }`n")) {
        $index++
        $homeDirectory = Join-Path $outputRoot "conflicting-home-$index"; $null=New-Item -ItemType Directory -Path $homeDirectory
        $tomlPath=Join-Path $homeDirectory 'config.toml'; [IO.File]::WriteAllText($tomlPath,$fixture)
        $result=Invoke-ProcessJson 'pwsh' @('-NoProfile','-File',(Join-Path $repoRoot 'integration\install-codex.ps1'),'-CodexHome',$homeDirectory,'-ExecutablePath',$ExecutablePath,'-ConfigPath',$script:Config,'-BackupDirectory',(Join-Path $outputRoot "conflicting-backup-$index"))
        Assert-True ($result.ExitCode -ne 0 -and $fixture -ceq [IO.File]::ReadAllText($tomlPath) -and !(Test-Path -LiteralPath (Join-Path $homeDirectory 'hooks.json'))) 'Conflicting valid TOML was modified.'
    }
}
Test-Case 'uninstall refuses values appended to the owned MCP table' {
    $homeDirectory=Join-Path $outputRoot 'appended-home'; $null=New-Item -ItemType Directory -Path $homeDirectory
    $tomlPath=Join-Path $homeDirectory 'config.toml'
    [IO.File]::WriteAllText($tomlPath,"[mcp_servers.other]`ncommand='other.exe'`n")
    $backupDirectory=Join-Path $outputRoot 'appended-backup'
    $null=Invoke-ProcessJson 'pwsh' @('-NoProfile','-File',(Join-Path $repoRoot 'integration\install-codex.ps1'),'-CodexHome',$homeDirectory,'-ExecutablePath',$ExecutablePath,'-ConfigPath',$script:Config,'-BackupDirectory',$backupDirectory)
    $changed=[IO.File]::ReadAllText($tomlPath).Replace('# END PRUNLET MCP',"# END PRUNLET MCP`nenabled = false")
    [IO.File]::WriteAllText($tomlPath,$changed)
    $hooksBefore=[IO.File]::ReadAllText((Join-Path $homeDirectory 'hooks.json'))
    $result=Invoke-ProcessJson 'pwsh' @('-NoProfile','-File',(Join-Path $repoRoot 'integration\uninstall-codex.ps1'),'-CodexHome',$homeDirectory,'-BackupDirectory',$backupDirectory)
    Assert-True ($result.ExitCode -ne 0 -and $changed -ceq [IO.File]::ReadAllText($tomlPath) -and $hooksBefore -ceq [IO.File]::ReadAllText((Join-Path $homeDirectory 'hooks.json'))) 'Uninstall reassigned user-added values.'
}

$failed = @($script:Results | Where-Object { !$_.passed })
$report = [ordered]@{
    timestampUtc = [DateTime]::UtcNow.ToString('O')
    executable = [IO.Path]::GetFullPath($ExecutablePath)
    executableSha256 = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash
    legacyExecutable = if ($LegacyExecutablePath) { [IO.Path]::GetFullPath($LegacyExecutablePath) } else { $null }
    legacyExecutableSha256 = if ($LegacyExecutablePath -and [IO.File]::Exists($LegacyExecutablePath)) { (Get-FileHash -LiteralPath $LegacyExecutablePath -Algorithm SHA256).Hash } else { $null }
    outputDirectory = $outputRoot
    symbolicRestoreEvidence = @($script:SymbolicRestoreEvidence)
    passed = $script:Results.Count - $failed.Count
    failed = $failed.Count
    results = @($script:Results)
    cleanup = 'This disposable output directory contains only fixtures from this run; retain the report, then remove the directory after checking links and process termination.'
}
$reportJson = $report | ConvertTo-Json -Depth 15
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath), $reportJson, [Text.UTF8Encoding]::new($false))
@{passed=$report.passed;failed=$report.failed;report=$ReportPath} | ConvertTo-Json -Compress
if ($failed.Count) { exit 1 }
