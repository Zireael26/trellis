---
name: plan
description: Turn an accepted feature spec (`specs/<NNN>-<slug>/spec.md`) into a technical design — file-by-file approach, schema/API shape if any, risks, sequencing — and write it to `specs/<NNN>-<slug>/plan.md` on the same branch. Use AFTER `spec` has been written and reviewed, BEFORE the `tasks` skill, and never as a substitute for `spec`. The skill never writes implementation code; it produces the design document only.
---

# plan

Middle step of the spec → plan → tasks triad. Reads the spec, returns a written design. Output is one file: `specs/<NNN>-<slug>/plan.md`. Implementation does not start here — that's `tasks` (next) plus actual coding.

## When to use

- A spec.md exists in the current branch's `specs/<NNN>-<slug>/` directory and has been reviewed.
- The operator (or you, if appropriate) has answered the spec's open questions or explicitly punted them.
- The feature is non-trivial enough that the file-by-file approach is not obvious from the spec.

## When NOT to use

- No spec.md exists. Run `spec` first.
- Spec is still labelled `status: draft` and the reviewer hasn't signed off. The plan would be designing against a moving target.
- A spec exists but it's a one-line one-file change. Skip plan + tasks; just open the PR.
- The plan is being asked for as a substitute for the spec ("can you plan how we'd build a thing that does X?"). That's spec territory. Run `spec` first.

## Input contract

The skill expects to find:

- `specs/<NNN>-<slug>/spec.md` — non-empty, with the canonical 8 sections from the spec template.
- The current branch is `feature/<slug>` (the spec skill enforces this; `plan` should verify it before writing).

If the input contract fails, the skill stops and tells the operator what's missing.

## Output contract

One new file: `specs/<NNN>-<slug>/plan.md`. The skill must not modify `spec.md` and must not touch any other file.

## How to use

1. **Re-read the spec.** Including all eight sections. If any section says "TBD" or lists an unanswered open question, stop and surface it. Don't silently invent answers.
2. **Read the project's `CLAUDE.md`, `gotchas.md`, and recent `docs/adr/*.md`.** These constrain the plan; cite by filename when a constraint applies.
3. **Read every file the spec hints at.** If the spec mentions auth, read `src/auth/*`. If it mentions billing, read `src/billing/*`. The plan is grounded in current code, not speculation.
4. **Draft `plan.md`** using `references/plan-template.md` as the structure: technical approach, data model + schema changes, API surface, file-by-file change list, sequencing + dependencies, test strategy, rollout plan, risks + mitigations, decisions log.
5. **Cite specifics.** "Add a new endpoint" is not a plan. "Add `POST /api/orders/replay` in `src/api/orders/replay.ts`, route handler delegates to `replayOrder()` in `src/services/orders/replay.ts`, both new" is a plan.
6. **Surface trade-offs.** When two approaches are viable, name both, pick one, justify in the decisions-log section. Don't paper over the choice.
7. **Stop after writing.** The plan is reviewed before tasks are generated. Don't invoke `tasks` in the same turn unless the operator asks.

## Authoring rules

- **Plan inherits the spec's intent.** Don't widen scope. If you find a tempting adjacent fix, list it under "Out of scope (deferred)" and move on.
- **Each file in the change list has a one-line purpose.** Reviewer can scan it in 60 seconds.
- **Schema/API shapes are concrete.** Column types named. Field types named. Status codes named. No "we'll figure it out at implementation".
- **Sequencing matters.** Order the change list so each step leaves the tree in a buildable state. If that's impossible, name the broken-window step and the rollback path.
- **Decisions log is brief and absolute.** "Picked Postgres JSONB column over a join table. Why: writes are 10x reads, denormalised wins. Rejected: separate table (more migrations, no perf gain)." Three sentences per decision.

## Relationship to other artifacts

- `spec.md` — the *what* + *why*. Plan reads it; never edits it.
- `tasks.md` (next phase, separate skill) — work breakdown derived from this plan.
- `gotchas.md` — pre-existing project lessons. Read before planning; cite when they constrain a decision.
- `docs/adr/*.md` — architectural decisions. Cite by filename when relevant; if your plan contradicts an ADR, stop and ask the operator before writing.
- `engineering-process.md` — Trellis's narrative manual. Plan inherits process; don't restate.

## Boundaries

- **One file written.** `specs/<NNN>-<slug>/plan.md`. Nothing else. No code, no config, no test scaffolding.
- **Read-only against the rest of the tree.** Read whatever you need; modify nothing except the plan file itself.
- **No `tasks.md` here.** That belongs to the `tasks` skill, after this plan is reviewed.
- **Refuse to overwrite an existing plan.** If `plan.md` already exists, the operator must explicitly remove it. Plans don't get silently rewritten — they get revised in a follow-up commit.

## Sensible failure modes

- `specs/` directory missing → tell the operator to run the `spec` skill first.
- `specs/<NNN>-<slug>/spec.md` missing → same.
- Spec exists but has unanswered open questions → stop, list them, ask.
- Current branch is not `feature/<slug>` → warn and ask; don't silently switch branches.
- Two specs match the slug heuristic → stop and ask which one.
