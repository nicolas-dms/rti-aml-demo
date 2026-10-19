<#
.SYNOPSIS
    Track C / M7 - Trace what is served in PROD back to its data, code and training run.

.DESCRIPTION
    Read-only. Starting from the PROD endpoint (or an explicit -ModelVersion) it follows:

      endpoint -> deployment at the highest traffic -> registry model version
        -> model tags (git_sha, ado_build_id, data_asset, data_manifest_sha256, mae ...)
        -> data asset in DEV (telemetry_train:<snapshot>) and its tags
        -> DEV training job found by the ado_build_id tag (best effort)

    and CHECKS that the manifest hash carried by the model equals the one carried by the
    data asset. A mismatch is reported as a failure (exit 1): that is the point of the chain.
    Nothing is modified. Needs an az login that can read DEV, PROD and the registry
    (the laptop account is enough; no service connection involved).

.EXAMPLE
    .\scripts\78_trace_lineage.ps1                      # what PROD serves right now
    .\scripts\78_trace_lineage.ps1 -ModelVersion 8      # a specific registry version

.NOTES
    ASCII; Windows PowerShell 5.1 compatible. User-operated.
#>
[CmdletBinding()]
param(
    [int] $ModelVersion = 0,
    [string] $ModelName = 'temp_forecaster',
    [string] $Registry = 'mlr-rti-demo',
    [string] $ResourceGroup = 'rg-rti-aml-demo',
    [string] $DevWorkspace = 'aml-rti-demo',
    [string] $ProdWorkspace = 'aml-rti-prod',
    [string] $Endpoint = 'temp-forecast-prod-ep',
    [string] $AdoOrganization = '<ADO_ORG>',
    [string] $AdoProject = 'rti-aml-demo'
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
    finally { $ErrorActionPreference = $previous }
    $stderr = ''
    if (Test-Path $errorFile) {
        $stderr = (Get-Content -Path $errorFile -Raw)
        Remove-Item -Path $errorFile -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ ExitCode = $exitCode; StdOut = ($stdout | Out-String); StdErr = $stderr }
}

function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $r = Invoke-Az -Arguments $Arguments
    if ($r.ExitCode -ne 0) { throw ("az " + ($Arguments -join ' ') + " -> exit $($r.ExitCode)`n" + $r.StdErr) }
    return ($r.StdOut | ConvertFrom-Json)
}

function Show-Row {
    param([string] $Label, $Value)
    Write-Host ("  {0,-24}: {1}" -f $Label, $Value)
}

$failures = @()

# --- 1. which model version ---------------------------------------------------
if ($ModelVersion -le 0) {
    Write-Host "`n[1] What does PROD serve?" -ForegroundColor Cyan
    $prodArgs = @('--resource-group', $ResourceGroup, '--workspace-name', $ProdWorkspace)
    $ep = Invoke-Az (@('ml', 'online-endpoint', 'show', '--name', $Endpoint) + $prodArgs + @('--output', 'json'))
    if ($ep.ExitCode -ne 0) {
        throw "Endpoint $Endpoint cannot be read in $ProdWorkspace (deleted, or no access). Use -ModelVersion <n> to trace a registry version.`n$($ep.StdErr)"
    }
    $epInfo = $ep.StdOut | ConvertFrom-Json
    $served = @()
    if ($epInfo.traffic) {
        foreach ($p in $epInfo.traffic.PSObject.Properties) { if ([int]$p.Value -gt 0) { $served += [pscustomobject]@{ Name = $p.Name; Pct = [int]$p.Value } } }
    }
    if ($served.Count -eq 0) { throw "No deployment of $Endpoint carries traffic." }
    $top = $served | Sort-Object Pct -Descending | Select-Object -First 1
    $dep = Invoke-AzJson (@('ml', 'online-deployment', 'show', '--name', $top.Name, '--endpoint-name', $Endpoint) + $prodArgs + @('--output', 'json'))
    Show-Row 'endpoint' $Endpoint
    Show-Row 'scoring_uri' $epInfo.scoring_uri
    Show-Row 'traffic' (($served | ForEach-Object { '{0}={1}' -f $_.Name, $_.Pct }) -join ' ')
    Show-Row 'deployment' $top.Name
    Show-Row 'model (as deployed)' $dep.model
    if ([string]$dep.model -match '/versions/([^/?]+)$') { $ModelVersion = [int]$Matches[1] }
    elseif ([string]$dep.model -match ':([^:]+)$') { $ModelVersion = [int]$Matches[1] }
    else { throw "Cannot read a version from the deployed model reference '$($dep.model)'." }
}
else {
    Write-Host "`n[1] Model version given: $ModelVersion (endpoint not queried)" -ForegroundColor Cyan
}

# --- 2. registry model and its tags ------------------------------------------
Write-Host "`n[2] Registry model $ModelName v$ModelVersion ($Registry)" -ForegroundColor Cyan
$model = Invoke-AzJson @('ml', 'model', 'show', '--name', $ModelName, '--version', "$ModelVersion",
    '--registry-name', $Registry, '--output', 'json')
$t = $model.tags
Show-Row 'id' $model.id
foreach ($k in 'git_sha', 'ado_build_id', 'data_asset', 'data_manifest_sha256', 'mae', 'rmse', 'baseline_mae', 'skill_vs_baseline', 'test_period_end') {
    Show-Row $k ([string]$t.$k)
}
foreach ($k in 'git_sha', 'ado_build_id', 'data_asset', 'data_manifest_sha256') {
    if (-not [string]$t.$k -or [string]$t.$k -eq 'local') { $failures += "model tag '$k' is empty or 'local' (model not produced by rti-train?)" }
}

# --- 3. data asset in DEV -----------------------------------------------------
Write-Host "`n[3] Data asset in DEV ($DevWorkspace)" -ForegroundColor Cyan
$assetRef = [string]$t.data_asset
if ($assetRef -match '^([^:]+):(.+)$') {
    $assetName = $Matches[1]; $assetVersion = $Matches[2]
    $asset = Invoke-Az @('ml', 'data', 'show', '--name', $assetName, '--version', $assetVersion,
        '--resource-group', $ResourceGroup, '--workspace-name', $DevWorkspace, '--output', 'json')
    if ($asset.ExitCode -ne 0) {
        $failures += "data asset $assetRef not readable in ${DevWorkspace}"
    }
    else {
        $a = $asset.StdOut | ConvertFrom-Json
        Show-Row 'asset' $assetRef
        Show-Row 'path' $a.path
        foreach ($k in 'site', 'window_start', 'window_end', 'row_count', 'manifest_sha256', 'source_table', 'source_delta_version') {
            Show-Row $k ([string]$a.tags.$k)
        }
        if ([string]$a.tags.manifest_sha256 -and [string]$t.data_manifest_sha256 -and
            ([string]$a.tags.manifest_sha256).ToLower() -eq ([string]$t.data_manifest_sha256).ToLower()) {
            Write-Host "  MATCH: manifest hash on the model = manifest hash on the data asset" -ForegroundColor Green
        }
        else {
            $failures += "manifest hash differs: model=$($t.data_manifest_sha256) asset=$($a.tags.manifest_sha256)"
        }
    }
}
else {
    $failures += "model tag data_asset ('$assetRef') is not '<name>:<version>'"
}

# --- 4. DEV training job (best effort) ---------------------------------------
Write-Host "`n[4] DEV training job (found by ado_build_id)" -ForegroundColor Cyan
$buildId = [string]$t.ado_build_id
if ($buildId -and $buildId -ne 'local') {
    $jobs = Invoke-Az @('ml', 'job', 'list', '--resource-group', $ResourceGroup, '--workspace-name', $DevWorkspace,
        '--query', "[?tags.ado_build_id=='$buildId'].{name:name,status:status,display:display_name}", '--output', 'json')
    if ($jobs.ExitCode -eq 0) {
        $list = @($jobs.StdOut | ConvertFrom-Json)
        if ($list.Count -eq 0) { Write-Host "  no job carries ado_build_id=$buildId (not an error: job listing is best effort)" -ForegroundColor Yellow }
        foreach ($j in $list) { Show-Row 'job' "$($j.name)  [$($j.status)]" }
    }
    else { Write-Host "  job listing failed (not an error): $($jobs.StdErr)" -ForegroundColor Yellow }
}
else { Write-Host "  no ado_build_id on the model" -ForegroundColor Yellow }

# --- 5. code and build --------------------------------------------------------
Write-Host "`n[5] Code and build" -ForegroundColor Cyan
Show-Row 'git commit' ([string]$t.git_sha)
if ($buildId -and $buildId -ne 'local') {
    Show-Row 'Azure DevOps run' "https://dev.azure.com/$AdoOrganization/$AdoProject/_build/results?buildId=$buildId"
}
Write-Host "  to see the commit: git show $([string]$t.git_sha)"

# --- verdict ------------------------------------------------------------------
Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "LINEAGE INCOMPLETE:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "LINEAGE OK: $ModelName v$ModelVersion <- run $buildId <- commit $([string]$t.git_sha) <- $assetRef (manifest verified)" -ForegroundColor Green
