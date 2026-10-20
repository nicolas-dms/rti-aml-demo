<#
.SYNOPSIS
    P4 - Register the training environment and submit the AML training pipeline.

.DESCRIPTION
    Idempotent. The environment is created only if that exact version is absent,
    because AML refuses to overwrite an existing environment version.
    Requires the data asset produced by P3 to exist already.

.NOTES
    Windows PowerShell 5.1 turns ANY stderr write by a native command into a
    terminating error when $ErrorActionPreference is 'Stop', and "2>$null" does
    not prevent it. Since "az ... show" legitimately writes to stderr when a
    resource is absent, every az call goes through Invoke-Az below, which
    isolates stdout, stderr and the exit code.
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = (& "$PSScriptRoot\lib\cfg.ps1" AZURE_RESOURCE_GROUP -Required),
    [string] $Workspace = (& "$PSScriptRoot\lib\cfg.ps1" AML_DEV_WORKSPACE -Required),
    [string] $EnvironmentFile = 'aml/environments/train-env.yml',
    [string] $EnvironmentName = 'rti-training-env',
    [string] $EnvironmentVersion = '3',
    [string] $DataAssetName = 'telemetry_features',
    [string] $DataAssetVersion = '1',
    [string] $PipelineFile = 'aml/pipelines/training_pipeline.yml',
    # Track C (all optional; without them the script behaves exactly as in track A).
    # -SnapshotId selects the frozen asset telemetry_train:<id> and turns on the
    # manifest verification in prep. The expected manifest hash is read from the
    # asset's manifest_sha256 tag unless -ExpectedManifestSha256 overrides it.
    [string] $SnapshotId = '',
    [string] $ExpectedManifestSha256 = '',
    [string] $GitSha = '',
    [string] $AdoBuildId = '',
    # Gate threshold override (AT-05 uses 0.1). Absent = the value in the YAML.
    [string] $MaxMae = '',
    [switch] $NoStream
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
        throw "az $($Arguments -join ' ') -> exit $($result.ExitCode)`n$($result.StdErr)"
    }
    return ($result.StdOut | ConvertFrom-Json)
}

Write-Host "=== P4 - AML training ===" -ForegroundColor Cyan
if ($SnapshotId) {
    $DataAssetName = 'telemetry_train'
    $DataAssetVersion = $SnapshotId
    Write-Host "track C        : frozen snapshot $SnapshotId" -ForegroundColor Yellow
}
Write-Host "resource group : $ResourceGroup"
Write-Host "workspace      : $Workspace"

# --- 1. The data asset is a hard prerequisite ------------------------------
Write-Host "`n[1/3] Checking data asset ${DataAssetName}:${DataAssetVersion} ..."
$assetResult = Invoke-Az -Arguments @('ml', 'data', 'show', '--name', $DataAssetName,
    '--version', $DataAssetVersion, '-g', $ResourceGroup, '-w', $Workspace, '-o', 'json')
if ($assetResult.ExitCode -ne 0) {
    throw "Data asset ${DataAssetName}:${DataAssetVersion} not found. Run first: az ml data create -f aml/data/data-asset.yml -g $ResourceGroup -w $Workspace"
}
$asset = $assetResult.StdOut | ConvertFrom-Json
Write-Host "  found: $($asset.path)" -ForegroundColor Green

$setArgs = @()
if ($SnapshotId) {
    if (-not $ExpectedManifestSha256) {
        $ExpectedManifestSha256 = [string] $asset.tags.manifest_sha256
    }
    if ($ExpectedManifestSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "No valid manifest SHA-256 for ${DataAssetName}:${DataAssetVersion} (tag manifest_sha256 missing and no -ExpectedManifestSha256). Refusing to train on unverified data."
    }
    $ExpectedManifestSha256 = $ExpectedManifestSha256.ToLower()
    Write-Host "  expected manifest sha256: $ExpectedManifestSha256"
    $dataRef = "${DataAssetName}:${DataAssetVersion}"
    $setArgs += @('--set', "inputs.telemetry_features.path=azureml:$dataRef",
        '--set', "inputs.data_asset_tag=$dataRef",
        '--set', "jobs.prep.inputs.expected_manifest_sha256=$ExpectedManifestSha256",
        '--set', "jobs.register.inputs.data_manifest_sha256=$ExpectedManifestSha256",
        '--set', "tags.data_asset=$dataRef",
        '--set', "tags.snapshot_id=$SnapshotId")
}
if ($GitSha) {
    $setArgs += @('--set', "jobs.register.inputs.git_sha=$GitSha", '--set', "tags.git_sha=$GitSha")
}
if ($AdoBuildId) {
    $setArgs += @('--set', "jobs.register.inputs.ado_build_id=$AdoBuildId", '--set', "tags.ado_build_id=$AdoBuildId")
}
if ($MaxMae) {
    $setArgs += @('--set', "inputs.max_mae=$MaxMae")
}
# --- 2. Environment -------------------------------------------------------
Write-Host "`n[2/3] Environment ${EnvironmentName}:${EnvironmentVersion} ..."
$envResult = Invoke-Az -Arguments @('ml', 'environment', 'show', '--name', $EnvironmentName,
    '--version', $EnvironmentVersion, '-g', $ResourceGroup, '-w', $Workspace, '-o', 'json')
if ($envResult.ExitCode -eq 0) {
    Write-Host "  already registered, reused as-is" -ForegroundColor Green
}
else {
    Write-Host "  absent, creating (the conda image is built on first use) ..."
    Invoke-AzJson -Arguments @('ml', 'environment', 'create', '-f', $EnvironmentFile,
        '-g', $ResourceGroup, '-w', $Workspace, '-o', 'json') | Out-Null
    Write-Host "  created" -ForegroundColor Green
}

# --- 3. Pipeline ----------------------------------------------------------
Write-Host "`n[3/3] Submitting pipeline ..."
$job = Invoke-AzJson -Arguments (@('ml', 'job', 'create', '-f', $PipelineFile,
    '-g', $ResourceGroup, '-w', $Workspace, '-o', 'json') + $setArgs)

Write-Host "`n--- SUMMARY (report in docs/PROGRESS.md) ---"
Write-Host "job name   : $($job.name)"
Write-Host "status     : $($job.status)"
Write-Host "studio url : $($job.services.Studio.endpoint)"
# Hand the job name to the next steps of an Azure DevOps run (no effect elsewhere).
if ($env:TF_BUILD) {
    Write-Host "##vso[task.setvariable variable=amlJobName]$($job.name)"
}

if (-not $NoStream) {
    Write-Host "`nStreaming logs (Ctrl+C detaches, the job keeps running) ..." -ForegroundColor Yellow
    # Streamed live on purpose: buffering it through Invoke-Az would defeat it.
    $ErrorActionPreference = 'Continue'
    & az ml job stream --name $job.name -g $ResourceGroup -w $Workspace
    $ErrorActionPreference = 'Stop'
}

Write-Host "`nWhen it succeeds:"
Write-Host "  az ml model list --name temp_forecaster -g $ResourceGroup -w $Workspace -o table"
