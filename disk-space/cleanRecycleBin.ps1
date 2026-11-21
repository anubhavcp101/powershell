<#
.SYNOPSIS
    Cleans the Recycle Bin for all users on drive C: (or specified drive).
.DESCRIPTION
    On NTFS drives, the Recycle Bin is stored at C:\$Recycle.Bin\<User-SID>.
    Standard Clear-RecycleBin only empties the current user's bin. This script
    iterates through all user SID folders under C:\$Recycle.Bin and removes
    their contents.

    Must be run from an elevated session (Run as Administrator).

.EXAMPLE
    .\cleanRecycleBin.ps1

.NOTES
    QUICK ONE-LINER ALTERNATIVES (FOR VERIFICATION/TESTING):
    ---------------------------------------------------------
    Option 1: Using Windows Command Prompt (Admin) to wipe and let Windows recreate it:
        rd /s /q C:\$Recycle.Bin

    Option 2: Running that CMD command directly from PowerShell (Admin):
        cmd.exe /c "rd /s /q C:\`$Recycle.Bin"

    Option 3: Quick PowerShell loop one-liner:
        Get-ChildItem -LiteralPath 'C:\$Recycle.Bin' -Force -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Force -Recurse | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue }
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$DriveLetter = "C"
)

# Ensure script is running with elevated Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must be executed in an elevated PowerShell prompt (Run as Administrator)."
    exit 1
}

$driveLetterClean = $DriveLetter.TrimEnd(":\")
$recycleBinPath = "${driveLetterClean}:\`$Recycle.Bin"

if (-not (Test-Path -LiteralPath $recycleBinPath)) {
    Write-Host "Recycle bin path '$recycleBinPath' does not exist." -ForegroundColor Yellow
    exit 0
}

Write-Host "Scanning Recycle Bin at '$recycleBinPath'..." -ForegroundColor Cyan

# Enumerate user SID directories inside $Recycle.Bin
$userBins = Get-ChildItem -LiteralPath $recycleBinPath -Force -Directory -ErrorAction SilentlyContinue

if (-not $userBins) {
    Write-Host "No user Recycle Bin folders found under '$recycleBinPath'." -ForegroundColor Yellow
    exit 0
}

$totalDeletedCount = 0

foreach ($folder in $userBins) {
    $sid = $folder.Name

    # Attempt to resolve the SID into an account name (Domain\User or Computer\User)
    try {
        $account = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value
    } catch {
        $account = "Unknown / Orphaned SID"
    }

    Write-Host "Checking bin for: $account ($sid)..." -NoNewline

    $items = Get-ChildItem -LiteralPath $folder.FullName -Force -Recurse -ErrorAction SilentlyContinue
    $count = ($items | Measure-Object).Count

    if ($count -gt 0) {
        if ($PSCmdlet.ShouldProcess("$account ($sid)", "Delete $count items from Recycle Bin")) {
            $items | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            Write-Host " Done (Removed $count items/files)." -ForegroundColor Green
            $totalDeletedCount += $count
        } else {
            Write-Host " Skipped (WhatIf mode)." -ForegroundColor Yellow
        }
    } else {
        Write-Host " Empty." -ForegroundColor Gray
    }
}

Write-Host "`nCleanup completed. Total items purged: $totalDeletedCount" -ForegroundColor Green
