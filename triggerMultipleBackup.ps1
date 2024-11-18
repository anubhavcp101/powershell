#
$vmList = @("vmA","vmB")
$tex = """" + ($vmList -join """,""") + """"
$vaultquery = 'recoveryservicesresources
| where type == "microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers/protecteditems"
| where properties.dataSourceId in~ (' + $tex + ')
| project VM=split(properties.sourceResourceId,"/")[-1],vaultId = properties.vaultId,subscriptionId,vault=split(properties.vaultId,"/")[-1],vaultrg = split(properties.vaultId,"/")[-5]'
#
$queryres = Search-AzGraph -Query $vaultquery -usetenantscope
$queryres | ForEach-Object {
  $subscriptionID = (Get-AzContext).Subscription.Id.ToString()
  if ($subscriptionID -eq $_.subscriptionId.ToString()) {
    #
  } else {
    #
    Set-AzContext -Subscription $_.subscriptionId.ToString()
    #to do
  }
  Write-Host Host : $_.VM and Subscription : $subscriptionID
  $BackupContainer = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName $_.VM.ToString() -VaultId $_.vaultId.ToString()
  $Item = Get-AzRecoveryServicesBackupItem -Container $BackupContainer -WorkloadType AzureVM -VaultId $_.vaultId.ToString()
  $outp = Backup-AzRecoveryServicesBackupItem -Item $Item -VaultId $_.vaultId.ToString() -ExpiryDateTimeUTC ((Get-Date).ToUniversalTime().AddDays(14))
  Write-Host $outp
}
