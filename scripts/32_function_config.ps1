<#
.SYNOPSIS
    P6 - Grants and app settings for the scoring Function. No keys, anywhere.

.DESCRIPTION
    Four grants and two configuration blocks:

      1. AML data plane. The Function calls the scoring URI with a Microsoft
         Entra token whose audience is https://ml.azure.com. That requires the
         RBAC action .../onlineEndpoints/score/action, carried by the built-in
         role "AzureML Data Scientist".

      2. AML control plane, same role. The Function reads back which MODEL
         VERSION sits behind the deployment that answered, so the demo cannot
         drift out of sync with a hardcoded "blue = v1" app setting.

      3. Host storage. The tenant forbids shared-key access on every storage
         account, so both AzureWebJobsStorage and the deployment container must
         authenticate with the managed identity. Without this the app cannot
         even be published: Kudu fails with "Key based authentication is not
         permitted on this storage account".

      4. Eventhouse. Database Viewer to call features_now(), Database Ingestor
         to write scoring_results. Kusto permissions are not Azure RBAC: they
         are KQL control commands, and they identify a managed identity by its
         APPLICATION id, not its principal (object) id. Getting that wrong is a
         silent 403 at the first ingestion.

    Idempotent. Re-runnable as many times as needed.

.NOTES
    Run scripts/30_aml_endpoint.ps1 first: the scoring URI is read from the
    endpoint, not typed in by hand.

    ASCII only - Windows PowerShell 5.1 reads .ps1 as ANSI.
#>

[CmdletBinding()]
param(
    [string] $ResourceGroup   = (& "$PSScriptRoot\lib\cfg.ps1" AZURE_RESOURCE_GROUP -Required),
    [string] $Workspace       = (& "$PSScriptRoot\lib\cfg.ps1" AML_DEV_WORKSPACE -Required),
    [string] $EndpointName    = (& "$PSScriptRoot\lib\cfg.ps1" ENDPOINT_DEV -Default 'temp-forecast-ep'),
    [string] $FunctionApp     = (& "$PSScriptRoot\lib\cfg.ps1" FUNCTION_APP -Required),
    [string] $SubscriptionId  = (& "$PSScriptRoot\lib\cfg.ps1" AZURE_SUBSCRIPTION_ID -Required),
    [string] $TenantId        = (& "$PSScriptRoot\lib\cfg.ps1" AZURE_TENANT_ID -Required),
    [string] $ClusterUri      = (& "$PSScriptRoot\lib\cfg.ps1" KUSTO_QUERY_URI -Required),
    [string] $Database        = (& "$PSScriptRoot\lib\cfg.ps1" KQL_DATABASE -Default 'sensors'),
    [int]    $HorizonMinutes  = 15,
    [int]    $MaxStalenessSec = 180,
    [switch] $SkipKustoGrants
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

    [pscustomobject]@{ ExitCode = $exitCode; StdOut = ($stdout | Out-String); StdErr = $stderr }
}

function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $result = Invoke-Az -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw ("az " + ($Arguments -join ' ') + " -> exit $($result.ExitCode)`n" + $result.StdErr)
    }
    return ($result.StdOut | ConvertFrom-Json)
}

function Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }

function Grant-Role {
    <#
        Assigns a built-in role, tolerating the two usual annoyances:
        an assignment that already exists, and Entra replication lag, which
        makes the RBAC service answer PrincipalNotFound for an identity that
        demonstrably exists.
    #>
    param(
        [Parameter(Mandatory)] [string] $PrincipalId,
        [Parameter(Mandatory)] [string] $Role,
        [Parameter(Mandatory)] [string] $Scope
    )

    $existing = Invoke-AzJson @(
        'role', 'assignment', 'list',
        '--assignee', $PrincipalId, '--scope', $Scope, '--role', $Role, '--output', 'json'
    )
    if ($existing.Count -gt 0) {
        Write-Host "    '$Role' already assigned"
        return
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $result = Invoke-Az @(
            'role', 'assignment', 'create',
            '--assignee-object-id', $PrincipalId,
            '--assignee-principal-type', 'ServicePrincipal',
            '--role', $Role, '--scope', $Scope, '--output', 'none'
        )
        if ($result.ExitCode -eq 0) { Write-Host "    '$Role' created"; return }
        if ($result.StdErr -notmatch 'PrincipalNotFound') { throw $result.StdErr }
        Write-Host "    PrincipalNotFound, retry $attempt/5 in 15s" -ForegroundColor DarkYellow
        Start-Sleep -Seconds 15
    }
    throw "Could not assign '$Role' on $Scope after 5 attempts."
}

# ---------------------------------------------------------------------------
# [1/5] Scoring URI - read from the endpoint, never typed
# ---------------------------------------------------------------------------
Step "[1/7] Reading the scoring URI of '$EndpointName'"
$endpoint = Invoke-AzJson @(
    'ml', 'online-endpoint', 'show',
    '--name', $EndpointName,
    '--resource-group', $ResourceGroup,
    '--workspace-name', $Workspace,
    '--output', 'json'
)
$scoringUri = $endpoint.scoring_uri
if (-not $scoringUri) { throw "The endpoint has no scoring_uri yet. Is the deployment finished?" }
Write-Host "    $scoringUri"

# ---------------------------------------------------------------------------
# [2/5] Identity of the Function
# ---------------------------------------------------------------------------
Step "[2/7] Resolving the managed identity of '$FunctionApp'"
$identity = Invoke-AzJson @(
    'functionapp', 'identity', 'show',
    '--name', $FunctionApp, '--resource-group', $ResourceGroup, '--output', 'json'
)
$principalId = $identity.principalId
if (-not $principalId) {
    throw "No system-assigned identity on $FunctionApp. Run: az functionapp identity assign --name $FunctionApp --resource-group $ResourceGroup"
}

# Azure RBAC uses the principal (object) id; Kusto uses the application id.
# They are two different GUIDs for the same identity - a classic confusion.
$appId = (Invoke-AzJson @('ad', 'sp', 'show', '--id', $principalId, '--output', 'json')).appId
Write-Host "    principalId (Azure RBAC) = $principalId"
Write-Host "    appId       (Kusto)      = $appId"

# ---------------------------------------------------------------------------
# [3/7] Azure RBAC on the AML workspace
# ---------------------------------------------------------------------------
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.MachineLearningServices/workspaces/$Workspace"

Step "[3/7] Granting 'AzureML Data Scientist' on the workspace"
Grant-Role -PrincipalId $principalId -Role 'AzureML Data Scientist' -Scope $scope

# ---------------------------------------------------------------------------
# [4/7] Host storage without keys
# ---------------------------------------------------------------------------
# The tenant policy sets allowSharedKeyAccess=false on every storage account,
# which breaks BOTH halves of the Flex Consumption storage story:
#
#   - the deployment container, where Kudu uploads the zip. Failing here is
#     loud: "Key based authentication is not permitted on this storage account".
#   - AzureWebJobsStorage, which the host needs to start at all. Failing here
#     is quiet: the app publishes fine and then never runs. Our trigger is a
#     timer, and timers take their single-execution locks on blobs through
#     this very connection.
#
# Fixing only the first one produces a successful deployment that never
# executes - a worse outcome than the failure we started from.
Step "[4/7] Reading the deployment storage configuration"
$site = Invoke-AzJson @(
    'functionapp', 'show',
    '--name', $FunctionApp, '--resource-group', $ResourceGroup, '--output', 'json'
)
# Note the 'properties' hop: az functionapp show flattens most of the site
# object, but not functionAppConfig, so the obvious path silently yields null.
$deployment = $site.properties.functionAppConfig.deployment.storage
if (-not $deployment -or -not $deployment.value) {
    throw "No deployment storage on $FunctionApp. Is it really a Flex Consumption app?"
}
# value looks like https://<account>.blob.core.windows.net/<container>
$deploymentUri = [uri] $deployment.value
$storageAccount = $deploymentUri.Host.Split('.')[0]
$deploymentContainer = $deploymentUri.AbsolutePath.Trim('/')
Write-Host "    account   = $storageAccount"
Write-Host "    container = $deploymentContainer"
Write-Host "    auth      = $($deployment.authentication.type)"

$storageScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccount"

# Storage Blob Data Owner is the documented minimum for AzureWebJobsStorage and
# also covers the Blob Data Contributor the deployment container requires.
# Storage Table Data Contributor is what lets the host persist its diagnostic
# events - that is, the logs you need precisely when the app fails to start.
Grant-Role -PrincipalId $principalId -Role 'Storage Blob Data Owner' -Scope $storageScope
Grant-Role -PrincipalId $principalId -Role 'Storage Table Data Contributor' -Scope $storageScope

# ---------------------------------------------------------------------------
# [5/7] Kusto principals on the Eventhouse database
# ---------------------------------------------------------------------------
if ($SkipKustoGrants) {
    Step "[5/7] Kusto grants skipped (-SkipKustoGrants)"
}
else {
    Step "[5/7] Granting Database Viewer + Ingestor on '$Database'"
    $principal = "aadapp=$appId;$TenantId"
    $kql = @(
        "// Generated by scripts/32_function_config.ps1 - do not edit by hand.",
        "// Viewer: call features_now(). Ingestor: write scoring_results.",
        "// A managed identity is declared by its APPLICATION id, not its object id.",
        ".add database ['$Database'] viewers ('$principal') '$FunctionApp managed identity'",
        "",
        ".add database ['$Database'] ingestors ('$principal') '$FunctionApp managed identity'",
        ""
    ) -join "`r`n"

    $generated = Join-Path (Get-Location) 'fabric/kql/05_function_permissions.generated.kql'
    Set-Content -Path $generated -Value $kql -Encoding ASCII
    Write-Host "    wrote $generated"

    & (Join-Path $PSScriptRoot '11_apply_kql.ps1') -ClusterUri $ClusterUri -Database $Database -Files $generated
}

# ---------------------------------------------------------------------------
# [6/7] App settings
# ---------------------------------------------------------------------------
Step "[6/7] Writing the app settings of '$FunctionApp'"
$ingestUri = $ClusterUri -replace '^https://', 'https://ingest-'
$settings = @(
    "KUSTO_CLUSTER_URI=$ClusterUri",
    "KUSTO_INGEST_URI=$ingestUri",
    "KUSTO_DATABASE=$Database",
    "AML_SCORING_URI=$scoringUri",
    "AML_SUBSCRIPTION_ID=$SubscriptionId",
    "AML_RESOURCE_GROUP=$ResourceGroup",
    "AML_WORKSPACE=$Workspace",
    "AML_ENDPOINT_NAME=$EndpointName",
    "HORIZON_MIN=$HorizonMinutes",
    "MAX_STALENESS_SEC=$MaxStalenessSec",
    # A double underscore is read as a colon, so these four are interpreted by
    # the host as properties of a single AzureWebJobsStorage object.
    "AzureWebJobsStorage__blobServiceUri=https://$storageAccount.blob.core.windows.net",
    "AzureWebJobsStorage__queueServiceUri=https://$storageAccount.queue.core.windows.net",
    "AzureWebJobsStorage__tableServiceUri=https://$storageAccount.table.core.windows.net",
    "AzureWebJobsStorage__credential=managedidentity"
)
Invoke-AzJson (@(
    'functionapp', 'config', 'appsettings', 'set',
    '--name', $FunctionApp, '--resource-group', $ResourceGroup,
    '--settings') + $settings + @('--output', 'json')) | Out-Null
Write-Host "    $($settings.Count) settings applied"

# ---------------------------------------------------------------------------
# [7/7] Deployment storage on the managed identity
# ---------------------------------------------------------------------------
Step "[7/7] Switching deployment storage to the system-assigned identity"
if ($deployment.authentication.type -eq 'SystemAssignedIdentity') {
    Write-Host "    already using the managed identity"
}
else {
    Invoke-AzJson @(
        'functionapp', 'deployment', 'config', 'set',
        '--name', $FunctionApp, '--resource-group', $ResourceGroup,
        '--deployment-storage-name', $storageAccount,
        '--deployment-storage-container-name', $deploymentContainer,
        '--deployment-storage-auth-type', 'SystemAssignedIdentity',
        '--output', 'json'
    ) | Out-Null
    Write-Host "    switched"
}

# Only now that nothing points at them any more: drop the key-bearing settings.
# Order matters. Deleting these first would leave the app with no way to reach
# its own storage between the two commands.
$obsolete = @('AzureWebJobsStorage', 'DEPLOYMENT_STORAGE_CONNECTION_STRING')
$current = (Invoke-AzJson @(
    'functionapp', 'config', 'appsettings', 'list',
    '--name', $FunctionApp, '--resource-group', $ResourceGroup, '--output', 'json'
)) | ForEach-Object { $_.name }
$toDelete = $obsolete | Where-Object { $current -contains $_ }
if ($toDelete) {
    Invoke-AzJson (@(
        'functionapp', 'config', 'appsettings', 'delete',
        '--name', $FunctionApp, '--resource-group', $ResourceGroup,
        '--setting-names') + $toDelete + @('--output', 'json')) | Out-Null
    Write-Host "    removed the key-bearing settings: $($toDelete -join ', ')"
}
else {
    Write-Host "    no key-bearing settings left"
}

Write-Host "`n==================== SUMMARY ====================" -ForegroundColor Green
[pscustomobject]@{
    functionApp    = $FunctionApp
    principalId    = $principalId
    appId          = $appId
    scoringUri     = $scoringUri
    ingestUri      = $ingestUri
    storageAccount = $storageAccount
} | Format-List

Write-Host "RBAC changes can take up to 10 minutes to propagate." -ForegroundColor Yellow
Write-Host "If the next step fails on a 403, wait and retry before changing anything." -ForegroundColor Yellow
Write-Host "Next: deploy the code with scripts/33_function_deploy.ps1" -ForegroundColor Yellow
