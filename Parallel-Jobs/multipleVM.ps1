#
$path = "./"
$subscription = ""
$filenamesuffix = "_" + (Get-Date -Format "dd-mm-yyyy_HH_mm_fff") +"_"+ ((Get-TimeZone).standardname.replace(" ","_")) +".txt"
Start-Transcript -Path ($path + "transcript" + $filenamesuffix)
$vmNames = @("vmA","vmB")
Set-AzContext -Subscription $subscription
$vms = Get-AzVM
#
$mVm = $vms | Where-Object {$_.Name -in $vmNames}
$mVm | ForEach-Object {
  Write-Host $_.Name : $_.Id
  #
  Invoke-AzVMRunCommand -ResourceGroupName "" -VMName "" -CommandId "RunPowerShellScript" -ScriptPath ''
  Stop-AzVM -Id $_.Id
}
Stop-Transcript
