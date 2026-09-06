# Ship the three-harness contract as one reviewed release

Date: 2026-09-06
Status: Proposed; release gate and final review pending

## Decision

Ship Spec045 as one integration PR with separate conventional commits for the
runtime contract, fixtures and verification, documentation, and release metadata.
The change exceeds the normal 800-line hard cap. This ADR explains the exception;
it does not waive independent review or turn the PR-size warning into a pass.
The final PR must carry a different agent's explicit acknowledgement of its size.

## Why the integration boundary matters

The inheritance manifest, immutable release renderer, native hook adapters,
Pi extension and worker startup, task-state records, and doctor capability reports
jointly define the supported attachment contract. Publishing these separately
would expose intermediate releases whose renderer installs links that a receiver
does not understand, whose ownership record disagrees with detach, or whose
capability report claims enforcement that its native adapter cannot perform.

The test repair also belongs to that contract. Disposable release fixtures must
contain the manifest's real primitives and allocate command scratch through the
current managed state root. Their assertions must observe real hook execution,
cleanup and preservation, rather than pinning the retired release-store temporary
path. The gate's Git fence and OS write/network restrictions must remain intact.

Wiki refinement and evaluation use the shared native adapters and identity-bound
artifacts. Keeping their acceptance with the same release prevents a published
learning claim from referring to an adapter that was not included in that release.
No improvement in held-out pass rate is claimed by the completed pilot.

## Review and verification

Review remains partitioned into explicit, disjoint source units and reconciled by
the integrating agent. Focused checks are retained as supporting evidence; only
the complete isolated local run qualifies the integration gate. The four-shard
wrapper retains its 3600-second deadline. Ten audited suites may execute two
independent cases concurrently using Bats' within-file semaphore.

Platform-only exclusions are reported separately as unsupported. Exact case,
reason and host-platform binding are required; unknown skips, missing tools,
incomplete output and timeouts remain blockers. Excluded cases do not increase
executed or passed counts.

## Rollout and recovery

Publish the reviewed private source and portable public projection through PRs,
then create the annotated immutable 1.0.0 release. Verify two canaries before
adopting the remaining registered projects. Capture each checkout's release,
attachment and dirty-state identity before and after. Preserve project edits.
If a canary fails, stop expansion and restore that checkout to its recorded prior
verified release through the supported adoption path. Do not rewrite Git history
or delete project changes as a recovery shortcut.

## Consequences

The PR is larger than normal and requires a complete receipt index and explicit
reviewer acknowledgement. A single release identity makes installation and
rollback coherent. Historical raw logs remain private local evidence; only a
curated, reviewed acceptance summary belongs in the release's source history.
