# ADR — Worktree lifecycle: janitor reaps pushed+clean trees; `fanout-verify` self-reaps; early tripwire

**Date:** 2026-07-16 · **Status:** accepted
> **Retirement boundary — former `codex-fanout` follow-up #1.** PR #162
> accepted the caller-provisioned conflicting-unit reap doctrine; commit
> `2ad1808` later retired it. Its [companion ADR](2026-07-16-orchestrator-conflicting-unit-reap.md)
> remains field evidence only, not current reaping guidance. This leaves Spec
> 016's `fanout-verify` teardown, generic `disk-janitor` safe reaping (including
> manual-delegation worktrees), manual `--apply`, and the separately accepted
> opt-in scheduled merged-only `--safe-only` apply path live.

## Context

The control-plane Mac fills to 100% roughly weekly. The June cache blow-up
(`2026-06-02-disk-janitor.md`, disk-janitor v0.9.0) is fixed and holding. The
new recurring cost is **orphaned git worktrees from Codex audit-remediation
fan-out**.

Incident forensics (2026-07-16, 3.3 GiB free / 100% full): 224 linked worktrees
fleet-wide (126 on `the monorepo project` alone); `/private/tmp` 148 GB, `the monorepo project-worktrees`
137 GB, `the RAG service-worktrees` 28 GB; each tree 1–3 GB. The janitor reported
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
mutates a verdict.

> **Historical retired exception — former `codex-fanout` / follow-up #1.** Its
> caller-provisioned conflicting-unit worktree carried an uncommitted diff; the
> post-commit+push orchestrator reap was accepted in PR #162, then retired by
> commit `2ad1808`. The
> [companion ADR](2026-07-16-orchestrator-conflicting-unit-reap.md) preserves
> that field evidence; it is not current routing or reaping guidance.

New config (all under `disk_janitor`, all defaulted):
`reap_pushed_worktrees=true`, `ephemeral_tmp_ttl_days=2`,
`worktree_count_ceiling=25`, `worktree_total_gb_ceiling=80`.

## Consequences

- **Fixed:** surprise-100% (the tripwire warns early) and unsafe/tedious cleanup
  (reclaim is now one `--apply` over a provably-safe, secret-aware set). The
  janitor can finally *see* the fan-out flood it previously reported as
  `0 B reclaimable`.
- **Hands-off follow-on shipped separately.** PR #160 initially left `--apply`
  manual. The accepted scheduled-safe-reap ADR later added a separate, opt-in
  `org.trellis.disk-janitor-apply` LaunchAgent that runs the stricter
  merged-only `--safe-only` predicate; the report-only agent remains the default.
  Rollback must unload/remove the apply job before changing the predicate or
  reverting PR #160.
- **Blast radius** of the destructive path is bounded by report-first, manual
  confirmation by default, the scheduled path's merged-only `--safe-only`
  tightening, porcelain-dirty and secret guards, and `git worktree remove`
  preserving every branch ref. PR #160 verified 73/73 bats, shellcheck, and both
  then-present recipes with `node --check`.

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
