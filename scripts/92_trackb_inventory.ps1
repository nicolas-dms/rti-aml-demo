# Read-only inventory of the leftover Azure resources of track B (LoRA fine-tuning),
# which was removed from this repo on 2026-10-07. Deleting the repo files deleted
# nothing in Azure, so this script answers one question: what is still there, and
# what does it cost?
#
# NOTHING IS DELETED HERE. The script prints the delete commands it would suggest,
# it never runs them. Safe to re-run.
#
#   .\scripts\92_trackb_inventory.ps1

[CmdletBinding()]
param(
    [string] $ResourceGroup = 'rg-rti-aml-demo',
    [string] $Workspace     = 'aml-rti-demo',
    [string] $Storage       = '<STORAGE_ACCOUNT>',
    [string] $Subscription  = '<SUBSCRIPTION_ID>'
)

$ErrorActionPreference = 'Continue'

# The PATH is regularly lost in the integrated terminal - resolve az once, by hand.
$az = 'az'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    $fallback = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
    if (Test-Path $fallback) { $az = $fallback }
    else { throw 'az CLI not found - open a fresh terminal.' }
}

function Write-Section([string] $Title) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 0. The session drifts to the personal tenant regularly. Check before anything.
# ---------------------------------------------------------------------------
Write-Section '0. Azure session'
$acct = & $az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { throw 'Not logged in. Run: az login --tenant <TENANT_ID>' }
Write-Host ("  user : {0}" -f $acct.user.name)
Write-Host ("  sub  : {0} ({1})" -f $acct.name, $acct.id)
if ($acct.id -ne $Subscription) {
    Write-Host "  -> wrong subscription, switching" -ForegroundColor Yellow
    & $az account set --subscription $Subscription | Out-Null
}

# ---------------------------------------------------------------------------
# 1. Online endpoints - the only thing that bills 24/7.
# ---------------------------------------------------------------------------
Write-Section '1. Online endpoints (these bill 24/7 even when idle)'
$eps = & $az ml online-endpoint list -w $Workspace -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
$eps = @($eps | Where-Object { $null -ne $_ })
if ($eps.Count -eq 0) {
    Write-Host '  none' -ForegroundColor Green
} else {
    foreach ($ep in $eps) {
        $track = if ($ep.name -like '*vlm*' -or $ep.name -like 'maint-*') { 'TRACK B' } else { 'track A/C' }
        Write-Host ("  {0,-26} {1,-10} traffic={2}" -f $ep.name, $track, ($ep.traffic | ConvertTo-Json -Compress))
        # list, then show - `list` on deployments omits instance_count and would report 0 instances
        $deps = & $az ml online-deployment list --endpoint-name $ep.name -w $Workspace -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
        foreach ($d in @($deps | Where-Object { $null -ne $_ })) {
            $full = & $az ml online-deployment show -n $d.name --endpoint-name $ep.name -w $Workspace -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
            Write-Host ("      - {0,-10} {1,-20} x{2}" -f $full.name, $full.instance_type, $full.instance_count)
        }
    }
}

# ---------------------------------------------------------------------------
# 2. Compute clusters - harmless at min_instances = 0, but check it really is 0.
# ---------------------------------------------------------------------------
Write-Section '2. Compute clusters'
$computes = & $az ml compute list -w $Workspace -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
foreach ($c in @($computes | Where-Object { $null -ne $_ })) {
    $min = if ($null -ne $c.min_instances) { $c.min_instances } else { $c.scale_settings.min_instances }
    $max = if ($null -ne $c.max_instances) { $c.max_instances } else { $c.scale_settings.max_instances }
    $flag = if ($min -gt 0) { '  <-- BILLING' } else { '' }
    $track = if ($c.name -like 'gpu-*') { 'TRACK B' } else { 'track A/C' }
    Write-Host ("  {0,-20} {1,-10} {2,-22} min={3} max={4}{5}" -f $c.name, $track, $c.size, $min, $max, $flag)
}

# ---------------------------------------------------------------------------
# 3. Model and data assets - storage only, cheap, but they clutter the workspace
#    and the demo. `maint-vlm-merged` alone is ~518 MB.
# ---------------------------------------------------------------------------
Write-Section '3. Track B assets (storage cost only)'
$suggest = New-Object System.Collections.Generic.List[string]

foreach ($name in @('base-smolvlm', 'maint-vlm-adapter', 'maint-vlm-merged')) {
    $m = & $az ml model list -n $name -w $Workspace -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
    $versions = @($m | Where-Object { $null -ne $_ }).Count
    if ($versions -gt 0) {
        Write-Host ("  model  {0,-20} {1} version(s)" -f $name, $versions)
        $suggest.Add("az ml model archive -n $name -w $Workspace -g $ResourceGroup")
    }
}
foreach ($name in @('maintenance_vlm_ds')) {
    $d = & $az ml data list -n $name -w $Workspace -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
    $versions = @($d | Where-Object { $null -ne $_ }).Count
    if ($versions -gt 0) {
        Write-Host ("  data   {0,-20} {1} version(s)" -f $name, $versions)
        $suggest.Add("az ml data archive -n $name -w $Workspace -g $ResourceGroup")
    }
}

# ---------------------------------------------------------------------------
# 4. The dataset images on ADLS.
# ---------------------------------------------------------------------------
Write-Section '4. Track B data on ADLS'
$exists = & $az storage fs file list -f snapshots --path finetune --account-name $Storage --auth-mode login -o json 2>$null | ConvertFrom-Json
$files = @($exists | Where-Object { $null -ne $_ })
if ($files.Count -gt 0) {
    $mb = [math]::Round((($files | Measure-Object contentLength -Sum).Sum / 1MB), 1)
    Write-Host ("  snapshots/finetune/  {0} file(s), {1} MB" -f $files.Count, $mb)
    $suggest.Add("az storage fs directory delete -f snapshots -n finetune --account-name $Storage --auth-mode login --yes")
} else {
    Write-Host '  nothing under snapshots/finetune/' -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 5. Suggested cleanup - printed, never executed.
# ---------------------------------------------------------------------------
Write-Section '5. Suggested cleanup (NOT executed)'
if ($suggest.Count -eq 0) {
    Write-Host '  nothing to clean up' -ForegroundColor Green
} else {
    Write-Host '  Review these, then run them by hand:' -ForegroundColor Yellow
    foreach ($s in $suggest) { Write-Host "    $s" }
    Write-Host ''
    Write-Host '  Reminder: delete an ENDPOINT, never a deployment first - a deployment' -ForegroundColor DarkYellow
    Write-Host '  holding traffic cannot be deleted. Archiving a model/data asset hides it,' -ForegroundColor DarkYellow
    Write-Host '  it does not reclaim blob storage; the blobs live in the workspace store.' -ForegroundColor DarkYellow
}

Write-Host ''
