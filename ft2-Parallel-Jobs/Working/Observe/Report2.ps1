#
$filePath = "..\..\grouped\vms.csv" # location of input csv file 
$maxJob = 11 # Number of Jobs needs to run at a time
$reportPath = '' # It should be a location of a directory, not a file

$task = {
    param(
        #
        $vm,
        $wrkdir)
    Write-Host "Starting Job for" $vm.Name 

    # $ErrorActionPreference = "Stop"
    Set-Location $wrkdir -ErrorAction Stop


    $commandStatus = ''
    $commandOutput = ''

    $ctx = Set-AzContext -Subscription $vm.Subscription.trim() -ErrorAction Stop
    $vmStatus = Get-AzVM -Status -Name $vm.Name.trim() -ResourceGroupName $vm.ResourceGroup.trim() -DefaultProfile $ctx -ErrorAction Stop
    if (($vmStatus.Statuses[1].DisplayStatus -ne 'VM running') -or ( -not ($vmStatus.VMAgent)) ) {
        Write-Output "The VM is not running. Please check $($vm.Name.trim())"
        $commandStatus = 'Failed'
        $commandOutput = 'VM not running'
        
    }
    elseif ($vmStatus.OsName -notlike "*Windows*") {
        Write-Output "Not a windows VM"
        $commandStatus = 'Failed'
        $commandOutput = 'Not a Windows VM'
        
    }
    else {

        $attempt = 0
        do {
            $attempt++
            try {
                $commandOutput = Invoke-AzVMRunCommand -VMName $vm.Name.trim() -ResourceGroupName $vm.ResourceGroup.trim() -CommandId 'RunPowerShellScript' -ScriptPath '' -DefaultProfile $ctx -ErrorAction Stop
                $commandStatus = 'Success'
                break
            }
            catch {
                Write-Output "Attempt $($attempt): An Error Occurred"
                Write-Output $PSItem.tostring()
                Write-Output $PSItem.ScriptStackTrace
                $commandOutput = "Command Failed: $($PSItem.tostring())"
                $commandStatus = 'Failed'
                if ($attempt -lt $vm.retry) { # retry+1
                    Write-Output "Retry will be attempted after a delay of $(30*$attempt) seconds"
                    Start-Sleep -Seconds (30 * $attempt)
                }
                elseif ($attempt -eq $vm.retry) { # retry+1
                    Write-Output "Retried $($attempt) times but it failed. Please check $($vm.Name)"
                }
            }
        } while ($attempt -lt $vm.retry) # retry+1
    }

    $expVM = $null
    if ($commandStatus -eq 'Success') {
        $expVM = [PSCustomObject]@{
            'VM'            = $vm.Name.trim();
            'CommandOutput' = $commandOutput.Value[0].Message.trim();
            'CommandStatus' = $commandStatus
        }
    }
    else {
        $expVM = [PSCustomObject]@{
            'VM'            = $vm.Name.trim();
            'CommandOutput' = $commandOutput;
            'CommandStatus' = $commandStatus
        }
    }

    $expVM | Export-Csv -NoTypeInformation -Path (Join-Path $vm.reportTempDir "$($vm.Name.trim()).csv") -Force -Append
    
    Write-Host "Finished Job for" $vm.Name
}
#
$optionToAdd = @{

}

$retry = 3 # 0 will disabled it.
$optionToAdd.Add('retry', $retry)


$Global:jobs = @()
$Global:jobCounter = 0
$Global:totalJobs = 0
$Global:jobErrors = ""
$Global:errorFile = @()

$maxJobCount = @($maxJob, 30) | Where-Object { ($_ -ne '') -and ($_ -ne $null) -and ($_.GetType().ToString() -eq 'System.Int32') } | Select-Object -First 1

$reportPaths = @($reportPath, $PSScriptRoot, ($PWD.Path), $HOME, $env:TEMP, 'C:\Temp')
$wrkdir = $reportPaths | Where-Object { ($_ -ne '') -and ($_ -ne $null) -and (Test-Path -Path $_ -PathType Container) } | Select-Object -First 1

Set-Location $wrkdir
# $vms = Import-Csv -Path $filePath #-Header "Name"

$reportTempDir = "Report-Temp-$(Get-Date -Format 'dd-MM-yyyy-hh-mm')"
New-Item -Path (Join-Path $wrkdir $reportTempDir) -ItemType Directory -Force -ErrorAction Stop | Out-Null
$optionToAdd.Add("reportTempDir", (Join-Path $wrkdir $reportTempDir))

if (((Get-Content $filePath)[0] -notmatch '(.+,{1})?Name,ResourceGroup,Subscription(,.+)?$')) {
    Write-Output "Please check headers in the csv file"
    exit
}

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

if ( (Test-Path Variable:\optionToAdd) -and ($optionToAdd.Count -gt 0)) {
    try {
        foreach ($instance in $vms) {
            foreach ($key in $optionToAdd.Keys) {
                $instance | Add-Member -NotePropertyName "$($key)".Replace(' ', '') -NotePropertyValue $optionToAdd[$key]
            }
        }
    }
    catch {
        Write-Output "Failed to add additional options"
        Write-Output $PSItem.tostring()
    }
}



$folderName = "Run-$(Get-Date -Format 'dd-MM-yyyyThh-mm')"
New-Item -Path "$(Join-Path $wrkdir $folderName)" -ItemType Directory -Force -ErrorAction Stop | Out-Null
New-Item -Path "$(Join-Path $wrkdir $folderName)\outputXml" -ItemType Directory -Force -ErrorAction Stop | Out-Null


$Global:totalJobs = ($vms | Measure-Object).Count
$vms | ForEach-Object {
    if ( $jobCounter -lt $maxJobCount) {
        Write-Host "Starting Job for $($_.Name)"
        $job = Start-Job -Name $_.Name -ScriptBlock $task -ArgumentList $_, $wrkdir
        $Global:jobs += $job
        $Global:jobCounter++
    } 
}

while ($true) {
    $currentlyRunningJobs = $Global:jobs | where State -EQ "Running" | where HasMoreData -EQ $true
    #Write-Host Current Job is #$currentlyRunningJobs
    if ((($currentlyRunningJobs | Measure-Object).Count -lt $maxJobCount) -and (($jobCounter) -lt $Global:totalJobs)) {
        Write-Host "Starting Job for $($vms[$Global:jobCounter].Name)"
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

### Cleaning ###
$vars = @('vms','vm','maxJobCount','maxJob','currentJobs','failedJobs','jobCounter','folderName','CurrentlyRunningJobs','jobs','totalJobs','optionToAdd','retry')
$vars | Where-Object { Test-Path "Variable:\$($_)"} | ForEach-Object { Clear-Variable $_}
Clear-Variable 'vars'

### Processing ###
Write-Output "Processing"

Set-Location (Join-Path $wrkdir $reportTempDir) 
$VmOutputs = Import-Csv -Path (Get-ChildItem -Path . -Filter *.csv)

$reportPath = Join-Path $wrkdir "Report-$(Get-Date -Format 'dd-MM-yyyy-hh-mm').csv"
$VmOutputs | Export-Csv -NoTypeInformation -Force -Path $reportPath

Write-Output "Report Generated at: $($reportPath)"
