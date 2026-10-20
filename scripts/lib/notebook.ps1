# Helpers to publish repo notebooks to Fabric with the values of demo.config.env.
# Dot-source it:   . "$PSScriptRoot\lib\notebook.ps1"
# ASCII only - Windows PowerShell 5.1 reads .ps1 as ANSI.

# Replaces the literal of top-level constants (KEY = "value" or KEY = 'value') in every code cell.
# The notebook files in the repo keep working literals; only the uploaded copy is rewritten.
# Returns the list of keys that were replaced.
function Set-NotebookConstants {
    param(
        [Parameter(Mandatory)] $Notebook,                 # object from ConvertFrom-Json
        [Parameter(Mandatory)] [hashtable] $Values        # constant name -> new value
    )
    $replaced = New-Object System.Collections.Generic.List[string]
    foreach ($cell in $Notebook.cells) {
        if ($cell.cell_type -ne 'code') { continue }
        $isArray = $cell.source -is [array]
        $lines = @($cell.source)
        if (-not $isArray -and $lines.Count -eq 1) { $lines = @(([string]$cell.source) -split '(?<=\n)') }
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = [string]$lines[$i]
            if ($line -notmatch '^([A-Z][A-Z0-9_]*)\s*=\s*(["''])(.*?)\2(\s*#.*?)?(\r?\n)?$') { continue }
            $key = $Matches[1]
            if (-not $Values.ContainsKey($key)) { continue }
            $new = [string]$Values[$key]
            if ([string]::IsNullOrWhiteSpace($new)) { continue }
            $quote = $Matches[2]; $comment = $Matches[4]; $eol = $Matches[5]
            $lines[$i] = "$key = $quote$new$quote$comment$eol"
            $replaced.Add($key)
        }
        if ($isArray) { $cell.source = [string[]]$lines } else { $cell.source = ($lines -join '') }
    }
    return $replaced.ToArray()
}

# Values shared by the notebooks, read from demo.config.env (blank values are skipped).
function Get-NotebookConstantValues {
    $cfg = Join-Path $PSScriptRoot 'cfg.ps1'
    $map = @{
        WORKSPACE_ID    = 'FABRIC_WORKSPACE_ID'
        KQL_DATABASE_ID = 'KQL_DATABASE_ID'
        STORAGE_ACCOUNT = 'STORAGE_ACCOUNT'
        FILESYSTEM      = 'STORAGE_FILESYSTEM'
        SUBSCRIPTION_ID = 'AZURE_SUBSCRIPTION_ID'
        RESOURCE_GROUP  = 'AZURE_RESOURCE_GROUP'
        AML_WORKSPACE   = 'AML_DEV_WORKSPACE'
        KUSTO_URI       = 'KUSTO_QUERY_URI'
        ENDPOINT        = 'ENDPOINT_DEV'
    }
    $values = @{}
    foreach ($name in $map.Keys) { $values[$name] = (& $cfg $map[$name]) }
    return $values
}
