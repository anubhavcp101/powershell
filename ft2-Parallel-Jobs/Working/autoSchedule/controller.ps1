#
$subscription = ''
$rg = ''
$automationAccountName = ''
$targetRunbook = ''

# its adding the timezone offset to the time provided here so adjust it accordingly
#
$initDate = Get-Date -Date (Get-Date).Date -Month (Get-Date).Month -Year (Get-Date).Year -Hour 16 -Minute 0 -Second 0
$dates = @(
    ($initDate).AddDays(3),
    ($initDate).AddDays(5),
    #
    ($initDate).AddDays(7),
    ($initDate).AddDays(9),
    ($initDate).AddDays(11)
)
#
Set-AzContext -Subscription $subscription

$counter = 0
foreach ( $date in $dates) {
    $scheduleName = "OneTimeSchedule-$($initDate.Month)-$($initDate.Year)-$($counter)"
    $counter++
    New-AzAutomationSchedule -Name $scheduleName -StartTime $date -TimeZone 'India Standard Time' -ResourceGroupName $rg -AutomationAccountName $automationAccountName -OneTime

    Register-AzAutomationScheduledRunbook -ScheduleName $scheduleName -RunbookName $targetRunbook -ResourceGroupName $rg -AutomationAccountName $automationAccountName -Parameters @{'messages'= @('New3','Mew3','Few3')}

}

<#
# to get automation schedule in past time

get-azAutomationSchedule -ResourceGroupName $rg -AutomationAccountName $automationAccountName | Where-Object { $_.Name -match 'OneTimeSchedule-\d{1}-\d{4}-\d{1}' } | Where-Object { $_.NextRun.DateTime -lt (Get-Date) }

get-azAutomationSchedule -ResourceGroupName $rg -AutomationAccountName $automationAccountName | Where-Object { $_.Name -match 'OneTimeSchedule-\d{1}-\d{4}-\d{1}' } | Where-Object { $null -eq $_.NextRun } | Where-Object { $_.Frequency -eq 'Onetime' } | measure

# and removing them
get-azAutomationSchedule -ResourceGroupName $rg -AutomationAccountName $automationAccountName | Where-Object { $_.Name -match 'OneTimeSchedule-\d{1}-\d{4}-\d{1}' } | Where-Object { $_.NextRun.DateTime -gt (Get-Date) } | Where-Object { $_.Frequency -eq 'Onetime' } | Remove-AzAutomationSchedule -Force
#>
