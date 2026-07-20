#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Turn the server-side PDP enforcement on/off across every project by adding the
  "pdp_enforce" flag to each .harness/portal-sync.json — WITHOUT touching any
  other data (portal_url, project_id, _README are preserved; the secret
  portal-sync.key is never read or modified).

.DESCRIPTION
  Safe JSON round-trip: parse -> set only pdp_enforce -> write back UTF-8 (no
  BOM). Idempotent. A project whose portal-sync.json is missing/corrupt is
  skipped (never overwritten). Enabling PDP means the PreToolUse hook consults
  the Portal for high-risk actions (H4 outbound allowlist, H5 approval, H3
  release gate).

.EXAMPLE
  powershell -File ...\set-pdp-enforce.ps1                 # enable on all projects
  powershell -File ...\set-pdp-enforce.ps1 -Enforce:$false # disable on all
  powershell -File ...\set-pdp-enforce.ps1 -WhatIf         # dry run, change nothing
#>
param(
    [string]$BaseDir = "E:\SourceCode",
    [bool]$Enforce = $true,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
# Console output ASCII-only + best-effort UTF-8 so it never mojibakes on a
# non-UTF console codepage (e.g. cp932). Keep all Write-Host messages ASCII.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$skip = @("HarnessAI-ToolKIT", "Harness-ToolKIT")

Write-Host "==================================================================" -ForegroundColor Green
Write-Host " Set pdp_enforce = $Enforce   (base: $BaseDir)$(if ($WhatIf) { '   [DRY RUN]' })" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green

$projects = Get-ChildItem $BaseDir -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin $skip -and (Test-Path (Join-Path $_.FullName ".harness\portal-sync.json")) }

if (-not $projects) { Write-Warning "No project with .harness\portal-sync.json under $BaseDir"; exit 0 }

$summary = @()
foreach ($p in $projects) {
    $f = Join-Path $p.FullName ".harness\portal-sync.json"
    try {
        $cfg = Get-Content $f -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        Write-Warning ("  ! {0,-26} portal-sync.json unreadable -- SKIPPED (left as-is)" -f $p.Name)
        $summary += [pscustomobject]@{ Project = $p.Name; Old = "parse-error"; New = "(skipped)" }
        continue
    }
    $old = if ($null -ne $cfg.pdp_enforce) { [string]$cfg.pdp_enforce } else { "(unset)" }

    if ($WhatIf) {
        Write-Host ("  ~ {0,-26} pdp_enforce {1} -> {2}" -f $p.Name, $old, $Enforce) -ForegroundColor Yellow
        $summary += [pscustomobject]@{ Project = $p.Name; Old = $old; New = "$Enforce (would)" }
        continue
    }

    # Set only this one property; every other key is preserved verbatim.
    $cfg | Add-Member -NotePropertyName pdp_enforce -NotePropertyValue $Enforce -Force
    [System.IO.File]::WriteAllText($f, ($cfg | ConvertTo-Json -Depth 8), $Utf8NoBom)
    Write-Host ("  > {0,-26} pdp_enforce {1} -> {2}  (portal_url/project_id preserved)" -f $p.Name, $old, $Enforce) -ForegroundColor Cyan
    $summary += [pscustomobject]@{ Project = $p.Name; Old = $old; New = "$Enforce" }
}

Write-Host "`n==================== SUMMARY ($($summary.Count)) ====================" -ForegroundColor Green
$summary | Format-Table -AutoSize
if (-not $WhatIf -and $Enforce) {
    Write-Host "PDP enabled. Takes effect only when portal_url/project_id/key are set and the Portal is reachable." -ForegroundColor Gray
    Write-Host "To turn off: re-run with -Enforce:`$false" -ForegroundColor Gray
}
