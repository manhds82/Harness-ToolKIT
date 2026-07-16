#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Thiet lap dong bo telemetry len Control Portal cho MOT project (ket hop:
  cai bundle v1.2.0 + ghi config + ghi key + test push). Chay 1 lenh la xong.

.USAGE
  .\setup-portal-sync.ps1 -ProjectDir <duong dan project> -ProjectId <id> -IngestKey <key>

  Vi du:
    .\setup-portal-sync.ps1 `
        -ProjectDir "E:\SourceCode\claude-code-anyllm" `
        -ProjectId  "00a97c2a...." `
        -IngestKey  "abcd1234...."

.PARAMETER ProjectDir  Thu muc goc cua project (noi co / se co thu muc .harness).
.PARAMETER ProjectId   Project ID lay tu Portal (tab Settings > Push telemetry).
.PARAMETER IngestKey   Ingest key lay tu Portal (nut Reveal ingest key).
.PARAMETER PortalUrl   URL Portal (mac dinh da dien san).
.PARAMETER BundleFile  Duong dan .bundle.json (mac dinh: ban v1.2.0 trong repo nay).
.PARAMETER SkipInstall Bo qua buoc cai bundle (chi ghi config + push).
.PARAMETER SkipPush    Bo qua buoc test push (chi cai + ghi config).
#>
param(
    [Parameter(Mandatory)][string]$ProjectDir,
    [Parameter(Mandatory)][string]$ProjectId,
    [Parameter(Mandatory)][string]$IngestKey,
    [string]$PortalUrl  = "https://YOUR-PORTAL-HOST",
    [string]$BundleFile = "",
    [switch]$SkipInstall,
    [switch]$SkipPush
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ToolDir = $PSScriptRoot   # ...\tools\harness-bundle
$RepoRoot = (Resolve-Path (Join-Path $ToolDir "..\..")).Path

function Say($msg, $color = "Gray") { Write-Host $msg -ForegroundColor $color }

Say "==================================================================" Cyan
Say " Portal sync setup -> $ProjectDir" Cyan
Say "==================================================================" Cyan

# --- 0. Kiem tra project dir ---
if (-not (Test-Path $ProjectDir)) {
    throw "Khong tim thay thu muc project: $ProjectDir"
}
$ProjectDir = (Resolve-Path $ProjectDir).Path

# --- 1. Cai / cap nhat bundle v1.2.0 (hooks moi) ---
if (-not $SkipInstall) {
    if (-not $BundleFile) {
        # Tim bundle o ca 2 layout: repo goc (bundles\standard-governance\)
        # va repo phan phoi phang (bundle nam canh script).
        $candidates = @(
            (Join-Path $RepoRoot "bundles\standard-governance\standard-governance-1.2.0.bundle.json"),
            (Join-Path $ToolDir "standard-governance-1.2.0.bundle.json")
        )
        $BundleFile = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $BundleFile) {
            # fallback: bundle moi nhat tim thay gan script
            $found = Get-ChildItem -Path $ToolDir, $RepoRoot -Recurse -Filter "*.bundle.json" -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($found) { $BundleFile = $found.FullName }
        }
    }
    if (-not $BundleFile -or -not (Test-Path $BundleFile)) {
        throw "Khong tim thay bundle .bundle.json (dung -BundleFile de chi dinh, hoac -SkipInstall)"
    }
    $Installer = Join-Path $ToolDir "install.ps1"
    Say "`n[1/3] Cai bundle v1.2.0 (hooks) vao project..." Yellow
    & $Installer -BundleFile $BundleFile -TargetDir $ProjectDir -Force -MergeClaude
} else {
    Say "`n[1/3] (bo qua cai bundle theo -SkipInstall)" DarkGray
}

# --- 2. Ghi config + key ---
Say "`n[2/3] Ghi cau hinh push (.harness/portal-sync.json + .key)..." Yellow
$HarnessDir = Join-Path $ProjectDir ".harness"
if (-not (Test-Path $HarnessDir)) { New-Item -ItemType Directory -Path $HarnessDir -Force | Out-Null }

$ConfigObj = [ordered]@{ portal_url = $PortalUrl.TrimEnd('/'); project_id = $ProjectId.Trim() }
$ConfigJson = ($ConfigObj | ConvertTo-Json)
[System.IO.File]::WriteAllText((Join-Path $HarnessDir "portal-sync.json"), $ConfigJson, $Utf8NoBom)
Say "      -> portal-sync.json (portal_url + project_id)"

# Key file = CHI chua key, 1 dong, khong BOM, khong xuong dong thua.
[System.IO.File]::WriteAllText((Join-Path $HarnessDir "portal-sync.key"), $IngestKey.Trim(), $Utf8NoBom)
Say "      -> portal-sync.key (da luu key, file nay da gitignore, khong commit)"

# --- 3. Test push ngay ---
if (-not $SkipPush) {
    $Pusher = Join-Path $ProjectDir ".harness\scripts\powershell\push-telemetry.ps1"
    if (-not (Test-Path $Pusher)) {
        Say "`n[3/3] CHUA co push-telemetry.ps1 trong project -- co ve bundle chua cai. Chay lai KHONG kem -SkipInstall." Red
        exit 1
    }
    Say "`n[3/3] Test push len Portal..." Yellow
    & $Pusher -HarnessRoot $ProjectDir
} else {
    Say "`n[3/3] (bo qua test push theo -SkipPush)" DarkGray
}

Say "`n==================================================================" Green
Say " XONG. Tu gio moi session ket thuc se tu dong day telemetry len Portal." Green
Say " Kiem tra: mo Portal -> project -> so lieu Tokens/Prompts/Errors." Green
Say "==================================================================" Green
