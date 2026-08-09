#
$filePath = 'vms.csv'
$jobCount = 30
$execute = {
    # Something
}


function Invoke-Jobs {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [Object[]]$VmList,
        [scriptblock]$execute = {},
        [int]$MaxJob = 11,
        [string]$ReportPath = '',
        [int]$jobTimeOutSec = 1800,
        [string]$runName = '',
        [string]$workPath
    )

    $task = $execute

    $retry = 3
    $optionsToAdd = @{}
    $optionsToAdd.Add('retry', $retry)

    $initTask = {
        param (
            $tmpVm,
            $workdir
        )
        Set-Location $workdir
        $tmpVm.PSObject.Members | Where-Object { $_.MemberType -eq 'NoteProperty' } | ForEach-Object { New-Variable -Name "$($_.Name)".Replace(' ', '') -Value $_.Value }
        Write-Output "Starting Job for $($tmpVm.Name)"
        Clear-Variable -Name 'tmpVm'
    }

    $task = [scriptblock]::Create($initTask.ToString() + "`n" + $task.ToString())

    $Global:jobs = @()
    $Global:jobCounter = 0
    $Global:totalJobs = 0
    $Global:jobErrors = ''
    $Global:errorFile = @()

    $maxJobCount = @($MaxJob, 30) | Where-Object { ($_ -ne '') -and ($_ -ne $null) -and ($_.GetType().ToString() -eq 'System.Int32') } | Select-Object -First 1
    $jobTimeoutSec = @($jobTimeOutSec, 1800) | Where-Object { ($_ -ne '') -and ($_ -ne $null) -and ($_.GetType().ToString() -eq 'System.Int32') } | Select-Object -First 1

    $workPaths = @($workPath, $PSScriptRoot, (Get-Location).Path, $HOME, $env:TEMP, 'C:\Temp')
    $wrkdir = $workPaths | Where-Object { ($_ -ne '') -and ($null -ne $_) -and (Test-Path -Path $_ -PathType Container) } | Select-Object -First 1
    Set-Location $wrkdir

    $processing = $false

    if ($processing) {
        $reportTempDir = "Report-Temp-$(Get-Date -Format 'dd-MM-yyyy-hh-mm')"
        New-Item -Path (Join-Path $wrkdir $reportTempDir) -ItemType Directory -Force -ErrorAction Stop | Out-Null
        $optionsToAdd.Add('reportTempDir', (Join-Path $wrkdir $reportTempDir))
    }

    $vms = $VmList

    if (Test-Path Variable:\optionsToAdd -and $optionsToAdd.Count -gt 0) {
        foreach ($instance in $vms) {
            foreach ($key in $optionsToAdd.Keys) {
                $instance | Add-Member -NotePropertyName "$($key)".Replace(' ', '') -NotePropertyValue $optionsToAdd[$key]
            }
        }
    }

    if (($null -eq $runName) -or ($runName -eq '') ) {
        $folderName = "Run-$(Get-Date -Format 'dd-MM-yyyyThh-mm')"
    }
    else {
        $folderName = $runName
    }

    New-Item -Path (Join-Path $wrkdir $folderName) -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path (Join-Path $wrkdir $folderName) 'outputXml') -ItemType Directory -Force | Out-Null
    $timeoutLog = Join-Path $folderName 'timeoutJobs.csv'
    $skipLog = Join-Path $folderName 'skippedJobs.csv'
    $stopLog = Join-Path $folderName 'stoppedJobs.csv'

    function Save-JobLog {
        param (
            [Parameter(Mandatory = $true)]$JobList,
            [Parameter(Mandatory = $true)]$TargetFolder
        )
        $JobList | ForEach-Object {
            Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath (Join-Path $TargetFolder "$($_.Name).txt") -ErrorVariable outFileError
            Receive-Job -Keep -Job $_ *>&1 | Export-Clixml -Depth 3 -Force -Path (Join-Path (Join-Path $TargetFolder 'outputXml') "$($_.Name).xml")
            if ($outFileError) {
                Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath (Join-Path $TargetFolder "$($_.Name)-$(Get-Date -Format 'dd-MM-yyyyThh-mm-ss').txt")
            }
        }
    }

    function Show-FailingJobsWindow {
        param (
            [Parameter(Mandatory = $true)]$JobList,
            [Parameter(Mandatory = $true)]$TargetFolder,
            [Parameter(Mandatory = $true)][ref]$FailFlagRef,
            [Parameter(Mandatory = $true)]$ShowFailedJob,
            $CurrentProc
        )
        $failedJobs = $JobList | where State -EQ 'Failed' | where HasMoreData -EQ $true
        if (($failedJobs | Measure-Object).Count -gt 0) {
            $failedJobs | ft Name, State, Id, @{n = 'Reason'; e = { ($_.ChildJobs.JobStateInfo.Reason -join ';') -replace '^System.Management.Automation.RemoteException:', '' } } -Wrap | Out-File -FilePath "./$TargetFolder/failingJobs.txt"
            $FailFlagRef.Value++
        }
        if ($FailFlagRef.Value -eq 3) {
            $fPath = "./$TargetFolder/failingJobs.txt"
            $command = @"
while(`$true) {
Clear-Host
Get-Content `$"$fPath`"
Start-Sleep -Seconds 5
}
"@
            $bytes = [System.Text.Encoding]::Unicode.GetBytes($command)
            $encodedCommand = [Convert]::ToBase64String($bytes)
            if ($ShowFailedJob) {
                return (Start-Process powershell.exe -ArgumentList '-NoExit', '-EncodedCommand', $encodedCommand -PassThru)
            }
        }
        return $CurrentProc
    }

    $showFailedJob = $true
    $failFlag = 2
    $proc = $null

    $Global:totalJobs = ($vms | Measure-Object).Count
    $vms | ForEach-Object {
        if ($jobCounter -lt $maxJobCount) {
            Write-Host "Starting Job of $_.Name"
            $job = Start-Job -Name $_.Name -ScriptBlock $task -ArgumentList $_, $wrkdir
            $Global:jobs += $job
            $Global:jobCounter++
        }
    }

    while ($true) {
        if (Test-Path (Join-Path $wrkdir 'Break_Loop')) {
            Write-Host 'Break_Loop flag detected, exiting job monitoring loop.'
            $currentRunning = $Global:jobs | Where-Object { $_.State -eq 'Running' }
            foreach ($j in $currentRunning) {
                [PSCustomObject]@{ Name = $j.Name; Id = $j.Id; State = 'Skipped'; Reason = 'Break_Loop flag' } |
                Export-Csv -Path $skipLog -NoTypeInformation -Append -Force
            }
            Remove-Item -Path (Join-Path $wrkdir 'Break_Loop') -Force -ErrorAction SilentlyContinue
            break
        }

        $currentlyRunningJobs = $Global:jobs | where State -EQ 'Running' | where HasMoreData -EQ $true
        if ((($currentlyRunningJobs | Measure-Object).Count -lt $maxJobCount) -and (($jobCounter) -lt $Global:totalJobs)) {
            Write-Host "Starting Job of $vms[$Global:jobCounter].Name"
            $job = Start-Job -Name $vms[$Global:jobCounter].Name -ScriptBlock $task -ArgumentList $vms[$Global:jobCounter], $wrkdir
            $Global:jobs += $job
            $Global:jobCounter++
        }
        elseif (($jobCounter) -eq $Global:totalJobs) {
            Write-Host 'All Jobs Initiated'
            $currentJobs = $Global:jobs | where State -EQ 'Running' | where HasMoreData -EQ $true
            $stopFlagFiles = Get-ChildItem -Path $wrkdir -Filter 'StopJob_*.txt' -File -ErrorAction SilentlyContinue
            foreach ($file in $stopFlagFiles) {
                if ($file.BaseName -match '^StopJob_(\\d+)$') {
                    $jobId = $Matches[1]
                    $job = Get-Job -Id $jobId -ErrorAction SilentlyContinue
                    if ($job -and $job.State -eq 'Running') {
                        Stop-Job -Id $jobId
                        Write-Host "Job $jobId stopped via flag file $($file.Name)."
                        [PSCustomObject]@{Name = $job.Name; Id = $job.Id; State = $job.State; Reason = 'Stopped using per-job flag' } | Export-Csv -Path $stopLog -NoTypeInformation -Append -Force
                    }
                    Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
                }
            }
            if (($currentJobs | Measure-Object).Count -gt 0) {
                Write-Host 'Currently Waiting for all jobs to be finished'
                Write-Host 'Currently Running Jobs are:'
                $currentJobs | Select-Object Id, Name, State, @{n = 'Timer(Sec)'; e = { [Math]::Floor(((Get-Date) - $_.PSBeginTime).TotalSeconds) } } | Format-Table -AutoSize -RepeatHeader
                $currentJobs | ForEach-Object {
                    $elapsed = (Get-Date) - $_.PSBeginTime
                    if ($elapsed.TotalSeconds -gt $jobTimeoutSec) {
                        Stop-Job -Id $_.Id
                        $timeoutInfo = [PSCustomObject]@{ Name = $_.Name; Id = $_.Id; State = $_.State; Reason = 'Job Timed Out' }
                        $timeoutInfo | Export-Csv -Path $timeoutLog -NoTypeInformation -Append -Force
                        Write-Host "Job $($_.Name) timed out and was stopped."
                    }
                }
                Save-JobLog -JobList $currentJobs -TargetFolder $folderName
                $proc = Show-FailingJobsWindow -JobList $Global:jobs -TargetFolder $folderName -FailFlagRef ([ref]$failFlag) -ShowFailedJob $showFailedJob -CurrentProc $proc
                Start-Sleep -Seconds 30
            }
            else {
                Save-JobLog -JobList $Global:jobs -TargetFolder $folderName
                Start-Transcript -Path "./$folderName/allJobs.txt" -Force
                $Global:jobs | ForEach-Object {
                    ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                    $jobDetails = (Receive-Job -Job $_ -Keep)
                    Write-Host $jobDetails
                }
                Stop-Transcript
                $failedJobs = $Global:jobs | where State -EQ 'Failed' | where HasMoreData -EQ $true
                $proc = Show-FailingJobsWindow -JobList $Global:jobs -TargetFolder $folderName -FailFlagRef ([ref]$failFlag) -ShowFailedJob $showFailedJob -CurrentProc $proc
                if ($null -ne $proc) { Stop-Process -Id $proc.Id }
                if (($failedJobs | Measure-Object).Count -gt 0) {
                    Write-Host 'Following Jobs Failed. Please Check'
                    Write-Host "$(($failedJobs | Measure-Object).Count) jobs failed out of $Global:totalJobs jobs"
                    $failedJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
                    $failedJobs | Select-Object Id, Name, State | Export-Csv -Path (Join-Path $folderName 'listOfFailedJobs.csv') -NoTypeInformation -Force
                    'Name,Id,State,Reason' | Out-File -FilePath (Join-Path $folderName 'failedJobError.csv') -Force
                    $failedJobs | ForEach-Object {
                        ($_ | Select-Object Id, Name, State | Format-Table -AutoSize -HideTableHeaders)
                        $errorDetails = $_.ChildJobs.JobStateInfo.Reason -join ';'
                        Write-Host $errorDetails
                        "${($_.Name)},${($_.Id)},${($_.State)},${($errorDetails -replace '^System.Management.Automation.RemoteException:', '' )}" | Out-File -FilePath (Join-Path $folderName 'failedJobError.csv') -Append -Force
                    }
                }
                Write-Host 'All Jobs Finished'
                Write-Host "$(($failedJobs | Measure-Object).Count) jobs failed out of $Global:totalJobs jobs"
                break
            }
        }
        else {
            $currentJobs = $Global:jobs | where State -EQ 'Running' | where HasMoreData -EQ $true
            $stopFlagFiles = Get-ChildItem -Path $wrkdir -Filter 'StopJob_*.txt' -File -ErrorAction SilentlyContinue
            foreach ($file in $stopFlagFiles) {
                if ($file.BaseName -match '^StopJob_(\\d+)$') {
                    $jobId = $Matches[1]
                    $job = Get-Job -Id $jobId -ErrorAction SilentlyContinue
                    if ($job -and $job.State -eq 'Running') {
                        Stop-Job -Id $jobId
                        Write-Host "Job $jobId stopped via flag file $($file.Name)."
                        [PSCustomObject]@{Name = $job.Name; Id = $job.Id; State = $job.State; Reason = 'Stopped using per-job flag' } | Export-Csv -Path $stopLog -NoTypeInformation -Append -Force
                    }
                    Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
                }
            }
            $currentJobs | ForEach-Object {
                $elapsed = (Get-Date) - $_.PSBeginTime
                if ($elapsed.TotalSeconds -gt $jobTimeoutSec) {
                    Stop-Job -Id $_.Id
                    $timeoutInfo = [PSCustomObject]@{ Name = $_.Name; Id = $_.Id; State = $_.State; Reason = 'Job Timed Out' }
                    $timeoutInfo | Export-Csv -Path $timeoutLog -NoTypeInformation -Append -Force
                    Write-Host "Job $($_.Name) timed out and was stopped."
                }
            }
            Save-JobLog -JobList $currentJobs -TargetFolder $folderName
            $proc = Show-FailingJobsWindow -JobList $Global:jobs -TargetFolder $folderName -FailFlagRef ([ref]$failFlag) -ShowFailedJob $showFailedJob -CurrentProc $proc
            $currentJobs | Select-Object Id, Name, State, @{n = 'Timer(Sec)'; e = { [Math]::Floor(((Get-Date) - $_.PSBeginTime).TotalSeconds) } } | Format-Table -AutoSize -RepeatHeader
            Start-Sleep -Seconds 30
        }
    }

    $outputXmlDir = Join-Path $folderName 'outputXml'
    Get-ChildItem -Path (Join-Path $outputXmlDir '*.xml') | Select-Object BaseName, @{Name = 'ErrMsg'; Exp = { Get-Item -Path $_.fullName | Import-Clixml | where writeErrorStream -EQ $true | Select-Object -ExpandProperty TargetObject } } | Export-Csv -NoTypeInformation -Force -Path (Join-Path $outputXmlDir 'error.csv')

    if ($processing) {
        Write-Output 'Processing'
        Set-Location (Join-Path $wrkdir $reportTempDir)
        $VmOutputs = Import-Csv -Path (Get-ChildItem -Path . -Filter *.csv)


        $reportPath = Join-Path $wrkdir "Report-$(Get-Date -Format 'dd-MM-yyyy-hh-mm').csv"
        $VmOutputs | Export-Csv -NoTypeInformation -Force -Path $reportPath
        Write-Output "Report Generated at: $($reportPath)"
    }

    $summaryFile = Join-Path $folderName 'jobSummary.csv'
    $notStartedLog = Join-Path $folderName 'notStartedJobs.csv'
    if (Test-Path $skipLog) {
        $notStartedJobs = Compare-Object -ReferenceObject $vms.Name -DifferenceObject $jobs.Name | Where-Object { $_.SideIndicator -eq '<=' }
        foreach ($job in $notStartedJobs) {
            [PSCustomObject]@{Name = $job.InputObject; Id = 'NA'; State = 'Not Started'; Reason = 'Not Started as stopped by Break_Loop' } | Export-Csv -Path $notStartedLog -NoTypeInformation -Append -Force
        }
    }
    $logFiles = @($timeoutLog, $skipLog, $stopLog, (Join-Path $folderName 'failedJobError.csv'), $notStartedLog)
    foreach ($lf in $logFiles) {
        if (Test-Path $lf) { Import-Csv $lf | Export-Csv -Path $summaryFile -NoTypeInformation -Append -Force }
    }
    
}

$workDirs = @($PSScriptRoot, (Get-Location).Path, $HOME, $env:TEMP, 'C:\Temp')
$workdir = $workDirs | Where-Object { ($_ -ne '') -and ($null -ne $_) -and (Test-Path -Path $_ -PathType Container) } | Select-Object -First 1
Set-Location $workdir


$runName = "Run-$(Get-Date -Format 'dd-MM-yyyyThh-mm')"

$vmList = Import-Csv $filePath
Invoke-Jobs -VmList ($vmList) -MaxJob $jobCount -execute $execute -runName $runName -workPath $workdir

if (
    (Test-Path (Join-Path $runName 'failedJobError.csv')) -or
    (Test-Path (Join-Path $runName 'notStartedJobs.csv'))
) {
    $retryTable = @{}
    $vmList | ForEach-Object {
        if ($retryTable.ContainsKey($_.Name)) {
            $retryTable[$_.Name] += $_
        }
        else {
            $retryTable[$_.Name] = @($_)
        }
    }

    $retryInputs = foreach ( $file in @(
            (Join-Path $runName 'failedJobError.csv'),
            (Join-Path $runName 'notStartedJobs.csv')
        )) {
        Import-Csv $file | Where-Object { $retryTable.ContainsKey($_.Name) } | ForEach-Object { $retryTable[$_.Name] }
    }

    if ($retryInputs) {
        Write-Output 'Do you want to retry with following inputs:'
        $retryInputs | Format-Table
        $resp = Read-Host
        if ($resp -in @('y', 'Y')) {
            Invoke-Jobs -VmList $retryInputs -MaxJob $jobCount -runName "Retry-$($runName)" -workPath $workdir
    
        }
    }
}


