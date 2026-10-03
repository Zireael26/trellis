# Spec 043 foreground-panes amendment ships as one PR over the size cap

- Status: accepted
- Date: 2026-09-27

## Context

PR #502 carries the spec 043 amendment "visible panes that keep caller focus" and its implementation. It is about 1,700 countable lines, over the 800-line hard cap. Roughly 1,300 of those lines are spec-first evidence that the operator's PROTOCOL §7 (2026-09-27) requires:
- the amendment itself;
- three rounds of multi-family reviews (Sol, Gemini, Grok, Muse), plus Sol, Muse and Claude code reviews;
- the R7 live Herdr receipt with its raw, id-only JSON.

The executable change is small: `foreman-start.sh` (the `--no-focus` flags and the exit-5 abort), its test, and docs.

## Decision

Ship the amendment and its implementation as one PR, squashed into two commits (spec, then fix), following the precedent of `2026-09-18-spec-050-release-size.md`.

1. **The review record is the unit of review.** Splitting the evidence from the code would leave the implementation PR citing reviews that are not on the branch.
2. **The code alone is under the cap.** A reviewer can read the `fix(herdr-foreman)` commit on its own, and the spec commit is documentation only.

## Consequences

- Rollback is a revert of the fix commit. The spec commit can stay as the record.
- The reviewer acknowledges the size in the PR description.
