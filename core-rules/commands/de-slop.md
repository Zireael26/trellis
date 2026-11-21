---
description: Audit and remove type/mock/fallback slop and single-use abstractions in one subsystem while preserving behavior.
argument-hint: "[subsystem-or-path] [--install-profile]"
disable-model-invocation: true
---

# De-Slop: $ARGUMENTS

Run a targeted **anti-slop audit, boundary cleanup, and structural simplification pass** on one subsystem or path while preserving existing behavior. If no path is given, scope to the current subsystem.

## Steps

### 1. Profile & baseline audit

- Check `.trellis.json` `gate_profiles.anti_slop.posture`. If `--install-profile` is passed (or the native language profile is absent and the operator approves), follow the `anti-slop` skill (`profiles/<lang>/`) to merge the language profile (`oxlint` for TypeScript, `ruff` + `mypy` for Python) without clobbering existing rules, and start posture at `"advisory"`.
- Run `.trellis/runtime/core-rules/skills/anti-slop/scripts/audit-slop.sh --json` (or `core-rules/skills/anti-slop/scripts/audit-slop.sh --json` in the Trellis source repo) on the target subtree and `trellis lean-audit --json` to record baseline LOC and slop violations before editing.

### 2. Evidence & boundary de-slop

- Clear reported findings in owned source without adding lint or type suppressions.
- Parse and validate untrusted data at I/O boundaries instead of using `as` casts, `any`, `ANN401`, or runtime `typeof` narrowing.
- Replace internal module mocks with explicit dependency seams (injected interfaces or parameters).
- Make fallbacks explicit and distinguishable from measured success (no silent empty/default returns masquerading as valid results).

### 3. Simplification & anti-abstraction pass

- Inline single-use wrappers, helpers, and factories — three similar lines beat a premature factory.
- Collapse pass-through indirection and thin re-export layers that add no boundary or invariant.
- Remove dead optional parameters, unused props, and speculative configuration branches.
- Keep each atomic slice to `<= 7` files with net-neutral or net-negative LOC.

### 4. Verify & receipt

- Run full project `typecheck`, `lint`, `tests`, and `.trellis/runtime/core-rules/skills/process-gate/scripts/check-slop.sh` (or `core-rules/skills/process-gate/scripts/check-slop.sh` in the Trellis source repo) on the diff. Halt on any failure or regression and leave the slice uncommitted.
- Emit a concise receipt listing:
  - **Files:** changed paths (`<= 7` per slice)
  - **Net LOC delta:** `+<added> / -<deleted>` (net delta)
  - **Slop findings:** `<before> -> <after>`
  - **Verification:** exact commands run and exit codes
