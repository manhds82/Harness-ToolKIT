# Harness AI Toolkit — Governance Bundle

A one-command, hash-verified **governance layer for Claude Code projects**.
Install it into any repo and your Claude Code sessions gain enforceable
guardrails (dangerous-command blocking, prompt-injection scanning, an
append-only audit ledger), a 9-agent role fleet, and a structured
analyze → implement → verify → evidence pipeline.

> **Author / Maintainer:** Dau Sy Manh — `manhds@`
> **License:** Apache-2.0 (see [`LICENSE`](LICENSE) / [`NOTICE`](NOTICE))
> This repo is the **public distribution** (packaged artifact + installer +
> guide). It is consumed, not built here.

---

## What's in this repo

| File | Purpose |
|------|---------|
| `standard-governance-1.5.0.bundle.json` | The packaged governance bundle — 115 files (agents, skills, per-OS hook settings, control policies, contract templates, JSON schemas, the golden-set eval dataset, the ready-to-run `policy-ci`/`red-team`/`golden` suites, and **both** PowerShell + bash scripts), base64-encoded with a SHA-256 content hash. **This is the product.** |
| `install.ps1` / `install.sh` | The installer (Windows / macOS-Linux). Verifies the bundle's content hash **before** writing anything (fail-closed), then materializes every file byte-exact into your project. |
| `uninstall.ps1` / `uninstall.sh` | Gated, audited uninstaller. Removes exactly the installed files; keeps files you edited (or backs them up with `-Force`/`--force`); honors a PM lock. |
| `harness-lock.ps1` / `harness-lock.sh` | PM tool to lock/unlock uninstall behind an approval code. |
| `harness-verify.ps1` / `harness-verify.sh` | Doctor: checks a project has the bundle applied correctly (files present + hash-match, hooks wired, lock status). |
| `CODEOWNERS.example` | Ready-to-use CODEOWNERS so a team can require PM approval to change/remove the harness at merge time (real enforcement). |
| `bundle.yaml` | The manifest (name/version/maintainer + the `provides` globs the bundle was packed from) — for transparency. |
| `CLAUDE.harness.md` | A generic, project-agnostic governance reference (Guiding Principles, Conventions C1–C10, Model Reference) to merge into your project's own `CLAUDE.md`. Also shipped inside the bundle. |
| `docs/` | Optional central-management guides: [`portal-usage-guide.html`](docs/portal-usage-guide.html) (Portal setup, token metering, onboard an existing project) and [`server-deploy-runbook.html`](docs/server-deploy-runbook.html) (self-host the Portal on a shared server). |

## Requirements

- **Claude Code** (the CLI/agent that reads `.claude/` and runs hooks).
- **Tooling** (install/uninstall/lock):
  - **Windows:** the `.ps1` scripts (PowerShell 5.1 built-in — no install needed).
  - **macOS/Linux:** the `.sh` scripts (bash + **python3**, both standard on
    macOS/Linux; no `jq` needed).
- **Governance hooks** ship in **both** flavors inside the bundle
  (`.harness/scripts/powershell/*.ps1` and `.harness/scripts/bash/*.sh`).
  Which one fires is decided by `.claude/settings.json` — see
  [Cross-platform hooks](#cross-platform-hooks) for how to wire it per OS.

## Install into your project

```powershell
# Windows (PowerShell)
git clone https://github.com/manhds82/Harness-ToolKIT.git
cd Harness-ToolKIT
powershell -File install.ps1 `
    -BundleFile standard-governance-1.5.0.bundle.json `
    -TargetDir C:\path\to\your-project
```

```bash
# macOS / Linux (bash + python3)
git clone https://github.com/manhds82/Harness-ToolKIT.git
cd Harness-ToolKIT
bash install.sh \
    --bundle standard-governance-1.5.0.bundle.json \
    --target /path/to/your-project
```

Both installers behave identically: print `[WRITE]`/`[SKIP]` per file, **never
overwrite an existing file** unless you pass `-Force` / `--force` (so your own
`CLAUDE.md`, `.claude/settings.json`, etc. stay safe), and **refuse to write
anything if the content hash doesn't match** (tamper / corruption check).

### Auto-merge governance into CLAUDE.md

Pass `-MergeClaude` (PowerShell) or `--merge-claude` (bash) to automatically
merge the harness governance reference into your project's `CLAUDE.md` in one
step — no manual copy-paste needed:

```powershell
# Windows: install + auto-merge CLAUDE.md
powershell -File install.ps1 `
    -BundleFile standard-governance-1.5.0.bundle.json `
    -TargetDir C:\path\to\your-project `
    -MergeClaude
```

```bash
# macOS / Linux: install + auto-merge CLAUDE.md
bash install.sh \
    --bundle standard-governance-1.5.0.bundle.json \
    --target /path/to/your-project \
    --merge-claude
```

Behaviour:
- **No `CLAUDE.md` yet** → creates it from `CLAUDE.harness.md`.
- **`CLAUDE.md` exists, no harness section** → appends the harness governance
  block with a `<!-- harness:merged -->` sentinel.
- **Sentinel already present** → skips silently (safe to re-run with `-Force`).

After install, **restart Claude Code** in your project so the new
`.claude/settings.json` (permissions + hooks) takes effect.

## Verify it's applied (the doctor)

Confirm a project has the bundle applied correctly at any time — it reads the
install receipt and checks every file is present + hash-matches, that the hooks
use the current schema and their guard script exists, and the PM-lock status.

```powershell
# Windows (the bundle also installs this into <project>/tools/harness-bundle/)
powershell -File harness-verify.ps1 -TargetDir C:\path\to\your-project
```
```bash
bash harness-verify.sh --target /path/to/your-project
```
Look for `== RESULT: APPLIED OK` (exit 0). `NOT FULLY APPLIED` (exit 1) lists what
to fix — e.g. missing files (re-run install) or an old-format `settings.json`
(re-install it so the hooks actually fire).

For the **full command & feature reference** (gateway, portal, tests, skills,
maintenance), see [`docs/COMMANDS.md`](https://github.com/manhds82/HarnessAIToolKIT/blob/main/docs/COMMANDS.md) in the source repo.

## What gets installed

```
your-project/
├── .claude/
│   ├── settings.json          # permission gate + 6 lifecycle hooks
│   ├── agents/*.md            # 9-agent fleet
│   └── skills/**              # 10 skills (pipeline + utilities)
├── .harness/
│   ├── control/               # risk-policy.yaml, tool-registry.json, guard-zones, patterns…
│   ├── schemas/               # JSON Schemas for the configs
│   ├── scripts/powershell/    # the hook + guard scripts
│   └── memory/constitution.md
├── contracts/                 # project.yaml, tool-registry.yaml, workflow.yaml, agent.yaml
├── tools/harness-bundle/      # in-project copy of install/uninstall/harness-lock (.ps1 + .sh)
└── CLAUDE.harness.md          # governance reference (compare/merge into your CLAUDE.md)
```

Install also writes `.harness/.bundle-manifest.json` — a receipt (each installed
path + its original SHA-256) so the in-project uninstaller knows exactly what to
remove and which files you've since edited, without needing the original bundle.

The bundle **does not ship a `CLAUDE.md`** — your project's own memory file is
never touched.

## What changes in your Claude Code sessions

**1. Permission gate** (`.claude/settings.json`, enforced natively by Claude Code):
- **Denies** destructive commands: `rm -rf`, `sudo`, `chmod -R`,
  `git reset --hard`, `git push --force[-with-lease]`, `del /F /S`,
  `Remove-Item -Recurse -Force`, `Start-Process -Verb RunAs`.
- **Asks** before: `Agent`, `Workflow`, `Skill`, `CronCreate/Delete`, `TodoWrite`.
- **Allows**: Read/Grep/Glob/Web*/Bash/PowerShell/Edit/Write/NotebookEdit.

**2. Lifecycle hooks** (PowerShell):
- **On every prompt** → prompt-injection scan; **hard-blocks** a HIGH-severity
  injection, logs findings to `.harness/telemetry/security-events.jsonl`.
- **Before every tool call** → runtime guard reads `risk-policy.yaml` +
  `tool-registry.json` and **hard-blocks** a matching deny-pattern or a
  deny-by-default high/critical tool.
- **After tool / subagent / session** → telemetry + token/cost sampling +
  append-only evidence ledger (`.harness/ledger/chain.jsonl`).

**3. Capabilities:** 9 role subagents (analyst, architect, boss, developer,
devops, researcher, reviewer, tester, writer) and 10 skills — the core pipeline
`/analyze-requirements` → `/implement-change` → `/verify-implementation` →
`/evidence-bundle`, plus `/fix-and-verify`, `/deep-research`, `/fan`,
`/deploy-to-test`, `/commit-deploy-log`, `/be-fe-security-audit`.

## Cross-platform hooks

The bundle ships the hook logic **twice** — `.harness/scripts/powershell/*.ps1`
and `.harness/scripts/bash/*.sh` (identical behavior) — plus two ready
`.claude/settings.json` variants. **The installer picks the right one for you:**
`install.ps1` keeps the PowerShell form; `install.sh` activates the bash form
(and never overwrites a `settings.json` you already had). So on a normal install
you don't wire anything by hand.

Why it matters: Claude Code runs a hook `command` through a shell (`sh -c` on
macOS/Linux, Git Bash / PowerShell on Windows), so a **bare `.ps1` path does not
run on macOS/Linux** — the hook must name an interpreter. The two forms the
installer selects between (shown for reference / manual verification):

```jsonc
// Windows — .claude/settings.json (PowerShell)
"hooks": {
  "PreToolUse": [{ "matcher": "",
    "hooks": [{ "type": "command",
      "command": "powershell", "args": ["-NoProfile","-File",
        "${CLAUDE_PROJECT_DIR}/.harness/scripts/powershell/harness-runtime-guard.ps1"] }] }]
}
```

```jsonc
// macOS / Linux — .claude/settings.json (bash)
"hooks": {
  "PreToolUse": [{ "matcher": "",
    "hooks": [{ "type": "command",
      "command": "bash", "args": [
        "${CLAUDE_PROJECT_DIR}/.harness/scripts/bash/harness-runtime-guard.sh"] }] }]
}
```

(Same pattern for `UserPromptSubmit` → `injection-scan`, `PostToolUse` →
`harness-post-tool-use`, `SessionStart`/`SessionEnd`, `SubagentStop` →
`agentops-sampler`.) A hook **blocks** a tool by exiting `2` (stderr → Claude)
or by printing `{"hookSpecificOutput":{"permissionDecision":"deny", ...}}` and
exiting `0`; the bundled guard scripts already do this.

> **Version note (verify on your Claude Code):** the exact `hooks` schema is
> version-specific. Confirm the shape against `claude` docs / `--help` for your
> version; older builds accepted a bare path string. The `permissions`
> allow/ask/deny list works identically on all OSes regardless of hooks.

## Configure for your project

1. **`contracts/project.yaml`** — the project SSOT:
   - `project.name` / `project.description` — your project's identity.
   - `identity.roles[].allowed_tools` — allowed tools **per role** (nested under
     `identity.roles`, not a top-level key).
   - top-level `budget:` — `max_tokens_per_session`, `max_cost_per_session_usd`,
     `alert_at_percent`.
   You can set the first two at install time instead:
   `-ProjectName "MyApp"` (description defaults to the name). It only writes
   while the contract still holds the shipped placeholder, so a project that
   already named itself is never renamed — `-ForceIdentity` overrides.
2. **Governance for every assistant, not just Claude** — pass `-MergeGuides` /
   `--merge-guides` at install (`-MergeClaude` still works as an alias). The one
   canonical text (`CLAUDE.harness.md`) is projected into each guide file your
   tools read:

   | File | Read by |
   |------|---------|
   | `CLAUDE.md` | Claude Code |
   | `AGENTS.md` | the cross-tool convention (Codex, Cursor, Jules, …) |
   | `.github/copilot-instructions.md` | GitHub Copilot |

   Edit the list in `.harness/control/casan-policies.yaml` →
   `governance.guide_targets` — adding a tool is one line, no script change.

   **Your content is never lost.** The text goes between
   `<!-- BEGIN harness-governance -->` and `<!-- END harness-governance -->`.
   A missing file is created, an existing one is **appended to**, and an update
   replaces only what is inside the markers. Keep your own rules **outside** the
   block and they survive every update; running install twice never duplicates it.

   > **Honest scope.** Only Claude Code *enforces* these rules, via
   > `.claude/settings.json` hooks and permission deny lists. Copilot, Codex and
   > friends have **no hook mechanism** — for them this file is guidance a model
   > may ignore. If you need them actually constrained, the control must sit
   > outside the assistant: a server-side gateway, CI that fails the build, and
   > branch protection + `CODEOWNERS` over `.harness/** .claude/** contracts/**`.
3. **`.harness/control/risk-policy.yaml`** — add/adjust the command deny
   patterns for your project. Guard scripts **read** this YAML, so you change
   policy by editing config, not scripts.

## Verify integrity yourself

`install.ps1` recomputes the SHA-256 over every `path:base64` pair and compares
it to the manifest's `content_hash` before writing. A tampered or truncated
bundle is rejected with `Bundle integrity check FAILED`. The published artifact:

```
content_hash : 715f91632bab06d5d3f42b09e240f4e695558a4e3a6b3d5999d69ffe8b295338
file_count   : 89
```

## Honest limitations

- **Local defense-in-depth, not a hard boundary.** Hooks + config live in the
  repo; a user with write access can relax `risk-policy.yaml` / `settings.json`.
  Un-bypassable enforcement needs a server-side gateway (not part of this bundle).
- **Hooks ship for both shells** (`.ps1` + `.sh`), but `.claude/settings.json`
  must point to the flavor for your OS (see [Cross-platform hooks](#cross-platform-hooks));
  a bare `.ps1` path does not run on macOS/Linux. The native permission gate
  works on every OS regardless.
- **No central server included.** Token budgets here are local telemetry only;
  multi-member budgets/dashboards require the separate Control Portal.
- **`secret-scan` is shipped but not wired to a hook by default** — wire it in
  `.claude/settings.json` if you want automatic secret scanning.

## Update

Re-run `install.ps1` / `install.sh` with a newer bundle. Additive by default; add
`-Force` / `--force` to bring every managed file up to the current version.

**Your project-owned files are safe.** The bundle declares a `preserve` list —
`contracts/project.yaml` and `.harness/control/casan-policies.yaml` are **never
overwritten once they exist, not even with `--force`**, because they hold your
identity, stack, doc refs and tuned suite commands. When the shipped copy has
moved on you get a `<file>.new` beside yours to diff and adopt new keys on
purpose. Guide files (`CLAUDE.md`, `AGENTS.md`, …) are merged, not replaced:
only the `BEGIN/END harness-governance` block is refreshed.

To update many projects at once (maintainer):

```powershell
powershell -File update-all-projects.ps1 [-WhatIf] [-NoIdentity] [-ForceIdentity]
```
```bash
bash update-all-projects.sh [--dry-run] [--no-identity] [--force-identity]
```
Each project is reinstalled to the newest bundle, named after its folder in
`contracts/project.yaml` (unless it already named itself), and its guide files
are refreshed.

## Uninstall (gated + audited)

Because the bundle ships the tooling **into** the project, you can uninstall
**from inside the project** — `uninstall` reads the install receipt
(`.harness/.bundle-manifest.json`), so no `-BundleFile` is needed. It removes
**exactly** the files the bundle installed, keeps files you *edited* (or backs
them up to `.harness-uninstall-backup/` and removes them with `-Force`), and
logs every attempt to an audit receipt at the project root.

```powershell
# From inside the installed project (Windows). -Force also backs up edited files;
# -Purge also drops runtime data (ledger + telemetry).
cd C:\path\to\your-project
powershell -File tools\harness-bundle\uninstall.ps1 -TargetDir .
powershell -File tools\harness-bundle\uninstall.ps1 -TargetDir . -Force
powershell -File tools\harness-bundle\uninstall.ps1 -TargetDir . -Force -Purge
```

```bash
# From inside the installed project (macOS / Linux)
cd /path/to/your-project
bash tools/harness-bundle/uninstall.sh --target .
bash tools/harness-bundle/uninstall.sh --target . --force
bash tools/harness-bundle/uninstall.sh --target . --force --purge
```

(You can still run the copies in **this** repo with `--bundle` if you prefer.)

```bash
# macOS / Linux — same behavior
bash uninstall.sh --target /path/to/your-project
bash uninstall.sh --target /path/to/your-project --force
bash uninstall.sh --target /path/to/your-project --force --purge
```

### Requiring PM approval to uninstall

**Local gate** — a PM locks the project so uninstall refuses without a code:

```powershell
# Windows
powershell -File harness-lock.ps1 -TargetDir C:\path\to\your-project -Action Set -PM "Dau Sy Manh <manhds@>"
powershell -File uninstall.ps1  -TargetDir C:\path\to\your-project -ApprovalCode <the-code>
powershell -File harness-lock.ps1 -TargetDir C:\path\to\your-project -Action Clear
```

```bash
# macOS / Linux
bash harness-lock.sh --target /path/to/your-project --action set --pm "Dau Sy Manh <manhds@>"
bash uninstall.sh    --target /path/to/your-project --approval-code <the-code>
bash harness-lock.sh --target /path/to/your-project --action clear
```

> **Be honest about what this is (C10).** The lock gates the *uninstall script*
> and creates an audit trail — it is a **deterrent**, not an OS-level lock.
> Anyone with write access to the folder can still delete files by hand. The
> lock file itself (`.harness/uninstall-policy.json`) can be deleted.

**Real enforcement for a team** — protect the governance paths at the
repository level, which **cannot be bypassed locally**:

1. Copy [`CODEOWNERS.example`](CODEOWNERS.example) to your project's
   `.github/CODEOWNERS`, set the PM as owner of `.harness/**`, `.claude/**`,
   `contracts/**`, `CLAUDE.harness.md`.
2. Enable branch protection on the default branch with **“Require review from
   Code Owners.”**

Now any PR that removes or edits the harness needs the PM's approval to merge —
enforced by GitHub, not by a script a developer can sidestep.

---

*Copyright © 2026 Dau Sy Manh <manhds@>. Licensed under Apache-2.0.*
