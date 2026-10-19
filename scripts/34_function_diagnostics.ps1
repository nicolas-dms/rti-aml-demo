<#
.SYNOPSIS
    Routes the Function App platform logs to Log Analytics, then restarts it.

.DESCRIPTION
    Written while debugging a host that refused to index any function.

    The app's own telemetry was useless for that: it flows through
    Application Insights, which the host can only reach once it has started.
    When the question IS "why does the host not start", that instrument
    measures nothing - and an empty AppTraces table looks exactly like a
    healthy silence.

    FunctionAppLogs is emitted by the platform, not by the app. It keeps
    reporting when the host is broken, which is precisely when we need it.
    Worth keeping after the bug is fixed.

    Idempotent: re-running replaces the diagnostic setting.
#>

[CmdletBinding()]
param(
    [string] $ResourceGroup = 'rg-rti-aml-demo',
    [string] $FunctionApp = 'func-rti-scorer-<SUFFIX>',
    [string] $Workspace = 'amlrtidelogalyti3a9a13a6',
    [string] $SubscriptionId = '<SUBSCRIPTION_ID>',
    [string] $SettingName = 'func-platform-logs'
)

$ErrorActionPreference = 'Continue'

function Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }

$siteId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$FunctionApp"
$workspaceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$Workspace"

# FunctionAppLogs only. AppServiceConsoleLogs would have carried the Python
# worker's stdout, which is where an import failure surfaces, but Flex
# Consumption rejects that category outright: "Category 'AppServiceConsoleLogs'
# is not supported". FunctionAppLogs still carries the host lifecycle and the
# indexing errors, which is what we are after.
$logs = @'
[{"category":"FunctionAppLogs","enabled":true}]
'@

Step "[1/3] Creating the diagnostic setting '$SettingName'"
az monitor diagnostic-settings create `
    --name $SettingName `
    --resource $siteId `
    --workspace $workspaceId `
    --logs $logs `
    --output none
if ($LASTEXITCODE -ne 0) {
    Write-Host "    failed - see the error above." -ForegroundColor Yellow
    exit 1
}
Write-Host "    created"

Step "[2/3] Restarting '$FunctionApp'"
az functionapp restart --name $FunctionApp --resource-group $ResourceGroup --output none
Write-Host "    restarted"

Step "[3/3] Forcing a trigger sync"
az rest --method post `
    --url "https://management.azure.com$siteId/syncfunctiontriggers?api-version=2022-03-01" `
    --output none
Write-Host "    synced"

Write-Host "`nLogs take 2 to 5 minutes to appear the first time." -ForegroundColor Yellow
Write-Host "Tell me when it has been a few minutes and I will read FunctionAppLogs." -ForegroundColor Yellow
