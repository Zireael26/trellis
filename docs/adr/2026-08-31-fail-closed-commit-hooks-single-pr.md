# Fail-closed commit hooks ship as one PR

- Status: accepted
- Date: 2026-08-31

## Context

`trellis-instance` had **zero active git hooks**: `.git/hooks` held 14 `.sample` files and nothing
else — no `pre-push`, no `commit-msg`, no `pre-commit`. The repository that authors and ships the
fleet's process gate was the least protected of the sixteen projects, and every commit and push from
it was unchecked at the git boundary.

This change adopts fail-closed commit-time hooks with a hermetic test suite. It measures **+832 lines
across 8 files**, over the 800-line hard cap in `check-pr.sh`.

The breakdown is the reason for this ADR:

| part | lines |
|---|---|
| `scripts/tests/commit-hooks.bats` | 344 |
| `scripts/tests/install-commit-hooks.bats` | 272 |
| `scripts/install-commit-hooks.sh` | 96 |
| `scripts/check-commit-message.sh` | 66 |
| `.husky/pre-commit` | 28 |
| `.husky/commit-msg` | 16 |
| `CHANGELOG.md`, `units.md` | 10 |

**Code and configuration total 206 lines. Tests total 616.** The executable change is well under the
cap; the evidence is what exceeds it.

## Decision

Ship as a single PR rather than splitting.

Splitting along the only natural seam — hooks in one PR, tests in another — would land a hook that
changes how everyone in the repo commits **with no demonstration that it can fail**. That is the exact
defect this change exists to remove, and it is documented five times over in `gotchas.md`: a check that
cannot fail while printing a reassuring line is worse than no check. A hooks-only PR would be
indistinguishable from the state it replaces.

The tests are not incidental volume. They encode five separate failure mechanisms found in the fleet
this week, each of which produced a silent pass somewhere:

1. a hook that downgrades to a weaker checker without saying so
2. `core.hooksPath` pointing at a directory containing no `commit-msg`
3. a hooks directory containing only `.sample` files
4. `.husky/_` missing on disk in a worktree
5. an installer that resolves to the **main checkout** when run from a worktree

Mechanism 5 is guarded by `install-commit-hooks.sh:41-87` and covered by
`zero-argument install refuses a linked worktree before writing hooks`.

## Consequences

- `check-pr.sh` reports **warn** rather than fail via the ADR exception. The reviewer size
  acknowledgement is recorded in the PR description.
- `pre-push` is deliberately **out of scope** and `install-commit-hooks.bats` asserts it is not
  installed. Installing it while `trellis_run_managed_payload` still hardcodes
  `PATH=/usr/bin:/bin:/usr/sbin:/sbin` would make this checkout unpushable, which is the state
  a fleet project's root checkout is in. Sequencing is enforced by a test rather than by memory.
- The hooks are shipped but **not enabled** in the operator's working checkout. The PR provides the
  capability and a one-line install command; turning it on changes how the operator commits and is
  their decision.
- `command -v node` is deliberately **absent**. It was correct in the repository this pattern came
  from, where the checker was `./node_modules/.bin/commitlint`; here `check-commit-message.sh` is pure
  bash and a node guard would skip a checker that runs perfectly — reintroducing the fail-open being
  removed.
