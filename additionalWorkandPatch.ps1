param(
    $vmName
)

$amaExt = {
    param(
        $vmExt
    )
    Set-AzContext -SubscriptionId ($vmExt.RequestId -split("/"))[2]
    Set-AzVMExtension -Name AzureMonitorWindowsAgent -ExtensionType AzureMonitorWindowsAgent -Publisher Microsoft.Azure.Monitor -ResourceGroupName $vmExt.ResourceGroupName -VMName $vmExt.Name -Location $vmExt.Location -TypeHandlerVersion "1.0" -EnableAutomaticUpgrade $true
}

$dcrAssociation = {
    param(
        $vmDcr
    )
    $dcrName = ""
    Set-AzContext -SubscriptionId ($vmDcr.RequestId -split("/"))[2]
    $dcr = Get-AzDataCollectionRule | where Name -Like $dcrName
    if ($dcr) {
        New-AzDataCollectionRuleAssociation -AssociationName ($dcr.Name + "-association") -DataCollectionRuleId $dcr.Id -ResourceUri $vmDcr.Id
    }
}

$patchMode = {
    param(
        $vmPatMode
    )
    Set-AzContext -SubscriptionId ($vmPatMode.RequestId -split("/"))[2]
    $vmPatMode.OSProfile.WindowsConfiguration.PatchSettings.AssessmentMode = "AutomaticByPlatform"
    $vmPatMode.OSProfile.WindowsConfiguration.PatchSettings.AutomaticByPlatformSettings = @{"bypassPlatformSafetyChecksOnUserSchedule" = $true}
    Update-AzVM -ResourceGroupName $vmPatMode.ResourceGroupName -VM $vmPatMode
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
    Start-Job -Name ($AzVm.Name + "-dcrAssociation") -ScriptBlock $dcrAssociation -ArgumentList $AzVm
    Start-Job -Name ($AzVm.Name + "-patchMode") -ScriptBlock $patchMode -ArgumentList $AzVm
} else {
    Write-Error $vmname Not found
}
