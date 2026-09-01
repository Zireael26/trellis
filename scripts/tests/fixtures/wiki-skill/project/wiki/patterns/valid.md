---
slug: valid
status: active
---
# Pattern: valid

## Failure mode
After a project is attached, Husky's preparation step can move Git's hook authority away from the managed Trellis dispatcher. Later doctor checks then report hook-authority drift even though the dispatcher files still exist.

## Root cause
The install-time preparation step rewrites `core.hooksPath` after attachment, so Git invokes a different hook manager than the attachment recorded.

## Working path
Preconditions: the project is attached to Trellis and the managed dispatcher is configured. Named input: the project root.

1. Inspect the recorded hook path and compare it with the managed dispatcher.
2. Run the doctor check against the project root; it must report the managed dispatcher as current.

Observable result: doctor reports the managed dispatcher as current. Verification: run doctor a second time and confirm that no hook-authority drift is reported.

## Dead ends
- Copying Trellis hooks into `.husky/` leaves Git pointed at the wrong authority and can create two competing hook managers.
- Treating a single doctor result as proof misses a path that is rewritten by a later install.

## Evidence
- Gotcha: [gotchas.md#managed-dispatcher-drift](../../gotchas.md#managed-dispatcher-drift)
- Context: [context-log.md#session-2026-08-20](../../context-log.md#session-2026-08-20)
- PR: [PR #123](https://github.com/example/project/pull/123)
