#
function Invoke-CsvProcessing {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$CsvPath,
        [string]$delimiter = '#',
        [string]$column = 'CommandOutput',
        [string[]]$newColumns = @('HostName', 'OS', 'PatchesInstalled', 'UpTime'),
        [string]$ConditionalColumn = 'CommandStatus'
    )
    $allFiles = Import-csv -Path $CsvPath
    $newItems = foreach ($item in $allFiles) {
        #
       
        if ( ($item.$ConditionalColumn -eq $true) -or
            ($item.$ConditionalColumn.trim().tolower() -eq 'success') -or
            ($item.$ConditionalColumn.trim().tolower() -eq 'true')
        ) {
            $segments = $item.$column.split($delimiter)
            $i = 0
            foreach ($newColumn in $newColumns) {
                $item.$newColumn = $segments[$i]
                $i++
            }
        }
        else {
            $i = 0
            foreach ($newColumn in $newColumns) {
                $item.$newColumn = 'Error'
                $i++
            }
        }
        
    }
    #

    

}
    