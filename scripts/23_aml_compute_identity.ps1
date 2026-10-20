<#
.SYNOPSIS
    Gives the AML compute cluster a system-assigned managed identity and grants it
    data-plane access to the storage accounts the jobs need to read and write.

.DESCRIPTION
    Once the workspace uses identity-based system datastores, the compute no longer
    borrows an account key: it must present an identity of its own. A cluster created
    without one fails in seconds with

        Identity of the specified managed compute ... is not found.

    This script closes that gap and grants the new principal:
      - Storage Blob Data Contributor on the workspace storage account
        (workspaceblobstore / workspaceartifactstore = job outputs and logs)
      - Storage Blob Data Reader on the snapshot account behind rti_snapshots
        (read-only: the training pipeline must never write into the source data)

.NOTES
    A freshly created managed identity is not immediately visible to Entra, so role
    assignments are retried for a short while on PrincipalNotFound.

    Uses the Invoke-Az wrapper: on Windows PowerShell 5.1 with
    $ErrorActionPreference = 'Stop', any native command writing to stderr raises a
    terminating NativeCommandError, and 2>$null does not prevent it.
#>

[CmdletBinding()]
param(
    [string] $ResourceGroup = (& "$PSScriptRoot\lib\cfg.ps1" AZURE_RESOURCE_GROUP -Required),
    [string] $Workspace = (& "$PSScriptRoot\lib\cfg.ps1" AML_DEV_WORKSPACE -Required),
    [string] $ComputeName = (& "$PSScriptRoot\lib\cfg.ps1" AML_COMPUTE -Default 'cpu-cluster'),
    [string] $SnapshotDatastore = 'rti_snapshots',
    [int] $MaxRetries = 10
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

function Grant-Role {
    param(
        [Parameter(Mandatory)] [string] $PrincipalId,
        [Parameter(Mandatory)] [string] $Role,
        [Parameter(Mandatory)] [string] $Scope
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $result = Invoke-Az -Arguments @(
            'role', 'assignment', 'create',
            '--assignee-object-id', $PrincipalId,
            '--assignee-principal-type', 'ServicePrincipal',
            '--role', $Role,
            '--scope', $Scope,
            '-o', 'none'
        )

        if ($result.ExitCode -eq 0) { return 'granted' }
        if ($result.StdErr -match 'RoleAssignmentExists') { return 'already present' }
        if ($result.StdErr -match 'PrincipalNotFound|does not exist in the directory') {
            Write-Host "    identity not replicated yet, retry $attempt/$MaxRetries ..."
            Start-Sleep -Seconds 10
            continue
        }

        throw ("role assignment failed -> exit $($result.ExitCode)`n" + $result.StdErr)
    }

    throw "Identity $PrincipalId never became visible to Entra after $MaxRetries attempts."
}

Write-Host "=== AML compute identity ===" -ForegroundColor Cyan

# --- 1. attach a system-assigned identity ------------------------------------
$compute = Invoke-AzJson -Arguments @('ml', 'compute', 'show', '-n', $ComputeName, '-g', $ResourceGroup, '-w', $Workspace, '-o', 'json')
$principalId = $null
if ($compute.identity -and $compute.identity.principal_id) {
    $principalId = $compute.identity.principal_id
}

Write-Host "compute     : $ComputeName"
Write-Host "identity    : $(if ($principalId) { $principalId } else { '<none>' })"
Write-Host ""

Write-Host "[1/3] Ensuring system-assigned identity ..."
if ($principalId) {
    Write-Host "  already present"
}
else {
    $updated = Invoke-AzJson -Arguments @(
        'ml', 'compute', 'update',
        '-n', $ComputeName, '-g', $ResourceGroup, '-w', $Workspace,
        '--identity-type', 'SystemAssigned',
        '-o', 'json'
    )
    $principalId = $updated.identity.principal_id
    if (-not $principalId) {
        throw "The update returned no principal_id; check 'az ml compute show'."
    }
    Write-Host "  created: $principalId"
}

# --- 2. resolve the two storage accounts (never hardcode) --------------------
$ws = Invoke-AzJson -Arguments @('ml', 'workspace', 'show', '-n', $Workspace, '-g', $ResourceGroup, '-o', 'json')
$wsStorageId = $ws.storage_account

$ds = Invoke-AzJson -Arguments @('ml', 'datastore', 'show', '--name', $SnapshotDatastore, '-g', $ResourceGroup, '-w', $Workspace, '-o', 'json')
$snapStorageId = (Invoke-Az -Arguments @('storage', 'account', 'show', '-n', $ds.account_name, '--query', 'id', '-o', 'tsv')).StdOut.Trim()
if (-not $snapStorageId) {
    throw "Could not resolve the resource id of storage account $($ds.account_name)."
}

# --- 3. grant the roles -------------------------------------------------------
Write-Host "`n[2/3] Workspace storage ($($wsStorageId.Split('/')[-1])) - Storage Blob Data Contributor"
Write-Host "  $(Grant-Role -PrincipalId $principalId -Role 'Storage Blob Data Contributor' -Scope $wsStorageId)"

Write-Host "`n[3/3] Snapshot storage ($($ds.account_name)) - Storage Blob Data Reader"
Write-Host "  $(Grant-Role -PrincipalId $principalId -Role 'Storage Blob Data Reader' -Scope $snapStorageId)"

Write-Host ""
Write-Host "Role assignments can take a couple of minutes to take effect." -ForegroundColor Yellow
Write-Host "Next: resubmit the pipeline" -ForegroundColor Green
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\20_aml_train.ps1"
