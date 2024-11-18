#
$allcsvfiles = @()
$allFiles = (Get-ChildItem -Path "./*.csv").Name
$allFiles | ForEach-Object {
$currFile = Import-Csv -Path ("./"+$_)
$allcsvfiles += $currFile
}
#
$allcsvfiles | Export-Csv -Path "./combined.csv" -Force -NoTypeInformation
