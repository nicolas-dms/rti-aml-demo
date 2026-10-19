<#
.SYNOPSIS
    P1 - Bootstraps every Azure resource needed by the RTI x AML demo.

.DESCRIPTION
    Idempotent. Safe to re-run: every step checks for existence first.
    No IaC on purpose - this is the shortest path for a demo.
    Creates: resource group, ADLS Gen2 (+ snapshots filesystem), Azure ML workspace,
    AML compute cluster, AML datastore (identity-based), Function App (Flex Consumption),
    and the RBAC role assignments.

.NOTES
    Region and subscription are locked in docs/DEMO-PLAN.md.
    Run:  pwsh -File scripts/00_bootstrap.ps1
#>

[CmdletBinding()]
param(
    [string] $SubscriptionId = '<SUBSCRIPTION_ID>',    [string] $Location       = 'westus3',
    [string] $ResourceGroup  = 'rg-rti-aml-demo',
    [string] $AmlWorkspace   = 'aml-rti-demo',
    [string] $ComputeName    = 'cpu-cluster',
    [string] $ComputeSize    = 'Standard_DS3_v2',
    [string] $DatastoreName  = 'rti_snapshots',
    [string] $FileSystem     = 'snapshots'
)

$ErrorActionPreference = 'Stop'

# The VS Code terminal sometimes loses PATH; always resolve az explicitly.
$AzCmd = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
if (-not (Test-Path $AzCmd)) { $AzCmd = (Get-Command az -ErrorAction Stop).Source }

# No param block on purpose -> plain function, no PowerShell common parameters,
# so short az flags such as -o / -g are never intercepted by the binder.
# (All az flags below are still spelled in long form for readability.)
#
# $ErrorActionPreference='Stop' + '2>&1' on a NATIVE command turns any stderr line
# into a terminating NativeCommandError. az writes warnings to stderr, so we must
# neutralise that inside the helpers.
function Invoke-AzRaw {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $AzCmd @args 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{
        Ok     = ($code -eq 0)
        Code   = $code
        Output = (($out -join "`n").Trim())
    }
}

function Invoke-Az {
    $r = Invoke-AzRaw @args
    if (-not $r.Ok) {
        throw "az $($args -join ' ') failed (exit $($r.Code)):`n$($r.Output)"
    }
    return $r.Output
}

# Same, but never throws - for operations that are fine to fail (already exists).
function Invoke-AzSoft {
    return (Invoke-AzRaw @args)
}

function Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }

# --------------------------------------------------------------------------
# 0. Context + deterministic globally-unique suffix
# --------------------------------------------------------------------------
Step "Setting subscription $SubscriptionId"
Invoke-Az account set --subscription $SubscriptionId | Out-Null

$hash    = ([System.Security.Cryptography.SHA256]::Create()).ComputeHash([Text.Encoding]::UTF8.GetBytes("$SubscriptionId/$ResourceGroup"))
$suffix  = -join ($hash[0..3] | ForEach-Object { $_.ToString('x2') })   # 8 hex chars
$Storage = "strtiaml$suffix"          # 16 chars, lowercase, globally unique
$FuncSa  = "stfuncrti$suffix"         # storage backing the Function App
$FuncApp = "func-rti-scorer-$suffix"

Write-Host "  storage      : $Storage"
Write-Host "  function sa  : $FuncSa"
Write-Host "  function app : $FuncApp"

Step "Registering resource providers (no-op if already registered)"
foreach ($rp in 'Microsoft.MachineLearningServices', 'Microsoft.Storage', 'Microsoft.Web', 'Microsoft.Insights', 'Microsoft.KeyVault') {
    Invoke-Az provider register --namespace $rp --wait | Out-Null
}

# --------------------------------------------------------------------------
# 1. Resource group
# --------------------------------------------------------------------------
Step "Resource group $ResourceGroup ($Location)"
if ((Invoke-Az group exists --name $ResourceGroup) -eq 'false') {
    Invoke-Az group create --name $ResourceGroup --location $Location --output none | Out-Null
    Write-Host "  created"
} else { Write-Host "  already exists" }

# --------------------------------------------------------------------------
# 2. ADLS Gen2 (hierarchical namespace) = AML datastore backing store
# --------------------------------------------------------------------------
Step "ADLS Gen2 $Storage"
$count = Invoke-Az storage account list --resource-group $ResourceGroup --query "[?name=='$Storage'] | length(@)" --output tsv
if ($count -eq '0') {
    Invoke-Az storage account create `
        --name $Storage --resource-group $ResourceGroup --location $Location `
        --sku Standard_LRS --kind StorageV2 --enable-hierarchical-namespace true `
        --min-tls-version TLS1_2 --allow-blob-public-access false --output none | Out-Null
    Write-Host "  created"
} else { Write-Host "  already exists" }

$storageId = Invoke-Az storage account show --name $Storage --resource-group $ResourceGroup --query id --output tsv

# The MCAPSGov "Deploy and Modify" policy (management-group scope) forces
# publicNetworkAccess=Disabled and allowSharedKeyAccess=false on every new
# storage account. allowSharedKeyAccess=false is fine (we use --auth-mode login
# and managed identities), but publicNetworkAccess=Disabled blocks the data
# plane from the laptop AND from AML compute, so it must be re-enabled.
Step "Ensuring public network access is Enabled on $Storage"
$pna = Invoke-Az storage account show --name $Storage --resource-group $ResourceGroup --query publicNetworkAccess --output tsv
if ($pna -ne 'Enabled') {
    Write-Host "  currently '$pna' (forced by Azure Policy) - re-enabling..."
    $r = Invoke-AzSoft storage account update --name $Storage --resource-group $ResourceGroup `
            --public-network-access Enabled --default-action Allow --bypass AzureServices --output none
    if (-not $r.Ok) { throw "Could not enable public network access on ${Storage}:`n$($r.Output)" }
    $pna = Invoke-Az storage account show --name $Storage --resource-group $ResourceGroup --query publicNetworkAccess --output tsv
    if ($pna -ne 'Enabled') {
        throw "Azure Policy immediately reverted publicNetworkAccess to '$pna' on $Storage. A private endpoint (or a policy exemption) is required."
    }
}
Write-Host "  publicNetworkAccess = $pna"

Step "Granting the signed-in user 'Storage Blob Data Contributor' on $Storage"
$me = Invoke-Az ad signed-in-user show --query id --output tsv
$r  = Invoke-AzSoft role assignment create --assignee-object-id $me --assignee-principal-type User `
        --role 'Storage Blob Data Contributor' --scope $storageId --output none
Write-Host $(if ($r.Ok) { "  assigned" } else { "  already assigned (or insufficient rights) - continuing" })

Step "Filesystem '$FileSystem'"
# The data-plane role assignment above can take up to a minute to propagate.
$fsOk = $false
foreach ($attempt in 1..6) {
    $r = Invoke-AzSoft storage fs create --name $FileSystem --account-name $Storage --auth-mode login --output none
    if ($r.Ok) { $fsOk = $true; break }
    Write-Host "  attempt $attempt/6 failed: $($r.Output)" -ForegroundColor DarkYellow
    Write-Host "  waiting 15s for RBAC propagation..."
    Start-Sleep -Seconds 15
}
if (-not $fsOk) { throw "Could not create filesystem '$FileSystem' on $Storage - check the 'Storage Blob Data Contributor' assignment." }
Write-Host "  ok"

# --------------------------------------------------------------------------
# 3. Azure ML workspace + compute cluster
# --------------------------------------------------------------------------
Step "Azure ML workspace $AmlWorkspace"
$count = Invoke-Az ml workspace list --resource-group $ResourceGroup --query "[?name=='$AmlWorkspace'] | length(@)" --output tsv
if ($count -eq '0') {
    # --system-datastores-auth-mode identity (preview): the subscription policy sets
    # allowSharedKeyAccess = false on every storage account and remediates continuously,
    # so the default accesskey mode would break every job output and log download with
    # KeyBasedAuthenticationNotPermitted. See scripts/22_aml_identity_datastores.ps1
    # for the same change applied to an already-created workspace.
    Invoke-Az ml workspace create --name $AmlWorkspace --resource-group $ResourceGroup --location $Location `
        --system-datastores-auth-mode identity --output none | Out-Null
    Write-Host "  created"
} else { Write-Host "  already exists" }

Step "AML compute cluster $ComputeName (min 0 / max 2, $ComputeSize)"
$count = Invoke-Az ml compute list --resource-group $ResourceGroup --workspace-name $AmlWorkspace --query "[?name=='$ComputeName'] | length(@)" --output tsv
if ($count -eq '0') {
    Invoke-Az ml compute create --name $ComputeName --type amlcompute --size $ComputeSize `
        --min-instances 0 --max-instances 2 --idle-time-before-scale-down 120 `
        --identity-type SystemAssigned `
        --resource-group $ResourceGroup --workspace-name $AmlWorkspace --output none | Out-Null
    Write-Host "  created"
} else { Write-Host "  already exists" }

Step "Granting the AML workspace identity 'Storage Blob Data Contributor' on $Storage"
$amlMi = Invoke-Az ml workspace show --name $AmlWorkspace --resource-group $ResourceGroup --query identity.principal_id --output tsv
$r = Invoke-AzSoft role assignment create --assignee-object-id $amlMi --assignee-principal-type ServicePrincipal `
        --role 'Storage Blob Data Contributor' --scope $storageId --output none
Write-Host $(if ($r.Ok) { "  assigned" } else { "  already assigned (or insufficient rights) - continuing" })

# --------------------------------------------------------------------------
# 4. AML datastore pointing at the ADLS Gen2 filesystem (identity-based, no keys)
# --------------------------------------------------------------------------
Step "AML datastore $DatastoreName -> $Storage/$FileSystem"
$repoRoot      = Split-Path $PSScriptRoot -Parent
$datastoreTpl  = Join-Path $repoRoot 'aml\data\datastore.yml'
$datastoreTmp  = Join-Path ([IO.Path]::GetTempPath()) 'rti-datastore.yml'
(Get-Content $datastoreTpl -Raw).Replace('PLACEHOLDER_ACCOUNT', $Storage) | Set-Content $datastoreTmp -Encoding utf8
Invoke-Az ml datastore create --file $datastoreTmp --resource-group $ResourceGroup --workspace-name $AmlWorkspace --output none | Out-Null
Remove-Item $datastoreTmp -Force
Write-Host "  ok"

# --------------------------------------------------------------------------
# 5. Function App (Flex Consumption, Python 3.11, system-assigned identity)
# --------------------------------------------------------------------------
Step "Function App storage $FuncSa"
$count = Invoke-Az storage account list --resource-group $ResourceGroup --query "[?name=='$FuncSa'] | length(@)" --output tsv
if ($count -eq '0') {
    Invoke-Az storage account create --name $FuncSa --resource-group $ResourceGroup --location $Location `
        --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false --output none | Out-Null
    Write-Host "  created"
} else { Write-Host "  already exists" }

Step "Function App $FuncApp (Flex Consumption, Python 3.11)"
$count = Invoke-Az functionapp list --resource-group $ResourceGroup --query "[?name=='$FuncApp'] | length(@)" --output tsv
if ($count -eq '0') {
    Invoke-Az functionapp create --name $FuncApp --resource-group $ResourceGroup `
        --storage-account $FuncSa --flexconsumption-location $Location `
        --runtime python --runtime-version 3.11 --output none | Out-Null
    Write-Host "  created"
} else { Write-Host "  already exists" }

Step "Enabling the system-assigned managed identity on $FuncApp"
$funcMi = Invoke-Az functionapp identity assign --name $FuncApp --resource-group $ResourceGroup --query principalId --output tsv
Write-Host "  principalId = $funcMi"

# --------------------------------------------------------------------------
# Summary - copy these values into docs/PROGRESS.md
# --------------------------------------------------------------------------
Write-Host "`n==================== SUMMARY ====================" -ForegroundColor Green
[pscustomobject]@{
    subscription   = $SubscriptionId
    location       = $Location
    resourceGroup  = $ResourceGroup
    adlsAccount    = $Storage
    filesystem     = $FileSystem
    amlWorkspace   = $AmlWorkspace
    amlCompute     = $ComputeName
    amlDatastore   = $DatastoreName
    amlPrincipalId = $amlMi
    functionApp    = $FuncApp
    functionSa     = $FuncSa
    functionMi     = $funcMi
} | Format-List

Write-Host "Next: P2 - create the Fabric workspace on capacity '<FABRIC_CAPACITY>' and the Eventhouse." -ForegroundColor Yellow
