<#
.SYNOPSIS
    Teardown of what bills 24/7 after a demo: the two online endpoints. Optional: registry, PROD workspace.

.DESCRIPTION
    Asks for confirmation BEFORE EACH deletion (type the name, or y). Nothing is deleted without an answer.
    Deleting an endpoint deletes its deployments with it: this is the only deletion that works while
    a deployment still has traffic (a deployment with traffic cannot be deleted on its own).

    Default (always safe to re-run):
      - endpoint ENDPOINT_DEV  in AML_DEV_WORKSPACE   (temp-forecast-ep)
      - endpoint ENDPOINT_PROD in AML_PROD_WORKSPACE  (temp-forecast-prod-ep)

    Options:
      -IncludeRegistry   also deletes the AML registry AML_REGISTRY (its storage + ACR bill until deleted)
      -IncludeProdWorkspace  also deletes the PROD workspace AML_PROD_WORKSPACE

    NOT handled here (do it in the portal or with scripts\91_cost_guard.ps1 -Stop):
      - Fabric capacity (suspend it: it is the dominant cost)
      - the whole resource group (az group delete --name <AZURE_RESOURCE_GROUP>) if you want everything gone
      - the Fabric workspace and its items

.EXAMPLE
    .\scripts\90_teardown.ps1
    .\scripts\90_teardown.ps1 -IncludeRegistry -IncludeProdWorkspace

.NOTES
    ASCII only - Windows PowerShell 5.1 reads .ps1 as ANSI.
#>
[CmdletBinding()]
param(
    [switch] $IncludeRegistry,
    [switch] $IncludeProdWorkspace,
    [string] $ResourceGroup = (& "$PSScriptRoot\lib\cfg.ps1" AZURE_RESOURCE_GROUP -Required),
    [string] $DevWorkspace = (& "$PSScriptRoot\lib\cfg.ps1" AML_DEV_WORKSPACE -Required),
    [string] $ProdWorkspace = (& "$PSScriptRoot\lib\cfg.ps1" AML_PROD_WORKSPACE -Required),
    [string] $DevEndpoint = (& "$PSScriptRoot\lib\cfg.ps1" ENDPOINT_DEV -Default 'temp-forecast-ep'),
    [string] $ProdEndpoint = (& "$PSScriptRoot\lib\cfg.ps1" ENDPOINT_PROD -Default 'temp-forecast-prod-ep'),
    [string] $Registry = (& "$PSScriptRoot\lib\cfg.ps1" AML_REGISTRY -Default '')
)

$ErrorActionPreference = 'Stop'

function Invoke-AzSoft {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & az @args 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ Ok = ($code -eq 0); Output = (($out -join "`n").Trim()) }
}

function Confirm-Delete {
    param([string] $What)
    $answer = Read-Host "Delete $What ? (y/N)"
    return ($answer -match '^(y|yes|o|oui)$')
}

function Remove-Endpoint {
    param([string] $Name, [string] $Workspace)
    Write-Host "`n==> Endpoint $Name in $Workspace" -ForegroundColor Cyan
    $show = Invoke-AzSoft ml online-endpoint show --name $Name --resource-group $ResourceGroup --workspace-name $Workspace --query name --output tsv
    if (-not $show.Ok) { Write-Host "  not found (already deleted, or workspace absent): nothing to do"; return }
    if (-not (Confirm-Delete "endpoint $Name (and all its deployments)")) { Write-Host "  skipped"; return }
    $del = Invoke-AzSoft ml online-endpoint delete --name $Name --resource-group $ResourceGroup --workspace-name $Workspace --yes
    if ($del.Ok) { Write-Host "  deleted" -ForegroundColor Green } else { Write-Host "  FAILED: $($del.Output)" -ForegroundColor Red }
}

Remove-Endpoint -Name $ProdEndpoint -Workspace $ProdWorkspace
Remove-Endpoint -Name $DevEndpoint -Workspace $DevWorkspace

if ($IncludeRegistry) {
    Write-Host "`n==> Registry $Registry" -ForegroundColor Cyan
    if ([string]::IsNullOrWhiteSpace($Registry)) { Write-Host "  AML_REGISTRY is not set: skipped" }
    else {
        $show = Invoke-AzSoft ml registry show --name $Registry --resource-group $ResourceGroup --query name --output tsv
        if (-not $show.Ok) { Write-Host "  not found: nothing to do" }
        elseif (Confirm-Delete "registry $Registry (shared models are lost)") {
            $del = Invoke-AzSoft ml registry delete --name $Registry --resource-group $ResourceGroup --yes
            if ($del.Ok) { Write-Host "  deleted" -ForegroundColor Green } else { Write-Host "  FAILED: $($del.Output)" -ForegroundColor Red }
        } else { Write-Host "  skipped" }
    }
}

if ($IncludeProdWorkspace) {
    Write-Host "`n==> PROD workspace $ProdWorkspace" -ForegroundColor Cyan
    $show = Invoke-AzSoft ml workspace show --name $ProdWorkspace --resource-group $ResourceGroup --query name --output tsv
    if (-not $show.Ok) { Write-Host "  not found: nothing to do" }
    elseif (Confirm-Delete "workspace $ProdWorkspace (its storage, key vault and insights are kept unless you delete them)") {
        $del = Invoke-AzSoft ml workspace delete --name $ProdWorkspace --resource-group $ResourceGroup --yes
        if ($del.Ok) { Write-Host "  deleted" -ForegroundColor Green } else { Write-Host "  FAILED: $($del.Output)" -ForegroundColor Red }
    } else { Write-Host "  skipped" }
}

Write-Host "`nStill billing? Run: .\scripts\91_cost_guard.ps1   (and -Stop to suspend the Fabric capacity)."
