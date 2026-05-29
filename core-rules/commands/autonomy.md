---
description: Set the session autonomy level (1–5). Persists at <canonical-root>/.claude/session-autonomy.
argument-hint: <level 1-5>
---

# Autonomy: $ARGUMENTS

You are setting this session's autonomy level. The level controls **who answers** Trellis's interactive gates (user vs. agent). All gates and quality controls remain at every level — only consultation surface changes.

See `core-rules/autonomy.md` for the full level matrix, guardrails, and resolution algorithm.

## Steps

### 1. Validate the argument

Parse `$ARGUMENTS` as an integer. Valid range: 1–5.

- Empty / non-numeric / out-of-range → print one line to user:
  > Usage: `/autonomy N` where N is 1, 2, 3, 4, or 5.
  Then stop.

### 2. Resolve canonical root

Run `git rev-parse --git-common-dir` and take its parent. This is `<canonical-root>` — survives worktree boundaries.

### 3. Resolve preset ceiling

Read `<canonical-root>/.trellis.config.json` (preferred) or `<canonical-root>/trellis.config.json`. Parse the `.presets` array.

For each preset name in the array, read `<trellis-root>/core-rules/presets/<name>.md` and parse its YAML frontmatter. If frontmatter declares `autonomy_ceiling`, collect it. The active ceiling is the **lowest** value across all declared ceilings; if no preset declares one, ceiling is 5.

If `<trellis-root>` cannot be resolved (no Trellis config), skip ceiling resolution and assume ceiling = 5.

### 4. Clamp if needed

If requested `N` > ceiling, clamp to ceiling. Set `actual_level = min(N, ceiling)`. If clamped, surface one-line warning:

> Requested autonomy L<N>, clamped to L<ceiling> (preset `<preset-name>`).

(Name the preset whose ceiling won. If multiple, name the lowest.)

### 5. Persist the level

Write `actual_level` (as a single integer string with a trailing newline) to `<canonical-root>/.claude/session-autonomy`. Create the `.claude/` directory if needed (it almost always exists).

### 6. Acknowledge

Print exactly one line to the user with the new level and a one-line summary of what changes. Map:

- L1 Pedagogical — I will ask before every non-trivial action and explain reasoning.
- L2 Cautious — I will ask with my recommendation embedded; you answer yes/no.
- L3 Standard — current Trellis behavior; ask for non-trivial / 3+ step / architectural.
- L4 Initiative — I will batch routine questions, surface architectural decisions inline, and log decisions to `decisions-log.md`.
- L5 Autonomous — I will decide silently except for architectural decisions (surfaced inline) and the always-on guardrails; full decision log at end-of-turn.

Example output for `/autonomy 4`:
> Autonomy set to L4 (Initiative). I will batch routine questions, surface architectural decisions inline, and log decisions to `decisions-log.md`.

### 7. Verify

Confirm the file was written:

```bash
cat <canonical-root>/.claude/session-autonomy
```

Expected: a single integer followed by newline.

## What this command does NOT do

- It does not modify `trellis.config.json` (use `$EDITOR` for that).
- It does not modify presets or remove their ceilings.
- It does not edit `decisions-log.md`.
- It does not start retroactively re-deciding things from earlier in the session — it applies to subsequent turns.

## Boundaries

- **Session-scoped.** The file lives at `<canonical-root>/.claude/session-autonomy`, which is gitignored. The level persists across `/compact` and worktree boundaries within the same canonical repo, but a fresh checkout starts from the config-resolved default.
- **Clamped, not blocked.** A higher level than ceiling falls back to ceiling; the command never errors. This is intentional — friction belongs in the surfaced warning, not in command failure.
