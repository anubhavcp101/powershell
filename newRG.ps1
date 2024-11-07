#
$rgname = ""
$rgSubscription = ""
$rgLocation = ""
$rgTags = @{""="";"x"=""}
$currentSubscription = (Get-AzContext).Subscription.Name.ToString()
if ($currentSubscription -ne $rgSubscription){
  #
  Set-AzContext -Subscription $rgSubscription -ErrorAction Stop
}
New-AzResourceGroup -Name $rgname -Location $rgLocation -Tag $rgTags
