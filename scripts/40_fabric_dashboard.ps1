<#
.SYNOPSIS
    P6 - Publie fabric/dashboard/rti_dashboard.json comme Real-Time Dashboard Fabric.

.DESCRIPTION
    Le dashboard vit dans le repo (source de verite) et est pousse vers Fabric par
    l'API REST, comme le notebook. Toute retouche faite dans le portail sera ecrasee
    au prochain passage de ce script.

    Contraintes de l'API (verifiees sur Microsoft Learn, ne pas "corriger") :
      - collection      : workspaces/{id}/kqlDashboards
      - definition.parts: chemin EXACT "RealTimeDashboard.json"
      - payloadType     : InlineBase64

    Le JSON embarque l'URI du cluster et le nom de la base. Le script les reecrit
    a partir de l'Eventhouse reellement present dans le workspace, pour que le
    fichier reste juste meme si la capacite est recreee ailleurs.

    VERIFICATION FINALE, non negociable : un 202 Fabric n'est PAS un succes. Quand
    une definition est refusee, l'item est cree puis ANNULE quelques secondes plus
    tard, sans message - c'est ce qui s'etait produit avec es-sensors. Le script
    relit donc l'item apres coup et echoue bruyamment s'il a disparu.

    NOTE : fichier volontairement en ASCII pur - Windows PowerShell 5.1 lit les
    scripts en ANSI et casse sur les caracteres accentues.

.NOTES
    Prerequis : az login --tenant <AZURE_TENANT_ID>
                capacite Fabric demarree (sinon le workspace est inaccessible)
#>

[CmdletBinding()]
param(
    [string] $WorkspaceName  = (& "$PSScriptRoot\lib\cfg.ps1" FABRIC_WORKSPACE -Required),
    [string] $DashboardName  = 'rti-aml-scoring',
    [string] $DashboardPath  = 'fabric/dashboard/rti_dashboard.json',
    [string] $DatabaseName   = (& "$PSScriptRoot\lib\cfg.ps1" KQL_DATABASE -Default 'sensors')
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\fabric.ps1"

function Write-Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "    OK  $Message" -ForegroundColor Green }

Connect-Fabric

# ------------------------------------------------------------ 1. Workspace
Write-Step "[1/5] Resolution du workspace '$WorkspaceName'"

$workspaces = Invoke-Fabric -Method get -Path 'workspaces'
$workspace  = $workspaces.value | Where-Object { $_.displayName -eq $WorkspaceName } | Select-Object -First 1
if (-not $workspace) { throw "Workspace '$WorkspaceName' introuvable. Lancez d'abord scripts\10_fabric_rti.ps1." }
$workspaceId = $workspace.id
Write-Ok "workspace $workspaceId"

# ------------------------------------------------- 2. Cluster de l'Eventhouse
Write-Step "[2/5] Resolution de l'Eventhouse et de la base '$DatabaseName'"

$databases = Invoke-Fabric -Method get -Path "workspaces/$workspaceId/kqlDatabases"
$database  = $databases.value | Where-Object { $_.displayName -eq $DatabaseName } | Select-Object -First 1
if (-not $database) { throw "Base KQL '$DatabaseName' introuvable dans le workspace." }

$clusterUri = $database.properties.queryServiceUri
if ([string]::IsNullOrWhiteSpace($clusterUri)) {
    throw "Impossible de lire queryServiceUri sur la base '$DatabaseName'."
}
Write-Ok "base $($database.id)"
Write-Ok "cluster $clusterUri"

# ------------------------------------------------------------ 3. Definition
Write-Step "[3/5] Lecture de $DashboardPath"

$resolved = Resolve-Path $DashboardPath
$content  = Get-Content -Path $resolved -Raw

# Valide le JSON avant l'envoi : une erreur ici est bien plus lisible qu'un rejet Fabric.
$parsed = $content | ConvertFrom-Json
Write-Ok "JSON valide - $($parsed.tiles.Count) tuile(s), $($parsed.queries.Count) requete(s)"

# Realigne la source de donnees sur ce qui existe vraiment.
foreach ($source in $parsed.dataSources) {
    $source.clusterUri = $clusterUri
    $source.database   = $DatabaseName
}
$content = $parsed | ConvertTo-Json -Depth 40

$definition = @{
    parts = @(
        @{
            path        = 'RealTimeDashboard.json'
            payload     = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content))
            payloadType = 'InlineBase64'
        }
    )
}

# ------------------------------------------------------------ 4. Publication
Write-Step "[4/5] Dashboard '$DashboardName'"

$dashboard = Get-FabricItemByName -Path "workspaces/$workspaceId/kqlDashboards" -DisplayName $DashboardName

if ($dashboard) {
    Invoke-Fabric -Method post -Path "workspaces/$workspaceId/kqlDashboards/$($dashboard.id)/updateDefinition" -Body @{
        definition = $definition
    } | Out-Null
    Write-Ok "definition mise a jour (id $($dashboard.id))"
}
else {
    $created = Invoke-Fabric -Method post -Path "workspaces/$workspaceId/kqlDashboards" -Body @{
        displayName = $DashboardName
        description = 'P6 - Sante de la chaine, prediction vs realite, blue/green, MAE'
        definition  = $definition
    }

    $dashboard = $created
    if (-not $dashboard -or -not $dashboard.id) {
        $dashboard = Get-FabricItemByName -Path "workspaces/$workspaceId/kqlDashboards" -DisplayName $DashboardName
    }
    if (-not $dashboard) { throw "Dashboard '$DashboardName' introuvable apres creation." }
    Write-Ok "cree - id $($dashboard.id)"
}

# ------------------------------------- 5. L'item a-t-il SURVECU a sa creation ?
Write-Step "[5/5] Verification que l'item existe toujours"

Start-Sleep -Seconds 10
$check = Get-FabricItemByName -Path "workspaces/$workspaceId/kqlDashboards" -DisplayName $DashboardName
if (-not $check) {
    throw "Le dashboard a disparu apres creation : Fabric a refuse la definition. " +
          "Exportez un dashboard depuis le portail et comparez le schema avec $DashboardPath."
}
Write-Ok "toujours present 10 s apres (id $($check.id))"

# ------------------------------------------------------------------ Resume
Write-Host "`n--- SUMMARY (a reporter dans docs/PROGRESS.md) ---" -ForegroundColor Yellow
[pscustomobject][ordered]@{
    workspaceId   = $workspaceId
    dashboardName = $DashboardName
    dashboardId   = $check.id
    clusterUri    = $clusterUri
    database      = $DatabaseName
    source        = $DashboardPath
} | Format-List

Write-Host "Ouvrir : https://app.fabric.microsoft.com/groups/$workspaceId" -ForegroundColor Yellow
Write-Host "La tuile 0 repond en une seconde a 'est-ce que ca tourne ?'."   -ForegroundColor Yellow
