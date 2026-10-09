function Invoke-RunCommand {
    [CmdletBinding(DefaultParameterSetName = 'ScriptBlock')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$VMName,
        [Parameter(Mandatory, Position = 1)]
        [string]$ResourceGroupName,
        # Either a script block or a path to a .ps1 file containing the script to execute
        [Parameter(Mandatory, ParameterSetName = 'ScriptBlock', Position = 2)]
        [string]$ScriptBlock,
        [Parameter(Mandatory, ParameterSetName = 'ScriptPath', Position = 2)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$ScriptPath,
        [Parameter(Position = 3)]
        [ValidateSet('RunPowerShellScript', 'RunShellScript')]
        [string]$CommandId = 'RunPowerShellScript',
        [Parameter()]
        [object]$Context,
        [int]$Retry = 3,
        [int]$BaseDelaySeconds = 30,
        [switch]$EnableJitter,
        [switch]$EnableExponentialBackoff
    )

    # # Resolve the script contents based on the active parameter set
    # if ($PSCmdlet.ParameterSetName -eq 'ScriptBlock') {
    #     $scriptString = $ScriptBlock
    # }
    # else {
    #     $scriptString = Get-Content -Path $ScriptPath -Raw
    # }

    $attempt = 0
    do {
        $attempt++
        try {
            if ($PSCmdlet.ParameterSetName -eq 'ScriptBlock') {
                $commandOutput = Invoke-AzVMRunCommand -VMName $VMName.Trim() -ResourceGroupName $ResourceGroupName.Trim() -CommandId $CommandId -ScriptString $ScriptBlock -DefaultProfile $Context -ErrorAction Stop
            }
            else {
                $commandOutput = Invoke-AzVMRunCommand -VMName $VMName.Trim() -ResourceGroupName $ResourceGroupName.Trim() -CommandId $CommandId -ScriptPath $ScriptPath -DefaultProfile $Context -ErrorAction Stop
            }
            if ($?) {
                $commandStatus = 'Success'
                Write-Output $commandOutput.Value[0].Message.Trim()
                break
            }
        }
        catch {
            Write-Output "Attempt $($attempt): An Error Occurred"
            Write-Output $_.Exception.Message
            $commandOutput = "Command Failed: $($_.Exception.Message)"
            $commandStatus = 'Failed'
            if ($attempt -lt $Retry) {
                $delay = $BaseDelaySeconds
                if ($EnableExponentialBackoff) {
                    $delay = $BaseDelaySeconds * [math]::Pow(2, $attempt - 1)
                }
                if ($EnableJitter) {
                    $delay = Get-Random -Minimum 0 -Maximum $delay
                }
                Write-Output "Retry will be attempted after a delay of $delay seconds (attempt $attempt)"
                Start-Sleep -Seconds $delay
            }
            elseif ($attempt -eq $Retry) {
                Write-Output "Retried $($attempt) times but it failed. Please check $($VMName)"
            }
        }
    } while ($attempt -lt $Retry)

    return [PSCustomObject]@{
        CommandOutput = $commandOutput
        CommandStatus = $commandStatus
    }
}


