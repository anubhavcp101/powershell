#
$vmList = @("")
$dcrName = ""
$vmList | ForEach-Object {
  $vmname = $_.trim()
  $resId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project id") -UseTenantScope).id; write $resId;
  $subsId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project subscriptionId") -UseTenantScope).subscriptionId; write $subsId;
  Set-AzContext -SubscriptionId $subsId
  #
  $vm = Get-AzVM -ResourceId $resId
  $dcr = Get-AzDataCollectionRule | where Name -Like $dcrName
  if ($dcr) {
    New-AzDataCollectionRuleAssociation -AssociationName ($dcr.Name + "-association") -DataCollectionRuleId $dcr.Id -ResourceUri $vm.Id
  }
}