#!/usr/bin/env bash
# Inspect companion plugin GUI node resolution and Codex SessionEnd compatibility.
# Default is read-only. --repair explicitly repairs supported drift; it never
# replaces an operator-owned regular node file.
# Usage: check-codex-plugin-surface.sh [--quiet] [--repair]
# Exit: 0 healthy or not installed; 1 drift/error; 64 invalid arguments.
set -euo pipefail
exec python3 - "$@" <<'PY'
import glob
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile

args = sys.argv[1:]
if any(arg not in {"--quiet", "--repair"} for arg in args):
    print("usage: check-codex-plugin-surface.sh [--quiet] [--repair]", file=sys.stderr)
    sys.exit(64)
repair = "--repair" in args
quiet = "--quiet" in args
drift = False


def report(message, problem=False):
    global drift
    if problem:
        drift = True
    if problem or not quiet:
        print(message)


home = Path.home()
plugin_files = []
for harness in (".claude", ".codex"):
    base = home / harness / "plugins"
    patterns = [
        str(base / "marketplaces/openai-codex/plugins/codex/hooks/hooks.json"),
        str(base / "cache/openai-codex/codex/*/hooks/hooks.json"),
    ]
    for pattern in patterns:
        plugin_files.extend((Path(path), harness == ".codex") for path in sorted(glob.glob(pattern)))

if not plugin_files:
    report("codex-plugin-surface: not installed (no companion hook manifests found)")
    sys.exit(0)

prefix = 'PATH="$HOME/.local/bin:$PATH" node '
needs_node = False
for path, is_codex in plugin_files:
    try:
        document = json.loads(path.read_text())
        hooks = document["hooks"]
        if not isinstance(hooks, dict):
            raise ValueError("hooks must be an object")
        changes = []
        for event, groups in hooks.items():
            if not isinstance(groups, list):
                raise ValueError("event entries must be arrays")
            for group in groups:
                for hook in group["hooks"]:
                    if hook.get("type") != "command":
                        continue
                    command = hook.get("command", "")
                    if not isinstance(command, str):
                        raise ValueError("command must be a string")
                    if re.match(r"^\s*node\s+", command):
                        needs_node = True
                        hook["command"] = re.sub(r"^\s*node\s+", lambda _: prefix, command, count=1)
                        changes.append("node PATH prefix")
                    elif command.startswith(prefix):
                        needs_node = True
                    timeout = hook.get("timeout")
                    if is_codex and event == "SessionEnd" and isinstance(timeout, (int, float)) and timeout > 3:
                        hook["timeout"] = 3
                        changes.append("SessionEnd timeout capped at 3s")
        if changes and repair:
            # Preserve the installed file's mode and replace atomically. Resolve
            # manifest symlinks so repair does not replace the link itself.
            target = path.resolve(strict=True)
            fd, staged = tempfile.mkstemp(prefix=".hooks-", dir=target.parent)
            try:
                with os.fdopen(fd, "w") as output:
                    json.dump(document, output, indent=2)
                    output.write("\n")
                    os.fchmod(output.fileno(), stat.S_IMODE(target.stat().st_mode))
                os.replace(staged, target)
            finally:
                if os.path.exists(staged):
                    os.unlink(staged)
            report(f"hooks.json: repaired {', '.join(sorted(set(changes)))} in {path}")
        elif changes:
            report(f"hooks.json: drift ({', '.join(sorted(set(changes)))}) in {path}; run with --repair", True)
        else:
            report(f"hooks.json: OK {path}")
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        report(f"hooks.json: cannot inspect/repair {path}: {exc}", True)

if needs_node:
    shim = home / ".local/bin/node"
    # Exclude the shim directory even with trailing slashes or relative aliases.
    search_path = os.pathsep.join(
        entry for entry in os.environ.get("PATH", "").split(os.pathsep)
        if Path(entry or ".").resolve() != shim.parent.resolve()
    )
    real_node = shutil.which("node", path=search_path)
    if shim.exists() and not shim.is_symlink():
        report("node shim: operator-owned regular file/directory; refusing to replace ~/.local/bin/node", True)
    elif shim.is_symlink() and shim.is_file() and os.access(shim, os.X_OK):
        # An existing executable pin is authoritative. PATH may intentionally
        # select a different Node version for interactive shells.
        report(f"node shim: OK ({os.readlink(shim)})")
    elif not real_node:
        report("node shim: no node outside ~/.local/bin on PATH; cannot maintain shim", True)
    elif repair:
        try:
            shim.parent.mkdir(parents=True, exist_ok=True)
            if shim.is_symlink():
                shim.unlink()
            shim.symlink_to(real_node)
            report(f"node shim: refreshed ~/.local/bin/node -> {real_node}")
        except OSError as exc:
            report(f"node shim: cannot repair: {exc}", True)
    else:
        report("node shim: missing/stale ~/.local/bin/node; run with --repair", True)

sys.exit(1 if drift else 0)
PY
