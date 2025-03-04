#
$RAM = (Get-WmiObject -Class Win32_ComputerSystem).TotalPhysicalMemory / 1MB
$MinSize = [math]::Round(2 * $RAM)
$TDriveSize = (Get-PSDrive -Name T).Used / 1MB + (Get-PSDrive -Name T).Free / 1MB
$MaxSize = [math]::Round(0.84 * $TDriveSize)
$PageFile = Get-WmiObject Win32_PageFileSetting
$PageFile.InitialSize = $MinSize
#
$PageFile.MaximumSize = $MaxSize
$PageFile.Name = "T:\pagefile.sys"
try {
    $PageFile.Put()
    #
    Write-Output "Page file successfully configured on T:\pagefile.sys"
} catch {
    Write-Error "Error configuring page file: $($_.Exception.Message)"
}
Write-Output "A system reboot is required for these changes to take effect. So, rebooting it."
shutdown /r 