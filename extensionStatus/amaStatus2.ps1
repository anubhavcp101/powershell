#
$filePath = "./vms.csv"
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

        $vmname = $vm.Name.trim()
        $resId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project id") -UseTenantScope).id; write $resId;
        $subsId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project subscriptionId") -UseTenantScope).subscriptionId; write $subsId;
        $currentSubscriptionId = (Get-AzContext).Subscription.Id.ToString()
        #
        if ($currentSubscriptionId -ne $subsId) { Set-AzContext -SubscriptionId $subsId -ErrorAction Stop }
        $resIdCount = ($resId | Measure-Object).Count 
        if ($resIdCount -gt 0 -and $resIdCount -lt 2) {
            $AzVm = Get-AzVM -ResourceId $resId

            if ($AzVm.StorageProfile.OsDisk.OsType -eq "Windows") {
                $extension = Get-AzVMExtension -ResourceGroupName $AzVm.ResourceGroupName -VMName $AzVm.Name -Name "AzureMonitorWindowsAgent" -Status
            } else {
                $extension = Get-AzVMExtension -ResourceGroupName $AzVm.ResourceGroupName -VMName $azvm.Name -Name "AzureMonitorLinuxAgent" -Status
            }
            $outFolderPath = Get-ChildItem -Path . -Directory | Where-Object {$.BaseName -like "Output-*"} | Sort-Object -Property CreationTime -Descending | Select-Object -First 1 | Select-Object -ExpandProperty FullName
            $outputPath = "$($outFolderPath)/$($AzVm.Name)-$(Get-Date -Format 'dd-MM-yyyy-hh-mm').csv"
            "Date,Name,Status,Message" | Out-File -FilePath $outputPath -Append -Force
            "$(Get-Date -Format 'dd-MM-yyyyThh-mm'),$($AzVm.Name),$($extension.Statuses.DisplayStatus),$($extension.Statuses.Message)" | Out-File -FilePath $outputPath -Append -Force


        }
        else {
            Write-Error $vmname Not found
        }


        Start-Sleep -Seconds 11
        Write-Error "This is an error to be printed"
        Get-Item "C:\NonExistentFile2.txt" -ErrorAction Stop
    }
    catch {
        throw "An Error Occurred: $($_.Exception.Message)"
    }
    Write-Host "Finished Job for" $vm.Name
}
#
$Global:jobs = @()
$Global:jobCounter = 0
$Global:totalJobs = 0
$Global:jobErrors = ""
$Global:errorFile = @()
Set-Location $PSScriptRoot
$wrkdir = $PSScriptRoot
$vms = Import-Csv -Path $filePath #-Header "Name"

$outFolderName = "Output-$(Get-Date -Format 'dd-MM-yyyy-hh-mm')"

$newFolder = New-Item -Path . -Name $outFolderName -ItemType Directory -Force | Out-Null
Write-Output "The Output Folder is at : $($newFolder.FullName)"


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
            Write-Host Currently Running Jobs are:
            $currentJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
            Start-Sleep -Seconds 30
        }
        else {
            $failedJobs = $Global:jobs | where State -EQ "Failed" | where HasMoreData -EQ $true
            if (($failedJobs | Measure-Object).Count -gt 0) {
                Write-Host Following Jobs Failed. Please Check
                Write-Host ($failedJobs | Measure-Object).Count jobs failed out of $Global:totalJobs jobs
                $failedJobs | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -RepeatHeader
                $failedJobs | Select-Object Id, Name, State | Export-Csv -Path "./listOfFailedJobs.csv" -NoTypeInformation -Force
                # Start-Transcript -Path "./failedJobs.txt" -Force
                "jobName,Error" | Out-File -FilePath "./failedJobError.csv" -Force
                $failedJobs | ForEach-Object {
                    ($_ | Select-Object Id, Name, State, HasMoreData | Format-Table -AutoSize -HideTableHeaders)
                    # $errorDetails = (Receive-Job -Job $_ -Keep) 
                    $errorDetails = $_.ChildJobs.JobStateInfo.Reason -join ";"
                    Write-Host $errorDetails
                    $_.Name + "," + $errorDetails | Out-File -FilePath "./failedJobError.csv" -Append -Force 
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
        Start-Sleep -Seconds 30
    }
}

Set-Location $newFolder.FullName
$allFiles = Import-Csv -Path (Get-ChildItem -Path ".\*.csv").FullName 
$combinedFile = "00-CombinedFile-$(Get-Date -Format 'dd-MM-yyyy-hh-mm').csv"
Set-Location -Path (Split-Path -Path (Get-Location) -Parent)
$allFiles | Export-Csv -Path ".\$combinedFile" -NoTypeInformation -Force
$finalFile = Get-ChildItem -Path ".\$($combinedFile)"
Write-Output "The Generated File is $($combinedFile)"
Write-Output "It is at $($finalFile.FullName)"
Compress-Archive -Path $newFolder.FullName -DestinationPath ".\$($newFolder.BaseName).zip" -Force