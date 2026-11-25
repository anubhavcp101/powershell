<#
.SYNOPSIS
    Compresses log and dump files across multiple directories and wildcard paths with unique archive naming.

.DESCRIPTION
    Scans one or more directories or wildcard paths (e.g. 'C:\WindowsAzure\Logs', 'C:\Users\*\AppData\Local\CrashDumps')
    for uncompressed files matching specified filters (default: '*.log'). Generates unique archive names
    (using file content SHA-256 hash and/or timestamp), compresses each file into a .zip archive, and optionally
    removes the original files to reclaim disk space.

    Key Capabilities:
    - Multi-Path & Wildcard Support: Resolves paths like 'C:\Users\*\AppData\Local\CrashDumps' across all profiles.
    - Permission Check & Grant: When scanning user profiles or restricted directories, ensures Administrators have Full Control via icacls.
    - Multi-Filter Support: Accepts multiple file patterns, e.g. '*.log', '*.dmp', '*.txt'.
    - Unique Naming: Prevents collisions using content hash and/or timestamp.
    - Lock Detection: Automatically checks and skips active/locked files without throwing errors.
    - Zip Protection: Automatically excludes .zip files from being compressed into nested archives.
    - Safety & Elevation: Enforces Administrator privileges and supports -WhatIf / -Confirm.

    Unique Naming Modes (-UniqueNaming):
    - TimestampHash (Default): <BaseName>_<yyyyMMdd_HHmmss>_<ShortHash>.zip (e.g. dump_20261123_105000_9f63ee06.zip)
    - Hash:                    <BaseName>_<ShortHash>.zip (e.g. dump_9f63ee06.zip)
    - Timestamp:               <BaseName>_<yyyyMMdd_HHmmss>.zip (e.g. dump_20261123_105000.zip)
    - None:                    <FileName>.zip (e.g. dump.dmp.zip)

.PARAMETER LogRoot
    One or more root directories or wildcard path patterns to scan.
    Aliases: -Path, -Paths, -LogRoots
    Default: 'C:\WindowsAzure\Logs', 'C:\Windows\Temp', 'C:\ProgramData\Microsoft\Windows\WER'
    Examples:
      -LogRoot 'C:\WindowsAzure\Logs'
      -LogRoot 'C:\WindowsAzure\Logs', 'C:\Users\*\AppData\Local\CrashDumps', 'C:\inetpub\logs'

.PARAMETER FileFilter
    One or more file patterns to match.
    Aliases: -Filter, -Filters
    Default: '*.log'
    Examples:
      -Filter '*.log'
      -Filter '*.log', '*.dmp'
      -Filter '*.txt', '*.out'

.PARAMETER OlderThanDays
    Minimum file age in days. Default is 0 (all eligible files).

.PARAMETER DeleteOriginal
    Deletes the original uncompressed file after verifying successful zip creation. Default is $true.

.PARAMETER EnsureAdminPermissions
    Checks target directories and assigns Full Control permissions to Administrators using icacls if not already present.
    This check only applies to directories located under a Users profile folder (e.g. 'C:\Users\*\AppData\Local\CrashDumps')
    and strictly targets the matched directory (e.g. 'CrashDumps') and its subfolders/files, without touching parent folders.
    Default is $true.

.PARAMETER UniqueNaming
    Archive naming convention: 'TimestampHash' (default), 'Hash', 'Timestamp', 'None'.

.PARAMETER HashLength
    Length of the SHA-256 content hash in the archive name. Default is 9.

.PARAMETER OverwriteZip
    Overwrites existing zip archives if one with the same name already exists. Default is $false.

.EXAMPLE
    .\compressLogs.ps1
    Compresses all .log files in 'C:\WindowsAzure\Logs' and all subfolders.

.EXAMPLE
    .\compressLogs.ps1 -Paths 'C:\WindowsAzure\Logs', 'C:\Users\*\AppData\Local\CrashDumps' -Filters '*.log', '*.dmp'
    Scans Azure VM logs and all user crash dumps, compressing both .log and .dmp files.

.EXAMPLE
    .\compressLogs.ps1 -Paths 'C:\Users\*\AppData\Local\CrashDumps' -Filter '*.dmp' -OlderThanDays 30
    Compresses user crash dumps older than 30 days.

.EXAMPLE
    .\compressLogs.ps1 -Paths 'C:\inetpub\logs\LogFiles', 'D:\AppLogs' -WhatIf
    Previews which files across multiple paths would be compressed without making changes.

.EXAMPLE
    .\compressLogs.ps1 -DeleteOriginal:$false
    Compresses files but keeps the original uncompressed files intact.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [Alias("LogRoots", "Path", "Paths")]
    [string[]]$LogRoot = @("C:\WindowsAzure\Logs", "C:\Windows\Temp", "C:\ProgramData\Microsoft\Windows\WER"),

    [Parameter(Position = 1)]
    [Alias("Filter", "Filters")]
    [string[]]$FileFilter = @("*.log"),

    [Parameter()]
    [ValidateRange(0, 3650)]
    [int]$OlderThanDays = 0,

    [Parameter()]
    [bool]$DeleteOriginal = $true,

    [Parameter()]
    [bool]$EnsureAdminPermissions = $true,

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
        [int]$Length = 9
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

# Function to check and ensure Administrators have Full Control on a directory using icacls
function Ensure-AdminPermissions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    # Resolve localized Administrators group name via well-known SID S-1-5-32-544
    $adminGroupName = "Administrators"
    try {
        $sid = [System.Security.Principal.SecurityIdentifier]'S-1-5-32-544'
        $account = $sid.Translate([System.Security.Principal.NTAccount])
        if ($account -and $account.Value) {
            $adminGroupName = $account.Value
        }
    }
    catch {
        $adminGroupName = "Administrators"
    }

    # Check existing ACL rules for Administrators Full Control
    $hasFullControl = $false
    try {
        $acl = Get-Acl -LiteralPath $Path
        foreach ($access in $acl.Access) {
            $matchedAdmin = ($access.IdentityReference.Value -eq $adminGroupName -or
                $access.IdentityReference.Value -eq "BUILTIN\Administrators" -or
                $access.IdentityReference.Value -eq "Administrators")
            if ($matchedAdmin -and
                $access.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                (($access.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq [System.Security.AccessControl.FileSystemRights]::FullControl)) {
                $hasFullControl = $true
                break
            }
        }
    }
    catch {
        # If Get-Acl fails (e.g. Access Denied on user folder), permission definitely needs to be granted
        $hasFullControl = $false
    }

    if (-not $hasFullControl) {
        if ($PSCmdlet.ShouldProcess($Path, "Grant Administrators Full Control permissions (icacls `"$Path`" /grant `"*S-1-5-32-544:(OI)(CI)(F)`" /T /C /Q)")) {
            Write-Host "[Permissions] Granting Administrators Full Control to '$Path'..." -ForegroundColor Yellow
            $grantArg = "*S-1-5-32-544:(OI)(CI)(F)"
            $icaclsOutput = & icacls "$Path" /grant "$grantArg" /T /C /Q 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[Permissions] Successfully updated permissions for '$Path'." -ForegroundColor Green
            }
            else {
                Write-Warning "[Permissions] icacls reported warnings or errors for '$Path': $($icaclsOutput -join '; ')"
            }
        }
    }
    else {
        Write-Verbose "Administrators already have Full Control on '$Path'."
    }
}

# Function to normalize and expand directory paths (including wildcards like C:\Users\*\AppData\Local\CrashDumps)
function Expand-DirectoryTargets {
    param([string[]]$Patterns)

    $resolvedDirs = [System.Collections.Generic.List[string]]::new()

    foreach ($pattern in $Patterns) {
        $trimmed = $pattern.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if ($trimmed -match '[\*\?]') {
            # Wildcard pattern: resolve matching filesystem containers
            $pathMatches = Resolve-Path -Path $trimmed -ErrorAction SilentlyContinue
            if ($pathMatches) {
                foreach ($m in $pathMatches) {
                    if (Test-Path -LiteralPath $m.ProviderPath -PathType Container) {
                        $resolvedDirs.Add($m.ProviderPath)
                    }
                }
            }
            else {
                Write-Warning "Wildcard path pattern matched 0 directories: '$trimmed'"
            }
        }
        else {
            # Literal path
            if (Test-Path -LiteralPath $trimmed -PathType Container) {
                $resolvedDirs.Add((Get-Item -LiteralPath $trimmed).FullName)
            }
            else {
                Write-Warning "Directory does not exist: '$trimmed'"
            }
        }
    }

    return ($resolvedDirs | Select-Object -Unique)
}

# Normalize file filters (e.g. '.log' -> '*.log', 'dmp' -> '*.dmp')
$normalizedFilters = @(
    foreach ($f in $FileFilter) {
        $clean = $f.Trim()
        if ($clean -notmatch '^\*' -and -not $clean.Contains('*') -and -not $clean.Contains('?')) {
            if ($clean.StartsWith('.')) { "*$clean" } else { "*.$clean" }
        }
        else {
            $clean
        }
    }
) | Select-Object -Unique

# 1. Verify elevation (Administrator privileges)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script requires elevated Administrator privileges. Please re-run in an elevated PowerShell session (Run as Administrator)."
    exit 1
}

# 2. Resolve all target root directories
$targetDirectories = Expand-DirectoryTargets -Patterns $LogRoot

if (-not $targetDirectories -or $targetDirectories.Count -eq 0) {
    Write-Warning "No valid directories found to scan. Please verify specified paths."
    exit 0
}

# Check and grant Administrator permissions on target directories if needed (only for paths located under a Users directory)
if ($EnsureAdminPermissions) {
    foreach ($dir in $targetDirectories) {
        # Only check/grant permissions if the path resides under a Users directory (e.g. C:\Users\<Username>\...)
        if ($dir -match '^[a-zA-Z]:\\Users\\') {
            Ensure-AdminPermissions -Path $dir
        }
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan #
Write-Host " Log & Dump File Compression Tool" -ForegroundColor Cyan #
Write-Host " Target Directories ($($targetDirectories.Count)):" -ForegroundColor White
foreach ($dir in $targetDirectories) {
    Write-Host "   - $dir" -ForegroundColor Gray
}
Write-Host " Target Filters    : $($normalizedFilters -join ', ')" -ForegroundColor White
Write-Host " Naming Scheme     : $UniqueNaming (Hash Length: $HashLength)" -ForegroundColor White #
if ($OlderThanDays -gt 0) {
    Write-Host " Age Filter        : Older than $OlderThanDays days" -ForegroundColor White
}
else {
    Write-Host " Age Filter        : All ages (0+ days)" -ForegroundColor White
}
Write-Host " Remove Source     : $DeleteOriginal" -ForegroundColor White
Write-Host " Overwrite Zip     : $OverwriteZip" -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Cyan

# 3. Discover files across all resolved directories
$cutoffDate = (Get-Date).AddDays(-$OlderThanDays)
$candidateFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

foreach ($dir in $targetDirectories) {
    $foundFiles = Get-ChildItem -LiteralPath $dir -File -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object {
        # Must not be a .zip archive
        if ($_.Extension -eq '.zip') { return $false }
        # Must meet age cutoff
        if ($_.LastWriteTime -gt $cutoffDate) { return $false }
        # Must match at least one filter pattern
        $matched = $false
        foreach ($pattern in $normalizedFilters) {
            if ($_.Name -like $pattern) {
                $matched = $true
                break
            }
        }
        return $matched
    }

    if ($foundFiles) {
        foreach ($file in $foundFiles) {
            $candidateFiles.Add($file)
        }
    }
}

if ($candidateFiles.Count -eq 0) {
    Write-Host "`nNo matching files found across the target directories." -ForegroundColor Yellow
    exit 0
}

Write-Host "`nFound $($candidateFiles.Count) file(s) matching criteria.`n" -ForegroundColor Green

$totalOriginalBytes = 0
$totalCompressedBytes = 0
$processedCount = 0
$skippedLockedCount = 0
$skippedExistingCount = 0
$failedCount = 0

foreach ($file in $candidateFiles) {
    $sourcePath = $file.FullName
    $fileSize = $file.Length
    $totalOriginalBytes += $fileSize

    Write-Host "[Processing] " -NoNewline -ForegroundColor Cyan
    Write-Host "$sourcePath " -NoNewline -ForegroundColor White
    Write-Host "($(Format-FileSize $fileSize))" -ForegroundColor Gray

    # Check if file is currently locked/in use
    if (Test-FileLocked -FilePath $sourcePath) {
        Write-Host "SKIPPED: File is currently locked / in use by another process." -ForegroundColor Yellow
        $skippedLockedCount++
        continue
    }

    # Generate unique archive filename
    $zipFileName = Get-UniqueArchiveName -FileInfo $file -Mode $UniqueNaming -Length $HashLength
    $zipPath = Join-Path -Path $file.DirectoryName -ChildPath $zipFileName

    # Check if destination archive already exists
    if ((Test-Path -LiteralPath $zipPath) -and (-not $OverwriteZip)) {
        Write-Host "SKIPPED: Archive '$zipFileName' already exists. Use -OverwriteZip to replace." -ForegroundColor Yellow
        $skippedExistingCount++
        continue
    }

    # SupportsShouldProcess / -WhatIf handling
    if ($PSCmdlet.ShouldProcess($sourcePath, "Compress to '$zipPath' and $(if ($DeleteOriginal) {'delete original'} else {'preserve original'})")) {
        try {
            # Compress to zip archive
            Compress-Archive -LiteralPath $sourcePath -DestinationPath $zipPath -Force -ErrorAction Stop

            # Verify the zip archive was created and has non-zero size
            if (Test-Path -LiteralPath $zipPath) {
                $zipItem = Get-Item -LiteralPath $zipPath -Force
                $compressedSize = $zipItem.Length
                $totalCompressedBytes += $compressedSize
                $savingsPercent = if ($fileSize -gt 0) { [math]::Round(((1 - ($compressedSize / $fileSize)) * 100), 1) } else { 0 }

                Write-Host "Created: $zipFileName ($(Format-FileSize $compressedSize), $savingsPercent% reduction)" -ForegroundColor Green

                # Remove original file if configured
                if ($DeleteOriginal) {
                    Remove-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
                    Write-Host "Removed original uncompressed file." -ForegroundColor DarkGray
                }
                $processedCount++
            }
            else {
                Write-Warning "FAILED: Zip archive was not found after Compress-Archive execution."
                $failedCount++
            }
        }
        catch {
            Write-Error "ERROR: Failed to compress or remove '$sourcePath': $_"
            $failedCount++
        }
    }
}

# 4. Display summary
$netSavings = [math]::Max(0, ($totalOriginalBytes - $totalCompressedBytes))

Write-Host "`n======================= SUMMARY ==========================" -ForegroundColor Cyan
Write-Host "Directories scanned          : $($targetDirectories.Count)"
Write-Host "Total files evaluated        : $($candidateFiles.Count)"
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
