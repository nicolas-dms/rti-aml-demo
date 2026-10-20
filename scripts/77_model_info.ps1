<#
.SYNOPSIS
    M5 - Find the model version produced by an rti-train run and write model-info.json.

.DESCRIPTION
    Read-only on AML. The version is found by its ado_build_id tag, never by "the latest
    version": two runs close together must not be able to swap each other's model.
    Exit 1 if no version carries the tag (typical case: the gate rejected the model, so
    nothing was registered - that is the expected outcome of AT-05, reported as such).
    Writes <OutputDir>/model-info.json and <OutputDir>/model-info.md (run summary).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AdoBuildId,
    [string] $JobName = '',
    [string] $ModelName = 'temp_forecaster',
    [string] $ResourceGroup = (& "$PSScriptRoot\lib\cfg.ps1" AZURE_RESOURCE_GROUP -Required),
    [string] $Workspace = (& "$PSScriptRoot\lib\cfg.ps1" AML_DEV_WORKSPACE -Required),
    [string] $OutputDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not $OutputDir) { $OutputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'tmp-model-info' }

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

$r = Invoke-Az -Arguments @('ml', 'model', 'list', '--name', $ModelName,
    '-g', $ResourceGroup, '-w', $Workspace, '-o', 'json')
if ($r.ExitCode -ne 0) { throw "az ml model list failed: $($r.StdErr)" }

$models = @($r.StdOut | ConvertFrom-Json)
$found = @($models | Where-Object { $_.tags -and ([string] $_.tags.ado_build_id) -eq $AdoBuildId })
if ($found.Count -eq 0) {
    Write-Host "NO model version of '$ModelName' carries ado_build_id=$AdoBuildId." -ForegroundColor Red
    Write-Host "If the gate rejected the model this is expected: nothing was registered."
    exit 1
}
if ($found.Count -gt 1) {
    Write-Host "WARNING: $($found.Count) versions carry ado_build_id=$AdoBuildId; taking the highest." -ForegroundColor Yellow
}
$model = $found | Sort-Object { [int] $_.version } | Select-Object -Last 1
$t = $model.tags

$info = [ordered]@{
    model_name           = $ModelName
    model_version        = [string] $model.version
    model_id             = [string] $model.id
    workspace            = $Workspace
    aml_job_name         = $JobName
    ado_build_id         = [string] $t.ado_build_id
    git_sha              = [string] $t.git_sha
    data_asset           = [string] $t.data_asset
    data_manifest_sha256 = [string] $t.data_manifest_sha256
    mae                  = [string] $t.mae
    rmse                 = [string] $t.rmse
    baseline_mae         = [string] $t.baseline_mae
    skill_vs_baseline    = [string] $t.skill_vs_baseline
    test_period_end      = [string] $t.test_period_end
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$jsonPath = Join-Path $OutputDir 'model-info.json'
($info | ConvertTo-Json) | Set-Content -Path $jsonPath -Encoding UTF8

$md = @"
# rti-train - $ModelName v$($info.model_version)

| | |
|---|---|
| AML job | $JobName |
| Azure DevOps build | $($info.ado_build_id) |
| Git commit | $($info.git_sha) |
| Data asset | $($info.data_asset) |
| Manifest SHA-256 | $($info.data_manifest_sha256) |
| MAE / baseline MAE | $($info.mae) / $($info.baseline_mae) |
| Skill vs baseline | $($info.skill_vs_baseline) |
"@
Set-Content -Path (Join-Path $OutputDir 'model-info.md') -Value $md -Encoding UTF8

Write-Host "`n--- model-info ---"
$info.GetEnumerator() | ForEach-Object { Write-Host ("{0,-22}: {1}" -f $_.Key, $_.Value) }
Write-Host "`nwritten: $jsonPath"
