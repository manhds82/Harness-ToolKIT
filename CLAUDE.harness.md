<!--
  Harness AI Toolkit — Common Governance Reference
  Copyright (c) 2026 Dau Sy Manh <manhds@fpt.com>. All rights reserved.
  Author / Maintainer: Dau Sy Manh <manhds@fpt.com>
  Bundle: standard-governance

  This file ships INSIDE the governance bundle so it lands in every project
  that installs it (as `CLAUDE.harness.md`, a name distinct from your own
  `CLAUDE.md` so nothing is overwritten). It is a REFERENCE to compare against
  and copy from — not your project's live memory file.
-->

# Governance Reference (merge into your project's `CLAUDE.md`)

> **Attribution:** Governance harness authored by **Dau Sy Manh**
> (`manhds@fpt.com`). When a review/audit skill inspects a project, this header
> and the bundle `maintainer` field identify the source.

**How to use this file:** open your project's own `CLAUDE.md` side by side with
this one and copy in the sections below that fit your project. Keep this file as
a read-only reference (or delete it once merged). Do **not** copy any
project-specific content — the sections here are written to be generic.

---

## Guiding Principles

- **Hooks > rules:** enforceable hooks beat static conventions in prose.
- **Execution ≠ control:** the tool that executes a side-effect is not the thing
  that decides whether it's allowed; keep the decision in policy/config.
- **No false safety:** local hooks are defense-in-depth. Anything truly
  high-risk needs server-side enforcement at a gateway — say so honestly.
- **Lowest layer sets the ceiling:** the weakest governance layer caps the whole
  system's assurance; don't advertise more safety than the weakest link gives.

## Key Conventions (C1–C10)

- **C1 — Native layout:** use the agent tool's native config dir (`.claude/`);
  project memory lives in `CLAUDE.md`.
- **C2 — Config in data, not code:** guard/hook scripts **read** policy from
  YAML/JSON — never hardcode rules inside scripts.
- **C3 — Registered side-effects:** every side-effect-capable tool has an entry
  in the tool registry; unknown tools are denied by default.
- **C4 — Explicit model ladder:** pin the exact models you allow (e.g. the
  Claude family: Fable 5 / Opus 4.8 / Sonnet 5 / Haiku 4.5). Any on-prem/OSS
  tier is a separate ladder and must not be mislabeled as the vendor's model.
- **C5 — No hardcoded secrets:** never commit secrets/API keys; source them from
  env or a vault (file-based `*_FILE` secrets for containers).
- **C6 — Side-effects via approved path only:** deny-by-default for dangerous
  operations (destructive shell, deploys, DB writes, outbound fetch) unless they
  run through the approved workflow.
- **C7 — One primary script language + bash parity:** pick a primary shell for
  harness scripts (PowerShell here) and keep a bash counterpart; use absolute
  paths inside harness scripts. Application code (web/back-end) is a separate
  layer and is not bound by this.
- **C8 — Schema-validatable config:** every JSON/YAML policy file is validatable
  by a JSON Schema kept alongside it.
- **C9 — Immutable logging:** every side-effect tool call appends one line to an
  append-only ledger (identity + input/output hash); the chain is tamper-evident.
- **C10 — Honest about enforcement:** local hooks are defense-in-depth; label
  high-risk actions as "needs server-side enforcement" rather than implying the
  local hook is a hard boundary.

## Model Reference (adjust to your licensed models)

| Profile       | Fable 5    | Opus 4.8    | Sonnet 5    | Haiku 4.5   |
|---------------|------------|-------------|-------------|-------------|
| planning      | Primary    | Fallback    | —           | —           |
| coding        | —          | Primary     | Fallback    | —           |
| review        | —          | Primary     | —           | Fallback    |
| summarization | —          | —           | —           | Primary     |

---

*Governance harness · standard-governance bundle · © 2026 Dau Sy Manh
<manhds@fpt.com>.*
