# Retire the flat PR line-count cap in `process-gate`

- Status: accepted
- Date: 2026-11-17

## Context

`core-rules/skills/process-gate/scripts/check-pr.sh` (backed by `scripts/lib/pr-size.py`) enforced a flat countable-diff line budget (`PROCESS_GATE_PR_SIZE_LIMIT=600` warn, `PROCESS_GATE_PR_SIZE_HARD=1200` / `800` fail unless the range added a new Markdown file under `docs/adr/`).

Over a year of self-hosted and fleet operation, two structural problems emerged:

1. **ADR noise displaced architectural signal:** 39 of the 88 files in `docs/adr/` (`*-pr-size.md`) were boilerplate size-waiver notes authored solely to satisfy `check-pr.sh` on cohesive releases, harness cutovers, and mechanical refactors where splitting would leave intermediate commits broken.
2. **Line count is a weak proxy for change risk:** Risk-tiered verification (`mandatory_pipeline` spec gating on substantive feature branches, deterministic `stop-verify` / `process-gate` test & security suites, and cross-family `code-review-subagent` passes) catches defects directly, whereas maintaining a 467-line custom Git blob/attribute line counter (`pr-size.py`) and 1,100 lines of Bats permutations slowed every push without catching real bugs.

## Decision

Remove the PR line-count cap (`PROCESS_GATE_PR_SIZE_LIMIT`, `PROCESS_GATE_PR_SIZE_HARD`, and `scripts/lib/pr-size.py`) from `process-gate` Gate 1 (`check-pr.sh`).

- Gate 1 continues to enforce branch naming (`<type>/<kebab-slug>` / `pi-agent-*`) and Conventional Commit subject hygiene across the gated range.
- Substantive scope governance stays with `.trellis.json#mandatory_pipeline` (`spec-gate`), per-phase edit discipline in `AGENTS.md`, and risk-tiered automated + cross-family review.
- `docs/adr/` returns strictly to genuine architectural decisions.

## Consequences

- Cohesive refactors, dead-code purges, and release integrations no longer require waiver ADRs.
- `check-pr.sh` drops its `pr-size.py` subprocess batch pass, making Gate 1 near-instant.
- Existing `PROCESS_GATE_PR_SIZE_*` entries in project `local.config.sh` files remain harmless ignored data keys so unmigrated base configs never fail closed.
