#
$outputs = @()
$serverName = hostname 
$month = 3#(Get-Date).Month
$year = (Get-Date).Year
$cmHotfix = Get-HotFix | Where-Object {$_.InstalledOn -gt (Get-Date -Day 3 -Month $month -Year $year) -and $_.InstalledOn -lt (Get-Date -Day 27 -Month $month -Year $year)}
$hotfix = $cmHotfix.HotFixID -join ","
#
$hostInfo = Get-CimInstance -ClassName Win32_OperatingSystem
$uptime = ((Get-Date) - ($hostInfo).LastBootUpTime).ToString("%d'days,'%h'hrs,'%m'mins'")
$osName = $hostInfo.Caption
$outputs += $serverName;$outputs += $osName;$outputs += $hotfix;$outputs += $uptime
#
Write-Output ($outputs -join "&")
