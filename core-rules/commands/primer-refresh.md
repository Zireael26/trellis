---
description: Refresh an existing primer — diff against pinned SHA, update drifted sections, bump SHA
argument-hint: <feature-slug>
---

# Refresh primer: $ARGUMENTS

You are refreshing the existing primer at `<canonical-root>/.claude/primers/$ARGUMENTS.md`. The goal is to update only what has *meaningfully* drifted since the primer was last pinned — not to rewrite it.

## Steps

### 0. Resolve the canonical project root

Run `git rev-parse --git-common-dir` and take its parent — that is the canonical repo root. All primer file operations happen at `<canonical-root>/.claude/primers/`, never at a worktree-specific path. Same pattern as the three context-log hooks (see `gotchas.md` 2026-05-11 entry).

### 1. Load the primer

Read `<canonical-root>/.claude/primers/$ARGUMENTS.md`. Extract:

- `pinned_to: <sha>` from the frontmatter
- The list of entry-point file paths
- The list of referenced functions and modules

If the file does not exist, stop and tell the user to run `/primer $ARGUMENTS` instead.

### 2. Verify the pinned SHA exists

Run `git cat-file -e <pinned_sha>^{commit}`. If the SHA is unreachable (rebased away, force-pushed branch), warn the user and ask whether to:

- Re-pin to the closest reachable ancestor, or
- Treat the primer as fully stale and regenerate from scratch (effectively `/primer`).

### 3. Diff against current HEAD

Run `git diff <pinned_sha>..HEAD -- <entry-point files>` and `git log <pinned_sha>..HEAD --oneline -- <entry-point files>`.

Classify the change volume:

- **No changes** → bump `pinned_to` to current HEAD and exit. Primer is still accurate.
- **Small changes** (renames, signature tweaks, minor additions) → patch the relevant sections only.
- **Large changes** (data flow restructured, new dependencies, removed entry points) → flag this clearly and propose either a full rewrite or splitting the primer.

### 4. Verify referenced symbols still exist

For each function, module, or path the primer names:

- Path exists: `test -e <path>`
- Function exists: `grep -rn "def <name>\|function <name>\|<name>(" <path>` (adjust syntax per language)

Anything missing goes in a `STALE:` callout you'll show the user before editing.

### 5. Patch the primer

Update only the sections that drifted. Preserve the rest verbatim — including hand-written notes and gotchas the user added (those are high signal and you did not write them).

Update the `pinned_to` SHA to `git rev-parse HEAD` after edits. Bump `last_refreshed` to today's date.

If you added new gotchas based on what you observed in the diff (e.g., "the auth check was moved out of the handler into middleware"), append them — don't overwrite existing ones.

### 6. Confirm and commit

Show the user the diff of what changed in the primer file (not the codebase). Ask whether to commit.

## Constraints

- **Never silently overwrite hand-written content.** If a section has clearly been edited by the user (style differs from agent voice, contains personal notes), patch around it.
- **Don't expand scope.** If you discover the feature now covers something it didn't before, surface that to the user — don't quietly add it.
- **Keep the primer compact.** If it grew past ~150 lines during refresh, suggest splitting.

## What this command does NOT do

- It does not edit source code.
- It does not create new primers — for that, use `/primer`.
- It does not audit other primers — for that, use `/primer-check`.

<!--
Canonical-root lineage: `git rev-parse --git-common-dir`, parallel to
`_se_repo_root` in `core-rules/hooks/lib/deps.sh`.
-->
