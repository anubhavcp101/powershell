# test.ps1 - Pester Test Suite for updateReport.ps1

Describe "Offline Patch Report Test Suite" {

    Context "When running updateReport.ps1 offline with mock Azure data" {

        It "Runs background jobs offline, verifies progress, and generates final CSV report" {

            # Define mock Azure functions string to inject inside $task block (line 6 of updateReport.ps1)
            $mockHeader = @"
function Set-AzContext { return `$null }
function Get-AzVM {
    param(`$Name)
    return [PSCustomObject]@{
        Statuses = @(
            `$null,
            [PSCustomObject]@{ DisplayStatus = 'VM running' }
        )
        VMAgent  = `$true
        OsName   = 'Windows Server 2022'
    }
}
function Invoke-AzVMRunCommand {
    param(`$VMName)
    Start-Sleep -Seconds 1
    return [PSCustomObject]@{
        Value = @(
            [PSCustomObject]@{
                Message = "`$VMName#Windows Server 2022#KB5012345;KB5012346#10days,2hrs,15mins"
            }
        )
    }
}
"@

            # Read updateReport.ps1 and inject mockHeader directly into the $task definition block
            $scriptContent = Get-Content ".\updateReport.ps1" -Raw
            $injectedScript = $scriptContent -replace '(\$task\s*=\s*\{)', "`$1`n$mockHeader"

            # Execute the injected script in local scope
            Invoke-Expression $injectedScript

            # Reset working directory back to script root (since updateReport.ps1 changes location to Report-Temp-*)
            Set-Location $PSScriptRoot

            # Assert: Verify local Report-Temp-* directory was created
            $tempDirs = Get-ChildItem -Path $PSScriptRoot -Filter "Report-Temp-*"
            $tempDirs.Count | Should BeGreaterThan 0

            # Assert: Verify final Report-*.csv was generated
            $reportFiles = Get-ChildItem -Path $PSScriptRoot -Filter "Report-*.csv"
            $reportFiles.Count | Should BeGreaterThan 0

            # Assert: Check content of the latest generated report CSV
            $latestReport = $reportFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $reportData = Import-Csv -Path $latestReport.FullName
            $reportData.Count | Should Be 2
            $reportData[0].CommandStatus | Should Be 'Success'
            $reportData[0].HostName | Should Be 'TestVM01'
            $reportData[0].Patches | Should Be 'KB5012345;KB5012346'
            $reportData[1].HostName | Should Be 'TestVM02'
        }
    }
}
