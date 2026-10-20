<#
.SYNOPSIS
    Pre-fills demo.config.env from your current az session. Run once, before anything else.

.DESCRIPTION
    - Subscription and tenant: taken from `az account show`.
    - Fabric capacity: if exactly one Microsoft.Fabric/capacities exists in the subscription it is
      used (name, resource group, region). If there are several, the script lists them and you set
      FABRIC_CAPACITY / FABRIC_CAPACITY_RESOURCE_GROUP yourself.
    - Registry name: made unique with a suffix derived from <subscription>/<resource group>.
    - Everything else keeps the default written in the file.

    Only keys that are still empty or still a <placeholder> are written, unless -Force is given.
    Nothing is created in Azure. Safe to re-run.

.EXAMPLE
    .\scripts\00a_init_config.ps1
    .\scripts\00a_init_config.ps1 -ResourceGroup rg-my-demo -Force

.NOTES
    If PowerShell refuses to run scripts:  Set-ExecutionPolicy -Scope Process Bypass
    ASCII only - Windows PowerShell 5.1 reads .ps1 as ANSI.
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = '',
    [string] $Location = '',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$AzCmd = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
if (-not (Test-Path $AzCmd)) { $AzCmd = (Get-Command az -ErrorAction Stop).Source }

function Invoke-AzQuiet {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $AzCmd @args 2>$null } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { return $null }
    return (($out | ForEach-Object { "$_" }) -join "`n")
}

function Get-Cfg { param([string] $Key) return (& "$PSScriptRoot\lib\cfg.ps1" $Key) }
function Test-Unset { param([string] $Value) return ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '^<.*>$') }

function Set-IfUnset {
    param([string] $Key, [string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $current = Get-Cfg $Key
    if ($Force -or (Test-Unset $current)) {
        & "$PSScriptRoot\lib\cfg-set.ps1" $Key $Value | Out-Null
        Write-Host ("  {0,-34} = {1}" -f $Key, $Value)
    } else {
        Write-Host ("  {0,-34} kept ({1})" -f $Key, $current) -ForegroundColor DarkGray
    }
}

Write-Host "`n==> Reading the az session" -ForegroundColor Cyan
$json = Invoke-AzQuiet account show --output json
if (-not $json) { throw "No az session. Run: az login   (add --tenant <tenant-id> if you have several tenants)" }
$acct = $json | ConvertFrom-Json
Write-Host "  account : $($acct.user.name)"
Write-Host "  sub     : $($acct.name) ($($acct.id))"
Write-Host "  tenant  : $($acct.tenantId)"

Write-Host "`n==> Writing demo.config.env" -ForegroundColor Cyan
Set-IfUnset 'AZURE_SUBSCRIPTION_ID' $acct.id
Set-IfUnset 'AZURE_TENANT_ID' $acct.tenantId

# Fabric capacity (needs read access on the subscription; no extension required).
$capJson = Invoke-AzQuiet resource list --resource-type Microsoft.Fabric/capacities --query "[].{name:name,rg:resourceGroup,location:location}" --output json
$caps = $null
if ($capJson) { $caps = ConvertFrom-Json $capJson }
$capCount = @($caps).Count
$capLocation = ''
if ($capCount -eq 1) {
    $cap = @($caps)[0]
    Set-IfUnset 'FABRIC_CAPACITY' $cap.name
    Set-IfUnset 'FABRIC_CAPACITY_RESOURCE_GROUP' $cap.rg
    $capLocation = ($cap.location -replace '\s', '').ToLower()
} elseif ($capCount -gt 1) {
    Write-Host "  several Fabric capacities found - set FABRIC_CAPACITY and FABRIC_CAPACITY_RESOURCE_GROUP yourself:" -ForegroundColor Yellow
    foreach ($c in $caps) { Write-Host ("    {0}  (rg {1}, {2})" -f $c.name, $c.rg, $c.location) }
} else {
    Write-Host "  no Fabric capacity visible in this subscription (create one, or start a Fabric trial)" -ForegroundColor Yellow
}

# Region: explicit parameter, else the capacity's region (the demo needs both in the same region).
if (-not $Location) { $Location = $capLocation }
if ($Location) { Set-IfUnset 'AZURE_LOCATION' $Location }
if ($ResourceGroup) { Set-IfUnset 'AZURE_RESOURCE_GROUP' $ResourceGroup }

# Registry name must be unique in the tenant: add a stable suffix.
$sub = Get-Cfg 'AZURE_SUBSCRIPTION_ID'
$rg = Get-Cfg 'AZURE_RESOURCE_GROUP'
if (-not (Test-Unset $sub) -and -not (Test-Unset $rg)) {
    $hash = ([System.Security.Cryptography.SHA256]::Create()).ComputeHash([Text.Encoding]::UTF8.GetBytes("$sub/$rg"))
    $suffix = -join ($hash[0..3] | ForEach-Object { $_.ToString('x2') })
    Set-IfUnset 'AML_REGISTRY' "mlr-rti-$suffix"
    Write-Host "  (derived suffix: $suffix - used by 00_bootstrap.ps1 for the storage and Function names)" -ForegroundColor DarkGray
}

Write-Host "`n==> Still to fill in by hand" -ForegroundColor Cyan
$required = 'AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_LOCATION', 'AZURE_RESOURCE_GROUP',
            'AML_DEV_WORKSPACE', 'AML_PROD_WORKSPACE', 'AML_REGISTRY',
            'FABRIC_CAPACITY', 'FABRIC_CAPACITY_RESOURCE_GROUP', 'FABRIC_WORKSPACE'
$todo = @($required | Where-Object { Test-Unset (Get-Cfg $_) })
if ($todo.Count -eq 0) {
    Write-Host "  nothing: every required key is set." -ForegroundColor Green
} else {
    foreach ($k in $todo) { Write-Host "  $k" -ForegroundColor Yellow }
    Write-Host "  Edit demo.config.env, then re-run this script or go straight to 00b_preflight.ps1."
}
Write-Host "`nOptional (leave blank if you do not use them): STORAGE_ACCOUNT / FUNCTION_STORAGE_ACCOUNT / FUNCTION_APP are derived by 00_bootstrap.ps1; ADO_* and SP_*_OBJECT_ID only matter for the Azure DevOps path."
Write-Host "Next: .\scripts\00b_preflight.ps1"
