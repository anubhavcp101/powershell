#
$url = ""
$outPath = ($env:TEMP + "\" + ($url.split("/")[-1]))
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $url -OutFile $outPath
wusa.exe $outPath # /quiet /forcerestart
