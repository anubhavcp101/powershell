#
$name = "" # Name of the Azure VM
$subscription = "" # subscription where vault resides
$vault = "" # name of the vault
$vaultRG = "" # resource group of the vault
$Policy = "" # name of the backup policy
$ctx = Set-AzContext -Subscription $subscription -Scope Process
#
$azVault = Get-AzRecoveryServicesVault -Name $vault -ResourceGroupName $vaultRG -DefaultProfile $ctx
$bkpPolicy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $Policy -VaultId $azVault.ID -DefaultProfile $ctx
$bkpItem = Get-AzRecoveryServicesBackupItem -WorkloadType AzureVM -BackupManagementType AzureVM -Name $Name -VaultId $azVault.ID -DefaultProfile $ctx
Enable-AzRecoveryServicesBackupProtection -Item $bkpItem -Policy $bkpPolicy -VaultId $azVault.ID -DefaultProfile $ctx