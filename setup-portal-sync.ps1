#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Thiet lap dong bo telemetry len Control Portal cho MOT project (ket hop:
  cai bundle MOI NHAT + ghi config + ghi key + test push). Chay 1 lenh la xong.

.USAGE
  .\setup-portal-sync.ps1 -ProjectDir <duong dan project> -ProjectId <id> -IngestKey <key>

  Vi du:
    .\setup-portal-sync.ps1 `
        -ProjectDir "E:\SourceCode\YourProject" `
        -ProjectId  "00a97c2a...." `
        -IngestKey  "abcd1234...."

.PARAMETER ProjectDir  Thu muc goc cua project (noi co / se co thu muc .harness).
.PARAMETER ProjectId   Project ID lay tu Portal (tab Settings > Push telemetry).
.PARAMETER IngestKey   Ingest key lay tu Portal (nut Reveal ingest key).
.PARAMETER PortalUrl   URL Portal (mac dinh da dien san).
.PARAMETER BundleFile  Duong dan .bundle.json (mac dinh: ban co SO VERSION cao nhat).
.PARAMETER SkipInstall Bo qua buoc cai bundle (chi ghi config + push).
.PARAMETER SkipPush    Bo qua buoc test push (chi cai + ghi config).
#>
param(
    [Parameter(Mandatory)][string]$ProjectDir,
    [Parameter(Mandatory)][string]$ProjectId,
    [Parameter(Mandatory)][string]$IngestKey,
    [string]$PortalUrl  = "https://YOUR-PORTAL-DOMAIN",
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

# PortalUrl giu placeholder chung vi script nay ship ra ban public -- no khong
# duoc mang URL noi bo. Nhung neu operator quen -PortalUrl thi truoc day script
# van GHI placeholder do vao portal-sync.json va bao thanh cong; loi chi lo ra
# nhieu phut sau, o buoc push, duoi dang mot loi DNS khong lien quan gi den buoc
# cai dat. Dung han o day, ngay truoc khi ghi.
if ($PortalUrl -match 'YOUR-PORTAL-DOMAIN') {
    throw "Chua dat -PortalUrl. Truyen URL Portal that, vi du: -PortalUrl ""https://portal.example.com"""
}

# --- 1. Cai / cap nhat bundle MOI NHAT ---
# Truoc day cho nay uu tien dich danh standard-governance-1.2.0.bundle.json, va
# file do van nam trong repo -- nen moi du an onboard MOI deu duoc cai ban 1.2.0,
# cach ban hien tai 47 phien ban va thieu toan bo cac ban va guard. Khong co gi
# bao loi: install chay xanh, receipt ghi 1.2.0, va chi lo ra khi ai do doc
# receipt. Nhanh du phong con te hon -- no chon theo LastWriteTime, tuc thoi gian
# file, nen mot ban cu vua duoc pack lai se thang mot ban moi hon.
#
# Gio chon theo SO VERSION, dung cach update-all-projects.ps1 da lam.
if (-not $SkipInstall) {
    if (-not $BundleFile) {
        $searchDirs = @((Join-Path $RepoRoot "bundles\standard-governance"), $ToolDir) |
                      Where-Object { Test-Path $_ }
        $latest = Get-ChildItem -Path $searchDirs -Filter "standard-governance-*.bundle.json" -ErrorAction SilentlyContinue |
            ForEach-Object {
                if ($_.Name -match 'standard-governance-(\d+)\.(\d+)\.(\d+)\.bundle\.json') {
                    [pscustomobject]@{ File = $_.FullName; V = [version]("{0}.{1}.{2}" -f $matches[1], $matches[2], $matches[3]) }
                }
            } | Sort-Object V -Descending | Select-Object -First 1
        if ($latest) { $BundleFile = $latest.File }
    }
    if (-not $BundleFile -or -not (Test-Path $BundleFile)) {
        throw "Khong tim thay bundle .bundle.json (dung -BundleFile de chi dinh, hoac -SkipInstall)"
    }
    $Installer = Join-Path $ToolDir "install.ps1"
    $verShown = if ($BundleFile -match 'standard-governance-([\d.]+)\.bundle\.json') { $matches[1] } else { "?" }
    Say "`n[1/3] Cai bundle v$verShown vao project..." Yellow
    Say "      $BundleFile" DarkGray
    & $Installer -BundleFile $BundleFile -TargetDir $ProjectDir -Force -MergeClaude
} else {
    Say "`n[1/3] (bo qua cai bundle theo -SkipInstall)" DarkGray
}

# --- 2. Ghi config + key ---
Say "`n[2/3] Ghi cau hinh push (.harness/portal-sync.json + .key)..." Yellow
$HarnessDir = Join-Path $ProjectDir ".harness"
if (-not (Test-Path $HarnessDir)) { New-Item -ItemType Directory -Path $HarnessDir -Force | Out-Null }

# GIU LAI cac truong san co thay vi ghi de ca file.
#
# Truoc day cho nay dung mot hashtable moi gom dung portal_url + project_id, nen
# chay lai script tren mot du an DA cau hinh se xoa mat:
#   * member_email -> telemetry mat quy chu, token khong gan duoc vao ai
#   * pdp_enforce  -> quay ve mac dinh, tuc TAT kiem soat server-side
# Ca hai deu bien mat trong im lang: script in "thanh cong", va cai mat la mot
# thu khong ai nhin thay cho den luc can den no.
$ConfigPath = Join-Path $HarnessDir "portal-sync.json"
$ConfigObj = [ordered]@{}
if (Test-Path $ConfigPath) {
    try {
        $existing = Get-Content -Path $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($p in $existing.PSObject.Properties) { $ConfigObj[$p.Name] = $p.Value }
    } catch {
        Say "      (portal-sync.json cu khong doc duoc, se ghi moi)" DarkYellow
    }
}
$kept = @($ConfigObj.Keys | Where-Object { $_ -notin @('portal_url', 'project_id') })
$ConfigObj['portal_url'] = $PortalUrl.TrimEnd('/')
$ConfigObj['project_id'] = $ProjectId.Trim()
$ConfigJson = ($ConfigObj | ConvertTo-Json)
[System.IO.File]::WriteAllText($ConfigPath, $ConfigJson, $Utf8NoBom)
if ($kept.Count -gt 0) {
    Say "      -> portal-sync.json (portal_url + project_id; giu nguyen: $($kept -join ', '))"
} else {
    Say "      -> portal-sync.json (portal_url + project_id)"
}

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
