param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$ConfigPath = 'C:\Users\IMT\.local\Prunlet\config.json'
)

$ErrorActionPreference = 'Stop'
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath, $ConfigPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw "Absolute path required: $path" }
}
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
if (![IO.File]::Exists($ExecutablePath)) { throw "Executable not found: $ExecutablePath" }
if ([IO.Directory]::Exists($OutputDirectory) -or [IO.File]::Exists($OutputDirectory)) { throw "Output already exists: $OutputDirectory" }
if ([IO.File]::Exists($ReportPath) -or [IO.Directory]::Exists($ReportPath)) { throw "Report already exists: $ReportPath" }
if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($OutputDirectory))) { throw 'Output parent does not exist.' }
if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($ReportPath))) { throw 'Report parent does not exist.' }
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$fixture = Join-Path $OutputDirectory 'hook-sentinel.txt'
[IO.File]::WriteAllText($fixture, 'hook sentinel: never execute fixture commands', [Text.UTF8Encoding]::new($false))
$fixtureHash = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash

# 検査対象はすべてhookへ送る文字列で、実行しない。
$single = @('$script=@''', '/opt/homebrew/bin/docker --host socket exec sample /bin/sh -ec ''cd /work/src; [ -f /work/src/core ]; rm -- /work/src/core; [ ! -e /work/src/core ]''', '''@; $encoded=Encode($script); & ssh mac $encoded') -join "`n"
$double = @('$script=@"', '/bin/sh -ec ''cd /work/src; rm -- /work/src/core''', '"@', '& ssh mac $script') -join "`n"
$expansion = @('$script=@"', 'literal $(Remove-Item -LiteralPath "<FILE>")', '"@', '& ssh mac $script') -join "`n"
$singleExpansion = @('$script=@''', 'literal $(Remove-Item -LiteralPath "<FILE>")', '''@', '& ssh mac $script') -join "`n"
$startSpace = @('$script=@''  ', '/bin/sh -ec ''cd /work/src; rm -- /work/src/core''', '''@', '& ssh mac $script') -join "`n"
$indentTerminator = @('$script=@''', 'literal', '  ''@', 'rm -- <FILE>') -join "`n"
$afterTerminator = @('$script=@''', '/bin/sh -ec ''cd /work/src; rm -- /work/src/core''', '''@; rm -- <FILE>') -join "`n"
$unterminated = @('$script=@''', 'literal', 'rm -- <FILE>') -join "`n"
$malformed = @('$script=@''', 'literal', '''@ trailing text; rm -- <FILE>') -join "`n"
$cmdBlock = @('$script=@''', 'echo ok & rm -- <FILE>', '''@') -join "`n"
$wrapper = 'pwsh -Command ' + '"' + ($single -replace '"', '`"') + '"'
$cases = @(
    @{ name='single-here-pwsh'; command=$single; shell='pwsh'; pass=$true; bashPass=$false },
    @{ name='single-here-powershell-path'; command=$single; shell='C:\Program Files\PowerShell\7\pwsh.exe'; pass=$true; bashPass=$false },
    @{ name='single-here-no-hint'; command=$single; pass=$false },
    @{ name='single-here-unknown'; command=$single; shell='unknown-shell'; pass=$false },
    @{ name='single-here-bash-hint'; command=$single; shell='bash'; pass=$false },
    @{ name='single-here-sh-hint'; command=$single; shell='sh'; pass=$false },
    @{ name='single-here-zsh-hint'; command=$single; shell='zsh'; pass=$false },
    @{ name='single-here-cmd'; command=$cmdBlock; shell='cmd.exe'; pass=$false },
    @{ name='double-here-literal'; command=$double; shell='pwsh'; pass=$true },
    @{ name='double-here-local-expansion'; command=$expansion; shell='pwsh'; pass=$false },
    @{ name='single-here-literal-expansion'; command=$singleExpansion; shell='pwsh'; pass=$true; bashPass=$false },
    @{ name='single-here-start-space'; command=$startSpace; shell='pwsh'; pass=$true; bashPass=$false },
    @{ name='single-here-indented-terminator'; command=$indentTerminator; shell='pwsh'; pass=$false },
    @{ name='after-terminator-local-delete'; command=$afterTerminator; shell='pwsh'; pass=$false },
    @{ name='before-here-local-delete'; command=('rm -- <FILE>' + "`n" + $single); shell='pwsh'; pass=$false },
    @{ name='after-here-local-delete'; command=($single + "`n" + 'Remove-Item -LiteralPath <FILE>'); shell='pwsh'; pass=$false },
    @{ name='cmd-wrapper-delete'; command='cmd /c "echo ok & rm -- <FILE>"'; shell='pwsh'; pass=$false },
    @{ name='pwsh-wrapper-here'; command=$wrapper; shell='cmd.exe'; pass=$true },
    @{ name='pwsh-wrapper-delete'; command='pwsh -Command "Remove-Item -LiteralPath <FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='unterminated-here'; command=$unterminated; shell='pwsh'; pass=$false },
    @{ name='malformed-here'; command=$malformed; shell='pwsh'; pass=$false },
    @{ name='ssh-quoted-text'; command='ssh mac "echo safe; rm -- /remote/core"'; shell='pwsh'; pass=$true },
    @{ name='ordinary-non-delete'; command='Write-Output "hello"'; shell='pwsh'; pass=$true },
    @{ name='registry-delete'; command='reg.exe delete HKCU\Software\PrunletHookProbe /f'; pass=$false },
    @{ name='registry-pwsh-wrapper'; command='pwsh -Command "Remove-Item HKCU:\Software\PrunletHookProbe"'; pass=$false },
    @{ name='registry-cmd-wrapper'; command='cmd.exe /d /c reg.exe delete HKCU\Software\PrunletHookProbe /f'; pass=$false },
    @{ name='file-remove-item'; command='Remove-Item -LiteralPath "<FILE>"'; shell='pwsh'; pass=$false },
    @{ name='powershell-escape'; command='Remove`-Item -LiteralPath "<FILE>"'; shell='pwsh'; pass=$false },
    @{ name='cmd-escape'; command='d^el "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='posix-escape'; command='r\m -- "<FILE>"'; shell='bash'; pass=$false }
)

$results = [Collections.Generic.List[object]]::new()
foreach ($case in $cases) {
    foreach ($tool in @('Bash', 'exec_command', 'functions.exec_command')) {
        $inputObject = @{ cwd = $OutputDirectory }
        $inputObject[$(if ($tool -eq 'Bash') { 'command' } else { 'cmd' })] = $case.command.Replace('<FILE>', $fixture)
        if ($case.ContainsKey('shell')) { $inputObject.shell = $case.shell }
        $event = @{ hook_event_name = 'PreToolUse'; tool_name = $tool; tool_input = $inputObject }
        $json = $event | ConvertTo-Json -Depth 8 -Compress
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $ExecutablePath
        $start.ArgumentList.Add('--config')
        $start.ArgumentList.Add($ConfigPath)
        $start.ArgumentList.Add('hook')
        $start.UseShellExecute = $false
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
        $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::Start($start)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($json)
        $process.StandardInput.Close()
        if (!$process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw "Hook timed out: $($case.name) / $tool" }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $decision = 'invalid'
        try {
            $parsed = $stdout | ConvertFrom-Json
            if ($stdout.Trim() -ceq '{}') { $decision = 'pass' }
            elseif ($parsed.hookSpecificOutput.permissionDecision -ceq 'deny' -and !$parsed.hookSpecificOutput.updatedInput -and $parsed.hookSpecificOutput.permissionDecisionReason -match '(?i)prunlet') { $decision = 'deny' }
        } catch { }
        $fixtureUnchanged = [IO.File]::Exists($fixture) -and (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash -ceq $fixtureHash
        $expectedPass = if ($tool -eq 'Bash' -and $case.ContainsKey('bashPass')) { $case.bashPass } else { $case.pass }
        $expected = if ($expectedPass) { 'pass' } else { 'deny' }
        $results.Add([pscustomobject]@{ name=$case.name; tool=$tool; input=$event; inputJson=$json; expected=$expected; decision=$decision; exitCode=$process.ExitCode; stdout=$stdout; stderr=$stderr; fixtureUnchanged=$fixtureUnchanged; passed=($process.ExitCode -eq 0 -and $decision -ceq $expected -and $fixtureUnchanged) })
        $process.Dispose()
    }
}
$failed = @($results | Where-Object { !$_.passed })
$report = [ordered]@{ executable=$ExecutablePath; executableSha256=(Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash; configPath=$ConfigPath; runner=$PSCommandPath; runnerSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash; fixture=$fixture; fixtureSha256=$fixtureHash; passed=$results.Count-$failed.Count; failed=$failed.Count; results=@($results) }
[IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
Write-Output "passed=$($report.passed) failed=$($report.failed) report=$ReportPath"
foreach ($result in $failed) { Write-Output "FAIL $($result.name) $($result.tool): expected=$($result.expected) actual=$($result.decision) exit=$($result.exitCode) fixtureUnchanged=$($result.fixtureUnchanged)" }
if ($failed.Count) { exit 1 }
