# Trellis — engineering process manual

**Owner:** __MAINTAINER_NAME__ (solo maintainer)
**Status:** Authoritative. Updates only via PR against `~/projects/trellis-instance/`.
**Last revised:** 2026-05-02

This is the single human-readable source of truth for how engineering is done under the Trellis regime. Everything elaborated here is grounded in the machinery that already exists in `~/projects/trellis-instance/` — specs in `core-rules/`, canonical hooks in `core-rules/hooks/`, the project list in `registry.md`, and the scheduled audits in `scheduled-tasks/`. This manual narrates and connects them; it does not duplicate them. When a section points at a sibling file, that file is the deep dive.

---

## Table of contents

1. [Introduction](#1-introduction)
2. [Philosophy](#2-philosophy)
3. [The control plane](#3-the-control-plane)
4. [Project regime](#4-project-regime)
5. [Hook enforcement](#5-hook-enforcement)
6. [Git workflow](#6-git-workflow)
7. [Definition of done](#7-definition-of-done)
8. [Code quality standards](#8-code-quality-standards)
9. [Documentation standards](#9-documentation-standards)
10. [Onboarding a new project](#10-onboarding-a-new-project-full-playbook)
11. [Scheduled audits & the feedback loop](#11-scheduled-audits--the-feedback-loop)
12. [Incident response & rollback](#12-incident-response--rollback)
13. [Secrets & dependency management](#13-secrets--dependency-management)
14. [Evolving Trellis](#14-evolving-trellis)
15. [Glossary & quick reference](#15-glossary--quick-reference)

---

## 1. Introduction

### What Trellis is

Trellis is a shared engineering-process regime that a set of opt-in personal projects inherit from. It lives in `~/projects/trellis-instance/` and manifests in each registered project as:

- A `.claude/rules/trellis.md` symlink for Claude Code and `AGENTS.md` / `.agents/rules/trellis.md` for Codex, all pointing at the canonical parent rules.
- Canonical hooks deployed under `.claude/hooks/` for Claude Code and `.codex/` for Codex that enforce the rules mechanically at tool-use time.
- Weekly and monthly audits that scan every registered project for drift and write reports to `~/projects/trellis-instance/audits/`.

The goal: shared high standards across projects without hand-enforcing them per session.

### Why this manual exists

The specs (`core-rules/CLAUDE.md`, `hooks.md`, `inheritance.md`) are terse and LLM-optimized. They tell Claude *what* to enforce. They don't explain *why*, don't narrate the workflow end-to-end, and don't give a human reader (you, your future self, or a collaborator) a single place to ramp on the whole regime. This manual fills that gap.

### Audience

- **You (Abhishek)** — when you need to remember what the policy is, when you need to decide whether a pattern should be lifted into the parent, or when you're about to change something about the process.
- **Your LLM collaborators** — Claude Code, Codex, and headless audit runners — already load the parent rules via the inheritance mechanism. This manual is a companion for human-readable context that can be referenced on demand.
- **Future contributors** — if Trellis ever has other humans working inside it, this is the doc that onboards them.

### Scope

Trellis covers engineering process for *personal* projects under `~/projects/personal/`. Work projects, client engagements, and throwaway experiments are out of scope — this regime is opinionated, prescriptive, and designed around solo-dev-with-high-standards dynamics. If a project opts into Trellis it commits to the whole stack; partial adoption is not supported.

---

## 2. Philosophy

Five principles the manual comes back to:

**1. Parent/child layered rules, Rule of Three for promotion.** Cross-cutting rules live in the parent (`core-rules/CLAUDE.md` + `hooks.md`). Project-specific rules live in each project's own `CLAUDE.md`. A rule earns parent status only when three independent projects adopt it; n=2 is the danger zone where you lock in the wrong abstraction. Candidates waiting for their third witness live in `core-rules/deferred.md`. See [§14](#14-evolving-trellis).

**2. Process is code.** Every rule that can be mechanically enforced becomes a hook. Hooks fail closed (block the agent or fail the build). Written rules that depend on good intentions erode in under a month; written rules backed by a hook persist until the hook is deleted. See [§5](#5-hook-enforcement).

**3. Receipts over self-reporting.** "Done" means you attach the verification command, the exit code, and the diff lines that prove the change. "It works" without receipts is not done. The `stop-verify` hook enforces the underlying checks; the presentation discipline is on the agent. See [§7](#7-definition-of-done).

**4. Small surface, deep discipline.** The parent layer is intentionally small: <5 KB for `core-rules/CLAUDE.md`, nine canonical hooks, seven scheduled audits. Anything broader than that belongs in a project-local file. This keeps the contract legible and the drift surface narrow. See [§3](#3-the-control-plane).

**5. Harness-safe by default.** Every mechanism in the regime should work in Claude Code and Codex, with hook envelopes separated where the tools differ. Claude's primary inheritance path is `.claude/rules/`; Codex's is root `AGENTS.md` plus `.agents/`. See [§4.2](#42-inheritance-symlink--import) and `core-rules/inheritance.md`.

---

## 3. The control plane

Everything that defines and evolves Trellis lives in `~/projects/trellis-instance/`:

```
trellis-instance/
├── engineering-process.md          ← you are here
├── trellis.config.json             ← deployment-local configuration (paths, harnesses, GitHub user)
├── registry.md                     ← active projects opt-in list
├── blacklist.md                    ← temporary exemptions
├── recon.md                        ← LIFT/LEAVE/DEFER thesis doc (history)
├── core-rules/
│   ├── CLAUDE.md                   ← parent rules (LLM-facing, inherited)
│   ├── AGENTS.md                   ← symlink → CLAUDE.md (Codex parity)
│   ├── hooks.md                    ← three-tier hook spec
│   ├── inheritance.md              ← symlink + @-import + multi-harness spec
│   ├── deferred.md                 ← n=1 candidates awaiting third witness
│   ├── hooks/                      ← canonical Claude Code hook implementations
│   ├── codex/                      ← canonical Codex hooks.json + hook scripts
│   ├── husky/                      ← canonical Tier-3 git hooks
│   ├── skills/                     ← canonical agent-invoked skills (process-gate)
│   └── templates/                  ← context-log.md, gotchas.md seeds
├── scheduled-tasks/                ← weekly/monthly audit prompt sources
├── scripts/                        ← bootstrap + onboard + sync utilities
│   ├── lib/                        ← config-load.sh, sed-portable.sh
│   ├── onboard-project.sh          ← register + seed a project
│   ├── sync-hooks.sh               ← canonical Claude hooks → projects rsync
│   ├── sync-codex-hooks.sh         ← canonical Codex hooks → projects rsync
│   └── sync-to-template.sh         ← live → public template export (with redaction)
└── audits/                         ← dated output of every audit run
```

### 3.1 `trellis.config.json`

Single file capturing the customizations of THIS clone of Trellis. Bootstrapped from the template; consumed by every script that needs absolute paths or harness mode.

```jsonc
{
  "trellis_root":   "/abs/path/to/trellis-instance",
  "projects_root":  "/abs/path/to/projects/personal",
  "user_home":      "/Users/<you>",
  "maintainer_name":"<your name>",
  "github_user":    "<github-username>",
  "harnesses":      ["claude"],         // or ["claude", "codex"]
  "template": {
    "remote": "git@github.com:<you>/trellis.git",
    "branch": "main",
    "redact_paths": ["audits/", "blacklist.md", "registry.md"]
  },
  "sed_flavor": "auto"                  // auto | gnu | bsd
}
```

Scripts source `scripts/lib/config-load.sh` to populate `$TRELLIS_ROOT`, `$PROJECTS_ROOT`, `$HARNESSES[@]`, etc. The config is **deployment-local** — not synced to the public template (the template ships placeholders).

Cross-machine portability is achieved by:

1. **The template repo** (`trellis-template`) — placeholders + `AGENT_SETUP.md` walking an LLM through bootstrap.
2. **`sync-to-template.sh`** — exports current canonical content from this live repo back to the template, redacting user-specific values to placeholders. The friend pulls template updates and re-applies to their own clone.
3. **Audit prompts retain absolute paths** — bootstrap-time sed-substitution, not runtime resolution. Headless-safe by construction; each customer's clone has their own absolute paths after bootstrap.

### 3.2 Scripts

| Script | Purpose |
|---|---|
| `scripts/onboard-project.sh <project-path>` | Seed inheritance symlinks, gotchas/context-log templates, husky hooks (or skip for native-githooks projects). Reads config; honors `harnesses` to seed `AGENTS.md`, `.agents/`, and `.codex/` parity when Codex enabled. |
| `scripts/sync-hooks.sh [--dry-run\|--yes]` | Canonical Tier 1+2 hook scripts → all registered projects' `.claude/hooks/`. Skill symlinks update automatically (no rsync needed). |
| `scripts/sync-codex-hooks.sh [--dry-run\|--yes]` | Canonical Codex hook manifest + scripts → all registered projects' `.codex/` trees when Codex is enabled. |
| `scripts/sync-to-template.sh [--apply] [--push]` | Live → template export. Redacts `$TRELLIS_ROOT`, `$PROJECTS_ROOT`, `$USER_HOME`, `$MAINTAINER_NAME`, `$GITHUB_USER` back to placeholders. Default mode is dry-run; `--apply` writes to template working tree; `--push` also commits + pushes (with confirmation). Excludes `audits/`, `registry.md`, `blacklist.md` (private). |

**Read-repeatedly files** (the contract):
- `engineering-process.md` (this doc)
- `core-rules/CLAUDE.md`, `core-rules/hooks.md`, `core-rules/inheritance.md`
- `registry.md`, `blacklist.md`

**Write-infrequently files** (the evolution loop):
- `core-rules/deferred.md` — modified when a new candidate rule appears or a third witness promotes one.
- `audits/YYYY-MM-DD-*.md` — write-only; scheduled tasks append; remediation tracked elsewhere.

**Read-once-for-history files**:
- `recon.md` — the thesis doc that drove the original lift/leave/defer classification. Don't rewrite it; its value is the historical record of *why* the parent layer looks the way it does.

---

## 4. Project regime

### 4.1 What "active under Trellis" means

A project is active under Trellis if and only if it appears in `registry.md` and not in `blacklist.md`. Active projects are:

- Required to carry the canonical hooks, symlink, and `CLAUDE.md` files (see [§10](#10-onboarding-a-new-project-full-playbook) for the checklist).
- Automatically included in every scheduled audit run (see [§11](#11-scheduled-audits--the-feedback-loop)).
- Subject to the commit / PR / merge rules in [§6](#6-git-workflow).

`registry.md` is the authoritative list of active projects. Resolve against the registry — do not rely on any count or roster hardcoded elsewhere (including in this manual). When a project is added or removed, `registry.md` changes; nothing else needs to.

### 4.2 Inheritance (symlink + @-import)

Claude Code does **not** cascade `CLAUDE.md` up the directory tree. Inheritance is explicit, via two mechanisms with different trust profiles:

**Primary — `.claude/rules/trellis.md` symlink.** Files under `.claude/rules/` load unconditionally at session start, in interactive *and* headless modes. This is the only inheritance path that's load-bearing. Required for every registered project.

**Tracking policy: gitignored, regenerated locally.** The symlink target is an absolute path under `$TRELLIS_ROOT` (e.g., `__TRELLIS_PATH__/...`), which differs on every developer's machine. Tracking it in git produces a path that resolves only on the developer who created it; every other developer's clone has a dangling symlink, and any cross-machine merge produces a textual conflict on the symlink target. The canonical symlinks (`.claude/rules/trellis.md`, `.claude/skills/process-gate`, `.agents/rules/trellis.md`, `.agents/skills/process-gate`) are therefore **gitignored** in every registered project. Each developer recreates them post-clone by running `~/projects/trellis-instance/scripts/onboard-project.sh <project-path>`. Relative symlinks (e.g., root `AGENTS.md → CLAUDE.md`) are stable across machines and remain tracked.

**Secondary — `@`-import in project `CLAUDE.md`.** `@__TRELLIS_PATH__/core-rules/CLAUDE.md` on line 2 of each project's `CLAUDE.md`. Belt-and-braces redundancy in interactive mode. Trust-prompt-gated and silently drops in headless mode, so it must never be treated as primary.

If either mechanism breaks, Claude Code drops the instruction silently — no error, no warning. The `parent-hook-drift` audit catches drift; the `cross-project-process-audit` catches missing symlinks. See `core-rules/inheritance.md` for silent-drop invariants and the registered-project checklist.

### 4.3 Registering / blacklisting

To add a project: follow [§10](#10-onboarding-a-new-project-full-playbook).

To temporarily exempt a project: move its row to `blacklist.md` with a reason and a revisit date. The `bypass-tripwire` and `cross-project-process-audit` skip blacklisted projects. Don't delete the row from `registry.md` — preserve the history of "this project was active once."

To permanently deregister: delete the row from `registry.md` and note the reason in the commit message. Rare — blacklisting is almost always the right move instead.

---

## 5. Hook enforcement

Full spec: `core-rules/hooks.md`. Summary follows.

### 5.1 Three-tier architecture

| Tier | When it runs | Budget | Purpose |
|---|---|---|---|
| **Tier 1 — fast-local** | Every relevant tool call | ≤ 3s | Sub-second feedback loops; PreToolUse / PostToolUse hooks. |
| **Tier 2 — heavy-gated** | On turn wrap-up (`Stop` event) | ≤ 90s | Catch "claimed done but isn't" before the turn ends. |
| **Tier 3 — git-boundary** | On commit / push (husky) | Project-local | Last-line defense if tier 1/2 misfired. |

Tier 1 and 2 are harness hook events. Claude Code and Codex use separate JSON envelopes, so Trellis keeps separate canonical script trees while preserving the same policy intent. Tier 3 is husky + lint-staged + commitlint, standard git machinery.

### 5.2 The nine canonical hooks

| Script | Tier | Event | Responsibility |
|---|---|---|---|
| `block-destructive.sh` | 1 | PreToolUse (Bash) | Deny `rm -rf /`, force-push, hard-reset, DB DROP, `.env` reads. |
| `post-edit-verify.sh` | 1 | PostToolUse (Write/Edit/MultiEdit) | Per-file lint (eslint/ruff/clippy/golangci-lint). Block on fail. |
| `truncation-check.sh` | 1 | PostToolUse (Grep/Bash/Read) | Warn when tool output ≥50K chars or truncation marker present. |
| `session-context.sh` | 1 | SessionStart (startup/resume) | Inject branch, last commits, dirty-file count, pending gotchas. |
| `save-context-log.sh` | 1 | PreCompact | Persist session state to `context-log.md`. |
| `post-compact-context.sh` | 1 | SessionStart (compact) | Restore `context-log.md` into context after auto-compact. |
| `stop-verify.sh` | 2 | Stop | Block if todos open, run typecheck + lint + fast tests. |
| `code-review-subagent.sh` | 2 | Stop (edit-heavy) | Dispatch a code-review subagent on the diff; findings must resolve or defer. |
| `ui-verify.sh` | 2 | Stop (UI diff) | Spin up dev server, take screenshot, attach. |

Claude implementations are version-controlled at `core-rules/hooks/`. Projects deploy by copying into `.claude/hooks/` and wiring into `.claude/settings.json` using `$CLAUDE_PROJECT_DIR` paths.

Codex implementations are version-controlled at `core-rules/codex/`. Projects deploy by copying `hooks.json` and `hooks/*.sh` into `.codex/`; scripts resolve the project via `$CODEX_PROJECT_DIR` with `$CLAUDE_PROJECT_DIR` as a fallback. Codex hooks require `[features] hooks = true` in `$CODEX_HOME/config.toml` (the older `codex_hooks` key still works as a deprecated alias on Codex CLI 0.129+).

### 5b. Skills layer

Canonical skills live under `core-rules/skills/<name>/` and are inherited by every project via the same symlink mechanism as parent rules. Skills are *agent-invoked* — not run automatically — and supply structured procedures plus harness-agnostic validator scripts.

**Current canonical skill: `process-gate`.** The pre-PR enforcement gate. Six categories (PR hygiene, secrets, bypass markers, tests, docs, stack profile), each with a reference file and a validator script. Returns a single verdict block (`MERGEABLE` / `NEEDS CHANGES` / `BLOCKED`). Spec: `core-rules/skills/process-gate/SKILL.md`. Mandatory before merging to `main`.

**Project deployment.** Each registered project carries:

```
<project-root>/.claude/skills/process-gate/  →  $TRELLIS_ROOT/core-rules/skills/process-gate/
```

The directory itself is symlinked, so canonical updates appear automatically. Project-local configuration goes beside the symlink in `<project-root>/.claude/skills/process-gate-local/local.config.sh` (NOT covered by the canonical symlink — project owns it).

**Codex-enabled projects** additionally carry `.agents/skills/process-gate/` pointing at the same canonical target and `.agents/skills/process-gate-local/local.config.sh` for Codex-local overrides. Both symlinks resolve to byte-identical content; `process-gate-local/` is the per-project extension point.

**Stack profiles.** The canonical six gates apply to every project. Stack-specific validators (design tokens, a11y, module boundaries, asset checks) attach via `PROCESS_GATE_STACK_PROFILE` and `PROCESS_GATE_STACK_VALIDATORS` in `local.config.sh`. See `core-rules/skills/process-gate/references/stack-profiles.md`. Profiles waiting for a third witness queue in `core-rules/deferred.md`.

**Lume carve-out.** Lume (Unity, n=1 native-stack project) declares `PROCESS_GATE_STACK_PROFILE="unity"` with project-local validators only. The canonical six gates still apply. The carve-out is documented in `registry.md` and the extended `parent-hook-drift` audit treats it as expected, not drift.

### 5.3 Project overrides

Projects can override:
- Per-file linter command (`post-edit-verify`)
- Typecheck/lint/test commands (`stop-verify`, `pre-push`)
- Edit-heavy threshold (`code-review-subagent`)
- UI file glob + dev-server port/regex (`ui-verify`)
- Commit scope allowlist (`commit-msg`)

Overrides live in each project's `.claude/hooks/config.sh` and/or `.codex/hooks/config.sh`. The canonical `.sh` files themselves are never edited per-project — drift from canonical is what `parent-hook-drift` catches.

### 5.4 Guarantees

- **Rename-proof.** Hooks use `$CLAUDE_PROJECT_DIR` or `$CODEX_PROJECT_DIR`, never hardcoded project paths.
- **Headless-safe.** Claude hooks work identically in `claude -p` runs and scheduled tasks; Codex hook parity is project-local and gated by the Codex hook feature flag.
- **Fail closed.** A failed hook blocks; it never logs-and-continues.

### 5.5 Harness coverage matrix

Claude Code is the primary harness. Codex is the secondary. Different layers cover different harnesses:

| Layer | Claude Code | Codex | Notes |
|---|---|---|---|
| Parent rules doc | `CLAUDE.md` (via `.claude/rules/trellis.md` symlink) | `AGENTS.md` (symlink → `CLAUDE.md`, or `.agents/rules/trellis.md` symlink) | Single canonical source of truth in `core-rules/CLAUDE.md`. |
| Skills (`process-gate`, future) | `.claude/skills/<name>/` symlink | `.agents/skills/<name>/` symlink | Same canonical target; byte-identical across harnesses. |
| Tier 1 + 2 hooks | `.claude/settings.json` hook entries | `.codex/hooks.json` hook entries | Separate canonical envelopes; same policy intent. |
| Tier 3 git hooks (husky / native) | runs in both | runs in both | Harness-agnostic. |
| Scheduled audits | `mcp__scheduled-tasks__*` MCP | **N/A** at MCP level | Audit prompts are plain markdown; can be invoked from cron via `claude -p` regardless of which harness the user develops in. |

Projects opt into Codex by setting `harnesses: ["claude", "codex"]` in `trellis.config.json` (see §3 control plane). The public template defaults to `["claude"]`; this live control plane runs both.

---

## 6. Git workflow

### 6.1 Branching model

**Trunk-based with short-lived feature branches.** `main` is the only long-lived branch. Work happens on feature branches named `<type>/<short-slug>` (e.g., `feat/avatar-rig`, `fix/cloth-sim-crash`, `chore/upgrade-next-15`). Feature branches live ≤ 5 working days; older branches either merge or get abandoned.

No `develop`. No `release/*`. No `hotfix/*`. If you need a pre-production branch for a specific reason (integration testing, staged release), create it, merge what you need, delete it when done.

### 6.2 Commit conventions

**[Conventional Commits](https://www.conventionalcommits.org/)** enforced by `commit-msg` hook (`@commitlint/config-conventional`).

Allowed types: `feat`, `fix`, `refactor`, `chore`, `docs`, `style`, `test`, `perf`, `build`, `ci`, `revert`.

**Scopes are optional and opt-in per project.** Projects that define a scope allowlist (e.g., Neev's 16 package names) enforce that allowlist. Projects that don't, accept unscoped commits. Never invent a scope ad-hoc.

Examples:
```
feat: add avatar rotation gesture
fix(wardrobe): reset zoom after outfit swap
chore: bump pnpm lockfile to v2
```

Commit bodies are optional. When present, use them for *why*, not for *what* (the diff is the *what*). Footers for `BREAKING CHANGE:`, `Refs: #123`, `Co-authored-by:`.

### 6.3 PR flow

**Every change to `main` goes through a PR.** No exceptions under normal conditions. Direct push to `main` is blocked at three layers:

1. Local `pre-push` hook (husky) — refuses direct push to `main`/`master`. Override: `TRELLIS_ALLOW_MAIN_PUSH=1 git push` (use almost never, document every use in the project's `gotchas.md` or commit trailer).
2. GitHub branch protection — require PR, require passing status checks, **squash-merge disabled in repo settings** so merge commits are the only path that lands on `main` (preserves full PR history). Do not enable "Require linear history" — it forbids merge commits.
3. Convention — you know better.

Review model for sole-maintainer projects: **self-review discipline + CI gates**. GitHub blocks self-approval so "reviewed by = merged by" is structurally prevented, but the review happens:
- When you open the PR, write the description as if explaining to a stranger. If it's hard to write, the change is too big or too unclear — split it.
- Wait at least one session (≥ 30 minutes; overnight is better) before merging. Re-read the diff with fresh eyes. Non-trivial changes benefit from a code-review subagent pass via the Agent tool.
- CI must be green. Status checks required at the branch protection level.
- Merge style: **merge commit** by default — preserve the full per-commit history of every PR (including agent attribution and intermediate review state). Squash-merge is forbidden; rebase-merge only when the branch's commit history is intentionally clean and linear and explicitly approved for that PR. (See `core-rules/skills/process-gate/references/pr-hygiene.md` and `core-rules/hooks.md` for the canonical statements; the `bypass-tripwire` audit treats the `(#NN)` squash marker as a direct-push detection signal, which assumes merge commits are the norm.)

### 6.4 Branch protection

Every Trellis project must have branch protection on `main`:
- Require pull requests before merging.
- Require status checks to pass (CI: install → lint → typecheck → unit tests → build).
- Disable squash-merge in repo settings; allow merge-commit (default) and rebase-merge only. Do **not** enable the "Require linear history" branch-protection toggle — it forbids merge commits, conflicting with the canonical merge-commit policy. Effective linearity is achieved by rebasing feature branches onto current `main` before merge so the merge commit is fast-forwardable.
- Do not allow force pushes to `main`.
- Do not allow deletions.

Review-count rules are N/A for sole-maintainer orgs (GitHub's self-approval block means any required-review setting = undeployable). The local `pre-push` guard + CI + the PR window are the functional gate.

### 6.5 History hygiene

- **Merge-commit by default** — one merge commit per PR on `main`, preserving the branch's per-commit history. Squash-merge is forbidden (drops agent attribution, intermediate review state, and bisect resolution). Rebase-merge is allowed only for branches whose commit history is intentionally clean and linear, with explicit approval per PR.
- **Linear history on `main`** (by convention, not by GitHub toggle) — rebase feature branches onto current `main` before merge so the merge commit is fast-forwardable. The "Require linear history" branch-protection setting is **disabled** because it forbids merge commits; the discipline is enforced at PR time by the gate, not by GitHub.
- **Don't amend published commits** without force-with-lease on the feature branch. Never force-push `main` under any condition (blocked anyway).
- **`git revert` over `git reset`** for rolling back merged work. Preserves history.

---

## 7. Definition of done

A change is done when all of the following are true:

1. **Receipts attached.** The response that claims done includes: the verification command(s) run, their exit codes, and the diff lines (or a summary pointing at the PR) that prove the change. "It works" without receipts is not done.
2. **Todos closed.** If `TodoWrite` has `in_progress` or `pending` items, the turn is not done. Complete them, defer with reason, or abandon with reason. `stop-verify` enforces this.
3. **Typecheck + lint + fast tests green.** Enforced by `stop-verify` at turn end and by `pre-push` at git boundary.
4. **Code review resolved.** On edit-heavy turns (≥ 3 files or ≥ 200 lines), the `code-review-subagent` runs. Findings either get fixed or explicitly acknowledged and deferred.
5. **Visual verification for UI.** For any diff touching UI files, `ui-verify` has run and attached a screenshot. Logically verified is not visually verified.

Done is a property of the *turn* that claimed done, not of the project. Turn-level done compounds into project-level correctness; don't skip the turn-level gate on the theory that a later turn will catch it.

---

## 8. Code quality standards

Full expression in `core-rules/CLAUDE.md`. Summary:

### 8.1 Planning discipline

- When asked to plan, output only the plan. No code until explicit approval.
- When given a plan, follow it exactly. Flag real problems and wait.
- For non-trivial features (3+ steps or architectural decisions), interview the user first: implementation, UX, trade-offs.
- Never attempt multi-file refactors in one response. Phase them: max 5 files per phase, verify, get approval, continue.

### 8.2 Edit safety

- Re-read every file before editing it. Re-read it after. The Edit tool fails silently on stale `old_string` matches.
- On any rename or signature change, search separately for: direct calls, type refs, string literals, dynamic imports, `require()` calls, re-exports, barrel files, test mocks. Assume grep missed something.
- Never delete a file without verifying nothing references it.

### 8.3 Context management

- For tasks touching >5 independent files, dispatch parallel sub-agents (5–8 files each). Sequential processing of 20 files guarantees context decay by file 12.
- After 10+ messages, re-read any file before editing it. Auto-compaction may have destroyed your memory of its contents.
- If you notice context degradation (referencing nonexistent variables, forgetting file structure), run `/compact` proactively. `save-context-log` captures state to `context-log.md`.
- Reads are capped at 2000 lines. For files >500 LOC, use offset/limit chunks.
- Tool results over 50K chars truncate to a 2KB preview. Re-run narrower or read the source directly.

### 8.4 Style

- Ignore the default "simplest approach / don't refactor beyond the ask" dogma when it applies. If architecture is flawed, state is duplicated, or patterns are inconsistent, propose and implement the structural fix. Ask "what would a senior perfectionist dev reject in code review?" — fix that.
- Comments default to none. Comment when the *why* is non-obvious. No robotic comment blocks.
- Don't build for imaginary scenarios. Simple and correct beats elaborate and speculative.

### 8.5 Debugging

- Work from raw error data. Don't guess. If a bug report has no output, ask for it.
- For long-running processes (dev server, test watcher, build, log tail), use the `monitor` tool — never `tail -f`, polling loops, or repeated Bash calls.
- If a fix doesn't work after two attempts, stop. Read the entire relevant section top-down. State where your mental model was wrong before trying again.

### 8.6 Testing bar

Minimum per project (enforced by CI and `stop-verify`):
- **Unit tests** — fast suite, runs on every turn. Target coverage: useful-is-enough; don't chase %.
- **Type-check** — `tsc --noEmit`, `mypy`, `cargo check`, or `go vet` — whichever fits the stack.
- **Lint** — project's configured linter runs repo-wide on Stop, per-file on edit.
- **Integration / E2E** — where the project warrants it; run in CI, not on every turn. Don't mock boundaries that production crosses (DB, queue, auth).

Playwright is the default E2E framework for web projects. Non-web stacks (games, CLIs, native apps, embedded) bring their own testing and tooling conventions — document those in the project's own `CLAUDE.md` and let the Rule of Three ([§14.1](#141-rule-of-three)) decide whether any of it rises into this manual. The parent layer stays small on purpose.

---

## 9. Documentation standards

### 9.1 Project `CLAUDE.md`

Each registered project has a `CLAUDE.md` at its root. Structure:

```markdown
# <project-name>

@__TRELLIS_PATH__/core-rules/CLAUDE.md

> Engineering process manual: `~/projects/trellis-instance/engineering-process.md`

<1–3 sentences: what is this project, who uses it, what's its current phase>

## Stack
<language / framework / runtime / deployment>

## Architecture
<high-level shape: monorepo packages, services, main modules>

## Project-specific rules
<anything that doesn't belong in the parent — e.g., "never import @neev/orders from @neev/inventory">

## Gotchas
<pointer to gotchas.md + any highlights worth surfacing>

## Running locally
<commands: install, dev, test, build>
```

Target size: **< 5 KB**. Bloat pushes signal out of context. Long reference material goes in sibling files and gets linked.

### 9.2 README.md

Project-level README is for *humans landing on the repo for the first time*. Orthogonal to `CLAUDE.md`.

```markdown
# <project-name>

<one-line tagline>

<one-paragraph what/why>

## Requirements
<node version, pnpm, docker, etc.>

## Quick start
<the 3-5 commands that get someone productive>

## Documentation
<links to deeper docs if any>

## License
<license name + year>
```

### 9.3 gotchas.md

Every project maintains a `gotchas.md` at the root. Purpose: log every *correction* the user gives you, every surprising discovery, every "turns out this library does X." Format per entry:

```markdown
## <YYYY-MM-DD> — <short title>
**Context:** <where this bit us>
**Gotcha:** <what actually happens>
**Rule:** <what to do about it>
```

Read at session start (`session-context` hook surfaces pending items). Reviewed monthly by the `gotchas-rollup` audit, which clusters entries and applies the Rule of Three — n≥3 similar entries promotes to `CLAUDE.md`, n=2 queues in `deferred.md`.

### 9.4 context-log.md

Hook-managed (`save-context-log` writes on `PreCompact`, `post-compact-context` re-injects on resume). Don't edit by hand. Don't commit to `main` — it's a local working file. Gitignored in every project.

### 9.5 ADRs (parked)

Architecture Decision Records are currently in `deferred.md` awaiting a third project to adopt. TGSC uses `docs/adr/NNNN-<slug>.md` with context / decision / consequences / status. Neev uses tech-spec docs. Neither is the parent rule yet.

**Interim guidance:** if you write an ADR, use TGSC's shape. When a third project picks the same shape, promote it.

### 9.6 Frontend-quality references

Projects with a public web surface (portfolio, marketing page, SaaS console, app landing) inherit four reference docs via the process-gate skill: `core-rules/skills/process-gate/references/web-{perf,a11y,seo,agent-readiness}.md`. These synthesize Lighthouse (Performance, Accessibility, Best Practices, SEO, Agentic Browsing), web.dev a11y, Google's AI optimization guide, and Cloudflare's `isitagentready.com` scorecard into a single Trellis-stamped checklist. Advisory today; automation deferred per `core-rules/deferred.md` until Rule of Three. Consult before any non-trivial public-page PR.

---

## 10. Onboarding a new project — full playbook

This is the canonical sequence. Run it manually, or point `scripts/onboard-project.sh` at it once the script exists (not yet).

**Agent-driven shortcut.** `AGENT_ONBOARD_PROJECT.md` at the repo root wraps every step below into a paste-into-agent interview — detect mode (new / fresh-clone / repair), run `scripts/onboard-project.sh`, wire the project's `CLAUDE.md` `@`-import, update `registry.md`, and commit in both repos. Use it unless you specifically want the manual walkthrough.

### 10.1 Pre-flight questions (answer before anything)

- **Name?** Final, committed. Directory name matches.
- **GitHub host?** User, new org, existing org?
- **Stack?** Informs `CLAUDE.md` seed and `.gitignore`.
- **Class?** Monorepo SaaS, single Next.js app, portfolio site, game, CLI — informs registry.
- **License?** MIT default; choose something else only with reason.

### 10.2 Scaffold steps

```bash
# 1. Create project directory
cd ~/projects/personal
mkdir <name>
cd <name>

# 2. git init
git init -b main

# 3. Create the Claude Code inheritance structure
mkdir -p .claude/rules .claude/hooks

# 4. Symlink parent rules (PRIMARY inheritance — required)
ln -s __TRELLIS_PATH__/core-rules/CLAUDE.md \
      .claude/rules/trellis.md

# 5. Copy canonical hooks
cp __TRELLIS_PATH__/core-rules/hooks/*.sh .claude/hooks/
chmod +x .claude/hooks/*.sh

# 5b. Symlink canonical skills (process-gate)
mkdir -p .claude/skills
ln -s __TRELLIS_PATH__/core-rules/skills/process-gate \
      .claude/skills/process-gate

# 5c. (Codex-enabled projects only) seed .agents and .codex trees
# If `harnesses` in trellis.config.json includes "codex":
#   mkdir -p .agents/rules .agents/skills .codex/hooks
#   ln -s __TRELLIS_PATH__/core-rules/CLAUDE.md \
#         .agents/rules/trellis.md
#   ln -s __TRELLIS_PATH__/core-rules/skills/process-gate \
#         .agents/skills/process-gate
#   cp __TRELLIS_PATH__/core-rules/codex/hooks.json .codex/hooks.json
#   cp __TRELLIS_PATH__/core-rules/codex/hooks/*.sh .codex/hooks/
#   chmod +x .codex/hooks/*.sh
#   # AGENTS.md at project root: either content + @-import OR symlink → CLAUDE.md
#   ln -s CLAUDE.md AGENTS.md   # if no Codex-specific divergence is needed

# 6. Write .claude/settings.json
# (copy from any active project — structure is identical, uses $CLAUDE_PROJECT_DIR)

# 7. Write project CLAUDE.md (template in §9.1)
cat > CLAUDE.md <<'EOF'
# <name>

@__TRELLIS_PATH__/core-rules/CLAUDE.md

<1-3 sentence project overview>

## Stack
...
EOF

# 8. Write gotchas.md (template in core-rules/templates/gotchas.md)
cp __TRELLIS_PATH__/core-rules/templates/gotchas.md .

# 9. .gitignore — append the Trellis fragment + project-local entries
cat __TRELLIS_PATH__/core-rules/templates/project.gitignore.fragment >> .gitignore
cat >> .gitignore <<'EOF'
context-log.md
.claude/settings.local.json
EOF
# The fragment gitignores the four canonical absolute-path symlinks
# (.claude/rules/trellis.md, .claude/skills/process-gate,
#  .agents/rules/trellis.md, .agents/skills/process-gate). Each developer
# regenerates them post-clone via scripts/onboard-project.sh.

# 10. README.md (template in §9.2)

# 11. Initial commit
git add -A
git commit -m "chore: initial scaffold with Trellis inheritance"

# 12. Add to registry.md
# Edit ~/projects/trellis-instance/registry.md, add a new row under "Active projects"
# Commit that change in trellis-instance with "chore: register <name>"

# 13. Create GitHub repo (via gh CLI or UI), add remote
gh repo create <owner>/<name> --private --source=. --remote=origin
git push -u origin main

# 14. Enable branch protection on main (see §6.4)
# Can be done via gh api or the GitHub UI. Must do before first PR.
```

### 10.3 First-commit checklist (verify before you push)

- [ ] Read `~/projects/trellis-instance/engineering-process.md` end-to-end. Everything below this line assumes you have.
- [ ] `ls -la .claude/rules/trellis.md` — symlink exists, points at canonical path.
- [ ] `readlink .claude/rules/trellis.md` — target is `__TRELLIS_PATH__/core-rules/CLAUDE.md`.
- [ ] `ls .claude/hooks/` — all nine canonical `.sh` files present and executable.
- [ ] `ls -la .claude/skills/process-gate` — symlink exists, points at canonical `core-rules/skills/process-gate`.
- [ ] `readlink .claude/skills/process-gate` — target is `__TRELLIS_PATH__/core-rules/skills/process-gate`.
- [ ] `grep -q '$CLAUDE_PROJECT_DIR' .claude/settings.json` — no hardcoded project paths.
- [ ] `CLAUDE.md` starts with `@__TRELLIS_PATH__/core-rules/CLAUDE.md` on line 2.
- [ ] `gotchas.md` exists at project root.
- [ ] `.gitignore` includes the Trellis symlink fragment (`.claude/rules/trellis.md`, `.claude/skills/process-gate`, `.agents/rules/trellis.md`, `.agents/skills/process-gate`) plus `context-log.md` and `.claude/settings.local.json`.
- [ ] `git ls-files .claude/rules/trellis.md .claude/skills/process-gate` returns nothing — the absolute-path symlinks are NOT staged for the initial commit.
- [ ] If Codex-enabled: `AGENTS.md`, `.agents/rules/trellis.md`, `.agents/skills/process-gate`, `.agents/skills/process-gate-local/local.config.sh`, `.codex/hooks.json`, and `.codex/hooks/*.sh` are present.
- [ ] If Codex-enabled: `$CODEX_HOME/config.toml` has `[features] hooks = true` (or the legacy `codex_hooks = true` alias; deprecated as of Codex CLI 0.129+).
- [ ] `registry.md` has a row for the new project.
- [ ] Branch protection enabled on `main`.

### 10.4 Post-onboarding verification

Wait for the next scheduled run of `parent-hook-drift` (Sunday 21:00) and `registry-blacklist-health` (Monday 10:36) — both should come back clean with the new project listed. Or manually trigger them via the scheduled-tasks MCP to verify immediately.

### 10.5 Bootstrapping a fresh clone (every developer, every machine)

The canonical absolute-path symlinks (`.claude/rules/trellis.md`, `.claude/skills/process-gate`, `.agents/rules/trellis.md`, `.agents/skills/process-gate`) are gitignored — they encode a per-machine `$TRELLIS_ROOT` and cannot be shared across developers (see §4.2 tracking policy). After cloning a registered project, run:

```bash
git clone <repo-url>
cd <project>
~/projects/trellis-instance/scripts/onboard-project.sh "$PWD"
```

`onboard-project.sh` is idempotent: it creates each missing symlink, leaves existing correct ones alone, warns on mismatches, and never overwrites tracked files. Re-running after every `git pull` is harmless.

If you skip this step, Claude Code and Codex sessions in the project will silently run **without** the Trellis parent rules and skills — no error, no warning, just a session quietly missing the load-bearing inheritance file. Add the bootstrap to your project README's "Setup" section so teammates can't miss it.

---

## 11. Scheduled audits & the feedback loop

### 11.1 The seven audits

| Audit | Cadence | What it catches |
|---|---|---|
| `bypass-tripwire` | Daily (Mon–Fri 08:07) | `--no-verify` commits, direct-to-main pushes, husky skips, force-pushes. |
| `cross-project-process-audit` | Weekly (Mon 10:06) | Missing symlinks, missing hooks, staleness, required-file gaps. |
| `registry-blacklist-health` | Weekly (Mon 10:36) | Registry vs. filesystem consistency, orphans, overdue blacklist reviews. |
| `test-health` | Weekly (Mon 11:00) | Each project's fast test suite: pass/fail + last-green bisect on red. |
| `parent-hook-drift` | Weekly (Sun 21:00) | Byte-identity of deployed hooks vs. canonical; settings.json registration gaps. |
| `gotchas-rollup` | Monthly (1st 09:00) | Clusters each project's gotchas, applies Rule of Three for promotion. |
| `audit-report-rollup` | Monthly (1st 10:00) | Trend analysis across the six audits above. |

All audits write to `~/projects/trellis-instance/audits/YYYY-MM-DD-<name>.md`. All are headless `claude -p` runs driven by the scheduled-tasks MCP (`mcp__scheduled-tasks__*`). Prompt sources live in `scheduled-tasks/<name>/prompt.md`; runtime prompts live inside the MCP and should be kept in sync with disk.

### 11.2 Remediation workflow

1. **Read the audit report.** Critical findings first; warnings second; info last.
2. **Classify:** is it drift (the project copy diverged from canonical), gap (missing a required file), or policy violation (bypass/direct push)?
3. **For drift:** rsync the canonical hook or file to the project, commit with `chore: sync <thing> to canonical`. Run the audit again to verify.
4. **For gaps:** re-run the relevant part of [§10 onboarding](#10-onboarding-a-new-project-full-playbook) for the missing file.
5. **For policy violations:** if intentional (emergency override), document in `gotchas.md` and move on. If accidental, understand how it slipped past the three tiers of gates and close that gap.

### 11.3 Writing new audit tasks

Audits are written as SKILL-style prompt.md files under `scheduled-tasks/<name>/`. Good audit prompts:
- Name their inputs (which files to read) and outputs (where to write).
- Are **reporting only** — they never modify project files. That's a hard boundary.
- Cap output size (50 lines of diff, 30 lines of log).
- Degrade gracefully if a project is missing (defer to a sibling audit that owns detection).
- Include sensible-failure-mode handling.

See `scheduled-tasks/parent-hook-drift/prompt.md` as a template.

---

## 12. Incident response & rollback

Solo-dev scope — this is not PagerDuty territory. The patterns:

### 12.1 Triage tree

1. **Is the production deployment broken?** Roll back first, diagnose second. `gh pr list --state merged --limit 5` to find the suspect; revert via `git revert <sha>` (never `git reset --hard` on shared branches); push through a revert PR.
2. **Is local dev broken but prod is fine?** Diagnose without urgency. Check the last clean sha (`test-health` weekly report gives last-green automatically).
3. **Is Trellis itself broken?** (Hooks failing, audits erroring, inheritance drift.) Fix at the parent layer; rsync fix to every project; commit in the Trellis canonical repo with `fix:` prefix.

### 12.2 Rollback options, ranked

1. **`git revert <sha>`** — preserves history, reversible, works after merge. Default choice.
2. **Forward-fix** — if the bug is small and the fix is obvious, ship a fix rather than a revert. Only when you're sure of the scope.
3. **`git reset --hard HEAD~N`** — forbidden on `main`. Allowed on a feature branch only if it's not yet pushed.
4. **Force-push `main`** — forbidden unconditionally. Branch protection blocks this; the `pre-push` hook blocks this; don't try.

### 12.3 Postmortem pattern (blameless, lightweight)

For anything that took > 2 hours to resolve, write a short note in `gotchas.md`:

```markdown
## <YYYY-MM-DD> — <short title of what broke>
**What happened:** <one paragraph>
**Why it happened:** <root cause, not symptom>
**Detection:** <how it surfaced — hook blocked us / user reported / audit caught it>
**Fix:** <what the fix was>
**Prevention:** <is there a hook, a test, a lint rule, an invariant check that would catch this category next time? If yes, open an issue or add it now.>
```

If a prevention is possible and cross-cutting, add it to `deferred.md` with this project as the first witness. When two more projects hit the same category, promote to parent.

---

## 13. Secrets & dependency management

### 13.1 Secrets

- **Never commit secrets.** `.env*`, `secrets/**`, `*.pem`, `*.key` are blocked from reads by `block-destructive` and should be `.gitignore`d at project root.
- **Local dev** uses `.env.local` (gitignored). Share a `.env.example` with the keys and no values.
- **CI/CD** secrets live in the platform's secret store (GitHub Actions secrets, Vercel environment variables, Cloudflare secret bindings). Rotate on any suspected leak.
- **Production** uses the same platform secret stores. Per-environment values.
- **Never pipe secrets through hooks or subagents.** Hooks run with the user's env and can see them; they must not echo them into tool output.

### 13.2 Dependency management

Baseline across all projects:

- **Dependabot** (or Renovate) enabled on every repo — weekly schedule for minor/patch, manual for major.
- **Auto-merge patch updates** when CI passes. Manual review for minor. Major upgrades are their own PR with testing notes.
- **Pin versions** in lockfiles (`pnpm-lock.yaml`, `Cargo.lock`, etc.). Never commit with an out-of-sync lockfile.
- **`npm audit` / `pnpm audit` / `cargo audit` / equivalent** runs in CI. High-severity vulnerabilities block the merge; medium/low get a fix window and a tracking issue.

Upgrade cadence:
- **Weekly:** accept Dependabot patch PRs.
- **Monthly:** process minor upgrades with a morning of focused work.
- **Quarterly:** evaluate major upgrades. Don't let any dep stay >2 majors behind without a written reason.

#### Node engine declaration

Every active project declares `engines.node` matching the watchlist Node target (currently `>=22.0.0`) at the root `package.json`, plus a root `.nvmrc` (or `.node-version`) carrying the matching major for local-dev parity. Workspace-level `engines.node` overrides are allowed only when a workspace genuinely needs a different floor; otherwise inherit from root. Reasoning: Node-tier tooling (turbo, lint-staged, husky, codegen) silently picks up whatever Node is on PATH when no engine is declared, which produces drift the dep-major-upgrade-watch audit can only detect after the fact.

#### Python engine declaration

Every active Python project declares `requires-python` in `pyproject.toml` matching the watchlist Python target (currently `>=3.12`), plus a root `.python-version` carrying the matching version for local-dev parity (read by `pyenv`, `uv`, `pdm`, and most editor integrations). Workspace-level overrides are allowed only when a sub-package genuinely needs a different floor. Reasoning is identical to Node: Python-tier tooling (mypy, ruff, pytest, codegen) silently picks up whatever `python3` is on PATH when no engine is declared, which produces interpreter-version drift the dep-major-upgrade-watch audit can only detect after the fact.

### 13.3 CVE monitoring

GitHub's Dependabot alerts are the default channel. High-severity alerts get same-week attention. For runtime-critical projects (e.g., anything public-facing handling user data), subscribe to the relevant advisory feeds (Node security, Rust advisory DB, GHSA).

---

## 14. Evolving Trellis

### 14.1 Rule of Three

The parent layer grows slowly and deliberately. A rule earns parent status only when *three* independent projects adopt it. The mechanics:

- **n = 1:** a rule appears in exactly one project's `CLAUDE.md` or hook set. Leave it project-local.
- **n = 2:** a rule appears in two. Enter it in `core-rules/deferred.md` with source, what/why, and the condition for lift (usually "when a third project adopts a close variant").
- **n = 3:** a third project adopts a close variant of the rule. Promote: edit `core-rules/CLAUDE.md` or `core-rules/hooks.md` as appropriate, cite the three sources, delete the `deferred.md` entry, run `parent-hook-drift` to sync.

This is the discipline that prevents `core-rules/CLAUDE.md` from bloating into a 30 KB kitchen sink (as Neev's did before Trellis extracted it).

### 14.2 Demotion

If a parent rule stops applying to one of the registered projects, consider demoting it. Demotion criteria:
- At least three projects no longer use the rule actively, OR
- The rule has been shown to cause harm (locked in wrong defaults, blocked legitimate work).

Demotion mechanics: move the rule body into an `archived/` file with date + reason, remove from parent, run `parent-hook-drift` to sync.

### 14.3 Who edits `core-rules/`

Edits to `core-rules/` affect every registered project immediately (via the symlink). Consequence: every edit to `core-rules/CLAUDE.md`, `hooks.md`, or `inheritance.md` is a PR in the Trellis canonical repo with:
- The rationale (why this edit).
- The Rule-of-Three evidence if it's a lift.
- A re-run of `parent-hook-drift` after merge to confirm every project's deployed copies are still identical.

### 14.4 Rollout hygiene

When a canonical hook changes:
1. Edit `core-rules/hooks/<name>.sh` in the Trellis canonical repo.
2. Commit in the Trellis canonical repo with `fix:` or `feat:` prefix.
3. Rsync to every active project: `for p in $(registry-list); do cp core-rules/hooks/<name>.sh ~/projects/personal/$p/.claude/hooks/; done`.
4. Commit in each project with `chore: sync <hook> to canonical`.
5. Next `parent-hook-drift` run confirms all byte-identical.

Step 3 will be automated by `scripts/sync-hooks.sh` once it exists (currently manual).

### 14.5 Versioning & the upgrade flow

Spec-kit adoption (Phase A, 2026-05-12) introduced a semver pin on the canonical core-rules so downstream consumers can decide when to pull canonical changes instead of getting silently dragged along.

- `core-rules/VERSION` — single-line semver. Authoritative. Bumped intentionally when a meaningful rule, hook, or skill change lands. The version is tagged on the public mirror after `sync-to-template.sh`, never on the private clone.
- `trellis.config.json` — optional `trellis_version` field. Downstream forks (and the parent itself, on the canonical clone) pin to a specific version. Absent = "not pinned yet" (the expected pre-rollout state for existing projects).
- `scripts/upgrade.sh` — consumer-side check. Fetches tags from `origin` (or `template.remote` fallback), compares pinned version to highest `v*.*.*` tag, prints a stat diff of `core-rules/`. Read-only by default; `--opt-in` rewrites the pin and revalidates the config against the schema. `--check` exits non-zero on drift for CI.
- `scheduled-tasks/version-drift/` — weekly audit. Walks the registry, classifies each project as current / no-pin / patch-drift / minor-drift / major-drift / ahead / malformed. Only major drift is critical; everything else is informational while the rollout reaches each project.

Severity contract is shared between `upgrade.sh` and `version-drift`. If you change tiers, change both in the same commit.

`core-rules/VERSION` is at `0.2.0` after the spec-kit Phase A + rebrand work. `v0.1.0` was already taken by the 2026-05-08 meta-audit Phase 3 wrap-up (commit `b5eb660`); the next release tag is `v0.2.0`, applied on the public mirror after `sync-to-template.sh`. Existing projects that already use the legacy `SE_CORE_*` env vars or `.claude/rules/se-core.md` symlink will be re-linked by `scripts/rollout-rebrand.sh` (one-shot, idempotent); after that pass the audit's `no-pin` rows can convert to real pins on a project-by-project schedule.

### 14.6 The clarify → spec → plan → tasks → analyze pipeline (opt-in)

Spec-kit Phases B + C (2026-05-12) added five opt-in skills that take a vague request through structured questioning, formal specification, technical planning, work breakdown, and a final coherence check. They live as canonical skills under `core-rules/skills/{clarify,spec,plan,tasks,analyze}/` and are seeded into every registered project's `.claude/skills/` (and `.agents/skills/` under Codex) by `onboard-project.sh` / `scripts/rollout-feature-skills.sh`.

**Decision rule — when to invoke the pipeline:**

Trellis's default is surgical scope. The pipeline is for changes that DON'T fit that mould. Invoke when any of:

- The request lists **three or more acceptance criteria**.
- The change introduces **net-new behaviour across more than two files**.
- The change is **cross-cutting** (auth, billing, infra, shared UI primitives) or otherwise load-bearing.
- The operator explicitly says "spec this out first" or asks for a write-up.

If none apply, skip the pipeline. Bug fixes with clear reproductions, refactors with no behaviour change, single-file additions, and operational tasks all stay on the surgical-default path: failing test → fix → PR.

**Where each skill fits:**

- `clarify` — front-step question pass. Use BEFORE `spec` when the operator's request is vague, contradictory, or leaves any of the five canonical intent dimensions unresolved. Optional but recommended for non-trivial requests.
- `spec` — formal specification: problem, users, success criteria, non-goals, constraints, open questions, risks, out-of-scope.
- `plan` — file-by-file technical design.
- `tasks` — checkbox work breakdown, ≤4h per task, dependencies tracked, every task maps back to a spec criterion.
- `analyze` — tail-step drift check across spec ↔ plan ↔ tasks (and clarify if present). Advisory, not gating; runs BEFORE implementation begins, OR mid-implementation when something feels off.

**Pipeline mechanics:**

The scaffolding step is shared across the pipeline: `core-rules/skills/spec/scripts/new-feature.sh <slug>` validates the kebab-case slug, checks for a dirty tree, picks the next NNN, creates branch `feature/<slug>` from main/master, and lays down a *template* `spec.md`. After scaffolding, the skills compose:

1. **`clarify` skill** *(optional, recommended for vague requests)* — captures the operator's voice verbatim across five canonical questions (intent, users affected, success metric, edge cases, rollback plan). Writes `specs/<NNN>-<slug>/clarify.md` alongside the template spec.md. Refuses to declare done until every question has an answer or an explicit `Deferred: <reason>` block. The schema lives at `core-rules/skills/clarify/references/question-schema.md`.
2. **`spec` skill** — reads `clarify.md` if it exists, then replaces the template `spec.md` placeholders with real content. Authoring rules forbid implementation detail; the spec answers *what* + *why* only.
3. **`plan` skill** — reads the reviewed spec, writes `specs/<NNN>-<slug>/plan.md`: technical approach, schema, API surface, file-by-file change list, sequencing + dependencies, test strategy mapping each spec criterion to a test, rollout plan, risks + mitigations, decisions log. Refuses to overwrite.
4. **`tasks` skill** — reads the reviewed plan, writes `specs/<NNN>-<slug>/tasks.md`: checkbox table of atomic tasks (≤4h each), dependencies, coverage map. `tasks.md` is the source of truth for the feature's work breakdown; `TodoWrite` mirrors the active 3–5-item slice during implementation.
5. **`analyze` skill** — reads `spec.md` + `plan.md` + `tasks.md` (+ `clarify.md` if present), writes `specs/<NNN>-<slug>/analyze.md`: drift findings across 8 categories (coverage, origin, scope, constraint compliance, intent fidelity, rollback consistency, test strategy completeness, sequencing sanity). Ends with a verdict — PASS / NEEDS-REVISION / BLOCKED. Advisory only; operator owns the call to act or override.

**The TodoWrite-vs-tasks.md contract.** `tasks.md` is committed, reviewed, archived alongside the rest of the pipeline — the document of record. `TodoWrite` is the ephemeral in-flight surface: pull the next 3–5 unchecked tasks into TodoWrite as you sit down to work; tick the box in `tasks.md` AND mark TodoWrite items complete in lockstep. If they disagree, `tasks.md` wins.

**Stopping points between skills.** The pipeline is deliberately five skills (not one): each artifact is reviewed before the next is generated. After any skill returns, do not chain to the next in the same turn unless the operator asks. The skills are writers (and one analyst), not builders — implementation begins after `tasks` completes (and ideally after `analyze` returns PASS or NEEDS-REVISION with operator-accepted findings), not before.

**Onboarding + rollout.** New projects pick up the symlinks via `onboard-project.sh`. Existing registered projects get the symlinks via `scripts/rollout-feature-skills.sh` (idempotent). `core-rules/templates/project.gitignore.fragment` lists all seven canonical skill symlinks (process-gate + security-gate + the five pipeline skills) under both `.claude/skills/` and `.agents/skills/`; new onboarding picks the fragment up automatically. Pre-Phase-C projects with the older 5-skill fragment trigger an automatic legacy-detection note when re-onboarded; duplicate gitignore entries are harmless.

**Artifact layout per feature:**

```
<project-root>/specs/<NNN>-<slug>/
├── clarify.md          # clarify skill (optional front-step)
├── spec.md             # spec skill
├── plan.md             # plan skill
├── tasks.md            # tasks skill (work-breakdown source of truth)
└── analyze.md          # analyze skill (advisory verdict before implementation)
```

After a feature ships, the directory stays in git as historical record.

### 14.7 Presets — layering opt-in rule variants on top of parent

Spec-kit Phase D (2026-05-12) added an opt-in mechanism for projects whose discipline needs genuinely diverge from the parent default. The Rule of Three protects the parent layer from bloat (§14.1); presets let two projects compose differently without forcing every project to inherit either side of the divergence.

**Mechanism.** Each preset is a single markdown file at `core-rules/presets/<name>.md`. Projects opt in by listing the name(s) in a project-local `<project>/.trellis.config.json` (preferred, hidden) or `<project>/trellis.config.json`:

```json
{
  "presets": ["compliance-strict"]
}
```

`scripts/rollout-presets.sh` (and `onboard-project.sh`'s preset-seeding pass) read this array, install symlinks at `<project>/.claude/rules/preset-<name>.md` and `<project>/.agents/rules/preset-<name>.md` (under Codex), and prune symlinks no longer declared. Both harnesses load every file under their rules directory, so preset content composes with `trellis.md` automatically.

**Priority order (conceptual — rules are additive, not last-wins):**

Both harnesses load every file under their rules directory and concatenate the content into the agent's prompt. There is no engine-level override; "priority" here means *which layer's voice an agent should defer to when prose conflicts*, not which file silently overwrites another.

1. Parent rules (`core-rules/CLAUDE.md`) — always loaded. The baseline.
2. Presets (`core-rules/presets/<name>.md`) — opt-in; the array order in the project config is also conceptual (later entries are more specific). All declared presets are loaded.
3. Project-local (`<project>/CLAUDE.md`) — most specific; the agent should give it the most weight when it contradicts a higher-up layer.

In practice, presets stay additive — they extend the parent with new rules or explicit carve-outs ("§X of the parent rules is relaxed here because…"). They never directly contradict without a written carve-out. The drift audit and code-review pass catch contradictions that slipped in silently.

**Available presets** (catalogue lives at `core-rules/presets/README.md`):

- `compliance-strict` — additions on top of parent: mandatory ADR per architectural change, two-human PR sign-off, no `--no-verify` ever, mandatory CHANGELOG per PR, hard-fail secrets scan, deploy artifacts encode merge SHA. For regulated-data / audit-bound projects.
- `experimental-loose` — carve-outs only: direct commits to main allowed, skip the spec-kit pipeline (TodoWrite only), optional CHANGELOG, PR-size ceiling demoted to warn, test coverage not required. Time-bound (three-week revisit); security-gate still runs. For throwaway prototypes / hackathon projects.

**Authoring new presets** is governed by `core-rules/presets/README.md` — single-purpose, ≤50 lines, additions+carve-outs structure, cite a reason. Two-project minimum before a new preset ships (a scaled-down Rule of Three because presets are opt-in).

**Drift audit.** `scheduled-tasks/preset-drift/` runs weekly (Mon 12:00). For each registered project it compares the declared `presets` array against the symlinks actually present and reports critical findings (unknown preset, missing symlink, harness divergence) plus stale-symlink warnings.

**Rollout flow:**

```
# 1. Pick a preset (or write a new one). Catalogue: core-rules/presets/README.md
# 2. Add to the project's local config:
$EDITOR <project>/.trellis.config.json   # add to .presets array
# 3. Apply (idempotent — also prunes anything no longer declared):
scripts/rollout-presets.sh <project>
# 4. Re-onboard the project if its .gitignore predates Phase D (the
#    preset-*.md gitignore globs are in the (7-skill set + presets)
#    fragment, sentinel-bumped from prior versions).
scripts/onboard-project.sh /abs/path/to/<project>
```

Onboarding new projects with presets pre-declared is fully automatic: write `<project>/.trellis.config.json` before running `onboard-project.sh`, and the seeding pass installs the preset symlinks alongside the canonical skill + rule symlinks.

---

## 15. Glossary & quick reference

**Active project** — appears in `registry.md`, not in `blacklist.md`.

**Canonical hook** — the nine `.sh` files under `~/projects/trellis-instance/core-rules/hooks/`. Projects deploy copies; drift is flagged by `parent-hook-drift`.

**Control plane** — the contents of `~/projects/trellis-instance/`. The place where the regime is defined, evolved, and audited.

**Drift** — a project's deployed hook or required file has diverged from canonical. Critical: flagged, must be remediated.

**`$CLAUDE_PROJECT_DIR`** — environment variable injected by Claude Code pointing at the project root. Used in `settings.json` to keep hook paths rename-proof.

**Headless-safe** — works identically in `claude -p` mode and interactive mode. All primary mechanisms must be headless-safe.

**Inheritance** — the mechanism by which each project picks up parent rules. Primary: `.claude/rules/trellis.md` symlink. Secondary: `@`-import in project `CLAUDE.md`.

**Parent layer** — the rules and hooks in `~/projects/trellis-instance/core-rules/` that every registered project inherits.

**Receipts** — the verification command + exit code + diff lines required to claim "done."

**Registered** — synonymous with active.

**Rule of Three** — promotion criterion: three independent project adoptions before a rule enters the parent layer.

**Trellis** — this regime. The name, the directory, the process.

**Silent drop** — Claude Code's behavior when inheritance breaks: no error, no warning, instruction simply doesn't load. Detection is via the `InstructionsLoaded` hook and periodic audits.

**Tier (hook)** — three tiers: fast-local (every turn), heavy-gated (Stop event), git-boundary (husky).

### Cheat sheet

| I want to... | Do this |
|---|---|
| Add a project to Trellis | [§10](#10-onboarding-a-new-project-full-playbook) |
| Temporarily exempt a project | Move row to `blacklist.md` with reason + revisit date |
| Change a parent rule | PR in the Trellis canonical repo, cite Rule-of-Three evidence, rsync hooks, re-run `parent-hook-drift` |
| Understand why a hook blocked me | Read `core-rules/hooks.md` for the spec; error output identifies the rule |
| Roll back a bad merge | `git revert <sha>` → PR → merge. Never `reset --hard` on main. |
| Commit while `.env` is in my diff | Stop. Remove the file. Rotate the secret. Recommit. |
| Skip a broken hook | You don't. Fix the hook or document an override. `--no-verify` is tripwired. |
| Find the last-green commit | `test-health` weekly report has it per project. |
| Promote a rule from deferred.md | Rule of Three satisfied → edit parent rules → delete deferred entry → rsync |

---

## References

- `core-rules/CLAUDE.md` — parent rules (LLM-facing, 76 lines).
- `core-rules/hooks.md` — three-tier hook spec (159 lines).
- `core-rules/inheritance.md` — symlink + @-import mechanism (43 lines).
- `core-rules/deferred.md` — n=1 candidates awaiting third witness (71 lines).
- `core-rules/hooks/README.md` — canonical hook script index + attribution.
- `core-rules/hooks/*.sh` — nine canonical hook implementations.
- `registry.md` — active project opt-in list.
- `blacklist.md` — temporary exemptions.
- `recon.md` — LIFT/LEAVE/DEFER thesis that seeded the regime.
- `scheduled-tasks/` — audit prompt sources.
- `audits/` — dated audit output archive.

## Upstream attribution

Core hook patterns (`block-destructive`, `post-edit-verify`, `stop-verify`, `truncation-check`) derive from [iamfakeguru/claude-md](https://github.com/iamfakeguru/claude-md) (MIT). Extensions are documented in each script's header. The three-tier architecture, TodoWrite-completion guard, `code-review-subagent`, `ui-verify`, session-context / save-context-log / post-compact-context hooks, and the git-boundary tier are Trellis additions.
