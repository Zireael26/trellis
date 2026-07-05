# SETUP — manual walkthrough

If you'd rather have an agent do this for you, paste the contents of [`AGENT_SETUP.md`](AGENT_SETUP.md) into Claude Code, Codex, or another agent conversation with filesystem tools and follow along. This file is for doing it by hand.

Total time: ~30 minutes if you have one project to onboard, +5 minutes per additional project.

---

## 0. Prerequisites

- macOS or Linux
- `bash`, `git`, `jq`, `grep`, `sed` on `PATH`
- Node.js (only required if your projects use husky-managed git hooks)
- A directory for your projects where each project is its own git repo
- Claude Code and/or Codex installed
- For Codex hooks: Codex CLI with hooks support and `[features] hooks = true` in `$CODEX_HOME/config.toml` (the older `codex_hooks` key is deprecated as of Codex CLI 0.129+)

---

## 1. Clone the template

Pick a stable home for Trellis. Convention is alongside your projects directory:

```bash
mkdir -p /path/to/workspace
cd /path/to/workspace
git clone https://github.com/Zireael26/trellis.git trellis-instance
cd trellis-instance
```

> **Why "trellis-instance" not "trellis"?** Once cloned and customized, this *is* your live Trellis control plane — disambiguate from the upstream template by adding the `-instance` suffix.

If you want the customized result on your own GitHub, point the remote at your own repo (create an empty private one first, then):

```bash
git remote set-url origin git@github.com:<YOUR-USER>/trellis-instance.git
```

---

## 2. Decide your placeholder values

Open a scratch buffer and write down:

| Placeholder            | Your value                                            |
|------------------------|-------------------------------------------------------|
| `__TRELLIS_PATH__`     | Absolute path to the cloned repo (no trailing slash) |
| `__PROJECTS_ROOT__`    | Absolute path to the parent dir of your projects     |
| `__MAINTAINER_NAME__`  | Your name                                            |
| `__GITHUB_USER__`      | Your GitHub username                                 |
| `__USER_HOME__`        | Your home directory (e.g., `/home/jane`)             |

Example for a user named "Jane Doe":

```
__TRELLIS_PATH__    = /path/to/workspace/trellis-instance
__PROJECTS_ROOT__   = /path/to/workspace/projects
__MAINTAINER_NAME__ = Jane Doe
__GITHUB_USER__     = janedoe
__USER_HOME__       = /home/jane
```

---

## 3. Substitute placeholders across the repo

From the `trellis-instance` root, run a sed pass for each placeholder. The exclusion list keeps `.git/`, `LICENSE`, `README.md`, `SETUP.md`, and `AGENT_SETUP.md` from being touched (they reference the placeholders by literal name as documentation).

```bash
TRELLIS_PATH="/path/to/workspace/trellis-instance"    # <-- edit
PROJECTS_ROOT="/path/to/workspace/projects"          # <-- edit
MAINTAINER_NAME="Jane Doe"                           # <-- edit
GITHUB_USER="janedoe"                                # <-- edit
USER_HOME="/home/jane"                               # <-- edit

# macOS sed needs `-i ''`; GNU sed (Linux) needs `-i`.
SED_INPLACE=(-i '')   # macOS
# SED_INPLACE=(-i)    # uncomment for Linux

find . -type f \
  ! -path './.git/*' \
  ! -name LICENSE ! -name README.md ! -name SETUP.md ! -name AGENT_SETUP.md \
  -exec sed "${SED_INPLACE[@]}" \
    -e "s|__TRELLIS_PATH__|$TRELLIS_PATH|g" \
    -e "s|__PROJECTS_ROOT__|$PROJECTS_ROOT|g" \
    -e "s|__MAINTAINER_NAME__|$MAINTAINER_NAME|g" \
    -e "s|__GITHUB_USER__|$GITHUB_USER|g" \
    -e "s|__USER_HOME__|$USER_HOME|g" \
    {} +
```

**Verify:** no leftover placeholders should remain in source files.

```bash
grep -rn "__TRELLIS_PATH__\|__PROJECTS_ROOT__\|__MAINTAINER_NAME__\|__GITHUB_USER__\|__USER_HOME__" . \
  --exclude-dir=.git --exclude=LICENSE --exclude=README.md --exclude=SETUP.md --exclude=AGENT_SETUP.md
# (should print nothing)
```

---

## 4. Choose harness support

The `harnesses` array in `trellis.config.json` accepts any combination of:

```json
"harnesses": ["claude", "codex"]
```

**What each harness gets:**

- **`claude`** — Claude Code. Seeds `.claude/{rules,skills,commands,primers,hooks}/`, `.claude/settings.json`, and root `CLAUDE.md`.
- **`codex`** — Codex CLI. Seeds the shared `AGENTS.md` + `.agents/{rules,skills,primers,workflows}/` surface, the Codex-only `.agents/commands/*.md` slash commands, and the Codex-only `.codex/hooks.json` + `.codex/hooks/*.sh` hook envelope.

Codex reads the shared `AGENTS.md` symlink and the `.agents/{rules,skills,primers,workflows}/` content; the shared surface is seeded once.

If you intentionally use only one harness, remove the unused entries from `trellis.config.json`.

For Codex hooks, also confirm your user config has:

```toml
[features]
hooks = true
```

---

## 5. Onboard your first project

Pick one of your existing projects and onboard it. The script seeds the inheritance symlink, the project-local files (`gotchas.md`, `context-log.md`), and (if it's a Node project) the husky hook stack.

```bash
./scripts/onboard-project.sh /path/to/workspace/projects/my-app
```

Read the script's "Next steps" output carefully — it asks you to:

1. Add the `@`-import line at the top of the project's `CLAUDE.md`.
2. If Codex is enabled, review `AGENTS.md`, `.agents/`, and `.codex/`.
3. `git add` the new files inside the project.
4. Run `pnpm install` / `bun install` / `npm install` so husky activates.
5. Add a row to `registry.md` here in `trellis-instance/`.

With the default `harnesses: ["claude", "codex"]`, onboarding also seeds the shared `.agents/` surface for Codex: a root `AGENTS.md` entrypoint when safe plus `.agents/rules/`, `.agents/skills/`, and `.agents/workflows/*.md` slash-command copies. After onboarding 1–3 projects, you'll see the system pay off — the `cross-project-process-audit` will start surfacing real findings.

---

## 6. (Optional) Wire up scheduled audits

The `scheduled-tasks/` dir holds prompts and configuration for 10 weekly/monthly audits. To actually *run* them on a schedule, you need either:

- **Cowork mode (Claude Code)** — register each task using `mcp__scheduled-tasks__create_scheduled_task`. The thin wrapper reads `prompt.md` + `targets.md` at run time so you can edit them in version control without re-registering. See `scheduled-tasks/README.md` for cron times and the connected-folder requirement.
- **Plain cron + `claude -p`** — invoke `claude -p < scheduled-tasks/<task>/prompt.md` from cron, redirecting output to `audits/`. You lose the per-run target capture but it works fine for single-machine setups.

You don't have to enable any of them on day one. They become useful once you have ≥3 registered projects.

---

## 7. Commit and push your customized Trellis

```bash
git add -A
git commit -m "chore: bootstrap Trellis for $USER"
git push
```

This is now your living control plane. Future changes — new rules, new audits, registry updates — go through the same PR flow you'll be enforcing on your other projects (the husky `pre-push` hook in your projects blocks direct pushes to `main`; the same discipline applies here once you wire it).

---

## What's next

Read `engineering-process.md` cover to cover (it's ~25KB; takes about 30 min). It is the narrative source of truth — every decision, why, and how it connects to the rest. After that, `core-rules/CLAUDE.md` and `core-rules/hooks.md` are quick references you'll come back to.
