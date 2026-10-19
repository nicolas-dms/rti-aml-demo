<#
.SYNOPSIS
    P7 - Publie le notebook de demo dans Fabric et televerse le pipeline AML.

.DESCRIPTION
    Deux operations indissociables, d'ou un seul script :

      1. Televerse le dossier aml/ du depot vers snapshots/pipeline-source/.
         Le YAML du pipeline reference ses composants par des chemins RELATIFS,
         et un notebook Fabric n'a pas le depot sous la main. Sans cette copie,
         l'etape 2 du notebook echoue sur un fichier introuvable.

      2. Publie fabric/notebooks/02_retrain_and_promote.ipynb comme item Fabric.

    Contraintes de l'API (verifiees, ne pas "corriger") :
      - definition.format doit valoir "ipynb" ;
      - le chemin de la partie doit etre EXACTEMENT "artifact.content.ipynb" ;
      - la creation est asynchrone (202) : lib\fabric.ps1 suit l'operation.

    Le depot reste la source de verite. Toute retouche faite dans le portail sera
    ecrasee au prochain passage de ce script.

    NOTE : fichier volontairement en ASCII pur - Windows PowerShell 5.1 lit les
    scripts en ANSI et casse sur les caracteres accentues.

.NOTES
    Prerequis : az login --tenant <TENANT_ID>
                role Storage Blob Data Contributor sur le compte de stockage
#>

[CmdletBinding()]
param(
    [string] $WorkspaceName = 'ws-rti-aml-demo',
    [string] $NotebookName = '02_retrain_and_promote',
    [string] $NotebookPath = 'fabric/notebooks/02_retrain_and_promote.ipynb',
    [string] $StorageAccount = '<STORAGE_ACCOUNT>',
    [string] $FileSystem = 'snapshots',
    [string] $SourcePrefix = 'pipeline-source',
    [switch] $SkipUpload
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
. "$PSScriptRoot\lib\fabric.ps1"

function Write-Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string] $Message) Write-Host "    OK  $Message" -ForegroundColor Green }

function Invoke-Az {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $errorFile = [System.IO.Path]::GetTempFileName()
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $stdout = & az @Arguments 2> $errorFile
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    $stderr = ''
    if (Test-Path $errorFile) {
        $stderr = (Get-Content -Path $errorFile -Raw)
        Remove-Item -Path $errorFile -Force -ErrorAction SilentlyContinue
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = ($stdout | Out-String)
        StdErr   = $stderr
    }
}

# --------------------------------------------------- 1. Pipeline source upload
if ($SkipUpload) {
    Write-Step '[1/3] Televersement du pipeline ignore (-SkipUpload)'
}
else {
    Write-Step "[1/3] Televersement de aml/ vers $FileSystem/$SourcePrefix/aml"

    if (-not (Test-Path 'aml/pipelines/training_pipeline.yml')) {
        throw "aml/pipelines/training_pipeline.yml introuvable. Lancez ce script depuis le depot."
    }

    # --auth-mode login : jeton Entra, jamais de cle. Le compte a
    # allowSharedKeyAccess=false, donc le mode par defaut echouerait de toute facon.
    # --recursive redescend prep.py/train.py/... dont le SDK a besoin pour archiver
    # le code de chaque composant.
    $result = Invoke-Az -Arguments @(
        'storage', 'fs', 'directory', 'upload',
        '--account-name', $StorageAccount,
        '--file-system', $FileSystem,
        '--source', 'aml',
        '--destination-path', "$SourcePrefix/aml",
        '--recursive',
        '--auth-mode', 'login',
        '--output', 'none'
    )
    if ($result.ExitCode -ne 0) {
        throw "Televersement en echec (exit $($result.ExitCode)) :`n$($result.StdErr)"
    }
    Write-Ok "aml/ televerse sous $SourcePrefix/aml"
}

# ------------------------------------------------------------ 2. Workspace
Write-Step "[2/3] Resolution du workspace '$WorkspaceName'"

Connect-Fabric

$workspaces = Invoke-Fabric -Method get -Path 'workspaces'
$workspace = $workspaces.value | Where-Object { $_.displayName -eq $WorkspaceName } | Select-Object -First 1
if (-not $workspace) { throw "Workspace '$WorkspaceName' introuvable. Lancez d'abord scripts\10_fabric_rti.ps1." }
$workspaceId = $workspace.id
Write-Ok "workspace $workspaceId"

# ------------------------------------------------------------ 3. Publication
Write-Step "[3/3] Notebook '$NotebookName'"

$resolved = Resolve-Path $NotebookPath
$content = Get-Content -Path $resolved -Raw

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
        description = 'P7 - Pousser des donnees, reentrainer, promouvoir en blue/green'
        definition  = $definition
    }

    $notebook = $created
    if (-not $notebook -or -not $notebook.id) {
        $notebook = Get-FabricItemByName -Path "workspaces/$workspaceId/notebooks" -DisplayName $NotebookName
    }
    if (-not $notebook) { throw "Notebook '$NotebookName' introuvable apres creation." }
    Write-Ok "cree - id $($notebook.id)"
}

# Un 202 Fabric n'est PAS un succes : une definition refusee fait creer puis
# ANNULER l'item quelques secondes plus tard, sans message. C'est ce qui s'etait
# produit avec es-sensors. On relit donc l'item apres coup.
Start-Sleep -Seconds 10
$check = Get-FabricItemByName -Path "workspaces/$workspaceId/notebooks" -DisplayName $NotebookName
if (-not $check) {
    throw "Le notebook a disparu apres publication : Fabric a rejete la definition."
}
Write-Ok 'toujours present apres 10 s'

# ------------------------------------------------------------------ Resume
Write-Host "`n--- SUMMARY (a reporter dans docs/PROGRESS.md) ---" -ForegroundColor Yellow
[pscustomobject][ordered]@{
    workspaceId    = $workspaceId
    notebookName   = $NotebookName
    notebookId     = $check.id
    source         = $NotebookPath
    pipelineSource = "$FileSystem/$SourcePrefix/aml"
} | Format-List

Write-Host "Ouvrir : https://app.fabric.microsoft.com/groups/$workspaceId" -ForegroundColor Yellow
Write-Host "Avant d'executer, relancer le simulateur en regime modifie :" -ForegroundColor Yellow
Write-Host "  python simulator/sensor_producer.py --thermal-gain 40 --ambient-offset 5 --backfill-minutes 240" -ForegroundColor Yellow
