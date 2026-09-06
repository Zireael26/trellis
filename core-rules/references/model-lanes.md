# Model lanes

## What a lane is

A model lane is an execution route selected before a bounded work order runs.
The first-party lane uses the harness's supported model directly. A foreign
lane reaches another model through a local lane router, which may in turn use
an OpenAI-compatible local proxy. The router is an optional capability, not a
prerequisite for loading the agent or completing the work.

The public contract defines routing, availability, and failure/continuity behavior. An
instance-private binding outside the template owns concrete hosts, ports,
credentials, process management, and provider setup.

## Routing predicate: model name to lane

Routing is explicit and ordered:

1. Normalize the requested model name with Unicode NFKC and trim surrounding
   whitespace.
2. Test the first-party namespace first. A recognized first-party model stays
   first-party even if the rest of its name resembles a foreign convention.
3. Route to the foreign lane only when the normalized name matches an
   operator-configured foreign name or prefix.
4. An omitted optional foreign selector leaves routing off and preserves the
   selected native model. An explicitly requested empty, malformed, or unknown
   model name is an error, not permission to select the first-party model.

The precedence is load-bearing. Foreign matching must never steal a
first-party name because of a suffix, whitespace, or a Unicode look-alike.
An explicit unknown model must fail visibly, never mean "try another provider
and see." Optional routing being off does not erase an explicit selection.

## Capability gate

`core-rules/skills/orchestrate/SKILL.md` supplies the precedent: the gate keys
on **capability, not harness identity**. It asks what mechanism the harness
actually exposes, self-activates where that mechanism exists, and
self-deactivates where it does not. It also keeps the same prose contract at
every tier while only the carrying mechanism changes.

Apply that framing here. A lane probe — when an operator supplies one —
reports whether the local lane is configured and currently healthy; callers
decide what to do. Unknown state, malformed output, missing tools, connection
errors, and timeouts all resolve to unavailable.

## Failure and continuity tiers

1. **Selected foreign lane available.** Dispatch the bounded work order through the
   configured lane and retain its receipt.
2. **Selected foreign lane unavailable.** The lane returns `STATUS: UNAVAILABLE` and
   `CODE: LANE_UNAVAILABLE`. Record the failed selection. The selected attempt stays
   visible and fails closed; its receipt does not authorize an automatic rerun on the
   first-party model or any other lane.
3. **Explicit re-selection or same-provider continuity.** A caller or operator may
   explicitly select a different lane after observing the failed receipt. If the
   first-party lane was already selected and native delegation is unavailable, execute
   the identical unit inline on the first-party model, preserving the same scope,
   constraints, proof, and expected output. That is same-provider continuity, not a
   fallback.

An explicitly re-selected lane preserves the unit contract. The router never rewrites
the requested model or chooses a replacement provider.

## Omission is not an unknown selection

- An **omitted optional foreign selector** disables that optional routing;
  it does not choose a different native model.
- An **explicit unknown model name** is a selection error and refuses dispatch.
- An **unknown lane state** resolves to `available: false`, so dispatch to the
  selected lane is off until a positive probe proves it healthy.

Treating unknown state as available turns a broken probe into a fail-open gate.
Treating a typo as permission for either foreign or first-party dispatch silently
changes the requested route. Neither is acceptable at a system boundary.

## Explicit re-selection before a first-party rerun

A foreign-lane unavailable receipt ends the selected attempt. It does not authorize a
rerun. If a caller or operator explicitly selects the first-party lane afterwards, the
caller must:

1. state that the foreign lane was unavailable and include the receipt reason;
2. preserve `task_prompt`, `target_cwd`, scope, constraints, proof, expected
   output, and any explicitly requested model-independent settings;
3. submit that identical work order through the explicitly selected native model
   and host, or execute it inline on that same selected model when no delegation
   mechanism exists; and
4. run the original verification before reporting completion.

Do not ask the router to substitute silently. Do not widen the unit during an
explicitly selected rerun. Do not report the unavailable attempt as success.

## Herdr foreman lane

Inside Herdr (`HERDR_ENV=1`) a multi-unit task may run through a pi foreman workflow
whose subagents are chosen per role from live quota. Topology, the cross-family rule,
and commit-at-phase-boundary obligations: `core-rules/references/herdr-foreman.md`.

## Precedent and deliberate limits

The durable rules a foreign-lane route must follow: pin a first-party
frontmatter model, reach the foreign backend through `Bash`, gate on
capability, and return a structured unavailable receipt that the caller must
handle.

Effort ladders, setup triples, background launch, job-id polling,
no-session-id retries, cancellation bookkeeping, and diff-stat receipts are
not copied here. A single foreground lane request has no effort-tier policy,
companion setup, background job, session-id wedge, or worker-owned edit to
measure; the former worker is retired. Copying those mechanics would add
ceremony without preserving a real invariant.
