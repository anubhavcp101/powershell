#
$filePath = "..\grouped\vms.csv"
$maxJobCount = 11
$task = {
    param(
        $vm,
        $wrkdir)
    #
    Write-Host "Starting Job for" $vm.Name 
    try {
        $ErrorActionPreference = "Stop"
        # Use $PSDefaultParameterValues['command:parameter'] = $value to pass value to common parameters
        Set-Location $wrkdir 

        Start-Sleep -Seconds 11
        Write-Error "This is an error to be printed"
        Get-Item "C:\NonExistentFile2.txt" -ErrorAction Stop
    }
    catch {
        throw "An Error Occurred: $($PSItem.Exception.Message)"
    }
    Write-Host "Finished Job for" $vm.Name
}
#
$optionsToAdd = @{
    'OptA' = 'ValA';
    'OptB' = 'ValB';
    'OptC' = 'ValC'
}


$Global:jobs = @()
$Global:jobCounter = 0
$Global:totalJobs = 0
$Global:jobErrors = ""
$Global:errorFile = @()
$wrkdir = $PSScriptRoot
Set-Location $PSScriptRoot
# $vms = Import-Csv -Path $filePath #-Header "Name"

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
        Write-Output "Failed to add additional options"
        Write-Output $PSItem.tostring()
    }
}

$folderName = "Run-$(Get-Date -Format 'dd-MM-yyyyThh-mm')"
New-Item -Path "$($wrkdir)\$($folderName)" -ItemType Directory -Force -ErrorAction Stop | Out-Null
New-Item -Path "$($wrkdir)\$($folderName)\outputXml" -ItemType Directory -Force -ErrorAction Stop | Out-Null


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
            Write-Host "Currently Running Jobs are:"
            $currentJobs | Select-Object Id, Name, State | Format-Table -AutoSize -RepeatHeader
            ###
            $currentJobs | ForEach-Object {
                Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath "$($folderName)\$($_.Name).txt" -ErrorVariable outFileError
                Receive-Job -Keep -Job $_ *>&1 | Export-Clixml -Depth 3 -Force -Path "$($folderName)\outputXml\$($_.Name).xml" 
                if ($outFileError) {
                    Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath "$($folderName)\$($_.Name)-$(Get-Date -Format 'dd-MM-yyyyThh-mm-ss').txt"
                }
            }
            ###
            Start-Sleep -Seconds 30
        }
        else {
            ###
            $Global:jobs | ForEach-Object {
                Receive-Job -Keep -Job $_ *>&1 | Out-File -Force -FilePath "$($folderName)\$($_.Name).txt" -ErrorVariable outFileError
                Receive-Job -Keep -Job $_ *>&1 | Export-Clixml -Depth 3 -Force -Path "$($folderName)\outputXml\$($_.Name).xml" 
                if ($outFileError) {
                    Receive-Job -Keep -Job $_ *>&1 | Out-String | Out-File -Force -FilePath "$($folderName)\$($_.Name)-$(Get-Date -Format 'dd-MM-yyyyThh-mm-ss').txt"
                }
            }
            ###
            Start-Transcript -Path "./$folderName/allJobs.txt" -Force
            $Global:jobs | ForEach-Object {
                ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                $jobDetails = (Receive-Job -Job $_ -Keep *>&1) 
                Write-Host $jobDetails
            }
            Stop-Transcript
            $failedJobs = $Global:jobs | where State -EQ "Failed" | where HasMoreData -EQ $true
            if (($failedJobs | Measure-Object).Count -gt 0) {
                Write-Host Following Jobs Failed. Please Check
                Write-Host ($failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
                $failedJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
                $failedJobs | Select-Object Id, Name, State | Export-Csv -Path "./$folderName/listOfFailedJobs.csv" -NoTypeInformation -Force
                # Start-Transcript -Path "./failedJobs.txt" -Force
                "jobName,Error" | Out-File -FilePath "./$folderName/failedJobError.csv" -Force
                $failedJobs | ForEach-Object {
                    ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                    # $errorDetails = (Receive-Job -Job $_ -Keep) 
                    $errorDetails = $_.ChildJobs.JobStateInfo.Reason -join ";"
                    Write-Host $errorDetails
                    $_.Name + "," + $errorDetails | Out-File -FilePath "./$folderName/failedJobError.csv" -Append -Force 
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
        Start-Sleep -Seconds 30
    }
}
Get-ChildItem -Path "$($folderName)\outputXml\*.xml" | Select BaseName, @{Name = "ErrMsg"; Exp = { Get-Item -Path $_.fullName | Import-Clixml | Where writeErrorStream -eq $true | Select -ExpandProperty TargetObject } } | Export-Csv -NoTypeInformation -Force -Path "$($folderName)\outputXml\error.csv"