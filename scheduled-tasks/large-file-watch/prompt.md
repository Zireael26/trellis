# Large-file watch (Tier 2 — not registered)

> **Status:** Drafted, not scheduled. Register with
> `mcp__scheduled-tasks__create_scheduled_task` when we're ready.
> See `scheduled-tasks/README.md` for the promotion criteria.

## Purpose

Flag files that have grown past a readability threshold. The CLAUDE.md
core rule around context-management caps individual reads at 2000 lines,
but more importantly, files past ~500 lines are a code-smell signal:
likely doing too much, likely resistant to change, likely eating more
Claude context on every edit.

This task is a weekly nudge to refactor, not a blocker.

## Inputs

1. Registry ∖ blacklist.

## Thresholds (tunable per project via `targets.md`)

- `WARNING_LOC = 500` — flag for refactor consideration.
- `CRITICAL_LOC = 1000` — needs a refactor plan; context-compaction risk
  is real.
- `IGNORE_GLOBS` — generated files, lockfiles, vendored code, migrations,
  fixtures, snapshots. Default:
  ```
  *.lock
  package-lock.json
  pnpm-lock.yaml
  yarn.lock
  **/dist/**
  **/build/**
  **/node_modules/**
  **/migrations/**
  **/*.snap
  **/*.generated.*
  ```

## Checks per project

### 1. Walk tracked source files

Only files under git (`git ls-files`), excluding IGNORE_GLOBS. Consider:
`.ts .tsx .js .jsx .py .rs .go .java .kt .rb .php .c .cc .cpp .h .hpp`.

### 2. Count lines

`wc -l` per file. Record path, line count.

### 3. Trend

Compare against last week's audit for the same project. New files over
threshold get flagged separately from existing-and-still-over.

## Output

```
# Large-file watch — <date>

## Summary
- Projects scanned: <N>
- Files over 1000 LOC (critical): <count>
- Files between 500-1000 LOC (warning): <count>
- New over-threshold files this week: <count>

## Critical (>1000 LOC)

| Project | File | LOC | Δ vs. last week |
|---|---|---|---|
| ... | | | |

## Warning (500-1000 LOC)
<same shape>

## New over-threshold this week
<list — these are the refactor nudges>
```

## Why Tier 2

A weekly nudge about file size is useful but easy to ignore. Better to
wait until either:
- We have evidence that big files are causing real pain (failed reads,
  context compaction at bad times, bug density correlates with LOC), or
- We want a nudge that refactor candidates exist so we can pick one up
  during a light week.

## Promotion criteria

Turn this on when:
- Working on any project starts hitting the 2000-line read cap regularly.
- A retro identifies "this file is too big" as a recurring pain point.

## Loop safety

This task is a Trellis loop and honors `core-rules/loop-safety.md`. It
declares and honors three ceilings and **halts on any one**; ceiling
values resolve most-specific-wins: per-loop override (this stanza) →
`.trellis.config.json.loop_safety` → `trellis.config.json.loop_safety` →
built-in fallback constants (100 / 3 / $1000). On a trip it hard-stops
(never auto-continues) and emits a structured halt report — which ceiling
tripped, the last progress marker, work done so far — surfaced in the run
report rather than dying silently.

- `max_iterations`: inherit default (100)
- `no_progress_iterations`: inherit default (3)
- `budget_ceiling_usd`: inherit default (1000)
- Progress signal: **new finding** — a project/file over threshold not
  flagged in last week's audit.
