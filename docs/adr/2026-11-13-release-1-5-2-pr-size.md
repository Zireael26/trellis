# 1.5.2 lands as one PR above the size cap

## Status

Proposed on 2026-11-13 for the 1.5.2 release PR, `feature/152` into `main`, after `fix/152-cut` is integrated by merge commit. This records the size exception's rationale; it is not an owner approval, a gate waiver, or a merge verdict. The final tested head and counts must be confirmed at freeze.

## Context

Against published 1.5.0 on `main` (`cf8be187a6bfb6a11ac9581930198715e2895ab2`), the pre-ADR `fix/152-cut` head `14350302d12f326ae2a88e41de97cf92a8fa11f7` has 332 commits, including 88 merge commits; the Git diff has 512 files, +184,949 / −154,536. The process-gate PR-hygiene validator counts **319,767 changed lines** after excluding 19,507 test and 211 fixture lines, versus a 1,200-line hard cap. These are pre-ADR, pre-freeze figures, not final T45 results.

Most of the count is changed qualification evidence: 88 files under `specs/074-fast-hooks/evidence/` account for **293,512 changed lines**, approximately **91.8%** of the countable total. These include re-recorded machine qualification JSON and its derived records. Qualification must bind the integrated version and native assets; the final records must be assessed with the exact release head. The sealed release payload and public mirror exclude `specs/`, so these records do not ship as runtime policy.

The remainder includes the integrated 1.5.1 changes, 1.5.2 doctor, registry, sync, native Stop and worktree-create changes, their tests and upgrade notes. The planned 1.5.1 release was not published separately; its changes ship in 1.5.2. A split by lane would either require publishing an intermediate release that was not approved or re-recording and requalifying each serial intermediate, while obscuring the integrated, versioned release that is to be installed. Lanes remain reviewable through their merge commits.

## Decision

Propose one integrated 1.5.2 PR and require full qualification and review of that exact final head. Request explicit reviewer acknowledgement of the oversized PR in its description. Do not split, squash or rewrite lane history merely to change the count.

## Consequences

- This ADR changes the size hard-cap failure to a warning only when the validator accepts it; reviewer size acknowledgement remains required. It does not resolve any other PR-hygiene finding.
- The pre-ADR validator also reported 103 commit-subject findings, including older lane subjects over 72 characters and other nonconforming subjects. They arrive through merge commits and are not rewritten; the owner and reviewers must resolve the gate posture through the normal process, without a bypass or history rewrite.
- The range changes gate-relevant paths. The owner's `gate-config-approved: <full-final-head>` on the actual PR and the remaining applicable gate/review receipts are separate requirements.
- Final T45, native qualification, release tag verification, canary and rollout remain separate gates; this ADR is not evidence that any passed.
