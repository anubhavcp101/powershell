#
$output = Get-Content -Path ./test.log -Raw

$log_pattern = '(?<timestamp>[A-Za-z]{3}\s+\d{2}\s+\d{2}:\d{2}:\d{2})\s+(?<action>(?:Installed|Updated|Erased)):\s+(?<package>\S+)' 
# $log_pattern = '(?<timestamp>[A-Za-z]{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+(?<action>Installed|Updated|Erased):\s+(?<package>.+)\.(?<linux>el\d+(?:_\d+)?)\.(?:(?<os>[a-z]+)\.)?(?<release>\d+)\.(?<arch>x86_64|i\d86|aarch64)$'
# '(?<package>\S+)\.(?<release>el\d(?:_\d\.\d)?)(?<os>\.[a-z]+\.\d)?\.x86_64'
$logMatches = [regex]::Matches($output, $log_pattern)

#
$result = foreach ( $match in $logMatches) {
    [PSCustomObject]@{
        Timestamp = $match.Groups['timestamp'].Value
        Action    = $match.Groups['action'].Value
        Package   = $match.Groups['package'].Value
    }
}

$result | Format-table -AutoSize