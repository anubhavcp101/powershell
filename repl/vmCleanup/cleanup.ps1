#
<#
This needs a csv file with columns Name, ResourceGroup, Subscription where Name is for name of the VM but
ResourceGroup is for name of resource group from where the VM should be cleaned up and
Subscription is for name of the Subscription where the VM is present. 
#>
$filepath = "./vms.csv"
#
Set-Location $PSScriptRoot
$drVms = Import-Csv -Path $filepath
foreach ($drVm in $drVms) {
  Set-AzContext -Subscription $drVm.Subscription.trim()
  #
  $vmStatus = Get-AzVM -Status -ResourceGroupName $drVm.ResourceGroup.trim() -Name $drVm.Name.trim()
  $AzVm = Get-AzVM -ResourceGroupName $drVm.ResourceGroup.trim() -Name $drVm.Name.trim()
  if ( ($vmStatus.Statuses[1].DisplayStatus -eq "VM deallocated") -and ($AzVm.Location -eq "eastus") ) {
    #
    $AzVm.StorageProfile.OsDisk.DeleteOption = 'Delete'
    $AzVm.StorageProfile.DataDisks | ForEach-Object { $_.DeleteOption = 'Delete' }
    $AzVm.NetworkProfile.NetworkInterfaces | ForEach-Object { $_.DeleteOption = 'Delete' }
    $AzVm | Update-AzVM
    Update-AzTag -ResourceId $AzVm.StorageProfile.OsDisk.ManagedDisk.Id -Tag @{"cleanup_resource"="true"} -Operation Merge
    Update-AzTag -ResourceId $AzVm.Id -Tag @{"cleanup_resource"="true"} -Operation Merge
    
    foreach ($disk in $AzVm.StorageProfile.DataDisks) {
      Update-AzTag -ResourceId $disk.ManagedDisk.Id -Tag @{"cleanup_resource"="true"} -Operation Merge
    }

    foreach ($nic in $AzVm.NetworkProfile.NetworkInterfaces) {
      Update-AzTag -ResourceId $nic.Id -Tag @{"cleanup_resource"="true"} -Operation Merge
    }
    Remove-AzVM -Name $AzVm.Name -ResourceGroupName $AzVm.ResourceGroupName -Force
  }
}

# Get-AzResource -TagName "cleanup_resource" -TagValue "true" | Select Name, ResourceGroupName, Type, SubscriptionId
