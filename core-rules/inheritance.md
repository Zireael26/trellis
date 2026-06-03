# Load-bearing inheritance mechanism

Claude Code does **not** cascade `CLAUDE.md` up the directory tree — a child session loads the nearest `CLAUDE.md` and nothing above it unless the child explicitly names a parent. There are two documented mechanisms for explicit inheritance, and they behave very differently.

## Primary — `.claude/rules/` symlink (REQUIRED for every registered project)

Each project under `registry.md` MUST carry a symlink at:

    <project-root>/.claude/rules/trellis.md → __TRELLIS_PATH__/core-rules/CLAUDE.md

Claude Code loads every file under `.claude/rules/` **unconditionally** at session start — no approval dialog, no gate, no TTY dependency. This works identically in interactive and `claude -p` headless modes, which is the property that matters: every automated run (scheduled tasks, cron jobs, subagents, CI) must inherit parent rules without human interaction.

Track the symlink in git so the inheritance is visible in repo state and protected from local deletion. If `.claude/` is gitignored in a project, add explicit exceptions for `.claude/rules/` and `.claude/rules/trellis.md` — otherwise the symlink exists only on one machine.

## Secondary — `@`-import in project `CLAUDE.md` (interactive fallback only)

Every project `CLAUDE.md` also carries an `@`-import line pointing at the canonical path:

    @__TRELLIS_PATH__/core-rules/CLAUDE.md

This is kept for belt-and-braces redundancy in **interactive** sessions only. `@`-imports are gated by Claude Code's trust-verification approval dialog, which:

- Cannot fire in `-p` / headless mode — trust verification is explicitly disabled non-interactively (per Claude Code docs). Unapproved imports silently skip.
- Fires once on the first interactive session that encounters a new `@`-import. Approve → persists per project. Decline → permanently disabled for that project with no further prompt.

So the `@`-import is useful only after a human has clicked "approve" at least once in interactive mode. It is never load-bearing for automation and must never be treated as the primary inheritance path.

## Silent-drop invariants

1. If either the symlink target or the `@`-import path does not resolve on disk, Claude Code drops the instruction with **no runtime error, no warning, no user-visible log line.** Detection is only possible via the `InstructionsLoaded` hook (`~/.claude/hooks/log-instructions-loaded.sh` → `~/.claude/instruction-audit.log`), and even that captures `session_start` reliably but not every include-style event.
2. When this parent directory moves, the symlinks in all five projects break at once. Update them in the same filesystem change as the move, or accept that every child session will silently run unparented until the next scheduled audit catches the drift.
3. Never replace the symlink with a file copy. A copy diverges. Divergence kills the whole point of a parent layer.

## Registered-project checklist

Every project in `registry.md` must:

- [ ] Contain `CLAUDE.md` at the project root.
- [ ] Contain `.claude/rules/trellis.md` as a symlink to the canonical core-rules path.
- [ ] Track `.claude/rules/trellis.md` in git (including `.gitignore` exceptions where needed).
- [ ] Contain the `@`-import line in the project `CLAUDE.md` for interactive fallback.
- [ ] Contain `.claude/skills/process-gate/` as a symlink to the canonical skills path (see "Skills inheritance" above).
- [ ] If Codex- or AntiGravity-enabled (`harnesses` includes `"codex"` or `"antigravity"`): contain root `AGENTS.md`, `.agents/rules/trellis.md`, `.agents/skills/process-gate/`, and `.agents/skills/process-gate-local/local.config.sh`.
- [ ] If Codex-enabled additionally: `.codex/hooks.json`, executable `.codex/hooks/*.sh`, and `.agents/commands/{primer,primer-refresh,primer-check,explore}.md` symlinks.
- [ ] If AntiGravity-enabled additionally: `.agents/workflows/{primer,primer-refresh,primer-check,explore}.md` symlinks. **No** `.antigravity/` directory — AntiGravity hook integration is deferred.
- [ ] Have GitHub branch protection enabled on `main` (see `registry.md` step 5).

## Skills inheritance (process-gate + future canonical skills)

Canonical skills live under `core-rules/skills/<name>/` and are inherited via symlinks identical in shape to the rules symlink:

    <project-root>/.claude/skills/<name>/  →  __TRELLIS_PATH__/core-rules/skills/<name>/
    <project-root>/.agents/skills/<name>/  →  __TRELLIS_PATH__/core-rules/skills/<name>/

The directory itself is symlinked (not individual files) so additions to canonical files appear automatically without per-project re-onboarding. Project-local overrides go in `<project-root>/.claude/skills/<name>/local.config.sh` (or other ungitignored override file the skill defines) — these are project-private, NOT covered by the canonical symlink.

As of Phase 6 (2026-06-02), nine canonical skills ship: `process-gate`, `security-gate` (always-on), the opt-in pipeline `clarify`, `spec`, `plan`, `tasks`, `analyze`, the canonical builder `execute` (shipped Phase 4), and the ideation front-door `brainstorming` (shipped Phase 6). (Was seven as of Phase C, 2026-05-12, before `execute` and `brainstorming`.)

Same silent-drop invariant: if the symlink target moves or breaks, the skill simply does not load — no error. Detected by the extended `parent-hook-drift` audit (skills coverage), not at session time.

### Skill path-scoping (optional, project-local)

Canonical skills are global by design — they apply to the whole repo, regardless of which subtree the agent is editing. That works because every canonical skill is workflow-shaped, not language-shaped: `process-gate`, `security-gate`, and the two `brainstorming` front-door routes — the lightweight track `brainstorming` → `docs/plans` → `execute`, and the heavyweight spec-kit pipeline `clarify` → `spec` → `plan` → `tasks` → `analyze` → `execute`.

**Project-local skills can opt into path-scoping.** A project-local skill (one that does NOT come from the canonical symlink — typically lives at `<project>/.claude/skills/<custom-name>/` and is project-owned) may carry a `scope.json` next to its `SKILL.md`:

    {
      "paths": ["services/**", "pkg/**"],
      "reason": "Go-only validators; would noise non-Go subtrees"
    }

When `scope.json` is present, the agent reads it at session start and only auto-mentions the skill when the session's working tree (or the changed files this turn) falls under at least one of the listed globs. The agent still **can** invoke the skill explicitly via `/skill <name>` from any path; the scope only controls auto-invocation.

This is a Trellis convention, not a Claude Code engine feature. The agent is expected to honour it because every project loads `core-rules/CLAUDE.md` and that file directs scope-respecting behaviour. If you find yourself wanting to write a canonical skill with a `scope.json`, the skill is probably mis-shaped — split it into a workflow part (canonical, global) and a stack-specific part (project-local, scoped).

Schema (one entry per skill):

| Field | Required | Meaning |
|---|---|---|
| `paths` | yes | Glob array (POSIX-style, project-relative). At least one element. |
| `reason` | yes | One-line human note for the audit trail. Travels with the file. |
| `also_active_when` | no | Free-form selector list for follow-up scoping (e.g., `["touched_files: services/**/*.go"]`). Reserved; agent treats as advisory only. |

## Presets inheritance (opt-in rule layering)

Presets are the rules-side counterpart to the skills inheritance above: opt-in layers that sit on top of the parent CLAUDE.md. Each preset is a single markdown file at `core-rules/presets/<name>.md`. Projects opt in via the `presets` array in `<project>/.trellis.config.json` (or `trellis.config.json`).

For each declared preset, parallel symlinks land at:

    <project-root>/.claude/rules/preset-<name>.md  →  __TRELLIS_PATH__/core-rules/presets/<name>.md
    <project-root>/.agents/rules/preset-<name>.md  →  __TRELLIS_PATH__/core-rules/presets/<name>.md

Both harnesses load every file under their rules directory and add the content to the agent's prompt — rules are additive, not last-wins. There is no mechanical "override". The "priority" framing in `engineering-process.md §14.8` is a conceptual contract for how an agent should resolve apparent conflicts between layers (later layers in the parent < preset < project-local chain are more specific and should win), not a directive that the engine enforces. If a preset's prose contradicts the parent rules, the preset's wording typically carries because it's more contextual — but the parent rule's voice is still in the context too. Authoring presets means staying additive and carving out explicitly when needed, not relying on naming order to silently override.

Symmetry with skills:

| Aspect | Skills | Presets |
|---|---|---|
| Canonical source | `core-rules/skills/<name>/` (directory) | `core-rules/presets/<name>.md` (single file) |
| Project symlink (Claude) | `.claude/skills/<name>/` | `.claude/rules/preset-<name>.md` |
| Project symlink (Codex) | `.agents/skills/<name>/` | `.agents/rules/preset-<name>.md` |
| Opt-in mechanism | Always seeded by `onboard-project.sh` | Only seeded when project's `.trellis.config.json` declares it |
| Rollout script | `scripts/rollout-feature-skills.sh` | `scripts/rollout-presets.sh` |
| Drift audit | `parent-hook-drift` (skills section) | `scheduled-tasks/preset-drift/` |
| Silent-drop invariant | yes — broken symlink → skill doesn't load | yes — broken symlink → preset rules don't load |

Removing a preset from the project's config + re-running `rollout-presets.sh` prunes the now-stale symlink automatically.

## Multi-harness support (Claude Code + Codex + AntiGravity)

Claude Code is the primary harness. Codex and AntiGravity are secondaries. Trellis is configured per-clone via the `harnesses` array in `trellis.config.json`; when `"codex"` and/or `"antigravity"` is included, onboarding seeds parallel artifact trees pointing at the same canonical sources.

**Canonical file layout under `core-rules/`:**

| Path | Purpose | Used by |
|---|---|---|
| `core-rules/CLAUDE.md` | Parent rules — single source of truth | Claude Code (`.claude/rules/trellis.md` symlink target) |
| `core-rules/AGENTS.md` | Symlink → `CLAUDE.md` | Codex AND AntiGravity (via project root `AGENTS.md` and `.agents/rules/trellis.md`) |
| `core-rules/skills/<name>/` | Canonical skills | All three harnesses via parallel project symlinks |
| `core-rules/commands/<name>.md` | Canonical slash commands | All three harnesses (link target differs per harness: see below) |
| `core-rules/hooks/` | Tier 1 + 2 Claude Code hooks | Claude Code only |
| `core-rules/codex/` | Codex hook manifest + scripts | Codex only |
| `core-rules/husky/` | Tier 3 git hooks | All three (git-level, harness-agnostic) |

**Slash-command directory names differ per engine:**

| Harness | Slash-command directory | Rationale |
|---|---|---|
| Claude Code | `.claude/commands/` | Claude Code convention |
| Codex | `.agents/commands/` | Codex convention; reuses the `AGENTS.md` companion dir |
| AntiGravity | `.agents/workflows/` | AntiGravity convention (official Google codelabs reference) |

All three point at the same canonical files under `core-rules/commands/`. A project enabling all three harnesses ends up with three symlinks (one per harness directory) pointing at the same `primer.md`, `explore.md`, etc.

**What a fully-configured project (Claude + Codex + AntiGravity) looks like:**

```
<project-root>/
├── CLAUDE.md                                                ← Claude Code rules entry
├── AGENTS.md                                                ← symlink → CLAUDE.md (shared: Codex + AntiGravity)
├── .claude/
│   ├── rules/trellis.md   → /…/trellis/core-rules/CLAUDE.md
│   ├── skills/process-gate/ → /…/trellis/core-rules/skills/process-gate/
│   ├── commands/primer.md → /…/trellis/core-rules/commands/primer.md
│   ├── hooks/                                               ← Tier 1+2, Claude-only
│   └── settings.json
├── .agents/                                                 ← shared between Codex and AntiGravity
│   ├── rules/trellis.md   → /…/trellis/core-rules/CLAUDE.md   (same target as .claude/rules/)
│   ├── skills/process-gate/ → /…/trellis/core-rules/skills/process-gate/
│   ├── skills/process-gate-local/local.config.sh
│   ├── primers/INDEX.md                                     ← shared primer index
│   ├── commands/primer.md → /…/trellis/core-rules/commands/primer.md  ← Codex-only
│   └── workflows/primer.md → /…/trellis/core-rules/commands/primer.md ← AntiGravity-only
└── .codex/                                                  ← Codex-only; AntiGravity has no analog
    ├── hooks.json
    └── hooks/*.sh
```

Codex project instructions are loaded from `AGENTS.md`; AntiGravity reads the same `AGENTS.md` plus `.agents/`. Keep `AGENTS.md` as a symlink to `CLAUDE.md` unless a project has a deliberate harness-specific override. Codex hooks require the user-level feature flag in `$CODEX_HOME/config.toml`:

```toml
[features]
hooks = true
```

(The older `[features].codex_hooks` key still works as a deprecated alias but emits a warning on Codex CLI 0.129+. New installs should use `hooks`.)

Tier 3 (husky / native git hooks) covers all three harnesses identically.

For Claude-Code-only projects (default), `.agents/` is omitted entirely.

### Known gap: AntiGravity native hooks deferred

Trellis defers shipping a workspace hook envelope for AntiGravity as of 2026-05-20. The deferral is empirical rather than architectural — AntiGravity 2.0's standalone desktop app does not expose a workspace hooks UI in its Customizations panel, and the workspace hook config path is not documented in the official Google codelabs. (The Antigravity-IDE bundle does contain hook-related code paths internally — events PreToolUse/PostToolUse/Stop and a `hooks.json` reader — but those entry points are not advertised as a public, supported workspace surface today.)

Consequence: Trellis does not seed `.antigravity/` for AntiGravity-enabled projects. Tier 1 and Tier 2 hook enforcement (`block-destructive`, `post-edit-verify`, `stop-verify`, etc.) is **not available** in AntiGravity sessions. Turn-level enforcement on AntiGravity sessions relies on:

- Parent rules via `AGENTS.md` and `.agents/rules/` (load-bearing on every session).
- Canonical skills via `.agents/skills/` (process-gate and security-gate, invoked by name).
- Tier 3 (`husky` / native git hooks) at commit/push boundaries — unaffected by the harness gap.

This gap will be re-evaluated via a fresh ADR when Google publishes a workspace hook API (or formally exposes the existing one). Until then, sessions in `agy` are best treated as Tier-3-gated only; high-risk operations (`rm -rf`, schema mutations) that Tier 1 would normally catch in Claude Code or Codex must be caught at commit time on AntiGravity-only projects.

If a maintainer needs strict tool-call enforcement on AntiGravity, the recommended workaround today is to enable Claude Code alongside (`"harnesses": ["claude", "antigravity"]`) and run risky changes through a Claude session before pushing — Tier 1 + 2 protect the diff before it reaches the AntiGravity branch.

## Native git hooks (Unity / non-Node projects)

Projects without `package.json` (Unity, C#, Rust, Go, Python-only, etc.) cannot use husky. They MUST instead enforce the Trellis PR-flow guard via native git hooks:

- Set `git config core.hooksPath` to a tracked directory (e.g., `.githooks/`).
- That directory MUST contain a `pre-push` whose body includes the canonical Trellis PR-flow guard (block direct push to `main`/`master`, `TRELLIS_ALLOW_MAIN_PUSH=1` override).
- The hooks directory and its scripts MUST be tracked in git so the enforcement is visible in repo state and survives a clone.

Reference example: `lume` (Unity 3D) uses `.githooks/pre-push` with `core.hooksPath = .githooks`. The `cross-project-process-audit` rubric skips the husky-presence check when `package.json` is absent and the native-hooks fallback is in place — see `scheduled-tasks/cross-project-process-audit/prompt.md` §3.

## Worktree inheritance (`git worktree add` re-seeding)

### The problem

All Trellis inheritance symlinks — `.claude/rules/trellis.md`, `.claude/rules/preset-*.md`, `.claude/skills/*`, `.claude/commands/*`, and the `.agents/` mirror — are **gitignored** by design: their targets are absolute paths under each developer's `$TRELLIS_ROOT`, which differs per machine. `git worktree add` materializes only tracked content from the commit. Gitignored files are never recreated in a new worktree.

The consequence is the canonical silent-drop failure: a fresh worktree of any managed project has no parent rules, no skills, no commands. An agent starts without error, without warning, and runs completely unparented. This is the same silent-drop class as a broken symlink target — undetectable at runtime unless the caller checks explicitly.

### The fix: mirror the main checkout

**`scripts/seed-inheritance-symlinks.sh`** is an idempotent seeder. It enumerates the inheritance symlinks already present in the project's **main working tree** (the ones `onboard-project.sh` placed there) and recreates each at the same relative path with the same target in the target worktree. It owns no symlink list and cannot drift from onboard; new skills, presets, and `.agents` entries are covered automatically. Root is resolved from the main checkout's `.claude/rules/trellis.md` symlink target — machine-local, correct on every developer's clone.

### Four triggers

One seeder; four contexts that call it:

1. **`core-rules/githooks/post-checkout`** (eager, native-hooks projects only) — fires on `git worktree add`. Installed by `onboard-project.sh` only when `core.hooksPath` points at a tracked directory (native-`.githooks` projects: lume, clusterbid-console; plain-git: `.git/hooks`). Always `exit 0` — seeding failure never aborts the worktree creation.

2. **`trellis worktree add|sync`** (universal — use this) — wraps `git worktree add` and calls the seeder immediately after. Works on every project, regardless of hook type. `trellis worktree sync [<path>]` re-seeds an existing worktree. This is the recommended way to create worktrees of Trellis-managed projects.

3. **SessionStart safety-net** (`core-rules/hooks/session-context.sh` + codex mirror) — on session start in a linked worktree, runs the seeder in verify-only mode; if symlinks are missing, seeds them (for the *next* session) and emits a loud restart warning. Cannot heal the current session — skills are enumerated at process init before any SessionStart hook filesystem change lands (verified). Converts the silent-drop into a visible, self-repairing event.

4. **`doctor` `hc_worktree_inheritance` check + `--fix`** — Tier-1 doctor check; enumerates `git worktree list` and reports linked worktrees with missing inheritance. `doctor --fix` (gated by the Tier-0 canonical-on-main guard) repairs them via the seeder.

### Per-project capability

The eager git hook is unavailable on husky projects. Husky v9 sets `core.hooksPath=.husky/_` and `.husky/_` (the dispatch directory) is gitignored — it never materializes in a worktree. Any `post-checkout` placed in the dispatch dir is dead. This is the same bug class as the inheritance symlinks themselves, verified on neev.

| Project type | Eager hook | `trellis worktree add` | Raw `git worktree add` → first session |
|---|---|---|---|
| native-`.githooks` (lume, clusterbid-console) | ✓ correct | ✓ correct | **first-session-correct** |
| husky (neev, tgsc, akaushik.org, curat.money, vericite) | ✗ dead | ✓ correct | unparented → SessionStart warns + seeds-for-next → restart |

No project ever fails silently. The silent-drop invariant that governs rules and skills symlinks throughout this document holds for worktrees too — but only because the seeder + triggers make silence structurally impossible.
