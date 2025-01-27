#
function diskSkuChange {
    param(
        [string]$diskName,
        [string]$newSku 
    )
    $ErrorActionPreference = 'Stop'
    #
    $diskquery = "
    resources
    | where type == ""microsoft.compute/disks""
    | where name like $diskName
    | project id,subscriptionId
    "
    $qres = Search-AzGraph -Query $diskquery -UseTenantScope -First 1000

    if (($qres|Measure-Object).Count -le 0 ) {
        Write-Host Not Found $diskName
    } elseif (($qres|Measure-Object).Count -ge 2) {
        Write-Host Too many disks $diskName
    } else {
        Set-AzContext -SubscriptionId $qres.subscriptionId
        $disk = Get-AzResource -ResourceId $qres.id
        $vm = Get-AzVM -ResourceId $disk.ManagedBy
        Write-Host Stopping the vm: $vm.Name
        Stop-AzVM -Id $vm.Id -Force
        Write-Host Updating Disk: $disk.Name sku to $newSku
        $supportedDiskSku = @('Premium_LRS','StandardSSD_LRS','Standard_LRS')
        $newDiskSku = $supportedDiskSku | Where-Object {$_ -like $newSku}
        if (($newDiskSku|Measure-Object).Count -le 0) {
            Write-Host Requested Sku not Found: $newSku
        } elseif (($newDiskSku|Measure-Object).Count -ge 2 ) {
            Write-Host Too many similar sku: $newSku
        } else {
            $disk.Sku.Name = $newDiskSku
            Update-AzDisk -ResourceGroupName ($disk.ResourceGroupName) -DiskName ($disk.Name) -Disk $disk
        }
        Write-Host Starting the vm: $vm.Name
        Start-AzVM -Id $vm.Id 
    }
}

diskSkuChange -diskName "" -newSku ""