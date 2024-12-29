#
$rg = ""
$vaultName = ""
$plsName = "Connection-B" # update vnet and subnet details in below vnet command / in 12th line subnet
$asgName = ""
$pvepName = ""
$subscription = ""
#
Set-AzContext -Subscription $subscription
$keyvault = Get-AzKeyVault -VaultName $vaultName -ResourceGroupName $rg
$plsConnection = New-AzPrivateLinkServiceConnection -PrivateLinkServiceId $keyvault.ResourceId -Name $plsName -GroupId "vault"
$virtualNetwork = Get-AzVirtualNetwork -ResourceName '' -ResourceGroupName ''
#
$subnet = $virtualNetwork | Select-Object -ExpandProperty subnets | Where-Object Name -eq ''
$asg = Get-AzApplicationSecurityGroup -Name $asgName -ResourceGroupName $rg
New-AzPrivateEndpoint -Name $pvepName `
  -ResourceGroupName $rg `
  -Location "westus 3" `
  -PrivateLinkServiceConnection $plsConnection -Subnet $subnet `
  -ApplicationSecurityGroup $asg `
  -CustomNetworkInterfaceName ("pvep-"+$_+"-nic")
