# 2026-06-02 — Worktree inheritance seeding

## Context

Trellis child projects inherit parent rules, skills, commands, and presets via
**gitignored, machine-absolute symlinks** under `.claude/` (and `.agents/` for
Codex and AntiGravity). The symlinks are gitignored deliberately: their targets
are absolute paths under each developer's own `$TRELLIS_ROOT`, which differs per
machine — committing them would break every other clone.

`git worktree add` materializes only **tracked** content from the commit.
Gitignored files are never recreated in a new worktree. A fresh worktree of any
child project therefore loses **all** Trellis inheritance silently:

- `.claude/rules/trellis.md` — parent rules (the load-bearing primary inherit)
- `.claude/rules/preset-*.md` — opt-in rule layers
- `.claude/skills/*` (7) — process-gate, security-gate, clarify, spec, plan, tasks, analyze
- `.claude/commands/*.md` (5) — primer, primer-refresh, primer-check, explore, autonomy
- `.agents/*` mirror — Codex and AntiGravity equivalents

The reported symptom was a missing `process-gate` skill, but the silent loss of
parent rules is the larger bug: an agent in a worktree runs unparented with no
error, no warning, no log line — the canonical Trellis silent-drop failure mode.

Two empirical findings (verified 2026-06-02) shaped the solution:

1. **A SessionStart hook cannot heal the current session.** A hook that creates
   a skill symlink at SessionStart fired (verified by marker + symlink creation
   mid-session) but the same session still reported the skill as unavailable.
   Skills are enumerated at process init, before SessionStart hook filesystem
   changes land. SessionStart can only fix the *next* session, plus warn.

2. **Husky's dispatch directory is gitignored, so a `post-checkout` hook is
   dead in worktrees on husky projects.** Husky v9 sets `core.hooksPath=.husky/_`
   and `.husky/_/.gitignore` is `*` (husky-generated). In a worktree `.husky/_`
   never materializes (same bug class as the inheritance symlinks), so git finds
   no dispatch directory — the hook never fires. Verified live on neev: `.husky/_`
   absent in the worktree, `core.hooksPath` still `.husky/_`, no post-checkout fires.
   A `post-checkout` in the tracked `.husky/` wrapper layer is also unreachable
   because the dispatch dir is what git invokes first.

These two findings constrain the solution space: no single mechanism works on
every project and every session. The architecture must compose multiple triggers
so that no project ever fails silently, even if the first-session experience
differs by hook type.

## Decision

Add **`scripts/seed-inheritance-symlinks.sh`** — an idempotent seeder that
mirrors the main checkout's inheritance symlinks into a target worktree — and
wire it through **four triggers** covering every project type and session
boundary:

1. **`core-rules/githooks/post-checkout`** (eager, native-hooks projects only) —
   fires on `git worktree add`, detects linked worktree, seeds immediately,
   always `exit 0`. Installed by `onboard-project.sh` only when `core.hooksPath`
   points at a tracked directory (native-`.githooks`: lume, clusterbid-console;
   plain-git: `.git/hooks`). Not installed on husky projects — dead there by
   finding #2 above.

2. **`trellis worktree add|sync`** (universal eager front door) — a new
   subcommand in `scripts/trellis` that wraps `git worktree add` and calls the
   seeder immediately after. Works on every project regardless of hook type, since
   it does not depend on a git hook firing. This is the **recommended path** for
   all Trellis-managed projects.

3. **SessionStart safety-net** (`core-rules/hooks/session-context.sh` +
   `core-rules/codex/hooks/session-context.sh`) — on session start, checks if
   cwd is a linked worktree with missing inheritance; if so, runs the seeder
   (repairs for the *next* session per finding #1) and emits a loud restart
   warning. Universal — fires on every project where SessionStart fires.

4. **`doctor` `hc_worktree_inheritance` check + `--fix` repair** — Tier-1 doctor
   check enumerates linked worktrees and reports any missing core symlinks;
   `--fix` (gated by the existing Tier-0 canonical-on-main guard) runs the seeder
   on each offending worktree. The backstop for unattended or pre-ship gaps.

**Seeder approach: mirror the main checkout, not re-derive from config.** The
seeder enumerates the inheritance symlinks already present in the project's own
main working tree (the symlinks `onboard-project.sh` created) and recreates each
at the same relative path with the same target. The main checkout is the single
source of truth; the seeder owns no symlink list and cannot drift from onboard.
New skills, presets, or `.agents` entries land automatically with no seeder
change. `onboard-project.sh`'s symlink phase is deliberately left untouched —
lower blast radius on a load-bearing script; onboard gains only one small,
additive step (the post-checkout hook install for native-hooks projects).

The seeder resolves `$TRELLIS_ROOT` from the main checkout's
`.claude/rules/trellis.md` symlink target, so it works correctly on every
developer's machine without any manual configuration: symlinks in the worktree
point at *their* `$TRELLIS_ROOT`, never the original author's.

## Consequences

**Per-project capability matrix:**

| Project type | Eager hook | `trellis worktree add` | Raw `git worktree add` → first session |
|---|---|---|---|
| native-`.githooks` (lume, clusterbid-console) | ✓ correct | ✓ correct | **first-session-correct** (hook fires) |
| husky (neev, tgsc, akaushik.org, curat.money, vericite) | ✗ dead | ✓ correct | unparented → SessionStart seeds-for-next + **loud warn** → restart |

No project ever fails silently. "First-session-correct on raw `git worktree add`"
holds for native-hooks projects. Husky projects are first-session-warned +
second-session-correct unless `trellis worktree add` is used. The loud
SessionStart warning names the restart requirement explicitly — the silent-drop
failure mode is eliminated.

**Teammate safety.** All seeded symlinks are gitignored (the existing gitignore
fragment is tracked, so they are gitignored in every worktree too). They are
machine-local by construction: root is resolved from the teammate's own main
checkout symlink. No committed artifact ever encodes a developer-specific path.

**Depth-2 bound.** The seeder's main-checkout detection (`git worktree list
--porcelain` first entry) means the seeder only seeds a linked worktree relative
to its own project's main checkout. A nested worktree-of-a-worktree is not
re-mirrored (bounded to depth 2); this is an accepted edge case.

**Branch-preset gap.** A worktree on a branch whose `.trellis.config.json`
declares a preset not yet present in the main checkout will not get that preset's
symlink (the main checkout has no symlink to mirror). Accepted, documented; `trellis
worktree sync` can re-seed if needed after the preset reaches the main checkout.

**onboard's symlink phase is untouched.** The seeder's additive approach means
`onboard-project.sh` remains the canonical tool for the initial symlink layout;
the seeder is a complementary runtime that propagates what onboard already
established.

## Alternatives considered

**Re-derive the symlink list from `trellis.config.json` + skills/presets config
(instead of mirroring the main checkout).** Rejected: any derivation logic
duplicates knowledge that `onboard-project.sh` already encodes, creating a drift
surface. If onboard gains a new skill or a preset changes name, the re-derivation
path would need a parallel update. The mirror approach owns no list and is
immune to this class of drift.

**SessionStart-only (no eager hook, no wrapper).** Rejected: finding #1
confirmed that SessionStart cannot heal the current session — skills are
enumerated at process init. A SessionStart-only solution would require a session
restart on every raw `git worktree add` for every project, with no way to make
the first session correct. The eager hook + wrapper eliminate this restart
requirement for well-configured projects.

**Install `post-checkout` via husky's tracked `.husky/` directory.** Rejected:
finding #2 confirmed the dispatch is dead. Husky v9 invokes hooks through
`.husky/_/` (the gitignored dispatch dir), which is absent in worktrees. The
tracked `.husky/post-checkout` is unreachable. Any solution relying on husky's
dispatch layer fails on the five husky projects in the fleet.

## Related

- Seeder: `scripts/seed-inheritance-symlinks.sh`.
- Eager hook: `core-rules/githooks/post-checkout`.
- Wrapper: `scripts/worktree.sh`, `scripts/trellis`.
- Doctor check: `scripts/lib/health-checks.sh` `hc_worktree_inheritance`.
- Safety-net hooks: `core-rules/hooks/session-context.sh`, `core-rules/codex/hooks/session-context.sh`.
- Invariants: `core-rules/inheritance.md` (new "Worktree inheritance" section).
- Design spec (full verified findings + algorithm): `docs/specs/2026-06-02-worktree-inheritance-design.md`.
- Prior doctor ADR: `docs/adr/2026-05-30-trellis-doctor.md`.
