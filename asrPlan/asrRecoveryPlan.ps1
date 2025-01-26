#
$recoveryPlanName = ""
$vmList = @("","")
$primaryRegion = ""
$recoveryRegion = ""
$vaultName = ""
$subscription = ""

#

$tex = """" + ($vmList -join """,""") + """"
$replquery ='
recoveryservicesresources
| where type == "microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems"
| project vm = properties.friendlyName, vault = split(id,"/")[-7], fabric =split(id,"/")[-5], container = split(id,"/")[-3], subscriptionId
| where vm in~ ('+ $tex +')
'
#
$replres = Search-AzGraph -query $replquery -usetenantscope -first 1000
$rpis = @()
$replres | ForEach-Object {
    Set-AzContext -SubscriptionId $_.subscriptionId
    $vault = Get-AzRecoveryServicesVault -Name $_.vault
    Set-AzRecoveryServicesAsrVaultContext -Vault $vault
    $fab = Get-AzRecoveryServicesAsrFabric -Name $_.fabric
    $container = Get-AzRecoveryServicesAsrProtectionContainer -Name $_.container -Fabric $fab
    $item = Get-AzRecoveryServicesAsrReplicationProtectedItem -FriendlyName $_.vm -ProtectionContainer $container
    $rpis += $item
}

Set-AzContext -SubscriptionId $subscription
$vault = Get-AzRecoveryServicesVault -Name $vaultName
Set-AzRecoveryServicesAsrVaultContext -Vault $vault

$primaryFabric = Get-AzRecoveryServicesAsrFabric | where-object { $_.fabricSpecificDetails.Location -like $primaryRegion -or $_.fabricSpecificDetails.Location -like $primaryRegion.replace(' ','')}
$recoveryFabric = Get-AzRecoveryServicesAsrFabric | where-object { $_.fabricSpecificDetails.Location -like $recoveryRegion -or $_.fabricSpecificDetails.Location -like $recoveryRegion.replace(' ','')}

New-AzRecoveryServicesAsrRecoveryPlan -Name $recoveryPlanName -PrimaryFabric $primaryFabric -RecoveryFabric $recoveryFabric -ReplicationProtectedItem $rpis


function createASRRecoveryPlan {
    param (
        [string]$recoveryPlanName,
        [string[]]$vmList,
        [string]$primaryRegion,
        [string]$recoveryRegion,
        [string]$vaultName,
        [string]$subscription
    )
    $ErrorActionPreference = 'Stop'
    $tex = """" + ($vmList -join """,""") + """"
    $replquery ='
recoveryservicesresources
| where type == "microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems"
| project vm = properties.friendlyName, vault = split(id,"/")[-7], fabric =split(id,"/")[-5], container = split(id,"/")[-3], subscriptionId
| where vm in~ ('+ $tex +')
'

    $replres = Search-AzGraph -query $replquery -usetenantscope -first 1000
    $rpis = @()
    $replres | ForEach-Object {
        Set-AzContext -SubscriptionId $_.subscriptionId
        $vault = Get-AzRecoveryServicesVault -Name $_.vault
        Set-AzRecoveryServicesAsrVaultContext -Vault $vault
        $fab = Get-AzRecoveryServicesAsrFabric -Name $_.fabric
        $container = Get-AzRecoveryServicesAsrProtectionContainer -Name $_.container -Fabric $fab
        $item = Get-AzRecoveryServicesAsrReplicationProtectedItem -FriendlyName $_.vm -ProtectionContainer $container
        $rpis += $item
    }

    $ErrorActionPreference = 'Stop'
    Set-AzContext -SubscriptionId $subscription
    $vault = Get-AzRecoveryServicesVault -Name $vaultName
    Set-AzRecoveryServicesAsrVaultContext -Vault $vault

    $primaryFabric = Get-AzRecoveryServicesAsrFabric | where-object { $_.fabricSpecificDetails.Location -like $primaryRegion -or $_.fabricSpecificDetails.Location -like $primaryRegion.replace(' ','')}
    $recoveryFabric = Get-AzRecoveryServicesAsrFabric | where-object { $_.fabricSpecificDetails.Location -like $recoveryRegion -or $_.fabricSpecificDetails.Location -like $recoveryRegion.replace(' ','')}

    $outputJob = New-AzRecoveryServicesAsrRecoveryPlan -Name $recoveryPlanName -PrimaryFabric $primaryFabric -RecoveryFabric $recoveryFabric -ReplicationProtectedItem $rpis
    
    while (($outputJob.State -eq "InProgress") -or ($outputJob.State -eq "NotStarted")){
        Start-Sleep -Seconds 30
        $outputJob = Get-AzRecoveryServicesAsrJob -Job $outputJob
    }
    return $outputJob.StateDescription
}

$jobStateDescription = createASRRecoveryPlan -recoveryPlanName "" -primaryRegion "" -recoveryRegion "" -vaultName "" -subscription "" -vmList @("","")






