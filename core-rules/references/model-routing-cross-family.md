# model-routing-cross-family — allocating units across two model families

> **Precondition.** This file is in force only when `gptx.enabled` is true in
> `trellis.config.json` (resolution: project-local `.trellis.config.json.gptx` →
> central `trellis.config.json.gptx` → built-in *off*). GPTX assumes the operator
> holds **both** a Claude subscription and a Codex subscription and has run
> `scripts/gptx/install.sh`. With the switch off, nothing here applies: no
> `gpt-*` profile is a routing target, the allocation floor below does not bind,
> and `core-rules/references/model-routing.md` is the whole of routing doctrine.
>
> Turn it on by setting `"gptx": { "enabled": true }`. See `specs/028`.
>
> **Tunables.** Three keys under `gptx.routing` govern allocation, resolved with
> the same precedence as the switch itself:
> `default_family` (`gpt` | `claude` | `balanced`) is the lane a dual-eligible unit
> takes without a named reason; `share_floor` (0 < x <= 1) is a **tripwire** — the
> minimum fraction of the candidate set that must stay unreserved, not a quota to
> allocate; `orchestrator_inline_max_lines` is the size above which the
> orchestrator delegates instead of editing inline. Absent or
> malformed, all three fall back to `balanced` / `0.4` / no threshold — which is
> behaviour identical to a spec-028 Trellis. See `specs/030`.

This file adds one stage to `model-routing.md`: **which family** a unit goes to.
Everything in that file — verifiable-property routing, the effort ceiling, the
review rule, profile choice within a family — still applies and is not repeated
here.

The short version: the two frontier lanes are close enough in capability that
capability alone cannot pick between them, so route on properties you can verify
and send the rest to a **named default lane**. Given a free choice between
comparable *lanes*, an orchestrator collapses onto whichever family it already
holds — measured behaviour, not a hypothesis, and the reason this file names a
default and a floor rather than saying "use the best model for the job". The
default exists so that the lane chosen when nobody decides is the lane you meant.

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
They are not the configuration we run — see `model-routing.md` § Effort.

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

Everything not excluded in stage 1 is **dual-eligible**, and the dual-eligible units
of one piece of work are its **candidate set** — the two terms name the same thing,
the second when you are counting it. For the large middle class — ordinary
implementation, bounded refactoring, bounded debugging — the lanes are at
near-parity and no scenario evidence separates them.

The default lane is `gptx.routing.default_family` in `trellis.config.json`. Where it
names a family:

> **1. Form the candidate set** — every unit that survived stage 1. Record it.
> **2. Each candidate is either reserved or not.** A candidate is reserved only if a
> named domain from the closed list below applies. Name the domain.
> **3. Every unreserved candidate goes to `default_family`.** All of them, not a
> quota of them.
> **4. Check the floor:** unreserved candidates must number at least
> `ceil(share_floor x candidate set size)`. If they do not, the reservations are
> over-claimed — re-examine them rather than proceeding.

Worked, at the shipped `default_family: gpt` / `share_floor: 0.7`. Five candidates,
one reserved under R1 (a UI unit): four unreserved → four to GPT. Floor check
`ceil(0.7 x 5) = 4`; four unreserved passes. Had three of the five been claimed as
reserved, only two would be unreserved, `2 < 4`, and the rule says stop and
re-examine the reservations — not route the difference to GPT anyway.

**The floor is a tripwire, not an allocation.** It does not schedule units to
Claude and it does not create a 70/30 split. Step 3 is what allocates, and where no
reservation applies it sends *everything* to GPT. The floor exists solely to catch
the failure mode this whole file is about: reservations quietly expanding until the
default means nothing. Compliance is checkable from the spawn record — count
candidates, count reservations, verify each names a domain.

### Why this is directional and not a mix

An earlier form of this rule read "send `ceil(0.4 x pool)` to a family other than
the one you reached for first". That is **symmetric**: it puts a floor under the
minority family, whichever that turns out to be, so raising the number does not
lean either way — it only makes the split more even. It was also unauditable,
because "the family you reached for first" leaves no artifact in a transcript, so
no reviewer could check it and any allocation could be justified after the fact.

The directional form fixes both. There is one named default, the allocation rule has
a sign, and compliance is checkable from the spawn record alone.

The recorded candidate set still matters, and for the original reason: "at least 40%
of *comparable* units" without a definition let the denominator be chosen after the
fact. Six candidates — API, UI, schema, config, tests, docs — can each be called a
different shape, leaving no group of three, after which everything routes one way
while every checkable rule is satisfied. **Departures from the default must come
from stage 1 or from the reserved list below, and must be named. "Not comparable" is
not a reason.**

This is structural, not a tiebreak. A rule that says "choose the best fit" where fit
is indistinguishable reproduces the single-lane collapse in `model-routing.md`
§ Why this file exists.

**What this costs, stated plainly.** The symmetric rule guaranteed cross-family
divergence signal — two families with different failure modes disagreeing
informatively on comparable work — because it always left units on both lanes. The
directional rule does not. A fan-out with no applicable reservation goes entirely to
GPT, and that signal is simply gone. It is a real loss and it is accepted
deliberately: the operator's constraint is subscription headroom, and buying
divergence on every fan-out is not worth the Claude tokens it costs. Where you want
it on a specific fan-out, get it by asking for cross-family review of the result
(R3), which is cheaper than splitting the work.

`default_family` and `share_floor` are both starting points, expected to be tuned
against observed usage rather than defended on principle. The *mechanism* —
recorded candidate set, named reservations, a default with a sign — is not the
tunable part.

### When `default_family` is `balanced`

`balanced` is not a family. It selects the pre-030 symmetric rule, which is what an
install with no `routing` block gets, and it is stated here in full rather than left
to be reconstructed from history:

> **Given a fan-out of three or more dual-eligible units: record the pool, and send
> `ceil(share_floor x pool size)` units to a family other than the one you reached
> for first. Record why any unit was excluded from the pool.**

Under `balanced` the fallback `share_floor` is `0.4`, the reserved list below does
not apply as a closed set, and front-end/visual work returns to being a residual
preference rather than R1. Note the fan-out threshold: below three units the rule
imposes nothing, which the directional form does not replicate.

### The Claude reservation is closed

First, two things that are **not** reservations because they never reach step 2:
review of GPT-authored work and units holding >200K of surface are *stage 1
exclusions*. They are removed before the candidate set is formed. Listing them as
reservations would double-count them and inflate the denominator.

What remains — while `default_family` is `gpt`, these are the **only** reasons an
unreserved candidate becomes a reserved one. The list is closed.

| # | reserved domain | test | why |
|---|---|---|---|
| R1 | Front-end, visual, and interaction design | Does the unit decide what a human sees or interacts with? | Operator decision, supported by vendor benchmarks. |
| R2 | Stand-alone planning or advisory output, and the named advisor seat | Is the deliverable *itself* advice — plan, decomposition, review, recommendation, or normative doctrine — **and does it change nothing that executes?** | Operator decision; this is the orchestrator's own function. |
| R5 | Short interactive turn with a human waiting | Is a person watching this specific turn complete? | Verified TTFT: Opus first-token is roughly a third of either GPT lane. |
| R6 | Cheap read-only fan-out | Grep-shaped search, no mutation. | Goes to **Haiku**, not Opus — see the delegation note below. |

**R2 is bounded by output, not by subject.** The test is whether the deliverable is
advice, not whether the topic is planning. A unit that plans *and then implements*
is not R2 — split it: Claude may produce or review the plan, and the implementation
returns to step 3 and goes to GPT. "Decompose the auth migration, then make the
edits" is two units, one reserved and one not.

The checkable line is **does the artifact execute?** A doctrine file, a spec, a
plan, a review — read by humans and agents, run by nothing — can be R2. Code,
config, schema, and shell are executed or parsed by machinery, and are never R2 no
matter how architectural the work feels. So authoring *this file* is R2; authoring
the config block and shell resolver that back it is not, and goes to GPT.

Without that bound R2 becomes a subject-matter category, and subject-matter
categories are exactly how a reservation list stops being closed. "It's really a
design problem" is available for almost any unit, which is why it is not a test.

**Not reserved.** "Security-sensitive", "high-consequence", "difficult design", and
"weak-oracle debugging" do **not** send a unit to Claude. `gpt-sol` at `xhigh` is
the answer for that shape, and stage 3 already says so. This matters more than it
looks: those four phrases describe most non-trivial work, so admitting any of them
as a reservation swallows the default and reproduces exactly the collapse this file
exists to prevent. If a unit feels like it needs Claude for one of those reasons,
the honest reading is that it needs *more effort*, not another family.

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
genuine choice within a family: abstract reasoning, novel-problem design, and life
sciences favour Opus on vendor benchmarks; long sustained generation favours Terra
on measured throughput.

Front-end and visual work used to sit in that list. It does not any more — it is
R1, a reserved domain that decides the lane in stage 2. Listing it in both places
stated a contradiction, and the residual list is the weaker of the two claims.

## The main loop is in the pool

Stages 1–3 allocate *delegated* units. On a Claude-orchestrated install that is not
where most of the tokens are, and a family rule that only governs delegation cannot
move the total by much.

Measured on this instance (`audits/2026-07-30-model-routing-baseline.md`,
post-cutoff): the main loop was **55.6%** of all output tokens and **99.4% Claude**
by construction — the orchestrator seat is Claude because it holds the >200K
surface the GPT lane cannot accept (stage 1 rule 1). Only the remaining 44.4% is
allocable at all.

The arithmetic that follows is the whole point: **even a perfect 100%-GPT
delegation policy caps GPT near 44% of output tokens.** No value of `share_floor`
changes that, because the main loop never enters the pool. The lever that raises
the ceiling is not the ratio — it is how much the orchestrator implements inline
instead of delegating.

So, while `gptx.routing.orchestrator_inline_max_lines` is set:

> **A unit of work whose expected net change exceeds
> `orchestrator_inline_max_lines` is delegated, not implemented in the
> orchestrator's own context.**

The orchestrator keeps planning, decomposition, review of returned work, and
synthesis. Absent the key, there is no threshold and the orchestrator may implement
inline freely, which is the pre-030 behaviour.

**"Reserved to Claude" and "stays inline" are different questions.** A reservation
names a *family*; the threshold names *who executes*. R6 is the clearest case: cheap
read-only fan-out is reserved to the Claude family and is nonetheless **delegated**,
to Haiku, because delegating it is the entire point of that row. R1 work is
similarly delegable to a Claude-family executor. Do not read a reservation as a
licence to do the work inline — that would route the reserved domains straight back
into the 55.6% this section exists to shrink.

Two costs, stated here rather than discovered later:

- **Latency.** A delegated 50-line edit is slower end-to-end than an inline one —
  spawn, cold context, return. R5 does not cover this; R5 is about turn latency,
  not unit size. Interactive work gets genuinely slower, and that is accepted
  deliberately rather than overlooked.
- **Context cost.** The orchestrator pays to describe the unit and to read the
  result back. Below some size, delegating costs more total tokens than doing the
  work. The shipped threshold is an estimate of that crossover, not a measurement.

Related: `core-rules/references/model-routing.md` (single-family doctrine — the
base this file extends), `core-rules/references/delegation.md` (staging, teammate
lifecycle), `core-rules/references/model-lanes.md` (name → lane, degrade tiers),
`core-rules/references/model-prompting-deltas.md` (per-family prompting).
