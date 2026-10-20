<#
.SYNOPSIS
    P3 - Publie les notebooks du repo (01 et 04 par defaut) dans le workspace Fabric.

.DESCRIPTION
    Les notebooks vivent dans le repo (source de verite) et sont pousses vers Fabric par
    l'API REST. Le portail sert a les executer, pas a les editer : toute modification
    faite en ligne serait ecrasee au prochain passage de ce script.

    Les constantes d'en-tete (WORKSPACE_ID, KQL_DATABASE_ID, STORAGE_ACCOUNT, FILESYSTEM,
    ...) sont remplacees a l'envoi par les valeurs de demo.config.env. Le fichier du repo
    n'est jamais modifie. Lancez donc 10_fabric_rti.ps1 puis 00_bootstrap.ps1 avant.

    Contraintes de l'API (verifiees sur Microsoft Learn, ne pas "corriger") :
      - definition.format doit valoir "ipynb" ;
      - le chemin de la partie doit etre EXACTEMENT "artifact.content.ipynb".
        Toute autre valeur fait echouer la creation ;
      - la creation est asynchrone (202) : on passe par scripts\lib\fabric.ps1
        qui suit l'operation jusqu'a son verdict.

    NOTE : fichier volontairement en ASCII pur - Windows PowerShell 5.1 lit les
    scripts en ANSI et casse sur les caracteres accentues.

.EXAMPLE
    .\scripts\14_fabric_notebook.ps1
    .\scripts\14_fabric_notebook.ps1 -Notebooks 04_snapshot_versioned

.NOTES
    Prerequis : az login --tenant <AZURE_TENANT_ID>
#>

[CmdletBinding()]
param(
    [string]   $WorkspaceName = (& "$PSScriptRoot\lib\cfg.ps1" FABRIC_WORKSPACE -Required),
    # Noms de fichiers sous fabric/notebooks/ (sans .ipynb). Le nom Fabric = le nom du fichier.
    [string[]] $Notebooks     = @('01_snapshot_to_datastore', '04_snapshot_versioned')
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\fabric.ps1"
. "$PSScriptRoot\lib\notebook.ps1"

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

# Le workspace existe : son id fait foi, meme si demo.config.env n'etait pas a jour.
$constants = Get-NotebookConstantValues
$constants['WORKSPACE_ID'] = $workspaceId

$summary = @()
foreach ($NotebookName in $Notebooks) {
    $NotebookPath = "fabric/notebooks/$NotebookName.ipynb"

    # ------------------------------------------------------------ 2. Definition
    Write-Step "Lecture de $NotebookPath"
    $resolved = Resolve-Path $NotebookPath
    $content  = Get-Content -Path $resolved -Raw -Encoding UTF8

    # Valide le JSON avant l'envoi : une erreur ici est plus lisible qu'un rejet Fabric.
    $parsed = $content | ConvertFrom-Json
    Write-Ok "notebook valide - $($parsed.cells.Count) cellule(s)"

    $replaced = Set-NotebookConstants -Notebook $parsed -Values $constants
    if ($replaced.Count -gt 0) {
        Write-Ok "constantes remplacees depuis demo.config.env : $($replaced -join ', ')"
        $content = $parsed | ConvertTo-Json -Depth 50 -Compress
    }

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
            description = "RTI x AML - $NotebookName"
            definition  = $definition
        }

        $notebook = $created
        if (-not $notebook -or -not $notebook.id) {
            $notebook = Get-FabricItemByName -Path "workspaces/$workspaceId/notebooks" -DisplayName $NotebookName
        }
        if (-not $notebook) { throw "Notebook '$NotebookName' introuvable apres creation." }
        Write-Ok "cree - id $($notebook.id)"
    }

    $summary += [pscustomobject][ordered]@{ notebookName = $NotebookName; notebookId = $notebook.id; source = $NotebookPath }
}

# ------------------------------------------------------------------ 4. Resume
Write-Host "`n--- SUMMARY (a reporter dans docs/PROGRESS.md) ---" -ForegroundColor Yellow
$summary | Format-Table -AutoSize

Write-Host "Etape suivante : ouvrir le notebook dans Fabric et l'executer (Run all)." -ForegroundColor Yellow
Write-Host "  - 01_snapshot_to_datastore : piste A (snapshot v1), puis az ml data create -f aml/data/data-asset.yml" -ForegroundColor Yellow
Write-Host "  - 04_snapshot_versioned    : piste C (snapshot fige + manifeste, a rejouer a chaque nouvelle version)" -ForegroundColor Yellow
