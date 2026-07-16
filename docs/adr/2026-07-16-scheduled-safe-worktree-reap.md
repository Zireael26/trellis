# ADR — Scheduled unattended worktree reap: --safe-only (merged-only) nightly LaunchAgent

**Date:** 2026-07-16 · **Status:** accepted

## Context

Companion to `2026-07-16-worktree-lifecycle-reap.md` (the 3-layer fix, PR #160).
That PR made the janitor *able* to reclaim orphaned fan-out worktrees and warn
early — but it is **not hands-off**: the launchd agent only `--report`s, so the
disk still fills between manual `--apply` runs. The operator asked to close
"don't do this every week" fully. The chosen close-out is *both* a scheduled
safe-set `--apply` (this ADR) and orchestrator-side reap at the primary source
(follow-up #1, a separate spec).

The naïve version — schedule `--apply --scopes worktrees --yes` on the full
delete-set — is **unsafe unattended**. The default predicate reaps any
`clean AND (merged OR pushed) AND no-secret` tree. A `pushed`-but-unmerged clean
tree is exactly what an *in-flight* overnight fan-out unit is working in: it
commits+pushes to open its PR, then keeps running. `git worktree remove` doesn't
care that the path is some process's cwd — the process just starts getting
ENOENT. Attended `--apply` never hit this because a human doesn't run it during a
fan-out; a 3:30am timer will. The worktree scan has **no live-process guard**
(the build-active guard covers caches only; the incident's "1 live process"
exclusion was done by hand).

## Decision

Add a **`--safe-only`** flag and a **separate, opt-in nightly LaunchAgent** that
runs `disk-janitor --apply --scopes worktrees --yes --safe-only`.

`--safe-only` is a pure post-verdict **tightening**: a `delete` verdict survives
only for a tree that is **merged AND porcelain-clean AND non-detached AND
non-secret**. Every other auto-delete — `pushed`-but-unmerged, ephemeral
`/private/tmp` — is downgraded to a manual `candidate` and left in place. It only
ever downgrades, never promotes, so `--dry-run --safe-only` previews exactly what
the nightly will reap.

**Why merged-only is the concurrency guarantee.** A merged PR means the unit is
*done* — a fan-out never merges its own PR mid-run (the operator merges, later).
So a merged tree has no live agent in it, and merged-only carries the safety that
a live-process guard would otherwise provide. It also targets precisely the
primary accumulation pattern the incident named: "operator merges the PR later;
nothing reaps the tree." Result: **merge a PR → its worktree is gone by
morning.** Fails safe — merge detection is a read-only `gh pr list … --state
merged`; no gh / no network at 3:30am → "unverified → never reaped" → the nightly
no-ops instead of guessing.

**Deliberately left to other owners** (not the nightly): `pushed`-unmerged and
`/private/tmp`-ephemeral trees are in-flight; Layer 1 (fan-out teardown) and
follow-up #1 (orchestrator reap) own them. The pieces compose rather than
overlap.

**Delivery.** New template `core-rules/templates/org.trellis.disk-janitor-apply.plist`
(RunAtLoad false; 04:00, after the 03:30 report; own log). The installer gains
`--with-apply` — the default run still installs report-only; the destructive
agent is explicit opt-in and prints what it will and won't reap.

## Consequences

- The main post-merge accumulation self-clears nightly with no operator action —
  the actual "every week" retirement for that class.
- **Enabling is gated.** The nightly is inert until the `--safe-only` predicate
  is on the host: flip it on only after PR #160 is merged and the host has pulled
  (`install-disk-janitor-launchd.sh --with-apply`). Building the code now is
  fine; enabling it before the predicate ships would just error harmlessly.
- **Still not the whole job.** `pushed`-unmerged and abandoned (never-merged)
  trees are untouched by the nightly by design — those are follow-up #1's remit.
  Between the two, "every week" is closed; alone, the nightly closes only the
  merged-clean class.
- Verified: 78/78 disk-janitor bats (incl. the discriminating pair — a
  pushed-unmerged tree is reaped WITHOUT the flag and survives WITH it),
  shellcheck `--severity=warning` clean, plist `plutil -lint` OK with exactly the
  safe argv.

## Alternatives considered

- **Nightly on the full `merged OR pushed` set.** Rejected: races live fan-out
  units (the ENOENT hazard above).
- **Add a live-process guard instead of restricting to merged.** More moving
  parts (lsof/cwd scanning, macOS-specific, slow) for the same outcome
  merged-only gives for free; merged is a stronger, simpler signal that the unit
  is done.
- **Fold into PR #160.** Rejected: destructive-on-a-timer warrants its own PR +
  ADR and its own review; #160 is presented for merge.
