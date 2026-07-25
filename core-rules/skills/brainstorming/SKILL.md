---
name: brainstorming
description: The ideation front-door. Use when a request describes new or changed behavior — a feature, a component, added functionality — and no design or task list exists yet, or when two valid readings of the request exist and picking silently would be a guess. Sizes the work, runs only as much design dialogue as the weight warrants, and routes to the right downstream skill instead of implementing inline. Terminal handoffs are by weight — heavyweight routes to `clarify`/`spec`, lightweight routes to `docs/plans/<topic>.md` then `execute`, surgical goes straight to `execute` (or just make the change).
---

# brainstorming

The front-door for turning an idea into something a builder can act on. It does **not** implement. Its job is to size the work, run only as much design dialogue as the work warrants, leave a durable design artifact, and hand off — by weight — to an installed downstream skill. It is the entry the spine routes through; the authoritative rules live in `engineering-process.md`, `CLAUDE.md`, and the skills this doc hands off to. When in doubt, those win.

The discipline this skill carries is **design-before-implementation**: for anything beyond a surgical fix, a design is presented and approved before any implementation action. The weight router decides *how much* design — not *whether* — for lightweight and heavyweight work. Surgical work is the one deliberate exception (see below).

## When to use

- A request describes new or changed behavior — a feature, a component, added functionality — and no design or task list exists yet.
- You can already feel the request splits into more than one independent piece and you need to decompose before designing.
- Two valid readings of the request exist and picking silently would be a guess.

## When NOT to use

- **A one-line surgical fix that never went through the pipeline.** Just make the change (with a receipt) — that is the SURGICAL route below, and it is the only path that legitimately skips a design.
- **A design or task list already exists.** If `specs/<NNN>-<slug>/` is filled or `docs/plans/<topic>.md` is written, you are past ideation — go straight to `execute` (or resume the spec-kit pipeline).
- **Crossing the merge boundary.** That is the `process-gate` skill, not this one.

## The weight router

Size the request first, then take exactly one route. The three weights and their terminal handoffs:

| Weight | What it looks like | Route | Terminal handoff |
|---|---|---|---|
| **SURGICAL** | A tiny, obvious change with one clear correct shape — a one-line fix, a copy tweak, a config flip. No unexamined design question. | Skip ideation. | Make the change directly (with a receipt), or hand to `execute` if there is already a checkbox for it. |
| **LIGHTWEIGHT** | A self-contained feature or change you can design in a short dialogue — one subsystem, a handful of files, no cross-cutting risk. | Run a short design dialogue, then author `docs/plans/<topic>.md`. | `execute` — it builds the plan checkbox by checkbox. |
| **HEAVYWEIGHT** | Cross-cutting, load-bearing, or multi-subsystem work; vague or contradictory intent; three or more acceptance criteria. | Hand the ideation to the spec-kit pipeline; do not design inline. | `clarify` → `spec` (the pipeline owns the full design, review, plan, and tasks). |

This mirrors the two tracks named in `inheritance.md`: the lightweight track `brainstorming` → `docs/plans` → `execute`, and the heavyweight spec-kit pipeline `clarify` → `spec` → `plan` → `tasks` → `analyze` → `execute`. Both converge on the single canonical builder, `execute`.

### Why surgical is the only design-skip

Most ideation skills assert "every change needs a design, no exceptions." This one does not — the design-gate binds **lightweight and heavyweight** work, and **surgical is the narrow, deliberate exception**. The boundary is the same one `execute` draws in its own "When NOT to use": *a one-line surgical fix that never went through the pipeline — just make the change with a receipt.* The two skills must agree on what "surgical" means, so anchor it there.

The risk this guards against runs the other way too: when a change *feels* surgical but actually hides an unexamined assumption — a config flip with a blast radius, a "one-line" change that changes a contract — it is not surgical. It is lightweight, and it gets a short design. Route on whether an unexamined design question exists, not on line count.

**Interaction with the mandatory-pipeline gate (spec 006).** The design-gate above is always-on doctrine; the 006 gate is a complementary, config-gated, default-off layer that keys on **size**. Its one effect on routing: above the floor a `docs/plans/<topic>.md` doc no longer satisfies the gate, so a lightweight *feature* escalates to the triad and genuinely *mechanical* work takes `/surgical` — never `/surgical` as a dodge on real feature work. Below the floor, or with the knob off, the three-track routing is unchanged. Canonical: `engineering-process.md` §14.7.

## The design dialogue (lightweight)

For lightweight work, run a short, collaborative design pass before writing the plan. Keep it proportional — a few sentences for a straightforward change, more for a nuanced one.

1. **Explore context first.** Read the relevant files, docs, and recent commits before proposing anything. Follow existing patterns; don't propose unrelated refactoring.
2. **Ask clarifying questions one at a time.** Multiple choice when it fits, open-ended when it doesn't. Focus on purpose, constraints, and success criteria. One question per message — break a broad topic into several.
3. **Propose 2-3 approaches with trade-offs.** Lead with your recommendation and the reasoning behind it. When the obvious approaches converge on one shape, deliberately generate a divergent one before settling — invert an assumption, remove the hardest constraint, or reframe for a different user — then converge back to a recommendation.

   **Prototype before you argue about it — when the question is visual or interactive.** For layout, flow, or interaction questions, build 2–3 low-fidelity HTML mockups with fake data rather than describing them; prose comparison of layouts is the weakest form of the question. Keep fidelity deliberately low while exploring — structure, not polish. Show them together, let the operator pick one or ask for a remix of two, then converge. For non-visual work (a data model, a protocol, a build step) skip this — the prose trade-off is the right instrument.
4. **Present the design and get approval.** Scale each section to its complexity. Cover the parts that matter — components, data flow, error handling, testing — and confirm each before moving on. Be ready to go back and clarify.
5. **Design for isolation and clarity, and cut ruthlessly.** YAGNI applies to every design: drop anything the stated problem does not require. Break the work into units that each have one clear purpose, communicate through well-defined interfaces, and can be understood and tested on their own. For each unit you should be able to say what it does, how it is used, and what it depends on. If a unit's internals can't change without breaking its consumers, the boundary needs work — smaller, well-bounded units are also easier to build reliably.

Only after the user approves the design do you author `docs/plans/<topic>.md` and hand to `execute`.

### Authoring the plan

- Write the approved design as a task-by-task plan at `docs/plans/<topic>.md` in the shape `execute` drives: `## Task N: <title>` section headers, each with `- [ ] **Step N: <label>**` checkbox steps and a per-task Done/acceptance-criteria list. This is `execute`'s Dialect-B plan contract — see `execute`'s `references/loop.md` (Shape 3) for the authoritative `(section, locator)` derivation, so the plan drives `execute`'s loop rather than only `tick.sh`'s substring fallback. (User preferences for plan location override this default.)
- Then hand off: invoke the `execute` skill. `execute` is the next and only step — do not implement inline, and do not invoke any other implementation skill.

## The spec-kit handoff (heavyweight)

For heavyweight work, do **not** run the design inline and do **not** write the plan yourself. Hand the ideation to the pipeline:

- Invoke `clarify` to front-load the five canonical intent questions, then `spec` to formalize the design. The pipeline (`clarify` → `spec` → `plan` → `tasks` → `analyze`) owns the full design, its review, the technical plan, and the task breakdown — and it terminates in `execute`.
- brainstorming's job at this weight is the routing decision and the decomposition (below), not the spec itself.

### Decomposition

If the request is too large for a single spec — it names multiple independent subsystems — flag that immediately. Don't spend design questions refining a project that needs to be split first. Help the user name the independent pieces, how they relate, and the order to build them. Then route the **first** piece through the appropriate weight; each piece gets its own design → handoff cycle.

## The ephemeral brainstorm lane (`docs/brainstorm/`)

Scratch thinking that isn't yet a durable design has a home: `docs/brainstorm/<topic>.md`, a **per-project** lane. Use it for exploration you want committed (so it survives across sessions and is visible to collaborators) but that is explicitly **not** a spec or a plan — it is safe-to-delete scratch.

Mark every such file as ephemeral with a banner as the first line of the file:

```
> EPHEMERAL BRAINSTORM SCRATCH — safe to delete. Not a spec or a plan. Durable design lives in docs/specs/ or docs/plans/.
```

A throwaway HTML prototype under `docs/brainstorm/<topic>/` carries the same text as an HTML comment on its first line, since a markdown blockquote is not valid there.

The banner is what distinguishes scratch from a durable artifact: a reader (or an audit) can tell at a glance that the file is disposable. When the thinking matures into something a builder acts on, promote it — author the real `docs/plans/<topic>.md` (lightweight) or run the spec-kit pipeline (heavyweight); the brainstorm file can then be deleted. Do **not** route `execute` at a `docs/brainstorm/` file — it is not a task list.

This is a convention, not a scaffold. Do not create the `docs/brainstorm/` directory here; each project creates it on first use.

## Boundaries

- **Never implements production code.** brainstorming writes a `docs/plans/<topic>.md` plan (lightweight), `docs/brainstorm/<topic>.md` scratch, and — for UI-visible or interaction-shaped work — **throwaway prototypes under `docs/brainstorm/<topic>/`**. A prototype is a self-contained HTML file with fake data, built to test layout and flow, wired to nothing. It carries the same EPHEMERAL marker as brainstorm scratch, as an HTML comment on its first line, and is deleted when the design is approved. It is not the implementation and never becomes it — `execute` is never routed at it. It writes no spec — that is `spec`'s job, and the build is `execute`'s.
- **Routes to installed skills only.** The terminal handoff is, by weight, `clarify`/`spec` (heavyweight) or `execute` (lightweight/surgical). There is no other terminal — do not hand off to any uninstalled or harness-specific skill.
- **Design-gate binds lightweight and heavyweight.** No implementation action — no production code, no scaffold of the real thing, no invoking a builder — until a design has been presented and approved, for everything except the surgical exception. Throwaway prototypes under `docs/brainstorm/<topic>/` are part of the design pass, not an implementation action: they exist to make the design arguable and are deleted when it is approved. Surgical work skips the design by definition; everything else does not.
- **Harness-neutral.** Same behavior under every harness. No harness-specific verbs, no harness-specific skill names — only the canonical skills `clarify`, `spec`, and `execute`.
- **Right-size the route.** The cheapest correct route that answers the open design question wins.
