<#
.SYNOPSIS
    Checks the workstation, the az session and demo.config.env before you build anything.

.DESCRIPTION
    Read-only: creates nothing, changes nothing. Prints OK / WARN / FAIL per check and exits 1 if any
    check FAILs. Re-run it after fixing what it reports.

    Checks: az, ml extension, python, func, PowerShell, az login tenant, required config keys,
    resource providers, Azure rights, Fabric capacity (exists, Active), Fabric API token,
    storage account name availability.

.EXAMPLE
    .\scripts\00b_preflight.ps1

.NOTES
    If PowerShell refuses to run scripts:  Set-ExecutionPolicy -Scope Process Bypass
    ASCII only - Windows PowerShell 5.1 reads .ps1 as ANSI.
#>
[CmdletBinding()]
param(
    [string] $ExpectedMlExtension = '2.44.1'
)

$ErrorActionPreference = 'Stop'

$AzCmd = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
if (-not (Test-Path $AzCmd)) {
    $found = Get-Command az -ErrorAction SilentlyContinue
    if ($found) { $AzCmd = $found.Source } else { $AzCmd = $null }
}

$script:fails = 0
$script:warns = 0
function Ok   { param([string] $m) Write-Host ("  [ OK ] " + $m) -ForegroundColor Green }
function Warn { param([string] $m) $script:warns++; Write-Host ("  [WARN] " + $m) -ForegroundColor Yellow }
function Fail { param([string] $m) $script:fails++; Write-Host ("  [FAIL] " + $m) -ForegroundColor Red }
function Head { param([string] $m) Write-Host ("`n==> " + $m) -ForegroundColor Cyan }

function Invoke-AzQuiet {
    if (-not $AzCmd) { return $null }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $AzCmd @args 2>$null } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { return $null }
    return (($out | ForEach-Object { "$_" }) -join "`n").Trim()
}

function Get-Cfg { param([string] $Key) return (& "$PSScriptRoot\lib\cfg.ps1" $Key) }
function Test-Unset { param([string] $Value) return ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '^<.*>$') }

# ---------------------------------------------------------------- tools
Head 'Tools'
if ($PSVersionTable.PSVersion.Major -ge 5) { Ok "PowerShell $($PSVersionTable.PSVersion)" } else { Fail "PowerShell $($PSVersionTable.PSVersion) - 5.1 or later required" }

if ($AzCmd) {
    $v = Invoke-AzQuiet version --output json
    if ($v) { Ok ("az CLI " + ((ConvertFrom-Json $v).'azure-cli')) } else { Fail 'az found but `az version` failed' }
} else {
    Fail 'az CLI not found (https://learn.microsoft.com/cli/azure/install-azure-cli)'
}

$mlExt = Invoke-AzQuiet extension list --query "[?name=='ml'].version | [0]" --output tsv
if ($mlExt) {
    if ($mlExt -eq $ExpectedMlExtension) { Ok "az extension ml $mlExt" }
    else { Warn "az extension ml is $mlExt, the demo was validated with $ExpectedMlExtension (az extension add -n ml --version $ExpectedMlExtension --upgrade)" }
} else {
    Fail "az extension ml missing (az extension add -n ml --version $ExpectedMlExtension)"
}

$py = Get-Command python -ErrorAction SilentlyContinue
if ($py) {
    $pv = (& python --version 2>&1 | ForEach-Object { "$_" }) -join ' '
    Ok $pv
} else { Fail 'python not found (3.10+ required for the simulator and scripts 72, 31, 66)' }

$fn = Get-Command func -ErrorAction SilentlyContinue
if ($fn) { Ok 'Azure Functions Core Tools (func)' } else { Warn 'func not found - needed only to deploy the Function (script 33)' }

# ---------------------------------------------------------------- config
Head 'demo.config.env'
$required = 'AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_LOCATION', 'AZURE_RESOURCE_GROUP',
            'AML_DEV_WORKSPACE', 'AML_PROD_WORKSPACE', 'AML_REGISTRY',
            'FABRIC_CAPACITY', 'FABRIC_CAPACITY_RESOURCE_GROUP', 'FABRIC_WORKSPACE'
$missing = @()
foreach ($k in $required) {
    $val = Get-Cfg $k
    if (Test-Unset $val) { $missing += $k }
}
if ($missing.Count -eq 0) { Ok 'all required keys are set' }
else { foreach ($k in $missing) { Fail "$k is empty - edit demo.config.env or run scripts\00a_init_config.ps1" } }

$sub = Get-Cfg 'AZURE_SUBSCRIPTION_ID'
$tenant = Get-Cfg 'AZURE_TENANT_ID'
$rg = Get-Cfg 'AZURE_RESOURCE_GROUP'
$loc = Get-Cfg 'AZURE_LOCATION'

foreach ($k in 'STORAGE_ACCOUNT', 'FUNCTION_STORAGE_ACCOUNT') {
    $val = Get-Cfg $k
    if (-not (Test-Unset $val) -and $val -notmatch '^[a-z0-9]{3,24}$') { Fail "$k '$val' is invalid: 3-24 lowercase letters and digits only" }
}

if ($missing.Count -gt 0 -or -not $AzCmd) {
    Write-Host "`nStopping the Azure checks: fix the items above first." -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------- session
Head 'az session'
$acctJson = Invoke-AzQuiet account show --output json
if (-not $acctJson) {
    Fail "not logged in: az login --tenant $tenant"
    exit 1
}
$acct = ConvertFrom-Json $acctJson
if ($acct.tenantId -ne $tenant) {
    Fail "az is logged in to tenant $($acct.tenantId), config expects $tenant -> az login --tenant $tenant"
    exit 1
}
Ok "tenant $tenant"
if ($acct.id -ne $sub) {
    $set = Invoke-AzQuiet account set --subscription $sub
    $now = Invoke-AzQuiet account show --query id --output tsv
    if ($now -eq $sub) { Ok "subscription switched to $sub" } else { Fail "cannot select subscription $sub with this account" ; exit 1 }
} else { Ok "subscription $sub" }

# ---------------------------------------------------------------- providers
Head 'Resource providers'
foreach ($rp in 'Microsoft.MachineLearningServices', 'Microsoft.Storage', 'Microsoft.Web', 'Microsoft.Insights', 'Microsoft.KeyVault', 'Microsoft.Fabric') {
    $state = Invoke-AzQuiet provider show --namespace $rp --query registrationState --output tsv
    if ($state -eq 'Registered') { Ok $rp }
    else { Warn "$rp is '$state' (00_bootstrap.ps1 registers it; Microsoft.Fabric: az provider register -n Microsoft.Fabric)" }
}

# ---------------------------------------------------------------- rights
Head 'Azure rights (needed to create resources and assign roles)'
$me = Invoke-AzQuiet ad signed-in-user show --query id --output tsv
if (-not $me) { $me = Invoke-AzQuiet account show --query user.name --output tsv }
$rolesJson = Invoke-AzQuiet role assignment list --assignee $me --all --include-inherited --include-groups --query "[].roleDefinitionName" --output json
if ($rolesJson) {
    $roles = @(ConvertFrom-Json $rolesJson)
    $canBuild = ($roles -contains 'Owner') -or ($roles -contains 'Contributor')
    $canAssign = ($roles -contains 'Owner') -or ($roles -contains 'User Access Administrator') -or ($roles -contains 'Role Based Access Control Administrator')
    if ($canBuild) { Ok 'can create resources (Owner or Contributor)' } else { Warn 'no Owner/Contributor role found on the subscription (a role scoped to the resource group, or PIM, is fine if it covers it)' }
    if ($canAssign) { Ok 'can assign roles (Owner, User Access Administrator or RBAC Administrator)' }
    else { Warn 'cannot assign roles - 00_bootstrap.ps1 and 71_mlops_rbac.ps1 create role assignments; ask an Owner to run them' }
} else {
    Warn 'could not list your role assignments (Graph or RBAC read denied); the first script that fails will tell you'
}

# ---------------------------------------------------------------- fabric
Head 'Fabric capacity'
$capName = Get-Cfg 'FABRIC_CAPACITY'
$capRg = Get-Cfg 'FABRIC_CAPACITY_RESOURCE_GROUP'
$capJson = Invoke-AzQuiet resource show --resource-group $capRg --name $capName --resource-type Microsoft.Fabric/capacities --output json
if ($capJson) {
    $cap = ConvertFrom-Json $capJson
    $state = $cap.properties.state
    $sku = $cap.sku.name
    if ($state -eq 'Active') { Ok "$capName ($sku, Active)" }
    else { Warn "$capName is '$state' - resume it: az resource invoke-action --action resume --ids $($cap.id) --api-version 2023-11-01" }
    $capLoc = ($cap.location -replace '\s', '').ToLower()
    if ($capLoc -ne $loc.ToLower()) { Warn "capacity is in $capLoc but AZURE_LOCATION is $loc - the demo works, but data crosses regions" }
} else {
    Fail "capacity '$capName' not found in resource group '$capRg' (Fabric trial capacities do not appear in Azure: then set FABRIC_CAPACITY to its display name and ignore this line)"
}

$tok = Invoke-AzQuiet account get-access-token --resource https://api.fabric.microsoft.com --query expiresOn --output tsv
if ($tok) { Ok 'token for the Fabric API' } else { Fail 'cannot get a token for https://api.fabric.microsoft.com (is Fabric enabled for your tenant and user?)' }

# ---------------------------------------------------------------- names
Head 'Globally unique names'
$hash = ([System.Security.Cryptography.SHA256]::Create()).ComputeHash([Text.Encoding]::UTF8.GetBytes("$sub/$rg"))
$suffix = -join ($hash[0..3] | ForEach-Object { $_.ToString('x2') })
$names = @(
    @{ Key = 'STORAGE_ACCOUNT';          Default = "strtiaml$suffix" },
    @{ Key = 'FUNCTION_STORAGE_ACCOUNT'; Default = "stfuncrti$suffix" }
)
foreach ($n in $names) {
    $val = Get-Cfg $n.Key
    if (Test-Unset $val) { $val = $n.Default }
    $existing = Invoke-AzQuiet storage account list --resource-group $rg --query "[?name=='$val'] | length(@)" --output tsv
    if ($existing -eq '1') { Ok "$($n.Key) = $val (already created in $rg)"; continue }
    $avail = Invoke-AzQuiet storage account check-name --name $val --query nameAvailable --output tsv
    if ($avail -eq 'true') { Ok "$($n.Key) = $val (available)" }
    else { Fail "$($n.Key) = $val is taken by someone else - change it in demo.config.env" }
}

# ---------------------------------------------------------------- summary
Write-Host ""
if ($script:fails -gt 0) {
    Write-Host "$($script:fails) FAIL, $($script:warns) WARN - fix the FAIL lines, then re-run." -ForegroundColor Red
    exit 1
}
Write-Host "No blocking issue ($($script:warns) warning(s)). Next: .\scripts\00_bootstrap.ps1" -ForegroundColor Green
exit 0
