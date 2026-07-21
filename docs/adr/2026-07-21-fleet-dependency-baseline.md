# ADR — Exact fleet dependency lanes and evidence-backed remediation ledger

**Date:** 2026-07-21 · **Status:** accepted

## Context

Trellis had separate prose audits for vulnerable, stale, and major-version
dependencies. They could identify a mismatch but could not answer which version
was authoritative across projects, whether a divergence was a deliberate
compatibility lane, or what evidence permitted a finding to close. Audits also
read checked-out branches, so dirty and stale local state could be mistaken for
current main.

## Decision

Trellis owns `dependency-baseline.json` and
`audits/fleet-remediation-ledger.json`.

- Shared means a direct dependency in at least two active projects.
- Direct dependencies use one exact resolved version per named compatibility
  lane. Peer dependencies retain ranges but must accept the lane version.
- Project discovery and resolution read authenticated, freshly fetched
  `origin/main` objects through git; checked-out files are never authoritative.
- Security floors validate every resolved transitive branch that matters (for
  example brace-expansion 1, 2, and 5), and may forbid a package entirely.
- An exception is invalid without its project/workspace, reason, owner,
  replacement condition, and expiry date. Expired exceptions fail.
- Ledger rows have stable IDs and explicit dispositions. A terminal disposition
  is invalid without a command, commit/PR, test/audit, or risk receipt; risk and
  manual gates also expire.

The baseline is generated from the highest fetched-main resolution already in
the fleet, then overlays explicit platform targets and security-fixed floors.
`trellis deps check`, snapshot, apply-plan, and ledger commands all read the
same file.

## Consequences

Dependency convergence is now deterministic and resumable. The initial ledger
is intentionally large because it records each current workspace-level drift
and each vulnerability row rather than collapsing them into a narrative. This
generated data explains why the PR exceeds the normal line cap; future updates
are mechanical ledger/baseline refreshes plus small validator changes.

The baseline PR does not make the fleet green by itself. Its failing check is
the remediation work list; project security and convergence PRs drain it. A
failed remote fetch prevents a clean verdict, and application deploys remain
outside this control-plane decision.

## Alternatives considered

- **Registry latest as policy.** Rejected: latest can be incompatible or newly
  vulnerable, and it ignores deliberate framework lanes.
- **Declared ranges only.** Rejected: identical ranges can resolve differently
  and therefore do not provide predictable behavior.
- **One prose rollup.** Rejected: prose cannot reliably resume hundreds of
  findings or enforce evidence and expiry rules.
- **Read current checkouts.** Rejected: user-owned dirty branches and stale local
  refs are not authoritative.
