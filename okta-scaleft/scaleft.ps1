#
$url = "https://dist.scaleft.com/repos/windows/stable/amd64/server-tools/"
$page = Invoke-WebRequest -uri $url
$versions = $page.Links | Where-Object { $_.href -match '^\.\/v\d+\.\d+\.\d+\/$' } | ForEach-Object {
    [PSCustomObject]@{
        Version = [version]($_.href.TrimStart('./v').TrimEnd('/'))
        Url     = "$url$($_.href.TrimStart('./'))"
        Text    = $_.OuterHtml
    }
}
$latest = $versions | Sort-Object -Property Version -Descending | Select-Object -First 1
$newPage = Invoke-WebRequest -Uri $latest.Url
#
$downloadUrl = "$($latest.Url)$($newPage.Links[0].href.TrimStart('./'))"
$downloadUrl
$filename = "okta-scaleft-$([string]$latest.Version).msi"
$tempFolder = (New-TemporaryFile).DirectoryName
Invoke-WebRequest -Uri $downloadUrl -OutFile (Join-Path $tempFolder $filename)