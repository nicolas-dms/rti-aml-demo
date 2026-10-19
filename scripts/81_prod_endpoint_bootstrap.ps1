<#
.SYNOPSIS
    M6 - Creates the PROD endpoint and its FIRST colour (blue). Run once, at D-1.

.DESCRIPTION
    R-60. This is the only place where --all-traffic is acceptable: the endpoint is
    brand new, there is no traffic to protect yet. Every later change goes through
    rti-publish (80_prod_rollout.ps1), which never routes 100 percent at once.

    Managed online endpoints bill 24/7: do not run this before D-1 (20 Oct 2026),
    and delete the endpoint after the demo (79_mlops_teardown.ps1).

    Preconditions, all checked:
      - the model version exists in the registry (run once:
        scripts/80_prod_rollout.ps1 -Stage share -ModelVersion <v>  with a DEV session);
      - the endpoint does not exist yet, or exists with NO deployment;
      - you confirm by typing the endpoint name.

    The model reference is the registry URI; the deployment is tagged with the
    model's own data_asset tag, not the hard-coded one of deployment-blue.yml.

    ASCII only - Windows PowerShell 5.1 reads .ps1 as ANSI.
#>
[CmdletBinding()]
param(
    [int] $ModelVersion = 0,
    [string] $ResourceGroup = 'rg-rti-aml-demo',
    [string] $Workspace = 'aml-rti-prod',
    [string] $Endpoint = 'temp-forecast-prod-ep',
    [string] $Registry = 'mlr-rti-demo',
    [string] $ModelName = 'temp_forecaster',
    [switch] $Yes
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
    finally { $ErrorActionPreference = $previous }
    $stderr = ''
    if (Test-Path $errorFile) {
        $stderr = (Get-Content -Path $errorFile -Raw)
        Remove-Item -Path $errorFile -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ ExitCode = $exitCode; StdOut = ($stdout | Out-String); StdErr = $stderr }
}

$common = @('--resource-group', $ResourceGroup, '--workspace-name', $Workspace)

if ($ModelVersion -le 0) {
    # No version given: take the highest one already in the registry (nothing is shared here).
    $all = Invoke-Az @('ml', 'model', 'list', '--name', $ModelName, '--registry-name', $Registry, '--output', 'json')
    if ($all.ExitCode -ne 0) { throw ("Cannot list $ModelName in registry ${Registry}:`n" + $all.StdErr) }
    $versions = @(($all.StdOut | ConvertFrom-Json) | ForEach-Object { [int]$_.version })
    if ($versions.Count -eq 0) {
        throw "No $ModelName version in registry $Registry. Run: scripts/80_prod_rollout.ps1 -Stage share -ModelVersion <v>"
    }
    $ModelVersion = ($versions | Measure-Object -Maximum).Maximum
    Write-Host "No -ModelVersion given: latest in registry $Registry = v$ModelVersion (of $($versions.Count) version(s))" -ForegroundColor Cyan
}
$modelUri = "azureml://registries/$Registry/models/$ModelName/versions/$ModelVersion"

Write-Host "=== PROD bootstrap: $Endpoint ($Workspace) with $modelUri ===" -ForegroundColor Cyan

$model = Invoke-Az @('ml', 'model', 'show', '--name', $ModelName, '--version', "$ModelVersion", '--registry-name', $Registry, '--output', 'none')
if ($model.ExitCode -ne 0) {
    throw "$ModelName v$ModelVersion is not in registry $Registry. Run: scripts/80_prod_rollout.ps1 -Stage share -ModelVersion $ModelVersion"
}

$existing = Invoke-Az (@('ml', 'online-deployment', 'list', '--endpoint-name', $Endpoint) + $common + @('--output', 'json'))
if ($existing.ExitCode -eq 0) {
    $list = @($existing.StdOut | ConvertFrom-Json)
    if ($list.Count -gt 0) {
        throw "$Endpoint already has $($list.Count) deployment(s) ($(($list | ForEach-Object { $_.name }) -join ', ')). Bootstrap is for an empty endpoint only: use rti-publish."
    }
}

Write-Host "`nThis creates a managed online endpoint (Standard_DS2_v2 x 1, billed 24/7) and routes 100 percent to 'blue'."
if (-not $Yes) {
    $answer = Read-Host "Type the endpoint name ($Endpoint) to confirm"
    if ($answer -ne $Endpoint) { throw 'Not confirmed, nothing created.' }
}

# No -SkipTraffic on purpose: first colour, nothing to protect (the only allowed --all-traffic).
& (Join-Path $PSScriptRoot '30_aml_endpoint.ps1') -ResourceGroup $ResourceGroup -Workspace $Workspace `
    -EndpointName $Endpoint -DeploymentName 'blue' -ModelUri $modelUri

Write-Host "`nNext: scripts/73_function_target.ps1 -Target prod (asks for confirmation), once the endpoint answers." -ForegroundColor Yellow
