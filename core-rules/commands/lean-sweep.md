---
description: Audit one project for unused code and tests, then remove verified dead files in small, independently checked slices.
argument-hint: "[project-root]"
disable-model-invocation: true
---

# Lean Sweep: $ARGUMENTS

Run a targeted **read-only audit, then an operator-approved cleanup** in one project. If no root is given, use the current project. Never run the audit in pre-push.

## Steps

### 1. Audit and baseline

- Run `trellis lean-audit --json` in the project, or pass `PROJECT_ROOT` explicitly. If the launcher does not yet expose the verb, invoke the Trellis payload's `scripts/lean-audit.sh` with the same arguments. Audit only trusted checkouts: installed analyzers can load project configuration.
- Show findings, skipped inputs, and analyzer statuses. `unavailable` or `error` means not measured, not clean. Record the baseline checks and inventory of routes, public exports, CLI targets, and migrations before editing.

### 2. Verify and select

- Consider only `HIGH` candidates. Check each path, stem, and exported symbol against imports, runtime registration, package consumers, CI/deploy scripts, docs, and other out-of-band callers. Preserve framework entry points, migrations, and load-bearing tests. Hand test consolidation to `/test-cleanup` and structural/type simplification to `/de-slop` separately.
- Treat scanner findings as leads, not deletion proof. Stop on any ambiguity, missing verification, or unexplained reference. Show the verified list and get operator approval before deleting; stop when verification costs more than the expected gain.

### 3. Delete, verify, and commit one slice at a time

- Limit each **atomic commit to ≤7 files**, one concern per slice. After each slice, compare the inventory and run full project `typecheck`, `lint`, `tests`, and UI smoke checks (record why UI is not applicable for a non-UI project).
- Halt on any failure, inventory drift, or ambiguity. Leave the slice uncommitted, report the evidence, and do not advance. If green, commit only that slice.

### 4. Report receipt

List each commit and its deleted paths, the inventory comparison, exact verification commands and exit codes, and any skipped or unresolved candidates.
