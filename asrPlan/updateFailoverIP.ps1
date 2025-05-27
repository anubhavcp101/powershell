#
param (
  $vm,
  $failoverSubnetName,
  $failoverIP
)
$vmname = $vm.trim()
#

$vmList = @($vmname)
$tex = """" + ($vmList -join """,""") + """"

#
$replquery = '
recoveryservicesresources
| where type == "microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems"
| project vm = properties.friendlyName, vault = split(id,"/")[-7], fabric =split(id,"/")[-5], container = split(id,"/")[-3], subscriptionId
| where vm in~ ('+ $tex + ')
'
#
$replres = Search-AzGraph -query $replquery -usetenantscope -first 1000
#
Set-AzContext -SubscriptionId $replres.subscriptionId
$vault = Get-AzRecoveryServicesVault -Name $replres.vault
Set-AzRecoveryServicesAsrVaultContext -Vault $vault
$fab = Get-AzRecoveryServicesAsrFabric -Name $replres.fabric
$container = Get-AzRecoveryServicesAsrProtectionContainer -Name $replres.container -Fabric $fab 
$item = Get-AzRecoveryServicesAsrReplicationProtectedItem -FriendlyName $replres.vm -ProtectionContainer $container 

# Getting old Nic Config
$oldNicConfig = $item.NicDetails[0]

# Creating new Nic IP Config

$newNicIPConfig = New-AzRecoveryServicesAsrVMNicIPConfig -IpConfigName $oldNicConfig.IpConfigs[0].Name -RecoverySubnetName $failoverSubnetName -RecoveryStaticIPAddress $failoverIP

# creating new Nic Config

$newNicConfig = New-AzRecoveryServicesAsrVMNicConfig -NicId $oldNicConfig.NicId -IPConfig @($newNicIPConfig) -ReplicationProtectedItem $item -RecoveryVMNetworkId $oldNicConfig.RecoveryVMNetworkId -TfoVMNetworkId $oldNicConfig.RecoveryVMNetworkId

# Setting new nic details to replicated item

Set-AzRecoveryServicesAsrReplicationProtectedItem -InputObject $item -ASRVMNicConfiguration @($newNicConfig)
