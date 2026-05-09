# Gotchas rollup (monthly)

You are aggregating per-project `gotchas.md` entries across the user's active personal projects to detect patterns. The goal is to close the Rule-of-Three loop: if the same lesson shows up in **3+ projects**, it should graduate from per-project gotcha to a parent-layer rule.

## Inputs

1. Read `__SE_CORE_PATH__/registry.md`.
2. Read `__SE_CORE_PATH__/blacklist.md`.
3. Target set = `registry \ blacklist`.
4. Also read `__SE_CORE_PATH__/core-rules/deferred.md` — this is the promotion queue. Entries here are waiting for more data points before graduation.

## Process

### 1. Collect
For each target project:
- Read `<project>/gotchas.md` if present.
- Parse entries. Expected format is Markdown headings + bullets, but be tolerant of free-form.
- For each entry, extract: date added, one-line summary, category (if tagged), project source.

### 2. Cluster
Group entries across projects by semantic similarity. Do not require exact string match — the user writes in their own voice and the same lesson might read differently in two projects.

Reasonable clustering signals:
- Same tool/technology mentioned (e.g., "TypeScript strict mode").
- Same failure mode (e.g., "tests passed locally, failed in CI").
- Same anti-pattern (e.g., "returning `null` vs. throwing").

### 3. Rank
For each cluster, count distinct-project occurrences. Sort descending.

### 4. Promote / queue / watch

| Project count | Action |
|---|---|
| ≥3 | **Promote candidate.** Draft a proposed rule for `core-rules/CLAUDE.md` addition. |
| 2 | **Queue for deferred.md.** If not already there, propose adding it. If already there, confirm evidence. |
| 1 | **Watch.** Note it but take no action. |

### 5. Check deferred.md graduation
For each entry currently in `deferred.md`:
- Does it now have evidence in ≥3 projects? → Recommend graduation to `core-rules/CLAUDE.md`.
- Has its last-data-point date aged beyond 6 months? → Recommend removing from `deferred.md` with reason "stale".

## Output

Write to `__SE_CORE_PATH__/audits/YYYY-MM-DD-gotchas-rollup.md` (monthly):

```
# Gotchas rollup — <date>

## Summary
- Projects scanned: <N>
- Gotchas collected: <total>
- Clusters formed: <N>
- Promote candidates (n≥3): <count>
- deferred.md candidates (n=2): <count>
- Watch items (n=1): <count>

## Promote candidates (n≥3) — draft rules

### <cluster title>
- **Evidence:** <project1> (<date>), <project2> (<date>), <project3> (<date>)
- **Proposed rule (for core-rules/CLAUDE.md):**
  > <draft rule text, one or two sentences>
- **Why:** <the why, to help the user judge edge cases later>

<repeat per promote candidate>

## deferred.md updates

### Additions (n=2, not yet in deferred.md)
<list>

### Confirmations (n=2, already in deferred.md — evidence added)
<list>

### Graduations (now n≥3, recommend moving to CLAUDE.md)
<list>

### Stale removals (last data point >6 months ago)
<list>

## Watch items (n=1)
<just a list — no action needed yet>

## What to do
1. Review promote candidates. Approve or revise the drafted rule text.
2. Apply approved rules to `core-rules/CLAUDE.md`.
3. Update `deferred.md` per the recommendations above.
4. Consider whether any cluster represents a tooling gap — is there a hook, lint rule, or automation that would have caught this?
```

## Boundaries

- **Do not modify any project's `gotchas.md`.** Read-only across all project files.
- **Do not modify `CLAUDE.md` or `deferred.md`** yourself. The user approves rule promotions explicitly — this report's job is to surface them.
- If a project has no `gotchas.md`, note it but don't flag as an error.
- If `deferred.md` doesn't exist yet, skip step 5 and note it in the report.

## Sensible failure modes

- If `registry.md` is missing, stop with a clear error.
- If a project's `gotchas.md` is malformed enough to be unparseable, note it and skip — do not abort the rollup.
