# AGENT_ONBOARD_PROJECT.md — paste-into-agent project onboarding

> **For the human:** open an agent (Claude Code, Codex, Cowork, or any agent with filesystem + shell tools) **inside this Trellis canonical repo**, then paste **everything below the `--- BEGIN PROMPT ---` line**. The agent will interview you — including a short pass on what has bitten you in this repo, which is the one thing it cannot work out for itself — run `scripts/onboard-project.sh`, wire your project's `CLAUDE.md`, seed `gotchas.md`, update `registry.md`, commit in both repos, and verify.
>
> Works for three entry paths:
> - **`new`** — a project not yet in `registry.md`. Full onboarding.
> - **`fresh-clone`** — a registered project freshly cloned to a new machine. Just re-creates the per-machine symlinks.
> - **`repair`** — a registered project whose canonical artefacts have drifted. Re-runs onboarding, reports what was missing.
>
> Run the manual playbook in [`engineering-process.md` §10](engineering-process.md#10-onboarding-a-new-project-full-playbook) instead if you want to walk it by hand. If this Trellis clone opts into an operator-managed shared runtime, use [`docs/local-development-infrastructure.md`](docs/local-development-infrastructure.md) as the public integration manual.

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
6. `trellis.config.json` — to read `trellis_root`, `projects_root`, optional `shared_infra_root`, and `harnesses`. You'll need the resolved `trellis_root` for the `@`-import path. The shared-infrastructure path is used only when the optional key is non-empty.
7. If `shared_infra_root` is non-empty, read [`docs/local-development-infrastructure.md`](docs/local-development-infrastructure.md), then read `$SHARED_INFRA_ROOT/projects.yaml` and the external repository's `Makefile`. Understand the current manifest entry shape and use only targets that actually exist. Do not edit the manifest by hand around the `register` target. If the key is absent, skip these shared-infrastructure reads and continue with ordinary onboarding.

Resolve the optional path before continuing and validate it only when enabled:

```bash
SHARED_INFRA_ROOT="$(jq -r '.shared_infra_root // empty' trellis.config.json)"
if [ -n "$SHARED_INFRA_ROOT" ]; then
  test -d "$SHARED_INFRA_ROOT"
  test -f "$SHARED_INFRA_ROOT/projects.yaml"
  test -f "$SHARED_INFRA_ROOT/Makefile"
fi
```

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
- **`Codex acknowledgement`** — if `harnesses` in `trellis.config.json` includes `"codex"`, remind the user that Codex hooks require `[features] hooks = true` in `$CODEX_HOME/config.toml` (the older `codex_hooks` key is deprecated as of Codex CLI 0.129+). Don't ask whether to enable Codex — that's a global config choice already made.

- **`local infrastructure declaration`** — resolve `SHARED_INFRA_ROOT` with `jq -r '.shared_infra_root // empty'`. When it is empty, shared-infrastructure integration is disabled: collect no external manifest declaration, pass no `--infra-entry`, and continue with ordinary onboarding. When it is non-empty, every registered project must have a reviewed `services` + `ports` entry in `$SHARED_INFRA_ROOT/projects.yaml`, including explicit `services: {}` when it consumes none of the externally managed shared services. Do not infer that omission means none.

  With the integration enabled, a new project or an existing project adopting another service first gets a conservative static proposal:

  ```bash
  make -C "$SHARED_INFRA_ROOT" propose \
    PROJECT="$PROJ_BASE" SOURCE="$PROJECT" \
    OUTPUT="/absolute/path/to/$PROJ_BASE-infra-proposal.yaml"
  ```

  Review the proposal with the user. Discovery may cite recognized Compose images/services, host-port mappings, environment-variable names and endpoints, Make/package startup commands, and emulator declarations. It must not source environment files, execute project code, read secret values, choose an allocation or credential silently, or overwrite an existing entry. Resolve every ambiguity explicitly. The reviewed fragment contains only `services` and `ports`; the project name comes from the registry/basename and cannot redirect the write.

  Echo the reviewed fragment with the other collected values and wait for explicit approval. Record its absolute path as `INFRA_ENTRY`; do not proceed to external manifest mutation with an unreviewed proposal. The external repository remains operator-managed; Trellis only delegates to its reviewed Make contract.

- **`gotchas`** — the only genuinely non-derivable input, and the highest-value thing this interview can collect. Everything above this line, you could work out from the filesystem; this you cannot. Ask, in the user's own words:
  - "What has bitten you in this repo that you'd warn a new contributor about on day one?"
  - "What here looks like it does one thing but actually does another?"
  - "What's the thing you have to explain to every new person?"
  - "Is there a directory, service, or dependency that is dead, half-migrated, or load-bearing in a way its name doesn't convey?"

  Ask up to four; stop when the answers stop surprising you. If the user has nothing, that is a legitimate answer — say so in the final report and move on. **Do not invent gotchas.**

  Before asking, spend a couple of tool calls looking: skim the README, the last 20 commit subjects, and any `TODO` / `HACK` / `XXX` / `FIXME` comments. Lead with what you found — "I noticed X; is that deliberate?" — rather than a blank prompt. A specific question gets a specific answer; an open one gets "nothing comes to mind."

  ```bash
  git -C "$PROJECT" log --oneline -20
  grep -rIn --exclude-dir=node_modules --exclude-dir=.git -E "(TODO|HACK|XXX|FIXME)" "$PROJECT" | head -30
  ```

  You write these up in Step 4b, once `onboard-project.sh` has seeded `gotchas.md`.

Echo all collected values back as a table, with the gotchas listed underneath it in the user's own phrasing. Wait for explicit "yes" before continuing.

### Step 3 — Run the onboarding script

This step applies to all three modes. The script is idempotent and detects what it needs to seed.

For mode `new`, choose the command from the optional configuration. With shared-infrastructure integration enabled, an undeclared project must pass the explicitly reviewed manifest fragment; without `--infra-entry`, the script produces a proposal and completes ordinary Trellis onboarding without mutating the external manifest — no `register` or `reconcile` target runs. With the integration disabled, use the ordinary one-argument onboarding path and do not pass `--infra-entry`.

```bash
if [ -n "$SHARED_INFRA_ROOT" ]; then
  ./scripts/onboard-project.sh "$PROJECT" --infra-entry "$INFRA_ENTRY"
else
  ./scripts/onboard-project.sh "$PROJECT"
fi
```

For `fresh-clone` or `repair`, the one-argument rerun remains idempotent. When integration is enabled, the existing external manifest entry is reused; when it is disabled, no shared-infrastructure validation or mutation runs:

```bash
./scripts/onboard-project.sh "$PROJECT"
```

What the script does (do not re-implement any of this):

- Seeds `gotchas.md`, `context-log.md` at the project root.
- Appends the Trellis fragment to `.gitignore` (skipped if already present).
- Removes legacy tracked symlinks from the git index if any.
- Creates the absolute-path symlinks (`.claude/rules/trellis.md`, `.claude/skills/{process-gate,security-gate,...}`, `.claude/commands/{primer,primer-refresh,primer-check}.md`, plus `.agents/...` equivalents if Codex is enabled).
- Seeds `.claude/skills/process-gate-local/local.config.sh` with the auto-detected stack profile.
- When `SHARED_INFRA_ROOT` is non-empty, validates the reviewed `services` + `ports` fragment, atomically registers it through the external repository, and reconciles only that project. A no-service declaration remains explicit as `services: {}`. When the key is absent, it skips all shared-infrastructure proposal, registration, and reconciliation work.
- With integration enabled, seeds `scripts/local-infra-preflight.sh` from the canonical template. Wire this wrapper into the project's native startup path so fixed-port checks run before application processes or project-owned infrastructure bind listeners. The wrapper preflights only; projects with `services: {}` do not start the shared runtime. With integration disabled, no wrapper or shared-infrastructure startup check is required.
- Copies `.claude/primers/INDEX.md` from the canonical primer-index template — opt-in feature primer system bootstrap. Empty INDEX = "no primers yet"; primers accumulate via `/primer <slug>` over time. INDEX.md and individual primer files are project-state (tracked in git); the three command symlinks are gitignored per the fragment.
- Copies Claude hooks → `.claude/hooks/*.sh` and `.claude/settings.json`.
- If `package.json` exists: seeds `.husky/{pre-commit,commit-msg,pre-push}`.
- If Codex is enabled: seeds the shared `AGENTS.md → CLAUDE.md` relative symlink, `.agents/rules/`, `.agents/skills/`, `.agents/primers/INDEX.md`, and `.agents/skills/process-gate-local/local.config.sh`.
- If Codex is enabled (in addition to the shared surface): seeds `.codex/hooks.json`, `.codex/hooks/*.sh`, `.agents/commands/*.md` slash-command symlinks, and `.agents/workflows/*.md` slash-command tracked copies (Codex reads `.agents/`, including `.agents/workflows/`; workflow aliases are tracked copies, not symlinks, so they stay portable across teammates).
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

**Layout check.** Skim the top-level directories yourself — you do not need the user to describe them, and asking them to type out what `ls` already tells you wastes the interview:

```bash
ls -d "$PROJECT"/*/ 2>/dev/null \
  | grep -Ev '/(node_modules|\.next|dist|build|out|target|vendor|\.venv|venv|coverage|\.turbo|\.cache)/$'
```

The names plus a glance inside will resolve most of them. Ask about only the ones that *don't* resolve: a name that doesn't match its contents, a tree that looks abandoned, a split you can't account for. Write a `## Codebase map` section holding only those lines, directly under `## Architecture`:

```markdown
## Codebase map
- `py/` — despite the name, only the ML runners; the ingest scripts are in `services/`
- `legacy-web/` — dead since the Next.js migration; kept for the redirect table only
```

**Keep the heading when the project has ≥ 5 top-level directories, even if nothing misleads.** In that case the section carries a single line saying so — `- Layout is self-describing; no directory misstates its role.` — which is itself useful information, and it costs one line rather than the full inventory the section used to hold.

Below that threshold, skip the section when there is nothing to say.

This is a deliberate split between *what the section contains* and *whether it exists*. The content rule changed, because a plain listing of top-level directories is something an agent derives from one `ls` and paying injected tokens for it every turn buys nothing. The existence rule did not change, because the scheduled `cross-project-process-audit` still reports any registered project with ≥ 5 top-level directories whose `CLAUDE.md` lacks the heading, and whether to retire that check is an operator decision that has not been made. Keeping the heading means a correctly-onboarded project does not become a standing false positive in an advisory report while that decision is pending — and noisy advisory findings are exactly what decays compliance.

### Step 4b — Write the gotchas (mode `new` only)

`onboard-project.sh` seeds `gotchas.md` from the canonical template, which is **empty**. Without this step every project starts with the file and none of the content, and the `session-context` hook surfaces nothing at session start until someone happens to log the first entry by hand.

Write each gotcha you collected in Step 2 into `$PROJECT/gotchas.md`, replacing the `*(empty — add entries as they surface)*` placeholder. Use the canonical entry format from [`engineering-process.md` §9.3](engineering-process.md#93-gotchasmd), with today's date (`date +%Y-%m-%d`):

```markdown
## <YYYY-MM-DD> — <short title>
**Context:** <where this bit us>
**Gotcha:** <what actually happens>
**Rule:** <what to do about it>
```

Keep the user's own phrasing in the **Gotcha** line — that is the part that carries the information. Then surface the two or three most live ones inline under a `## Gotchas` heading in the project `CLAUDE.md`, above `## Stack`, with a pointer to `gotchas.md` for the full log:

```markdown
## Gotchas
- <one line each — the ones that will bite this week>

Full log: `gotchas.md`.
```

If the user had nothing to offer, leave `gotchas.md` as seeded and omit the `## Gotchas` section. Do not invent entries to fill the space.

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
        .claude/hooks .claude/settings.json .claude/primers/ \
        .claude/skills/security-gate \
        .claude/skills/process-gate-local/local.config.sh \
        AGENTS.md .agents/primers/ .agents/workflows/ \
        .agents/skills/security-gate \
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

# Inherited rules surface the loop-safety contract: loop-safety.md is reachable as a
# sibling of the symlink target. Onboarded projects inherit the contract automatically
# via the parent-rules symlink — there is no per-project copy (post-merge: passes for
# new / fresh-clone / repair alike).
test -e "$(dirname "$(readlink -f "$PROJECT/.claude/rules/trellis.md")")/loop-safety.md"

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

# Shared .agents/ surface (only if "codex" in trellis.config.json harnesses)
test -L "$PROJECT/AGENTS.md"
test -e "$PROJECT/.agents/rules/trellis.md"
test -e "$PROJECT/.agents/skills/process-gate/SKILL.md"
test -f "$PROJECT/.agents/primers/INDEX.md"

# Codex-only artifacts (only if "codex" in harnesses)
test -f "$PROJECT/.codex/hooks.json"
ls "$PROJECT/.codex/hooks"/*.sh
test -L "$PROJECT/.agents/commands/primer.md"
# .agents/workflows/ is seeded for Codex too — Codex reads .agents/, including .agents/workflows/
# (tracked copies, not symlinks, so use test -f)
test -f "$PROJECT/.agents/workflows/primer.md"
test -f "$PROJECT/.agents/workflows/explore.md"

# Registry row present (mode `new`): match absolute path, shorthand, or projects-root-relative form
grep -nE "\`(${PROJECT}|${PROJ_SHORT}${PROJ_REL:+|${PROJ_REL}})\`" registry.md

# Ordinary Trellis doctor always runs. Shared-infrastructure validation,
# preflight, and external doctor run only when the optional integration is enabled.
./scripts/doctor.sh --project "$PROJ_BASE"
if [ -n "$SHARED_INFRA_ROOT" ]; then
  # Every external entry has explicit services + ports; services: {} is valid
  # and required when the project consumes no shared service.
  make -C "$SHARED_INFRA_ROOT" validate PROJECT="$PROJ_BASE"
  test -x "$PROJECT/scripts/local-infra-preflight.sh"
  "$PROJECT/scripts/local-infra-preflight.sh"
  make -C "$SHARED_INFRA_ROOT" doctor \
    PROJECT="$PROJ_BASE" REGISTRY_FILE="$PWD/registry.md"
fi

# Both repos clean after the commits
( cd "$PROJECT" && git status --short )           # should be empty
git status --short                                # in Trellis canonical repo: should be empty
```

Report any check that fails. Don't claim success until they all pass.

For mode `repair`, also note that operators can configure a private hook-drift check to compare deployed hooks byte-for-byte with canonical. For immediate deterministic verification, run `./scripts/doctor.sh`; do not assume an operator scheduler or named audit is installed.

### Step 8 — Final report

Three short blocks, in order:

1. **What changed.** A short paragraph: mode (new / fresh-clone / repair), paths created, symlinks installed, registry row added, two commit SHAs (if applicable). Say how many gotchas you logged, or state plainly that the user had none. Quote any `WARN:` lines the script produced.
2. **What's still on the user.**
   - Push the project commit and (mode `new`) the Trellis-repo commit when ready.
   - If GitHub repo doesn't exist yet, create it and enable branch protection on `main` (see `engineering-process.md` §10.2 step 14).
   - If `package.json` exists, run `pnpm install` / `bun install` / `npm install` so husky activates `core.hooksPath`.
   - If Codex is enabled, confirm `$CODEX_HOME/config.toml` has `[features] hooks = true` (the older `codex_hooks` key still works but is deprecated as of Codex CLI 0.129+).
   - If the project is Unity / Rust / Go / Python-only, set up `.githooks/` per `core-rules/inheritance.md` "Native git hooks".
   - The `CLAUDE.md` we seeded is deliberately thin, and thin is the target — under 5 KB. It grows from `gotchas.md`, not from documentation written up front: log corrections as they happen, and the `gotchas-rollup` audit promotes anything that recurs three times. Resist the urge to describe the codebase in it; describe what the codebase will get wrong.
3. **What runs automatically.** The inherited rules and hooks apply immediately. No audit schedule ships by default; if this operator has private registry-driven audits, note that the new project becomes eligible under that operator's own cadence.

Hand off cleanly. Don't write a tutorial — the manual is in `engineering-process.md`.

### Later shared-service adoption

An already registered project uses the same proposal-review-registration path when it begins consuming an operator-managed shared service or adds a fixed listener. This path exists only when the optional integration is configured:

```bash
SHARED_INFRA_ROOT="$(jq -r '.shared_infra_root // empty' trellis.config.json)"
test -n "$SHARED_INFRA_ROOT"
make -C "$SHARED_INFRA_ROOT" propose \
  PROJECT="$PROJ_BASE" SOURCE="$PROJECT" \
  OUTPUT="/absolute/path/to/$PROJ_BASE-infra-proposal.yaml"
# Review and complete the proposal; never register it unseen.
./scripts/onboard-project.sh "$PROJECT" --infra-entry "$INFRA_ENTRY"
./scripts/doctor.sh --project "$PROJ_BASE"
make -C "$SHARED_INFRA_ROOT" doctor \
  PROJECT="$PROJ_BASE" REGISTRY_FILE="$PWD/registry.md"
```

If `shared_infra_root` is absent, there is no shared-service adoption path to run; keep using ordinary onboarding until an operator separately supplies and configures an external repository. When enabled, update the project's environment examples, migrations, startup preflight, native run documentation, and project-owned infrastructure commands. Reconcile and verify the new allocation, including appropriate positive and negative isolation checks. Project shutdown must leave the shared runtime running. Publish changes in both repositories through scoped PRs with commit, gate, PR, merge, and local-main synchronization receipts.

### Discipline you must follow throughout

- **Read before editing.** Read every file you're about to modify, even one you "know." Your memory of a file read earlier in the session can be stale.
- **Don't push without explicit permission.** Step 6 stops at local commits.
- **Don't create accounts or repos for the user.** Step 8 reminds them to create the GitHub repo themselves.
- **Don't invent project-specific rules or gotchas.** When seeding a new project's `CLAUDE.md` in Steps 4 and 4b, keep it to the `@`-import plus whatever the user actually told you in Step 2. An empty `## Gotchas` section is better than a guessed one.
- **Check in where it costs the user something.** Confirm before Step 3 (the script can run 10–60 minutes on the security baseline) and before Step 6 (commits land in two repos). The steps in between — the registry row, the `@`-import, the gotchas write-up — follow from the interview they already approved; do them and report. If you hit something genuinely ambiguous, ask and end the turn rather than guessing.

## --- END PROMPT ---
