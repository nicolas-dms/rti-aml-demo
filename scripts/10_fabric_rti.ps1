<#
.SYNOPSIS
    P2 - Provisionne la couche Fabric Real-Time Intelligence de la demo RTI x AML.

.DESCRIPTION
    Idempotent. Cree, s'ils n'existent pas deja :
      - le workspace Fabric        ws-rti-aml-demo   (sur la capacite <FABRIC_CAPACITY>)
      - l'Eventhouse               eh-sensors
      - la KQL Database            sensors
    Puis affiche les URI de requete / d'ingestion necessaires aux etapes suivantes.

    Le SDK/CLI "Microsoft.Fabric.Mcp" ne sait creer que des items dans un workspace
    existant ; la creation du workspace et la lecture des proprietes passent donc par
    l'API REST Fabric (https://api.fabric.microsoft.com/v1).

.NOTES
    Prerequis : az login --tenant <TENANT_ID>
    Aucun secret n'est ecrit ni affiche.
#>

[CmdletBinding()]
param(
    [string] $WorkspaceName  = 'ws-rti-aml-demo',
    [string] $CapacityName   = '<FABRIC_CAPACITY>',
    [string] $EventhouseName = 'eh-sensors',
    [string] $DatabaseName   = 'sensors'
)

$ErrorActionPreference = 'Stop'

$FabricApi      = 'https://api.fabric.microsoft.com/v1'
$FabricResource = 'https://api.fabric.microsoft.com'

# --- Resolution de az.cmd (le PATH est parfois perdu dans le terminal integre) ---
$AzCmd = $null
$azCommand = Get-Command az -ErrorAction SilentlyContinue
if ($azCommand) { $AzCmd = $azCommand.Source }
if (-not $AzCmd) { $AzCmd = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd' }
if (-not (Test-Path $AzCmd)) { throw "Azure CLI introuvable. Installez-la ou ajoutez az au PATH." }

function Write-Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "    OK  $Message" -ForegroundColor Green }

<#
  Appelle l'API REST Fabric. Bascule ErrorActionPreference en Continue pendant
  l'appel natif : sinon PowerShell transforme toute ligne stderr d'az.cmd en erreur
  terminante (cf. journal P1).
#>
function Invoke-Fabric {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        [object] $Body
    )

    $url    = "$FabricApi/$($Path.TrimStart('/'))"
    $azArgs = @('rest', '--method', $Method, '--url', $url, '--resource', $FabricResource, '--output', 'json')

    $tmp = $null
    if ($null -ne $Body) {
        $tmp = [System.IO.Path]::GetTempFileName()
        ($Body | ConvertTo-Json -Depth 20 -Compress) | Set-Content -Path $tmp -Encoding ascii -NoNewline
        $azArgs += @('--headers', 'Content-Type=application/json', '--body', "@$tmp")
    }

    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = (& $AzCmd @azArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    }
    finally {
        $ErrorActionPreference = $previous
        if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Force }
    }

    if ($LASTEXITCODE -ne 0) { throw "Fabric API $Method $Path a echoue :`n$raw" }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

# Recupere un item de workspace par nom, ou $null.
function Get-FabricItem {
    param(
        [Parameter(Mandatory)] [string] $WorkspaceId,
        [Parameter(Mandatory)] [string] $Collection,   # eventhouses | kqlDatabases | eventstreams | notebooks
        [Parameter(Mandatory)] [string] $DisplayName
    )
    $list = Invoke-Fabric -Method get -Path "workspaces/$WorkspaceId/$Collection"
    if (-not $list -or -not $list.value) { return $null }
    return $list.value | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1
}

# ---------------------------------------------------------------- 1. Capacite
Write-Step "Resolution de la capacite '$CapacityName'"
$capacities = Invoke-Fabric -Method get -Path 'capacities'
$capacity   = $capacities.value | Where-Object { $_.displayName -eq $CapacityName } | Select-Object -First 1
if (-not $capacity) { throw "Capacite '$CapacityName' introuvable." }
if ($capacity.state -ne 'Active') { throw "Capacite '$CapacityName' est dans l'etat '$($capacity.state)'. Demarrez-la avant de continuer." }
Write-Ok "$CapacityName ($($capacity.sku), $($capacity.region)) - id $($capacity.id)"

# --------------------------------------------------------------- 2. Workspace
Write-Step "Workspace '$WorkspaceName'"
$workspaces = Invoke-Fabric -Method get -Path 'workspaces'
$workspace  = $workspaces.value | Where-Object { $_.displayName -eq $WorkspaceName } | Select-Object -First 1

if ($workspace) {
    Write-Ok "deja present - id $($workspace.id)"
}
else {
    $workspace = Invoke-Fabric -Method post -Path 'workspaces' -Body @{
        displayName = $WorkspaceName
        description = 'Demo Fabric Real-Time Intelligence x Azure Machine Learning'
        capacityId  = $capacity.id
    }
    Write-Ok "cree - id $($workspace.id)"
}
$workspaceId = $workspace.id

$assignedCapacity = $workspace.PSObject.Properties['capacityId']
if (-not $assignedCapacity -or $assignedCapacity.Value -ne $capacity.id) {
    Write-Step "Rattachement du workspace a la capacite"
    Invoke-Fabric -Method post -Path "workspaces/$workspaceId/assignToCapacity" -Body @{ capacityId = $capacity.id } | Out-Null
    Write-Ok "rattache a $CapacityName"
}

# -------------------------------------------------------------- 3. Eventhouse
Write-Step "Eventhouse '$EventhouseName'"
$eventhouse = Get-FabricItem -WorkspaceId $workspaceId -Collection 'eventhouses' -DisplayName $EventhouseName

if ($eventhouse) {
    Write-Ok "deja present - id $($eventhouse.id)"
}
else {
    Invoke-Fabric -Method post -Path "workspaces/$workspaceId/eventhouses" -Body @{
        displayName = $EventhouseName
        description = 'Eventhouse des telemetries capteurs'
    } | Out-Null

    # La creation peut etre asynchrone (202) : on repolle jusqu'a apparition de l'item.
    for ($i = 0; $i -lt 30 -and -not $eventhouse; $i++) {
        Start-Sleep -Seconds 5
        $eventhouse = Get-FabricItem -WorkspaceId $workspaceId -Collection 'eventhouses' -DisplayName $EventhouseName
    }
    if (-not $eventhouse) { throw "Eventhouse '$EventhouseName' non visible apres creation." }
    Write-Ok "cree - id $($eventhouse.id)"
}
$eventhouseId = $eventhouse.id

# ------------------------------------------------------------ 4. KQL Database
Write-Step "KQL Database '$DatabaseName'"
$database = Get-FabricItem -WorkspaceId $workspaceId -Collection 'kqlDatabases' -DisplayName $DatabaseName

if ($database) {
    Write-Ok "deja presente - id $($database.id)"
}
else {
    Invoke-Fabric -Method post -Path "workspaces/$workspaceId/kqlDatabases" -Body @{
        displayName     = $DatabaseName
        description     = 'Base KQL : telemetry + scoring_results'
        creationPayload = @{
            databaseType           = 'ReadWrite'
            parentEventhouseItemId = $eventhouseId
        }
    } | Out-Null
    for ($i = 0; $i -lt 30 -and -not $database; $i++) {
        Start-Sleep -Seconds 5
        $database = Get-FabricItem -WorkspaceId $workspaceId -Collection 'kqlDatabases' -DisplayName $DatabaseName
    }
    if (-not $database) { throw "KQL Database '$DatabaseName' non visible apres creation." }
    Write-Ok "creee - id $($database.id)"
}

# Les URI de service vivent dans les proprietes detaillees de la base.
$databaseDetail = Invoke-Fabric -Method get -Path "workspaces/$workspaceId/kqlDatabases/$($database.id)"
$queryUri       = $databaseDetail.properties.queryServiceUri
$ingestionUri   = $databaseDetail.properties.ingestionServiceUri

# ----------------------------------------------------------------- 5. Resume
Write-Host "`n--- SUMMARY (a reporter dans docs/PROGRESS.md) ---" -ForegroundColor Yellow
[pscustomobject][ordered]@{
    capacityName    = $CapacityName
    capacityId      = $capacity.id
    workspaceName   = $WorkspaceName
    workspaceId     = $workspaceId
    eventhouseName  = $EventhouseName
    eventhouseId    = $eventhouseId
    databaseName    = $DatabaseName
    databaseId      = $database.id
    queryUri        = $queryUri
    ingestionUri    = $ingestionUri
    onelakeAbfss    = "abfss://$WorkspaceName@onelake.dfs.fabric.microsoft.com/$EventhouseName.Eventhouse/Tables/telemetry"
} | Format-List

Write-Host "Etape suivante : appliquer fabric/kql/01_create_tables.kql sur $queryUri (base '$DatabaseName')." -ForegroundColor Yellow
