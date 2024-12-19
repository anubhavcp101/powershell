#
$svcs = @("","","","","nonexistent")
$outputStr = ""
$svcs | ForEach-Object {
    $status =""
    if (Get-Service $_) {
        $status = Get-Service -Name $_ | Select-Object -ExpandProperty Status
        #
    } else {
        $status = "notFound"
    }
    $outputStr += $_ + ":" + $status + ";"
    #
}
Write-Host $outputStr

