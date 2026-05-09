# Scheduled tasks — index

This directory holds prompt + config for every centralized scheduled task
run out of Software Engineering Core. Tasks iterate over
`registry.md ∖ blacklist.md` unless noted otherwise.

Each task lives in its own subdirectory:

```
<task-name>/
  prompt.md       # Full task instructions (canonical — scheduler reads this)
  targets.md      # Config: scope, overrides, skip lists, tunable thresholds
```

The scheduler entry (registered via `mcp__scheduled-tasks__create_scheduled_task`)
is a **thin wrapper** that reads these two files at run time. That way, the
prompt can be edited here in version control without reregistering the task.

---

## Tier 1 — registered and running

Ten centralized tasks cover: hook compliance, process bypasses, test health,
control-plane hygiene, pattern rollup, executive summary, dependency posture
(security, currency, major-version watch), and fleet-wide security baseline.

| Task | Cadence | Cron (local) | Purpose |
|---|---|---|---|
| `cross-project-process-audit` | Weekly | `0 10 * * 1` (Mon 10:00) | Compliance snapshot — hook presence, staleness, required files. |
| `registry-blacklist-health` | Weekly | `30 10 * * 1` (Mon 10:30) | Audits registry ↔ filesystem ↔ blacklist consistency. |
| `test-health` | Weekly | `0 11 * * 1` (Mon 11:00) | Runs each project's fast test suite; bisects for last-green on red. |
| `dep-currency` | Weekly | `30 11 * * 1` (Mon 11:30) | Outdated-dep scan: patch / minor / major drift across the registry. |
| `bypass-tripwire` | Weekdays | `0 8 * * 1-5` (weekdays 08:00) | Silent-unless-tripped scan for `--no-verify`, force-push, direct-to-main. |
| `dep-vulnerabilities` | Weekdays | `30 8 * * 1-5` (weekdays 08:30) | CVE / GHSA scan via native pkg-mgr audit + osv-scanner. |
| `parent-hook-drift` | Weekly | `0 21 * * 0` (Sun 21:00) | SHA256-compares canonical hooks vs. deployed copies. |
| `gotchas-rollup` | Monthly | `0 9 1 * *` (1st 09:00) | Rule-of-Three aggregator — n≥3 → promote, n=2 → defer. |
| `audit-report-rollup` | Monthly | `0 10 1 * *` (1st 10:00) | Month-over-month trend report across all other audits. |
| `dep-major-upgrade-watch` | Monthly | `0 11 1 * *` (1st 11:00) | Curated framework-tier (Next, React, TS, Node…) drift vs. watchlist targets. |
| `security-baseline` | Quarterly | `0 5 1 1,4,7,10 *` (Q1/Q2/Q3/Q4 1st 05:00) | Mode 1 fleet-wide security baseline (semgrep + osv-scanner + gitleaks). Host-pinned. Rewrites per-project baseline JSON; diff scans dedupe against newest. |

**Ordering rationale:**

- Monday morning runs in strict sequence so downstream tasks see a verified
  target list: `cross-project-process-audit` (10:00) →
  `registry-blacklist-health` (10:30) → `test-health` (11:00) →
  `dep-currency` (11:30). Currency lands last so it doesn't pile upgrade
  noise on top of test-failure noise — by 11:30 the user already knows which
  projects are healthy enough to plan upgrades for.
- `parent-hook-drift` is Sunday night so Monday morning can act on findings
  within the same week.
- `bypass-tripwire` fires early (08:00) and is silent on clean days —
  noise-free daily discipline check. `dep-vulnerabilities` runs right after
  it (08:30) so a critical CVE published overnight surfaces in the day's
  first audit pass; weekday-only because weekend CVE drops will be picked up
  Monday and the workflow doesn't need weekend-noise.
- Monthly rollups (`gotchas-rollup`, `audit-report-rollup`,
  `dep-major-upgrade-watch`) run on the 1st in sequence 9:00 → 10:00 →
  11:00. The major-upgrade audit goes last so it can cite both rollups —
  e.g., a gotcha hit by 3+ projects on the same Next major is exactly the
  evidence the upgrade-watch wants.

---

## Tier 2 — drafted, not scheduled

These are real tasks with working prompts. They're parked pending evidence
that the Tier 1 stack isn't enough. Each `prompt.md` includes promotion
criteria — the specific signal that would justify turning it on.

| Task | Cadence (proposed) | Reason parked |
|---|---|---|
| `lint-debt-trend` | Weekly | Wait to see if the PostToolUse hook is enough to cap warnings. |
| `large-file-watch` | Weekly | Wait for evidence that big-file pain is real. |

To promote a Tier 2 task to Tier 1:

1. Verify the prompt is still accurate (reference the current hook manifest,
   current file paths, current thresholds).
2. Register via `mcp__scheduled-tasks__create_scheduled_task` with a
   thin-wrapper prompt that points at this directory (same pattern as the
   Tier 1 tasks).
3. Add a row to the table above and move the task's block from the Tier 2
   section.

---

## Neev-scoped tasks (not centralized)

The following scheduled tasks predate the centralized stack and operate
only on `msme-neev`. They are **not** in this directory and do not iterate
the registry. They continue to run in parallel:

| Task | Cadence | Purpose |
|---|---|---|
| `weekly-process-health-check` | Mon 09:00 | Neev EPM gaps, risk register, tech debt. |
| `sprint-boundary-review` | Fri 09:00 (biweekly) | Neev Definition-of-Done audit, sprint summary. |
| `monthly-documentation-audit` | 1st 09:00 | Neev EPM currency, missing ADRs, Obsidian sync. |

If any of their concerns generalize beyond Neev — i.e., we find ourselves
wanting the same check on another project — lift them into this directory
as a Tier 1 task and retire the Neev-scoped copy.

---

## Prompt & targets conventions

Every `prompt.md` should specify, in this order:

1. **Purpose** — one paragraph: what this checks, why it matters.
2. **Inputs** — exact paths it reads (registry, blacklist, project files,
   prior audits).
3. **Process / checks** — numbered list of what to do per target.
4. **Output** — exact path pattern (`audits/YYYY-MM-DD-<task>.md`) and a
   template skeleton of the report.
5. **Severity taxonomy** — critical / warning / info, when each applies.
6. **Boundaries** — read-only rules, what not to modify.
7. **Sensible failure modes** — what to do if inputs missing, registry
   empty, network blocked, etc.

Every `targets.md` should specify:

1. **Scope** — cadence, ordering rationale vs. sibling tasks.
2. **Per-project overrides** — escape hatch for projects that need a
   different command or threshold.
3. **Skip list** — projects that can't be checked automatically (e.g.,
   needs GPU, needs secrets).
4. **Tunable thresholds** — if the task has magic numbers, surface them
   here with defaults and override syntax.

---

## Audit file naming conventions

Two file classes live side-by-side in `audits/`. The audit-report-rollup
distinguishes them when computing run counts and trends.

| Class | Filename pattern | Example | Source |
|---|---|---|---|
| **Audit** (scheduled-task output) | `YYYY-MM-DD-<task>.md` | `2026-05-08-cross-project-process-audit.md` | One of the registered tasks above |
| **Remediation report** (post-audit fix narrative) | `YYYY-MM-DD-<source-audit>-remediation.md` | `2026-04-27-cross-project-process-audit-remediation.md` | Hand-authored after a remediation cycle |
| **Plan** (executable contract for a remediation cycle) | `YYYY-MM-DD-<topic>-plan.md` | `2026-05-08-se-core-meta-audit-plan.md` | Hand-authored alongside / before remediation |
| **Source audit** (one-off deep audit) | `YYYY-MM-DD-<topic>.md` | `2026-05-08-se-core-meta-audit.md` | Hand-authored, not from a scheduled task |

Rules:
- The `-remediation.md` suffix is **load-bearing** — `audit-report-rollup`'s
  parser must treat these as a separate class so monthly run counts of the
  underlying scheduled task aren't double-counted by their remediation reports.
- Plan files (`-plan.md` suffix) are also separate from regular audits — they
  are status-tracked by the loop agent, not by the rollup.
- Source audits without `-remediation` or `-plan` suffix and without a
  task-name match are one-off authored audits — surface them in the rollup
  but don't try to compute trend lines.
- Plan task: P3.8 introduced this taxonomy. P3.6 conformance test enforces it.

Some tasks also carry a curated, human-edited reference file alongside
`prompt.md` / `targets.md` (e.g., `dep-major-upgrade-watch/watchlist.md`).
Convention: name it for what it contains, document the read/write contract
inline at the top of the file, and never let the audit modify it.

Read-only across project state is the default. Any task that writes to a
project must say so loudly in its Boundaries section.

---

## Connected-folder requirement (dep-* tasks)

The three dependency tasks (`dep-vulnerabilities`, `dep-currency`, `dep-major-upgrade-watch`) Read files under `__PROJECTS_ROOT__/<project>/`. Cowork mode bounds `Read` to **connected folders** — directories explicitly attached to the running session.

Each scheduled task captures its connected-folder set **at registration time** from the session that registered it. The cron path runs the task with that captured set; "Run now" inherits the calling Cowork session's set instead.

**Required folder set for dep-* tasks:** both `__SE_CORE_PATH__/` and `__PROJECTS_ROOT__/`. Reference: `cross-project-process-audit` and `gotchas-rollup` are configured this way and run successfully.

**If you create or recreate a dep-* task**, do it from a Cowork session that has both folders connected — otherwise the new registration will only capture `se-core/` and the task will hit the connected-folder preflight on every run, write a stub report, and exit. The MCP scheduler tool (`create_scheduled_task` / `update_scheduled_task`) does not expose folder selection; the only way to fix a misregistered task is to delete and recreate from a properly-connected session, or edit folder selection in the Cowork app's task-settings UI.

**Symptoms of a misconfigured task:**
- Audit report contains `personal/ not connected to this session` info finding (preflight detected the issue and exited cleanly).
- Older audits — written before the preflight — instead show 6 noisy "<project>: path missing" rows; those reports are misleading and the underlying cause was the same.

---

## Maintenance

- When the canonical hook manifest changes (adding a new hook under
  `core-rules/hooks/`), update `parent-hook-drift/prompt.md` and
  `parent-hook-drift/targets.md` to include the new hook.
- When a new project joins `registry.md`, no changes needed here — the
  tasks pick it up automatically on the next run.
- When thresholds (`PROMOTE_THRESHOLD`, `WARNING_LOC`, etc.) need tuning,
  edit the relevant `targets.md`. The scheduler re-reads these at runtime.
- Retiring a task: set `enabled: false` via
  `mcp__scheduled-tasks__update_scheduled_task`, then move its row into a
  "retired" section below (keep the history).

---

## Retired tasks

*(none yet)*
