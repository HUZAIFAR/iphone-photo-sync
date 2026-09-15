<#
.SYNOPSIS
    Removes the scheduled watcher task and stops any running watcher.
    Your photo library, index and logs are left completely untouched.
#>
[CmdletBinding()]
param([string]$TaskName = 'iPhone Photo Sync Watcher')

Stop-ScheduledTask       -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*Watch-iPhone.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host 'Watcher removed. Library, index and logs were left untouched.' -ForegroundColor Green
