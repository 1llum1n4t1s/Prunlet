#requires -Version 7.0
# e2e-windows.ps1 が背景で動かす、hook の連続実行。更新（Update.exe による root の入れ替え）の最中に、
# root の外の hook 複製が「deny 以外の応答・起動失敗」を 1 件も出さないことを確かめるための負荷。
#
# StopFile が作られるまで、毎回新しいプロセスで hook を起動し、拒否される入力（再帰削除）を標準入力で渡す。
# 結果は LogFile へ 1 行 1 回の JSON で追記する（ok = 終了コード 0 かつ permissionDecision が deny）。
# 子プロセスは CreateNoWindow で起動し、ウィンドウを出さない。環境（LOCALAPPDATA など）は起動元から継承する。
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HookExecutable,
    [Parameter(Mandatory)][string]$Config,
    [Parameter(Mandatory)][string]$CliExecutable,
    [Parameter(Mandatory)][string]$StopFile,
    [Parameter(Mandatory)][string]$LogFile,
    [int]$PauseMilliseconds = 20
)
$ErrorActionPreference = 'Stop'
$payload = '{"tool_name":"Bash","tool_input":{"command":"rm -rf C:/prunlet-e2e-hook-loop-target"}}'
$sequence = 0
while (!(Test-Path -LiteralPath $StopFile)) {
    $sequence++
    $entry = [ordered]@{ n = $sequence; at = [DateTime]::UtcNow.ToString('o'); ok = $false; exit = $null; detail = $null }
    try {
        $info = [Diagnostics.ProcessStartInfo]::new($HookExecutable)
        foreach ($argument in @('--config', $Config, 'hook', '--cli-executable', $CliExecutable)) { $info.ArgumentList.Add($argument) }
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($payload)
        $process.StandardInput.Close()
        if (!$process.WaitForExit(15000)) { $process.Kill(); $entry.detail = 'timeout' }
        else {
            $entry.exit = $process.ExitCode
            $text = $stdout.GetAwaiter().GetResult()
            try { $decision = ($text | ConvertFrom-Json).hookSpecificOutput.permissionDecision } catch { $decision = $null }
            $entry.ok = ($process.ExitCode -eq 0 -and $decision -ceq 'deny')
            if (!$entry.ok) { $entry.detail = "exit=$($process.ExitCode) decision=$decision stdout=$($text.Substring(0, [Math]::Min(200, $text.Length))) stderr=$(($stderr.GetAwaiter().GetResult()) -replace '\s+', ' ')" }
        }
        $process.Dispose()
    } catch {
        # 起動できない（ファイルが無い・ロックされている等）。
        $entry.detail = "start failed: $($_.Exception.Message)"
    }
    Add-Content -LiteralPath $LogFile -Value ($entry | ConvertTo-Json -Compress)
    Start-Sleep -Milliseconds $PauseMilliseconds
}
