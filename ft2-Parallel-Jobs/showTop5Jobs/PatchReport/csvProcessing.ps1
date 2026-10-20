#
function Invoke-CsvProcessing {
    [CmdletBinding(DefaultParameterSetName = 'ByColumn')]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
                if (-not (Test-Path $_)) {
                    throw "The path '$_' does not exist."
                }
                if (Test-Path $_ -PathType Container) {
                    $csvFiles = @(Get-ChildItem -Path $_ -Filter '*.csv' -File)
                    if ($csvFiles.Count -eq 0) {
                        throw "The directory '$_' does not contain any .csv files."
                    }
                }
                $true
            })]
        [string]$CsvPath,

        [ValidateNotNullOrEmpty()]
        [string]$delimiter = '#',

        [ValidateNotNullOrEmpty()]
        [string]$column = 'CommandOutput',

        [Parameter(ParameterSetName = 'ByColumn')]
        [ValidateNotNullOrEmpty()]
        [ValidateCount(1, 100)]
        [ValidateScript({
                if ([string]::IsNullOrWhiteSpace($_)) {
                    throw 'Column names in newColumns cannot be empty or whitespace.'
                }
                $true
            })]
        [string[]]$newColumns = @('HostName', 'OS', 'PatchesInstalled', 'UpTime'),

        [Parameter(ParameterSetName = 'ByIndex')]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
                if ($_.Count -eq 0) {
                    throw 'PropertyValueIndex hashtable cannot be empty.'
                }
                foreach ($entry in $_.GetEnumerator()) {
                    if ([string]::IsNullOrWhiteSpace($entry.Key)) {
                        throw 'Property names in PropertyValueIndex cannot be empty or whitespace.'
                    }
                    if ((-not ($entry.Value -is [int])) -or (-not ($entry.Value -as [int]))) {
                        throw "All values in PropertyValueIndex must be integers.  Invalid entry: $($entry.Key) = $($entry.Value)"
                    }
                }
                $true
            })]
        [hashtable]$PropertyValueIndex = @{'HostName' = 0; 'OS' = 1; 'PatchesInstalled' = 2; 'Uptime' = 3 },

        [ValidateNotNullOrEmpty()]
        [string]$ConditionalColumn = 'CommandStatus',

        [ValidateNotNullOrEmpty()]
        [string]$ErrorValue = 'Error',

        [ValidateNotNullOrEmpty()]
        [ValidateScript({
                if (-not (Test-Path $_ -PathType Leaf)) {
                    throw "The VerifyCsv path '$_' does not exist or is not a valid file."
                }
                $true
            })]
        [string]$VerifyCsv,

        [ValidateNotNullOrEmpty()]
        [string]$refVerifyColumn = 'Name',

        [ValidateNotNullOrEmpty()]
        [string]$diffVerifyColumn = 'VMName'
    )
    $sucessWords = @('success', 'okay', 'green', 'completed', 'successful', 'successfully', 'true', 'complete', 'done', 'finished', 'finish')
    function Add-ObjectProperties {
    [CmdletBinding(DefaultParameterSetName = 'ByProperties')]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Object]$Object,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ $_.Count -gt 0 })]
        [string[]]$Values,

        [Parameter(ParameterSetName = 'ByProperties', Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ $_.Count -gt 0 })]
        [string[]]$Properties,

        [Parameter(ParameterSetName = 'ByIndex', Mandatory = $true)]
        [ValidateNotNull()]
        [ValidateScript({
                if ($_.Count -le 0) {
                    throw "The PropertyValueIndex hashtable cannot be empty."
                }

                foreach ($entry in $_.GetEnumerator()) {
                    if ([string]::IsNullOrWhiteSpace($entry.Key)) {
                        throw "Property names in PropertyValueIndex cannot be empty or whitespace."
                    }
                    if ((-not ($entry.Value -is [int])) -or (-not ($entry.Value -as [int]))) {
                        throw "All values in PropertyValueIndex must be integers.  Invalid entry: $($entry.Key) = $($entry.Value)"
                    }
                }
                $true
            })]
        [hashtable]$PropertyValueIndex,

        [Parameter()]
        [switch]$Overwrite
    )

    # Runtime validation to ensure matching counts between values and target properties
    if ($PSCmdlet.ParameterSetName -eq 'ByProperties') {
        if ($Values.Count -ne $Properties.Count) {
            throw "In the 'ByProperties' parameter set, the number of values ($($Values.Count)) must match the number of properties ($($Properties.Count))."
        }
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'ByIndex') {
        if ($Values.Count -ne $PropertyValueIndex.Count) {
            throw "In the 'ByIndex' parameter set, the number of values ($($Values.Count)) must match the number of entries in PropertyValueIndex ($($PropertyValueIndex.Count))."
        }
    }

    # Warn about overwriting existing properties unless -Overwrite is specified
    if (-not $Overwrite) {
        $targetProps = if ($PSCmdlet.ParameterSetName -eq 'ByIndex') { $PropertyValueIndex.Keys } else { $Properties }
        $existing = $Object.PSObject.Properties.Name
        $overlap = $targetProps | Where-Object { $_ -in $existing }
        if ($overlap) {
            Write-Warning "The following properties already exist on the object and will be overwritten: $($overlap -join ', ')"
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'ByIndex') {
        foreach ($key in $PropertyValueIndex.Keys) {
            $Object | Add-Member -NotePropertyName $key -NotePropertyValue $Values[$PropertyValueIndex[$key]] -Force
        }
    }
    else {
        $i = 0
        foreach ($prop in $Properties) {
            $Object | Add-Member -NotePropertyName $prop -NotePropertyValue $Values[$i] -Force
            $i++
        }
    }

    return $Object
}

    #
    # Import CSV (supports both a single CSV file or a directory of CSV files)
    if (Test-Path $CsvPath -PathType Container) {
        $csvFiles = Get-ChildItem -Path $CsvPath -Filter '*.csv' -File
        try {
            $allItems = @($csvFiles | Import-Csv -ErrorAction Stop)
        }
        catch {
            throw "Failed to import CSV files from directory '$CsvPath': $($_.Exception.Message)"
        }
    }
    else {
        try {
            $allItems = @(Import-Csv -Path $CsvPath -ErrorAction Stop)
        }
        catch {
            throw "Failed to import CSV file '$CsvPath': $($_.Exception.Message)"
        }
    }

    if ($allItems.Count -eq 0) {
        throw "The CSV input at '$CsvPath' contains no data rows."
    }

    # Extract CSV header names
    $csvHeaders = $allItems[0].PSObject.Properties.Name

    # 1. Validate that required processing columns exist in the CSV
    if ($column -notin $csvHeaders) {
        throw "The specified column '$column' does not exist in '$CsvPath'. Available columns: $($csvHeaders -join ', ')"
    }
    if ($ConditionalColumn -notin $csvHeaders) {
        throw "The conditional column '$ConditionalColumn' does not exist in '$CsvPath'. Available columns: $($csvHeaders -join ', ')"
    }

    # 2. Check for duplicate column names in newColumns
    if ($PSCmdlet.ParameterSetName -eq 'ByColumn' -and ($newColumns.Count -ne ($newColumns | Select-Object -Unique).Count)) {
        throw "Parameter 'newColumns' cannot contain duplicate column names."
    }

    # 3. Warn if new columns will overwrite existing columns
    $targetProps = if ($PSCmdlet.ParameterSetName -eq 'ByIndex') { $PropertyValueIndex.Keys } else { $newColumns }
    $overlapping = $targetProps | Where-Object { $_ -in $csvHeaders }
    if ($overlapping) {
        Write-Warning "The following target columns already exist in '$CsvPath' and will be overwritten: $($overlapping -join ', ')"
    }

    # 4. Handle VerifyCsv validations and comparison
    if ($PSBoundParameters.ContainsKey('VerifyCsv') -or $PSBoundParameters.ContainsKey('refVerifyColumn') -or $PSBoundParameters.ContainsKey('diffVerifyColumn')) {
        if (-not $PSBoundParameters.ContainsKey('VerifyCsv') -or -not $PSBoundParameters.ContainsKey('refVerifyColumn') -or -not $PSBoundParameters.ContainsKey('diffVerifyColumn')) {
            Write-Warning "Please provide all three parameters for verification: VerifyCsv, refVerifyColumn, and diffVerifyColumn"
            return
        }

        # Check diffVerifyColumn exists in CsvPath
        if ($diffVerifyColumn -notin $csvHeaders) {
            throw "The diff verify column '$diffVerifyColumn' does not exist in '$CsvPath'. Available columns: $($csvHeaders -join ', ')"
        }

        # Import and validate VerifyCsv
        $verifyItems = @(Import-Csv -Path $VerifyCsv)
        if ($verifyItems.Count -eq 0) {
            throw "The verification CSV file at '$VerifyCsv' contains no data rows."
        }
        $verifyHeaders = $verifyItems[0].PSObject.Properties.Name
        if ($refVerifyColumn -notin $verifyHeaders) {
            throw "The ref verify column '$refVerifyColumn' does not exist in '$VerifyCsv'. Available columns: $($verifyHeaders -join ', ')"
        }

        $missingRows = Compare-Object -ReferenceObject ($verifyItems.$refVerifyColumn) -DifferenceObject ($allItems.$diffVerifyColumn) | Where-Object {
            $_.SideIndicator -eq '<='
        }
        if ($missingRows) {
            $missingRows | ForEach-Object {
                $_.$diffVerifyColumn = $_.InputObject
                if ($PSCmdlet.ParameterSetName -eq 'ByIndex') {
                    $allItems += (Add-ObjectProperties -Object $_ -Properties $PropertyValueIndex.Keys -Values (@($ErrorValue) * $PropertyValueIndex.Count) )
                }
                else {
                    $allItems += (Add-ObjectProperties -Object $_ -Properties $newColumns -Values (@($ErrorValue) * $newColumns.length) )
                }
            }
        }
    }
    
    $newItems = foreach ($item in $allItems) {
        #
       
        if ( ($item.$ConditionalColumn -eq $true) -or
            ($item.$ConditionalColumn.trim().tolower() -in $sucessWords )
        ) {
            $segments = $item.$column.split($delimiter)
            if ($PSCmdlet.ParameterSetName -eq 'ByIndex') {
                Add-ObjectProperties -Object $item -PropertyValueIndex $PropertyValueIndex -Values $segments
            }
            else {
                Add-ObjectProperties -Object $item -Properties $newColumns -Values $segments
            }
        }
        else {
            if ($PSCmdlet.ParameterSetName -eq 'ByIndex') {
                Add-ObjectProperties -Object $item -Properties $PropertyValueIndex.Keys -Values (@($ErrorValue) * $PropertyValueIndex.Count) 
            }
            else {
                Add-ObjectProperties -Object $item -Properties $newColumns -Values (@($ErrorValue) * $newColumns.length) 
            }
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

Get-Command Invoke-CsvProcessing -Syntax
    