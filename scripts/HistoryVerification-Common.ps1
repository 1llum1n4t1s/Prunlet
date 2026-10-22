# 履歴検証の共通関数。呼び出し元のスクリプトスコープで使用する。
function Assert-True([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }

function Digest([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
    finally { $stream.Dispose() }
}

function Save-Json([string]$Path, [object]$Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 50), [Text.UTF8Encoding]::new($false)) }

function Start-Cli([string[]]$Arguments, [switch]$Mcp) {
    $values = @('--config', $script:Config) + $Arguments
    foreach ($value in @($ExecutablePath) + $values) { if ($value -match '["%&|<>^!\r\n]') { throw 'Unsafe CMD argument.' } }
    $info = [Diagnostics.ProcessStartInfo]::new('cmd.exe')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.RedirectStandardInput = [bool]$Mcp
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $info.Arguments = '/d /s /c ""' + $ExecutablePath + '" ' + (($values | ForEach-Object { '"' + $_ + '"' }) -join ' ') + '"'
    foreach ($entry in $script:CliEnvironment.GetEnumerator()) { $info.Environment[$entry.Key] = $entry.Value }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $null = $process.Start()
    if ($Mcp) { return @{ Process = $process; Stderr = $process.StandardError.ReadToEndAsync() } }
    return @{ Process = $process; Stdout = $process.StandardOutput.ReadToEndAsync(); Stderr = $process.StandardError.ReadToEndAsync(); Arguments = $Arguments }
}

function Finish-Cli($Running) {
    $process = $Running.Process
    try {
        if (!$process.WaitForExit(75000)) { $process.Kill($true); $process.WaitForExit(); throw 'CLI timed out.' }
        $raw = $Running.Stdout.GetAwaiter().GetResult(); $errorText = $Running.Stderr.GetAwaiter().GetResult()
        $json = if ($raw.Trim()) { $raw | ConvertFrom-Json -Depth 50 } else { $null }
        $commands.Add(@{ case = [IO.Path]::GetFileName($script:CaseRoot); arguments = $Running.Arguments; exitCode = $process.ExitCode; response = $json; stderr = $errorText })
        return @{ ExitCode = $process.ExitCode; Json = $json }
    } finally { $process.Dispose() }
}

function Invoke-Cli([string[]]$Arguments) { Finish-Cli (Start-Cli $Arguments) }

function New-Case([string]$Name) {
    $script:CaseRoot = Join-Path $outputRoot $Name
    $script:Recovery = Join-Path $script:CaseRoot 'recovery'
    $script:Config = Join-Path $script:CaseRoot 'config.json'
    $null = [IO.Directory]::CreateDirectory($script:Recovery)
    Assert-True ((Invoke-Cli @('init', '--backup-directory', $script:Recovery)).ExitCode -eq 0) 'Initialization failed.'
}

function New-History([int]$Schema = 1, [int]$WarningCount = 1, [switch]$Live) {
    $source = Join-Path $script:CaseRoot 'source.txt'
    [IO.File]::WriteAllText($source, ('history-source' * 100), [Text.UTF8Encoding]::new($false))
    if ($Schema -eq 2) {
        $directory = Join-Path $script:CaseRoot 'source-directory'
        $null = [IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllText((Join-Path $directory 'child.txt'), 'directory history')
        $source = $directory
    }
    if ($Schema -eq 3) { [IO.File]::WriteAllText(($source + ':history-stream'), 'stream history') }
    $arguments = @('delete'); if ($Schema -eq 2) { $arguments += '--recursive' }; $arguments += @('--', $source)
    $deleted = Invoke-Cli $arguments
    Assert-True ($deleted.ExitCode -eq 0) 'Fixture delete failed.'
    $operation = Join-Path $script:Recovery $deleted.Json.operationId
    $manifest = [IO.File]::ReadAllText((Join-Path $operation 'manifest.json')) | ConvertFrom-Json
    Assert-True ($manifest.schema -eq $Schema) 'Fixture schema differs.'
    if (!$Live) {
        $purged = Invoke-Cli @('purge', $deleted.Json.operationId, '--apply')
        Assert-True ($purged.ExitCode -eq 0) 'Fixture purge failed.'
        $deleteResultPath = Join-Path $operation 'delete-result.json'
        $deleteResult = [IO.File]::ReadAllText($deleteResultPath) | ConvertFrom-Json
        # 1値の上限以内で実際の大きい履歴を再現する。manifestやintentのdigestは変更しない。
        $deleteResult.warnings = @((1..$WarningCount) | ForEach-Object { 'history warning ' * 32768 })
        Save-Json $deleteResultPath $deleteResult
    }
    return @{ Id = $deleted.Json.operationId; Directory = $operation; Source = $source }
}

function Snapshot([string]$Root) {
    (@(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + $_.Length + ':' + [int]$_.Attributes + ':' + (Digest $_.FullName) }) -join '|')
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    try { New-Case $Name; & $Body; $results.Add(@{ name = $Name; passed = $true }); Write-Output "PASS $Name" }
    catch { $results.Add(@{ name = $Name; passed = $false; error = $_.Exception.Message }); Write-Output "FAIL ${Name}: $($_.Exception.Message)" }
}
