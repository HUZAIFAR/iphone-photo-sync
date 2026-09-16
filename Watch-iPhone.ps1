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
$StatusPath = Join-Path $StateDir 'status.json'

# Watchdog thresholds (overridable in config.json).
$StallSeconds    = 300
$MaxAutoRestarts = 5
if ($cfg.PSObject.Properties.Name -contains 'StallSeconds' -and [int]$cfg.StallSeconds -gt 0) {
    $StallSeconds = [int]$cfg.StallSeconds
}
if ($cfg.PSObject.Properties.Name -contains 'MaxAutoRestarts') {
    $MaxAutoRestarts = [int]$cfg.MaxAutoRestarts
}
$script:Restarts = 0

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
            # Fresh connection: allow the full restart budget again, otherwise a
            # few wedges in one session would disable recovery permanently.
            $script:Restarts = 0
        }
        elseif (-not $present -and $wasPresent) {
            Write-WLog 'Device disconnected.'
        }
        $wasPresent = $present

        # Report a finished sync without having blocked on it.
        if ($script:SyncProc -and $script:SyncProc.HasExited) {
            Write-WLog ('Sync finished (exit {0}).' -f $script:SyncProc.ExitCode)
            $script:SyncProc = $null
        }

        # --- watchdog -------------------------------------------------------
        # An MTP session can wedge permanently: the sync blocks inside a COM call
        # that never returns, so it stops copying, stops logging, and cannot even
        # honour Pause or Stop because it never reaches the check. Nothing was
        # watching for that, so a transfer could sit dead for hours.
        # If a sync claims to be running but has not published status for a while,
        # kill it. The index makes restarting free - it resumes where it stopped.
        if (Test-Path -LiteralPath $StatusPath) {
            try {
                $st = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
                $active = @('Starting','Waiting','Scanning','Copying','Stopping') -contains $st.State
                if ($active -and $st.Pid) {
                    $age = ((Get-Date).ToUniversalTime() - [datetime]::Parse($st.UpdatedUtc).ToUniversalTime()).TotalSeconds
                    if ($age -gt $StallSeconds) {
                        $victim = Get-Process -Id $st.Pid -ErrorAction SilentlyContinue
                        if ($victim) {
                            Write-WLog ("Sync pid {0} wedged - no status for {1}s. Killing it." -f $st.Pid, [int]$age)
                            Stop-Process -Id $st.Pid -Force -ErrorAction SilentlyContinue
                            $script:SyncProc = $null
                            if ($script:Restarts -lt $MaxAutoRestarts) {
                                $script:Restarts++
                                $syncedThis = $false   # let the loop start a fresh one
                                Write-WLog ("Will restart it (attempt {0} of {1})." -f $script:Restarts, $MaxAutoRestarts)
                            } else {
                                Write-WLog "Restart limit reached; unplug and replug to try again."
                            }
                        }
                    }
                }
            } catch { }
        }

        if ($present -and -not $syncedThis) {
            # Give Windows a moment to finish mounting the MTP store.
            Start-Sleep -Seconds 3
            Write-WLog 'Starting sync (will wait for unlock if needed).'
            $syncedThis = $true
            try {
                # Launched as its own process, NOT called inline. Running it inline
                # froze this polling loop for the whole sync, so the heartbeat in
                # device.json went stale and the dashboard showed "Auto-sync off"
                # during the one time it mattered most. Staying responsive also
                # means we keep noticing the phone being unplugged.
                $script:SyncProc = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
                    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
                    '-File', ('"{0}"' -f $syncScript),
                    '-ConfigPath', ('"{0}"' -f $ConfigPath),
                    '-FromWatcher'
                )
            } catch {
                Write-WLog ('Sync error: ' + $_.Exception.Message)
            }
        }
    } catch {
        Write-WLog ('Watcher loop error: ' + $_.Exception.Message)
    }
    Start-Sleep -Seconds $poll
}
