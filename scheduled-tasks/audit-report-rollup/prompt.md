# Audit report rollup (monthly)

You are reading the past month's audit reports in
`__TRELLIS_PATH__/audits/` and producing
a single executive summary that shows trends across tasks and time. The raw
audits are detailed and numerous; this rollup is the "did things get better
or worse?" view.

## Inputs

1. All files in `__TRELLIS_PATH__/audits/`
   whose filename starts with a date in the last 35 days (i.e., previous
   calendar month plus a few days of overlap).
2. For context: the most recent `-rollup` from the prior month (if any), so
   you can compare month-over-month.

## Audit file naming convention

Authoritative taxonomy: [`scheduled-tasks/README.md` "Audit file naming conventions"](../README.md#audit-file-naming-conventions).

Four file classes live in `audits/`:

| Class | Pattern | Treatment in this rollup |
|---|---|---|
| **Audit** (scheduled-task output) | `YYYY-MM-DD-<task>.md` | Group by `<task>`, count per-task runs, compute trends |
| **Remediation report** | `YYYY-MM-DD-<source-audit>-remediation.md` | Separate class — list under "Remediation activity"; do **not** count toward the source audit's run count |
| **Plan** | `YYYY-MM-DD-<topic>-plan.md` | Skip in this rollup (loop agent tracks status) |
| **Source audit** (one-off authored) | `YYYY-MM-DD-<topic>.md` (no `-remediation`/`-plan` suffix; `<topic>` doesn't match a registered task name) | List under "One-off authored audits"; surface findings but don't trend-line |

Recognized scheduled-task names (group regular audits under these):

- `cross-project-process-audit` — weekly
- `registry-blacklist-health` — weekly
- `test-health` — weekly
- `bypass-tripwire` — daily (may be silent on clean days; count those too)
- `parent-hook-drift` — weekly
- `gotchas-rollup` — monthly (one file, from the 1st)
- `dep-currency` — weekly
- `dep-vulnerabilities` — daily
- `dep-major-upgrade-watch` — monthly
- `security-baseline` — quarterly

## Eval harness inputs

Phase 4 P4.3 ships an eval harness at `core-rules/evals/`. Per-run results land under `core-rules/evals/.results/<timestamp>.json` (gitignored). Schema: see [`core-rules/evals/SCHEMA.md`](../../core-rules/evals/SCHEMA.md).

For this rollup, look for eval-results files in the last 30 days under `core-rules/evals/.results/`. Each results file's top-level shape is:

```json
{
  "schema_version": 1,
  "started_at": "...",
  "fixtures": [ { "id": "...", "project": "...", "pass_rate": 0.8, "passed": true, ... } ],
  "summary": { "total": <N>, "passed": <N>, "failed": <N>, "pass_rate": 0.0–1.0 }
}
```

If no results files exist (i.e., `ANTHROPIC_API_KEY` not yet wired per plan task P4.4a, or no PRs ran the workflow's `run` job yet), surface that in the rollup as: "Eval harness shipped (PRs #44/#47/#48-50/#52-53), runtime not yet wired — eval pass-rate trend unavailable until P4.4a lands." Do not synthesize results.

If results files exist, treat them as inputs alongside audit files: per-fixture pass-rate, per-project rollup, 30-day trend. Promote-rule rule (per audit §6 P4.4): rule-changes (PRs touching `core-rules/CLAUDE.md`, `core-rules/hooks/*.sh`, or any skill prompt) should not regress eval pass-rate. Flag any rule-touching PR whose post-merge eval pass-rate is below the prior 7-day median.

## Process

### 1. Per-task rollup

For each task, for the last 30 days:

- **Run count**: how many audits fired vs. expected (e.g., 4 weekly audits
  in a month; 20–22 weekdays of `bypass-tripwire`).
- **Severity counts**: sum the critical / warning / info findings across
  all audits.
- **Repeat offenders**: which projects appear in the "problems" list most
  often?
- **Trend vs. prior month**: if last month's rollup exists, compare counts.

### 2. Cross-task synthesis

Look for patterns that span tasks. Examples worth surfacing:
- Project X has been red in `test-health` for 3+ weeks running.
- Project Y keeps drifting in `parent-hook-drift` *and* keeps missing
  `.claude/` in `registry-blacklist-health` — probably not actually being
  maintained.
- `bypass-tripwire` has fired zero times in 30 days → either processes are
  working or the tripwire is broken. Sanity-check the latter.

### 3. Automation opportunities

If a finding appears in N audits in the month, that's a signal it should be
automated further upstream — a new hook, a stricter existing hook, or a
prompt-level rule. Surface these explicitly.

## Output

Write to `__TRELLIS_PATH__/audits/YYYY-MM-DD-audit-rollup.md` (monthly, 1st of the month):

```
# Audit rollup — <YYYY-MM>

## Executive summary

<2-3 sentences — is the pipeline healthier, worse, or flat compared to last month? What's the biggest concern?>

## Run health

| Task | Expected runs | Actual runs | Missed |
|---|---|---|---|
| cross-project-process-audit | 4 | <N> | <list missing dates if any> |
| ... | | | |

Missed runs usually mean the app wasn't open at the scheduled time. If a run was missed, note it but don't treat it as a task failure.

## Findings by severity (last 30 days)

| Severity | This month | Last month | Δ |
|---|---|---|---|
| Critical | <N> | <N> | <+/-> |
| Warning | <N> | <N> | <+/-> |
| Info | <N> | <N> | <+/-> |

## Eval pass-rate (last 30 days)

If `core-rules/evals/.results/` has results files in the window:

| Project | Fixtures | Pass-rate (median) | Trend (7d) | Notes |
|---|---|---|---|---|
| neev | 10 | <0.0–1.0> | <+/-> | <regression flags or empty> |
| tgsc | 10 | <...> | <...> | <...> |
| akaushik.org | 10 | <...> | <...> | <...> |
| curat.money | 10 | <...> | <...> | <...> |
| vericite | 10 | <...> | <...> | <...> |
| lume | 10 | <...> | <...> | <...> |
| **Fleet** | 60 | <...> | <...> | <...> |

If no results files in the window, replace the table with: "Eval harness landed (PRs #44, #47, #48–53). Awaiting `ANTHROPIC_API_KEY` wiring (plan task P4.4a) before runtime data flows. No regression signal yet."

## Per-task highlights

### cross-project-process-audit
- Key finding: <one-liner>
- Repeat offender: <project>
- Trend: improving / worsening / flat

<repeat per task>

## Cross-task patterns

<bullets — things that only show up when you look across tasks>

## Automation opportunities

1. <finding appears N times → suggest X>
2. ...

## Recommended focus this month

<3-5 prioritized items>
```

## Boundaries

- **Read-only.** Do not modify any audit file. Do not modify the registry,
  blacklist, or any project.
- Do not re-run any audit. This task summarizes what's already been
  produced; it doesn't re-execute the underlying checks.

## Sensible failure modes

- If `audits/` is missing or empty, write a short report noting that no
  audits have run and stop.
- If expected tasks haven't produced any audits at all in 30 days, that's
  itself the top finding — surface it prominently.
- If prior-month rollup is missing, skip the trend comparison and note that
  this is the first rollup.

## Loop safety

This task is a Trellis loop and honors the loop-safety contract
([`core-rules/loop-safety.md`](../../core-rules/loop-safety.md)). It declares
and honors three ceilings and **halts on any one** of them; ceiling values
resolve most-specific-wins: per-loop override → `.trellis.config.json.loop_safety`
→ `trellis.config.json.loop_safety` → built-in fallback constants
(100 / 3 / $1000). On a trip the loop hard-stops (never auto-continues) and
emits a structured halt report (which ceiling tripped, last progress marker,
work done); as an unattended cron loop it surfaces the halt in its run report
rather than dying silently.

- `max_iterations`: inherits default (100)
- `no_progress_iterations`: inherits default (3)
- `budget_ceiling_usd`: inherits default (1000)
- **Progress signal**: work-list drain — the remaining set of audit and
  eval-results files to read shrinks each iteration.
