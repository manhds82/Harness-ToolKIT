#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Harness Bundle installer (L5 -- distribution layer).
  Materializes a packed .bundle.json into a target project (byte-exact),
  after verifying its content hash -- the "npm install" analog. This is the
  governed evolution of harness-init: instead of hardcoded templates, it
  installs a named, versioned, hash-verified bundle.
.USAGE
  .\install.ps1 -BundleFile <x.bundle.json> -TargetDir <project dir> [-Force] [-MergeClaude]

  -MergeClaude  After installing, automatically merge CLAUDE.harness.md into
                CLAUDE.md of the target project.
                  * If CLAUDE.md does not exist: creates it from CLAUDE.harness.md.
                  * If CLAUDE.md exists but has no harness section: appends the
                    harness content with a <!-- harness:merged --> sentinel (safe
                    to re-run -- the sentinel prevents double-merging).
                  * If sentinel is already present: skips silently.
#>
param(
    [string]$BundleFile = "",
    [string]$TargetDir  = ".",
    [switch]$Force = $false,
    [switch]$MergeClaude = $false
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Sha256HexOf([byte[]]$Bytes) {
    $s = [System.Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($s.ComputeHash($Bytes)) -replace '-', '').ToLower()
}

# --- Auto-find newest bundle if not specified ---
if (-not $BundleFile) {
    $found = Get-ChildItem -Recurse -Filter "*.bundle.json" -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $found) { throw "No .bundle.json found. Specify -BundleFile <path-or-url>." }
    $BundleFile = $found.FullName
    Write-Output "[install] Auto-selected bundle: $BundleFile"
}

# --- Download if URL ---
$TempDownload = $null
if ($BundleFile -match '^https?://') {
    $TempDownload = [System.IO.Path]::GetTempFileName() + ".bundle.json"
    Write-Output "[install] Downloading bundle from $BundleFile ..."
    Invoke-WebRequest -Uri $BundleFile -OutFile $TempDownload -UseBasicParsing
    $BundleFile = $TempDownload
}

if (-not (Test-Path $BundleFile)) { throw "Bundle file not found: $BundleFile" }
$bundle = Get-Content -Path $BundleFile -Raw -Encoding utf8 | ConvertFrom-Json

# --- Verify content hash before writing anything (fail-closed integrity) ---
$hashInput = ($bundle.files | ForEach-Object { "$($_.path):$($_.b64)" }) -join "`n"
$sha = [System.Security.Cryptography.SHA256]::Create()
$computed = ([BitConverter]::ToString($sha.ComputeHash($Utf8NoBom.GetBytes($hashInput))) -replace '-', '').ToLower()
if ($computed -ne $bundle.content_hash) {
    throw "Bundle integrity check FAILED: computed $computed != declared $($bundle.content_hash)"
}

Write-Output "[install] $($bundle.name) v$($bundle.version) ($($bundle.file_count) files) -> $TargetDir"
if (-not (Test-Path $TargetDir)) { New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null }

$written = 0; $skipped = 0
foreach ($f in $bundle.files) {
    $dest = Join-Path $TargetDir ($f.path -replace '/', '\')
    if ((Test-Path $dest) -and -not $Force) {
        Write-Output "  [SKIP] $($f.path) (exists; use -Force to overwrite)"
        $skipped++
        continue
    }
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($dest, [Convert]::FromBase64String($f.b64))
    Write-Output "  [WRITE] $($f.path)"
    $written++
}

# --- Install receipt: lets the in-project uninstaller know exactly what this
# bundle placed (path + original sha256), so uninstall works without the
# original .bundle.json and can tell pristine files from user-edited ones. ---
$manifestFiles = foreach ($f in $bundle.files) {
    $bytes = [Convert]::FromBase64String($f.b64)
    [ordered]@{ path = $f.path; sha256 = (Sha256HexOf $bytes) }
}
$receiptDir = Join-Path $TargetDir ".harness"
if (-not (Test-Path $receiptDir)) { New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null }
$receipt = [ordered]@{
    name         = $bundle.name
    version      = $bundle.version
    content_hash = $bundle.content_hash
    installed_at = (Get-Date -Format 'o')
    files        = @($manifestFiles)
} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText((Join-Path $receiptDir ".bundle-manifest.json"), $receipt, $Utf8NoBom)

Write-Output "[install] done: $written written, $skipped skipped. Integrity OK ($($bundle.content_hash))."

# --- Portal-sync scaffold: create the two files a newcomer would otherwise
# have to hand-author, at the right location, ready to edit. NEVER overwrite an
# existing file (a real ingest key / configured project_id is preserved). These
# are exactly what push-telemetry.ps1 reads to sync telemetry to the Portal. ---
$syncDir = Join-Path $TargetDir ".harness"
if (-not (Test-Path $syncDir)) { New-Item -ItemType Directory -Path $syncDir -Force | Out-Null }

$syncJson = Join-Path $syncDir "portal-sync.json"
if (-not (Test-Path $syncJson)) {
    $syncTmpl = @"
{
  "_README": "Fill portal_url and project_id from your Control Portal (open the Project, then Settings, then Reveal ingest key). Next, paste the ingest key into portal-sync.key in THIS same .harness folder. Set pdp_enforce to true to make the PreToolUse hook consult the Portal PDP (H4 outbound allowlist, H5 approval, H3 release gate) -- leave false to keep it off. You may delete this _README line.",
  "portal_url": "https://YOUR-PORTAL-DOMAIN",
  "project_id": "PASTE-PROJECT-ID-HERE",
  "pdp_enforce": false,
  "member_email": ""
}
"@
    [System.IO.File]::WriteAllText($syncJson, $syncTmpl, $Utf8NoBom)
    Write-Output "[scaffold] created .harness\portal-sync.json  -> EDIT portal_url + project_id"
} else {
    Write-Output "[scaffold] .harness\portal-sync.json already exists -> kept"
}

$syncKey = Join-Path $syncDir "portal-sync.key"
if (-not (Test-Path $syncKey)) {
    [System.IO.File]::WriteAllText($syncKey, "", $Utf8NoBom)
    Write-Output "[scaffold] created empty .harness\portal-sync.key -> PASTE ingest key here (1 line)"
} else {
    Write-Output "[scaffold] .harness\portal-sync.key already exists -> kept"
}

# --- Buglist scaffold (M6): every project gets a living buglist.md at its root
# from the shipped template, so AI has a mandated place to log bugs (system OR
# AI-introduced). NEVER overwrite an existing buglist. ---
$bugFile = Join-Path $TargetDir "buglist.md"
$bugTmpl = Join-Path $syncDir "templates\buglist.md"
if (-not (Test-Path $bugFile)) {
    if (Test-Path $bugTmpl) {
        $t = (Get-Content $bugTmpl -Raw -Encoding utf8).Replace("<PROJECT>", (Split-Path $TargetDir -Leaf))
        [System.IO.File]::WriteAllText($bugFile, $t, $Utf8NoBom)
        Write-Output "[scaffold] created buglist.md (log every bug here -- see rule in the file)"
    }
} else {
    Write-Output "[scaffold] buglist.md already exists -> kept"
}

# C5: never commit the ingest key. Ensure the target project's .gitignore
# ignores it (idempotent -- add the line only if missing).
$giPath = Join-Path $TargetDir ".gitignore"
$giLine = ".harness/portal-sync.key"
$giHas = (Test-Path $giPath) -and (Select-String -Path $giPath -SimpleMatch $giLine -Quiet)
if (-not $giHas) {
    Add-Content -Path $giPath -Value "`n# Harness Portal ingest key - secret, never commit (C5)`n$giLine" -Encoding utf8
    Write-Output "[scaffold] added portal-sync.key to .gitignore (C5)"
}

# --- H1 scaffold: build the context pointer store so a freshly-onboarded project
# satisfies its own context contract right away (the policy-ci suite asserts it,
# and the release gate would otherwise block until the first session ran the
# hook). Best-effort: a failure here must never fail the install.
$ctxBuild = Join-Path $TargetDir ".harness\scripts\powershell\harness-context-build.ps1"
$ctxStore = Join-Path $TargetDir ".harness\context\pipeline-context.yaml"
if ((Test-Path $ctxBuild) -and (-not (Test-Path $ctxStore))) {
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $ctxBuild -HarnessRoot $TargetDir *> $null
        if (Test-Path $ctxStore) { Write-Output "[scaffold] built .harness\context\pipeline-context.yaml (H1)" }
    } catch {
        Write-Warning "[scaffold] could not build the H1 pointer store (non-fatal): $($_.Exception.Message)"
    }
}

# --- Auto-merge CLAUDE.harness.md -> CLAUDE.md (-MergeClaude) ---
if ($MergeClaude) {
    $harnessMd = Join-Path $TargetDir "CLAUDE.harness.md"
    $claudeMd  = Join-Path $TargetDir "CLAUDE.md"
    if (-not (Test-Path $harnessMd)) {
        Write-Warning "[merge] CLAUDE.harness.md not found in target -- skipping (bundle may not ship it)"
    } else {
        $harnessContent = [System.IO.File]::ReadAllText($harnessMd, $Utf8NoBom)
        if (-not (Test-Path $claudeMd)) {
            [System.IO.File]::WriteAllText($claudeMd, $harnessContent, $Utf8NoBom)
            Write-Output "[MERGE] created CLAUDE.md from CLAUDE.harness.md"
        } else {
            $existing = [System.IO.File]::ReadAllText($claudeMd, $Utf8NoBom)
            if ($existing -match '<!--\s*harness:merged\s*-->') {
                Write-Output "[SKIP]  CLAUDE.md already contains harness governance (sentinel found -- skipping)"
            } else {
                $sep = "`n`n---`n<!-- harness:merged -->`n`n"
                [System.IO.File]::WriteAllText($claudeMd, $existing.TrimEnd() + $sep + $harnessContent, $Utf8NoBom)
                Write-Output "[MERGE] appended harness governance to existing CLAUDE.md"
            }
        }
    }
}

# --- Cleanup temp download if used ---
if ($TempDownload -and (Test-Path $TempDownload)) { Remove-Item $TempDownload -Force }
