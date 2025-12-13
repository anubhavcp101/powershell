#
$path = "C:\Windows\System32\config\systemprofile\Documents"
Set-Location $path
$folders = Get-ChildItem -Path $path | Where-Object { $_.BaseName -like "20*" }
foreach ($folder in $folders) {
    Compress-Archive -Path $folder.FullName -DestinationPath "$($path)\archive-$($folder.BaseName)-$((Get-Date -Format 'dd-MM-yyyy-hh-mm')).zip"
    Get-ChildItem -Path $path | Where-Object { $_.BaseName -eq $folder.BaseName } | Remove-Item -Recurse
    #
}

$compressTask = {
    $path = "C:\Windows\System32\config\systemprofile\Documents"
    Set-Location $path
    $folders = Get-ChildItem -Path $path | Where-Object { $_.BaseName -like "20*" }
    foreach ($folder in $folders) {
        Compress-Archive -Path $folder.FullName -DestinationPath "$($path)\archive-$($folder.BaseName)-$((Get-Date -Format 'dd-MM-yyyy-hh-mm')).zip"
        Get-ChildItem -Path $path | Where-Object { $_.BaseName -eq $folder.BaseName } | Remove-Item -Recurse
    }
}

# Run once after starts 3 mins  
Register-ScheduledJob -Name "CompressTask-$(Get-Date -Format 'dd-MM-yyyy-hh-mm')" -ScriptBlock $compressTask -Trigger (New-JobTrigger -Once -At ((Get-Date).AddMinutes(3)) ) -RunNow

# Run once but every 12hrs for next 36hrs 
Register-ScheduledJob -Name "CompressTask-$(Get-Date -Format 'dd-MM-yyyy-hh-mm')" -ScriptBlock $compressTask -Trigger (New-JobTrigger -Once -At ((Get-Date).AddMinutes(3)) -RepetitionInterval (New-TimeSpan -Hours 12) -RepetitionDuration (New-TimeSpan -Hours 36) )



