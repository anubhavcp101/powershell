#
$name = "" # Name of the Azure VM
$resourceGroup = "" # Resource group of the Azure VM
$subscription = "" # subscription where vault resides
$vault = "" # name of the vault
$vaultRG = "" # resource group of the vault
$Policy = "" # name of the backup policy
#
$ctx = Set-AzContext -Subscription $subscription -Scope Process
Get-AzRecoveryServicesVault -Name $vault -ResourceGroupName $vaultRG -DefaultProfile $ctx | Set-AzRecoveryServicesVaultContext -DefaultProfile $ctx
$bkpPolicy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $Policy -DefaultProfile $ctx
Enable-AzRecoveryServicesBackupProtection -ResourceGroupName $resourceGroup -Name $name -Policy $bkpPolicy -DefaultProfile $ctx
#