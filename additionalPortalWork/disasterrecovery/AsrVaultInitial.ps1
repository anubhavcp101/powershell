#
$vaultSubscription = ""
$vaultName = ""
$replicationPolicy = ""
$primaryRegion = "" # "East US 3" or "West US 2"
$secondaryRegion = "" # "East US 3" or "West US 2"

#
function WaitForAsrJob {
    param (
        $TempAsrJob
    )
    #
    $TempASRJob = Get-AzRecoveryServicesAsrJob -Job $TempAsrJob
    while (($TempASRJob.State -eq "InProgress") -or ($TempASRJob.State -eq "NotStarted")) {
        Start-Sleep -Seconds 20
        $TempASRJob = Get-AzRecoveryServicesAsrJob -Job $TempASRJob
    }
    return $TempASRJob.StateDescription
}
Set-AzContext -Subscription $vaultSubscription
$vault = Get-AzRecoveryServicesVault -Name $vaultName 
Set-AzRecoveryServicesAsrVaultContext -Vault $vault

$createdContainer = $false
$primaryFabric = Get-AzRecoveryServicesAsrFabric | Where-Object { $_.FriendlyName -like $primaryRegion }

if (-not $primaryFabric) {
    $TempASRJob = New-AzRecoveryServicesAsrFabric -Azure -Name "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))" -Location $primaryRegion
    WaitForAsrJob -TempAsrJob $TempASRJob
    $primaryfab = Get-AzRecoveryServicesAsrFabric -Name "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))"

    $createdContainer = $true
    $TempASRJob = New-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))-container" -InputObject $primaryfab
    WaitForAsrJob -TempAsrJob $TempASRJob

    $primaryContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))-container" -Fabric $primaryfab

}

$secondaryFabric = Get-AzRecoveryServicesAsrFabric | Where-Object { $_.FriendlyName -like $secondaryRegion }

if (-not $secondaryFabric) {
    $TempASRJob = New-AzRecoveryServicesAsrFabric -Azure -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))" -Location $secondaryRegion
    WaitForAsrJob -TempAsrJob $TempASRJob
    $secondaryfab = Get-AzRecoveryServicesAsrFabric -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))"

    $createdContainer = $true
    $TempASRJob = New-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))-container" -InputObject $secondaryfab
    WaitForAsrJob -TempAsrJob $TempASRJob
    $secondaryContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))-container" -Fabric $secondaryfab

}

$ReplicationPolicy = Get-AzRecoveryServicesAsrPolicy -Name $replicationPolicy

if (-not $replicationPolicy) {
    $TempASRJob = New-AzRecoveryServicesAsrPolicy -AzureToAzure -Name $replicationPolicy -RecoveryPointRetentionInHours 24 -ApplicationConsistentSnapshotFrequencyInHours 3
    
    WaitForAsrJob -TempAsrJob $TempASRJob
    $ReplicationPolicy = Get-AzRecoveryServicesAsrPolicy -Name $replicationPolicy
}

$primaryContainer = (Get-AzRecoveryServicesAsrProtectionContainer -Fabric $primaryfab)[0]
if (-not $primaryContainer) {
    $createdContainer = $true
    $TempASRJob = New-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))-container" -InputObject $primaryfab
    WaitForAsrJob -TempAsrJob $TempASRJob

    $primaryContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))-container" -Fabric $primaryfab

}

$secondaryContainer = (Get-AzRecoveryServicesAsrProtectionContainer -Fabric $secondaryfab)[0]
if (-not $secondaryContainer) {
    $createdContainer = $true
    $TempASRJob = New-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))-container" -InputObject $secondaryfab
    WaitForAsrJob -TempAsrJob $TempASRJob
    $secondaryContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))-container" -Fabric $secondaryfab

}

if ($createdContainer) {

    $TempASRJob = New-AzRecoveryServicesAsrProtectionContainerMapping -Name "$($primaryRegion.tolower().replace(' ',''))-$($secondaryRegion.tolower().replace(' ',''))-mapping" `
        -Policy $replicationPolicy -PrimaryProtectionContainer $primaryContainer -RecoveryProtectionContainer $secondaryContainer

    WaitForAsrJob -TempAsrJob $TempASRJob

    $TempASRJob = New-AzRecoveryServicesAsrProtectionContainerMapping -Name "$($secondaryRegion.tolower().replace(' ',''))-$($primaryRegion.tolower().replace(' ',''))-mapping" `
        -Policy $replicationPolicy -PrimaryProtectionContainer $secondaryContainer -RecoveryProtectionContainer $primaryContainer

    WaitForAsrJob -TempAsrJob $TempASRJob
}


$primaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $protContainer | where PolicyFriendlyName -eq $policyName | where SourceFabricFriendlyName -eq $primaryRegion | where TargetFabricFriendlyName -eq $secondaryRegion
if (-not $primaryContainerMapping) {
    $TempASRJob = New-AzRecoveryServicesAsrProtectionContainerMapping -Name "$($primaryRegion.tolower().replace(' ',''))-$($secondaryRegion.tolower().replace(' ',''))-mapping" `
        -Policy $replicationPolicy -PrimaryProtectionContainer $primaryContainer -RecoveryProtectionContainer $secondaryContainer
    
    WaitForAsrJob -TempAsrJob $TempASRJob
    $primaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $protContainer | where PolicyFriendlyName -eq $policyName | where SourceFabricFriendlyName -eq $primaryRegion | where TargetFabricFriendlyName -eq $secondaryRegion

}

$secondaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $protContainer | where PolicyFriendlyName -eq $replicationPolicy | where SourceFabricFriendlyName -eq $secondaryRegion | where TargetFabricFriendlyName -eq $primaryRegion

if (-not $secondaryContainerMapping) {
    $TempASRJob = New-AzRecoveryServicesAsrProtectionContainerMapping -Name "$($secondaryRegion.tolower().replace(' ',''))-$($primaryRegion.tolower().replace(' ',''))-mapping" `
        -Policy $replicationPolicy -PrimaryProtectionContainer $secondaryContainer -RecoveryProtectionContainer $primaryContainer
    
    WaitForAsrJob -TempAsrJob $TempASRJob
    $primaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $protContainer | where PolicyFriendlyName -eq $policyName | where SourceFabricFriendlyName -eq $primaryRegion | where TargetFabricFriendlyName -eq $secondaryRegion

}

# Create Network Mapping 