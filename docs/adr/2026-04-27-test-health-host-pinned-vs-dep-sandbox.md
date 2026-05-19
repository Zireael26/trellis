# ADR: test-health audit is host-pinned, not dep-sandboxed

## Status
Accepted (retroactive — host-pinning landed 2026-04-27 via PR #6 `8366e76 chore(audit): pin test-health to macOS host`; recorded 2026-05-08 per plan task P3.10)

## Context

`scheduled-tasks/test-health` runs each project's fast test suite weekly
and bisects for last-green-on-red. Early designs (April 2026) proposed
running the audit in a fresh dependency sandbox per project — pull the
project's lockfile, install in `/tmp`, run tests, throw the sandbox away.
Goal: reproducibility regardless of host state.

Over 2026-04 the design walked back across multiple iterations:

1. Initial spec: dep-sandbox per project. Failed because real test
   suites need real native toolchains (Xcode CLT for iOS, Unity Editor
   for the lume project, system-level pnpm/bun versions tied to host
   `.tool-versions`, etc.).
2. Mid-April: dep-sandbox for Node-only projects, host for native.
   Failed because the per-project sandbox classification turned into
   its own per-project config burden and drifted vs. reality.
3. **2026-04-27 final**: pin the entire audit to a host macOS runner
   (the maintainer's M-series Mac). Add a `tools/run-tests.sh` detection
   tier so each project tells the audit what command to invoke.

The audit (2026-05-08 §2.3 cross-cutting observation) called out that
this multi-week walk-back is not anywhere documented; a future maintainer
re-reads the prompt and might re-attempt the dep-sandbox design without
knowing why it failed.

## Decision

The test-health audit runs **on the maintainer's macOS host**. Per-project
test commands come from a `tools/run-tests.sh` (or equivalent) that the
audit auto-detects.

## Why host-pinning won

- **Native toolchain access**: Xcode CLT, Unity Editor, system bun /
  pnpm, simctl, and other tools that don't fit in a per-project sandbox
  without a containerized macOS host (which doesn't exist — Apple).
- **Ground truth**: tests passing on the maintainer's daily-driver Mac
  is the relevant signal. Sandbox-passing-tests-but-fails-on-host is the
  failure mode the audit is supposed to catch.
- **Cost**: dep-sandbox per project per week was substantial install
  time. Host-runner reuses everything cached.

## Consequences

- The audit cannot run in CI on a Linux runner. This is intentional and
  documented in `scheduled-tasks/test-health/targets.md`.
- New macOS-only test dependencies are fine. New Linux-only test
  dependencies for projects in this fleet would require revisiting (no
  current project has them).
- Onboarding a new maintainer (not currently a concern given the solo
  setup) requires inheriting the maintainer's host or rebuilding
  equivalent tooling.

## References

- `scheduled-tasks/test-health/targets.md`
- PR #6 (`8366e76`) — `chore(audit): pin test-health to macOS host; add tools/run-tests.sh detection tier`
- Audit §2.3 cross-cutting observation
