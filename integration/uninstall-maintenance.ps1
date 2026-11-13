#requires -Version 7.0
param(
    [string]$ExecutablePath = (Join-Path $PSScriptRoot 'prunlet.exe'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.json'),
    # 更新タスクの識別には使わない（引数の記録だけ）。既定値のままでよい。
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'maintenance-task.ps1')
# 定期実行（保守・更新）の登録だけを解除し、製品・設定・復元データは残す。
$name = Unregister-PrunletMaintenanceTask $ExecutablePath $ConfigPath
$updateName = Unregister-PrunletUpdateTask $ExecutablePath $ConfigPath $CodexHome
@{ status = 'unregistered'; taskName = $name; updateTaskName = $updateName; message = 'Executable, configuration and recovery data were retained.' } | ConvertTo-Json -Compress
