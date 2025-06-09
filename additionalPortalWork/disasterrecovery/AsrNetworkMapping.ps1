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
# $secondaryfabric = Get-AzRecoveryServicesAsrFabric | Where-Object { $_.FriendlyName -like $secondaryRegion } # "East US" or "West US 3"

Get-AzRecoveryServicesAsrNetworkMapping -PrimaryFabric $primaryfabric
