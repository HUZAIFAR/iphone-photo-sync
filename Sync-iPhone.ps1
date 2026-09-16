<#
.SYNOPSIS
    Incremental one-way sync of iPhone/iPad camera roll (DCIM) to a local library
    over USB / MTP. No iCloud, no iTunes, no third-party software.

.DESCRIPTION
    Phase 1  scan every DCIM album, size each item, work out what is new.
    Phase 2  copy the new items in small chunks, verify each by byte size,
             file into Library\YYYY\YYYY-MM\, record in an append-only index.

    While running it publishes state\status.json (for the GUI) and obeys
    state\pause.flag and state\stop.flag. Unplugging the phone mid-run is safe:
    the run ends cleanly and the next connection resumes where it stopped.

.NOTES
    Needs nothing but Windows + PowerShell 5.1. Phone unlocked, "Trust" tapped.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [int]    $UnlockWaitSeconds = -1,
    [switch] $FromWatcher,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:Root 'config.json' }

# ---------------------------------------------------------------- config ----
$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

function ConvertTo-WinPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    # Expands %ENV% vars so config.json can ship portable paths like
    # %USERPROFILE%\Pictures instead of a hard-coded C:\Users\<name>\...
    $Path = [Environment]::ExpandEnvironmentVariables($Path)
    return ($Path -replace '/', '\').TrimEnd('\')
}

$LibraryPath    = ConvertTo-WinPath $cfg.LibraryPath
$cfg.BackupPath = ConvertTo-WinPath $cfg.BackupPath
$StateDir       = Join-Path $script:Root 'state'
$LogDir         = Join-Path $script:Root 'logs'
$StageDir       = Join-Path $script:Root '.staging'
$IndexPath      = Join-Path $StateDir 'index.tsv'
$CatalogPath    = Join-Path $StateDir 'catalog.jsonl'
$StatusPath     = Join-Path $StateDir 'status.json'
$PauseFlag      = Join-Path $StateDir 'pause.flag'
$StopFlag       = Join-Path $StateDir 'stop.flag'

if ($UnlockWaitSeconds -lt 0) { $UnlockWaitSeconds = [int]$cfg.UnlockWaitSeconds }
$ChunkSize = 25
if ($cfg.PSObject.Properties.Name -contains 'ChunkSize' -and [int]$cfg.ChunkSize -gt 0) {
    $ChunkSize = [int]$cfg.ChunkSize
}

foreach ($d in @($LibraryPath, $StateDir, $LogDir, $StageDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# Metadata capture (see lib\Metadata.ps1). Originals always keep their own EXIF;
# the catalog is a derived index and can be rebuilt at any time.
. (Join-Path $script:Root 'lib\Metadata.ps1')
$CaptureMetadata = $true
$HashFiles       = $true
if ($cfg.PSObject.Properties.Name -contains 'CaptureMetadata') { $CaptureMetadata = [bool]$cfg.CaptureMetadata }
if ($cfg.PSObject.Properties.Name -contains 'HashFiles')       { $HashFiles       = [bool]$cfg.HashFiles }
$ExifTool = Get-ExifToolPath

$LogPath = Join-Path $LogDir ('sync-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO')
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

# ------------------------------------------------------------ status file ---
$script:Status = [ordered]@{
    State           = 'Starting'   # Starting|Waiting|Scanning|Copying|Paused|Stopping|Idle|Error
    Phase           = 'Starting up'
    Device          = ''
    Album           = ''
    AlbumIndex      = 0
    AlbumCount      = 0
    CurrentFile     = ''
    CurrentDate     = ''
    Done            = 0
    Total           = 0
    Failed          = 0
    AlreadyHad      = 0
    Bytes           = 0
    TotalBytes      = 0
    BytesPerSec     = 0
    EtaSeconds      = -1
    StartedUtc      = (Get-Date).ToUniversalTime().ToString('o')
    UpdatedUtc      = ''
    FinishedUtc     = ''
    LastResult      = ''
    Pid             = $PID
}
$script:LastStatusWrite = [DateTime]::MinValue

function Set-Status {
    param([hashtable]$Patch, [switch]$Force)
    if ($Patch) { foreach ($k in $Patch.Keys) { $script:Status[$k] = $Patch[$k] } }
    if (-not $Force -and ((Get-Date) - $script:LastStatusWrite).TotalMilliseconds -lt 400) { return }
    $script:LastStatusWrite = Get-Date
    $script:Status['UpdatedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
    try {
        $json = ($script:Status | ConvertTo-Json -Compress -Depth 4)
        $tmp  = $StatusPath + '.tmp'
        [IO.File]::WriteAllText($tmp, $json, [Text.Encoding]::UTF8)
        [IO.File]::Copy($tmp, $StatusPath, $true)
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Test-StopRequested { return (Test-Path -LiteralPath $StopFlag) }

function Wait-WhilePaused {
    if (-not (Test-Path -LiteralPath $PauseFlag)) { return }
    $prev = $script:Status['State']
    Write-Log 'Paused by user.' 'WARN'
    Set-Status @{ State = 'Paused'; Phase = 'Paused - press Resume' } -Force
    while ((Test-Path -LiteralPath $PauseFlag) -and -not (Test-StopRequested)) {
        Start-Sleep -Milliseconds 400
        Set-Status @{} -Force
    }
    if (-not (Test-StopRequested)) {
        Write-Log 'Resumed.' 'OK'
        Set-Status @{ State = $prev; Phase = 'Resuming' } -Force
    }
}

function Show-Toast {
    param([string]$Title, [string]$Text)
    if (-not $cfg.Notify) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon    = [System.Drawing.SystemIcons]::Information
        $ni.Visible = $true
        $ni.ShowBalloonTip(10000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Seconds 5
        $ni.Visible = $false
        $ni.Dispose()
    } catch { }
}

# --------------------------------------------------------- single instance --
$mutex = New-Object System.Threading.Mutex($false, 'Global\iPhonePhotoSync')
if (-not $mutex.WaitOne(0)) {
    Write-Log 'Another sync is already running. Exiting.' 'WARN'
    return
}

# Stale one-shot commands from a previous run.
Remove-Item -LiteralPath $StopFlag  -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $PauseFlag -Force -ErrorAction SilentlyContinue
Set-Status @{ State = 'Starting'; Phase = 'Looking for device' } -Force

# --------------------------------------------------------------- shell API --
$SHCONTF = 4 + 16 + 512 + 1024   # no progress UI, yes-to-all, no confirm, no error UI
$shell   = New-Object -ComObject Shell.Application

function Get-SubFolder {
    param($Folder, [string]$NamePattern)
    if (-not $Folder) { return $null }
    foreach ($it in $Folder.Items()) {
        if ($it.IsFolder -and $it.Name -match $NamePattern) { return $it.GetFolder }
    }
    return $null
}

function Get-DeviceDcim {
    <#
        Returns the folder whose SUBFOLDERS hold the camera roll, or $null when
        the device is absent or still locked.

        iPhones present two different layouts over MTP:
          classic   Internal Storage\DCIM\100APPLE\IMG_0001.HEIC
          bucketed  Internal Storage\202403_a\ARQM0324     (no DCIM level at all,
                    month-bucketed folder names, and no file extensions)
        Only handling the first one made the second look identical to "phone is
        locked", because no folder called DCIM ever turned up.
    #>
    $thisPC = $shell.NameSpace(17)
    if (-not $thisPC) { return $null }
    foreach ($dev in $thisPC.Items()) {
        if (-not $dev.IsFolder) { continue }
        if ($dev.Name -notmatch $cfg.DeviceNamePattern) { continue }
        $devFolder = $dev.GetFolder
        if (-not $devFolder) { continue }

        # The device root plus each storage below it ("Internal Storage").
        $candidates = New-Object System.Collections.ArrayList
        [void]$candidates.Add($devFolder)
        try {
            foreach ($sub in $devFolder.Items()) {
                if ($sub.IsFolder) { [void]$candidates.Add($sub.GetFolder) }
            }
        } catch { }

        # 1. Classic layout wins if a real DCIM exists.
        foreach ($store in $candidates) {
            $dcim = Get-SubFolder $store '^DCIM$'
            if ($dcim) {
                $script:DeviceLabel  = $dev.Name
                $script:DeviceLayout = 'DCIM'
                return $dcim
            }
        }

        # 2. Otherwise look for media-shaped buckets: 202403_a or 100APPLE.
        foreach ($store in $candidates) {
            try {
                $subs = @($store.Items() | Where-Object { $_.IsFolder })
                $mediaish = @($subs | Where-Object {
                    $_.Name -match '^\d{6}_[A-Za-z]$' -or $_.Name -match '^\d{3}[A-Z]{3,6}$'
                })
                if ($mediaish.Count -ge 1) {
                    $script:DeviceLabel  = $dev.Name
                    $script:DeviceLayout = 'bucketed'
                    return $store
                }
            } catch { }
        }
    }
    return $null
}

function Test-DeviceStillThere {
    try {
        $thisPC = $shell.NameSpace(17)
        if (-not $thisPC) { return $false }
        foreach ($dev in $thisPC.Items()) {
            if ($dev.IsFolder -and $dev.Name -match $cfg.DeviceNamePattern) { return $true }
        }
    } catch { }
    return $false
}

function Wait-ForStagedFile {
    param([string]$Path, [long]$ExpectedSize, [int]$TimeoutSec = 240)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastLen  = -1
    $stable   = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $len = (Get-Item -LiteralPath $Path).Length
            if ($len -eq $lastLen -and ($ExpectedSize -le 0 -or $len -eq $ExpectedSize)) {
                $stable++
                if ($stable -ge 2) { return $true }
            } else { $stable = 0 }
            $lastLen = $len
        }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

# ------------------------------------------------------------------ index ---
$index = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $IndexPath) {
    foreach ($line in [System.IO.File]::ReadLines($IndexPath)) {
        if ($line.Length -gt 0) { [void]$index.Add(($line -split "`t")[0]) }
    }
}
Write-Log ("Index holds {0} previously synced item(s)." -f $index.Count)

function Get-UniqueDest {
    param([string]$Dir, [string]$Name, [long]$Size)
    $base = [IO.Path]::GetFileNameWithoutExtension($Name)
    $ext  = [IO.Path]::GetExtension($Name)
    $p    = Join-Path $Dir $Name
    $n    = 1
    while (Test-Path -LiteralPath $p) {
        $existing = Get-Item -LiteralPath $p
        if ($Size -gt 0 -and $existing.Length -eq $Size) { return $null }   # identical -> skip
        $n++
        $p = Join-Path $Dir ("{0}_{1}{2}" -f $base, $n, $ext)
    }
    return $p
}

function Complete-StagedFile {
    param([string]$StagedPath, [string]$Key, [long]$ExpectedSize, [string]$Album)
    $fi = Get-Item -LiteralPath $StagedPath
    if ($ExpectedSize -gt 0 -and $fi.Length -ne $ExpectedSize) {
        Write-Log ("Size mismatch for {0} ({1} vs {2}) - discarded, will retry next run." -f $fi.Name, $fi.Length, $ExpectedSize) 'WARN'
        Remove-Item -LiteralPath $StagedPath -Force -ErrorAction SilentlyContinue
        return $null
    }
    # Some iPhones hand over names with no extension at all ("ARQM0324"). Sniff
    # the real type from the file header so what lands on disk is openable.
    $outName = $fi.Name
    if (-not [IO.Path]::GetExtension($outName)) {
        $sniffed = Get-ExtensionFromContent -Path $StagedPath
        if ($sniffed) { $outName = $outName + $sniffed }
    }

    $stamp = $fi.LastWriteTime
    if ($stamp.Year -lt 2000 -or $stamp -gt (Get-Date).AddDays(2)) { $stamp = Get-Date }
    $bucket = '{0}-{1:00}' -f $stamp.Year, $stamp.Month

    if ($cfg.OrganizeByDate) {
        $destDir = Join-Path $LibraryPath ('{0}\{1}' -f $stamp.Year, $bucket)
    } else {
        $destDir = $LibraryPath
    }
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

    $dest = Get-UniqueDest -Dir $destDir -Name $outName -Size $fi.Length
    $script:LastBucket = $bucket
    if ($null -eq $dest) {
        Remove-Item -LiteralPath $StagedPath -Force -ErrorAction SilentlyContinue
        $script:idxWriter.WriteLine(("{0}`t{1}`t{2}" -f $Key, '(duplicate)', (Get-Date -Format s)))
        return [long]0
    }
    Move-Item -LiteralPath $StagedPath -Destination $dest -Force
    $rel = $dest.Substring($LibraryPath.Length).TrimStart('\')
    $script:idxWriter.WriteLine(("{0}`t{1}`t{2}" -f $Key, $rel, (Get-Date -Format s)))

    # --- catalog record (derived; rebuildable from the file at any time) ---
    if ($script:CaptureMetadata -and $script:catWriter) {
        try {
            $rec = Get-PhotoMetadata -Path $dest -RelativePath $rel -Key $Key `
                                     -Album $Album -ExifTool $script:ExifTool -Hash:$script:HashFiles
            $script:catWriter.WriteLine(($rec | ConvertTo-Json -Compress -Depth 4))
        } catch {
            Write-Log ("  metadata capture failed for {0}: {1}" -f $fi.Name, $_.Exception.Message) 'WARN'
        }
    }
    return [long]$fi.Length
}

# ------------------------------------------------------------------- main ---
$sw = [Diagnostics.Stopwatch]::StartNew()
Write-Log '================ sync started ================'

# --- find the device, waiting for unlock if asked to -------------------------
Set-Status @{ State = 'Waiting'; Phase = 'Waiting for an unlocked iPhone' } -Force
$dcim         = $null
$waitDeadline = (Get-Date).AddSeconds($UnlockWaitSeconds)
do {
    if (Test-StopRequested) { break }
    $dcim = Get-DeviceDcim
    if ($dcim) { break }
    if ($UnlockWaitSeconds -le 0) { break }
    Start-Sleep -Seconds 3
    Set-Status @{} -Force
} while ((Get-Date) -lt $waitDeadline)

if (-not $dcim -or (Test-StopRequested)) {
    $msg = if (Test-StopRequested) { 'Stopped before it began.' } else { 'No unlocked iPhone/iPad found. Plug it in, unlock it, and tap Trust.' }
    Write-Log $msg 'WARN'
    Set-Status @{ State = 'Idle'; Phase = 'Not connected'; LastResult = $msg
                  FinishedUtc = (Get-Date).ToUniversalTime().ToString('o') } -Force
    Remove-Item -LiteralPath $StopFlag -Force -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
    return
}
Write-Log ("Device: {0}" -f $script:DeviceLabel) 'OK'
Set-Status @{ Device = $script:DeviceLabel } -Force

# Clear leftovers from any crashed run.
Get-ChildItem -LiteralPath $StageDir -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

$stageNs = $shell.NameSpace($StageDir)
$script:idxWriter = New-Object System.IO.StreamWriter($IndexPath, $true, [Text.Encoding]::UTF8)
$script:idxWriter.AutoFlush = $true
$script:catWriter = $null
if ($CaptureMetadata) {
    $script:catWriter = New-Object System.IO.StreamWriter($CatalogPath, $true, [Text.Encoding]::UTF8)
    $script:catWriter.AutoFlush = $true
    if ($ExifTool) { Write-Log ("Metadata: exiftool ({0})" -f $ExifTool) }
    else { Write-Log 'Metadata: Windows property system (install exiftool for full HEIC/GPS support)' }
}

$copied = 0; $failed = 0; $skipped = 0
[long]$bytes = 0
$stoppedEarly = $false
$disconnected = $false
$rateSamples  = New-Object System.Collections.ArrayList

try {
    # ------------------------------------------------------- phase 1: scan --
    Set-Status @{ State = 'Scanning'; Phase = 'Scanning camera roll' } -Force
    $rollFolders = @($dcim.Items() | Where-Object { $_.IsFolder })
    Write-Log ("Found {0} album folder(s) in DCIM." -f $rollFolders.Count)
    Set-Status @{ AlbumCount = $rollFolders.Count } -Force

    $work    = New-Object System.Collections.ArrayList
    $scanned = 0
    $ai      = 0

    foreach ($rollItem in $rollFolders) {
        if (Test-StopRequested) { $stoppedEarly = $true; break }
        Wait-WhilePaused
        if (Test-StopRequested) { $stoppedEarly = $true; break }

        $ai++
        $rollName = $rollItem.Name
        $roll     = $rollItem.GetFolder
        Set-Status @{ Album = $rollName; AlbumIndex = $ai
                      Phase = ("Scanning {0} ({1} of {2})" -f $rollName, $ai, $rollFolders.Count) } -Force

        $newHere = 0
        foreach ($it in $roll.Items()) {
            if ($it.IsFolder) { continue }
            $scanned++
            $size = 0
            try { $size = [long]$it.ExtendedProperty('System.Size') } catch { }
            if ($size -le 0) { try { $size = [long]$it.Size } catch { $size = 0 } }
            $key = '{0}/{1}|{2}' -f $rollName, $it.Name, $size
            if ($index.Contains($key)) {
                $skipped++
            } else {
                [void]$work.Add([pscustomobject]@{
                    Album = $rollName; Name = $it.Name; Size = $size; Key = $key; Item = $it
                })
                $newHere++
            }
            if (($scanned % 100) -eq 0) {
                Set-Status @{ Total = $work.Count; AlreadyHad = $skipped
                              CurrentFile = ("{0} items scanned" -f $scanned) }
            }
        }
        Write-Log ("{0}: {1} new." -f $rollName, $newHere)
    }

    [long]$totalBytes = 0
    foreach ($w in $work) { $totalBytes += $w.Size }
    Write-Log ("Scan complete: {0} scanned, {1} already had, {2} to copy ({3:N1} GB)." -f `
        $scanned, $skipped, $work.Count, ($totalBytes / 1GB))
    Set-Status @{ Total = $work.Count; TotalBytes = $totalBytes; AlreadyHad = $skipped
                  CurrentFile = '' } -Force

    if ($DryRun) { $copied = $work.Count; $work.Clear() }

    # ------------------------------------------------------- phase 2: copy --
    if ($work.Count -gt 0 -and -not $stoppedEarly) {
        Set-Status @{ State = 'Copying'; Phase = 'Importing' } -Force
        $copyStart = Get-Date
        [void]$rateSamples.Add([pscustomobject]@{ T = $copyStart; B = [long]0 })

        for ($i = 0; $i -lt $work.Count; $i += $ChunkSize) {
            if (Test-StopRequested) { $stoppedEarly = $true; break }
            Wait-WhilePaused
            if (Test-StopRequested) { $stoppedEarly = $true; break }

            $slice = $work[$i..([Math]::Min($i + $ChunkSize - 1, $work.Count - 1))]

            foreach ($e in $slice) {
                try { $stageNs.CopyHere($e.Item, $SHCONTF) }
                catch { Write-Log ("  CopyHere failed for {0}: {1}" -f $e.Name, $_.Exception.Message) 'WARN' }
            }

            $chunkTimeouts = 0
            foreach ($e in $slice) {
                $sp = Join-Path $StageDir $e.Name
                Set-Status @{ CurrentFile = $e.Name; Album = $e.Album }
                if (Wait-ForStagedFile -Path $sp -ExpectedSize $e.Size) {
                    $r = Complete-StagedFile -StagedPath $sp -Key $e.Key -ExpectedSize $e.Size -Album $e.Album
                    if ($null -ne $r) {
                        $copied++; $bytes += $r; [void]$index.Add($e.Key)
                    } else { $failed++ }
                } else {
                    Write-Log ("  timed out copying {0} - will retry next run." -f $e.Name) 'WARN'
                    $failed++; $chunkTimeouts++
                    Remove-Item -LiteralPath $sp -Force -ErrorAction SilentlyContinue
                }
                Set-Status @{ Done = $copied; Failed = $failed; Bytes = $bytes
                              CurrentDate = $script:LastBucket }
            }

            # --- throughput + ETA over a rolling window ---------------------
            [void]$rateSamples.Add([pscustomobject]@{ T = (Get-Date); B = $bytes })
            while ($rateSamples.Count -gt 40) { $rateSamples.RemoveAt(0) }
            $first = $rateSamples[0]; $last = $rateSamples[$rateSamples.Count - 1]
            $span  = ($last.T - $first.T).TotalSeconds
            $bps   = 0; $eta = -1
            if ($span -gt 1) {
                $bps = [long](($last.B - $first.B) / $span)
                if ($bps -gt 0) {
                    $remaining = $totalBytes - $bytes
                    if ($remaining -lt 0) { $remaining = 0 }
                    $eta = [int]($remaining / $bps)
                }
            }
            Set-Status @{ BytesPerSec = $bps; EtaSeconds = $eta
                          Phase = ("Importing {0:N0} of {1:N0}" -f $copied, $work.Count) } -Force

            Write-Log ("  {0}/{1} done ({2:N1} GB)" -f ([Math]::Min($i + $ChunkSize, $work.Count)), $work.Count, ($bytes / 1GB))

            # --- did the phone go away? -------------------------------------
            if ($chunkTimeouts -ge [Math]::Min(5, $slice.Count) -and -not (Test-DeviceStillThere)) {
                Write-Log 'Device disconnected - stopping cleanly. Reconnect to resume.' 'WARN'
                $disconnected = $true
                break
            }
        }
    }
}
catch {
    Write-Log ('Unhandled error: ' + $_.Exception.Message) 'ERROR'
    Set-Status @{ State = 'Error'; Phase = $_.Exception.Message } -Force
}
finally {
    if ($script:idxWriter) { $script:idxWriter.Flush(); $script:idxWriter.Dispose() }
    if ($script:catWriter) { $script:catWriter.Flush(); $script:catWriter.Dispose() }
    Get-ChildItem -LiteralPath $StageDir -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { }
}

$sw.Stop()
$verb = 'Finished'
if ($disconnected) { $verb = 'Interrupted (phone unplugged)' }
elseif ($stoppedEarly) { $verb = 'Stopped by you' }

$result = '{0}: {1:N0} new, {2:N0} already had, {3} failed, {4:N1} GB in {5:hh\:mm\:ss}' -f `
    $verb, $copied, $skipped, $failed, ($bytes / 1GB), $sw.Elapsed
Write-Log ("RESULT: " + $result) 'OK'

Set-Status @{ State = 'Idle'; Phase = $verb; CurrentFile = ''; LastResult = $result
              EtaSeconds = -1; BytesPerSec = 0
              FinishedUtc = (Get-Date).ToUniversalTime().ToString('o') } -Force
Remove-Item -LiteralPath $StopFlag  -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $PauseFlag -Force -ErrorAction SilentlyContinue

# ----------------------------------------------------------- second copy ----
if ($cfg.BackupPath -and -not $DryRun -and $copied -gt 0) {
    $bDrive = Split-Path -Qualifier $cfg.BackupPath
    if (Test-Path -LiteralPath ($bDrive + '\')) {
        Write-Log ("Mirroring library to {0} ..." -f $cfg.BackupPath)
        Set-Status @{ State = 'Copying'; Phase = 'Mirroring to backup drive' } -Force
        $rcArgs = @($LibraryPath, $cfg.BackupPath, '/E', '/COPY:DAT', '/DCOPY:DAT',
                    '/R:1', '/W:2', '/MT:8', '/NFL', '/NDL', '/NJH', '/NP',
                    ('/LOG+:' + $LogPath))
        if ($cfg.MirrorDeletes) { $rcArgs += '/PURGE' }
        & robocopy.exe @rcArgs | Out-Null
        if ($LASTEXITCODE -lt 8) { Write-Log 'Mirror complete.' 'OK' }
        else { Write-Log ("robocopy reported errors (exit {0}); see log." -f $LASTEXITCODE) 'ERROR' }
        Set-Status @{ State = 'Idle'; Phase = $verb } -Force
    } else {
        Write-Log ("Backup drive {0} not present - mirror skipped." -f $bDrive) 'WARN'
    }
}

# ------------------------------------------------------------- log prune ----
try {
    Get-ChildItem -LiteralPath $LogDir -Filter 'sync-*.log' |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-[int]$cfg.LogRetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

if ($copied -gt 0) {
    Show-Toast 'iPhone photo sync' ("Imported {0:N0} new item(s), {1:N1} GB." -f $copied, ($bytes / 1GB))
} elseif (-not $FromWatcher) {
    Show-Toast 'iPhone photo sync' 'Nothing new - library is up to date.'
}

$mutex.ReleaseMutex()
