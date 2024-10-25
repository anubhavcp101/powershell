#
$vms = Import-Csv -Path "./vms.csv"
$vms | ForEach-Object {
$vmConfig = Get-AzVM -ResourceGroupName $_.RESOURCEGROUP -Name $_.NAME
$vmConfig.StorageProfile.OsDisk.DeleteOption = 'Delete'
$vmConfig.StorageProfile.DataDisks | ForEach-Object { $_.DeleteOption = 'Delete' }
$vmConfig.NetworkProfile.NetworkInterfaces | ForEach-Object { $_.DeleteOption = 'Delete' }
#
$vmConfig | Update-AzVM
Remove-AzVM -ResourceGroupName $_.RESOURCEGROUP -Name $_.NAME -Force
}
##
##
# its imports a csv file having columns Name and ResourceGroup and delete those azure VMs
