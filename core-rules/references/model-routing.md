# model-routing — which model gets which unit

*Whether* to delegate is decided in `core-rules/CLAUDE.md` § Context management.
*How* a delegated unit reaches a lane is in `core-rules/references/model-lanes.md`.
This file decides **which model** a unit should go to once you have decided to
delegate it. Read it before choosing a `subagent_type`, before assigning a
teammate, and before picking models inside a dynamic workflow.

The short version: the orchestrator holds the large context and delegates
execution; the two frontier lanes are close enough in capability that capability
alone cannot pick between them, so route on properties you can verify and
deliberately mix the rest.

## Why this file exists

Given a free choice between comparable lanes, an orchestrator collapses onto
whichever model it already holds. That is measured behaviour, not a hypothesis,
and it is why the sections below prefer verifiable properties and an explicit
mix requirement over "use the best model for the job". On units where nothing
distinguishes fit, "best fit" is not a decision procedure — it is a preference,
and preference collapses.

## The two workhorses are near-parity

On Artificial Analysis Intelligence Index v4.1 — one methodology, nine
evaluations (GDPval-AA v2, τ³-Banking, Terminal-Bench v2.1, SciCode, Humanity's
Last Exam, GPQA Diamond, CritPt, AA-Omniscience, AA-LCR), all at max effort:

| model | Index | output tok/s | time to first token | $/1M blended |
|---|---|---|---|---|
| Claude Opus 5 | 61 | 53.7 | 65.1s | $3.85 |
| GPT-5.6 Sol | 59 | 66.7 | 145.7s | $4.35 |
| GPT-5.6 Terra | 55 | 142.7 | 153.0s | $2.17 |

Three consequences:

- **Opus 5 and Sol are near-parity.** A two-point gap on a nine-eval composite
  is not a routing signal. Do not reach for one over the other on a general
  belief that it is smarter.
- **Terra is a throughput tier, not a downgrade tier** — roughly 90% of Opus's
  index at about 2.6× its output rate. It used to be gated behind a mandatory
  advisory call before it could mutate anything; that was retired 2026-07-30 for
  **delegated** units, because a blocking round-trip cancels the throughput advantage
  that is the only reason to select Terra, and because the orchestrator's review gate
  already arbitrates the finished diff. Pair it with an advisor when one is available
  and say so when one is not.

  Two limits, from cross-model review of that retirement. The review-gate substitution
  assumes an orchestrator exists above the unit, which is false when Terra is the *main*
  model — so a Terra main loop must be able to reach a Claude-family oracle. And reviewing
  a finished diff cannot undo an irreversible effect, so advice is still required before
  destroying data, writing outside declared paths, or causing externally visible effects.

  Note what the 55-vs-61 index does and does not establish. It is a *capability* composite
  at max effort; `gpt-terra` runs at `xhigh`, and no local evidence bears on Terra safety
  at all — `audits/2026-07-30-model-routing-baseline.md` records zero Terra selections in
  the measured window. The ratio justifies routing bulk generation to Terra. It does not
  establish that a pre-mutation check was redundant, because selecting the wrong workspace
  or issuing a destructive command is not the kind of error a nine-eval capability score
  predicts. Treat the retirement as a throughput decision with a named residual risk.
- **Time-to-first-token inverts the speed story.** Opus begins responding in
  about a third the time either GPT model takes, while Terra finishes fastest.
  Long sustained generation favours Terra; short interactive turns favour Opus.
  "Fast" is a property of the task shape, not of the model.

Numbers above are max-effort published figures, quoted for *relative* standing.
They are not the configuration we run — see § Effort.

## Context is the asymmetry that structures everything

The GPT lane is capped at **272,000 tokens** for the whole request including
output. The Claude lane reaches **1,000,000** on the `[1m]` variants. That is
the reason the orchestrator seat is Claude: it must hold the entire task surface
while the work happens elsewhere.

It is also a hard routing rule rather than a preference. A unit that must *hold*
more than roughly 200K of surface cannot go to the GPT lane at all — not because
the model is weaker, but because the request will not fit. Below that ceiling
both lanes are eligible.

Treat the ceiling as a property of the lane we operate, not a claim about the
model's maximum. Vendor and aggregator pages may quote a larger window; what
governs is what the router enforces.

## Route in three stages

Family first, profile second. That order matters: an earlier draft consulted a
per-shape table *before* allocating family, which meant the table decided the lane
for most units and the mix rule below could never fire — or fired and contradicted
it. Cross-model review caught that. Family is decided in stage 2; nothing before it
may name a specific agent.

### Stage 1 — hard exclusions

Only two properties exclude a lane outright. Both are decidable before any work.

1. **Context footprint.** A unit that must *hold* more than ~200K of surface cannot
   go to the GPT lane — the request will not fit. Claude only. Below that, both
   lanes remain eligible.
2. **Review crosses model families, always.** Claude's work is reviewed by a GPT
   reviewer; GPT's work is reviewed by Claude. Never GPT-on-GPT — a same-family
   reviewer shares the author's assumptions, and on this lane there is a measured
   propensity to get another instance to conceal misbehaviour. Not negotiable, and
   it fixes the family by the author's family rather than by choice.

Nothing else is a hard exclusion. In particular **oracle authorship is not**: if
the only check would be one the worker wrote, that is a reason to prefer Claude or
to add a real oracle, but the published rate is scaffold-dependent, so it is weighed
rather than enforced. Do not treat it as deciding the lane — it was previously
listed among "decidable" properties while its own text said to weigh it, which
decides nothing and let either choice claim compliance.

### Stage 2 — allocate family across the pool

Everything not excluded in stage 1 is **dual-eligible**. For the large middle class
— ordinary implementation, bounded refactoring, bounded debugging — the lanes are at
near-parity and no scenario evidence separates them.

Given a fan-out of three or more dual-eligible units:

> **Record the pool. Send `ceil(0.4 x pool size)` units to a family other than the
> one you reached for first. Record why any unit was excluded from the pool.**

The recorded pool is what makes this auditable, and it exists because "at least 40%
of *comparable* units" without a definition let the denominator be chosen after the
fact: six dual-eligible units — API, UI, schema, config, tests, docs — can each be
called a different shape, leaving no group of three, after which everything routes
one way while every checkable rule is satisfied. Exclusions must come from stage 1
and be named. "Not comparable" is not an exclusion.

Worked: 5 dual-eligible units, first reach was GPT → `ceil(0.4 x 5) = 2` go to
Claude. 3 units → `ceil(1.2) = 2`. 4 units → `ceil(1.6) = 2`.

This is structural, not a tiebreak. A rule that says "choose the best fit" where fit
is indistinguishable reproduces the single-lane collapse in § Why this file exists.
It also buys cross-family signal for free: two families with different failure modes
on comparable work diverge informatively, which is a review pass you would otherwise
pay for.

The 40% figure is a starting point, expected to be tuned against observed usage
rather than defended on principle. The *mechanism* — recorded pool, named exclusions
— is not the tunable part.

### Stage 3 — pick profile and effort within the allocated family

Family is now fixed. These rows choose *how* to spend it, never *which lane*.

| unit shape | within Claude | within GPT | evidence |
|---|---|---|---|
| high-volume output against a pre-existing oracle — codemods, bulk refactor, generated docs, mechanical migration | Opus | `gpt-terra` | verified: throughput |
| bounded implementation against a pre-existing oracle | Opus | `gpt-mid` / `gpt-high` | published eval, inverse |
| difficult design, weak-oracle debugging, security-sensitive, high-consequence | Opus at `xhigh` | `gpt-sol` | tier definition |
| reviewing the other family's work | Opus 5 | `gpt-sol-reviewer` | stage 1 rule 2 |
| short interactive turn, latency felt by a human | Opus | — | verified: TTFT |
| very cheap read-only fan-out — grep-shaped codebase search | Haiku | — | operator decision |

Where a row offers only Claude, that shape should not have been allocated to GPT in
stage 2 — a short latency-sensitive turn is not fan-out work, so it never enters the
pool.

Sonnet and Haiku are not general-purpose choices. Haiku takes cheap read-only
fan-out; neither takes judgement or implementation work.

Residual preferences that do **not** decide a lane, for use when stage 2 leaves a
genuine choice within a family: abstract reasoning, novel-problem design, front-end
and visual work, and life sciences favour Opus on vendor benchmarks; long sustained
generation favours Terra on measured throughput.

## Effort

Effort buys **search over the solution space**. It does not buy knowledge, care,
or instruction-following. The question is never "is this task important" — it is
*how many plausible-but-wrong answers exist, and would anything catch one?*

- **`xhigh` is the ceiling. Do not select `max`.** Above `xhigh` these models
  spend substantially more reasoning for very little additional performance, so
  `xhigh` is where price-to-performance peaks. Escalate to `xhigh` and stop.
- **`medium` is the floor.** Below it, `minimal` clamps to `low` anyway.
- Mechanical work with a strong oracle comes out the same at every rung. Do not
  pay for depth an oracle already provides.
- Per-agent effort is independent of session effort; a profile's rung travels
  with the profile.

Related: `core-rules/references/delegation.md` (staging, teammate lifecycle),
`core-rules/references/model-lanes.md` (name → lane, degrade tiers),
`core-rules/references/model-prompting-deltas.md` (per-family prompting).
