#
param(
    $msg
)

$timeInfo = (Get-TimeZone).Id
Write-Output "The Time Zone is $timeInfo"
#
Write-Output "-- $msg --"