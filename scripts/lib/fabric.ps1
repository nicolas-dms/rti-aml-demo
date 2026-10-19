<#
.SYNOPSIS
    Client minimal de l'API Fabric, conscient des operations asynchrones (LRO).

.DESCRIPTION
    A dot-sourcer : . "$PSScriptRoot\lib\fabric.ps1"

    Pourquoi ne pas utiliser 'az rest' ?
    Parce qu'il n'expose ni le code de statut ni les en-tetes de reponse. Un POST de
    creation Fabric renvoie 202 + un en-tete Location : le travail reel se fait ensuite,
    de facon asynchrone. Avec 'az rest' on croit avoir reussi alors que l'operation peut
    echouer une minute plus tard - et Fabric annule alors l'item cree. C'est exactement
    ce qui s'est produit avec es-sensors : item visible, puis disparu, sans message.

    Invoke-WebRequest donne acces au statut, aux en-tetes et au corps des erreurs, donc
    on peut suivre l'operation jusqu'a son verdict et remonter le vrai message d'erreur.

    Le jeton d'acces est garde en memoire et n'est jamais affiche ni ecrit sur disque.
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$FabricApiRoot  = 'https://api.fabric.microsoft.com/v1'
$FabricResource = 'https://api.fabric.microsoft.com'
$FabricToken    = $null

function Connect-Fabric {
    <#  Recupere un jeton delegue via Azure CLI. Le jeton n'est jamais affiche.  #>
    [CmdletBinding()]
    param()

    $previous = $ErrorActionPreference
    try {
        # az ecrit ses avertissements sur stderr : sans ce basculement, PowerShell en
        # ferait une erreur terminante.
        $ErrorActionPreference = 'Continue'
        $output = (& az account get-access-token --resource $FabricResource --query accessToken --output tsv 2>&1 |
            ForEach-Object { "$_" }) -join ''
    }
    finally { $ErrorActionPreference = $previous }

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output) -or $output -match 'ERROR') {
        throw "Impossible d'obtenir un jeton pour $FabricResource. Lancez 'az login' puis reessayez."
    }
    $script:FabricToken = $output.Trim()
}

function Invoke-FabricRequest {
    <#  Requete HTTP brute : renvoie l'objet reponse complet (statut + en-tetes + corps).  #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri,
        [object] $Body
    )

    if (-not $FabricToken) { throw 'Appelez Connect-Fabric avant toute requete.' }

    $parameters = @{
        Method          = $Method
        Uri             = $Uri
        Headers         = @{ Authorization = "Bearer $FabricToken" }
        UseBasicParsing = $true
        ErrorAction     = 'Stop'
    }
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 40 -Compress
        # Octets UTF-8 explicites : evite toute reinterpretation de l'encodage.
        $parameters.Body        = [System.Text.Encoding]::UTF8.GetBytes($json)
        $parameters.ContentType = 'application/json; charset=utf-8'
    }

    try {
        return Invoke-WebRequest @parameters
    }
    catch [System.Net.WebException] {
        $webResponse = $_.Exception.Response
        if (-not $webResponse) { throw }

        $status = [int] $webResponse.StatusCode
        $reader = New-Object System.IO.StreamReader($webResponse.GetResponseStream())
        $text   = $reader.ReadToEnd()
        $reader.Close()
        throw "Fabric $Method $Uri -> HTTP $status`n$text"
    }
}

function Wait-FabricOperation {
    <#  Suit une operation asynchrone jusqu'a Succeeded ou Failed, et renvoie son resultat.  #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Response,
        [int] $TimeoutSeconds = 600
    )

    $location = $Response.Headers['Location']
    if (-not $location) {
        if ([string]::IsNullOrWhiteSpace($Response.Content)) { return $null }
        return $Response.Content | ConvertFrom-Json
    }

    $delay = 5
    if ($Response.Headers['Retry-After']) {
        $parsed = 0
        if ([int]::TryParse($Response.Headers['Retry-After'], [ref] $parsed) -and $parsed -gt 0) { $delay = $parsed }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $delay

        $stateResponse = Invoke-FabricRequest -Method Get -Uri $location
        $state         = $stateResponse.Content | ConvertFrom-Json

        if ($state.status -eq 'Failed') {
            # C'est ici que se trouve la raison reelle d'un rejet de definition.
            throw "Operation Fabric en echec :`n$($state | ConvertTo-Json -Depth 12)"
        }
        if ($state.status -eq 'Succeeded') {
            $resultUri = $stateResponse.Headers['Location']
            if (-not $resultUri) { $resultUri = "$location/result" }
            try {
                $result = Invoke-FabricRequest -Method Get -Uri $resultUri
                if ([string]::IsNullOrWhiteSpace($result.Content)) { return $null }
                return $result.Content | ConvertFrom-Json
            }
            catch {
                # Certaines operations n'exposent pas de resultat : le succes suffit.
                return $state
            }
        }
    }
    throw "Operation Fabric toujours en cours apres $TimeoutSeconds secondes : $location"
}

function Invoke-Fabric {
    <#  Appel de haut niveau : resout le chemin, suit les LRO, renvoie l'objet deserialise.  #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        [object] $Body,
        [switch] $NoWait
    )

    $uri = if ($Path -match '^https?://') { $Path } else { "$FabricApiRoot/$($Path.TrimStart('/'))" }
    $response = Invoke-FabricRequest -Method $Method -Uri $uri -Body $Body

    if ([int] $response.StatusCode -eq 202 -and -not $NoWait) {
        return Wait-FabricOperation -Response $response
    }
    if ([string]::IsNullOrWhiteSpace($response.Content)) { return $null }
    return $response.Content | ConvertFrom-Json
}

function Get-FabricItemByName {
    <#  Recherche un item par displayName dans une collection Fabric.  #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $DisplayName
    )

    $collection = Invoke-Fabric -Method Get -Path $Path
    if (-not $collection) { return $null }
    return $collection.value | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1
}
