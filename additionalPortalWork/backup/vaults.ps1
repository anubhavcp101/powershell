#
$vaultName = "testVault"
$vaultRG = "rg-drTest"
$location = "westus3"
New-AzRecoveryServicesVault -Name $vaultName -ResourceGroupName $vaultRG -Location $location -PublicNetworkAccess "Disabled"
$vault = Get-AzRecoveryServicesVault -Name $vaultName 
Set-AzRecoveryServicesBackupProperty  -Vault $vault -BackupStorageRedundancy LocallyRedundant
#
Set-AzRecoveryServicesVaultContext -Vault $vault
$vaultId = $vault.ID
Set-AzRecoveryServicesBackupProperty -Vault $vault -BackupStorageRedundancy LocallyRedundant

#
$SchPol = Get-AzRecoveryServicesBackupSchedulePolicyObject -WorkloadType AzureVM
$SchPol.ScheduleRunFrequency = "Weekly"
$SchPol.ScheduleRunTimes.Clear()
$DT = Get-Date -Hour 21 -Minute 30 -Day 12 -Month 2 -Second 0 -Millisecond 0
$SchPol.ScheduleRunTimes.Add($DT.ToUniversalTime())
$SchPol.ScheduleRunTimeZone = [System.TimeZoneInfo]::Utc.Id
$SchPol.ScheduleRunDays = @("Sunday","Monday","Tuesday")

#Retention Policy
$RetPol = Get-AzRecoveryServicesBackupRetentionPolicyObject -WorkloadType AzureVM
$RetPol.IsDailyScheduleEnabled = $false
$RetPol.IsWeeklyScheduleEnabled = $true
$RetPol.IsMonthlyScheduleEnabled = $false
$RetPol.IsYearlyScheduleEnabled = $false

$RetPol.WeeklySchedule.DurationCountInWeeks = 14
$RetPol.WeeklySchedule.DaysOfTheWeek = @("Sunday","Monday","Tuesday")

$policy = New-AzRecoveryServicesBackupProtectionPolicy -Name "bkpPolicy2" -WorkloadType AzureVM -SchedulePolicy $SchPol -RetentionPolicy $RetPol
<#
Currently Working on this 
#>

# Replication Policy 
#New-AzRecoveryServicesAsrPolicy -AzureToAzure -Name "myReplicationPolicy" -RecoveryPointRetentionInHours 24 -ApplicationConsistentSnapshotFrequencyInHours 1


