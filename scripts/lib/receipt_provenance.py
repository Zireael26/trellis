"""Read-only start provenance for release-bound gate receipts (spec 066 process).

JSON lines go to stderr and a sibling .provenance.jsonl, never the timing TSV.
Inventory CLI calls never capture. Capture/emission failures are nonfatal.
Only the named tools, PATH and active CLI pointer are read; no environment dump
or Trellis invocation. Version probes are bounded and unavailable is explicit.
"""
from __future__ import annotations

import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Any, Sequence

TOOLS = ("bash", "bats", "jq", "git", "node", "pnpm")


def probe(command: Sequence[str], env: dict[str, str], cwd: Path) -> str:
    try:
        # Stay in the caller's group so gate teardown/interrupts kill probes too.
        child = subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL)
        try:
            output, _ = child.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                child.kill()
            except ProcessLookupError:
                pass
            try:
                child.communicate(timeout=0.2)
            except subprocess.TimeoutExpired:
                # A descendant may still hold stdout; never wait indefinitely.
                child.stdout.close()
            return "unavailable: probe timeout"
        if child.returncode:
            return "unavailable: probe exit {}".format(child.returncode)
        text = output.decode("utf-8", errors="replace").strip()
        return text.splitlines()[0] if text else "unavailable: empty probe"
    except OSError:
        return "unavailable: probe could not execute"


def capture(root: Path, command: Sequence[str], phase: str = "start") -> dict[str, Any]:
    # Copy before any probe, so a changed PATH cannot retroactively change START.
    env = os.environ.copy()
    path = env.get("PATH", "")
    # A Corepack-backed pnpm --version must not provision/download a tool.
    env["COREPACK_ENABLE_NETWORK"] = "0"
    env["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    # Head is the explicit source root, never Git's inherited hook checkout.
    git_env = {k: v for k, v in env.items() if not k.startswith("GIT_")}
    tools = {}
    for name in TOOLS:
        executable = shutil.which(name, path=path)
        tools[name] = {"path": executable or "unavailable: not on PATH",
                       "realpath": str(Path(executable).resolve()) if executable else "unavailable: not on PATH",
                       "version": probe([executable, "--version"], env, root)
                       if executable else "unavailable: not on PATH"}
    git = shutil.which("git", path=path)
    head = probe([git, "-C", str(root), "rev-parse", "--verify", "HEAD"], git_env, root) if git else "unavailable: git"
    config = Path(env.get("TRELLIS_HOME", str(Path.home() / ".trellis"))) / "config.json"
    release = "unavailable: active_cli_release"
    try:
        value = json.loads(config.read_text(encoding="utf-8"))["active_cli_release"]
        if isinstance(value, str) and value:
            release = value
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return {"receipt_provenance": 1, "phase": phase, "timestamp": timestamp,
            "head": head, "command": list(command), "source_root": str(root),
            "path": path, "tools": tools, "active_trellis_release": release,
            "active_release_source": str(config)}


def safe_capture(root: Path, command: Sequence[str], phase: str = "start") -> dict[str, Any]:
    try:
        return capture(root, command, phase)
    except (OSError, ValueError, RuntimeError) as exc:
        # Expected capture errors only; runner deadline/signal exits propagate.
        # Exception class only: arbitrary error messages can contain private data.
        return {"phase": phase, "provenance": "unavailable",
                "reason": "capture failed: " + type(exc).__name__}


def emit(record: dict[str, Any], receipt: Path | None = None, *, stderr: bool = True) -> bool:
    line = json.dumps(record, sort_keys=True) + "\n"
    durable = False
    if receipt is not None:
        try:
            sidecar = Path(str(receipt) + ".provenance.jsonl")
            sidecar.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(sidecar, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            try:
                os.write(fd, line.encode("utf-8"))
            finally:
                os.close(fd)
            durable = True
        except (OSError, ValueError, RuntimeError):
            record["provenance_sidecar"] = "unavailable: write failed"
            line = json.dumps(record, sort_keys=True) + "\n"
    if stderr:
        try:
            print(line, file=sys.stderr, end="", flush=True)
        except (OSError, ValueError):
            pass
    return durable


if __name__ == "__main__":
    # Internal CLI: ROOT PHASE RECEIPT (empty = no sidecar) COMMAND...
    root, phase, receipt, *command = sys.argv[1:]
    record = safe_capture(Path(root), command, phase)
    emit(record, Path(receipt) if receipt else None, stderr=False)
    # The shell runner owns stderr.
    print(json.dumps(record, sort_keys=True))
