#
$maxJobCount = 11
$filePath = "./vms.csv"
$task = {
    param(
        $vm,
        $wrkdir)
    #
    Write-Host "Starting Job for" $vm.Name 
    Set-Location $wrkdir 
    try {
        $ErrorActionPreference = "Stop"
        function createASRRecoveryPlan {
            param (
                [string]$recoveryPlanName,
                [string[]]$vmList,
                [string]$primaryRegion = "",
                [string]$recoveryRegion = "",
                [string]$vaultName,
                [string]$subscription
            )
        
            $ErrorActionPreference = 'Stop'

            $tex = """" + ($vmList -join """,""") + """"
            $replquery = '
    recoveryservicesresources
    | where type == "microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems"
    | project vm = properties.friendlyName, vault = split(id,"/")[-7], fabric =split(id,"/")[-5], container = split(id,"/")[-3], subscriptionId
    | where vm in~ ('+ $tex + ')
    '
    
            $replres = Search-AzGraph -Query $replquery -UseTenantScope -First 1000
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
    
            # $ErrorActionPreference = 'Stop'
            Set-AzContext -SubscriptionId $subscription
            $vault = Get-AzRecoveryServicesVault -Name $vaultName
            Set-AzRecoveryServicesAsrVaultContext -Vault $vault
    
            $primaryFabric = Get-AzRecoveryServicesAsrFabric | where-object { $_.fabricSpecificDetails.Location -like $primaryRegion -or $_.fabricSpecificDetails.Location -like $primaryRegion.tolower().replace(' ', '') }
            $recoveryFabric = Get-AzRecoveryServicesAsrFabric | where-object { $_.fabricSpecificDetails.Location -like $recoveryRegion -or $_.fabricSpecificDetails.Location -like $recoveryRegion.tolower().replace(' ', '') }
    
            $outputJob = New-AzRecoveryServicesAsrRecoveryPlan -Name $recoveryPlanName -PrimaryFabric $primaryFabric -RecoveryFabric $recoveryFabric -ReplicationProtectedItem $rpis
        
            while (($outputJob.State -eq "InProgress") -or ($outputJob.State -eq "NotStarted")) {
                Start-Sleep -Seconds 30
                $outputJob = Get-AzRecoveryServicesAsrJob -Job $outputJob
            }
            return $outputJob.StateDescription
        }
    
        $jobStateDescription = createASRRecoveryPlan -recoveryPlanName $vm.Name.trim()  -vaultName $vm.vault.trim() -subscription $vm.subscription.trim() -vmList ($vm.vmList.trim() -split ",")
    }
    catch {
        throw "An Error Occurred: $($_.Exception.Message)"
    }

    Write-Host "Finished Job for" $vm.Name
}
#
$Global:jobs = @()
$Global:jobCounter = 0
$Global:totalJobs = 0
$Global:jobErrors = ""
$Global:errorFile = @()
Set-Location $PSScriptRoot
$wrkdir = $PSScriptRoot
$vms = Import-Csv -Path $filePath


$Global:totalJobs = ($vms | Measure-Object).Count
$vms | ForEach-Object {
    if ( $jobCounter -lt $maxJobCount) {
        Write-Host Starting Job of $_.Name
        $job = Start-Job -Name $_.Name -ScriptBlock $task -ArgumentList $_, $wrkdir
        $Global:jobs += $job
        $Global:jobCounter++
    } 
}

while ($true) {
    $currentlyRunningJobs = $Global:jobs | where State -EQ "Running" | where HasMoreData -EQ $true
    #Write-Host Current Job is #$currentlyRunningJobs
    if ((($currentlyRunningJobs | Measure-Object).Count -lt $maxJobCount) -and (($jobCounter) -lt $Global:totalJobs)) {
        Write-Host Starting Job of $vms[$Global:jobCounter].Name
        $job = Start-Job -Name $vms[$Global:jobCounter].Name -ScriptBlock $task -ArgumentList $vms[$Global:jobCounter], $wrkdir 
        $Global:jobs += $job
        $Global:jobCounter++
    }
    elseif (($jobCounter) -eq $Global:totalJobs) {
        Write-Host All Jobs Initiated
        # wait for all jobs to be completed
        $currentJobs = $Global:jobs | where State -EQ "Running" | where HasMoreData -EQ $true
        if (($currentJobs | Measure-Object).Count -gt 0) {
            Write-Host "Currently Waiting for all jobs to be finished"
            Write-Host Currently Running Jobs are:
            $currentJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
            Start-Sleep -Seconds 30
        }
        else {
            Start-Transcript -Path "./allJobs.txt" -Force
            $Global:jobs | ForEach-Object {
                    ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                $jobDetails = (Receive-Job -Job $_ -Keep) 
                Write-Host $jobDetails
            }
            Stop-Transcript
            $failedJobs = $Global:jobs | where State -EQ "Failed" | where HasMoreData -EQ $true
            if (($failedJobs | Measure-Object).Count -gt 0) {
                Write-Host Following Jobs Failed. Please Check
                Write-Host ($failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
                $failedJobs | Select-Object Id, Name, State | Format-Table -AutoSize -RepeatHeader
                $failedJobs | Select-Object Id, Name, State | Export-Csv -Path "./listOfFailedJobs.csv" -NoTypeInformation -Force
                # Start-Transcript -Path "./failedJobs.txt" -Force
                "jobName,Error" | Out-File -FilePath "./failedJobError.csv" -Force
                $failedJobs | ForEach-Object {
                    ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                    # $errorDetails = (Receive-Job -Job $_ -Keep) 
                    $errorDetails = $_.ChildJobs.JobStateInfo.Reason -join ";"
                    Write-Host $errorDetails
                    $_.Name + "," + $errorDetails | Out-File -FilePath "./failedJobError.csv" -Append -Force 
                }
                Write-Host ($failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
                # Stop-Transcript
            }
            Write-Host All Jobs Finished
            Write-Host ($failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
            break
        }

    }
    else {
        $currentJobs = $Global:jobs | where State -EQ "Running" | where HasMoreData -EQ $true
        #Write-Host $currentJobs 
        $currentJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
        Start-Sleep -Seconds 30
    }
}