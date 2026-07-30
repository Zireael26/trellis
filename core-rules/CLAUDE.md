# Parent engineering rules

Cross-cutting rules that apply to every active personal project. Project-specific `CLAUDE.md` files extend this — they do not repeat it.

---

## Planning

- When asked to plan, output only the plan. No code until explicit approval.
- When given a plan, follow it exactly. If you see a real problem, say so in a sentence — then wait or proceed-and-log per the active autonomy level.
- For non-trivial features (3+ steps or architectural decisions), interview the user about implementation, UX, and tradeoffs before writing code.
- **Mandatory feature pipeline (opt-in, default off).** When `mandatory_pipeline` is enabled in `trellis.config.json`, a branch whose net gated diff exceeds the size floor cannot be pushed without a spec triad, a size-capped `/surgical` declaration, or a logged `/surgical --emergency`; sub-floor work stays surgical-default. The gate is deterministic and harness-identical, and is not a bright-line guardrail — *who answers* the intake interview follows the autonomy slider. Mechanism: `engineering-process.md` §14.7, `core-rules/hooks.md`.
- Never attempt multi-file refactors in one response. Break into phases sized by a **soft, autonomy-scoped ceiling** — ~7 files at L1–L3, widening at L4/L5 where the agent runs less interactively. It is a safety rail, not a hard cap: the `code-review-subagent` fires at ≥3 files / ≥200 lines, so review coverage scales with phase size. Complete, verify (hooks enforce), get approval per the active autonomy level, then continue.
- Don't hide confusion. When two readings of the request would lead to materially different work, surface the choice instead of picking silently; resolve routine ambiguity yourself, per the active autonomy level.
- Frame each task as a verifiable goal before writing code: bug → reproducing test that fails then passes; refactor → tests green before and after; new behavior → explicit acceptance check per step. Weak goals ("make it work") force back-and-forth; strong goals let you loop independently.

## Code quality

- Default to surgical scope: touch only what the task requires, match existing style, don't refactor adjacent code. Carve-outs: (a) if structural rot blocks the current task, flag and fix it in scope; (b) if you spot adjacent rot worth fixing, spin a separate session with your harness's session-spawn tool — never silently bundle.
- No abstractions for single-use code. Three similar lines beat a premature factory.
- When two patterns in the codebase contradict, pick one (recency or test coverage), justify the choice, and flag the loser for cleanup. Don't blend or "average" them.
- Write code that reads like the surrounding code: match its comment density, naming, and idiom.
- Commit messages follow the same rule: terse, human voice, no `Co-authored-by: Claude` or `🤖 Generated with Claude Code` footers.
- Don't build for imaginary scenarios. Simple and correct beats elaborate and speculative.
- No speculative defensive code. Don't add error handling, fallbacks, or validation for cases that can't occur — trust internal callers and framework guarantees; validate only at system boundaries (user input, external APIs).

## Context management

- Context budget: measure and minimize the full injected scaffold; see `engineering-process.md` §9.1.
- Before any structural refactor on a file >300 LOC, remove all dead props, unused exports, unused imports, debug logs. Commit cleanup separately.
- Batch independent tool calls — reads, greps, bash — into a single message rather than firing them serially. A serial chain of five greps costs five round-trips for no benefit.
- Your job as orchestrator is to orchestrate: read, plan, decide, delegate, verify, synthesize. You hold the large context window so you can keep the whole task surface while the work happens elsewhere — not so you can do the work yourself. Bounded units of *execution* leave the main loop by default; you stay in the loop by reviewing what comes back. Most of the tokens on a multi-unit task should not be yours.
- **Context trigger** for delegation: the work is genuinely independent, parallelizable, and larger than you would finish in a handful of tool calls — a wide multi-file investigation, an audit spanning several subsystems, a search whose breadth you cannot predict. Don't delegate context-triggered work you could finish inline, and if one subagent can do it use one rather than several.
- **Fit trigger** for delegation, sufficient on its own: the unit matches an enumerated profile trigger — a large sustained generation, a bounded unit with a pre-existing oracle, or work whose value is a second model's independent eyes. Matching is the test; there is deliberately **no** comparison of whether the other model would do it *better*. The lanes are at near-parity, so a "better than me" test almost never passes and the work silently stays inline — which is the exact failure this rule exists to prevent. "There is no context pressure" is also not a reason to skip it. Family allocation across a fan-out, and profile choice within a family: `core-rules/references/model-routing.md`.
- Whether to spawn a subagent to check your own work depends on run length, not preference: on a short attended run don't, and on a long or multi-window run verify at a declared interval with a fresh-context subagent against the spec. Deterministic gates are exempt either way — they are mechanism, not self-checking. The rule and its rationale: `core-rules/references/model-prompting-deltas.md` § Verification. Dispatch and keep working rather than blocking; intervene if one goes off track or is missing context you have, and reuse one that already has the context rather than spawning fresh. The payoff is fresh context and wall-clock parallelism — delegation for its own sake costs both.
- When orchestrating multi-stage work, keep planning, review, and synthesis on the orchestrator and route bounded execution-heavy units to an executor node where one exists. Which profile and which family: `core-rules/references/model-routing.md` — the frontier lanes are at near-parity, so a lopsided split is a preference artifact. Explicit provider selections stay authoritative: surface lane failures, fail closed, and never silently substitute the optional legacy `codex-worker` / OpenAI Codex plugin path. Routing policy and the work-order gate: `core-rules/references/delegation.md`.
- Compaction is a state-preservation event, not a budget event: the `save-context-log` hook fires on `PreCompact` and writes `context-log.md` — never author that file by hand. Do not stop, narrow your own scope, wrap up early, or propose a new session on account of context limits; there is ample context and the work continues. When you deliberately start a fresh window, commit first and make sure `context-log.md` and any run log are written, then continue from them. On noticed degradation — referencing variables that don't exist, having lost the file structure — prefer a fresh window over `/compact`: state lives on disk and rediscovering it beats a lossy summary. Resume procedure: `core-rules/references/loops.md` § Resuming across context windows.
- At session start the `session-context` hook injects the previous session's `context-log.md`. Treat it as authoritative for what you were in the middle of — branch, files touched, open todos, last decisions — and read it before asking the user to re-explain context (injected fields, path resolution: `core-rules/hooks.md`).

## Edit safety

- Before editing an existing file, make sure you have read it this turn — the `reread-guard` hook enforces this and blocks an edit to a file you have not read (auto-compaction may have wiped your memory of its contents). The Edit tool errors loudly on a stale `old_string` and the harness tracks file state, so a routine re-read *after* editing is not needed.
- On any rename or signature change, search separately for: direct calls, type references, string literals, dynamic imports, require() calls, re-exports, barrel files, test mocks. Assume grep missed something.
- Before adding code in an unfamiliar area, read the immediate callers, the module's public exports, and any shared utilities it would touch. "Looks orthogonal" is dangerous — if you can't explain why the surrounding code is structured as it is, ask.
- Never delete a file without verifying nothing references it.
- Code-asset pairing: when a code change has a non-code companion (a checked-in generated file, a scene/prefab reference, a fixture, a binding manifest, rendered media), update it in the same commit — typecheck/build/lint cannot detect the drift; it surfaces only at runtime or via an integrity test. (observed across 4 projects)
- Confirm which checkout you are in (`git rev-parse --show-toplevel`) before any path-sensitive op: a worktree is a tracked-content-only checkout, and `git clean -fd` / `git checkout .` / `git commit --amend` against shared state can destroy another checkout's work. Detail: `core-rules/references/gotchas-operational.md`.

## Definition of done

- Receipts required. When declaring done, include the verification command you ran, its exit code, and the diff lines that prove the change. "It works" without receipts is not done. The canonical machine-readable form is the marker `<!-- dod-receipt cmd="…" exit=<int> diff="+N/-M (K files)" -->`: Stop hooks check it and the `execute` skill emits it. It maps 1:1 to this prose — `cmd`→verification command, `exit`→exit code, `diff`→diff lines.
- Receipt evidence must come from executing or diffing the artifact: the real command, its exit code, and the diff — never agent self-report. Where a skill has an eval, prefer a judge that runs/diffs the artifact over one that reads the transcript ([Fable Method: 15 rounds, 260+ runs](https://github.com/Sahir619/fable-method#results-at-a-glance)).
- Follow-ups required at completion boundaries. At a spec status flip (DECIDED/SHIPPED), a PR open, or a DoD-receipt emission on a substantive unit, end the message with a `Follow-ups` block — items drawn ONLY from context already read this session, never from new exploration. Alongside the DoD receipt emit the marker `<!-- follow-ups: <count> -->` (or `<!-- follow-ups: none -->`); Stop hooks warn — non-blocking, by design — on a receipt without it. Trivial turns emit nothing. Block format, durable capture, and disposition routing: `core-rules/references/follow-ups.md`.
- Open todos mean not done. If `TodoWrite` has `in_progress` or `pending` items, complete them, defer with a reason, or abandon with a reason. The Stop hook enforces this.
- Live teammates mean not done. A named teammate/agent pane you spawned is a held resource: engine-run workflow agents auto-terminate, named teammates do not. The root may use `name` for an intentional teammate mailbox; named teammates and nested Agent callers omit `name` and consume unnamed results directly. An Agent name is never a `TaskOutput` task ID: wait for messages, use `SendMessage` for follow-up, and call `TaskStop` in the same turn that accepts, supersedes, fails, or abandons named work. Do not defer teardown or originate `shutdown_request`. Flat-roster, task-ID, and teardown details: `core-rules/references/delegation.md`.
- On edit-heavy turns a code-review subagent runs against the diff. Resolve findings or explicitly acknowledge and defer them. You do not self-mark your own homework.
- For UI-visible changes, verify visually: run the dev server, take a computer-use screenshot (fallback: headless Playwright), attach it. Logically verified is not visually verified.
- Tests must fail when business intent changes, not just when an implementation detail moves. A test you can't break by inverting the requirement is wrong — receipts only prove the assertion ran, not that it asserts anything load-bearing.

## Debugging

- Work from raw error data. Don't guess. If a bug report has no output, ask for it. Never claim anything about code you haven't opened — if the user names a file, read it before answering, not after.
- For any long-running process (dev server, test watcher, build, log tail), use the `monitor` tool — never `tail -f`, polling loops, or repeated Bash calls. Monitor streams stdout lines as notifications with zero token overhead.
- If a fix doesn't work after two attempts, stop. Read the entire relevant section top-down and escalate reasoning effort (`/effort xhigh`, or the equivalent your harness exposes — `xhigh` is the ceiling, `max` buys very little for substantially more reasoning) before the next attempt — the stuck-point is where the extra reasoning pays for itself. Name the assumption about the system that the evidence just falsified, and make the next attempt test a different one.
- Before provisioning cloud infrastructure, verify the specific capability and quota you need exist in the target region — global signals and other regions lie: `core-rules/references/gotchas-operational.md`.

## Credentials

A token shared by several projects has ONE canonical source, exported from your shell profile and never duplicated into per-project `.env.local`; verify it works before any deploy rather than falling back to a copy found in some project's env file. Full rule, refresh procedure, and the stale-copy cleanup case: `core-rules/references/gotchas-operational.md` § Shared credentials.

## Self-correction

- After any correction from the user, log the pattern to `gotchas.md` in the project root — convert mistakes into rules. Update an existing gotcha rather than appending a near-duplicate, and delete one that turns out to be wrong. Review gotchas at session start.
- When pointed to existing code as reference, study it and match its patterns exactly. Working code is a better spec than English.
- When asked to test your own output, test it the way someone seeing the project for the first time would.

## Communication

- When the user says "yes," "do it," or "push," execute. Don't repeat the plan.
- While the operator is watching, be terse. TodoWrite carries in-flight state and the diff carries the result — don't narrate what they already show.
- The final message of an unattended run is different: it is the operator's first look at everything you did. Write it as a re-grounding rather than a continuation of your working thread — complete sentences, outcome first, terms spelled out, no working shorthand or invented labels. This applies to overnight runs, cron jobs, background workflows, and any long stretch of tool calls since the operator last spoke. Where the run produced them, the `## Decisions made (L<n>)` and `Follow-ups` blocks are part of that message, not exceptions to it.
- Flag real problems up front. Don't bury them under "here's what I did."

## Autonomy

Trellis ships a **responsibility slider** (L1–L5, default L3) controlling *who answers* interactive gates — user or agent. All gates and quality controls fire at every level; the level changes only the consultation surface. Bright-line guardrails (hard hooks, destructive ops, external messages, secrets, DoD receipts, code-review subagent, untrusted-content boundary) stay mandatory at every level, and architectural decisions surface inline mid-turn even at L5. At L4/L5 decisions taken on the user's behalf go to `<canonical-root>/decisions-log.md` (a separate file, never touched by `save-context-log`) and render as a `## Decisions made (L<n>)` block.

Level resolution (pick → clamp): `trellis.config.json.autonomy_default` → project-local `.trellis.config.json.autonomy` → preset `autonomy_default` (when no project-local) → session override (`/autonomy N`); then clamp to the lowest preset `autonomy_ceiling`. Full matrix, guardrails, resolution algorithm, decision-log format: `core-rules/autonomy.md`.

## Loops

Every Trellis loop — operator cron jobs, `orchestrate` fan-outs, `/loop` and `/goal` runs — declares and honors **three ceilings** and **halts on any one**: `max_iterations`, `no_progress_iterations`, `budget_ceiling_usd`. On a trip it hard-stops (never auto-continues) and emits a structured halt report; unattended loops surface the halt in their run report. Ceiling resolution, progress-signal catalog, halt behavior, and the token↔dollar conversion: `core-rules/loop-safety.md`.

## Advisor

When the `advisor` tool is available (auto-forwards full conversation history; no parameters), prefer the strongest reasoning model on offer. Call it when a second opinion would change what you do next: before locking an interpretation that is expensive to unwind, when an approach has stopped converging, and before declaring done on a long or unattended run. Skip it on short reactive turns where the next action is already dictated by tool output you just read.

## Hooks

Two tiers — **fast-local** (every turn) and **heavy-gated** (wrap-up) — plus a **git-boundary** tier whose `pre-push` blocks direct push to `main`. Tier contents, per-hook names, harness paths, and event wiring: `hooks.md`.

## Skills

Canonical skills live under `core-rules/skills/<name>/`, inherited by every project via symlink (Claude Code: `.claude/skills/`; Codex: `.agents/skills/`). Each skill's `SKILL.md` is its spec.

**Path-scoping (project-local skills only).** If a non-canonical skill carries a `scope.json` beside its `SKILL.md`, read it before auto-mentioning the skill: auto-invoke only when the session cwd or this turn's changed files match a glob in `paths[]`. Explicit `/skill <name>` invocations always work. Schema + rationale: `core-rules/inheritance.md` § "Skill path-scoping".

## Commands

Canonical slash commands live under `core-rules/commands/<name>.md`, inherited via symlink (`.claude/commands/`, `.agents/commands/`). Commands are explicit user invocations (`/<name> <args>`); skills are what the agent dispatches from context. The canonical set and what each does: `core-rules/commands/`. Reach for `/explore` before touching an unfamiliar subsystem — it maps one to a transient note in a read-only subagent, which is cheaper than exploring inline.

<!-- BEGIN PRIMER SECTION -->

## Feature primers

Where `<canonical-root>/.claude/primers/INDEX.md` exists, primers are live and the `inject-primer-index` hook injects INDEX at session start. **When the task names a feature, directory, or subsystem listed in INDEX, read that primer before exploring code** — loading is not optional. On any drift flag other than FRESH or WARM, say so before relying on it and offer `/primer-refresh`. Opt-in, authoring, staleness, storage, and the `/primer` commands: `core-rules/primers.md`.

<!-- END PRIMER SECTION -->

## Project-local files every project maintains

- `CLAUDE.md` — project-specific rules only. No duplication of this file. Target <5 KB.
- `gotchas.md` — lessons logged as they happen.
- `context-log.md` — written by the `save-context-log` hook at the canonical project root, auto-injected at session start and after compaction. Never edit by hand (mechanism: `core-rules/hooks.md`).

## Documentation

- Architecture decisions go in numbered, sequential ADRs (`docs/adr/NNNN-<slug>.md`: context, decision, consequences, status). (observed across 3 projects) Where a project already captures the same decisions in tech-spec docs, follow that convention.

## Control plane

Active projects opt in via `registry.md`; temporary exemptions in `blacklist.md`. Audits, registry, and project onboarding live in `__TRELLIS_PATH__/`, whose `engineering-process.md` is the narrative manual (why/how, onboarding playbook, incident patterns, glossary) — read it on demand when you need more than these terse rules. Target for this file: **≤19,000 bytes and ≤200 lines** (`wc -c`, `wc -l`; the line budget is what `trellis-doctor` reports on, warn-class). Anything situational belongs in a sibling reference. Stated in bytes rather than KB on purpose: the previous target was "<5 KB" against a 24 KB file, and a target nobody can check is a target nobody keeps.

## Inheritance

Inheritance mechanism (symlink + @-import, skills inheritance, multi-harness layout, silent-drop invariants, registered-project checklist): `core-rules/inheritance.md`. The scheduled `cross-project-process-audit` fails a project missing required inheritance.

---

Keep responses short while the operator is watching; write the final message of an unattended run as a re-grounding in plain prose.
