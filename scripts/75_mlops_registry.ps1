<#
.SYNOPSIS
    Track C / M1b - Create or verify only the shared AML registry mlr-rti-demo.

.DESCRIPTION
    Target: registry mlr-rti-demo / rg-rti-aml-demo / westus3 (aml/registry/registry.yml).
    Requires an existing Azure CLI login and the ml extension. Installs nothing,
    does not switch accounts, grants no role, changes no network setting.
    Lists registries first; an existing registry is read and never updated.

    A registry creates its OWN Storage account and ACR in a managed resource group
    (azureml-rg-mlr-rti-demo-...) that the caller does not choose. Policy
    MCAPSGovDeployPolicies may remediate that storage to publicNetworkAccess
    Disabled some minutes after creation. Exemption exempt-rti-aml-registry
    (subscription scope, expires 2026-10-29) is meant to prevent it, but that is
    NOT proven until the managed storage is rechecked at least 30 minutes later.
    The registry has a standing cost (storage + ACR) until teardown.

    This script does not search the managed resource group. Verify its storage
    independently (Resource Graph) right after creation and again after 30 minutes.

.PARAMETER VerifyOnly
    Read-only; fails if the registry is absent.

.EXAMPLE
    .\scripts\75_mlops_registry.ps1

.NOTES
    ASCII; Windows PowerShell 5.1 compatible. User-operated, not agent-executed.
    Raw CLI stdout is never printed. stderr is kept in a local temp file only.
    Run from the repository root (the YAML path is relative).
#>
[CmdletBinding()]
param([switch] $VerifyOnly)

$ErrorActionPreference = 'Stop'
$SubscriptionId = '<SUBSCRIPTION_ID>'
$TenantId = '<TENANT_ID>'
$ResourceGroup = 'rg-rti-aml-demo'
$Location = 'westus3'
$RegistryName = 'mlr-rti-demo'
$RegistryFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'aml\registry\registry.yml'
$RegistryId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.MachineLearningServices/registries/$RegistryName"

$AzCmd = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
if (-not (Test-Path -LiteralPath $AzCmd -PathType Leaf)) {
    $AzCmd = (Get-Command az -CommandType Application -ErrorAction Stop).Source
}

function Invoke-AzRaw {
    param([Parameter(Mandatory = $true)] [string[]] $Arguments)
    $errorFile = [IO.Path]::GetTempFileName()
    $previousPreference = $ErrorActionPreference
    $stdout = @()
    $stderr = ''
    $exitCode = $null
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        $stdout = & $AzCmd @Arguments 2> $errorFile
        $exitCode = $global:LASTEXITCODE
        $stderr = [IO.File]::ReadAllText($errorFile)
    }
    finally {
        $ErrorActionPreference = $previousPreference
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        StdOut = (($stdout | ForEach-Object { [string] $_ }) -join "`n").Trim()
        StdErr = $stderr
    }
}

function Invoke-AzChecked {
    param(
        [Parameter(Mandatory = $true)] [string[]] $Arguments,
        [Parameter(Mandatory = $true)] [string] $Operation
    )
    $result = Invoke-AzRaw -Arguments $Arguments
    if ($null -eq $result.ExitCode -or $result.ExitCode -ne 0) {
        $diagnosticPath = Join-Path ([IO.Path]::GetTempPath()) ("rti-m1b-error-" + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($diagnosticPath, $result.StdErr)
        Write-Host "Local stderr diagnostic: $diagnosticPath" -ForegroundColor Yellow
        Write-Host 'Inspect locally; share only the ERROR line after checking for secrets.' -ForegroundColor Yellow
        $knownCodes = @('InvalidAuthenticationTokenTenant', 'AuthorizationFailed', 'AuthenticationFailed',
            'ResourceGroupNotFound', 'RequestDisallowedByPolicy', 'MissingSubscriptionRegistration',
            'SubscriptionDisabled', 'AlreadyExists', 'NameNotAvailable', 'Conflict')
        $codes = @($knownCodes | Where-Object {
            $result.StdErr -match [regex]::Escape($_) -or $result.StdOut -match [regex]::Escape($_)
        })
        throw "$Operation failed (CLI exit '$($result.ExitCode)', known codes: $($codes -join ', ')). This is not proof of absence."
    }
    return $result.StdOut
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory = $true)] [string[]] $Arguments,
        [Parameter(Mandatory = $true)] [string] $Operation
    )
    $text = Invoke-AzChecked -Arguments ($Arguments + @('--output', 'json', '--only-show-errors')) -Operation $Operation
    if ([string]::IsNullOrWhiteSpace($text)) { throw "$Operation returned empty stdout, not valid JSON evidence." }
    try { $parsed = ConvertFrom-Json -InputObject $text -ErrorAction Stop }
    catch { throw "$Operation returned invalid JSON; raw output suppressed." }
    if ($text.TrimStart().StartsWith('[')) { return ,@($parsed | Where-Object { $null -ne $_ }) }
    if ($null -eq $parsed -or -not $text.TrimStart().StartsWith('{')) { throw "$Operation returned neither a JSON object nor an array." }
    return $parsed
}

Write-Host '=== Track C / M1b - shared registry only ===' -ForegroundColor Cyan
Write-Host "Target: $RegistryId ($Location); VerifyOnly=$VerifyOnly"

if (-not (Test-Path -LiteralPath $RegistryFile -PathType Leaf)) { throw "Registry definition not found: $RegistryFile" }

$account = Invoke-AzJson -Arguments @('account', 'show') -Operation 'CLI account context'
if ($account.id -ne $SubscriptionId -or $account.tenantId -ne $TenantId -or $account.state -ne 'Enabled') {
    throw 'CLI context must be the locked subscription and tenant, state Enabled. Nothing was written.'
}
$extensions = Invoke-AzJson -Arguments @('extension', 'list') -Operation 'Installed CLI extensions'
$mlExtensions = @($extensions | Where-Object { $_.name -eq 'ml' })
if ($mlExtensions.Count -ne 1) { throw 'The ml CLI extension must already be installed; no implicit installation.' }
Write-Host "ML extension version: $($mlExtensions[0].version)"

$registries = Invoke-AzJson -Arguments @('ml', 'registry', 'list', '--resource-group', $ResourceGroup,
    '--subscription', $SubscriptionId) -Operation 'Registry existence list'
$matches = @($registries | Where-Object { $_.name -eq $RegistryName })
if ($matches.Count -gt 1) { throw 'Registry list returned multiple target matches; refusing any write.' }

if ($matches.Count -eq 0) {
    if ($VerifyOnly) { throw "$RegistryName is absent. VerifyOnly never creates resources." }
    Write-Host 'Registry absent. Creating; standing cost (storage + ACR) until teardown.' -ForegroundColor Yellow
    Invoke-AzChecked -Arguments @('ml', 'registry', 'create', '--file', $RegistryFile,
        '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId,
        '--output', 'none', '--only-show-errors') -Operation 'Registry creation' | Out-Null
    Write-Host "Registry creation command completed at $([DateTime]::UtcNow.ToString('o'))."
} else {
    Write-Host 'Registry exists. Read-only validation; no update.'
}

$registry = Invoke-AzJson -Arguments @('ml', 'registry', 'show', '--name', $RegistryName,
    '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId) -Operation 'Registry show'
$checkedAt = [DateTime]::UtcNow
Write-Host "`n--- M1b current-state evidence (copy to docs/PROGRESS.md) ---" -ForegroundColor Green
[pscustomobject]@{
    checkedUtc = $checkedAt.ToString('o')
    verifyOnly = [bool] $VerifyOnly
    name = $registry.name
    location = $registry.location
    id = $registry.id
    publicNetworkAccess = $registry.public_network_access
    replicationLocations = (@($registry.replication_locations | ForEach-Object { $_.location }) -join ',')
    discoveryUrl = $registry.discovery_url
} | Format-List
Write-Host 'Registry exists. This is NOT the M1b exit proof.' -ForegroundColor Yellow
Write-Host 'Next: find the managed resource group (azureml-rg-mlr-rti-demo-*) and its storage with Resource Graph,'
Write-Host "then recheck that storage publicNetworkAccess is Enabled no earlier than $($checkedAt.AddMinutes(30).ToString('o'))."
Write-Host 'Pause Fabric capacity and run scripts/91_cost_guard.ps1 after the session.'
