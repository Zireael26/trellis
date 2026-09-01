# Fleet audit evidence lands as one commit

- Status: accepted
- Date: 2026-08-31

## Context

The 2026-08-31 fleet spec/implementation gap scan produced 263 files and ~20,000 lines of generated
findings across 15 projects and 7 dimensions. This is 25x the 800-line hard cap in `check-pr.sh`.

The content is **generated evidence, not authored code**: one Markdown file per project-dimension cell,
each carrying `head_sha` and `branch` provenance headers, severity-tagged findings, and `file:line`
citations resolved against a frozen tree.

## Decision

Commit the evidence whole rather than splitting it, and record why splitting would destroy its value.

**The dataset is only meaningful as a set.** Its central property is coverage against a declared
denominator — 105 first-pass cells and 56 re-scan cells, with missing cells reported as UNSCANNED rather
than clean. A partial commit has a partial denominator, which is precisely the defect the scan itself was
built to avoid and which its consolidator rejects.

**Both passes must land together.** Wave 1 read 8 of 15 projects off whatever branch their checkout was
parked on — one 672 commits behind its default — so 264 findings were void. `rescan/` is the corrected
pass. Committing only the corrected pass would erase the evidence that the first was wrong, and the
comparison between them is a finding in its own right: the void pass was wrong in **both** directions,
under-reporting one project from 6 high to 22.

**It is inert.** No executable path, no configuration, nothing imported or run. The size is a
transcription cost, not a review cost, and no reviewer is expected to read 20,000 lines of generated
findings line by line — they read `BACKLOG.md` and follow citations into the cells that matter.

## Consequences

- `check-pr.sh` reports warn rather than fail via the ADR exception; the size acknowledgement is
  recorded in the commit and this ADR.
- The evidence is durable and diffable rather than living in `/tmp`, where the disk-janitor sweeps.
  Two sessions lost work to tmp-only artifacts during this programme.
- Provenance is verifiable after the fact: every `rescan/` cell carries `head_sha` and `branch`, so a
  future reader can bound any finding with `git log <head_sha>..origin/main` rather than trusting it.
- Future scans should write directly into `audits/<date>-<name>/` rather than `/tmp`, making this a
  one-time transcription rather than a recurring large commit.
