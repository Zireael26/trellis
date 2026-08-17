# Fleet audit remediation batch

## Status

Accepted — 2026-08-13

## Context

Seven scheduled fleet audits produced coupled findings across canonical hooks,
scheduled-task execution, dependency policy, conductor inventory, and dated
evidence. Splitting the Trellis control-plane portion by mechanism would leave
task receipts and cross-project verification detached from the controls they
verify. The project repositories remain separate pull requests.

## Decision

Review the Trellis control-plane changes as one spec-backed remediation batch
under `specs/035-august-audit-remediation`. The branch may exceed the normal pull
request line cap because its immutable OSV query set and resolved-occurrence
evidence account for most added lines. Project implementation changes stay in
repository-local pull requests with independent rollback.

The control batch includes:

- hook and synchronizer correctness;
- scheduled dependency and test-health execution;
- dependency baseline and terminal-disposition evidence;
- conductor collision verification; and
- the complete spec, task receipts, live OSV result, and macOS fleet-test record.

## Consequences

Reviewers can validate one coherent control-plane diff and follow every task to
a dated artifact. The large evidence payload is accepted as reviewable data,
not implementation complexity. No project dependency or production enablement
change is merged through this branch.
