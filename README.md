# Harness AI Toolkit — Governance Bundle

A one-command, hash-verified **governance layer for Claude Code projects**.
Install it into any repo and your Claude Code sessions gain enforceable
guardrails (dangerous-command blocking, prompt-injection scanning, an
append-only audit ledger), a 9-agent role fleet, and a structured
analyze → implement → verify → evidence pipeline.

> **Author / Maintainer:** Dau Sy Manh — `manhds@fpt.com`
> **License:** Apache-2.0 (see [`LICENSE`](LICENSE) / [`NOTICE`](NOTICE))
> This repo is the **public distribution** (packaged artifact + installer +
> guide). It is consumed, not built here.

---

## What's in this repo

| File | Purpose |
|------|---------|
| `standard-governance-1.0.0.bundle.json` | The packaged governance bundle — 69 files (agents, skills, hooks, control policies, contract templates, JSON schemas, scripts), base64-encoded with a SHA-256 content hash. **This is the product.** |
| `install.ps1` | The installer. Verifies the bundle's content hash **before** writing anything (fail-closed), then materializes every file byte-exact into your project. |
| `uninstall.ps1` | Gated, audited uninstaller. Removes exactly the installed files; keeps files you edited (or backs them up with `-Force`); honors a PM lock. |
| `harness-lock.ps1` | PM tool to lock/unlock uninstall behind an approval code. |
| `CODEOWNERS.example` | Ready-to-use CODEOWNERS so a team can require PM approval to change/remove the harness at merge time (real enforcement). |
| `bundle.yaml` | The manifest (name/version/maintainer + the `provides` globs the bundle was packed from) — for transparency. |
| `CLAUDE.harness.md` | A generic, project-agnostic governance reference (Guiding Principles, Conventions C1–C10, Model Reference) to merge into your project's own `CLAUDE.md`. Also shipped inside the bundle. |

## Requirements

- **Claude Code** (the CLI/agent that reads `.claude/` and runs hooks).
- **PowerShell 5.1+** (Windows built-in) or **PowerShell 7+** (`pwsh`, cross-platform).
  The installer and the governance hooks are PowerShell scripts.
  - On macOS/Linux, install `pwsh` so the hooks run; the native Claude Code
    permission gate works regardless.

## Install into your project

```powershell
# 1. Get this repo (clone or download the .bundle.json + install.ps1)
git clone https://github.com/manhds82/Harness-ToolKIT.git
cd Harness-ToolKIT

# 2. Install into YOUR project's repo root
powershell -File install.ps1 `
    -BundleFile standard-governance-1.0.0.bundle.json `
    -TargetDir C:\path\to\your-project
```

The installer prints `[WRITE]` for each new file and `[SKIP]` for files that
already exist. **It never overwrites an existing file** unless you pass
`-Force`, so your project's own `CLAUDE.md`, `.claude/settings.json`, etc. are
safe. It refuses to write anything if the content hash doesn't match (tamper /
corruption check).

After install, **restart Claude Code** in your project so the new
`.claude/settings.json` (permissions + hooks) takes effect.

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
└── CLAUDE.harness.md          # governance reference (compare/merge into your CLAUDE.md)
```

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

## Configure for your project

1. **`contracts/project.yaml`** — the project SSOT:
   - `project.name` / `project.description` — your project's identity.
   - `identity.roles[].allowed_tools` — allowed tools **per role** (nested under
     `identity.roles`, not a top-level key).
   - top-level `budget:` — `max_tokens_per_session`, `max_cost_per_session_usd`,
     `alert_at_percent`.
2. **`CLAUDE.harness.md` → your `CLAUDE.md`** — open both side by side and copy
   the **Guiding Principles**, **Conventions C1–C10**, and **Model Reference**
   sections into your own `CLAUDE.md` (create one if you have none). Keep
   `CLAUDE.harness.md` as a read-only reference or delete it once merged.
3. **`.harness/control/risk-policy.yaml`** — add/adjust the command deny
   patterns for your project. Guard scripts **read** this YAML, so you change
   policy by editing config, not scripts.

## Verify integrity yourself

`install.ps1` recomputes the SHA-256 over every `path:base64` pair and compares
it to the manifest's `content_hash` before writing. A tampered or truncated
bundle is rejected with `Bundle integrity check FAILED`. The published artifact:

```
content_hash : 1c5a4d31ba5d644ecc6b9e50521c4940eb57b390c674a84de0e35f750bd49e19
file_count   : 69
```

## Honest limitations

- **Local defense-in-depth, not a hard boundary.** Hooks + config live in the
  repo; a user with write access can relax `risk-policy.yaml` / `settings.json`.
  Un-bypassable enforcement needs a server-side gateway (not part of this bundle).
- **Hooks are PowerShell.** On non-Windows, install `pwsh` or the hooks no-op
  (the native permission gate still works).
- **No central server included.** Token budgets here are local telemetry only;
  multi-member budgets/dashboards require the separate Control Portal.
- **`secret-scan` is shipped but not wired to a hook by default** — wire it in
  `.claude/settings.json` if you want automatic secret scanning.

## Update

Re-run `install.ps1` with a newer bundle and `-Force` to overwrite the managed
files (back up any you customized first — or let uninstall's backup handle it).

## Uninstall (gated + audited)

Use `uninstall.ps1` — it removes **exactly** the files the bundle installed
(reads the manifest), so your own files are never touched. Files you *edited*
since install are **kept** by default (or backed up to
`.harness-uninstall-backup/` and removed with `-Force`). Every attempt is logged
to an audit receipt at the project root.

```powershell
# Interactive: asks you to type the project folder name to confirm
powershell -File uninstall.ps1 -TargetDir C:\path\to\your-project

# Non-interactive / CI: -Force skips the prompt and also backs-up+removes edited files
powershell -File uninstall.ps1 -TargetDir C:\path\to\your-project -Force

# Also drop runtime data (ledger + telemetry), which are not part of the bundle
powershell -File uninstall.ps1 -TargetDir C:\path\to\your-project -Force -Purge
```

### Requiring PM approval to uninstall

**Local gate** — a PM locks the project so uninstall refuses without a code:

```powershell
# PM sets a lock (prompts for a hidden approval code; stored salted-hashed)
powershell -File harness-lock.ps1 -TargetDir C:\path\to\your-project -Action Set -PM "Dau Sy Manh <manhds@fpt.com>"

# Now uninstall needs the code, or it refuses and logs a denied attempt
powershell -File uninstall.ps1 -TargetDir C:\path\to\your-project -ApprovalCode <the-code>

# PM removes the lock later
powershell -File harness-lock.ps1 -TargetDir C:\path\to\your-project -Action Clear
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

*Copyright © 2026 Dau Sy Manh <manhds@fpt.com>. Licensed under Apache-2.0.*
