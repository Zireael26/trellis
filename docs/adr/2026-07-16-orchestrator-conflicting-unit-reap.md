# ADR — Orchestrator reaps a codex-fanout conflicting-unit worktree after commit+push (immediacy)

**Date:** 2026-07-16 · **Status:** accepted

## Context

Closes follow-up #1 of `2026-07-16-worktree-lifecycle-reap.md` (spec 016). That
spec's Layer 1 mechanized worktree teardown inside `fanout-verify.wf.js`, but
explicitly deferred the `codex-fanout` conflicting-unit case: a conflicting unit
runs in a **caller-provisioned** `targetCwd` worktree, and the recipe leaves that
tree's diff **uncommitted** for verification. The recipe never commits or pushes
— the orchestrator (main loop) commits accepted diffs serially in dependency
order *after* the recipe returns receipts. So the recipe physically cannot reap
these trees (reaping an uncommitted tree destroys the work; the recipe also
didn't provision the path). Reaping is the orchestrator's job.

Two facts scope this correctly:

1. **It is not new reap capability.** After the orchestrator commits+pushes a
   conflicting unit, that tree is porcelain-clean AND pushed — which the spec 016
   janitor predicate (`clean AND recoverable(merged OR pushed) AND no-secret →
   delete`) already reaps via `disk-janitor --apply --scopes worktrees`. The only
   gap is **immediacy**: without an orchestrator-side reap, the tree lingers
   (1–3 GB each) until the next manual `--apply` or the merged-only nightly.
2. **Conflicting units are a minority.** Most fan-out units share the implicit
   workflow checkout with disjoint declared paths; only `conflicts:true` units
   claim a dedicated worktree. The weekly disk pressure was *diffuse*
   (`fanout-verify` + general fan-out + manual delegation), not primarily these
   trees.

## Decision

Codify — as **doctrine**, in the orchestrator's playbook — that when the main
loop commits+pushes a recipe-provisioned worktree, it reaps that tree
**immediately after the push**: `git worktree remove <targetCwd>`, re-verifying
`git status --porcelain` empty AND the tip pushed to origin at reap time, never
`--force`. For `codex-fanout` this is per-receipt (`worktree`/`targetCwd`/`branch`
are exposed for exactly this), pre-merge (the owner knows the unit is done once
its accepted diff is committed+pushed — it does not wait for merge, unlike the
unattended nightly which *must* wait for merge because it has no such knowledge).

Recorded in `recipes/MANIFEST.md` (the `codex-fanout` row) and
`orchestrate/SKILL.md` (a general orchestrator reap-after-commit rule). The
recipe's own trailing comment already specifies the procedure; this promotes it
into the catalog and the playbook.

## Consequences

- Conflicting-unit trees are reclaimed at source (mid-run) instead of lingering
  until the next `--apply`/nightly — the immediacy the spec-016 net can't give.
- **Doctrine, not a hard hook** — and deliberately so. It cannot be mechanized in
  the recipe (uncommitted at recipe-return) and the orchestrator's commit loop is
  main-loop behavior, not a script. This is *not* a repeat of the original
  incident's unenforced text hint, because the mechanical enforcement already
  exists: the disk-janitor predicate reaps any tree the orchestrator misses. The
  doctrine buys promptness; the janitor guarantees eventual reclaim.
- No new code, no new helper (a parallel `reap-worktree.sh` was rejected — it
  would duplicate the re-verify-at-reap-time pattern already in
  `fanout-verify.wf.js`). Doc-only change.

## Alternatives considered

- **Mechanize in `codex-fanout.wf.js`.** Impossible: conflicting trees are
  uncommitted when the recipe returns; the recipe didn't provision them and never
  commits.
- **Rely solely on the janitor net (do nothing).** Acceptable for eventual
  reclaim, but leaves multi-GB trees for up to a day during a wave; the immediacy
  doctrine is cheap and closes that window.
- **New shared `reap-worktree.sh` helper.** Rejected as premature abstraction
  over an existing single-use pattern.
