---
name: tasks
description: Turn an accepted technical plan (`specs/<NNN>-<slug>/plan.md`) into a check-boxed work breakdown — each task ≤4 hours of focused work, dependencies marked, mapped back to spec success criteria — and write it to `specs/<NNN>-<slug>/tasks.md` on the same branch. Use AFTER `spec` and `plan` are written and reviewed; this is the last step before implementation begins. `tasks.md` is the human-facing source of truth for the feature; `TodoWrite` is the ephemeral in-flight mirror.
---

# tasks

Final step of the spec → plan → tasks triad. Reads the plan, returns a checkboxed work breakdown. Output is one file: `specs/<NNN>-<slug>/tasks.md`. Implementation begins after this skill returns — the operator (or you) walks the list, ticking boxes as each task completes.

## When to use

- `spec.md` and `plan.md` both exist in the current branch's `specs/<NNN>-<slug>/`.
- The plan is reviewed (not labelled `status: draft`).
- The feature is non-trivial enough that the operator (or you, when running solo) benefits from explicit task atoms rather than ad-hoc TodoWrite.

## When NOT to use

- No plan.md exists. Run `plan` first.
- Plan is still draft. Tasks built against a draft plan get thrown away.
- Implementation is one file and one commit. A PR description is the right artifact, not a tasks.md.
- The operator wants a TodoWrite list, not a committed file. TodoWrite is fine for those; this skill produces the committed artifact.

## Input contract

- `specs/<NNN>-<slug>/plan.md` — non-empty, reviewed.
- Current branch = `feature/<slug>`.

If either is missing or mismatched, stop and tell the operator what to fix.

## Output contract

One new file: `specs/<NNN>-<slug>/tasks.md`. No edits to spec.md, plan.md, or any other file.

## How to use

1. **Re-read the plan.** Especially section 4 (file-by-file change list) and section 6 (test strategy).
2. **Decompose into atomic tasks.** Each task ≤4 hours of focused work for a competent engineer who has read the plan. If a "task" is "implement the feature", you haven't decomposed yet.
3. **Mark dependencies.** Some tasks block others (migration must run before code that reads the new column). Use `Depends: T2` notation in the task line.
   - **Name the slicing strategy that drives the order.** Beyond ≤4h atoms, decide *how* the work is sliced — **vertical** (a thin end-to-end slice through every layer, shippable on its own), **contract-first** (define and lock the interface/schema, then fill implementations behind it — lets dependent work start in parallel), or **risk-first** (attack the most uncertain / most-likely-to-fail unit first, so a dead end surfaces while it's cheap). Pick per plan: risk-first when there's a big unknown, contract-first when parallel tasks share an interface, vertical by default. (Folded from the `incremental-implementation` pattern.)
4. **Map back to success criteria.** Every spec success criterion must be referenced by at least one task. If not, either the plan missed it or the task list missed it — surface and fix.
5. **Order tasks by dependency, not preference.** Reviewer should be able to follow the list top-to-bottom and end up with a working feature.
6. **Stop after writing.** Implementation is not part of this skill's output.

## The TodoWrite relationship (read this carefully)

`tasks.md` and `TodoWrite` overlap. The contract:

- **`tasks.md` is the source of truth.** Committed to the repo, reviewed in the PR, archived alongside spec + plan. It outlives the session.
- **`TodoWrite` is the in-flight mirror.** When you sit down to work the list, you pull (typically) the next 3–5 unchecked tasks into TodoWrite as the active slice. As you finish each, you tick the box in tasks.md AND mark the TodoWrite item completed.
- **Don't duplicate the full list.** Putting every `tasks.md` item into TodoWrite up front bloats the context window. Slice it.
- **If tasks.md and TodoWrite disagree, tasks.md wins.** It's the document of record; TodoWrite is a working surface.

The operator may also add ad-hoc TodoWrite items that aren't in tasks.md (one-off fixes, follow-ups discovered mid-implementation). Those don't migrate back to tasks.md unless they grow into substantive work the spec should have covered.

## Authoring rules

- **Each task is a sentence in imperative voice.** "Add `replayOrder()` to `src/services/orders/replay.ts`." Not "Implement order replay".
- **Each task names a file.** Vague tasks like "wire it up" or "polish" are not tasks.
- **Hour estimate goes after the title in `(~Xh)`.** Used as a sanity check on decomposition. >4h → split.
- **Dependencies are explicit.** `Depends: T2, T5`. Cycles are illegal.
- **Coverage column maps to a spec criterion.** If no criterion covers a task, that's a planning gap — note it and surface.
- **Tasks aren't subtasks.** No nested checkboxes. If you're tempted to nest, split into two top-level tasks.

## Boundaries

- **One file written.** `specs/<NNN>-<slug>/tasks.md`. No code, no edits to spec/plan.
- **Refuse to overwrite an existing tasks.md.** Operator must remove explicitly; the skill doesn't silently rewrite.
- **Don't start implementation.** Even if the tasks look simple. The skill is a writer, not a builder.

## Sensible failure modes

- `plan.md` missing → tell operator to run `plan` first.
- `plan.md` exists but is empty / template-only → stop and surface.
- A task references a file the plan didn't list → that's a planning gap. Stop and surface to the operator; don't paper over.
- A spec success criterion has no covering task → surface and ask whether the spec or the tasks need updating.
