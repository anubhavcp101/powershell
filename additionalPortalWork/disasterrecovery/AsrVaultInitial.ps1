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
    $primaryFabric = Get-AzRecoveryServicesAsrFabric -Name "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))"

    $createdContainer = $true
    $TempASRJob = New-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))-container" -InputObject $primaryFabric
    WaitForAsrJob -TempAsrJob $TempASRJob

    $primaryContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))-container" -Fabric $primaryFabric

}

$secondaryFabric = Get-AzRecoveryServicesAsrFabric | Where-Object { $_.FriendlyName -like $secondaryRegion }

if (-not $secondaryFabric) {
    $TempASRJob = New-AzRecoveryServicesAsrFabric -Azure -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))" -Location $secondaryRegion
    WaitForAsrJob -TempAsrJob $TempASRJob
    $secondaryFabric = Get-AzRecoveryServicesAsrFabric -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))"

    $createdContainer = $true
    $TempASRJob = New-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))-container" -InputObject $secondaryFabric
    WaitForAsrJob -TempAsrJob $TempASRJob
    $secondaryContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))-container" -Fabric $secondaryFabric

}

$ReplicationPolicy = Get-AzRecoveryServicesAsrPolicy -Name $replicationPolicy

if (-not $replicationPolicy) {
    $TempASRJob = New-AzRecoveryServicesAsrPolicy -AzureToAzure -Name $replicationPolicy -RecoveryPointRetentionInHours 24 -ApplicationConsistentSnapshotFrequencyInHours 3
    
    WaitForAsrJob -TempAsrJob $TempASRJob
    $ReplicationPolicy = Get-AzRecoveryServicesAsrPolicy -Name $replicationPolicy
}

$primaryContainer = (Get-AzRecoveryServicesAsrProtectionContainer -Fabric $primaryFabric)[0]
if (-not $primaryContainer) {
    $createdContainer = $true
    $TempASRJob = New-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))-container" -InputObject $primaryFabric
    WaitForAsrJob -TempAsrJob $TempASRJob

    $primaryContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))-container" -Fabric $primaryFabric

}

$secondaryContainer = (Get-AzRecoveryServicesAsrProtectionContainer -Fabric $secondaryFabric)[0]
if (-not $secondaryContainer) {
    $createdContainer = $true
    $TempASRJob = New-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))-container" -InputObject $secondaryFabric
    WaitForAsrJob -TempAsrJob $TempASRJob
    $secondaryContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))-container" -Fabric $secondaryFabric

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

function configureAsrVault {
    param (
        $vaultSubscription,
        $vaultName,
        $primaryRegion,
        $secondaryRegion,
        $replicationPolicy = "DR-Policy"
    )
    
    Set-AzContext -Subscription $vaultSubscription
    $vault = Get-AzRecoveryServicesVault -Name $vaultName
    Set-AzRecoveryServicesAsrVaultContext -Vault $vault

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

    $createdContainer = $false
    $primaryFabric = Get-AzRecoveryServicesAsrFabric | Where-Object { $_.FriendlyName -like $primaryRegion }

    if (-not $primaryFabric) {
        Write-Output "Primary Fabric doesn't exist"
        $fabricName = "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))"
        Write-Output "Trying to Create Primary Fabric with Name $($fabricName)"
        try {
            
            $TempASRJob = New-AzRecoveryServicesAsrFabric -Azure -Name $fabricName -Location $primaryRegion
            $fabricReturn = WaitForAsrJob -TempAsrJob $TempASRJob
            Write-Output "Primary Fabric Creation: $($fabricReturn)"
            $primaryFabric = Get-AzRecoveryServicesAsrFabric -Name $fabricName

            if ( -not $primaryFabric) {
                Write-Error "Failed to create Primary Fabric: $($fabricName). Please check Site Recovery Jobs in the Vault"
                return
            }

            $containerName = "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))-container"
            Write-Output "Trying to Create Primary Container in the Primary Fabric: $($containerName)"
            $createdContainer = $true
            $TempASRJob = New-AzRecoveryServicesAsrProtectionContainer -Name $containerName -InputObject $primaryFabric
            $containerReturn = WaitForAsrJob -TempAsrJob $TempASRJob
            Write-Output "Primary Container Creation: $($containerReturn)"

            $primaryContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))-container" -Fabric $primaryFabric

            if ( -not $primaryContainer) {
                Write-Error "Failed to create Primary Container: $($containerName). Please check Site Recovery Jobs in the Vault"
                return
            }
        }
        catch {
            Write-Error "An Error Occurred during Primary Fabric Creation: $($_.Exception.Message)"
        }
    } else {
        Write-Output "Primary Fabric already Exists."
    }

    $secondaryFabric = Get-AzRecoveryServicesAsrFabric | Where-Object { $_.FriendlyName -like $secondaryRegion }

    if (-not $secondaryFabric) {
        Write-Output "Secondary Fabric doesn't exist"
        $fabricName = "asr-a2a-primary-$($secondaryRegion.tolower().replace(' ',''))"
        Write-Output "Trying to Create Secondary Fabric with Name $($fabricName)"
        try {
            
            $TempASRJob = New-AzRecoveryServicesAsrFabric -Azure -Name $fabricName -Location $secondaryRegion
            $fabricReturn = WaitForAsrJob -TempAsrJob $TempASRJob
            Write-Output "Secondary Fabric Creation: $($fabricReturn)"

            $secondaryFabric = Get-AzRecoveryServicesAsrFabric -Name $fabricName

            $containerName = "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))-container"
            Write-Output "Trying to Create Secondary Container in the Secondary Fabric: $($containerName)"
            $createdContainer = $true
            $TempASRJob = New-AzRecoveryServicesAsrProtectionContainer -Name $containerName -InputObject $secondaryFabric
            $containerReturn = WaitForAsrJob -TempAsrJob $TempASRJob
            Write-Output "Secondary Container Creation: $($containerReturn)"
            $secondaryContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name $containerName -Fabric $secondaryFabric

            if ( -not $secondaryContainer) {
                Write-Error "Failed to create Secondary Container: $($containerName). Please check Site Recovery Jobs in the Vault"
                return
            }
        }
        catch {
            Write-Error "An Error Occurred during Secondary Fabric Creation: $($_.Exception.Message)"

        }
    } else {
        Write-Output "Secondary Fabric already exists"
    }

    # Pending Containers and Container Mappings 

    $Policy = Get-AzRecoveryServicesAsrPolicy -Name $replicationPolicy -ErrorAction SilentlyContinue

    if (-not $Policy) {
        Write-Output "Didn't the find Replication Policy. Trying to create a replication policy: $($replicationPolicy)"
        $TempASRJob = New-AzRecoveryServicesAsrPolicy -AzureToAzure -Name $replicationPolicy -RecoveryPointRetentionInHours 24 -ApplicationConsistentSnapshotFrequencyInHours 3
    
        $policyReturn = WaitForAsrJob -TempAsrJob $TempASRJob
        Write-Output "Replication Policy Creation: $($policyReturn)"
        $Policy = Get-AzRecoveryServicesAsrPolicy -Name $replicationPolicy

        if (-not $Policy) {
            Write-Error "An Error Occurred during Policy Creation: $($replicationPolicy). Please check Site Recovery Jobs in the Vault"
            return
        }
    } else {
        Write-Output "Replication Policy already exists"
    }

    $primaryContainer = (Get-AzRecoveryServicesAsrProtectionContainer -Fabric $primaryFabric)[0]
    if (-not $primaryContainer) {
        $createdContainer = $true
        $containerName = "asr-a2a-primary-$($primaryRegion.tolower().replace(' ',''))-container"
        Write-Output "Didn't find Primary Container. Trying to create the primary container with name: $($containerName)"
        $TempASRJob = New-AzRecoveryServicesAsrProtectionContainer -Name $containerName -InputObject $primaryFabric
        $containerReturn = WaitForAsrJob -TempAsrJob $TempASRJob
        Write-Output "Primary Container Creation: $($containerReturn)"

        $primaryContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name $containerName -Fabric $primaryFabric

        if (-not $primaryContainer) {
            Write-Error "An Error Occurred during primary container creation: $($_.Exception.Message). Please check Site Recovery Jobs in the Vault"
            return
        }
    } else {
        Write-Output "Primary Container already exists."
    }

    $secondaryContainer = (Get-AzRecoveryServicesAsrProtectionContainer -Fabric $secondaryFabric)[0]
    if (-not $secondaryContainer) {
        $createdContainer = $true
        $containerName = "asr-a2a-secondary-$($secondaryRegion.tolower().replace(' ',''))-container"
        $TempASRJob = New-AzRecoveryServicesAsrProtectionContainer -Name $containerName -InputObject $secondaryFabric
        $containerReturn = WaitForAsrJob -TempAsrJob $TempASRJob
        Write-Output "Secondary Container Creation: $($containerReturn)"

        $secondaryContainer = Get-AzRecoveryServicesAsrProtectionContainer -Name $containerName -Fabric $secondaryFabric
        if (-not $secondaryContainer) {
            Write-Error "An Error Occurred during secondary container creation: $($_.Exception.Message). Please check Site Recovery Jobs in the Vault"
            return
        }
    } else {
        Write-Output "Secondary Container already exists."
    }

    if ($createdContainer) {

        Write-Output "As created container earlier. So, creating container mappings now"

        $TempASRJob = New-AzRecoveryServicesAsrProtectionContainerMapping -Name "$($primaryRegion.tolower().replace(' ',''))-$($secondaryRegion.tolower().replace(' ',''))-$($replicationPolicy)-mapping" `
            -Policy $Policy -PrimaryProtectionContainer $primaryContainer -RecoveryProtectionContainer $secondaryContainer

        $containerMappingReturn = WaitForAsrJob -TempAsrJob $TempASRJob
        Write-Output "Primary Container Mapping Creation: $($containerMappingReturn)"

        $TempASRJob = New-AzRecoveryServicesAsrProtectionContainerMapping -Name "$($secondaryRegion.tolower().replace(' ',''))-$($primaryRegion.tolower().replace(' ',''))-$($replicationPolicy)-mapping" `
            -Policy $Policy -PrimaryProtectionContainer $secondaryContainer -RecoveryProtectionContainer $primaryContainer

        $containerMappingReturn = WaitForAsrJob -TempAsrJob $TempASRJob
        Write-Output "Secondary Container Mapping Creation: $($containerMappingReturn)"
    }

    $primaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $primaryContainer | where PolicyFriendlyName -eq $replicationPolicy | where SourceFabricFriendlyName -eq $primaryRegion | where TargetFabricFriendlyName -eq $secondaryRegion
    if (-not $primaryContainerMapping) {
        $primaryContainerMappingName = "$($primaryRegion.tolower().replace(' ',''))-$($secondaryRegion.tolower().replace(' ',''))-$($replicationPolicy)-mapping"
        Write-Output "Primary Container Mapping not found. Trying to create primary container mapping: $($primaryContainerMappingName)"
        $TempASRJob = New-AzRecoveryServicesAsrProtectionContainerMapping -Name $primaryContainerMappingName `
            -Policy $Policy -PrimaryProtectionContainer $primaryContainer -RecoveryProtectionContainer $secondaryContainer
    
        $containerMappingReturn = WaitForAsrJob -TempAsrJob $TempASRJob
        Write-Output "Primary Container Mapping: $($containerMappingReturn)"
        $primaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $secondaryContainer | where PolicyFriendlyName -eq $replicationPolicy | where SourceFabricFriendlyName -eq $primaryRegion | where TargetFabricFriendlyName -eq $secondaryRegion

    } else {
        Write-Output "Primary Container Mapping already exists"
    }

    $secondaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $secondaryContainer | where PolicyFriendlyName -eq $replicationPolicy | where SourceFabricFriendlyName -eq $secondaryRegion | where TargetFabricFriendlyName -eq $primaryRegion

    if (-not $secondaryContainerMapping) {
        $secondaryContainerMappingName = "$($secondaryRegion.tolower().replace(' ',''))-$($primaryRegion.tolower().replace(' ',''))-$($replicationPolicy)-mapping"
        Write-Output "Secondary Container Mapping not found. Trying to create secondary container mapping: $($secondaryContainerMappingName)"
        $TempASRJob = New-AzRecoveryServicesAsrProtectionContainerMapping -Name $secondaryContainerMappingName `
            -Policy $Policy -PrimaryProtectionContainer $secondaryContainer -RecoveryProtectionContainer $primaryContainer
    
        $containerMappingReturn = WaitForAsrJob -TempAsrJob $TempASRJob
        Write-Output "Secondary Container Mapping Creation: $($containerMappingReturn)"
        $primaryContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $protContainer | where PolicyFriendlyName -eq $policyName | where SourceFabricFriendlyName -eq $primaryRegion | where TargetFabricFriendlyName -eq $secondaryRegion

    } else {
        Write-Output "Secondary Container Mapping already exists"
    }

}