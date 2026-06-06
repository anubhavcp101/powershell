#
# VM Details
$VMName        = "vm-prod-01"
$ResourceGroup = "rg-prod"
$Subscription  = "Production"
$ShutdownDate  = ""
$DecomDate     = ""
$TicketNumber  = "CHG123456"

# Output File
$ExcelFile = "$($PWD.Path)\$VMName-DecomChecklist.xlsx"

# Excel Stuff
$excel = New-Object -ComObject Excel.Application
$excel.Visible = $true
$wb = $excel.Workbooks.Add()
$ws = $wb.Worksheets.Item(1)
$ws.range("A1:F2").merge()
$ws.Range("A1").value = "Title"
#
#$ws.Range("A1") | gm | ogv
$ws.Range("A1").HorizontalAlignment = [Microsoft.Office.Interop.Excel.XlHAlign]::xlHAlignCenter
$ws.Range("A1").VerticalAlignment = [Microsoft.Office.Interop.Excel.XlVAlign]::xlVAlignCenter
$ws.Range("A1").Font.Size = 21

# Info Section

$vmInfo = @(
    @("VM Name",        $VMName),
    @("Resource Group", $ResourceGroup),
    @("Subscription",   $Subscription),
    @("Shutdown Date",  $ShutdownDate),
    @("Decom Date",     $DecomDate),
    @("Ticket Number",  $TicketNumber)
)

$row = 3

foreach ($item in $vmInfo) {
    $ws.Cells.Item($row,1) = $item[0]
    $ws.Cells.Item($row,2) = $item[1]
    $row++
}

# Sub-title heading

$ws.range("A$($row):D$($row + 1)").merge()
$ws.Range("A$row").value = "Sub-Title"
$ws.Range("A$row").HorizontalAlignment = [Microsoft.Office.Interop.Excel.XlHAlign]::xlHAlignCenter
$ws.Range("A$row").VerticalAlignment = [Microsoft.Office.Interop.Excel.XlVAlign]::xlVAlignCenter
$ws.Range("A$row").Font.Size = 18


# Sub-title List

$row = $row + 3

$ws.Cells.Item($row,1) = "Step"
$ws.Cells.Item($row,2) = "Task"
$ws.Cells.Item($row,3) = "Status"

#$ws.Range("A$row:C$row").Font.Bold = $true
#$ws.Range("A$row:C$row").Interior.ColorIndex = 15

$row++

$tasks = @(
    "Shutdown VM",
    "Take backup before decommission",
    "Decommission VM",
    "Notify Application Team",
    "Notify Infrastructure Team",
    "Notify Monitoring Team",
    "Update ticket with decommission details"
)

$step = 1

foreach ($task in $tasks) {
    $ws.Cells.Item($row,1) = $step
    $ws.Cells.Item($row,2) = $task
    $ws.Cells.Item($row,3) = "Pending"

    $step++
    $row++
}

# Formatting

# Auto Fit Column Width 

$ws.range("A12:C19").Columns.AutoFit()

$ws.range("A3:B8").Columns.AutoFit()


# Make All-Border
$ws.range("A3:B8").Borders.LineStyle = 1
$ws.range("A3:B8").Borders.Weight = 2

$ws.range("A12:C19").Borders.LineStyle = 1
$ws.range("A12:C19").Borders.Weight = 2

$ws.Range("A9:D11").Borders.LineStyle = 1

$ws.Range("A1:F2").Borders.LineStyle = 1


# Save
$wb.SaveAs($ExcelFile)

# Cleanup
$wb.Close($true)
$excel.Quit()

[System.Runtime.Interopservices.Marshal]::ReleaseComObject($ws) | Out-Null
[System.Runtime.Interopservices.Marshal]::ReleaseComObject($wb) | Out-Null
[System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null

[GC]::Collect()
[GC]::WaitForPendingFinalizers()

Write-Host "Excel file created: $ExcelFile"