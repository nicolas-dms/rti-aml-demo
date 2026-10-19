<#
.SYNOPSIS
    Applique un ou plusieurs fichiers .kql sur une base Eventhouse / Azure Data Explorer.

.DESCRIPTION
    Le MCP Kusto d'Azure MCP refuse les commandes de controle ("Management command
    '.create' is not allowed in queries for security reasons"). On passe donc par
    l'endpoint de management natif du cluster :

        POST {ClusterUri}/v1/rest/mgmt
        { "db": "<database>", "csl": "<commande>" }

    Le script decoupe le fichier en commandes individuelles :
      - les lignes de commentaire "//" hors bloc sont ignorees ;
      - une nouvelle commande demarre a chaque ligne commencant par "." en colonne 0,
        sauf a l'interieur d'un bloc delimite par des triples backquotes.

    Idempotent tant que les fichiers .kql le sont (.create-merge / .create-or-alter / .alter).

    NOTE : fichier volontairement en ASCII pur - Windows PowerShell 5.1 lit les
    scripts en ANSI et casse sur les caracteres accentues ou les tirets longs.

.EXAMPLE
    .\scripts\11_apply_kql.ps1 -Files fabric\kql\01_create_tables.kql

.NOTES
    Prerequis : az login --tenant <TENANT_ID>
#>

[CmdletBinding()]
param(
    [string]   $ClusterUri = 'https://<EVENTHOUSE_HOST>.z7.kusto.fabric.microsoft.com',
    [string]   $Database   = 'sensors',
    [string[]] $Files      = @('fabric/kql/01_create_tables.kql'),
    # Audience du token. Vide = decouverte automatique (recommande).
    [string]   $Resource   = ''
)

$ErrorActionPreference = 'Stop'

$AzCmd = $null
$azCommand = Get-Command az -ErrorAction SilentlyContinue
if ($azCommand) { $AzCmd = $azCommand.Source }
if (-not $AzCmd) { $AzCmd = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd' }
if (-not (Test-Path $AzCmd)) { throw "Azure CLI introuvable. Installez-la ou ajoutez az au PATH." }

function Write-Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "    OK  $Message" -ForegroundColor Green }
function Write-Bad  { param([string] $Message) Write-Host "    KO  $Message" -ForegroundColor Red }

<#
  Determine l'audience de token acceptee par le cluster.

  1. Le cluster expose /v1/rest/auth/metadata SANS authentification : il y publie
     lui-meme son KustoServiceResourceId. C'est la source de verite.
  2. A defaut, on essaie une liste de candidats connus et on garde le premier pour
     lequel Entra ID accepte de delivrer un token.

  A NE PAS coder en dur : "https://kusto.fabric.microsoft.com" n'est pas un resource
  principal enregistre (AADSTS500011). Les Eventhouse Fabric reutilisent l'application
  Entra d'Azure Data Explorer.
#>
function Resolve-KustoResource {
    $candidates = New-Object System.Collections.Generic.List[string]

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $metadata = Invoke-RestMethod -Method Get -UseBasicParsing `
            -Uri "$($ClusterUri.TrimEnd('/'))/v1/rest/auth/metadata"
        $discovered = $metadata.AzureAD.KustoServiceResourceId
        if ($discovered) {
            Write-Host "    audience publiee par le cluster : $discovered"
            $candidates.Add($discovered)
        }
    }
    catch {
        Write-Host "    /v1/rest/auth/metadata injoignable, passage aux candidats connus" -ForegroundColor DarkYellow
    }

    foreach ($fallback in @(
        'https://kusto.kusto.windows.net',
        'https://api.kusto.windows.net',
        $ClusterUri.TrimEnd('/'),
        'https://api.fabric.microsoft.com'
    )) {
        if (-not $candidates.Contains($fallback)) { $candidates.Add($fallback) }
    }

    foreach ($candidate in $candidates) {
        $previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            # --output none : aucun token n'est ecrit sur la sortie.
            & $AzCmd account get-access-token --resource $candidate --output none 2>&1 | Out-Null
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previous }

        if ($code -eq 0) { return $candidate }
        Write-Host "    audience refusee : $candidate" -ForegroundColor DarkYellow
    }

    throw "Aucune audience de token acceptee pour $ClusterUri. Essayez : az login --tenant <tenant> --scope <audience>/.default"
}

<#
  Decoupe un fichier .kql en commandes de controle individuelles.
#>
function Split-KqlCommands {
    param([Parameter(Mandatory)] [string] $Path)

    $fence    = '```'
    $inFence  = $false
    $current  = New-Object System.Collections.Generic.List[string]
    $commands = New-Object System.Collections.Generic.List[string]

    foreach ($line in (Get-Content -Path $Path)) {

        if ($line.Trim() -eq $fence) { $inFence = -not $inFence }

        # Commentaires de niveau fichier : ignores (jamais a l'interieur d'un bloc).
        if (-not $inFence -and $line.TrimStart().StartsWith('//')) { continue }

        # Nouvelle commande : un point en colonne 0, hors bloc.
        if (-not $inFence -and $line.StartsWith('.')) {
            if ($current.Count -gt 0) {
                $text = ($current -join "`n").Trim()
                if ($text) { $commands.Add($text) }
                $current.Clear()
            }
        }

        if ($current.Count -gt 0 -or $line.Trim()) { $current.Add($line) }
    }

    if ($current.Count -gt 0) {
        $text = ($current -join "`n").Trim()
        if ($text) { $commands.Add($text) }
    }

    return $commands
}

<#
  Envoie une commande de controle a l'endpoint de management du cluster.
#>
function Invoke-KustoMgmt {
    param([Parameter(Mandatory)] [string] $Csl)

    $body = @{ db = $Database; csl = $Csl } | ConvertTo-Json -Depth 5 -Compress
    $tmp  = [System.IO.Path]::GetTempFileName()
    # UTF8 sans BOM : le BOM ferait echouer le parsing JSON cote serveur.
    [System.IO.File]::WriteAllText($tmp, $body, (New-Object System.Text.UTF8Encoding($false)))

    $azArgs = @(
        'rest', '--method', 'post',
        '--url', "$($ClusterUri.TrimEnd('/'))/v1/rest/mgmt",
        '--resource', $script:KustoResource,
        '--headers', 'Content-Type=application/json',
        '--body', "@$tmp",
        '--output', 'json'
    )

    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = (& $AzCmd @azArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{ Success = ($code -eq 0); Output = $raw }
}

Write-Step "Cible : $ClusterUri / base '$Database'"

if ($Resource) {
    $script:KustoResource = $Resource
    Write-Host "    audience imposee : $script:KustoResource"
}
else {
    $script:KustoResource = Resolve-KustoResource
}
Write-Ok "audience retenue : $script:KustoResource"

$failures = 0
foreach ($file in $Files) {
    $resolved = Resolve-Path -Path $file
    Write-Step "Fichier $file"

    $commands = Split-KqlCommands -Path $resolved
    Write-Host "    $($commands.Count) commande(s) detectee(s)"

    $index = 0
    foreach ($command in $commands) {
        $index++
        $label = ($command -split "`n")[0]
        if ($label.Length -gt 90) { $label = $label.Substring(0, 90) + '...' }

        $result = Invoke-KustoMgmt -Csl $command
        if ($result.Success) {
            Write-Ok "[$index/$($commands.Count)] $label"
        }
        else {
            $failures++
            Write-Bad "[$index/$($commands.Count)] $label"
            Write-Host $result.Output -ForegroundColor DarkRed
        }
    }
}

Write-Host ""
if ($failures -gt 0) {
    Write-Host "TERMINE AVEC $failures ERREUR(S)." -ForegroundColor Red
    exit 1
}

Write-Host "TERMINE - toutes les commandes ont ete appliquees." -ForegroundColor Green
