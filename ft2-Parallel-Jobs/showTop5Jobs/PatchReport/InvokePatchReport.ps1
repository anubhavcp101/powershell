function Invoke-PatchReport {
    <#
.SYNOPSIS
    Generates a patch report for a collection of VM objects.
.DESCRIPTION
    This function processes a collection of Azure VM objects to generate comprehensive patch reports. 
    It executes parallel jobs to collect hotfix installation information from Windows VMs, 
    including system uptime and operating system details. Each VM is validated for running status 
    and Windows OS compatibility before execution. The function implements retry logic with 
    exponential backoff for transient failures and generates detailed CSV reports and XML logs 
    for troubleshooting. Output is organized in timestamped folders with separate tracking for 
    timeout, skipped, and stopped jobs.
.PARAMETER VmList
    An array of VM objects. Each object must contain at least the properties 
    `Name`, `ResourceGroup`, `Subscription`, and any custom options required by 
    the report.
.PARAMETER MaxJob
    Maximum number of parallel jobs to run. Defaults to 11.
.PARAMETER ReportPath
    Destination directory for the final reports. If omitted, the function searches 
    for the first available writable directory from: provided path, script root, 
    current location, user home, temp folder, or C:\Temp.
.PARAMETER jobTimeOutSec
    Timeout in seconds for each job. Default is 1800 (30 minutes).
.PARAMETER runName
    Identifier for the run; used for naming output folders and log files. If not 
    specified, defaults to "Run-<dd-MM-yyyyThh-mm>" format.
.EXAMPLE
    $vms = Import-Csv 'vms.csv'
    Invoke-PatchReport -VmList $vms -MaxJob 20 -runName 'Run-2023-09-01'
.EXAMPLE
    $vms = Get-AzVM | Select-Object Name, ResourceGroup, Location
    Invoke-PatchReport -VmList $vms -ReportPath 'C:\Reports' -jobTimeOutSec 3600
.NOTES
    Requirements:
        - Azure PowerShell modules (Az.Accounts, Az.Compute)
        - Active Azure context with appropriate permissions
    
    Limitations:
        - Only processes Windows VMs (Linux VMs are skipped)
        - VMs must be running; stopped VMs are skipped
        - Requires VM Agent to be operational
    
    Behavior:
        - Each failed command is retried up to 3 times with progressive delays (30s, 60s, 90s)
        - Job outputs are saved as both text files and XML for debugging
        - Global variables are used for job tracking: $Global:jobs, $Global:jobCounter, $Global:totalJobs
    
    Output Structure:
        - <ReportPath>/<runName>/              - Main run folder
        - <ReportPath>/<runName>/outputXml/    - XML job outputs
        - <ReportPath>/<runName>/timeoutJobs.csv - Jobs that timed out
        - <ReportPath>/<runName>/skippedJobs.csv  - Jobs that were skipped
        - <ReportPath>/<runName>/stoppedJobs.csv  - Jobs that were stopped
.LINK
    https://docs.microsoft.com/powershell/module/az.compute
    https://docs.microsoft.com/powershell/module/az.accounts
#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [Object[]]$VmList,
        [int]$MaxJob = 11,
        [ValidateScript({ if ([string]::IsNullOrWhiteSpace($_)) { $true } else { Test-Path -Path $_ -PathType Container } })]
        [string]$ReportPath = '',
        [ValidateRange(1800, 7200)]
        [int]$jobTimeOutSec = 1800,
        [string]$runName = ""
    )


    $task = {
        $commandStatus = ''
        $commandOutput = ''
        $hotfixBlock = {
            $serverName = hostname
            $month = (Get-Date).Month
            $year = (Get-Date).Year
            $cmHotfix = Get-HotFix | Where-Object { $_.InstalledOn -gt (Get-Date -Day 3 -Month $month -Year $year) -and $_.InstalledOn -lt ((Get-Date -Day 1 -Month $month -Year $year).AddMonths(1).AddDays(-1)) }
            $hotfix = $cmHotfix.HotFixID -join ';'
            if ($hotfix -eq '') { $hotfix = 'Nothing Installed' }
            $hostInfo = Get-CimInstance -ClassName Win32_OperatingSystem
            $uptime = ((Get-Date) - ($hostInfo).LastBootUpTime).ToString("%d'days,'%h'hrs,'%m'mins'")
            $osName = $hostInfo.Caption
            $outputs = @($serverName, $osName, $hotfix, $uptime)
            Write-Output ($outputs -join '#')
        }
        $ctx = Set-AzContext -Subscription $subscription.trim() -ErrorAction Stop -Scope Process
        $vmStatus = Get-AzVM -Status -Name $Name.trim() -ResourceGroupName $resourceGroup.trim() -DefaultProfile $ctx -ErrorAction Stop
        if (($vmStatus.Statuses[1].DisplayStatus -ne 'VM running') -or ( -not ($vmStatus.VMAgent)) ) {
            Write-Output "The VM is not running. Please check $($Name.trim())"
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
                        Write-Output "Retry will be attempted after a delay of $(30*$attempt) seconds"
                        Start-Sleep -Seconds (30 * $attempt)
                    }
                    elseif ($attempt -eq $retry) {
                        Write-Output "Retried $($attempt) times but it failed. Please check $($Name)"
                    }
                }
            } while ($attempt -lt $retry)
        }
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

    $retry = 3
    $optionsToAdd = @{}
    $optionsToAdd.Add('retry', $retry)

    $initTask = {
        param (
            $tmpVm,
            $workdir
        )
        Set-Location $workdir
        $tmpVm.PSObject.Members | Where-Object { ($_.MemberType -eq 'NoteProperty') -and ($_.Name -ne 'Name') } | ForEach-Object { New-Variable -Name "$($_.Name)".Replace(' ', '') -Value $_.Value } 
        $tmpVm.PSObject.Members | Where-Object { ($_.MemberType -eq 'NoteProperty') -and ($_.Name -eq 'Name') } | ForEach-Object { New-Variable -Name "$($_.Name)".Replace(' ', '') -Value "$(($_.Value -split "#")[0])" }
        Write-Output 'Starting Job for' $tmpVm.Name
    }

    $task = [scriptblock]::Create($initTask.ToString() + "`n" + $task.ToString())

    $Global:jobs = @()
    $Global:jobCounter = 0
    $Global:totalJobs = 0
    $Global:jobErrors = ''
    $Global:errorFile = @()


    $columns = $VmList[0].PSObject.Members | Where-Object { $_.MemberType -eq 'NoteProperty' } | Select-Object -ExpandProperty Name
    if ( $columns -contains 'Name' ) {
        # Check for duplicate VM names and append  a unique identifier to duplicate names to ensure each job has a unique name
        if (($VmList.Count) -ne ( $VmList.Name | Select-Object -Unique).Count) {
            Write-Warning "Duplicate VM names found in the input list."
            $nameCounts = @{} 
            foreach ($instance in $VmList) {
                $currentName = $instance.Name
                if ($nameCounts.ContainsKey($currentName)) {
                    $nameCounts[$currentName]++
                    $instance.Name = "$($currentName)#$($nameCounts[$currentName])"
                }
                else {
                    $nameCounts[$currentName] = 0
                }
            } 
            foreach ( $key in (($nameCounts).Keys) ) {
                if ( $nameCounts[$key] -gt 0) {
                    Write-Warning "Duplicate VM found: $($key) - Count: $($nameCounts[$key])"
                }
            }
        }
    }
    else {
        # what if Name column is missing, look for another column and replicate it to generate Name column
        $alternativeColumnFound = $false
        foreach ($column in $columns) {
            if (($VmList.Count) -eq (($VmList | Select-Object -ExpandProperty $column | Select-Object -Unique).Count)) {
                $VmList | ForEach-Object { $_ | Add-Member -NotePropertyName 'Name' -NotePropertyValue ($_ | Select-Object -ExpandProperty $column) }
                $alternativeColumnFound = $true
                break
            }
        }
        # Generate alternate column 
        if ( -not $alternativeColumnFound) {
            for ($i = 0; $i -lt $VmList.Count; $i++) {
                $VmList[$i] | Add-Member -NotePropertyName 'Name' -NotePropertyValue "$(($VmList[$i] | Select-Object -ExpandProperty $columns[0]))#$($i)"
            }
        }
    }

    $maxJobCount = @($MaxJob, 30) | Where-Object { ($_ -ne '') -and ($_ -ne $null) -and ($_.GetType().ToString() -eq 'System.Int32') } | Select-Object -First 1
    $jobTimeoutSec = $jobTimeOutSec

    $reportPaths = @($ReportPath, $PSScriptRoot, (Get-Location).Path, $HOME, $env:TEMP, 'C:\Temp')
    $wrkdir = $reportPaths | Where-Object { ($_ -ne '') -and ($_ -ne $null) -and (Test-Path -Path $_ -PathType Container) } | Select-Object -First 1
    Set-Location $wrkdir

    $reportTempDir = "Report-Temp-$(Get-Date -Format 'dd-MM-yyyy-hh-mm')"
    New-Item -Path (Join-Path $wrkdir $reportTempDir) -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $optionsToAdd.Add('reportTempDir', (Join-Path $wrkdir $reportTempDir))

    $vms = $VmList

    if ((Test-Path Variable:\optionsToAdd) -and $optionsToAdd.Count -gt 0) {
        foreach ($instance in $vms) {
            foreach ($key in $optionsToAdd.Keys) {
                $instance | Add-Member -NotePropertyName "$($key)".Replace(' ', '') -NotePropertyValue $optionsToAdd[$key]
            }
        }
    }

    if (($null -eq $runName) -or ($runName -eq "") ) {
        $folderName = "Run-$(Get-Date -Format 'dd-MM-yyyyThh-mm')"
    }
    else {
        $folderName = $runName
    }

    $runFolder = Join-Path -Path $wrkdir -ChildPath $folderName
    $outputXmlFolder = Join-Path -Path $runFolder -ChildPath 'outputXml'
    New-Item -Path $runFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    New-Item -Path $outputXmlFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    
    $timeoutLog = Join-Path $runFolder 'timeoutJobs.csv'
    $skipLog = Join-Path $runFolder 'skippedJobs.csv'
    $stopLog = Join-Path $runFolder 'stoppedJobs.csv'

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
        $failedJobs = $JobList | Where-Object { ($_.State -eq 'Failed') -and ($_.HasMoreData -eq $true) }
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

    function Invoke-StopFlagProcessing {
        param (
            [Parameter(Mandatory = $true)]
            [string]$WorkingDirectory,

            [Parameter(Mandatory = $true)]
            [string]$StopLogPath
        )

        $stopFlagFiles = Get-ChildItem -Path $WorkingDirectory -Filter 'StopJob_*.txt' -File -ErrorAction SilentlyContinue
        foreach ($file in $stopFlagFiles) {
            if ($file.BaseName -match '^StopJob_(\\d+)$') {
                $jobId = $Matches[1]
                $job = Get-Job -Id $jobId -ErrorAction SilentlyContinue
                if ($job -and $job.State -eq 'Running') {
                    Stop-Job -Id $jobId
                    Write-Output "Job $jobId stopped via flag file $($file.Name)."
                    [PSCustomObject]@{Name = $job.Name; Id = $job.Id; State = $job.State; Reason = "Stopped using per-job flag" } |
                    Export-Csv -Path $StopLogPath -NoTypeInformation -Append -Force
                }
                Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }

    function Invoke-JobTimeoutCheck {
        param (
            [Parameter(Mandatory = $true)]
            [object[]]$RunningJobs,

            [Parameter(Mandatory = $true)]
            [int]$TimeoutSeconds,

            [Parameter(Mandatory = $true)]
            [string]$TimeoutLogPath
        )

        $RunningJobs | ForEach-Object {
            $elapsed = (Get-Date) - $_.PSBeginTime
            if ($elapsed.TotalSeconds -gt $TimeoutSeconds) {
                Stop-Job -Id $_.Id
                $timeoutInfo = [PSCustomObject]@{
                    Name   = $_.Name
                    Id     = $_.Id
                    State  = $_.State
                    Reason = 'Job Timed Out'
                }
                $timeoutInfo | Export-Csv -Path $TimeoutLogPath -NoTypeInformation -Append -Force
                Write-Output "Job $($_.Name) timed out and was stopped."
            }
        }
    }

    function Update-Progress {
        param(
            [string]$Status,               # short description of current step
            [int]   $Percent = $null       # 0‑100 - if omitted PowerShell keeps the last value
        )
        $activity = 'Running Patch Report'
        if ($null -ne $Percent) {
            Write-Progress -Activity $activity -Status $Status -PercentComplete $Percent
        }
        else {
            Write-Progress -Activity $activity -Status $Status
        }
    }

    $showFailedJob = $true
    $failFlag = 2
    $proc = $null 

    $totalVMs = $VmList.Count
    $started = 0
    Update-Progress -Status "Initialising ($totalVMs VMs)" -Percent 0

    $Global:totalJobs = ($vms | Measure-Object).Count
    $vms | ForEach-Object {
        if ($jobCounter -lt $maxJobCount) {
            $started++
            $percent = [Math]::Round(($started / $totalVMs) * 100)
            Update-Progress -Status "Launching jobs ($started / $totalVMs)" -Percent $percent
            Write-Output "Starting Job of $_.Name"
            $job = Start-Job -Name $_.Name -ScriptBlock $task -ArgumentList $_, $wrkdir
            $Global:jobs += $job
            $Global:jobCounter++
        }
    }

    while ($true) {
        if (Test-Path (Join-Path $wrkdir 'Break_Loop')) {
            Write-Output 'Break_Loop flag detected, exiting job monitoring loop.'
            $currentRunning = $Global:jobs | Where-Object { $_.State -eq 'Running' }
            foreach ($j in $currentRunning) {
                [PSCustomObject]@{ Name = $j.Name; Id = $j.Id; State = 'Skipped'; Reason = 'Break_Loop flag' } |
                Export-Csv -Path $skipLog -NoTypeInformation -Append -Force
            }
            Remove-Item -Path (Join-Path $wrkdir 'Break_Loop') -Force -ErrorAction SilentlyContinue
            break
        }

        $currentlyRunningJobs = $Global:jobs | Where-Object { ($_.State -eq 'Running') -and ($_.HasMoreData -eq $true) }
        if ((($currentlyRunningJobs | Measure-Object).Count -lt $maxJobCount) -and (($jobCounter) -lt $Global:totalJobs)) {
            $started++
            $percent = [Math]::Round(($started / $totalVMs) * 100)
            Update-Progress -Status "Launching jobs ($started / $totalVMs)" -Percent $percent
            Write-Output "Starting Job of $vms[$Global:jobCounter].Name"
            $job = Start-Job -Name $vms[$Global:jobCounter].Name -ScriptBlock $task -ArgumentList $vms[$Global:jobCounter], $wrkdir
            $Global:jobs += $job
            $Global:jobCounter++
        }
        elseif (($jobCounter) -eq $Global:totalJobs) {
            Write-Output 'All Jobs Initiated'
            $currentJobs = $Global:jobs | Where-Object { ($_.State -eq 'Running') -and ($_.HasMoreData -eq $true) }
            Invoke-StopFlagProcessing -WorkingDirectory $wrkdir -StopLogPath $stopLog
            if (($currentJobs | Measure-Object).Count -gt 0) {
                Write-Output "Currently Waiting for all jobs to be finished"
                Update-Progress -Status "Waiting - all jobs started, monitoring"
                Write-Output "Currently Running Jobs are:"
                $currentJobs | Select-Object Id, Name, State, @{n = 'Timer(Sec)'; e = { [Math]::Floor(((Get-Date) - $_.PSBeginTime).TotalSeconds) } } | Format-Table -AutoSize -RepeatHeader
                Invoke-JobTimeoutCheck -RunningJobs $currentJobs -TimeoutSeconds $jobTimeoutSec -TimeoutLogPath $timeoutLog
                Save-JobLog -JobList $currentJobs -TargetFolder $folderName
                $proc = Show-FailingJobsWindow -JobList $Global:jobs -TargetFolder $folderName -FailFlagRef ([ref]$failFlag) -ShowFailedJob $showFailedJob -CurrentProc $proc
                Start-Sleep -Seconds 30
            }
            else {
                # All work done - final 100 % progress
                Update-Progress -Status "All jobs finished - aggregating results" -Percent 100
                Save-JobLog -JobList $Global:jobs -TargetFolder $folderName
                Start-Transcript -Path "./$folderName/allJobs.txt" -Force
                $Global:jobs | ForEach-Object {
                    ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                    $jobDetails = (Receive-Job -Job $_ -Keep)
                    Write-Output $jobDetails
                }
                Stop-Transcript
                $failedJobs = $Global:jobs | Where-Object { ($_.State -eq 'Failed') -and ($_.HasMoreData -eq $true) }
                $proc = Show-FailingJobsWindow -JobList $Global:jobs -TargetFolder $folderName -FailFlagRef ([ref]$failFlag) -ShowFailedJob $showFailedJob -CurrentProc $proc
                if ($null -ne $proc) { Stop-Process -Id $proc.Id }
                if (($failedJobs | Measure-Object).Count -gt 0) {
                    Write-Output "Following Jobs Failed. Please Check"
                    Write-Output "$(($failedJobs | Measure-Object).Count) jobs failed out of $Global:totalJobs jobs"
                    $failedJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
                    $failedJobs | Select-Object Id, Name, State | Export-Csv -Path (Join-Path $folderName 'listOfFailedJobs.csv') -NoTypeInformation -Force
                    'Name,Id,State,Reason' | Out-File -FilePath (Join-Path $folderName 'failedJobError.csv') -Force
                    $failedJobs | ForEach-Object {
                        ($_ | Select-Object Id, Name, State | Format-Table -AutoSize -HideTableHeaders)
                        $errorDetails = $_.ChildJobs.JobStateInfo.Reason -join ';'
                        Write-Output $errorDetails
                        "$(($_.Name)),$(($_.Id)),$(($_.State)),$(($errorDetails -replace '^System.Management.Automation.RemoteException:', '' ))" | Out-File -FilePath (Join-Path $folderName 'failedJobError.csv') -Append -Force
                    }
                }
                Write-Output 'All Jobs Finished'
                Write-Output "$(($failedJobs | Measure-Object).Count) jobs failed out of $Global:totalJobs jobs"
                break
            }
        }
        else {
            $currentJobs = $Global:jobs | Where-Object { (($_.State -eq 'Running') -and ($_.HasMoreData -eq $true)) }
            Invoke-StopFlagProcessing -WorkingDirectory $wrkdir -StopLogPath $stopLog
            Invoke-JobTimeoutCheck -RunningJobs $currentJobs -TimeoutSeconds $jobTimeoutSec -TimeoutLogPath $timeoutLog
            Save-JobLog -JobList $currentJobs -TargetFolder $folderName
            $proc = Show-FailingJobsWindow -JobList $Global:jobs -TargetFolder $folderName -FailFlagRef ([ref]$failFlag) -ShowFailedJob $showFailedJob -CurrentProc $proc
            $currentJobs | Select-Object Id, Name, State, @{n = 'Timer(Sec)'; e = { [Math]::Floor(((Get-Date) - $_.PSBeginTime).TotalSeconds) } } | Format-Table -AutoSize -RepeatHeader
            Start-Sleep -Seconds 30
        }
    }

    $outputXmlDir = Join-Path $folderName 'outputXml'
    Get-ChildItem -Path (Join-Path $outputXmlDir '*.xml') | Select-Object BaseName, @{Name = 'ErrMsg'; Exp = { Get-Item -Path $_.fullName | Import-Clixml | Where-Object { $_.writeErrorStream -eq $true } | Select-Object -ExpandProperty TargetObject } } | Export-Csv -NoTypeInformation -Force -Path (Join-Path $outputXmlDir 'error.csv')

    Write-Output 'Processing'
    Set-Location (Join-Path $wrkdir $reportTempDir)
    $csvFiles = Get-ChildItem -Path . -Filter *.csv
    $fileIdx = 0
    $VmOutputs = @()
    foreach ($csv in $csvFiles) {
        $fileIdx++
        $percent = [Math]::Round(($fileIdx / $csvFiles.Count) * 100)
        Update-Progress -Status "Aggregating $($csv.Name) ($fileIdx / $($csvFiles.Count))" -Percent $percent
        $VmOutputs += Import-Csv -Path $csv.FullName
    }

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
    if (Test-Path $reportPath) {
        $finalReport = Import-Csv $reportPath
        foreach ($r in $finalReport) {
            $state = if ($r.CommandStatus -eq 'Success') { 'Completed' } else { 'Failed' }
            $reason = if ($state -eq 'Failed') { $r.CommandOutput } else { '' }
            [PSCustomObject]@{ Name = $r.VMName; Id = ''; State = $state; Reason = $reason } |
            Export-Csv -Path $summaryFile -NoTypeInformation -Append -Force
        }
    }
}




$filePath = "vms.csv"
$vmList = Import-Csv $filePath
$runName = "Run-$(Get-Date -Format 'dd-MM-yyyyThh-mm')"
Set-Location $PSScriptRoot
Invoke-PatchReport -VmList ($vmList) -MaxJob 30 -runName $runName
if ((Test-Path (Join-Path $runName 'failedJobError.csv')) -or (Test-Path (Join-Path $runName 'notStartedJobs.csv'))) {
    $retryTable = @{}
    # Build a hash table of VM name => array of VM objects (preserves duplicates)
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
        if (Test-Path $file) {
            Import-Csv $file | Where-Object { $retryTable.ContainsKey($_.Name) } | ForEach-Object { $retryTable[$_.Name] }
        }
    }

    if ($retryInputs) {
        Write-Output 'Do you want to retry with following inputs:'
        $retryInputs | Format-Table
        $resp = Read-Host
        if ($resp -in @('y', "Y")) {
            Invoke-PatchReport -VmList $retryInputs -MaxJob 20 -runName "Retry-$runName"
        }
    }
}

Write-Output "Following Jobs failed because either of timeout, stopped or skipped"
@(
    (Join-Path $runName 'timeoutJobs.csv'),
    (Join-Path $runName 'skippedJobs.csv'),
    (Join-Path $runName 'stoppedJobs.csv'),
    (Join-Path "Retry-$runName" 'timeoutJobs.csv'),
    (Join-Path "Retry-$runName" 'stoppedJobs.csv'),
    (Join-Path "Retry-$runName" 'skippedJobs.csv'),
    (Join-Path "Retry-$runName" 'failedJobError.csv')
) | Where-Object { Test-Path $_ } | ForEach-Object {
    Import-Csv $_ | Format-Table -AutoSize -Property Name, Id, State, Reason
}

