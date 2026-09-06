# model-routing — which model gets which unit

*Whether* to delegate is decided in `core-rules/CLAUDE.md` § Context management.
*How* a delegated unit reaches a lane is in `core-rules/references/model-lanes.md`.
This file explains the properties supplied to task classification or an explicit
operator selection; it is not a second model selector. Concrete automatic
routes and effort come from the live classifier described in
`core-rules/references/delegation.md`.

The short version: the orchestrator holds the large context and delegates
execution; route on a model family that fits the unit and on live facts you can
verify — quota, availability, authentication, and cost — rather than a belief
that one named model is always the frontier.

## Why this file exists

Given a free choice between comparable options, an orchestrator collapses onto
whichever one it already holds. That is measured behaviour, not a hypothesis, and
it is why the sections below prefer verifiable properties over "use the best model
for the job". On units where nothing distinguishes fit, "best fit" is not a
decision procedure — it is a preference, and preference collapses.

So: decide on properties that are checkable before the work starts, and be
explicit when nothing distinguishes the candidates.

## Route on verifiable properties

Use these observable unit properties to classify the work or explain an explicit
selection. They do not override the classifier's eligibility checks or invent
an alternative automatic route.

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

## Multi-provider doctrine

A frontier capability is a class, not a permanent provider or model. Route a
multi-provider unit from four facts:

1. **Model family.** Select the family whose behavior fits the unit and whose
   independence requirements it can satisfy. Never assume one named model
   remains the universal frontier.
2. **Live quota and availability.** The classifier refuses `disabled`, `exhausted`,
   or `limitReached` states, missing metered telemetry, and reported headroom below
   the configured threshold. Explicitly declared prepaid/unmetered routes may be
   eligible without a report, subject to the remaining capability, authentication
   and family checks. Keep that reportless state visible; it is not measured
   headroom. Decide from the current observation, not a previous successful run.
3. **Authentication and policy.** A candidate without a valid, permitted
   credential is ineligible. Credential and data-handling policy can rule out a
   capable provider before price or apparent quality matters.
4. **Cost.** Among capable, permitted, live candidates, spend the least that
   meets the unit's required assurance and output shape. Cost may break a tie;
   it does not justify weakening the oracle or review.

Concrete provider/model names, family mappings, ordered role chains, thresholds, and cost data are configuration in
`core-rules/skills/herdr-foreman/roles.json`, not prose. The live resolver applies
that configuration from its current observations; an explicit eligible operator
selection takes precedence. This reference states selection doctrine, not roster or
resolver mechanics.

## Independent and cross-family review

Review must come from a context that did not author the work. Where an eligible
second family exists, a reviewer, security reviewer, or refuter MUST use it.
A fresh context remains necessary: a different family handed the author's
reasoning merely inherits the same assumptions.

If no eligible second family exists, a fresh-context same-family review can
still add evidence, but it is **DEGRADED**, not cross-family review. Disclose
the author and reviewer family, the missing guard, and the limiting condition:
quota, availability, authentication/policy, or an approved cost boundary.
Never silently downgrade assurance or self-certify. Deterministic gates are
exempt: a hook, a type checker, or a test suite is mechanism, not self-review.

## Profile and effort

These considerations inform classification or explicit selection; concrete
models and supported effort remain the classifier/host's responsibility.

| unit property | consideration | evidence |
|---|---|---|
| high-volume output against a pre-existing oracle — codemods, bulk refactor, generated docs, mechanical migration | a live eligible, low-cost candidate in a capable family, at a low rung | verified: throughput |
| bounded implementation against a pre-existing oracle | a live eligible capable candidate | published eval |
| difficult design, weak-oracle debugging, security-sensitive, high-consequence | stronger problem-solving and independent assurance at the configured supported effort | observed task performance |
| short interactive turn, latency felt by a human | a live eligible candidate optimized for interactive latency | verified: TTFT |
| very cheap read-only fan-out — grep-shaped codebase search | a live eligible low-cost read-only candidate | operator decision |

The cheap read-only fan-out role is not a general-purpose choice. It takes
search-shaped work; it does not take judgment or implementation.

## Effort

Effort buys **search over the solution space**. It does not buy knowledge, care,
or instruction-following. The question is never "is this task important" — it is
*how many plausible-but-wrong answers exist, and would anything catch one?*

- Resolve automatic worker effort from the current role configuration and
  classifier in `references/delegation.md`; deliberate direct Codex dispatch
  follows `docs/codex-routing.md` §3. These are workload policies, not universal
  model capability limits. Explicit user-selected session effort follows the host.
- Check supported efforts on the selected model and host. Do not infer a floor,
  clamp, or cost optimum from a different model's ladder.
- Use a strong oracle to test whether lower effort preserves the required
  outcome; do not claim all effort levels are equivalent without a comparison.
- Per-agent effort is independent of session effort; a profile's rung travels
  with the profile.

Related: `core-rules/references/delegation.md` (staging, teammate lifecycle),
`core-rules/references/model-lanes.md` (name → lane, degrade tiers),
`core-rules/references/model-prompting-deltas.md` (per-family prompting).
