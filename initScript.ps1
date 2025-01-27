##
# in the init script with an environment variable
##
# $asrTaskStates = @("NotStarted","InProgress","Done")
# [System.Environment]::SetEnvironmentVariable('AsrTask', 'NotStarted', [System.EnvironmentVariableTarget]::Machine)
## Run this outside of init script to set right initial value
$initScriptBlock = {
    $env:Task = [System.Environment]::GetEnvironmentVariable('AsrTask', [System.EnvironmentVariableTarget]::Machine)
    if ($env:Task -eq 'NotStarted') {
        [System.Environment]::SetEnvironmentVariable('AsrTask', 'InProgress', [System.EnvironmentVariableTarget]::Machine)
        $env:Task = [System.Environment]::GetEnvironmentVariable('AsrTask', [System.EnvironmentVariableTarget]::Machine)
        Write-Host Starting the init script as its NotStarted
        # Simulating some task
        Start-Sleep -Seconds 30
        # Completed simulating the task
        Write-Host  the init script has completed    
        [System.Environment]::SetEnvironmentVariable('AsrTask', 'Done', [System.EnvironmentVariableTarget]::Machine)
        $env:Task = [System.Environment]::GetEnvironmentVariable('AsrTask', [System.EnvironmentVariableTarget]::Machine)
    }
    elseif ($env:Task -eq 'InProgress') {
        Write-Output the init script started has already started so will wait
        $taskState = [System.Environment]::GetEnvironmentVariable('AsrTask', [System.EnvironmentVariableTarget]::Machine)
        while ($taskState -eq 'InProgress') {
            Start-Sleep -Seconds 30
            # $env:Task = [System.Environment]::GetEnvironmentVariable('AsrTask', [System.EnvironmentVariableTarget]::Machine)
            $taskState = [System.Environment]::GetEnvironmentVariable('AsrTask', [System.EnvironmentVariableTarget]::Machine)
            Write-Output Currently init script is at $taskState state
        }
    }
    else {
        Write-Output the init script is already completed so will go ahead
    } }