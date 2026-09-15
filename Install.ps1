<#
.SYNOPSIS
    Registers the watcher as a Scheduled Task that starts at logon, and starts
    it now. Does not require administrator rights.
#>
[CmdletBinding()]
param([string]$TaskName = 'iPhone Photo Sync Watcher')

$ErrorActionPreference = 'Stop'
$Root    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Watcher = Join-Path $Root 'Watch-iPhone.ps1'

if (-not (Test-Path -LiteralPath $Watcher)) { throw "Watch-iPhone.ps1 not found next to Install.ps1." }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $Watcher
) -WorkingDirectory $Root

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null

Write-Host "Registered scheduled task: $TaskName" -ForegroundColor Green

Stop-ScheduledTask  -TaskName $TaskName -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2
$state = (Get-ScheduledTask -TaskName $TaskName).State
Write-Host "Watcher state: $state" -ForegroundColor Green
Write-Host ""
Write-Host "Done. Plug in your iPhone, unlock it, and it will sync by itself." -ForegroundColor Cyan
Write-Host "Logs: $(Join-Path $Root 'logs')"
