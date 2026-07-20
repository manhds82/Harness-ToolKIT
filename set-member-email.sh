#!/usr/bin/env bash
# Set "member_email" in each project's .harness/portal-sync.json (bash parity of
# set-member-email.ps1). Safe JSON round-trip via python3 — only member_email
# changes; other keys + portal-sync.key untouched. One email PER project.
#   BASE_DIR=/path set-member-email.sh you@example.com
#   set-member-email.sh other@example.com --only ProjectX,ProjectY
#   set-member-email.sh you@example.com --exclude ProjectX
#   set-member-email.sh you@example.com --dry-run
set -uo pipefail

EMAIL="${1:-}"; shift || true
[ -z "$EMAIL" ] && { echo "usage: set-member-email.sh <email> [--only a,b] [--exclude a,b] [--dry-run]" >&2; exit 2; }
BASE_DIR="${BASE_DIR:-$HOME/SourceCode}"; ONLY=""; EXCLUDE=""; DRY=0
while [ $# -gt 0 ]; do case "$1" in
  --only) ONLY="$2"; shift 2;; --exclude) EXCLUDE="$2"; shift 2;; --dry-run) DRY=1; shift;; *) shift;; esac; done
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }

echo "=================================================================="
echo " Set member_email = $EMAIL   (base: $BASE_DIR)$([ $DRY -eq 1 ] && echo '   [DRY RUN]')"
[ -n "$ONLY" ] && echo " Only: $ONLY"; [ -n "$EXCLUDE" ] && echo " Exclude: $EXCLUDE"
echo "=================================================================="

for d in "$BASE_DIR"/*/; do
  name=$(basename "$d")
  case "$name" in HarnessAI-ToolKIT|Harness-ToolKIT) continue;; esac
  f="$d/.harness/portal-sync.json"; [ -f "$f" ] || continue
  if [ -n "$ONLY" ] && [[ ",$ONLY," != *",$name,"* ]]; then continue; fi
  if [ -n "$EXCLUDE" ] && [[ ",$EXCLUDE," == *",$name,"* ]]; then continue; fi
  FILE="$f" EMAIL="$EMAIL" DRY="$DRY" NAME="$name" python3 - <<'PY'
import os,json
f=os.environ["FILE"]; email=os.environ["EMAIL"]; dry=os.environ["DRY"]=="1"; name=os.environ["NAME"]
try: cfg=json.load(open(f,encoding="utf-8-sig"))
except Exception: print("  ! %-26s unreadable -- SKIP"%name); raise SystemExit
old=cfg.get("member_email","(unset)")
if dry: print("  ~ %-26s member_email %s -> %s"%(name,old,email)); raise SystemExit
cfg["member_email"]=email
json.dump(cfg,open(f,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
print("  > %-26s member_email %s -> %s"%(name,old,email))
PY
done
echo "Next: run harness-sync to re-push (agentic tokens get attributed + back-filled)."
