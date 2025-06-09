#
$primaryVmId = ""

$vaultSubscription = ""
$vaultName = ""
$fabric = ""
$container = ""
#
$policyName = ""
$primaryLocation = "West US" # "West US 3"
$recoveryRGId = ""
$cacheStorageAccountId = ""
#
$recoveryDiskEncryptionSetId = ""
Set-AzContext -Subscription ($primaryVmId -split "/")[2]
$vm = Get-AzVM -ResourceId $primaryVmId

Set-AzContext -Subscription $vaultSubscription
$vault = Get-AzRecoveryServicesVault -Name $vaultName 
Set-AzRecoveryServicesAsrVaultContext -Vault $vault
$fab = Get-AzRecoveryServicesAsrFabric -Name $fabric
$protContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name $container -Fabric $fab

$primaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $protContainer | where PolicyFriendlyName -eq $policyName | where SourceFabricFriendlyName -eq $primaryLocation

$recoveryRG = Get-AzResource -ResourceId $recoveryRGId

# $replicaDiskAccountType = $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
$osDiskConfig = New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -ManagedDisk -LogStorageAccountId $cacheStorageAccountId `
    -DiskId $vm.StorageProfile.OsDisk.ManagedDisk.Id -RecoveryResourceGroupId $recoveryRGId `
    -RecoveryReplicaDiskAccountType $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType `
    -RecoveryTargetDiskAccountType $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType `
    -RecoveryDiskEncryptionSetId $recoveryDiskEncryptionSetId

$diskConfigs = @()

foreach ($datadisk in $vm.StorageProfile.DataDisks) {

    $replicaDiskAccountType = $datadisk.ManagedDisk.StorageAccountType
    if ($replicaDiskAccountType -in @("PremiumV2_LRS", "Ultra_LRS")) {
        $replicaDiskAccountType = "Premium_LRS"
    }

    $datadiskConfig = New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -ManagedDisk `
        -LogStorageAccountId $cacheStorageAccountId -DiskId $datadisk.ManagedDisk.Id -RecoveryResourceGroupId $recoveryRGId `
        -RecoveryReplicaDiskAccountType $replicaDiskAccountType `
        -RecoveryTargetDiskAccountType $datadisk.ManagedDisk.StorageAccountType `
        -RecoveryDiskEncryptionSetId $recoveryDiskEncryptionSetId

    $diskConfigs += $datadiskConfig
}

$diskConfigs += $osDiskConfig

if ($vm.Zones) {
    $TempASRJob = New-AzRecoveryServicesAsrReplicationProtectedItem -AzureToAzure `
        -AzureVmId $vm.Id -AzureToAzureDiskReplicationConfiguration $diskConfigs `
        -ProtectionContainerMapping $primaryContainerMapping `
        -Name (New-Guid).Guid `
        -RecoveryResourceGroupId $recoveryRGId `
        -RecoveryAvailabilityZone $vm.Zones[0]
}
else {
    $TempASRJob = New-AzRecoveryServicesAsrReplicationProtectedItem -AzureToAzure `
        -AzureVmId $vm.Id -AzureToAzureDiskReplicationConfiguration $diskConfigs `
        -ProtectionContainerMapping $primaryContainerMapping `
        -Name (New-Guid).Guid `
        -RecoveryResourceGroupId $recoveryRGId
}

while (($TempASRJob.State -eq "InProgress") -or ($TempASRJob.State -eq "NotStarted")) {
    Start-Sleep -Seconds 30
    $TempASRJob = Get-AzRecoveryServicesAsrJob -Job $TempASRJob
}

Write-Output $TempASRJob.State

function ConfigureAsr {
    param (
        $primaryVmId,
        $vaultSubscription,
        $vaultName,
        $fabric,
        $container,
        $policyName,
        $primaryRegion,
        $recoveryRGId,
        $cacheStorageAccountId,
        $recoveryDiskEncryptionSetId
    )

    if ($primaryRegion -eq "westus") {
        $primaryLocation = "West US"
    }
    elseif ($primaryRegion -eq "westus3") {
        $primaryLocation = "West US 3"
    }
    else {
        $primaryLocation = $primaryRegion
    }

    Set-AzContext -Subscription ($primaryVmId -split "/")[2]
    $vm = Get-AzVM -ResourceId $primaryVmId

    Set-AzContext -Subscription $vaultSubscription
    $vault = Get-AzRecoveryServicesVault -Name $vaultName 
    Set-AzRecoveryServicesAsrVaultContext -Vault $vault
    $fab = Get-AzRecoveryServicesAsrFabric -Name $fabric
    $protContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name $container -Fabric $fab

    $primaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $protContainer | where PolicyFriendlyName -eq $policyName | where SourceFabricFriendlyName -eq $primaryLocation

    # $recoveryRG = Get-AzResource -ResourceId $recoveryRGId

    # $replicaDiskAccountType = $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
    $osDiskConfig = New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -ManagedDisk -LogStorageAccountId $cacheStorageAccountId `
        -DiskId $vm.StorageProfile.OsDisk.ManagedDisk.Id -RecoveryResourceGroupId $recoveryRGId `
        -RecoveryReplicaDiskAccountType $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType `
        -RecoveryTargetDiskAccountType $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType `
        -RecoveryDiskEncryptionSetId $recoveryDiskEncryptionSetId

    $diskConfigs = @()

    foreach ($datadisk in $vm.StorageProfile.DataDisks) {

        $replicaDiskAccountType = $datadisk.ManagedDisk.StorageAccountType
        if ($replicaDiskAccountType -in @("PremiumV2_LRS", "Ultra_LRS")) {
            $replicaDiskAccountType = "Premium_LRS"
        }

        $datadiskConfig = New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -ManagedDisk `
            -LogStorageAccountId $cacheStorageAccountId -DiskId $datadisk.ManagedDisk.Id -RecoveryResourceGroupId $recoveryRGId `
            -RecoveryReplicaDiskAccountType $replicaDiskAccountType `
            -RecoveryTargetDiskAccountType $datadisk.ManagedDisk.StorageAccountType `
            -RecoveryDiskEncryptionSetId $recoveryDiskEncryptionSetId

        $diskConfigs += $datadiskConfig
    }

    $diskConfigs += $osDiskConfig

    if ($vm.Zones) {
        $TempASRJob = New-AzRecoveryServicesAsrReplicationProtectedItem -AzureToAzure `
            -AzureVmId $vm.Id -AzureToAzureDiskReplicationConfiguration $diskConfigs `
            -ProtectionContainerMapping $primaryContainerMapping `
            -Name (New-Guid).Guid `
            -RecoveryResourceGroupId $recoveryRGId `
            -RecoveryAvailabilityZone $vm.Zones[0]
    }
    else {
        $TempASRJob = New-AzRecoveryServicesAsrReplicationProtectedItem -AzureToAzure `
            -AzureVmId $vm.Id -AzureToAzureDiskReplicationConfiguration $diskConfigs `
            -ProtectionContainerMapping $primaryContainerMapping `
            -Name (New-Guid).Guid `
            -RecoveryResourceGroupId $recoveryRGId
    }

    while (($TempASRJob.State -eq "InProgress") -or ($TempASRJob.State -eq "NotStarted")) {
        Start-Sleep -Seconds 30
        $TempASRJob = Get-AzRecoveryServicesAsrJob -Job $TempASRJob
    }

    Write-Output $TempASRJob.State

}

# ------- Further Working --------------------

if ($primaryRegion -eq "westus") {
    $primaryLocation = "West US"
}
elseif ($primaryRegion -eq "westus3") {
    $primaryLocation = "West US 3"
}
else {
    $primaryLocation = $primaryRegion
}
$secondaryRegion = "East US 3"

Set-AzContext -Subscription $vaultSubscription
$vault = Get-AzRecoveryServicesVault -Name $vaultName 
Set-AzRecoveryServicesAsrVaultContext -Vault $vault
$fabric = Get-AzRecoveryServicesAsrFabric | Where-Object { $_.FriendlyName -like $primaryLocation } # "East US" or "West US 3"

# $container = (Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric | Where-Object { (($_.FabricFriendlyName -like $primaryLocation) -and ($_.AvailablePolicies.FriendlyName -contains "My-Policy")) })[0]

$containers = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric | Where-Object { ($_.FabricFriendlyName -like $primaryLocation) }
$foundContainer = $false
$rightContainer = $null
$foundPrimaryToRecoveryMapping = $false
$foundRecoveryToPrimaryMapping = $false

foreach ($container in $containers) {
    foreach ($mapping in $container.ProtectionContainerMappings) {
        if (($mapping.SourceFabricFriendlyName -like $primaryLocation) -and ($mapping.TargetFabricFriendlyName -like $secondaryRegion)) {
            $foundPrimaryToRecoveryMapping = $true
        }
        elseif (($mapping.SourceFabricFriendlyName -like $secondaryRegion) -and ($mapping.TargetFabricFriendlyName -like $primaryLocation)) {
            $foundRecoveryToPrimaryMapping = $true
        }
    } 
    if ($foundPrimaryToRecoveryMapping -and $foundRecoveryToPrimaryMapping) {
        $foundContainer = $true
        $rightContainer = $container
        break 
    } 
}

if ( -not $foundContainer) {
    Write-Error "Didn't find any container with right mappings"
}


$primaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $rightContainer | where PolicyFriendlyName -eq $policyName | where SourceFabricFriendlyName -eq $primaryLocation

# ---- Further Working -----------

$replicationPolicy = ""
$createdContainer = $false
$primaryFabric = Get-AzRecoveryServicesAsrFabric | Where-Object { $_.FriendlyName -like $primaryLocation }

if (-not $primaryFabric) {
    New-AzRecoveryServicesAsrFabric -Azure -Name "asr-a2a-primary-$($primaryLocation.tolower().replace(' ',''))" -Location $primaryLocation
    $primaryfab = Get-AzRecoveryServicesAsrFabric -Name "asr-a2a-primary-$($primaryLocation.tolower().replace(' ',''))"

    $createdContainer = $true
    New-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-primary-$($primaryLocation.tolower().replace(' ',''))-container" -InputObject $primaryfab
    $primaryContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))-container" -Fabric $primaryfab

}

$secondaryFabric = Get-AzRecoveryServicesAsrFabric | Where-Object { $_.FriendlyName -like $secondaryRegion }

if (-not $secondaryFabric) {
    New-AzRecoveryServicesAsrFabric -Azure -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))" -Location $secondaryRegion
    $secondaryfab = Get-AzRecoveryServicesAsrFabric -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))"

    $createdContainer = $true
    New-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))-container" -InputObject $secondaryfab
    $secondaryContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))-container" -Fabric $secondaryfab

}

$ReplicationPolicy = Get-AzRecoveryServicesAsrPolicy -Name $replicationPolicy

if ( -not $replicationPolicy) {
    New-AzRecoveryServicesAsrPolicy -AzureToAzure -Name $replicationPolicy -RecoveryPointRetentionInHours 24 -ApplicationConsistentSnapshotFrequencyInHours 3
    $ReplicationPolicy = Get-AzRecoveryServicesAsrPolicy -Name $replicationPolicy
}

if ($createdContainer) {
    # create container mappings

    New-AzRecoveryServicesAsrProtectionContainerMapping -Name "$($primaryRegion.tolower().replace(' ',''))-$($secondaryRegion.tolower().replace(' ',''))-mapping" `
        -Policy $replicationPolicy -PrimaryProtectionContainer $primaryContainer -RecoveryProtectionContainer $secondaryContainer

    New-AzRecoveryServicesAsrProtectionContainerMapping -Name "$($secondaryRegion.tolower().replace(' ',''))-$($primaryRegion.tolower().replace(' ',''))-mapping" `
        -Policy $replicationPolicy -PrimaryProtectionContainer $secondaryContainer -RecoveryProtectionContainer $primaryContainer
}

$primaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $protContainer | where PolicyFriendlyName -eq $policyName | where SourceFabricFriendlyName -eq $primaryLocation | where TargetFabricFriendlyName -eq $secondaryRegion
if (-not $primaryContainerMapping) {
    New-AzRecoveryServicesAsrProtectionContainerMapping -Name "$($primaryRegion.tolower().replace(' ',''))-$($secondaryRegion.tolower().replace(' ',''))-mapping" `
        -Policy $replicationPolicy -PrimaryProtectionContainer $primaryContainer -RecoveryProtectionContainer $secondaryContainer
    $primaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $protContainer | where PolicyFriendlyName -eq $policyName | where SourceFabricFriendlyName -eq $primaryLocation | where TargetFabricFriendlyName -eq $secondaryRegion

}

$secondaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $protContainer | where PolicyFriendlyName -eq $replicationPolicy | where SourceFabricFriendlyName -eq $secondaryRegion | where TargetFabricFriendlyName -eq $primaryLocation

if (-not $secondaryContainerMapping) {
    New-AzRecoveryServicesAsrProtectionContainerMapping -Name "$($secondaryRegion.tolower().replace(' ',''))-$($primaryLocation.tolower().replace(' ',''))-mapping" `
        -Policy $replicationPolicy -PrimaryProtectionContainer $secondaryContainer -RecoveryProtectionContainer $primaryContainer
    $primaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $protContainer | where PolicyFriendlyName -eq $policyName | where SourceFabricFriendlyName -eq $primaryLocation | where TargetFabricFriendlyName -eq $secondaryRegion

}