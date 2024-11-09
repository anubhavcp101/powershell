#
$maxJobCount = 11
$vms = Import-Csv -Path "./vms.csv" -Header "Name"
$task = {
    param(
        $vm
    )
    Write-Host "Starting Job for" $vm.Name  

    $vmname = $vm.Name.trim()
    $resId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project id") -UseTenantScope).id; write $resId;
    $subsId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project subscriptionId") -UseTenantScope).subscriptionId; write $subsId;
    Set-AzContext -SubscriptionId $subsId -ErrorAction Stop
    #
    if ($resId) {
        $AzVm = Get-AzVM -ResourceId $resId
        $dcr = Get-AzDataCollectionRule | where Name -Like $vm.dcrName
        if ($dcr) {
            New-AzDataCollectionRuleAssociation -AssociationName ($dcr.Name + "-association") -DataCollectionRuleId $dcr.Id -ResourceUri $AzVm.Id -ErrorAction Stop
            Write-Host Asssociate $AzVm.Name with $dcr.Name
        }
        else {
            Write-Error The DCR $vm.dcrName is not found
        }
    } else {
        Write-Error The VM $vm.Name is not found
    }
    
}
#
$Global:jobs = @()
$Global:jobCounter = 0
$Global:totalJobs = 0
$Global:jobErrors = ""
$Global:errorFile = @()

$Global:totalJobs = ($vms | Measure-Object).Count
$vms | ForEach-Object {
    if ( $jobCounter -lt $maxJobCount) {
        Write-Host Starting Job of $_.Name
        $job = Start-Job -Name $_.Name -ScriptBlock $task -ArgumentList $_
        $Global:jobs += $job
        $Global:jobCounter++
    } 
}

while ($true) {
    $currentlyRunningJobs = $Global:jobs | where State -EQ "Running" | where HasMoreData -EQ $true
    #Write-Host Current Job is #$currentlyRunningJobs
    if ((($currentlyRunningJobs | Measure-Object).Count -lt $maxJobCount) -and (($jobCounter) -lt $Global:totalJobs)) {
        Write-Host Starting Job of $vms[$Global:jobCounter].Name
        $job = Start-Job -Name $vms[$Global:jobCounter].Name -ScriptBlock $task -ArgumentList $vms[$Global:jobCounter]  
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
            $failedJobs = $Global:jobs | where State -EQ "Failed" | where HasMoreData -EQ $true
            if (($failedJobs | Measure-Object).Count -gt 0) {
                Write-Host Following Jobs Failed. Please Check
                Write-Host ($failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
                $failedJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
                $failedJobs | Select-Object Id, Name, State | Export-Csv -Path "./listOfFailedJobs.csv" -NoTypeInformation -Force
                Start-Transcript -Path "./failedJobs.txt" -Force
                $failedJobs | ForEach-Object {
                    ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                    $errorDetails = (Receive-Job -Job $_ -Keep) 
                    Write-Host $errorDetails
                    # code to export a csv file containing failed job name and error details
                    # and this is still pending 
                }
                Write-Host ($failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
                Stop-Transcript
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