#
$vaultName = "testVault"
$vaultRG = "rg-drTest"
$location = "westus3"
New-AzRecoveryServicesVault -Name $vaultName -ResourceGroupName $vaultRG -Location $location -PublicNetworkAccess "Disabled"
$vault = Get-AzRecoveryServicesVault -Name $vaultName 
#Set-AzRecoveryServicesBackupProperty  -Vault $vault -BackupStorageRedundancy LocallyRedundant
#
Set-AzRecoveryServicesAsrVaultContext -Vault $vault
#Set-AzRecoveryServicesVaultContext -Vault $vault
$vaultId = $vault.ID
$vaultSettingsFile = Get-AzRecoveryServicesVaultSettingsFile -Vault $vault -Path "." -SiteRecovery 
$fileLocation = ((Get-ChildItem -Path ./*.VaultCredentials).PSpath -split("::"))[-1]
#
Import-AzRecoveryServicesAsrVaultSettingsFile -Path $fileLocation
#
#Set-AzRecoveryServicesBackupProperty -Vault $vault -BackupStorageRedundancy LocallyRedundant

#
# Replication Policy for Azure VMs
New-AzRecoveryServicesAsrPolicy -AzureToAzure -Name "myReplicationPolicy" -RecoveryPointRetentionInHours 24 -ApplicationConsistentSnapshotFrequencyInHours 1




# get-childItem -Path ./*.VaultCredentials | Sort-Object -Property CreationTime -Descending | Select-Object -First 1
# ((Get-ChildItem -Path ./*.VaultCredentials).pspath -split("::"))[-1]
# ((get-childItem -Path ./*.VaultCredentials | Sort-Object -Property CreationTime -Descending | Select-Object -First 1).pspath -split("::"))[-1]
# Replication Policy for Azure VMs


