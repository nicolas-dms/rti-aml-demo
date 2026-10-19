<#
.SYNOPSIS
    Force one execution of the score_timer function, on demand.

.DESCRIPTION
    A timer trigger on Flex Consumption only runs when the platform decides to
    allocate an instance, which makes it a poor thing to debug against and a
    poor thing to rely on live on stage. The Functions admin API exposes every
    function - including non-HTTP ones - at

        POST https://<app>.azurewebsites.net/admin/functions/<name>

    with a JSON body {"input": "..."}. The host then invokes the function
    exactly as the trigger would, synchronously enough that a 202 proves the
    host was up and accepted the work.

    This gives us two things: a deterministic test harness while we are still
    proving the loop, and a "force a tick" button during the demo.

    The master key is read into a variable and never printed. It is passed in
    the x-functions-key header. Nothing is written to disk.

.NOTES
    Verification after running this: query scoring_results in the Eventhouse,
    and read AppTraces where OperationName == 'score_timer'.
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'rg-rti-aml-demo',
    [string] $FunctionApp   = 'func-rti-scorer-<SUFFIX>',
    [string] $FunctionName  = 'score_timer',
    [int]    $Repeat        = 1,
    [int]    $DelaySeconds  = 30
)

$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host "==> [1/3] Reading the master key for '$FunctionApp'" -ForegroundColor Cyan

# --output tsv keeps this to a single bare value. It is captured, never echoed.
$masterKey = & az functionapp keys list `
    --resource-group $ResourceGroup `
    --name $FunctionApp `
    --query 'masterKey' `
    --output tsv

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($masterKey)) {
    throw "Could not read the master key. Check that you are logged in and that the app exists."
}
Write-Host "    key retrieved (not displayed)"

$uri = "https://$FunctionApp.azurewebsites.net/admin/functions/$FunctionName"
Write-Host ''
Write-Host "==> [2/3] Waking the host" -ForegroundColor Cyan

# Hitting the admin API is itself enough to make the platform allocate an
# instance. Asking for the host status first separates "the host will not
# start" from "the function itself fails".
try {
    $status = Invoke-RestMethod `
        -Uri "https://$FunctionApp.azurewebsites.net/admin/host/status" `
        -Headers @{ 'x-functions-key' = $masterKey } `
        -Method Get
    Write-Host "    host state : $($status.state)"
    Write-Host "    host version: $($status.version)"
    if ($status.errors) {
        Write-Host "    host errors : $($status.errors -join '; ')" -ForegroundColor Red
    }
}
catch {
    Write-Host "    host status unavailable: $($_.Exception.Message)" -ForegroundColor DarkYellow
}

Write-Host ''
Write-Host "==> [3/3] Invoking '$FunctionName' $Repeat time(s)" -ForegroundColor Cyan

$body = @{ input = '' } | ConvertTo-Json -Compress

for ($i = 1; $i -le $Repeat; $i++) {
    try {
        $response = Invoke-WebRequest `
            -Uri $uri `
            -Method Post `
            -Headers @{ 'x-functions-key' = $masterKey } `
            -ContentType 'application/json' `
            -Body $body `
            -UseBasicParsing
        Write-Host ("    [{0}/{1}] accepted, HTTP {2}" -f $i, $Repeat, [int]$response.StatusCode)
    }
    catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        Write-Host ("    [{0}/{1}] FAILED, HTTP {2} - {3}" -f $i, $Repeat, $code, $_.Exception.Message) -ForegroundColor Red
    }

    if ($i -lt $Repeat) { Start-Sleep -Seconds $DelaySeconds }
}

$masterKey = $null

Write-Host ''
Write-Host "Done. A 202 means the host ACCEPTED the invocation, not that it succeeded." -ForegroundColor Yellow
Write-Host "The proof is in the data: scoring_results in the Eventhouse, and"          -ForegroundColor Yellow
Write-Host "AppTraces where OperationName == 'score_timer'."                            -ForegroundColor Yellow
Write-Host ''
