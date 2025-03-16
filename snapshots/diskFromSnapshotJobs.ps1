#
$maxJobCount = 11
$vms = Import-Csv -Path "./vms.csv" -Header "Name"
$task = {
    param(
        $snpshot,
        $wrkdir)
        #
    Write-Host "Starting Job for" $snpshot.SnapshotName 
    Set-Location $wrkdir 
    # Here the csv file should have 7 columns for SnapshotName, its ResourceGroup, its Subscription and then its corresponding diskName, diskRG, diskSubscription, and diskEncryptionSetId
    Set-AzContext -Subscription $snpshot.Subscription -ErrorAction Stop
    #
    $ErrorActionPreference = 'Stop'
    $filePath = "./diskCreationFromSnapshot.csv"
    $snapshot = Get-AzSnapshot -SnapshotName $snpshot.SnapshotName.trim() -ResourceGroupName $snpshot.ResourceGroup.trim()
    $diskConfig = New-AzDiskConfig -SkuName 'Standard_LRS' -CreateOption Copy -SourceResourceId $snapshot.Id
    try {
        Set-AzContext -Subscription $snpshot.diskSubscription.trim() -ErrorAction Stop
        New-AzDisk -Disk $diskConfig -DiskName $snpshot.diskName.trim() -ResourceGroupName $snpshot.diskRG.trim() -DiskEncryptionSetId $snpshot.diskEncryptionSetId.trim()
        "$($snpshot.diskName),$($snpshot.diskRG),$($snpshot.diskSubscription),Success" | Out-File -FilePath $filePath -Append -Force
        Write-Output "Success for $($snpshot.diskName.trim())"
    }
    catch {
        Write-Error "An error occurred during disk creation for $($_.diskName)"
        $errMsg = $_.Exception.Message
        Write-Output $errMsg
        "$($snpshot.diskName),$($snpshot.diskRG),$($snpshot.diskSubscription),Failure,$errMsg" | Out-File -FilePath $filePath -Append -Force
    }

    Write-Host "Finished Job for" $snpshot.SnapshotName
}
#
$Global:jobs = @()
$Global:jobCounter = 0
$Global:totalJobs = 0
$Global:jobErrors = ""
$Global:errorFile = @()
$wrkdir = $PSScriptRoot
Set-Location $wrkdir
$filePath = "$wrkdir/diskCreationFromSnapshot.csv"
"DiskName,DiskRG,DiskSubscription,Msg,$(Get-Date -Format 'dd-MM-yyyyThh:mm:ss')" | Out-File -FilePath $filePath -Append -Force

$Global:totalJobs = ($vms | Measure-Object).Count
$vms | ForEach-Object {
    if ( $jobCounter -lt $maxJobCount) {
        Write-Host Starting Job of $_.SnapshotName
        $job = Start-Job -Name $_.SnapshotName -ScriptBlock $task -ArgumentList $_, $wrkdir
        $Global:jobs += $job
        $Global:jobCounter++
    } 
}

while ($true) {
    $currentlyRunningJobs = $Global:jobs | where State -EQ "Running" | where HasMoreData -EQ $true
    #Write-Host Current Job is #$currentlyRunningJobs
    if ((($currentlyRunningJobs | Measure-Object).Count -lt $maxJobCount) -and (($jobCounter) -lt $Global:totalJobs)) {
        Write-Host Starting Job of $vms[$Global:jobCounter].SnapshotName
        $job = Start-Job -Name $vms[$Global:jobCounter].SnapshotName -ScriptBlock $task -ArgumentList $vms[$Global:jobCounter], $wrkdir 
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