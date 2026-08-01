#
$filePath = 'vms.csv'
$maxJob = 11 # Number of Jobs needs to run at a time
$reportPath = '' # It should be a location of a directory, not a file

$task = {
    $commandStatus = ''
    #
    $commandOutput = ''
    $hotfixBlock = {
        #
        $serverName = hostname 
        #
        $month = (Get-Date).Month
        $year = (Get-Date).Year
        $cmHotfix = Get-HotFix | Where-Object { $_.InstalledOn -gt (Get-Date -Day 3 -Month $month -Year $year) -and $_.InstalledOn -lt ((Get-Date -Day 1 -Month $month -Year $year).AddMonths(1).AddDays(-1)) }
        $hotfix = $cmHotfix.HotFixID -join ';'
        if ($hotfix -eq '') { $hotfix = 'Nothing Installed' }
        #
        $hostInfo = Get-CimInstance -ClassName Win32_OperatingSystem
        $uptime = ((Get-Date) - ($hostInfo).LastBootUpTime).ToString("%d'days,'%h'hrs,'%m'mins'")
        $osName = $hostInfo.Caption
        $outputs = @($serverName, $osName, $hotfix, $uptime)
        #
        Write-Output ($outputs -join '#')
    }
    $ctx = Set-AzContext -Subscription $subscription.trim() -ErrorAction Stop -Scope Process
    $vmStatus = Get-AzVM -Status -Name $Name.trim() -ResourceGroupName $resourceGroup.trim() -DefaultProfile $ctx -ErrorAction Stop
    if (($vmStatus.Statuses[1].DisplayStatus -ne 'VM running') -or ( -not ($vmStatus.VMAgent)) ) {
        Write-Output "The VM is not running. Please check $($vm.Name.trim())"
        $commandStatus = 'Failed'
        $commandOutput = 'VM not running'
        
    }
    elseif ($vmStatus.OsName -notlike '*Windows*') {
        Write-Output 'Not a windows VM'
        $commandStatus = 'Failed'
        $commandOutput = 'Not a Windows VM'
        
    }
    else {

        $attempt = 0
        do {
            $attempt++
            try {
                $commandOutput = Invoke-AzVMRunCommand -VMName $Name.trim() -ResourceGroupName $resourceGroup.trim() -CommandId 'RunPowerShellScript' -ScriptString $hotfixBlock.ToString() -DefaultProfile $ctx -ErrorAction Stop

                if ($?) {
                    $commandStatus = 'Success'
                    break
                }
            }
            catch {
                Write-Output "Attempt $($attempt): An Error Occurred"
                Write-Output $PSItem.tostring()
                Write-Output $PSItem.ScriptStackTrace
                $commandOutput = "Command Failed: $($PSItem.tostring())"
                $commandStatus = 'Failed'
                if ($attempt -lt $retry) {
                    # retry+1
                    Write-Output "Retry will be attempted after a delay of $(30*$attempt) seconds"
                    Start-Sleep -Seconds (30 * $attempt)
                }
                elseif ($attempt -eq $retry) {
                    # retry+1
                    Write-Output "Retried $($attempt) times but it failed. Please check $($Name)"
                }
            }
        } while ($attempt -lt $retry) # retry+1
    }

    $expVM = $null
    if ($commandStatus -eq 'Success') {
        $expVM = [PSCustomObject]@{
            'VM'            = $Name.trim();
            'CommandOutput' = $commandOutput.Value[0].Message.trim();
            'CommandStatus' = $commandStatus
        }
    }
    else {
        $expVM = [PSCustomObject]@{
            'VM'            = $Name.trim();
            'CommandOutput' = $commandOutput;
            'CommandStatus' = $commandStatus
        }
    }

    $expVM | Export-Csv -NoTypeInformation -Path (Join-Path $reportTempDir "$($Name.trim()).csv") -Force -Append
    
}
#
$optionsToAdd = @{
}
$retry = 3 # 0 will disabled it.
$optionsToAdd.Add('retry', $retry)

$initTask = {
    param (
        $tmpVm,
        $workdir
    )
    Set-Location $workdir
    # $ErrorActionPreference = 'Stop'

    $tmpVm.PSObject.Members | Where-Object { $_.MemberType -eq 'NoteProperty' } | ForEach-Object { New-Variable -Name "$($_.Name)".Replace(' ', '') -Value $_.Value }

    Write-Output 'Starting Job for' $tmpVm.Name
}

$task = [scriptblock]::Create($initTask.ToString() + "`n" + $task.ToString())


$Global:jobs = @()
$Global:jobCounter = 0
$Global:totalJobs = 0
$Global:jobErrors = ''
$Global:errorFile = @()

$maxJobCount = @($maxJob, 30) | Where-Object { ($_ -ne '') -and ($_ -ne $null) -and ($_.GetType().ToString() -eq 'System.Int32') } | Select-Object -First 1
$jobTimeoutSec = 1800 # 30 minutes timeout in seconds

$reportPaths = @($reportPath, $PSScriptRoot, ($PWD.Path), $HOME, $env:TEMP, 'C:\Temp')
$wrkdir = $reportPaths | Where-Object { ($_ -ne '') -and ($_ -ne $null) -and (Test-Path -Path $_ -PathType Container) } | Select-Object -First 1

Set-Location $wrkdir
# $vms = Import-Csv -Path $filePath #-Header "Name"

$reportTempDir = "Report-Temp-$(Get-Date -Format 'dd-MM-yyyy-hh-mm')"
New-Item -Path (Join-Path $wrkdir $reportTempDir) -ItemType Directory -Force -ErrorAction Stop | Out-Null
$optionsToAdd.Add('reportTempDir', (Join-Path $wrkdir $reportTempDir))

# if (((Get-Content $filePath)[0] -notmatch '(.+,{1})?Name,ResourceGroup,Subscription(,.+)?$')) {
#     Write-Output 'Please check headers in the csv file'
#     exit
# }


try {
    $vms = Import-Csv -Path $filePath #-Header "Name"
}
catch [System.IO.FileNotFoundException] {
    Write-Output "File not found at the location: $filePath"
    Write-Output $PSItem.tostring()
    exit
}
catch [System.UnauthorizedAccessException] {
    Write-Output "Access denied to the file: $filePath"
    Write-Output $PSItem.tostring()
    exit
}
catch [System.IO.DirectoryNotFoundException] {
    Write-Output "a directory not found in the path provided: $filePath"
    Write-Output $PSItem.tostring()
    exit
}
catch {
    Write-Output "Encounter an error: $($PSItem.Exception.Message)"
    Write-Output $PSItem.tostring()
    exit
}

if ( (Test-Path Variable:\optionsToAdd) -and ($optionsToAdd.Count -gt 0)) {
    try {
        foreach ($instance in $vms) {
            foreach ($key in $optionsToAdd.Keys) {
                $instance | Add-Member -NotePropertyName "$($key)".Replace(' ', '') -NotePropertyValue "$($optionsToAdd[$key])"
            }
        }
    }
    catch {
        Write-Output 'Failed to add additional options'
        Write-Output $PSItem.tostring()
    }
}

$folderName = "Run-$(Get-Date -Format 'dd-MM-yyyyThh-mm')"
New-Item -Path (Join-Path $wrkdir $folderName) -ItemType Directory -Force | Out-Null
New-Item -Path (Join-Path (Join-Path $wrkdir $folderName) 'outputXml') -ItemType Directory -Force | Out-Null
$timeoutLog = Join-Path $folderName 'timeoutJobs.csv'
'Name,Id,State,Reason' | Out-File -FilePath $timeoutLog -Encoding utf8 -Force
$skipLog = Join-Path $folderName 'skippedJobs.csv'
'Name,Id,State,Reason' | Out-File -FilePath $skipLog -Encoding utf8 -Force
$stopLog = Join-Path $folderName 'stoppedJobs.csv'
'Name,Id,State,Reason' | Out-File -FilePath $stopLog -Encoding utf8 -Force

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
Get-Content `"$fPath`"
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

#<> Top 5 Failed Jobs
$showFailedJob = $true
$failFlag = 2
$proc = $null
#<>


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
    # Check for break flag file
    if (Test-Path (Join-Path $wrkdir 'Break_Loop')) {
        Write-Host 'Break_Loop flag detected, exiting job monitoring loop.'
        # Log currently running jobs as skipped
        $currentRunning = $Global:jobs | Where-Object { $_.State -eq 'Running' }
        foreach ($j in $currentRunning) {
            [pscustomobject]@{ Name = $j.Name; Id = $j.Id; State = 'Skipped'; Reason = 'Break_Loop flag' } |
            Export-Csv -Path $skipLog -NoTypeInformation -Append -Force
        }
        break
    }
    $currentlyRunningJobs = $Global:jobs | where State -EQ 'Running' | where HasMoreData -EQ $true
    if ((($currentlyRunningJobs | Measure-Object).Count -lt $maxJobCount) -and (($jobCounter) -lt $Global:totalJobs)) {
        Write-Host Starting Job of $vms[$Global:jobCounter].Name
        $job = Start-Job -Name $vms[$Global:jobCounter].Name -ScriptBlock $task -ArgumentList $vms[$Global:jobCounter], $wrkdir 
        $Global:jobs += $job
        $Global:jobCounter++
    }
    elseif (($jobCounter) -eq $Global:totalJobs) {
        Write-Host All Jobs Initiated
        # wait for all jobs to be completed
        $currentJobs = $Global:jobs | where State -EQ 'Running' | where HasMoreData -EQ $true
        # Check for per-job stop flag files
        $stopFlagFiles = Get-ChildItem -Path $wrkdir -Filter 'StopJob_*.txt' -File -ErrorAction SilentlyContinue
        foreach ($file in $stopFlagFiles) {
            if ($file.BaseName -match '^StopJob_(\d+)$') {
                $jobId = $Matches[1]
                $job = Get-Job -Id $jobId -ErrorAction SilentlyContinue
                if ($job -and $job.State -eq 'Running') {
                    Stop-Job -Id $jobId -Force
                    Write-Host "Job $jobId stopped via flag file $($file.Name)."
                }
                Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        if (($currentJobs | Measure-Object).Count -gt 0) {
            Write-Host 'Currently Waiting for all jobs to be finished'
            Write-Host Currently Running Jobs are:
            $currentJobs | Select-Object Id, Name, State, @{n = 'Timer(Sec)'; e = { [Math]::Floor(((Get-Date) - $_.PSBeginTime).TotalSeconds) } } | Format-Table -AutoSize -RepeatHeader
            ###
            Save-JobLog -JobList $currentJobs -TargetFolder $folderName
            ###
            #<>
            $proc = Show-FailingJobsWindow -JobList $Global:jobs -TargetFolder $folderName -FailFlagRef ([ref]$failFlag) -ShowFailedJob $showFailedJob -CurrentProc $proc
            #<>
            Start-Sleep -Seconds 30
        }
        else {
            ###
            Save-JobLog -JobList $Global:jobs -TargetFolder $folderName
            ###
            Start-Transcript -Path "./$folderName/allJobs.txt" -Force
            $Global:jobs | ForEach-Object {
                ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                $jobDetails = (Receive-Job -Job $_ -Keep) 
                Write-Host $jobDetails
            }
            Stop-Transcript
            $failedJobs = $Global:jobs | where State -EQ 'Failed' | where HasMoreData -EQ $true
            #<>
            $proc = Show-FailingJobsWindow -JobList $Global:jobs -TargetFolder $folderName -FailFlagRef ([ref]$failFlag) -ShowFailedJob $showFailedJob -CurrentProc $proc
            if ($null -ne $proc) {
                Stop-Process -Id $proc.Id
                # $failedJobs | Select-Object Name, State, Id, @{n = 'Reason'; e = { ($_.ChildJobs.JobStateInfo.Reason -join ';') -replace '^System.Management.Automation.RemoteException:', '' } }, @{n = 'Output'; e = { Get-Content (Join-Path $folderName "$($_.Name).txt") } } | Out-GridView -Title 'Failed Jobs'
            }
            #<>
            if (($failedJobs | Measure-Object).Count -gt 0) {
                Write-Host Following Jobs Failed. Please Check
                Write-Host ($failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
                $failedJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
                $failedJobs | Select-Object Id, Name, State | Export-Csv -Path "./$folderName/listOfFailedJobs.csv" -NoTypeInformation -Force
                'jobName,Error' | Out-File -FilePath "./$folderName/failedJobError.csv" -Force
                $failedJobs | ForEach-Object {
                    ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                    $errorDetails = $_.ChildJobs.JobStateInfo.Reason -join ';'
                    Write-Host $errorDetails
                    $_.Name + ',' + $errorDetails | Out-File -FilePath "./$folderName/failedJobError.csv" -Append -Force 
                }
                Write-Host ($failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
            }
            Write-Host All Jobs Finished
            Write-Host ($failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
            break
        }

    }
    else {
        $currentJobs = $Global:jobs | where State -EQ 'Running' | where HasMoreData -EQ $true
        # Check for per-job stop flag files
        $stopFlagFiles = Get-ChildItem -Path $wrkdir -Filter 'StopJob_*.txt' -File -ErrorAction SilentlyContinue
        foreach ($file in $stopFlagFiles) {
            if ($file.BaseName -match '^StopJob_(\d+)$') {
                $jobId = $Matches[1]
                $job = Get-Job -Id $jobId -ErrorAction SilentlyContinue
                if ($job -and $job.State -eq 'Running') {
                    Stop-Job -Id $jobId -Force
                    Write-Host "Job $jobId stopped via flag file $($file.Name)."
                }
                Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        # Timeout handling for running jobs
        $currentJobs | ForEach-Object {
            $elapsed = (Get-Date) - $_.PSBeginTime
            if ($elapsed.TotalSeconds -gt $jobTimeoutSec) {
                Stop-Job -Id $_.Id -Force
                $timeoutInfo = [PSCustomObject]@{ Name = $_.Name; Id = $_.Id; State = $_.State; Reason = 'Timeout after 30 minutes' }
                $timeoutInfo | Export-Csv -Path $timeoutLog -NoTypeInformation -Append -Force
                Write-Host "Job $($_.Name) timed out and was stopped."
            }
        }
        ###
        Save-JobLog -JobList $currentJobs -TargetFolder $folderName
        ###
        #<>
        $proc = Show-FailingJobsWindow -JobList $Global:jobs -TargetFolder $folderName -FailFlagRef ([ref]$failFlag) -ShowFailedJob $showFailedJob -CurrentProc $proc
        #<>
        $currentJobs | Select-Object Id, Name, State, @{n = 'Timer(Sec)'; e = { [Math]::Floor(((Get-Date) - $_.PSBeginTime).TotalSeconds) } } | Format-Table -AutoSize -RepeatHeader
        Start-Sleep -Seconds 30
    }
}
$outputXmlDir = Join-Path $folderName 'outputXml'
Get-ChildItem -Path (Join-Path $outputXmlDir '*.xml') | Select-Object BaseName, @{Name = 'ErrMsg'; Exp = { Get-Item -Path $_.fullName | Import-Clixml | where writeErrorStream -EQ $true | Select-Object -ExpandProperty TargetObject } } | Export-Csv -NoTypeInformation -Force -Path (Join-Path $outputXmlDir 'error.csv')

### Cleaning ###
$vars = @('vms', 'vm', 'maxJobCount', 'maxJob', 'currentJobs', 'failedJobs', 'jobCounter', 'folderName', 'CurrentlyRunningJobs', 'jobs', 'totalJobs', 'optionToAdd', 'retry')
$vars | Where-Object { Test-Path "Variable:\$($_)" } | ForEach-Object { Clear-Variable $_ }
Clear-Variable 'vars'

### Processing ###
Write-Output 'Processing'

Set-Location (Join-Path $wrkdir $reportTempDir) 
$VmOutputs = Import-Csv -Path (Get-ChildItem -Path . -Filter *.csv) #-Header @('VMName','commandStatus','ServerName','OS','Patches','Uptime')

$report = foreach ($output in $VmOutputs) {
    if ($output.CommandStatus -eq 'Success') {
        $outputDetails = $output.CommandOutput -split '#'
        [PSCustomObject]@{
            'VMName'        = $output.VM 
            'HostName'      = $outputDetails[0]
            'OS'            = $outputDetails[1]
            'Patches'       = $outputDetails[2]
            'Uptime'        = $outputDetails[3]
            'CommandStatus' = $output.CommandStatus
            'CommandOutput' = $output.CommandOutput
        }
    }
    else {
        [PSCustomObject]@{
            'VMName'        = $output.VM 
            'HostName'      = 'Error'
            'OS'            = 'Error'
            'Patches'       = 'Error'
            'Uptime'        = 'Error'
            'CommandStatus' = $output.CommandStatus
            'CommandOutput' = $output.CommandOutput
        }
    }
}

$reportPath = Join-Path $wrkdir "Report-$(Get-Date -Format 'dd-MM-yyyy-hh-mm').csv"
$report | Export-Csv -NoTypeInformation -Force -Path $reportPath

Write-Output "Report Generated at: $($reportPath)"
# Combine all status logs into a central summary
$summaryFile = Join-Path $folderName 'jobSummary.csv'
'Name,Id,State,Reason' | Out-File -FilePath $summaryFile -Encoding utf8 -Force
$logFiles = @($timeoutLog, $skipLog, $stopLog)
foreach ($lf in $logFiles) {
    if (Test-Path $lf) { Import-Csv $lf | Export-Csv -Path $summaryFile -NoTypeInformation -Append -Force }
}
# Add completed and failed jobs from final report
if (Test-Path $reportPath) {
    $finalReport = Import-Csv $reportPath
    foreach ($r in $finalReport) {
        $state = if ($r.CommandStatus -eq 'Success') { 'Completed' } else { 'Failed' }
        $reason = if ($state -eq 'Failed') { $r.CommandOutput } else { '' }
        [PSCustomObject]@{ Name = $r.VMName; Id = ''; State = $state; Reason = $reason } |
        Export-Csv -Path $summaryFile -NoTypeInformation -Append -Force
    }
}