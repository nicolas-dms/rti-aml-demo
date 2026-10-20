<#
.SYNOPSIS
    Reactivates every node of the Eventstream - the REST equivalent of "Activate all".

.DESCRIPTION
    Pausing a Fabric capacity DEACTIVATES the Eventstream destinations, and resuming
    the capacity does NOT bring them back. The symptom is misleading: the source stays
    "Running" with a live preview, so the Eventstream looks healthy, while the Kusto
    table silently stops growing. Events sent meanwhile are LOST - nothing is queued.

    Run this after every "az fabric capacity resume", BEFORE starting the simulator.

    The endpoint is undocumented on Learn; it was found by probing. Two things are
    counter-intuitive and worth keeping in mind:
      - the body is FLAT: {"startType":"Now"}. The error message names the parameter
        "startRequest", but that is the name of the BODY PARAMETER, not a JSON key -
        wrapping it produces "Required property 'startType' not found in JSON".
      - the per-node paths (/topology/destinations/{id}/resume, /topology/nodes/{name}/resume)
        do NOT exist and answer EntityNotFound. Only the item-level resume works.

    startType semantics:
      Now              - resume from the current time. Default here: after a multi-day
                         pause there is nothing worth replaying, and this is the option
                         that cannot surprise you with a flood of stale events.
      LastStoppedTime  - resume where streaming stopped.

.NOTES
    ASCII only (Windows PowerShell 5.1 reads .ps1 as ANSI).
    An empty response is the success case: the API answers 202 with no body.
#>
[CmdletBinding()]
param(
    [string] $WorkspaceName   = (& "$PSScriptRoot\lib\cfg.ps1" FABRIC_WORKSPACE -Required),
    [string] $EventstreamName = (& "$PSScriptRoot\lib\cfg.ps1" EVENTSTREAM -Default 'es-sensors'),
    [ValidateSet('Now', 'LastStoppedTime')]
    [string] $StartType = 'Now',
    # Seconds to wait for the nodes to leave the "Resuming" state.
    [int] $TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

$FabricApi      = 'https://api.fabric.microsoft.com/v1'
$FabricResource = 'https://api.fabric.microsoft.com'

# az writes to stderr on plain warnings; with $ErrorActionPreference='Stop' that
# becomes a terminating NativeCommandError, and 2>$null does not prevent it.
function Invoke-Az {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $errorFile = [System.IO.Path]::GetTempFileName()
    $previous  = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $stdout   = & az @Arguments 2> $errorFile
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

function Get-Fabric {
    param([Parameter(Mandatory)] [string] $Path)

    $result = Invoke-Az -Arguments @('rest', '--method', 'get',
        '--url', "$FabricApi/$($Path.TrimStart('/'))",
        '--resource', $FabricResource, '--output', 'json')
    if ($result.ExitCode -ne 0) { throw "GET $Path -> exit $($result.ExitCode)`n$($result.StdErr)" }
    return ($result.StdOut | ConvertFrom-Json)
}

Write-Host "=== Eventstream resume (Activate all) ===" -ForegroundColor Cyan

# --- [1/3] resolve ids ------------------------------------------------------
$workspace = (Get-Fabric 'workspaces').value |
    Where-Object { $_.displayName -eq $WorkspaceName } | Select-Object -First 1
if (-not $workspace) { throw "Workspace '$WorkspaceName' not found." }

$eventstream = (Get-Fabric "workspaces/$($workspace.id)/eventstreams").value |
    Where-Object { $_.displayName -eq $EventstreamName } | Select-Object -First 1
if (-not $eventstream) { throw "Eventstream '$EventstreamName' not found in '$WorkspaceName'." }

$itemPath = "workspaces/$($workspace.id)/eventstreams/$($eventstream.id)"
Write-Host "  workspace   : $($workspace.id)"
Write-Host "  eventstream : $($eventstream.id)"

# --- [2/3] state before -----------------------------------------------------
function Show-Topology {
    param([Parameter(Mandatory)] $Topology)

    $nodes = @()
    foreach ($group in 'sources', 'streams', 'destinations') {
        foreach ($node in $Topology.$group) {
            $nodes += [pscustomobject]@{ kind = $group; name = $node.name; status = $node.status }
        }
    }
    $nodes | Format-Table -AutoSize | Out-String | Write-Host
    return $nodes
}

Write-Host "`n[1/3] Current topology" -ForegroundColor Cyan
$before = Show-Topology (Get-Fabric "$itemPath/topology")

if (-not ($before | Where-Object { $_.status -ne 'Running' })) {
    Write-Host "Every node is already Running - nothing to do." -ForegroundColor Green
    return
}

# --- [3/3] resume -----------------------------------------------------------
Write-Host "[2/3] POST $itemPath/resume  (startType=$StartType)" -ForegroundColor Cyan

# --body @file rather than an inline string: PowerShell 5.1 mangles nested quotes
# when passing JSON to a native command. ASCII, no BOM - a BOM breaks the parser.
$bodyFile = [System.IO.Path]::GetTempFileName()
try {
    "{`"startType`":`"$StartType`"}" | Out-File -FilePath $bodyFile -Encoding ascii -NoNewline

    $resume = Invoke-Az -Arguments @('rest', '--method', 'post',
        '--url', "$FabricApi/$itemPath/resume",
        '--resource', $FabricResource,
        '--headers', 'Content-Type=application/json',
        '--body', "@$bodyFile",
        '--output', 'json')

    if ($resume.ExitCode -ne 0) {
        Write-Host $resume.StdErr -ForegroundColor Red
        throw "Resume rejected."
    }
}
finally { Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue }

Write-Host "  accepted (empty response = 202)"

# The call is asynchronous: nodes go through "Resuming" first. Returning here would
# report success on a stream that is not yet forwarding anything.
Write-Host "`n[3/3] Waiting for the nodes to settle ..." -ForegroundColor Cyan
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Seconds 5
    $topology = Get-Fabric "$itemPath/topology"
    $pending = @()
    foreach ($group in 'sources', 'streams', 'destinations') {
        $pending += $topology.$group | Where-Object { $_.status -notin @('Running', 'Active') }
    }
    Write-Host "  pending: $($pending.Count)"
} while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline)

$after = Show-Topology $topology

if ($pending.Count -gt 0) {
    Write-Host "Still not settled after $TimeoutSeconds s. Check the Eventstream in the portal." -ForegroundColor Yellow
}
else {
    Write-Host "All nodes Running." -ForegroundColor Green
    Write-Host "Next: start the simulator, then confirm ingestion with" -ForegroundColor Yellow
    Write-Host "  telemetry | summarize newest = max(timestamp), ingest_lag = now() - max(ingestion_time())"
}
