<#
.SYNOPSIS
    Calculates and displays the sizes of files and folders in a specified directory.

.DESCRIPTION
    Scans the target directory (defaults to current directory) and calculates aggregate
    sizes for folders and direct sizes for files. Results are sorted from largest to smallest.

.PARAMETER Path
    The directory path to inspect. Defaults to the current directory ('.').

.PARAMETER Top
    Limit output to the top N largest items. If omitted, returns all items.

.PARAMETER Unit
    Force output display in 'Auto', 'MB', or 'GB'. Defaults to 'Auto'.

.EXAMPLE
    .\diskspace.ps1
    Inspects current directory with auto-sized units.

.EXAMPLE
    .\diskspace.ps1 -Path C:\Windows -Top 10 -Unit GB
    Shows top 10 largest items in C:\Windows in GB.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromPipeline = $true)]
    [string]$Path = ".",

    [Parameter(Position = 1)]
    [int]$Top = 0,

    [ValidateSet("Auto", "MB", "GB")]
    [string]$Unit = "Auto"
)

# Helper function to format bytes into human-readable string
function Format-HumanSize {
    param([double]$Bytes)

    if ($Bytes -ge 1GB) {
        return "$([math]::Round($Bytes / 1GB, 2)) GB"
    } elseif ($Bytes -ge 1MB) {
        return "$([math]::Round($Bytes / 1MB, 2)) MB"
    } elseif ($Bytes -ge 1KB) {
        return "$([math]::Round($Bytes / 1KB, 2)) KB"
    } else {
        return "$Bytes B"
    }
}

# Resolve target path
$targetPath = Convert-Path -Path $Path -ErrorAction Stop
Write-Host "Scanning: $targetPath" -ForegroundColor Cyan

# Gather immediate children (files & folders)
$items = Get-ChildItem -Path $targetPath -Force -ErrorAction SilentlyContinue

if (-not $items) {
    Write-Warning "No files or folders found in '$targetPath'."
    return
}

$totalItems = $items.Count
$counter = 0

$results = foreach ($item in $items) {
    $counter++
    Write-Progress -Activity "Calculating disk space" -Status "Checking $($item.Name)" -PercentComplete (($counter / $totalItems) * 100)

    if ($item.PSIsContainer) {
        # Calculate aggregate size for folder
        $measure = Get-ChildItem -Path $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                   Measure-Object -Property Length -Sum

        $rawBytes = if ($measure.Sum) { [double]$measure.Sum } else { 0.0 }
        $itemType = "Folder"
    } else {
        $rawBytes = [double]$item.Length
        $itemType = "File"
    }

    # Format size based on user preference
    $displaySize = switch ($Unit) {
        "GB"   { "$([math]::Round($rawBytes / 1GB, 2)) GB" }
        "MB"   { "$([math]::Round($rawBytes / 1MB, 2)) MB" }
        "Auto" { Format-HumanSize -Bytes $rawBytes }
    }

    [PSCustomObject]@{
        Name        = $item.Name
        Type        = $itemType
        Size        = $displaySize
        SizeBytes   = $rawBytes
        LastWrite   = $item.LastWriteTime
        FullPath    = $item.FullName
    }
}

Write-Progress -Activity "Calculating disk space" -Completed

# Sort descending by raw bytes
$sorted = $results | Sort-Object -Property SizeBytes -Descending

# Apply Top N limit if specified
if ($Top -gt 0) {
    $sorted = $sorted | Select-Object -First $Top
}

# Output formatted table by default (while keeping raw objects usable in pipeline)
$sorted | Format-Table -Property Name, Type, Size, LastWrite -AutoSize
