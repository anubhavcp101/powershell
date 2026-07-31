#
$filePath = '..\func4ParallelJob\vms.csv'
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
        $cmHotfix = Get-HotFix | Where-Object { $_.InstalledOn -gt (Get-Date -Day 3 -Month $month -Year $year) -and $_.InstalledOn -lt ((Get-Date -Day 1 -Month $month -year $year).AddMonths(1).AddDays(-1)) }
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
New-Item -Path "$($wrkdir)\$($folderName)" -ItemType Directory -Force | Out-Null
New-Item -Path "$($wrkdir)\$($folderName)\outputXml" -ItemType Directory -Force | Out-Null

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
        if (($currentJobs | Measure-Object).Count -gt 0) {
            Write-Host 'Currently Waiting for all jobs to be finished'
            Write-Host Currently Running Jobs are:
            $currentJobs | Select-Object Id, Name, State, @{n = 'Timer(Sec)'; e = { ((Get-Date) - $_.PSBeginTime).Seconds } } | Format-Table -AutoSize -RepeatHeader
            ###
            $currentJobs | ForEach-Object {
                Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath "$($folderName)\$($_.Name).txt" -ErrorVariable outFileError
                Receive-Job -Keep -Job $_ *>&1 | Export-Clixml -Depth 3 -Force -Path "$($folderName)\outputXml\$($_.Name).xml" 
                if ($outFileError) {
                    Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath "$($folderName)\$($_.Name)-$(Get-Date -Format 'dd-MM-yyyyThh-mm-ss').txt"
                }
            }
            ###
            #<>
            $currentlyFailedJobs = $Global:jobs | where State -EQ 'Failed' | where HasMoreData -EQ $true
            if (($currentlyFailedJobs | Measure-Object).Count -gt 0 ) {
                $currentlyFailedJobs | ft Name, State, Id, @{n = 'Reason'; e = { ($_.ChildJobs.JobStateInfo.Reason -join ';') -replace '^System.Management.Automation.RemoteException:', '' } } -Wrap | Out-File -FilePath "./$folderName/failingJobs.txt"
                $failFlag++
            }
            if ($failFlag -eq 3) {
                
                $fPath = "./$folderName/failingJobs.txt"
                $command = @"
while(`$true) {
Clear-Host
Get-Content `"$fPath`"
Start-Sleep -Seconds 5
}
"@
                #
                $bytes = [System.Text.Encoding]::Unicode.GetBytes($command)
                $encodedCommand = [Convert]::ToBase64String($bytes)
                if ($showFailedJob) {
                    $proc = Start-Process powershell.exe -ArgumentList '-NoExit', '-EncodedCommand', $encodedCommand -PassThru
                }
            }

            #<>
            Start-Sleep -Seconds 30
        }
        else {
            ###
            $Global:jobs | ForEach-Object {
                Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath "$($folderName)\$($_.Name).txt" -ErrorVariable outFileError
                Receive-Job -Keep -Job $_ *>&1 | Export-Clixml -Depth 3 -Force -Path "$($folderName)\outputXml\$($_.Name).xml" 
                if ($outFileError) {
                    Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath "$($folderName)\$($_.Name)-$(Get-Date -Format 'dd-MM-yyyyThh-mm-ss').txt"
                }
            }
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
            if (($failedJobs | Measure-Object).Count -gt 0) {
                $failedJobs | ft Name, State, Id, @{n = 'Reason'; e = { ($_.ChildJobs.JobStateInfo.Reason -join ';') -replace '^System.Management.Automation.RemoteException:', '' } } -Wrap | Out-File -FilePath "./$folderName/failingJobs.txt"
                $failFlag++
            }
            if ($failFlag -eq 3) {
                $fPath = "./$folderName/failingJob.txt"
                $command = @"
while(`$true) {
Clear-Host
Get-Content `"$fPath`"
Start-Sleep -Seconds 5
}
"@
                $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
                if ($showFailedJob) {
                    $proc = Start-Process powershell.exe -ArgumentList '-NoExit', '-EncodedCommand', $encoded -PassThru
                }
            }
            if ($null -ne $proc) {
                Stop-Process -Id $proc.Id
                $failedJobs | Select-Object Name, State, Id, @{n = 'Reason'; e = { ($_.ChildJobs.JobStateInfo.Reason -join ';') -replace '^System.Management.Automation.RemoteException:', '' } }, @{n = 'Output'; e = { Get-Content "$($folderName)\$($_.Name).txt" } } | Out-GridView -Title 'Failed Jobs'
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
        ###
        $currentJobs | ForEach-Object {
            Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath "$($folderName)\$($_.Name).txt" -ErrorVariable outFileError
            Receive-Job -Keep -Job $_ *>&1 | Export-Clixml -Depth 3 -Force -Path "$($folderName)\outputXml\$($_.Name).xml" 
            if ($outFileError) {
                Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath "$($folderName)\$($_.Name)-$(Get-Date -Format 'dd-MM-yyyyThh-mm-ss').txt"
            }
        }
        ###
        #<>
        $currentlyFailedJobs = $Global:jobs | where State -EQ 'Failed' | where HasMoreData -EQ $true
        if (($currentlyFailedJobs | Measure-Object).Count -gt 0 ) {
            $currentlyFailedJobs | ft Name, State, Id, @{n = 'Reason'; e = { ($_.ChildJobs.JobStateInfo.Reason -join ';') -replace '^System.Management.Automation.RemoteException:', '' } } -Wrap | Out-File -FilePath "./$folderName/failingJobs.txt"
            $failFlag++
        }
        if ($failFlag -eq 3) {
            
            $fPath = "./$folderName/failingJobs.txt"
            $command = @"
while(`$true) {
Clear-Host
Get-Content `"$fPath`"
Start-Sleep -Seconds 5
}
"@
            #
            $bytes = [System.Text.Encoding]::Unicode.GetBytes($command)
            $encodedCommand = [Convert]::ToBase64String($bytes)
            if ($showFailedJob) {
                $proc = Start-Process powershell.exe -ArgumentList '-NoExit', '-EncodedCommand', $encodedCommand -PassThru
            }
        }
        #<>
        $currentJobs | Select-Object Id, Name, State, @{n = 'Timer(Sec)'; e = { ((Get-Date) - $_.PSBeginTime).Seconds } } | Format-Table -AutoSize -RepeatHeader
        Start-Sleep -Seconds 30
    }
}
Get-ChildItem -Path "$($folderName)\outputXml\*.xml" | Select-Object BaseName, @{Name = 'ErrMsg'; Exp = { Get-Item -Path $_.fullName | Import-Clixml | where writeErrorStream -EQ $true | Select-Object -ExpandProperty TargetObject } } | Export-Csv -NoTypeInformation -Force -Path "$($folderName)\outputXml\error.csv"

### Cleaning ###
$vars = @('vms', 'vm', 'maxJobCount', 'maxJob', 'currentJobs', 'failedJobs', 'jobCounter', 'folderName', 'CurrentlyRunningJobs', 'jobs', 'totalJobs', 'optionToAdd', 'retry')
$vars | Where-Object { Test-Path "Variable:\$($_)" } | ForEach-Object { Clear-Variable $_ }
Clear-Variable 'vars'

### Processing ###
Write-Output 'Processing'

Set-Location (Join-Path $wrkdir $reportTempDir) 
$VmOutputs = Import-Csv -Path (Get-ChildItem -Path . -Filter *.csv) #-Header @('VMName','commandStatus','ServerName','OS','Patches','Uptime')

$report = foreach($output in $VmOutputs) {
    if ($output.CommandStatus -eq 'Success') {
        $outputDetails = $output.CommandOutput -split "#"
        [PSCustomObject]@{
            "VMName" = $output.VM 
            "HostName" = $outputDetails[0]
            "OS" = $outputDetails[1]
            "Patches" = $outputDetails[2]
            "Uptime" = $outputDetails[3]
            "CommandStatus" = $output.CommandStatus
            "CommandOutput" = $output.CommandOutput
        }
    } else {
        [PSCustomObject]@{
            "VMName" = $output.VM 
            "HostName" = "Error"
            "OS" = "Error"
            "Patches" = "Error"
            "Uptime" = "Error"
            "CommandStatus" = $output.CommandStatus
            "CommandOutput" = $output.CommandOutput
        }
    }
}

$reportPath = Join-Path $wrkdir "Report-$(Get-Date -Format 'dd-MM-yyyy-hh-mm').csv"
$report | Export-Csv -NoTypeInformation -Force -Path $reportPath

Write-Output "Report Generated at: $($reportPath)"