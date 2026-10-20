<#
.SYNOPSIS
    Writes ONE value into demo.config.env (updates the KEY=... line, or appends it).

.DESCRIPTION
    Used by scripts that discover a value (Fabric ids, Kusto URI) so the next scripts
    and the notebooks do not have to look it up again. Comments and other lines are kept.

    ASCII only - Windows PowerShell 5.1 reads .ps1 as ANSI.
#>
param(
    [Parameter(Mandatory, Position = 0)] [string] $Key,
    [Parameter(Mandatory, Position = 1)] [string] $Value
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$path = $env:RTI_CONFIG
if ([string]::IsNullOrWhiteSpace($path)) { $path = Join-Path $repoRoot 'demo.config.env' }
if (-not (Test-Path -LiteralPath $path)) { throw "Configuration file not found: $path" }

$lines = New-Object System.Collections.Generic.List[string]
$lines.AddRange([string[]][IO.File]::ReadAllLines($path))

$found = $false
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*([A-Za-z0-9_]+)\s*=' -and $Matches[1] -eq $Key -and $lines[$i] -notmatch '^\s*#') {
        $lines[$i] = "$Key=$Value"
        $found = $true
        break
    }
}
if (-not $found) { $lines.Add("$Key=$Value") }

# UTF-8 without BOM, keeping the file's line endings simple (CRLF on Windows).
[IO.File]::WriteAllText($path, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "    config: $Key set in $(Split-Path $path -Leaf)"
