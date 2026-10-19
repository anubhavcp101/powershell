#
function Invoke-CsvProcessing {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateScript({ Test-Path $_ })]
        [string]$CsvPath,
        [string]$delimiter = '#',
        [string]$column = 'CommandOutput',
        [string[]]$newColumns = @('HostName', 'OS', 'PatchesInstalled', 'UpTime'),
        [hashtable]$PropertyValueIndex = @{'HostName' = 0; 'OS' = 1; 'PatchesInstalled' = 2; 'Uptime' = 3 },
        [string]$ConditionalColumn = 'CommandStatus',
        [string]$ErrorValue = 'Error',
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$VerifyCsv,
        [string]$refVerifyColumn = 'Name',
        [string]$diffVerifyColumn = 'VMName'
    )
    $sucessWords = @('success', 'okay', 'green', 'completed', 'successful', 'successfull', 'true', 'complete', 'done', 'finished', 'finish')
    function Add-ObjectProperties {
        param(
            [Object]$Object,
            [string[]]$Properties,
            [string[]]$Values,
            [hashtable]$PropertyValueIndex
        )

        if ( -not $PSBoundParameters.Contains('PropertyValueIndex')) {
            $i = 0
            foreach ( $prop in $Properties) {
                $Object | Add-Member -NotePropertyName $prop -NotePropertyValue $Values[$i] -Force
                $i++
            } 
        }

        if ($PSBoundParameters.Contains('PropertyValueIndex')) {
            foreach ( $key in $PropertyValueIndex.Keys) {
                $Object | Add-Member -NotePropertyName $key -NotePropertyValue $Values[$PropertyValueIndex[$key]] -Force
            } 
        }

        return $Object
    }
    #
    $allItems = Import-csv -Path $CsvPath

    if ( $PSBoundParameters.Contains('VerifyCsv') -or $PSBoundParameters.Contains('refVerifyColumn') -or $PSBoundParameters.Contains('diffVerifyColumn') ) {
        if ( (!$PSBoundParameters.Contains('VerifyCsv')) -or (!$PSBoundParameters.Contains('refVerifyColumn')) -or (!$PSBoundParameters.Contains('diffVerifyColumn')) ) {
            Write-Warning "Please provide all the parameters for VerifyCsv, refVerifyColumn, and diffVerifyColumn"
            return
        }
        if ( (!$VerifyCsv) -or (!$refVerifyColumn) -or (!$diffVerifyColumn)) {
            Write-Warning "These params can't be null or empty strings: VerifyCsv, refVerifyColumn, and diffVerifyColumn"
            return
        }
    }
    
    if ($PSBoundParameters.Contains('VerifyCsv') -and $PSBoundParameters.Contains('refVerifyColumn') -and $PSBoundParameters.Contains('diffVerifyColumn')) {
        $missingRows = Compare-Object -ReferenceObject ((Import-csv $VerifyCsv).$refVerifyColumn) -DifferenceObject $allItems.$diffVerifyColumn | Where-Object {
            $_.SideIndicator -eq '<='
        }
        if ($missingRows) {
            $missingRows | ForEach-Object {
                $_.$diffVerifyColumn = $_.InputObject
                $allItems += (Add-ObjectProperties -Object $_ -Properties $newColumns -Values (@($ErrorValue) * $newColumns.length) )
            }
        }   

    }
    
    $newItems = foreach ($item in $allItems) {
        #
       
        if ( ($item.$ConditionalColumn -eq $true) -or
            ($item.$ConditionalColumn.trim().tolower() -in $sucessWords )
        ) {
            $segments = $item.$column.split($delimiter)
            if ( -not $PSBoundParameters.Contains('PropertyValueIndex')) {
                Add-ObjectProperties -Object $item -Properties $newColumns -Values $segments
            }
            else {
                Add-ObjectProperties -Object $item -PropertyValueIndex $PropertyValueIndex -Values $segments
            }
        }
        else {
            Add-ObjectProperties -Object $item -Properties $newColumns -Values (@($ErrorValue) * $newColumns.length) 
        }
        
    }

    $dirPath = $null 
    if ( Test-Path $CsvPath -PathType Container) {
        $dirPath = $CsvPath
    }
    else {
        $dirPath = Split-Path $CsvPath -Parent
    }
    $newLocation = Join-Path $dirPath "Processed-$(Get-Date -Format 'yyyy-MM-dd_HH-mm').csv"
    $newItems | Export-csv -Path $newLocation -NoTypeInformation
    Write-Output "Processed CSV saved to $newLocation"
    $env:NewLocation = $newLocation
    Set-Clipboard -Value $newLocation
    return $allItems
}
    