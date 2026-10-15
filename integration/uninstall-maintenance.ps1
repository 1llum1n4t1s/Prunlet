#requires -Version 7.0
param(
    [string]$ExecutablePath = (Join-Path $PSScriptRoot 'prunlet.exe'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.json')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'maintenance-task.ps1')
$name = Unregister-PrunletMaintenanceTask $ExecutablePath $ConfigPath
@{ status = 'unregistered'; taskName = $name; message = 'Executable, configuration and recovery data were retained.' } | ConvertTo-Json -Compress
