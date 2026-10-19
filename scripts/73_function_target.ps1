<#
.SYNOPSIS
    M6 - Points the scoring Function at the DEV endpoint or at the PROD endpoint.

.DESCRIPTION
    Track C, R-61. This is the ONLY supported way to retarget the Function. It is
    a real traffic switch (the Function feeds scoring_results and the dashboard),
    so it asks for confirmation before changing anything.

    What it does:
      1. reads the target endpoint (scoring URI, traffic) and refuses a target
         that serves nothing (traffic total != 100);
      2. makes sure the Function managed identity holds 'AzureML Data Scientist'
         on the target workspace (idempotent; RBAC can take a few minutes);
      3. asks for confirmation (skip with -Yes only in a rehearsal);
      4. updates AML_SCORING_URI, AML_WORKSPACE, AML_ENDPOINT_NAME and
         DEPLOYMENT_CACHE_TTL_SEC (600 for dev = track A behaviour, 60 for prod);
      5. verifies in scoring_results that NEW rows (by ingestion time) carry a
         model_version that really sits behind the target endpoint.

    Idempotent: running it again with the current target changes nothing but
    still verifies.

    -Show prints the current target and changes nothing.

    ASCII only - Windows PowerShell 5.1 reads .ps1 as ANSI.
#>
[CmdletBinding()]
param(
    [ValidateSet('dev', 'prod')]
    [string] $Target,
    [switch] $Show,
    [switch] $Yes,
    [switch] $SkipVerify,
    [int]    $VerifyWaitMin = 8,
    [string] $ResourceGroup = 'rg-rti-aml-demo',
    [string] $FunctionApp = 'func-rti-scorer-<SUFFIX>',
    [string] $SubscriptionId = '<SUBSCRIPTION_ID>',
    [string] $ClusterUri = 'https://<EVENTHOUSE_HOST>.z7.kusto.fabric.microsoft.com',
    [string] $Database = 'sensors'
)

$ErrorActionPreference = 'Stop'

$targets = @{
    dev  = @{ Workspace = 'aml-rti-demo'; Endpoint = 'temp-forecast-ep'; Ttl = '600' }
    prod = @{ Workspace = 'aml-rti-prod'; Endpoint = 'temp-forecast-prod-ep'; Ttl = '60' }
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
    $result = Invoke-Az -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw ("az " + ($Arguments -join ' ') + " -> exit $($result.ExitCode)`n" + $result.StdErr)
    }
    return ($result.StdOut | ConvertFrom-Json)
}

function Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }

function Get-AppSettings {
    $all = Invoke-AzJson @('functionapp', 'config', 'appsettings', 'list',
        '--name', $FunctionApp, '--resource-group', $ResourceGroup, '--output', 'json')
    $map = @{}
    foreach ($item in $all) { $map[$item.name] = $item.value }
    return $map
}

# --- Show -------------------------------------------------------------------
$current = Get-AppSettings
if ($Show -or -not $Target) {
    Write-Host "Function $FunctionApp currently targets:"
    Write-Host "  AML_WORKSPACE             = $($current['AML_WORKSPACE'])"
    Write-Host "  AML_ENDPOINT_NAME         = $($current['AML_ENDPOINT_NAME'])"
    Write-Host "  AML_SCORING_URI           = $($current['AML_SCORING_URI'])"
    Write-Host "  DEPLOYMENT_CACHE_TTL_SEC  = $($current['DEPLOYMENT_CACHE_TTL_SEC'])"
    if (-not $Target) { Write-Host "`nPass -Target dev|prod to change it." }
    return
}

$workspace = $targets[$Target].Workspace
$endpointName = $targets[$Target].Endpoint
$ttl = $targets[$Target].Ttl
$common = @('--resource-group', $ResourceGroup, '--workspace-name', $workspace)

# --- [1/5] the target must exist and serve ----------------------------------
Step "[1/5] Reading $endpointName in $workspace"
$endpoint = Invoke-AzJson (@('ml', 'online-endpoint', 'show', '--name', $endpointName) + $common + @('--output', 'json'))
$scoringUri = $endpoint.scoring_uri
if (-not $scoringUri) { throw "Endpoint $endpointName has no scoring_uri." }

$total = 0
foreach ($property in $endpoint.traffic.PSObject.Properties) { $total += [int]$property.Value }
Write-Host "  scoring uri : $scoringUri"
Write-Host "  traffic     : $($endpoint.traffic | ConvertTo-Json -Compress)  (total $total)"
if ($total -ne 100) {
    throw "Refusing to target ${endpointName}: its traffic totals $total, nothing (or not everything) would answer the Function."
}

$deployments = Invoke-AzJson (@('ml', 'online-deployment', 'list', '--endpoint-name', $endpointName) + $common + @('--output', 'json'))
$versionsBehind = @()
foreach ($deployment in $deployments) {
    if ($deployment.provisioning_state -ne 'Succeeded') { continue }
    if ([string]$deployment.model -match '/models/([^/]+)/versions/([^/?]+)$') { $versionsBehind += $Matches[2] }
    elseif ([string]$deployment.model -match ':([^:]+)$') { $versionsBehind += $Matches[1] }
}
Write-Host "  model versions behind it: $($versionsBehind -join ', ')"

# --- [2/5] Function identity -> role on the target workspace -----------------
Step "[2/5] 'AzureML Data Scientist' for the Function identity on $workspace"
$principalId = (Invoke-AzJson @('functionapp', 'identity', 'show', '--name', $FunctionApp,
        '--resource-group', $ResourceGroup, '--output', 'json')).principalId
if (-not $principalId) { throw "No system-assigned identity on $FunctionApp." }
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.MachineLearningServices/workspaces/$workspace"
$hasRole = Invoke-AzJson @('role', 'assignment', 'list', '--assignee', $principalId, '--scope', $scope,
    '--role', 'AzureML Data Scientist', '--output', 'json')
$roleMissing = ($hasRole.Count -eq 0)
if ($roleMissing) { Write-Host "  missing, will be created after confirmation" } else { Write-Host "  already assigned" }

# --- [3/5] confirmation ------------------------------------------------------
$alreadyThere = ($current['AML_WORKSPACE'] -eq $workspace -and $current['AML_ENDPOINT_NAME'] -eq $endpointName -and
    $current['AML_SCORING_URI'] -eq $scoringUri -and $current['DEPLOYMENT_CACHE_TTL_SEC'] -eq $ttl)
Step "[3/5] Confirmation"
if ($alreadyThere -and -not $roleMissing) {
    Write-Host "  the Function already targets $Target, nothing to change"
}
else {
    Write-Host "  The Function $FunctionApp will score against: $endpointName ($workspace)"
    Write-Host "  Real traffic: scoring_results and the dashboard will follow."
    if (-not $Yes) {
        $answer = Read-Host "  Type the target name ($Target) to confirm"
        if ($answer -ne $Target) { throw "Not confirmed, nothing changed." }
    }

    if ($roleMissing) {
        $created = Invoke-Az @('role', 'assignment', 'create', '--assignee-object-id', $principalId,
            '--assignee-principal-type', 'ServicePrincipal', '--role', 'AzureML Data Scientist',
            '--scope', $scope, '--output', 'none')
        if ($created.ExitCode -ne 0) { throw $created.StdErr }
        Write-Host "  role created (propagation can take up to 10 minutes)" -ForegroundColor Yellow
    }

    # --- [4/5] app settings --------------------------------------------------
    Step "[4/5] App settings"
    $settings = @(
        "AML_SCORING_URI=$scoringUri",
        "AML_WORKSPACE=$workspace",
        "AML_ENDPOINT_NAME=$endpointName",
        "DEPLOYMENT_CACHE_TTL_SEC=$ttl"
    )
    Invoke-AzJson (@('functionapp', 'config', 'appsettings', 'set', '--name', $FunctionApp,
            '--resource-group', $ResourceGroup, '--settings') + $settings + @('--output', 'none')) | Out-Null
    Write-Host "  applied: workspace=$workspace endpoint=$endpointName ttl=$ttl"
}
$switchedAt = (Get-Date).ToUniversalTime()

if ($SkipVerify) {
    Write-Host "`nVerification skipped (-SkipVerify). Check scoring_results yourself." -ForegroundColor Yellow
    return
}

# --- [5/5] verify in scoring_results -----------------------------------------
Step "[5/5] Verifying in scoring_results (up to $VerifyWaitMin min)"
$metadata = Invoke-RestMethod -Method Get -UseBasicParsing -Uri "$($ClusterUri.TrimEnd('/'))/v1/rest/auth/metadata"
$resource = $metadata.AzureAD.KustoServiceResourceId
if (-not $resource) { throw "Cannot discover the Kusto token audience of $ClusterUri." }
$token = (Invoke-Az @('account', 'get-access-token', '--resource', $resource, '--query', 'accessToken', '--output', 'tsv')).StdOut.Trim()
$since = if ($alreadyThere) { (Get-Date).ToUniversalTime().AddMinutes(-10) } else { $switchedAt }
$sinceText = $since.ToString('yyyy-MM-ddTHH:mm:ssZ')
$query = "scoring_results | where ingestion_time() > datetime($sinceText) | summarize rows=count(), last=max(ingestion_time()) by deployment, model_version"
$body = @{ db = $Database; csl = $query } | ConvertTo-Json -Compress

$deadline = (Get-Date).AddMinutes($VerifyWaitMin)
$matched = $false
while ($true) {
    $rows = @()
    try {
        $response = Invoke-RestMethod -Method Post -Uri "$($ClusterUri.TrimEnd('/'))/v1/rest/query" `
            -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body $body
        $rows = @($response.Tables[0].Rows)
    }
    catch { Write-Host "  query error: $($_.Exception.Message)" -ForegroundColor DarkYellow }

    if ($rows.Count -gt 0) {
        foreach ($row in $rows) { Write-Host ("  deployment={0} model_version={1} rows={2}" -f $row[0], $row[1], $row[2]) }
        $seen = $rows | ForEach-Object { [string]$_[1] }
        $matched = [bool](@($seen | Where-Object { $versionsBehind -contains $_ }).Count)
        if ($matched) { break }
    }
    if ((Get-Date) -gt $deadline) { break }
    Start-Sleep -Seconds 30
}
Remove-Variable token

if ($matched) {
    Write-Host "`nOK: new rows since $sinceText carry a model version served by $endpointName." -ForegroundColor Green
}
else {
    Write-Host "`nNOT CONFIRMED: no new row since $sinceText with a model version in [$($versionsBehind -join ', ')]." -ForegroundColor Red
    Write-Host "Likely causes: RBAC propagation (403 in the Function logs), simulator stopped, Eventstream not Running."
    Write-Host "Check 34_function_diagnostics.ps1 before changing anything."
    exit 1
}
