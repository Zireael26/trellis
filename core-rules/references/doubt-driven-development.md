# doubt-driven-development — a named verification primitive

A bounded, adversarial self-check applied to a claim before you act on it or
ship it. Consolidates the adversarial-review spirit that was scattered across
`advisor` usage, the `orchestrate` adversarial-verify pattern, and the
`code-review-subagent` into one named loop you can invoke by hand or reference
from a skill. Folded in from the `addyosmani/agent-skills`
`doubt-driven-development` skill (2026-07), adapted to Trellis's cross-harness
setup.

## The loop — CLAIM → EXTRACT → DOUBT → RECONCILE → STOP

1. **CLAIM.** State the assertion you are about to rely on, in one sentence.
   "This regex validates the input." "The migration is backward-compatible."
   "The finding is a real bug." A claim you cannot state crisply is not ready to
   doubt — sharpen it first.
2. **EXTRACT.** Pull out the *artifact* the claim rests on — the actual code, the
   actual diff, the actual output, the actual doc line. **Pass the artifact, not
   the claim.** A downstream check that receives "it validates the input" can
   only agree; one that receives the regex and three inputs can disprove.
3. **DOUBT.** Try to *refute* the claim against the artifact. Default to guilty:
   assume it is wrong and look for the input, state, or edge that breaks it. If a
   second model is available, the doubt pass goes to **the other model**
   (cross-model diversity beats self-redundancy — see `docs/codex-routing.md` §2
   and the `verify-panel` recipe).
4. **RECONCILE.** Fold what the doubt found back into the claim: strengthen it,
   scope it down, or drop it. Record the reconciliation, not just the verdict.
5. **STOP.** **Bounded to 3 cycles.** If the claim is not settled after three
   DOUBT→RECONCILE passes, escalate to a human rather than looping — an
   unresolved claim after three honest attempts is a signal, not a reason to
   spin. (Honors the agent-loop-safety discipline: every loop halts.)

## When to use

- Before acting on a **hard / `critical`** finding (pair it with `verify-panel`
  for the cross-model leg).
- Before shipping a claim whose being-wrong is expensive (a security assertion, a
  "this is backward-compatible", a "the tests prove X").
- Inside `analyze` / `security-gate` where a verdict must survive an adversary.

Not for routine low-stakes work — three refutation cycles on a typo fix is
waste. Reserve it for claims that carry cost.

## Why "pass the artifact, not the claim"

This is the load-bearing rule. The failure mode of self-review is that the
reviewer re-reads the *conclusion* and nods. Handing the doubt pass the raw
artifact (diff, output, input/output pair, doc line) forces it to re-derive the
conclusion and gives it something to break. It is also what makes the cross-model
handoff work: the other model gets evidence, not your framing.

## Doubt handles wrong answers; unknowns need a different pass

DDD checks a claim you can *state*. It cannot surface what you never thought to
claim. The framing that separates the two: your instructions are the **map**, the
real constraints are the **territory**, and the gap between them is where an
agent has to guess.

| | you know it | you don't |
|---|---|---|
| **you'd write it down** | known knowns — put them in the prompt | known unknowns — ask, or go read |
| **you wouldn't** | unknown knowns — obvious to you, absent from the prompt, recognized instantly when shown | unknown unknowns — the expensive ones |

DDD covers the left column. The passes below cover the right, and they are
cheapest *before* the work rather than after it.

- **Blind spot pass** (unknown unknowns). Before starting in an unfamiliar
  domain, ask for one explicitly: "I'm doing X and know little about Y — do a
  blind spot pass on my relevant unknown unknowns." Disclose your actual
  expertise level; it changes the answer.
- **Interview, ordered by architectural impact** (known unknowns). When the agent
  questions you, the questions worth asking are the ones **where your answer
  would change the architecture** — data models, type interfaces, UX flows.
  Mechanical detail can be decided in-flight. `clarify` and `brainstorming` are
  the Trellis surfaces; this is the ordering rule they should apply.
- **Reference over description** (unknown knowns). A working implementation is a
  better spec than English — "this crate has the exact semantics I want; read it
  and reimplement in our language" beats a paragraph describing the semantics.
  This is the same reflex the constitution carries as "working code is a better
  spec than English"; the addition is that it also surfaces context you would
  never have thought to write down. Distinct from `source-driven-development`,
  which verifies claims *about* a dependency rather than borrowing its shape.
- **Implementation notes, during the work.** For any run long enough to drift
  from its plan, keep a temporary `implementation-notes.md` — untracked, at the
  repo root of the active checkout, deleted once folded — logging each
  deviation and the conservative choice taken at that fork. It is the cheapest
  possible record of where the map and the territory disagreed — and every entry
  is a claim, which makes it the natural input to the next DDD pass.

**Instructional balance.** Too specific and the agent follows the instruction
even when pivoting is right; too vague and it falls back on generic industry
best practice. Disclose your experience level and your current thinking, and
treat the agent as a thought partner rather than an executor.

## Relationship to other surfaces

- `verify-panel` recipe — the parallel, two-model realization of one DOUBT pass.
- `advisor` — a single stronger-reviewer DOUBT pass over your whole transcript.
- `code-review-subagent` — the automated DOUBT pass over an edit-heavy diff.
- `source-driven-development` — DOUBT specialized to framework claims (verify
  against official docs).

Doubt-driven-development is the *doctrine*; those are its mechanisms.
