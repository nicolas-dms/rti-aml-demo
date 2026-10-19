<#
.SYNOPSIS
    Shifts traffic between the blue and green deployments of temp-forecast-ep.

.DESCRIPTION
    P7, the point of the whole demo: the Function never changes. It keeps
    calling the SAME scoring URI with the SAME token. Only the traffic split
    moves, and scoring_results shows deployment/model_version follow along.

    Typical sequence:
      41_aml_traffic.ps1 -Mirror 10        # green sees a copy, answers nobody
      41_aml_traffic.ps1 -Blue 70 -Green 30
      41_aml_traffic.ps1 -Blue 0  -Green 100

    Mirroring and splitting are two different mechanisms. Mirror duplicates a
    percentage of live requests to green and THROWS AWAY its answers - the
    caller only ever sees blue. It warms the container and proves green does
    not crash, without exposing anyone to it. A split actually routes callers.
    Mirror first, split second: that ordering is the safety argument.

.NOTES
    Traffic must total 100 across the deployments that serve. Azure ML rejects
    anything else. Mirror traffic is separate and is not part of that total.
#>
[CmdletBinding(DefaultParameterSetName = 'Split')]
param(
    [string] $ResourceGroup = 'rg-rti-aml-demo',
    [string] $Workspace = 'aml-rti-demo',
    [string] $EndpointName = 'temp-forecast-ep',

    [Parameter(ParameterSetName = 'Split')]
    [ValidateRange(0, 100)]
    [int] $Blue = 100,

    [Parameter(ParameterSetName = 'Split')]
    [ValidateRange(0, 100)]
    [int] $Green = 0,

    # Percentage of live traffic COPIED to green. Its responses are discarded.
    # 0 disables mirroring.
    [Parameter(ParameterSetName = 'Mirror')]
    [ValidateRange(0, 50)]
    [int] $Mirror,

    # M6: colour that receives the mirrored copy. Default green keeps track A as
    # it was. A deployment gets real traffic OR mirror traffic, never both, so
    # in a second promotion cycle (candidate = blue) the caller passes blue.
    [Parameter(ParameterSetName = 'Mirror')]
    [ValidateSet('blue', 'green')]
    [string] $MirrorTarget = 'green',

    [Parameter(ParameterSetName = 'Show')]
    [switch] $Show
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

    [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = ($stdout | Out-String)
        StdErr   = $stderr
    }
}

function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $result = Invoke-Az -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw ("az " + ($Arguments -join ' ') + " -> exit $($result.ExitCode)`n" + $result.StdErr)
    }
    return ($result.StdOut | ConvertFrom-Json)
}

$common = @('--resource-group', $ResourceGroup, '--workspace-name', $Workspace)

function Show-State {
    $endpoint = Invoke-AzJson -Arguments (@('ml', 'online-endpoint', 'show',
        '--name', $EndpointName) + $common + @('--output', 'json'))

    Write-Host ""
    Write-Host "endpoint : $($endpoint.name)"
    Write-Host "traffic  : $(($endpoint.traffic | ConvertTo-Json -Compress))"
    Write-Host "mirror   : $(($endpoint.mirror_traffic | ConvertTo-Json -Compress))"

    $deployments = Invoke-AzJson -Arguments (@('ml', 'online-deployment', 'list',
        '--endpoint-name', $EndpointName) + $common + @('--output', 'json'))
    foreach ($deployment in $deployments) {
        Write-Host ("  {0,-6} model={1}  state={2}" -f `
            $deployment.name, $deployment.model, $deployment.provisioning_state)
    }
    Write-Host ""
}

if ($Show) {
    Show-State
    return
}

if ($PSCmdlet.ParameterSetName -eq 'Mirror') {
    Write-Host "==> Mirroring $Mirror% of live traffic to '$MirrorTarget'" -ForegroundColor Cyan
    Write-Host "    Callers keep receiving the other colour's answers. $MirrorTarget's are discarded."
    # Disabling = '<colour>=0'. An empty string does NOT clear it (proved on the PROD
    # endpoint, 2026-10-14: the update returned success and mirror stayed at 10).
    $value = "$MirrorTarget=$Mirror"
    $result = Invoke-Az -Arguments (@('ml', 'online-endpoint', 'update',
        '--name', $EndpointName, '--mirror-traffic', $value) + $common + @('--output', 'none'))
    if ($result.ExitCode -ne 0) { throw $result.StdErr }

    # Verify instead of trusting the exit code.
    $after = Invoke-AzJson -Arguments (@('ml', 'online-endpoint', 'show',
        '--name', $EndpointName) + $common + @('--output', 'json'))
    $left = 0
    if ($after.mirror_traffic) {
        foreach ($p in $after.mirror_traffic.PSObject.Properties) { $left += [int]$p.Value }
    }
    if ($Mirror -eq 0 -and $left -gt 0) {
        throw "Mirror was not cleared on ${EndpointName}: $(($after.mirror_traffic | ConvertTo-Json -Compress))"
    }
}
else {
    $total = $Blue + $Green
    if ($total -ne 100) {
        throw "Blue + Green must equal 100, got $total. Azure ML rejects any other total."
    }

    Write-Host "==> Traffic split: blue=$Blue green=$Green" -ForegroundColor Cyan
    $result = Invoke-Az -Arguments (@('ml', 'online-endpoint', 'update',
        '--name', $EndpointName, '--traffic', "blue=$Blue green=$Green") + $common + @('--output', 'none'))
    if ($result.ExitCode -ne 0) { throw $result.StdErr }
}

Show-State

Write-Host "Watch it land (tile 3 of the dashboard, or):" -ForegroundColor Yellow
Write-Host "  scoring_results | where scored_at > ago(10m) | summarize count() by deployment, model_version"
Write-Host ""
Write-Host "The Function was not touched. Same URI, same token, same code." -ForegroundColor Green
