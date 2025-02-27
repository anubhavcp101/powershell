#
function replicateVm {
    param (
        [string]$vmName,
        [string]$failoverRG,
        [string]$cacheStorageAccount,
        [string]$failoverDiskEncryptionSet,
        #
        [string]$vault,
        [string]$primaryRegion, 
        [string]$failoverRegion,
        [string]$replicationPolicy
        #
    )
    $vaultName = $vault.Replace(' ', '')
    $vaultId = (Search-AzGraph -Query "resources | where type == ""microsoft.recoveryservices/vaults"" | where name like ""$vaultName"" | project id,subscriptionId" -UseTenantScope).id 
    Set-AzContext -Subscription ($vaultId -split ("/"))[2]
    $azVault = Get-AzRecoveryServicesVault -ResourceGroupName ($vaultId -split ("/"))[4] -Name ($vaultId -split ("/"))[-1]
    Set-AzRecoveryServicesAsrVaultContext -Vault $azVault

    $vmname = $vmName.Replace(' ', '')
    $resId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project id") -UseTenantScope).id; write $resId;
    $subsId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project subscriptionId") -UseTenantScope).subscriptionId; write $subsId;
    $currentSubscriptionId = (Get-AzContext).Subscription.Id.ToString()
    if ($currentSubscriptionId -ne $subsId) { Set-AzContext -SubscriptionId $subsId -ErrorAction Stop }
    $resIdCount = ($resId | Measure-Object).Count 
    if (($resIdCount -le 0) -or ($resIdCount -ge 2)) {
        Write-Error $vmname Not found
    } 
    else {
        $failoverRGName = $failoverRG.Replace(' ', '')
        $failoverRgId = (Search-AzGraph -Query ("resourcecontainers | where type == ""microsoft.resources/subscriptions/resourcegroups"" | where name like ""$failoverRGName"" | project id, subscriptionId") -UseTenantScope).id 

        $cacheStorageAccountName = $cacheStorageAccount.Replace(' ', '')
        $CacheStorageAccountId = (Search-AzGraph -Query ("resources | where type == ""microsoft.storage/storageaccounts"" | where name like ""$cacheStorageAccountName"" | project id,subscriptionId") -UseTenantScope).id 

        $failoverDiskEncryptionSetName = $failoverDiskEncryptionSet.Replace(' ', '')
        $failoverDiskEncryptionSetId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/diskencryptionsets"" | where name like ""$failoverDiskEncryptionSetName"" | project id, subscriptionId") -UseTenantScope).id 

        if ((($failoverRgId | Measure-Object).Count -ne 1) -or (($CacheStorageAccountId | Measure-Object).Count -ne 1) -or (($failoverDiskEncryptionSetId | Measure-Object).Count -ne 1) ) {
            Write-Host Please check $failoverRG , $cacheStorageAccount or $failoverDiskEncryptionSet
            return 
        }

        $vm = Get-AzVM -ResourceId $resId

        $AllVmDisks = if (($vm.StorageProfile.DataDisks | Measure-Object).Count -gt 0) { $vm.StorageProfile.DataDisks } else { @() }
        $AllVmDisks += $vm.StorageProfile.OsDisk

        $diskAsrConfigs = @()
        $AllVmDisks | ForEach-Object {
            $diskId = $_.ManagedDisk.Id
            $diskType = $_.ManagedDisk.StorageAccountType

            $diskAsrConfig = New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -ManagedDisk `
                -LogStorageAccountId $CacheStorageAccountId `
                -DiskId $diskId `
                -RecoveryResourceGroupId $failoverRgId `
                -RecoveryReplicaDiskAccountType $diskType `
                -RecoveryTargetDiskAccountType $diskType `
                -RecoveryDiskEncryptionSetId $failoverDiskEncryptionSetId

            $diskAsrConfigs += $diskAsrConfig
        }

        Set-AzContext -Subscription ($vaultId -split ("/"))[2]
        Set-AzRecoveryServicesAsrVaultContext -Vault $azVault
        
        $primaryFabric = Get-AzRecoveryServicesAsrFabric | where-object { $_.fabricSpecificDetails.Location -like $primaryRegion -or $_.fabricSpecificDetails.Location -like $primaryRegion.replace(' ', '') }
        $primaryContainer = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $primaryFabric | Where-Object { $_.Name -like "*$primaryRegion*" }
        $primaryContMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $primaryContainer | Where-Object { $_.SourceFabricFriendlyName -like "$primaryRegion" -and $_.TargetFabricFriendlyName -like "$failoverRegion" -and $_.PolicyFriendlyName -like "$replicationPolicy" }

        if ($vm.Zones) {
            $outputJob = New-AzRecoveryServicesAsrReplicationProtectedItem -AzureToAzure `
                -AzureVmId $vm.Id `
                -Name (New-Guid).Guid `
                -ProtectionContainerMapping $primaryContMapping `
                -AzureToAzureDiskReplicationConfiguration $diskAsrConfigs `
                -RecoveryResourceGroupId $failoverRgId `
                -RecoveryAvailabilityZone $vm.Zones[0]
        }
        else {
            $outputJob = New-AzRecoveryServicesAsrReplicationProtectedItem -AzureToAzure `
                -AzureVmId $vm.Id `
                -Name (New-Guid).Guid `
                -ProtectionContainerMapping $primaryContMapping `
                -AzureToAzureDiskReplicationConfiguration $diskAsrConfigs `
                -RecoveryResourceGroupId $failoverRgId
        
        }

        while (($outputJob.State -eq "InProgress") -or ($outputJob.State -eq "NotStarted")) {
            Start-Sleep -Seconds 30
            $outputJob = Get-AzRecoveryServicesAsrJob -Job $outputJob
        }
        Write-Host $outputJob.State
        return $outputJob.State
    }

}
replicateVm -vmName "vm-test" -failoverRG "rg-drTest" -cacheStorageAccount "" -failoverDiskEncryptionSet "" -vault "testVault" -primaryRegion "eastus" -failoverRegion "westus" -replicationPolicy "myReplicationPolicy"