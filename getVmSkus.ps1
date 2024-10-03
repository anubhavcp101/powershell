#
Set-AzContext -Subscription ""
$vm = Get-AzVM -ResourceId ""
$sizes = $vm | Get-AzVMSize
$dseries = $sizes | where name -like "Standard_D*"
$rsizes = $dseries | where NumberOfCores -EQ 4 | where MemoryInMB -eq (16*1024)
$rsizes | select Name,NumberOfCores,MemoryInMB,MaxDataDiskCount | Export-Csv -Path ("./" + "skuvail.csv") -NoTypeInformation -Force
#
write $rsizes | select Name,NumberOfCores,MemoryInMB,MaxDataDiskCount | Format-Table
###
# to get avaiable sku(s) of a VM 
# but it show only D series and 4cores and 16gb only. Need to further improve it 
