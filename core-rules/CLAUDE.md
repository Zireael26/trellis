# Parent engineering rules

Cross-cutting rules for every active personal project. Project-specific `CLAUDE.md` files extend it, not repeat it.

---

## Planning

- When asked to plan, output only the plan. No code until explicit approval.
- When given a plan, follow it exactly. If a real problem appears, say so in one sentence — then wait or proceed-and-log per the active autonomy level.
- For non-trivial features (3+ steps or architectural decisions), interview the user on implementation, UX, and tradeoffs before coding.
- **Mandatory feature pipeline (opt-in, default off).** When effective portable policy enables `mandatory_pipeline` (the tracked project declaration is `.trellis.json`), a branch whose net gated diff exceeds the size floor cannot be pushed without a spec triad, a size-capped `/surgical` declaration, or a logged `/surgical --emergency`; sub-floor work stays surgical-default. Deterministic and harness-identical, but not a bright-line guardrail — *who answers* the intake interview follows the autonomy slider. `engineering-process.md` §14.7, `core-rules/hooks.md`.
- Never attempt a multi-file refactor in one response; break into phases under a **soft, autonomy-scoped ceiling** — ~7 files at L1–L3, widening at L4/L5. `code-review-subagent` fires at ≥3 files / ≥200 lines, so review coverage scales with phase size. Complete, verify (hooks enforce), get approval per the active autonomy level, continue.
- Don't hide confusion: when interpretations would materially change the work, surface the choice; resolve routine ambiguity yourself per the active autonomy level.
- Before coding, frame each task as a verifiable goal: bug → reproducing test fails then passes; refactor → tests green before and after; new behavior → explicit acceptance check per step. Strong goals enable independent loops.

## Code quality

- Default to surgical scope: touch only what the task requires, match existing style, don't refactor adjacent code. Carve-outs: (a) structural rot blocking the task — flag and fix in scope; (b) adjacent rot worth fixing — spin a separate session via your harness's session-spawn tool, never silently bundle.
- No single-use abstractions; three similar lines beat a premature factory.
- When codebase patterns contradict, pick one (recency or test coverage), justify it, and flag the loser for cleanup — don't blend or "average" them.
- Write code like its neighbors: match comment density, naming, and idiom.
- Commit messages follow the same rule: terse, human voice, no `Co-authored-by: Claude` or `🤖 Generated with Claude Code` footers.
- Don't build for imaginary scenarios; simple, correct beats elaborate speculation.
- No speculative defensive code: no error handling, fallbacks, or validation for impossible cases — trust internal callers/framework guarantees; validate only at system boundaries (user input, external APIs).
- A fallback must be distinguishable from success: when a default, fixture, cached value, or unfiltered result stands in for real data, expose a distinct status, null, or logged degradation — never present it as measured.
- Retriable async work isn't processed until the durable side effect succeeds; use claim/commit state and a domain idempotency backstop for handlers, webhooks, worker handoffs, and callbacks.
- Evidence doctrine: no escape-hatch contract types or unjustified casts; parse at boundaries — `references/anti-slop.md`.

## Context management

- Context budget: mostly cached-per-type tool schemas — `references/delegation.md`.
- Before any structural refactor on a file >300 LOC, remove dead props, unused exports/imports, debug logs. Commit cleanup separately.
- Batch independent reads, greps, and bash calls in one message.
- Your job as orchestrator is to orchestrate: read, plan, decide, delegate, verify, synthesize — hold the whole task surface while execution happens elsewhere. Bounded units of *execution* leave the main loop by default; you stay in it by reviewing what comes back. Most tokens on a multi-unit task should not be yours.
- **Context trigger** for delegation: work genuinely independent, parallelizable, and larger than a handful of tool calls — a wide multi-file investigation, an audit spanning subsystems, a search of unpredictable breadth. Don't delegate what you could finish inline. But when a request names N independent targets, N is the dispatch count: single-agent fan-out is the measured failure mode, not the cautious default — `references/delegation.md`.
- **Fit trigger** for delegation, sufficient on its own: the unit matches an enumerated profile trigger — a large sustained generation, a bounded unit with a pre-existing oracle, or work whose value is review by a context that didn't author it. Matching is the test — deliberately **no** "would another model do it better" comparison, and "no context pressure" is no reason to skip.
- Self-checking via subagent depends on run length, not preference: short attended run — don't; long or multi-window run — verify at a declared interval with a fresh-context subagent against the spec (deterministic gates exempt — mechanism, not self-checking; rationale: `core-rules/references/model-prompting-deltas.md` § Verification). Dispatch and keep working; intervene on drift; reuse one that already has the context. Payoff: fresh context and wall-clock parallelism — delegation for its own sake costs both.
- Multi-stage orchestration keeps planning, review, and synthesis on the orchestrator. Use Claude Workflow when the work depends on orchestrator context and Claude-family units dominate; use OMP `eval` for non-Anthropic quota or cross-family review. Operator-named routing wins over these defaults; otherwise the live role resolver decides. Profile and effort: `core-rules/references/model-routing.md`. Provider selections are authoritative: an empty or error-shaped delegated result is a non-result, never a clean finding — confirm the transcript or receipt, surface the lane failure, never silently substitute a provider. Work orders: `core-rules/references/delegation.md`.
- Compaction is a state-preservation event, not a budget event: the `save-context-log` hook fires on `PreCompact` and writes `context-log.md` — never author it by hand. Never stop, narrow scope, wrap up early, or propose a new session over context limits; the work continues. Deliberate fresh window: commit, confirm `context-log.md`, continue from it. On noticed degradation prefer a fresh window over `/compact` — state on disk beats a lossy summary. Resume: `core-rules/references/loops.md`.
- At session start the `session-context` hook injects the previous session's `context-log.md` — authoritative for where you were (branch, files touched, open todos, last decisions); read it before asking the user to re-explain (injected fields, path resolution: `core-rules/hooks.md`).

## Edit safety

- Before editing an existing file, read it this turn — `reread-guard` blocks unread files. The Edit tool errors loudly on stale `old_string`, so no routine reread after editing.
- On any rename or signature change, search separately for: direct calls, type references, string literals, dynamic imports, require() calls, re-exports, barrel files, test mocks. Assume grep missed something.
- Before adding code in an unfamiliar area, read its immediate callers, public exports, and shared utilities it touches. "Looks orthogonal" is dangerous — if you can't explain the surrounding structure, ask.
- Never delete a file without verifying nothing references it.
- Code-asset pairing: when a code change has a non-code companion (a checked-in generated file, a scene/prefab reference, a fixture, a binding manifest, rendered media), update it in the same commit — typecheck/build/lint can't see the drift; it surfaces only at runtime or via an integrity test.
- Before authoring or shipping a migration, verify the runner against authoritative live state — applied head/watermark, deploy role, actual schema. File order, snapshots, and “Migrations complete” output are not proof.
- Confirm which checkout you're in (`git rev-parse --show-toplevel`) before any path-sensitive op: `git clean -fd` / `git checkout .` / `git commit --amend` against shared state can destroy another checkout's work. Detail: `core-rules/references/gotchas-operational.md`.

## Definition of done

- Receipts required when declaring done: the verification command you ran, its exit code, and the diff lines that prove the change. Machine-readable form, checked by Stop hooks, emitted by the `execute` skill: `<!-- dod-receipt cmd="…" exit=<int> diff="+N/-M (K files)" -->`.
- Receipt evidence must come from executing or diffing the artifact, never agent self-report. Where a skill has an eval, prefer a judge that runs/diffs it over one reading the transcript ([Fable Method](https://github.com/Sahir619/fable-method#results-at-a-glance)).
- Follow-ups required at completion boundaries — a spec status flip (DECIDED/SHIPPED), a PR open, or a DoD-receipt emission on a substantive unit: end with a `Follow-ups` block, items drawn ONLY from context already read this session, never new exploration. Emit `<!-- follow-ups: <count> -->` (or `none`) alongside the receipt; Stop hooks warn, non-blocking by design. Format, capture, routing: `core-rules/references/follow-ups.md`.
- Open todos mean not done: complete `in_progress`/`pending` `TodoWrite` items or defer/abandon with a reason. The Stop hook enforces this.
- Live teammates mean not done. A named teammate you spawned is a held resource: engine-run workflow agents auto-terminate, named teammates do not — call `TaskStop` in the same turn that accepts, supersedes, fails, or abandons the work; never defer teardown, never originate `shutdown_request`. Naming, flat roster, teardown: `core-rules/references/delegation.md`.
- On edit-heavy turns a code-review subagent runs against the diff. Resolve findings or explicitly acknowledge and defer them — you don't self-mark your homework.
- For UI-visible changes, verify visually: run the dev server, take a computer-use screenshot (fallback: headless Playwright), attach it — logically verified is not visually verified.
- For framework changes, verify built/runtime behavior, not source-level intent; config, rendering, generated types, bundling, CSS, and browser-security semantics can diverge after build.
- Tests must fail when business intent changes, not just when an implementation detail moves. A test you can't break by inverting the requirement is wrong; receipts prove the assertion ran, not that it asserts anything load-bearing.

## Debugging

- Work from raw error data — don't guess; if a bug report has no output, ask. Never claim anything about code you haven't opened; if the user names a file, read it before answering.
- For any long-running process (dev server, test watcher, build, log tail), use the `monitor` tool — never `tail -f`, polling loops, or repeated Bash calls.
- If a fix doesn't work after two attempts, stop. Read the whole relevant section top-down and escalate effort (`/effort xhigh` or your harness's equivalent — `xhigh` is the ceiling; `max` buys little for far more reasoning) before the next attempt. Name the assumption the evidence just falsified; make the next attempt test a different one.
- Provider defaults, local config, and docs are hypotheses until probed in the target runtime. Before declaring a deploy or integration ready, verify actual region, image, environment, credentials, runtime binary, and protocol behavior; cloud provisioning also needs target-region capability and quota.

## Credentials

A token shared by several projects has ONE canonical source, exported from your shell profile and never duplicated into per-project `.env.local`; verify it works before any deploy. Full rule, refresh, stale-copy cleanup: `core-rules/references/gotchas-operational.md` § Shared credentials.

## Self-correction

- After any user correction, log the pattern to `gotchas.md` at the project root — convert mistakes into rules. Update an existing gotcha rather than appending a near-duplicate; delete one that proves wrong. Review gotchas at session start.
- When pointed to existing code, study it and match its patterns exactly. Working code is a better spec than English.
- When testing your own output, do it as a first-time project user would.

## Communication

Default: human-attention-first — judge a reply by what its reader takes away, not what it contains. Open with the conclusion; keep every point the reader needs, compress each, add nothing more. Precision floors: numbers, thresholds, versions, and scoped conditions stated exactly — no widened scope, no dropped figure, no one-sided report of a contested fact. Warnings stay attached to what they qualify, cut last. Deliverables ship bare, no framing prose; an explicit depth request lifts brevity for that reply. Full doctrine: `core-rules/references/communication.md`.

- When the user says "yes," "do it," or "push," execute — don't repeat the plan. While the operator watches, be terse: TodoWrite carries in-flight state, the diff the result — don't narrate what they show.
- An unattended run's final message (overnight, cron, background, any long stretch since the operator last spoke) is their first look at everything: a re-grounding, not a continuation — outcome first, complete sentences, terms spelled out, no shorthand or invented labels. `## Decisions made (L<n>)` and `Follow-ups` blocks are part of it.
- Flag real problems up front, never buried under "here's what I did."

## Autonomy

Trellis ships a **responsibility slider** (L1–L5, default L3) controlling *who answers* interactive gates — user or agent. All gates and quality controls fire at every level; the level changes only the consultation surface. Bright-line guardrails (hard hooks, destructive ops, external messages, secrets, DoD receipts, code-review subagent, untrusted-content boundary) stay mandatory at every level; architectural decisions surface inline mid-turn even at L5. At L4/L5, decisions taken on the user's behalf go to `<project-root>/decisions-log.md` (never touched by `save-context-log`) and render as `## Decisions made (L<n>)`.

Level resolution reads portable project policy from `.trellis.json`, then the active immutable release and declared presets, then the session override; it clamps to the lowest preset `autonomy_ceiling`. Full matrix, guardrails, precedence, and decision-log format: `core-rules/autonomy.md`.

## Loops

Every Trellis loop — operator cron jobs, `orchestrate` fan-outs, `/loop` and `/goal` runs — declares **three ceilings** and **halts on any one**: `max_iterations`, `no_progress_iterations`, `budget_ceiling_usd`. On a trip it hard-stops (never auto-continues) with a structured halt report; unattended loops surface it in their run report. Resolution, progress signals, halt behavior, token↔dollar conversion: `core-rules/loop-safety.md`.

## Advisor

When the `advisor` tool is available (auto-forwards full history; no parameters), prefer the strongest reasoning model offered. Call it when a second opinion would change your next move: before locking an interpretation expensive to unwind, when an approach stops converging, before declaring done on a long or unattended run. Skip short reactive turns where fresh tool output dictates the next action.

## Hooks

Two tiers — **fast-local** (every turn) and **heavy-gated** (wrap-up) — plus a **git-boundary** tier whose `pre-push` blocks direct push to `main`. Tier contents, per-hook names, harness paths, event wiring: `hooks.md`.

## Skills

When a project is explicitly attached, release-owned skills are expanded as manifest-owned local leaves in the native Claude Code, Codex, and OMP surfaces. Each skill's `SKILL.md` is its spec.

**Path-scoping (project-local skills only).** If a non-canonical skill carries a `scope.json` beside its `SKILL.md`, read it before auto-mentioning: auto-invoke only when the session cwd or the turn's changed files match a glob in `paths[]`. Explicit `/skill <name>` always works. Schema + rationale: `core-rules/inheritance.md` § "Skill path-scoping".

## Commands

When a project is explicitly attached, release-owned slash commands are manifest-owned local leaves in the native Claude Code, Codex, and OMP surfaces. Commands are explicit user invocations (`/<name> <args>`); skills are what the agent dispatches from context. The release-owned set is under `core-rules/commands/`. Reach for `/explore` before touching an unfamiliar subsystem — it maps one to a transient note in a read-only subagent, cheaper than inline.

<!-- BEGIN PRIMER SECTION -->

## Feature primers

Where an attached project renders `<project-root>/.claude/primers/INDEX.md`, primers are live and the `inject-primer-index` hook injects INDEX at session start. **When the task names a feature, directory, or subsystem listed in INDEX, read that primer before exploring code** — loading is not optional. On any drift flag other than FRESH or WARM, say so before relying on it and offer `/primer-refresh`. Authoring, staleness, storage, commands: `core-rules/primers.md`.

<!-- END PRIMER SECTION -->

## Project-local policy and records

- `.trellis.json` — the sole Trellis-controlled tracked project state; portable identity and policy only. Local attachment state is never added to it.
- `CLAUDE.md` — project-specific rules only. No duplication of the parent layer. Target <5 KB.
- `gotchas.md` — lessons logged as they happen.
- `context-log.md` — written by the `save-context-log` hook at the project root, auto-injected at session start and after compaction. Never edit by hand (mechanism: `core-rules/hooks.md`).

## Documentation

- Architecture decisions go in numbered, sequential ADRs (`docs/adr/NNNN-<slug>.md`: context, decision, consequences, status). Where a project already captures these in tech-spec docs, follow it.

## Control plane

Explicit attachment stores machine configuration, fleet inventory, immutable releases, ownership records, and recovery journals under private `TRELLIS_HOME` (default `~/.trellis`). Resolve a project's fleet and runtime from that local state through the installed `trellis` launcher — `registry list`, `doctor`, `show-config`, scoped with `--fleet`/`--project`. There is no tracked fleet inventory: the machine-local registry is the only membership authority, rebuildable from `.trellis.json` manifests plus operator-selected discovery roots. A failed row is reported, never deleted, repaired, or replaced by a guessed path; row classes and exit semantics are in `engineering-process.md`. The source checkout is a management/publication checkout, never attached-runtime authority. Read `engineering-process.md` for the operator process, `docs/MIGRATING-LOCAL-FLEETS.md` for migration, and `docs/UPGRADING.md` for release transitions. Target for this file: **≤19,800 bytes and ≤200 lines** (`wc -c`, `wc -l`; the line budget is what `trellis-doctor` reports, warn-class). The byte figure is a high-water mark — re-set from 19,000 for the four rules added since, and only when a rule earns its place, never quietly exceeded. Anything situational goes in a sibling reference — a target nobody can check is a target nobody keeps.

## Inheritance

Portable attachment, manifest-owned leaves, silent-drop handling, three-harness layout, local settings ownership, Git common-directory state, worktree diagnosis, and recovery are defined in `core-rules/inheritance.md`. A raw contributor clone remains inert; attached projects resolve only through their verified immutable runtime anchor.
