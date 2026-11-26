<#
.SYNOPSIS
    Reverts file compression operations performed by compressLogs.ps1 using its JSON undo log manifest.

.DESCRIPTION
    Reads a JSON undo log manifest produced by compressLogs.ps1 and reverses the compression actions:
    - If the original uncompressed file was deleted: Extracts the .zip archive back to its original
      directory, restores original file timestamps, validates file restoration, and removes the .zip archive.
    - If the original file was preserved (DeleteOriginal was $false): Deletes the redundant .zip archive.
    - Accurately tracks skipped files, already existing files, and missing archives.
    - Enforces Administrator privileges and supports -WhatIf and -Confirm for safe execution.

.PARAMETER LogPath
    Path to the JSON undo log manifest file produced by compressLogs.ps1.
    Aliases: -Path, -Manifest, -UndoLog

.PARAMETER KeepZip
    Preserves the .zip archives after extracting/restoring the original files, rather than deleting them.
    Default is $false (created .zip archives are removed once restoration is verified).

.PARAMETER OverwriteExisting
    Overwrites destination files if an uncompressed file with the same name already exists.
    Default is $false (skips existing files to prevent accidental loss).

.EXAMPLE
    .\undo-compressLogs.ps1 -LogPath '.\compress_undo_20261126_064500.json'
    Restores original uncompressed files and deletes the corresponding .zip archives.

.EXAMPLE
    .\undo-compressLogs.ps1 -LogPath '.\compress_undo_20261126_064500.json' -WhatIf
    Simulates the restoration process without touching any files on disk.

.EXAMPLE
    .\undo-compressLogs.ps1 -LogPath '.\compress_undo_20261126_064500.json' -KeepZip
    Restores original files but keeps the .zip archives.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [Alias("Path", "Manifest", "UndoLog")]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath,

    [Parameter()]
    [switch]$KeepZip,

    [Parameter()]
    [switch]$OverwriteExisting,

    [Parameter()]
    [switch]$SkipAdminCheck
)

# Helper to format bytes to human-readable size
function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes Bytes"
}

# 1. Verify elevation (Administrator privileges)
if (-not $SkipAdminCheck) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Error "This script requires elevated Administrator privileges. Please re-run in an elevated PowerShell session (Run as Administrator)."
        exit 1
    }
}

# 2. Validate manifest existence
if (-not (Test-Path -LiteralPath $LogPath)) {
    Write-Error "Undo log manifest not found at path: '$LogPath'"
    exit 1
}

# 3. Read and parse manifest
try {
    $manifestContent = Get-Content -LiteralPath $LogPath -Raw -Encoding UTF8 -ErrorAction Stop
    $manifest = $manifestContent | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Error "Failed to parse JSON manifest from '$LogPath': $_"
    exit 1
}

if (-not $manifest -or -not $manifest.Operations) {
    Write-Warning "The specified manifest contains no operations to revert."
    exit 0
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Undo Log & Dump File Compression Tool" -ForegroundColor Cyan
Write-Host " Manifest File     : $LogPath" -ForegroundColor White
Write-Host " Run ID            : $($manifest.RunId)" -ForegroundColor Gray
Write-Host " Original Machine  : $($manifest.MachineName)" -ForegroundColor Gray
Write-Host " Original Time     : $($manifest.StartTimeUtc)" -ForegroundColor Gray
Write-Host " Total Operations  : $($manifest.Operations.Count)" -ForegroundColor White
Write-Host " Keep Zip Archives : $KeepZip" -ForegroundColor White
Write-Host " Overwrite Existing: $OverwriteExisting" -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Cyan

$restoredCount = 0
$deletedZipCount = 0
$skippedCount = 0
$failedCount = 0
$unsupportedCount = 0

foreach ($op in $manifest.Operations) {
    # Only process compressible actions that succeeded originally
    if ($op.Action -ne "Compress" -or $op.Status -ne "Success") {
        if ($op.Action -eq "PurgeZip") {
            Write-Host "[Note] Skipped PurgeZip record (id: $($op.Id)) - permanently purged zips cannot be undone." -ForegroundColor DarkGray
            $unsupportedCount++
        }
        continue
    }

    $sourcePath = $op.OriginalPath
    $sourceDir  = $op.OriginalDirectory
    $zipPath    = $op.ArchivePath
    $zipName    = $op.ArchiveName
    $wasDeleted = [bool]$op.OriginalDeleted

    Write-Host "`n[Operation #$($op.Id)] " -NoNewline -ForegroundColor Cyan
    Write-Host "$sourcePath" -ForegroundColor White

    # Case 1: Original file was deleted -> extract archive back to original directory
    if ($wasDeleted) {
        if (-not (Test-Path -LiteralPath $zipPath)) {
            Write-Warning "Archive file not found: '$zipPath'. Cannot restore original file."
            $failedCount++
            continue
        }

        if ((Test-Path -LiteralPath $sourcePath) -and (-not $OverwriteExisting)) {
            Write-Host "SKIPPED: Target uncompressed file already exists. Use -OverwriteExisting to replace." -ForegroundColor Yellow
            $skippedCount++
            continue
        }

        # Perform extraction
        if ($PSCmdlet.ShouldProcess($zipPath, "Extract archive to '$sourceDir' to restore '$sourcePath'$(if (-not $KeepZip) { ' and remove zip' })")) {
            try {
                # Ensure destination directory exists
                if (-not (Test-Path -LiteralPath $sourceDir)) {
                    New-Item -Path $sourceDir -ItemType Directory -Force | Out-Null
                }

                # Extract archive
                Expand-Archive -LiteralPath $zipPath -DestinationPath $sourceDir -Force -ErrorAction Stop

                if (Test-Path -LiteralPath $sourcePath) {
                    # Restore original timestamp if available
                    if ($op.OriginalLastWriteUtc) {
                        try {
                            $origUtc = [DateTime]::Parse($op.OriginalLastWriteUtc)
                            (Get-Item -LiteralPath $sourcePath).LastWriteTimeUtc = $origUtc
                        }
                        catch {
                            Write-Verbose "Could not restore original timestamp: $_"
                        }
                    }

                    Write-Host "Restored: $sourcePath" -ForegroundColor Green
                    $restoredCount++

                    # Remove zip archive if configured
                    if (-not $KeepZip) {
                        Remove-Item -LiteralPath $zipPath -Force -ErrorAction Stop
                        Write-Host "Removed archive: $zipName" -ForegroundColor DarkGray
                        $deletedZipCount++
                    }
                }
                else {
                    Write-Warning "Extraction ran but '$sourcePath' was not found in destination directory."
                    $failedCount++
                }
            }
            catch {
                Write-Error "ERROR: Failed to restore '$sourcePath' from '$zipPath': $_"
                $failedCount++
            }
        }
    }
    # Case 2: Original file was preserved (DeleteOriginal was $false) -> simply remove the created archive
    else {
        if (Test-Path -LiteralPath $zipPath) {
            if (-not $KeepZip) {
                if ($PSCmdlet.ShouldProcess($zipPath, "Delete created zip archive (original uncompressed file was never deleted)")) {
                    try {
                        Remove-Item -LiteralPath $zipPath -Force -ErrorAction Stop
                        Write-Host "Removed archive: $zipName (original file already intact)" -ForegroundColor Green
                        $deletedZipCount++
                    }
                    catch {
                        Write-Error "ERROR: Failed to delete archive '$zipPath': $_"
                        $failedCount++
                    }
                }
            }
            else {
                Write-Host "Original file is intact; -KeepZip specified, leaving archive in place." -ForegroundColor Gray
                $skippedCount++
            }
        }
        else {
            Write-Host "Original file is intact and archive '$zipName' is already gone." -ForegroundColor Gray
            $skippedCount++
        }
    }
}

Write-Host "`n======================= SUMMARY ==========================" -ForegroundColor Cyan
Write-Host "Total Operations Evaluated   : $($manifest.Operations.Count)"
Write-Host "Original Files Restored      : $restoredCount" -ForegroundColor Green
Write-Host "Zip Archives Removed         : $deletedZipCount" -ForegroundColor Green
Write-Host "Skipped                      : $skippedCount" -ForegroundColor $(if ($skippedCount -gt 0) { "Yellow" } else { "White" })
Write-Host "Non-Reversible (e.g. Purged) : $unsupportedCount" -ForegroundColor $(if ($unsupportedCount -gt 0) { "DarkGray" } else { "White" })
Write-Host "Failed Operations            : $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "White" })
Write-Host "==========================================================" -ForegroundColor Cyan
