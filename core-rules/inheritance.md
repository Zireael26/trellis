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
- [ ] If Codex-enabled (`harnesses` includes `"codex"`): contain root `AGENTS.md`, `.agents/rules/trellis.md`, `.agents/skills/process-gate/`, and `.agents/skills/process-gate-local/local.config.sh`.
- [ ] If Codex-enabled additionally: `.codex/hooks.json`, executable `.codex/hooks/*.sh`, `.agents/commands/{primer,primer-refresh,primer-check,explore}.md` symlinks, and `.agents/workflows/{primer,primer-refresh,primer-check,explore}.md` symlinks (workflow-style command surface Codex also reads).
- [ ] Contain the exact Trellis-owned OMP surface: `.omp/AGENTS.md`, `.omp/skills`, `.omp/commands`, `.omp/agents`, and `.omp/hooks` as absolute symlinks to the targets in the OMP table below; the generated managed-ignore block covers them.
- [ ] Have GitHub branch protection enabled on `main` (see `registry.md` step 5).

## Skills inheritance (process-gate + future canonical skills)

Canonical skills live under `core-rules/skills/<name>/` and are inherited via symlinks identical in shape to the rules symlink:

    <project-root>/.claude/skills/<name>/  →  __TRELLIS_PATH__/core-rules/skills/<name>/
    <project-root>/.agents/skills/<name>/  →  __TRELLIS_PATH__/core-rules/skills/<name>/

The directory itself is symlinked (not individual files) so additions to canonical files appear automatically without per-project re-onboarding. Project-local overrides go in `<project-root>/.claude/skills/<name>/local.config.sh` (or other ungitignored override file the skill defines) — these are project-private, NOT covered by the canonical symlink.

As of 2026-07-09, twelve canonical skills ship: `process-gate`, `security-gate` (always-on), the pipeline `clarify`, `spec`, `plan`, `tasks`, `analyze` (opt-in by default; enforceable above a size floor via `mandatory_pipeline`, spec 006), the canonical builder `execute` (shipped Phase 4), the ideation front-door `brainstorming` (shipped Phase 6), the dynamic-workflow orchestration kit `orchestrate` (capability-gated: runs the recipe's workflow script when the harness exposes a subagent-orchestration tool, otherwise degrades to running the same stages by hand), the explicit teach-it-back skill `debrief` (explicit-invoke-only, never auto-fires: teaches the human the change just made, gated incremental, verifying understanding before advancing), and the publishing skill `writing` (explicit-invoke-only, spec 010: drafts and publishes blogs + X threads in the author's voice, gated by a scriptable anti-AI-tell check; posting leg capability-gated, degrades to draft handoff). (Was eleven before `writing`, 2026-06-05; nine before `orchestrate`; seven as of Phase C, 2026-05-12, before `execute` and `brainstorming`.)

Same silent-drop invariant: if the symlink target moves or breaks, the skill simply does not load — no error. Detected by the extended `parent-hook-drift` audit (skills coverage), not at session time.

## Canonical agents inheritance

Canonical Claude Workflow-agent definitions live under `core-rules/agents/` and
use the same machine-local symlink pattern as skills and commands:

    <project-root>/.claude/agents/<name>.md  →  __TRELLIS_PATH__/core-rules/agents/<name>.md

### Skill path-scoping (optional, project-local)

Canonical skills are global by design — they apply to the whole repo, regardless of which subtree the agent is editing. That works because every canonical skill is workflow-shaped, not language-shaped: `process-gate`, `security-gate`, the two `brainstorming` front-door routes — the lightweight track `brainstorming` → a project-local design plan → `execute`, and the heavyweight spec-kit pipeline `clarify` → `spec` → `plan` → `tasks` → `analyze` → `execute` — and the dynamic-workflow orchestration kit `orchestrate`.

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

Claude Code and Codex load their enabled preset-rule links natively; the OMP adapter injects the same canonical preset content on first agent start. Rules are additive, not last-wins. There is no mechanical "override". The "priority" framing in `engineering-process.md §14.8` is a conceptual contract for how an agent should resolve apparent conflicts between layers (later layers in the parent < preset < project-local chain are more specific and should win), not a directive that the engine enforces. If a preset's prose contradicts the parent rules, that is a bug in the preset — fix the text rather than relying on load order.

Symmetry with skills:

| Aspect | Skills | Presets |
|---|---|---|
| Canonical source | `core-rules/skills/<name>/` (directory) | `core-rules/presets/<name>.md` (single file) |
| Project symlink (Claude) | `.claude/skills/<name>/` | `.claude/rules/preset-<name>.md` |
| Project symlink (Codex) | `.agents/skills/<name>/` | `.agents/rules/preset-<name>.md` |
| Opt-in mechanism | Always seeded by `onboard-project.sh` | Only seeded when project's `.trellis.config.json` declares it |
| Rollout script | `scripts/rollout-feature-skills.sh` | `scripts/rollout-presets.sh` |
| Drift audit | operator hook-drift check | operator preset-drift check |
| Silent-drop invariant | yes — broken symlink → skill doesn't load | yes — broken symlink → preset rules don't load |

Removing a preset from the project's config + re-running `rollout-presets.sh` prunes the now-stale symlink automatically.

## Multi-harness support (Claude Code + Codex + Oh My Pi)

Claude Code is the baseline harness, Codex a parallel native harness, and OMP the third native harness. Trellis is configured per clone via the `harnesses` array in `trellis.config.json`; each enabled value adds its own native surface while pointing at the same canonical policy.

**Canonical file layout under `core-rules/`:**

| Path | Purpose | Used by |
|---|---|---|
| `core-rules/CLAUDE.md` | Parent rules — single source of truth | Claude Code directly; Codex through `AGENTS.md`; OMP through project `.omp/AGENTS.md` |
| `core-rules/AGENTS.md` | Symlink → `CLAUDE.md` | Codex canonical companion |
| `core-rules/skills/<name>/` | Canonical skills | All three harnesses through native links |
| `core-rules/commands/<name>.md` | Canonical slash commands | All three harnesses through native links |
| `core-rules/agents/` | Reserved harness-neutral task-agent root | OMP whole-directory link; currently `.gitkeep` only |
| `core-rules/hooks/` | Canonical Tier 1 + 2 hook scripts | Claude Code directly; OMP through its adapter |
| `core-rules/codex/` | Codex hook manifest + scripts | Codex only |
| `core-rules/omp/` | OMP lifecycle adapter | OMP only |
| `core-rules/husky/` | Tier 3 git hooks | All three (git-level, harness-agnostic) |

**Slash-command directory names differ per engine:**

| Harness | Slash-command directory | Rationale |
|---|---|---|
| Claude Code | `.claude/commands/` | Claude Code convention |
| Codex | `.agents/commands/` | Codex convention; reuses the `AGENTS.md` companion dir |
| Codex (workflows) | `.agents/workflows/` | workflow-style command surface Codex also reads |
| OMP | `.omp/commands/` | Native whole-directory link |

Every command surface resolves to the same canonical files under `core-rules/commands/`. A project enabling all three harnesses exposes those files through each harness's native directory without copied policy.

**What a fully-configured project (Claude + Codex) looks like:**

```
<project-root>/
├── CLAUDE.md                                                ← Claude Code rules entry
├── AGENTS.md                                                ← symlink → CLAUDE.md (Codex)
├── .claude/
│   ├── rules/trellis.md   → /…/trellis/core-rules/CLAUDE.md
│   ├── skills/process-gate/ → /…/trellis/core-rules/skills/process-gate/
│   ├── commands/primer.md → /…/trellis/core-rules/commands/primer.md
│   ├── hooks/                                               ← Tier 1+2, Claude-only
│   └── settings.json
├── .agents/                                                 ← Codex companion dir
│   ├── rules/trellis.md   → /…/trellis/core-rules/CLAUDE.md   (same target as .claude/rules/)
│   ├── skills/process-gate/ → /…/trellis/core-rules/skills/process-gate/
│   ├── skills/process-gate-local/local.config.sh
│   ├── primers/INDEX.md                                     ← shared primer index
│   ├── commands/primer.md → /…/trellis/core-rules/commands/primer.md  ← Codex-only
│   └── workflows/primer.md → /…/trellis/core-rules/commands/primer.md ← Codex (workflow-style command surface)
└── .codex/                                                  ← Codex-only
    ├── hooks.json
    └── hooks/*.sh
```

Codex project instructions are loaded from `AGENTS.md` plus `.agents/`. Keep `AGENTS.md` as a symlink to `CLAUDE.md` unless a project has a deliberate harness-specific override. Codex hooks require the user-level feature flag in `$CODEX_HOME/config.toml`:

```toml
[features]
hooks = true
```

(The older `[features].codex_hooks` key still works as a deprecated alias but emits a warning on Codex CLI 0.129+. New installs should use `hooks`.)

Tier 3 (husky / native git hooks) covers all three harnesses identically.

For Claude-Code-only projects (default), `.agents/` is omitted entirely.

## Oh My Pi — third native harness

Oh My Pi (OMP) is Trellis's **third native harness**. Add `"omp"` to the top-level `harnesses` array to enable its surface; the current private instance enables `["claude", "codex", "omp"]`. The OMP path is additive: onboarding and doctor gate it independently, and do not rewrite Claude Code or Codex rules, settings, hooks, routing, or provider configuration.

### OMP project surface

The Trellis-owned OMP surface is **exactly** these five absolute, machine-local, gitignored symlinks:

| OMP path | Live target | Purpose |
|---|---|---|
| `.omp/AGENTS.md` | `<project-root>/CLAUDE.md` | Project overlay, including its canonical `@<trellis_root>/core-rules/CLAUDE.md` import |
| `.omp/skills` | `<trellis_root>/core-rules/skills` | All canonical skills, including future additions |
| `.omp/commands` | `<trellis_root>/core-rules/commands` | All canonical slash commands, including future additions |
| `.omp/agents` | `<trellis_root>/core-rules/agents` | Reserved task-agent root; contains only `.gitkeep` after GPTX-era custom agents were retired |
| `.omp/hooks` | `<trellis_root>/core-rules/omp/hooks` | Native OMP adapter factories |

Whole-directory links are deliberate: the next OMP discovery pass sees new canonical skills, commands, future harness-neutral agents, and adapters without re-running onboarding. No custom task agent ships today; OMP uses its bundled agents. `.omp/AGENTS.md` points to the **project** `CLAUDE.md`, not directly to the parent file, so the project overlay is not discarded by OMP's native context priority. The adapter additionally injects enabled canonical `preset-*.md` policies because OMP does not natively load Claude's `.claude/rules/` surface. The private canonical checkout is the special case: because it has no root `CLAUDE.md`, its link targets `core-rules/CLAUDE.md` directly. `onboard-project.sh` owns creation and the managed-ignore block; `seed-inheritance-symlinks.sh` mirrors these links into worktrees.

Do not add a `.omp/RULES.md`. Do not generate or overwrite user-owned `.omp/config.yml`, `.omp/mcp.json`, or any other OMP file. Model/provider settings remain operator-owned; `approved_mcps` remains documentary rather than an enforceable MCP allowlist; and OMP memory is not a Trellis context-log or compaction authority. Every Trellis policy surface here is a live link or a runtime adapter, never a copied policy file.

### OMP discovery and freshness

OMP's native provider priority is 100. The **nearest non-empty ancestor `.omp` directory stops project discovery even when its required entries are absent**. A partial, missing, dangling, wrong-target, regular-file, or otherwise non-symlink Trellis-owned path is therefore not harmless fallback: doctor must report it as an inheritance error.

When OMP is enabled, doctor verifies the exact targets and realpaths, target types, canonical-root containment where applicable, the project `CLAUDE.md` parent import, OMP skill/command discovery requirements, the deliberately empty custom-agent root, and the absence of discoverable legacy custom agents. It exits nonzero for any broken or stale OMP inheritance path; a warning is not parity. An OMP-disabled Claude/Codex installation neither requires nor validates `.omp` artifacts.

The links are live, but OMP snapshots discovery and filesystem reads within a running process. A **fresh OMP session** reads the files currently present under `trellis_root` and the project root. After changing a canonical fixture or project overlay, reset OMP discovery explicitly or restart the OMP process; an already-open session does not receive a full in-process hot reload, and onboarding need not be repeated.

### OMP child sessions and adapter

OMP task children inherit skills, templates, workspace data, and extension paths, but OMP excludes `AGENTS.md` from inherited context files and does not natively load Trellis's Claude preset links. The adapter's first `before_agent_start` event injects the live project `CLAUDE.md` when absent and adds enabled canonical presets before the child's first agent run, preserving the project overlay, its canonical parent import, and Trellis preset policy.

The adapter is `core-rules/omp/hooks/pre/trellis.ts`, exposed through `.omp/hooks`. It resolves `trellis_root` and the current project at runtime, translates OMP event payloads to canonical Trellis hook envelopes, and executes the live canonical scripts. Denials map to OMP `{block: true, reason}` results. Unsupported payloads, adapter errors, and script exceptions fail loudly with the exact adapter/script path; they do not silently pass as parity.

### OMP doctor and rollout contract

Doctor statically verifies the links, manifests, import chain, and adapter path. Rollout verification separately loads the adapter and checks its registered events, proves that a fresh headless session sees both parent and project markers, exercises a task child against the same policy, and confirms that a canonical fixture mutation appears after the documented discovery reset or process restart. GPTX and OpenCode remain absent from active Trellis/OMP routing.

An explicit OMP inheritance rollout covers every row in `registry.md`, including registered-but-held rows. Installing the ignored five-link surface does not enroll a held project in scheduled work: normal scheduling continues to honor `blacklist.md`.

### Primary OMP references

- [OMP context files](https://github.com/can1357/oh-my-pi/blob/main/docs/context-files.md)
- [OMP skills](https://github.com/can1357/oh-my-pi/blob/main/docs/skills.md)
- [OMP task-agent discovery](https://github.com/can1357/oh-my-pi/blob/main/docs/task-agent-discovery.md)
- [OMP extensions](https://github.com/can1357/oh-my-pi/blob/main/docs/extensions.md)
- [OMP extension loading](https://github.com/can1357/oh-my-pi/blob/main/docs/extension-loading.md)
- [OMP settings](https://github.com/can1357/oh-my-pi/blob/main/docs/settings.md)
- [OMP native discovery source](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/discovery/builtin.ts)
- [OMP extension event types](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/extensibility/extensions/types.ts)

## Native git hooks (Unity / non-Node projects)

Projects without `package.json` (Unity, C#, Rust, Go, Python-only, etc.) cannot use husky. They MUST instead enforce the Trellis PR-flow guard via native git hooks:

- Set `git config core.hooksPath` to a tracked directory (e.g., `.githooks/`).
- That directory MUST contain a `pre-push` whose body includes the canonical Trellis PR-flow guard (block direct push to `main`/`master`, `TRELLIS_ALLOW_MAIN_PUSH=1` override).
- The hooks directory and its scripts MUST be tracked in git so the enforcement is visible in repo state and survives a clone.

Reference example: a Unity project using `.githooks/pre-push` with `core.hooksPath = .githooks` should be treated as healthy when `package.json` is absent and the native-hooks fallback is in place. Operator process audits should encode the same exception.

### `commit-msg` — use the native hook, not the husky copy

`core-rules/githooks/commit-msg` validates the conventional-commit header in POSIX `sh` with **no Node dependency**. Non-Node projects MUST copy that one, not `core-rules/husky/commit-msg`.

This was a silent hole, and wider than "non-Node": the husky variant shelled out to `./node_modules/.bin/commitlint` and printed `skipping` when it was absent. A fleet check found commitlint actually installed in only **2 of 7** registered projects — so the hook was reporting success while checking nothing almost everywhere, including Node projects that never installed it. Both canonical variants now run the native check; husky's still prefers commitlint where it genuinely exists, since it reads the project's own config.

The native check is header-only by design (type, optional scope, optional `!`, non-empty description, ≤100 chars, no trailing period) and passes machine-generated headers — merge, revert, fixup/squash/amend — untouched. Body and footer rules stay with commitlint. A check that runs everywhere and catches the common mistake beats a thorough one that runs nowhere.

**Projects already carrying the old copy keep skipping until they re-seed it** — `onboard-project.sh` never overwrites an existing file. lume and prana are both in that state today.

## Canonical clone hygiene

The canonical clone (`trellis_root` in `trellis.config.json`) is a **published surface, not a workspace.** Every registered project resolves its rules, skills, and hooks through absolute paths into it, so that clone's branch and working-tree state are inherited *live* by all of them. Checking out a feature branch there, or leaving an edit uncommitted, silently changes governance for every project and every running session — including hook behaviour, which is the part nobody notices until it misfires.

`trellis-doctor` Tier 0 already checks all three conditions (`on main`, `clean`, `in sync with origin`). A Tier 0 failure is **blocking, not advisory**.

### The rule

- Canonical stays on **`main`, clean, in sync with origin**.
- All Trellis work happens in a `git worktree`. Never check out a feature branch in the canonical clone.
- After a Trellis PR merges, fast-forward canonical so projects inherit it.

### Agents enforce this unprompted

Finding canonical off-main or dirty is a **stop-and-fix condition that precedes the task in hand** — not something to report and work around. Recovery, in order:

1. `git add -A && git commit` the working tree as a WIP snapshot. **Prefer this to `git stash`:** a commit stays reachable by branch *and* reflog, survives a failed pop, and does not interact with the shared stash stack that other worktrees can see.
2. Free `main` if another worktree holds it, then `git worktree add <path> <branch>` for the parked work.
3. In the canonical clone: `git checkout main && git merge --ff-only origin/main`.
4. In the new worktree: `git reset HEAD~1` (mixed) to restore the exact prior state — tracked files modified, previously-untracked files untracked again.

Verify by comparing dirty-entry count and commits-ahead before and after; they must match. Never discard, never force-push, never resolve this by deleting work.

### What this does not solve

Projects still track `main`, so a bad merge reaches all of them on the next fast-forward. This bounds the blast radius from *any keystroke* to *any merge* — it is not isolation. True immunity needs `trellis_root` pinned to a tag with deliberate roll-forward; adopt that only if a bad merge actually bites.

`~/.claude/agents/` symlinks are the same class of problem: they resolve into the canonical checkout, so a fast-forward there changes agents mid-session for every live session. Use a pinned worktree at `origin/main` for that path if agent stability matters.

## Worktree inheritance (`git worktree add` re-seeding)

### The problem

All Trellis inheritance symlinks — `.claude/rules/trellis.md`, `.claude/rules/preset-*.md`, `.claude/skills/*`, `.claude/commands/*`, `.claude/agents/*`, the `.agents/` mirror, and the five `.omp` paths (`AGENTS.md`, `skills`, `commands`, `agents`, `hooks`) — are **gitignored** by design: their targets are absolute paths under each developer's `$TRELLIS_ROOT`, which differs per machine. `git worktree add` materializes only tracked content from the commit. Gitignored files are never recreated in a new worktree.

The consequence is the canonical silent-drop failure: a fresh worktree of any managed project has no parent rules, no skills, no commands, and no canonical Workflow agents. An agent starts without error, without warning, and runs completely unparented. This is the same silent-drop class as a broken symlink target — undetectable at runtime unless the caller checks explicitly.

### The fix: mirror the main checkout

**`scripts/seed-inheritance-symlinks.sh`** is an idempotent seeder. It enumerates the inheritance symlinks already present in the project's **main working tree** (the ones `onboard-project.sh` placed there) and recreates each at the same relative path with the same target in the target worktree. It owns no symlink list and cannot drift from onboard; new skills, presets, `.agents` entries, and `.omp` entries are covered automatically. Root is resolved from the main checkout's `.claude/rules/trellis.md` symlink target — machine-local, correct on every developer's clone.

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
