# ADR — Worktree lifecycle: janitor reaps pushed+clean trees; fan-out self-reaps; early tripwire

**Date:** 2026-07-16 · **Status:** accepted

## Context

The control-plane Mac fills to 100% roughly weekly. The June cache blow-up
(`2026-06-02-disk-janitor.md`, disk-janitor v0.9.0) is fixed and holding. The
new recurring cost is **orphaned git worktrees from Codex audit-remediation
fan-out**.

Incident forensics (2026-07-16, 3.3 GiB free / 100% full): 224 linked worktrees
fleet-wide (126 on `neev` alone); `/private/tmp` 148 GB, `neev-worktrees`
137 GB, `vericite-worktrees` 28 GB; each tree 1–3 GB. The janitor reported
**`0 B reclaimable` while the disk was full.** Classifying by real
`git status --porcelain`: 157 porcelain-empty (safe — branch ref survives reap),
66 with genuine uncommitted work, 1 live process. Emergency resolved by hand
(reap the 157 + prune pnpm store + strip caches ≈ 206 GB reclaimed, zero work
lost, 100%→83%).

Two structural causes, both required for the flood:

1. **Nothing reaps fan-out worktrees.** The only cleanup was an unenforced text
   hint at `fanout-verify.wf.js:101`. Agents are told "Do NOT merge", so their
   "done" is PR-open (pre-merge); they abandon the tree. The operator merges
   later; no post-merge reaper existed.
2. **The janitor structurally could not reclaim them.** Its reap gate was
   `stale(>30d) AND clean AND merged`. Fan-out trees are fresh (<30d), commonly
   **unmerged-but-pushed** (117/224), and the old clean-gate over-refused on any
   unrecognized gitignored file. All three sub-gates missed the flood.

## Decision

Three layers, config-gated and default-safe.

**Layer 2 — janitor reap predicate (fleet-wide safety net).** Replace the
merged-only gate with:

```
reap iff  porcelain_clean  AND  recoverable  AND  NOT secret_ignored
recoverable = branch_merged OR branch_pushed
```

- `porcelain_clean` is authoritative for "no uncommitted work" — plain
  `git status --porcelain` empty. (git already excludes ignored files; the old
  allowlist clean-gate is retained only for the knob-off path.) A
  porcelain-**dirty** tree is *never* reaped.
- `branch_pushed` = upstream `@{u}` exists and `@{u}..HEAD` count is 0. This is
  the key correctness fix: an unmerged-but-pushed tree is recoverable from
  origin, so it is reapable. `git worktree remove` deletes the checkout, never
  the branch ref.
- **Secret denylist (fail-closed).** A clean+recoverable tree carrying a
  gitignored secret (`.env`, `.env.*`, `.dev.vars`, `.npmrc`, `*.pem`, `*.key`,
  `*.keystore`, `*.jks`, `*.p8`) downgrades to *candidate* (manual), never
  auto-reap — a gitignored secret is not in the object store and is
  unrecoverable.
- **Ephemeral `/private/tmp` path.** A clean tree with no verifiable upstream,
  under `/private/tmp`, older than `ephemeral_tmp_ttl_days`, not detached →
  reapable (these are throwaway by construction); younger or detached →
  candidate; and the secret denylist still applies here.
- `reap_pushed_worktrees:false` reproduces the exact prior predicate — a clean
  opt-out.

**Layer 3 — early tripwire.** Daily `--report` emits a per-repo worktree-**count**
line (WARN above `worktree_count_ceiling`) and an aggregate linked-worktree
**bytes** line (WARN above `worktree_total_gb_ceiling`), so the alarm fires
before the free-space floor rather than after.

**Layer 1 — mechanized reap-at-source.** `fanout-verify.wf.js` gains a
`Teardown` phase: each unit reports its `worktree_path` and leaves the tree in
place; after fan-out, a bounded reap agent **re-verifies at reap time** (linked
non-main worktree, absolute non-root path, porcelain-empty, pushed) before
`git worktree remove` (never `--force`). Teardown is failure-isolated — a
lock/race/refusal leaves the tree (status quo) and never aborts the run or
mutates a verdict. `codex-fanout`'s conflicting-unit worktree is
caller-provisioned with an uncommitted diff, so the recipe documents that the
**orchestrator** reaps it after its own commit+push (follow-up #1).

New config (all under `disk_janitor`, all defaulted):
`reap_pushed_worktrees=true`, `ephemeral_tmp_ttl_days=2`,
`worktree_count_ceiling=25`, `worktree_total_gb_ceiling=80`.

## Consequences

- **Fixed:** surprise-100% (the tripwire warns early) and unsafe/tedious cleanup
  (reclaim is now one `--apply` over a provably-safe, secret-aware set). The
  janitor can finally *see* the fan-out flood it previously reported as
  `0 B reclaimable`.
- **Not yet hands-off.** launchd runs `--report` only; `--apply` stays manual by
  design. Layer 1 auto-cleans **only `fanout-verify`** — not the primary
  historical source (`codex-fanout` / manual delegation trees). So trees still
  accumulate between manual `--apply` runs. Fully closing "don't do this every
  week" needs **either** follow-up #1 (orchestrator-side reap) **or** a scheduled
  `--apply` restricted to the provably-safe set — an operator decision, not
  assumed here.
- **Blast radius** of the one genuinely-destructive line (janitor now `rm`s more
  trees) is bounded by report-first, manual per-category `--apply` confirm, the
  porcelain-dirty and secret guards, and `git worktree remove` preserving every
  branch ref. Verified: 73/73 bats green, shellcheck clean, both recipes
  `node --check` clean.

## Alternatives considered

- **Merged-only reap (status quo predicate, just lower the age).** Rejected:
  117/224 trees were unmerged-but-pushed; age alone never reaches them and
  merged-only misses the majority class.
- **Auto `git fetch --prune` in report.** Rejected: report/dry-run must stay
  non-mutating.
- **Delete trees purely by age/size.** Rejected: destroys uncommitted work;
  porcelain state is the only safe signal.

Full forensics: `specs/016-worktree-lifecycle-reap/` and the
`audits/2026-07-16-*` incident record.
