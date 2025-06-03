#
$primaryVmId = ""

$vaultSubscription = ""
$vaultName = ""
$fabric = ""
$container = ""
#
$recoveryRGId = ""
$cacheStorageAccountId = ""
$recoveryDiskEncryptionSetId = ""
$primaryProtContainerMapping = ""
#
Set-AzContext -Subscription ($primaryVmId -split "/")[2]
$vm = Get-AzVM -ResourceId $primaryVmId

Set-AzContext -Subscription $vaultSubscription
$vault = Get-AzRecoveryServicesVault -Name $vaultName 
Set-AzRecoveryServicesAsrVaultContext -Vault $vault
$fab = Get-AzRecoveryServicesAsrFabric -Name $fabric
$protContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name $container -Fabric $fab


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
        -ProtectionContainerMapping $primaryProtContainerMapping `
        -Name (New-Guid).Guid `
        -RecoveryResourceGroupId $recoveryRGId `
        -RecoveryAvailabilityZone $vm.Zones[0]
}
else {
    $TempASRJob = New-AzRecoveryServicesAsrReplicationProtectedItem -AzureToAzure `
        -AzureVmId $vm.Id -AzureToAzureDiskReplicationConfiguration $diskConfigs `
        -ProtectionContainerMapping $primaryProtContainerMapping `
        -Name (New-Guid).Guid `
        -RecoveryResourceGroupId $recoveryRGId
}

while (($TempASRJob.State -eq "InProgress") -or ($TempASRJob.State -eq "NotStarted")) {
    Start-Sleep -Seconds 30
    $TempASRJob = Get-AzRecoveryServicesAsrJob -Job $TempASRJob
}

Write-Output $TempASRJob.State