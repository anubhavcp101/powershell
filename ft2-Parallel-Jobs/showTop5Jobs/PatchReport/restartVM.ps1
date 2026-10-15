#
function Restart-VM {
    [CmdletBinding(DefaultParameterSetName = 'ContextSet')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'ContextSet')]
        [object]$Context,

        [Parameter(Mandatory = $true, ParameterSetName = 'SubscriptionSet')]
        [string]$Subscription,

        [Parameter(Mandatory = $true)]
        [string]$VMName,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter()]
        [int]$delay = 180,
        [Parameter()]
        [int]$exitCount = 3
    )
    # Resolve context if SubscriptionId is provided
    if ($PSCmdlet.ParameterSetName -eq 'SubscriptionSet') {
        $Context = Set-AzContext -Subscription $Subscription -Scope Process
    }
    $tempFile = New-TemporaryFile
    Start-Transcript -FilePath $tempFile.FullName
    
    $exitCounter = 0
    $vmStatus = (Get-AzVM -Name $VMName.Trim() -ResourceGroupName $ResourceGroupName.Trim() -DefaultProfile $Context -Status)
    if (($vmStatus.Statuses[1].DisplayStatus -like 'VM running') ) {
        Restart-AzVM -Name $VMName.Trim() -ResourceGroupName $ResourceGroupName.Trim() -DefaultProfile $Context -Force
        Start-Sleep -Seconds 30
        $vmStatus = (Get-AzVM -Name $VMName.Trim() -ResourceGroupName $ResourceGroupName.Trim() -DefaultProfile $Context -Status)
        while (($vmStatus.Statuses[1].DisplayStatus -ne 'VM running') -or ( -not ($vmStatus.VMAgent))) {
            $exitCounter++
            if ($exitCounter -eq $exitCount) {
                Write-Output "VM $VMName is not coming up. Please check"
                Stop-Transcript
                return 1
            }
            Start-Sleep -Seconds $delay
            $vmStatus = (Get-AzVM -Name $VMName.Trim() -ResourceGroupName $ResourceGroupName.Trim() -DefaultProfile $Context -Status)
        }
        Stop-Transcript
        return 0
    }
    else {
        Write-Output "VM $VMName is not running"
    }

    # Stop-Transcript
    # $transcriptFileName = "Transcript-$(Get-Date -Format 'yyyy-MM-dd-hh-mm')-$($tempFile.BaseName).txt"
    # Copy-Item -Path $tempFile.FullName -Destination (Join-Path $PWD.Path $transcriptFileName)
    # Rename-Item -Path $tempFile.FullName -NewName $transcriptFileName -Force
    
}
# explorer (Split-Path ((New-TemporaryFile).FullName) -Parent)

function Invoke-ReapplyVM {
    <#
    .SYNOPSIS
        Reapplies the VM's provisioning state and waits for it to become healthy.
    .DESCRIPTION
        Triggers Set-AzVM -Reapply to re-run the Azure fabric provisioning for the VM.
        This is less intrusive than a redeploy — the VM stays on the same host — and is
        typically the recommended first recovery step when a VM is stuck in a Failed state
        or has configuration drift.

        After issuing the reapply the function polls until the VM reports 'VM running' with
        an operational VMAgent, up to $exitCount iterations (each separated by $delay seconds).
    .PARAMETER Context
        An Azure context object (from Set-AzContext) for the target subscription.
    .PARAMETER Subscription
        Subscription name or ID; the function creates a process-scoped context automatically.
    .PARAMETER VMName
        Name of the target virtual machine.
    .PARAMETER ResourceGroupName
        Resource group that contains the VM.
    .PARAMETER delay
        Seconds to wait between health-check polls. Default: 180.
    .PARAMETER exitCount
        Maximum number of poll iterations before giving up. Default: 3.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ContextSet')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'ContextSet')]
        [object]$Context,

        [Parameter(Mandatory = $true, ParameterSetName = 'SubscriptionSet')]
        [string]$Subscription,

        [Parameter(Mandatory = $true)]
        [string]$VMName,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter()]
        [int]$delay = 180,
        [Parameter()]
        [int]$exitCount = 3
    )

    # Resolve context if SubscriptionId is provided
    if ($PSCmdlet.ParameterSetName -eq 'SubscriptionSet') {
        $Context = Set-AzContext -Subscription $Subscription -Scope Process
    }

    $tempFile = New-TemporaryFile
    Start-Transcript -FilePath $tempFile.FullName

    $exitCounter = 0

    # Pre-flight: get current VM status
    $vmStatus = Get-AzVM -Name $VMName.Trim() -ResourceGroupName $ResourceGroupName.Trim() -DefaultProfile $Context -Status

    # Validate that the VM exists and is in a state where reapply makes sense
    if ($null -eq $vmStatus) {
        Write-Output "VM $VMName not found in resource group $ResourceGroupName"
        Stop-Transcript
        return 1
    }

    $powerState = $vmStatus.Statuses[1].DisplayStatus
    $provisioningState = $vmStatus.Statuses[0].DisplayStatus

    # Reapply is useful when the VM is running but stuck, or when provisioning has failed
    if (($powerState -like 'VM running') -or ($provisioningState -like '*failed*')) {
        Write-Output "Reapplying VM $VMName (Power: $powerState | Provisioning: $provisioningState)"

        try {
            Set-AzVM -Name $VMName.Trim() -ResourceGroupName $ResourceGroupName.Trim() -DefaultProfile $Context -Reapply -ErrorAction Stop
        }
        catch {
            Write-Output "Reapply command failed for VM $VMName : $($_.Exception.Message)"
            Stop-Transcript
            return 1
        }

        # Wait a brief moment for the operation to take effect
        Start-Sleep -Seconds 30

        # Poll until VM is running with VMAgent ready
        $vmStatus = Get-AzVM -Name $VMName.Trim() -ResourceGroupName $ResourceGroupName.Trim() -DefaultProfile $Context -Status
        while (($vmStatus.Statuses[1].DisplayStatus -ne 'VM running') -or (-not ($vmStatus.VMAgent))) {
            $exitCounter++
            if ($exitCounter -eq $exitCount) {
                Write-Output "VM $VMName did not recover after reapply ($exitCount checks). Please investigate."
                Stop-Transcript
                return 1
            }
            Write-Output "Waiting for VM $VMName to become healthy (attempt $exitCounter / $exitCount)..."
            Start-Sleep -Seconds $delay
            $vmStatus = Get-AzVM -Name $VMName.Trim() -ResourceGroupName $ResourceGroupName.Trim() -DefaultProfile $Context -Status
        }

        Write-Output "VM $VMName is running and VMAgent is responsive after reapply."
        Stop-Transcript
        return 0
    }
    else {
        Write-Output "VM $VMName is in state '$powerState' / '$provisioningState' — reapply may not help. Consider Invoke-RedeployVM instead."
        Stop-Transcript
        return 1
    }
}


function Invoke-RedeployVM {
    <#
    .SYNOPSIS
        Redeploys the VM to a new Azure host and waits for it to become healthy.
    .DESCRIPTION
        Triggers Set-AzVM -Redeploy which shuts down the VM, migrates it to a different
        physical host in the Azure datacenter, and powers it back on. Use this when
        reapply has not resolved the issue or when the problem is suspected to be
        host-level (hardware, networking, etc.).

        WARNING: Data on the temporary/ephemeral disk will be lost. Dynamic IP addresses
        may change.

        After issuing the redeploy the function polls until the VM reports 'VM running'
        with an operational VMAgent, up to $exitCount iterations.
    .PARAMETER Context
        An Azure context object (from Set-AzContext) for the target subscription.
    .PARAMETER Subscription
        Subscription name or ID; the function creates a process-scoped context automatically.
    .PARAMETER VMName
        Name of the target virtual machine.
    .PARAMETER ResourceGroupName
        Resource group that contains the VM.
    .PARAMETER delay
        Seconds to wait between health-check polls. Default: 180.
    .PARAMETER exitCount
        Maximum number of poll iterations before giving up. Default: 5.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ContextSet')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'ContextSet')]
        [object]$Context,

        [Parameter(Mandatory = $true, ParameterSetName = 'SubscriptionSet')]
        [string]$Subscription,

        [Parameter(Mandatory = $true)]
        [string]$VMName,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter()]
        [int]$delay = 180,
        [Parameter()]
        [int]$exitCount = 5
    )

    # Resolve context if SubscriptionId is provided
    if ($PSCmdlet.ParameterSetName -eq 'SubscriptionSet') {
        $Context = Set-AzContext -Subscription $Subscription -Scope Process
    }

    $tempFile = New-TemporaryFile
    Start-Transcript -FilePath $tempFile.FullName

    $exitCounter = 0

    # Pre-flight: get current VM status
    $vmStatus = Get-AzVM -Name $VMName.Trim() -ResourceGroupName $ResourceGroupName.Trim() -DefaultProfile $Context -Status

    # Validate that the VM exists
    if ($null -eq $vmStatus) {
        Write-Output "VM $VMName not found in resource group $ResourceGroupName"
        Stop-Transcript
        return 1
    }

    $powerState = $vmStatus.Statuses[1].DisplayStatus
    $provisioningState = $vmStatus.Statuses[0].DisplayStatus

    # Redeploy is valid for running VMs or VMs that failed to provision on the current host
    if (($powerState -like 'VM running') -or ($powerState -like 'VM stopped') -or ($provisioningState -like '*failed*')) {
        Write-Output "Redeploying VM $VMName to a new host (Power: $powerState | Provisioning: $provisioningState)"
        Write-Warning "Ephemeral disk data will be lost. Dynamic IPs may change."

        try {
            Set-AzVM -Name $VMName.Trim() -ResourceGroupName $ResourceGroupName.Trim() -DefaultProfile $Context -Redeploy -ErrorAction Stop
        }
        catch {
            Write-Output "Redeploy command failed for VM $VMName : $($_.Exception.Message)"
            Stop-Transcript
            return 1
        }

        # Redeploy involves a full migration — give extra initial wait time
        Write-Output "Waiting 60 seconds for the redeploy to initiate..."
        Start-Sleep -Seconds 60

        # Poll until VM is running with VMAgent ready
        $vmStatus = Get-AzVM -Name $VMName.Trim() -ResourceGroupName $ResourceGroupName.Trim() -DefaultProfile $Context -Status
        while (($vmStatus.Statuses[1].DisplayStatus -ne 'VM running') -or (-not ($vmStatus.VMAgent))) {
            $exitCounter++
            if ($exitCounter -eq $exitCount) {
                Write-Output "VM $VMName did not recover after redeploy ($exitCount checks over $($exitCount * $delay)s). Please investigate."
                Stop-Transcript
                return 1
            }
            Write-Output "Waiting for VM $VMName to become healthy (attempt $exitCounter / $exitCount)..."
            Start-Sleep -Seconds $delay
            $vmStatus = Get-AzVM -Name $VMName.Trim() -ResourceGroupName $ResourceGroupName.Trim() -DefaultProfile $Context -Status
        }

        Write-Output "VM $VMName is running and VMAgent is responsive after redeploy."
        Stop-Transcript
        return 0
    }
    elseif ($powerState -like 'VM deallocated') {
        Write-Output "VM $VMName is deallocated. Start the VM first (Start-AzVM) before attempting a redeploy."
        Stop-Transcript
        return 1
    }
    else {
        Write-Output "VM $VMName is in unexpected state '$powerState' / '$provisioningState'. Cannot redeploy."
        Stop-Transcript
        return 1
    }
}