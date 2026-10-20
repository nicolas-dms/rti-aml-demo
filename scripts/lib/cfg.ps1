<#
.SYNOPSIS
    Returns ONE value from demo.config.env (repo root). Used in param() defaults of every script.

.DESCRIPTION
    Usage in a script:
        [string] $ResourceGroup = (& "$PSScriptRoot\lib\cfg.ps1" AZURE_RESOURCE_GROUP -Required)

    A param() default is only evaluated when the caller does not pass the parameter, so an
    explicit -ResourceGroup always wins and a missing key only fails when it is really needed.

    Lookup order: environment variable RTI_<KEY>, then demo.config.env, then -Default.
    The file is read as KEY=VALUE lines. '#' starts a comment line (no inline comments).
    A value that is empty or still a placeholder such as <your-subscription-id> counts as missing.
    The file path can be overridden with the environment variable RTI_CONFIG.

    ASCII only - Windows PowerShell 5.1 reads .ps1 as ANSI.
#>
param(
    [Parameter(Mandatory, Position = 0)] [string] $Key,
    [string] $Default = '',
    [switch] $Required
)

$ErrorActionPreference = 'Stop'

function Test-Missing { param([string] $Value) return ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '^<.*>$') }

$value = $null

$fromEnv = [Environment]::GetEnvironmentVariable("RTI_$Key")
if (-not (Test-Missing $fromEnv)) { $value = $fromEnv }

if ($null -eq $value) {
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $path = $env:RTI_CONFIG
    if ([string]::IsNullOrWhiteSpace($path)) { $path = Join-Path $repoRoot 'demo.config.env' }

    if (Test-Path -LiteralPath $path) {
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            if ($line -match '^\s*#' -or $line -notmatch '^\s*([A-Za-z0-9_]+)\s*=(.*)$') { continue }
            if ($Matches[1] -ne $Key) { continue }
            $candidate = $Matches[2].Trim()
            if ($candidate.Length -ge 2 -and (($candidate.StartsWith('"') -and $candidate.EndsWith('"')) -or ($candidate.StartsWith("'") -and $candidate.EndsWith("'")))) {
                $candidate = $candidate.Substring(1, $candidate.Length - 2)
            }
            if (-not (Test-Missing $candidate)) { $value = $candidate }
        }
    }
    elseif ($Required) {
        throw "Configuration file not found: $path. Run scripts/00a_init_config.ps1 or restore demo.config.env at the repository root."
    }
}

if ($null -eq $value) { $value = $Default }
if ($Required -and (Test-Missing $value)) {
    throw "Missing setting $Key in demo.config.env. Fill it in (see the comments in that file) or run scripts/00a_init_config.ps1."
}
return $value
