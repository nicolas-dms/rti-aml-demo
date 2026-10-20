<#
.SYNOPSIS
    Track C / M1a - Create or verify only the PROD AML workspace (AML_PROD_WORKSPACE).

.DESCRIPTION
    Target: AML_PROD_WORKSPACE / AZURE_RESOURCE_GROUP / AZURE_LOCATION of demo.config.env.
    Requires an existing Azure CLI login and the ml extension. Installs nothing
    and does not switch accounts. Lists workspaces before deciding to create.
    Existing incompatible workspaces are never updated or repaired automatically.

    Workspace creation can also create backing Storage, Key Vault and Application
    Insights (including a Log Analytics dependency); ACR may be created on demand.
    These dependencies can incur charges: no compute does NOT mean zero cost.
    Workspace provisioning may assign its identity roles on its dependencies;
    resource-group-wide role assignments are explicitly disabled. This script
    makes no separate role assignments, network changes or provider registrations.
    No AML registry, online endpoint, deployment or compute is created.

    Verification uses ARM GET for provisioningState, systemDatastoresAuthMode,
    identity and the actual backing storage ID (not the shared snapshot account).
    Disabled, missing or non-Enabled storage publicNetworkAccess fails closed.
    Enabled alone does not prove data-plane access or exemption validity.

.PARAMETER VerifyOnly
    Read-only checks; fails if the workspace is absent. Run again at least 30
    minutes after provisioning completes to detect delayed policy remediation.
    There is no sleep or automatic 30-minute validation. Record both timestamps
    and independently verify the workspace through Resource Graph for M1a exit.

.EXAMPLE
    powershell.exe -NoProfile -File .\scripts\70_mlops_prod_bootstrap.ps1

.EXAMPLE
    powershell.exe -NoProfile -File .\scripts\70_mlops_prod_bootstrap.ps1 -VerifyOnly

.NOTES
    ASCII; Windows PowerShell 5.1 compatible. User-operated, not agent-executed.
    No raw CLI JSON, stdout or stderr is printed (may contain sensitive data).
    Authentication/authorization/list errors are fatal, never treated as absence.
    Official references checked before implementation:
    https://learn.microsoft.com/en-us/cli/azure/ml/workspace
    https://learn.microsoft.com/en-us/azure/machine-learning/how-to-manage-workspace-cli
    https://learn.microsoft.com/en-us/rest/api/azureml/workspaces/get?view=rest-azureml-2025-06-01
    https://learn.microsoft.com/en-us/rest/api/storagerp/storage-accounts/get-properties?view=rest-storagerp-2023-05-01
    https://learn.microsoft.com/en-us/rest/api/resources/subscriptions/get?view=rest-resources-2022-12-01
#>
[CmdletBinding()]
param([switch] $VerifyOnly)

$ErrorActionPreference = 'Stop'
# Target comes from demo.config.env; there is no command-line override on purpose.
$SubscriptionId = & "$PSScriptRoot\lib\cfg.ps1" AZURE_SUBSCRIPTION_ID -Required
$TenantId = & "$PSScriptRoot\lib\cfg.ps1" AZURE_TENANT_ID -Required
$ResourceGroup = & "$PSScriptRoot\lib\cfg.ps1" AZURE_RESOURCE_GROUP -Required
$Location = & "$PSScriptRoot\lib\cfg.ps1" AZURE_LOCATION -Required
$WorkspaceName = & "$PSScriptRoot\lib\cfg.ps1" AML_PROD_WORKSPACE -Required
$WorkspaceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.MachineLearningServices/workspaces/$WorkspaceName"
$ArmBase = 'https://management.azure.com'

# Match existing bootstrap PATH recovery without changing the caller's PATH.
$AzCmd = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
if (-not (Test-Path -LiteralPath $AzCmd -PathType Leaf)) {
    $AzCmd = (Get-Command az -CommandType Application -ErrorAction Stop).Source
}

function Invoke-AzRaw {
    param([Parameter(Mandatory = $true)] [string[]] $Arguments)

    $errorFile = [IO.Path]::GetTempFileName()
    $previousPreference = $ErrorActionPreference
    $previousDynamicInstall = [Environment]::GetEnvironmentVariable('AZURE_EXTENSION_USE_DYNAMIC_INSTALL', 'Process')
    $stdout = @()
    $stderr = ''
    $exitCode = $null
    try {
        # PS5.1 native stderr warnings must not terminate a successful command.
        $ErrorActionPreference = 'Continue'
        $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'no'
        # Native execution updates the global automatic variable. A local reset
        # masks that value in PS5.1 and falsely reports an empty exit code.
        $global:LASTEXITCODE = $null
        $stdout = & $AzCmd @Arguments 2> $errorFile
        $exitCode = $global:LASTEXITCODE
        $stderr = [IO.File]::ReadAllText($errorFile)
    }
    finally {
        $ErrorActionPreference = $previousPreference
        [Environment]::SetEnvironmentVariable('AZURE_EXTENSION_USE_DYNAMIC_INSTALL', $previousDynamicInstall, 'Process')
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
        # Retain stderr outside the repository for local inspection, not publication.
        # Never persist stdout: some Azure commands can return credentials there.
        $diagnosticPath = Join-Path ([IO.Path]::GetTempPath()) ("rti-m1a-error-" + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($diagnosticPath, $result.StdErr)
        Write-Host "Local stderr diagnostic: $diagnosticPath" -ForegroundColor Yellow
        Write-Host 'Inspect locally. Do not upload the whole file; share only the error message after checking for secrets.' -ForegroundColor Yellow
        # Print only known error codes, never arbitrary CLI error bodies or tokens.
        $knownCodes = @('InvalidAuthenticationTokenTenant', 'AuthorizationFailed',
            'AuthenticationFailed', 'ResourceGroupNotFound', 'RequestDisallowedByPolicy',
            'MissingSubscriptionRegistration', 'SubscriptionDisabled', 'AADSTS500011')
        $codes = @($knownCodes | Where-Object {
            $result.StdErr -match [regex]::Escape($_) -or $result.StdOut -match [regex]::Escape($_)
        })
        throw "$Operation failed (CLI exit '$($result.ExitCode)', known codes: $($codes -join ', ')). Stop; this is not proof of resource absence. Raw output suppressed to protect secrets. Check CLI login/tenant, scoped permissions and policy; do not grant broad roles."
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
    # PS5.1 enumerates an empty JSON array to null. Preserve a real [] as empty,
    # but reject null/scalars so malformed responses cannot imply absence.
    if ($text.TrimStart().StartsWith('[')) {
        return ,@($parsed | Where-Object { $null -ne $_ })
    }
    if ($null -eq $parsed -or -not $text.TrimStart().StartsWith('{')) {
        throw "$Operation returned neither a JSON object nor an array."
    }
    return $parsed
}

function Get-ArmResource {
    param([string] $ResourceId, [string] $ApiVersion, [string] $Operation)
    Invoke-AzJson -Arguments @('rest', '--method', 'get', '--url',
        "$ArmBase${ResourceId}?api-version=$ApiVersion", '--subscription', $SubscriptionId) -Operation $Operation
}

Write-Host '=== Track C / M1a - PROD workspace only ===' -ForegroundColor Cyan
Write-Host "Target: $WorkspaceId ($Location); VerifyOnly=$VerifyOnly"

$account = Invoke-AzJson -Arguments @('account', 'show') -Operation 'CLI account context'
if ($account.id -ne $SubscriptionId -or $account.tenantId -ne $TenantId -or
    $account.state -ne 'Enabled' -or $account.environmentName -ne 'AzureCloud') {
    throw 'CLI context must be the locked AzureCloud subscription and tenant, state Enabled. No account switch or resource write was performed.'
}
# ARM is current evidence of subscription state; account show may be cached.
$subscription = Get-ArmResource -ResourceId "/subscriptions/$SubscriptionId" -ApiVersion '2022-12-01' -Operation 'ARM subscription state'
if ($subscription.subscriptionId -ne $SubscriptionId -or $subscription.tenantId -ne $TenantId -or $subscription.state -ne 'Enabled') {
    throw 'ARM subscription context is incompatible or not Enabled; refusing provisioning.'
}
$extensions = Invoke-AzJson -Arguments @('extension', 'list') -Operation 'Installed CLI extensions'
if (-not ($extensions -is [array])) { throw 'Extension list response is not an array.' }
$mlExtensions = @($extensions | Where-Object { $_.name -eq 'ml' })
if ($mlExtensions.Count -ne 1) { throw 'The ml CLI extension must already be installed; no implicit installation is allowed.' }
Write-Host "ML extension version: $($mlExtensions[0].version)"

$group = Invoke-AzJson -Arguments @('group', 'show', '--name', $ResourceGroup,
    '--subscription', $SubscriptionId) -Operation 'Existing target resource group'
if ($group.id -ne "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" -or $group.location -ne $Location) {
    throw 'Existing target resource group ID/location does not match the approved target.'
}

$workspaces = Invoke-AzJson -Arguments @('ml', 'workspace', 'list', '--resource-group',
    $ResourceGroup, '--subscription', $SubscriptionId) -Operation 'Workspace existence list'
if (-not ($workspaces -is [array])) { throw 'Workspace list response is not an array.' }
$matches = @($workspaces | Where-Object { $_.name -eq $WorkspaceName })
if ($matches.Count -gt 1) { throw 'Workspace list returned multiple target matches; refusing any write.' }
if ($matches.Count -eq 0) {
    if ($VerifyOnly) { throw "$WorkspaceName is absent. VerifyOnly never creates resources." }
    Write-Host 'Workspace absent. Creating with identity datastores; backing resources may incur charges.' -ForegroundColor Yellow
    # SystemAssigned is the documented default workspace identity; verify it below.
    # Disable RG-wide assignments (the default is true) for least privilege.
    Invoke-AzChecked -Arguments @('ml', 'workspace', 'create', '--name', $WorkspaceName,
        '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId,
        '--location', $Location, '--system-datastores-auth-mode', 'identity',
        '--allow-roleassignment-on-rg', 'false', '--output', 'none', '--only-show-errors') -Operation 'PROD workspace creation' | Out-Null
    Write-Host "Workspace creation command completed at $([DateTime]::UtcNow.ToString('o'))."
} else {
    if ($matches[0].id -ne $WorkspaceId) { throw 'Workspace list ID differs from the locked target; refusing any write.' }
    Write-Host 'Workspace exists. Read-only validation; no update or repair.'
}

# CLI SDK serialization does not reliably expose provisioningState. Use the
# documented ARM envelope, including Identity (capitalized enum) auth mode.
$workspace = Get-ArmResource -ResourceId $WorkspaceId -ApiVersion '2025-06-01' -Operation 'ARM PROD workspace verification'
if ($workspace.id -ne $WorkspaceId -or $workspace.name -ne $WorkspaceName -or
    $workspace.location -ne $Location -or $workspace.type -ne 'Microsoft.MachineLearningServices/workspaces' -or
    ($workspace.kind -and $workspace.kind -ne 'Default')) {
    throw 'Workspace ID/name/type/kind/location is incompatible; no automatic modification is allowed.'
}
if ($workspace.properties.provisioningState -ne 'Succeeded') {
    throw 'Workspace provisioningState is not Succeeded. Inspect provisioning failure or rerun -VerifyOnly when complete; no repair attempted.'
}
if ($workspace.properties.systemDatastoresAuthMode -ne 'Identity') {
    throw 'Workspace properties.systemDatastoresAuthMode is missing or not Identity. Existing workspace will not be updated silently.'
}
if ($workspace.identity.type -ne 'SystemAssigned' -or
    [string]::IsNullOrWhiteSpace([string] $workspace.identity.principalId) -or
    $workspace.identity.tenantId -ne $TenantId) {
    throw 'Workspace requires SystemAssigned identity with principalId in the locked tenant; no identity changes attempted.'
}

$computes = Invoke-AzJson -Arguments @('ml', 'compute', 'list', '--resource-group', $ResourceGroup,
    '--workspace-name', $WorkspaceName, '--subscription', $SubscriptionId) -Operation 'PROD compute inventory'
if (-not ($computes -is [array])) { throw 'Compute list response is not an array.' }
if ($computes.Count -ne 0) { throw 'PROD has compute resources; M1a requires none. Nothing was deleted or changed.' }

$storageId = [string] $workspace.properties.storageAccount
$storagePattern = '^/subscriptions/' + [regex]::Escape($SubscriptionId) + '/resourceGroups/[^/]+/providers/Microsoft\.Storage/storageAccounts/[a-z0-9]{3,24}$'
if ($storageId -notmatch $storagePattern) { throw 'Workspace backing storage ARM ID is absent or outside the locked subscription. No storage check can be certified.' }
$storage = Get-ArmResource -ResourceId $storageId -ApiVersion '2023-05-01' -Operation 'Backing storage network inspection'
if ($storage.id -ne $storageId) { throw 'Backing storage response ID does not match the workspace reference.' }
Write-Host "Backing storage: $storageId"
if ($storage.properties.publicNetworkAccess -eq 'Disabled') {
    throw "Backing storage publicNetworkAccess is Disabled: $storageId. M1a blocked; inspect policy/exemption. No network update or role grant performed."
}
if ($storage.properties.publicNetworkAccess -ne 'Enabled') {
    throw 'Backing storage publicNetworkAccess is absent or not Enabled; M1a is not validated. No network update performed.'
}

$checkedAt = [DateTime]::UtcNow
Write-Host "`n--- M1a current-state evidence (copy to docs/PROGRESS.md) ---" -ForegroundColor Green
[pscustomobject]@{
    checkedUtc = $checkedAt.ToString('o')
    verifyOnly = [bool] $VerifyOnly
    subscriptionId = $SubscriptionId
    tenantId = $TenantId
    workspaceId = $workspace.id
    location = $workspace.location
    provisioningState = $workspace.properties.provisioningState
    identityType = $workspace.identity.type
    principalId = $workspace.identity.principalId
    systemDatastoresAuthMode = $workspace.properties.systemDatastoresAuthMode
    computeCount = $computes.Count
    storageId = $storageId
    storagePublicNetworkAccess = $storage.properties.publicNetworkAccess
    storageNetworkDefaultAction = $storage.properties.networkAcls.defaultAction
    keyVaultId = $workspace.properties.keyVault
    applicationInsightsId = $workspace.properties.applicationInsights
    containerRegistryId = $workspace.properties.containerRegistry
} | Format-List
Write-Host 'Current-state checks passed; this is NOT the delayed 30-minute M1a exit proof.' -ForegroundColor Yellow
Write-Host "If this is the initial check, rerun -VerifyOnly no earlier than $($checkedAt.AddMinutes(30).ToString('o'))."
Write-Host 'No sleep. Retain both outputs and verify Succeeded through Resource Graph before closing M1a.'
Write-Host 'No registry, endpoint or compute created. Data-plane access and RBAC are not tested.'
Write-Host 'After the session, pause Fabric capacity if active and run scripts/91_cost_guard.ps1.'