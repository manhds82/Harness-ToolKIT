#!/usr/bin/env bash
# Harness Bundle installer (POSIX parity of install.ps1). Verifies the bundle's
# SHA-256 content hash before writing anything (fail-closed), then materializes
# every file byte-exact into the target project. Existing files are skipped
# unless --force. Requires python3 (for JSON/base64/hash; avoids jq/coreutils
# flag differences between macOS and Linux).
#
#   ./install.sh --bundle standard-governance-1.0.0.bundle.json --target /path/to/project [--force]
set -euo pipefail

BUNDLE=""; TARGET=""; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE="$2"; shift 2;;
    --target) TARGET="$2"; shift 2;;
    --force)  FORCE=1; shift;;
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
print("[install] done: %d written, %d skipped. Integrity OK (%s)." % (written, skipped, b["content_hash"]))
PY
