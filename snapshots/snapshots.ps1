#
$vm = ''
$snapshotRegion = ''
$snapshotName = ''
$snapshotRG = ''
$snapshotSubscription = ''
$vmname = $vm.trim()
#
$resId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project id") -UseTenantScope).id; write $resId;
$subsId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project subscriptionId") -UseTenantScope).subscriptionId; write $subsId;
$currentSubscriptionId = (Get-AzContext).Subscription.Id.ToString() 
if ($currentSubscriptionId -ne $subsId) { Set-AzContext -SubscriptionId $subsId -ErrorAction Stop }
#
if ((($resId | Measure-Object).Count -gt 2) -or (($resId | Measure-Object).Count -lt 0)) {
    Write-Output $vmname not found
    exit 
}
Set-Location $PSScriptRoot -ErrorAction Stop
$filePath = "$PSScriptRoot/snapshots-$($vmname)-$(Get-Date -Format 'dd-MM-yyyyThh-mm-ss').csv"
"SnapshotName,ResourceGroup,Subscription,Msg" | Out-File -FilePath $filePath -Append -Force
$azvm = Get-AzVM -ResourceId $resId
$disks = $azvm.StorageProfile.OsDisk + $azvm.StorageProfile.DataDisks
$disks | ForEach-Object {
    $snapshotConfig = New-AzSnapshotConfig -SkuName 'Standard_LRS' -SourceUri $_.ManagedDisk.Id -Location $snapshotRegion -CreateOption Copy
    Set-AzContext -Subscription $snapshotSubscription -ErrorAction Stop
    if ($snapshotName -ne '') {
        try {
            New-AzSnapshot -SnapshotName $snapshotName -ResourceGroupName $snapshotRG -Snapshot $snapshotConfig
            "$($snapshotName),$($snapshotRG),$($snapshotSubscription),Success" | Out-File -FilePath $filePath -Append -Force
            Write-Output "Success for $($snapshotName)"
        }
        catch {
            Write-Error "An error occurred during snapshot creation for $($snapshotName)"
            $errMsg = $_.Exception.Message
            "$($snapshotName),$($snapshotRG),$($snapshotSubscription),Failure,$errMsg" | Out-File -FilePath $filePath -Append -Force
        }
    }
    else {
        try {
            New-AzSnapshot -SnapshotName ("snpsht-$($vm.Name)-$(($_.ManagedDisk.Id -split "/")[-1])") -ResourceGroupName $snapshotRG -Snapshot $snapshotConfig
            "snpsht-$($azvm.Name)-$(($_.ManagedDisk.Id -split "/")[-1]),$($snapshotRG),$($snapshotSubscription),Success" | Out-File -FilePath $filePath -Append -Force
            Write-Output "Success for snpsht-$($azvm.Name)-$(($_.ManagedDisk.Id -split "/")[-1])"
        }
        catch {
            Write-Error "An error occurred during snapshot creation for snpsht-$($azvm.Name)-$(($_.ManagedDisk.Id -split "/")[-1])"
            $errMsg = $_.Exception.Message
            Write-Output $errMsg
            "snpsht-$($azvm.Name)-$(($_.ManagedDisk.Id -split "/")[-1]),$($snapshotRG),$($snapshotSubscription),Failure,$errMsg" | Out-File -FilePath $filePath -Append -Force
        }

    }
}


