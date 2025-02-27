#
$vms = Import-Csv -Path "./vms.csv"
$vms | ForEach-Object {
$vmname = $_.NAME.trim()
$resId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """+$vmname+""" | project id") -UseTenantScope).id; write $resId;
$subsId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """+$vmname+""" | project subscriptionId") -UseTenantScope).subscriptionId; write $subsId;
Set-AzContext -SubscriptionId $subsId
#
$vm = Get-AzVM -ResourceId $resId
$skus = $vm | Get-AzVMSize
$skuAvail = $_.REQUESTEDSKU.trim() -in $skus.Name;
if ($skuAvail) {
$maxdisk = ($skus | Where name -eq $_.REQUESTEDSKU).MaxDataDiskCount; write $maxdisk
#
$currDisk = ($vm.StorageProfile.DataDisks | Measure-Object).Count; write $currDisk
$skuAvail = $maxdisk -ge $currDisk;
}
$_ | Add-Member -NotePropertyName "Sku_Available" -NotePropertyValue ($skuAvail)
}
$vms | Export-Csv -Path ".\sku.csv" -NoTypeInformation -Force
Import-Csv -Path ".\sku.csv"
##########
# it import a csv file with headers Name and Requested Sku where name is basically name of the VM and requested sku is self explanatory
# and outputs the same file witb new column name sku_Available which show in True/False that the requested sku is available or not 
