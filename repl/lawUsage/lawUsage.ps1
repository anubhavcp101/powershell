#
<#
The needs a CSV file having columns Subscription, WorkSpaceId and Name where name is name of Log Analytics Workspace, and
WorkspaceId is the workspaceid(customerid) of the workspace.  
This is to find Tables present in a workspace and to which resource the logs belongs to.
Tables.csv file helps to find workspace which don't have any data in any Table and
LogResult.csv is the final result of the script
#>
$logs = Import-Csv -Path "./logs.csv" # subscription, workspaceid, Name
$tablesQuery = 'Usage
| where TimeGenerated  > ago(99d)
| summarize IngestedBytes = sum(Quantity) by Table = DataType'
"subscription,Name,workspaceid,tableList" | Out-File -FilePath "./Tables.csv" -Append -Force
"subscription,Name,workspaceid,table" | Out-File -FilePath "./TablesRows.csv" -Append -Force
$logs | ForEach-Object {
  #
  Set-AzContext -Subscription $_.subscription
  $tablesResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $_.workspaceid -Query $tablesQuery
  $tableList = $tablesResult.Results.Table -join ";"
  #
  "$($_.subscription),$($_.Name),$($_.workspaceid),$($tableList)" | Out-File -FilePath "./Tables.csv" -Append -Force
  foreach ($table in $tablesResult.Results.Table) {
    "$($_.subscription),$($_.Name),$($_.workspaceid),$($table)" | Out-File -FilePath "./TablesRows.csv" -Append -Force
  }
}

$tables = Import-Csv -Path "./TablesRows.csv"
$tables | ForEach-Object {
  $resourceQuery = '| where TimeGenerated > ago(99d)
| distinct _ResourceId
| project name = split(_ResourceId,"/")[-1]
| summarize resources = strcat_array(make_list(name),"; ")'
  $minTime = '
| where TimeGenerated > ago(99d)
| summarize MinTime = min(TimeGenerated)'
  $maxTime = '
| where TimeGenerated > ago(99d)
| summarize MaxTime = max(TimeGenerated)'
  $resourceQueryRes = Invoke-AzOperationalInsightsQuery -WorkspaceId $_.workspaceid -Query ("$($_.table)" + $resourceQuery)
  $minTimeRes = Invoke-AzOperationalInsightsQuery -WorkspaceId $_.workspaceid -Query ("$($_.table)" + $minTime)
  $maxTimeRes = Invoke-AzOperationalInsightsQuery -WorkspaceId $_.workspaceid -Query ("$($_.table)" + $maxTime)
  $_ | Add-Member -NotePropertyName "MaxTime" -NotePropertyValue $maxTimeRes.Results.MaxTime
  $_ | Add-Member -NotePropertyName "MinTime" -NotePropertyValue $minTimeRes.Results.MinTime
  $_ | Add-Member -NotePropertyName "Resources" -NotePropertyValue $resourceQueryRes.Results.resources
}

$tables | Export-Csv -Path "./LogResult.csv" -NoTypeInformation -Force
Rename-Item -Path "./TablesRows.csv" -NewName "TablesRows-$(Get-Date -Format 'dd-MM-yyyy-hh-mm-ss').csv"
Rename-Item -Path "./Tables.csv" -NewName "Tables-$(Get-Date -Format 'dd-MM-yyyy-hh-mm-ss').csv"
