#
Connect-AzAccount -TenantId ""
$subs = Get-AzSubscription
$subs | ForEach-Object {
    Set-AzContext -Subscription $_.Name
    $subsobj = @()
    $rgs = Get-AzResourceGroup
    #
    $rgs | ForEach-Object {
        $lock = Get-AzResourceLock -ResourceGroupName $_.ResourceGroupName -AtScope
        $obj = New-Object -TypeName psobject
        $obj | Add-Member -NotePropertyName "LockName" -NotePropertyValue $lock.Name
        #
        $obj | Add-Member -NotePropertyName "ResourceGroup" -NotePropertyValue $_.ResourceGroupName
        $subsobj += $obj
        #Remove-AzResourceLock -LockId $lock.LockId -Force
    }
    $subsobj | Export-Csv -Path (".\" + $_.Name + ".csv") -Force -NoTypeInformation
}
