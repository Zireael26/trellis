# Obsolete-rules audit (quarterly)

You are reviewing the Trellis rules corpus for entries that have aged out of usefulness as the underlying Claude Code + Codex harnesses and the Claude model family have improved. The goal is to surface rules that compensate for limitations that no longer exist, so the user can prune them and stop paying their cost on every session.

This is the only audit that proposes **removals** rather than additions. Treat the bar accordingly — high specificity, low false-positive rate. A wrong removal silently degrades discipline; a missed removal just wastes a few tokens.

## Inputs

1. `__TRELLIS_PATH__/core-rules/CLAUDE.md` — the parent rules.
2. `__TRELLIS_PATH__/core-rules/presets/*.md` — opt-in rule layers.
3. `__TRELLIS_PATH__/engineering-process.md` — narrative manual.
4. For each registered project (read `registry.md`, exclude `blacklist.md`):
   - `<project>/CLAUDE.md`
   - `<project>/gotchas.md`
5. `__TRELLIS_PATH__/core-rules/VERSION` — current canonical version.
6. The most recent `__TRELLIS_PATH__/CHANGELOG.md` entries — gives you context on what was added or changed recently.

## Process

### 1. Classify every rule

Walk each rules file. For each discrete rule (one line, one bullet, one short paragraph), tag it with one of:

- **load-bearing** — the rule encodes domain knowledge (commit conventions, branch protection, secrets handling, security baselines) that no model upgrade obsoletes. Skip.
- **model-compensating** — the rule exists because some past Claude / Codex version got it wrong without prompting (e.g., "max 7 files per phase", "always re-read before editing", "don't summarise what you did"). Candidate.
- **harness-compensating** — the rule exists because some past hook / tool / CLI version misbehaved. Candidate. Cross-check against the current Claude Code release notes if you can fetch them.
- **stylistic** — the rule encodes the user's voice / aesthetic ("terse responses", "no AI footers", "human voice in commits"). Skip — these are preference, not capability.
- **process** — the rule encodes a workflow contract (Rule of Three, presets, registry, audits). Skip — these are scaffolding, not model behaviour.

### 2. Evidence check (for each candidate)

For every `model-compensating` or `harness-compensating` candidate:

1. Read the surrounding context. Does the rule cite a specific incident, gotcha, or model version?
2. Search `gotchas.md` files across projects for evidence the failure mode still happens. Date the most recent occurrence.
3. Check git blame on the rule line (if reachable from this run) for the introduction date.
4. Estimate "model generation when this was written" from the introduction date — pre-2025 = pre-Claude-4 era; mid-2025 = Claude 4 era; 2026+ = Claude 4.5+ era. This is approximate; use commit dates and Trellis CHANGELOG entries as anchors.

A candidate is a **strong removal proposal** if all of:

- It is model- or harness-compensating, not load-bearing.
- The most recent gotchas evidence is **> 6 months old**, or there is none.
- The rule was written before the current major model generation (or before a Claude Code release that demonstrably fixed the underlying gap).
- Removing it does not strand any project-specific rule that depends on it.

A candidate is a **weak removal proposal** if it meets the first criterion but evidence is inconclusive. Report these separately so the user can decide; do not lump weak with strong.

### 3. Compose the report

Write to `__TRELLIS_PATH__/audits/YYYY-MM-DD-obsolete-rules.md`:

```
# Obsolete-rules audit — <date>

## Summary
- Rules scanned: <N> (parent <N>, presets <N>, projects <N>)
- Candidates classified: <N> model-compensating, <N> harness-compensating
- Strong removal proposals: <N>
- Weak removal proposals: <N>
- Skipped (load-bearing / stylistic / process): <N>

## Strong removal proposals

### <rule excerpt or short title>
- **Location:** `<file>:<line>` (e.g., `core-rules/CLAUDE.md:12`)
- **Classification:** model-compensating | harness-compensating
- **Introduced:** <commit SHA or date> (model generation: <pre-Claude-4 / Claude 4 / Claude 4.5+>)
- **Last evidence in gotchas:** <project / date> or "none"
- **Why it was added:** <one-sentence reconstruction from surrounding context>
- **Why it can go:** <one-sentence rationale tied to current capability>
- **Suggested removal:** <exact diff — what to delete, what to leave>

<repeat per strong proposal>

## Weak removal proposals (decision needed)

<same shape, but include the inconclusive signals — e.g., "evidence from 4 months ago, borderline">

## Skipped (with reason)

<terse list — rule + classification, no further detail>

## What to do
1. Review strong proposals. For each, decide: accept, defer, or reject. Apply accepted diffs.
2. Decide on weak proposals — usually defer to next quarter unless something has changed.
3. Bump `core-rules/VERSION` if any rule was removed.
4. Add a CHANGELOG entry citing this audit.
```

## Boundaries

- **Do not modify any rules file.** This audit only proposes removals; the user is the one who applies them.
- **Do not propose additions** — the gotchas-rollup audit owns that promotion path. This audit is removal-only.
- If a candidate would remove a rule that has a corresponding hook (`code-review-subagent`, `stop-verify`, etc.) still enforcing it, downgrade to "weak" and note the hook coupling. Removing a rule but leaving an enforcement hook is silent drift.
- If you cannot date the introduction of a rule, skip rather than guess — write it under "needs git blame" at the end of the report.

## Sensible failure modes

- If `core-rules/CLAUDE.md` parses cleanly but a project's `CLAUDE.md` does not, note the project and skip; don't abort the audit.
- If a candidate references a specific Claude Code feature flag or hook event that you cannot verify exists today, mark it weak rather than strong — the cost of a wrong strong-recommendation is higher than the cost of a deferred review.

## Cadence

Runs quarterly (Jan 1, Apr 1, Jul 1, Oct 1, at 09:00). Triggered after major model launches as well — coordinate with the user. The first run after a model launch is the highest-yield: most pre-launch workarounds become candidates.

## Loop safety

This task is a Trellis loop and honors `core-rules/loop-safety.md`. Ceilings resolve most-specific-first: per-loop override in this stanza → project-local `.trellis.config.json.loop_safety` → central `trellis.config.json.loop_safety` → built-in fallback constants (100 / 3 / $1000). The loop halts on **any** one ceiling and emits a structured halt report (which ceiling tripped, the last progress marker, and the work done so far); an unattended/cron run surfaces the halt in its run report rather than dying silently.

- `max_iterations`: inherit default (100)
- `no_progress_iterations`: inherit default (3)
- `budget_ceiling_usd`: inherit default (1000)
- Progress signal: **new finding** — a removal proposal (strong or weak) surfaced this iteration that was not present before.
