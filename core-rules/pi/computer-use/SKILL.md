---
name: trellis-computer-use
description: Use Pi to operate browser pages or native desktop apps, preferring a dedicated headless browser for web tasks and Cua Driver for desktop UI.
---

# Computer use in Pi

Use an available app API or CLI when it fits the task. For browser pages use
`$HOME/.local/bin/agent-browser`; for native UI use the `cua_*` tools or discover
Cua tools through `mcp`. This profile is installed separately from Trellis attachment.

## Browser pages

Use a unique `--session` name for the task. The default browser is headless and
separate from the person's browser. Keep that session name on every command:

```bash
"$HOME/.local/bin/agent-browser" --session task-name open https://example.com
"$HOME/.local/bin/agent-browser" --session task-name snapshot -i
# Use the returned refs for fill/click, then take a fresh snapshot.
"$HOME/.local/bin/agent-browser" --session task-name screenshot /tmp/task-name.png
```

Read the screenshot with Pi's `read` tool when visual verification matters.
Use `--profile` with a dedicated task profile when login persistence is needed;
do not copy a personal Chrome profile. `--headed` or attaching to an existing
browser changes the interaction model: use it only when the task requires it.
Close only the task's session when done with `--session task-name close`.

## Native desktop apps

1. Find the exact app and window with `cua_list_apps` and `cua_list_windows`.
2. Observe that `(pid, window_id)` with `cua_get_window_state`. Ground actions
   in both the screenshot and structured elements; bound large trees with
   `max_elements`. A screenshot alone does not prove input is available.
3. Prefer `element_token` from the current snapshot. Tokens and indices expire
   after a newer snapshot. Use one stable `session` label throughout the task.
4. Use `delivery_mode: "background"` on input calls. Check the reported route
   and verify the actual UI change with a fresh snapshot. A dispatched event
   is not proof that the application accepted the action.
5. If background input is refused, report the app/window limitation. Use
   foreground delivery only when interrupting the desktop is authorized for
   that task; background-only requests must stop instead of escalating.

macOS windows on another Space can expose a screenshot but no actionable AX
tree. Do not guess snapshot IDs, borrow another window's elements, or replay an
ambiguous click. If tokens are absent despite a populated tree, check the
version-pinned adapter patch rather than switching to ungrounded input.

Use the dedicated browser for web work. Cua's browser attachment and trusted
background-click support vary by platform; do not change its daemon grants to
work around a refusal. This setup is background-first, not a desktop sandbox or
a guarantee that every app supports background input.
