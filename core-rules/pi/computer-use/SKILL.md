---
name: trellis-computer-use
description: Pi has no computer-use tools. Use when a task needs a browser page or a native desktop app operated; route that unit to Codex CLI in a Herdr pane or to Claude Code.
---

# Computer use from Pi

Pi carries no computer-use or browser-driving tools in the Trellis setup. Do not
install a tool server to get them. Prefer an app API or CLI when one fits;
otherwise hand the unit to a harness that has computer use:

- **Codex CLI in Herdr**, in a visible pane:
  `herdr agent start <name> --kind codex --pane <id> -- --search`.
  Codex CLI's startup hooks-review screen blocks the session until dismissed,
  and a prompt sent before that is lost.
- **Claude Code**, with its own computer-use and browser tools.

Give the receiving agent a self-contained brief: the goal, the app or URL, what
counts as done, and what it must not touch. Treat its report as a claim and
verify the visible result yourself.
