<#
.SYNOPSIS
    P5 - Creates the managed online endpoint and the "blue" deployment (model v1),
    then smoke-tests it.

.DESCRIPTION
    temp_forecaster is registered as an mlflow_model, so this is a no-code
    deployment: no scoring script, no environment. Azure ML rebuilds the serving
    container from the conda file embedded in the model.

    Expect the deployment to take 8-15 minutes. Almost all of it is image build
    plus node provisioning, not our code.

.NOTES
    Managed online endpoints bill 24/7 as long as they exist, even with no
    traffic. Delete the endpoint after the demo (scripts/90_teardown.ps1).

    Uses the Invoke-Az wrapper: on Windows PowerShell 5.1 with
    $ErrorActionPreference = 'Stop', any native command writing to stderr raises
    a terminating NativeCommandError, and 2>$null does not prevent it.
#>

[CmdletBinding()]
param(
    [string] $ResourceGroup = (& "$PSScriptRoot\lib\cfg.ps1" AZURE_RESOURCE_GROUP -Required),
    [string] $Workspace = (& "$PSScriptRoot\lib\cfg.ps1" AML_DEV_WORKSPACE -Required),
    [string] $EndpointName = (& "$PSScriptRoot\lib\cfg.ps1" ENDPOINT_DEV -Default 'temp-forecast-ep'),
    [string] $DeploymentName = 'blue',
    # Overrides the version written in the deployment YAML. Handy when a model
    # has to be re-registered without touching the file.
    [int]    $ModelVersion = 1,
    # M6: full registry reference, e.g.
    #   azureml://registries/mlr-rti-demo/models/temp_forecaster/versions/8
    # When given it wins over -ModelVersion. The model is read from the registry,
    # the deployment is re-tagged with the model's OWN data_asset tag (never the
    # hard-coded one of the YAML), and an unchanged deployment is left alone.
    [string] $ModelUri = '',
    [string] $EndpointFile = 'aml/endpoints/endpoint.yml',
    # Default follows -DeploymentName: green -> deployment-green.yml, else blue.
    [string] $DeploymentFile = '',
    [string] $RequestFile = 'aml/endpoints/sample-request.json',
    # P7 creates "green" with zero traffic so it can be smoke-tested in
    # isolation before anything is shifted onto it.
    [switch] $SkipTraffic,
    [switch] $SkipSmokeTest
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

$common = @('--resource-group', $ResourceGroup, '--workspace-name', $Workspace)

if (-not $DeploymentFile) {
    $DeploymentFile = if ($DeploymentName -eq 'green') { 'aml/endpoints/deployment-green.yml' } else { 'aml/endpoints/deployment-blue.yml' }
}

# What is deployed: a workspace model (track A) or a registry model (track C).
$registryName = ''
$modelName = 'temp_forecaster'
$modelRef = "azureml:temp_forecaster:$ModelVersion"
$modelLabel = "temp_forecaster:$ModelVersion"
if ($ModelUri) {
    if ($ModelUri -notmatch '^azureml://registries/([^/]+)/models/([^/]+)/versions/([^/?]+)$') {
        throw "-ModelUri must look like azureml://registries/<registry>/models/<name>/versions/<v>, got '$ModelUri'."
    }
    $registryName = $Matches[1]
    $modelName = $Matches[2]
    $ModelVersion = $Matches[3]
    $modelRef = $ModelUri
    $modelLabel = "$registryName/${modelName}:$ModelVersion"
}

Write-Host "=== P5 - AML online endpoint ===" -ForegroundColor Cyan
Write-Host "resource group : $ResourceGroup"
Write-Host "workspace      : $Workspace"
Write-Host "endpoint       : $EndpointName"
Write-Host "deployment     : $DeploymentName"

# --- [1/4] the model must exist before anything else ------------------------
Write-Host "`n[1/4] Checking model $modelLabel ..." -ForegroundColor Cyan
if ($registryName) {
    $model = Invoke-AzJson -Arguments @('ml', 'model', 'show', '--name', $modelName, '--version', "$ModelVersion",
        '--registry-name', $registryName, '--output', 'json')
}
else {
    $model = Invoke-AzJson -Arguments (@('ml', 'model', 'show', '--name', 'temp_forecaster', '--version', "$ModelVersion") + $common + @('--output', 'json'))
}
Write-Host "  found: type=$($model.type)  stage=$($model.stage)"
if ($model.type -ne 'mlflow_model') {
    throw "Model type is '$($model.type)', expected 'mlflow_model'. No-code deployment will not work; a scoring script would be required."
}
# Lineage tag of the deployment: the model's own, never the YAML's hard-coded one.
$dataAssetTag = ''
if ($registryName -and $model.tags -and $model.tags.data_asset) { $dataAssetTag = [string]$model.tags.data_asset }

# --- [2/4] endpoint ---------------------------------------------------------
Write-Host "`n[2/4] Endpoint $EndpointName ..." -ForegroundColor Cyan
$probe = Invoke-Az -Arguments (@('ml', 'online-endpoint', 'show', '--name', $EndpointName) + $common + @('--output', 'json'))
if ($probe.ExitCode -eq 0) {
    Write-Host "  already exists, reused as-is"
}
else {
    Write-Host "  creating (2-4 min) ..."
    $created = Invoke-Az -Arguments (@('ml', 'online-endpoint', 'create', '--name', $EndpointName, '--file', $EndpointFile) + $common + @('--output', 'none'))
    if ($created.ExitCode -ne 0) {
        Write-Host $created.StdErr -ForegroundColor Red
        throw "Endpoint creation failed. If the error mentions a name conflict, the name is taken elsewhere in the region: re-run with -EndpointName <other>."
    }
    Write-Host "  created"
}

# --- [3/4] deployment -------------------------------------------------------
# create or update, depending on what is already there. A deployment left in
# Failed state still owns its name, so a plain "create" is not re-runnable -
# which defeats the point of a script meant to be replayed live.
Write-Host "`n[3/4] Deployment $DeploymentName (8-15 min: image build + node) ..." -ForegroundColor Cyan

$existing = Invoke-Az -Arguments (@(
        'ml', 'online-deployment', 'show',
        '--name', $DeploymentName, '--endpoint-name', $EndpointName) + $common + @('--output', 'json'))

$verb = 'create'
if ($existing.ExitCode -eq 0) {
    $existingObject = $existing.StdOut | ConvertFrom-Json
    $state = $existingObject.provisioning_state
    Write-Host "  already exists (provisioning_state=$state) -> update in place"
    $verb = 'update'
    # M6 (R-51): a candidate that already carries this exact model version is
    # not rebuilt (it may have been pre-deployed the day before).
    if ($ModelUri -and $state -eq 'Succeeded' -and
        ([string]$existingObject.model) -match "/models/$([regex]::Escape($modelName))/versions/$([regex]::Escape([string]$ModelVersion))$") {
        Write-Host "  already runs $modelLabel and is Succeeded -> nothing to do"
        $verb = 'skip'
    }
}

$arguments = @(
    'ml', 'online-deployment', $verb,
    '--name', $DeploymentName,
    '--endpoint-name', $EndpointName,
    '--file', $DeploymentFile,
    '--set', "model=$modelRef")
if ($ModelUri) {
    # PROD is not tied to the YAML's endpoint_name, and the hard-coded data_asset
    # tag of deployment-blue.yml would lie about the lineage.
    $arguments += @('--set', "endpoint_name=$EndpointName")
    $arguments += @('--set', "tags.data_asset=$(if ($dataAssetTag) { $dataAssetTag } else { 'unknown' })")
    $arguments += @('--set', "tags.model_uri=$ModelUri")
}
# --all-traffic is a create-only flag; on update the traffic split is a property
# of the endpoint, not of the deployment, and is set separately below.
if ($verb -eq 'create' -and -not $SkipTraffic) { $arguments += '--all-traffic' }

if ($verb -eq 'skip') {
    $deploy = [pscustomobject]@{ ExitCode = 0; StdErr = '' }
}
else {
    $deploy = Invoke-Az -Arguments ($arguments + $common + @('--output', 'none'))
}
if ($deploy.ExitCode -ne 0) {
    Write-Host $deploy.StdErr -ForegroundColor Red
    Write-Host ""
    Write-Host "Read the container logs before changing anything:" -ForegroundColor Yellow
    Write-Host "  az ml online-deployment get-logs --name $DeploymentName --endpoint-name $EndpointName --resource-group $ResourceGroup --workspace-name $Workspace --lines 300"
    Write-Host "A 502 on the liveness probe means the container started and then died:" -ForegroundColor Yellow
    Write-Host "  that is an import or dependency failure in the model's own conda file,"
    Write-Host "  not a quota problem and not an instance-size problem."
    Write-Host "If the update itself is rejected, the failed deployment has to go first:" -ForegroundColor Yellow
    Write-Host "  az ml online-deployment delete --name $DeploymentName --endpoint-name $EndpointName --resource-group $ResourceGroup --workspace-name $Workspace --yes"
    throw "Deployment of $modelLabel failed ($verb)."
}
Write-Host "  $verb ok"

if ($SkipTraffic) {
    Write-Host "  traffic left untouched (-SkipTraffic)"
}
else {
    Write-Host "  routing 100 percent of the traffic to $DeploymentName ..."
    $traffic = Invoke-Az -Arguments (@(
            'ml', 'online-endpoint', 'update',
            '--name', $EndpointName,
            '--traffic', "$DeploymentName=100") + $common + @('--output', 'none'))
    if ($traffic.ExitCode -ne 0) {
        Write-Host $traffic.StdErr -ForegroundColor Red
        throw "Deployment is up but the traffic split could not be set."
    }
    Write-Host "  done"
}

# --- [4/4] summary + smoke test --------------------------------------------
$endpoint = Invoke-AzJson -Arguments (@('ml', 'online-endpoint', 'show', '--name', $EndpointName) + $common + @('--output', 'json'))

Write-Host "`n--- SUMMARY (report in docs/PROGRESS.md) ---" -ForegroundColor Yellow
Write-Host "endpoint     : $($endpoint.name)"
Write-Host "state        : $($endpoint.provisioning_state)"
Write-Host "auth mode    : $($endpoint.auth_mode)"
Write-Host "identity     : $($endpoint.identity.principal_id)"
Write-Host "scoring uri  : $($endpoint.scoring_uri)"
Write-Host "traffic      : $($endpoint.traffic | ConvertTo-Json -Compress)"

if ($SkipSmokeTest) {
    Write-Host "`nSmoke test skipped."
    return
}

Write-Host "`nSmoke test ($RequestFile) ..." -ForegroundColor Cyan
$invoke = Invoke-Az -Arguments (@(
        'ml', 'online-endpoint', 'invoke',
        '--name', $EndpointName,
        '--deployment-name', $DeploymentName,
        '--request-file', $RequestFile) + $common)
if ($invoke.ExitCode -ne 0) {
    Write-Host $invoke.StdErr -ForegroundColor Red
    Write-Host "The deployment is up but rejected the payload. Compare the columns in" -ForegroundColor Yellow
    Write-Host "$RequestFile with the MLflow signature (Studio > Models > temp_forecaster > Artifacts > MLmodel)." -ForegroundColor Yellow
    throw "Smoke test failed."
}
Write-Host "  predictions: $($invoke.StdOut.Trim())" -ForegroundColor Green
Write-Host "`nThese two numbers are the predicted temperature 15 min ahead for machine-01 and machine-03."
