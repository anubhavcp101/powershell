#
$maxJob = 11 # Number of Jobs needs to run at a time
$htPatch = @{
    'Windows Server 2012' = @();
    'Windows Server 2016' = @();
    'Windows Server 2019' = @();
    'Windows Server 2022' = @();
    'Windows Server 2025' = @();
    'Windows 10'          = @();
    'Windows 11'          = @()
}
$reportPath = '' # It should be a location of a directory, not a file
#

$subs = @()
$rgs = @()
$filePath = "..\..\grouped\vms.csv" # location of input csv file 
$tag = @{'Key' = 'Value' }


Connect-AzAccount
$fPaths = @()
$fPaths += $filePath
if ($subs.Count -gt 0) {

    $allSubs = Get-AzSubscription
    $names = $allSubs | Where-Object { $_.Name -in $subs } | Select-Object -ExpandProperty Id
    $ids = $allSubs.Id | Where-Object { $_ -in $subs }

    $fsubs = $names + $ids 
    $qString = "`"" + ( $fsubs -join "`",`"" ) + "`""

    try {
        $ErrorActionPreference = 'Stop'
        $subsQuery = @"
Resources 
| where subscriptionid in~ ($($qString)) 
| project Name=name, ResourceGroup=resourcegroup, Subscription = subscriptionId
"@
        $data = Search-AzGraph -Query $subsQuery -UseTenantScope -First 1000
        $fPath = Join-Path ($PWD.Path) "input-subs-$(Get-Date -Format 'dd-MM-yyyy-hh-mm').csv"
        $data.Data | Export-Csv -NoTypeInformation -Force -Path $fPath
        $fPaths += $fPaths

    }
    catch {
        Write-Output 'An Error Occurred'
        Write-Output $PSItem.tostring()
        Write-Output $PSItem.ScriptStackTrace
    }
}
if ($rgs.Count -gt 0) {
    try {
        $ErrorActionPreference = 'Stop'
        $qString = "`"" + ( $rgs -join "`",`"" ) + "`""
        $rgQuery = @"
Resources | where resourcegroup in~ ($($qString)) | project Name=name, ResourceGroup=resourcegroup, Subscription=subscriptionId
"@
        $data = Search-AzGraph -Query $rgQuery -UseTenantScope -First 1000
        $fPath = Join-Path ($PWD.Path) "input-rg-$(Get-Date -Format 'dd-MM-yyyy-hh-mm').csv"
        $data.Data | Export-Csv -NoTypeInformation -Force -Path $fPath
        $fPaths += $fPath

    }
    catch {
        Write-Output 'An Error Occurred'
        Write-Output $PSItem.tostring()
        Write-Output $PSItem.ScriptStackTrace
    }
}
$tagOp = "=~" # other options are: ==, like 
if ($tag.Count -gt 0) {
    try {
        $ErrorActionPreference = 'Stop'
        $tagStrings = @()
        foreach ($key in $tag.Keys) {
            $tagStrings += "tags[`'$($key)`'] $($tagOp) `'$($tag["$($key)"])`'"
        }
        $joinTagStr = $tagStrings -join " and "
        $tagQuery = @"
Resources | where $($joinTagStr) | project Name=name,ResourceGroup=resourcegroup,Subscription=subscriptionId
"@
        $data = Search-AzGraph -Query $tagQuery -UseTenantScope -First 1000
        $fPath = Join-Path ($PWD.Path) "input-tag-$(Get-Date -Format 'dd-MM-yyyy-hh-mm').csv"
        $fPaths += $fPaths
        $data.Data | Export-Csv -NoTypeInformation -Force -Path $fPath
    }
    catch {
        Write-Output 'An Error Occurred'
        Write-Output $PSItem.tostring()
        Write-Output $PSItem.ScriptStackTrace
    }

}

$fullLists = Import-Csv $fPaths | Sort-Object -Unique #-Property {$_}
$resPath = Join-Path ($PWD.Path) "res-$(Get-Date -Format 'dd-MM-yyyy-hh-mm').csv"
$fullLists | Export-Csv -NoTypeInformation -Force -Path $resPath
# $filePath = $fPaths # or $filePath = $resPath


$task = {
    param(
        $vm,
        $wrkdir)
    #
    Write-Host "Starting Job for" $vm.Name 
    
    # $ErrorActionPreference = "Stop"
    Set-Location $wrkdir -ErrorAction Stop
    #

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
                if ($attempt -lt $vm.retry) {# retry+1
                    Write-Output "Retry will be attempted after a delay of $(30*$attempt) seconds"
                    Start-Sleep -Seconds (30 * $attempt)
                }
                elseif ($attempt -eq $vm.retry) {# retry+1
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

$reportPaths = @($reportPath, $PSScriptRoot, ($PWD.Path), $HOME, $env:TEMP, 'C:\Temp','C:\')
$wrkdir = $reportPaths | Where-Object { ($_ -ne '') -and ($_ -ne $null) -and (Test-Path -Path $_ -PathType Container) } | Select-Object -First 1

Set-Location $wrkdir
# $vms = Import-Csv -Path $filePath #-Header "Name"

$reportTempDir = "Report-Temp-$(Get-Date -Format 'dd-MM-yyyy-hh-mm')"
New-Item -Path (Join-Path $wrkdir $reportTempDir) -ItemType Directory -Force -ErrorAction Stop | Out-Null
$optionToAdd.Add("reportTempDir", (Join-Path $wrkdir $reportTempDir))

$fps = @($filePath,$fPaths) | Where-Object {$_.GetType().ToString() -eq 'System.Object[]'} | Select-Object -First 1
$validateFiles = $fps | Where-Object { (Get-Content $_)[0] -notmatch '(.+,{1})?Name,ResourceGroup,Subscription(,.+)?$' } 
if (($validateFiles | Measure-Object).Count -gt 0) {
    Write-Output "Please check headers in the files:"
    Write-Output ($validateFiles -join ",`n")
    exit
}
if ($filePath.GetType().ToString() -eq 'System.String') {
    if (((Get-Content $filePath)[0] -notmatch '(.+,{1})?Name,ResourceGroup,Subscription(,.+)?$')) {
        Write-Output "Please check headers of the file: $($filePath)"
        exit
    }
}

try {
    $vms = Import-Csv -Path $filePath #-Header "Name" # Update path 
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
$Global:jobs | Remove-Job -Force
$vars = @('vms', 'vm', 'maxJobCount', 'maxJob', 'currentJobs', 'failedJobs', 'jobCounter', 'folderName', 'CurrentlyRunningJobs', 'jobs', 'totalJobs', 'optionToAdd', 'retry')
$vars | Where-Object { Test-Path "Variable:\$($_)" } | ForEach-Object { Clear-Variable $_ }
Clear-Variable 'vars'

### Processing ###
Write-Output "Processing"

Set-Location (Join-Path $wrkdir $reportTempDir) 
$VmResponses = Import-Csv -Path (Get-ChildItem -Path . -Filter *.csv)
$responseObj = @()
foreach ( $response in $VmResponses) {
    if ($response.CommandStatus -eq 'Success') {
        $comm = $response.CommandOutput -split "&"
        if (($comm[2] -eq '') -or ($comm[2] -eq 'Nothing Installed')) {
            $comm[2] = 'Nothing Installed'
        }
        $responseObj += [PSCustomObject]@{
            'VmName'        = $response.VM;
            'HostName'      = $comm[0];
            'OS'            = $comm[1];
            'Patches'       = $comm[2];
            'Uptime'        = $comm[3];
            'CommandStatus' = $response.CommandStatus;
            'Output'        = $response.CommandOutput
        }
    }
    else {
        $responseObj += [PSCustomObject]@{
            'VmName'        = $response.VM;
            'HostName'      = 'Error';
            'OS'            = 'Error';
            'Patches'       = 'Error';
            'Uptime'        = 'Error';
            'CommandStatus' = $response.CommandStatus;
            'Output'        = $response.CommandOutput
        }
    }
}


foreach ($server in $responseObj) {
    if ($server.CommandStatus -eq 'Success') {
        $key = $htPatch.Keys | Where-Object { $server.OS -like "*$($_)*" } | Select-Object -First 1
        $server | Add-Member -NotePropertyName 'OsKey' -NotePropertyValue $key
        if (($server.Patches -ne '') -or ($null -ne $server.Patches) -or ($server.Patches -ne 'Nothing Installed')) {
            $patches = $server.Patches -split ","
            $Missing = (Compare-Object -ReferenceObject $htPatch[$server.OsKey] -DifferenceObject $patches)
            $Missing = ($Missing | Where-Object { $_.SideIndicator -eq '<=' }).InputObject -join ","
            if ($Missing -eq '') {
                $Missing = 'None'
            } 
            $server | Add-Member -NotePropertyName 'Missing' -NotePropertyValue $Missing
        }
        else {
            $server | Add-Member -NotePropertyName 'Missing' -NotePropertyValue ($htPatch[$server.OsKey] -join ',')
        }

    }
    else {
        $server | Add-Member -NotePropertyName 'OsKey' -NotePropertyValue 'Error'
        $server | Add-Member -NotePropertyName 'Missing' -NotePropertyValue 'Error'
    }

}

$responseObj | Export-Csv -NoTypeInformation -Force -Path "Combined-$(Get-Date -Format 'dd-MM-yyyy-hh-mm').csv"

$reportPath = Join-Path $wrkdir "Report-$(Get-Date -Format 'dd-MM-yyyy-hh-mm').csv"
$responseObj | Select-Object -Property VmName, OS, Patches, Missing, Uptime, CommandStatus, CommandOutput | Export-Csv -NoTypeInformation -Force -Path $reportPath

Write-Output "Report Generated at: $($reportPath)"
