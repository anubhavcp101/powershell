#
$maxJobCount = 11
$vms = Import-Csv -Path "./vms.csv" -Header "Name"
$task = {
    param(
        $vm
    )
    Write-Host "Starting Job for" $vm.Name  

    $curSubs = (Get-AzContext).Subscription.Id.ToString()
    if ( $vm.SUBSCRIPTIONID -ne $curSubs) { Set-AzContext -SubscriptionId $vm.SUBSCRIPTIONID -ErrorAction Stop }
    $AzVm = Get-AzVM -ResourceGroupName $vm.RESOURCEGROUP -Name $vm.NAME -ErrorAction Stop 
    $vmSize = $AzVm.HardwareProfile.VmSize
    #
    if ($vm.CURRENTSIZE -eq $vmSize ) {
        $AzVm.HardwareProfile.VmSize = $vm.REQUESTEDSIZE
        Write-Host "Stopping VM: " $AzVm.Name " and its expected size is " ($AzVm.HardwareProfile.VmSize)
        Stop-AzVM -Id $AzVm.Id -Force -ErrorAction Stop
        #
        Write-Host "Updating the VM: " $AzVm.Name " to " ($AzVm.HardwareProfile.VmSize)
        Update-AzVM -ResourceGroupName $AzVm.ResourceGroupName -VM $AzVm -ErrorAction Stop
        Write-Host " Starting the VM: " $vm.Name
        Start-AzVM -Id $vm.Id -NoWait
    }
    else {
        Write-Host The VM $AzVm.Name "size in the csv file and azure portal doesn't match"
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