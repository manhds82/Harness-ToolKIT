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
    [switch]$ForceIdentity = $false,
    # Show exactly what an install WOULD do -- per file: WRITE / KEEP / SKIP /
    # MERGE-CONFLICT -- and write nothing. Every consuming team asked for this:
    # they wanted to see the blast radius before committing to it.
    [switch]$DryRun = $false
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

# Shared by the payload parse and the installer-side fallback below. Returns the
# four rule collections and prints nothing -- a Write-Output in here would join
# the return value (the push-telemetry.ps1 lesson).
function Read-OwnershipRules([string]$Text) {
    $r = @{ Owned = @(); Globs = @(); Keyed = @{}; Merge = @{} }
    $section = ''
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^([a-z_]+):\s*$') { $section = $matches[1]; continue }
        if ($line -match '^[a-z_]+:') { $section = ''; continue }
        if ($section -eq 'project_owned' -and $line -match '^\s+-\s*"?([^"]+?)"?\s*$') { $r.Owned += $matches[1] }
        if ($section -eq 'project_owned_globs' -and $line -match '^\s+-\s*"?([^"]+?)"?\s*$') { $r.Globs += $matches[1] }
        if ($section -eq 'keyed_lists' -and $line -match '^\s+"([^"]+)":\s*"([^"]+)"') { $r.Keyed[$matches[1]] = $matches[2] }
        if ($section -eq 'merge_json_maps' -and $line -match '^\s+"([^"]+)":\s*"([^"]+)"') { $r.Merge[$matches[1]] = $matches[2] }
    }
    return $r
}

# --- Ownership rules (C2): read from the bundle's OWN payload, before anything is
# written, so the rules that govern this install are the ones this bundle shipped
# -- not whatever an older copy left on disk. Absent file = fall back to
# bundle.yaml's `preserve` alone, i.e. exactly the previous behaviour.
$ownGlobs = @(); $keyedLists = @{}; $mergeMaps = @{}
$ownEntry = $bundle.files | Where-Object { $_.path -eq '.harness/control/bundle-ownership.yaml' } | Select-Object -First 1
if ($ownEntry) {
    try {
        $rules = Read-OwnershipRules ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ownEntry.b64)))
        $preserve += $rules.Owned; $ownGlobs += $rules.Globs
        $keyedLists = $rules.Keyed; $mergeMaps = $rules.Merge
        $preserve = @($preserve | Select-Object -Unique)
    } catch {
        Write-Output "[own] WARNING: bundle-ownership.yaml unreadable ($($_.Exception.Message)); falling back to preserve list only"
    }
}

# A bundle packed before a rule existed must not reopen the loss that rule
# prevents: v1.6.0 ships no merge_json_maps, so governed by its payload alone it
# would still overwrite tool-registry.json -- the exact defect. So the rules
# that travel BESIDE this installer (../../.harness/control/, in this repo and
# in an installed project alike) are unioned in. A union can only protect more
# than the bundle asked, never less, and the bundle stays authoritative wherever
# both copies define the same path, so a future bundle can still re-scope a rule
# on purpose. No file there is the standalone-installer case and means "bundle
# rules only" -- the previous behaviour, silently.
$installerRules = $null
try { $installerRules = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) ".harness\control\bundle-ownership.yaml" } catch { }
if ($installerRules -and (Test-Path $installerRules)) {
    try {
        $mine = Read-OwnershipRules ([System.IO.File]::ReadAllText($installerRules, $Utf8NoBom))
        $newer = @()
        foreach ($p in $mine.Owned) { if ($preserve -notcontains $p) { $preserve += $p; $newer += "project_owned:$p" } }
        foreach ($g in $mine.Globs) { if ($ownGlobs -notcontains $g) { $ownGlobs += $g; $newer += "project_owned_globs:$g" } }
        foreach ($k in (@($mine.Keyed.Keys) | Sort-Object)) { if (-not $keyedLists.ContainsKey($k)) { $keyedLists[$k] = $mine.Keyed[$k]; $newer += "keyed_lists:$k" } }
        foreach ($k in (@($mine.Merge.Keys) | Sort-Object)) { if (-not $mergeMaps.ContainsKey($k)) { $mergeMaps[$k] = $mine.Merge[$k]; $newer += "merge_json_maps:$k" } }
        if ($newer.Count -gt 0) {
            Write-Output "[own] this bundle predates $($newer.Count) ownership rule(s); applied from the installer's copy: $($newer -join ', ')"
        }
    } catch {
        Write-Output "[own] WARNING: installer-side bundle-ownership.yaml unreadable ($($_.Exception.Message)); using the bundle's own rules only"
    }
}

# --- Tamper detection (C9-adjacent): the PREVIOUS install's receipt already
# records a sha256 per shipped file. Comparing it to what is on disk now answers
# the question `preserve` never could -- "did the project hand-edit a file the
# bundle owns?" Overwriting that silently is how four separate teams lost work.
$prevHashes = @{}
$prevReceipt = Join-Path $TargetDir ".harness\.bundle-manifest.json"
if (Test-Path $prevReceipt) {
    try {
        $pr = Get-Content -Path $prevReceipt -Raw -Encoding utf8 | ConvertFrom-Json
        # Prefer installed_sha256 -- what the LAST install left on disk. Fall back
        # to sha256 (shipped bytes) only for receipts written before that field
        # existed, where it is the best baseline available.
        foreach ($e in @($pr.files)) {
            if ($e.path) {
                $h = if ($e.PSObject.Properties.Name -contains 'installed_sha256' -and $e.installed_sha256) { "$($e.installed_sha256)" } else { "$($e.sha256)" }
                $prevHashes[$e.path] = $h
            }
        }
    } catch { }   # unreadable receipt just means "no baseline" -- never fatal
}

function Test-OwnedGlob([string]$Path, [string[]]$Globs) {
    foreach ($g in $Globs) {
        # Match the full relative path AND the bare filename, so a convention like
        # "project-*" or "*.local.*" applies at any depth without the rule author
        # having to spell out a directory prefix.
        if ($Path -like $g) { return $true }
        if ((Split-Path -Leaf $Path) -like $g) { return $true }
    }
    return $false
}

# Item keys of a keyed YAML list, by line scan. No YAML module exists on PS 5.1,
# and this only has to recognize the shape the bundle itself ships: a top-level
# `<list>:` followed by `  - <key>: value` items.
function Get-ListKeys([string]$Text, [string]$ListKey, [string]$ItemKey) {
    $keys = @(); $inList = $false
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match "^$([regex]::Escape($ListKey)):\s*$") { $inList = $true; continue }
        if ($inList -and $line -match '^[A-Za-z0-9_]+:') { $inList = $false; continue }
        if ($inList -and $line -match "^\s+-\s+$([regex]::Escape($ItemKey)):\s*`"?([^`"#]+?)`"?\s*$") {
            $keys += $matches[1].Trim()
        }
    }
    return $keys
}

# --- JSON writer used by the merge below --------------------------------------
# Emits byte-for-byte what python's json.dumps(obj, indent=2, ensure_ascii=False)
# emits, because install.sh does the same merge in python. C7 parity has to hold
# at the BYTE level here: the merged file is re-hashed into the install receipt,
# so two spellings of the same content would make the next run of the OTHER
# installer report a hand-edit that never happened. ConvertTo-Json cannot be used
# -- PS 5.1 indents with 4 spaces, doubles the space after ':' and escapes every
# non-ASCII char, none of which python does.
function ConvertTo-HarnessJsonString([string]$S) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($c in $S.ToCharArray()) {
        $n = [int]$c
        if     ($c -eq '"')  { [void]$sb.Append('\"') }
        elseif ($c -eq '\')  { [void]$sb.Append('\\') }
        elseif ($n -eq 8)    { [void]$sb.Append('\b') }
        elseif ($n -eq 9)    { [void]$sb.Append('\t') }
        elseif ($n -eq 10)   { [void]$sb.Append('\n') }
        elseif ($n -eq 12)   { [void]$sb.Append('\f') }
        elseif ($n -eq 13)   { [void]$sb.Append('\r') }
        elseif ($n -lt 32)   { [void]$sb.Append(('\u{0:x4}' -f $n)) }
        else                 { [void]$sb.Append($c) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-HarnessJson($Value, [int]$Indent = 0) {
    $pad = ' ' * $Indent
    $pad2 = ' ' * ($Indent + 2)
    if ($null -eq $Value)   { return 'null' }
    if ($Value -is [bool])  { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) { return (ConvertTo-HarnessJsonString $Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return '{}' }
        $parts = @()
        foreach ($k in $Value.Keys) {
            $parts += "$pad2$(ConvertTo-HarnessJsonString ([string]$k)): $(ConvertTo-HarnessJson $Value[$k] ($Indent + 2))"
        }
        return "{`n" + ($parts -join ",`n") + "`n$pad}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = @()
        foreach ($i in $items) { $parts += "$pad2$(ConvertTo-HarnessJson $i ($Indent + 2))" }
        return "[`n" + ($parts -join ",`n") + "`n$pad]"
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return ([double]$Value).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return ([string]$Value)
}

# ConvertFrom-Json hands back PSCustomObject, which the writer above cannot walk
# in document order without this. Order matters: the merged file must come out
# identical on a re-run, or every install would look like a change.
function ConvertTo-OrderedTree($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $o = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $o[$p.Name] = ConvertTo-OrderedTree $p.Value }
        return $o
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in @($Value.Keys)) { $o[[string]$k] = ConvertTo-OrderedTree $Value[$k] }
        return $o
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $a = @()
        foreach ($i in $Value) { $a += ,(ConvertTo-OrderedTree $i) }
        return ,$a
    }
    return $Value
}

# Field-level merge of a JSON object map (bundle-ownership.yaml merge_json_maps).
# Returns a result object and writes NOTHING to the output stream: a Write-Output
# inside a function joins the function's return value, and that exact mistake
# already shipped once in push-telemetry.ps1 (a status line serialized into a
# JSON field and the server 422'd the push). The caller prints; this only decides.
function Merge-JsonEntryMap {
    param([string]$DiskText, [string]$ShipText, [string]$MapKey)

    $fail = { param($why) [pscustomobject]@{ Ok = $false; Reason = $why } }
    try { $diskObj = ConvertTo-OrderedTree ($DiskText | ConvertFrom-Json) }
    catch { return (& $fail "could not parse your copy as JSON") }
    try { $shipObj = ConvertTo-OrderedTree ($ShipText | ConvertFrom-Json) }
    catch { return (& $fail "could not parse the shipped copy as JSON") }
    if (-not ($diskObj -is [System.Collections.IDictionary])) { return (& $fail "could not parse your copy as JSON") }
    if (-not ($shipObj -is [System.Collections.IDictionary])) { return (& $fail "could not parse the shipped copy as JSON") }
    if (-not $shipObj.Contains($MapKey)) { return (& $fail "the shipped copy has no '$MapKey' object") }

    $shipMap = $shipObj[$MapKey]
    if (-not ($shipMap -is [System.Collections.IDictionary])) { return (& $fail "the shipped copy has no '$MapKey' object") }
    $diskMap = $null
    if ($diskObj.Contains($MapKey) -and ($diskObj[$MapKey] -is [System.Collections.IDictionary])) { $diskMap = $diskObj[$MapKey] }

    $addedNames = @(); $yours = @(); $overrides = @(); $extraTop = @()
    $updated = 0; $fields = 0; $entries = 0

    $mergedMap = [ordered]@{}
    foreach ($name in @($shipMap.Keys)) {
        $shipEntry = $shipMap[$name]
        if ($null -eq $diskMap -or -not $diskMap.Contains($name)) {
            $mergedMap[$name] = $shipEntry
            $addedNames += $name
            continue
        }
        $diskEntry = $diskMap[$name]
        if (-not ($shipEntry -is [System.Collections.IDictionary]) -or -not ($diskEntry -is [System.Collections.IDictionary])) {
            # Not an object on one side -- nothing to merge field-wise, bundle wins.
            $mergedMap[$name] = $shipEntry
            $updated++
            continue
        }
        $out = [ordered]@{}
        foreach ($k in @($shipEntry.Keys)) { $out[$k] = $shipEntry[$k] }
        $keptFields = 0
        foreach ($k in @($diskEntry.Keys)) {
            if (-not $shipEntry.Contains($k)) {
                # The whole point: a field the bundle has no opinion about.
                $out[$k] = $diskEntry[$k]
                $keptFields++
            } elseif ((ConvertTo-HarnessJson $diskEntry[$k]) -ne (ConvertTo-HarnessJson $shipEntry[$k])) {
                $overrides += "$name.$k"
            }
        }
        if ($keptFields -gt 0) { $fields += $keptFields; $entries++ }
        $mergedMap[$name] = $out
        $updated++
    }
    if ($null -ne $diskMap) {
        foreach ($name in @($diskMap.Keys)) {
            if (-not $shipMap.Contains($name)) { $mergedMap[$name] = $diskMap[$name]; $yours += $name }
        }
    }

    # Top level: the bundle owns its own keys (schema_version, generated_at...),
    # anything the project added beside them is theirs and rides along.
    $root = [ordered]@{}
    foreach ($k in @($shipObj.Keys)) {
        if ($k -eq $MapKey) { $root[$k] = $mergedMap } else { $root[$k] = $shipObj[$k] }
    }
    foreach ($k in @($diskObj.Keys)) {
        if (-not $shipObj.Contains($k)) { $root[$k] = $diskObj[$k]; $extraTop += $k }
    }

    return [pscustomobject]@{
        Ok = $true; Reason = ""
        Text = (ConvertTo-HarnessJson $root 0) + "`n"
        Added = $addedNames.Count; AddedNames = @($addedNames)
        Updated = $updated; Yours = @($yours); Overrides = @($overrides)
        Fields = $fields; Entries = $entries; ExtraTop = @($extraTop)
    }
}

$written = 0; $skipped = 0; $kept = 0; $merged = 0; $conflicts = @(); $merges = @()
foreach ($f in $bundle.files) {
    $dest = Join-Path $TargetDir ($f.path -replace '/', '\')
    $bytes = [Convert]::FromBase64String($f.b64)
    $exists = Test-Path $dest

    # 1) Project-owned, by exact path or by convention glob.
    if ($exists -and (($preserve -contains $f.path) -or (Test-OwnedGlob $f.path $ownGlobs))) {
        $same = $false
        try { $same = [System.Linq.Enumerable]::SequenceEqual([byte[]](Get-Content -Path $dest -Encoding Byte -Raw), $bytes) } catch { }
        if (-not $same) {
            if (-not $DryRun) { [System.IO.File]::WriteAllBytes("$dest.new", $bytes) }
            Write-Output "  [KEEP]  $($f.path) (yours; shipped copy saved as $($f.path).new)"
        } else {
            Write-Output "  [KEEP]  $($f.path) (yours; identical to shipped)"
        }
        $kept++
        continue
    }

    if ($exists) {
        $diskBytes = $null
        try { $diskBytes = [byte[]](Get-Content -Path $dest -Encoding Byte -Raw) } catch { }
        $diskHash = if ($diskBytes) { Sha256HexOf $diskBytes } else { "" }

        # 2) A JSON object map the project may have EXTENDED -- extra FIELDS on
        # entries the bundle ships, and/or entries of its own. Overwriting the
        # whole file is what erased one project's contract/timeout annotations
        # across all 62 registry tools (see merge_json_maps in
        # bundle-ownership.yaml). Merge per entry, per field instead.
        # Runs with or WITHOUT -Force on purpose: the merge cannot lose a field
        # the bundle does not ship, and gating it behind -Force would leave a
        # plain install with a registry that never learns about new tools --
        # which C3 turns into "unknown tool, denied by default" at run time.
        if ($mergeMaps.ContainsKey($f.path) -and $diskBytes) {
            $mk = $mergeMaps[$f.path]
            $res = Merge-JsonEntryMap -DiskText ([System.Text.Encoding]::UTF8.GetString($diskBytes)) `
                                      -ShipText ([System.Text.Encoding]::UTF8.GetString($bytes)) `
                                      -MapKey $mk
            if ($res.Ok) {
                if (-not $DryRun) { [System.IO.File]::WriteAllText($dest, $res.Text, $Utf8NoBom) }
                Write-Output "  [MERGE] $($f.path) ($mk`: $($res.Added) added, $($res.Updated) updated, $(@($res.Yours).Count) yours kept; $($res.Fields) project field(s) preserved on $($res.Entries) entry(ies))"
                if (@($res.Yours).Count -gt 0)      { Write-Output "             kept yours: $(@($res.Yours) -join ', ')" }
                if (@($res.AddedNames).Count -gt 0) { Write-Output "             added by the bundle: $(@($res.AddedNames) -join ', ')" }
                if (@($res.ExtraTop).Count -gt 0)   { Write-Output "             kept your extra top-level key(s): $(@($res.ExtraTop) -join ', ')" }
                # Never silent: these are the only edits of theirs that did NOT
                # survive, so name every one (C10).
                if (@($res.Overrides).Count -gt 0)  { Write-Output "             bundle value wins on $(@($res.Overrides).Count) field(s) you had changed: $(@($res.Overrides) -join ', ')" }
                $merges += "$($f.path): $($res.Fields) project field(s) on $($res.Entries) entry(ies), $(@($res.Yours).Count) project-only entry(ies) kept"
                $merged++
                continue
            }
            # Unparseable on either side, or the shipped copy lost the map: never
            # write a half-merged governance file. Say so and keep theirs.
            if (-not $DryRun) { [System.IO.File]::WriteAllBytes("$dest.new", $bytes) }
            $msg = "$($f.path): $($res.Reason) -- not merged"
            Write-Output "  [CONFLICT] $msg"
            Write-Output "             kept yours; shipped copy is $($f.path).new"
            $conflicts += $msg
            $kept++
            continue
        }

        # 3) A keyed list the project may have EXTENDED. Overwriting is right for
        # the shipped entries and destructive for the project's own, so when the
        # project has entries the bundle does not ship, stop and name them.
        # Deliberately a conflict, not an auto-merge: guessing where to splice a
        # YAML item risks a broken pipeline that still validates (C10).
        if ($keyedLists.ContainsKey($f.path) -and $diskBytes) {
            $spec = $keyedLists[$f.path] -split ':', 2
            $mineText = [System.Text.Encoding]::UTF8.GetString($diskBytes)
            $shipText = [System.Text.Encoding]::UTF8.GetString($bytes)
            $mine = @(Get-ListKeys $mineText $spec[0] $spec[1])
            $ship = @(Get-ListKeys $shipText $spec[0] $spec[1])
            $extra = @($mine | Where-Object { $ship -notcontains $_ })
            if ($extra.Count -gt 0) {
                if (-not $DryRun) { [System.IO.File]::WriteAllBytes("$dest.new", $bytes) }
                $msg = "$($f.path): your $($spec[0]) has $($extra.Count) entry(ies) the bundle does not ship -- $($extra -join ', ')"
                Write-Output "  [CONFLICT] $msg"
                Write-Output "             kept yours; shipped copy is $($f.path).new -- carry those entries over by hand"
                $conflicts += $msg
                $kept++
                continue
            }
        }

        # 4) A bundle-owned file the project hand-edited since the last install.
        # Only claimable when a baseline exists; with no receipt we cannot tell an
        # edit from a first install, and guessing would either cry wolf or hide it.
        if ($prevHashes.ContainsKey($f.path) -and $diskHash -and
            $prevHashes[$f.path] -and $diskHash -ne $prevHashes[$f.path]) {
            if (-not $DryRun) { [System.IO.File]::WriteAllBytes("$dest.new", $bytes) }
            $msg = "$($f.path): edited by hand since the last install (sha differs from the recorded baseline)"
            Write-Output "  [CONFLICT] $msg"
            Write-Output "             kept yours; shipped copy is $($f.path).new"
            $conflicts += $msg
            $kept++
            continue
        }

        if (-not $Force) {
            Write-Output "  [SKIP] $($f.path) (exists; use -Force to overwrite)"
            $skipped++
            continue
        }
    }

    if ($DryRun) {
        Write-Output "  [WRITE] $($f.path)"
    } else {
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($dest, $bytes)
        Write-Output "  [WRITE] $($f.path)"
    }
    $written++
}

# --- Summary. Conflicts are listed again, by name: a count alone reads as "all
# fine" and the whole point of this pass is that some files were NOT updated.
Write-Output ""
Write-Output "[summary] written=$written  merged=$merged  kept=$kept  skipped=$skipped  conflicted=$($conflicts.Count)"
if ($merges.Count -gt 0) {
    Write-Output "[summary] merged in place -- your fields survived:"
    foreach ($m in $merges) { Write-Output "  - $m" }
}
if ($conflicts.Count -gt 0) {
    Write-Output "[summary] NOT updated -- resolve these by hand:"
    foreach ($c in $conflicts) { Write-Output "  - $c" }
}
if ($DryRun) {
    Write-Output "[summary] DRY RUN -- nothing was written. Re-run without -DryRun to apply."
    if ($TempDownload -and (Test-Path $TempDownload)) { Remove-Item $TempDownload -Force }
    exit 0
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
    # Recorded so a maintainer can SEE which files this install treats as
    # project-owned, instead of having to read the installer to find out.
    preserve     = @($preserve)
    files        = @($manifestFiles)
} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText((Join-Path $receiptDir ".bundle-manifest.json"), $receipt, $Utf8NoBom)

Write-Output "[install] done: $written written, $merged merged, $skipped skipped, $kept kept (project-owned). Integrity OK ($($bundle.content_hash))."

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

# --- Agent Pack scaffold (v1.6.0): the bundle ships the agents + skills; the
# project supplies only agent-config.yaml (its test runner). Auto-generate it by
# detecting the stack, so review->fix->test works from day one instead of the
# project having to know the file exists. NEVER overwrite an existing one (it is
# project-owned in bundle-ownership.yaml). Detection is best-effort: if we cannot
# tell the stack, write the annotated sample so a human fills it in rather than
# guessing a command that would fail silently.
$acFile = Join-Path $TargetDir ".harness\control\agent-config.yaml"
$acSample = Join-Path $syncDir "templates\agent-pack\agent-config.yaml.sample"
if (-not (Test-Path $acFile) -and (Test-Path $acSample)) {
    $unit = ""; $full = ""; $detected = ""
    $pkg = Join-Path $TargetDir "package.json"
    if (Test-Path $pkg) {
        $pkgTxt = Get-Content $pkg -Raw -Encoding utf8
        if ($pkgTxt -match '"vitest"') { $unit = "npx vitest related --run {files}"; $full = "npx vitest run"; $detected = "vitest" }
        elseif ($pkgTxt -match '"jest"') { $unit = "npx jest --findRelatedTests {files}"; $full = "npx jest"; $detected = "jest" }
    }
    if (-not $detected -and ((Test-Path (Join-Path $TargetDir "pyproject.toml")) -or (Test-Path (Join-Path $TargetDir "pytest.ini")))) {
        $unit = "pytest --testmon -q"; $full = "pytest -q"; $detected = "pytest"
    }
    if (-not $detected -and (Test-Path (Join-Path $TargetDir "composer.json"))) {
        $unit = "php artisan test --filter {files}"; $full = "php artisan test"; $detected = "phpunit"
    }
    if ($detected) {
        $gen = @"
# Agent Pack project config -- AUTO-GENERATED by installer (detected: $detected).
# Tune to taste. Project-owned: re-install never overwrites this.
# Schema: .harness/schemas/agent-config.schema.json
test:
  unit_related_cmd: "$unit"
  full_suite_cmd:   "$full"
  integration_smoke: []
impact:
  force_full_test_on:
    - "**/migrations/**"
    - "**/schema.*"
    - "**/middleware.*"
    - "package-lock.json"
    - "composer.lock"
    - "poetry.lock"
"@
        [System.IO.File]::WriteAllText($acFile, $gen, $Utf8NoBom)
        Write-Output "[scaffold] agent-config.yaml generated (detected $detected test runner)"
    } else {
        Copy-Item $acSample $acFile
        Write-Output "[scaffold] agent-config.yaml: stack not detected -> wrote sample to fill in (Agent Pack review->fix->test needs it)"
    }
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

# The legacy-guide migration below writes a one-time '<file>.pre-migration.bak'.
# That is a local safety net, not project content -- ignore it so it does not
# show up as untracked noise in every project the migration touched.
$bakLine = "*.pre-migration.bak"
$bakHas = (Test-Path $giPath) -and (Select-String -Path $giPath -SimpleMatch $bakLine -Quiet)
if (-not $bakHas) {
    Add-Content -Path $giPath -Value "`n# One-time backup written when a legacy guide block is migrated`n$bakLine" -Encoding utf8
    Write-Output "[scaffold] added *.pre-migration.bak to .gitignore"
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

# --- Re-stamp the receipt with what this install actually LEFT ON DISK ---------
# The baseline for "did the project hand-edit a bundle-owned file?" has to be the
# state the installer finished in, not the bytes the bundle shipped. Several steps
# above deliberately modify files after writing them -- the guide merge appends a
# managed block, settings/identity get stamped -- so comparing against the shipped
# hash flagged .claude/settings.json as hand-edited on the very next run. That
# false positive would train a maintainer to ignore conflict reports, which costs
# more than having no detection at all.
#
# `sha256` keeps its original meaning (the shipped bytes) because the uninstaller
# uses it to tell a pristine file from a user-edited one; `installed_sha256` is
# added alongside, and the tamper check prefers it when present.
try {
    $rPath = Join-Path $TargetDir ".harness\.bundle-manifest.json"
    if (Test-Path $rPath) {
        $r = Get-Content -Path $rPath -Raw -Encoding utf8 | ConvertFrom-Json
        $out = foreach ($e in @($r.files)) {
            $p = Join-Path $TargetDir ($e.path -replace '/', '\')
            $ih = ""
            if (Test-Path $p) {
                try { $ih = Sha256HexOf ([byte[]](Get-Content -Path $p -Encoding Byte -Raw)) } catch { }
            }
            [ordered]@{ path = $e.path; sha256 = "$($e.sha256)"; installed_sha256 = $ih }
        }
        $r2 = [ordered]@{
            name = $r.name; version = $r.version; content_hash = $r.content_hash
            installed_at = $r.installed_at; preserve = @($r.preserve); files = @($out)
        } | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($rPath, $r2, $Utf8NoBom)
    }
} catch {
    Write-Output "[receipt] WARNING: could not re-stamp installed hashes ($($_.Exception.Message)); next run may report false conflicts"
}

# --- Cleanup temp download if used ---
if ($TempDownload -and (Test-Path $TempDownload)) { Remove-Item $TempDownload -Force }
