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
    }
    else {
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


    if ($toCopyDisk.Encryption.DiskEncryptionSetId) {
        $diskEncryptionSetId = $toCopyDisk.Encryption.DiskEncryptionSetId
        $newDiskConfig = New-AzDiskConfig -Location $toCopyDisk.Location `
            -SkuName $toCopyDisk.Sku.Name `
            -CreateOption Empty `
            -OsType $toCopyDisk.OsType `
            -DiskSizeGB $newSizeGB `
            -DiskEncryptionSetId $diskEncryptionSetId `
            -Zone $vmZone `
            -Tag $oldTags
    }
    else {
        $newDiskConfig = New-AzDiskConfig -Location $toCopyDisk.Location `
            -SkuName $toCopyDisk.Sku.Name `
            -CreateOption Empty `
            -OsType $toCopyDisk.OsType `
            -DiskSizeGB $newSizeGB `
            -Zone $vmZone `
            -Tag $oldTags
    }

    $nameNumber = 2
    $newDiskName = ("DataDisk0" + $nameNumber + "-" + $vmName)
    while ($allDataDisks.Name -contains $newDiskName) {
        $nameNumber++
        $newDiskName = ("DataDisk0" + $nameNumber + "-" + $vmName)
    }

    try {
        $newDisk = New-AzDisk -ResourceGroupName $vm.ResourceGroupName -DiskName $newDiskName -Disk $newDiskConfig
        Write-Output "New disk '$newDiskName' created successfully"
        Write-Output "New disk '$newDiskName' created successfully" | Out-File -FilePath (".\$vmName.txt") -Append -Force
    }
    catch {
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

    $template = @'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "resources": [
    {
      "type": "Microsoft.Compute/virtualMachines",
      "apiVersion": "2023-03-01",
      "name": "[parameters('vmName')]",
      "location": "[resourceGroup().location]",
      "properties": {
        "storageProfile": {
          "dataDisks": [
            {
              "lun": "[parameters('diskLun')]",
              "name": "[parameters('diskName')]",
              "createOption": "Attach",
              "hostCaching": "[parameters('hostCaching')]",
              "managedDisk": {
                "id": "[resourceId('Microsoft.Compute/disks', parameters('diskName'))]"
              }
            }
          ]
        }
      }
    }
  ],
  "parameters": {
    "vmName": {
      "type": "string",
      "metadata": {
        "description": "The name of the virtual machine."
      }
    },
    "diskName": {
      "type": "string",
      "metadata": {
        "description": "The name of the existing managed disk to attach."
      }
    },
    "diskLun": {
      "type": "int",
      "defaultValue": 0,
      "metadata": {
        "description": "The logical unit number (LUN) to assign to the disk."
      }
    },
    "hostCaching": {
      "type": "string",
      "allowedValues": [
        "None",
        "ReadOnly",
        "ReadWrite"
      ],
      "defaultValue": "None",
      "metadata": {
        "description": "The host caching setting for the data disk."
      }
    }
  }
}
'@
$templateHash =@{}
$templateJson = $template | ConvertFrom-Json
$templateJson.psobject.properties | ForEach-Object { $templateHash[$_.Name] = $_.value }

$templateParameters = @{
    "vmName"      = $vmName
    "diskName"    = $newDiskName
    "diskLun"     = $newLun
    "hostCaching" = $oldHostCaching
}

New-AzResourceGroupDeployment `
    -ResourceGroupName $resourceGroupName `
    -TemplateObject ($template | ConvertFrom-Json -AsHashtable) `
    -TemplateParameterObject $templateParameters

if ($?) {
    Write-Host "Disk $diskName successfully attached to VM $vmName at LUN $diskLun with Host Caching $hostCaching." -ForegroundColor Green
} else {
    Write-Host "Failed to attach disk. Check the error details above." -ForegroundColor Red
}

}

diskCreate -vmName "myVM" -resourceGroupName "myResourceGroup" -lun 2 -newSizeGB 128

