#
$paths = @(
    "C:\Windows\Temp",
    "C:\Temp",
    "C:\WindowsAzure\Logs",
    "C:\Packages\Plugins",
    "C:\inetpub\logs\LogFiles",
    #
    "C:\Windows\SoftwareDistribution\Download",
    "C:\Windows\MEMORY.DMP",
    "C:\Windows\Minidump",
    "C:\Windows\Panther"
    #
    "C:\Windows\Logs\DISM",
    "C:\Windows\Logs\CBS",
    "C:\Windows\System32\LogFiles",
    'C:\Users\*\AppData\Local\CrashDumps',
    'C:\Users\*\AppData\Local\Temp',
    'C:\ProgramData\Microsoft\Windows\WER',
    'C:\$Recycle.Bin',
    'C:\ProgramData\Docker',
    'C:\Program Files\Microsoft SQL Server',
    'C:\ProgramData\Microsoft\Windows\DeliveryOptimization'
)

foreach ($path in $paths) {
    if (Test-Path $path) {
        $size = (Get-ChildItem $path -File -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum

        [PSCustomObject]@{
            Path = $path
            SizeGB = [math]::Round($size / 1GB, 3)
        }
    }
}