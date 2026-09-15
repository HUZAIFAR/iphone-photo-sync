<#
.SYNOPSIS
    Groups the catalog into trips / events, and optionally builds browsable
    folders of hard links (which cost no extra disk space).

.DESCRIPTION
    Clustering rules, in order:
      1. Photos are sorted by capture time.
      2. A gap longer than -GapHours starts a new cluster.
      3. If GPS exists, a jump further than -JumpKm also starts a new cluster.
      4. Clusters smaller than -MinItems are dropped as noise.
      5. A cluster is labelled a TRIP if its centre is more than -HomeKm from
         home, otherwise it is an EVENT. "Home" is inferred as the place you
         have the most photos of - no lookups, no network.

    Nothing is moved, copied or modified. With -MakeFolders you get
    Groups\<name>\ full of hard links: the same bytes on disk, browsable as if
    they were copies. Delete a Groups folder any time; the library is untouched.

.EXAMPLE
    .\Group-Trips.ps1
    .\Group-Trips.ps1 -MakeFolders
    .\Group-Trips.ps1 -GapHours 8 -JumpKm 75 -MinItems 15 -MakeFolders
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [double] $GapHours = 14,
    [double] $JumpKm   = 60,
    [int]    $MinItems = 8,
    [double] $HomeKm   = 40,
    [switch] $MakeFolders,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'config.json' }
$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

function ConvertTo-WinPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    # Expands %ENV% vars so config.json can ship portable paths like
    # %USERPROFILE%\Pictures instead of a hard-coded C:\Users\<name>\...
    $Path = [Environment]::ExpandEnvironmentVariables($Path)
    return ($Path -replace '/', '\').TrimEnd('\')
}

$LibraryPath = ConvertTo-WinPath $cfg.LibraryPath
$StateDir    = Join-Path $Root 'state'
$CatalogPath = Join-Path $StateDir 'catalog.jsonl'
$GroupsDir   = Join-Path $Root 'Groups'
$TripsJson   = Join-Path $StateDir 'trips.json'

if (-not (Test-Path -LiteralPath $CatalogPath)) {
    Write-Host "No catalog yet. Run .\Rebuild-Catalog.ps1 first." -ForegroundColor Yellow
    return
}

function Get-DistanceKm {
    param([double]$Lat1, [double]$Lon1, [double]$Lat2, [double]$Lon2)
    $R = 6371.0
    $dLat = ($Lat2 - $Lat1) * [Math]::PI / 180.0
    $dLon = ($Lon2 - $Lon1) * [Math]::PI / 180.0
    $a = [Math]::Sin($dLat/2) * [Math]::Sin($dLat/2) +
         [Math]::Cos($Lat1 * [Math]::PI/180.0) * [Math]::Cos($Lat2 * [Math]::PI/180.0) *
         [Math]::Sin($dLon/2) * [Math]::Sin($dLon/2)
    return $R * 2 * [Math]::Atan2([Math]::Sqrt($a), [Math]::Sqrt(1-$a))
}

# ------------------------------------------------------------- load ---------
$items = New-Object System.Collections.ArrayList
foreach ($line in [IO.File]::ReadLines($CatalogPath)) {
    if (-not $line) { continue }
    try {
        $o = $line | ConvertFrom-Json
        if ($o.Kind -eq 'sidecar') { continue }
        $dt = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$o.DateTaken, [ref]$dt)) { continue }
        [void]$items.Add([pscustomobject]@{
            File = [string]$o.File
            Name = [string]$o.Name
            When = $dt
            Lat  = $(if ($o.PSObject.Properties.Name -contains 'GpsLat') { [double]$o.GpsLat } else { $null })
            Lon  = $(if ($o.PSObject.Properties.Name -contains 'GpsLon') { [double]$o.GpsLon } else { $null })
            Kind = [string]$o.Kind
        })
    } catch { }
}

if ($items.Count -eq 0) { Write-Host 'Catalog is empty.' -ForegroundColor Yellow; return }
$items = @($items | Sort-Object When)
$gpsItems = @($items | Where-Object { $null -ne $_.Lat })

Write-Host ''
Write-Host ('  {0:N0} catalogued item(s), {1:N0} with GPS.' -f $items.Count, $gpsItems.Count) -ForegroundColor Cyan

# ------------------------------------------------------------- home ---------
# Home is the ~11km cell where you took photos on the most DISTINCT DAYS.
#
# Counting photos instead of days gets this badly wrong: one camera-happy
# fortnight abroad easily outnumbers a whole year of occasional photos at home,
# and then every real trip gets scored as "home" and disappears. Days spread
# across the calendar is what actually distinguishes where you live.
# Purely local - no lookups, no network.
$homeSpot = $null
if ($gpsItems.Count -gt 0) {
    $cells = @{}
    foreach ($i in $gpsItems) {
        $k = '{0:N1}|{1:N1}' -f $i.Lat, $i.Lon
        if (-not $cells.ContainsKey($k)) {
            $cells[$k] = [pscustomobject]@{
                Items = (New-Object System.Collections.ArrayList)
                Days  = (New-Object 'System.Collections.Generic.HashSet[string]')
            }
        }
        [void]$cells[$k].Items.Add($i)
        [void]$cells[$k].Days.Add($i.When.ToString('yyyy-MM-dd'))
    }
    $best = ($cells.GetEnumerator() |
             Sort-Object @{E={$_.Value.Days.Count}}, @{E={$_.Value.Items.Count}} -Descending |
             Select-Object -First 1)
    if ($best) {
        $homeSpot = [pscustomobject]@{
            Lat  = ($best.Value.Items | Measure-Object -Property Lat -Average).Average
            Lon  = ($best.Value.Items | Measure-Object -Property Lon -Average).Average
            N    = $best.Value.Items.Count
            Days = $best.Value.Days.Count
        }
        Write-Host ('  Home looks like {0:N4}, {1:N4}  ({2:N0} photos across {3:N0} separate days).' -f `
            $homeSpot.Lat, $homeSpot.Lon, $homeSpot.N, $homeSpot.Days)
    }
}

# ---------------------------------------------------------- clustering ------
$clusters = New-Object System.Collections.ArrayList
$cur      = New-Object System.Collections.ArrayList
$lastGps  = $null

foreach ($i in $items) {
    $split = $false
    if ($cur.Count -gt 0) {
        $prev = $cur[$cur.Count - 1]
        if (($i.When - $prev.When).TotalHours -gt $GapHours) { $split = $true }
        if (-not $split -and $null -ne $i.Lat -and $null -ne $lastGps) {
            if ((Get-DistanceKm $lastGps.Lat $lastGps.Lon $i.Lat $i.Lon) -gt $JumpKm) { $split = $true }
        }
    }
    if ($split) { [void]$clusters.Add($cur); $cur = New-Object System.Collections.ArrayList }
    [void]$cur.Add($i)
    if ($null -ne $i.Lat) { $lastGps = $i }
}
if ($cur.Count -gt 0) { [void]$clusters.Add($cur) }

# ------------------------------------------------------------ describe -----
$groups = New-Object System.Collections.ArrayList
foreach ($c in $clusters) {
    if ($c.Count -lt $MinItems) { continue }
    $start = $c[0].When
    $end   = $c[$c.Count - 1].When
    $days  = [Math]::Max(1, [int][Math]::Ceiling(($end - $start).TotalDays))

    $g = @($c | Where-Object { $null -ne $_.Lat })
    $lat = $null; $lon = $null; $distHome = $null
    if ($g.Count -gt 0) {
        $lat = ($g | Measure-Object -Property Lat -Average).Average
        $lon = ($g | Measure-Object -Property Lon -Average).Average
        if ($homeSpot) { $distHome = [Math]::Round((Get-DistanceKm $homeSpot.Lat $homeSpot.Lon $lat $lon), 1) }
    }

    $type = 'event'
    if ($null -ne $distHome -and $distHome -gt $HomeKm) { $type = 'trip' }

    $label = if ($start.Date -eq $end.Date) { $start.ToString('yyyy-MM-dd') }
             else { '{0} to {1}' -f $start.ToString('yyyy-MM-dd'), $end.ToString('yyyy-MM-dd') }
    $name = '{0} - {1} items' -f $label, $c.Count
    if ($type -eq 'trip') { $name = '{0} - TRIP - {1} items' -f $label, $c.Count }

    [void]$groups.Add([pscustomobject]@{
        Name       = $name
        Type       = $type
        Start      = $start.ToString('s')
        End        = $end.ToString('s')
        Days       = $days
        Count      = $c.Count
        Photos     = @($c | Where-Object { $_.Kind -eq 'image' }).Count
        Videos     = @($c | Where-Object { $_.Kind -eq 'video' }).Count
        Lat        = $(if ($null -ne $lat) { [Math]::Round($lat, 5) } else { $null })
        Lon        = $(if ($null -ne $lon) { [Math]::Round($lon, 5) } else { $null })
        KmFromHome = $distHome
        Files      = @($c | ForEach-Object { $_.File })
    })
}

$trips = @($groups | Where-Object { $_.Type -eq 'trip' })
Write-Host ('  {0:N0} group(s): {1:N0} trip(s), {2:N0} event(s).' -f $groups.Count, $trips.Count, ($groups.Count - $trips.Count))
Write-Host ''

if (-not $Quiet) {
    foreach ($g in ($groups | Sort-Object Start -Descending | Select-Object -First 25)) {
        $where = if ($null -ne $g.KmFromHome) { '{0:N0} km away' -f $g.KmFromHome }
                 elseif ($null -ne $g.Lat)    { 'located' }
                 else                         { 'no GPS' }
        $colour = if ($g.Type -eq 'trip') { 'Cyan' } else { 'Gray' }
        Write-Host ('   {0,-46} {1,5} items  {2,2}d  {3}' -f $g.Name, $g.Count, $g.Days, $where) -ForegroundColor $colour
    }
    if ($groups.Count -gt 25) { Write-Host ('   ... and {0:N0} more (see trips.json)' -f ($groups.Count - 25)) }
    Write-Host ''
}

($groups | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $TripsJson -Encoding UTF8
Write-Host ('  Written: {0}' -f $TripsJson) -ForegroundColor Green

# --------------------------------------------------------- hard links ------
if ($MakeFolders) {
    Write-Host ''
    Write-Host '  Building Groups\ (hard links - no extra disk space used)...' -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $GroupsDir)) { New-Item -ItemType Directory -Path $GroupsDir -Force | Out-Null }

    $made = 0; $linkFail = 0
    foreach ($g in $groups) {
        $safe = ($g.Name -replace '[<>:"/\\|?*]', '-')
        $dir  = Join-Path $GroupsDir $safe
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        foreach ($rel in $g.Files) {
            $src = Join-Path $LibraryPath $rel
            $dst = Join-Path $dir (Split-Path -Leaf $rel)
            if (Test-Path -LiteralPath $dst) { continue }
            if (-not (Test-Path -LiteralPath $src)) { continue }
            try { New-Item -ItemType HardLink -Path $dst -Target $src -ErrorAction Stop | Out-Null; $made++ }
            catch { $linkFail++ }
        }
    }
    Write-Host ('  {0:N0} link(s) created in {1}' -f $made, $GroupsDir) -ForegroundColor Green
    if ($linkFail -gt 0) {
        Write-Host ("  {0:N0} link(s) failed - hard links need the library and Groups on the same NTFS volume." -f $linkFail) -ForegroundColor Yellow
    }
    Write-Host '  Rename these folders freely; re-running rebuilds only what is missing.'
}
Write-Host ''
