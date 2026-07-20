#!/usr/bin/env bash
# Turn PDP enforcement on/off across projects by setting "pdp_enforce" in each
# .harness/portal-sync.json (bash parity of set-pdp-enforce.ps1). Safe JSON
# round-trip via python3 — only that one key changes; portal_url/project_id/
# _README preserved; portal-sync.key never touched. Corrupt files are skipped.
#
# Usage:
#   BASE_DIR=/path set-pdp-enforce.sh            # enable on all
#   set-pdp-enforce.sh --disable                 # turn off
#   set-pdp-enforce.sh --dry-run
set -euo pipefail

BASE_DIR="${BASE_DIR:-$HOME/SourceCode}"
ENFORCE=true; DRY=0
for a in "$@"; do
  case "$a" in
    --disable) ENFORCE=false;;
    --dry-run) DRY=1;;
  esac
done

echo "=================================================================="
echo " Set pdp_enforce = $ENFORCE   (base: $BASE_DIR)$([ $DRY -eq 1 ] && echo '   [DRY RUN]')"
echo "=================================================================="

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }

for d in "$BASE_DIR"/*/; do
  name=$(basename "$d")
  case "$name" in HarnessAI-ToolKIT|Harness-ToolKIT) continue;; esac
  f="$d/.harness/portal-sync.json"
  [ -f "$f" ] || continue
  FILE="$f" ENFORCE="$ENFORCE" DRY="$DRY" NAME="$name" python3 - <<'PY'
import os, json
f=os.environ["FILE"]; want=os.environ["ENFORCE"]=="true"; dry=os.environ["DRY"]=="1"; name=os.environ["NAME"]
try:
    cfg=json.load(open(f, encoding="utf-8-sig"))
except Exception:
    print("  ! %-26s portal-sync.json unreadable — SKIP"%name); raise SystemExit
old=cfg.get("pdp_enforce","(unset)")
if dry:
    print("  ~ %-26s pdp_enforce %s -> %s"%(name, old, want)); raise SystemExit
cfg["pdp_enforce"]=want
json.dump(cfg, open(f,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
print("  > %-26s pdp_enforce %s -> %s  (other keys preserved)"%(name, old, want))
PY
done
echo "Done."
