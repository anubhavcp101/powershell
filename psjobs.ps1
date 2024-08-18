#
$task = {
    param (
    $time
    )
    # Simulate some work by using the Write-Host command
    Write-Host "Running task on VM..."
    #
    # Simulated task with a sleep to mimic a long-running process
    Start-Sleep -Seconds $time
    # Output a message to indicate completion
    Write-Host "Task completed."
    #
}
# Array to hold job objects
$jobs = @()

# Start multiple jobs
for ($i = 1; $i -le 3; $i++) {
    $job = Start-Job -ScriptBlock $task -ArgumentList (30+$i) -Name ("Job"+$(30+$i))
    $jobs += $job
}

# Monitor the PowerShell jobs
while ($jobs.Count -gt 0) {
    $remainingJobs = @()  # New array to hold remaining jobs

    foreach ($job in $jobs) {
        if ($job.State -eq 'Completed') {
            Write-host ------------------------
            Write-Host "Job $($job.Name) has completed successfully."
            $jobOutput = Receive-Job -Job $job
            Write-Host "Job Output: $jobOutput"
            Write-host ------------------------
        } elseif ($job.State -eq 'Failed') {
            Write-Host "Job $($job.Name) has failed."
            $jobError = $job.ChildJobs[0].JobStateInfo.Reason
            Write-Host "Job Error: $jobError"
        } else {
            Write-host ------------------------
            Write-Host "Job $($job.Name) is still running..."
            $remainingJobs += $job  # Add job to the remaining jobs array
            Write-Host (Receive-Job -Job $job)
            Write-host ------------------------
        }
    }

    $jobs = $remainingJobs  # Update the jobs array with only the remaining jobs
    Start-Sleep -Seconds 10
}

# Clean up completed jobs
foreach ($job in $jobs) {
    Remove-Job -Job $job
}

Write-Host "All jobs have completed."
