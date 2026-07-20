#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Set "member_email" in each project's .harness/portal-sync.json so the Portal
  can attribute that project's agentic (Claude Code) tokens to a member + the
  Tier-2 provider connection whose display_name equals this email.

.DESCRIPTION
  Safe JSON round-trip: only member_email changes; portal_url/project_id/
  pdp_enforce/_README preserved; portal-sync.key never touched. ASCII console
  output. One email PER project (a project's transcript tokens can't be split
  across accounts). For 2 accounts, run twice with -Only for each set.

.EXAMPLE
  # all projects -> account A
  set-member-email.ps1 -Email "you@example.com"
  # just two projects -> account B
  set-member-email.ps1 -Email "other@example.com" -Only "ProjectX,ProjectY"
  # everything except one
  set-member-email.ps1 -Email "you@example.com" -Exclude "ProjectX"
  set-member-email.ps1 -Email "you@example.com" -WhatIf   # preview only
#>
param(
    [string]$BaseDir = "E:\SourceCode",
    [Parameter(Mandatory = $true)][string]$Email,
    [string]$Only = "",
    [string]$Exclude = "",
    [switch]$WhatIf
)
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$skip = @("HarnessAI-ToolKIT", "Harness-ToolKIT")
$onlySet = @($Only -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$exclSet = @($Exclude -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

Write-Host "==================================================================" -ForegroundColor Green
Write-Host " Set member_email = $Email   (base: $BaseDir)$(if ($WhatIf) { '   [DRY RUN]' })" -ForegroundColor Green
if ($onlySet) { Write-Host " Only: $($onlySet -join ', ')" -ForegroundColor Green }
if ($exclSet) { Write-Host " Exclude: $($exclSet -join ', ')" -ForegroundColor Green }
Write-Host "==================================================================" -ForegroundColor Green

$projects = Get-ChildItem $BaseDir -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin $skip -and (Test-Path (Join-Path $_.FullName ".harness\portal-sync.json")) }

$summary = @()
foreach ($p in $projects) {
    if ($onlySet -and $p.Name -notin $onlySet) { continue }
    if ($exclSet -and $p.Name -in $exclSet) { continue }
    $f = Join-Path $p.FullName ".harness\portal-sync.json"
    try { $cfg = Get-Content $f -Raw -Encoding utf8 | ConvertFrom-Json }
    catch {
        Write-Warning ("  ! {0,-26} portal-sync.json unreadable -- SKIPPED" -f $p.Name)
        $summary += [pscustomobject]@{ Project = $p.Name; Old = "parse-error"; New = "(skipped)" }
        continue
    }
    $old = if ($cfg.member_email) { [string]$cfg.member_email } else { "(unset)" }
    if ($WhatIf) {
        Write-Host ("  ~ {0,-26} member_email {1} -> {2}" -f $p.Name, $old, $Email) -ForegroundColor Yellow
        $summary += [pscustomobject]@{ Project = $p.Name; Old = $old; New = "$Email (would)" }
        continue
    }
    $cfg | Add-Member -NotePropertyName member_email -NotePropertyValue $Email -Force
    [System.IO.File]::WriteAllText($f, ($cfg | ConvertTo-Json -Depth 8), $Utf8NoBom)
    Write-Host ("  > {0,-26} member_email {1} -> {2}" -f $p.Name, $old, $Email) -ForegroundColor Cyan
    $summary += [pscustomobject]@{ Project = $p.Name; Old = $old; New = $Email }
}

Write-Host "`n==================== SUMMARY ($($summary.Count)) ====================" -ForegroundColor Green
$summary | Format-Table -AutoSize
Write-Host "member_email must match a Provider connection display_name for per-connection attribution." -ForegroundColor Gray
Write-Host "Next: run harness-sync.local.ps1 to re-push (agentic tokens get attributed + back-filled)." -ForegroundColor Gray
