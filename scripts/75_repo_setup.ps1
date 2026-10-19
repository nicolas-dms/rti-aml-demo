param(
    [string]$RemoteUrl = 'https://dev.azure.com/<ADO_ORG>/rti-aml-demo/_git/rti-aml-demo'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

function Invoke-Git {
    param([string[]]$GitArgs)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Git failed (exit $LASTEXITCODE). No commit or push was performed."
    }
}

Get-Command git -ErrorAction Stop | Out-Null
Push-Location $repo
try {
    # Do not accidentally stage into a repository belonging to a parent folder.
    if (-not (Test-Path -LiteralPath '.git')) {
        Invoke-Git -GitArgs @('init', '--initial-branch=main')
    }
    $root = (Invoke-Git -GitArgs @('rev-parse', '--show-toplevel')).Trim()
    if ([IO.Path]::GetFullPath($root).TrimEnd('\', '/') -ne
        [IO.Path]::GetFullPath($repo).TrimEnd('\', '/')) {
        throw 'Unexpected Git root. Stop and inspect the repository.'
    }

    $remotes = @(Invoke-Git -GitArgs @('remote'))
    if ($remotes -contains 'origin') {
        $origin = (Invoke-Git -GitArgs @('remote', 'get-url', 'origin')).Trim()
        if ($origin -ne $RemoteUrl) {
            throw 'Origin already exists with a different URL. It was not changed.'
        }
    } else {
        Invoke-Git -GitArgs @('remote', 'add', 'origin', $RemoteUrl)
    }

    # Explicit allowlist: never stage .env, virtual environments or local metadata.
    $paths = @('.gitignore', '.env.example', 'aml', 'docs', 'fabric',
        'functions', 'scripts', 'simulator')
    Invoke-Git -GitArgs (@('add', '--') + $paths)
    $staged = @(Invoke-Git -GitArgs @('diff', '--cached', '--name-only'))
    $forbidden = @($staged | Where-Object {
        $_ -match '(^|/)(\.env|local\.settings\.json)$|\.(pem|publishsettings)$'
    })
    if ($forbidden.Count -gt 0) {
        throw 'Sensitive file names detected in index. Stop; do not commit.'
    }

    Write-Host "`nReview the staged file summary:"
    Invoke-Git -GitArgs @('diff', '--cached', '--stat')
    Write-Host "`nCurrent branch:"
    Invoke-Git -GitArgs @('branch', '--show-current')
    Write-Host "`nSetup complete. No commit or push performed."
    Write-Host 'Review staged contents for secrets before the first commit.'
} finally {
    Pop-Location
}