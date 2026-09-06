# Spec 044 de-slop cohort C7 ships as one PR

- Status: accepted
- Date: 2026-09-04

## Context

PR #439 (`de-slop/C7-skills-code`, ~8,375 countable lines across 160 files) exceeds
the 800-line hard PR-size cap in the process gate, which permits an ADR explaining
why splitting harms clarity. This is that ADR.

The change is one cohort of spec 044's de-slop programme: a mechanical evidence-
doctrine sweep over `core-rules/skills` code. The units were enumerated in phase 1
(71 scan units, 2,164 rows), triaged in phase 2 to 236 approved fix units with
per-unit operator decisions, and executed in phase 3 by a single foreman against
that approved list. The line count is the sum of many small, individually-justified
edits, not one large design.

## Decision

Ship cohort C7 as a single PR rather than splitting it.

Three reasons, in order of weight:

1. **The triage record is the unit of review, not the diff.** Every hunk traces to
   an approved unit in `specs/044-de-slop`, with its finding, decision and rationale
   already recorded. A reviewer reads the triage and spot-checks the diff. Ten PRs
   of 800 lines each would carry the same triage ten times and give the reviewer ten
   partial views of one sweep.

2. **Splitting by file count is arbitrary here.** There is no seam. The cohort is
   defined by *pattern* — the same doctrine violation wherever it appears in skills
   code — so any split cuts across the property under review and makes "did we get
   all of them?" unanswerable per PR. That question is the whole point of a de-slop
   sweep.

3. **A half-applied doctrine sweep is worse than none.** Intermediate states leave
   the codebase with the pattern fixed in some skills and not others, which reads as
   inconsistency to the next contributor and to the anti-slop tripwire.

## Consequences

- Review is triage-led: check `specs/044-de-slop` decisions against a sample of the
  diff, not line-by-line over 160 files.
- Rollback is the whole cohort. That is acceptable because the cohort is mechanical
  and behaviour-preserving by construction; a partial revert would reintroduce the
  inconsistency described above.
- The gate still requires reviewer acknowledgement of the size in the PR
  description, which is where the sampling evidence belongs.
- This ADR covers C7 only. Cohort C6/C8 carries its own, for the same reasons
  against a different file set.
