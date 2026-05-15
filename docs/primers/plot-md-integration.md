# plot.md integration (forward-looking)

> **Status:** v1 of the primer system does **not** consume `active_primers`. The default loading policy is agent-decides — the agent reads `INDEX.md` at session start and judges relevance from the task description. This doc captures the design for a future enhancement where users can pin a primer list in `plot.md` for automatic load. No managed project today carries `plot.md`; bootstrap with the primer INDEX only.

Trellis supports two `plot.md` scopes when projects adopt them:

- **Global plot.md** — at the Trellis instance root, declares the active project and global state
- **Local plot.md** — inside each managed project, declares the current focus area within that project

Primers would integrate at the **local** level. The global plot.md does not know which primers exist (that's per-project), so it shouldn't reference them directly.

---

## Local plot.md: `active_primers` field

Add an optional `active_primers` list to the frontmatter or a designated section of a managed project's `plot.md`:

### Frontmatter style (recommended)

```markdown
---
focus: marketing-chatbot end-to-end testing
active_primers:
  - marketing-chatbot-core
  - marketing-chatbot-telegram-adapter
  - persona-system
since: 2026-05-12
---

# What I'm working on

Testing the marketing chatbot end-to-end via Telegram on local. Goal is to validate the persona pipeline and dispatch logic against real user messages before moving to staging.
```

### Body-section style (alternative)

If a `plot.md` doesn't use frontmatter:

```markdown
# What I'm working on

Testing the marketing chatbot end-to-end via Telegram on local.

**Active primers:**
- marketing-chatbot-core
- marketing-chatbot-telegram-adapter
- persona-system
```

Either format works — the agent looks for `active_primers` in both places.

---

## Session-start behavior (future)

When an agent starts a session in a Trellis-managed project that adopts plot.md:

1. Read local `plot.md` (Trellis already does this).
2. If `active_primers` is present, **load those primers immediately** without consulting INDEX. They are user-curated as relevant to current focus, so trust the curation.
3. If `active_primers` is absent or empty, fall back to INDEX-based discovery: read `.claude/primers/INDEX.md`, then decide what to load based on the user's task.

This gives users a one-line way to pin context for the focus area without having to mention primers in every prompt.

---

## What `active_primers` is NOT

- **Not a list of every primer that exists.** That's INDEX. `active_primers` is the subset relevant to *current focus*.
- **Not enforced.** If the user adds a primer slug that doesn't exist, the agent reports the miss and continues with what does exist.
- **Not auto-managed.** The user updates this when focus shifts. The agent can *suggest* additions ("we just touched X, want me to add `x-primer` to active_primers?") but doesn't modify plot.md silently.

---

## Updating `active_primers`

Two ways:

- **Manual** — user edits plot.md.
- **Agent-proposed** — at end of a session that touched a feature with a primer, agent suggests adding it to `active_primers` if it isn't already there. User accepts or skips.

The Trellis handoff system (`context-log.md`) can record the active primer set used in a session in its frontmatter — useful when resuming work after a context break. See `docs/primers/handoff-integration.md`.

---

## Edge cases

**Switching focus areas.** When the user changes focus, they update `active_primers`. The agent loading the new set should *unload* (i.e., not re-reference) primers that fell off the list — they're no longer presumed relevant.

**Stale entries.** If `active_primers` lists a primer that has since been deleted, surface it at session start: "plot.md references `foo-primer` but `.claude/primers/foo-primer.md` doesn't exist. Remove from plot.md?"

**Primer drift between sessions.** If a primer in `active_primers` has stale entry points (caught at load time), the agent should flag and ask whether to `/primer-refresh` before continuing — *don't* silently use stale info.
