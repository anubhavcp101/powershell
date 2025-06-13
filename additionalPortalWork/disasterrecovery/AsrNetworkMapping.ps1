#
$vaultSubscription
$vaultName
$primaryRegion
$secondaryRegion


#
Set-AzContext -Subscription $vaultSubscription
$vault = Get-AzRecoveryServicesVault -Name $vaultName 
Set-AzRecoveryServicesAsrVaultContext -Vault $vault

#
$primaryfabric = Get-AzRecoveryServicesAsrFabric | Where-Object { $_.FriendlyName -like $primaryRegion } # "East US" or "West US 3"
$secondaryfabric = Get-AzRecoveryServicesAsrFabric | Where-Object { $_.FriendlyName -like $secondaryRegion } # "East US" or "West US 3"

#Get-AzRecoveryServicesAsrNetworkMapping -PrimaryFabric $primaryfabric

# $fab = Get-AzRecoveryServicesAsrFabric | Where-Object {$_.FabricSpecificDetails.Location -like "westus"} # another approach w/o standard format for region

$networkMappings = Get-AzRecoveryServicesAsrNetworkMapping -PrimaryFabric $primaryfabric | where PairingStatus -eq "Paired"
$isPrimaryNetworkMappingPresent = $false
$isRecoveryNetworkMappingPresent = $false

$recoveryVnet = ($recoveryVnetId -split "/")[-1]

$vm = Get-AzVM -ResourceId $priamryVmId

if (($vm.NetworkProfile.NetworkInterfaces | Measure-Object).Count -ge 2) {
  Write-Error "Script Not Supported for VMs with Multiple Nics"
  exit
}

$nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
$nic = Get-AzNetworkInterface -ResourceId $nicId

if (($nic.IpConfigurations | Measure-Object).Count -ge 2) {
  Write-Error "Script Not Supported for Nic with Multiple IPConfigs"
  exit
}

$subnetId = $nic.IpConfigurations[0].Subnet.Id
$primaryVnetName = ($subnetId -split "/")[-3]
$vnetPieces = $subnetId -split "/"
$primaryVnetId = $vnetPieces[0 .. ($vnetPieces.Length -3)] -join "/"

foreach ($mapping in $networkMappings) {
  if (($mapping.PrimaryNetworkFriendlyName -eq $primaryVnetName) -and ($mapping.RecoveryNetworkFriendlyName -eq $recoveryVnet) -and ($mapping.FabricSpecificNetworkMappingDetails.PrimaryNetworkLocation -eq $primaryRegion.replace(' ','').tolower()) -and ($mapping.FabricSpecificNetworkMappingDetails.RecoveryNetworkLocation -eq $secondaryRegion.replace(' ','').tolower())) {
    $isPrimaryNetworkMappingPresent = $true

  }

  if (($mapping.PrimaryNetworkFriendlyName -eq $recoveryVnet) -and ($mapping.RecoveryNetworkFriendlyName -eq $primaryVnetName) -and ($mapping.FabricSpecificNetworkMappingDetails.PrimaryNetworkLocation -eq $secondaryRegion.replace(' ','').tolower()) -and ($mapping.FabricSpecificNetworkMappingDetails.RecoveryNetworkLocation -eq $primaryRegion.replace(' ','').tolower())) {
    $isRecoveryNetworkMappingPresent = $true

  }

  if ($isPrimaryNetworkMappingPresent -and $isRecoveryNetworkMappingPresent) {
    break
  }
}

if (-not $isPrimaryNetworkMappingPresent) {
  New-AzRecoveryServicesAsrNetworkMapping -AzureToAzure `
  -PrimaryFabric $primaryfabric `
  -PrimaryAzureNetworkId $primaryVnetId `
  -RecoveryFabric $secondaryfabric `
  -RecoveryAzureNetworkId $recoveryVnetId
}

if (-not $isRecoveryNetworkMappingPresent) {
  New-AzRecoveryServicesAsrNetworkMapping -AzureToAzure `
  -PrimaryFabric $secondaryfabric `
  -PrimaryAzureNetworkId $recoveryVnetId `
  -RecoveryFabric $primaryRegion `
  -RecoveryAzureNetworkId $primaryVnetId
}
