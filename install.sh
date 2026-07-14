#!/usr/bin/env bash
# Harness Bundle installer (POSIX parity of install.ps1). Verifies the bundle's
# SHA-256 content hash before writing anything (fail-closed), then materializes
# every file byte-exact into the target project. Existing files are skipped
# unless --force. Requires python3 (for JSON/base64/hash; avoids jq/coreutils
# flag differences between macOS and Linux).
#
#   ./install.sh --bundle standard-governance-1.0.0.bundle.json --target /path/to/project [--force] [--merge-claude]
#
#   --merge-claude  After installing, auto-merge CLAUDE.harness.md into CLAUDE.md.
#                   Creates CLAUDE.md if absent; appends with <!-- harness:merged -->
#                   sentinel if present but not yet merged; skips if sentinel found.
set -euo pipefail

BUNDLE=""; TARGET=""; FORCE=0; MERGE_CLAUDE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)       BUNDLE="$2"; shift 2;;
    --target)       TARGET="$2"; shift 2;;
    --force)        FORCE=1; shift;;
    --merge-claude) MERGE_CLAUDE=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
# Default bundle: newest *.bundle.json next to this script.
if [[ -z "$BUNDLE" ]]; then
  BUNDLE="$(ls -1t "$(dirname "$0")"/*.bundle.json 2>/dev/null | head -1 || true)"
fi
[[ -n "$BUNDLE" && -f "$BUNDLE" ]] || { echo "bundle file not found (use --bundle)" >&2; exit 2; }
[[ -n "$TARGET" ]] || { echo "usage: --target <project dir> required" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[[ -n "$PY" ]] || { echo "python3 required" >&2; exit 3; }

# Did the project already have its own settings.json? (so we don't clobber it)
PRE_SETTINGS=0; [[ -f "$TARGET/.claude/settings.json" ]] && PRE_SETTINGS=1

"$PY" - "$BUNDLE" "$TARGET" "$FORCE" <<'PY'
import json, base64, hashlib, os, sys
bundle_path, target, force = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
b = json.load(open(bundle_path, encoding="utf-8"))
# Fail-closed integrity: recompute hash over sorted path:b64 pairs.
hi = "\n".join("%s:%s" % (f["path"], f["b64"]) for f in b["files"])
comp = hashlib.sha256(hi.encode("utf-8")).hexdigest()
if comp != b["content_hash"]:
    sys.exit("Bundle integrity check FAILED: computed %s != declared %s" % (comp, b["content_hash"]))
print("[install] %s v%s (%d files) -> %s" % (b["name"], b["version"], b["file_count"], target))
written = skipped = 0
for f in b["files"]:
    dest = os.path.join(target, *f["path"].split("/"))
    if os.path.exists(dest) and not force:
        print("  [SKIP] %s (exists; use --force to overwrite)" % f["path"]); skipped += 1; continue
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "wb") as fh:
        fh.write(base64.b64decode(f["b64"]))
    print("  [WRITE] %s" % f["path"]); written += 1

# Install receipt for the in-project uninstaller (path + original sha256).
import hashlib, datetime, json as _json
receipt = {
    "name": b["name"], "version": b["version"], "content_hash": b["content_hash"],
    "installed_at": datetime.datetime.now().astimezone().isoformat(),
    "files": [{"path": f["path"],
               "sha256": hashlib.sha256(base64.b64decode(f["b64"])).hexdigest()}
              for f in b["files"]],
}
rdir = os.path.join(target, ".harness"); os.makedirs(rdir, exist_ok=True)
with open(os.path.join(rdir, ".bundle-manifest.json"), "w", encoding="utf-8") as fh:
    _json.dump(receipt, fh, indent=2)
print("[install] done: %d written, %d skipped. Integrity OK (%s)." % (written, skipped, b["content_hash"]))
PY

# --- Auto-merge CLAUDE.harness.md -> CLAUDE.md (--merge-claude) ---
if [[ "$MERGE_CLAUDE" -eq 1 ]]; then
  HARNESS_MD="$TARGET/CLAUDE.harness.md"
  CLAUDE_MD="$TARGET/CLAUDE.md"
  if [[ ! -f "$HARNESS_MD" ]]; then
    echo "[merge] WARNING: CLAUDE.harness.md not found in target -- skipping" >&2
  elif grep -q '<!--.*harness:merged.*-->' "$CLAUDE_MD" 2>/dev/null; then
    echo "[SKIP]  CLAUDE.md already contains harness governance (sentinel found -- skipping)"
  elif [[ ! -f "$CLAUDE_MD" ]]; then
    cp "$HARNESS_MD" "$CLAUDE_MD"
    echo "[MERGE] created CLAUDE.md from CLAUDE.harness.md"
  else
    printf '\n\n---\n<!-- harness:merged -->\n\n' >> "$CLAUDE_MD"
    cat "$HARNESS_MD" >> "$CLAUDE_MD"
    echo "[MERGE] appended harness governance to existing CLAUDE.md"
  fi
fi

# --- OS hook selection (macOS/Linux): use the bash hooks, not the .ps1 ones ---
# The bundle ships settings.json (Windows/powershell) + settings.posix.json
# (bash). On POSIX, activate the bash variant -- but never overwrite a
# settings.json the project already had (unless --force).
POSIX="$TARGET/.claude/settings.posix.json"
SET="$TARGET/.claude/settings.json"
if [[ -f "$POSIX" && ( "$PRE_SETTINGS" -eq 0 || "$FORCE" -eq 1 ) ]]; then
  cp -f "$POSIX" "$SET"
  echo "[install] selected POSIX (bash) hooks for .claude/settings.json"
fi

