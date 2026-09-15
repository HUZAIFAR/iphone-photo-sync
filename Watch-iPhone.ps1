<#
.SYNOPSIS
    Background watcher: polls for the iPhone appearing under "This PC" and fires
    Sync-iPhone.ps1 exactly once per physical connection.

.DESCRIPTION
    Runs hidden at logon via Task Scheduler (see Install.ps1). Costs almost
    nothing - it enumerates the "This PC" shell namespace every few seconds.
    The "already synced this connection" flag resets when the phone is unplugged.
#>
[CmdletBinding()]
param([string]$ConfigPath)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'config.json' }

$cfg      = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$LogDir   = Join-Path $Root 'logs'
$StateDir = Join-Path $Root 'state'
foreach ($d in @($LogDir, $StateDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$WatchLog   = Join-Path $LogDir 'watcher.log'
$DevicePath = Join-Path $StateDir 'device.json'

function Write-DeviceState {
    param([bool]$Present, [string]$Name)
    try {
        $o = [ordered]@{
            Present    = $Present
            Name       = $Name
            UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            WatcherPid = $PID
        }
        $tmp = $DevicePath + '.tmp'
        [IO.File]::WriteAllText($tmp, ($o | ConvertTo-Json -Compress), [Text.Encoding]::UTF8)
        [IO.File]::Copy($tmp, $DevicePath, $true)
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Write-WLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $WatchLog -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

function Test-DevicePresent {
    # Cheap presence check: is a portable device with a matching name attached?
    $shell = $null
    try {
        $shell  = New-Object -ComObject Shell.Application
        $thisPC = $shell.NameSpace(17)
        if (-not $thisPC) { return $false }
        foreach ($dev in $thisPC.Items()) {
            if ($dev.IsFolder -and $dev.Name -match $cfg.DeviceNamePattern) {
                $script:FoundName = $dev.Name
                return $true
            }
        }
        return $false
    } catch {
        return $false
    } finally {
        if ($shell) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { } }
    }
}

# Keep only the last ~2000 lines of the watcher log.
try {
    if ((Test-Path -LiteralPath $WatchLog) -and (Get-Item $WatchLog).Length -gt 512KB) {
        $tail = Get-Content -LiteralPath $WatchLog -Tail 2000
        Set-Content -LiteralPath $WatchLog -Value $tail -Encoding UTF8
    }
} catch { }

Write-WLog '--- watcher started ---'

$poll        = [Math]::Max(3, [int]$cfg.PollSeconds)
$wasPresent  = $false
$syncedThis  = $false
$syncScript  = Join-Path $Root 'Sync-iPhone.ps1'

while ($true) {
    try {
        $script:FoundName = ''
        $present = Test-DevicePresent
        Write-DeviceState -Present $present -Name $script:FoundName

        if ($present -and -not $wasPresent) {
            Write-WLog 'Device connected.'
            $syncedThis = $false
        }
        elseif (-not $present -and $wasPresent) {
            Write-WLog 'Device disconnected.'
        }
        $wasPresent = $present

        if ($present -and -not $syncedThis) {
            # Give Windows a moment to finish mounting the MTP store.
            Start-Sleep -Seconds 3
            Write-WLog 'Starting sync (will wait for unlock if needed).'
            $syncedThis = $true
            try {
                & $syncScript -ConfigPath $ConfigPath -FromWatcher 4>&1 5>&1 | Out-Null
                Write-WLog 'Sync finished.'
            } catch {
                Write-WLog ('Sync error: ' + $_.Exception.Message)
            }
        }
    } catch {
        Write-WLog ('Watcher loop error: ' + $_.Exception.Message)
    }
    Start-Sleep -Seconds $poll
}
