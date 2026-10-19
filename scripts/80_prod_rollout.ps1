<#
.SYNOPSIS
    M6 - One stage of the progressive PROD rollout of a registry model.

.DESCRIPTION
    Called by devops/pipelines/publish.yml (rti-publish), one stage per call, and
    runnable on a laptop with the same arguments. It owns the colour logic so the
    YAML stays thin; every endpoint creation goes through 30_aml_endpoint.ps1 and
    every traffic change through 41_aml_traffic.ps1 (R-53).

    Stages (each idempotent, replayable):
      state            prints the endpoint, the current/candidate colours, changes nothing
      share            DEV workspace -> registry (skipped if the version is already there)
      deploy_candidate candidate colour at 0 percent from the registry model + direct smoke test
      mirror           mirror -MirrorPercent to the candidate, observe -ObserveMinutes
      canary           cut the mirror, then current=100-C / candidate=C
      promote          candidate=100, current=0
      retire           delete the old colour, ONLY at 0 percent traffic
      rollback         current=100, candidate=0, mirror off, nothing deleted

    Colours are never hard-coded. The candidate is the colour that already runs
    -ModelVersion, else the opposite of the colour serving the traffic. Two
    successive promotions (green, then blue) therefore both work unchanged.

    Required starting state of deploy_candidate (R-51): exactly one colour at 100
    percent, empty mirror, the other colour at 0 percent. Otherwise it stops and
    says what to do.

    ASCII only - Windows PowerShell 5.1 reads .ps1 as ANSI.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('state', 'share', 'deploy_candidate', 'mirror', 'canary', 'promote', 'retire', 'rollback')]
    [string] $Stage,
    [Parameter(Mandatory)] [int] $ModelVersion,
    [ValidateRange(1, 50)]  [int] $MirrorPercent = 10,
    [ValidateRange(1, 50)]  [int] $CanaryPercent = 10,
    [ValidateRange(0, 120)] [int] $ObserveMinutes = 5,
    [string] $ResourceGroup = 'rg-rti-aml-demo',
    [string] $Workspace = 'aml-rti-prod',
    [string] $Endpoint = 'temp-forecast-prod-ep',
    [string] $DevWorkspace = 'aml-rti-demo',
    [string] $Registry = 'mlr-rti-demo',
    [string] $ModelName = 'temp_forecaster'
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

$common = @('--resource-group', $ResourceGroup, '--workspace-name', $Workspace)
$modelUri = "azureml://registries/$Registry/models/$ModelName/versions/$ModelVersion"
$colours = @('blue', 'green')
function Other { param([string] $Colour) if ($Colour -eq 'blue') { 'green' } else { 'blue' } }

function Get-Split {
    param($Object)
    $map = @{}
    # Zero weights (e.g. mirror 'green=0' after a cut) are the same as absent.
    if ($Object) { foreach ($p in $Object.PSObject.Properties) { if ([int]$p.Value -gt 0) { $map[$p.Name] = [int]$p.Value } } }
    return $map
}

function Get-State {
    $probe = Invoke-Az (@('ml', 'online-endpoint', 'show', '--name', $Endpoint) + $common + @('--output', 'json'))
    if ($probe.ExitCode -ne 0) {
        if ($probe.StdErr -match 'ResourceNotFound') {
            throw "Endpoint ${Endpoint} does not exist in ${Workspace}. Nothing was deployed. Create it first with scripts/81_prod_endpoint_bootstrap.ps1 (D-1 only, billed 24/7)."
        }
        throw ("az ml online-endpoint show -> exit $($probe.ExitCode)`n" + $probe.StdErr)
    }
    $endpointInfo = $probe.StdOut | ConvertFrom-Json
    $list = Invoke-AzJson (@('ml', 'online-deployment', 'list', '--endpoint-name', $Endpoint) + $common + @('--output', 'json'))
    $traffic = Get-Split $endpointInfo.traffic
    $mirror = Get-Split $endpointInfo.mirror_traffic
    $deployments = @{}
    foreach ($d in $list) {
        $version = ''
        if ([string]$d.model -match '/versions/([^/?]+)$') { $version = $Matches[1] }
        elseif ([string]$d.model -match ':([^:]+)$') { $version = $Matches[1] }
        $t = 0
        if ($traffic.ContainsKey($d.name)) { $t = $traffic[$d.name] }
        $deployments[$d.name] = [pscustomobject]@{ Name = $d.name; Version = $version; State = $d.provisioning_state; Traffic = $t }
    }
    [pscustomobject]@{ Traffic = $traffic; Mirror = $mirror; Deployments = $deployments }
}

function Resolve-Roles {
    param($State)
    $holder = $null
    foreach ($c in $colours) {
        if ($State.Deployments.ContainsKey($c) -and $State.Deployments[$c].Version -eq "$ModelVersion") { $holder = $c }
    }
    if ($holder) {
        $candidate = $holder
        $current = $null
        if ($State.Deployments.ContainsKey((Other $holder))) { $current = Other $holder }
    }
    else {
        $served = @($colours | Where-Object { $State.Deployments.ContainsKey($_) -and $State.Deployments[$_].Traffic -gt 0 } |
            Sort-Object { $State.Deployments[$_].Traffic } -Descending)
        if ($served.Count -eq 0) {
            throw "No colour serves traffic on $Endpoint. Run scripts/81_prod_endpoint_bootstrap.ps1 (bootstrap) first."
        }
        $current = $served[0]
        $candidate = Other $current
    }
    [pscustomobject]@{ Current = $current; Candidate = $candidate }
}

function Show-State {
    param($State, $Roles)
    Write-Host "endpoint  : $Endpoint ($Workspace)"
    Write-Host "traffic   : $(($State.Traffic.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ' ')"
    Write-Host "mirror    : $(($State.Mirror.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ' ')"
    foreach ($c in $colours) {
        if ($State.Deployments.ContainsKey($c)) {
            $d = $State.Deployments[$c]
            Write-Host ("  {0,-6} version={1,-4} state={2,-10} traffic={3}" -f $d.Name, $d.Version, $d.State, $d.Traffic)
        }
    }
    Write-Host "model     : $modelUri"
    Write-Host "current   : $($Roles.Current)"
    Write-Host "candidate : $($Roles.Candidate)"
}

function Set-Mirror {
    param([int] $Percent, [string] $Target)
    & (Join-Path $PSScriptRoot '41_aml_traffic.ps1') -ResourceGroup $ResourceGroup -Workspace $Workspace `
        -EndpointName $Endpoint -Mirror $Percent -MirrorTarget $Target
}

function Set-Split {
    param([hashtable] $Percent)   # colour -> percent, must total 100
    $blue = 0; $green = 0
    if ($Percent.ContainsKey('blue')) { $blue = $Percent['blue'] }
    if ($Percent.ContainsKey('green')) { $green = $Percent['green'] }
    & (Join-Path $PSScriptRoot '41_aml_traffic.ps1') -ResourceGroup $ResourceGroup -Workspace $Workspace `
        -EndpointName $Endpoint -Blue $blue -Green $green
}

Write-Host "=== rollout stage '$Stage' - $ModelName v$ModelVersion ===" -ForegroundColor Cyan

# --- share: no PROD access needed, runs with the DEV connection ---------------
if ($Stage -eq 'share') {
    $present = Invoke-Az @('ml', 'model', 'show', '--name', $ModelName, '--version', "$ModelVersion",
        '--registry-name', $Registry, '--output', 'json')
    if ($present.ExitCode -eq 0) {
        Write-Host "$ModelName v$ModelVersion is already in registry $Registry -> nothing to share" -ForegroundColor Green
    }
    else {
        $source = Invoke-AzJson @('ml', 'model', 'show', '--name', $ModelName, '--version', "$ModelVersion",
            '--resource-group', $ResourceGroup, '--workspace-name', $DevWorkspace, '--output', 'json')
        Write-Host "source (DEV): $DevWorkspace  tags: $(($source.tags | ConvertTo-Json -Compress))"
        $shared = Invoke-Az @('ml', 'model', 'share', '--name', $ModelName, '--version', "$ModelVersion",
            '--resource-group', $ResourceGroup, '--workspace-name', $DevWorkspace,
            '--registry-name', $Registry, '--share-with-name', $ModelName, '--share-with-version', "$ModelVersion")
        if ($shared.ExitCode -ne 0) { throw ("model share failed:`n" + $shared.StdErr) }
        $check = Invoke-AzJson @('ml', 'model', 'show', '--name', $ModelName, '--version', "$ModelVersion",
            '--registry-name', $Registry, '--output', 'json')
        Write-Host "shared: $($check.id)" -ForegroundColor Green
    }
    $info = Invoke-AzJson @('ml', 'model', 'show', '--name', $ModelName, '--version', "$ModelVersion",
        '--registry-name', $Registry, '--output', 'json')
    Write-Host "registry model tags: $(($info.tags | ConvertTo-Json -Compress))"
    return
}

$state = Get-State
$roles = Resolve-Roles $state
Show-State $state $roles
$candidate = $roles.Candidate
$current = $roles.Current

switch ($Stage) {
    'state' { return }

    'deploy_candidate' {
        if (-not $current) {
            Write-Host "Version $ModelVersion is the only colour on ${Endpoint}: it is already served, nothing to deploy." -ForegroundColor Green
            return
        }
        if ($state.Deployments.ContainsKey($candidate) -and $state.Deployments[$candidate].Version -eq "$ModelVersion" -and
            $state.Deployments[$candidate].State -eq 'Succeeded' -and $state.Deployments[$candidate].Traffic -eq 0) {
            Write-Host "'$candidate' already runs v$ModelVersion (Succeeded, 0 percent real traffic): nothing to deploy, resume at the next stage." -ForegroundColor Green
            return
        }
        if ($state.Deployments[$current].Traffic -ne 100 -or $state.Mirror.Count -gt 0 -or
            ($state.Deployments.ContainsKey($candidate) -and $state.Deployments[$candidate].Traffic -ne 0)) {
            throw ("Starting state is not 'one colour at 100 percent, empty mirror, other colour at 0'. " +
                "A rollout is probably in progress. Resume at the next stage (mirror/canary/promote/retire) " +
                "or run action=rollback.")
        }
        Write-Host "`nDeploying $modelUri as '$candidate' at 0 percent (current: $current)" -ForegroundColor Cyan
        & (Join-Path $PSScriptRoot '30_aml_endpoint.ps1') -ResourceGroup $ResourceGroup -Workspace $Workspace `
            -EndpointName $Endpoint -DeploymentName $candidate -ModelUri $modelUri -SkipTraffic
    }

    'mirror' {
        if (-not $current) { throw "No other colour than '$candidate': nothing to compare against, mirror makes no sense." }
        $d = $state.Deployments[$candidate]
        if ($d.State -ne 'Succeeded') { throw "Candidate '$candidate' is '$($d.State)', not Succeeded. Run deploy_candidate first." }
        if ($d.Traffic -ne 0) { throw "Candidate '$candidate' already carries $($d.Traffic) percent: a deployment gets real traffic or mirror traffic, never both." }
        Set-Mirror -Percent $MirrorPercent -Target $candidate
        if ($ObserveMinutes -gt 0) {
            Write-Host "`nObserving for $ObserveMinutes min. Only calls that do not name a deployment are copied (the Function's)." -ForegroundColor Cyan
            Start-Sleep -Seconds ($ObserveMinutes * 60)
        }
        $logs = Invoke-Az (@('ml', 'online-deployment', 'get-logs', '--name', $candidate, '--endpoint-name', $Endpoint) + $common + @('--lines', '20'))
        if ($logs.ExitCode -eq 0) { Write-Host "--- last log lines of '$candidate' ---"; Write-Host $logs.StdOut }
    }

    'canary' {
        if (-not $current) { throw "No other colour than '$candidate': nothing to split with." }
        if ($state.Deployments[$candidate].State -ne 'Succeeded') { throw "Candidate '$candidate' is not Succeeded." }
        if ($state.Deployments[$candidate].Traffic -ge 100) { throw "Candidate '$candidate' already serves 100 percent: continue with retire, or rollback." }
        if ($state.Mirror.Count -gt 0) { Set-Mirror -Percent 0 -Target $candidate }
        Set-Split @{ $current = (100 - $CanaryPercent); $candidate = $CanaryPercent }
    }

    'promote' {
        if (-not $current) {
            Write-Host "'$candidate' is the only colour left: already promoted." -ForegroundColor Green
            return
        }
        if ($state.Deployments[$candidate].State -ne 'Succeeded') { throw "Candidate '$candidate' is not Succeeded." }
        if ($state.Mirror.Count -gt 0) { Set-Mirror -Percent 0 -Target $candidate }
        Set-Split @{ $current = 0; $candidate = 100 }
    }

    'retire' {
        if (-not $current) {
            Write-Host "Old colour already retired." -ForegroundColor Green
            return
        }
        if ($state.Deployments[$candidate].Traffic -ne 100 -or $state.Deployments[$current].Traffic -ne 0) {
            throw "Refusing to delete '$current': it must be at 0 percent and '$candidate' at 100 percent (a deployment with traffic cannot be deleted)."
        }
        Write-Host "`nDeleting old colour '$current' ..." -ForegroundColor Yellow
        $deleted = Invoke-Az (@('ml', 'online-deployment', 'delete', '--name', $current, '--endpoint-name', $Endpoint) + $common + @('--yes'))
        if ($deleted.ExitCode -ne 0) { throw ("delete failed:`n" + $deleted.StdErr) }
        Write-Host "deleted" -ForegroundColor Green
    }

    'rollback' {
        if (-not $current) { throw "The old colour is already retired. Rolling back means publishing the previous model version again." }
        if (-not $state.Deployments.ContainsKey($candidate)) { throw "Candidate '$candidate' does not exist: nothing to roll back." }
        if ($state.Mirror.Count -gt 0) { Set-Mirror -Percent 0 -Target $candidate }
        Set-Split @{ $current = 100; $candidate = 0 }
    }
}

$after = Get-State
Write-Host "`n--- state after '$Stage' ---"
Show-State $after (Resolve-Roles $after)
