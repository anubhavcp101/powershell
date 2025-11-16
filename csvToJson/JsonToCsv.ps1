#
$filePath = "C:\Users\yashw\OneDrive\Desktop\powershell\powershell\csvToJson\combined.json"
$cwd = $PSScriptRoot
Set-Location $cwd
$jsonFile = Get-Content -Path $filePath | ConvertFrom-Json
foreach ($file in $jsonFile) {
    $file.FileContent | Export-Csv -Path "$($file.FileName)" -NoTypeInformation -Force
}