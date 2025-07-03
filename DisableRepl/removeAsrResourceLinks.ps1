#
$vmname = $vm.name.trim()
$resId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project id") -UseTenantScope).id; write $resId;
$subsId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project subscriptionId") -UseTenantScope).subscriptionId; write $subsId;
Set-AzContext -Subscription $subsId
$context = Get-AzContext

$azureUrl = $context.Environment.ResourceManagerUrl

$linksResourceId = $azureUrl + "subscriptions/" + $subscriptionId + '/providers/Microsoft.Resources/links'
$vmId = '/subscriptions/' + $subscriptionId + '/resourceGroups/' + $rgName + '/providers/Microsoft.Compute/virtualMachines/' + $vmName + '/'

Write-Host $("Deleting links for $vmId using resourceId: $linksResourceId")




$links = @(Get-AzResource -ResourceId $linksResourceId |  Where-Object { $_.Properties.sourceId -match $vmId } | Where-Object { $_.Properties.targetId.ToLower().Contains("microsoft.recoveryservices/vaults") } -or $_.Properties.targetId.ToLower().Contains("/protecteditemarmid/"))
Write-Host "Links to be deleted"
$links
Foreach ($link in $links) {
    Write-Host $("Deleting link " + $link.Name)
    Remove-AzResource -ResourceId $link.ResourceId -Force
}

Write-Host $("Deleted all links ")