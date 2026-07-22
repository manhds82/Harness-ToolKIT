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
PROJECT_NAME=""; PROJECT_DESC=""; FORCE_IDENTITY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)       BUNDLE="$2"; shift 2;;
    --target)       TARGET="$2"; shift 2;;
    --force)        FORCE=1; shift;;
    # --merge-claude is the old name; both project the governance text into every
    # guide file listed in casan-policies governance.guide_targets.
    --merge-guides|--merge-claude) MERGE_CLAUDE=1; shift;;
    --project-name)        PROJECT_NAME="$2"; shift 2;;
    --project-description) PROJECT_DESC="$2"; shift 2;;
    --force-identity)      FORCE_IDENTITY=1; shift;;
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
written = skipped = kept = 0
# Files the project OWNS once they exist: never overwritten, not even with
# --force, because they carry per-project decisions. When the shipped copy has
# moved on, a `<file>.new` is dropped beside it to adopt new keys deliberately.
preserve = set(b.get("preserve") or [])
for f in b["files"]:
    dest = os.path.join(target, *f["path"].split("/"))
    data = base64.b64decode(f["b64"])
    if os.path.exists(dest) and f["path"] in preserve:
        with open(dest, "rb") as fh:
            same = fh.read() == data
        if same:
            print("  [KEEP]  %s (yours; identical to shipped)" % f["path"])
        else:
            with open(dest + ".new", "wb") as fh:
                fh.write(data)
            print("  [KEEP]  %s (yours; shipped copy saved as %s.new)" % (f["path"], f["path"]))
        kept += 1
        continue
    if os.path.exists(dest) and not force:
        print("  [SKIP] %s (exists; use --force to overwrite)" % f["path"]); skipped += 1; continue
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "wb") as fh:
        fh.write(data)
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
print("[install] done: %d written, %d skipped, %d kept (project-owned). Integrity OK (%s)." % (written, skipped, kept, b["content_hash"]))
PY

# --- Portal-sync scaffold: create the two files a newcomer would otherwise have
# to hand-author, at the right location, ready to edit. NEVER overwrite existing
# ones (a real key / configured project_id is preserved). push-telemetry.sh reads
# exactly these two files to sync telemetry to the Portal. ---
mkdir -p "$TARGET/.harness"
SYNC_JSON="$TARGET/.harness/portal-sync.json"
if [[ ! -f "$SYNC_JSON" ]]; then
  cat > "$SYNC_JSON" <<'JSON'
{
  "_README": "Fill portal_url and project_id from your Control Portal (open the Project, then Settings, then Reveal ingest key). Next, paste the ingest key into portal-sync.key in THIS same .harness folder. Set pdp_enforce to true to make the PreToolUse hook consult the Portal PDP (H4 outbound allowlist, H5 approval, H3 release gate) -- leave false to keep it off. You may delete this _README line.",
  "portal_url": "https://YOUR-PORTAL-DOMAIN",
  "project_id": "PASTE-PROJECT-ID-HERE",
  "pdp_enforce": false,
  "member_email": ""
}
JSON
  echo "[scaffold] created .harness/portal-sync.json  -> EDIT portal_url + project_id"
else
  echo "[scaffold] .harness/portal-sync.json already exists -> kept"
fi
SYNC_KEY="$TARGET/.harness/portal-sync.key"
if [[ ! -f "$SYNC_KEY" ]]; then
  : > "$SYNC_KEY"
  echo "[scaffold] created empty .harness/portal-sync.key -> PASTE ingest key here (1 line)"
else
  echo "[scaffold] .harness/portal-sync.key already exists -> kept"
fi

# --- Buglist scaffold (M6): living buglist.md at project root from the shipped
# template; never overwrite an existing one. ---
BUG_FILE="$TARGET/buglist.md"
BUG_TMPL="$TARGET/.harness/templates/buglist.md"
if [[ ! -f "$BUG_FILE" && -f "$BUG_TMPL" ]]; then
  sed "s/<PROJECT>/$(basename "$TARGET")/g" "$BUG_TMPL" > "$BUG_FILE"
  echo "[scaffold] created buglist.md (log every bug here -- see rule in the file)"
elif [[ -f "$BUG_FILE" ]]; then
  echo "[scaffold] buglist.md already exists -> kept"
fi

# C5: never commit the ingest key. Ensure the target project's .gitignore
# ignores it (idempotent -- add the line only if missing).
GI="$TARGET/.gitignore"
if ! grep -qF ".harness/portal-sync.key" "$GI" 2>/dev/null; then
  printf '\n# Harness Portal ingest key -- secret, never commit (C5)\n.harness/portal-sync.key\n' >> "$GI"
  echo "[scaffold] added portal-sync.key to .gitignore (C5)"
fi

# --- H1 scaffold: build the context pointer store so a freshly-onboarded project
# satisfies its own context contract right away (the policy-ci suite asserts it,
# and the release gate would otherwise block until the first session ran the
# hook). Best-effort: a failure here must never fail the install.
CTX_BUILD="$TARGET/.harness/scripts/bash/harness-context-build.sh"
CTX_STORE="$TARGET/.harness/context/pipeline-context.yaml"
if [ -f "$CTX_BUILD" ] && [ ! -f "$CTX_STORE" ]; then
  if HARNESS_ROOT="$TARGET" bash "$CTX_BUILD" >/dev/null 2>&1 && [ -f "$CTX_STORE" ]; then
    echo "[scaffold] built .harness/context/pipeline-context.yaml (H1)"
  else
    echo "[scaffold] could not build the H1 pointer store (non-fatal)"
  fi
fi

# --- Project identity + governance projection (--merge-guides) ---
# ONE canonical text (CLAUDE.harness.md) -> every agent-guide file the project
# uses, as a DELIMITED managed block, so re-installing refreshes only that block
# and never touches what the project wrote around it.
"$PY" - "$TARGET" "$MERGE_CLAUDE" "$PROJECT_NAME" "$PROJECT_DESC" "$FORCE_IDENTITY" <<'PY'
import os, re, sys
target, do_guides = sys.argv[1], sys.argv[2] == "1"
pname, pdesc, force_id = sys.argv[3], sys.argv[4], sys.argv[5] == "1"

# ---- identity: patch only the two scalars inside the `project:` block --------
if pname:
    if not pdesc:
        pdesc = pname
    contract = os.path.join(target, "contracts", "project.yaml")
    if not os.path.isfile(contract):
        print("[identity] contracts/project.yaml not found -- skipped")
    else:
        lines = open(contract, encoding="utf-8").read().split("\n")
        cur, inp = "", False
        for ln in lines:
            if re.match(r"^project:\s*$", ln):
                inp = True; continue
            if inp:
                if re.match(r"^\S", ln): break
                m = re.match(r"^\s+name:\s*(.*)$", ln)
                if m: cur = m.group(1).strip().strip('"')
        placeholder = cur in ("", "harness-toolkit", "my-project")
        if not force_id and not placeholder:
            print("[identity] kept existing project name '%s' (use --force-identity to overwrite)" % cur)
        else:
            out, inp, changed = [], False, False
            for ln in lines:
                if re.match(r"^project:\s*$", ln):
                    inp = True; out.append(ln); continue
                if inp:
                    if re.match(r"^\S", ln):
                        inp = False
                    else:
                        m = re.match(r"^(\s+)name:\s*", ln)
                        if m:
                            out.append('%sname: "%s"' % (m.group(1), pname)); changed = True; continue
                        m = re.match(r"^(\s+)description:\s*", ln)
                        if m:
                            out.append('%sdescription: "%s"' % (m.group(1), pdesc)); changed = True; continue
                out.append(ln)
            if changed:
                open(contract, "w", encoding="utf-8", newline="\n").write("\n".join(out))
                print("[identity] contracts/project.yaml -> name/description = '%s'" % pname)
            else:
                print("[identity] could not find name/description under 'project:' -- skipped")

# ---- guides: project the common governance text -----------------------------
if do_guides:
    src = os.path.join(target, "CLAUDE.harness.md")
    if not os.path.isfile(src):
        print("[guides] CLAUDE.harness.md not found in target -- skipping")
        sys.exit(0)
    gov = open(src, encoding="utf-8").read().strip()

    # C2: the target list is data (casan-policies governance.guide_targets).
    targets, policy = [], os.path.join(target, ".harness", "control", "casan-policies.yaml")
    if os.path.isfile(policy):
        inb = False
        for ln in open(policy, encoding="utf-8-sig"):
            ln = ln.rstrip("\n")
            if re.match(r"^\s*guide_targets:\s*(#.*)?$", ln):
                inb = True; continue
            if inb:
                if re.match(r"^\s*#", ln): continue
                m = re.match(r"^\s*-\s*(.+?)\s*$", ln)
                if m:
                    v = re.sub(r"\s+#.*$", "", m.group(1)).strip().strip('"').strip("'")
                    if v: targets.append(v)
                elif ln.strip():
                    break
    if not targets:
        targets = ["CLAUDE.md", "AGENTS.md", ".github/copilot-instructions.md"]

    BEGIN, END = "<!-- BEGIN harness-governance -->", "<!-- END harness-governance -->"
    note = ("<!-- standard-governance - MANAGED BLOCK. Edits inside are replaced on the next "
            "install; put your own project rules OUTSIDE this block. -->")
    block = "%s\n%s\n\n%s\n\n%s" % (BEGIN, note, gov, END)
    for rel in targets:
        p = os.path.join(target, *rel.split("/"))
        os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
        if not os.path.exists(p):
            open(p, "w", encoding="utf-8", newline="\n").write(block + "\n")
            print("[guides] created %s" % rel); continue
        cur = open(p, encoding="utf-8").read()
        bi, ei = cur.find(BEGIN), cur.find(END)
        if bi >= 0 and ei > bi:
            open(p, "w", encoding="utf-8", newline="\n").write(cur[:bi] + block + cur[ei + len(END):])
            print("[guides] refreshed managed block in %s" % rel)
        elif re.search(r"<!--\s*harness:merged\s*-->", cur):
            print("[guides] %s has a legacy merged block -- left as is" % rel)
        else:
            open(p, "w", encoding="utf-8", newline="\n").write(cur.rstrip() + "\n\n---\n\n" + block + "\n")
            print("[guides] appended governance to existing %s (your content untouched)" % rel)
PY

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

