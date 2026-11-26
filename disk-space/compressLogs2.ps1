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

.PARAMETER PurgeOldZipDays
    Deletes existing .zip archives in the target directories older than the specified number of days.
    Default is 0 (retention cleanup disabled, no zip files removed).
    Aliases: -RemoveOldZipDays, -CleanZipOlderThanDays
    Examples:
      -PurgeOldZipDays 30   # Purges .zip archives older than 30 days
      -PurgeOldZipDays 60   # Purges .zip archives older than 60 days

.PARAMETER LogPath
    Path to save the JSON undo manifest log file. If a directory or empty, a timestamped
    file (compress_undo_<yyyyMMdd_HHmmss>.json) is generated. This log records every
    compressed file, archive path, and original file metadata so operations can be reverted
    using an undo script (e.g. undo-compressLogs.ps1).
    Aliases: -LogFile, -ManifestPath, -UndoLog
    Default: 'compress_undo_<yyyyMMdd_HHmmss>.json' in the script directory.

.PARAMETER DisableLog
    Disables writing the undo manifest log file.

.EXAMPLE
    .\compressLogs.ps1
    Compresses all .log files in 'C:\WindowsAzure\Logs' and all subfolders.

.EXAMPLE
    .\compressLogs.ps1 -Paths 'C:\WindowsAzure\Logs' -LogPath 'C:\Logs\run_audit.json'
    Compresses logs and outputs an undo manifest directly to 'C:\Logs\run_audit.json'.

.EXAMPLE
    .\compressLogs.ps1 -Paths 'C:\WindowsAzure\Logs', 'C:\Users\*\AppData\Local\CrashDumps' -Filters '*.log', '*.dmp'
    Scans Azure VM logs and all user crash dumps, compressing both .log and .dmp files.

.EXAMPLE
    .\compressLogs.ps1 -Paths 'C:\Users\*\AppData\Local\CrashDumps' -Filter '*.dmp' -OlderThanDays 30 -PurgeOldZipDays 60
    Compresses user crash dumps older than 30 days and removes any existing .zip files older than 60 days.

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
    [bool]$EnsureAdminPermissions = $false,

    [Parameter()]
    [ValidateRange(0, 3650)]
    [Alias("RemoveOldZipDays", "CleanZipOlderThanDays")]
    [int]$PurgeOldZipDays = 0,

    [Parameter()]
    [ValidateSet('TimestampHash', 'Hash', 'Timestamp', 'None')]
    [string]$UniqueNaming = 'TimestampHash',

    [Parameter()]
    [ValidateRange(4, 32)]
    [int]$HashLength = 9,

    [Parameter()]
    [switch]$OverwriteZip,

    [Parameter()]
    [Alias("LogFile", "ManifestPath", "UndoLog")]
    [string]$LogPath,

    [Parameter()]
    [switch]$DisableLog,

    [Parameter()]
    [switch]$SkipAdminCheck
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

# Function to persist or update the undo operation manifest (JSON)
function Save-UndoManifest {
    param(
        [string]$FilePath,
        [hashtable]$ManifestData
    )
    if (-not $FilePath) { return }
    try {
        $dir = [System.IO.Path]::GetDirectoryName($FilePath)
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
        $ManifestData | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $FilePath -Encoding UTF8 -Force
    }
    catch {
        Write-Warning "Failed to write undo log manifest to '$FilePath': $_"
    }
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
if (-not $SkipAdminCheck) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Error "This script requires elevated Administrator privileges. Please re-run in an elevated PowerShell session (Run as Administrator)."
        exit 1
    }
}

# 2. Resolve all target root directories
$targetDirectories = Expand-DirectoryTargets -Patterns $LogRoot

if (-not $targetDirectories -or $targetDirectories.Count -eq 0) {
    Write-Warning "No valid directories found to scan. Please verify specified paths."
    exit 0
}

# Resolve LogRoot parameter values to absolute paths for the manifest
$resolvedLogRoots = @(
    foreach ($pattern in $LogRoot) {
        $trimmed = $pattern.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        try {
            $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($trimmed)
        }
        catch {
            $trimmed
        }
    }
)

# 3. Initialize Undo Logging Manifest
$runStartTime = Get-Date
$runId = [Guid]::NewGuid().ToString()

if (-not $DisableLog) {
    $timestampStr = $runStartTime.ToString("yyyyMMdd_HHmmss")
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $defaultDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $LogPath = Join-Path -Path $defaultDir -ChildPath "compress_log_$timestampStr.json"
    }
    elseif ((Test-Path -LiteralPath $LogPath -PathType Container) -or $LogPath.EndsWith('\') -or $LogPath.EndsWith('/')) {
        $LogPath = Join-Path -Path $LogPath -ChildPath "compress_log_$timestampStr.json"
    }

    # Ensure LogPath is an absolute path
    try {
        $LogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
    }
    catch {
        try {
            $LogPath = [System.IO.Path]::GetFullPath($LogPath)
        }
        catch {
            # Keep path as provided if resolution fails
        }
    }
}

$logOperations = [System.Collections.Generic.List[PSObject]]::new()
$undoManifest = [ordered]@{
    SchemaVersion = "1.0"
    RunId         = $runId
    Script        = "compressLogs.ps1"
    MachineName   = $env:COMPUTERNAME
    UserName      = "$env:USERDOMAIN\$env:USERNAME"
    StartTimeUtc  = $runStartTime.ToUniversalTime().ToString("o")
    EndTimeUtc    = $null
    Status        = "InProgress"
    Parameters    = [ordered]@{
        LogRoots               = $resolvedLogRoots
        TargetDirectories      = $targetDirectories
        FileFilter             = $FileFilter
        OlderThanDays          = $OlderThanDays
        DeleteOriginal         = $DeleteOriginal
        EnsureAdminPermissions = $EnsureAdminPermissions
        PurgeOldZipDays        = $PurgeOldZipDays
        UniqueNaming           = $UniqueNaming
        HashLength             = $HashLength
        OverwriteZip           = $OverwriteZip.IsPresent
    }
    Summary       = [ordered]@{
        DirectoriesScanned     = 0
        TotalFilesEvaluated    = 0
        SuccessfullyCompressed = 0
        OldZipsPurged          = 0
        SkippedLocked          = 0
        SkippedExisting        = 0
        FailedOperations       = 0
        TotalOriginalBytes     = 0
        TotalCompressedBytes   = 0
        ReclaimedBytes         = 0
    }
    Operations    = $logOperations
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

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Log & Dump File Compression Tool" -ForegroundColor Cyan
Write-Host " Target Directories ($($targetDirectories.Count)):" -ForegroundColor White
foreach ($dir in $targetDirectories) {
    Write-Host "   - $dir" -ForegroundColor Gray
}
Write-Host " Target Filters    : $($normalizedFilters -join ', ')" -ForegroundColor White
Write-Host " Naming Scheme     : $UniqueNaming (Hash Length: $HashLength)" -ForegroundColor White
if ($OlderThanDays -gt 0) {
    Write-Host " Age Filter        : Older than $OlderThanDays days" -ForegroundColor White
}
else {
    Write-Host " Age Filter        : All ages (0+ days)" -ForegroundColor White
}
if ($PurgeOldZipDays -gt 0) {
    Write-Host " Purge Old Zips    : Yes (Older than $PurgeOldZipDays days)" -ForegroundColor Yellow
}
else {
    Write-Host " Purge Old Zips    : Disabled (0 days)" -ForegroundColor White
}
Write-Host " Remove Source     : $DeleteOriginal" -ForegroundColor White
Write-Host " Overwrite Zip     : $OverwriteZip" -ForegroundColor White
if (-not $DisableLog) {
    Write-Host " Undo Log Manifest : $LogPath" -ForegroundColor White
}
else {
    Write-Host " Undo Log Manifest : Disabled" -ForegroundColor DarkGray
}
Write-Host "==========================================================" -ForegroundColor Cyan

# 4. Discover files across all resolved directories
$cutoffDate = (Get-Date).AddDays(-$OlderThanDays)
$candidateFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$purgedZipFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$purgedZipBytes = 0
$purgeCutoffDate = if ($PurgeOldZipDays -gt 0) { (Get-Date).AddDays(-$PurgeOldZipDays) } else { $null }

# Optional: Purge existing zip files older than $PurgeOldZipDays
if ($PurgeOldZipDays -gt 0) {
    Write-Host "`nScanning for existing .zip archives older than $PurgeOldZipDays days to purge..." -ForegroundColor Cyan
    foreach ($dir in $targetDirectories) {
        $oldZips = Get-ChildItem -LiteralPath $dir -File -Recurse -Force -Filter '*.zip' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $purgeCutoffDate }

        if ($oldZips) {
            foreach ($zip in $oldZips) {
                $zipSize = $zip.Length
                if ($PSCmdlet.ShouldProcess($zip.FullName, "Purge old zip archive (Last modified: $($zip.LastWriteTime))")) {
                    try {
                        Remove-Item -LiteralPath $zip.FullName -Force -ErrorAction Stop
                        Write-Host "[Purged Old Zip] $($zip.FullName) ($(Format-FileSize $zipSize))" -ForegroundColor DarkYellow
                        $purgedZipFiles.Add($zip)
                        $purgedZipBytes += $zipSize

                        if (-not $DisableLog) {
                            $logOperations.Add([pscustomobject]@{
                                    Id                   = $logOperations.Count + 1
                                    TimestampUtc         = (Get-Date).ToUniversalTime().ToString("o")
                                    Action               = "PurgeZip"
                                    Status               = "Success"
                                    CanUndo              = $false
                                    OriginalPath         = $null
                                    OriginalName         = $null
                                    OriginalDirectory    = $null
                                    OriginalSize         = 0
                                    OriginalLastWriteUtc = $null
                                    ArchivePath          = $zip.FullName
                                    ArchiveName          = $zip.Name
                                    ArchiveSize          = $zipSize
                                    OriginalDeleted      = $null
                                    ErrorMessage         = $null
                                    Note                 = "Pre-existing zip archive permanently purged due to -PurgeOldZipDays retention cleanup."
                                })
                            Save-UndoManifest -FilePath $LogPath -ManifestData $undoManifest
                        }
                    }
                    catch {
                        Write-Warning "Failed to delete old zip file '$($zip.FullName)': $_"
                    }
                }
            }
        }
    }

    if ($purgedZipFiles.Count -gt 0) {
        Write-Host "Purged $($purgedZipFiles.Count) old zip archive(s) freeing $(Format-FileSize $purgedZipBytes).`n" -ForegroundColor Green
    }
    else {
        Write-Host "No old zip archives found older than $PurgeOldZipDays days.`n" -ForegroundColor Gray
    }
}

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
    if (-not $DisableLog) {
        $undoManifest.EndTimeUtc = (Get-Date).ToUniversalTime().ToString("o")
        $undoManifest.Status = "CompletedNoFilesFound"
        $undoManifest.Summary.DirectoriesScanned = $targetDirectories.Count
        Save-UndoManifest -FilePath $LogPath -ManifestData $undoManifest
    }
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
                $deletedOriginalSuccessfully = $false
                if ($DeleteOriginal) {
                    Remove-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
                    $deletedOriginalSuccessfully = $true
                    Write-Host "Removed original uncompressed file." -ForegroundColor DarkGray
                }
                $processedCount++

                if (-not $DisableLog) {
                    $logOperations.Add([pscustomobject]@{
                            Id                   = $logOperations.Count + 1
                            TimestampUtc         = (Get-Date).ToUniversalTime().ToString("o")
                            Action               = "Compress"
                            Status               = "Success"
                            CanUndo              = $true
                            OriginalPath         = $sourcePath
                            OriginalName         = $file.Name
                            OriginalDirectory    = $file.DirectoryName
                            OriginalSize         = $fileSize
                            OriginalLastWriteUtc = $file.LastWriteTimeUtc.ToString("o")
                            ArchivePath          = $zipPath
                            ArchiveName          = $zipFileName
                            ArchiveSize          = $compressedSize
                            OriginalDeleted      = $deletedOriginalSuccessfully
                            ErrorMessage         = $null
                            Note                 = $(if ($deletedOriginalSuccessfully) { "Original uncompressed file removed; can be restored by extracting archive." } else { "Original uncompressed file preserved; undo will remove created archive." })
                        })
                    Save-UndoManifest -FilePath $LogPath -ManifestData $undoManifest
                }
            }
            else {
                Write-Warning "FAILED: Zip archive was not found after Compress-Archive execution."
                $failedCount++

                if (-not $DisableLog) {
                    $logOperations.Add([pscustomobject]@{
                            Id                   = $logOperations.Count + 1
                            TimestampUtc         = (Get-Date).ToUniversalTime().ToString("o")
                            Action               = "Compress"
                            Status               = "Failed"
                            CanUndo              = $false
                            OriginalPath         = $sourcePath
                            OriginalName         = $file.Name
                            OriginalDirectory    = $file.DirectoryName
                            OriginalSize         = $fileSize
                            OriginalLastWriteUtc = $file.LastWriteTimeUtc.ToString("o")
                            ArchivePath          = $zipPath
                            ArchiveName          = $zipFileName
                            ArchiveSize          = 0
                            OriginalDeleted      = $false
                            ErrorMessage         = "Zip archive was not found after Compress-Archive execution."
                            Note                 = "Compression failed."
                        })
                    Save-UndoManifest -FilePath $LogPath -ManifestData $undoManifest
                }
            }
        }
        catch {
            Write-Error "ERROR: Failed to compress or remove '$sourcePath': $_"
            $failedCount++

            if (-not $DisableLog) {
                $logOperations.Add([pscustomobject]@{
                        Id                   = $logOperations.Count + 1
                        TimestampUtc         = (Get-Date).ToUniversalTime().ToString("o")
                        Action               = "Compress"
                        Status               = "Failed"
                        CanUndo              = $false
                        OriginalPath         = $sourcePath
                        OriginalName         = $file.Name
                        OriginalDirectory    = $file.DirectoryName
                        OriginalSize         = $fileSize
                        OriginalLastWriteUtc = $file.LastWriteTimeUtc.ToString("o")
                        ArchivePath          = $zipPath
                        ArchiveName          = $zipFileName
                        ArchiveSize          = 0
                        OriginalDeleted      = $false
                        ErrorMessage         = "$_"
                        Note                 = "Compression error occurred."
                    })
                Save-UndoManifest -FilePath $LogPath -ManifestData $undoManifest
            }
        }
    }
}

# 5. Display summary
$netSavings = [math]::Max(0, ($totalOriginalBytes - $totalCompressedBytes)) + $purgedZipBytes

$undoManifest.EndTimeUtc = (Get-Date).ToUniversalTime().ToString("o")
$undoManifest.Status = if ($failedCount -gt 0) { "CompletedWithErrors" } else { "Completed" }
$undoManifest.Summary.DirectoriesScanned = $targetDirectories.Count
$undoManifest.Summary.TotalFilesEvaluated = $candidateFiles.Count
$undoManifest.Summary.SuccessfullyCompressed = $processedCount
$undoManifest.Summary.OldZipsPurged = $purgedZipFiles.Count
$undoManifest.Summary.SkippedLocked = $skippedLockedCount
$undoManifest.Summary.SkippedExisting = $skippedExistingCount
$undoManifest.Summary.FailedOperations = $failedCount
$undoManifest.Summary.TotalOriginalBytes = $totalOriginalBytes
$undoManifest.Summary.TotalCompressedBytes = $totalCompressedBytes
$undoManifest.Summary.ReclaimedBytes = $netSavings

Write-Host "`n======================= SUMMARY ==========================" -ForegroundColor Cyan
Write-Host "Directories scanned          : $($targetDirectories.Count)"
Write-Host "Total files evaluated        : $($candidateFiles.Count)"
Write-Host "Successfully compressed      : $processedCount" -ForegroundColor Green
if ($PurgeOldZipDays -gt 0) {
    Write-Host "Old zip archives purged      : $($purgedZipFiles.Count) ($(Format-FileSize $purgedZipBytes))" -ForegroundColor $(if ($purgedZipFiles.Count -gt 0) { "Green" } else { "White" })
}
Write-Host "Skipped (locked/in-use)      : $skippedLockedCount" -ForegroundColor $(if ($skippedLockedCount -gt 0) { "Yellow" } else { "White" })
Write-Host "Skipped (zip already exists) : $skippedExistingCount" -ForegroundColor $(if ($skippedExistingCount -gt 0) { "Yellow" } else { "White" })
Write-Host "Failed operations            : $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "White" })
if ($processedCount -gt 0 -or $purgedZipBytes -gt 0) {
    if ($processedCount -gt 0) {
        Write-Host "Original Total Size          : $(Format-FileSize $totalOriginalBytes)"
        Write-Host "Compressed Total Size        : $(Format-FileSize $totalCompressedBytes)"
    }
    Write-Host "Total Reclaimed Disk Space   : $(Format-FileSize $netSavings)" -ForegroundColor Green
}

if (-not $DisableLog) {
    Save-UndoManifest -FilePath $LogPath -ManifestData $undoManifest
    Write-Host "`nUndo Log Manifest            : $LogPath" -ForegroundColor Cyan
    if ($processedCount -gt 0) {
        Write-Host "To undo operations recorded in this run, execute:" -ForegroundColor Gray
        Write-Host "  .\undo-compressLogs.ps1 -LogPath `"$LogPath`"" -ForegroundColor Yellow
    }
}
Write-Host "==========================================================" -ForegroundColor Cyan
