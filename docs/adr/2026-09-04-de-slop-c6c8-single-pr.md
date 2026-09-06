# Spec 044 de-slop cohorts C6 and C8 ship as one PR

- Status: accepted
- Date: 2026-09-04

## Context

PR #440 (`de-slop/C6C8-hooks-twins`, ~10,000 countable lines across 195 files)
exceeds the 800-line hard PR-size cap in the process gate, which permits an ADR
explaining why splitting harms clarity. This is that ADR.

The change is two cohorts of spec 044's de-slop programme, executed together by one
foreman: C6 covers `core-rules/hooks`, C8 covers the hook "twins" — the paired
Claude and Codex renderings of the same hook, which must stay byte-equivalent in
behaviour or the two harnesses silently diverge.

## Decision

Ship C6 and C8 as a single PR rather than splitting, and keep them together rather
than as two PRs.

1. **C6 and C8 are the same edit applied twice by construction.** A twin pair is
   two files that must change together; landing the hook fix without its twin is
   precisely the drift the twins exist to prevent, and it is invisible to typecheck,
   lint and tests — it surfaces only when a session runs under the other harness.
   Splitting C6 from C8 would land that drift deliberately.

2. **The triage record is the unit of review.** Every hunk traces to an approved
   unit in `specs/044-de-slop` with its finding, decision and rationale. Splitting
   by file count repeats the triage across PRs and gives the reviewer partial views
   of one sweep.

3. **Hooks are the highest-blast-radius surface in the repo.** Every attached
   project executes them on every turn. A sequence of partial hook releases is more
   dangerous than one reviewed sweep, because each intermediate is a distinct
   configuration that no one will run for long enough to find defects in.

## Consequences

- Review is triage-led and twin-aware: for a sampled hook, check both renderings.
- Rollback is the whole cohort pair, which is the correct granularity — reverting
  one twin alone recreates the drift.
- The gate still requires reviewer acknowledgement of the size in the PR
  description, which is where the sampling evidence belongs.
- This ADR covers C6/C8 only. Cohort C7 carries its own.
