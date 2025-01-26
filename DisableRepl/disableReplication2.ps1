#
$vmList = @("vmA","vmB")
$tex = """" + ($vmList -join """,""") + """"
$replquery ='
recoveryservicesresources
| where type == "microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems"
| project vm = properties.friendlyName, vault = split(id,"/")[-7], fabric =split(id,"/")[-5], container = split(id,"/")[-3], subscriptionId
| where vm in~ ('+ $tex +')
'
#
$replres = Search-AzGraph -query $replquery -usetenantscope -first 1000
$replres | ForEach-Object {
  Set-AzContext -SubscriptionId $_.subscriptionId
  $vault = Get-AzRecoveryServicesVault -Name $_.vault
  #
  Set-AzRecoveryServicesAsrVaultContext -Vault $vault
  $fab = Get-AzRecoveryServicesAsrFabric -Name $_.fabric
  $container = Get-AzRecoveryServicesAsrProtectionContainer -Name $_.container -Fabric $fab
  $item = Get-AzRecoveryServicesAsrReplicationProtectedItem -FriendlyName $_.vm -ProtectionContainer $container
  $outputJob = Remove-AzRecoveryServicesAsrReplicationProtectedItem -InputObject $item -Force

  while (($outputJob.State -eq "InProgress") -or ($outputJob.State -eq "NotStarted")){
    Start-Sleep -Seconds 30
    $outputJob = Get-AzRecoveryServicesAsrJob -Job $outputJob
}

  Write-Output $outputJob.StateDescription
}# azcontext should be dr subscription
<#
'
recoveryservicesresources
| where type == "microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems"
| project vm = properties.friendlyName, vault = split(id,"/")[-7], fabric =split(id,"/")[-5], container = split(id,"/")[-3], subscriptionId
'
#>
