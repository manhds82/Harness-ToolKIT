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
    # Project the common governance text into every agent-guide file the project
    # uses (CLAUDE.md, AGENTS.md, .github/copilot-instructions.md, ... - the list
    # is data, see casan-policies.yaml governance.guide_targets). The old name is
    # kept so existing callers/scripts keep working.
    [Alias("MergeClaude")]
    [switch]$MergeGuides = $false,
    # Stamp the project's identity into contracts/project.yaml on install.
    [string]$ProjectName = "",
    [string]$ProjectDescription = "",
    # By default identity is only written when the file still carries the shipped
    # placeholder, so a project that named itself is never renamed behind its back.
    [switch]$ForceIdentity = $false
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

# Files the project owns: never overwritten once they exist, not even with
# -Force, because they carry per-project decisions. When the shipped copy has
# moved on, drop a `<file>.new` beside it so new keys can be adopted on purpose.
$preserve = @()
if ($bundle.PSObject.Properties.Name -contains 'preserve' -and $bundle.preserve) { $preserve = @($bundle.preserve) }

$written = 0; $skipped = 0; $kept = 0
foreach ($f in $bundle.files) {
    $dest = Join-Path $TargetDir ($f.path -replace '/', '\')
    $bytes = [Convert]::FromBase64String($f.b64)

    if ((Test-Path $dest) -and ($preserve -contains $f.path)) {
        $same = $false
        try { $same = [System.Linq.Enumerable]::SequenceEqual([byte[]](Get-Content -Path $dest -Encoding Byte -Raw), $bytes) } catch { }
        if (-not $same) {
            [System.IO.File]::WriteAllBytes("$dest.new", $bytes)
            Write-Output "  [KEEP]  $($f.path) (yours; shipped copy saved as $($f.path).new)"
        } else {
            Write-Output "  [KEEP]  $($f.path) (yours; identical to shipped)"
        }
        $kept++
        continue
    }
    if ((Test-Path $dest) -and -not $Force) {
        Write-Output "  [SKIP] $($f.path) (exists; use -Force to overwrite)"
        $skipped++
        continue
    }
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($dest, $bytes)
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

Write-Output "[install] done: $written written, $skipped skipped, $kept kept (project-owned). Integrity OK ($($bundle.content_hash))."

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

# --- Project identity: stamp name/description into contracts/project.yaml ---
# Patches ONLY the two scalars inside the `project:` block, so comments and every
# other key in the contract survive untouched.
function Set-ProjectIdentity {
    param([string]$Path, [string]$Name, [string]$Description, [bool]$Force)
    if (-not (Test-Path $Path)) { return "no-contract" }
    $lines = [System.IO.File]::ReadAllText($Path, $Utf8NoBom) -split "`r?`n"
    $inProject = $false; $changed = $false; $curName = ""
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^project:\s*$') { $inProject = $true; continue }
        if ($inProject) {
            if ($lines[$i] -match '^\S') { break }                      # dedent = block ended
            if ($lines[$i] -match '^(\s+)name:\s*(.*)$') { $curName = $matches[2].Trim().Trim('"') }
        }
    }
    # The shipped contract carries the toolkit's own identity; treat that (and an
    # empty name) as "not yet claimed by this project". A name starting with "-"
    # is never legitimate -- it can only come from an argument-binding slip -- so
    # treat it as unclaimed too and let a re-run repair it.
    $isPlaceholder = ($curName -eq "" -or $curName -eq "harness-toolkit" -or
                      $curName -eq "my-project" -or $curName.StartsWith("-"))
    if (-not $Force -and -not $isPlaceholder) { return "kept:$curName" }

    $inProject = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^project:\s*$') { $inProject = $true; continue }
        if ($inProject) {
            if ($lines[$i] -match '^\S') { break }
            if ($lines[$i] -match '^(\s+)name:\s*') {
                $lines[$i] = "$($matches[1])name: `"$Name`""; $changed = $true
            } elseif ($lines[$i] -match '^(\s+)description:\s*') {
                $lines[$i] = "$($matches[1])description: `"$Description`""; $changed = $true
            }
        }
    }
    if (-not $changed) { return "no-fields" }
    [System.IO.File]::WriteAllText($Path, ($lines -join "`n"), $Utf8NoBom)
    return "set"
}

if ($ProjectName) {
    if (-not $ProjectDescription) { $ProjectDescription = $ProjectName }
    $contract = Join-Path $TargetDir "contracts\project.yaml"
    $r = Set-ProjectIdentity -Path $contract -Name $ProjectName -Description $ProjectDescription -Force:$ForceIdentity
    switch -Wildcard ($r) {
        "set"          { Write-Output "[identity] contracts/project.yaml -> name/description = '$ProjectName'" }
        "kept:*"       { Write-Output "[identity] kept existing project name '$($r.Substring(5))' (use -ForceIdentity to overwrite)" }
        "no-contract"  { Write-Warning "[identity] contracts/project.yaml not found -- skipped" }
        default        { Write-Warning "[identity] could not find name/description under 'project:' -- skipped" }
    }
}

# --- Project the common governance text into every agent-guide file ---
# ONE canonical source (CLAUDE.harness.md) -> many tool-specific files. The block
# is delimited, so re-installing REPLACES only the managed block and never
# touches whatever the project wrote around it.
if ($MergeGuides) {
    $harnessMd = Join-Path $TargetDir "CLAUDE.harness.md"
    if (-not (Test-Path $harnessMd)) {
        Write-Warning "[guides] CLAUDE.harness.md not found in target -- skipping (bundle may not ship it)"
    } else {
        $govText = ([System.IO.File]::ReadAllText($harnessMd, $Utf8NoBom)).Trim()

        # C2: the target list is data, not code. Falls back to the common trio.
        $targets = @()
        $policy = Join-Path $TargetDir ".harness\control\casan-policies.yaml"
        if (Test-Path $policy) {
            $inBlock = $false
            foreach ($line in (Get-Content $policy -Encoding utf8)) {
                if ($line -match '^\s*guide_targets:\s*(#.*)?$') { $inBlock = $true; continue }
                if ($inBlock) {
                    if ($line -match '^\s*#') { continue }
                    if ($line -match '^\s*-\s*(.+?)\s*$') {
                        $v = ($matches[1] -replace '\s+#.*$', '').Trim().Trim('"').Trim("'")
                        if ($v) { $targets += $v }
                    } elseif ($line -match '\S') { break }
                }
            }
        }
        if (-not $targets) { $targets = @("CLAUDE.md", "AGENTS.md", ".github/copilot-instructions.md") }

        $begin = "<!-- BEGIN harness-governance -->"
        $end   = "<!-- END harness-governance -->"
        $note  = "<!-- standard-governance v$($bundle.version) - MANAGED BLOCK. Edits inside are replaced on the next install; put your own project rules OUTSIDE this block. -->"
        $block = "$begin`n$note`n`n$govText`n`n$end"

        foreach ($rel in $targets) {
            $p = Join-Path $TargetDir ($rel -replace '/', '\')
            $dir = Split-Path -Parent $p
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            if (-not (Test-Path $p)) {
                [System.IO.File]::WriteAllText($p, $block + "`n", $Utf8NoBom)
                Write-Output "[guides] created $rel"
                continue
            }
            $existing = [System.IO.File]::ReadAllText($p, $Utf8NoBom)
            # LastIndexOf for the closing marker: if the governance text (or the
            # project's own notes) ever mentions the marker inside the block, a
            # first-match search would cut the block short and leave orphaned text
            # behind on every refresh.
            $bi = $existing.IndexOf($begin); $ei = $existing.LastIndexOf($end)
            if ($bi -ge 0 -and $ei -gt $bi) {
                $pre = $existing.Substring(0, $bi)
                $post = $existing.Substring($ei + $end.Length)
                [System.IO.File]::WriteAllText($p, $pre + $block + $post, $Utf8NoBom)
                Write-Output "[guides] refreshed managed block in $rel"
            } elseif ($existing -match '<!--\s*harness:merged\s*-->') {
                # Pre-1.5.0 merge appended the governance text with only a start
                # sentinel and ran to EOF, so it could never be refreshed. Convert
                # it: keep everything BEFORE the sentinel (that is the project's
                # own content) and re-emit the governance as a managed block.
                # A one-time .bak makes the conversion reversible.
                $mm = [regex]::Match($existing, '(?m)^\s*-{3,}\s*\r?\n<!--\s*harness:merged\s*-->')
                if (-not $mm.Success) { $mm = [regex]::Match($existing, '<!--\s*harness:merged\s*-->') }
                $bak = "$p.pre-migration.bak"
                if (-not (Test-Path $bak)) { [System.IO.File]::WriteAllText($bak, $existing, $Utf8NoBom) }
                $pre = $existing.Substring(0, $mm.Index).TrimEnd()
                [System.IO.File]::WriteAllText($p, $pre + "`n`n---`n`n" + $block + "`n", $Utf8NoBom)
                Write-Output "[guides] migrated legacy block in $rel -> managed block (backup: $rel.pre-migration.bak)"
            } else {
                [System.IO.File]::WriteAllText($p, $existing.TrimEnd() + "`n`n---`n`n" + $block + "`n", $Utf8NoBom)
                Write-Output "[guides] appended governance to existing $rel (your content untouched)"
            }
        }
    }
}

# --- Cleanup temp download if used ---
if ($TempDownload -and (Test-Path $TempDownload)) { Remove-Item $TempDownload -Force }
