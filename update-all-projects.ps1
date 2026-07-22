#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Update EVERY onboarded project to the latest standard-governance bundle.
  Run it the same way every time — it auto-detects the newest bundle and every
  project; nothing to edit when a new version ships.

.DESCRIPTION
  * Finds the highest-version *.bundle.json in the bundles dir (semantic sort).
  * Discovers projects: every directory under -BaseDir that has a .harness/
    (i.e. already onboarded), excluding the toolkit repos themselves.
  * Installs with -Force -MergeClaude (idempotent; NEVER touches portal-sync.key
    or portal-sync.json — your ingest key is preserved).
  * Rebuilds the H1 retrieval index so context-query works right away.
  * Prints a summary: project | old version | new version | status.

.EXAMPLE
  powershell -File E:\SourceCode\HarnessAI-ToolKIT\tools\harness-bundle\update-all-projects.ps1
  powershell -File ...\update-all-projects.ps1 -WhatIf        # dry run, change nothing
  powershell -File ...\update-all-projects.ps1 -Reinstall     # reinstall even if same version
#>
param(
    [string]$BaseDir   = "E:\SourceCode",
    [string]$BundleDir = "",
    [switch]$Reinstall,
    [switch]$PdpEnforce,   # also turn on server-side PDP enforcement in each portal-sync.json
    [switch]$WhatIf,
    [switch]$NoIdentity,   # do NOT stamp project name/description from the folder name
    [switch]$ForceIdentity # overwrite the name even when the project already set one
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }  # avoid console mojibake
$ToolkitRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
if (-not $BundleDir) { $BundleDir = Join-Path $ToolkitRoot "bundles\standard-governance" }
$Installer = Join-Path $ToolkitRoot "tools\harness-bundle\install.ps1"

# --- 1. Pick the newest bundle by semantic version (not string sort) ---
$latest = Get-ChildItem "$BundleDir\*.bundle.json" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -match 'standard-governance-(\d+)\.(\d+)\.(\d+)\.bundle\.json') {
        [pscustomobject]@{ File = $_.FullName; V = [version]("{0}.{1}.{2}" -f $matches[1], $matches[2], $matches[3]) }
    }
} | Sort-Object V -Descending | Select-Object -First 1

if (-not $latest) { throw "No standard-governance-*.bundle.json found in $BundleDir" }
$LatestVer = $latest.V.ToString()
# Content hash of the artifact we are about to install -- the real identity of a
# build. Compared against each project's receipt so a repacked version is not
# mistaken for "already installed".
$LatestHash = ""
try { $LatestHash = (Get-Content $latest.File -Raw -Encoding utf8 | ConvertFrom-Json).content_hash } catch { }
Write-Host "==================================================================" -ForegroundColor Green
Write-Host " Latest bundle: standard-governance v$LatestVer" -ForegroundColor Green
Write-Host " Base dir     : $BaseDir$(if ($WhatIf) { '   [DRY RUN]' })" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green

# --- 2. Discover onboarded projects (have .harness), skip the toolkit repos ---
$skip = @("HarnessAI-ToolKIT", "Harness-ToolKIT")
$projects = Get-ChildItem $BaseDir -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin $skip -and (Test-Path (Join-Path $_.FullName ".harness")) }

if (-not $projects) { Write-Warning "No onboarded projects (with .harness) found under $BaseDir"; exit 0 }

# --- 3. Update each ---
$summary = @()
$py = (Get-Command python3 -ErrorAction SilentlyContinue); if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }

foreach ($p in $projects) {
    $root = $p.FullName
    $manifest = Join-Path $root ".harness\.bundle-manifest.json"
    $cur = "-"; $curHash = ""
    if (Test-Path $manifest) {
        try {
            $m = Get-Content $manifest -Raw -Encoding utf8 | ConvertFrom-Json
            $cur = $m.version
            if ($m.PSObject.Properties.Name -contains 'content_hash') { $curHash = $m.content_hash }
        } catch { }
    }

    # "Up to date" means the CONTENT matches, not just the version string. A
    # version that was repacked (same number, different files) would otherwise be
    # silently skipped and the project left on the older artifact.
    $isCurrent = if ($LatestHash -and $curHash) { $curHash -eq $LatestHash } else { $cur -eq $LatestVer }
    if ($isCurrent -and -not $Reinstall) {
        Write-Host ("  = {0,-26} v{1}  (up-to-date)" -f $p.Name, $cur) -ForegroundColor DarkGray
        $summary += [pscustomobject]@{ Project = $p.Name; Old = $cur; New = $cur; Status = "up-to-date" }
        continue
    }

    if ($WhatIf) {
        Write-Host ("  ~ {0,-26} v{1} -> v{2}  (would update)" -f $p.Name, $cur, $LatestVer) -ForegroundColor Yellow
        $summary += [pscustomobject]@{ Project = $p.Name; Old = $cur; New = $LatestVer; Status = "would-update" }
        continue
    }

    Write-Host ("  > {0,-26} v{1} -> v{2}" -f $p.Name, $cur, $LatestVer) -ForegroundColor Cyan
    try {
        # Identity: name the project after its folder. The installer only writes
        # it when contracts/project.yaml still carries the shipped placeholder,
        # so a project that already named itself is never renamed (unless
        # -ForceIdentity). -NoIdentity opts out entirely.
        # Splat a HASHTABLE, not an array: `@array` splats positionally, which
        # binds the literal string "-ProjectName" as the value of the first free
        # positional parameter. A hashtable maps keys to parameter NAMES.
        $idArgs = @{}
        if (-not $NoIdentity) {
            $idArgs['ProjectName'] = $p.Name
            $idArgs['ProjectDescription'] = $p.Name
            if ($ForceIdentity) { $idArgs['ForceIdentity'] = $true }
        }
        & $Installer -BundleFile $latest.File -TargetDir $root -Force -MergeGuides @idArgs | Out-Null
        # Rebuild H1 retrieval index so context-query works immediately (best-effort).
        $rag = Join-Path $root ".harness\scripts\lib\harness_rag.py"
        if ($py -and (Test-Path $rag)) { $env:HARNESS_ROOT = $root; & $py.Source $rag index --root $root *>$null }
        $summary += [pscustomobject]@{ Project = $p.Name; Old = $cur; New = $LatestVer; Status = "updated" }
    } catch {
        Write-Warning "    FAILED: $_"
        $summary += [pscustomobject]@{ Project = $p.Name; Old = $cur; New = $LatestVer; Status = "FAILED" }
    }
}

Write-Host "`n==================== SUMMARY ($($summary.Count) projects) ====================" -ForegroundColor Green
$summary | Format-Table -AutoSize
$updated = ($summary | Where-Object { $_.Status -eq "updated" }).Count
$failed  = ($summary | Where-Object { $_.Status -eq "FAILED" }).Count
Write-Host ("Done: {0} updated, {1} up-to-date, {2} failed." -f $updated,
    ($summary | Where-Object { $_.Status -eq "up-to-date" }).Count, $failed) -ForegroundColor $(if ($failed) { "Yellow" } else { "Green" })
Write-Host "portal-sync.key / portal-sync.json were preserved. Run a Claude session per project to refresh telemetry." -ForegroundColor Gray

# Optionally flip on PDP enforcement (safe JSON merge; preserves all other keys).
if ($PdpEnforce) {
    Write-Host ""
    & (Join-Path $PSScriptRoot "set-pdp-enforce.ps1") -BaseDir $BaseDir -Enforce $true -WhatIf:$WhatIf
}
