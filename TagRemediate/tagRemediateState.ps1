#
$neededTag = "PatchTag"             # Property/Column name in CSV
$azTagKey = "Patch"                # Azure Tag Key to update in Azure
$restoreModifiedTags = $false                 # Set to $true if user wants to restore/update modified tags in Azure
$referenceCsvPath = "./vms_reference.csv"  # Path to reference CSV file
$updatedCsvPath = "./vms_updated.csv"    # Path to updated CSV file
$finalCsvPath = "./final_vms.csv"       # Output path for final remediated CSV file
#
function Get-VmId {
    param ([Parameter(Mandatory = $true)] $VmObj)
    return "$($VmObj.VM)#$($VmObj.ResourceGroup)#$($VmObj.Subscription)"
}
#
function Get-VmTagComparison {
    param (
        [Parameter(Mandatory = $true)] [array]$ReferenceVMs,
        [Parameter(Mandatory = $true)] [array]$UpdatedVMs,
        [Parameter(Mandatory = $true)] [string]$TagName
    )

    # Added VMs (present in updated list but not in reference list)
    $addedVMs = Compare-Object -ReferenceObject $ReferenceVMs -DifferenceObject $UpdatedVMs -Property VM, ResourceGroup, Subscription -PassThru | 
    Where-Object { $_.SideIndicator -eq '=>' }

    # Removed VMs (present in reference list but not in updated list)
    $removedVMs = Compare-Object -ReferenceObject $ReferenceVMs -DifferenceObject $UpdatedVMs -Property VM, ResourceGroup, Subscription -PassThru | 
    Where-Object { $_.SideIndicator -eq '<=' }

    # Hashtable lookup using composite VmId (VM#ResourceGroup#Subscription)
    $refHashtable = @{}
    foreach ($vm in $ReferenceVMs) {
        $vmId = Get-VmId $vm
        $refHashtable[$vmId] = $vm
    }

    # Modified VMs (existing in both lists where tag value has changed)
    $modifiedVMs = foreach ($updated in $UpdatedVMs) {
        $vmId = Get-VmId $updated
        if ($refHashtable.ContainsKey($vmId)) {
            $ref = $refHashtable[$vmId]
            $oldTagVal = $ref.$TagName
            $newTagVal = $updated.$TagName

            if ($oldTagVal -ne $newTagVal) {
                [PSCustomObject]@{
                    VM            = $updated.VM
                    ResourceGroup = $updated.ResourceGroup
                    Subscription  = $updated.Subscription
                    OldTag        = $oldTagVal
                    NewTag        = $newTagVal
                }
            }
        }
    }

    # Blank Tag VMs (VMs in updated list where tag value is empty or whitespace)
    $blankTagVMs = foreach ($updated in $UpdatedVMs) {
        if ([string]::IsNullOrWhiteSpace($updated.$TagName)) {
            $vmId = Get-VmId $updated
            $oldValue = if ($refHashtable.ContainsKey($vmId)) { $refHashtable[$vmId].$TagName } else { $null }
            [PSCustomObject]@{
                VM            = $updated.VM
                ResourceGroup = $updated.ResourceGroup
                Subscription  = $updated.Subscription
                OldTag        = $oldValue
                NewTag        = $updated.$TagName
            }
        }
    }

    return [PSCustomObject]@{
        Added    = $addedVMs
        Removed  = $removedVMs
        Modified = $modifiedVMs
        Blank    = $blankTagVMs
    }
}


function Remediate-RemovedVMs {
    param (
        [Parameter(Mandatory = $true)] [array]$RemovedVMs,
        [Parameter(Mandatory = $true)] [string]$TagName,
        [Parameter(Mandatory = $true)] [string]$TagKey
    )

    Write-Output "`n--- Remediating Removed VMs ---"
    foreach ($removedVM in $RemovedVMs) {
        try {
            $ctx = Set-AzContext -Subscription $removedVM.Subscription -Scope Process
            $vmObj = Get-AzVM -Name $removedVM.VM -ResourceGroupName $removedVM.ResourceGroup -ErrorAction SilentlyContinue -DefaultProfile $ctx

            if ($null -ne $vmObj) {
                Write-Output "VM '$($removedVM.VM)' exists in Azure Portal. Adding tag '$TagKey'..."
                $tagValue = $removedVM.$TagName
                Update-AzTag -ResourceId $vmObj.Id -Operation Merge -Tag @{ $TagKey = $tagValue } -DefaultProfile $ctx
                
                if ($?) {
                    $removedVM | Add-Member -NotePropertyName 'Comment' -NotePropertyValue "VM found in Azure - Tag '$TagKey' added/restored" -Force
                }
                else {
                    $removedVM | Add-Member -NotePropertyName 'Comment' -NotePropertyValue "VM found in Azure - Tag update failed" -Force
                }
            }
            else {
                Write-Output "VM '$($removedVM.VM)' does not exist in Azure Portal."
                $removedVM | Add-Member -NotePropertyName 'Comment' -NotePropertyValue "VM not found in Azure" -Force
            }
        }
        catch {
            Write-Warning "Error checking/updating removed VM $($removedVM.VM): $_"
            $removedVM | Add-Member -NotePropertyName 'Comment' -NotePropertyValue "Exception during Azure verification" -Force
        }
    }
}

function Remediate-BlankTagVMs {
    param (
        [Parameter(Mandatory = $true)] [array]$BlankTagVMs,
        [Parameter(Mandatory = $true)] [array]$ReferenceVMs,
        [Parameter(Mandatory = $true)] [string]$TagName,
        [Parameter(Mandatory = $true)] [string]$TagKey
    )

    Write-Output "`n--- Remediating Blank Tag VMs ---"

    $refHashtable = @{}
    foreach ($vm in $ReferenceVMs) {
        $vmId = Get-VmId $vm
        $refHashtable[$vmId] = $vm
    }

    foreach ($vm in $BlankTagVMs) {
        try {
            $vmId = Get-VmId $vm
            $restoredValue = if ($refHashtable.ContainsKey($vmId)) { $refHashtable[$vmId].$TagName } else { $null }

            if ([string]::IsNullOrWhiteSpace($restoredValue)) {
                Write-Output "No reference tag value available for blank tag VM '$($vm.VM)'."
                $vm | Add-Member -NotePropertyName 'Comment' -NotePropertyValue "Blank tag - No reference value to restore" -Force
                continue
            }

            Write-Output "Restoring blank tag for '$($vm.VM)' with value '$restoredValue' in Azure..."
            $ctx = Set-AzContext -Subscription $vm.Subscription -Scope Process
            $vmObj = Get-AzVM -Name $vm.VM -ResourceGroupName $vm.ResourceGroup -ErrorAction Stop -DefaultProfile $ctx
            Update-AzTag -ResourceId $vmObj.Id -Operation Merge -Tag @{ $TagKey = $restoredValue } -DefaultProfile $ctx

            if ($?) {
                $vm | Add-Member -NotePropertyName 'Comment' -NotePropertyValue "Blank tag remediated in Azure ($TagKey = $restoredValue)" -Force
            }
            else {
                $vm | Add-Member -NotePropertyName 'Comment' -NotePropertyValue "Blank tag remediation failed in Azure" -Force
            }
        }
        catch {
            Write-Warning "Exception during blank tag update for $($vm.VM): $_"
            $vm | Add-Member -NotePropertyName 'Comment' -NotePropertyValue "Exception occurred during tag update" -Force
        }
    }
}

function Remediate-ModifiedTagVMs {
    param (
        [Parameter(Mandatory = $true)] [array]$ModifiedTagVMs,
        [Parameter(Mandatory = $true)] [string]$TagName,
        [Parameter(Mandatory = $true)] [string]$TagKey,
        [Parameter(Mandatory = $true)] [bool]$EnableRestoration
    )

    Write-Output "`n--- Remediating Modified Tag VMs ---"

    if (-not $EnableRestoration) {
        Write-Output "Modified tag restoration is disabled (`$restoreModifiedTags = `$false). Skipping Azure tag updates."
        foreach ($vm in $ModifiedTagVMs) {
            $vm | Add-Member -NotePropertyName 'Comment' -NotePropertyValue "Modified tag update skipped (`$restoreModifiedTags = `$false)" -Force
        }
        return
    }

    foreach ($vm in $ModifiedTagVMs) {
        try {
            Write-Output "Updating modified tag for '$($vm.VM)' to '$($vm.NewTag)' in Azure..."
            $ctx = Set-AzContext -Subscription $vm.Subscription -Scope Process
            $vmObj = Get-AzVM -Name $vm.VM -ResourceGroupName $vm.ResourceGroup -ErrorAction Stop -DefaultProfile $ctx
            Update-AzTag -ResourceId $vmObj.Id -Operation Merge -Tag @{ $TagKey = $vm.NewTag } -DefaultProfile $ctx

            if ($?) {
                $vm | Add-Member -NotePropertyName 'Comment' -NotePropertyValue "Modified tag updated in Azure ($TagKey = $($vm.NewTag))" -Force
            }
            else {
                $vm | Add-Member -NotePropertyName 'Comment' -NotePropertyValue "Modified tag update failed in Azure" -Force
            }
        }
        catch {
            Write-Warning "Exception during modified tag update for $($vm.VM): $_"
            $vm | Add-Member -NotePropertyName 'Comment' -NotePropertyValue "Exception occurred during tag update" -Force
        }
    }
}

function Invoke-TagRemediation {
    param (
        [Parameter(Mandatory = $true)] [array]$ReferenceVMs,
        [Parameter(Mandatory = $true)] [array]$UpdatedVMs,
        [string]$TagName = $neededTag,
        [string]$TagKey = $azTagKey,
        [bool]$RestoreModified = $restoreModifiedTags,
        [string]$OutPath = $finalCsvPath
    )

    Write-Output "================================================================="
    Write-Output " Starting Tag Remediation Process for Tag Column: '$TagName'"
    Write-Output " Azure Tag Key: '$TagKey' | Restore Modified Tags: $RestoreModified"
    Write-Output "================================================================="

    # Perform State Comparison
    $comparison = Get-VmTagComparison -ReferenceVMs $ReferenceVMs -UpdatedVMs $UpdatedVMs -TagName $TagName

    Write-Output "`n=== ADDED VMs ==="
    if ($comparison.Added) { $comparison.Added | Format-Table VM, ResourceGroup, Subscription, $TagName -AutoSize } else { Write-Output "None" }

    Write-Output "`n=== REMOVED VMs ==="
    if ($comparison.Removed) { $comparison.Removed | Format-Table VM, ResourceGroup, Subscription, $TagName -AutoSize } else { Write-Output "None" }

    Write-Output "`n=== MODIFIED TAG VMs ==="
    if ($comparison.Modified) { $comparison.Modified | Format-Table VM, ResourceGroup, Subscription, OldTag, NewTag -AutoSize } else { Write-Output "None" }

    Write-Output "`n=== BLANK TAG VMs ==="
    if ($comparison.Blank) { $comparison.Blank | Format-Table VM, ResourceGroup, Subscription, OldTag, NewTag -AutoSize } else { Write-Output "None" }

    # Run Remediation Functions
    if ($comparison.Removed) {
        Remediate-RemovedVMs -RemovedVMs $comparison.Removed -TagName $TagName -TagKey $TagKey
    }

    if ($comparison.Blank) {
        Remediate-BlankTagVMs -BlankTagVMs $comparison.Blank -ReferenceVMs $ReferenceVMs -TagName $TagName -TagKey $TagKey
    }

    if ($comparison.Modified) {
        Remediate-ModifiedTagVMs -ModifiedTagVMs $comparison.Modified -TagName $TagName -TagKey $TagKey -EnableRestoration $RestoreModified
    }

    # --------------------------------------------------------------------------
    # Build Union of All VMs with Status Comments (Keyed by Composite VmId)
    # --------------------------------------------------------------------------
    Write-Output "`n--- Building Union of All VMs ---"

    $unionDict = [ordered]@{}

    # Build reference lookup hashtable by VmId
    $refHashtable = @{}
    foreach ($vm in $ReferenceVMs) {
        $refHashtable[(Get-VmId $vm)] = $vm
    }

    # Helper hashtable of blank tag remediation comments keyed by VmId
    $blankCommentMap = @{}
    if ($comparison.Blank) {
        foreach ($bVm in $comparison.Blank) {
            $blankCommentMap[(Get-VmId $bVm)] = if ($bVm.Comment) { $bVm.Comment } else { "Blank tag detected" }
        }
    }

    # Helper hashtable of modified tag remediation comments keyed by VmId
    $modifiedCommentMap = @{}
    if ($comparison.Modified) {
        foreach ($mVm in $comparison.Modified) {
            $modifiedCommentMap[(Get-VmId $mVm)] = if ($mVm.Comment) { $mVm.Comment } else { "Tag modified" }
        }
    }

    # Helper lookup for Added VmIds
    $addedVmIds = @{}
    if ($comparison.Added) {
        foreach ($aVm in $comparison.Added) {
            $addedVmIds[(Get-VmId $aVm)] = $true
        }
    }

    # Process all VMs from Updated list first
    foreach ($vm in $UpdatedVMs) {
        $vmId = Get-VmId $vm
        $vmComment = "VM remained same"

        if ($blankCommentMap.ContainsKey($vmId)) {
            $vmComment = $blankCommentMap[$vmId]
            # Restore reference tag value in output object if blank
            if ($refHashtable.ContainsKey($vmId) -and [string]::IsNullOrWhiteSpace($vm.$TagName)) {
                $vm.$TagName = $refHashtable[$vmId].$TagName
            }
        }
        elseif ($modifiedCommentMap.ContainsKey($vmId)) {
            $vmComment = $modifiedCommentMap[$vmId]
        }
        elseif ($addedVmIds.ContainsKey($vmId)) {
            $vmComment = "VM added"
        }

        $unionDict[$vmId] = [PSCustomObject]@{
            VM            = $vm.VM
            ResourceGroup = $vm.ResourceGroup
            Subscription  = $vm.Subscription
            $TagName      = $vm.$TagName
            Comment       = $vmComment
        }
    }

    # Add Removed VMs from Reference list (if not already present in Updated list)
    if ($comparison.Removed) {
        foreach ($rVm in $comparison.Removed) {
            $rId = Get-VmId $rVm
            if (-not $unionDict.Contains($rId)) {
                $rComment = if ($rVm.Comment) { $rVm.Comment } else { "VM removed" }
                $unionDict[$rId] = [PSCustomObject]@{
                    VM            = $rVm.VM
                    ResourceGroup = $rVm.ResourceGroup
                    Subscription  = $rVm.Subscription
                    $TagName      = $rVm.$TagName
                    Comment       = $rComment
                }
            }
        }
    }

    $finalVmList = @($unionDict.Values)

    Write-Output "`n=== FINAL REMEDIATED LIST (UNION OF ALL VMs) ==="
    $finalVmList | Format-Table VM, ResourceGroup, Subscription, $TagName, Comment -AutoSize

    # Export to CSV
    if ($OutPath) {
        $finalVmList | Export-Csv -Path $OutPath -NoTypeInformation -Force
        Write-Output "Final union CSV generated at: $OutPath"
    }

    return $finalVmList
}

$refData = @()
$updData = @()
if (Test-Path $referenceCsvPath) {
    $refData = Import-Csv -Path $referenceCsvPath
}
else {
    Write-Warning "Reference CSV file not found at '$referenceCsvPath'"
    exit
}

if (Test-Path $updatedCsvPath) {
    $updData = Import-Csv -Path $updatedCsvPath
}
else {
    Write-Warning "Updated CSV file not found at '$updatedCsvPath'"
    exit
}

if ($refData -and $updData) {
    Invoke-TagRemediation -ReferenceVMs $refData -UpdatedVMs $updData | Format-Table
}
