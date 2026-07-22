#!/usr/bin/env bash
# Update EVERY onboarded project to the latest standard-governance bundle
# (bash parity of update-all-projects.ps1). Auto-detects the newest bundle and
# every project with a .harness/ under BASE_DIR — nothing to edit per release.
# Idempotent; preserves portal-sync.key/.json. Rebuilds the H1 retrieval index.
#
# Usage:
#   BASE_DIR=/path/to/projects tools/harness-bundle/update-all-projects.sh
#   tools/harness-bundle/update-all-projects.sh --dry-run
#   tools/harness-bundle/update-all-projects.sh --reinstall
set -euo pipefail

BASE_DIR="${BASE_DIR:-$HOME/SourceCode}"
DRY=0; REINSTALL=0; PDP=0; NO_IDENTITY=0; FORCE_IDENTITY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1;;
    --reinstall) REINSTALL=1;;
    --pdp-enforce) PDP=1;;
    --no-identity) NO_IDENTITY=1;;        # do not stamp name/description from the folder
    --force-identity) FORCE_IDENTITY=1;;  # overwrite even a name the project already set
  esac
done

TOOLKIT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE_DIR="${BUNDLE_DIR:-$TOOLKIT_ROOT/bundles/standard-governance}"
INSTALLER="$TOOLKIT_ROOT/tools/harness-bundle/install.sh"

# 1. newest bundle by semantic version
LATEST_FILE=""; LATEST_VER=""
while IFS= read -r f; do
  v=$(basename "$f" | sed -nE 's/standard-governance-([0-9]+\.[0-9]+\.[0-9]+)\.bundle\.json/\1/p')
  [ -z "$v" ] && continue
  if [ -z "$LATEST_VER" ] || [ "$(printf '%s\n%s\n' "$v" "$LATEST_VER" | sort -V | tail -1)" = "$v" ]; then
    LATEST_VER="$v"; LATEST_FILE="$f"
  fi
done < <(ls "$BUNDLE_DIR"/*.bundle.json 2>/dev/null)
[ -z "$LATEST_FILE" ] && { echo "No bundle found in $BUNDLE_DIR" >&2; exit 1; }

echo "=================================================================="
echo " Latest bundle: standard-governance v$LATEST_VER"
echo " Base dir     : $BASE_DIR$([ $DRY -eq 1 ] && echo '   [DRY RUN]')"
echo "=================================================================="

updated=0; uptodate=0; failed=0
for d in "$BASE_DIR"/*/; do
  name=$(basename "$d")
  case "$name" in HarnessAI-ToolKIT|Harness-ToolKIT) continue;; esac
  [ -d "$d/.harness" ] || continue

  cur="-"
  if [ -f "$d/.harness/.bundle-manifest.json" ]; then
    cur=$(grep -oE '"version"[^,]*' "$d/.harness/.bundle-manifest.json" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "-")
  fi

  if [ "$cur" = "$LATEST_VER" ] && [ $REINSTALL -eq 0 ]; then
    printf '  = %-26s v%s  (up-to-date)\n' "$name" "$cur"; uptodate=$((uptodate+1)); continue
  fi
  if [ $DRY -eq 1 ]; then
    printf '  ~ %-26s v%s -> v%s  (would update)\n' "$name" "$cur" "$LATEST_VER"; continue
  fi

  printf '  > %-26s v%s -> v%s\n' "$name" "$cur" "$LATEST_VER"
  # Name the project after its folder. The installer only writes it while the
  # contract still carries the shipped placeholder, so a project that named
  # itself is never renamed (unless --force-identity).
  ID_ARGS=()
  if [[ "$NO_IDENTITY" -eq 0 ]]; then
    ID_ARGS+=(--project-name "$name" --project-description "$name")
    [[ "$FORCE_IDENTITY" -eq 1 ]] && ID_ARGS+=(--force-identity)
  fi
  if bash "$INSTALLER" --bundle "$LATEST_FILE" --target "$d" --force --merge-guides "${ID_ARGS[@]}" >/dev/null 2>&1; then
    rag="$d/.harness/scripts/lib/harness_rag.py"
    [ -f "$rag" ] && command -v python3 >/dev/null 2>&1 && HARNESS_ROOT="$d" python3 "$rag" index --root "$d" >/dev/null 2>&1 || true
    updated=$((updated+1))
  else
    echo "    FAILED"; failed=$((failed+1))
  fi
done

echo
echo "Done: $updated updated, $uptodate up-to-date, $failed failed."
echo "portal-sync.key/.json preserved. Run a Claude session per project to refresh telemetry."

if [ $PDP -eq 1 ]; then
  echo
  BASE_DIR="$BASE_DIR" bash "$(dirname "$0")/set-pdp-enforce.sh" $([ $DRY -eq 1 ] && echo --dry-run)
fi
