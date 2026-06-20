#
$src = ""
$dest = "C:\azcopy"
New-Item -Path $dest -ItemType Directory -Force
Invoke-WebRequest -Uri $src -OutFile "$des\azcopy.zip"
Set-Location $dest
$zi = Get-ChildItem -Path . -Filter "*.zip"
#
Expand-Archive -Path $zi.FullName -DestinationPath .
$it = Get-ChildItem -Directory | Where Name -like "azcopy*"
Set-Location $it.FullName
.\azcopy.exe --version
#
Copy-Item -Path "$($it.FullName)\azcopy.exe" -Destination "$dest\azcopy.exe"
&"C:\azcopy\azcopy.exe" --version

# zip and grab a folder
$path = ""
Compress-Archive -Path $path -DestinationPath "$(Split-Path -Path $path -Parent)\$(Split-Path -Path $path -Leaf).zip"
$itm = $null
if (Test-Path "$path.zip") {
    $itm = Get-Item -Path "$path.zip"
}
$itm
&"C:\azcopy\azcopy.exe" copy "$($itm.FullName)" "$url"