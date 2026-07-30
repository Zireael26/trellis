# Preserve Workflow stage identity and fail required work closed

Date: 2026-07-28
Status: Accepted
Spec: `specs/024-workflow-stage-integrity/`

## Context

Workflow runtime failure semantics are intentionally non-throwing at orchestration boundaries: a failed `agent()` may resolve to `null`, `parallel()` retains a null slot, and `pipeline()` nulls one item while other chains continue. Several shipped recipes used result-level filtering or continued with partially populated arrays. Required work could therefore disappear while the run returned a smaller, apparently successful result.

Fix spans parity test harness, canonical recipe template, eight representative recipes, private fleet workflow, authoring documentation, focused regressions, and release surfaces. Mechanical repetition is required because Workflow scripts execute as standalone source with injected globals and cannot import one shared helper module.

## Decision

1. Every dispatched identity receives a settled `{id, ok, value, error}` receipt.
2. Null and thrown results are failed receipts; schema-level negative verdicts remain successful receipts.
3. `requireStage` validates exact receipt cardinality and identity, emits one structured `workflow_stage_gate`, and throws when required success is below declared threshold.
4. Optional provider legs may declare `minSuccess: 0`, but still preserve every expected failed receipt. Required Claude fallbacks remain strict.
5. Test stub mirrors production null-settling, pipeline skip, and stage-argument behavior.
6. Recipes keep helpers inline and identical because shared imports are not part of engine contract.

## Review scope rationale

Change exceeds normal 800-line review cap because failure contract must land atomically across authoring template, parity stub, focused inversion tests, strict recipes, provider-aware recipes, private fleet recipe, and public documentation. Splitting tests/stub from recipes would temporarily certify behavior production recipes do not enforce. Splitting helper adoption by recipe would leave canonical examples with contradictory success semantics. Most added lines are intentionally repeated, engine-compatible helper code and focused fixtures rather than new product breadth.

Review remains bounded by one invariant: no required Workflow identity may disappear as null. Independent review plus focused per-recipe tests cover each degradation shape. No engine, router, service, installer, or live-session behavior changes.

## Alternatives considered

**Change Workflow engine globally.** Rejected. Engine null isolation is useful for independent items and is outside Trellis recipe source; required versus optional semantics belong to each recipe.

**Use `.filter(Boolean)` plus count checks.** Rejected. Filtering destroys failed identity and cannot produce truthful per-unit receipts.

**Return `{ok:false}` without throwing.** Rejected. Workflow records ordinary JavaScript returns as completed; required-stage failure must throw.

**Create one shared helper module.** Rejected. Published recipes are standalone scripts executed with injected globals; imports would widen runtime/package contract.

## Consequences

- Required stage loss becomes explicit failed run with stable IDs and counts.
- Optional provider degradation stays visible without failing otherwise valid work.
- Recipe source grows through repeated local helpers, traded for engine compatibility and reviewable identical semantics.
- Public mirror publication must rerun from rebased `main`; configured mirror currently contains concurrent GPTX work not present on this independent branch.
