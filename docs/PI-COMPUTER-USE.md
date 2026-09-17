# Computer use with Pi

This opt-in profile gives Pi a dedicated headless browser for web tasks and Cua
Driver for native desktop apps. It does not change Trellis attachment defaults,
provider credentials, or a project's MCP configuration.

Qualified on 2026-09-07: Pi **0.85.1**, Node **24**, `pi-mcp-adapter`
**2.32.1** with the patch below, Cua Driver **0.23.2**, and `agent-browser`
**0.36.0** on macOS. The older base recipe in `AGENT_PI_SETUP.md` is separately
pinned to Pi 0.84.4; do not replay its package/settings replacement steps over
an existing newer installation.

## 1. Preflight and install the separate tool directory

Run the command blocks in order in one Bash shell, stopping at the first error.
Run from the Trellis checkout. Existing Pi 0.85.1 users do not need a Pi upgrade.
If upgrading an older Pi, install `@earendil-works/pi-coding-agent@0.85.1`
explicitly and reapply its matching compaction patch before continuing. Never
update Pi implicitly while installing this profile.

```bash
set -euo pipefail
export TRELLIS_REPO_ROOT="$(git rev-parse --show-toplevel)"
export PI_CUA_PREFIX="$HOME/.local/share/trellis/pi-computer-use"
test "$(pi --version)" = "0.85.1"
node -e 'if (Number(process.versions.node.split(".")[0]) < 24) process.exit(1)'
mkdir -p "$PI_CUA_PREFIX"
npm install --prefix "$PI_CUA_PREFIX" --save-exact --legacy-peer-deps \
  --ignore-scripts pi-mcp-adapter@2.32.1 agent-browser@0.36.0
python3 "$TRELLIS_REPO_ROOT/core-rules/pi/patches/apply-pi-mcp-adapter-patch.py" \
  "$PI_CUA_PREFIX/node_modules/pi-mcp-adapter"
PI_MCP_ADAPTER_ROOT="$PI_CUA_PREFIX/node_modules/pi-mcp-adapter" \
  node --test "$TRELLIS_REPO_ROOT/core-rules/pi/patches/tests/pi-mcp-structured-content.mjs"
"$PI_CUA_PREFIX/node_modules/.bin/agent-browser" install
```

The separate prefix avoids reinstalling Pi's existing patched add-ons.
`--legacy-peer-deps` is deliberate: Pi supplies its own extension APIs, while
the adapter declares the older optional `pi-ai ^0.84.1` peer. Live qualification
is against Pi 0.85.1; the peer range alone is not compatibility evidence.
`--ignore-scripts` is supported by these qualified packages: the browser CLI's
platform binaries ship in its tarball, and browser installation is explicit.

Keep the generated `package-lock.json`. For a reinstall, run
`npm ci --prefix "$PI_CUA_PREFIX" --legacy-peer-deps --ignore-scripts`, then
reapply the adapter patch. The installer accepts only the exact package version
and source digest, verifies the replacement before installing it, and is
idempotent. Package updates need a fresh qualification.

The patch preserves `structuredContent` alongside text and native image blocks.
Without it, Cua's snapshot handles, active-app flags, and browser capabilities
can disappear from Pi's model-visible result even though a screenshot works.
The structured payload is placed first; the adapter's existing text-output
limits still apply. Bound large accessibility snapshots rather than relying on
unbounded tree output.

## 2. Install or update Cua Driver

On an existing installation, check its version and back up the app bundle before
updating. This profile was tested with the stable release below, not nightly:

```bash
CUA_DRIVER_RS_VERSION=0.23.2 /bin/bash -c \
  "$(curl -fsSL https://cua.ai/driver/install.sh)"
test "$("$HOME/.local/bin/cua-driver" --version)" = "cua-driver 0.23.2"
open -n -g -a CuaDriver --args serve --permission-mode standard --no-overlay
"$HOME/.local/bin/cua-driver" status
"$HOME/.local/bin/cua-driver" permissions status --json
```

Wait for daemon startup before checking permissions. If either grant is missing,
run `"$HOME/.local/bin/cua-driver" permissions grant` from the user's terminal.
This requests the app-owned permissions; it cannot approve them for the user.
Hand these steps to the person at the Mac:

1. Open **System Settings → Privacy & Security → Accessibility** and enable
   **CuaDriver** (`/Applications/CuaDriver.app`, identity `com.trycua.driver`).
2. In **Privacy & Security → Screen & System Audio Recording** (called
   **Screen Recording** on some macOS versions), enable **CuaDriver** too.
3. Complete any macOS authentication locally. Accept **Quit & Reopen** if offered,
   and respond to any further screen-capture consent dialog. Never send the
   account password to the agent or chat.
4. Tell the agent when finished. The agent must fully restart the app daemon,
   recheck both grants, and obtain a real screenshot through Pi in step 4.

If CuaDriver is absent from a list, confirm that the signed app is installed and
running, then request permissions again; use the Settings add-app control where
available. A managed Mac may require its administrator to permit the change.
Do not reset the machine's permission database as a routine troubleshooting step.
Do not grant permissions to a terminal in place of the app. A read-only status
check or MCP call does not raise the approval UI, and `unknown` while the daemon
is stopped is not a passing result. These steps follow the
[Cua first-app guide](https://cua.ai/docs/tutorials/drive-your-first-app).

Before LaunchAgent registration, restart with `cua-driver stop` followed by the
`open -n -g -a CuaDriver ...` command above. After registration, use
`launchctl kickstart -k "gui/$(id -u)/com.trycua.cua-driver"` instead, avoiding a
second daemon. A passing status check alone does not prove live capture works.

`standard` permits desktop interaction but does not pre-authorize attaching a
personal authenticated Chromium profile. Use the separate browser below for
web work. This is not an app sandbox; users needing app/origin restrictions
should use Cua's reviewed bounded capability manifests.

For login persistence, create `~/Library/LaunchAgents/com.trycua.cua-driver.plist`
with the following values (review an existing entry instead of overwriting it):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.trycua.cua-driver</string>
  <key>ProgramArguments</key><array>
    <string>/Applications/CuaDriver.app/Contents/MacOS/cua-driver</string>
    <string>serve</string><string>--permission-mode</string><string>standard</string>
    <string>--no-overlay</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
</dict></plist>
```

At an attended boundary with no active Cua tasks, stop the manually started
daemon and register the LaunchAgent:

```bash
plutil -lint "$HOME/Library/LaunchAgents/com.trycua.cua-driver.plist"
"$HOME/.local/bin/cua-driver" stop
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.trycua.cua-driver.plist"
launchctl print "gui/$(id -u)/com.trycua.cua-driver"
"$HOME/.local/bin/cua-driver" permissions status --json
```

The overlay is disabled because qualification found a multi-monitor rendering
defect: the visible cursor appeared on the other display while accessibility
clicks reached the correct button. It is a visual indicator, not the actual
system pointer or proof of input delivery. To enable it, remove `--no-overlay`
from the plist and reload the LaunchAgent at an attended boundary. This profile
does not patch the Cua binary or claim the rendering defect is fixed.

## 3. Register Pi without replacing existing settings

```bash
pi install "$PI_CUA_PREFIX/node_modules/pi-mcp-adapter"
mkdir -p "$HOME/.local/bin"
test ! -e "$HOME/.local/bin/agent-browser"
test ! -L "$HOME/.local/bin/agent-browser"
ln -s "$PI_CUA_PREFIX/node_modules/.bin/agent-browser" "$HOME/.local/bin/agent-browser"
test -L "$HOME/.pi/agent/skills/trellis-computer-use"
```

If the browser command already exists, inspect its target and version; retain a
matching installation instead of replacing it. The `trellis-computer-use` skill
arrives as a Trellis-managed link from the active release — `trellis attach
--user` creates it — and the `test -L` above fails closed while the user surface
is not attached. Never copy `SKILL.md` by hand: a real directory at that path
is an ownership conflict that blocks `attach --user`. If a hand-placed copy is
in the way, run `trellis attach --user --adopt-identical` when its bytes match
the release, otherwise remove the copy by hand and run `trellis attach --user`.

Merge this server into `~/.pi/agent/mcp.json`, preserving other servers/settings.
Replace `ABSOLUTE_CUA_DRIVER_PATH` with the absolute value of
`$HOME/.local/bin/cua-driver`; JSON does not expand shell variables.

```json
{
  "settings": { "hostConfigDiscovery": "off" },
  "mcpServers": {
    "cua": {
      "command": "ABSOLUTE_CUA_DRIVER_PATH",
      "args": ["mcp"],
      "lifecycle": "lazy-keep-alive",
      "directTools": ["list_apps", "list_windows", "get_window_state", "click", "type_text", "press_key", "scroll", "launch_app"],
      "includeTools": ["list_apps", "list_windows", "get_window_state", "click", "double_click", "type_text", "press_key", "scroll", "drag", "launch_app", "bring_to_front", "get_cursor_position", "check_permissions", "get_config", "start_session", "end_session", "get_session"]
    }
  }
}
```

Restart Pi and use `/mcp` to inspect the connection. The first call connects the
lazy server; it stays connected for the session so snapshot handles survive.
The included direct tools appear as `cua_*`; other included tools are available
through `mcp`. The adapter can emit harmless unknown `uint32`/`uint64` schema
format warnings with this driver version; errors or missing tools are not a
passing setup. Use an image-capable model (`pi --list-models` shows an `images`
column). No particular provider account is required by this profile.

## 4. Verify through the actual Pi session

For native apps, use a disposable window on the current desktop Space. Ask Pi
to observe a control, act in explicit background mode, then read the changed UI
and screenshot. Require current element tokens, an observed postcondition, and
the action route. Compare the frontmost application before and after. A human
may move their own cursor while the test runs; changed cursor coordinates alone
cannot establish whether the agent moved it.

For the browser, ask Pi to open a disposable local form using a unique
`agent-browser --session` name, fill and submit it, read the resulting text,
save a screenshot and read that image. Close only that session. Use the default
headless mode. For durable login state, select a separate `--profile` directory
and authenticate there; no personal browser profile is copied or attached.

Qualification evidence: Pi delivered native screenshot image blocks and used
fresh-token `AXPress` background actions to change a disposable AppKit counter
from 0 to 1 to 2 while Ghostty remained the frontmost application at the before
and after checks. This does not establish that every macOS app works off-Space.
Calculator on another Space was observation-only and correctly refused input.
Cua's isolated Chrome launch also refused the host's browser, so this profile
uses agent-browser's separately installed headless Chromium for web work.
The headless Pi test filled a local form, clicked its submit control, observed
the resulting confirmation, saved and read the screenshot, and closed only its
named session. The displayed confirmation and image were independently checked.

## Rollback

Remove only this profile's local package entry with
`pi remove "$PI_CUA_PREFIX/node_modules/pi-mcp-adapter"`, remove its `cua` server
entry and the `trellis-computer-use` skill link, and restart Pi. Preserve other packages, servers, and
customizations. Close this profile's browser sessions before removing its CLI
symlink or tool directory. To disable daemon autostart, use
`launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.trycua.cua-driver.plist"`.
Keep the tool lockfile, original Cua bundle and configuration backups until
verification passes. Trellis release adoption does not upgrade these user tools.

References: [Cua background contract](https://cua.ai/docs/concepts/the-no-foreground-contract),
[Cua daemon setup](https://cua.ai/docs/how-to-guides/driver/keep-running),
[Pi MCP adapter](https://github.com/nicobailon/pi-mcp-adapter),
[agent-browser](https://github.com/vercel-labs/agent-browser).
