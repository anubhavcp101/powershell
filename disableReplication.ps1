#
$replquery ='
recoveryservicesresources
| where type == "microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems"
| project vm = properties.friendlyName, vault = split(id,"/")[-7], fabric =split(id,"/")[-5], container = split(id,"/")[-3], id
| where vm in~ ("wab-flepw01","AZR-LCWEBPW01","AZW-NEXAPPL04","WAB-WLAPW01","WAB-WEBPW06")
'
$replres = Search-AzGraph -query $replquery -usetenantscope -first 1000
#
$replres | ForEach-Object {
  $vault = Get-AzRecoveryServicesVault -Name $_.vault
  Set-AzRecoveryServicesAsrVaultContext -Vault $vault
  $fab = Get-AzRecoveryServicesAsrFabric -Name $_.fabric
  #
  $container = Get-AzRecoveryServicesAsrProtectionContainer -Name $_.container -Fabric $fab
  $item = Get-AzRecoveryServicesAsrReplicationProtectedItem -FriendlyName $_.vm -ProtectionContainer $container
  $job = Remove-AzRecoveryServicesAsrReplicationProtectedItem -InputObject $item -Force
  Write-Output $job
}# azcontext should be dr subscription
<#
'
recoveryservicesresources
| where type == "microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems"
| project vm = properties.friendlyName, vault = split(id,"/")[-7], fabric =split(id,"/")[-5], container = split(id,"/")[-3], subscriptionId
'
#>
