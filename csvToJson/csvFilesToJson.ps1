#
$cwd = "C:\Users\yashw\OneDrive\Desktop\powershell\powershell"
Set-Location $cwd
$csvFiles = Get-ChildItem -Path . -Filter "*.csv"

$files = @()

#
foreach ($csvfile in $csvFiles) {
    $file = [PSCustomObject]@{
        FileName = $csvfile.Name
        FileContent = (Import-Csv -Path $csvfile.FullName)
        #
    }
    $files += $file

}

$files | ConvertTo-Json -Depth 32 | Out-File -FilePath "$cwd/combined.json" -Force
$files | ConvertTo-Json -Depth 32