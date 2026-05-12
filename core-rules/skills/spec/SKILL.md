---
name: spec
description: Turn a vague product or engineering request into a written feature specification with problem statement, success criteria, non-goals, and constraints. Use BEFORE writing any code when the request meets at least one of (a) three or more acceptance criteria, (b) touches more than two files of net-new behaviour, (c) is cross-cutting or load-bearing. Output is `specs/<NNN>-<slug>/spec.md` on a `feature/<slug>` branch. The skill never writes implementation code — that is the `plan` skill's job, downstream.
---

# spec

Opt-in companion to Trellis's surgical-default discipline. Surgical scope is right for bug fixes, refactors, and tightly-scoped changes. Greenfield features and behaviour that crosses multiple files benefit from spelling out *what* and *why* before *how*. This skill produces that artifact.

The spec is the load-bearing input to the `plan` skill (technical design) and then `tasks` (work breakdown). Together they form the spec → plan → tasks pipeline borrowed from spec-kit. The triad is **always opt-in**; the agent or operator invokes them deliberately. Day-to-day surgical changes do not use them.

## When to use

- A new feature is being requested and the path to "done" is not obvious from the prompt alone.
- The request lists three or more acceptance criteria.
- The change introduces net-new behaviour across more than two files.
- The change is cross-cutting (touches auth, billing, infra, shared UI primitives) or otherwise load-bearing.
- An operator says "spec this out before you build it" or asks for a write-up.

## When NOT to use

- Bug fixes with a clear reproduction. Trellis's surgical default applies; jump straight to a failing test → fix.
- Refactors with no behaviour change. Use a brief PR description instead.
- Single-file additions where the design is one paragraph. Document inline; don't spawn a spec.
- Operational tasks (add a script, bump a dep, update a config). The diff IS the spec.

If you're unsure, ask the operator: "Should I spec this first or jump straight to implementation?" Don't unilaterally spawn a `specs/` directory.

## How to use

0. **(Recommended) Run the `clarify` skill first** when the request is vague, contradictory, or leaves any of the five canonical questions (intent, users, success metric, edge cases, rollback plan) unresolved. Clarify writes `clarify.md` beside the (template) spec.md; the spec skill reads it before filling the real content. The pipeline stays opt-in — if the operator has handed you a tight, well-shaped request, skip clarify and go straight to step 1.
1. **Pick a slug.** Kebab-case, descriptive, ≤40 chars. Examples: `quote-checkout`, `webhook-replay`, `mobile-offline-cache`. Avoid generic slugs like `new-feature` or `improvements`.
2. **Run `scripts/new-feature.sh <slug>`.** The script:
   - Refuses to run if the working tree is dirty or the current branch isn't `main`/`master`.
   - Picks the next zero-padded number by scanning existing `specs/` subdirs.
   - Creates `specs/NNN-<slug>/`.
   - Creates and checks out branch `feature/<slug>`.
   - Copies `references/spec-template.md` to `specs/NNN-<slug>/spec.md`.
   - Prints the file path for the operator (or `$EDITOR` if set + interactive).
3. **Fill in the template.** If `specs/<NNN>-<slug>/clarify.md` exists from a prior `clarify` invocation, read it first — operator's voice in clarify is the authoritative input to the spec; quote from it where helpful, don't drift from it. Sections, in order: Problem statement, Users + scenario, Success criteria (testable), Non-goals, Constraints, Open questions, Risks, Out of scope (intentional). The skill must complete every section; "TBD" is acceptable for items the operator cannot pin down yet, but the section header stays.
4. **Stop after writing.** Do not start coding. Do not invoke the `plan` skill in the same turn unless the operator asks. The spec is reviewed before the plan begins.

## Output contract

Every spec ships with:

- `specs/<NNN>-<slug>/spec.md` — the structured spec document.
- The current branch is `feature/<slug>`.

That's the entire deliverable for this skill. Implementation, schema, file layout decisions belong in `plan.md` (created by the `plan` skill, next).

## Authoring rules

- **Problem statement first, solution last.** If the spec opens with "implement X using Y", you've skipped what.
- **Success criteria are testable.** "Faster checkout" is not a criterion. "p95 checkout-to-confirmation latency drops below 600ms on staging fixtures" is.
- **Non-goals are explicit.** Most spec bloat comes from creep. Spell out what this feature is NOT solving.
- **Open questions are surfaced, not papered over.** If you don't know whether the cron runs nightly or hourly, write "Open question: cadence?" Don't pick silently.
- **Specs are reviewable in 5 minutes.** If yours runs longer than two screens, you're conflating spec with plan.

## Relationship to other artifacts

- `gotchas.md` — pre-existing project lessons. Read before writing the spec; many "open questions" are already answered in here.
- `docs/adr/*.md` — architectural decisions that constrain this spec. Cite by filename if relevant.
- `engineering-process.md` — Trellis's narrative manual. The spec doesn't restate process; it inherits it.
- `plan.md` (next phase, separate skill) — file-by-file technical approach. Created from the spec.
- `tasks.md` (third phase, separate skill) — work breakdown with explicit checkboxes. Created from the plan.
- `TodoWrite` (ephemeral, in-session) — mirrors `tasks.md`'s in-flight slice. Source of truth is `tasks.md`; TodoWrite is the in-flight view.

## Boundaries

- **Read-only against the rest of the repo.** The skill creates one directory (`specs/<NNN>-<slug>/`) and copies one template into it. It does not edit existing code, configs, or docs.
- **Branch is mandatory.** The skill refuses to run on `main`/`master`. If the operator wants to spec into the current feature branch (e.g., a sub-feature of work already in flight), they pass `--no-branch` to the script — the script then only creates the directory.
- **Never overwrites.** If `specs/<NNN>-<slug>/spec.md` already exists, the script aborts. The operator picks a new slug or removes the existing one explicitly.

## Sensible failure modes

- Working tree is dirty → abort with the file list. The spec should land on a clean branch.
- Not in a git repo → abort with a clear error.
- `specs/` exists but isn't a directory → abort.
- `$EDITOR` is unset → print the path, don't try to launch anything.
