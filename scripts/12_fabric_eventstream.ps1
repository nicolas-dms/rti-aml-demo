<#
.SYNOPSIS
    P2 - Cree l'Eventstream "es-sensors" et recupere la connexion du Custom endpoint.

.DESCRIPTION
    Topologie poussee (fabric/eventstream/eventstream.json) :

        [CustomEndpoint] --> [es-sensors-stream] --> [Eventhouse eh-sensors / sensors.telemetry]

    Le mode d'ingestion est "ProcessedIngestion" : il route directement vers
    databaseName / tableName et ne demande AUCUNE connexion cloud a creer au
    prealable, contrairement au mode "DirectIngestion" qui exige connectionName +
    mappingRuleName. C'est le chemin le plus court pour la demo.

    Le CLI "Microsoft.Fabric.Mcp" 1.0.0 ne sait pas pousser d'item definition :
    on passe par l'API REST Fabric, via scripts\lib\fabric.ps1 qui SUIT les
    operations asynchrones. C'est indispensable ici : la creation d'un Eventstream
    renvoie 202, et une definition refusee fait annuler l'item quelques secondes
    plus tard. Sans ce suivi, on croit avoir reussi et l'item disparait en silence.

    Par defaut seule la partie eventstream.json est poussee (definition minimale
    suffisante). -IncludeProperties ajoute retention et debit, optionnels ici.

    A la fin, la chaine de connexion du Custom endpoint est ecrite dans le fichier
    .env (git-ignore) et JAMAIS affichee a l'ecran.

    NOTE : fichier volontairement en ASCII pur - Windows PowerShell 5.1 lit les
    scripts en ANSI et casse sur les caracteres accentues ou les tirets longs.

.NOTES
    Prerequis : az login --tenant <AZURE_TENANT_ID>
#>

[CmdletBinding()]
param(
    [string] $WorkspaceName    = (& "$PSScriptRoot\lib\cfg.ps1" FABRIC_WORKSPACE -Required),
    [string] $EventhouseName   = (& "$PSScriptRoot\lib\cfg.ps1" EVENTHOUSE -Default 'eh-sensors'),
    [string] $DatabaseName     = (& "$PSScriptRoot\lib\cfg.ps1" KQL_DATABASE -Default 'sensors'),
    [string] $TableName        = 'telemetry',
    [string] $EventstreamName  = (& "$PSScriptRoot\lib\cfg.ps1" EVENTSTREAM -Default 'es-sensors'),
    [string] $DefinitionPath   = 'fabric/eventstream/eventstream.json',
    [string] $PropertiesPath   = 'fabric/eventstream/eventstreamProperties.json',
    [string] $EnvFile          = '.env',
    [int]    $SourceReadyTimeoutSeconds = 300,
    [switch] $IncludeProperties
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\fabric.ps1"

function Write-Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "    OK  $Message" -ForegroundColor Green }

function ConvertTo-Base64 {
    param([Parameter(Mandatory)] [string] $Text)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
}

# Cherche recursivement une chaine de connexion Event Hub dans une reponse JSON,
# quelle que soit sa profondeur. On la reconnait a sa FORME, pas a son chemin :
# la structure exacte varie selon le type de source Eventstream.
function Find-ConnectionString {
    param($Node, [int] $Depth = 0)

    if ($null -eq $Node -or $Depth -gt 6) { return $null }

    if ($Node -is [string]) {
        if ($Node -match '^Endpoint=sb://') { return $Node }
        return $null
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in $Node) {
            $found = Find-ConnectionString -Node $item -Depth ($Depth + 1)
            if ($found) { return $found }
        }
        return $null
    }
    if ($Node.PSObject -and $Node.PSObject.Properties) {
        foreach ($property in $Node.PSObject.Properties) {
            $found = Find-ConnectionString -Node $property.Value -Depth ($Depth + 1)
            if ($found) { return $found }
        }
    }
    return $null
}

# Renvoie la valeur de la premiere propriete non vide parmi $Names.
function Select-FirstProperty {
    param($Node, [string[]] $Names)

    if ($null -eq $Node) { return $null }
    foreach ($name in $Names) {
        $property = $Node.PSObject.Properties[$name]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string] $property.Value)) {
            return [string] $property.Value
        }
    }
    return $null
}

Connect-Fabric

# ------------------------------------------------------- 1. Resolution des ids
Write-Step "Resolution du workspace '$WorkspaceName', de l'Eventhouse '$EventhouseName' et de la base '$DatabaseName'"

$workspaces = Invoke-Fabric -Method get -Path 'workspaces'
$workspace  = $workspaces.value | Where-Object { $_.displayName -eq $WorkspaceName } | Select-Object -First 1
if (-not $workspace) { throw "Workspace '$WorkspaceName' introuvable. Lancez d'abord scripts\10_fabric_rti.ps1." }
$workspaceId = $workspace.id

$eventhouses = Invoke-Fabric -Method get -Path "workspaces/$workspaceId/eventhouses"
$eventhouse  = $eventhouses.value | Where-Object { $_.displayName -eq $EventhouseName } | Select-Object -First 1
if (-not $eventhouse) { throw "Eventhouse '$EventhouseName' introuvable." }

# La destination Eventhouse attend l'id de la KQL DATABASE, pas celui de l'Eventhouse :
# c'est l'item KQL Database qui porte l'URL du cluster. Avec l'id de l'Eventhouse,
# Fabric refuse la definition (EventStreamBadWebRequest : "Unable to extract cluster URL").
$databases = Invoke-Fabric -Method get -Path "workspaces/$workspaceId/kqlDatabases"
$database  = $databases.value | Where-Object { $_.displayName -eq $DatabaseName } | Select-Object -First 1
if (-not $database) {
    $known = ($databases.value | ForEach-Object { $_.displayName }) -join ', '
    throw "KQL Database '$DatabaseName' introuvable dans le workspace. Bases presentes : $known"
}

Write-Ok "workspace $workspaceId / eventhouse $($eventhouse.id) / kqlDatabase $($database.id)"

# ------------------------------------------------- 2. Construction de la definition
Write-Step "Construction de la definition depuis $DefinitionPath"

$topology = (Get-Content -Path (Resolve-Path $DefinitionPath) -Raw)
$topology = $topology.Replace('__WORKSPACE_ID__',           $workspaceId)
$topology = $topology.Replace('__KQL_DATABASE_ITEM_ID__',   $database.id)
$topology = $topology.Replace('__DATABASE_NAME__',          $DatabaseName)
$topology = $topology.Replace('__TABLE_NAME__',             $TableName)

if ($topology -match '__[A-Z_]+__') {
    throw "Des placeholders n'ont pas ete substitues dans $DefinitionPath : $($Matches[0])"
}
# Valide le JSON avant de l'envoyer : une erreur ici est bien plus lisible qu'un 400 Fabric.
$null = $topology | ConvertFrom-Json

$parts = @(
    @{ path = 'eventstream.json'; payload = (ConvertTo-Base64 $topology); payloadType = 'InlineBase64' }
)
if ($IncludeProperties -and (Test-Path $PropertiesPath)) {
    $properties = (Get-Content -Path (Resolve-Path $PropertiesPath) -Raw)
    $parts += @{ path = 'eventstreamProperties.json'; payload = (ConvertTo-Base64 $properties); payloadType = 'InlineBase64' }
}
Write-Ok "$($parts.Count) partie(s) : $(($parts | ForEach-Object { $_.path }) -join ', ')"

# ---------------------------------------------------- 3. Creation de l'Eventstream
Write-Step "Eventstream '$EventstreamName'"

$eventstreams = Invoke-Fabric -Method get -Path "workspaces/$workspaceId/eventstreams"
$eventstream  = $eventstreams.value | Where-Object { $_.displayName -eq $EventstreamName } | Select-Object -First 1

if ($eventstream) {
    Write-Ok "deja present - mise a jour de la definition (id $($eventstream.id))"
    Invoke-Fabric -Method post -Path "workspaces/$workspaceId/eventstreams/$($eventstream.id)/updateDefinition" -Body @{
        definition = @{ parts = $parts }
    } | Out-Null
    Write-Ok "definition mise a jour"
}
else {
    # Invoke-Fabric attend le verdict de l'operation asynchrone : une definition
    # refusee remonte ici comme une erreur explicite.
    $created = Invoke-Fabric -Method post -Path "workspaces/$workspaceId/eventstreams" -Body @{
        displayName = $EventstreamName
        description = 'Ingestion temps reel des capteurs vers eh-sensors'
        definition  = @{ parts = $parts }
    }

    $eventstream = $created
    if (-not $eventstream -or -not $eventstream.id) {
        $eventstream = Get-FabricItemByName -Path "workspaces/$workspaceId/eventstreams" -DisplayName $EventstreamName
    }
    if (-not $eventstream) { throw "Eventstream '$EventstreamName' introuvable apres creation." }
    Write-Ok "cree - id $($eventstream.id)"
}
$eventstreamId = $eventstream.id

# Filet de securite : une definition refusee fait annuler l'item quelques secondes plus tard.
Start-Sleep -Seconds 10
if (-not (Get-FabricItemByName -Path "workspaces/$workspaceId/eventstreams" -DisplayName $EventstreamName)) {
    throw "L'Eventstream a disparu : la definition a ete rejetee par Fabric."
}
Write-Ok 'item toujours present 10 s apres ecriture de la definition'

# --------------------------------------- 4. Connexion du Custom endpoint (SECRET)
Write-Step "Recuperation de la connexion du Custom endpoint"

# La source est provisionnee de facon asynchrone : tant que son statut vaut
# 'Creating', l'Event Hub sous-jacent n'existe pas encore et /connection repond 404.
# On attend donc qu'elle soit prete avant de demander la chaine de connexion.
$deadline = (Get-Date).AddSeconds($SourceReadyTimeoutSeconds)
$source   = $null

while ($true) {
    $topologyLive = Invoke-Fabric -Method get -Path "workspaces/$workspaceId/eventstreams/$eventstreamId/topology"
    $source       = $topologyLive.sources | Where-Object { $_.type -eq 'CustomEndpoint' } | Select-Object -First 1
    if (-not $source) {
        $found = ($topologyLive.sources | ForEach-Object { "$($_.name) ($($_.type))" }) -join ', '
        throw "Aucune source CustomEndpoint dans la topologie. Sources presentes : $found"
    }

    if ($source.status -eq 'Creating') {
        if ((Get-Date) -ge $deadline) {
            throw "La source '$($source.name)' est restee en statut 'Creating' au-dela de $SourceReadyTimeoutSeconds s."
        }
        Write-Host "    source '$($source.name)' - statut Creating, nouvelle verification dans 10 s..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
        continue
    }

    if ($source.status -match 'Fail|Error') {
        throw "La source '$($source.name)' est en statut '$($source.status)'."
    }
    break
}
Write-Ok "source '$($source.name)' - statut $($source.status)"

# Meme apres le passage hors 'Creating', l'endpoint peut mettre quelques secondes
# a etre disponible : on retente sur 404 uniquement, toute autre erreur remonte.
$connectionPath = "workspaces/$workspaceId/eventstreams/$eventstreamId/sources/$($source.id)/connection"
$connection     = $null

while (-not $connection) {
    try {
        $connection = Invoke-Fabric -Method get -Path $connectionPath
    }
    catch {
        if ($_.Exception.Message -notmatch 'HTTP 404') { throw }
        if ((Get-Date) -ge $deadline) {
            throw "La connexion du Custom endpoint repond toujours 404 apres $SourceReadyTimeoutSeconds s."
        }
        Write-Host '    connexion pas encore exposee (404), nouvelle tentative dans 10 s...' -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }
}

$connectionString = $null
$eventHubName     = $null
if ($connection.PSObject.Properties['eventHubName']) { $eventHubName = $connection.eventHubName }

# 1er choix : Fabric fournit parfois directement une chaine complete, a une
# profondeur qui varie selon le type de source. On la cherche par sa forme
# (Endpoint=sb://...) plutot que par un chemin devine.
$connectionString = Find-ConnectionString -Node $connection

# 2e choix : reconstruire la chaine a partir des morceaux renvoyes
# (type / fullyQualifiedNamespace / eventHubName / accessKeys).
if (-not $connectionString -and $connection.PSObject.Properties['fullyQualifiedNamespace'] -and $eventHubName) {
    $keys = $connection.accessKeys
    if ($keys) {
        $keyName = Select-FirstProperty -Node $keys -Names @('keyName', 'sharedAccessKeyName', 'primaryKeyName', 'name')
        $keyValue = Select-FirstProperty -Node $keys -Names @('primaryKey', 'key', 'primaryConnectionStringKey', 'secondaryKey')
        if (-not $keyName) { $keyName = 'RootManageSharedAccessKey' }
        if ($keyValue) {
            $connectionString = "Endpoint=sb://$($connection.fullyQualifiedNamespace)/;SharedAccessKeyName=$keyName;SharedAccessKey=$keyValue;EntityPath=$eventHubName"
            Write-Ok "chaine reconstruite depuis fullyQualifiedNamespace + accessKeys (policy '$keyName')"
        }
    }
}

if (-not $connectionString) {
    Write-Host "    Impossible d'extraire ou de reconstruire la chaine de connexion." -ForegroundColor Yellow
    # On n'affiche que les NOMS de proprietes, jamais les valeurs (secrets).
    Write-Host "    Proprietes racine de la reponse : $(($connection.PSObject.Properties.Name) -join ', ')" -ForegroundColor Yellow
    if ($connection.PSObject.Properties['accessKeys'] -and $connection.accessKeys) {
        Write-Host "    Proprietes de accessKeys : $(($connection.accessKeys.PSObject.Properties.Name) -join ', ')" -ForegroundColor Yellow
    }
    Write-Host "    Repli : portail Fabric > Eventstream > custom-endpoint > Event Hub > Connection string-primary key." -ForegroundColor Yellow
}
else {
    # Le secret va dans .env (git-ignore) et n'est jamais affiche.
    $lines = @()
    if (Test-Path $EnvFile) {
        $lines = Get-Content -Path $EnvFile | Where-Object {
            $_ -notmatch '^\s*EVENTSTREAM_CONNECTION_STRING\s*=' -and
            $_ -notmatch '^\s*EVENTSTREAM_EVENTHUB_NAME\s*='
        }
    }
    $lines += "EVENTSTREAM_CONNECTION_STRING=$connectionString"
    if ($eventHubName) { $lines += "EVENTSTREAM_EVENTHUB_NAME=$eventHubName" }
    Set-Content -Path $EnvFile -Value $lines -Encoding ascii

    Write-Ok "chaine de connexion ecrite dans $EnvFile (non affichee)"
}

# ------------------------------------------------------------------ 5. Resume
Write-Host "`n--- SUMMARY (a reporter dans docs/PROGRESS.md) ---" -ForegroundColor Yellow
[pscustomobject][ordered]@{
    workspaceId      = $workspaceId
    eventstreamName  = $EventstreamName
    eventstreamId    = $eventstreamId
    sourceType       = 'CustomEndpoint'
    destination      = "$EventhouseName / $DatabaseName.$TableName (ProcessedIngestion)"
    envFile          = $EnvFile
} | Format-List

Write-Host "Etape suivante : pip install -r simulator/requirements.txt puis python simulator/sensor_producer.py" -ForegroundColor Yellow
