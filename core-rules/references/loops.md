# loops — which loop to reach for

A selection guide for agent loops. A **loop** is an agent repeating cycles of
work until a real stop condition is met. Trellis already answers *how any loop
halts* — `loop-safety.md` is the canonical halting contract (three ceilings, a
progress-signal catalog, a structured halt report). Pieces of *selection*
guidance are scattered too — verifiable-goal framing (`CLAUDE.md` § Planning),
the subagent-dispatch triggers (`CLAUDE.md` § Context management), the
`orchestrate` pattern catalog. What was missing is a single **unified taxonomy**
that names the loop types and maps each to a Trellis primitive. This file is
that. Consult it when a task looks repetitive, scheduled, goal-shaped, or
unattended.

Adapted from the Claude team's *"Getting started with loops"* (2026-07). Its
mental model is folded in here; its safety advice is not re-authored — Trellis's
halting contract already exceeds it (a dollar ceiling and a no-progress ceiling,
not just a turn cap).

## The four loop types

| Type | Trigger | Stop signal | Use when | Reach for |
|---|---|---|---|---|
| **Turn-based** | a user prompt | self-judged done + DoD receipt | exploring / deciding; one-off work | a normal turn; `stop-verify` enforces the receipt |
| **Goal-based** | a manual real-time prompt | a deterministic exit criterion, or max turns | you know exactly what "done" looks like | the **verifiable-goal pattern** (`/goal` when your harness has it) |
| **Time-based** | a clock interval | cancellation, or external completion (PR merges, queue drains) | recurring work, or interfacing with an external system | `scheduled-tasks/` (Trellis cron, durable) · `/loop` only as a local Claude Code surface |
| **Proactive** | an event or schedule, no human present | each task exits when its goal is met; the routine runs until cancelled | recurring streams of well-defined work (triage, migrations, drift) | `scheduled-tasks/` + `orchestrate` — **+ Component-D only when it writes/opens PRs** |

**Harness-neutral note:** `/goal`, `/loop`, `/schedule` are **Claude Code surfaces** — a Codex reader may not have them, so reach for the *pattern* (a verifiable goal; a durable `scheduled-tasks/` cron), not the command. `scheduled-tasks/`, the `orchestrate` recipes, and the Component-D tier are Trellis's own and work under either harness.

## Per type — the primitive, and where it halts

Every loop below **inherits the halting contract**: declare `max_iterations`,
`no_progress_iterations`, and `budget_ceiling_usd`, halt on any one. Do not
restate ceilings inline — see `loop-safety.md` § "The three ceilings" and pick a
signal from its progress-signal catalog.

- **Turn-based** → just a turn. Stop = you judge it done *and* the Definition-of-Done receipt lands (`stop-verify` blocks a done-claim without one). No ceilings to declare; a turn is one iteration.
- **Goal-based** → the verifiable-goal pattern. Give it a **deterministic** exit criterion — tests passing, a score threshold, a count reaching zero — not a qualitative one, plus a max-turn cap. Where the harness exposes `/goal`, use it (`/goal … stop after N tries`); the portable part is the criterion, not the command. The goal *is* the progress signal.
- **Time-based** → a durable `scheduled-tasks/` entry for cron work (this is the Trellis-owned, cross-harness surface); `/loop` is a local Claude Code convenience, not something to build a durable loop on. Match the interval to how often the input actually changes — an hourly routine over a daily-changing input is wasted spend. Progress signal is usually **work-list drain** or **commit/PR**.
- **Proactive** → the heaviest tier: a schedule that fans out through `orchestrate`. If the loop only **reads** (scheduled audits, digests), that is all it needs. If it **writes** — opens PRs, mutates repos unattended — it runs through **Component-D**, whose every write-capable step stays behind the merge bright-line (opens a PR, never merges). Either way, declare a conservative `budget_ceiling_usd` and **pilot before a large fan-out** (see `orchestrate/SKILL.md`).

## Practices Trellis already enforces (don't re-invent)

The blog's operating advice maps onto machinery Trellis already ships — reference it, don't duplicate it:

- **Verification** ("don't hand back partially verified work") → DoD receipts (`CLAUDE.md` § Definition of done) + `stop-verify`; prefer **quantitative** checks (tests, scores) an agent can *observe*, over qualitative ones.
- **Adversarial review** ("use a fresh second agent") → the `verify-panel` recipe (Claude + Codex consensus) and cross-model review — beyond a single reviewer.
- **Encode the fix for all future iterations** → `gotchas.md` + the `propose-rules` hook + the rule-of-three promotion; a fix that only patches one iteration is half-done.
- **Budget / stop awareness** → the three ceilings; `budget_ceiling_usd` is dollar-native. Watch `/usage`, `/workflows`, and `/goal`'s token readout in-run.

## Start simplest

Not every task needs a loop. Reach for the **simplest primitive that has a real
stop condition**: a turn beats a `/goal` beats a scheduled routine beats a
proactive fan-out. Climb the ladder only when the work genuinely demands it —
the same restraint as surgical-default. A loop with a fuzzy stop condition is
worse than no loop; if you cannot state the stop signal in one line, you are not
ready to loop yet.
