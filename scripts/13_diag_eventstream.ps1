<#
.SYNOPSIS
    Diagnostic en lecture seule de l'Eventstream : que contient reellement l'item ?

.DESCRIPTION
    Le POST de creation a renvoye un succes mais GET .../topology renvoie EntityNotFound.
    Ce script ne modifie rien. Il repond a trois questions, dans l'ordre :
      1. L'item existe-t-il, et dans quel etat ?
      2. La definition poussee est-elle bien stockee (getDefinition) ?
      3. Que renvoie exactement /topology (message d'erreur brut) ?
    Aucun secret n'est manipule ici.
#>
[CmdletBinding()]
param(
    [string] $WorkspaceName   = 'ws-rti-aml-demo',
    [string] $EventstreamName = 'es-sensors'
)

$ErrorActionPreference = 'Stop'
$FabricApi      = 'https://api.fabric.microsoft.com/v1'
$FabricResource = 'https://api.fabric.microsoft.com'
$AzCmd          = 'az'

function Write-Step { param([string] $Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }

# Variante NON bloquante de Invoke-Fabric : on veut voir les erreurs, pas s'arreter dessus.
function Invoke-FabricRaw {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Path
    )

    $url      = "$FabricApi/$($Path.TrimStart('/'))"
    $azArgs   = @('rest', '--method', $Method, '--url', $url, '--resource', $FabricResource, '--output', 'json')
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = (& $AzCmd @azArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    }
    finally { $ErrorActionPreference = $previous }

    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Raw = $raw }
}

# ------------------------------------------------------------ 1. Etat de l'item
Write-Step '1. Etat de l item Eventstream'

$wsRes = Invoke-FabricRaw -Method get -Path 'workspaces'
if ($wsRes.ExitCode -ne 0) { throw "Impossible de lister les workspaces : `n$($wsRes.Raw)" }
$workspace = ($wsRes.Raw | ConvertFrom-Json).value |
    Where-Object { $_.displayName -eq $WorkspaceName } | Select-Object -First 1
if (-not $workspace) { throw "Workspace '$WorkspaceName' introuvable." }
$workspaceId = $workspace.id

$esRes = Invoke-FabricRaw -Method get -Path "workspaces/$workspaceId/eventstreams"
if ($esRes.ExitCode -ne 0) { throw "Impossible de lister les eventstreams : `n$($esRes.Raw)" }
$eventstream = ($esRes.Raw | ConvertFrom-Json).value |
    Where-Object { $_.displayName -eq $EventstreamName } | Select-Object -First 1
if (-not $eventstream) { throw "Eventstream '$EventstreamName' introuvable." }
$eventstreamId = $eventstream.id

Write-Host "    workspaceId   : $workspaceId"
Write-Host "    eventstreamId : $eventstreamId"
Write-Host '    item complet  :'
$eventstream | ConvertTo-Json -Depth 10

# --------------------------------------------------- 2. Definition reellement stockee
Write-Step '2. getDefinition - la definition poussee est-elle stockee ?'

$defRes = Invoke-FabricRaw -Method post -Path "workspaces/$workspaceId/eventstreams/$eventstreamId/getDefinition"

if ($defRes.ExitCode -ne 0) {
    Write-Host '    ECHEC de getDefinition :' -ForegroundColor Yellow
    Write-Host $defRes.Raw
}
elseif ([string]::IsNullOrWhiteSpace($defRes.Raw)) {
    Write-Host '    Reponse vide (operation probablement asynchrone : 202 sans corps).' -ForegroundColor Yellow
}
else {
    $definition = $defRes.Raw | ConvertFrom-Json
    $parts = $null
    if ($definition.PSObject.Properties['definition']) { $parts = $definition.definition.parts }
    elseif ($definition.PSObject.Properties['parts'])  { $parts = $definition.parts }

    if (-not $parts) {
        Write-Host '    Aucune partie trouvee. Reponse brute :' -ForegroundColor Yellow
        Write-Host $defRes.Raw
    }
    else {
        foreach ($part in $parts) {
            Write-Host "`n    --- partie : $($part.path) ---" -ForegroundColor Green
            if ($part.payloadType -eq 'InlineBase64') {
                $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.payload))
                Write-Host $decoded
            }
            else {
                Write-Host "    payloadType non decodable ici : $($part.payloadType)"
            }
        }
    }
}

# ------------------------------------------------------------- 3. Topologie live
Write-Step '3. /topology - message d erreur brut'

$topoRes = Invoke-FabricRaw -Method get -Path "workspaces/$workspaceId/eventstreams/$eventstreamId/topology"
Write-Host "    exit code : $($topoRes.ExitCode)"
Write-Host $topoRes.Raw

Write-Host "`n=== FIN DU DIAGNOSTIC (aucune modification effectuee) ===" -ForegroundColor Cyan
