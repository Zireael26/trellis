# Shareable Pi computer-use upgrade prompt

Copy the following prompt into your local coding agent on the Mac you use for Pi.
Stay available for the macOS permission dialogs and any login you choose to use.

```text
Set up Trellis's optional Pi computer-use profile on this Mac and verify it
through actual Pi tool calls. You are authorized to install the required tools
and make the scoped configuration changes. Preserve my existing Pi providers,
credentials, packages, extensions, patches, skills, and unrelated MCP servers.
Back up affected configuration and any existing CuaDriver app before changes.

Use the public Trellis v1.1.0 release:
https://github.com/Zireael26/trellis/releases/tag/v1.1.0
Read its docs/PI-COMPUTER-USE.md and follow the ordered install, verification,
and rollback instructions. Fetch the tagged source into a separate checkout;
do not change a dirty working tree or silently use a newer moving branch.
The base AGENT_PI_SETUP.md recipe is older: do not replay its replacements.
This request installs the optional user tools; do not adopt a release across
my project fleet or publish repository changes as a side effect.

Inspect versions first. The qualified combination is Pi 0.85.1, Node 24,
pi-mcp-adapter 2.32.1 with Trellis's guarded structured-content patch,
Cua Driver 0.23.2, and agent-browser 0.36.0. Keep the added npm tools in the
separate prefix specified by the guide. Do not reinstall Pi's existing add-ons.
If Pi needs an upgrade, preserve its existing configuration and reapply the
matching compaction patch. If I have a newer or otherwise unqualified version,
explain the mismatch before changing it; do not silently downgrade or claim
compatibility. Reuse matching existing files and inspect customized ones.

Use headless agent-browser for web tasks with its separately installed browser.
Use app-owned Cua Driver in standard mode for native apps. Set up its reviewed
login LaunchAgent with --no-overlay; the overlay has a known multi-monitor
rendering problem. Do not attach or copy my personal browser profile.

Guide me through macOS permissions at the correct point. Start the installed
/Applications/CuaDriver.app daemon first, inspect permissions, and run
cua-driver permissions grant if either is missing. Tell me exactly to open
System Settings > Privacy & Security > Accessibility and enable CuaDriver,
then Screen & System Audio Recording (or Screen Recording) and enable it there.
The permission owner must be CuaDriver, bundle ID com.trycua.driver, rather than
my terminal. I will enter any macOS password locally and approve the dialogs
myself. Accepting these requires my action: wait for me to finish, do not infer
approval from elapsed time. Explain any extra screen-capture consent dialog or
Quit & Reopen request. Then fully restart the daemon using the guide's method
for its current launch mode, check both permissions, and prove live capture.
Do not request passwords in chat or reset the machine's permission database.

Merge the Pi MCP configuration, install the computer-use skill, and restart Pi.
Use an image-capable model already available to me. Verify native screenshots
are actual image blocks and structured snapshot IDs/element tokens survive.
Test an explicit background action in a disposable native window on the current
Space with fresh tokens, read the changed UI and screenshot, and compare the
frontmost app before and after. You may open and initialize that disposable
window for this test; keep the tested action itself in background mode.
Do not call a successful tool response alone proof of a successful action.
If an app or off-Space window refuses background input, report that limit.

Also have Pi open a disposable local form in a unique headless browser session,
fill and submit it, read the confirmation, save and inspect the screenshot,
and close only that session. If a later task needs authentication, guide me
through login in a separate dedicated profile; do not copy personal sessions.
Clean up only test resources you created and retain the intended Cua daemon.

Finish with installed versions, changed configuration paths, backup locations,
native and browser test evidence, any limitations, and precise rollback steps.
Do not report completion while required macOS grants or live tests are missing.
```
