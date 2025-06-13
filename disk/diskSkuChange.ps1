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
    | where name like ""$diskName""
    | project id,subscriptionId
    "
    $qres = Search-AzGraph -Query $diskquery -UseTenantScope -First 1000

    if (($qres | Measure-Object).Count -le 0 ) {
        Write-Host Not Found $diskName
    }
    elseif (($qres | Measure-Object).Count -ge 2) {
        Write-Host Too many disks $diskName
    }
    else {
        $currentSubscriptionId = (Get-AzContext).Subscription.Id.ToString()
        if ($currentSubscriptionId -ne $qres.subscriptionId) { Set-AzContext -SubscriptionId $qres.subscriptionId -ErrorAction Stop }        
        $disk = Get-AzResource -ResourceId $qres.id
        $vm = Get-AzVM -ResourceId $disk.ManagedBy
        Write-Host Stopping the vm: $vm.Name
        Stop-AzVM -Id $vm.Id -Force
        Write-Host Updating Disk: $disk.Name sku to $newSku
        $supportedDiskSku = @('Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS')
        $newDiskSku = $supportedDiskSku | Where-Object { $_ -like $newSku }
        if (($newDiskSku | Measure-Object).Count -le 0) {
            Write-Host Requested Sku not Found: $newSku
        }
        elseif (($newDiskSku | Measure-Object).Count -ge 2 ) {
            Write-Host Too many similar sku: $newSku
        }
        else {
            $disk.Sku.Name = $newDiskSku
            Update-AzDisk -ResourceGroupName ($disk.ResourceGroupName) -DiskName ($disk.Name) -Disk $disk
        }
        Write-Host Starting the vm: $vm.Name
        Start-AzVM -Id $vm.Id 
    }
}

diskSkuChange -diskName "" -newSku ""

function startVmAfterDiskChange {
    param (
        [string]$csvFilePath
    )

    $disks = Import-Csv -Path $csvFilePath 
    $disks | ForEach-Object {
        $ErrorActionPreference = 'Stop'
        #
        $diskquery = "
    resources
    | where type == ""microsoft.compute/disks""
    | where name like ""$diskName""
    | project id,subscriptionId
    "
        $qres = Search-AzGraph -Query $diskquery -UseTenantScope -First 1000

        if (($qres | Measure-Object).Count -le 0 ) {
            Write-Host Not Found $diskName
        }
        elseif (($qres | Measure-Object).Count -ge 2) {
            Write-Host Too many disks $diskName
        }
        else {
            # Set-AzContext -SubscriptionId $qres.subscriptionId -ErrorAction Stop
            $currentSubscriptionId = (Get-AzContext).Subscription.Id.ToString()
            if ($currentSubscriptionId -ne $qres.subscriptionId) { Set-AzContext -SubscriptionId $qres.subscriptionId -ErrorAction Stop } 
            $disk = Get-AzResource -ResourceId $qres.id -ErrorAction Stop
            # $vm = Get-AzVM -ResourceId $disk.ManagedBy
            $vmCollect = @()
            $vmStat = Get-AzVM -ResourceId $disk.ManagedBy -Status
            if ($vmStat.Name -in $vmCollect) {
                Write-Output $vmStat.Name: Already sent request to start the VM 
            }
            else {
                $vmCollect.Add($vmStat.Name)
                if ($vmStat.Statuses[1].DisplayStatus -eq "VM deallocated") {
                    Start-AzVM -Id $disk.ManagedBy -NoWait
                }
            }
        }

    }
    
}

function diskSkuChange2 {
    param(
        [string]$diskName,
        [string]$newSku,
        [switch]$withoutStoppingVM 
    )
    $ErrorActionPreference = 'Stop'
    #
    $diskquery = "
    resources
    | where type == ""microsoft.compute/disks""
    | where name like ""$diskName""
    | project id,subscriptionId
    "
    $qres = Search-AzGraph -Query $diskquery -UseTenantScope -First 1000

    if (($qres | Measure-Object).Count -le 0 ) {
        Write-Host Not Found $diskName
    }
    elseif (($qres | Measure-Object).Count -ge 2) {
        Write-Host Too many disks $diskName
    }
    else {
        $currentSubscriptionId = (Get-AzContext).Subscription.Id.ToString()
        if ($currentSubscriptionId -ne $qres.subscriptionId) { Set-AzContext -SubscriptionId $qres.subscriptionId -ErrorAction Stop }
        # Set-AzContext -SubscriptionId $qres.subscriptionId
        $disk = Get-AzResource -ResourceId $qres.id
        $vm = Get-AzVM -ResourceId $disk.ManagedBy -Status
        if ($withoutStoppingVM) {
            Write-Host this script will not start the vm: $vm.Name
        }
        if (-not $withoutStoppingVM) {
            if ($vm.Statuses[1].DisplayStatus -eq 'VM running') {
                Write-Host Stopping the vm: $vm.Name
                Stop-AzVM -Id $vm.Id -Force
            } elseif ($vm.Statuses[1].DisplayStatus -eq 'VM deallocated') {
                Write-Output The VM: $vm.Name is already stopped
            }else{
                Write-Output The VM:$vm.Name is at $vm.Statuses[1].DisplayStatus State 
            }
        }
        Write-Host Updating Disk: $disk.Name sku to $newSku
        $supportedDiskSku = @('Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS')
        $newDiskSku = $supportedDiskSku | Where-Object { $_ -like $newSku }
        if (($newDiskSku | Measure-Object).Count -le 0) {
            Write-Host Requested Sku not Found: $newSku
        }
        elseif (($newDiskSku | Measure-Object).Count -ge 2 ) {
            Write-Host Too many similar sku: $newSku
        }
        else {
            $disk.Sku.Name = $newDiskSku
            Update-AzDisk -ResourceGroupName ($disk.ResourceGroupName) -DiskName ($disk.Name) -Disk $disk
        }
        if (-not $withoutStoppingVM) {
            $cVm = Get-AzVM -ResourceId $disk.ManagedBy -Status
            if ($cVm.Statuses[1].DisplayStatus -eq 'VM deallocated') {
                Write-Host Starting the vm: $vm.Name
                Start-AzVM -Id $vm.Id 
            } elseif ($cVm.Statuses[1].DisplayStatus -eq 'VM running') {
                Write-Output The VM is already running
            } else {
                Write-Output $cVm.Name is at $cVm.Statuses[1].DisplayStatus State
            }
        }
    }
}

## 
# diskSkuChange2 -diskName "" -newSku "" 
# or use like this
# diskSkuChange2 -diskName "" -newSku "" -withoutStoppingVM
##

function stopVmBeforeDiskChange {
    param (
        [string]$csvFilePath
    )

    $disks = Import-Csv -Path $csvFilePath 
    $disks | ForEach-Object {
        $ErrorActionPreference = 'Stop'
        #
        $diskquery = "
    resources
    | where type == ""microsoft.compute/disks""
    | where name like ""$diskName""
    | project id,subscriptionId
    "
        $qres = Search-AzGraph -Query $diskquery -UseTenantScope -First 1000

        if (($qres | Measure-Object).Count -le 0 ) {
            Write-Host Not Found $diskName
        }
        elseif (($qres | Measure-Object).Count -ge 2) {
            Write-Host Too many disks $diskName
        }
        else {
            # Set-AzContext -SubscriptionId $qres.subscriptionId -ErrorAction Stop
            $currentSubscriptionId = (Get-AzContext).Subscription.Id.ToString()
            if ($currentSubscriptionId -ne $qres.subscriptionId) { Set-AzContext -SubscriptionId $qres.subscriptionId -ErrorAction Stop } 
            $disk = Get-AzResource -ResourceId $qres.id -ErrorAction Stop
            # $vm = Get-AzVM -ResourceId $disk.ManagedBy
            # Start-AzVM -Id $disk.ManagedBy -NoWait
            $vmCollect = @()
            $vmStat = Get-AzVM -ResourceId $disk.ManagedBy -Status
            if ($vmStat.Name -in $vmCollect) {
                Write-Output $vmStat.Name: The VM is already Stopped
            }
            else {
                $vmCollect.Add($vmStat.Name)
                if ($vmStat.Statuses[1].DisplayStatus -eq "VM running") {
                    Stop-AzVM -Id $disk.ManagedBy -Force
                }
            }
            # Stop-AzVM -Id $disk.ManagedBy -Force
        }

    }
    
}