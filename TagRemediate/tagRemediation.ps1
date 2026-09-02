#
$referenceVMs = Import-Csv -Path ./vms_reference.csv
$updatedVMs = Import-Csv -Path ./vms_updated.csv

# Columns are VM, ResourceGroup, Subscription, PatchTag
#  added VMs
$addedVMs = Compare-Object -ReferenceObject $referenceVMs -DifferenceObject $updatedVMs -Property VM, ResourceGroup, Subscription -PassThru | Where-Object { $_.SideIndicator -eq '=>' }
#
#  removed VMs
$removedVMs = Compare-Object -ReferenceObject $referenceVMs -DifferenceObject $updatedVMs -Property VM, ResourceGroup, Subscription -PassThru | Where-Object { $_.SideIndicator -eq '<=' }

# Modified VMs (VMs existing in both files where PatchTag has changed)
$refHashtable = @{}
foreach ($vm in $referenceVMs) {
    $refHashtable[$vm.VM] = $vm
}

$modifiedVMs = foreach ($updated in $updatedVMs) {
    if ($refHashtable.ContainsKey($updated.VM)) {
        $ref = $refHashtable[$updated.VM]
        if ($ref.PatchTag -ne $updated.PatchTag) {
            [PSCustomObject]@{
                VM            = $updated.VM
                ResourceGroup = $updated.ResourceGroup
                Subscription  = $updated.Subscription
                OldPatchTag   = $ref.PatchTag
                NewPatchTag   = $updated.PatchTag
            }
        }
    }
}

Write-Output "=== ADDED VMs ==="
$addedVMs | Format-Table VM, ResourceGroup, Subscription, PatchTag -AutoSize

Write-Output "=== REMOVED VMs ==="
$removedVMs | Format-Table VM, ResourceGroup, Subscription, PatchTag -AutoSize

Write-Output "=== MODIFIED VMs (PatchTag Updated) ==="
$modifiedVMs | Format-Table VM, ResourceGroup, Subscription, OldPatchTag, NewPatchTag -AutoSize

# VMs needs remediation
Write-Output "=== REMOVED VMs ==="
$removedVMs | Format-Table VM, ResourceGroup, Subscription, PatchTag -AutoSize

Write-Output "=== VMs with Blank PatchTag ==="
$blankPatchTagVMs = $modifiedVMs | Where-Object { [string]::IsNullOrWhiteSpace($_.NewPatchTag) }
$blankPatchTagVMs | Format-Table VM, ResourceGroup, Subscription, OldPatchTag, NewPatchTag -AutoSize

# Final List Generation
$updatedVMs = $updatedVMs + ($removedVMs | Select-Object VM, ResourceGroup, Subscription, PatchTag)
if ($blankPatchTagVMs) {
    foreach ($vm in $updatedVMs) {
        $match = $blankPatchTagVMs | Where-Object { $_.VM -eq $vm.VM }
        if ($match) {
            $vm.PatchTag = $match.OldPatchTag
        }
    }
}

Write-Output "=== Final List ==="
$updatedVMs | Format-Table VM, ResourceGroup, Subscription, PatchTag -AutoSize

foreach ($vm in $updatedVMs) {
    $vm | Add-Member -NotePropertyName 'Comment' -NotePropertyValue 'VM remained same'
}

foreach ($removedVM in $removedVMs) {
    $ctx = Set-AzContext -Subscription $removedVM.Subscription -Scope Process
    $vm = Get-AzVM -Name $removedVM.VM -ResourceGroupName $removedVM.ResourceGroup -ErrorAction SilentlyContinue -DefaultProfile $ctx
    if ($null -eq $vm) {
        Write-Output "VM $($removedVM.VM) does not exist in Subscription $($removedVM.Subscription)"
        $removedVM.Comment = 'VM not found'
    }
}

foreach ( $vm in $blankPatchTagVMs) {
    try {
        $ctx = Set-AzContext -Subscription $vm.Subscription -Scope Process
        $vmObj = Get-AzVM -Name $vm.VM -ResourceGroupName $vm.ResourceGroup -ErrorAction Stop -DefaultProfile $ctx
        Update-AzTag -ResourceId $vmObj.Id -Operation Merge -Tag @{'Patch' = $vm.PatchTag }
        if ($?) {
            $vm.Comment = 'PatchTag updated'
        }
    }
    catch {
        $vm.Comment = 'Exception occrued during PatchTag update'
    }
}

$finalFilePath = "./final_vms.csv"
$updatedVMs | Export-Csv -Path $finalFilePath -NoTypeInformation -Force
Write-Output "Final file generated at $finalFilePath"
