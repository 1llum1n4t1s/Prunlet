[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference = 'Stop'
if (-not [IO.Path]::IsPathFullyQualified($OutputDirectory) -or -not [IO.Path]::IsPathFullyQualified($ReportPath)) { throw 'Verification paths must be absolute.' }
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
foreach ($destination in @($outputRoot, [IO.Path]::GetFullPath($ReportPath))) {
    if (-not [IO.Path]::IsPathFullyQualified($destination)) { throw 'Verification paths must be absolute.' }
    foreach ($forbidden in @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))) {
        if ($destination.Equals($forbidden, [StringComparison]::OrdinalIgnoreCase) -or $destination.StartsWith($forbidden.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Verification output must be external.' }
    }
    $ancestor = $destination
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Verification output must not traverse links.' }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
}
if (Test-Path -LiteralPath $outputRoot) { throw 'OutputDirectory must be new, not an existing directory.' }
if (Test-Path -LiteralPath $ReportPath) { throw 'ReportPath must be new.' }
$null = New-Item -ItemType Directory -Path $outputRoot
$script:Scope = Join-Path $outputRoot 'scope'
$script:Recovery = Join-Path $outputRoot 'recovery'
$script:Config = Join-Path $outputRoot 'config.json'
$null = New-Item -ItemType Directory -Path $script:Scope, $script:Recovery
$script:Results = [Collections.Generic.List[object]]::new()

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
function Test-Case([string]$Name, [scriptblock]$Body) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try { & $Body; $script:Results.Add(@{ name = $Name; passed = $true; milliseconds = $timer.Elapsed.TotalMilliseconds }) }
    catch { $script:Results.Add(@{ name = $Name; passed = $false; milliseconds = $timer.Elapsed.TotalMilliseconds; error = $_.Exception.Message }); Write-Warning "$Name : $($_.Exception.Message)" }
}
function Hook([string]$Command, [string]$ToolName = 'Bash', [string]$Field = 'command') {
    $event = @{ hook_event_name = 'PreToolUse'; tool_name = $ToolName; tool_input = @{ $Field = $Command; cwd = $script:Scope } } | ConvertTo-Json -Depth 8 -Compress
    $result = Invoke-ProcessJson $ExecutablePath @('--config', $script:Config, 'hook') $event
    Assert-True ($result.ExitCode -eq 0) 'Hook process failed.'
    return $result.Json
}
function Assert-Rejected([string[]]$Arguments, [string]$UntouchedPath) {
    $result = Invoke-Prunlet $Arguments
    Assert-True ($result.ExitCode -ne 0) 'Operation unexpectedly succeeded.'
    if ($UntouchedPath) { Assert-True ([IO.File]::Exists($UntouchedPath)) 'Original file was lost.' }
}
function File-Digest([string]$Path) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path))).ToLowerInvariant()
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
        Assert-True ($elevated.ExitCode -eq 0 -and [IO.File]::Exists($Path)) 'Elevated link fixture creation failed.'
    }
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

Test-Case 'init' {
    $result = Invoke-Prunlet @('init', '--backup-directory', $script:Recovery)
    Assert-True ($result.ExitCode -eq 0 -and [IO.File]::Exists($script:Config)) 'Init failed.'
}
Test-Case 'init never overwrites config' { Assert-Rejected @('init', '--allowed-root', $script:Scope, '--backup-directory', $script:Recovery) $script:Config }
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
        @{ Name = 'namespace'; Json = (ConvertTo-Json -InputObject @($file, ('\\?\' + $file)) -Compress) },
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
    foreach ($index in 1..4) { $directory = Join-Path $directory ('long-' + $index + '-' + ('x' * 64)); $null = New-Item -ItemType Directory -Path $directory }
    $file = Join-Path $directory '長い path.txt'; [IO.File]::WriteAllText($file, 'long path recovery bytes', [Text.UTF8Encoding]::new($false))
    Assert-True ($file.Length -gt 260) 'Long path fixture did not exceed MAX_PATH.'
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
Test-Case 'wildcard rejected' { Assert-Rejected @('delete', '--', (Join-Path $script:Scope '*.txt')) '' }
Test-Case 'directory rejected' { Assert-Rejected @('delete', '--', $script:Scope) '' }
Test-Case 'empty deletion rejected' { Assert-Rejected @('delete', '--') '' }
Test-Case 'ADS path rejected' {
    $file = New-File 'ads-path.txt'; Assert-Rejected @('delete', '--', ($file + ':stream')) $file
}
Test-Case 'source carrying ADS is preserved' {
    $file = New-File 'ads-content.txt'; [IO.File]::WriteAllText($file + ':custom', 'preserve stream')
    Assert-Rejected @('delete', '--', $file) $file
    Assert-True ([IO.File]::ReadAllText($file + ':custom') -eq 'preserve stream') 'Alternate data stream changed.'
}
Test-Case 'locked source is preserved' {
    $file = New-File 'locked.txt'; $lock = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Assert-Rejected @('delete', '--', $file) $file } finally { $lock.Dispose() }
}
Test-Case 'symbolic link rejected without changing target' {
    $target = New-File 'link-target.txt'; $link = Join-Path $script:Scope 'link.txt'
    New-SymbolicFixture $link $target
    Assert-Rejected @('delete', '--', $link) $target
}
Test-Case 'junction ancestor rejected without changing target' {
    $targetRoot = Join-Path $outputRoot 'junction-target'; $null = New-Item -ItemType Directory -Path $targetRoot
    $target = Join-Path $targetRoot 'target.txt'; [IO.File]::WriteAllText($target, 'junction fixture')
    $link = Join-Path $script:Scope 'junction'; $null = New-Item -ItemType Junction -Path $link -Target $targetRoot
    Assert-Rejected @('delete', '--', (Join-Path $link 'target.txt')) $target
}
Test-Case 'case-sensitive ancestors are rejected' {
    $caseRoot = Join-Path $script:Scope 'case-sensitive'; $null = New-Item -ItemType Directory -Path $caseRoot
    $helper = Join-Path $outputRoot 'create-case-fixture.ps1'
    $body = "& fsutil.exe file SetCaseSensitiveInfo '" + $caseRoot.Replace("'", "''") + "' enable; if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }"
    [IO.File]::WriteAllText($helper, $body, [Text.UTF8Encoding]::new($false))
    $elevated = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-File',('"' + $helper + '"')) -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    Assert-True ($elevated.ExitCode -eq 0) 'Cannot enable case-sensitive fixture.'
    $file = Join-Path $caseRoot 'file.txt'; [IO.File]::WriteAllText($file, 'case-sensitive data')
    Assert-Rejected @('delete', '--', $file) $file
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
    $result = Invoke-Prunlet @('operations'); Assert-True ($result.ExitCode -eq 0 -and $result.Json.operations.Count -ge 1) 'No operations listed.'
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
Test-Case 'purge rejects unverified partial backup from a failed delete operation' {
    $file = New-File 'purge-unverified-source.txt'
    $lock = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { $failed = Invoke-Prunlet @('delete', '--', $file) } finally { $lock.Dispose() }
    Assert-True ($failed.ExitCode -ne 0 -and $failed.Json.operationId -and [IO.File]::Exists($file)) 'Failed-operation fixture differs.'
    $root = Join-Path $script:Recovery $failed.Json.operationId
    $partial = Join-Path $root '0000.bak'; [IO.File]::WriteAllText($partial, 'unverified partial bytes')
    Assert-PurgeRejected @{ Id = $failed.Json.operationId; Root = $root; Backups = @($partial) }
    Assert-True ([IO.File]::Exists($file)) 'Unverified operation source changed.'
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
        # 削除notificationは副作用を起こさず、次のpingだけに応答する。
        $process.StandardInput.WriteLine((@{jsonrpc='2.0';method='tools/call';params=@{name='delete_files';arguments=@{paths=@($file)}}} | ConvertTo-Json -Depth 10 -Compress))
        $null = Rpc @{jsonrpc='2.0';id=3;method='ping'}
        Assert-True ([IO.File]::Exists($file)) 'MCP notification caused deletion.'
        $deleted = Rpc @{jsonrpc='2.0';id=4;method='tools/call';params=@{name='delete_files';arguments=@{paths=@($file)}}}
        Assert-True (!$deleted.result.isError -and ![IO.File]::Exists($file)) 'MCP delete failed.'
        $restored = Rpc @{jsonrpc='2.0';id=5;method='tools/call';params=@{name='restore_files';arguments=@{operationId=$deleted.result.structuredContent.operationId}}}
        Assert-True (!$restored.result.isError -and [IO.File]::ReadAllText($file) -eq 'MCP content') 'MCP restore failed.'
        $bad = Rpc @{jsonrpc='2.0';id=6;method='tools/call';params=@{name='delete_files';arguments=@{paths=@($file);dryRun='false'}}}
        Assert-True ($bad.error.code -eq -32602 -and [IO.File]::Exists($file)) 'Invalid arguments were not rejected.'
        $outside = Rpc @{jsonrpc='2.0';id=7;method='tools/call';params=@{name='delete_files';arguments=@{paths=@((Join-Path $outputRoot 'outside.txt'))}}}
        Assert-True (!$outside.result.isError -and ![IO.File]::Exists((Join-Path $outputRoot 'outside.txt'))) 'MCP still rejects local targets outside former roots.'
        $outsideRestored = Rpc @{jsonrpc='2.0';id=9;method='tools/call';params=@{name='restore_files';arguments=@{operationId=$outside.result.structuredContent.operationId}}}
        Assert-True (!$outsideRestored.result.isError -and [IO.File]::ReadAllText((Join-Path $outputRoot 'outside.txt')) -eq 'outside') 'MCP unrestricted restore differs.'
        $list = Rpc @{jsonrpc='2.0';id=8;method='tools/call';params=@{name='list_operations';arguments=@{}}}
        Assert-True (!$list.result.isError) 'MCP operations failed.'
        $process.StandardInput.Close()
        Assert-True ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'MCP did not stop on EOF.'
        Assert-True (!$errTask.GetAwaiter().GetResult()) 'MCP wrote unexpected errors.'
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
    outputDirectory = $outputRoot
    passed = $script:Results.Count - $failed.Count
    failed = $failed.Count
    results = @($script:Results)
    cleanup = 'This disposable output directory contains only fixtures from this run; retain the report, then remove the directory after checking links and process termination.'
}
$reportJson = $report | ConvertTo-Json -Depth 15
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath), $reportJson, [Text.UTF8Encoding]::new($false))
@{passed=$report.passed;failed=$report.failed;report=$ReportPath} | ConvertTo-Json -Compress
if ($failed.Count) { exit 1 }
