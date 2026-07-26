#
$kbs = @()
$maintainConfigName = ""
$rg = ""
$subscription = ""
Set-AzContext -Subscription $subscription
$maintainConfig = Get-AzMaintenanceConfiguration -ResourceGroupName $rg -Name $maintainConfigName
#
$kbs | ForEach-Object { $maintainConfig.WindowParameterKbNumberToInclude.add($_) } 
# $maintainConfig.WindowParameterKbNumberToInclude.Add("")
Update-AzMaintenanceConfiguration -ResourceGroupName $rg -Name $maintainConfigName -Configuration $maintainConfig
# Validate
#
$attempt = 0 
do {
    # try to update
    $attempt++
    $kbs | ForEach-Object { $maintainConfig.WindowParameterKbNumberToInclude.add($_) } 
    Update-AzMaintenanceConfiguration -ResourceGroupName $rg -Name $maintainConfigName -Configuration $maintainConfig
    $res = Compare-Object -ReferenceObject $kbs -DifferenceObject @($maintainConfig.WindowParameterKbNumberToInclude)
} while (
    ($null -ne $res) -and ($attempt -lt 3)
) 
$res = Compare-Object -ReferenceObject $kbs -DifferenceObject @($maintainConfig.WindowParameterKbNumberToInclude)
if ($null -eq $res) {
    Write-Output "Successfully Updated"
} else {
    Write-Output "Please verify"
    $res
}