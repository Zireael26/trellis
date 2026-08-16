# Fail-closed dependency-range classification

## Context

The docs-discipline gate exempts same-major dependency maintenance from a new
ADR. A textual comparator check could accept ranges that widened into a new
major, and later fixes still accepted invalid, empty, or unsatisfiable npm
semver ranges. Rename-away, type-change, and invalid Git ranges also had
fail-open paths.

The complete repair is slightly over the normal PR hard cap because the parser,
adversarial regression corpus, and reviewer-facing contract must change
together.

## Decision

Use a dependency-free interval model for the supported npm semver subset.
Grant the maintenance exemption only when both old and new ranges are valid,
satisfiable, and cover the same major-version set. Reject uncertain syntax,
wildcard prereleases, comparator prereleases, invalid Git ranges, and lossless
path-enumeration failures.

Keep the implementation, its complete regression corpus, and the documented
contract in one change. Splitting them would temporarily publish either an
untested classifier or tests/documentation for behavior the live gate did not
yet enforce, weakening review and rollback clarity.

## Consequences

- Same-major maintenance remains low-friction for supported valid ranges.
- Invalid, unsatisfiable, or ambiguous ranges require an ADR instead of being
  treated as routine maintenance.
- The gate remains Bash 3.2-compatible and uses Node only for semver arithmetic
  already required by the JavaScript dependency surface.
- The atomic change exceeds the default 800-line hard cap; this ADR records why
  that exception is safer than splitting the control and its proof.

## Alternatives considered

- Compare range strings or comparator shape only: rejected because distinct
  semantics can share both.
- Depend on the npm `semver` package at gate runtime: rejected because the
  process gate must work before project dependencies are installed.
- Split parser, tests, and contract into separate PRs: rejected because every
  intermediate state would be incomplete at the merge boundary.
