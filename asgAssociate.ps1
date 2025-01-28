#
function asgAssociate {
    param (
        [string]$vmName,
        [string[]]$asgs
    )
    $ErrorActionPreference = 'Stop'
    #
    $vmname = $vmName.Trim()
    $resId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project id") -UseTenantScope).id; write $resId;
    $subsId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project subscriptionId") -UseTenantScope).subscriptionId; write $subsId;
    $currentSubscriptionId = (Get-AzContext).Subscription.Id.ToString()
    #
    if ($currentSubscriptionId -ne $subsId) { Set-AzContext -SubscriptionId $subsId -ErrorAction Stop }
    $resIdCount = ($resId | Measure-Object).Count 
    if ($resIdCount -gt 0 -and $resIdCount -lt 2) {
        $AzVm = Get-AzVM -ResourceId $resId
        $nic = Get-AzNetworkInterface -ResourceId $Vm.NetworkProfile.NetworkInterfaces[0].id
        $asgs | ForEach-Object {
            $asg = Get-AzApplicationSecurityGroup -Name $_
            $nic.IpConfigurations[0].ApplicationSecurityGroups.Add($asg)
        }
    } else {
        Write-Error $vmname Not found
    }
    
}