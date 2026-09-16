<#
    Metadata extraction, dot-sourced by Sync-iPhone.ps1 and Rebuild-Catalog.ps1.

    IMPORTANT: this only ever READS metadata. The authoritative copy of every
    photo's EXIF stays embedded inside the original file, untouched, forever.
    state\catalog.jsonl is a derived index for fast querying and grouping - if
    it is ever lost, wrong, or incomplete, Rebuild-Catalog.ps1 regenerates it
    from the files themselves.

    Two backends:
      exiftool  - used when tools\exiftool.exe exists. Reads HEIC, MOV, Live
                  Photos and GPS properly. Strongly preferred.
      shell     - Windows property system. Zero dependencies, but on HEIC it
                  returns little or nothing unless the free "HEIF Image
                  Extensions" are installed from the Microsoft Store.
#>

$script:MetaShell = $null
$script:NsCache   = @{}

function Get-ExifToolPath {
    $p = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\exiftool.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    $cmd = Get-Command exiftool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-ShellNamespace {
    param([string]$Dir)
    if (-not $script:MetaShell) { $script:MetaShell = New-Object -ComObject Shell.Application }
    if (-not $script:NsCache.ContainsKey($Dir)) {
        $script:NsCache[$Dir] = $script:MetaShell.NameSpace($Dir)
    }
    return $script:NsCache[$Dir]
}

function ConvertFrom-Dms {
    # Shell returns GPS as a 3-element array of degrees/minutes/seconds.
    param($Parts, [string]$Ref)
    try {
        if ($null -eq $Parts) { return $null }
        $a = @($Parts)
        if ($a.Count -lt 3) { return $null }
        $dec = [double]$a[0] + ([double]$a[1] / 60.0) + ([double]$a[2] / 3600.0)
        if ($Ref -match '^[SW]') { $dec = -$dec }
        return [Math]::Round($dec, 7)
    } catch { return $null }
}

function Get-FileSha256 {
    param([string]$Path)
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    catch { return $null }
}

$script:ImageExt = @('.heic','.heif','.jpg','.jpeg','.png','.dng','.tif','.tiff','.gif','.webp','.bmp','.avif')
$script:VideoExt = @('.mov','.mp4','.m4v','.avi','.hevc')

function Get-ExtensionFromContent {
    <#
        Works out a file's real type by reading its magic bytes.

        Needed because some iPhones expose the camera roll over MTP with NO file
        extensions at all (names like "ARQM0324"). Copying those through as-is
        produces files Windows cannot open or thumbnail, so we sniff the header
        and append the correct extension. Returns '' if unrecognised, in which
        case the name is left exactly as the phone gave it.
    #>
    param([string]$Path)
    try {
        $b = New-Object byte[] 16
        $fs = [IO.File]::OpenRead($Path)
        try { $n = $fs.Read($b, 0, 16) } finally { $fs.Dispose() }
        if ($n -lt 12) { return '' }

        if ($b[0] -eq 0xFF -and $b[1] -eq 0xD8 -and $b[2] -eq 0xFF) { return '.jpg' }
        if ($b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47) { return '.png' }
        if ($b[0] -eq 0x47 -and $b[1] -eq 0x49 -and $b[2] -eq 0x46) { return '.gif' }
        if (($b[0] -eq 0x49 -and $b[1] -eq 0x49 -and $b[2] -eq 0x2A) -or
            ($b[0] -eq 0x4D -and $b[1] -eq 0x4D -and $b[3] -eq 0x2A)) { return '.tif' }
        if ($b[0] -eq 0x52 -and $b[1] -eq 0x49 -and $b[2] -eq 0x46 -and $b[3] -eq 0x46) { return '.webp' }

        # ISO base media format: bytes 4..7 are 'ftyp', then a 4-char brand.
        $tag = [Text.Encoding]::ASCII.GetString($b, 4, 8)
        if ($tag.StartsWith('ftyp')) {
            $brand = $tag.Substring(4, 4).ToLowerInvariant()
            if ($brand -match '^(heic|heix|heim|heis|hevc|hevx|mif1|msf1)') { return '.heic' }
            if ($brand -match '^avif') { return '.avif' }
            if ($brand -match '^qt')   { return '.mov' }
            return '.mp4'
        }
        return ''
    } catch { return '' }
}

function Get-MediaKind {
    param([string]$Ext)
    $e = $Ext.ToLowerInvariant()
    if ($script:ImageExt -contains $e) { return 'image' }
    if ($script:VideoExt -contains $e) { return 'video' }
    if ($e -eq '.aae') { return 'sidecar' }
    return 'other'
}

function Get-PhotoMetadataShell {
    <# Reads what the Windows property system knows about a local file. #>
    param([string]$Path)

    $dir  = Split-Path -Parent $Path
    $name = Split-Path -Leaf   $Path
    $meta = [ordered]@{}

    try {
        $ns = Get-ShellNamespace $dir
        if (-not $ns) { return $meta }
        $item = $ns.ParseName($name)
        if (-not $item) { return $meta }

        function Get-Prop { param($n) try { return $item.ExtendedProperty($n) } catch { return $null } }

        # The shell hands back DateTaken already shifted to UTC, but tags it
        # DateTimeKind.Unspecified. ToLocalTime() reverses exactly that shift and
        # recovers the wall-clock time the camera actually wrote into EXIF.
        # Without this every timestamp is off by the machine's UTC offset, which
        # misfiles photos near month boundaries and splits trip clusters wrongly.
        $dt = Get-Prop 'System.Photo.DateTaken'
        if (-not $dt) { $dt = Get-Prop 'System.Media.DateEncoded' }
        if ($dt -is [datetime]) { $meta.DateTaken = $dt.ToLocalTime().ToString('o') }

        $w = Get-Prop 'System.Image.HorizontalSize'
        $h = Get-Prop 'System.Image.VerticalSize'
        if (-not $w) { $w = Get-Prop 'System.Video.FrameWidth' }
        if (-not $h) { $h = Get-Prop 'System.Video.FrameHeight' }
        if ($w) { $meta.Width  = [int]$w }
        if ($h) { $meta.Height = [int]$h }

        $make  = Get-Prop 'System.Photo.CameraManufacturer'
        $model = Get-Prop 'System.Photo.CameraModel'
        if ($make)  { $meta.CameraMake  = [string]$make }
        if ($model) { $meta.CameraModel = [string]$model }

        $lat    = Get-Prop 'System.GPS.Latitude'
        $latRef = Get-Prop 'System.GPS.LatitudeRef'
        $lon    = Get-Prop 'System.GPS.Longitude'
        $lonRef = Get-Prop 'System.GPS.LongitudeRef'
        $dLat = ConvertFrom-Dms $lat ([string]$latRef)
        $dLon = ConvertFrom-Dms $lon ([string]$lonRef)
        if ($null -ne $dLat) { $meta.GpsLat = $dLat }
        if ($null -ne $dLon) { $meta.GpsLon = $dLon }
        $alt = Get-Prop 'System.GPS.Altitude'
        if ($alt) { try { $meta.GpsAlt = [Math]::Round([double]$alt, 1) } catch { } }

        $dur = Get-Prop 'System.Media.Duration'
        if ($dur) { try { $meta.DurationSec = [Math]::Round([double]$dur / 10000000.0, 2) } catch { } }

        $iso = Get-Prop 'System.Photo.ISOSpeed'
        if ($iso) { try { $meta.Iso = [int]$iso } catch { } }
        $fn = Get-Prop 'System.Photo.FNumber'
        if ($fn) { try { $meta.FNumber = [Math]::Round([double]$fn, 2) } catch { } }
        $fl = Get-Prop 'System.Photo.FocalLength'
        if ($fl) { try { $meta.FocalLength = [Math]::Round([double]$fl, 2) } catch { } }
        $ori = Get-Prop 'System.Photo.Orientation'
        if ($ori) { try { $meta.Orientation = [int]$ori } catch { } }
    } catch { }

    return $meta
}

function ConvertFrom-ExifToolObject {
    <# Normalises one exiftool -json record into our catalog field names. #>
    param($E)
    $meta = [ordered]@{}
    if (-not $E) { return $meta }

    $dtRaw = $null
    foreach ($f in @('SubSecDateTimeOriginal','DateTimeOriginal','CreateDate','MediaCreateDate')) {
        if ($E.PSObject.Properties.Name -contains $f -and $E.$f) { $dtRaw = [string]$E.$f; break }
    }
    if ($dtRaw) {
        # exiftool emits "2024:07:14 10:23:11" (optionally .sss and a zone)
        $s = $dtRaw -replace '^(\d{4}):(\d{2}):(\d{2})', '$1-$2-$3'
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($s, [ref]$parsed)) { $meta.DateTaken = $parsed.ToString('o') }
    }

    foreach ($pair in @(@('ImageWidth','Width'), @('ImageHeight','Height'))) {
        if ($E.PSObject.Properties.Name -contains $pair[0] -and $E.($pair[0])) {
            try { $meta[$pair[1]] = [int]$E.($pair[0]) } catch { }
        }
    }
    if ($E.Make)  { $meta.CameraMake  = [string]$E.Make }
    if ($E.Model) { $meta.CameraModel = [string]$E.Model }
    if ($E.LensModel) { $meta.Lens = [string]$E.LensModel }

    # -n makes exiftool emit GPS as signed decimal degrees already.
    foreach ($pair in @(@('GPSLatitude','GpsLat'), @('GPSLongitude','GpsLon'), @('GPSAltitude','GpsAlt'))) {
        if ($E.PSObject.Properties.Name -contains $pair[0] -and $null -ne $E.($pair[0])) {
            try { $meta[$pair[1]] = [Math]::Round([double]$E.($pair[0]), 7) } catch { }
        }
    }
    if ($E.Duration)     { try { $meta.DurationSec = [Math]::Round([double]$E.Duration, 2) } catch { } }
    if ($E.ISO)          { try { $meta.Iso         = [int]$E.ISO } catch { } }
    if ($E.FNumber)      { try { $meta.FNumber     = [Math]::Round([double]$E.FNumber, 2) } catch { } }
    if ($E.FocalLength)  { try { $meta.FocalLength = [Math]::Round([double]$E.FocalLength, 2) } catch { } }
    if ($E.Orientation)  { try { $meta.Orientation = [int]$E.Orientation } catch { } }
    if ($E.ContentIdentifier) { $meta.LivePhotoId = [string]$E.ContentIdentifier }

    return $meta
}

function Get-PhotoMetadata {
    <#
        Builds one catalog record for a local file.
        -ExifTool <path>  use exiftool for this file instead of the shell.
        -Hash             also compute SHA256 (integrity + cross-device dedup).
    #>
    param(
        [string]$Path,
        [string]$RelativePath,
        [string]$Key,
        [string]$Album,
        [string]$ExifTool,
        [switch]$Hash
    )

    $fi  = Get-Item -LiteralPath $Path
    $ext = $fi.Extension.ToLowerInvariant()

    $rec = [ordered]@{
        Key          = $Key
        File         = $RelativePath
        Name         = $fi.Name
        Base         = [IO.Path]::GetFileNameWithoutExtension($fi.Name)
        Ext          = $ext
        Kind         = Get-MediaKind $ext
        Album        = $Album
        Size         = $fi.Length
        FileModified = $fi.LastWriteTime.ToString('o')
        ImportedUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }

    $meta = $null
    if ($ExifTool) {
        try {
            $json = & $ExifTool -json -n -q -q -fast2 `
                        -DateTimeOriginal -SubSecDateTimeOriginal -CreateDate -MediaCreateDate `
                        -ImageWidth -ImageHeight -Make -Model -LensModel `
                        -GPSLatitude -GPSLongitude -GPSAltitude -Duration `
                        -ISO -FNumber -FocalLength -Orientation -ContentIdentifier `
                        -- $Path 2>$null
            if ($json) {
                $arr = ($json -join "`n") | ConvertFrom-Json
                if ($arr -and $arr.Count -ge 1) { $meta = ConvertFrom-ExifToolObject $arr[0] }
            }
        } catch { }
    }
    if (-not $meta -or $meta.Count -eq 0) { $meta = Get-PhotoMetadataShell -Path $Path }

    foreach ($k in $meta.Keys) { $rec[$k] = $meta[$k] }

    # Always have a usable timestamp: fall back to the file's own mtime, which
    # MTP preserves from the phone.
    if (-not $rec.Contains('DateTaken') -or -not $rec['DateTaken']) {
        $rec['DateTaken']       = $fi.LastWriteTime.ToString('o')
        $rec['DateTakenSource'] = 'filetime'
    } else {
        $rec['DateTakenSource'] = if ($ExifTool) { 'exif' } else { 'shell' }
    }

    if ($Hash) { $rec['Sha256'] = Get-FileSha256 -Path $Path }

    return $rec
}
