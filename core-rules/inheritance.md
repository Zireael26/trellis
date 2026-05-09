# Load-bearing inheritance mechanism

Claude Code does **not** cascade `CLAUDE.md` up the directory tree — a child session loads the nearest `CLAUDE.md` and nothing above it unless the child explicitly names a parent. There are two documented mechanisms for explicit inheritance, and they behave very differently.

## Primary — `.claude/rules/` symlink (REQUIRED for every registered project)

Each project under `registry.md` MUST carry a symlink at:

    <project-root>/.claude/rules/se-core.md → __SE_CORE_PATH__/core-rules/CLAUDE.md

Claude Code loads every file under `.claude/rules/` **unconditionally** at session start — no approval dialog, no gate, no TTY dependency. This works identically in interactive and `claude -p` headless modes, which is the property that matters: every automated run (scheduled tasks, cron jobs, subagents, CI) must inherit parent rules without human interaction.

Track the symlink in git so the inheritance is visible in repo state and protected from local deletion. If `.claude/` is gitignored in a project, add explicit exceptions for `.claude/rules/` and `.claude/rules/se-core.md` — otherwise the symlink exists only on one machine.

## Secondary — `@`-import in project `CLAUDE.md` (interactive fallback only)

Every project `CLAUDE.md` also carries an `@`-import line pointing at the canonical path:

    @__SE_CORE_PATH__/core-rules/CLAUDE.md

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
- [ ] Contain `.claude/rules/se-core.md` as a symlink to the canonical core-rules path.
- [ ] Track `.claude/rules/se-core.md` in git (including `.gitignore` exceptions where needed).
- [ ] Contain the `@`-import line in the project `CLAUDE.md` for interactive fallback.
- [ ] Contain `.claude/skills/process-gate/` as a symlink to the canonical skills path (see "Skills inheritance" above).
- [ ] If Codex-enabled (`harnesses` includes `"codex"` in `se-core.config.json`): contain root `AGENTS.md`, `.agents/rules/se-core.md`, `.agents/skills/process-gate/`, `.agents/skills/process-gate-local/local.config.sh`, `.codex/hooks.json`, and executable `.codex/hooks/*.sh`.
- [ ] Have GitHub branch protection enabled on `main` (see `registry.md` step 5).

## Skills inheritance (process-gate + future canonical skills)

Canonical skills live under `core-rules/skills/<name>/` and are inherited via symlinks identical in shape to the rules symlink:

    <project-root>/.claude/skills/<name>/  →  __SE_CORE_PATH__/core-rules/skills/<name>/
    <project-root>/.agents/skills/<name>/  →  __SE_CORE_PATH__/core-rules/skills/<name>/

The directory itself is symlinked (not individual files) so additions to canonical files appear automatically without per-project re-onboarding. Project-local overrides go in `<project-root>/.claude/skills/<name>/local.config.sh` (or other ungitignored override file the skill defines) — these are project-private, NOT covered by the canonical symlink.

The current canonical skill is `process-gate`. See `core-rules/skills/process-gate/SKILL.md` for the contract.

Same silent-drop invariant: if the symlink target moves or breaks, the skill simply does not load — no error. Detected by the extended `parent-hook-drift` audit (skills coverage), not at session time.

## Multi-harness support (Claude Code + Codex)

Claude Code is the primary harness. Codex is the secondary. SE Core is configured per-project via `harnesses` in `se-core.config.json` (Phase B); when `"codex"` is included, onboarding seeds both `.claude/` and `.agents/` artifact trees as parallel symlinks pointing at the same canonical sources.

**Canonical file layout under `core-rules/`:**

| Path | Purpose | Used by |
|---|---|---|
| `core-rules/CLAUDE.md` | Parent rules — single source of truth | Claude Code (`.claude/rules/se-core.md` symlink target) |
| `core-rules/AGENTS.md` | Symlink → `CLAUDE.md` | Codex (when `<project>/AGENTS.md` symlinks here, or `.agents/rules/se-core.md` does) |
| `core-rules/skills/<name>/` | Canonical skills | Both harnesses via parallel project symlinks |
| `core-rules/hooks/` | Tier 1 + 2 Claude Code hooks | Claude Code |
| `core-rules/codex/` | Codex hook manifest + scripts | Codex |
| `core-rules/husky/` | Tier 3 git hooks | Both harnesses (git-level, harness-agnostic) |

**What a Codex-enabled project looks like:**

```
<project-root>/
├── CLAUDE.md                                                ← Claude Code rules entry
├── AGENTS.md                                                ← symlink → CLAUDE.md (or its own equivalent)
├── .claude/
│   ├── rules/se-core.md   → /…/se-core/core-rules/CLAUDE.md
│   ├── skills/process-gate/ → /…/se-core/core-rules/skills/process-gate/
│   ├── hooks/                                               ← Tier 1+2, Claude-only
│   └── settings.json
├── .agents/
│   ├── rules/se-core.md   → /…/se-core/core-rules/CLAUDE.md   (same target as .claude/rules/)
│   ├── skills/process-gate/ → /…/se-core/core-rules/skills/process-gate/
│   └── skills/process-gate-local/local.config.sh
└── .codex/
    ├── hooks.json
    └── hooks/*.sh
```

Codex project instructions are loaded from `AGENTS.md`; keep it as a symlink to `CLAUDE.md` unless the project has a deliberate Codex-specific override. Codex hooks require the user-level feature flag in `$CODEX_HOME/config.toml`:

```toml
[features]
codex_hooks = true
```

Tier 3 (husky / native git hooks) covers both harnesses identically.

For Claude-Code-only projects (default), `.agents/` is omitted entirely.

## Native git hooks (Unity / non-Node projects)

Projects without `package.json` (Unity, C#, Rust, Go, Python-only, etc.) cannot use husky. They MUST instead enforce the SE Core PR-flow guard via native git hooks:

- Set `git config core.hooksPath` to a tracked directory (e.g., `.githooks/`).
- That directory MUST contain a `pre-push` whose body includes the canonical SE Core PR-flow guard (block direct push to `main`/`master`, `SE_CORE_ALLOW_MAIN_PUSH=1` override).
- The hooks directory and its scripts MUST be tracked in git so the enforcement is visible in repo state and survives a clone.

Reference example: `lume` (Unity 3D) uses `.githooks/pre-push` with `core.hooksPath = .githooks`. The `cross-project-process-audit` rubric skips the husky-presence check when `package.json` is absent and the native-hooks fallback is in place — see `scheduled-tasks/cross-project-process-audit/prompt.md` §3.
