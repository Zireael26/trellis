# 2026-05-19 — Primer freshness loop (SessionStart hook + weekly backstop)

## Context

v0.3.0 shipped the primer system: `/primer`, `/primer-refresh`, `/primer-check` canonical commands, opt-in `.claude/primers/` directory, parent-CLAUDE.md rules that nudge agents to "lean toward loading" primers. Real-world use exposed two gaps:

1. **Updates rely on the user remembering.** No mechanism forces / nudges `/primer-refresh` when entry-point files churn. Primers go stale silently.
2. **Usage relies on the agent deciding.** "Agent-decides" policy means some sessions skip the INDEX entirely, especially short reactive turns.

We invest tokens/time to build primers; both gaps undercut ROI.

## Decision

Two changes, both deterministic (no per-turn LLM cost):

1. **SessionStart hook `inject-primer-index.sh`** — runs once per session on both Claude and Codex. Computes drift per primer via `git rev-list` on entry-point paths since `pinned_to`. Injects compact INDEX-with-drift-flags block (~300 tokens) into context. Buckets: FRESH / WARM / STALE / MISSING_PATHS / UNREACHABLE_PIN / BROKEN.

2. **Parent CLAUDE.md rule hardened.** "Lean toward loading" → "MUST read primer when task names a primer-listed feature/dir". Auto-inject means INDEX is always in context; the rule converts "available" → "used".

3. **Weekly `primer-drift` Tier-1 audit** — backstop for cold projects. Same checks as the hook, fleet-wide, single audit file. Monday 12:15.

Rejected alternatives:

- **post-commit LLM hook to auto-refresh** — burns tokens per commit; unsupervised LLM editing of curated content is the wrong default.
- **PostToolUse dirty-marker file** — state to maintain, fires on aborted edits, no signal advantage over rev-list at session start.
- **Eager-load every primer at session start** — N × 3 KB token waste.

## Consequences

Positive:
- Drift becomes visible on every session for free.
- Usage moves from agent-judgement to enforced rule.
- Both harnesses behave identically; the existing context-log hook layout is the proven pattern we're re-using.
- Cold projects don't slip through — weekly fleet audit catches them.

Negative:
- One new hook per harness to maintain. Mitigated by bats coverage and inclusion in `parent-hook-drift` manifest.
- INDEX-parsing in shell is fragile to format changes. Lock the format (`- [slug](./slug.md) — desc`) via the primer-index template and bats tests; future format changes require a hook bump.

## Status

Accepted. Shipped as v0.3.1.
