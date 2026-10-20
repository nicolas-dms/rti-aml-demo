<#
.SYNOPSIS
    Single command that answers "what is costing me money right now?" across the two
    demos, and can shut down everything that is safe to shut down.

.DESCRIPTION
    The demo has exactly four things that can bill, and they behave very differently:

      1. Fabric capacity (F32, ~5.76 $/h = ~138 $/day)
         The dominant cost by an order of magnitude. Billed as long as it is Active,
         whether or not anything is running on it. No auto-pause exists. This is the
         one that actually matters.

      2. AML managed online endpoints (~0.15-0.30 $/h per instance)
         NEVER scale to zero. A deployment with 1 instance bills 24/7 until deleted.
         This is the classic forgotten cost.

      3. AML compute clusters (0 $/h at rest)
         Already safe: min_instances = 0 plus an idle timeout means the node is
         released automatically. Reported here for confirmation only.

      4. Function App on Flex Consumption (~0 $/h)
         Pay per execution. Negligible. Not reported.

.PARAMETER Stop
    Suspends the Fabric capacity and forces every AML cluster to min_instances = 0.
    Online endpoints are only REPORTED, never deleted: deleting a deployment is
    destructive and slow to undo, so it stays a deliberate human decision.

.NOTES
    ASCII only - PowerShell 5.1 reads .ps1 as ANSI.
    Hourly rates below are indicative retail figures used to rank the cost items,
    not a billing source. The authoritative number is Azure Cost Management.
#>

[CmdletBinding()]
param(
    [string] $ResourceGroup = (& "$PSScriptRoot\lib\cfg.ps1" AZURE_RESOURCE_GROUP -Required),
    [string] $Workspace = (& "$PSScriptRoot\lib\cfg.ps1" AML_DEV_WORKSPACE -Required),
    [string] $CapacityResourceGroup = (& "$PSScriptRoot\lib\cfg.ps1" FABRIC_CAPACITY_RESOURCE_GROUP -Required),
    [string] $CapacityName = (& "$PSScriptRoot\lib\cfg.ps1" FABRIC_CAPACITY -Required),
    [switch] $Stop
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

# indicative retail rates, USD per hour - used for ranking only
$RateTable = @{
    'Standard_DS2_v2'       = 0.146
    'Standard_DS3_v2'       = 0.293
    'Standard_DS4_v2'       = 0.585
    'Standard_F2s_v2'       = 0.085
    'Standard_F4s_v2'       = 0.169
}

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

function Get-Json {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $result = Invoke-Az -Arguments $Arguments
    if ($result.ExitCode -ne 0) { return $null }
    if (-not $result.StdOut.Trim()) { return $null }
    return ($result.StdOut | ConvertFrom-Json)
}

# PowerShell 5.1 trap: @($null).Count is 1, not 0. An empty JSON array can parse to
# $null and then counts as one phantom element - which is how a cost report ends up
# claiming a node exists when none does. Always go through this helper.
function Get-JsonArray {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $result = Invoke-Az -Arguments $Arguments
    if ($result.ExitCode -ne 0) { return @() }
    if (-not $result.StdOut.Trim()) { return @() }
    $parsed = $result.StdOut | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }
    return @($parsed | Where-Object { $null -ne $_ })
}

$total = 0.0

Write-Host ""
Write-Host "=== What is billing right now ===" -ForegroundColor Cyan
Write-Host ""

# --- 1. Fabric capacity -------------------------------------------------------
Write-Host "[1] Fabric capacity" -ForegroundColor Cyan

$subId = (Invoke-Az -Arguments @('account', 'show', '--query', 'id', '-o', 'tsv')).StdOut.Trim()
$capUrl = "https://management.azure.com/subscriptions/$subId/resourceGroups/$CapacityResourceGroup/providers/Microsoft.Fabric/capacities/$CapacityName" + "?api-version=2023-11-01"
$cap = Get-Json -Arguments @('rest', '--method', 'get', '--url', $capUrl, '--query', 'properties', '-o', 'json')

if (-not $cap) {
    Write-Host "  could not read the capacity state - check 'az account show'" -ForegroundColor Yellow
}
else {
    $sku = 'F32'
    $capRate = 5.76
    Write-Host "  $CapacityName ($sku) : state = $($cap.state)"
    if ($cap.state -eq 'Active') {
        $total += $capRate
        Write-Host "  ACTIVE - approx $capRate USD/h (~$([math]::Round($capRate * 24, 0)) USD/day)" -ForegroundColor Yellow
    }
    else {
        Write-Host "  not active - 0 USD/h" -ForegroundColor Green
    }
}

# --- 2. online endpoints ------------------------------------------------------
Write-Host ""
Write-Host "[2] AML online endpoints (these never scale to zero)" -ForegroundColor Cyan

$endpoints = Get-JsonArray -Arguments @('ml', 'online-endpoint', 'list', '-g', $ResourceGroup, '-w', $Workspace, '-o', 'json')
if ($endpoints.Count -eq 0) {
    Write-Host "  none - 0 USD/h" -ForegroundColor Green
}
else {
    foreach ($ep in $endpoints) {
        Write-Host "  endpoint $($ep.name)"
        $deployments = Get-JsonArray -Arguments @('ml', 'online-deployment', 'list', '-e', $ep.name, '-g', $ResourceGroup, '-w', $Workspace, '-o', 'json')
        if ($deployments.Count -eq 0) {
            Write-Host "    no deployment - 0 USD/h" -ForegroundColor Green
            continue
        }
        foreach ($dep in $deployments) {
            # 'online-deployment list' returns a summary that omits instance_count.
            # Reading it from the list is how a live deployment gets reported as 0.
            $detail = Get-Json -Arguments @('ml', 'online-deployment', 'show', '-n', $dep.name, '-e', $ep.name, '-g', $ResourceGroup, '-w', $Workspace, '-o', 'json')
            if (-not $detail) { $detail = $dep }

            $size = "$($detail.instance_type)"
            $count = 0
            $assumed = $false
            if ($detail.PSObject.Properties['instance_count'] -and $null -ne $detail.instance_count) {
                $count = [int]$detail.instance_count
            }
            if ($count -le 0) {
                # A managed online deployment never has 0 instance: it cannot scale to
                # zero. A zero here means the field is missing, not that it is free.
                $count = 1
                $assumed = $true
            }

            $rate = 0.0
            if ($RateTable.ContainsKey($size)) { $rate = $RateTable[$size] * $count }
            $total += $rate

            $traffic = 0
            if ($ep.traffic -and $ep.traffic.PSObject.Properties[$dep.name]) {
                $traffic = $ep.traffic.$($dep.name)
            }

            $suffix = ''
            if ($assumed) { $suffix = ' [instance_count unavailable, assumed 1]' }
            if (-not $RateTable.ContainsKey($size)) { $suffix += ' [no rate for this size]' }

            Write-Host "    $($dep.name) : $count x $size, traffic $traffic% - approx $([math]::Round($rate, 3)) USD/h$suffix" -ForegroundColor Yellow
            Write-Host "      billing 24/7 until deleted - approx $([math]::Round($rate * 24 * 30, 0)) USD/month" -ForegroundColor Yellow
        }
    }
}

# --- 3. compute clusters ------------------------------------------------------
Write-Host ""
Write-Host "[3] AML compute clusters (safe by construction)" -ForegroundColor Cyan

$computes = Get-JsonArray -Arguments @('ml', 'compute', 'list', '-g', $ResourceGroup, '-w', $Workspace, '-o', 'json')
$clusters = @($computes | Where-Object { $_.type -eq 'amlcompute' })
if ($clusters.Count -eq 0) {
    Write-Host "  none"
}
else {
    foreach ($c in $clusters) {
        $nodes = Get-JsonArray -Arguments @('ml', 'compute', 'list-nodes', '-n', $c.name, '-g', $ResourceGroup, '-w', $Workspace, '-o', 'json')
        $min = [int]$c.min_instances
        $idle = $c.idle_time_before_scale_down
        $line = "  $($c.name) : $($nodes.Count) node(s), min_instances=$min, idle=$idle s"

        if ($nodes.Count -gt 0) {
            $rate = 0.0
            if ($RateTable.ContainsKey("$($c.size)")) { $rate = $RateTable["$($c.size)"] * $nodes.Count }
            $total += $rate
            Write-Host "$line - approx $([math]::Round($rate, 3)) USD/h" -ForegroundColor Yellow
        }
        else {
            Write-Host "$line - 0 USD/h" -ForegroundColor Green
        }

        if ($min -ne 0) {
            Write-Host "    WARNING: min_instances is not 0, this cluster cannot scale to zero" -ForegroundColor Red
        }
    }
}

# --- total --------------------------------------------------------------------
Write-Host ""
Write-Host "-------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ("Estimated burn rate: {0} USD/h  (~{1} USD/day)" -f [math]::Round($total, 2), [math]::Round($total * 24, 0)) -ForegroundColor Cyan
Write-Host "-------------------------------------------------------------" -ForegroundColor Cyan

# --- shutdown -----------------------------------------------------------------
if (-not $Stop) {
    Write-Host ""
    Write-Host "To shut down what is safe to shut down:" -ForegroundColor Green
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\91_cost_guard.ps1 -Stop"
    return
}

Write-Host ""
Write-Host "=== Shutting down ===" -ForegroundColor Cyan

Write-Host "[1] Suspending the Fabric capacity ..."
$suspend = Invoke-Az -Arguments @('fabric', 'capacity', 'suspend', '--resource-group', $CapacityResourceGroup, '--capacity-name', $CapacityName)
if ($suspend.ExitCode -eq 0) {
    Write-Host "  suspend accepted (no output means success - verify below)" -ForegroundColor Green
}
else {
    Write-Host "  failed: $($suspend.StdErr.Trim())" -ForegroundColor Red
}

Start-Sleep -Seconds 20
$cap = Get-Json -Arguments @('rest', '--method', 'get', '--url', $capUrl, '--query', 'properties', '-o', 'json')
if ($cap) { Write-Host "  capacity state now: $($cap.state)" }

Write-Host ""
Write-Host "[2] Forcing every cluster to min_instances = 0 ..."
foreach ($c in $clusters) {
    if ([int]$c.min_instances -eq 0) {
        Write-Host "  $($c.name) : already 0" -ForegroundColor Green
        continue
    }
    $upd = Invoke-Az -Arguments @('ml', 'compute', 'update', '-n', $c.name, '-g', $ResourceGroup, '-w', $Workspace, '--min-instances', '0', '-o', 'none')
    if ($upd.ExitCode -eq 0) { Write-Host "  $($c.name) : set to 0" -ForegroundColor Green }
    else { Write-Host "  $($c.name) : failed - $($upd.StdErr.Trim())" -ForegroundColor Red }
}

Write-Host ""
Write-Host "[3] Online endpoints - NOT deleted on purpose" -ForegroundColor Yellow
if ($endpoints.Count -eq 0) {
    Write-Host "  none exist" -ForegroundColor Green
}
else {
    Write-Host "  Deleting a deployment is destructive and slow to recreate, so it stays"
    Write-Host "  your decision. They keep billing until you run:"
    foreach ($ep in $endpoints) {
        Write-Host "    az ml online-endpoint delete -n $($ep.name) -g $ResourceGroup -w $Workspace --yes"
    }
}
