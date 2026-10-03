# Release 1.3.6 ships as one integration PR above the size cap

- Status: accepted
- Date: 2026-09-27

## Context

Release 1.3.6 carries six changes, each of which was specified, reviewed across
model families, and opened as its own PR:

| PR | Change | Spec |
|---|---|---|
| #506 | specs 053 and 054 (docs only) | — |
| #503 | test-health runner materializes at each fire | 053 Unit D |
| #509 | per-run private HOME for project gate commands | 053 Unit G |
| #510 | `DOCKER_HOST` forwarding and container-runtime doctor rows | 053 Unit K |
| #505 | GPT-6 roster and per-role verdict independence | 052 |
| #516 | pin the AEO gate's ruff rule set (added after the first gate showed every PR gate red) | 058 |

The process gate runs this repository's full test suite (`scripts/run-tests-local.py`,
up to 3,660 s) for every PR. On 2026-09-27, seven apex lanes shared one 14-core host,
with load between 45 and 60. The operator's machine-capacity rule (handoff PROTOCOL §9)
caps full-suite runs at three concurrent slots machine-wide, and those slots were
already queued behind other lanes' gates. Gating the five PRs separately would take at
least five hour-long suite runs, run one after another in practice. The roster change
is the top cross-lane dependency: five other lanes are waiting on ROSTER LIVE.

## Decision

Integrate the six PR branches into `release/1.3.6`, add the version cut, and gate that
range once. The combined range is about 5,200 countable lines, above the 800-line hard
cap. Splitting it would not make it clearer to review:

- Each constituent change was already reviewed on its own. Round and verdict records
  are in each spec's `DISPOSITIONS.md` and in each PR body.
- The integration adds no code of its own: merge commits, a union of CHANGELOG entries
  consolidated into one `[1.3.6]` section, and the VERSION bump.
- One full-suite run over the integrated tree is stronger evidence than five runs over
  each branch in isolation, because it tests the combination that ships.

## Consequences

- When the release PR merges, all six constituent PRs land. GitHub marks each as
  merged because its head commits are in `main`.
- The size warning stays visible on the release PR and needs a reviewer's
  acknowledgement. This ADR exempts it from `fail`, not from being seen.
- This is an exception for this release under host-capacity pressure, not a new default.
  Once `trellis heavy` (spec 054) is live, releases return to one gate per PR.
