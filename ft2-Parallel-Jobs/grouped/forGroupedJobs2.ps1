#
$filepath = "./vms.csv"
$jobsToRun = 9
$groupingProperty = "subscription"
$task = {
    param($vm, $wrkdir)
    Write-Host "Starting Job for" $vm.Name 
    #
    try {
        $ErrorActionPreference = "Stop"
        # Use $PSDefaultParameterValues['command:parameter'] = $value to pass value to common parameters
        Set-Location $wrkdir 
        #
        Start-Sleep -Seconds 11
        Write-Error "This is an error to be printed"
        Get-Item "C:\NonExistentFile2.txt" -ErrorAction Stop
    }
    catch {
        throw "An Error Occurred: $($_.Exception.Message)"
    }
    Write-Host "Finished Job for" $vm.Name
}




function runParaJobs {
    param (
        [int]$maxJob = 11,
        [Parameter(Mandatory = $true)]$vms,
        [Parameter(Mandatory = $true)]
        [scriptblock]$taskScript,
        #
        [string]$groupingName = "DefaultGroup",
        [string]$runName = "DefaultRun",
        [int]$jobDelay = 30,
        [scriptblock]$initialScript = {}
    )

    #
    $maxJobCount = $maxJob
    $task = $taskScript
    #
    $localJobs = @()
    $Global:jobCounter = 0
    $Global:totalJobs = 0
    $Global:jobErrors = ""
    $Global:errorFile = @()
    $wrkdir = $PSScriptRoot
    Set-Location $PSScriptRoot

    $folderName = "$($runName)\$($groupingName)"
    New-Item -Path "$($wrkdir)\$($folderName)" -ItemType Directory -Force | Out-Null
    New-Item -Path "$($wrkdir)\$($folderName)\outputXml" -ItemType Directory -Force | Out-Null


    $Global:totalJobs = ($vms | Measure-Object).Count
    $vms | ForEach-Object {
        if ( $jobCounter -lt $maxJobCount) {
            Write-Host Starting Job of $_.Name
            $job = Start-Job -Name $_.Name -ScriptBlock $task -ArgumentList $_, $wrkdir
            $localJobs += $job
            $Global:jobs += $job
            $Global:jobCounter++
        } 
    }

    while ($true) {
        $currentlyRunningJobs = $localJobs | where State -EQ "Running" | where HasMoreData -EQ $true
        #Write-Host Current Job is #$currentlyRunningJobs
        if ((($currentlyRunningJobs | Measure-Object).Count -lt $maxJobCount) -and (($jobCounter) -lt $Global:totalJobs)) {
            Write-Host Starting Job of $vms[$Global:jobCounter].Name
            $job = Start-Job -Name $vms[$Global:jobCounter].Name -ScriptBlock $task -ArgumentList $vms[$Global:jobCounter], $wrkdir 
            $localJobs += $job
            $Global:jobs += $job
            $Global:jobCounter++
        }
        elseif (($jobCounter) -eq $Global:totalJobs) {
            Write-Host "All Jobs Initiated for $($groupingName)"
            # wait for all jobs to be completed
            $currentJobs = $localJobs | where State -EQ "Running" | where HasMoreData -EQ $true
            if (($currentJobs | Measure-Object).Count -gt 0) {
                Write-Host "Currently Waiting for the jobs to be finished"
                Write-Host Currently Running Jobs are:
                $currentJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
                ###
                $currentJobs | ForEach-Object {
                    Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath "$($folderName)\$($_.Name).txt" -ErrorVariable outFileError
                    Receive-Job -Keep -Job $_ *>&1 | Export-Clixml -Depth 3 -Force -Path "$($folderName)\outputXml\$($_.Name).xml" 
                    if ($outFileError) {
                        Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath "$($folderName)\$($_.Name)-$(Get-Date -Format 'dd-MM-yyyyThh-mm-ss').txt"
                    }
                }
                ###
                Start-Sleep -Seconds $jobDelay
            }
            else {
                ###
                $localJobs | ForEach-Object {
                    Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath "$($folderName)\$($_.Name).txt" -ErrorVariable outFileError
                    Receive-Job -Keep -Job $_ *>&1 | Export-Clixml -Depth 3 -Force -Path "$($folderName)\outputXml\$($_.Name).xml" 
                    if ($outFileError) {
                        Receive-Job -Keep -Job $_ *>&1 | Out-String | Out-File -Force -FilePath "$($folderName)\$($_.Name)-$(Get-Date -Format 'dd-MM-yyyyThh-mm-ss').txt"
                    }
                }
                ###
                <#
                Start-Transcript -Path "./$folderName/allJobs.txt" -Force
                $localJobs | ForEach-Object {
                    ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                    $jobDetails = (Receive-Job -Job $_ -Keep) 
                    Write-Host $jobDetails
                }
                Stop-Transcript
                #>
                # f-here
                $failedJobs = $localJobs | where State -EQ "Failed" | where HasMoreData -EQ $true
                if (($failedJobs | Measure-Object).Count -gt 0) {
                    # Write-Host Following Jobs Failed. Please Check
                    # Write-Host ($failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
                    # $failedJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
                    $failedJobs | Select-Object Id, Name, State | Export-Csv -Path "./$folderName/listOfFailedJobs.csv" -NoTypeInformation -Force
                    # Start-Transcript -Path "./failedJobs.txt" -Force
                    "jobName,Error" | Out-File -FilePath "./$folderName/failedJobError.csv" -Force
                    $failedJobs | ForEach-Object {
                        # ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                        # $errorDetails = (Receive-Job -Job $_ -Keep) 
                        $errorDetails = $_.ChildJobs.JobStateInfo.Reason -join ";"
                        # Write-Host $errorDetails
                        $_.Name + "," + $errorDetails | Out-File -FilePath "./$folderName/failedJobError.csv" -Append -Force 
                    }
                    # Write-Host ($failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
                    # Stop-Transcript
                }
                Write-Host "All Jobs Finished for $($groupingName) and $(($failedJobs | Measure-Object).Count) jobs failed"
                # Write-Host ($failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
                break
            }

        }
        else {
            $currentJobs = $localJobs | where State -EQ "Running" | where HasMoreData -EQ $true
            #Write-Host $currentJobs 
            ###
            $currentJobs | ForEach-Object {
                Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath "$($folderName)\$($_.Name).txt" -ErrorVariable outFileError
                Receive-Job -Keep -Job $_ *>&1 | Export-Clixml -Depth 3 -Force -Path "$($folderName)\outputXml\$($_.Name).xml" 
                if ($outFileError) {
                    Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath "$($folderName)\$($_.Name)-$(Get-Date -Format 'dd-MM-yyyyThh-mm-ss').txt"
                }
            }
            ###
            $currentJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
            Start-Sleep -Seconds $jobDelay
        }
    }
    Get-ChildItem -Path "$($folderName)\outputXml\*.xml" | Select BaseName, @{Name = "ErrMsg"; Exp = { Get-Item -Path $_.fullName | Import-Clixml | Where writeErrorStream -eq $true | Select -ExpandProperty TargetObject } } | Export-Csv -NoTypeInformation -Force -Path "$($folderName)\outputXml\error.csv"


}


<#
$Global:jobs += $job
$localJobs += $job

Silent the transcript 

grouping 
#>

$RunName = "Run-$(Get-Date -Format 'dd-MM-yyyyThh-mm')"

Set-Location $PSScriptRoot
$allVms = Import-Csv -Path $filepath
$VmGroups = $allVms | Group-Object -Property $groupingProperty

$Global:jobs = @()

foreach ($VmGroup in $VmGroups) {
    Write-Output "Starting for $($VmGroup.Name)"
    #runGroupedParallelTask -maxJob $jobsToRun -taskScript $tasky -vms $VmGroup.Group
    runParaJobs -maxJob $jobsToRun -taskScript $task -vms $VmGroup.Group -groupingName $VmGroup.Name -runName $RunName
    Start-Sleep -Seconds 11
}

Start-Transcript -Path "$($RunName)\allJobs.txt" -Force -Append
$Global:jobs | ForEach-Object {
    $_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders
    Receive-Job -Job $_ -Keep
}
Stop-Transcript

$allTotalJobs = ($Global:jobs | Measure-Object).Count
$allFailedJobs = $Global:jobs | where State -EQ "Failed" | where HasMoreData -EQ $true
if (($allFailedJobs | Measure-Object).Count -gt 0) {
    Write-Host Following Jobs Failed. Please Check
    Write-Host "$(($allFailedJobs | Measure-Object).Count) jobs failed out of $($allTotalJobs) jobs"
    $allFailedJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
    $allFailedJobs | Select-Object Id, Name, State | Export-Csv -Path "./$RunName/listOfFailedJobs.csv" -NoTypeInformation -Force
    "jobName,Error" | Out-File -FilePath "./$RunName/failedJobError.csv" -Force
    $allFailedJobs | ForEach-Object {
        ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
        $errorDetails = $_.ChildJobs.JobStateInfo.Reason -join ";"
        Write-Host $errorDetails
        $_.Name + "," + $errorDetails | Out-File -FilePath "./$RunName/failedJobError.csv" -Append -Force 
    }
    Write-Host ($allFailedJobs | Measure-Object).Count jobs failed out of $allTotalJobs jobs
}
Write-Host All Jobs Finished
Write-Host ($allFailedJobs | Measure-Object).Count jobs failed out of $allTotalJobs jobs