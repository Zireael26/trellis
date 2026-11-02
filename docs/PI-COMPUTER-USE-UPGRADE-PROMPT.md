# Shareable Pi computer-use removal prompt

Pi no longer carries computer-use tools in the Trellis setup; see
[Computer use with Pi](PI-COMPUTER-USE.md). Copy the following prompt into your
local coding agent on the Mac where an earlier Trellis Pi computer-use profile
was installed.

```text
Remove Trellis's retired Pi computer-use profile from this Mac. You are
authorized to change only ~/.pi/agent/settings.json and ~/.pi/agent/mcp.json.
Back up both first and preserve every other provider, credential, package,
extension, patch, skill, MCP server and setting.

1. Run `pi list`. If it lists the local pi-mcp-adapter package at
   ~/.local/share/trellis/pi-computer-use/node_modules/pi-mcp-adapter, remove
   it with `pi remove` and that exact path.
2. Delete only the `cua` entry from mcpServers in ~/.pi/agent/mcp.json.
3. Do not touch ~/.pi/agent/skills/trellis-computer-use: it is a Trellis-owned
   link, updated by `trellis configure --release`, never by hand.
4. Do not uninstall Cua Driver, the agent-browser symlink or the tool prefix.
   List them and tell me whether anything else still uses them; I decide.
5. Start a new Pi session and confirm that no cua_*, mcp or mcpScript tool is
   offered. A session that was already running keeps its old tools until restart.

Finish with the backup paths, the exact changes made, and the new tool list.
For computer-use work from now on, use Codex CLI as an hc sub-agent
(`hc run --bg --name <name> --cwd <dir> codex --no-daemon --search "<task>"`) or Claude Code.
```
