# Autonomy

The autonomy slider controls **who answers Trellis's interactive gates** — user or agent — at each gate-hit. All gates and quality controls fire at every level; level only determines *who decides*. Default L3 = current Trellis behavior.

## Level matrix

| Level | Name | Pre-action consultation | Post-action surfacing |
|-------|------|-------------------------|------------------------|
| **L1** | Pedagogical | Ask before every non-trivial action. Explain reasoning, alternatives, tradeoffs. Wait. | Conversation captures decisions. |
| **L2** | Cautious | Ask before non-trivial. Embed agent's recommendation + one-line rationale. Wait yes/no. | Conversation captures decisions. |
| **L3** | Standard (default) | Plan-approval for 3+ step / architectural. Flag ambiguity, wait. One-q-at-a-time brainstorm. Per-phase approval on multi-file refactors. | Conversation captures decisions. |
| **L4** | Initiative | Batches related interview questions. Picks-and-documents on routine ambiguity. Single plan-approval at start, no per-phase pause. **Architectural decisions surface inline mid-turn.** | Decision-log written to `decisions-log.md` and rendered at end-of-turn. |
| **L5** | Autonomous | Decides silently. No plan-approval pause. No per-phase pause. Answers brainstorm questions with documented reasoning. **Architectural decisions surface inline mid-turn.** | Full decision-log written to `decisions-log.md` and rendered at end-of-turn + in PR description. |

## Bright-line guardrails (always-on at every level, including L5)

1. **Hard hooks** — pre-push-to-main, security-gate, process-gate, post-edit checks. Infra, not heuristic.
2. **Destructive ops** — `rm -rf`, force-push, dropping tables, deleting branches with unmerged work. Always confirm.
3. **External messages to others** — Slack, email, PR comments on existing PRs. (PR creation itself flexes; see below.) Always confirm.
4. **Secrets** — never disclose, never commit. No overrides.
5. **Definition-of-Done receipts** — verification command + exit code in every "done" claim. Receipts are the audit; cannot skip.
6. **Code-review + ui-verify on the turns that warrant them** — always run. Code-review fires on every edit-heavy turn (≥3 files or ≥200 lines); ui-verify fires on every diff that touches UI files. Neither is skipped at any level. At L4/L5 the code-review prompt is expanded to verify decision-log completeness vs diff. *(Level-axis guarantee; turn-level-enforced on Claude Code + Codex — see engineering-process.md §5.5/§7.)*

## What flexes with the slider

- Plan-approval gate (when to wait vs proceed).
- Pre-implementation interview depth + question batching.
- Multi-file refactor phase approval.
- Ambiguity resolution (ask vs pick-and-document).
- Codebase pattern-conflict resolution.
- Brainstorming question batching.
- Spec-Kit phase handoff (clarify → spec → plan → tasks → analyze) — at L5 agent answers clarify questions itself with documented reasoning.
- Mandatory-pipeline intake interview (when `mandatory_pipeline` is enabled, spec 006). The pre-push *gate* is deterministic and fires the same at every level — it is **not** a bright-line guardrail, but the slider does not switch it off. What flexes is *who answers* the feature-intake: at **L1–L3** `clarify` interviews the user and `clarify.md` (or a `.claude/spec-waiver`) satisfies the gate; at **L4/L5** the agent self-answers and a `decisions-log.md` entry naming the branch satisfies it. See `engineering-process.md` §14.7 + `core-rules/hooks.md`.
- PR creation — at L5 agent may auto-open PR after gates pass; at L≤4 confirms.

## Loops as an autonomy surface

Loops are an autonomy surface: higher levels run loops with less consultation, and at L4/L5 a loop may run unattended (overnight, cron, `--run-in-background`). The **loop-safety contract** is the halting guarantee that makes that safe — every loop honors three ceilings (`max_iterations`, `no_progress_iterations`, `budget_ceiling_usd`) and hard-stops on any one, so raising autonomy never trades away the guarantee that a runaway loop halts. Full contract: `core-rules/loop-safety.md`.

## Opus 4.8 alignment

Anthropic's Opus 4.8 prompting guidance frames the same tradeoff this slider controls. Two of its system-prompt patterns map directly onto Trellis — the slider implements them as a setting rather than a fixed prompt:

- **Default-to-action ↔ conservative-action.** The doc ships two opposing snippets (`<default_to_action>` vs `<do_not_act_before_instructions>`). The L1–L5 slider *is* that spectrum: L1–L2 default to research-and-recommend (the conservative snippet), L4–L5 default to implement-and-document (the action snippet), L3 splits on the plan-approval gate. You pick a level, not a snippet.
- **Balancing autonomy and safety.** The doc recommends confirming before destructive, hard-to-reverse, or externally-visible actions, and never bypassing safety checks (`--no-verify`) as a shortcut. That is exactly the bright-line guardrail set above — enforced at every level including L5 by hooks, not heuristic.

Full mapping and source snippets: `docs/opus-4.8-steering.md`.

## Reversibility carve-out

Even at L5, surface **inline mid-turn** (not batched to end-of-turn):

- Architectural decisions: new dependency, new top-level module, new data store, auth flow change, public API shape change.
- Pattern-conflict resolution where the chosen pattern propagates beyond the current file.

Reason: reversibility cliff. Variable name = cheap to undo; architecture = not.

## Resolution algorithm

Pick phase (later steps override earlier):

1. Hard default = **L3**.
2. `trellis.config.json.autonomy_default` (fleet default for this clone, 1–5).
3. Active preset's `autonomy_default` if no project-local override.
4. Project-local `<project>/.trellis.config.json.autonomy`.
5. Session override at `<canonical-root>/.claude/session-autonomy` (single integer, written by `/autonomy N`).

Clamp phase:

6. If any active preset declares `autonomy_ceiling`, clamp picked value to ≤ ceiling. Surface one-line warning if clamped:
   > Requested autonomy L<requested>, clamped to L<ceiling> (preset `<preset-name>`).

If multiple presets declare conflicting ceilings, the **lowest ceiling wins** (most restrictive).

## Decision log

When active level ≥ 4, agent appends one line per decision to `<canonical-root>/decisions-log.md` as decisions happen. Format:

```
- {ISO-8601 timestamp} [L<n>] [{kind}] {what was decided}. Reasoning: {why}. Alternatives considered: {what else}.
```

Append ` SURFACED INLINE` if the entry is `architectural` (so audit knows it was not silent).

Kinds: `interpretation`, `pattern`, `scope`, `architectural`.

End-of-turn assistant message renders a `## Decisions made (L<n>)` block pulling this turn's entries. When `gh pr create` runs, the PR description body includes the same block. `session-context.sh` injects the last 10 entries from `decisions-log.md` at session start when active level ≥ 4.

### Storage policy

`decisions-log.md` is **tracked in git**. Reasons:

- Decisions accumulate value over time (architecture audits, ADR cross-references, post-incident review).
- A team operating Trellis benefits from shared visibility into per-session decisions across developers.
- An operator autonomy-drift rollup requires the file to persist across weeks; gitignored files don't survive `git clean -fdx`.

Operators who want per-developer decision logs (e.g., personal scratch projects with only one author) can opt out by adding `/decisions-log.md` to their project `.gitignore`. The Trellis-canonical `gitignore.fragment` does NOT ignore it by default.

If the file grows beyond 100 entries, `autonomy-drift` flags `decisions-log-overflow` (info severity); recommended action is to rotate to `decisions-log.archive.md` and truncate the live file to the last 50 entries.

## Session override (`/autonomy N`)

`core-rules/commands/autonomy.md` defines the slash command. On `/autonomy N`:

1. Validate `N ∈ {1,2,3,4,5}`.
2. Resolve preset ceiling from active presets.
3. Clamp if needed; warn if clamped.
4. Write `<canonical-root>/.claude/session-autonomy` containing the integer.
5. Acknowledge to user with one line: `Autonomy set to L<n> (<name>). <one-line summary of behavior change>.`

The file is gitignored (`<project>/.claude/session-autonomy` per project gitignore fragment). Survives `/compact` because it lives outside `save-context-log.sh`'s overwrite scope. Survives worktrees because canonical-rooted.

## Preset interaction

Presets MAY declare `autonomy_ceiling` and/or `autonomy_default` in YAML frontmatter at the top of their markdown file:

```markdown
---
autonomy_ceiling: 2
autonomy_default: 3
---
```

- `autonomy_ceiling` — clamp maximum value (lowest wins across multiple presets).
- `autonomy_default` — preset's preferred default, used when no project-local override.

`compliance-strict` ⇒ ceiling 2 (audit-grade discipline requires human-in-the-loop).
`experimental-loose` ⇒ ceiling 5, default 4 (throwaway work, decisions cheap to undo).
