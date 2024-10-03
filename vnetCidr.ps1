#
$vnetquery = 'resources
| where type == "microsoft.network/virtualnetworks"
| extend addressPrefixes = properties.addressSpace.addressPrefixes
| project name, addressPrefixes'
$vnetres = Search-AzGraph -Query $vnetquery -First 1000
$vnetres | ForEach-Object {
#
$ips = $_.addressPrefixes -join ","
$_ | Add-Member -NotePropertyName "IPs" -NotePropertyValue $ips
}
$vnetres| select name,IPs | Export-Csv -Path ".\vnets.csv" -NoTypeInformation -Force
##########
# To get vnets and their cidr
