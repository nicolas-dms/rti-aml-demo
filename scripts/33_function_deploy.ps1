<#
.SYNOPSIS
    P6 - Publishes the scoring Function to Azure and shows how to watch it run.

.DESCRIPTION
    Thin wrapper around "func azure functionapp publish". Its only real job is
    to fail early and clearly:

      - func must be found, which the PATH alone cannot guarantee on Windows
        (see Resolve-Func below), and must be v4;
      - the app settings must already be there, because a Function that starts
        without AML_SCORING_URI does not crash, it just logs a RuntimeError
        every 30 seconds and looks alive.

    Flex Consumption builds the dependencies remotely, so the first publish
    takes a few minutes. Nothing is compiled locally.

.NOTES
    ASCII only - Windows PowerShell 5.1 reads .ps1 as ANSI.
#>

[CmdletBinding()]
param(
    [string] $ResourceGroup = (& "$PSScriptRoot\lib\cfg.ps1" AZURE_RESOURCE_GROUP -Required),
    [string] $FunctionApp   = (& "$PSScriptRoot\lib\cfg.ps1" FUNCTION_APP -Required),
    [switch] $SkipSettingsCheck
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $repoRoot

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

function Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }

function Resolve-Func {
    <#
        The PATH is not a reliable way to find func on Windows.

        winget installs Core Tools as a PORTABLE package: the binary lands in
        WinGet\Packages\... and winget is supposed to drop a symlink in
        WinGet\Links, which is the folder actually on the PATH. That link is
        missing often enough (Developer Mode off, a repair install, a roaming
        profile) that "winget list" reports the package as installed while
        "where func" finds nothing at all - which is exactly what happened here.

        So: look at the PATH first, then at the known install locations, and
        only give up afterwards. Returns a full path to func.exe.
    #>
    $onPath = Get-Command func -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\func.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Microsoft.Azure.FunctionsCoreTools_Microsoft.Winget.Source_8wekyb3d8bbwe\func.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Azure Functions Core Tools\func.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Azure Functions Core Tools\func.exe'),
        (Join-Path $env:APPDATA 'npm\func.cmd')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }

    # Last resort: any versioned portable package directory.
    $packages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $packages) {
        $found = Get-ChildItem -Path $packages -Filter 'func.exe' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -notmatch 'in-proc\d' } |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    throw "func.exe not found on the PATH nor in the known install locations. Install it: winget install Microsoft.Azure.FunctionsCoreTools"
}

# ---------------------------------------------------------------------------
# [1/3] Tooling
# ---------------------------------------------------------------------------
Step "[1/3] Locating Azure Functions Core Tools"
$funcExe = Resolve-Func
Write-Host "    $funcExe"

# v3 cannot publish a Python v2 programming model project, and says so badly.
$funcVersion = (& $funcExe --version 2>&1 | Out-String).Trim()
Write-Host "    version $funcVersion"
if ($funcVersion -notmatch '^4\.') {
    throw "Core Tools v4 is required (found '$funcVersion'). The Python v2 model will not publish otherwise."
}

# ---------------------------------------------------------------------------
# [2/3] Configuration must exist BEFORE the code does
# ---------------------------------------------------------------------------
if ($SkipSettingsCheck) {
    Step "[2/3] App settings check skipped"
}
else {
    Step "[2/3] Verifying the app settings"
    $result = Invoke-Az @(
        'functionapp', 'config', 'appsettings', 'list',
        '--name', $FunctionApp, '--resource-group', $ResourceGroup, '--output', 'json'
    )
    if ($result.ExitCode -ne 0) { throw $result.StdErr }
    $names = ($result.StdOut | ConvertFrom-Json) | ForEach-Object { $_.name }

    $required = @(
        'KUSTO_CLUSTER_URI', 'KUSTO_INGEST_URI', 'KUSTO_DATABASE',
        'AML_SCORING_URI', 'AML_SUBSCRIPTION_ID', 'AML_RESOURCE_GROUP',
        'AML_WORKSPACE', 'AML_ENDPOINT_NAME'
    )
    $missing = $required | Where-Object { $names -notcontains $_ }
    if ($missing) {
        throw ("Missing app settings: " + ($missing -join ', ') + ". Run scripts/32_function_config.ps1 first.")
    }
    Write-Host "    all $($required.Count) required settings present"
}

# ---------------------------------------------------------------------------
# [3/3] Publish
# ---------------------------------------------------------------------------
Step "[3/3] Publishing functions/ to '$FunctionApp' (remote build, a few minutes)"
Push-Location (Join-Path $repoRoot 'functions')
try {
    & $funcExe azure functionapp publish $FunctionApp --python
    $publishExit = $LASTEXITCODE
}
finally {
    Pop-Location
}
if ($publishExit -ne 0) { throw "func publish failed with exit code $publishExit" }

Write-Host "`n==================== NEXT ====================" -ForegroundColor Green
Write-Host "Watch the loop (one line every 30 seconds):" -ForegroundColor Yellow
Write-Host "  `"$funcExe`" azure functionapp logstream $FunctionApp"
Write-Host ""
Write-Host "Then confirm the write-back in a Fabric queryset:" -ForegroundColor Yellow
Write-Host "  scoring_results | where scored_at > ago(10m) | summarize count() by deployment, model_version"
