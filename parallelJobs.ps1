#
$maxJobCount = 11
$task = {
    param(
        $vm
    )
    Write-Host "Starting Job for" $vm.Name  

    Start-Sleep -Seconds 11
    Write-Error "This is an error to be printed"
    Write-Host "Finished Job for" $vm.Name
}
#
$Global:jobs = @()
$Global:jobCounter = 0
$Global:totalJobs = 0

$vms = Import-Csv -Path "./vms.csv" #-Header "Name"
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
    if ((($currentlyRunningJobs|Measure-Object).Count -lt $maxJobCount) -and (($jobCounter) -lt $Global:totalJobs)) {
        Write-Host Starting Job of $vms[$Global:jobCounter].Name
        $job = Start-Job -Name $vms[$Global:jobCounter].Name -ScriptBlock $task -ArgumentList $vms[$Global:jobCounter]
        $Global:jobs += $job
        $Global:jobCounter++
    } elseif (($jobCounter) -eq $Global:totalJobs) {
        Write-Host All Jobs Initiated
        # wait for all jobs to be completed
        $completedJobs = $Global:jobs | where State -EQ "Completed" | where HasMoreData -EQ $true
        if (($completedJobs| Measure-Object).Count -eq $Global:totalJobs) {
            Write-Host All Jobs Completed
            break
        }else {
            Write-Host "Currently Waiting for all jobs to be completed"
            Write-Host Currently Running Jobs are:
            $currentJobs = $Global:jobs | where State -EQ "Running" | where HasMoreData -EQ $true
            $currentJobs | Select-Object Id,Name,State,HasMoreData | Format-Table -AutoSize -RepeatHeader
            Start-Sleep -Seconds 30
        }

    }else {
        $currentJobs = $Global:jobs | where State -EQ "Running" | where HasMoreData -EQ $true
        #Write-Host $currentJobs
        $currentJobs | Select-Object Id,Name,State,HasMoreData | Format-Table -AutoSize -RepeatHeader
        Start-Sleep -Seconds 30
    }
}