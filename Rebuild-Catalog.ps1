<#
.SYNOPSIS
    Rebuilds state\catalog.jsonl by re-reading metadata from every file in the
    library. Safe to run any time; it never modifies a photo.

.DESCRIPTION
    The photos themselves are the source of truth - every one still carries its
    original embedded EXIF/GPS exactly as the iPhone wrote it. The catalog is
    just a fast index over that. So if metadata was captured poorly (e.g. before
    you installed exiftool or the HEIF extensions), run this and it is fixed.

.EXAMPLE
    .\Rebuild-Catalog.ps1
    .\Rebuild-Catalog.ps1 -NoHash        # much faster, skips SHA256
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [switch] $NoHash,
    [switch] $Force      # rebuild every record, not just missing ones
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
if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

. (Join-Path $Root 'lib\Metadata.ps1')
$ExifTool = Get-ExifToolPath

if (-not (Test-Path -LiteralPath $LibraryPath)) { Write-Host "Library not found: $LibraryPath" -Fore Red; return }

Write-Host ''
Write-Host '  Rebuilding photo catalog' -ForegroundColor Cyan
Write-Host ('  Library : {0}' -f $LibraryPath)
Write-Host ('  Metadata: {0}' -f $(if ($ExifTool) { "exiftool  ($ExifTool)" } else { 'Windows property system' }))
if (-not $ExifTool) {
    Write-Host '            HEIC metadata may be sparse. See README for exiftool.' -ForegroundColor Yellow
}
Write-Host ''

# Keep existing records unless -Force, so a rerun is cheap.
$have = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$kept = New-Object System.Collections.ArrayList
if (-not $Force -and (Test-Path -LiteralPath $CatalogPath)) {
    foreach ($line in [IO.File]::ReadLines($CatalogPath)) {
        if (-not $line) { continue }
        try {
            $o = $line | ConvertFrom-Json
            if ($o.File -and (Test-Path -LiteralPath (Join-Path $LibraryPath $o.File))) {
                if ($have.Add([string]$o.File)) { [void]$kept.Add($line) }
            }
        } catch { }
    }
    Write-Host ("  Reusing {0:N0} existing record(s)." -f $kept.Count)
}

$files = @([IO.Directory]::EnumerateFiles($LibraryPath, '*', 'AllDirectories'))
Write-Host ("  Found {0:N0} file(s) in the library." -f $files.Count)
Write-Host ''

$tmp    = $CatalogPath + '.new'
$writer = New-Object System.IO.StreamWriter($tmp, $false, [Text.Encoding]::UTF8)
$n = 0; $added = 0; $withGps = 0; $withDate = 0
$sw = [Diagnostics.Stopwatch]::StartNew()

try {
    foreach ($line in $kept) { $writer.WriteLine($line) }

    foreach ($f in $files) {
        $n++
        $rel = $f.Substring($LibraryPath.Length).TrimStart('\')
        if ($have.Contains($rel)) { continue }

        try {
            $rec = Get-PhotoMetadata -Path $f -RelativePath $rel -Key '' -Album '' `
                                     -ExifTool $ExifTool -Hash:(-not $NoHash)
            $writer.WriteLine(($rec | ConvertTo-Json -Compress -Depth 4))
            $added++
            if ($rec.Contains('GpsLat')) { $withGps++ }
            if ($rec['DateTakenSource'] -ne 'filetime') { $withDate++ }
        } catch {
            Write-Host ("  ! {0}: {1}" -f $rel, $_.Exception.Message) -ForegroundColor Yellow
        }

        if (($n % 200) -eq 0) {
            $pct = [int](($n / [double]$files.Count) * 100)
            Write-Host ("  {0,3}%  {1:N0}/{2:N0}  ({3:N0} new)" -f $pct, $n, $files.Count, $added)
        }
    }
}
finally {
    $writer.Flush(); $writer.Dispose()
}

Move-Item -LiteralPath $tmp -Destination $CatalogPath -Force
$sw.Stop()

Write-Host ''
Write-Host ('  Done in {0:hh\:mm\:ss}' -f $sw.Elapsed) -ForegroundColor Green
Write-Host ('  {0:N0} new record(s); {1:N0} with real EXIF dates; {2:N0} with GPS.' -f $added, $withDate, $withGps)
if ($added -gt 0 -and $withGps -eq 0) {
    Write-Host ''
    Write-Host '  No GPS found on any file. Either Location was off when shooting,' -ForegroundColor Yellow
    Write-Host '  or the metadata reader cannot see into HEIC. See README.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host ('  Catalog: {0}' -f $CatalogPath)
Write-Host '  Next: .\Group-Trips.ps1'
Write-Host ''
