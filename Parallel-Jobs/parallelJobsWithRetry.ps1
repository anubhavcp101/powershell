#
$maxJobCount = 11
$csvFilePath = "./vms.csv"
$attempt = 0
$maxAttempt = 3
$delay = 30
$task = {
    #
    param(
        $vm,
        $wrkdir
        )
    Write-Host "Starting Job for" $vm.Name 
    Set-Location $wrkdir 

    Start-Sleep -Seconds 11
    Write-Error "This is an error to be printed"
    Get-Item "C:\NonExistentFile2.txt" -ErrorAction Stop
    Write-Host "Finished Job for" $vm.Name
}

while ($attempt -le $maxAttempt) {
    Set-Location $PSScriptRoot | Out-Null
    $vms = $null
    if ($attempt -eq 0) {
        $vms = Import-Csv -Path $csvFilePath #-Header "Name"
    }
    else {
        if (($Global:failedJobs | Measure-Object).Count -ge 0) {
            if ((Test-Path "./failedJobError.csv") -and (Get-Item "./failedJobError.csv").Length -ge 12) {
                $attempt++
                Write-Host Attempt $attempt with a delay of($delay * ($attempt)) Seconds
                $vms = Import-Csv -Path "./failedJobError.csv" 
                Start-Sleep -Seconds ($delay * ($attempt))
            }
            else {
                break; break;
            }
        }
    }

    #
    $Global:jobs = @()
    $Global:jobCounter = 0
    $Global:totalJobs = 0
    $Global:jobErrors = ""
    $Global:errorFile = @()
    $wrkdir = $PSScriptRoot


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
                $Global:failedJobs = $Global:jobs | where State -EQ "Failed" | where HasMoreData -EQ $true
                if (($Global:failedJobs | Measure-Object).Count -gt 0) {
                    Write-Host Following Jobs Failed. Please Check
                    Write-Host ($Global:failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
                    $Global:failedJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
                    $Global:failedJobs | Select-Object Id, Name, State | Export-Csv -Path "./listOfFailedJobs.csv" -NoTypeInformation -Force
                    # Start-Transcript -Path "./failedJobs.txt" -Force
                    "Name,Error" | Out-File -FilePath "./failedJobError.csv" -Force
                    $Global:failedJobs | ForEach-Object {
                    ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                        # $errorDetails = (Receive-Job -Job $_ -Keep) 
                        $errorDetails = $_.ChildJobs.JobStateInfo.Reason -join ";"
                        Write-Host $errorDetails
                        $_.Name + "," + $errorDetails | Out-File -FilePath "./failedJobError.csv" -Append -Force 
                    }
                    Write-Host ($Global:failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
                    # Stop-Transcript
                }
                Write-Host All Jobs Finished
                Write-Host ($Global:failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
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
}

