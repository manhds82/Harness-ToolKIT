#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Batch-install the governance bundle into all local projects in one run.
  For each project: removes stale governance files that block install,
  installs the current bundle with -MergeClaude, then verifies.

.USAGE
  # Run from E:\SourceCode\Harness-ToolKIT
  powershell -File install-all-projects.ps1

  # Dry-run: only verify, do not install
  powershell -File install-all-projects.ps1 -VerifyOnly
#>
param([switch]$VerifyOnly)

$ErrorActionPreference = "Continue"

$BUNDLE  = Join-Path $PSScriptRoot "standard-governance-1.0.0.bundle.json"
$INSTALL = Join-Path $PSScriptRoot "install.ps1"
$VERIFY  = Join-Path $PSScriptRoot "harness-verify.ps1"

# --- Project list -----------------------------------------------------------
# SkipInstall = $true  -> already the harness source repo; skip install, verify only
$PROJECTS = @(
    [pscustomobject]@{ Name="24hHotnewsAI";          Path="E:\SourceCode\24hHotnewsAI";          SkipInstall=$false },
    [pscustomobject]@{ Name="claude-code-anyllm";     Path="E:\SourceCode\claude-code-anyllm";     SkipInstall=$false },
    [pscustomobject]@{ Name="FPT-co-works";           Path="E:\SourceCode\FPT-co-works";           SkipInstall=$false },
    [pscustomobject]@{ Name="shadowing-app";          Path="E:\SourceCode\shadowing-app";          SkipInstall=$false },
    [pscustomobject]@{ Name="SynthGora";              Path="E:\SourceCode\SynthGora";              SkipInstall=$false },
    [pscustomobject]@{ Name="PythonWebOOP_Framework"; Path="E:\SourceCode\PythonWebOOP_Framework"; SkipInstall=$false },
    [pscustomobject]@{ Name="HarnessAI-ToolKIT";      Path="E:\SourceCode\HarnessAI-ToolKIT";      SkipInstall=$true  },
    [pscustomobject]@{ Name="DatabaseManager";        Path="E:\SourceCode\DatabaseManager";        SkipInstall=$false },
    [pscustomobject]@{ Name="CodeProvider";           Path="E:\SourceCode\CodeProvider";           SkipInstall=$false },
    [pscustomobject]@{ Name="AllIn1Site";             Path="E:\SourceCode\AllIn1Site";             SkipInstall=$false }
)

# Files that may be outdated from a previous install -- safe to delete before
# re-install (they have no effect on the running application).
$STALE_FILES = @(
    ".claude\settings.json",           # hooks not wired if this was from an old install
    ".claude\settings.posix.json",     # posix variant
    "tools\harness-bundle\install.ps1",# in-project copy outdated after bundle repack
    "tools\harness-bundle\install.sh"
)

# ---------------------------------------------------------------------------
function Write-Header($msg) { Write-Host "`n$msg" -ForegroundColor Cyan }
function Write-Step($msg)   { Write-Host "  $msg" -ForegroundColor DarkGray }
function Write-Ok($msg)     { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Write-Warn($msg)   { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail($msg)   { Write-Host "  [FAIL] $msg" -ForegroundColor Red }

$width = 30
Write-Host "`n#######################################################" -ForegroundColor Cyan
Write-Host "#  Harness ToolKit — Batch Install" -ForegroundColor Cyan
Write-Host "#  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
if ($VerifyOnly) { Write-Host "#  Mode: VERIFY ONLY (no install)" -ForegroundColor Yellow }
Write-Host "#######################################################`n" -ForegroundColor Cyan

$results = [ordered]@{}

foreach ($proj in $PROJECTS) {
    Write-Host ("-" * 54) -ForegroundColor DarkGray
    Write-Host "  $($proj.Name)" -ForegroundColor White
    Write-Host "  $($proj.Path)" -ForegroundColor DarkGray

    # 1. Check directory exists
    if (-not (Test-Path $proj.Path)) {
        Write-Fail "Directory not found -- skipping"
        $results[$proj.Name] = "DIR_NOT_FOUND"
        continue
    }

    $installOk = $true

    # 2. Install (unless VerifyOnly or SkipInstall)
    if (-not $VerifyOnly -and -not $proj.SkipInstall) {

        # Remove stale files so they get re-written cleanly
        foreach ($rel in $STALE_FILES) {
            $full = Join-Path $proj.Path $rel
            if (Test-Path $full) {
                Remove-Item $full -Force
                Write-Step "removed stale: $rel"
            }
        }

        Write-Step "installing..."
        $out = & powershell -NoProfile -File $INSTALL `
                   -BundleFile $BUNDLE -TargetDir $proj.Path -MergeClaude 2>&1
        foreach ($line in $out) { Write-Step $line }

        if ($LASTEXITCODE -ne 0) {
            Write-Fail "install.ps1 exited $LASTEXITCODE"
            $results[$proj.Name] = "INSTALL_FAILED"
            $installOk = $false
        }
    } elseif ($proj.SkipInstall) {
        Write-Step "install skipped (harness source repo)"
    } else {
        Write-Step "install skipped (--VerifyOnly)"
    }

    # 3. Verify
    if ($installOk) {
        Write-Step "verifying..."
        $vout = & powershell -NoProfile -File $VERIFY -TargetDir $proj.Path 2>&1
        $vtxt = $vout -join "`n"

        if ($vtxt -match "RESULT: APPLIED OK") {
            # Surface the files/hooks summary lines (compact)
            $summary = ($vout | Where-Object { $_ -match "files:|hooks:" }) -join "  "
            Write-Ok "APPLIED OK  |  $summary"
            $results[$proj.Name] = "OK"
        } else {
            # Print modified/missing details
            $issues = $vout | Where-Object { $_ -match "(modified|missing|\[!\])" }
            Write-Fail "NOT FULLY APPLIED"
            foreach ($i in $issues) { Write-Warn "  $i" }
            $results[$proj.Name] = "VERIFY_FAILED"
        }
    }
}

# ---------------------------------------------------------------------------
# Summary table
Write-Host "`n#######################################################" -ForegroundColor Cyan
Write-Host "#  SUMMARY" -ForegroundColor Cyan
Write-Host "#######################################################" -ForegroundColor Cyan

$okCount = 0; $failCount = 0
foreach ($kv in $results.GetEnumerator()) {
    $name = $kv.Key
    $s    = $kv.Value
    $pad  = $name.PadRight($width)
    switch ($s) {
        "OK"             { Write-Host "  $pad  APPLIED OK"    -ForegroundColor Green;  $okCount++ }
        "DIR_NOT_FOUND"  { Write-Host "  $pad  DIR NOT FOUND" -ForegroundColor Yellow; $failCount++ }
        "INSTALL_FAILED" { Write-Host "  $pad  INSTALL FAILED"-ForegroundColor Red;    $failCount++ }
        "VERIFY_FAILED"  { Write-Host "  $pad  VERIFY FAILED" -ForegroundColor Red;    $failCount++ }
        default          { Write-Host "  $pad  $s"            -ForegroundColor Yellow; $failCount++ }
    }
}

$color = if ($failCount -eq 0) { "Green" } else { "Yellow" }
Write-Host "`n  $okCount / $($PROJECTS.Count) projects APPLIED OK  |  $failCount issues" -ForegroundColor $color

if ($failCount -gt 0) {
    Write-Host @"

  Common fixes:
    VERIFY_FAILED (only contracts/project.yaml modified) -> expected, set project name in that file
    VERIFY_FAILED (hooks not wired) -> re-run this script (settings.json will be replaced)
    DIR_NOT_FOUND -> check the path in the PROJECTS list above
"@ -ForegroundColor DarkGray
}
Write-Host ""
