#
<#
This needs a csv file with columns Seq, Name, ResourceGroup, and Subscription where Seq is the Sequence number in which the VMs will be rebooted.
#>
$filepath = ".\vms.csv"
Set-Location $PSScriptRoot
$vms = Import-Csv -Path $filepath
#
$totalVm = $vms.Length
Start-Transcript -Path ((Split-Path $filepath) + "\output-$(Get-Date -Format 'hh-mm').txt") -Append -Force
for($count=1;$count -le $totalVm;$count++){
  $cVm = $vms | where Seq -eq $count
  #
  Write-Output "Triggering restart of the VM: $($cVm.Name)"
  Set-AzContext -Subscription ($cVm.Subscription)
  Restart-AzVM -Name ($cVm.Name) -ResourceGroupName ($cVm.ResourceGroup)
  Write-Output "Restart cmdlet returned for the VM: $($cVm.Name)"

  Write-Output "Going to sleep for 5 mins"
  Start-Sleep -Seconds 300
  Write-Output "Sleep Completed"
  
  $exitCount = 0
  $vmStatus = Get-AzVM -Status -Name ($cVm.Name) -ResourceGroupName ($cVm.ResourceGroup)
  while (($vmStatus.Statuses[1].DisplayStatus -ne "VM running") -and (-not ($vmStatus.VMAgent)) ) {
    Write-Output "Currently the VM $($vmStatus.Name) has status: $($vmStatus.Statuses[1].DisplayStatus)"
    Write-Output "Will Check again after 2 mins"
    Start-Sleep -Seconds 120
    $vmStatus = Get-AzVM -Status -Name $vmStatus.Name -ResourceGroupName $vmStatus.ResourceGroupName
    $exitCount++
    if ($exitCount -ge 5) {
      Write-Output "The Vm $($vmStatus.Name) is not coming up please check. This script will exit now"
      exit
    }
  }
  
}
Stop-Transcript
