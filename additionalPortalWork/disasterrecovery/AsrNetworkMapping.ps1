#
$vaultSubscription
$vaultName
$primaryRegion
$secondaryRegion
$priamryVmId
$recoveryVnetId
#
Set-AzContext ($primaryVMId -split "/")[2]
$vm = Get-AzVM -ResourceId $priamryVmId
Set-AzContext -Subscription $vaultSubscription
$vault = Get-AzRecoveryServicesVault -Name $vaultName 
#
Set-AzRecoveryServicesAsrVaultContext -Vault $vault

$primaryfabric = Get-AzRecoveryServicesAsrFabric | Where-Object { $_.FriendlyName -like $primaryRegion } # "East US" or "West US 3"
$secondaryfabric = Get-AzRecoveryServicesAsrFabric | Where-Object { $_.FriendlyName -like $secondaryRegion } # "East US" or "West US 3"

#Get-AzRecoveryServicesAsrNetworkMapping -PrimaryFabric $primaryfabric

# $fab = Get-AzRecoveryServicesAsrFabric | Where-Object {$_.FabricSpecificDetails.Location -like "westus"} # another approach w/o standard format for region

$networkMappings = Get-AzRecoveryServicesAsrNetworkMapping -PrimaryFabric $primaryfabric | where PairingStatus -eq "Paired"
$isPrimaryNetworkMappingPresent = $false
$isRecoveryNetworkMappingPresent = $false

$recoveryVnet = ($recoveryVnetId -split "/")[-1]

# $vm = Get-AzVM -ResourceId $priamryVmId

if (($vm.NetworkProfile.NetworkInterfaces | Measure-Object).Count -ge 2) {
    Write-Error "Script does not Supported for VMs with Multiple Nics"
    exit
}

$nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
$nic = Get-AzNetworkInterface -ResourceId $nicId

if (($nic.IpConfigurations | Measure-Object).Count -ge 2) {
    Write-Error "Script does not Supported for Nic with Multiple IPConfigs"
    exit
}

$subnetId = $nic.IpConfigurations[0].Subnet.Id
$primaryVnetName = ($subnetId -split "/")[-3]
$vnetPieces = $subnetId -split "/"
$primaryVnetId = $vnetPieces[0 .. ($vnetPieces.Length - 3)] -join "/"

foreach ($mapping in $networkMappings) {
    if (($mapping.PrimaryNetworkFriendlyName -eq $primaryVnetName) -and ($mapping.RecoveryNetworkFriendlyName -eq $recoveryVnet) -and ($mapping.FabricSpecificNetworkMappingDetails.PrimaryNetworkLocation -eq $primaryRegion.replace(' ', '').tolower()) -and ($mapping.FabricSpecificNetworkMappingDetails.RecoveryNetworkLocation -eq $secondaryRegion.replace(' ', '').tolower())) {
        $isPrimaryNetworkMappingPresent = $true

    }

    if (($mapping.PrimaryNetworkFriendlyName -eq $recoveryVnet) -and ($mapping.RecoveryNetworkFriendlyName -eq $primaryVnetName) -and ($mapping.FabricSpecificNetworkMappingDetails.PrimaryNetworkLocation -eq $secondaryRegion.replace(' ', '').tolower()) -and ($mapping.FabricSpecificNetworkMappingDetails.RecoveryNetworkLocation -eq $primaryRegion.replace(' ', '').tolower())) {
        $isRecoveryNetworkMappingPresent = $true

    }

    if ($isPrimaryNetworkMappingPresent -and $isRecoveryNetworkMappingPresent) {
        break
    }
}

if (-not $isPrimaryNetworkMappingPresent) {
    New-AzRecoveryServicesAsrNetworkMapping -AzureToAzure `
        -PrimaryFabric $primaryfabric `
        -PrimaryAzureNetworkId $primaryVnetId `
        -RecoveryFabric $secondaryfabric `
        -RecoveryAzureNetworkId $recoveryVnetId
}

if (-not $isRecoveryNetworkMappingPresent) {
    New-AzRecoveryServicesAsrNetworkMapping -AzureToAzure `
        -PrimaryFabric $secondaryfabric `
        -PrimaryAzureNetworkId $recoveryVnetId `
        -RecoveryFabric $primaryRegion `
        -RecoveryAzureNetworkId $primaryVnetId
}

function configureAsrNetworkMapping {
    param (
        $primaryVMId,
        $vaultSubscription,
        $vaultName,
        $primaryRegion,
        $secondaryRegion,
        $recoveryVnetId
    )
    try {
        $ErrorActionPreference = "Stop"
        Set-AzContext -Subscription ($primaryVMId -split "/")[2]
        $vm = Get-AzVM -ResourceId $primaryVMId

        Set-AzContext -Subscription $vaultSubscription
        $vault = Get-AzRecoveryServicesVault -Name $vaultName
        Set-AzRecoveryServicesAsrVaultContext -Vault $vault

        $primaryFabric = Get-AzRecoveryServicesAsrFabric | Where-Object { ($_.FabricSpecificDetails.Location -like $primaryRegion) -or ($_.FabricSpecificDetails.Location -like $primaryRegion.replace(' ', '').tolower()) }
        $secondaryFabric = Get-AzRecoveryServicesAsrFabric | Where-Object { ($_.FabricSpecificDetails.Location -like $secondaryRegion) -or ($_.FabricSpecificDetails.Location -like $secondaryRegion.replace(' ', '').tolower()) }

        $networkMappings = Get-AzRecoveryServicesAsrNetworkMapping -PrimaryFabric $primaryFabric

        $isPrimaryNetworkMappingPresent = $false
        $isRecoveryNetworkMappingPresent = $false

        $recoveryVnet = ($recoveryVnetId -split "/")[-1]

        if (($vm.NetworkProfile.NetworkInterfaces | Measure-Object).Count -ge 2) {
            Write-Error "Script does not Support for VMs with Multiple Nics"
            return
        }

        $nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
        $nic = Get-AzNetworkInterface -ResourceId $nicId

        if (($nic.IpConfigurations | Measure-Object).Count -ge 2) {
            Write-Error "Script does not Support for Nic with Multiple IPConfigs"
            return
        }

        $subnetId = $nic.IpConfigurations[0].Subnet.Id
        $primaryVnetName = ($subnetId -split "/")[-3]
        $vnetPieces = $subnetId -split "/"
        $primaryVnetId = $vnetPieces[0 .. ($vnetPieces.Length - 3)] -join "/"


        foreach ($mapping in $networkMappings) {
        
            if (($mapping.PrimaryNetworkFriendlyName -eq $primaryVnetName) -and ($mapping.RecoveryNetworkFriendlyName -eq $recoveryVnet) -and ($mapping.FabricSpecificNetworkMappingDetails.PrimaryNetworkLocation -eq $primaryRegion.replace(' ', '').tolower()) -and ($mapping.FabricSpecificNetworkMappingDetails.RecoveryNetworkLocation -eq $secondaryRegion.replace(' ', '').tolower())) {
                $isPrimaryNetworkMappingPresent = $true

            }

            if (($mapping.PrimaryNetworkFriendlyName -eq $recoveryVnet) -and ($mapping.RecoveryNetworkFriendlyName -eq $primaryVnetName) -and ($mapping.FabricSpecificNetworkMappingDetails.PrimaryNetworkLocation -eq $secondaryRegion.replace(' ', '').tolower()) -and ($mapping.FabricSpecificNetworkMappingDetails.RecoveryNetworkLocation -eq $primaryRegion.replace(' ', '').tolower())) {
                $isRecoveryNetworkMappingPresent = $true

            }

            if ($isPrimaryNetworkMappingPresent -and $isRecoveryNetworkMappingPresent) {
                break
            }

        }

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

        $primaryReturn = $isPrimaryNetworkMappingPresent
        $secondaryReturn = $isRecoveryNetworkMappingPresent

        if (-not $isPrimaryNetworkMappingPresent) {
            $TempASRJob = New-AzRecoveryServicesAsrNetworkMapping -AzureToAzure `
                -PrimaryFabric $primaryfabric `
                -PrimaryAzureNetworkId $primaryVnetId `
                -RecoveryFabric $secondaryfabric `
                -RecoveryAzureNetworkId $recoveryVnetId
        
            $primaryReturn = WaitForAsrJob -TempAsrJob $TempASRJob
        }

        if (-not $isRecoveryNetworkMappingPresent) {
            $TempASRJob = New-AzRecoveryServicesAsrNetworkMapping -AzureToAzure `
                -PrimaryFabric $secondaryfabric `
                -PrimaryAzureNetworkId $recoveryVnetId `
                -RecoveryFabric $primaryRegion `
                -RecoveryAzureNetworkId $primaryVnetId

            $secondaryReturn = WaitForAsrJob -TempAsrJob $TempASRJob
        }
    
        return "PrimaryNetworkMapping:$($primaryReturn);SecondaryNetworkMapping:$($secondaryReturn)"

    }
    catch {
        throw "An Error Occurred: $($_.Exception.Message)"
    }
}
$filePath = "./vms.csv"
Set-Location $PSScriptRoot
$vms = Import-Csv -Path $filePath
"VM,Output" | Out-File -FilePath "./output.csv" -Append -Force
foreach ($vm in $vms) {
    $out = configureAsrNetworkMapping `
        -primaryVMId $vm.primaryVMId.trim() `
        -vaultSubscription $vm.vaultSubscription.trim() `
        -vaultName $vm.vaultName.trim() `
        -primaryRegion $vm.primaryRegion.trim() `
        -secondaryRegion $vm.secondaryRegion.trim() `
        -recoveryVnetId $vm.recoveryVnetId.trim()
    "$(($primaryVMId -split "/")[-1]),$($out)" | Out-File -FilePath "./output.csv" -Append -Force
}

# Start-Process powershell -ArgumentList "-NoExit", "Get-Content './output.csv' -Wait"
