#
$filePath = 'vms.csv'
$jobCount = 11
$execute = {
    Write-Output "The name is $($Name)"
    Write-Output "The resource group is $($resourceGroup)"
    Write-Output "The subscription is $($subscription)"

    Start-Sleep -Seconds 11

    Write-Output "The retry is set to $($retry) and folder to $($reportTempDir)"
    Get-Item 'C:\NonExistentFile.txt' -ErrorAction Stop
    #
    Write-Output 'Running from Inside'
}

function Invoke-PatchReport {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [Object[]]$VmList,
        [int]$MaxJob = 11,
        [scriptblock]$execute = {},
        [ValidateScript({ if ([string]::IsNullOrWhiteSpace($_)) { $true } else { Test-Path -Path $_ -PathType Container } })]
        [string]$workPath = '',
        [ValidateRange(1800, 7200)]
        [int]$jobTimeOutSec = 1800,
        [string]$runName = '',
        [object]$limit = ''
    )

    begin {
        $accumulatedVmList = [System.Collections.Generic.List[object]]::new()

        $task = {
            $commandStatus = ''
            $commandOutput = ''
            $runBlock = $Using:execute
            # Write-Output $runBlock.ToString()
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
                        $commandOutput = Invoke-AzVMRunCommand -VMName $Name.trim() -ResourceGroupName $resourceGroup.trim() -CommandId 'RunPowerShellScript' -ScriptString $runBlock.ToString() -DefaultProfile $ctx -ErrorAction Stop
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

        $requiredColumns = @( 'subscription', 'resourceGroup', 'Name' ) 

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
            $tmpVm.PSObject.Members | Where-Object { ($_.MemberType -eq 'NoteProperty') -and ($_.Name -eq 'Name') } | ForEach-Object { New-Variable -Name "$($_.Name)".Replace(' ', '') -Value "$(($_.Value -split '#')[0])" }
            Write-Output 'Starting Job for' $tmpVm.Name
        }

        $task = [scriptblock]::Create($initTask.ToString() + "`n" + $task.ToString())

        $Global:jobs = [System.Collections.Generic.List[object]]::new()
        $Global:jobCounter = 0
        $Global:totalJobs = 0

        $progressBar = $true
        $cleanUp = $false
        $processing = $true
    }

    process {
        foreach ($vm in @($VmList)) {
            if ($null -ne $vm) {
                $accumulatedVmList.Add($vm)
            }
        }
    }

    end {
        if ($accumulatedVmList.Count -eq 0) {
            Write-Warning 'No VM objects were supplied.'
            return
        }

        $vms = @($accumulatedVmList)
        $totalVMs = $vms.Count

        $columns = $accumulatedVmList[0].PSObject.Members | Where-Object { $_.MemberType -eq 'NoteProperty' } | Select-Object -ExpandProperty Name

        $missing = Compare-Object -ReferenceObject $requiredColumns -DifferenceObject $columns | Where-Object { ($_.SideIndicator -eq '<=') } 
        if ( $missing ) { $missing | ForEach-Object { Write-Warning "Missing column: $($_.InputObject)" }; return 1 }  

        if ( $columns -contains 'Name' ) {
            # Check for duplicate VM names and append  a unique identifier to duplicate names to ensure each job has a unique name
            if (($accumulatedVmList.Count) -ne ( $accumulatedVmList.Name | Select-Object -Unique).Count) {
                Write-Warning 'Duplicate VM names found in the input list.'
                $nameCounts = @{} 
                foreach ($instance in $accumulatedVmList) {
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
                if (($accumulatedVmList.Count) -eq (($accumulatedVmList | Select-Object -ExpandProperty $column | Select-Object -Unique).Count)) {
                    $accumulatedVmList | ForEach-Object { $_ | Add-Member -NotePropertyName 'Name' -NotePropertyValue ($_ | Select-Object -ExpandProperty $column) }
                    $alternativeColumnFound = $true
                    break
                }
            }
            # Generate alternate column 
            if ( -not $alternativeColumnFound) {
                for ($i = 0; $i -lt $accumulatedVmList.Count; $i++) {
                    $accumulatedVmList[$i] | Add-Member -NotePropertyName 'Name' -NotePropertyValue "$(($accumulatedVmList[$i] | Select-Object -ExpandProperty $columns[0]))#$($i)"
                }
            }
        }

        function Update-Column {
            param (
                [Parameter(Mandatory = $true)]
                [ValidateNotNullOrEmpty()]
                [Object[]]$inputs,
                [ValidateNotNullOrEmpty()]
                [string]$column = 'Name'
            )

            $columnExists = $inputs[0].PSObject.Properties.Name -contains $column
            $columns = $inputs[0].PSObject.Members | Where-Object { $_.MemberType -eq 'NoteProperty' } | Select-Object -ExpandProperty Name
            # 
            if ( $columnExists) {
                if ($inputs.Count -eq ($inputs.$column | Select-Object -Unique).Count) {
                    return $inputs
                }
                else {
                    Write-Warning "Column $column has duplicate values"
                    $colCount = @{}
                    foreach ( $instance in $inputs) {
                        $value = $instance.$column
                        if ($colCount.ContainsKey($value)) {
                            $colCount[$value]++
                            $instance | Add-Member -NotePropertyName $column -NotePropertyValue "$($value)#$($colCount[$value])" -Force
                        }
                        else {
                            $colCount[$value] = 0
                        }
                    }
                    return $inputs
                }
            }
            else {
                Write-Warning "Column '$column' not found in input. Available columns: $columns"
                $foundOtherColumn = $false
                foreach ( $col in $columns) {
                    if (($inputs.Count) -eq ($inputs.$col | Select-Object -Unique).Count) {
                        $foundOtherColumn = $true
                        Write-Warning "Found unique column: $col"
                        $inputs | ForEach-Object { $_ | Add-Member -NotePropertyName $column -NotePropertyValue ( $_.$col) }
                        return $inputs
                    }
                }

                if (-not $foundOtherColumn) {
                    Write-Warning "No unique column found in input. Available columns: $columns"
                    for ($i = 0; $i -lt $inputs.Count; $i++) {
                        $inputs[$i] | Add-Member -NotePropertyName $column -NotePropertyValue "$(($inputs[$i].($columns[0])))#$i"
                    } 
                    return $inputs
                }
            }
        }

        # implement limit to try on few VMs first.
        function Limit-Input {
            param(
                [Parameter(Mandatory = $true)]
                [Object[]]$inputs,
                [Parameter(Mandatory = $true)]
                [ValidateNotNullOrEmpty()]
                [Object]$limit,
                [ValidateNotNullOrEmpty()]
                [string]$col = 'Name'
            ) 

            if (($limit.GetType().ToString() -ne 'System.Int32') -and ($col -notin ($inputs[0].PSObject.Members | Where-Object { ($_.MemberType -eq 'NoteProperty') } | Select-Object -ExpandProperty Name ) ) ) {
                Write-Warning 'Please provide a valid column name.'
                return 
            }

            if (($limit -is [int]) ) {
                if ($limit -gt $inputs.Count) {
                    Write-Warning "Limit ($limit) is greater than the number of inputs ($($inputs.Count))."
                    return $inputs
                }
                else {
                    return $inputs | Select-Object -First $limit
                } 

            }
            elseif (($limit -is [string]) -and ($limit -ne '')) {
                $matchedInputs = $inputs | Where-Object { ($_.$col) -match $limit }
                if ($matchedInputs) {
                    return $matchedInputs
                }
                else {
                    return 
                }
                
            }
            elseif (($limit -is [array])) {
                $returnInput = foreach ($item in $limit) { 
                    $inputs.Where({ ($_.$col) -match $item }) 
                }
                if ($returnInput) { 
                    return $returnInput
                }
                else {
                    return 
                }
            }
            else {
                Write-Warning 'Please provide a valid limit.'
                return 
            }
        } 


        # $limit = ''
        if (($null -ne $limit) -and ($limit -ne '')) {
            $vms = Limit-Input -inputs $vms -limit $limit
            if ( $vms -and ($vms.Count -gt 0)) {
                Write-Output 'Continue to try on below VMs?'
                $vms | Format-Table -AutoSize -Wrap
                $continue = Read-Host 'Continue (y/n)'
                if ($continue -in @('n', 'N')) {
                    return
                }
            }
            else {
                Write-Warning 'Please check the limit.'
                return
            }
        }


        $maxJobCount = @($MaxJob, 30) | Where-Object { ($_ -ne '') -and ($_ -ne $null) -and ($_.GetType().ToString() -eq 'System.Int32') } | Select-Object -First 1
        $jobTimeoutSec = $jobTimeOutSec
        

        $workPaths = @($workPath, $PSScriptRoot, (Get-Location).Path, $HOME, $env:TEMP, 'C:\Temp')
        $wrkdir = $workPaths | Where-Object { ($_ -ne '') -and ($null -ne $_) -and (Test-Path -Path $_ -PathType Container) } | Select-Object -First 1
        Set-Location $wrkdir

        if ($processing) {
            # Report Temp Directory
            $reportTempDir = "Report-Temp-$(Get-Date -Format 'dd-MM-yyyy-hh-mm')"
            New-Item -Path (Join-Path $wrkdir $reportTempDir) -ItemType Directory -Force -ErrorAction Stop | Out-Null
            $optionsToAdd.Add('reportTempDir', (Join-Path $wrkdir $reportTempDir))
        }

        if ((Test-Path Variable:\optionsToAdd) -and ($optionsToAdd.Count -gt 0)) {
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
                $failedJobs | Format-Table Name, State, Id, @{n = 'Reason'; e = { ($_.ChildJobs.JobStateInfo.Reason -join ';') -replace '^System.Management.Automation.RemoteException:', '' } } -Wrap | Out-File -FilePath (Join-Path $TargetFolder 'failingJobs.txt') #"./$TargetFolder/failingJobs.txt"
                $FailFlagRef.Value++
            }
            if ($FailFlagRef.Value -eq 3) {
                $fPath = Join-Path $TargetFolder 'failingJobs.txt' #"./$TargetFolder/failingJobs.txt"
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
                        [PSCustomObject]@{Name = $job.Name; Id = $job.Id; State = $job.State; Reason = 'Stopped using per-job flag' } |
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
                [string]$Status,
                [int]   $Percent = $null
            )
            if ($progressBar) {
                $activity = 'Running Patch Report'
                if ($null -ne $Percent) {
                    Write-Progress -Activity $activity -Status $Status -PercentComplete $Percent
                }
                else {
                    Write-Progress -Activity $activity -Status $Status
                }
            } 

        }

        function Invoke-BreakLoopProcessing {
            param (
                [string]$WorkingDirectory,
                [Object[]]$processJobs,
                [string]$logPath

            )
            if (Test-Path (Join-Path $WorkingDirectory 'Break_Loop')) {
                Write-Output 'Break_Loop flag detected, exiting job monitoring loop.'
                foreach ($j in $processJobs) {
                    [PSCustomObject]@{ Name = $j.Name; Id = $j.Id; State = 'Skipped'; Reason = 'Break_Loop flag' } |
                    Export-Csv -Path $logPath -NoTypeInformation -Append -Force
                }
                Remove-Item -Path (Join-Path $WorkingDirectory 'Break_Loop') -Force -ErrorAction SilentlyContinue
                return $true
            }
            else {
                return $false
            }
            
        }

        function Invoke-FailedJobsProcessing {
            param (
                [object[]]$processJobs,
                [string]$runFolder
            )
            $processJobs | Select-Object Id, Name, State | Export-Csv -Path (Join-Path $runFolder 'listOfFailedJobs.csv') -NoTypeInformation -Force
            $processJobs | ForEach-Object {
                $_ | Select-Object Id, Name, State | Format-Table -AutoSize -HideTableHeaders
                $errorDetails = $_.ChildJobs.JobStateInfo.Reason -join ';'
                [PSCustomObject]@{
                    'Id'     = $_.Id
                    'Name'   = $_.Name
                    'State'  = $_.State
                    'Reason' = $errorDetails -replace '^System.Management.Automation.RemoteException:', ''
                } | Export-Csv -Path (Join-Path $runFolder 'failedJobError.csv') -NoTypeInformation -Append -Force
            }
        }

        function Get-JobTranscript {
            param (
                $inputJobs,
                $folder
            )
            
            Start-Transcript -Path (Join-Path $folder 'allJobs.txt') -Force
            $inputJobs | ForEach-Object {
                ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                (Receive-Job -Job $_ -Keep)
            }
            Stop-Transcript
        }


        $showFailedJob = $true
        $failFlag = 2
        $proc = $null 

        $started = 0
        Update-Progress -Status "Initialising ($totalVMs VMs)" -Percent 0

        $Global:totalJobs = ($vms | Measure-Object).Count
        $vms | ForEach-Object {
            if ($Global:jobCounter -lt $maxJobCount) {
                $started++
                $percent = [Math]::Round(($started / $totalVMs) * 100)
                Update-Progress -Status "Launching jobs ($started / $totalVMs)" -Percent $percent
                Write-Output "Starting Job of $($_.Name)"
                $job = Start-Job -Name $_.Name -ScriptBlock $task -ArgumentList $_, $wrkdir
                $Global:jobs.Add($job)
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
            if ((($currentlyRunningJobs | Measure-Object).Count -lt $maxJobCount) -and (($Global:jobCounter) -lt $Global:totalJobs)) {
                $started++
                $percent = [Math]::Round(($started / $totalVMs) * 100)
                Update-Progress -Status "Launching jobs ($started / $totalVMs)" -Percent $percent
                Write-Output "Starting Job of $($vms[$Global:jobCounter].Name)"
                $job = Start-Job -Name $vms[$Global:jobCounter].Name -ScriptBlock $task -ArgumentList $vms[$Global:jobCounter], $wrkdir
                $Global:jobs.Add($job)
                $Global:jobCounter++
            }
            elseif (($Global:jobCounter) -eq $Global:totalJobs) {
                Write-Output 'All Jobs Initiated'
                $currentJobs = $Global:jobs | Where-Object { ($_.State -eq 'Running') -and ($_.HasMoreData -eq $true) }
                Invoke-StopFlagProcessing -WorkingDirectory $wrkdir -StopLogPath $stopLog
                if (($currentJobs | Measure-Object).Count -gt 0) {
                    Write-Output 'Currently Waiting for all jobs to be finished'
                    Update-Progress -Status 'Waiting - all jobs started, monitoring'
                    Write-Output 'Currently Running Jobs are:'
                    $currentJobs | Select-Object Id, Name, State, @{n = 'Timer(Sec)'; e = { [Math]::Floor(((Get-Date) - $_.PSBeginTime).TotalSeconds) } } | Format-Table -AutoSize -RepeatHeader
                    Invoke-JobTimeoutCheck -RunningJobs $currentJobs -TimeoutSeconds $jobTimeoutSec -TimeoutLogPath $timeoutLog
                    Save-JobLog -JobList $currentJobs -TargetFolder $folderName
                    $proc = Show-FailingJobsWindow -JobList $Global:jobs -TargetFolder $folderName -FailFlagRef ([ref]$failFlag) -ShowFailedJob $showFailedJob -CurrentProc $proc
                    Start-Sleep -Seconds 30
                }
                else {
                    # All work done - final 100 % progress
                    Update-Progress -Status 'All jobs finished - aggregating results' -Percent 100
                    Save-JobLog -JobList $Global:jobs -TargetFolder $folderName
                    Get-JobTranscript -InputJobs $Global:jobs -Folder $folderName
                    $failedJobs = $Global:jobs | Where-Object { ($_.State -eq 'Failed') -and ($_.HasMoreData -eq $true) }
                    $proc = Show-FailingJobsWindow -JobList $Global:jobs -TargetFolder $folderName -FailFlagRef ([ref]$failFlag) -ShowFailedJob $showFailedJob -CurrentProc $proc
                    if (($null -ne $proc) -and (Get-Process -Id $proc.Id)) { Stop-Process -Id $proc.Id }
                    if (($failedJobs | Measure-Object).Count -gt 0) {
                        Write-Output 'Following Jobs Failed. Please Check'
                        Write-Output "$(($failedJobs | Measure-Object).Count) jobs failed out of $Global:totalJobs jobs"
                        $failedJobs | Select-Object Id, Name, State | Format-Table -AutoSize -RepeatHeader
                        Invoke-FailedJobsProcessing -processJobs $failedJobs -runFolder $folderName
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
                Update-Progress -Status "Waiting for running jobs ($started / $totalVMs)" -Percent $percent
                Start-Sleep -Seconds 30
            }
        }

        $outputXmlDir = Join-Path $folderName 'outputXml'
        Get-ChildItem -Path (Join-Path $outputXmlDir '*.xml') | Select-Object BaseName, @{Name = 'ErrMsg'; Exp = { Get-Item -Path $_.fullName | Import-Clixml | Where-Object { $_.writeErrorStream -eq $true } | Select-Object -ExpandProperty TargetObject } } | Export-Csv -NoTypeInformation -Force -Path (Join-Path $outputXmlDir 'error.csv')

        if ($processing) {
            Write-Output 'Processing'
            Push-Location (Join-Path $wrkdir $reportTempDir)
            # Get-Service | Select-Object -First 5 | ForEach-Object { $_ | Export-Csv -NoTypeInformation -Force -Path "$($_.Name).csv" }
            $csvFiles = Get-ChildItem -Path . -Filter *.csv
            $fileIdx = 0
            $VmOutputs = [System.Collections.Generic.List[object]]::new()
            foreach ($csv in $csvFiles) {
                $fileIdx++
                $percent = [Math]::Round(($fileIdx / $csvFiles.Count) * 100)
                Update-Progress -Status "Aggregating $($csv.Name) ($fileIdx / $($csvFiles.Count))" -Percent $percent
                $VmOutputs.AddRange([object[]](Import-Csv -Path $csv.FullName))
            }

            $reportLocation = Join-Path $wrkdir "Report-$(Get-Date -Format 'dd-MM-yyyy-hh-mm').csv"
            $VmOutputs | Export-Csv -NoTypeInformation -Force -Path $reportLocation
            Write-Output "Report Generated at: $($reportLocation)"
            Pop-Location
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
        if (Test-Path $reportLocation) {
            $finalReport = Import-Csv $reportLocation
            foreach ($r in $finalReport) {
                $state = if ($r.CommandStatus -eq 'Success') { 'Completed' } else { 'Failed' }
                $reason = if ($state -eq 'Failed') { $r.CommandOutput } else { '' }
                [PSCustomObject]@{ Name = $r.VMName; Id = ''; State = $state; Reason = $reason } |
                Export-Csv -Path $summaryFile -NoTypeInformation -Append -Force
            }
        }

        # Clean up global variables and jobs
        if ($cleanUp) {
            $Global:jobs | Remove-Job -Force
            @('totalJobs', 'jobCounter', 'jobs') | ForEach-Object { Remove-Variable -Name $_ -Scope Global }
        }

    }
}

$workDirs = @($PSScriptRoot, (Get-Location).Path, $HOME, $env:TEMP, 'C:\Temp')
$workdir = $workDirs | Where-Object { ($_ -ne '') -and ($null -ne $_) -and (Test-Path -Path $_ -PathType Container) } | Select-Object -First 1
Set-Location $workdir

# $filePath = 'vms.csv'
$vmList = Import-Csv $filePath
$runName = "Run-$(Get-Date -Format 'dd-MM-yyyyThh-mm')"
# Set-Location $PSScriptRoot
# $vmList[0] | Invoke-PatchReport -MaxJob 11 -runName $runName
Invoke-PatchReport -VmList $vmList -MaxJob $jobCount -runName $runName -execute $execute -workPath $workdir
if ((Test-Path (Join-Path $runName 'failedJobError.csv')) -or (Test-Path (Join-Path $runName 'notStartedJobs.csv'))) {
    $retryTable = @{}
    # Build a hash table of VM name => array of VM objects (preserves duplicates)
    $vmList | Select-Object -Property * -ExcludeProperty retry, reportTempDir | ForEach-Object {
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
        if ($resp -in @('y', 'Y')) {
            Invoke-PatchReport -VmList $retryInputs -MaxJob $jobCount -runName "Retry-$runName" -execute $execute -workPath $workdir
        }
    }
}


