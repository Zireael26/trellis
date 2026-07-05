# Parent engineering rules

Cross-cutting rules that apply to every active personal project. Project-specific `CLAUDE.md` files extend this — they do not repeat it.

---

## Planning

- When asked to plan, output only the plan. No code until explicit approval.
- When given a plan, follow it exactly. Flag real problems and wait.
- For non-trivial features (3+ steps or architectural decisions), interview the user about implementation, UX, and tradeoffs before writing code.
- Never attempt multi-file refactors in one response. Break into phases sized by a **soft, autonomy-scoped ceiling** — ~7 files at L1–L3, widening at L4/L5 where the agent runs less interactively and a larger coherent phase is warranted. The ceiling is a safety rail, not a hard cap: the `code-review-subagent` fires at ≥3 files / ≥200 lines, so review coverage scales up with phase size. Complete, verify (hooks enforce), get approval per the active autonomy level, then continue.
- Don't hide confusion. If a request has multiple valid interpretations, surface them — don't pick silently. If something is unclear, stop and name what's confusing before guessing.
- Frame each task as a verifiable goal before writing code: bug → reproducing test that fails then passes; refactor → tests green before and after; new behavior → explicit acceptance check per step. Weak goals ("make it work") force back-and-forth; strong goals let you loop independently.

## Code quality

- Default to surgical scope: touch only what the task requires, match existing style, don't refactor adjacent code. Carve-outs: (a) if structural rot blocks the current task, flag and fix it in scope; (b) if you spot adjacent rot worth fixing, use `mcp__ccd_session__spawn_task` to spin a separate session — never silently bundle.
- No abstractions for single-use code. Three similar lines beat a premature factory.
- When two patterns in the codebase contradict, pick one (recency or test coverage), justify the choice, and flag the loser for cleanup. Don't blend or "average" them.
- Write code that reads like a human wrote it. No robotic comment blocks. Default to no comments. Only comment when the WHY is non-obvious.
- Commit messages follow the same rule: terse, human voice, no `Co-authored-by: Claude` or `🤖 Generated with Claude Code` footers.
- Don't build for imaginary scenarios. Simple and correct beats elaborate and speculative.
- No speculative defensive code. Don't add error handling, fallbacks, or validation for cases that can't occur — trust internal callers and framework guarantees; validate only at system boundaries (user input, external APIs).

## Context management

- Before any structural refactor on a file >300 LOC, remove all dead props, unused exports, unused imports, debug logs. Commit cleanup separately.
- Dispatch sub-agents in parallel for speed and context-isolation whenever work decomposes into independent units. Wall-clock parallelism beats sequential agent time; each subagent gets a fresh context = higher-quality output. Triggers: (a) ≥2 independent searches/fetches/analyses, (b) >5 files, (c) edit-heavy turns. Single message, multiple `Agent` tool calls. Skip only when one result must inform the next or work is trivially serial. Opus 4.8 under-dispatches subagents and tools by default — honor these triggers even when inlining feels easier, and batch independent tool calls (reads, greps, bash) in one message rather than firing them serially. For multi-stage work, if your harness exposes a tool that spawns and coordinates subagents, prefer orchestrating through it (decompose → fan-out → adversarially verify → synthesize); otherwise run the same stages yourself — the decompose / verify / synthesize discipline holds regardless of harness. When orchestrating multi-stage work and a dispatchable executor node is available, route execution-heavy bounded units (large mechanical edits, long-running background execution) to it while keeping planning, review, and synthesis on the orchestrator; when no executor node is available, run every unit on the orchestrator itself. This is a capability gate, not a model choice — the branch is on whether an executor node exists, never on which model is running.
- When ctx use ≥40% or after 25 messages (whichever comes first), re-read any file before editing it. Auto-compaction may have destroyed your memory of its contents.
- If you notice context degradation (referencing nonexistent variables, forgetting file structure), run `/compact` proactively — the `save-context-log` hook fires on `PreCompact` and writes `context-log.md` automatically; do not author the file by hand.
- At session start, the `session-context` hook auto-injects the previous session's `context-log.md`. Treat that injection as authoritative for "what was I in the middle of" — branch, files touched, open todos, last decisions. Read it before asking the user to re-explain context. The log is stored at the canonical project root (resolved via `git --git-common-dir`), so worktree sessions see the same log as the main checkout.

## Edit safety

- Before editing an existing file, make sure you have read it this turn — the `reread-guard` hook enforces this and blocks an edit to a file you have not read (auto-compaction may have wiped your memory of its contents). The Edit tool errors loudly on a stale `old_string` and the harness tracks file state, so a routine re-read *after* editing is not needed.
- On any rename or signature change, search separately for: direct calls, type references, string literals, dynamic imports, require() calls, re-exports, barrel files, test mocks. Assume grep missed something.
- Before adding new code in an unfamiliar area, read the immediate callers, the module's public exports, and any shared utilities it would touch. "Looks orthogonal" is dangerous — if you can't explain why the surrounding code is structured the way it is, ask.
- Never delete a file without verifying nothing references it.
- A git worktree is a tracked-content-only checkout, not a clone: gitignored files, inheritance symlinks, `node_modules`, and build caches are absent or root-scoped, and silently break skills, lint, and typecheck. Confirm which checkout you are in (`git rev-parse --show-toplevel`) before any path-sensitive op, and never run `git clean -fd`, `git checkout .`, or `git commit --amend` against shared/canonical state without attributing every untracked/staged entry — files you don't recognize are almost certainly another worktree's in-progress work. (observed across 4 projects)
- Code-asset pairing: when a code change has a non-code companion (a checked-in generated file, a scene/prefab reference, a fixture, a binding manifest, rendered media), update it in the same commit — typecheck/build/lint cannot detect the drift; it surfaces only at runtime or via an integrity test. (observed across 4 projects)

## Definition of done

- Receipts required. When declaring done, include the verification command you ran, its exit code, and the diff lines that prove the change. "It works" without receipts is not done. The canonical machine-readable form is the marker `<!-- dod-receipt cmd="…" exit=<int> diff="+N/-M (K files)" -->`: Stop hooks check it and the `execute` skill emits it. It maps 1:1 to this prose — `cmd`→verification command, `exit`→exit code, `diff`→diff lines.
- Open todos mean not done. If `TodoWrite` has `in_progress` or `pending` items, complete them, defer with a reason, or abandon with a reason. The Stop hook enforces this.
- On edit-heavy turns a code-review subagent runs against the diff. Resolve findings or explicitly acknowledge and defer them. You do not self-mark your own homework.
- For UI-visible changes, verify visually: run the dev server, take a computer-use screenshot (fallback: headless Playwright), attach it. Logically verified is not visually verified.
- Tests must fail when business intent changes, not just when an implementation detail moves. A test you can't break by inverting the requirement is wrong — receipts only prove the assertion ran, not that it asserts anything load-bearing.

## Debugging

- Work from raw error data. Don't guess. If a bug report has no output, ask for it. Never claim anything about code you haven't opened — if the user names a file, read it before answering, not after.
- For any long-running process (dev server, test watcher, build, log tail), use the `monitor` tool — never `tail -f`, polling loops, or repeated Bash calls. Monitor streams stdout lines as notifications with zero token overhead.
- If a fix doesn't work after two attempts, stop. Read the entire relevant section top-down, and escalate reasoning effort (`/effort max`, or ultracode if your harness exposes it) before the next attempt — the stuck-point is exactly where the extra reasoning pays for itself. State where your mental model was wrong before trying again.
- Cloud provisioning: before committing to a region, zone, or machine family, verify the *specific* capability you need is available there — model serving, machine-type/disk support, and the per-region quota bucket. Global signals (`effectiveLimit=-1`) and other regions lie about the target region; `asia-south1` in particular is on limited rollouts. (observed across 3 GCP projects)

## Self-correction

- After any correction from the user, log the pattern to `gotchas.md` in the project root. Convert mistakes into rules. Review gotchas at session start.
- When pointed to existing code as reference, study it and match its patterns exactly. Working code is a better spec than English.
- When asked to test your own output, adopt a new-user persona. Walk through as if you've never seen the project.

## Communication

- When the user says "yes," "do it," or "push," execute. Don't repeat the plan.
- Terse responses. No trailing prose summaries — TodoWrite carries in-flight state, the diff carries the result.
- Flag real problems up front. Don't bury them under "here's what I did."

## Autonomy

Trellis ships a **responsibility slider** (L1–L5, default L3) that controls *who answers* interactive gates — user or agent. All gates and quality controls fire at every level; level only changes consultation surface. Full matrix, guardrails, and resolution algorithm: `core-rules/autonomy.md`.

Active level resolution (pick → clamp): `trellis.config.json.autonomy_default` → project-local `.trellis.config.json.autonomy` → preset `autonomy_default` (if no project-local) → session override at `<canonical-root>/.claude/session-autonomy` (written by `/autonomy N`). Then clamp by lowest preset `autonomy_ceiling`.

At L4/L5, agent appends each decision made on user's behalf to `<canonical-root>/decisions-log.md` (separate file, NOT touched by `save-context-log.sh`). End-of-turn message renders a `## Decisions made (L<n>)` block; PR description (when created) includes same block.

**Architectural decisions surface inline mid-turn even at L5** (reversibility cliff). Bright-line guardrails (hard hooks, destructive ops, external messages, secrets, DoD receipts, code-review subagent) remain mandatory at every level.

Default L3 = current Trellis behavior; existing projects see no change.

## Loops

Trellis ships a **loop-safety contract** that guarantees every Trellis loop halts. Every loop — `scheduled-tasks/` cron loops, `orchestrate` fan-out workflows, `/loop` / `/goal` runs — declares and honors **three ceilings** and **halts on any one**: `max_iterations`, `no_progress_iterations`, and `budget_ceiling_usd`. On a trip the loop hard-stops (never auto-continues) and emits a structured halt report; unattended loops surface the halt in their run report. The contract is doctrine plus declared fields, not a mechanical kill hook. Full policy, progress-signal catalog, halt behavior, and the token↔dollar conversion: `core-rules/loop-safety.md`.

Ceiling value resolution (most specific wins, each ceiling independently): per-loop `safety` override → project-local `.trellis.config.json.loop_safety` → central `trellis.config.json.loop_safety` → documented built-in fallback constants (`core-rules/loop-safety.md`), so a loop in a broken/misconfigured context still halts.

## Advisor

When the `advisor` tool is available (auto-forwards full conversation history; no parameters required), prefer Opus when model selection is offered. Call before substantive work — writing, locking an interpretation, declaring done — and when stuck. On multi-step tasks, call at least once before committing to an approach and once before declaring done. Skip on short reactive tasks where the next action is dictated by tool output you just read; over-calling burns tokens and yields little.

## Hooks

Two tiers — **fast-local** (every turn) and **heavy-gated** (wrap-up) — plus a **git-boundary** tier (husky / native git hooks) whose `pre-push` carries the Trellis PR-flow guard blocking direct push to `main`. Per-hook names, harness paths (`.claude/` vs `.codex/`), and event wiring live in `hooks.md`.

## Skills

Canonical skills under `core-rules/skills/<name>/`, inherited by every project via symlink (Claude Code: `.claude/skills/`; Codex: `.agents/skills/`). Current canonical: **process-gate** — mandatory pre-PR gate. Spec: `core-rules/skills/process-gate/SKILL.md`.

**Path-scoping (project-local skills only).** If a non-canonical skill carries a `scope.json` next to its `SKILL.md`, read it before auto-mentioning the skill. Only auto-invoke when the session cwd or this turn's changed files match at least one glob in `paths[]`. Explicit `/skill <name>` invocations always work regardless of scope. Schema + rationale: `core-rules/inheritance.md` § "Skill path-scoping".

## Commands

Canonical slash commands under `core-rules/commands/<name>.md`, inherited by every project via symlink (Claude Code: `.claude/commands/`; Codex: `.agents/commands/`). Commands are explicit user invocations (`/<name> <args>`) — distinct from skills, which the agent dispatches based on context. Current canonical set: `primer`, `primer-refresh`, `primer-check` (feature primer system, see below), and `explore` (read-only subagent maps an unfamiliar subsystem to a transient note before the editing session touches it).

<!-- BEGIN PRIMER SECTION -->

## Feature primers

Trellis ships a primer system that gives agents pre-built context for stable features, reducing exploration cost on tasks like testing, debugging, or extending those features. Project opt-in: if `<canonical-root>/.claude/primers/INDEX.md` exists, primers are live for that project. Projects without that directory are unaffected by this section.

**At session start**, if `.claude/primers/INDEX.md` exists (resolved at the canonical repo root via `git rev-parse --git-common-dir`, same pattern as `context-log.md`):

1. The `inject-primer-index` SessionStart hook auto-injects `.claude/primers/INDEX.md` (one line per primer, with drift flags: FRESH / WARM / STALE / MISSING_PATHS / UNREACHABLE_PIN / BROKEN / NO_ENTRY_POINTS) into your context. You do not need to read INDEX manually.
2. **If the user's task names a feature, directory, or subsystem listed in INDEX, you MUST read that primer before exploring code.** Loading is not optional — that is why the primer exists. Cost is ~3 KB; reread cost would be 50× that.
3. If a relevant primer shows drift status WARM, FRESH, or no flag, load and use it. If it shows STALE / MISSING_PATHS / UNREACHABLE_PIN / BROKEN, tell the user before relying on it and offer `/primer-refresh`.
4. If the task touches a feature without a primer, do the work, then at the end propose running `/primer <feature-slug>` to capture what you learned.

**Loading policy:** auto-injected via SessionStart hook (since v0.3.1); the agent is required to load when task scope overlaps INDEX entries.

**Authorship:** primers are agent-written via `/primer` and hand-editable. Treat any hand-edits to a primer as load-bearing — `/primer-refresh` patches around them rather than overwriting.

**Staleness:** every primer is pinned to a commit SHA. When loading a primer, do a quick check that the referenced files still exist. If a primer looks stale (referenced files moved, SHA unreachable), note it to the user and suggest `/primer-refresh <slug>` rather than acting on potentially-wrong information.

**Available commands:**
- `/primer <slug>` — create a new primer for a feature
- `/primer-refresh <slug>` — update an existing primer against current HEAD
- `/primer-check` — audit all primers for staleness (no changes made)

**What primers describe:** stable shape — entry points, data flow, dependencies, test commands, gotchas. Not line-by-line walkthroughs. If a primer is over ~150 lines or describes implementation details, it should be split or trimmed.

**Storage location.** Primer files live at the canonical repo root (`<canonical-root>/.claude/primers/`), not the worktree-specific path — so worktree sessions see the same primer set as the main checkout. Same load-bearing canonical-root convention as the three context-log hooks; see `gotchas.md` 2026-05-11 entry for rationale.

<!-- END PRIMER SECTION -->

## Project-local files every project maintains

- `CLAUDE.md` — project-specific rules only. No duplication of this file. Target <5 KB.
- `gotchas.md` — lessons logged as they happen.
- `context-log.md` — maintained by the `save-context-log` hook on every `PreCompact` (Claude Code) / `Stop` (Codex). Stored at the canonical project root so it survives worktree cleanup. Auto-injected at session start by `session-context` and after compaction by `post-compact-context`. Never edit by hand.

## Documentation

- Architecture decisions go in numbered, sequential ADRs (`docs/adr/NNNN-<slug>.md`: context, decision, consequences, status). (observed across 3 projects) Project override: some projects capture the same decisions in tech-spec docs with a different layout — follow the project's established convention where one exists.

## Control plane

Active projects opt in via `registry.md`; temporary exemptions in `blacklist.md`. Audits, registry, and project onboarding live in `__TRELLIS_PATH__/`. Narrative manual (why/how, onboarding playbook, incident patterns, glossary): `__TRELLIS_PATH__/engineering-process.md` — read on demand when you need deeper context than these terse rules give you. Target <5 KB for this file; split deeper reference into sibling docs on demand.

## Inheritance

Load-bearing inheritance mechanism (symlink + @-import, skills inheritance, multi-harness Claude Code + Codex layout, silent-drop invariants, registered-project checklist): `core-rules/inheritance.md`. The scheduled `cross-project-process-audit` fails a project missing required Claude inheritance; Codex-enabled projects are also checked for `AGENTS.md`, `.agents/`, and `.codex/` parity.
