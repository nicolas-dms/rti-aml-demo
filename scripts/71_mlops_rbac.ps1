<#
.SYNOPSIS
    Track C / M1b - Registry-scope role assignments only (DEV writes, PROD reads).

.DESCRIPTION
    Scope of every assignment: the registry AML_REGISTRY itself. Nothing on the
    subscription, the resource group, DEV or PROD workspaces.

      DEV  service principal  SP_DEV_OBJECT_ID  (behind sc-rti-aml-dev)  -> AzureML Registry User
           (needed by `az ml model share`: read/write assets in the registry)
      PROD service principal  SP_PROD_OBJECT_ID (behind sc-rti-aml-prod) -> Reader
           (least privilege: PROD only reads the model it deploys)

    The two object ids are the service principals of the Azure DevOps service connections
    (docs/QUICKSTART.md, step 'Azure DevOps'). Without Azure DevOps, skip this script.

    Reader for PROD is NOT proven sufficient to deploy from the registry. If the
    PROD deployment is refused for lack of permission, the documented fallback is
    AzureML Registry User for that principal; do not widen it before seeing the error.

    Idempotent: an assignment that already exists is reported, never duplicated.
    Requires an existing Azure CLI login (caller must be allowed to create role
    assignments on the registry). Installs nothing, switches no account.

.PARAMETER VerifyOnly
    Read-only; reports which assignments exist and fails if one is missing.

.EXAMPLE
    .\scripts\71_mlops_rbac.ps1
    .\scripts\71_mlops_rbac.ps1 -VerifyOnly

.NOTES
    ASCII; Windows PowerShell 5.1 compatible. User-operated, not agent-executed.
    Principals are passed by object ID with an explicit ServicePrincipal type,
    so no Microsoft Graph lookup is needed.
#>
[CmdletBinding()]
param([switch] $VerifyOnly)

$ErrorActionPreference = 'Stop'
$SubscriptionId = & "$PSScriptRoot\lib\cfg.ps1" AZURE_SUBSCRIPTION_ID -Required
$TenantId = & "$PSScriptRoot\lib\cfg.ps1" AZURE_TENANT_ID -Required
$ResourceGroup = & "$PSScriptRoot\lib\cfg.ps1" AZURE_RESOURCE_GROUP -Required
$RegistryName = & "$PSScriptRoot\lib\cfg.ps1" AML_REGISTRY -Required
$DevSpObjectId = & "$PSScriptRoot\lib\cfg.ps1" SP_DEV_OBJECT_ID -Required
$ProdSpObjectId = & "$PSScriptRoot\lib\cfg.ps1" SP_PROD_OBJECT_ID -Required
$RegistryScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.MachineLearningServices/registries/$RegistryName"

$Assignments = @(
    [pscustomobject]@{ Label = 'DEV  service principal';  ObjectId = $DevSpObjectId;  Role = 'AzureML Registry User' },
    [pscustomobject]@{ Label = 'PROD service principal'; ObjectId = $ProdSpObjectId; Role = 'Reader' }
)

$AzCmd = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
if (-not (Test-Path -LiteralPath $AzCmd -PathType Leaf)) {
    $AzCmd = (Get-Command az -CommandType Application -ErrorAction Stop).Source
}

function Invoke-AzRaw {
    param([Parameter(Mandatory = $true)] [string[]] $Arguments)
    $errorFile = [IO.Path]::GetTempFileName()
    $previousPreference = $ErrorActionPreference
    $stdout = @()
    $stderr = ''
    $exitCode = $null
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        $stdout = & $AzCmd @Arguments 2> $errorFile
        $exitCode = $global:LASTEXITCODE
        $stderr = [IO.File]::ReadAllText($errorFile)
    }
    finally {
        $ErrorActionPreference = $previousPreference
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        StdOut = (($stdout | ForEach-Object { [string] $_ }) -join "`n").Trim()
        StdErr = $stderr
    }
}

function Invoke-AzChecked {
    param(
        [Parameter(Mandatory = $true)] [string[]] $Arguments,
        [Parameter(Mandatory = $true)] [string] $Operation
    )
    $result = Invoke-AzRaw -Arguments $Arguments
    if ($null -eq $result.ExitCode -or $result.ExitCode -ne 0) {
        $diagnosticPath = Join-Path ([IO.Path]::GetTempPath()) ("rti-m1b-rbac-error-" + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($diagnosticPath, $result.StdErr)
        Write-Host "Local stderr diagnostic: $diagnosticPath" -ForegroundColor Yellow
        Write-Host 'Inspect locally; share only the ERROR line after checking for secrets.' -ForegroundColor Yellow
        $knownCodes = @('InvalidAuthenticationTokenTenant', 'AuthorizationFailed', 'AuthenticationFailed',
            'ResourceNotFound', 'RoleAssignmentExists', 'PrincipalNotFound', 'RequestDisallowedByPolicy',
            'SubscriptionDisabled', 'Conflict')
        $codes = @($knownCodes | Where-Object {
            $result.StdErr -match [regex]::Escape($_) -or $result.StdOut -match [regex]::Escape($_)
        })
        throw "$Operation failed (CLI exit '$($result.ExitCode)', known codes: $($codes -join ', ')). This is not proof of absence."
    }
    return $result.StdOut
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory = $true)] [string[]] $Arguments,
        [Parameter(Mandatory = $true)] [string] $Operation
    )
    $text = Invoke-AzChecked -Arguments ($Arguments + @('--output', 'json', '--only-show-errors')) -Operation $Operation
    if ([string]::IsNullOrWhiteSpace($text)) { throw "$Operation returned empty stdout, not valid JSON evidence." }
    try { $parsed = ConvertFrom-Json -InputObject $text -ErrorAction Stop }
    catch { throw "$Operation returned invalid JSON; raw output suppressed." }
    if ($text.TrimStart().StartsWith('[')) { return ,@($parsed | Where-Object { $null -ne $_ }) }
    if ($null -eq $parsed -or -not $text.TrimStart().StartsWith('{')) { throw "$Operation returned neither a JSON object nor an array." }
    return $parsed
}

Write-Host '=== Track C / M1b - registry RBAC only ===' -ForegroundColor Cyan
Write-Host "Scope: $RegistryScope; VerifyOnly=$VerifyOnly"

$account = Invoke-AzJson -Arguments @('account', 'show') -Operation 'CLI account context'
if ($account.id -ne $SubscriptionId -or $account.tenantId -ne $TenantId -or $account.state -ne 'Enabled') {
    throw 'CLI context must be the locked subscription and tenant, state Enabled. Nothing was written.'
}

# The registry must exist before any assignment (also proves the scope string).
$registry = Invoke-AzJson -Arguments @('ml', 'registry', 'show', '--name', $RegistryName,
    '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId) -Operation 'Registry show'
if ($registry.id -ne $RegistryScope) { throw 'Registry ID differs from the expected scope; nothing was written.' }

$results = @()
foreach ($item in $Assignments) {
    # --scope AND --assignee-object-id: the exact (principal, role, scope) triple, no inherited match counted.
    $existing = Invoke-AzJson -Arguments @('role', 'assignment', 'list', '--scope', $RegistryScope,
        '--assignee', $item.ObjectId, '--role', $item.Role, '--subscription', $SubscriptionId) `
        -Operation "Role assignment list ($($item.Label))"
    $direct = @($existing | Where-Object { $_.scope -eq $RegistryScope })
    $state = 'present'
    if ($direct.Count -eq 0) {
        if ($VerifyOnly) {
            $state = 'MISSING'
        } else {
            Write-Host "Creating: $($item.Role) for $($item.Label) at registry scope." -ForegroundColor Yellow
            Invoke-AzChecked -Arguments @('role', 'assignment', 'create',
                '--assignee-object-id', $item.ObjectId, '--assignee-principal-type', 'ServicePrincipal',
                '--role', $item.Role, '--scope', $RegistryScope, '--subscription', $SubscriptionId,
                '--output', 'none', '--only-show-errors') -Operation "Role assignment create ($($item.Label))" | Out-Null
            $state = 'created'
        }
    }
    $results += [pscustomobject]@{ principal = $item.Label; objectId = $item.ObjectId; role = $item.Role; state = $state }
}

Write-Host "`n--- M1b registry RBAC evidence (copy to docs/PROGRESS.md) ---" -ForegroundColor Green
$results | Format-Table -AutoSize
Write-Host "checkedUtc: $([DateTime]::UtcNow.ToString('o'))"
if (@($results | Where-Object { $_.state -eq 'MISSING' }).Count -gt 0) {
    throw 'At least one assignment is missing (VerifyOnly).'
}
Write-Host 'Assignments can take several minutes to apply. Not proof of effective access until model share works.' -ForegroundColor Yellow
Write-Host 'Next: independent read-back with Resource Graph, then the model share test.'
