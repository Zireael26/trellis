# Computer use with Pi

Pi no longer carries computer-use tools in the Trellis setup. The earlier opt-in
profile (an MCP adapter package, a `cua` server in `~/.pi/agent/mcp.json`, Cua
Driver and a headless browser CLI) is retired: its tool schemas cost every Pi
session context whether or not the task used them. `AGENT_PI_SETUP.md` installs
none of it, and Trellis no longer ships the adapter patch.

## Where computer use runs instead

Route a unit that needs a browser page or a native desktop app to a harness that
has computer use:

- **Codex CLI in Herdr**, in a visible pane:
  `herdr agent start <name> --kind codex --pane <id> -- --search`.
- **Claude Code**, with its own computer-use and browser tools.

The `trellis-computer-use` skill still links into `~/.pi/agent/skills` from the
active release. From this release on, it holds only that routing rule, so a Pi
agent that meets a computer-use task hands it off instead of looking for tools.

## Removing the old profile from an existing install

Back up `~/.pi/agent/settings.json` and `~/.pi/agent/mcp.json` first, then:

```bash
pi remove "$HOME/.local/share/trellis/pi-computer-use/node_modules/pi-mcp-adapter"
jq 'del(.mcpServers.cua)' "$HOME/.pi/agent/mcp.json" > "$HOME/.pi/agent/mcp.json.tmp" &&
  mv "$HOME/.pi/agent/mcp.json.tmp" "$HOME/.pi/agent/mcp.json"
```

Preserve every other package, server and setting. Restart Pi at an attended
boundary: a running session keeps the tools it started with. The separate tool
prefix (`~/.local/share/trellis/pi-computer-use`), the `agent-browser` symlink and
Cua Driver are no longer used by Pi; remove them only if nothing else on the
machine uses them.

Do not delete or replace `~/.pi/agent/skills/trellis-computer-use` by hand. It is
a Trellis-owned link, and a hand edit blocks `detach --user` and `relink --user`.
`trellis configure --release <version>` relinks the user surface to the new
release, which replaces the old skill text with the routing rule.
