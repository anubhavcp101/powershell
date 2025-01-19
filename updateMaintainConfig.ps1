#
$kbs = @()
$maintainConfigName = ""
$rg = ""
$subscription = ""
Set-AzContext -Subscription $subscription
$maintainConfig = Get-AzMaintenanceConfiguration -ResourceGroupName $rg -Name $maintainConfigName
#
$kbs | ForEach-Object { $mc.WindowParameterKbNumberToInclude.add($_) } 
# $maintainConfig.WindowParameterKbNumberToInclude.Add("")
Update-AzMaintenanceConfiguration -ResourceGroupName $rg -Name $maintainConfigName -Configuration $maintainConfig
