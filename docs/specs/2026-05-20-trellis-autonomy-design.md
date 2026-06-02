# Trellis autonomy — responsibility-slider design

**Date:** 2026-05-20
**Status:** Draft (awaiting user review)
**Authors:** __MAINTAINER_NAME__ (+ Claude)
**Target version:** core-rules/VERSION 0.4.5

---

## Problem

Trellis is interactive by design: plan-approval, ambiguity flagging, pre-implementation interview, per-phase approval, brainstorming, spec-kit phase gates, destructive-action confirmation, PR-creation confirmation. Each gate exists to catch a real failure mode.

Some users want the discipline; some find the input cost prohibitive — especially on chore-grade work where the agent could plausibly decide alone. New users in particular drop off when the harness feels heavier than the task warrants.

Existing escape hatches are coarse: the `experimental-loose` preset relaxes structural rules (direct commits to main, no spec-kit) — useful for prototypes but the wrong tool for a senior operator running a chore session on a compliance-grade codebase.

## Goal

Introduce a **responsibility slider** between user and agent. Higher autonomy ⇒ agent makes more decisions on the user's behalf at gate-hits. Quality and gates do not change.

**Critical invariant:** every gate that fires at L3 still fires at L5. The level only determines *who answers it*.

## Non-goals

- **Removing or weakening gates.** Higher autonomy ≠ lower quality. Code review subagent, security gate, process gate all run regardless.
- **Replacing the `experimental-loose` preset.** That preset relaxes structural rules (commits to main, spec-kit pipeline). Autonomy is orthogonal and operates within whichever preset is active.
- **Bypassing hard hooks.** Pre-push, security-gate, secrets scan, post-edit hooks are infra, not heuristics. They fire at every level.
- **Building a UI for Trellis configuration.** Deferred — see "Deferred follow-ups".

---

## Level matrix

Five levels, default **L3 (Standard)** — exact current Trellis behavior. No silent regression for existing users.

| Level | Name | Pre-action consultation | Post-action surfacing |
|-------|------|-------------------------|------------------------|
| **L1** | **Pedagogical** | Ask before every non-trivial action. Explain reasoning, alternatives, tradeoffs. Wait. | Conversation captures decisions. No separate log. |
| **L2** | **Cautious** | Ask before non-trivial actions. Embed agent's recommendation with one-line rationale. Wait for yes/no. | Conversation captures decisions. |
| **L3** | **Standard (default, current)** | Plan-approval for 3+ step or architectural changes. Flag ambiguity, surface options, wait. Brainstorm one-question-at-a-time. Per-phase approval on multi-file refactors. | Conversation captures decisions. |
| **L4** | **Initiative** | Batches related interview questions. Picks-and-documents on routine ambiguity. Single plan approval at start, no per-phase pause. Architectural decisions surface **inline mid-turn** (don't batch). | Decision-log surfaced at end-of-turn. Architectural decisions also flagged inline. |
| **L5** | **Autonomous** | Decide silently. No plan-approval pause. No per-phase pause. Brainstorm questions answered by agent with documented reasoning. **Exception: architectural decisions surface inline** (reversibility cliff). | Full decision-log in end-of-turn message AND persisted to `context-log.md`. |

### What flexes vs what stays

**Flex with level (slider applies):**
- Plan-approval gate (when to wait vs proceed)
- Pre-implementation interview depth and batching
- Multi-file refactor phase approval
- Ambiguity resolution (ask vs pick + document)
- Codebase pattern-conflict resolution
- Brainstorming question batching
- Spec-Kit phase handoff (clarify → spec → plan → tasks → analyze)
- PR creation (L5 may auto-open PR after gates pass; L≤4 confirms)

**Bright-line guardrails (always-on, every level including L5):**

1. **Hard hooks** — pre-push-to-main, security-gate (semgrep/gitleaks/osv-scanner), process-gate, post-edit checks. Infra, not heuristic.
2. **Destructive ops** — `rm -rf`, force-push, dropping tables, deleting branches with unmerged work. Always confirm.
3. **External messages to others** — Slack, email, PR comments on existing PRs. (PR *creation* itself flexes; that is one's own work.) Always confirm.
4. **Secrets** — never disclose, never commit. No level overrides.
5. **Definition-of-Done receipts** — verification command + exit code in every "done" claim. Receipts are the audit; cannot skip.
6. **Code-review subagent on edit-heavy turns** — always runs. At L4/L5 its prompt is expanded: verify decision-log completeness vs diff.

### L1 vs L2 vs L3 distinctness

- **L1 Pedagogical** — explains *why* before asking. Lists alternatives considered. Optimized for learning / pairing / very high-stakes work.
- **L2 Cautious** — embeds one-line recommendation in the ask. No tutorial framing.
- **L3 Standard** — current Trellis behavior: only asks for non-trivial / 3+ step / architectural. Trivial decisions silent.

### Reversibility carve-out

Even at L5, the following surface **inline mid-turn**, not batched to end-of-turn:

- Architectural decisions: new dependency, new top-level module, new data store, auth flow change, public API shape change.
- Pattern-conflict resolution where the chosen pattern propagates beyond the current file.

Rationale: reversibility cliff. Variable name = cheap to undo; architecture = not. User must see these as they happen, even at full autonomy.

---

## Decision log

### Truth source

A new **separate file** `<canonical-root>/decisions-log.md` (canonical-rooted via `git --git-common-dir`, survives worktree boundaries).

**Why a separate file, not `context-log.md`:** `core-rules/hooks/save-context-log.sh` *overwrites* `context-log.md` wholesale on every `PreCompact` / `Stop`. Any decision entries written by the agent during a turn would be wiped on next compact. A separate file decouples agent-authored decisions from hook-managed session-state.

Format:

```markdown
# Decision log

- 2026-05-20T14:23:01Z [L5] [interpretation] Read "fix the auth bug" as token-expiry off-by-one in `auth/middleware.ts:42`. Reasoning: only failing test, recent gotchas entry 2026-05-15 names it. Alternatives considered: refresh-token rotation (no failing test), session-store schema (out of scope).
- 2026-05-20T14:25:14Z [L5] [pattern] Picked `useQuery` over `useSWR` for the new fetch hook. Reasoning: 12 callers of `useQuery` in repo vs 3 of `useSWR`; `useSWR` flagged for cleanup in 2026-04 ADR.
- 2026-05-20T14:31:02Z [L5] [architectural] Added new dependency `zod` for runtime schema validation. Reasoning: replaces 80-line ad-hoc validator; matches pattern in 4 other repos. SURFACED INLINE during turn.
- 2026-05-20T14:33:50Z [L4] [scope] Deferred the unrelated stale comment in `legacy/parser.ts`. Reasoning: out of scope; spawned `mcp__ccd_session__spawn_task` for follow-up.
```

Append-only by agent during L4/L5 turns. Newest entries at bottom. `session-context.sh` injects the last ~10 entries when active level ≥ 4 so the next session sees recent decisions.

### Decision kinds

- `interpretation` — resolved an ambiguity in the user's request.
- `pattern` — picked one of two contradictory codebase patterns.
- `scope` — decided to defer or include something at the edge of scope.
- `architectural` — load-bearing, reversibility cliff. Surfaces inline at L4/L5.

### Schema (each entry, one line)

```
- {ISO-8601 timestamp} [{kind}] {what was decided}. Reasoning: {why}. Alternatives considered: {what else}.
```

If the entry is `architectural`, append ` SURFACED INLINE` so the audit knows it was not silent.

### Rendering targets (read-only from truth source)

- **End-of-turn assistant message** at L4/L5: renders a "## Decisions made (L<n>)" section pulling that turn's entries from `context-log.md`.
- **PR description** when `gh pr create` runs: renders the same section under "Decisions made".
- **Code-review subagent prompt** at L4/L5: receives the decisions section plus the diff, instructed to flag *implicit* decisions present in the diff but missing from the log. Treats omission as a finding.

### Persistence hook

Existing `save-context-log` hook runs on PreCompact (Claude) / Stop (Codex). Extend it to recognize and preserve the `## Decisions (L4/L5)` section. New entries during a turn are written to context-log.md immediately by the agent (so a session crash mid-turn still preserves them).

---

## State persistence for autonomy level

### Resolution algorithm

The active level is computed in two phases — **pick** then **clamp**.

**Pick phase** (later steps override earlier):

1. Hard default = **L3**.
2. If `trellis.config.json.autonomy_default` is set ⇒ use it (fleet default for this clone, 1–5).
3. If active preset declares `autonomy_default` AND no project-local override exists ⇒ use preset default (e.g., `experimental-loose` default = 4).
4. If project-local `<project>/.trellis.config.json.autonomy` is set ⇒ use it (explicit per-project value beats preset default).
5. If session `/autonomy N` slash command issued ⇒ use N.

**Clamp phase:**

6. If any active preset declares `autonomy_ceiling`, clamp the picked value to ≤ ceiling. If clamped, agent surfaces one-line warning:
   > Requested autonomy L<requested>, clamped to L<ceiling> (preset `<preset-name>`).

If multiple presets are active and declare conflicting ceilings, the **lowest ceiling wins** (most restrictive). Reason: presets compose additively — `compliance-strict` + anything cannot dilute compliance discipline.

### Where current level lives within a session

A new **separate file** `<canonical-root>/.claude/session-autonomy` (gitignored). Single line: just the integer (`4`).

**Why a separate file, not `context-log.md`:** same reason as decision-log — `save-context-log.sh` overwrites `context-log.md` wholesale; any autonomy-level state stored there would be lost on PreCompact.

- `/autonomy N` writes the integer to this file.
- `session-context.sh` reads this file at session start and injects `Autonomy level: L<n> (<name>)` into the session context block.
- Survives `/compact` (file is outside hook-managed paths).
- Survives worktree boundaries (canonical-rooted via `git --git-common-dir`).
- Gitignored so it does not pollute project repos with per-developer state.

If the file is missing, agent resolves level from config + presets per the algorithm above.

### Code change surface for `/autonomy`

`core-rules/commands/autonomy.md` defines the slash command. On `/autonomy N`:

1. Validate N ∈ {1,2,3,4,5}.
2. Resolve ceiling from active presets.
3. Clamp if needed; warn if clamped.
4. Update `context-log.md` frontmatter.
5. Acknowledge to user with one line: `Autonomy set to L<n> (<name>). <one-line summary of behavior change>.`

---

## Preset interaction

### Existing presets

- **`compliance-strict`** — gains `autonomy_ceiling: 2`. Reason: audit-grade discipline requires human-in-the-loop on every non-trivial decision. Two-human sign-off cannot exist if one of the two is the agent acting autonomously.
- **`experimental-loose`** — gains `autonomy_ceiling: 5` and `autonomy_default: 4`. Reason: throwaway work, decisions are cheap to undo, prompting is the bottleneck.

### Preset frontmatter

Add to preset format (currently markdown with prose):

```markdown
---
autonomy_ceiling: 2
autonomy_default: 3
---
```

Optional. Absent ⇒ no constraint (`ceiling = 5`, `default` follows trellis.config.json or hard default).

`scripts/rollout-presets.sh` already syncs preset assets; extend to read the frontmatter and surface ceiling/default in its dry-run output.

### Audit

New scheduled audit `autonomy-drift`:

- Flag projects where session overrides repeatedly exceed config default (signal: raise config?).
- Flag projects at L4/L5 with zero decision-log entries over >N turns (signal: agent skipping the log).
- Flag projects under `compliance-strict` where session attempted to exceed ceiling >3 times (signal: friction with preset).

Runs weekly. Markdown report under `audits/YYYY-MM-DD-autonomy-drift.md`.

---

## File layout — what to add or change

### New files

- `core-rules/autonomy.md` — canonical level matrix, decision-log schema, guardrail list. Imported by `core-rules/CLAUDE.md` via @-import. Target: <5 KB.
- `core-rules/commands/autonomy.md` — slash command spec (validate → resolve ceiling → clamp → write context-log.md frontmatter → acknowledge).
- `scripts/show-config.sh` — pretty-prints resolved autonomy level (config + override + ceiling), active presets, approved MCPs. Discoverability win without UI cost.
- `docs/adr/2026-05-20-autonomy-slider.md` — captures the responsibility-slider decision (why levels, why ceiling, why context-log.md as truth source).
- `docs/specs/2026-05-20-trellis-autonomy-design.md` — this spec.

### Modified files

- `core-rules/CLAUDE.md` — add **Autonomy** section that @-imports `autonomy.md`. Update **Planning**, **Code quality**, **Communication** sections to reference level-aware behavior (one-liner cross-references, not duplication).
- `core-rules/VERSION` — bump 0.3.0 → 0.4.5 (additive feature).
- `CHANGELOG.md` — add 0.4.5 entry.
- `trellis.config.json` schema (`scripts/lib/trellis.config.schema.json`) — add optional `autonomy_default` field (integer 1–5).
- `trellis.config.json.example` template — add commented-out `autonomy_default: 3` example.
- `core-rules/presets/compliance-strict.md` — add autonomy frontmatter (ceiling 2).
- `core-rules/presets/experimental-loose.md` — add autonomy frontmatter (ceiling 5, default 4).
- `core-rules/presets/README.md` — document `autonomy_ceiling`, `autonomy_default` frontmatter fields.
- `core-rules/skills/process-gate/SKILL.md` — code-review subagent prompt expansion: at L4/L5 also verify decision-log vs diff.
- `core-rules/hooks/save-context-log.sh` (or equivalent) — recognize and preserve `## Decisions (L4/L5)` section + `autonomy_level:` frontmatter.
- `core-rules/hooks/session-context.sh` (or equivalent) — inject autonomy level into the session-start context block (it already injects context-log.md; this is one extra line).
- `scripts/rollout-presets.sh` — read preset frontmatter, show ceiling/default in `--dry-run`.
- `scheduled-tasks/` — add `autonomy-drift.md` audit prompt.
- `registry.md` — no schema change; existing projects opt in via per-project `.trellis.config.json`.

---

## Rollout

### Phase 1 — Core (this PR)

1. `core-rules/autonomy.md`, slash command, schema extension, version bump, CHANGELOG, ADR, spec.
2. Update CLAUDE.md with Autonomy section + cross-references.
3. Preset frontmatter on `compliance-strict` and `experimental-loose`.
4. `scripts/show-config.sh`.
5. Tests: schema validation cases (invalid N, valid N, missing default), clamp behavior fixture, rendering of decision-log section.

### Phase 2 — Hook integration (follow-up PR or same, depending on size)

1. Extend `save-context-log` to preserve frontmatter + decisions section.
2. Extend `session-context` to inject level.
3. Extend `process-gate` SKILL.md for L4/L5 code-review prompt.

### Phase 3 — Audit (follow-up PR)

1. `autonomy-drift` scheduled audit prompt.
2. `scripts/rollout-presets.sh` dry-run output update.
3. Conformance check entry for the new audit.

### Phase 4 — Documentation

1. Update `engineering-process.md` with §14.X on autonomy.
2. Update `README.md` Quick start to mention `/autonomy N`.

Phases can be bundled into one PR if total size stays reasonable; otherwise split at Phase 2 / Phase 3 boundaries.

### Versioning

Single semver bump: **0.3.0 → 0.4.5**. Additive feature, no breaking change (default L3 = current behavior).

### Backwards compatibility

- Projects without `autonomy_default` in config ⇒ L3.
- Projects without preset frontmatter ⇒ no ceiling.
- Sessions without `/autonomy` override ⇒ config value (or L3).
- No `context-log.md` change required for L1/L2/L3 sessions (decision-log section only appears at L4/L5).

---

## Open questions

These are spec-author judgment calls — implementation may surface a counterargument worth raising.

1. **Should `/autonomy N` persist past session end?** Currently spec'd as session-only. Alternative: persist in `.claude/local-autonomy` (gitignored) so a developer's preference survives across sessions on one machine. Defer to user.
2. **Decision-log retention.** `context-log.md` is overwritten on each PreCompact write; the section grows unbounded across sessions. Need a cap (e.g., last 100 entries) or a separate archive (`context-log.decisions.md`). Tentative: cap at 100 in-file, archive overflow.
3. **L4 vs L5 differentiation in practice.** L4 has "single plan approval at start"; L5 skips it. If most users find L4 still too talky, L4 collapses into L5 and we ship 4 levels with default L3. Watch usage; revisit at v0.5.

---

## Deferred follow-ups

- **Trellis UI / TUI** — Discoverability of config fields, level matrix visualization, decision-log browser, audit report viewer. Cheap alternative shipped now: `scripts/show-config.sh`. Revisit as separate ADR (`trellis-tui` or `trellis-console`) only after autonomy lands and real usage surfaces specific pain.
- **Per-task autonomy override in user message** (e.g., inline `/autonomy 4 fix the auth bug` syntax) — possible but adds parsing surface and magic. Slash command at start of session covers the use case; reconsider if requested.

---

## Decision rationale (key choices, summarized)

| Choice | Why |
|--------|-----|
| 5 levels, default L3 | User asked for 5 with default-middle. L3 = current behavior ⇒ no regression. |
| Hybrid trigger (config + slash) | Per-project config aligns with existing `presets` model; slash gives session override without re-edit. |
| `context-log.md` as decision-log truth source | Already canonical-rooted, already session-injected, survives compact. PR description + end-of-turn message render from it ⇒ no drift. |
| Architectural decisions surface inline at L4/L5 | Reversibility cliff: silent architecture decisions are too costly to undo. Carve-out keeps trust intact at high autonomy. |
| Code-review subagent verifies log completeness | Defense against incomplete logs. Without this, L5 trust is unbounded. |
| Preset ceiling clamps slash override | `compliance-strict` projects need a hard floor; slash command alone cannot satisfy compliance discipline. |
| No UI in this rollout | Trellis is file-driven; UI is scope creep. `show-config.sh` covers the realistic discoverability need. |
| Bright-line list locked (6 items) | Receipts, hooks, secrets, destructive ops, external messages, code-review — each protects against a failure mode where agent autonomy is the wrong abstraction. |
