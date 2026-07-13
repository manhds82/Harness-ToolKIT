#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Harness Bundle installer (L5 -- distribution layer).
  Materializes a packed .bundle.json into a target project (byte-exact),
  after verifying its content hash -- the "npm install" analog. This is the
  governed evolution of harness-init: instead of hardcoded templates, it
  installs a named, versioned, hash-verified bundle.
.USAGE
  .\install.ps1 -BundleFile <x.bundle.json> -TargetDir <project dir> [-Force]
#>
param(
    [Parameter(Mandatory)][string]$BundleFile,
    [Parameter(Mandatory)][string]$TargetDir,
    [switch]$Force = $false
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Sha256HexOf([byte[]]$Bytes) {
    $s = [System.Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($s.ComputeHash($Bytes)) -replace '-', '').ToLower()
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
