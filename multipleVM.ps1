#
$path = "./"
$filename = "transcript"
$filenamesuffix = "_" + (Get-Date -Format "dd-mm-yyyy_HH_mm_fff") +"_"+ ((Get-TimeZone).standardname.replace(" ","_")) +".txt"
Start-Transcript -Path ($path + $filename + $filenamesuffix)
$vmNames = @("vmA","vmB")
$vms = Get-AzVM
#
$mVm = $vms | Where-Object {$_.Name -in $vmNames}
$mVm | ForEach-Object {
  Write-Host $_.Name : $_.Id
#
  Stop-AzVM -Id $_.Id
}
Stop-Transcript
