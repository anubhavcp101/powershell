function diskCreate {
    param (
        [string]$vmName,
        [string]$resourceGroupName,
        [int]$lun,
        [int]$newSizeGB
    )
    #
    $ErrorActionPreference = 'Stop'
    # Get the VM and its attached disks
    $vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName
    $allDataDisks = $vm.StorageProfile.DataDisks
    $requiredDisk = $allDataDisks | where Lun -eq $lun 

    if ($requiredDisk) {
        # Extract the resource group of the disk from its ID
        $diskResourceGroup = ($requiredDisk.ManagedDisk.Id -split '/')[-5]
        $toCopyDisk = Get-AzDisk -ResourceGroupName $diskResourceGroup -DiskName $requiredDisk.Name
        $oldHostCaching = $requiredDisk.Caching
        $oldTags = $toCopyDisk.Tags
    } else {
        Write-Error "Disk with LUN $lun not found for VM '$vmName'."
        Write-Error "Disk with LUN $lun not found for VM '$vmName'." | Out-File -FilePath (".\$vmName.txt") -Append -Force
        return
    }

    # Determine the zone of the VM, if any
    $vmZone = if ($vm.Zones -join "") { $vm.Zones -join "" } else { $null }  # If the VM has a zone, it will be listed here
    if ($vm.Zones -join "") {
        Write-Host $vmName : This VM has Zones
        Write-Host $vmName : This VM has Zones | Out-File -FilePath (".\$vmName.txt") -Append -Force
    }


    if ($toCopyDisk.DiskEncryptionSet) {
        $diskEncryptionSetId = $toCopyDisk.DiskEncryptionSet.Id
        $newDiskConfig = New-AzDiskConfig -Location $toCopyDisk.Location `
        -SkuName $toCopyDisk.Sku.Name `
        -CreateOption Empty `
        -OsType $toCopyDisk.OsType `
        -DiskSizeGB $newSizeGB `
        -DiskEncryptionSetId $diskEncryptionSetId `
        -Zone $vmZone `
        -Tag $oldTags
    } else {
        $newDiskConfig = New-AzDiskConfig -Location $toCopyDisk.Location `
        -SkuName $toCopyDisk.Sku.Name `
        -CreateOption Empty `
        -OsType $toCopyDisk.OsType `
        -DiskSizeGB $newSizeGB `
        -Zone $vmZone `
        -Tag $oldTags
    }

    $nameNumber = 2
    $newDiskName = ("DataDisk0"+$nameNumber+"-"+$vmName)
    while ($allDataDisks.Name -contains $newDiskName) {
        $nameNumber++
        $newDiskName = ("DataDisk0"+$nameNumber+"-"+$vmName)
    }

    try {
        $newDisk = New-AzDisk -ResourceGroupName $vm.ResourceGroupName -DiskName $newDiskName -Disk $newDiskConfig
        Write-Output "New disk '$newDiskName' created successfully"
        Write-Output "New disk '$newDiskName' created successfully" | Out-File -FilePath (".\$vmName.txt") -Append -Force
    } catch {
        Write-Output " $vmName : Failed to create new disk: $_"
        Write-Output " $vmName : Failed to create new disk: $_" | Out-File -FilePath (".\$vmName.txt") -Append -Force
        return
    }

    # Find an available LUN for attaching the new disk, starting from 2 since 0 and 1 are reserved
    $usedLuns = $allDataDisks.Lun
    $newLun = 2
    while ($usedLuns -contains $newLun) {
        $newLun++
    }

    # Attach the new disk at the available LUN with the same host caching setting
    try {
        # Attach the new disk using Add-AzVMDataDisk
        $vm = Add-AzVMDataDisk -VM $vm `
        -Name $newDiskName `
        -CreateOption Attach `
        -ManagedDiskId $newDisk.Id `
        -Lun $newLun `
        -Caching $oldHostCaching

        # Update the VM with the new disk configuration
        # Update-AzVM -VM $vm -ResourceGroupName $resourceGroupName #-- need to check this
        Write-Output "New disk attached successfully to VM '$vmName' at new LUN $newLun "
        Write-Output "New disk attached successfully to VM '$vmName' at new LUN $newLun " | Out-File -FilePath (".\$vmName.txt") -Append -Force
    } catch {
        Write-Output " $vmName : Failed to attach new disk to VM: $_"
        Write-Output " $vmName : Failed to attach new disk to VM: $_" | Out-File -FilePath (".\$vmName.txt") -Append -Force 
    }
}

diskCreate -vmName "myVM" -resourceGroupName "myResourceGroup" -lun 2 -newSizeGB 32

