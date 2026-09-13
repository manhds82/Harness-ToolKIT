#!/usr/bin/env bash
# Thiet lap dong bo telemetry len Control Portal cho MOT project (bash parity
# cua setup-portal-sync.ps1): cai bundle + ghi config + ghi key + test push.
#
# Usage:
#   ./setup-portal-sync.sh --project-dir <dir> --project-id <id> --ingest-key <key> \
#       [--portal-url <url>] [--bundle-file <file>] [--skip-install] [--skip-push]
set -euo pipefail

PROJECT_DIR=""; PROJECT_ID=""; INGEST_KEY=""
PORTAL_URL="https://YOUR-PORTAL-DOMAIN"
BUNDLE_FILE=""; SKIP_INSTALL=0; SKIP_PUSH=0

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TOOL_DIR/../.." && pwd)"

while [ $# -gt 0 ]; do
    case "$1" in
        --project-dir) PROJECT_DIR="$2"; shift 2 ;;
        --project-id)  PROJECT_ID="$2"; shift 2 ;;
        --ingest-key)  INGEST_KEY="$2"; shift 2 ;;
        --portal-url)  PORTAL_URL="$2"; shift 2 ;;
        --bundle-file) BUNDLE_FILE="$2"; shift 2 ;;
        --skip-install) SKIP_INSTALL=1; shift ;;
        --skip-push)   SKIP_PUSH=1; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -n "$PROJECT_DIR" ] && [ -n "$PROJECT_ID" ] && [ -n "$INGEST_KEY" ] || {
    echo "Thieu tham so bat buoc: --project-dir --project-id --ingest-key" >&2; exit 1; }
[ -d "$PROJECT_DIR" ] || { echo "Khong tim thay project dir: $PROJECT_DIR" >&2; exit 1; }
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# PORTAL_URL giu placeholder chung vi script nay ship ra ban public -- no khong
# duoc mang URL noi bo. Nhung neu operator quen --portal-url thi truoc day script
# van GHI placeholder do vao portal-sync.json va bao thanh cong; loi chi lo ra o
# buoc push, duoi dang mot loi DNS khong lien quan den buoc cai dat. Dung han o
# day. Phai khop voi kiem tra cung ten trong setup-portal-sync.ps1 (C7).
case "$PORTAL_URL" in
    *YOUR-PORTAL-DOMAIN*)
        echo "Chua dat --portal-url. Truyen URL Portal that, vi du: --portal-url https://portal.example.com" >&2
        exit 1 ;;
esac

echo "=================================================================="
echo " Portal sync setup -> $PROJECT_DIR"
echo "=================================================================="

# 1. Cai bundle
if [ "$SKIP_INSTALL" -eq 0 ]; then
    if [ -z "$BUNDLE_FILE" ]; then
        # Chon theo SO VERSION cao nhat, khong phai ten dich danh.
        #
        # Truoc day cho nay uu tien standard-governance-1.2.0.bundle.json va file
        # do van nam trong repo, nen moi du an onboard MOI deu nhan ban 1.2.0 --
        # cach ban hien tai 47 phien ban, thieu toan bo cac ban va guard, va
        # khong co gi bao loi vi install van chay xanh. Nhanh du phong cu dung
        # `find | head -1`, tuc thu tu tuy he thong file tra ve.
        # `sort -V` sap theo version (1.6.19 > 1.6.9), khac han sort chuoi.
        BUNDLE_FILE="$(ls "$REPO_ROOT/bundles/standard-governance"/standard-governance-*.bundle.json \
                          "$TOOL_DIR"/standard-governance-*.bundle.json 2>/dev/null |
                       sed 's#.*/standard-governance-\([0-9.]*\)\.bundle\.json#\1 &#' |
                       sort -V -k1,1 | tail -1 | cut -d' ' -f2-)"
    fi
    [ -n "$BUNDLE_FILE" ] && [ -f "$BUNDLE_FILE" ] || { echo "Khong tim thay bundle .bundle.json" >&2; exit 1; }
    echo "[1/3] Cai bundle $(basename "$BUNDLE_FILE") vao project..."
    bash "$TOOL_DIR/install.sh" --bundle "$BUNDLE_FILE" --target "$PROJECT_DIR" --force --merge-claude
else
    echo "[1/3] (bo qua cai bundle)"
fi

# 2. Ghi config + key
echo "[2/3] Ghi cau hinh push..."
mkdir -p "$PROJECT_DIR/.harness"
PORTAL_URL_TRIM="${PORTAL_URL%/}"
printf '{\n  "portal_url": "%s",\n  "project_id": "%s"\n}\n' "$PORTAL_URL_TRIM" "$PROJECT_ID" \
    > "$PROJECT_DIR/.harness/portal-sync.json"
printf '%s' "$INGEST_KEY" > "$PROJECT_DIR/.harness/portal-sync.key"
echo "      -> portal-sync.json + portal-sync.key (key da gitignore)"

# 3. Test push
if [ "$SKIP_PUSH" -eq 0 ]; then
    PUSHER="$PROJECT_DIR/.harness/scripts/bash/push-telemetry.sh"
    if [ ! -f "$PUSHER" ]; then
        echo "[3/3] CHUA co push-telemetry.sh -- bundle chua cai. Chay lai khong kem --skip-install." >&2
        exit 1
    fi
    echo "[3/3] Test push len Portal..."
    HARNESS_ROOT="$PROJECT_DIR" bash "$PUSHER"
else
    echo "[3/3] (bo qua test push)"
fi

echo "=================================================================="
echo " XONG. Moi session ket thuc se tu dong day telemetry len Portal."
echo "=================================================================="
