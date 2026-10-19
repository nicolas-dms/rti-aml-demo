<#
.SYNOPSIS
    P3 - Publie fabric/notebooks/01_snapshot_to_datastore.ipynb dans le workspace Fabric.

.DESCRIPTION
    Le notebook vit dans le repo (source de verite) et est pousse vers Fabric par
    l'API REST. Le portail sert a l'executer, pas a l'editer : toute modification
    faite en ligne serait ecrasee au prochain passage de ce script.

    Contraintes de l'API (verifiees sur Microsoft Learn, ne pas "corriger") :
      - definition.format doit valoir "ipynb" ;
      - le chemin de la partie doit etre EXACTEMENT "artifact.content.ipynb".
        Toute autre valeur fait echouer la creation ;
      - la creation est asynchrone (202) : on passe par scripts\lib\fabric.ps1
        qui suit l'operation jusqu'a son verdict.

    NOTE : fichier volontairement en ASCII pur - Windows PowerShell 5.1 lit les
    scripts en ANSI et casse sur les caracteres accentues.

.NOTES
    Prerequis : az login --tenant <TENANT_ID>
#>

[CmdletBinding()]
param(
    [string] $WorkspaceName  = 'ws-rti-aml-demo',
    [string] $NotebookName   = '01_snapshot_to_datastore',
    [string] $NotebookPath   = 'fabric/notebooks/01_snapshot_to_datastore.ipynb'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\fabric.ps1"

function Write-Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "    OK  $Message" -ForegroundColor Green }

Connect-Fabric

# ------------------------------------------------------------ 1. Workspace
Write-Step "Resolution du workspace '$WorkspaceName'"

$workspaces = Invoke-Fabric -Method get -Path 'workspaces'
$workspace  = $workspaces.value | Where-Object { $_.displayName -eq $WorkspaceName } | Select-Object -First 1
if (-not $workspace) { throw "Workspace '$WorkspaceName' introuvable. Lancez d'abord scripts\10_fabric_rti.ps1." }
$workspaceId = $workspace.id
Write-Ok "workspace $workspaceId"

# ------------------------------------------------------------ 2. Definition
Write-Step "Lecture de $NotebookPath"

$resolved = Resolve-Path $NotebookPath
$content  = Get-Content -Path $resolved -Raw

# Valide le JSON avant l'envoi : une erreur ici est plus lisible qu'un rejet Fabric.
$parsed = $content | ConvertFrom-Json
Write-Ok "notebook valide - $($parsed.cells.Count) cellule(s)"

$definition = @{
    format = 'ipynb'
    parts  = @(
        @{
            path        = 'artifact.content.ipynb'
            payload     = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content))
            payloadType = 'InlineBase64'
        }
    )
}

# ------------------------------------------------------------ 3. Publication
Write-Step "Notebook '$NotebookName'"

$notebook = Get-FabricItemByName -Path "workspaces/$workspaceId/notebooks" -DisplayName $NotebookName

if ($notebook) {
    Invoke-Fabric -Method post -Path "workspaces/$workspaceId/notebooks/$($notebook.id)/updateDefinition" -Body @{
        definition = $definition
    } | Out-Null
    Write-Ok "definition mise a jour (id $($notebook.id))"
}
else {
    $created = Invoke-Fabric -Method post -Path "workspaces/$workspaceId/notebooks" -Body @{
        displayName = $NotebookName
        description = 'P3 - Snapshot RTI vers le datastore AML rti_snapshots'
        definition  = $definition
    }

    $notebook = $created
    if (-not $notebook -or -not $notebook.id) {
        $notebook = Get-FabricItemByName -Path "workspaces/$workspaceId/notebooks" -DisplayName $NotebookName
    }
    if (-not $notebook) { throw "Notebook '$NotebookName' introuvable apres creation." }
    Write-Ok "cree - id $($notebook.id)"
}

# ------------------------------------------------------------------ 4. Resume
Write-Host "`n--- SUMMARY (a reporter dans docs/PROGRESS.md) ---" -ForegroundColor Yellow
[pscustomobject][ordered]@{
    workspaceId  = $workspaceId
    notebookName = $NotebookName
    notebookId   = $notebook.id
    source       = $NotebookPath
} | Format-List

Write-Host "Etape suivante : ouvrir le notebook dans Fabric et l'executer (Run all)." -ForegroundColor Yellow
Write-Host "Puis : az ml data create -f aml/data/data-asset.yml -g rg-rti-aml-demo -w aml-rti-demo" -ForegroundColor Yellow
