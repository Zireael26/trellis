# 1.3.16 lands as one PR above the size cap

## Status

Accepted on 2026-10-17 under the owner's instruction to finish every reported Trellis bug in this release. Covers the `chore/release-1-3-16` PR.

## Context

The range against 1.3.15 is about +4,400/−230 lines across 67 files. Most of it is tests: each of the 22 fixes carries a test that fails before it and passes after. The fixes come from agents across downstream projects on 2026-10-16 and 2026-10-17 plus five open GitHub issues (#475–#478, #550).

Every merge runs the full test suite, about 70 minutes on an idle machine and longer under load, one gate at a time. The fixes share files (`attachment.sh`, `attach-project.sh`, the Stop hooks, `check-secrets.sh`), so splitting them would mean many serial gates and repeated rebases. A GPT-6.1 Sol foreman built them in waves with Luna, Haiku and Muse workers; Claude reviewed and committed each unit, and three automated security findings on the secrets skip list were fixed before release.

## Decision

Land 1.3.16 as one PR with one gate, stacked on 1.3.15.

## Consequences

- The PR-hygiene size row keeps its warning; this ADR explains it and does not waive review.
- Projects adopt by pin move. A project that wants env passthrough or a semgrep timeout merges its `.trellis.json` change first, through a gate-config PR.
