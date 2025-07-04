#
$tasky = {
    param(
        $vm,
        $wrkdir)
    Write-Host "Starting Job for" $vm.Name 
    Set-Location $wrkdir 
    #
    Start-Sleep -Seconds 11
    # if((Get-Random -Maximum 6 -Minimum 2) -in @(2,4)){
    Get-Item "C:\NonExist.txt" -ErrorAction Stop
    # }
    #
}
$jobsToRun = 9
$filepath = "./vm.csv"
$groupingProperty = "subscription"


function runParallelTask {
    param (
        [int]$maxJob = 11,
        [Parameter(Mandatory = $true)]
        $vms,
        [Parameter(Mandatory = $true)]
        #
        [ScriptBlock]$taskScript,
        [int]$jobDelay = 30,
        [ScriptBlock]$initialScript = {}
    )

    $maxJobCount = $maxJob
    #
    $task = $taskScript
    # $vms = Import-Csv -Path $csvFilePath # -Header "Name"

    $Global:jobs = @()
    $Global:jobCounter = 0
    $Global:totalJobs = 0
    $Global:jobErrors = ""
    $Global:errorFile = @()
    $Global:totalJobs = ($vms | Measure-Object).Count
    $errFilePath = "./failedJobs.csv"
    $wrkdir = $PSScriptRoot



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
                Start-Transcript -Path "./allJobs.txt" -Force -Append
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
                    $failedJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
                    $failedJobs | Select-Object Id, Name, State | Export-Csv -Path "./listOfFailedJobs.csv" -NoTypeInformation -Force -Append
                    # Start-Transcript -Path "./failedJobs.txt" -Force
                    "jobName,Error" | Out-File -FilePath $errFilePath -Force -Append
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



Set-Location $PSScriptRoot
$allVms = Import-Csv -Path $filepath

$VmGroups = $allVms | Group-Object -Property $groupingProperty

foreach ($VmGroup in $VmGroups) {
    Write-Output "Starting for $($VmGroup.Name)"
    runParallelTask -maxJob $jobsToRun -taskScript $tasky -vms $VmGroup.Group
    Start-Sleep -Seconds 11
}
# all job transcript, re-arrange, 

# runParallelTask -maxJob 9 -taskScript $tasky -vms (Import-Csv -Path "./vm.csv")