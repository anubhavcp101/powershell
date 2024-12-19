param(
    $vmName
)

$amaExt = {
    param(
        $vmExt
    )
    Set-AzContext -SubscriptionId ($vmExt.Id -split("/"))[2]
    Set-AzVMExtension -Name AzureMonitorWindowsAgent -ExtensionType AzureMonitorWindowsAgent -Publisher Microsoft.Azure.Monitor -ResourceGroupName $vmExt.ResourceGroupName -VMName $vmExt.Name -Location $vmExt.Location -TypeHandlerVersion "1.0" -EnableAutomaticUpgrade $true
}

$dcrAssociation = {
    param(
        $vmId
    )
    $dcrName = ""
    Set-AzContext -SubscriptionId ($vmId -split("/"))[2]
    $dcr = Get-AzDataCollectionRule | where Name -Like $dcrName
    if ($dcr) {
        New-AzDataCollectionRuleAssociation -AssociationName ($dcr.Name + "-association") -DataCollectionRuleId $dcr.Id -ResourceUri $vmId
    }
}

$patchMode = {
    param(
        $resId
    )
    Set-AzContext -SubscriptionId ($resId -split("/"))[2]
    $Vm = Get-AzVM -ResourceId $resId
    $Vm.OSProfile.WindowsConfiguration.PatchSettings.patchMode = "AutomaticByPlatform"
    $Vm.OSProfile.WindowsConfiguration.PatchSettings.AutomaticByPlatformSettings = @{"bypassPlatformSafetyChecksOnUserSchedule" = $true}
    Update-AzVM -ResourceGroupName $Vm.ResourceGroupName -VM $Vm
}

$sysIdentity = {
    param(
        $resId
    )
    Set-AzContext -SubscriptionId ($resId -split("/"))[2]
    $vmSysIdentity = Get-AzVM -ResourceId $resId
    Update-AzVM -ResourceGroupName $vmSysIdentity.ResourceGroupName -VM $vmSysIdentity -IdentityType SystemAssigned
}

$vmname = $vmName.trim()
$resId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project id") -UseTenantScope).id; write $resId;
$subsId = (Search-AzGraph -Query ("resources | where type == ""microsoft.compute/virtualmachines"" | where name like """ + $vmname + """ | project subscriptionId") -UseTenantScope).subscriptionId; write $subsId;
$currentSubscriptionId = (Get-AzContext).Subscription.Id.ToString()
#
if ($currentSubscriptionId -ne $subsId) { Set-AzContext -SubscriptionId $subsId -ErrorAction Stop }
$resIdCount = ($resId | Measure-Object).Count 
if ($resIdCount -gt 0 -and $resIdCount -lt 2) {
    $AzVm = Get-AzVM -ResourceId $resId
    Start-Job -Name ($AzVm.Name + "-amaExtension") -ScriptBlock $amaExt -ArgumentList $AzVm
    Start-Job -Name ($AzVm.Name + "-sysIdentity") -ScriptBlock $sysIdentity -ArgumentList $resId
    Start-Job -Name ($AzVm.Name + "-dcrAssociation") -ScriptBlock $dcrAssociation -ArgumentList $resId
    Start-Job -Name ($AzVm.Name + "-patchMode") -ScriptBlock $patchMode -ArgumentList $resId
    
} else {
    Write-Error $vmname Not found
}
