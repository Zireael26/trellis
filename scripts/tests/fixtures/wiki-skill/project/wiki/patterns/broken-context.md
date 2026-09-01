---
slug: broken-context
status: active
---
# Pattern: broken-context

## Failure mode
A project can retain the managed dispatcher files while Git invokes a different hook authority after attachment or installation.

## Root cause
The configured `core.hooksPath` no longer points at the dispatcher recorded for the attachment.

## Working path
Preconditions: the project is attached and the doctor command is available. Named input: the project root.

1. Inspect the recorded hook path and compare it with the managed dispatcher.
2. Restore the managed dispatcher at the configured path.
3. Run doctor and confirm that the dispatcher is current.

Observable result: doctor reports the managed dispatcher as current. Verification: run doctor again and confirm that no hook-authority drift is reported.

## Dead ends
- Running an install again without checking the hook path can rewrite the same setting and repeat the failure.

## Evidence
- Gotcha: [gotchas.md#managed-dispatcher-repair](../../gotchas.md#managed-dispatcher-repair)
- Context: [context-log.md#session-2099-01-01](../../context-log.md#session-2099-01-01)
- PR: [PR #123](https://github.com/example/project/pull/123)
