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
    return (Invoke-ProcessJson $ExecutablePath @('--config', $script:Config, 'hook', '--hook-script', (Join-Path $repoRoot 'integration\codex-pretooluse.ps1')) $event).Json
}
function Assert-Rejected([string[]]$Arguments, [string]$UntouchedPath) {
    $result = Invoke-Prunlet $Arguments
    Assert-True ($result.ExitCode -ne 0) 'Operation unexpectedly succeeded.'
    if ($UntouchedPath) { Assert-True ([IO.File]::Exists($UntouchedPath)) 'Original file was lost.' }
}

Test-Case 'init' {
    $result = Invoke-Prunlet @('init', '--allowed-root', $script:Scope, '--backup-directory', $script:Recovery)
    Assert-True ($result.ExitCode -eq 0 -and [IO.File]::Exists($script:Config)) 'Init failed.'
}
Test-Case 'init never overwrites config' { Assert-Rejected @('init', '--allowed-root', $script:Scope, '--backup-directory', $script:Recovery) $script:Config }
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
Test-Case 'scope violation preflight keeps every source' {
    $file = New-File 'preflight.txt'
    $outside = Join-Path $outputRoot 'outside.txt'; [IO.File]::WriteAllText($outside, 'outside')
    Assert-Rejected @('delete', '--', $file, $outside) $file
    Assert-True ([IO.File]::ReadAllText($outside) -eq 'outside') 'Outside source changed.'
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
    try { $null = New-Item -ItemType SymbolicLink -Path $link -Target $target }
    catch {
        # リンク作成権限がない環境では、fixture作成だけを管理者へ委任する。
        $helper = Join-Path $outputRoot 'create-link-fixture.ps1'
        $body = "$" + "ErrorActionPreference='Stop'; New-Item -ItemType SymbolicLink -Path '" + $link.Replace("'", "''") + "' -Target '" + $target.Replace("'", "''") + "' | Out-Null"
        [IO.File]::WriteAllText($helper, $body, [Text.UTF8Encoding]::new($false))
        $elevated = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', ('"' + $helper + '"')) -Verb RunAs -WindowStyle Hidden -PassThru -Wait
        Assert-True ($elevated.ExitCode -eq 0 -and [IO.File]::Exists($link)) 'Elevated link fixture creation failed.'
    }
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
Test-Case 'manifest scope tamper rejected before restore' {
    $file = New-File 'manifest-tamper.txt'; $result = Invoke-Prunlet @('delete', '--', $file)
    $manifestPath = Join-Path (Join-Path $script:Recovery $result.Json.operationId) 'manifest.json'
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -Depth 20
    $outside = Join-Path $outputRoot 'never-restore-outside.txt'
    $manifest.items[0].path = $outside
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 20))
    Assert-Rejected @('restore', $result.Json.operationId) ''
    Assert-True (![IO.File]::Exists($outside)) 'Manifest tamper wrote outside scope.'
}
Test-Case 'operations lists recorded ids' {
    $result = Invoke-Prunlet @('operations'); Assert-True ($result.ExitCode -eq 0 -and $result.Json.operations.Count -ge 1) 'No operations listed.'
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
        Assert-True ($outside.result.isError) 'MCP scope violation did not report isError.'
        $list = Rpc @{jsonrpc='2.0';id=8;method='tools/call';params=@{name='list_operations';arguments=@{}}}
        Assert-True (!$list.result.isError) 'MCP operations failed.'
        $process.StandardInput.Close()
        Assert-True ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'MCP did not stop on EOF.'
        Assert-True (!$errTask.GetAwaiter().GetResult()) 'MCP wrote unexpected errors.'
    } finally { if (!$process.HasExited) { $process.Kill($true) }; $process.Dispose() }
}
Test-Case 'hook replacement executes the real CLI once' {
    $file = New-File "日本語 hook's file.txt"
    $command = "Remove-Item -LiteralPath '" + $file.Replace("'", "''") + "' -Force -ErrorAction Stop"
    $result = Hook $command
    Assert-True ($result.hookSpecificOutput.permissionDecision -eq 'allow') 'Hook failed to rewrite.'
    $updated = $result.hookSpecificOutput.updatedInput
    Assert-True ($updated.cwd -eq $script:Scope) 'Hook dropped cwd.'
    $executed = Invoke-ProcessJson 'pwsh' @('-NoProfile','-Command',$updated.command)
    Assert-True ($executed.ExitCode -eq 0 -and ![IO.File]::Exists($file)) 'Rewritten CLI did not delete.'
}
Test-Case 'hook preserves literal brackets and maps WhatIf' {
    $file = New-File '[hook].txt'
    $result = Hook "Remove-Item -LiteralPath '$file' -WhatIf"
    Assert-True ($result.hookSpecificOutput.permissionDecision -eq 'allow' -and $result.hookSpecificOutput.updatedInput.command.Contains('--dry-run')) 'WhatIf rewrite failed.'
}
Test-Case 'hook preserves exec_command cmd argument shape' {
    $file = New-File 'cmd-shape.txt'; $result = Hook "Remove-Item -LiteralPath '$file'" 'exec_command' 'cmd'
    Assert-True ($result.hookSpecificOutput.permissionDecision -eq 'allow' -and $result.hookSpecificOutput.updatedInput.cmd) 'cmd shape missing.'
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
        Assert-True ($result.hookSpecificOutput.permissionDecision -in @('allow','deny')) 'Escaped delete passed the fast gate.'
        Assert-True ([IO.File]::Exists($file)) 'Hook itself caused deletion.'
    }
}
Test-Case 'hook preserves escaped JSON Unicode paths' {
    $file=New-File '日本語😀.txt'
    $event=@{tool_name='Bash';tool_input=@{command="Remove-Item -LiteralPath '$file'"}} | ConvertTo-Json -Depth 8 -Compress -EscapeHandling EscapeNonAscii
    $result=Invoke-ProcessJson $ExecutablePath @('--config',$script:Config,'hook','--hook-script',(Join-Path $repoRoot 'integration\codex-pretooluse.ps1')) $event
    Assert-True ($result.Json.hookSpecificOutput.permissionDecision -eq 'allow' -and $result.Json.hookSpecificOutput.updatedInput.command.Contains($file)) 'Escaped JSON Unicode path changed.'
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
Test-Case 'hook fast path excludes the PowerShell backend' {
    $event = @{tool_name='Bash';tool_input=@{command='rg --files'}} | ConvertTo-Json -Depth 5 -Compress
    $result = Invoke-ProcessJson $ExecutablePath @('--config',$script:Config,'hook','--hook-script',(Join-Path $outputRoot 'nonexistent-backend.ps1')) $event
    Assert-True ($result.ExitCode -eq 0 -and !$result.Json.hookSpecificOutput) 'Non-deletion invoked the backend.'
}
Test-Case 'hook invalid input fails closed' {
    $result = Invoke-ProcessJson $ExecutablePath @('--config',$script:Config,'hook','--hook-script',(Join-Path $repoRoot 'integration\codex-pretooluse.ps1')) '{invalid'
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
    $installArguments = @('-NoProfile','-File',$install,'-CodexHome',$homeDirectory,'-ExecutablePath',$ExecutablePath,'-ConfigPath',$script:Config,'-HookPath',(Join-Path $repoRoot 'integration\codex-pretooluse.ps1'),'-BackupDirectory',$backupDirectory)
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
        $result=Invoke-ProcessJson 'pwsh' @('-NoProfile','-File',(Join-Path $repoRoot 'integration\install-codex.ps1'),'-CodexHome',$homeDirectory,'-ExecutablePath',$ExecutablePath,'-ConfigPath',$script:Config,'-HookPath',(Join-Path $repoRoot 'integration\codex-pretooluse.ps1'),'-BackupDirectory',(Join-Path $outputRoot "conflicting-backup-$index"))
        Assert-True ($result.ExitCode -ne 0 -and $fixture -ceq [IO.File]::ReadAllText($tomlPath) -and !(Test-Path -LiteralPath (Join-Path $homeDirectory 'hooks.json'))) 'Conflicting valid TOML was modified.'
    }
}
Test-Case 'uninstall refuses values appended to the owned MCP table' {
    $homeDirectory=Join-Path $outputRoot 'appended-home'; $null=New-Item -ItemType Directory -Path $homeDirectory
    $tomlPath=Join-Path $homeDirectory 'config.toml'
    [IO.File]::WriteAllText($tomlPath,"[mcp_servers.other]`ncommand='other.exe'`n")
    $backupDirectory=Join-Path $outputRoot 'appended-backup'
    $null=Invoke-ProcessJson 'pwsh' @('-NoProfile','-File',(Join-Path $repoRoot 'integration\install-codex.ps1'),'-CodexHome',$homeDirectory,'-ExecutablePath',$ExecutablePath,'-ConfigPath',$script:Config,'-HookPath',(Join-Path $repoRoot 'integration\codex-pretooluse.ps1'),'-BackupDirectory',$backupDirectory)
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
