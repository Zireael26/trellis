# model-routing — which model gets which unit

*Whether* to delegate is decided in `core-rules/CLAUDE.md` § Context management.
*How* a delegated unit reaches a lane is in `core-rules/references/model-lanes.md`.
This file decides **which model** a unit should go to once you have decided to
delegate it. Read it before choosing a `subagent_type`, before assigning a
teammate, and before picking models inside a dynamic workflow.

The short version: the orchestrator holds the large context and delegates
execution; route on properties you can verify rather than on a general belief
about which model is smarter.

> **Cross-family routing is a separate, opt-in layer.** Everything below applies
> to a single-model-family Trellis, which is the default. If `gptx.enabled` is
> true in `trellis.config.json` — which requires both a Claude subscription and a
> Codex subscription, plus `scripts/gptx/install.sh` — then
> `core-rules/references/model-routing-cross-family.md` also applies and adds
> family allocation on top of this file. With the switch off, that file is not in
> force and nothing in Trellis routes to a second family.

## Why this file exists

Given a free choice between comparable options, an orchestrator collapses onto
whichever one it already holds. That is measured behaviour, not a hypothesis, and
it is why the sections below prefer verifiable properties over "use the best model
for the job". On units where nothing distinguishes fit, "best fit" is not a
decision procedure — it is a preference, and preference collapses.

So: decide on properties that are checkable before the work starts, and be
explicit when nothing distinguishes the candidates.

## Route on verifiable properties

Three properties are decidable before any work begins, and they are the ones that
should carry a routing decision.

1. **Context footprint.** A unit that must *hold* a large surface — more than
   roughly 200K of it — needs a large-window model and in practice stays close to
   the orchestrator seat. This is a hard property: below the ceiling the choice is
   open, above it there is no choice to make. Treat the ceiling as a property of
   the lane you operate rather than a claim about a model's maximum; vendor pages
   may quote a larger window, and what governs is what your router enforces.

2. **Output shape.** Long sustained generation and short interactive turns are
   different problems. Time-to-first-token and total throughput trade against each
   other, so "fast" is a property of the task shape, not of the model: a latency
   sensitive turn a human is waiting on and a bulk mechanical migration want
   opposite ends of that trade.

3. **Oracle authorship.** If the only check on a unit would be one the worker
   itself wrote, that is a reason to add a real oracle, or to keep the unit where
   you can review it directly. It is **weighed, not enforced** — the published
   rate behind this concern is scaffold-dependent, so it does not decide anything
   on its own. Do not treat it as a hard exclusion.

## Never review work with the context that produced it

Review must come from a context that did not author the work. In a single-family
install this means a **fresh-context subagent** reviewing against the spec — not
the same session continuing on, and not a reviewer handed the author's reasoning.
A reviewer that shares the author's context shares the author's assumptions, and
the failure it is most likely to miss is the one the author already talked itself
past.

This is the single-family form of a rule that has a stronger form when a second
model family is available; see the cross-family file when the switch is on. The
rule does not lapse when only one family is present — it changes shape.

Deterministic gates are exempt: a hook, a type checker, or a test suite is
mechanism, not self-review.

## Profile and effort

| unit shape | choose | evidence |
|---|---|---|
| high-volume output against a pre-existing oracle — codemods, bulk refactor, generated docs, mechanical migration | the frontier model, at a low rung | verified: throughput |
| bounded implementation against a pre-existing oracle | the frontier model | published eval |
| difficult design, weak-oracle debugging, security-sensitive, high-consequence | the frontier model at `xhigh` | tier definition |
| short interactive turn, latency felt by a human | the frontier model | verified: TTFT |
| very cheap read-only fan-out — grep-shaped codebase search | Haiku | operator decision |

Sonnet and Haiku are not general-purpose choices. Haiku takes cheap read-only
fan-out; neither takes judgement or implementation work.

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
`core-rules/references/model-prompting-deltas.md` (per-family prompting),
`core-rules/references/model-routing-cross-family.md` (opt-in, requires `gptx`).
