# 2026-05-20 — Autonomy slider (L1–L5, default L3)

## Status

Accepted.

## Context

New users report Trellis's interactive surface as the primary friction barrier. Trellis is intentionally interactive — plan-approval, ambiguity flagging, pre-implementation interview, phase-by-phase approval, brainstorming, spec-kit phase gates, destructive-action confirmation, PR-creation confirmation — each gate exists to catch a real failure mode. But experienced operators on chore-grade work pay the same input cost as a novice on a high-stakes refactor.

Existing escape hatches are coarse. `experimental-loose` preset relaxes structural rules (commits to main, no spec-kit) — wrong tool for a senior operator running chores on a compliance-grade codebase. `compliance-strict` adds discipline but cannot dial it the other way.

## Decision

Ship a **responsibility-slider** model: L1–L5 levels, default L3 (= current behavior, no regression). The level controls **who answers** when a gate fires (user vs. agent). All gates and quality controls remain at every level.

- L1 Pedagogical — agent asks + explains reasoning.
- L2 Cautious — agent asks with embedded recommendation.
- L3 Standard — current Trellis behavior.
- L4 Initiative — agent decides routine ambiguity, single plan-approval, architectural decisions still surface inline.
- L5 Autonomous — agent decides silently; architectural decisions still surface inline.

Bright-line guardrails (always-on): hard hooks, destructive ops, external messages, secrets, DoD receipts, code-review subagent.

State storage:
- Resolved value lives in `<canonical-root>/.claude/session-autonomy` (gitignored single-integer file).
- Decision log lives in `<canonical-root>/decisions-log.md` (separate file, append-only).
- Both files chosen to avoid the `save-context-log.sh` overwrite cycle.

Config layering:
- Fleet default: `trellis.config.json.autonomy_default`.
- Project override: `<project>/.trellis.config.json.autonomy`.
- Preset clamps: `autonomy_ceiling` in preset frontmatter (lowest ceiling wins).
- Session override: `/autonomy N` slash command writes the integer file.

## Consequences

- New users with a per-project `autonomy: 4` default ship faster on familiar territory.
- Compliance-strict projects get a hard floor via `autonomy_ceiling: 2` — `/autonomy 5` cannot exceed.
- Code-review subagent gains a new responsibility at L4/L5: verify decision-log completeness vs diff. Failure mode (incomplete log) is bounded.
- Architectural decisions never go silent; the reversibility cliff is honored.
- New audit `autonomy-drift` watches for: chronic override-vs-default mismatch (config probably needs raising), zero-decisions-at-L4/L5 sessions (suspicious silence), repeated clamp events (friction with preset).
- Default L3 = current behavior ⇒ no silent regression for existing projects.

## Alternatives considered

- **Binary flag (autonomous=on/off).** Rejected. Too coarse — some gates protect against catastrophe (destructive ops), others just slow ergonomic work (plan-approval for a chore). Lumping forces all-paranoid or all-cavalier.
- **Preset-only (autonomy-cautious / autonomy-standard / autonomy-initiative).** Rejected. Preset is project-scoped; no session override. The friction case is often "this *task* is fine to dial up", not "this *project* is fine to dial up".
- **Skill-driven (`autonomy` skill auto-invoked).** Rejected. Skills are task-focused; autonomy is cross-cutting and should not depend on agent's skill-discovery loop.
- **State stored inside `context-log.md`.** Rejected. `save-context-log.sh` overwrites the file on every `PreCompact`; any decision-log entries written during a turn would be wiped.
- **UI / TUI for Trellis configuration.** Deferred. Trellis is file-driven; UI is a separate concern. Cheap discoverability win: `scripts/show-config.sh`.

## References

- Spec: `docs/specs/2026-05-20-trellis-autonomy-design.md`.
- Plan: `docs/plans/2026-05-20-trellis-autonomy.md`.
- Related: `core-rules/presets/README.md` (preset model).
