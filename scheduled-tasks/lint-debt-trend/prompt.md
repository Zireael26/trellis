# Lint debt trend (Tier 2 — not registered)

> **Status:** Drafted, not scheduled. Register with
> `mcp__scheduled-tasks__create_scheduled_task` when we're ready.
> See `scheduled-tasks/README.md` for the promotion criteria.

## Purpose

Track lint/typecheck warning counts per project over time. Warnings have a
way of silently accumulating — the PostToolUse hooks flag *new* warnings
introduced in changed files, but nothing tracks the total trend. This task
closes that gap.

## Inputs

1. Registry ∖ blacklist.
2. Each project's lint/typecheck configuration (already auto-detected by
   `run-lint.sh` and `run-typecheck.sh`).

## Checks per project

### 1. Run lint/typecheck against the full project (not just changed files)

- TypeScript: `tsc --noEmit` — count TS errors and TS warnings separately.
- JavaScript/TypeScript: `eslint .` — count errors, warnings.
- Python: `ruff check .` — count by severity tier.
- Rust: `cargo clippy --quiet -- -D warnings 2>&1 | tail -50` — parse for
  warnings.
- Go: `go vet ./...` — count issues.

Budget: 3 minutes per project. If the project isn't configured for the
detected toolchain, record "not configured" and skip.

### 2. Compare to trend history

Read prior audits at
`__SE_CORE_PATH__/audits/*-lint-debt-trend.md`
and extract the per-project counts. Compute deltas vs. 1 week ago, 1 month
ago, 3 months ago.

### 3. Highlight regressions

- Counts up >20% week-over-week → **regression**.
- Counts down >20% → **cleanup win** (good, report the win).
- Flat → info only.

## Output

Write to `__SE_CORE_PATH__/audits/YYYY-MM-DD-lint-debt-trend.md`.

Format: one row per project, one column per tool, with deltas in parens.

```
| Project | TS errors | ESLint warnings | Ruff warnings | Trend |
|---|---|---|---|---|
| msme-neev | 0 (→) | 12 (+3 WoW) | — | ⚠️ regression |
| ... | | | | |
```

## Why Tier 2

This is a nice-to-have. The PostToolUse hooks already prevent new
warnings in changed files, so in theory debt can only grow via
existing-file-changes-that-touch-an-already-dirty-line. We should run
Tier 1 for a month, see if we actually have a warning-count problem, and
only then turn this on. Scheduling a task that produces noise without
actionable signal would train the pipeline to be ignored.

## Promotion criteria

Turn this on when either:
- Any Tier 1 task (especially `cross-project-process-audit`) starts
  reporting warning creep as a recurring finding, or
- A project's PR-review volume starts catching lint warnings as a
  not-trivial fraction of comments, or
- 6 months have passed and we just want to see the trend.
