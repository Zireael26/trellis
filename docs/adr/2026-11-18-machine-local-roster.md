# ADR: Keep machine routes out of portable role policy

- Date: 2026-11-18
- Status: Accepted for the v1.5.4 roster lane
- Related: [Spec 077](../../specs/077-machine-roster/spec.md), [Verdict independence](2026-09-27-gpt6-roster.md)

## Decision

The release decides what a model is, which efforts it supports, and which seats qualify for a role. The operator owns where those seats can run. `roles.json` names seats; `models.json` keeps their canonical identities and restrictions; `harnesses.json` describes launch adapters. `$TRELLIS_HOME/roster.json` is owner-local (0600, in a 0700 parent) and stores ordered routes, credential references, billing assertions and fleet fences, not credentials. One model keeps its family regardless of its launcher. This permits Claude Code and Cursor routes without pretending that Cursor-hosted Claude adds an independent family.

Opus is the final bounded-review rung but remains verdict-only. A machine that cannot field the required independent verdicts reports a topology ceiling and cannot produce an approval-ready result. Missing routes never imply provider exhaustion. The red-team task shape is a routing alias for defensive security review, not a launch workflow.

Select prepaid members by rendezvous hashing on a unit key and billing workspace identity (provisional member ID when the workspace is not known). Accounts sharing a workspace do not add healthy capacity. Record active limit cooldowns with the observed key fingerprint and a reset time; ignore the latch once that fingerprint changes or the reset passes. A one-hour fallback is labelled as a default, not observed telemetry. No scheduling cursor or shared per-selection write is required.

## Alternatives considered

- A single editable role document is easier to deploy but leaks host topology into every payload and permits unsafe divergence of independence policy.
- Round robin requires shared mutable state, reassigns healthy keys when membership changes, and is hard to replay. Weighted scheduling needs quota figures that prepaid providers do not expose.

## Rollout and consequences

Preview with `roster discover`, review billing and fleet claims, and opt in to writing with `--write`. Migrate an existing roster with `roster migrate --roles PATH` pointing to the prior inline-agent policy. Inline legacy policies retain compatibility when no local roster is present. Do not assume separate keys imply separate workspaces: only explicit `roster probe` makes a minimal inference request, and some responses do not identify the workspace.

Host flag verification, real account verification, dispatcher wiring, and consumer-side binding checks are rollout work. The roster lane does not edit installed state or materialize runtime launch agents. Rollback uses the previous release's inline policy; no portable release payload contains the machine roster.
