# 
function createMaintainConfig {
    param (
        $configName,
        $resourceGroup,
        $subscription,
        $rebootOpt = "IfRequired"
        
    )
    $RGName = $resourceGroup
    $configName = $configName + "-" + (Get-Date -Format "MMMyyyy")
    $scope = "InGuestPatch"
    $location = "westus"
    $timeZone = "India Standard Time" 
    $duration = "03:55"
    $upcomingSunday = (Get-Date ).AddDays((7 - [int](Get-Date).DayOfWeek) % 7) 
    $neededDay = $upcomingSunday.Date.AddHours(9.5).ToString("yyyy-MM-dd hh:mm")
    $startDateTime = $neededDay
    $ExpirationDateTime = $upcomingSunday.Date.AddDays(1).ToString("yyyy-MM-dd hh:mm")
    $recurEvery = "1Day"
    $WindowsParameterClassificationToInclude = "Security", "Critical";
    $LinuxParameterClassificationToInclude = "Security", "Critical";

    $rebootOptions = @("IfRequired", "Always", "Never")
    if ($rebootOpt -in $rebootOptions) {
        $RebootOption = $rebootOpt # "IfRequired"
        Set-AzContext -Subscription $subscription -ErrorAction Stop
        New-AzMaintenanceConfiguration -ResourceGroupName $RGName -Name $configName -MaintenanceScope $scope -Location $location -StartDateTime $startDateTime -ExpirationDateTime $ExpirationDateTime -Timezone $timeZone -Duration $duration -RecurEvery $recurEvery -WindowParameterClassificationToInclude $WindowsParameterClassificationToInclude -LinuxParameterClassificationToInclude $LinuxParameterClassificationToInclude -InstallPatchRebootSetting $RebootOption -ExtensionProperty @{"InGuestPatchMode" = "User" } -ErrorAction Stop
    }
    else {
        Write-Error Invalid Reboot Options Please select reboot option among IfRequired, Always or Never
    }
}

# createMaintainConfig -configName "" -resourceGroup "" -subscription "" -rebootOpt ''