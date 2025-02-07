#
function runParallelTask {
    param (
        [int]$maxJob = 11,
        [Parameter(Mandatory=$true)]
        [string]$csvFilePath,
        [Parameter(Mandatory=$true)]
        #
        [ScriptBlock]$taskScript,
        [int]$jobDelay = 30,
        [ScriptBlock]$initialScript = {}
    )

    $maxJobCount = $maxJob
    #
    $task = $taskScript
    $vms = Import-Csv -Path $csvFilePath # -Header "Name"

    $Global:jobs = @()
    $Global:jobCounter = 0
    $Global:totalJobs = 0
    $Global:jobErrors = ""
    $Global:errorFile = @()
    $wrkdir = $PSScriptRoot

    New-Item -ItemType Directory -Path ((Split-Path -path $csvFilePath) + "\errFiles") -Force | Out-Null
    $errFilePath = (Split-Path -Path $csvFilePath) + "\errFiles\failedJobError.csv"

    $Global:totalJobs = ($vms | Measure-Object).Count
    $vms | ForEach-Object {
        if ( $jobCounter -lt $maxJobCount) {
            Write-Host Starting Job of $_.Name
            $job = Start-Job -Name $_.Name -InitializationScript $initialScript -ScriptBlock $task -ArgumentList $_, $wrkdir
            $Global:jobs += $job
            $Global:jobCounter++
        }
        
    }

    while ($true) {
        $currentlyRunningJobs = $Global:jobs | where State -EQ "Running" | where HasMoreData -EQ $true
        #Write-Host Current Job is #$currentlyRunningJobs
        if ((($currentlyRunningJobs | Measure-Object).Count -lt $maxJobCount) -and (($jobCounter) -lt $Global:totalJobs)) {
            Write-Host Starting Job of $vms[$Global:jobCounter].Name
            $job = Start-Job -Name $vms[$Global:jobCounter].Name -InitializationScript $initialScript -ScriptBlock $task -ArgumentList $vms[$Global:jobCounter], $wrkdir 
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
                Start-Sleep -Seconds $jobDelay
            }
            else {
                $failedJobs = $Global:jobs | where State -EQ "Failed" | where HasMoreData -EQ $true
                if (($failedJobs | Measure-Object).Count -gt 0) {
                    Write-Host Following Jobs Failed. Please Check
                    Write-Host ($failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
                    $failedJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
                    $failedJobs | Select-Object Id, Name, State | Export-Csv -Path "./listOfFailedJobs.csv" -NoTypeInformation -Force
                    # Start-Transcript -Path "./failedJobs.txt" -Force
                    "jobName,Error" | Out-File -FilePath $errFilePath -Force
                    $failedJobs | ForEach-Object {
                    ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                        # $errorDetails = (Receive-Job -Job $_ -Keep) 
                        $errorDetails = $_.ChildJobs.JobStateInfo.Reason -join ";"
                        Write-Host $errorDetails
                        $_.Name + "," + $errorDetails | Out-File -FilePath $errFilePath -Append -Force 
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
            Start-Sleep -Seconds $jobDelay
        }
    }
}

function runParallelTaskWithRetry {
    param (
        [int]$maxJob = 11,
        [Parameter(Mandatory=$true)]
        [string]$csvFilePath,
        [Parameter(Mandatory=$true)]
        [ScriptBlock]$taskScript,
        [int]$jobDelay = 30,
        [ScriptBlock]$initialScript = {},
        [int]$maxAttempt = 3,
        [int]$retryDelay = 30,
        [switch]$withoutExponDelay
    )
    
    $attempt = 0
    $maxJobCount = $maxJob
    $delay = $retryDelay
    $task = $taskScript

    while ($attempt -le $maxAttempt) {
        Set-Location $PSScriptRoot | Out-Null
        $vms = $null
        if ($attempt -eq 0) {
            $attempt++
            $vms = Import-Csv -Path $csvFilePath #-Header "Name"
        }
        else {
            if (($Global:failedJobs | Measure-Object).Count -ge 0) {
                if ((Test-Path $errFilePath) -and (Get-Item $errFilePath).Length -ge 12) {
                    $resp = Read-Host "Want to Attempt again. Only yes is acceptable response"
                    if ($resp -in @("yes", "y")) {
                        Write-Host Your response is positive: $resp
                        if (-not $withoutExponDelay) {
                            Write-Host Attempt $attempt with a delay of($delay * ($attempt)) Seconds
                            Start-Sleep -Seconds ($delay * ($attempt))
                        }
                        else {
                            Write-Host Attempt $attempt with a delay of ($delay) Seconds
                            Start-Sleep -Seconds ($delay)
                        }
                        $vms = Import-Csv -Path $errFilePath 
                        $attempt++
                    }
                    else {
                        Write-Host Negative response received so stopping the script
                        break; break;
                    }
                
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

        New-Item -ItemType Directory -Path ((Split-Path -path $csvFilePath) + "\errFiles") -Force | Out-Null
        $errFilePath = (Split-Path -Path $csvFilePath) + "\errFiles\failedJobError.csv"

        $Global:totalJobs = ($vms | Measure-Object).Count
        $vms | ForEach-Object {
            if ( $Global:jobCounter -lt $maxJobCount) {
                Write-Host Starting Job of $_.Name
                $job = Start-Job -Name $_.Name -InitializationScript $initialScript -ScriptBlock $task -ArgumentList $_, $wrkdir
                $Global:jobs += $job
                $Global:jobCounter++
            } 
        }

        while ($true) {
            $currentlyRunningJobs = $Global:jobs | where State -EQ "Running" | where HasMoreData -EQ $true
            #Write-Host Current Job is #$currentlyRunningJobs
            if ((($currentlyRunningJobs | Measure-Object).Count -lt $maxJobCount) -and (($jobCounter) -lt $Global:totalJobs)) {
                Write-Host Starting Job of $vms[$Global:jobCounter].Name
                $job = Start-Job -Name $vms[$Global:jobCounter].Name -InitializationScript $initialScript -ScriptBlock $task -ArgumentList $vms[$Global:jobCounter], $wrkdir 
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
                    Start-Sleep -Seconds $jobDelay
                }
                else {
                    $Global:failedJobs = $Global:jobs | where State -EQ "Failed" | where HasMoreData -EQ $true
                    if (($Global:failedJobs | Measure-Object).Count -gt 0) {
                        Write-Host Following Jobs Failed. Please Check
                        Write-Host ($Global:failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
                        $Global:failedJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
                        $Global:failedJobs | Select-Object Id, Name, State | Export-Csv -Path "./listOfFailedJobs.csv" -NoTypeInformation -Force
                        # Start-Transcript -Path "./failedJobs.txt" -Force
                        "Name,Error" | Out-File -FilePath $errFilePath -Force
                        $Global:failedJobs | ForEach-Object {
                    ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                            # $errorDetails = (Receive-Job -Job $_ -Keep) 
                            $errorDetails = $_.ChildJobs.JobStateInfo.Reason -join ";"
                            Write-Host $errorDetails
                            $_.Name + "," + $errorDetails | Out-File -FilePath $errFilePath -Append -Force 
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
                Start-Sleep -Seconds $jobDelay
            }
        }
    }

}

$tasky = {
    param(
        $vm,
        $wrkdir)
        #
    Write-Host "Starting Job for" $vm.Name 
    Set-Location $wrkdir 
    #Start-Sleep -Seconds 11
    if((Get-Random -Maximum 6 -Minimum 2) -in @(2,4)){

    Get-Item "C:\NonExist.txt" -ErrorAction Stop
    }
}


#runParallelTask -csvFilePath "" -taskScript $tasky -maxJob 20

#  runParallelTaskWithRetry -csvFilePath "" -taskScript $tasky -maxJob 21 -withoutExponDelay