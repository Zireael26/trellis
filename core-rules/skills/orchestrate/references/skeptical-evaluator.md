# Reference — the skeptical-evaluator persona + sprint contract

An **opt-in, gated** verify persona for long-running builds, plus the **sprint
contract** that fixes "done" before code is written. Realizes the harness-design
thesis — *planner → generator → skeptical external evaluator* (GAN-inspired) —
on top of machinery Trellis already ships. It **sharpens** adversarial
verification for the hard end; it does **not** replace the always-on
`code-review-subagent`, DoD receipts, or the `verify-panel` recipe.

Source: Anthropic, *"Harness design for long-running apps"* (2026-07),
evaluated via the `ai-dev-trends` digest (2026-07-07, proposal P2).

## The grounded claim

Three findings from the post carry the design:

1. **Agents are bad at self-evaluation.** A generator praises its own mediocre
   work; making the *generator* self-critical is far less tractable than standing
   up a **separate** evaluator tuned to be skeptical. Separation is the lever —
   the same reason Trellis already forbids self-marking (`CLAUDE.md` §
   Definition of done, "you do not self-mark your own homework").
2. **Sprint contracts.** The generator and the evaluator agree on what testable
   "done" looks like **before** code is written — a stronger, adversarially-
   negotiated form of Trellis's existing verifiable-goal-before-code rule.
3. **The evaluator earns its cost only above solo reliability.** Every harness
   component encodes an assumption about what the model can't do; a skeptical
   evaluator is worth its tokens only when the task sits **beyond** what the
   model does reliably in one solo pass. Below that line it is pure overhead —
   the always-on `code-review-subagent` already covers routine turns.

## When to use — the gate

**Optional and gated.** Reach for the skeptical evaluator only when a task
**exceeds solo-model reliability**: a multi-session or long-running build, a
change the model cannot one-shot with confidence, an unattended **L4/L5** run
where no human is mid-loop to catch a generous self-assessment
(`core-rules/autonomy.md`). Below that line — a routine edit-heavy turn — the
default `code-review-subagent` (Stop hook, ≥3 files / ≥200 lines) is the right
tool and the evaluator is pure overhead. When in doubt, do **not** stand it up;
the gate defaults closed. This is the same restraint as surgical-default and the
"start simplest" loop rule (`core-rules/references/loops.md`).

The evaluator is **not** a new hook and adds no always-on surface cost: it is a
persona a recipe or a main-loop verify stage adopts **when the gate opens**, and
is absent otherwise.

When the gate opens, default to ≥2 **isolated** skeptical reviewers, not one.
Each judges the same frozen contract without seeing the other's assessment;
reconcile only after both verdicts return.

## The sprint contract (pre-build handshake)

Before the generator writes code, generator and evaluator agree — in writing —
on the **testable done-criteria** for the unit:

- **Written before code.** The contract is authored up front and frozen; it is
  the fixed bar the evaluator judges against, so it cannot be softened to fit
  whatever the generator produced (the same discipline that keeps
  generate-and-filter honest — `references/patterns.md`).
- **Testable, not qualitative.** Each criterion names an *observable* check — a
  test that goes green, a command whose exit code is 0, a count that reaches
  zero, a receipt that must exist — never "looks good." Prefer quantitative
  checks the evaluator can run over prose it must trust.
- **Per-criterion, not a single verdict.** The contract is a checklist; the
  evaluator returns a verdict **per line**, so a near-miss fails the specific
  criterion it missed rather than dragging a whole unit to a fuzzy "not quite."

The contract is the concrete form of "a verifiable goal before writing code"
(`CLAUDE.md` § Planning); the new part is that a **skeptical second party**
co-signs it up front, rather than the generator setting its own bar.

## The skeptical evaluator persona

A **separate** agent (never the generator) that judges the finished unit against
the sprint contract, with the prompt tuned **skeptical, not generous**:

- **Defaults to "not done."** The burden of proof is on the receipt: a criterion
  is met **only** when the evidence proves it (a cited command + exit code, a
  named test that passed, a diff line). Absent proof, the verdict is *not-done* —
  the inverse of a reviewer that rubber-stamps unless it spots a problem.
- **Judges the contract, nothing else.** It scores each criterion the contract
  named; it does not invent new bars mid-judgement (that would defeat the
  frozen-contract discipline) and does not credit unrequested extras.
- **Returns a structured verdict** the caller acts on — per criterion
  `{criterion, met, evidence, reason}` plus an overall `done` that is true only
  when **every** criterion is met. No partial "done."

The persona is a prompt tuning, so it is **harness-neutral**: any harness that
can dispatch a subagent can run it; where none exists, the main loop runs the
same skeptical judgement inline (the tier-3 degrade in `SKILL.md`), never
collapsing it into the generate step.

Evaluator sign-off is necessary, not sufficient. Pair it with the Definition of
done check that tests must fail when business intent changes (`CLAUDE.md`); do
not accept a green suite as proof of intent.

## How it composes (does not replace)

| Existing machinery | Relationship |
|---|---|
| `code-review-subagent` (Stop hook) | **Always-on floor.** Fires every edit-heavy turn regardless. The skeptical evaluator is an *additional*, gated layer for above-solo tasks — it never turns the hook off. |
| DoD receipts (`CLAUDE.md`) | **The evidence the evaluator demands.** "Defaults to not-done unless the receipt proves it" *is* the receipt rule, enforced by a skeptic instead of trusted. |
| `verify-panel` recipe | **One way to run the persona.** For a hard/`critical` criterion, run the skeptical evaluator as the Claude reviewer inside `verify-panel` to get a cross-model (Claude + Codex) consensus. The panel is the mechanism; the skeptical persona is the prompt it carries. |
| `autonomy.md` L4/L5 | **Where the gate most often opens.** Unattended runs have no human to catch a generous self-assessment, so the skeptical evaluator is the counterweight the slider's bright-line code-review guarantee already reaches for. |

## Loop safety

When a recipe adopts the evaluator as a verify stage, it inherits that recipe's
loop-safety contract (`core-rules/loop-safety.md`) — no new ceilings. A one-shot
evaluation over a contract's criteria is a single barrier:
`no_progress_iterations: null`, other ceilings inherit the resolved baseline. If
run cross-model via `verify-panel`, Codex tokens attribute at
`codex_usd_per_mtok`.

## See also

- `references/verify-panel.md` — the cross-model panel that can carry this persona.
- `references/patterns.md` — adversarial-verification and generate-and-filter, the shapes this sharpens.
- `core-rules/hooks.md` — the `code-review-subagent` floor this layers above.
- `core-rules/autonomy.md` — the L4/L5 bright-line code-review guarantee.
- `core-rules/references/loops.md` — "start simplest"; the same restraint as this gate.
