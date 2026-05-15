# Integration with the Trellis context-log (handoff) system

The context-log system and the primer system both persist context across sessions, but they answer different questions:

- **context-log.md** — "What was I doing? Where did I leave off?" — session-scoped, time-ordered, hook-maintained, auto-injected at session start.
- **Primers** — "What is this feature?" — feature-scoped, stable across sessions, hand-curated, mutable only on `/primer-refresh`.

They share storage conventions (canonical-root resolution) and session-start wiring. This file specifies how they fit together.

---

## Storage layout (per managed project)

```
<canonical-root>/                    (resolved via git rev-parse --git-common-dir)
├── context-log.md                   (hook-maintained; never edit by hand)
├── gotchas.md                       (hand-edited)
└── .claude/
    └── primers/
        ├── INDEX.md                 (one line per primer; loaded at session start)
        ├── <feature-slug>.md        (one file per primer)
        └── templates/               (optional: project-local template override)
            └── primer-template.md
```

Codex-enabled projects get a parallel `.agents/primers/INDEX.md` mirror (symlink target rules same as `.agents/skills/` parity).

A managed project gets primers infrastructure once via `scripts/onboard-project.sh`. Both subsystems write into the same canonical root, so worktree sessions see the same handoff and the same primer set as the main checkout.

---

## Session-start ordering

When an agent starts a session in a managed project that has primers bootstrapped, load context in this order:

1. **Auto-injected `context-log.md`** — the `session-context` hook injects the previous session's snapshot before your first turn. Treat as authoritative for "what was I in the middle of".
2. **Read local `plot.md`** if present. Identifies current focus and (future) `active_primers`.
3. **Read `.claude/primers/INDEX.md`** at the canonical root. Pick primers relevant to the task.
4. **Load relevant primers.** Cheap to read; bias toward loading more than fewer.

Order matters: the handoff says *where you left off*, primers say *what the thing is*. Reading handoff first means primer loads are informed by recent context.

---

## Handoffs can reference primers

When the `save-context-log` hook writes a handoff, the agent can record which primers it relied on during the session by including a `primers_used:` field in the log frontmatter (or a body section if the log format isn't frontmatter-based at the time of writing):

```markdown
primers_used:
  - marketing-chatbot-core
  - marketing-chatbot-telegram-adapter
  - persona-system
```

The next session's agent, on reading the auto-injected log, knows immediately which primers to reload — no INDEX scan needed.

This is forward-looking — the `save-context-log` hook does not write this field today. Hand-add it if useful, or extend the hook later.

---

## What about primers referencing handoffs?

**Generally no.** Primers describe stable shape; handoffs describe ephemeral session state. A primer referencing a specific handoff would couple a long-lived document to a short-lived one and create staleness.

The only valid case: a primer's `Gotchas` section can reference a *handoff date* if a particular session uncovered a non-obvious thing worth preserving. Even then, prefer to write the gotcha directly into the primer rather than linking out.

---

## Shared infrastructure to reuse

Primer commands reuse the same canonical-root pattern the three context-log hooks rely on:

- **Canonical-root resolution.** Primers respect `git rev-parse --git-common-dir` the same way `context-log.md` does, so worktrees see the same `.claude/primers/` directory.
  > Helper: `_se_repo_root` at `core-rules/hooks/lib/deps.sh:38-61`. The three context-log hooks (`save-context-log.sh`, `session-context.sh`, `post-compact-context.sh` on both Claude and Codex) source this. Primer commands invoke `git rev-parse --git-common-dir` directly in their instructions (they are markdown documents the agent reads, not shell scripts that source `lib/deps.sh`).
  > See `gotchas.md` 2026-05-11 entry — "Canonical-root resolution for context-log/gotchas hooks". Same load-bearing rationale.
- **Hooks.** Primers do **not** add new hooks in v1. The three context-log hooks are off-limits per the 2026-05-11 gotchas entry — primer commands explicitly avoid touching them. A future enhancement may add a post-commit hook that warns when entry-point files changed without a `/primer-refresh`; if so, it ships as a fourth hook, not a modification of the existing three.
- **Branch/worktree behavior.** Handoffs are content that gets snapshotted per session but lives at the canonical root. Primers are *not* per-session — they describe the feature regardless of which branch is checked out. Both live at the canonical root for the same reason.

---

## Gotchas

- **Do not let primer creation block on handoff completion.** They are independent. A user should be able to `/primer foo` mid-session without writing a handoff.
- **Do not write primers into context-log format.** A handoff is dated and session-specific. A primer has no date in its filename — it's named by slug.
- **The three context-log hooks are off-limits** (per `gotchas.md` 2026-05-11). Primers should not touch them. If primer creation needs hooks in the future, add new ones rather than reusing.
- **Branch-switching mid-session.** If the user switches branches while a primer is loaded, the primer's referenced files may not exist on the new branch. The agent should re-verify entry points on detected branch change.
