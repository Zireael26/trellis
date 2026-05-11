<div align="center">

# Trellis

### Engineering process for AI coding agents.

**One source of truth. Inherited by every project. Enforced by hooks. Audited weekly.**

*A trellis gives a climbing plant the structure to grow on. This one does the same for code an AI agent writes — without it the work sprawls and breaks; with it, it grows tall and clean.*

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-supported-7c3aed.svg)](https://docs.claude.com/en/docs/claude-code)
[![Codex](https://img.shields.io/badge/Codex-supported-10b981.svg)](https://github.com/openai/codex)
[![Forkable](https://img.shields.io/badge/Forkable-yes-f97316.svg)](#quick-start)
[![Shell](https://img.shields.io/badge/Shell-bash-181717.svg)](#requirements)

[Quick start](#quick-start) · [What you get](#what-you-get) · [Architecture](#architecture) · [Repo layout](#repo-layout) · [FAQ](#faq)

</div>

---

## Why this exists

The first time you let a coding agent write production code it feels like a superpower. The tenth time, you notice the corners it's been cutting: pushed straight to `main`, marked a task "done" when the tests never ran, summarised what it intended to do instead of what it actually did, force-pushed over an hour of your work to "clean things up."

None of those are bugs in the model. They are gaps in the *process* around the model — the same gaps human teams spent decades closing with branch protection, code review, commit conventions, CI gates, and a thousand small rituals. An agent has none of that scaffolding by default.

**Trellis is that scaffolding, opinionated, in one repo, forkable in ten minutes.**

---

## What you get

| | |
|---|---|
| 📜 **Parent rules in one place** | `core-rules/CLAUDE.md` is the single source of truth. Every project inherits via symlink — Claude Code through `.claude/rules/`, Codex through `AGENTS.md` + `.agents/`. |
| 🪝 **9 canonical hooks, 3 tiers** | Fast-local (<3s every turn) · Heavy-gated (on `Stop`, ≤90s) · Git-boundary (husky / native). Blocks `rm -rf ~`, force-pushes, direct pushes to `main`, secrets reads, and "done" without receipts. |
| ✅ **A harness-agnostic process-gate skill** | One canonical implementation, symlinked into every project. Runs the same way in Claude Code, Codex, `claude -p`, and CI. Emits a fixed verdict block: `MERGEABLE / NEEDS CHANGES / BLOCKED`. |
| 🔍 **A fleet of 10 scheduled audits** | Weekly sweeps for hook drift, `--no-verify` bypasses, dep CVEs, test rot, registry/blacklist health. Every report is dated markdown — grep, diff, quote in commits. |
| 📐 **Rule of Three for evolution** | New rules wait in `core-rules/deferred.md` until a 3rd independent project adopts them. n=2 is the danger zone. |
| 🤖 **Codex parity, opt-in or opt-out** | Default config enables both harnesses with the same policy intent. Remove `"codex"` from `trellis.config.json` if you don't use it. |

---

## Architecture

<div align="center">
  <img src="docs/architecture.svg" alt="Trellis architecture — parent control plane, project inheritance, three-tier hook enforcement, and scheduled audit feedback loop" width="100%"/>
</div>

The control plane owns the rules. Projects inherit through symlinks. Hooks enforce in the moment. Audits enforce over time. The Rule-of-Three loop keeps the parent layer honest.

---

## Quick start

> **Two ways to set up. Pick one.**

### (A) Agent-driven — ~10 minutes, recommended

1. Clone this repo.
2. Open it in Claude Code or Codex (or paste [`AGENT_SETUP.md`](AGENT_SETUP.md) into any agent session with filesystem tools).
3. The agent interviews you for paths/harness/name, fills placeholders in-place, optionally enables Codex parity, installs the inheritance symlinks, and seeds the canonical hooks.

That's it. No manual sed.

### (B) Manual — ~30 minutes

Follow [`SETUP.md`](SETUP.md) step by step.

### After setup — onboard each project

Paste [`AGENT_ONBOARD_PROJECT.md`](AGENT_ONBOARD_PROJECT.md) into an agent open inside your customised `trellis/`. It interviews you, runs `scripts/onboard-project.sh`, wires the project's `CLAUDE.md`, updates `registry.md`, and commits.

Works for new projects, fresh clones of registered projects, and drift repair.

---

## The three tiers, in 30 seconds

```
Tier 1 — fast-local         < 3s, every agent turn
─────────────────────────────────────────────────────
block-destructive   denies rm -rf ~, git push --force, DROP TABLE, .env reads
post-edit-verify    lints just the touched file (eslint/ruff/clippy/govet)
session-context     injects last session's state on SessionStart
save-context-log    writes context-log.md on PreCompact / Stop
post-compact-context  re-injects context-log.md after compaction
truncation-check    flags >50K-char tool results

Tier 2 — heavy-gated         ≤ 90s, on Stop
─────────────────────────────────────────────────────
stop-verify             open todos? typecheck? lint? fast tests? → block on any fail
code-review-subagent    dispatches a read-only reviewer on edit-heavy turns (≥3 files)
ui-verify               boots dev server + screenshots affected route on UI changes

Tier 3 — git-boundary        husky or native git hooks
─────────────────────────────────────────────────────
pre-commit          lint-staged on staged files
commit-msg          Conventional Commits, project-configured scope allowlist
pre-push            blocks direct push to main; runs typecheck/lint/tests
```

Every tier has the same escape hatch — `TRELLIS_ALLOW_MAIN_PUSH=1`, `--no-verify`, override env vars — and every escape hatch is **noisy**. The `bypass-tripwire` audit surfaces every use within 8 days, and the audit reports persist in git.

---

## The audit fleet

Ten scheduled tasks, registered as cron jobs, sweep every project in `registry.md`:

| Audit | Cadence | What it catches |
|---|---|---|
| `cross-project-process-audit` | Mon 10:00 | Hook presence, staleness, required files, inheritance wiring |
| `registry-blacklist-health` | Mon 10:30 | Registry ↔ filesystem ↔ blacklist consistency |
| `test-health` | Mon 11:00 | Fast suite green/red across the registry, last-green bisect on red |
| `dep-currency` | Mon 11:30 | Outdated-dep scan: patch / minor / major drift |
| `parent-hook-drift` | Sun 21:00 | SHA256 canonical-vs-deployed comparison for every hook |
| `bypass-tripwire` | Weekdays 08:00 | Silent unless someone used `--no-verify`, force-push, or direct-to-main |
| `dep-vulnerabilities` | Weekdays 08:30 | CVE / GHSA via native pkg-mgr audit + osv-scanner |
| `gotchas-rollup` | 1st of month | Rule-of-Three engine — promotes n≥3 patterns to parent rules |
| `audit-report-rollup` | 1st of month | Month-over-month trend report across every other audit |
| `dep-major-upgrade-watch` | 1st of month | Framework-tier (Next, React, TS, Node) drift vs. your watchlist |

Reports land in `audits/YYYY-MM-DD-<task>.md`. Examples (redacted) live in [`examples/audits/`](examples/audits/).

---

## Repo layout

```
.
├── README.md                  ← you are here
├── SETUP.md                   ← human-facing setup walkthrough
├── AGENT_SETUP.md             ← paste-into-agent prompt that does setup for you
├── AGENT_ONBOARD_PROJECT.md   ← onboard a project after Trellis is bootstrapped
├── LICENSE                    ← MIT
│
├── core-rules/                ← THE PARENT LAYER — what every project inherits
│   ├── CLAUDE.md              ← terse parent rules
│   ├── AGENTS.md              ← symlink → CLAUDE.md for Codex parity
│   ├── hooks.md               ← spec for the 9 canonical hooks (3 tiers)
│   ├── hooks/                 ← canonical Claude Code hook implementations
│   ├── codex/                 ← canonical Codex hooks.json + hook scripts
│   ├── husky/                 ← canonical pre-commit / commit-msg / pre-push
│   ├── skills/process-gate/   ← canonical pre-PR enforcement skill
│   ├── templates/             ← per-project file templates (gotchas, context-log)
│   ├── inheritance.md         ← how Claude and Codex inheritance work
│   └── deferred.md            ← rules waiting for their 3rd project (Rule of Three)
│
├── registry.md                ← list of projects under Trellis management
├── blacklist.md               ← projects to skip
│
├── engineering-process.md     ← THE MANUAL — narrative source of truth
│
├── scheduled-tasks/           ← 10 audits + 2 drafts; each is prompt + targets
├── scripts/                   ← onboard-project, sync-hooks, sync-codex-hooks
├── audits/                    ← generated audit reports land here
├── examples/audits/           ← redacted sample reports
└── docs/                      ← provenance + LIFT/LEAVE/DEFER recon
```

---

## What you customise

Five placeholders. Setup replaces them in-place.

| Placeholder | What it becomes | Example |
|---|---|---|
| `__TRELLIS_PATH__` | Absolute path where you cloned this repo | `/Users/jane/projects/trellis` |
| `__PROJECTS_ROOT__` | Absolute path to the parent dir holding your projects | `/Users/jane/projects` |
| `__MAINTAINER_NAME__` | Your name | `Jane Doe` |
| `__GITHUB_USER__` | Your GitHub handle | `janedoe` |
| `__USER_HOME__` | Your home dir (rare — legacy refs only) | `/Users/jane` |

`AGENT_SETUP.md` walks any LLM through asking you for these values and substituting them.

---

## Requirements

- **macOS or Linux** with `bash`, `git`, and `jq` on `PATH`. Hooks degrade gracefully if `jq` is missing.
- **Node.js** for projects using husky. (For Unity / Rust / Go / Python-only projects, see [`core-rules/inheritance.md`](core-rules/inheritance.md) → "Native git hooks".)
- **Claude Code and/or Codex.** Default config enables both. Remove either from `trellis.config.json` if you don't use it.
- **Codex hooks opt-in** requires Codex CLI with hooks support and `[features] codex_hooks = true` in `$CODEX_HOME/config.toml`.

---

## FAQ

<details>
<summary><b>Why both Claude Code <i>and</i> Codex?</b></summary>

Different harnesses have different strengths and I use both depending on the project. Forcing a single harness across every project would mean either giving up Codex's strengths or giving up Claude Code's. Trellis keeps the policy intent identical across them — same rules, different hook envelopes — so the choice is per-project, not per-process.

</details>

<details>
<summary><b>Why the Rule of Three?</b></summary>

n=1 is anecdote. n=2 is coincidence dressed as a pattern. n=3 is the cheapest sample size that lets you commit to an abstraction without locking in the wrong shape and the wrong defaults. Unwinding a bad parent rule across five projects is painful. Waiting for the third witness is free.

</details>

<details>
<summary><b>What if I disagree with a parent rule?</b></summary>

Fork it, edit `core-rules/CLAUDE.md`, done. The parent layer is yours after you clone. Trellis is opinionated, not prescriptive — the value is the *shape* (parent + child + hooks + audits + Rule of Three), not any specific rule.

</details>

<details>
<summary><b>Can I use this without Codex / without Claude Code?</b></summary>

Yes. Remove the harness you don't use from `harnesses` in `trellis.config.json`. Onboarding will skip the corresponding artifact tree.

</details>

<details>
<summary><b>What about projects without <code>package.json</code> (Unity, Rust, Go, Python)?</b></summary>

Native git hooks under `.githooks/` with `git config core.hooksPath = .githooks`. The PR-flow guard (`pre-push` blocking direct push to `main`) is the same; husky just isn't the vehicle. See [`core-rules/inheritance.md`](core-rules/inheritance.md) → "Native git hooks".

</details>

<details>
<summary><b>How do I tune the rules?</b></summary>

Per-project overrides live in `.claude/hooks/config.sh` (and `.codex/hooks/config.sh` if applicable). The parent hook scripts are read-only; projects point them at their tools via env vars. See [`hooks.md`](core-rules/hooks.md) → "Project overrides".

</details>

---

## Write-up

A longer-form blog post walking through the design decisions, the five principles, and the lessons:

→ **[Trellis: An Engineering Process for AI Coding Agents](https://akaushik.org/writing/trellis)**

---

## License

MIT — see [`LICENSE`](LICENSE) and [`docs/PROVENANCE.md`](docs/PROVENANCE.md) for upstream attribution.

---

<div align="center">

Built and maintained by [**Abhishek Kaushik**](https://akaushik.org).

If you fork it, tell me what you change — the Rule of Three only works with three witnesses.

</div>
