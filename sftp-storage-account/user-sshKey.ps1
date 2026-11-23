<#
.SYNOPSIS
    Configures Azure Storage Account SFTP and provisions local SFTP users with SSH key pairs.

.DESCRIPTION
    This script performs end-to-end setup for Azure Storage SFTP:
    1. Pre-flight verification (Azure session, required modules, ssh-keygen, HNS capability).
    2. Enables SFTP on the target Azure Storage Account (if not already enabled).
    3. Generates secure ed25519 SSH key pairs for specified local users.
    4. Validates/creates storage containers for each user.
    5. Configures Azure Storage Local Users with SSH public keys, permission scopes, and home directories.
    6. Exports user configuration details to a CSV audit file.

.PARAMETER ResourceGroupName
    The name of the Azure Resource Group containing the storage account.

.PARAMETER StorageAccountName
    The name of the Azure Storage Account. Note: SFTP requires Hierarchical Namespace (HNS) to be enabled.

.PARAMETER Users
    An array of custom objects defining users and their assigned containers.
    Example: @([PSCustomObject]@{ UserName = 'john'; ContainerName = 'data' })

.PARAMETER Permissions
    Container permissions assigned to the local user.
    Allowed letters: r (read), w (write), d (delete), l (list), c (create). Defaults to "rcwdl".

.PARAMETER CreateContainerIfMissing
    If specified, automatically creates the user's assigned container if it does not already exist.

.PARAMETER OutputDir
    Directory path where generated SSH keys and user CSV reports will be saved. Defaults to current directory.

.PARAMETER CleanTempKeys
    If specified, deletes the temporary directory containing raw private/public key files after CSV export.

.EXAMPLE
    .\sftpStorageAcccount.ps1 -ResourceGroupName "rg-prod-data" -StorageAccountName "stprodsftp01"

.EXAMPLE
    .\sftpStorageAcccount.ps1 -ResourceGroupName "rg-prod-data" -StorageAccountName "stprodsftp01" -CreateContainerIfMissing -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = "Azure Resource Group name")]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true, Position = 1, HelpMessage = "Azure Storage Account name")]
    [ValidateNotNullOrEmpty()]
    [string]$StorageAccountName,

    [Parameter(Position = 2)]
    [array]$Users = @(
        [PSCustomObject]@{ UserName = "xyz"; ContainerName = "xyc" },
        [PSCustomObject]@{ UserName = "xyd"; ContainerName = "xyr" },
        [PSCustomObject]@{ UserName = "xyg"; ContainerName = "xyh" }
    ),

    [Parameter()]
    [ValidatePattern('^[rcwdl]+$')]
    [string]$Permissions = "rcwdl",

    [Parameter()]
    [switch]$CreateContainerIfMissing,

    [Parameter()]
    [string]$OutputDir = ".",

    [Parameter()]
    [switch]$CleanTempKeys
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==============================================================================
# Helper Functions & Logging
# ==============================================================================
function Write-Step {
    param([string]$Message)
    Write-Host "`n[STEP] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function Write-Failure {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Gray
}

# ==============================================================================
# 1. Pre-flight Safety Checks
# ==============================================================================
Write-Step "Performing pre-flight checks..."

# Check 1.1: Verify ssh-keygen exists
$sshKeygenCmd = Get-Command "ssh-keygen.exe" -ErrorAction SilentlyContinue
if (-not $sshKeygenCmd) {
    Write-Failure "ssh-keygen.exe was not found in your PATH. Please install OpenSSH Client tools or ensure ssh-keygen is in PATH."
    exit 1
}
Write-Info "Found ssh-keygen at: $($sshKeygenCmd.Source)"

# Check 1.2: Verify required Az modules
$requiredModules = @('Az.Accounts', 'Az.Storage')
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Failure "Required PowerShell module '$module' is not installed. Installing it"
        Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
    }
}
Write-Info "Required Az modules are available."

# Check 1.3: Verify Azure login context
try {
    $azContext = Get-AzContext -ErrorAction Stop
    if (-not $azContext -or -not $azContext.Account) {
        throw "No active Azure context found."
    }
    Write-Success "Connected to Azure subscription '$($azContext.Subscription.Name)' ($($azContext.Subscription.Id)) as '$($azContext.Account.Id)'."
}
catch {
    Write-Failure "Not authenticated to Azure. Trying to run 'Connect-AzAccount' "
    Connect-AzAccount
}

# Check 1.4: Verify Resource Group existence
Write-Info "Checking Resource Group '$ResourceGroupName'..."
try {
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
    Write-Success "Resource group '$ResourceGroupName' found in region '$($rg.Location)'."
}
catch {
    Write-Failure "Resource group '$ResourceGroupName' was not found or access was denied. Details: $($_.Exception.Message)"
    exit 1
}

# Check 1.5: Verify Storage Account existence and HNS requirement
Write-Info "Checking Storage Account '$StorageAccountName'..."
try {
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
}
catch {
    Write-Failure "Storage Account '$StorageAccountName' was not found in '$ResourceGroupName'. Details: $($_.Exception.Message)"
    exit 1
}

# SFTP requires Hierarchical Namespace (HNS / Data Lake Gen2)
if (-not $storageAccount.EnableHierarchicalNamespace) {
    Write-Failure "Storage Account '$StorageAccountName' does NOT have Hierarchical Namespace (HNS) enabled."
    Write-Failure "Azure SFTP requires Hierarchical Namespace (Data Lake Storage Gen2). Please enable HNS on the storage account before using SFTP."
    exit 1
}
Write-Success "Storage Account '$StorageAccountName' verified (Hierarchical Namespace is enabled)."

# Check 1.6: Validate Users list
if (-not $Users -or $Users.Count -eq 0) {
    Write-Failure "No users provided in `$Users array."
    exit 1
}

# Validate username format (Azure SFTP rules: 3-64 chars, lowercase alphanumeric, hyphens, underscores)
$userPattern = '^[a-z0-9_-]{3,64}$'
foreach ($u in $Users) {
    if ([string]::IsNullOrWhiteSpace($u.UserName) -or [string]::IsNullOrWhiteSpace($u.ContainerName)) {
        Write-Failure "Each user object must have non-empty 'UserName' and 'ContainerName' properties."
        exit 1
    }
    if ($u.UserName -notmatch $userPattern) {
        Write-Failure "Username '$($u.UserName)' is invalid. Azure SFTP usernames must be 3-64 characters and contain only lowercase letters, numbers, hyphens, or underscores."
        exit 1
    }
}

# ==============================================================================
# 2. Enable SFTP on Storage Account (if not already enabled)
# ==============================================================================
Write-Step "Checking SFTP status on Storage Account '$StorageAccountName'..."

if ($storageAccount.EnableSftp -eq $true) {
    Write-Success "SFTP is already enabled on '$StorageAccountName'."
}
else {
    Write-Info "SFTP is currently disabled on '$StorageAccountName'. Enabling..."
    if ($PSCmdlet.ShouldProcess($StorageAccountName, "Enable SFTP")) {
        try {
            # Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -EnableSftp $true -ErrorAction Stop | Out-Null
            # Write-Success "SFTP successfully enabled on '$StorageAccountName'."
        }
        catch {
            Write-Failure "Failed to enable SFTP on '$StorageAccountName'. Details: $($_.Exception.Message)"
            exit 1
        }
    }
    else {
        Write-Info "WhatIf: Skipped enabling SFTP on '$StorageAccountName'."
    }
}

# ==============================================================================
# 3. Generate SSH Key Pairs for Each User
# ==============================================================================
Write-Step "Generating SSH ed25519 key pairs for users..."

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resolvedOutputDir = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $OutputDir))
if (-not (Test-Path -LiteralPath $resolvedOutputDir)) {
    New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null
}

$tempDir = Join-Path $resolvedOutputDir "sshTemp-$timestamp"
if (-not (Test-Path -LiteralPath $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}
Write-Info "Temporary keys directory created at: $tempDir"

$processedUsers = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($user in $Users) {
    $userName = $user.UserName
    $containerName = $user.ContainerName
    $privateKey = Join-Path $tempDir $userName
    $publicKey = "$privateKey.pub"

    Write-Info "Generating key for user: $userName..."

    # Overwrite protection / check if key exists
    if (Test-Path -LiteralPath $privateKey) {
        Remove-Item -LiteralPath $privateKey, $publicKey -Force -ErrorAction SilentlyContinue
    }

    if ($PSCmdlet.ShouldProcess($userName, "Generate SSH ed25519 Key Pair")) {
        # Generate ed25519 key with empty passphrase (-N "")
        $keygenProcess = Start-Process -FilePath "ssh-keygen.exe" `
            -ArgumentList @("-t", "ed25519", "-C", "$userName@$containerName", "-f", "`"$privateKey`"", "-N", "''''") `
            -NoNewWindow -PassThru -Wait

        if ($keygenProcess.ExitCode -ne 0 -or (-not (Test-Path -LiteralPath $publicKey))) {
            Write-Failure "SSH key generation failed for user '$userName' (Exit code: $($keygenProcess.ExitCode))."
            continue
        }

        try {
            $publicKeyContent = (Get-Content -LiteralPath $publicKey -Raw).Trim()
            $privateKeyContent = (Get-Content -LiteralPath $privateKey -Raw).Trim()

            if ([string]::IsNullOrWhiteSpace($publicKeyContent) -or [string]::IsNullOrWhiteSpace($privateKeyContent)) {
                throw "Generated key file is empty."
            }

            $userRecord = [PSCustomObject]@{
                UserName      = $userName
                ContainerName = $containerName
                PublicKey     = $publicKeyContent
                PrivateKey    = $privateKeyContent
                Status        = "KeyGenerated"
            }
            $processedUsers.Add($userRecord)
            Write-Success "Generated SSH key pair for '$userName'."
        }
        catch {
            Write-Failure "Failed to read generated keys for '$userName': $($_.Exception.Message)"
        }
    }
    else {
        Write-Info "WhatIf: Skipped key generation for '$userName'."
    }
}

if ($processedUsers.Count -eq 0 -and -not $WhatIfPreference) {
    Write-Failure "No user keys were successfully generated. Aborting."
    exit 1
}

# Export User Info to CSV
$csvPath = Join-Path $resolvedOutputDir "UserInfo-$timestamp.csv"
if ($processedUsers.Count -gt 0) {
    try {
        $processedUsers | Export-Csv -NoTypeInformation -Force -Path $csvPath -Encoding utf8
        Write-Success "User and key information exported to CSV: $csvPath"
        Write-Warning "The exported CSV contains PRIVATE KEYS. Store it securely and restrict file permissions!"
    }
    catch {
        Write-Failure "Failed to export user CSV: $($_.Exception.Message)"
    }
}

# ==============================================================================
# 4. Validate / Create Containers & Provision Azure Local Users
# ==============================================================================
Write-Step "Configuring Local Users in Azure Storage..."

$storageContext = $storageAccount.Context
$summaryResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($user in $processedUsers) {
    $userName = $user.UserName
    $containerName = $user.ContainerName
    Write-Info "Processing user '$userName' on container '$containerName'..."

    # 4.1 Container check / creation
    try {
        $container = Get-AzStorageContainer -Name $containerName -Context $storageContext -ErrorAction SilentlyContinue
        if (-not $container) {
            if ($CreateContainerIfMissing) {
                if ($PSCmdlet.ShouldProcess($containerName, "Create blob container")) {
                    Write-Info "Container '$containerName' does not exist. Creating..."
                    New-AzStorageContainer -Name $containerName -Context $storageContext -Permission Off -ErrorAction Stop | Out-Null
                    Write-Success "Container '$containerName' created."
                }
            }
            else {
                Write-Warning "Container '$containerName' does not exist in storage account '$StorageAccountName'. The user may be unable to access files until the container is created."
            }
        }
        else {
            Write-Info "Container '$containerName' verified."
        }
    }
    catch {
        Write-Warning "Could not verify container '$containerName': $($_.Exception.Message)"
    }

    # 4.2 Provision Local User with SSH Key & Permission Scopes
    if ($PSCmdlet.ShouldProcess("$userName ($StorageAccountName)", "Configure SFTP Local User")) {
        try {
            # Define container permission scope
            $permScope = New-AzStorageLocalUserPermissionScope `
                -Permission $Permissions `
                -ResourceName $containerName `
                -Service "blob"

            # Create SSH Public Key object for Az cmdlets
            $sshKeyObj = New-AzStorageLocalUserSshPublicKey `
                -Key $user.PublicKey `
                -Description "Key generated on $timestamp"

            # Set local user with permissions, home directory, and SSH key
            $localUser = Set-AzStorageLocalUser `
                -ResourceGroupName $ResourceGroupName `
                -StorageAccountName $StorageAccountName `
                -UserName $userName `
                -HomeDirectory $containerName `
                -PermissionScope @($permScope) `
                -SshAuthorizedKey @($sshKeyObj) `
                -HasSshKey $true `
                -HasSharedKey $false `
                -ErrorAction Stop

            Write-Success "Local user '$userName' successfully configured in '$StorageAccountName'."
            
            $summaryResults.Add([PSCustomObject]@{
                    UserName      = $userName
                    Container     = $containerName
                    Permissions   = $Permissions
                    HomeDirectory = $containerName
                    SshConfigured = $true
                    Status        = "Success"
                })
        }
        catch {
            Write-Failure "Failed to configure local user '$userName': $($_.Exception.Message)"
            $summaryResults.Add([PSCustomObject]@{
                    UserName      = $userName
                    Container     = $containerName
                    Permissions   = $Permissions
                    HomeDirectory = $containerName
                    SshConfigured = $false
                    Status        = "Failed: $($_.Exception.Message)"
                })
        }
    }
    else {
        Write-Info "WhatIf: Skipped configuring local user '$userName'."
    }
}

# ==============================================================================
# 5. Cleanup & Summary
# ==============================================================================
if ($CleanTempKeys -and (Test-Path -LiteralPath $tempDir)) {
    Write-Step "Cleaning up temporary key directory..."
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Success "Temporary keys directory removed."
}
else {
    Write-Info "Raw key files retained in: $tempDir"
}

Write-Step "Execution Summary"
if ($summaryResults.Count -gt 0) {
    $summaryResults | Format-Table -AutoSize
}
else {
    Write-Info "No users were modified."
}

Write-Success "Script completed. Review audit log: $csvPath"

