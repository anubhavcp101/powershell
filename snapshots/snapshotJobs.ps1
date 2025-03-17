#
$maxJobCount = 11
$vms = Import-Csv -Path "./vms.csv" -ErrorAction Stop #-Header "Name"
$task = {
    param(
        $disk,
        $wrkdir)
        #
    Write-Host "Starting Job for $($disk.diskName)"
    Set-Location $wrkdir 
    # the csv file should have diskName, diskRG, diskSubscription and then snapshotName, snapshotRG, snapshotSubscription and snapshotLocation
    Set-AzContext -Subscription $disk.diskSubscription -ErrorAction Stop
    #
    $ErrorActionPreference = 'Stop'
    $filePath = ".\snapshots.csv"
    $azDisk = Get-AzDisk -DiskName $disk.diskName -ResourceGroupName $disk.diskRG
    $snapshotConfig = New-AzSnapshotConfig -SkuName 'Standard_LRS' -Location $disk.snapshotLocation -CreateOption Copy -SourceUri $azDisk.Id
    Set-AzContext -Subscription $disk.snapshotSubscription
    if ($disk.snapshotName) {
        try {
            New-AzSnapshot -SnapshotName $disk.snapshotName -ResourceGroupName $disk.snapshotRG -Snapshot $snapshotConfig
            "$($disk.snapshotName),$($disk.snapshotRG),$($disk.snapshotSubscription),Success" | Out-File -FilePath $filePath -Append -Force
            Write-Output "Success for $($disk.snapshotName)"
        }
        catch {
            Write-Error "An error occurred during snapshot creation for $($disk.snapshotName)"
            $errMsg = $_.Exception.Message
            "$($disk.snapshotName),$($disk.snapshotRG),$($disk.snapshotSubscription),Failure,$errMsg" | Out-File -FilePath $filePath -Append -Force
        }
    }
    else {
        try {
            New-AzSnapshot -SnapshotName ("snpsht-$($azdisk.Name)") -ResourceGroupName $snapshotRG -Snapshot $snapshotConfig
            "snpsht-$($azDisk.Name),$($snapshotRG),$($snapshotSubscription),Success" | Out-File -FilePath $filePath -Append -Force
            Write-Output "Success for snpsht-$($azDisk.Name)"
        }
        catch {
            Write-Error "An error occurred during snapshot creation for snpsht-$($azvm.Name)-$(($_.ManagedDisk.Id -split "/")[-1])"
            $errMsg = $_.Exception.Message
            Write-Output $errMsg
            "snpsht-$($azDisk.Name),$($snapshotRG),$($snapshotSubscription),Failure,$errMsg" | Out-File -FilePath $filePath -Append -Force
        }
    }
    Write-Host "Finished Job for $($disk.diskName)" 
}
#
$Global:jobs = @()
$Global:jobCounter = 0
$Global:totalJobs = 0
$Global:jobErrors = ""
$Global:errorFile = @()
$wrkdir = $PSScriptRoot
$filePath = "$wrkdir/snapshots.csv"
"SnapshotName,SnapshotRG,SnapshotSubscription,Msg,$(Get-Date -Format 'dd-MM-yyyy hh:mm:ss')" | Out-File -FilePath $filePath -Append -Force


$Global:totalJobs = ($vms | Measure-Object).Count
$vms | ForEach-Object {
    if ( $jobCounter -lt $maxJobCount) {
        Write-Host Starting Job of $_.diskName
        $job = Start-Job -Name $_.diskName -ScriptBlock $task -ArgumentList $_, $wrkdir
        $Global:jobs += $job
        $Global:jobCounter++
    } 
}

while ($true) {
    $currentlyRunningJobs = $Global:jobs | where State -EQ "Running" | where HasMoreData -EQ $true
    #Write-Host Current Job is #$currentlyRunningJobs
    if ((($currentlyRunningJobs | Measure-Object).Count -lt $maxJobCount) -and (($jobCounter) -lt $Global:totalJobs)) {
        Write-Host Starting Job of $vms[$Global:jobCounter].diskName
        $job = Start-Job -Name $vms[$Global:jobCounter].diskName -ScriptBlock $task -ArgumentList $vms[$Global:jobCounter], $wrkdir 
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
                # Start-Transcript -Path "./failedJobs.txt" -Force
                "jobName,Error" | Out-File -FilePath "./failedJobError.csv" -Force
                $failedJobs | ForEach-Object {
                    ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                    # $errorDetails = (Receive-Job -Job $_ -Keep) 
                    $errorDetails = $_.ChildJobs.JobStateInfo.Reason -join ";"
                    Write-Host $errorDetails
                    $_.Name+","+$errorDetails | Out-File -FilePath "./failedJobError.csv" -Append -Force 
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