# Model lanes

## What a lane is

A model lane is an execution route selected before a bounded work order runs.
The first-party lane uses the harness's supported model directly. A foreign
lane reaches another model through a local lane router, which may in turn use
an OpenAI-compatible local proxy. The router is an optional capability, not a
prerequisite for loading the agent or completing the work.

The public contract defines routing, availability, and degrade behavior. An
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
4. Route an empty, malformed, or unknown model name to the first-party lane.

The precedence is load-bearing. Foreign matching must never steal a
first-party name because of a suffix, whitespace, or a Unicode look-alike.
Unknown model names therefore mean "foreign routing is off," not "try the
foreign lane and see."

## Capability gate

`core-rules/skills/orchestrate/SKILL.md` supplies the precedent: the gate keys
on **capability, not harness identity**. It asks what mechanism the harness
actually exposes, self-activates where that mechanism exists, and
self-deactivates where it does not. It also keeps the same prose contract at
every tier while only the carrying mechanism changes.

Apply that framing here. `scripts/lane-preflight.sh` reports whether the local
lane is configured and currently healthy; callers decide what to do. The
probe always exits 0 and returns one JSON line. `available` is true only when
the configured state endpoint answers with HTTP 2xx and reports state `ok`.
Unknown state, malformed output, missing tools, connection errors, and
timeouts all report false.

## GPTX delegate policy is a separate gate

`cmux-trellis-teams --delegates auto|gpt|claude|none` controls which providers
an Agent call may request. It is independent of the main mode, main-model
override, and advisor selection. Enforcement happens at the Agent caller in a
`PreToolUse` guard; the router never changes `model`, `subagent_type`, or
`name` to satisfy the policy.

An explicit Agent model classifies first. When model is absent or `inherit`, a
registered Agent type supplies the provider. `auto` permits known providers
and unknown extensions; `gpt` and `claude` fail closed on unknowns; `none`
rejects every Agent call. Policy permission does not prove that the lane has
quota or that a direct topology can reach it. A permitted call that encounters
an unavailable lane still follows the caller-owned degrade tiers below.
Workflow-engine agents use their own orchestration surface and are outside this
selector.

The published worker pins a first-party frontmatter model and reaches the
foreign backend through Bash only after the gate passes. This makes
`core-rules/agents/lane-worker.md` loadable on a stock harness while keeping
the optional route available to configured hosts.

## Degrade tiers

1. **Foreign lane available.** Dispatch the bounded work order through
   `lane-worker` and retain its receipt.
2. **Foreign lane unavailable.** The worker returns `STATUS: UNAVAILABLE` and
   `CODE: LANE_UNAVAILABLE`. The caller records the degrade and re-runs the
   identical unit on the first-party model.
3. **No delegation mechanism.** Execute the identical unit inline on the
   first-party model, preserving the same scope, constraints, proof, and
   expected output.

The unit contract does not change across tiers. Only the mechanism carrying it
changes: foreign lane, first-party delegation, or the caller's own context.
The router never rewrites the requested model to hide a fallback.

## Why unknown resolves to OFF

There are two distinct unknowns:

- An **unknown model name** resolves to the first-party lane, so foreign
  routing is off for that request.
- An **unknown lane state** resolves to `available: false`, so dispatch to the
  foreign lane is off until a positive probe proves it healthy.

Both defaults prevent accidental foreign dispatch. Treating an unknown state
as available converts a broken probe into a fail-open gate; treating an
unknown model as foreign lets a typo or naming collision change providers.
Neither is acceptable at a system boundary.

## Re-running on the first-party model

A caller that receives the unavailable receipt must:

1. state that the foreign lane was unavailable and include the receipt reason;
2. preserve `task_prompt`, `target_cwd`, scope, constraints, proof, expected
   output, and any explicitly requested model-independent settings;
3. submit that identical work order to a first-party Claude agent, or execute
   it inline when no delegation mechanism exists; and
4. run the original verification before reporting completion.

Do not ask the router to substitute silently. Do not widen the unit during the
rerun. Do not report the unavailable attempt as success.

## Precedent and deliberate limits

`core-rules/agents/codex-worker.md` provides four reusable rules: pin a
first-party frontmatter model, reach the foreign backend through Bash, gate on
capability, and return a structured unavailable receipt that the caller must
handle.

Its effort ladder, setup triple, background launch, job-id polling,
no-session-id retry, silent-log relaunch, cancellation bookkeeping, and
diff-stat receipt are not copied. A single foreground lane request has no
effort-tier policy, companion setup, background job, session-id wedge, or
worker-owned edit to measure. Copying those mechanics would add ceremony
without preserving a real invariant.
