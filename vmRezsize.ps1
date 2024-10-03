#
$vms = Import-Csv -Path "./vms.csv"
$vms | ForEach-Object {
$curSubs = (Get-AzContext).Subscription.Id.ToString()
if ( $_.SUBSCRIPTIONID -ne $curSubs) {Set-AzContext -SubscriptionId $_.SUBSCRIPTIONID }
$vm = Get-AzVM -ResourceGroupName $_.RESOURCEGROUP -Name $_.NAME
$vmSize = $vm.HardwareProfile.VmSize
#
if ($_.CURRENTSIZE -eq $vmSize ) {
$vm.HardwareProfile.VmSize = $_.REQUESTEDSIZE
Write-Host "Stopping VM: " $vm.Name " and expected size is " ($vm.HardwareProfile.VmSize)
Stop-AzVM -Id $vm.Id -Force -Confirm
#
Write-Host "Updating the VM: " $vm.Name " to " ($vm.HardwareProfile.VmSize)
Update-AzVM -ResourceGroupName $vm.ResourceGroupName -VM $vm
Write-Host " Starting the VM: " $vm.Name
Start-AzVM -Id $vm.Id -NoWait
} else {
Write-Host "Check the VM: " $_.NAME $vm.Name
}
}
###
# to resize VMs
# it import a csv file having columns named Name, ResourceGroup, CurrentSize and RequestedSize 
