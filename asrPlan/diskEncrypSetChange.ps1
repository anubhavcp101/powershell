#
function diskEncryptionSetChange {
    param (
        [string]$disk,
        [string]$diskEncryptionSet
    )
    $ErrorActionPreference = 'Stop'
    #
    $diskname = $disk
    $diskquery = "
    resources
    | where type == ""microsoft.compute/disks""
    | where name like ""$diskName""
    | project id,subscriptionId
    "

    $diskres = Search-AzGraph -Query $diskquery -UseTenantScope -First 1000

    if (($diskres | Measure-Object).Count -le 0 ) {
        Write-Host Not Found $disk
    }
    elseif (($diskres | Measure-Object).Count -ge 2) {
        Write-Host Too many disks $disk
    } else {
        $diskId = $diskres.id

        $currentSubscriptionId = (Get-AzContext).Subscription.Id.ToString()
        if ($currentSubscriptionId -ne $diskres.subscriptionId) { Set-AzContext -SubscriptionId $qres.subscriptionId -ErrorAction Stop }

        $disk = Get-AzResource -ResourceId $diskId
        $vm = Get-AzVM -ResourceId $disk.ManagedBy -Status

        Write-Output Stopping the vm: $vm.Name
        Stop-AzVM -Id $vm.Id -Force

        $diskEncryptionSetName = $diskEncryptionSet.Replace(' ', '')
        $diskEncryptionSetId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/diskencryptionsets"" | where name like ""$diskEncryptionSetName"" | project id, subscriptionId") -UseTenantScope).id 

        if (($diskEncryptionSetId | Measure-Object).Count -ne 1) {
            Write-Output Please check $diskEncryptionSet Not Found
            return
        }

        Write-Output Updating the disk: $disk.Name
        $disk.Encryption.DiskEncryptionSetId = $diskEncryptionSetId
        Update-AzDisk -ResourceGroupName $disk.ResourceGroupName -DiskName $disk.Name -Disk $disk

        Write-Output Starting the vm: $vm.Name
        Start-AzVM -Id $vm.Id 
    }
}