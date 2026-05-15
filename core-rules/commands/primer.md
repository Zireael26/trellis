---
description: Create a feature primer that captures load-bearing context for future sessions
argument-hint: <feature-slug>
---

# Create primer: $ARGUMENTS

You are creating a primer for the feature/subsystem named `$ARGUMENTS` in this Trellis-managed project.

A **primer** is a compact, hand-validated context document that lets future sessions understand this feature without broad codebase exploration. Primers describe *shape* (entry points, data flow, gotchas) — not implementation details. They are pinned to a commit SHA so staleness is detectable.

## Steps

### 0. Resolve the canonical project root

Run `git rev-parse --git-common-dir` and take its parent — that is the canonical repo root. All primer file operations happen at `<canonical-root>/.claude/primers/`, never at a worktree-specific path. This is the same load-bearing pattern used by the three context-log hooks (see `gotchas.md` 2026-05-11 entry on canonical-root resolution).

If `<canonical-root>/.claude/primers/INDEX.md` does not exist, stop and tell the user that this project has not been bootstrapped for primers yet. They should re-run `scripts/onboard-project.sh <project>` from the Trellis instance to seed the INDEX file.

### 1. Locate the feature

Identify which code belongs to `$ARGUMENTS`. Start from these signals:

- Plan documents under `docs/plans/` referencing this feature
- Directory names, module names, or file prefixes matching the slug
- `git log --all --oneline | grep -i <feature>` for recent commits

If the feature is ambiguous or spans many unrelated areas, ask the user to narrow scope before continuing.

### 2. Investigate (be targeted, not exhaustive)

You are writing the primer so future agents *don't* have to explore broadly. Spend your exploration budget here once.

For each section of the template, gather:

- **Purpose** — 1–2 sentences. What does this feature do? Why does it exist?
- **Entry points** — 3–5 key file paths where the feature starts. Where would a debugger set its first breakpoint?
- **Data flow** — Where does a request/event enter, what does it touch, where does it exit? Name files and functions, not lines.
- **Dependencies** — Other features, services, or primers this touches. Reference related primers by slug.
- **Test commands** — Exact commands to exercise the feature (make targets, pytest invocations, curl examples).
- **Gotchas** — Non-obvious things that bit during implementation. Configuration traps, ordering requirements, environment quirks. This section earns its keep over time.
- **Out of scope** — What this primer deliberately does *not* cover (sibling features, future work).

### 3. Pin to current commit

Run `git rev-parse HEAD` in the project root. Capture the SHA — this is the primer's `pinned_to` field. It anchors freshness checks later.

### 4. Write the primer

Copy the framework default template from `$TRELLIS_ROOT/core-rules/commands/templates/primer-template.md` (or the project-local override at `<canonical-root>/.claude/primers/templates/primer-template.md` if present) to `<canonical-root>/.claude/primers/$ARGUMENTS.md` and fill in every section.

Constraints:

- Keep the primer under 150 lines. If you exceed that, you are describing details, not shape — cut.
- Use file paths relative to the project root.
- Reference functions by name, not by line number (line numbers drift; names rarely do).
- If the feature is large, split into multiple primers (e.g., `marketing-chatbot-core`, `marketing-chatbot-telegram-adapter`) and cross-reference them in the dependencies section.

### 5. Update the index

Append a single line to `<canonical-root>/.claude/primers/INDEX.md`:

```
- [$ARGUMENTS](./$ARGUMENTS.md) — <one-line description of the feature>
```

Sort the index alphabetically by slug. INDEX is small and always loaded at session start — keep entries to one line each.

### 6. Confirm with the user

Show the primer contents (or a tight summary) and ask:

1. Does the purpose and scope match what you intended?
2. Are there any gotchas you remember from implementation that I missed?
3. Should I commit this now, or do you want to edit first?

Do not commit without explicit user approval.

## What this command does NOT do

- It does not modify any source code.
- It does not run tests or start services.
- It does not update existing primers — for that, use `/primer-refresh`.

If a primer already exists at `<canonical-root>/.claude/primers/$ARGUMENTS.md`, stop and tell the user to run `/primer-refresh $ARGUMENTS` instead.

<!--
Canonical-root lineage: this command uses `git rev-parse --git-common-dir` to
resolve the project root, matching the helper `_se_repo_root` in
`core-rules/hooks/lib/deps.sh` that the three context-log hooks rely on. See
the 2026-05-11 gotchas entry for the load-bearing rationale.
-->
