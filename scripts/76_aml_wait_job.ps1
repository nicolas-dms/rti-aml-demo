<#
.SYNOPSIS
    M5 - Wait for an AML job by polling its status, and explain a failure.

.DESCRIPTION
    Read-only. Polls "az ml job show --query status" instead of streaming, so it is
    safe in CI (no dependency on log streaming or on task notifications).
    Exit 0 only when the job is Completed. On Failed/Canceled/NotResponding it
    prints, for every failed child job, the tail of its user log (this is where the
    prep verification message or the register gate message lives) and exits 1.
    Exit 2 on timeout (the job keeps running in AML).

    Works with any az session that can read the workspace: the laptop account or
    the sc-rti-aml-dev service connection inside AzureCLI@2.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $JobName,
    [string] $ResourceGroup = 'rg-rti-aml-demo',
    [string] $Workspace = 'aml-rti-demo',
    [int] $TimeoutMin = 60,
    [int] $PollSec = 20,
    [int] $LogTailLines = 40
)

$ErrorActionPreference = 'Stop'

function Invoke-Az {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $errorFile = [System.IO.Path]::GetTempFileName()
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $stdout = & az @Arguments 2> $errorFile
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    $stderr = ''
    if (Test-Path $errorFile) {
        $stderr = (Get-Content -Path $errorFile -Raw)
        Remove-Item -Path $errorFile -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ ExitCode = $exitCode; StdOut = ($stdout | Out-String); StdErr = $stderr }
}

$terminalFailure = @('Failed', 'Canceled', 'Cancelled', 'NotResponding')
$deadline = (Get-Date).AddMinutes($TimeoutMin)
$last = ''
$errors = 0

Write-Host "Waiting for AML job $JobName (timeout $TimeoutMin min, poll $PollSec s) ..."
while ($true) {
    $r = Invoke-Az -Arguments @('ml', 'job', 'show', '--name', $JobName,
        '-g', $ResourceGroup, '-w', $Workspace, '--query', 'status', '-o', 'tsv')
    if ($r.ExitCode -ne 0) {
        # A transient az error must not be read as a job status.
        $errors++
        Write-Host "  az error ($errors/5): $($r.StdErr.Trim())"
        if ($errors -ge 5) { throw "Cannot read the status of job $JobName after 5 attempts." }
    }
    else {
        $errors = 0
        $status = $r.StdOut.Trim()
        if ($status -ne $last) {
            Write-Host ("  {0:HH:mm:ss}  status = {1}" -f (Get-Date), $status)
            $last = $status
        }
        if ($status -eq 'Completed') {
            Write-Host "Job $JobName Completed." -ForegroundColor Green
            exit 0
        }
        if ($terminalFailure -contains $status) { break }
    }
    if ((Get-Date) -gt $deadline) {
        Write-Host "TIMEOUT after $TimeoutMin min, last status '$last'. The job keeps running in AML." -ForegroundColor Yellow
        exit 2
    }
    Start-Sleep -Seconds $PollSec
}

Write-Host "`nJob $JobName ended with status '$last'." -ForegroundColor Red

# Best effort: which step failed and why. The message of the gate / of the
# snapshot verification is written by the component, so it is in the step's log.
try {
    $children = Invoke-Az -Arguments @('ml', 'job', 'list', '--parent-job-name', $JobName,
        '-g', $ResourceGroup, '-w', $Workspace, '-o', 'json')
    if ($children.ExitCode -eq 0) {
        $items = $children.StdOut | ConvertFrom-Json
        foreach ($child in $items) {
            Write-Host ("  step {0,-10} {1,-10} {2}" -f $child.display_name, $child.status, $child.name)
        }
        foreach ($child in ($items | Where-Object { $terminalFailure -contains $_.status })) {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("aml-" + $child.name)
            if (Test-Path $dir) { Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $download = Invoke-Az -Arguments @('ml', 'job', 'download', '--name', $child.name,
                '--download-path', $dir, '-g', $ResourceGroup, '-w', $Workspace)
            if ($download.ExitCode -ne 0) {
                Write-Host "Download of the logs of step '$($child.display_name)' failed (exit $($download.ExitCode)):"
                Write-Host $download.StdErr
            }
            $files = @(Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue)
            $log = $files | Where-Object { $_.Name -eq 'std_log.txt' } | Select-Object -First 1
            if (-not $log) {
                $log = $files | Where-Object { $_.FullName -match 'user_logs' -and $_.Extension -eq '.txt' } |
                    Select-Object -First 1
            }
            if ($log) {
                Write-Host "`n--- last $LogTailLines lines of the log of step '$($child.display_name)' ($($log.Name)) ---"
                Get-Content -Path $log.FullName -Tail $LogTailLines | ForEach-Object { Write-Host $_ }
                Write-Host '--- end of log ---'
            }
            else {
                Write-Host "No step log found for '$($child.display_name)' ($($files.Count) file(s) downloaded). See studio."
            }
        }
    }
}
catch {
    Write-Host "Could not collect step logs: $($_.Exception.Message)"
}
exit 1
