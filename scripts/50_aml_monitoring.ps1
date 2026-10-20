<#
.SYNOPSIS
    P8 - enable production data collection and create the model monitor.

.DESCRIPTION
    Model monitoring has one hard prerequisite: the online deployment must be
    collecting production inference data. If it is not, the monitor is created
    happily and every run finds nothing. In the studio wizard the same problem
    shows up as an empty "Select deployment with data collection enabled" list.

    Run order:
        .\scripts\50_aml_monitoring.ps1 -EnableCollection      # updates the deployment
        .\scripts\50_aml_monitoring.ps1 -RegisterReference     # mltable baseline
        .\scripts\50_aml_monitoring.ps1 -CreateMonitor -Email you@example.com
        .\scripts\50_aml_monitoring.ps1 -Show

.NOTES
    -EnableCollection UPDATES A LIVE DEPLOYMENT. Azure ML performs a rolling
    update of the inference container: the scoring endpoint can return errors
    for a while, and the Function will log failures. Never run it during a demo.

    On MLflow no-code deployments Azure ML auto-instruments the generated
    scoring script, so no score.py of our own is needed - the note in
    aml/endpoints/deployment-blue.yml claiming otherwise was wrong, and has
    been corrected.

    ASCII only (Windows PowerShell 5.1 reads .ps1 as ANSI).
#>
[CmdletBinding(DefaultParameterSetName = 'Show')]
param(
    [Parameter(ParameterSetName = 'EnableCollection', Mandatory)]
    [switch] $EnableCollection,

    [Parameter(ParameterSetName = 'RegisterReference', Mandatory)]
    [switch] $RegisterReference,

    [Parameter(ParameterSetName = 'CreateMonitor', Mandatory)]
    [switch] $CreateMonitor,

    [Parameter(ParameterSetName = 'CreateMonitor', Mandatory)]
    [string] $Email,

    [Parameter(ParameterSetName = 'Show')]
    [switch] $Show,

    [string] $ResourceGroup  = (& "$PSScriptRoot\lib\cfg.ps1" AZURE_RESOURCE_GROUP -Required),
    [string] $Workspace      = (& "$PSScriptRoot\lib\cfg.ps1" AML_DEV_WORKSPACE -Required),
    [string] $EndpointName   = (& "$PSScriptRoot\lib\cfg.ps1" ENDPOINT_DEV -Default 'temp-forecast-ep'),
    [string] $DeploymentName = 'blue'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$common   = @('-g', $ResourceGroup, '-w', $Workspace)

function Write-Step($text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
if ($EnableCollection) {
    Write-Step "Enabling data collection on $EndpointName/$DeploymentName"

    Write-Host "WARNING: this triggers a rolling update of the deployment." -ForegroundColor Yellow
    Write-Host "         Scoring may fail intermittently while it runs."     -ForegroundColor Yellow
    $answer = Read-Host "Continue? (yes/no)"
    if ($answer -ne 'yes') { Write-Host 'Aborted.'; return }

    # --set is used rather than a YAML edit so the deployment keeps its current
    # model version, whatever it happens to be right now.
    az ml online-deployment update `
        --name $DeploymentName --endpoint-name $EndpointName @common `
        --set data_collector.collections.model_inputs.enabled=True `
              data_collector.collections.model_outputs.enabled=True `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "Deployment update failed (exit $LASTEXITCODE)." }

    Write-Host 'Data collection enabled.' -ForegroundColor Green
    Write-Host 'Two data assets appear once the endpoint is called again:'
    Write-Host "  $EndpointName-$DeploymentName-model_inputs"
    Write-Host "  $EndpointName-$DeploymentName-model_outputs"
    return
}

# ---------------------------------------------------------------------------
if ($RegisterReference) {
    Write-Step 'Registering the mltable reference baseline'

    $assetFile = Join-Path $repoRoot 'aml\monitoring\reference-data-asset.yml'
    az ml data create -f $assetFile @common --output none
    if ($LASTEXITCODE -ne 0) { throw "Data asset creation failed (exit $LASTEXITCODE)." }

    az ml data show --name telemetry_features_mltable --version 1 @common `
        --query "{name:name,version:version,type:type,path:path}" -o json
    return
}

# ---------------------------------------------------------------------------
if ($CreateMonitor) {
    Write-Step 'Creating the monitoring schedule'

    $template = Join-Path $repoRoot 'aml\monitoring\monitoring.yml'
    $rendered = Join-Path $env:TEMP 'monitoring.rendered.yml'

    # The email is not committed to the repo, so it is injected here.
    (Get-Content $template -Raw).Replace('PLACEHOLDER_EMAIL', $Email) |
        Set-Content -Path $rendered -Encoding ascii

    az ml schedule create -f $rendered @common --output none
    if ($LASTEXITCODE -ne 0) { throw "Schedule creation failed (exit $LASTEXITCODE)." }
    Remove-Item $rendered -Force

    Write-Host 'Monitor created. The first results appear after the first run.' -ForegroundColor Green
    return
}

# ---------------------------------------------------------------------------
Write-Step 'Data collection status'
az ml online-deployment show --name $DeploymentName --endpoint-name $EndpointName @common `
    --query "data_collector" -o json

Write-Step 'Collected data assets'
az ml data list @common --query "[?contains(name, '$EndpointName')].{name:name,type:type}" -o table

Write-Step 'Monitoring schedules'
az ml schedule list @common --query "[].{name:name,enabled:is_enabled,trigger:trigger.frequency}" -o table
