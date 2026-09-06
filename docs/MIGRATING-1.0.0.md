# Migrating an existing installation to Trellis 1.0.0

Pulling the source repository updates policy source and documentation. Installed commands and attached projects continue using their recorded immutable releases until you explicitly switch them.

For a new machine, start with [AGENT_SETUP.md](../AGENT_SETUP.md). This guide covers an existing installation, including an older stable launcher and linked Git worktrees. Keep the original release installed for rollback. Do not change an installed payload or move the published `v1.0.0` tag.

## Record and verify the machine state

Run these commands with your normal user account. Set the local home and fleet deliberately; the examples use the usual personal installation. Keep the output and a private backup of your local configuration, ownership records and launcher. Do not publish those records.

```bash
export TRELLIS_HOME="$HOME/.trellis"
TRELLIS="$HOME/.local/bin/trellis"
FLEET=personal
TARGET_RELEASE=1.0.0
RELEASE_REMOTE=https://github.com/Zireael26/trellis.git

"$TRELLIS" release list
"$TRELLIS" registry list --fleet "$FLEET"
"$TRELLIS" release install "$TARGET_RELEASE" --remote "$RELEASE_REMOTE"
"$TRELLIS" release verify "$TARGET_RELEASE"
```

If this exact release is already installed, omit installation and verify it. A nonzero result requires diagnosis before the next mutation. Record unavailable or detached rows without inventing paths or attaching them automatically. Private operators should select their private release remote instead.

## Update an older stable launcher

`configure` refuses to overwrite a different existing launcher. An upgrade from a release candidate can therefore install and verify 1.0.0 successfully, then stop at launcher replacement.

Before replacing the launcher, verify both the currently configured release and 1.0.0 with the existing launcher. Compare the existing launcher byte for byte with `scripts/trellis-launcher.sh` in the verified current payload. If it differs, it may be a custom launcher: stop and resolve that difference. Do not overwrite it using this recipe.

The following replacement is limited to a regular, unmodified launcher from the verified current release. It backs up those bytes, creates the new executable beside the destination, rechecks the old bytes and atomically replaces the file. Run it only after the verification commands have succeeded, while no other process is updating the launcher or configuration.

```bash
CURRENT_RELEASE="$(python3 -c 'import json,os; print(json.load(open(os.path.join(os.environ["TRELLIS_HOME"],"config.json")))["active_cli_release"])')"
"$TRELLIS" release verify "$CURRENT_RELEASE"
"$TRELLIS" release verify 1.0.0

python3 - <<'PYTHON'
from pathlib import Path
import datetime, json, os, stat, tempfile
state = Path(os.environ["TRELLIS_HOME"])
current = json.loads((state / "config.json").read_text())["active_cli_release"]
destination = Path.home() / ".local/bin/trellis"
old_template = state / "releases" / current / "payload/scripts/trellis-launcher.sh"
new_template = state / "releases/1.0.0/payload/scripts/trellis-launcher.sh"
assert stat.S_ISREG(destination.lstat().st_mode), "launcher must be a regular file"
before = destination.read_bytes()
assert before == old_template.read_bytes(), "custom or changed launcher; stop"
after = new_template.read_bytes()
if before != after:
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = destination.with_name("trellis.before-1.0.0." + stamp)
    with backup.open("xb") as stream:
        stream.write(before)
    backup.chmod(0o700)
    fd, pending = tempfile.mkstemp(prefix=".trellis-1.0.0-", dir=destination.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(after)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(pending, 0o755)
        assert stat.S_ISREG(destination.lstat().st_mode)
        assert destination.read_bytes() == before, "launcher changed during replacement"
        os.replace(pending, destination)
        print("Launcher replaced; backup:", backup)
    finally:
        if os.path.exists(pending):
            os.unlink(pending)
else:
    print("Launcher already matches 1.0.0")
PYTHON

"$TRELLIS" configure --release 1.0.0
"$TRELLIS" release verify 1.0.0
```

This selects the CLI release and refreshes the managed user surface. Project attachment releases are a separate operation. Native credentials, trust decisions and provider subscriptions still belong to each harness.

## Mixed-release worktree failures

Release candidate rc.52 accepts only `claude` and `codex` in its registry schema. Adding a Pi attachment anywhere in the same local registry causes rc.52 worktree reconciliation to reject that registry. A newly created worktree can then have tracked hook settings referring to a missing `.trellis/runtime`. Symptoms include `registry failed schema-aware validation` and hook `No such file or directory` errors.

Use the verified 1.0.0 stable launcher to migrate every affected checkout group before relying on automatic worktree attachment. Attach each affected existing worktree explicitly after upgrading its group. Do not disable the hooks or edit the registry to hide the Pi selection. Until all old registry readers have been upgraded, mixed-release automatic worktree creation can remain unavailable.

## Choose adoption or a fresh harness render

For an attachment that already has the intended harness selection and owned templates, use the release-adoption procedure in [AGENT_UPGRADE.md](../AGENT_UPGRADE.md). Adoption changes its release while retaining recorded ownership and render values.

To add Pi, or apply changed harness templates, use detach followed by attach. Calling `attach` on an already attached root is an idempotent check; it does not add a harness. Setting `harnesses` in `trellis.config.json` does not select attachment harnesses. The attachment default selects Claude Code and Codex; full three-harness support requires all three repeated flags below.

List **every registered worktree in the shared checkout** before starting. Save each root's Git status, HEAD, index and existing harness settings. Include dirty and ignored user configuration in the preservation check. Coordinate with people working in those roots; do not reset their work or close their sessions.

If a package installation restored a previously recorded Husky hook path, inspect the ownership diagnostics. The supported `trellis relink --fleet "$FLEET" "$PROJECT_ROOT"` operation can restore managed hook authority with delegation to the recorded prior hooks. Verify its result before detaching. A different or unknown hook path requires diagnosis; do not hand-edit `core.hooksPath` to bypass a refusal.

```bash
# Use an actual registered root, and record every sibling root before detaching.
PROJECT_ROOT=/absolute/path/to/project
"$TRELLIS" detach --all-worktrees "$PROJECT_ROOT"

# Repeat this complete attach command for EACH previously registered worktree.
"$TRELLIS" attach --fleet "$FLEET" --release 1.0.0 \
  --harness claude --harness codex --harness pi \
  "$PROJECT_ROOT"
```

A shared checkout needs a consistent harness selection. `detach --all-worktrees` removes the whole group's attachments; attaching only the main root leaves its siblings detached. Restore every intended registered worktree explicitly. Keep originally detached or unavailable worktrees outside the operation.

Detach and attach issue new attachment IDs. Checkout and worktree identities, prior hook delegation, user-authored settings, dirty work, staged changes and HEAD should be preserved. For a new project, use [AGENT_ONBOARD_PROJECT.md](../AGENT_ONBOARD_PROJECT.md) to create its portable manifest and attachment.

## Copied canonical agent files

A worktree prepared by copying Trellis agent files can fail attachment with `attachment destination is project-owned: .agents/agents/Explore.md`. The ownership check intentionally refuses a regular file that exactly duplicates a canonical source.

Inventory all collisions before retrying. For each untracked regular file, compare its bytes against the corresponding file in the verified target payload. Only an exact canonical copy is eligible for replacement: preserve it with its mode in a private backup outside the project, recheck it has not changed, then move it out of the attachment destination and run the normal attach command. Verify that the resulting managed symlink resolves to identical bytes. Keep authored differences, tracked files and unknown symlinks untouched and diagnose them separately. Do not copy parent agent directories into new worktrees as an attachment substitute.

## Verify the result

```bash
PROJECT_ID=your-project-id
"$TRELLIS" registry list --fleet "$FLEET"
"$TRELLIS" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"
git -C "$PROJECT_ROOT" status --short
```

Check every intended root's recorded release and harness selection, then compare the preserved work and settings with the baseline. Doctor success alone does not prove user files stayed unchanged. Re-materialize scheduled task inputs if this machine uses them, following [AGENT_UPGRADE.md](../AGENT_UPGRADE.md).

Pi installation is separate from attaching its Trellis surfaces. [AGENT_PI_SETUP.md](../AGENT_PI_SETUP.md) contains a historical version-pinned setup recipe; it is not an instruction to downgrade a working Pi installation. Use the patch and SDK qualification notes matching your installed version. The public repository supplies portable Pi policy; users supply their own provider roster and credentials.
