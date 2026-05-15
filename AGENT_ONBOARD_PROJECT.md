# AGENT_ONBOARD_PROJECT.md — paste-into-agent project onboarding

> **For the human:** open an agent (Claude Code, Codex, Cowork, or any agent with filesystem + shell tools) **inside this Trellis canonical repo**, then paste **everything below the `--- BEGIN PROMPT ---` line**. The agent will interview you, run `scripts/onboard-project.sh`, wire your project's `CLAUDE.md`, update `registry.md`, commit in both repos, and verify.
>
> Works for three entry paths:
> - **`new`** — a project not yet in `registry.md`. Full onboarding.
> - **`fresh-clone`** — a registered project freshly cloned to a new machine. Just re-creates the per-machine symlinks.
> - **`repair`** — a registered project whose canonical artefacts have drifted. Re-runs onboarding, reports what was missing.
>
> Run the manual playbook in [`engineering-process.md` §10](engineering-process.md#10-onboarding-a-new-project-full-playbook) instead if you want to walk it by hand.

---

## --- BEGIN PROMPT ---

You are onboarding a project into **Trellis** — a multi-project engineering-process control plane. The repo you're working in is the Trellis control plane; the project being onboarded lives elsewhere on disk. Work carefully and verify each step.

### Step 0 — Establish context

Before touching anything, read these files in order so you understand the system:

1. `registry.md` — the current list of active projects + the **Class** enumeration (around lines 36-38). The "How to add a project" section is at the top.
2. `engineering-process.md` §10 "Onboarding a new project — full playbook" — the authoritative manual flow. You're automating it.
3. `core-rules/inheritance.md` — the registered-project checklist (around lines 34-44), the gitignore policy for symlinks (search for "gitignored"), and the "Native git hooks" section for non-Node projects.
4. `scripts/onboard-project.sh` — at minimum the header comment and the `guess_profile()` function. Don't reimplement anything this script already does.
5. `blacklist.md` — confirm the target project is not on the never-onboard list.
6. `trellis.config.json` — to read `trellis_root`, `projects_root`, and `harnesses`. You'll need the resolved `trellis_root` for the `@`-import path.

After reading, in one short paragraph, tell the user what you're about to do and which mode you intend to run (you'll detect the mode in Step 1).

### Step 1 — Mode detection

Ask the user for the **absolute path** to the project they want to onboard. Then detect the mode.

`registry.md` and `blacklist.md` cite paths in **shorthand** form (e.g., `` `/personal/neev` ``), not as the absolute path. You must check both forms or the lookup will silently misclassify a fresh-clone as a new project. Compute both:

```bash
PROJECT="<absolute-path-from-user>"
test -d "$PROJECT"                                    # must be a directory
test -e "$PROJECT/.git"                               # must be a git repo (else offer to `git init`)

PROJECTS_ROOT="$(jq -r .projects_root trellis.config.json)"
PROJ_BASE="$(basename "$PROJECT")"
PROJ_SHORT="/personal/$PROJ_BASE"                     # shorthand form used in registry/blacklist
case "$PROJECT" in
  "$PROJECTS_ROOT"/*)
    PROJ_REL="${PROJECT#"$PROJECTS_ROOT"}"            # e.g. /neev — only if under projects_root
    ;;
  *) PROJ_REL="" ;;
esac

# In the Trellis canonical repo. Check abs path, shorthand, and projects-root-relative — registry/blacklist
# rows wrap paths in backticks, so anchor with backticks to avoid false matches.
matches_any() {
  local file="$1"
  grep -qE "\`(${PROJECT}|${PROJ_SHORT}${PROJ_REL:+|${PROJ_REL}})\`" "$file" 2>/dev/null
}
matches_any blacklist.md && BLACKLISTED=1 || BLACKLISTED=0
matches_any registry.md  && REGISTERED=1  || REGISTERED=0

# Inside the project
test -L "$PROJECT/.claude/rules/trellis.md"           # canonical symlink present?
readlink "$PROJECT/.claude/rules/trellis.md" 2>/dev/null  # target matches trellis_root?
```

If either lookup ambiguously matches (e.g. the user's project basename happens to overlap with an unrelated registry row), surface the matching rows and ask the user which is correct before proceeding.

Mode rules:

| Mode | Condition |
|---|---|
| `new` | Path not in `registry.md`. Not blacklisted. |
| `fresh-clone` | Path in `registry.md`. `.claude/rules/trellis.md` symlink missing or broken. |
| `repair` | Path in `registry.md`. Symlink present. But filesystem state drifted — missing `.claude/hooks/`, missing `gotchas.md`, missing skill symlinks, etc. |

If the project is on `blacklist.md`, **stop and tell the user**. Don't proceed.

If `registry.md` already has a row for this project under a different path, surface the conflict and ask which is correct before continuing.

### Step 2 — Interview (mode `new` only)

Use whatever clarification mechanism your tooling provides (multi-choice question tool if available, or plain chat). Collect:

- **`name`** — final project name. The project's directory basename should match.
- **`path`** — already captured in Step 1. Confirm it lives under `projects_root` (read from `trellis.config.json`). Warn if it doesn't — the scheduled `cross-project-process-audit` walks `projects_root`, so projects outside it will be invisible to the audit. Symlink targets resolve fine either way.
- **`class`** — one of the documented shapes in `registry.md` ("Current shapes seen in active projects"). At time of writing: `monorepo SaaS`, `single Next.js app`, `portfolio site`, `app`, `game (Unity, 3D)`, plus reserved `service` and `api`. Present as multi-choice. If the user proposes a new shape, accept it but flag that it should also land in the class paragraph in `registry.md`.
- **`stack profile`** — run the auto-detect from `scripts/onboard-project.sh`:
  ```bash
  bash -c '
    p="'"$PROJECT"'"
    if [ -f "$p/pnpm-workspace.yaml" ] || ([ -f "$p/package.json" ] && grep -q "\"workspaces\"" "$p/package.json" 2>/dev/null); then echo monorepo-pnpm
    elif [ -f "$p/next.config.ts" ] || [ -f "$p/next.config.js" ] || [ -f "$p/next.config.mjs" ]; then echo web-next
    elif [ -f "$p/vite.config.ts" ] || [ -f "$p/vite.config.js" ]; then echo web-vite
    elif [ -f "$p/Cargo.toml" ] || [ -f "$p/go.mod" ] || [ -f "$p/pyproject.toml" ]; then echo native-other
    elif [ -d "$p/Assets" ] && [ -d "$p/ProjectSettings" ]; then echo unity
    else echo n-a; fi'
  ```
  Show the result and let the user override. The script writes this into `.claude/skills/process-gate-local/local.config.sh` as `PROCESS_GATE_STACK_PROFILE`.
- **`GitHub repo URL`** — for the registry row's notes column. If the user hasn't created a remote yet, that's fine; capture nothing and remind them at the end.
- **`Codex acknowledgement`** — if `harnesses` in `trellis.config.json` includes `"codex"`, remind the user that Codex hooks require `[features] codex_hooks = true` in `$CODEX_HOME/config.toml`. Don't ask whether to enable Codex — that's a global config choice already made.

Echo all collected values back as a table. Wait for explicit "yes" before continuing.

### Step 3 — Run the onboarding script

This step applies to all three modes. The script is idempotent and detects what it needs to seed.

```bash
./scripts/onboard-project.sh "$PROJECT"
```

What the script does (do not re-implement any of this):

- Seeds `gotchas.md`, `context-log.md` at the project root.
- Appends the Trellis fragment to `.gitignore` (skipped if already present).
- Removes legacy tracked symlinks from the git index if any.
- Creates the absolute-path symlinks (`.claude/rules/trellis.md`, `.claude/skills/{process-gate,security-gate,...}`, `.claude/commands/{primer,primer-refresh,primer-check}.md`, plus `.agents/...` equivalents if Codex is enabled).
- Seeds `.claude/skills/process-gate-local/local.config.sh` with the auto-detected stack profile.
- Copies `.claude/primers/INDEX.md` from the canonical primer-index template — opt-in feature primer system bootstrap. Empty INDEX = "no primers yet"; primers accumulate via `/primer <slug>` over time. INDEX.md and individual primer files are project-state (tracked in git); the three command symlinks are gitignored per the fragment.
- Copies Claude hooks → `.claude/hooks/*.sh` and `.claude/settings.json`.
- If `package.json` exists: seeds `.husky/{pre-commit,commit-msg,pre-push}`.
- If Codex is enabled: seeds `AGENTS.md → CLAUDE.md` relative symlink, `.codex/hooks.json`, `.codex/hooks/*.sh`, plus `.agents/commands/` and `.agents/primers/INDEX.md` mirrors.
- Runs the Mode-1 security-gate baseline unless `TRELLIS_SKIP_SECURITY_BASELINE=1`. The baseline can take 10-60 minutes; tell the user before running. Offer the skip env-var if they want to defer.

Capture the script's stdout. Surface any line starting with `WARN:` to the user — those signal pre-existing files the script didn't overwrite.

**Unity / Rust / Go / Python-only projects.** If the profile is `unity` or `native-other` and there is no `package.json`, the script skips husky. Tell the user they need native git hooks per `core-rules/inheritance.md` "Native git hooks" — at minimum a `pre-push` that runs the Trellis PR-flow guard. Templates live in `core-rules/husky/`; the user can copy them to `.githooks/` and run `git config core.hooksPath .githooks`. Do **not** auto-create `.githooks/` — leave that decision to the user.

### Step 4 — Wire the project's `CLAUDE.md` `@`-import

Resolve the canonical path once:

```bash
CANONICAL_RULES="$(jq -r .trellis_root trellis.config.json)/core-rules/CLAUDE.md"
test -f "$CANONICAL_RULES"   # sanity check
```

Then handle the project's `CLAUDE.md`:

- **If `$PROJECT/CLAUDE.md` exists and already contains `@$CANONICAL_RULES` (exact match or with a different absolute-path prefix that resolves to the same target):** leave it alone.
- **If `$PROJECT/CLAUDE.md` exists but is missing the import:** prepend `@$CANONICAL_RULES` as the first non-blank line, followed by a blank line, then the existing content. Read the file first; verify the prepend after.
- **If `$PROJECT/CLAUDE.md` does not exist:** create a minimal stub:
  ```markdown
  @<resolved CANONICAL_RULES>

  # <project name>

  Project-specific rules below the @-import. Inherits everything from core-rules/CLAUDE.md.
  ```
  Don't invent project-specific rules — that's for the user.

### Step 5 — Update `registry.md` (mode `new` only)

Append a row to the "Active projects" table. Match the path style and tone of the existing rows.

```markdown
| <name> | `<path>` | <class> | Onboarded YYYY-MM-DD. <one-line notes — GitHub URL if known, native-githooks if applicable, branch-protection status>. |
```

Use `date +%Y-%m-%d` for the date. The path can be relative (`/personal/<name>`) if it lives under `projects_root` and the existing rows use that shorthand — match the surrounding rows.

For `fresh-clone` and `repair`: do **not** touch `registry.md`. The row already exists.

### Step 6 — Commits

Two separate commits, one in each repo. Do **not** push either — the user pushes when they're ready.

**In the project** (`cd "$PROJECT"`):

```bash
git status                                  # see what onboarding produced
# Stage what's actually changed. Common candidates (only stage what exists + is untracked/modified):
git add CLAUDE.md gotchas.md context-log.md .gitignore \
        .claude/hooks .claude/settings.json .claude/skills/security-gate \
        .claude/skills/process-gate-local/local.config.sh \
        AGENTS.md .agents/skills/security-gate \
        .agents/skills/process-gate-local/local.config.sh \
        .codex/hooks.json .codex/hooks \
        .husky 2>/dev/null || true
git status                                  # verify staging looks right
git commit -m "chore: onboard to Trellis"
```

Some paths above only exist for Codex / Node / Unity projects — `git add` will skip missing ones silently. The four absolute-path symlinks (`.claude/rules/trellis.md`, `.claude/skills/process-gate`, `.agents/rules/trellis.md`, `.agents/skills/process-gate`) are **gitignored** by the fragment and should NOT appear in `git status`. If they do, something went wrong — investigate before committing.

Don't `git add -A` — that picks up unrelated working-tree changes the user may have in flight.

**In the Trellis canonical repo** (mode `new` only):

```bash
git status                                  # only registry.md should be modified
git add registry.md
git commit -m "chore: register <name>"
```

For `fresh-clone` and `repair`: no Trellis-repo commit needed.

### Step 7 — Verification

Run these checks against the project. All must pass.

```bash
# Resolves to the canonical rules file
readlink -f "$PROJECT/.claude/rules/trellis.md" | grep -F "core-rules/CLAUDE.md"

# Symlinks are gitignored, not tracked
( cd "$PROJECT" && ! git ls-files --error-unmatch .claude/rules/trellis.md 2>/dev/null )
( cd "$PROJECT" && ! git ls-files --error-unmatch .claude/skills/process-gate 2>/dev/null )

# Process-gate skill symlink resolves
test -e "$PROJECT/.claude/skills/process-gate/SKILL.md"

# Hooks present + executable, and settings.json references them
ls "$PROJECT/.claude/hooks"/*.sh                  # at least one .sh
test -f "$PROJECT/.claude/settings.json"
grep -q '\$CLAUDE_PROJECT_DIR' "$PROJECT/.claude/settings.json"

# Project root files
test -f "$PROJECT/CLAUDE.md"
grep -qF "@$CANONICAL_RULES" "$PROJECT/CLAUDE.md" || \
  grep -qE "^@.*core-rules/CLAUDE\.md$" "$PROJECT/CLAUDE.md"
test -f "$PROJECT/gotchas.md"
test -f "$PROJECT/context-log.md"

# Codex parity (only if "codex" in trellis.config.json harnesses)
test -L "$PROJECT/AGENTS.md"
test -e "$PROJECT/.agents/rules/trellis.md"
test -e "$PROJECT/.agents/skills/process-gate/SKILL.md"
test -f "$PROJECT/.codex/hooks.json"
ls "$PROJECT/.codex/hooks"/*.sh

# Registry row present (mode `new`)
grep -nF "$PROJECT" registry.md

# Both repos clean after the commits
( cd "$PROJECT" && git status --short )           # should be empty
git status --short                                # in Trellis canonical repo: should be empty
```

Report any check that fails. Don't claim success until they all pass.

For mode `repair`, also note that the `parent-hook-drift` scheduled task (Sun 21:00) does a byte-level SHA comparison of hooks vs canonical. If the user wants immediate verification rather than waiting for the next run, suggest triggering it manually via `mcp__scheduled-tasks__*` (the agent tooling exposes this).

### Step 8 — Final report

Three short blocks, in order:

1. **What changed.** A short paragraph: mode (new / fresh-clone / repair), paths created, symlinks installed, registry row added, two commit SHAs (if applicable). Quote any `WARN:` lines the script produced.
2. **What's still on the user.**
   - Push the project commit and (mode `new`) the Trellis-repo commit when ready.
   - If GitHub repo doesn't exist yet, create it and enable branch protection on `main` (see `engineering-process.md` §10.2 step 14).
   - If `package.json` exists, run `pnpm install` / `bun install` / `npm install` so husky activates `core.hooksPath`.
   - If Codex is enabled, confirm `$CODEX_HOME/config.toml` has `[features] codex_hooks = true`.
   - If the project is Unity / Rust / Go / Python-only, set up `.githooks/` per `core-rules/inheritance.md` "Native git hooks".
3. **What runs automatically.** The fleet picks up the new project on its next schedule: `cross-project-process-audit` (Mon 10:00), `parent-hook-drift` (Sun 21:00), `registry-blacklist-health` (Mon 10:30). Offer to trigger any of them now via `mcp__scheduled-tasks__*` if available.

Hand off cleanly. Don't write a tutorial — the manual is in `engineering-process.md`.

### Discipline you must follow throughout

- **Read before editing.** Read every file you're about to modify, even one you "know." The Edit tool fails silently on stale `old_string` matches.
- **Verify after editing.** After Step 4 (`@`-import) and Step 5 (registry row), re-read the file and confirm the change landed where you intended.
- **Don't push without explicit permission.** Step 6 stops at local commits.
- **Don't create accounts or repos for the user.** Step 8 reminds them to create the GitHub repo themselves.
- **Don't invent project-specific rules.** When seeding a new project's `CLAUDE.md` in Step 4, keep it minimal — just the `@`-import.
- **One step at a time.** Wait for "yes" between Steps 2, 3, 5, and 6. The user is in the loop.

## --- END PROMPT ---
