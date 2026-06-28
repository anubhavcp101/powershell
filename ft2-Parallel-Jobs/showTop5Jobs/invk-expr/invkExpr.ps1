#
$filePath = '..\..\func4ParallelJob\vms.csv'
$maxJobCount = 11
$task = {
    try {
        $ErrorActionPreference = 'Stop'
        # Use $PSDefaultParameterValues['command:parameter'] = $value to pass value to common parameters
        #
        Write-Output "This is value of Name: $($Name)"
        Write-Output "This is value of subscription: $($subscription)"
        Write-Output "This is value of resourceGroup: $($resourceGroup)"
        Start-Sleep -Seconds 11
        #
        Write-Output "This is the expression"
        Write-Output $expression
        Write-Output "Running the expression"
        Invoke-Expression $expression
        # Write-Error "This is an error to be printed"
        #Get-Item 'C:\NonExistentFile.txt' -ErrorAction Stop
    }
    catch {
        throw "An Error Occurred: $($_.Exception.Message)"
    }
    Write-Output 'Finished Job for' $Name
}
#
$optionsToAdd = @{
    'OptA' = 'ValA';
    'OptB' = 'ValB';
    'OptC' = 'ValC'
}

$expression = {
    Write-Output '<MSG>'
    Write-Output 'This is to run a expression with passing an string outside the script block'
}
$stringToPass = "This is the string being passed"

$optionsToAdd.Add("expression",($expression.ToString() -replace '<MSG>',$stringToPass) )


$initTask = {
    param (
        $tmpVm,
        $workdir
    )
    Set-Location $workdir
    $ErrorActionPreference = 'Stop'

    $tmpVm.PSObject.Members | Where-Object { $_.MemberType -eq 'NoteProperty' } | ForEach-Object { New-Variable -Name "$($_.Name)".Replace(' ', '') -Value $_.Value }

    Write-Output 'Starting Job for' $tmpVm.Name
}

$task = [scriptblock]::Create($initTask.ToString() + "`n" + $task.ToString())


$Global:jobs = @()
$Global:jobCounter = 0
$Global:totalJobs = 0
$Global:jobErrors = ''
$Global:errorFile = @()
$wrkdir = $PSScriptRoot
Set-Location $PSScriptRoot


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