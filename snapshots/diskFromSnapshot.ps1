#
# Here snapshots.csv should have 7 columns for snapshot name, its resource group and its subscription and then its corresponding diskName, diskRG, diskSubscription, and diskEncryptionSetId
$csvFilePath = ''
$workdir = Split-Path $csvFilePath
$snpshots = Import-Csv -Path $csvFilePath
$filePath = "$workdir/diskCreationFromSnapshot-$(Get-Date -Format 'dd-MM-yyyyThh-mm-ss').csv"
"DiskName,DiskRG,DiskSubscription,Msg" | Out-File -FilePath $filePath -Append -Force
#
Set-Location $workdir
$snpshots | ForEach-Object {
    Set-AzContext -Subscription $_.Subscription -ErrorAction Stop
    $snapshot = Get-AzSnapshot -SnapshotName $_.SnapshotName.trim() -ResourceGroupName $_.ResourceGroup.trim()
    #
    $diskConfig = New-AzDiskConfig -SkuName 'Standard_LRS' -CreateOption Copy -SourceResourceId $snapshot.Id

    try {
        Set-AzContext -Subscription $_.diskSubscription.trim() -ErrorAction Stop
        New-AzDisk -Disk $diskConfig -DiskName $_.diskName.trim() -ResourceGroupName $_.diskRG.trim() -DiskEncryptionSetId $_.diskEncryptionSetId.trim()
        "$($_.diskName),$($_.diskRG),$($_.diskSubscription),Success" | Out-File -FilePath $filePath -Append -Force
        Write-Output "Success for $($_.diskName.trim())"
    }
    catch {
        Write-Error "An error occurred during disk creation for $($_.diskName)"
        $errMsg = $_.Exception.Message
        Write-Output $errMsg
        "$($_.diskName),$($_.diskRG),$($_.diskSubscription),Failure,$errMsg" | Out-File -FilePath $filePath -Append -Force
    }
}
