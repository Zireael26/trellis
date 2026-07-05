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

## Relationship to other surfaces

- `verify-panel` recipe — the parallel, two-model realization of one DOUBT pass.
- `advisor` — a single stronger-reviewer DOUBT pass over your whole transcript.
- `code-review-subagent` — the automated DOUBT pass over an edit-heavy diff.
- `source-driven-development` — DOUBT specialized to framework claims (verify
  against official docs).

Doubt-driven-development is the *doctrine*; those are its mechanisms.
