#
$rg = ''
$vmName =''
$subscription=''
$scriptPath = 'getInfo.ps1'
$parameters = @{msg="The End"}
Set-Location $PSScriptRoot
#
Set-AzContext -Subscription $subscription
Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $vmName -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath -Parameter $parameters
