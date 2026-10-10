#
$name = "" # Name of the Azure VM
$subscription = "" # subscription where vault resides
$vault = "" # name of the vault
$vaultRG = "" # resource group of the vault

$ctx = Set-AzContext -Subscription $subscription -Scope Process
#
$azVault = Get-AzRecoveryServicesVault -Name $vault -ResourceGroupName $vaultRG -DefaultProfile $ctx
$bkpItem = Get-AzRecoveryServicesBackupItem -WorkloadType AzureVM -BackupManagementType AzureVM -Name $Name -VaultId $azVault.ID -DefaultProfile $ctx
Disable-AzRecoveryServicesBackupProtection -Item $bkpItem -Force -VaultId $azVault.ID -DefaultProfile $ctx -ErrorAction Stop