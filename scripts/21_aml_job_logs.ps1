<#
.SYNOPSIS
    Downloads and prints the logs of the failed child jobs of an AML pipeline run.

.DESCRIPTION
    "Pipeline has failed child jobs" tells you nothing. The real message is in the
    child job's user_logs/std_log.txt (the Python traceback) or, when the failure
    happened before Python started, in system_logs (image build, data mount, RBAC).
    This script fetches both.

.NOTES
    Uses the same Invoke-Az wrapper as 20_aml_train.ps1: on Windows PowerShell 5.1
    with $ErrorActionPreference = 'Stop', any native command writing to stderr
    raises a terminating NativeCommandError, and 2>$null does not prevent it.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $JobName,
    [string] $ResourceGroup = (& "$PSScriptRoot\lib\cfg.ps1" AZURE_RESOURCE_GROUP -Required),
    [string] $Workspace = (& "$PSScriptRoot\lib\cfg.ps1" AML_DEV_WORKSPACE -Required),
    [string] $DownloadRoot = '.jobs',
    [int] $TailLines = 120
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

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

    [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = ($stdout | Out-String)
        StdErr   = $stderr
    }
}

function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $result = Invoke-Az -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw ("az " + ($Arguments -join ' ') + " -> exit $($result.ExitCode)`n" + $result.StdErr)
    }
    return ($result.StdOut | ConvertFrom-Json)
}

Write-Host "=== AML child job logs ===" -ForegroundColor Cyan
Write-Host "parent job : $JobName"
Write-Host ""

$children = Invoke-AzJson -Arguments @(
    'ml', 'job', 'list',
    '--parent-job-name', $JobName,
    '-g', $ResourceGroup,
    '-w', $Workspace,
    '-o', 'json'
)

if (-not $children) {
    throw "No child job found for $JobName."
}

Write-Host "child jobs:"
foreach ($child in $children) {
    Write-Host ("  {0,-12} {1,-40} {2}" -f $child.status, $child.display_name, $child.name)
}
Write-Host ""

$failed = @($children | Where-Object { $_.status -eq 'Failed' })
if (-not $failed) {
    Write-Host "No failed child job. Nothing to inspect." -ForegroundColor Green
    return
}

foreach ($child in $failed) {
    $target = Join-Path $DownloadRoot $child.name
    if (Test-Path $target) {
        Remove-Item -Path $target -Recurse -Force
    }
    New-Item -ItemType Directory -Path $target -Force | Out-Null

    Write-Host "downloading $($child.display_name) -> $target ..." -ForegroundColor Yellow
    $download = Invoke-Az -Arguments @(
        'ml', 'job', 'download',
        '--name', $child.name,
        '-g', $ResourceGroup,
        '-w', $Workspace,
        '--download-path', $target
    )
    if ($download.ExitCode -ne 0) {
        Write-Warning "download failed -> exit $($download.ExitCode)"
        Write-Host $download.StdErr
        continue
    }

    $logFiles = Get-ChildItem -Path $target -Recurse -File -Include '*.txt', '*.log' |
        Sort-Object FullName

    if (-not $logFiles) {
        Write-Warning "no log file downloaded; open the Studio URL instead."
        continue
    }

    foreach ($file in $logFiles) {
        $relative = $file.FullName.Substring((Resolve-Path $target).Path.Length + 1)
        $content = Get-Content -Path $file.FullName -Tail $TailLines
        if (-not $content) { continue }

        Write-Host ""
        Write-Host ("--- {0} (last {1} lines) ---" -f $relative, $TailLines) -ForegroundColor Cyan
        $content | ForEach-Object { Write-Host $_ }
    }
}

Write-Host ""
Write-Host "Look first at user_logs/std_log.txt (Python traceback)." -ForegroundColor Green
