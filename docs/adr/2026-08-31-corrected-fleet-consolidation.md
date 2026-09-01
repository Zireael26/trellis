# The corrected fleet consolidation lands whole, beside the one it supersedes

- Status: accepted
- Date: 2026-08-31

## Context

`audits/2026-08-31-spec-gap/BACKLOG.md` reports **429 findings / 103 high**. That number is wrong,
and wrong in a way the artifact itself cannot show: the consolidator matched one findings-heading
shape, and the seven projects using a different shape contributed **zero** to the total silently. It
counted nothing rather than failing. A third heading variant surfaced only when guards were added.

`BACKLOG-CORRECTED.md` and `corrected.json` parse all three shapes and report **667 findings /
174 high** across all 15 projects. They were written ten minutes after the commit that tracked the
rest of the evidence had already merged, so they missed it and have lived untracked since.

This change is 4,340 lines against an 800-line hard cap.

## Decision

Track the corrected consolidation whole, and keep `BACKLOG.md` tracked beside it rather than
replacing it.

**It cannot be split.** `corrected.json` is the machine-readable source and the Markdown is generated
from it. A commit carrying one without the other publishes a total that no artifact in the tree
supports -- the same partial-denominator defect the scan exists to detect.

**The superseded consolidation stays.** A reader who finds only the corrected file cannot see that a
silent-zero undercount happened. A parser whose miss is indistinguishable from a clean result is the
same defect class as the void-provenance failure this audit already documents, and it is worth more
as evidence than as an embarrassment deleted. `README.md` names the corrected files as the only place
to take a number from, so the superseded file cannot be mistaken for current.

**It is inert.** Two generated artifacts and a README edit. No executable path, no configuration,
nothing imported or run.

## Consequences

- `check-pr.sh` reports warn rather than fail via the ADR exception; the size acknowledgement is
  recorded in the PR description.
- The tests leg is not meaningful for this range and was not run: no executable file changes. This is
  a disclosure, not a gate verdict -- see the PR description.
- The audit directory now holds two disagreeing totals on purpose. Anything quoting `429` after this
  commit is quoting the undercount.
