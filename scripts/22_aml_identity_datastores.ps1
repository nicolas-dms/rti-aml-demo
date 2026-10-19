<#
.SYNOPSIS
    Switches the AML workspace system datastores to identity-based auth and grants
    the signed-in user data-plane access to the workspace storage account.

.DESCRIPTION
    An Azure Policy sets allowSharedKeyAccess = false on every storage account of the
    subscription, and it remediates continuously. The AML workspace default datastores
    (workspaceblobstore / workspaceartifactstore) are created with accesskey auth, so
    every write and every log download against them dies with
    KeyBasedAuthenticationNotPermitted.

    Re-enabling shared keys would be undone by the policy within hours. The durable fix
    is to make the workspace use Entra identities for its own datastores, which is also
    the locked decision for this repo (managed identity + RBAC, zero keys).

.NOTES
    --system-datastores-auth-mode / -d is a PREVIEW parameter of az ml workspace
    create|update. Valid values: accesskey, identity.

    Uses the Invoke-Az wrapper: on Windows PowerShell 5.1 with
    $ErrorActionPreference = 'Stop', any native command writing to stderr raises a
    terminating NativeCommandError, and 2>$null does not prevent it.
#>

[CmdletBinding()]
param(
    [string] $ResourceGroup = 'rg-rti-aml-demo',
    [string] $Workspace = 'aml-rti-demo',
    [string] $Role = 'Storage Blob Data Contributor'
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

Write-Host "=== AML system datastores -> identity auth ===" -ForegroundColor Cyan

# --- 1. resolve the workspace storage account (never hardcode it) -------------
$ws = Invoke-AzJson -Arguments @('ml', 'workspace', 'show', '-n', $Workspace, '-g', $ResourceGroup, '-o', 'json')
$storageId = $ws.storage_account
if (-not $storageId) {
    throw "Could not read storage_account from the workspace."
}
$storageName = $storageId.Split('/')[-1]

Write-Host "workspace       : $Workspace"
Write-Host "storage account : $storageName"
Write-Host "current auth    : $($ws.system_datastores_auth_mode)"
Write-Host ""

# --- 2. grant the signed-in user data-plane access ----------------------------
# Without this, az ml job download cannot read the artifact store once the
# account key path is closed: RBAC becomes the only door.
$me = Invoke-AzJson -Arguments @('ad', 'signed-in-user', 'show', '-o', 'json')
Write-Host "[1/3] Granting '$Role' to $($me.userPrincipalName) on $storageName ..."

$assign = Invoke-Az -Arguments @(
    'role', 'assignment', 'create',
    '--assignee-object-id', $me.id,
    '--assignee-principal-type', 'User',
    '--role', $Role,
    '--scope', $storageId,
    '-o', 'none'
)
if ($assign.ExitCode -eq 0) {
    Write-Host "  granted (or already present)"
}
elseif ($assign.StdErr -match 'RoleAssignmentExists') {
    Write-Host "  already assigned"
}
else {
    Write-Warning "role assignment failed -> exit $($assign.ExitCode)"
    Write-Host $assign.StdErr
}

# --- 3. flip the workspace to identity-based system datastores ----------------
Write-Host "`n[2/3] Setting system-datastores-auth-mode = identity ..."
if ($ws.system_datastores_auth_mode -eq 'identity') {
    Write-Host "  already identity, nothing to do"
}
else {
    $updated = Invoke-AzJson -Arguments @(
        'ml', 'workspace', 'update',
        '-n', $Workspace, '-g', $ResourceGroup,
        '--system-datastores-auth-mode', 'identity',
        '-o', 'json'
    )
    Write-Host "  now: $($updated.system_datastores_auth_mode)"
}

# --- 4. verify the datastores actually switched -------------------------------
Write-Host "`n[3/3] Datastore credential types:"
foreach ($name in @('workspaceblobstore', 'workspaceartifactstore')) {
    $ds = Invoke-Az -Arguments @('ml', 'datastore', 'show', '--name', $name, '-g', $ResourceGroup, '-w', $Workspace, '-o', 'json')
    if ($ds.ExitCode -ne 0) {
        Write-Warning "  $name -> not readable (exit $($ds.ExitCode))"
        continue
    }
    $parsed = $ds.StdOut | ConvertFrom-Json
    $credType = 'none (identity)'
    if ($parsed.credentials -and $parsed.credentials.type) {
        $credType = $parsed.credentials.type
    }
    Write-Host ("  {0,-24} {1}" -f $name, $credType)
}

Write-Host ""
Write-Host "Next: resubmit the pipeline" -ForegroundColor Green
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\20_aml_train.ps1"
