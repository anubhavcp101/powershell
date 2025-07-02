#
$filepath = "./vms.csv"
function ConfigureAsr {
  param (
    [Parameter(Mandatory=$true)]
    $primaryVmId,

    #
    [Parameter(Mandatory=$true)]
    $vaultSubscription,
    [Parameter(Mandatory=$true)]
    $vaultName,
    #
    
    [Parameter(Mandatory=$true)]
    $policyName,

    [Parameter(Mandatory=$true)]
    [ValidateSet("West US","West US 3","East US")]
    $primaryRegion,

    [Parameter(Mandatory=$true)]
    [ValidateSet("West US","West US 3","East US")]
    $recoveryRegion,

    [Parameter(Mandatory=$true)]
    $recoveryRGId,

   
    [Parameter(Mandatory=$true)]
    $cacheStorageAccountId,

    [Parameter(Mandatory=$true)]
    $recoveryDiskEncryptionSetId,

    [Parameter(Mandatory=$true)]
    $failoverVnetId,

    [Parameter(Mandatory=$true)]
    $failoverSubnetName
  )

    $primaryLocation = $primaryRegion
 
  try {
    $ErrorActionPreference = "Stop"  
    
    $primaryRegion = (Get-AzLocation | where Location -like $primaryRegion.tolower().replace(' ','')).DisplayName
    $secondaryRegion = (Get-AzLocation | where Location -like $secondaryRegion.tolower().replace(' ','')).DisplayName

    Set-AzContext -Subscription ($primaryVmId -split "/")[2]
    $vm = Get-AzVM -ResourceId $primaryVmId

    Set-AzContext -Subscription $vaultSubscription
    $vault = Get-AzRecoveryServicesVault -Name $vaultName 
    Set-AzRecoveryServicesAsrVaultContext -Vault $vault
    $fab = Get-AzRecoveryServicesAsrFabric | Where-Object { $_.FriendlyName -like $primaryLocation }
    # $protContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name $container -Fabric $fab

    $containers = (Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fab | Where-Object { (($_.FabricFriendlyName -like $primaryLocation) -and ($_.AvailablePolicies.FriendlyName -contains $policyName)) })
    $foundContainer = $false
    $rightContainer = $null
    $foundPrimaryToRecoveryMapping = $false
    $foundRecoveryToPrimaryMapping = $false

    foreach ($container in $containers) {
      foreach ($mapping in $container.ProtectionContainerMappings) {
        if (($mapping.SourceFabricFriendlyName -like $primaryLocation) -and ($mapping.TargetFabricFriendlyName -like $recoveryRegion)) {
          $foundPrimaryToRecoveryMapping = $true
        }
        elseif (($mapping.SourceFabricFriendlyName -like $recoveryRegion) -and ($mapping.TargetFabricFriendlyName -like $primaryLocation)) {
          $foundRecoveryToPrimaryMapping = $true
        }
      } 
      if ($foundPrimaryToRecoveryMapping -and $foundRecoveryToPrimaryMapping) {
        $foundContainer = $true
        $rightContainer = $container
        break 
      } 
    }

    if (-not $foundContainer) {
      Write-Error "Didn't find any container with right mappings"
      return 
    }
    $protContainer = $rightContainer

    $primaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $protContainer | where PolicyFriendlyName -eq $policyName | where SourceFabricFriendlyName -eq $primaryLocation | where TargetFabricFriendlyName -eq $recoveryRegion

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
        -LogStorageAccountId $cacheStorageAccountId -DiskId $datadisk.ManagedDisk.Id -RecoveryResourceGroupId $recoveryRGId -RecoveryReplicaDiskAccountType $replicaDiskAccountType `
        -RecoveryTargetDiskAccountType $datadisk.ManagedDisk.StorageAccountType `
        -RecoveryDiskEncryptionSetId $recoveryDiskEncryptionSetId

      $diskConfigs += $datadiskConfig
    }

    $diskConfigs += $osDiskConfig

    Write-Output "Trying to Initiate Replication for the vm: $(($primaryVmId -split "/")[-1]))"
    if ($vm.Zones) {
      $TempASRJob = New-AzRecoveryServicesAsrReplicationProtectedItem -AzureToAzure `
        -AzureVmId $vm.Id -AzureToAzureDiskReplicationConfiguration $diskConfigs `
        -ProtectionContainerMapping $primaryContainerMapping `
        -Name (New-Guid).Guid `
        -RecoveryResourceGroupId $recoveryRGId `
        -RecoveryAzureNetworkId $failoverVnetId `
        -RecoveryAzureSubnetName $failoverSubnetName `
        -RecoveryAvailabilityZone $vm.Zones[0]
    }
    else {
      $TempASRJob = New-AzRecoveryServicesAsrReplicationProtectedItem -AzureToAzure `
        -AzureVmId $vm.Id -AzureToAzureDiskReplicationConfiguration $diskConfigs `
        -ProtectionContainerMapping $primaryContainerMapping `
        -Name (New-Guid).Guid `
        -RecoveryResourceGroupId $recoveryRGId `
        -RecoveryAzureNetworkId $failoverVnetId `
        -RecoveryAzureSubnetName $failoverSubnetName
    }

    while (($TempASRJob.State -eq "InProgress") -or ($TempASRJob.State -eq "NotStarted")) {
      Start-Sleep -Seconds 20
      $TempASRJob = Get-AzRecoveryServicesAsrJob -Job $TempASRJob
      Write-Output "Replication Job Status: $($TempASRJob.StateDescription)"
    }

    Write-Output "Replication Job Status: $($TempASRJob.State)"
    return $TempASRJob.StateDescription
  }
  catch {
    throw "An Error Occurred $($_.Exception.Message)"
  }

}


Set-Location $PSScriptRoot
$vms = Import-Csv -Path $filepath

foreach ($vm in $vms) {
  ConfigureAsr -primaryVmId $vm.primaryVmId.trim() `
  -vaultSubscription $vm.vaultSubscription.trim() `
  -vaultName $vm.vaultName.trim() `
  -policyName $vm.policyName.trim() `
  -primaryRegion $vm.primaryRegion.trim() `
  -recoveryRegion $vm.recoveryRegion.trim() `
  -recoveryRGId $vm.recoveryRGId.trim() `
  -cacheStorageAccountId $vm.cacheStorageAccountId.trim() `
  -recoveryDiskEncryptionSetId $vm.recoveryDiskEncryptionSetId.trim() `
  -failoverVnetId $vm.failoverVnetId.trim() `
  -failoverSubnetName $vm.failoverSubnetName.trim()
}
