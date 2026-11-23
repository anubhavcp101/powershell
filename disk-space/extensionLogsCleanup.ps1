<#
.SYNOPSIS
    Compresses log files in Azure VM directories (or any custom folder) on Windows OS with unique archive naming.

.DESCRIPTION
    Recursively scans the specified root log directory (default: 'C:\WindowsAzure\Logs', which contains
    'WaAppAgent.log' at root and all extension logs under 'Plugins\<ExtensionName>\<Version>\').
    Finds uncompressed log files matching the specified file filter (default: '*.log'), generates a unique
    archive name (using file content SHA-256 hash and/or timestamp), compresses each file into a .zip archive,
    and optionally removes the original log file to reclaim disk space.

    Unique Naming Modes:
    - TimestampHash (Default): <BaseName>_<yyyyMMdd_HHmmss>_<ShortHash>.zip (e.g. WaAppAgent_20261123_105000_9f63ee06.zip)
    - Hash:                    <BaseName>_<ShortHash>.zip (e.g. WaAppAgent_9f63ee06.zip)
    - Timestamp:               <BaseName>_<yyyyMMdd_HHmmss>.zip (e.g. WaAppAgent_20261123_105000.zip)
    - None:                    <FileName>.zip (e.g. WaAppAgent.log.zip)

    Includes safeguards for:
    - Active / locked log files (e.g. current WaAppAgent.log being written to by the VM agent)
    - Prevents accidental re-compression of .zip files
    - Customizable file filter (.log, *.log, *.txt, *.out, etc.)
    - Optional age filtering (compress only logs older than N days, or all logs)
    - Overwrite protection (-OverwriteZip)
    - Elevated privilege verification (Run as Administrator)
    - Full support for -WhatIf and -Confirm (via SupportsShouldProcess)

.PARAMETER LogRoot
    Root directory where logs reside.
    Default is 'C:\WindowsAzure\Logs'. Can be pointed to any directory (e.g. 'C:\inetpub\logs', 'D:\Logs').

.PARAMETER FileFilter
    File pattern filter to match. Default is '*.log'.
    Accepts extensions with or without wildcards (e.g. '*.log', '.log', 'log', '*.txt', 'trace*.log').
    Alias: -Filter.

.PARAMETER OlderThanDays
    Optional minimum age in days for logs to be compressed. Default is 0 (all eligible files).

.PARAMETER DeleteOriginal
    If set, deletes the original log file after verified successful compression. Default is $true.

.PARAMETER UniqueNaming
    Naming convention for the destination .zip archive:
    'TimestampHash' (default) - Appends modification timestamp and a short SHA-256 hash.
    'Hash'                    - Appends only a short SHA-256 hash.
    'Timestamp'               - Appends only modification timestamp.
    'None'                    - Retains standard <FileName>.zip naming.

.PARAMETER HashLength
    Number of characters from the SHA-256 hash to include in the archive name. Default is 8.

.PARAMETER OverwriteZip
    If set, will overwrite any existing destination .zip archive if it already exists. Default is $false.

.EXAMPLE
    .\extensionLogsCleanup.ps1
    Compresses all .log files under 'C:\WindowsAzure\Logs' into uniquely named archives
    and removes the original .log files.

.EXAMPLE
    .\extensionLogsCleanup.ps1 -LogRoot "C:\inetpub\logs\LogFiles" -Filter "*.log"
    Compresses IIS log files in custom directory.

.EXAMPLE
    .\extensionLogsCleanup.ps1 -Filter "*.txt" -OlderThanDays 14
    Compresses only .txt files older than 14 days under the default Azure log folder.

.EXAMPLE
    .\extensionLogsCleanup.ps1 -LogRoot "D:\AppLogs" -Filter "*.out" -UniqueNaming Hash
    Compresses .out files using content-based short hashes.

.EXAMPLE
    .\extensionLogsCleanup.ps1 -WhatIf
    Previews which files would be compressed and the generated archive names without making changes.

.EXAMPLE
    .\extensionLogsCleanup.ps1 -DeleteOriginal:$false
    Compresses files into .zip archives but preserves the original uncompressed files.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [string]$LogRoot = "C:\WindowsAzure\Logs",

    [Parameter(Position = 1)]
    [Alias("Filter")]
    [string]$FileFilter = "*.log",

    [Parameter()]
    [ValidateRange(0, 3650)]
    [int]$OlderThanDays = 0,

    [Parameter()]
    [bool]$DeleteOriginal = $true,

    [Parameter()]
    [ValidateSet('TimestampHash', 'Hash', 'Timestamp', 'None')]
    [string]$UniqueNaming = 'TimestampHash',

    [Parameter()]
    [ValidateRange(4, 32)]
    [int]$HashLength = 9,

    [Parameter()]
    [switch]$OverwriteZip
)

# Function to test if a file is currently locked/in use by another process
function Test-FileLocked {
    param([string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) { return $false }
    try {
        $fileStream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        if ($fileStream) {
            $fileStream.Close()
            $fileStream.Dispose()
        }
        return $false
    }
    catch {
        return $true
    }
}

# Function to generate a unique zip filename based on chosen mode
function Get-UniqueArchiveName {
    param(
        [System.IO.FileInfo]$FileInfo,
        [string]$Mode,
        [int]$Length
    )

    $baseName = $FileInfo.BaseName
    $timestamp = $FileInfo.LastWriteTime.ToString("yyyyMMdd_HHmmss")

    switch ($Mode) {
        'TimestampHash' {
            try {
                $hash = (Get-FileHash -LiteralPath $FileInfo.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.Substring(0, $Length).ToLower()
            }
            catch {
                $hash = [Guid]::NewGuid().ToString("N").Substring(0, $Length)
            }
            return "${baseName}_${timestamp}_${hash}.zip"
        }
        'Hash' {
            try {
                $hash = (Get-FileHash -LiteralPath $FileInfo.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.Substring(0, $Length).ToLower()
            }
            catch {
                $hash = [Guid]::NewGuid().ToString("N").Substring(0, $Length)
            }
            return "${baseName}_${hash}.zip"
        }
        'Timestamp' {
            return "${baseName}_${timestamp}.zip"
        }
        default {
            return "$($FileInfo.Name).zip"
        }
    }
}

# Helper to format bytes to human-readable size
function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes Bytes"
}

# 1. Verify elevation (Administrator privileges)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script requires elevated Administrator privileges. Please re-run in an elevated PowerShell session (Run as Administrator)."
    exit 1
}

# 2. Check if the target log directory exists
if (-not (Test-Path -LiteralPath $LogRoot)) {
    Write-Warning "The specified log directory does not exist: '$LogRoot'"
    exit 0
}

# Normalize file filter (e.g. '.log' or 'log' -> '*.log')
$normalizedFilter = $FileFilter.Trim()
if ($normalizedFilter -notmatch '^\*' -and -not $normalizedFilter.Contains('*') -and -not $normalizedFilter.Contains('?')) {
    if ($normalizedFilter.StartsWith('.')) {
        $normalizedFilter = "*$normalizedFilter"
    }
    else {
        $normalizedFilter = "*.$normalizedFilter"
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " System & VM Log Compression Tool" -ForegroundColor Cyan
Write-Host " Scanning Path : $LogRoot" -ForegroundColor White
Write-Host " Target Filter : $normalizedFilter" -ForegroundColor White
Write-Host " Naming Scheme : $UniqueNaming (Hash Length: $HashLength)" -ForegroundColor White
if ($OlderThanDays -gt 0) {
    Write-Host " Age Filter    : Older than $OlderThanDays days" -ForegroundColor White
}
else {
    Write-Host " Age Filter    : All ages (0+ days)" -ForegroundColor White
}
Write-Host " Remove Source : $DeleteOriginal" -ForegroundColor White
Write-Host " Overwrite Zip : $OverwriteZip" -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Cyan

# 3. Discover files recursively matching the filter (excluding existing .zip archives)
$cutoffDate = (Get-Date).AddDays(-$OlderThanDays)
$logFiles = Get-ChildItem -LiteralPath $LogRoot -Filter $normalizedFilter -File -Recurse -Force -ErrorAction SilentlyContinue |
Where-Object { $_.Extension -ne '.zip' -and $_.LastWriteTime -le $cutoffDate }

if (-not $logFiles -or $logFiles.Count -eq 0) {
    Write-Host "No files matching '$normalizedFilter' found under '$LogRoot'." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($logFiles.Count) file(s) matching criteria.`n" -ForegroundColor Green

$totalOriginalBytes = 0
$totalCompressedBytes = 0
$processedCount = 0
$skippedLockedCount = 0
$skippedExistingCount = 0
$failedCount = 0

foreach ($file in $logFiles) {
    $sourcePath = $file.FullName
    $fileSize = $file.Length
    $totalOriginalBytes += $fileSize

    Write-Host "[Processing] " -NoNewline -ForegroundColor Cyan
    Write-Host "$sourcePath " -NoNewline -ForegroundColor White
    Write-Host "($(Format-FileSize $fileSize))" -ForegroundColor Gray

    # Check if file is locked by guest agent or application process before reading/compressing
    if (Test-FileLocked -FilePath $sourcePath) {
        Write-Host " SKIPPED: File is currently locked / in use by another process." -ForegroundColor Yellow
        $skippedLockedCount++
        continue
    }

    # Generate unique archive filename
    $zipFileName = Get-UniqueArchiveName -FileInfo $file -Mode $UniqueNaming -Length $HashLength
    $zipPath = Join-Path -Path $file.DirectoryName -ChildPath $zipFileName

    # Check if target .zip already exists
    if ((Test-Path -LiteralPath $zipPath) -and (-not $OverwriteZip)) {
        Write-Host " SKIPPED: Archive '$zipFileName' already exists. Use -OverwriteZip to replace." -ForegroundColor Yellow
        $skippedExistingCount++
        continue
    }

    # SupportsShouldProcess / -WhatIf handling
    if ($PSCmdlet.ShouldProcess($sourcePath, "Compress to '$zipPath' and $(if ($DeleteOriginal) {'delete original'} else {'preserve original'})")) {
        try {
            # Compress log file to .zip
            Compress-Archive -LiteralPath $sourcePath -DestinationPath $zipPath -Force -ErrorAction Stop

            # Verify the zip archive was created and has non-zero size
            if (Test-Path -LiteralPath $zipPath) {
                $zipItem = Get-Item -LiteralPath $zipPath -Force
                $compressedSize = $zipItem.Length
                $totalCompressedBytes += $compressedSize
                $savingsPercent = if ($fileSize -gt 0) { [math]::Round(((1 - ($compressedSize / $fileSize)) * 100), 1) } else { 0 }

                Write-Host " Created: $zipFileName ($(Format-FileSize $compressedSize), $savingsPercent% reduction)" -ForegroundColor Green

                # Remove original log file if configured
                if ($DeleteOriginal) {
                    Remove-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
                    Write-Host " Removed original uncompressed file." -ForegroundColor DarkGray
                }
                $processedCount++
            }
            else {
                Write-Warning " FAILED: Zip archive was not found after Compress-Archive execution."
                $failedCount++
            }
        }
        catch {
            Write-Error " ERROR: Failed to compress or remove '$sourcePath': $_"
            $failedCount++
        }
    }
}

# 4. Display summary
$netSavings = [math]::Max(0, ($totalOriginalBytes - $totalCompressedBytes))

Write-Host "`n======================= SUMMARY ==========================" -ForegroundColor Cyan
Write-Host "Total files evaluated        : $($logFiles.Count)"
Write-Host "Successfully compressed      : $processedCount" -ForegroundColor Green
Write-Host "Skipped (locked/in-use)      : $skippedLockedCount" -ForegroundColor $(if ($skippedLockedCount -gt 0) { "Yellow" } else { "White" })
Write-Host "Skipped (zip already exists) : $skippedExistingCount" -ForegroundColor $(if ($skippedExistingCount -gt 0) { "Yellow" } else { "White" })
Write-Host "Failed operations            : $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "White" })
if ($processedCount -gt 0) {
    Write-Host "Original Total Size          : $(Format-FileSize $totalOriginalBytes)"
    Write-Host "Compressed Total Size        : $(Format-FileSize $totalCompressedBytes)"
    Write-Host "Reclaimed Disk Space         : $(Format-FileSize $netSavings)" -ForegroundColor Green
}
Write-Host "==========================================================" -ForegroundColor Cyan
