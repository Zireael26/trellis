#!/usr/bin/env python3
"""Measure the latency Trellis adds to agent work (spec 072 T0).

Run as `trellis bench [--suite hooks|lifecycle|gate] [--n N]`, or directly with
`python3 -I` from a checkout. Every measurement runs in a private sandbox: a
fresh HOME, TRELLIS_HOME and TMPDIR (canonical `pwd -P` paths of mktemp
directories), the stable launcher copied to $HOME/.local/bin/trellis, one
release, and one attached fixture project. The release is a copy of the
caller's installed active release (route mode: the caller's store is only
read), or, from a checkout or with --source, a committed revision sealed and
installed through the release-store library seam. Every PATH directory holding
another `trellis` is dropped so no live launcher can be reached.

Sections (--sections, comma list; --suite hooks = claude,codex,pi,pi-dispatch):
  claude       each Claude hook registered in the fixture's rendered
               .claude/settings.local.json, per tool (Read Bash Edit Write Grep
               Glob Skill) and per turn event (UserPromptSubmit, Stop). Matched
               hooks run concurrently, as Claude Code runs them.
  codex        the same for the rendered .codex/hooks.json. Codex concurrency is
               unverified, so both the concurrent wall and the serial sum of
               member walls are reported.
  pi           trellis.ts tool_call/tool_result/session_start/agent_settled
               handlers timed at the extension boundary by a headless host
               (pi-handler-runner.mjs): whatever the handler runs, in-process
               or through dispatch.sh, is inside the number.
  pi-dispatch  dispatch.sh alone, as trellis.ts invokes it (`--event-file F`,
               F 0600 in a fresh 0700 dir). Diagnostic; labelled dispatch-only.
  lifecycle    launcher routes, SessionStart hook groups, git switch, file
               checkout and worktree add in the attached fixture.
  gate         stage statistics from a run-tests-local aggregate TSV (--gate-tsv;
               the TSV carries no wall time, so pass --gate-wall).

Output: <out>/bench-<UTC date>-<label>.json and .md. Home, temp, sandbox and
user-specific strings are replaced by tokens at write time and PATH is kept as
counts, so a receipt can be published. Percentiles use linear interpolation;
p99 is reported only at n >= 200. CPU is user+sys of waited-for descendants
(RUSAGE_CHILDREN), so work a hook detaches into the background is not counted.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import resource
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

SCHEMA = "trellis-latency-bench/1"
SCRIPT_DIR = Path(__file__).resolve().parent
PAYLOADS = SCRIPT_DIR / "payloads"
DEFAULT_SOURCE = SCRIPT_DIR.parent.parent
TOOLS = ("Read", "Bash", "Edit", "Write", "Grep", "Glob", "Skill")
TURN_EVENTS = ("UserPromptSubmit", "Stop")
ALL_SECTIONS = ("claude", "codex", "pi", "pi-dispatch", "lifecycle", "gate")
SUITES = {"hooks": ("claude", "codex", "pi", "pi-dispatch"), "lifecycle": ("lifecycle",), "gate": ("gate",)}
P99_MIN_N = 200
LIFECYCLE_ITEMS = (
    "launcher-version", "launcher-help", "launcher-show-config", "launcher-heavy",
    "session-start-claude", "session-start-codex",
    "git-switch", "git-checkout-file", "git-worktree-add",
)
# pi tool families. For pi-dispatch: which phases trellis.ts sends to dispatch.sh
# (localPreAction decides read/edit/write pre-actions in-process).
PI_TOOLS = {
    "read": {"tool_call": None, "tool_result": "pi-tool_result-read.json"},
    "bash": {"tool_call": "pi-tool_call-bash.json", "tool_result": "pi-tool_result-bash.json"},
    "edit": {"tool_call": None, "tool_result": "pi-tool_result-edit.json"},
    "write": {"tool_call": None, "tool_result": "pi-tool_result-write.json"},
    "grep": {"tool_call": "pi-tool_call-grep.json", "tool_result": "pi-tool_result-grep.json"},
}
PI_LIFECYCLE = {"session_start": "pi-session_start.json", "agent_settled": "pi-agent_settled.json"}
COMMAND_TIMEOUT = 900.0
# `pyenv exec` prepends these when this script is launched through a shim; the
# user's real PATH has only the shims, which hooks must keep paying for.
PYENV_EXEC_PREPEND = re.compile(r"/\.pyenv/versions/|/pyenv/[^/]+/(?:libexec|plugins/)|/\.pyenv/(?:libexec|plugins/)")
# Hook state a real project ignores; without it the tree reads dirty and the
# Stop hooks measure a receipt demand instead of a clean turn end.
FIXTURE_FILES = {
    ".gitignore": "".join(line + "\n" for line in (
        ".claude/.reread-state/", ".codex/.reread-state/", ".pi/.reread-state/", ".codex/.fail-counter",
        ".claude/.review-done-*", ".codex/.review-done-*", "context-log.md")),
    "README.md": "# Bench fixture\n",
    "src/a.ts": "export function add(a: number, b: number): number {\n  return a + b;\n}\n",
    "src/b.py": "def add(a, b):\n    return a + b\n",
}

# One user turn and its reply, so transcript-scoped Stop hooks find an anchor.
TRANSCRIPT = "".join(json.dumps(line) + "\n" for line in (
    {"type": "user", "message": {"role": "user", "content": "fix the add function"}},
    {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Done."}]}},
))


class BenchError(Exception):
    pass


def log(message: str) -> None:
    print("trellis-latency: " + message, file=sys.stderr, flush=True)


def loadavg() -> List[float]:
    return [round(x, 2) for x in os.getloadavg()]


def canonical(path: str) -> str:
    return os.path.realpath(path)


def percentile(values: Sequence[float], q: float) -> float:
    ordered = sorted(values)
    k = (len(ordered) - 1) * q
    lo = int(k)
    hi = min(lo + 1, len(ordered) - 1)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (k - lo)


def stats(values: Sequence[float]) -> Optional[Dict[str, float]]:
    if not values:
        return None
    return {
        "n": len(values),
        "p50": round(percentile(values, 0.5), 1),
        "p90": round(percentile(values, 0.9), 1),
        "p99": round(percentile(values, 0.99), 1) if len(values) >= P99_MIN_N else None,
        "min": round(min(values), 1),
        "max": round(max(values), 1),
        "mean": round(sum(values) / len(values), 1),
    }


def children_cpu() -> float:
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime + usage.ru_stime


def tail(path: Path, limit: int = 400) -> str:
    try:
        data = path.read_bytes()
    except OSError:
        return ""
    return data[-limit:].decode("utf-8", errors="replace")


# --------------------------------------------------------------------------
# Process timing. Output goes to files, not pipes: a hook that leaves a
# background child holding stdout must not stretch the measured wall time
# past the moment its caller (git, the harness) would see it exit.


class Member:
    """One hook command. argv may be a callable, evaluated at each start."""

    def __init__(self, name: str, argv: Any, timeout_s: Optional[float] = None):
        self.name = name
        self.argv = argv
        self.timeout_s = timeout_s

    def command(self) -> List[str]:
        return self.argv() if callable(self.argv) else self.argv


def run_group(members: Sequence[Member], stdin: bytes, cwd: str, env: Dict[str, str],
              scratch: Path) -> Dict[str, Any]:
    """Start every member at once; return group wall, per-member wall, CPU, exits."""
    procs = []
    results: List[Dict[str, Any]] = [{} for _ in members]
    cpu0 = children_cpu()
    start = time.perf_counter()
    for index, member in enumerate(members):
        out = scratch / "m{}.out".format(index)
        err = scratch / "m{}.err".format(index)
        with open(out, "wb") as fout, open(err, "wb") as ferr:
            proc = subprocess.Popen(member.command(), cwd=cwd, env=env, stdin=subprocess.PIPE,
                                    stdout=fout, stderr=ferr, start_new_session=True)
        procs.append((proc, out, err))

    def feed_and_wait(index: int) -> None:
        proc = procs[index][0]
        try:
            if proc.stdin is not None:
                try:
                    proc.stdin.write(stdin)
                except BrokenPipeError:
                    pass
                proc.stdin.close()
            proc.wait(timeout=COMMAND_TIMEOUT)
            results[index]["timed_out"] = False
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
            proc.wait()
            results[index]["timed_out"] = True
        results[index]["wall_ms"] = (time.perf_counter() - start) * 1000.0
        results[index]["rc"] = proc.returncode

    threads = [threading.Thread(target=feed_and_wait, args=(i,)) for i in range(len(procs))]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    wall = (time.perf_counter() - start) * 1000.0
    cpu = (children_cpu() - cpu0) * 1000.0
    for index, (_, out, err) in enumerate(procs):
        results[index]["stdout"] = tail(out)
        results[index]["stderr"] = tail(err)
    return {"wall_ms": wall, "cpu_ms": cpu, "members": results}


def measure(case_id: str, members: Sequence[Member], stdin: bytes, cwd: str, env: Dict[str, str],
            runs: int, warmup: int, scratch: Path, before=None, after=None,
            extra: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    walls: List[float] = []
    cpus: List[float] = []
    member_walls: List[List[float]] = [[] for _ in members]
    rcs: List[set] = [set() for _ in members]
    timed_out = [0 for _ in members]
    over_registered = [0 for _ in members]
    sample: Optional[Dict[str, Any]] = None
    load_start = loadavg()
    for iteration in range(warmup + runs):
        if before is not None:
            before(iteration)
        outcome = run_group(members, stdin, cwd, env, scratch)
        if after is not None:
            after(iteration)
        if iteration == warmup:
            sample = [{"name": m.name, "rc": r["rc"], "stdout_tail": r["stdout"], "stderr_tail": r["stderr"]}
                      for m, r in zip(members, outcome["members"])]
        if iteration < warmup:
            continue
        walls.append(outcome["wall_ms"])
        cpus.append(outcome["cpu_ms"])
        for index, result in enumerate(outcome["members"]):
            member_walls[index].append(result["wall_ms"])
            rcs[index].add(result["rc"])
            if result["timed_out"]:
                timed_out[index] += 1
            limit = members[index].timeout_s
            if limit is not None and result["wall_ms"] > limit * 1000.0:
                over_registered[index] += 1
    record: Dict[str, Any] = {
        "id": case_id,
        "runs": runs,
        "warmup": warmup,
        "wall_ms": stats(walls),
        "cpu_ms": stats(cpus),
        "serial_sum_p50_ms": round(sum(percentile(w, 0.5) for w in member_walls if w), 1),
        "bench_cap_s": COMMAND_TIMEOUT,
        "load_start": load_start,
        "load_end": loadavg(),
        "members": [
            {
                "name": member.name,
                "registered_timeout_s": member.timeout_s,
                "wall_ms": stats(member_walls[index]),
                "exit_codes": sorted(rcs[index]),
                "runs_killed_at_bench_cap": timed_out[index],
                "runs_over_registered_timeout": over_registered[index],
            }
            for index, member in enumerate(members)
        ],
        "first_run": sample,
    }
    if extra:
        record.update(extra)
    p50 = record["wall_ms"]["p50"] if record["wall_ms"] else None
    log("{:<58} p50 {:>10} ms  (n={})".format(case_id, p50, runs))
    return record


# --------------------------------------------------------------------------
# Sandbox


def caller_path() -> str:
    """The PATH the caller's agents run with.

    Through `trellis bench` the launcher runs this script under its fixed
    control PATH and hands the caller's PATH over separately; measuring hooks
    under the control PATH would time a toolchain no agent has.
    """
    if os.environ.get("TRELLIS_BENCH_VIA_ROUTE") == "1":
        path = os.environ.get("TRELLIS_BENCH_CALLER_PATH", "")
        if not path:
            raise BenchError("the launcher did not forward the caller PATH; an installed launcher older than "
                             "`trellis bench` does not. Reinstall it with `trellis configure`.")
        return path
    return os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")


def clean_path(sandbox_bin: str, base: str) -> Tuple[str, Dict[str, int]]:
    """Caller PATH minus any other `trellis` launcher and pyenv's exec-time prepends."""
    kept: List[str] = []
    counts = {"caller_entries": 0, "dropped_trellis": 0, "dropped_pyenv_exec": 0}
    for entry in base.split(os.pathsep):
        if not entry:
            continue
        counts["caller_entries"] += 1
        resolved = os.path.normpath(entry)
        if os.path.exists(os.path.join(resolved, "trellis")):
            counts["dropped_trellis"] += 1
        elif PYENV_EXEC_PREPEND.search(resolved):
            counts["dropped_pyenv_exec"] += 1
        else:
            kept.append(entry)
    counts["entries"] = len(kept) + 1
    return os.pathsep.join([sandbox_bin] + kept), counts


class Sandbox:
    def __init__(self, root: str):
        self.root = root
        self.home = os.path.join(root, "home")
        self.trellis_home = os.path.join(root, "trellis-home")
        self.tmp = os.path.join(root, "tmp")
        self.project = os.path.join(root, "projects", "bench-fixture")
        self.transcript = os.path.join(root, "transcript.jsonl")
        self.launcher = os.path.join(self.home, ".local", "bin", "trellis")
        self.scratch = Path(root, "bench-scratch")
        self.path, self.path_counts = clean_path(os.path.join(self.home, ".local", "bin"), caller_path())
        self.meta: Dict[str, Any] = {}

    def env(self, **extra: str) -> Dict[str, str]:
        env = {
            "HOME": self.home,
            "TRELLIS_HOME": self.trellis_home,
            "TMPDIR": self.tmp + "/",
            "PATH": self.path,
            "LANG": os.environ.get("LANG", "en_US.UTF-8"),
            "USER": os.environ.get("USER", "bench"),
            "LOGNAME": os.environ.get("LOGNAME", os.environ.get("USER", "bench")),
            "SHELL": "/bin/bash",
            "TERM": "dumb",
            "GIT_CONFIG_NOSYSTEM": "1",
        }
        # Test seams (the run-tests Git fence) must reach every child.
        env.update({k: v for k, v in os.environ.items() if k.startswith("TRELLIS_TEST_")})
        env.update(extra)
        return env

    def git(self, args: List[str], cwd: str, check: bool = True, hooks: bool = True) -> subprocess.CompletedProcess:
        argv = ["git"] + ([] if hooks else ["-c", "core.hooksPath=/dev/null"]) + args
        proc = subprocess.run(argv, cwd=cwd, env=self.env(), capture_output=True, timeout=COMMAND_TIMEOUT)
        if check and proc.returncode != 0:
            raise BenchError("git {} failed in {}: {}".format(" ".join(args), cwd,
                                                             proc.stderr.decode(errors="replace")[-600:]))
        return proc


def is_checkout(path: str) -> bool:
    return subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"], capture_output=True,
                          text=True).stdout.strip() == canonical(path)


def install_from_checkout(sb: Sandbox, source: str, rev: str, timings: Dict[str, float]) -> Dict[str, Any]:
    """Seal the committed tree of <rev> as an annotated tag and install it."""
    t0 = time.perf_counter()
    commit = subprocess.run(["git", "-C", source, "rev-parse", "--verify", rev + "^{commit}"],
                            capture_output=True, text=True, check=True).stdout.strip()
    release_src = os.path.join(sb.root, "release-source")
    os.makedirs(release_src)
    archive = subprocess.Popen(["git", "-C", source, "archive", "--format=tar", commit], stdout=subprocess.PIPE)
    subprocess.run(["tar", "-x", "-C", release_src], stdin=archive.stdout, check=True)
    if archive.stdout is not None:
        archive.stdout.close()
    if archive.wait() != 0:
        raise BenchError("git archive failed for " + commit)
    version = Path(release_src, "core-rules", "VERSION").read_text(encoding="utf-8").strip()
    for args in (["init", "-q"], ["config", "user.email", "bench@example.invalid"],
                 ["config", "user.name", "Trellis Bench"], ["config", "commit.gpgsign", "false"],
                 ["config", "tag.gpgSign", "false"], ["config", "core.autocrlf", "false"],
                 ["add", "-A"], ["commit", "-qm", "release " + version],
                 ["tag", "-a", "v" + version, "-m", "release " + version]):
        sb.git(args, release_src, hooks=False)
    timings["release_source_s"] = round(time.perf_counter() - t0, 2)
    shutil.copyfile(os.path.join(release_src, "scripts", "trellis-launcher.sh"), sb.launcher)
    t0 = time.perf_counter()
    proc = subprocess.run(
        ["/bin/bash", "-c", '. "$1"; release_store_install "$2" "$3" "" >/dev/null', "bench-release-install",
         os.path.join(release_src, "scripts", "lib", "release-store.sh"), version, release_src],
        env=sb.env(), cwd=sb.root, capture_output=True, timeout=COMMAND_TIMEOUT)
    if proc.returncode != 0:
        raise BenchError("release install failed: " + proc.stderr.decode(errors="replace")[-800:])
    timings["release_install_s"] = round(time.perf_counter() - t0, 2)
    return {"mode": "checkout", "rev": rev, "commit": commit, "version": version, "source_root": release_src}


def copy_installed_release(sb: Sandbox, timings: Dict[str, float]) -> Dict[str, Any]:
    """Copy the caller's active installed release into the sandbox store (read-only on the caller)."""
    home = os.environ.get("TRELLIS_HOME") or os.path.join(os.path.expanduser("~"), ".trellis")
    version = json.loads(Path(home, "config.json").read_text(encoding="utf-8"))["active_cli_release"]
    t0 = time.perf_counter()
    releases = os.path.join(sb.trellis_home, "releases")
    os.makedirs(releases)
    os.chmod(releases, 0o700)
    # copytree applies each directory's (read-only) mode after filling it.
    shutil.copytree(os.path.join(home, "releases", version), os.path.join(releases, version), symlinks=True)
    record = json.loads(Path(releases, version, "release.json").read_text(encoding="utf-8"))
    shutil.copyfile(os.path.join(releases, version, "payload", "scripts", "trellis-launcher.sh"), sb.launcher)
    timings["release_copy_s"] = round(time.perf_counter() - t0, 2)
    source_root = os.path.join(sb.root, "release-source")
    os.makedirs(source_root)
    return {"mode": "installed", "rev": record.get("tag"), "commit": record.get("commit"), "version": version,
            "source_root": source_root}


def build_sandbox(base: str, source: Optional[str], rev: str) -> Sandbox:
    root = canonical(tempfile.mkdtemp(prefix="trellis-bench.", dir=base))
    sb = Sandbox(root)
    for path in (sb.home, sb.trellis_home, sb.tmp, os.path.dirname(sb.launcher), str(sb.scratch)):
        os.makedirs(path, exist_ok=True)
    for path in (sb.home, sb.trellis_home, sb.tmp):
        os.chmod(path, 0o700)
    Path(sb.transcript).write_text(TRANSCRIPT, encoding="utf-8")
    timings: Dict[str, float] = {}
    if source is not None:
        release = install_from_checkout(sb, source, rev, timings)
    else:
        release = copy_installed_release(sb, timings)
    os.chmod(sb.launcher, 0o755)
    projects = os.path.dirname(sb.project)
    os.makedirs(projects, exist_ok=True)
    config = {
        "schema_version": 1,
        "source_root": release["source_root"],
        "release_remote": "fixture://bench",
        "active_cli_release": release["version"],
        "default_fleet": "personal",
        "fleets": {"personal": {"discovery_roots": [projects]}},
    }
    config_path = os.path.join(sb.trellis_home, "config.json")
    Path(config_path).write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    os.chmod(config_path, 0o600)

    # Fixture project, attached through the launcher like an operator would.
    os.makedirs(sb.project)
    sb.git(["-c", "init.defaultBranch=main", "init", "-q"], sb.project, hooks=False)
    for key, value in (("user.email", "bench@example.invalid"), ("user.name", "Trellis Bench"),
                       ("commit.gpgsign", "false")):
        sb.git(["config", key, value], sb.project, hooks=False)
    Path(sb.project, ".trellis.json").write_text('{"schema_version":1,"project_id":"bench-fixture"}\n',
                                                 encoding="utf-8")
    for rel, text in FIXTURE_FILES.items():
        target = Path(sb.project, rel)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
    sb.git(["add", "-A"], sb.project, hooks=False)
    sb.git(["commit", "-qm", "initial"], sb.project, hooks=False)
    t0 = time.perf_counter()
    proc = subprocess.run([sb.launcher, "attach", "--fleet", "personal", sb.project], env=sb.env(),
                          cwd=sb.project, capture_output=True, timeout=COMMAND_TIMEOUT)
    if proc.returncode != 0:
        raise BenchError("attach failed ({}): {}".format(proc.returncode,
                                                         proc.stderr.decode(errors="replace")[-800:]))
    timings["attach_s"] = round(time.perf_counter() - t0, 2)
    sb.git(["branch", "bench-a"], sb.project, hooks=False)
    sb.meta = {"root": root, "source": source, "release_mode": release["mode"], "rev": release["rev"],
               "commit": release["commit"], "version": release["version"], "setup_seconds": timings}
    Path(root, "sandbox.json").write_text(json.dumps(sb.meta, indent=2) + "\n", encoding="utf-8")
    return sb


def reuse_sandbox(root: str) -> Sandbox:
    root = canonical(root)
    sb = Sandbox(root)
    sb.meta = json.loads(Path(root, "sandbox.json").read_text(encoding="utf-8"))
    sb.meta["reused"] = True
    sb.scratch.mkdir(exist_ok=True)
    return sb


def remove_tree(root: str) -> None:
    # Hooks detach background work (attach postjob, post-checkout reconcile)
    # that can outlive the measured command; stop it before deleting its tree.
    subprocess.run(["pkill", "-f", re.escape(root)], capture_output=True)
    for dirpath, dirnames, _ in os.walk(root):
        for name in dirnames:
            path = os.path.join(dirpath, name)
            try:
                if not os.path.islink(path):
                    os.chmod(path, os.lstat(path).st_mode | stat.S_IWUSR | stat.S_IXUSR | stat.S_IRUSR)
            except OSError:
                pass
    try:
        os.chmod(root, 0o700)
    except OSError:
        pass
    shutil.rmtree(root, ignore_errors=True)


# --------------------------------------------------------------------------
# Payloads and hook wiring


def payload(name: str, sb: Sandbox) -> bytes:
    text = (PAYLOADS / name).read_text(encoding="utf-8")
    for marker, value in (("@PROJECT@", sb.project), ("@TRANSCRIPT@", sb.transcript)):
        text = text.replace(marker, json.dumps(value)[1:-1])
    json.loads(text)
    return text.encode("utf-8")


def hook_label(command: str) -> str:
    launcher = re.search(r" hook ([a-z0-9-]+)", command)
    if launcher:
        return "launcher:" + launcher.group(1)
    scripts = re.findall(r"([A-Za-z0-9_-]+)\.(?:sh|pl|py)\b", command)
    scripts = [s for s in scripts if s != "guard-supervise"]
    return scripts[-1] if scripts else command[:40]


def if_matches(rule: str, tool: Optional[str], payload_bytes: Optional[bytes]) -> bool:
    """Approximate Claude's `if` filter: a Bash(...) glob over the whole command.

    Claude matches each subcommand and runs the hook when it cannot parse the
    input; any other rule shape is kept, so the bench never under-counts."""
    rule_match = re.fullmatch(r"(\w+)\((.*)\)", rule, re.S)
    if rule_match is None or tool is None:
        return True
    if rule_match.group(1) != tool:
        return False
    if tool != "Bash" or payload_bytes is None:
        return True
    command = json.loads(payload_bytes.decode("utf-8")).get("tool_input", {}).get("command", "")
    pattern = ".*".join(re.escape(part) for part in rule_match.group(2).split("*"))
    return re.fullmatch(pattern, command, re.S) is not None


def matched_hooks(hooks: Dict[str, Any], event: str, tool: Optional[str], project: str = "",
                  payload_bytes: Optional[bytes] = None) -> List[Member]:
    members: List[Member] = []
    for group in hooks.get(event, []):
        matcher = group.get("matcher") or ""
        if tool is not None and matcher and matcher != "*" and not re.fullmatch(matcher, tool):
            continue
        for hook in group.get("hooks", []):
            if hook.get("type", "command") != "command":
                continue
            if "if" in hook and not if_matches(hook["if"], tool, payload_bytes):
                continue
            command = hook["command"]
            if "args" in hook:
                # Exec form: Claude spawns the program directly and substitutes
                # ${CLAUDE_PROJECT_DIR} in each element as plain text.
                argv = [part.replace("${CLAUDE_PROJECT_DIR}", project) for part in [command] + hook["args"]]
                members.append(Member(hook_label(" ".join(argv)), argv, hook.get("timeout")))
            else:
                members.append(Member(hook_label(command), ["/bin/sh", "-c", command], hook.get("timeout")))
    return members


def load_hooks(path: str) -> Dict[str, Any]:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8")).get("hooks", {})
    except FileNotFoundError:
        raise BenchError("rendered hook settings missing from the attached fixture: " + path)


def wanted(case_id: str, pattern: Optional[str]) -> bool:
    return pattern is None or re.search(pattern, case_id) is not None


def bench_hook_harness(harness: str, sb: Sandbox, args, results: List[Dict[str, Any]]) -> None:
    if harness == "claude":
        hooks = load_hooks(os.path.join(sb.project, ".claude", "settings.local.json"))
        env = sb.env(CLAUDE_PROJECT_DIR=sb.project)
    else:
        hooks = load_hooks(os.path.join(sb.project, ".codex", "hooks.json"))
        env = sb.env(CODEX_PROJECT_DIR=sb.project)
    for tool in TOOLS:
        for phase in ("PreToolUse", "PostToolUse"):
            case_id = "{} {} {}".format(harness, phase, tool)
            if not wanted(case_id, args.hooks):
                continue
            stdin = payload("hook-{}-{}.json".format(phase, tool), sb)
            members = matched_hooks(hooks, phase, tool, sb.project, stdin)
            extra = {"section": harness, "harness": harness, "event": phase, "tool": tool}
            if not members:
                results.append(dict(extra, id=case_id, registered=0, wall_ms=None, note="no hook registered"))
                continue
            results.append(measure(case_id, members, stdin, sb.project, env, args.runs, args.warmup,
                                   sb.scratch, extra=dict(extra, registered=len(members))))
    for event in TURN_EVENTS:
        case_id = "{} {}".format(harness, event)
        if not wanted(case_id, args.hooks):
            continue
        members = matched_hooks(hooks, event, None, sb.project)
        extra = {"section": harness, "harness": harness, "event": event, "tool": None}
        if not members:
            results.append(dict(extra, id=case_id, registered=0, wall_ms=None, note="no hook registered"))
            continue
        before = None
        if event == "Stop":
            # Each turn opens with its prompt hooks; turn-baseline's record is what
            # lets Stop see an unchanged tree instead of an unknown one.
            prompt_members = matched_hooks(hooks, "UserPromptSubmit", None, sb.project)
            prompt = payload("hook-UserPromptSubmit.json", sb)

            def before(_i: int, members=prompt_members, prompt=prompt) -> None:
                run_group(members, prompt, sb.project, env, sb.scratch)

        results.append(measure(case_id, members, payload("hook-{}.json".format(event), sb), sb.project, env,
                               args.runs, args.warmup, sb.scratch, before=before,
                               extra=dict(extra, registered=len(members))))


def samples_record(case_id: str, values: List[float], runs: int, warmup: int, load_start: List[float],
                   extra: Dict[str, Any]) -> Dict[str, Any]:
    record = {"id": case_id, "runs": runs, "warmup": warmup, "wall_ms": stats(values), "cpu_ms": None,
              "load_start": load_start, "load_end": loadavg(), "members": [], "first_run": None}
    record.update(extra)
    log("{:<58} p50 {:>10} ms  (n={})".format(case_id, record["wall_ms"]["p50"] if values else None, runs))
    return record


def bench_pi(sb: Sandbox, args, results: List[Dict[str, Any]]) -> None:
    """Time trellis.ts handlers at the extension boundary through a headless pi host."""
    runner = str(SCRIPT_DIR / "pi-handler-runner.mjs")
    env = sb.env()
    node = shutil.which("node", path=env["PATH"])
    base = {"section": "pi", "harness": "pi", "boundary": "trellis.ts handler", "path": "extension handler"}
    jobs = [("tool", tool) for tool in PI_TOOLS] + [("event", event) for event in PI_LIFECYCLE]
    for kind, name in jobs:
        ids = (["pi tool_call " + name, "pi tool_result " + name] if kind == "tool" else ["pi " + name])
        if not any(wanted(case_id, args.hooks) for case_id in ids):
            continue
        events = ["tool_call", "tool_result"] if kind == "tool" else [name]
        if node is None:
            for case_id, event in zip(ids, events):
                results.append(dict(base, id=case_id, event=event, tool=name if kind == "tool" else None,
                                    wall_ms=None, note="node is not on PATH; the pi handler boundary is unmeasured"))
            continue
        load_start = loadavg()
        proc = subprocess.run([node, "--no-warnings", runner, "--project", sb.project, "--session-file",
                               sb.transcript, "--runs", str(args.runs), "--warmup", str(args.warmup),
                               "--" + kind, name], cwd=sb.project, env=env, capture_output=True,
                              timeout=COMMAND_TIMEOUT)
        if proc.returncode == 3:
            note = "node cannot load trellis.ts; the pi handler boundary is unmeasured: " + \
                proc.stderr.decode(errors="replace").strip()[-300:]
            for case_id, event in zip(ids, events):
                results.append(dict(base, id=case_id, event=event, tool=name if kind == "tool" else None,
                                    wall_ms=None, note=note))
            continue
        if proc.returncode != 0:
            raise BenchError("pi handler runner failed for {}: {}".format(
                name, proc.stderr.decode(errors="replace")[-800:]))
        report = json.loads(proc.stdout.decode().strip().splitlines()[-1])
        extra = {"exec_calls_per_run": round(report["exec_calls"] / (args.runs + args.warmup), 2),
                 "blocked_runs": report["blocked"]}
        if kind == "tool":
            for case_id, event, key in zip(ids, events, ("pre_ms", "post_ms")):
                if wanted(case_id, args.hooks):
                    results.append(samples_record(case_id, report[key], args.runs, args.warmup, load_start,
                                                  dict(base, event=event, tool=name, **extra)))
        else:
            results.append(samples_record(ids[0], report["ms"], args.runs, args.warmup, load_start,
                                          dict(base, event=name, tool=None, **extra)))


def pi_event_files(sb: Sandbox, name: str):
    """Recreate trellis.ts's transport per call: fresh 0700 dir, 0600 event file."""
    data = payload(name, sb)
    state: Dict[str, str] = {}

    def before(_iteration: int) -> None:
        directory = tempfile.mkdtemp(prefix="trellis-pi-event-", dir=sb.tmp)
        os.chmod(directory, 0o700)
        event = os.path.join(directory, "event.json")
        fd = os.open(event, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.chmod(event, 0o600)
        state["dir"] = directory
        state["file"] = event

    def after(_iteration: int) -> None:
        for remove in (lambda: os.unlink(state["file"]), lambda: os.rmdir(state["dir"])):
            try:
                remove()
            except FileNotFoundError:
                pass

    return before, after, state


def bench_pi_dispatch(sb: Sandbox, args, results: List[Dict[str, Any]]) -> None:
    """dispatch.sh alone (diagnostic): not the C1 boundary, labelled dispatch-only."""
    dispatcher = os.path.join(sb.project, ".trellis", "runtime", "core-rules", "pi", "hooks", "dispatch.sh")
    if not os.path.isfile(dispatcher):
        raise BenchError("pi dispatcher missing from the attached fixture: " + dispatcher)
    env = sb.env()
    base = {"section": "pi-dispatch", "harness": "pi", "boundary": "dispatch-only"}
    cases: List[Tuple[str, Optional[str], Dict[str, Any]]] = []
    for tool, phases in PI_TOOLS.items():
        for event, name in phases.items():
            cases.append(("pi-dispatch {} {}".format(event, tool), name, dict(base, event=event, tool=tool)))
    for event, name in PI_LIFECYCLE.items():
        cases.append(("pi-dispatch {}".format(event), name, dict(base, event=event, tool=None)))
    for case_id, name, extra in cases:
        if not wanted(case_id, args.hooks):
            continue
        if name is None:
            results.append(dict(extra, id=case_id, wall_ms=None, path="in-process",
                                note="trellis.ts decides this pre-action in-process (localPreAction); "
                                     "no dispatcher call"))
            continue
        before, after, state = pi_event_files(sb, name)
        member = Member(case_id, lambda state=state: [dispatcher, "--event-file", state["file"]], 300.0)
        results.append(measure(case_id, [member], b"", sb.project, env, args.runs, args.warmup, sb.scratch,
                               before=before, after=after, extra=dict(extra, path="dispatch.sh")))


# --------------------------------------------------------------------------
# Lifecycle


def bench_lifecycle(sb: Sandbox, args, results: List[Dict[str, Any]]) -> None:
    runs = args.lifecycle_runs
    items = args.lifecycle_items
    env = sb.env()
    base = {"section": "lifecycle"}

    def launcher(item: str, argv: List[str], cwd: str) -> None:
        if item in items:
            results.append(measure(item, [Member(item, [sb.launcher] + argv)], b"", cwd, env, runs, 0,
                                   sb.scratch, extra=dict(base, command="trellis " + " ".join(argv))))

    launcher("launcher-version", ["--version"], sb.root)
    launcher("launcher-help", ["help"], sb.root)
    launcher("launcher-show-config", ["show-config"], sb.project)
    launcher("launcher-heavy", ["heavy", "--lane", "bench", "--", "true"], sb.project)

    for harness, settings, project_var in (
            ("claude", os.path.join(sb.project, ".claude", "settings.local.json"), "CLAUDE_PROJECT_DIR"),
            ("codex", os.path.join(sb.project, ".codex", "hooks.json"), "CODEX_PROJECT_DIR")):
        item = "session-start-" + harness
        if item not in items:
            continue
        members = matched_hooks(load_hooks(settings), "SessionStart", None, sb.project)
        hook_env = sb.env(**{project_var: sb.project})
        results.append(measure(item, members, payload("hook-SessionStart.json", sb), sb.project, hook_env,
                               runs, 0, sb.scratch, extra=dict(base, harness=harness, event="SessionStart")))

    def git_member(name: str, git_args: Any, hooks: bool = True) -> Member:
        prefix = ["git"] + ([] if hooks else ["-c", "core.hooksPath=/dev/null"])
        if callable(git_args):
            return Member(name, lambda: prefix + git_args())
        return Member(name, prefix + git_args)

    if "git-switch" in items:
        sb.git(["switch", "-q", "main"], sb.project, hooks=False)
        for hooks in (False, True):
            name = "git-switch" + ("" if hooks else " (hooks off)")
            state = {"next": "bench-a"}

            def before(_i: int, state=state) -> None:
                state["argv"] = state["next"]

            def after(_i: int, state=state) -> None:
                state["next"] = "main" if state["next"] == "bench-a" else "bench-a"

            member = git_member(name, lambda state=state: ["switch", "-q", state["argv"]], hooks)
            results.append(measure(name, [member], b"", sb.project, env, runs, 0, sb.scratch, before, after,
                                   extra=dict(base, hooks=hooks)))
        sb.git(["switch", "-q", "main"], sb.project, hooks=False)

    if "git-checkout-file" in items:
        readme = Path(sb.project, "README.md")

        def dirty(_i: int) -> None:
            readme.write_text(FIXTURE_FILES["README.md"] + "changed\n", encoding="utf-8")

        for hooks in (False, True):
            name = "git-checkout-file" + ("" if hooks else " (hooks off)")
            results.append(measure(name, [git_member(name, ["checkout", "--", "README.md"], hooks)], b"",
                                   sb.project, env, runs, 0, sb.scratch, before=dirty,
                                   extra=dict(base, hooks=hooks)))

    if "git-worktree-add" in items:
        worktrees = os.path.join(sb.root, "worktrees")
        os.makedirs(worktrees, exist_ok=True)
        for hooks in (False, True):
            name = "git-worktree-add" + ("" if hooks else " (hooks off)")
            state: Dict[str, Any] = {"count": 0}
            tag = "on" if hooks else "off"

            def before(_i: int, state=state, tag=tag) -> None:
                state["count"] += 1
                state["branch"] = "bench-wt-{}-{}".format(tag, state["count"])
                state["path"] = os.path.join(worktrees, state["branch"])

            def after(_i: int, state=state) -> None:
                sb.git(["worktree", "remove", "--force", state["path"]], sb.project, check=False, hooks=False)
                sb.git(["branch", "-D", state["branch"]], sb.project, check=False, hooks=False)

            member = git_member(name, lambda state=state: ["worktree", "add", "-q", "-b", state["branch"],
                                                           state["path"]], hooks)
            results.append(measure(name, [member], b"", sb.project, env, runs, 0, sb.scratch, before, after,
                                   extra=dict(base, hooks=hooks)))


# --------------------------------------------------------------------------
# Gate


def bench_gate(tsv: str, wall: Optional[float], top: int) -> Dict[str, Any]:
    rows: List[Dict[str, Any]] = []
    try:
        with open(tsv, encoding="utf-8") as handle:
            header = handle.readline().rstrip("\r\n")
            if header != "ordinal\tstage\telapsed_seconds\texit":
                raise BenchError("not a run-tests-local timing receipt (header {!r}): {}".format(header, tsv))
            for line in handle:
                fields = line.rstrip("\r\n").split("\t")
                if len(fields) != 4:
                    raise BenchError("invalid timing row in {}: {!r}".format(tsv, line))
                rows.append({"ordinal": int(fields[0]), "stage": fields[1], "seconds": float(fields[2]),
                             "exit": int(fields[3])})
    except (OSError, ValueError) as exc:
        raise BenchError("unreadable timing receipt {}: {}".format(tsv, exc))
    if wall is None:
        log("warning: the gate section has no wall source (the TSV carries none); pass --gate-wall")
    seconds = [row["seconds"] for row in rows]
    total = sum(seconds)
    ranked = sorted(rows, key=lambda row: row["seconds"], reverse=True)
    return {
        "tsv": os.path.basename(tsv),
        "stages": len(rows),
        "failed_stages": sum(1 for row in rows if row["exit"] != 0),
        "stage_seconds_sum": round(total, 1),
        "wall_seconds": wall,
        "wall_source": "--gate-wall" if wall is not None else None,
        "max_stage_seconds": max(seconds) if seconds else None,
        "stage_seconds": stats(seconds),
        "top_stages": [dict(row, share=round(row["seconds"] / total, 3) if total else None) for row in ranked[:top]],
    }


# --------------------------------------------------------------------------
# Summary and output


def p50(record: Optional[Dict[str, Any]]) -> Optional[float]:
    if not record or not record.get("wall_ms"):
        return None
    return record["wall_ms"]["p50"]


def summarize(results: List[Dict[str, Any]]) -> Dict[str, Any]:
    by_id = {r["id"]: r for r in results}
    per_tool: Dict[str, Dict[str, Any]] = {}
    turn: Dict[str, Any] = {}
    reference = {"Read": 4, "Bash": 3, "Edit": 2, "Grep": 1}
    for harness in ("claude", "codex"):
        if not any(r.get("harness") == harness and r.get("section") == harness for r in results):
            continue
        tools: Dict[str, Any] = {}
        for tool in TOOLS:
            pre, post = by_id.get("{} PreToolUse {}".format(harness, tool)), by_id.get(
                "{} PostToolUse {}".format(harness, tool))
            if pre is None and post is None:
                continue
            total = sum(v for v in (p50(pre), p50(post)) if v is not None)
            entry: Dict[str, Any] = {"pre_p50_ms": p50(pre), "post_p50_ms": p50(post), "total_p50_ms": round(total, 1)}
            if harness == "codex":
                entry["serial_total_p50_ms"] = round(sum(
                    (r or {}).get("serial_sum_p50_ms") or 0 for r in (pre, post)), 1)
            tools[tool] = entry
        per_tool[harness] = tools
        events = {e: p50(by_id.get("{} {}".format(harness, e))) for e in TURN_EVENTS}
        if all(t in tools for t in reference):
            ms = sum(tools[t]["total_p50_ms"] * n for t, n in reference.items())
            ms += sum(v for v in events.values() if v is not None)
            turn[harness] = {"ms": round(ms, 1), "events_p50_ms": events}
    if any(r.get("section") == "pi" for r in results):
        tools = {}
        for tool in PI_TOOLS:
            pre, post = by_id.get("pi tool_call " + tool), by_id.get("pi tool_result " + tool)
            if pre is None and post is None:
                continue
            total = sum(v for v in (p50(pre), p50(post)) if v is not None)
            tools[tool] = {"pre_p50_ms": p50(pre), "pre_path": (pre or {}).get("path"),
                           "post_p50_ms": p50(post), "total_p50_ms": round(total, 1)}
        per_tool["pi"] = tools
        pi_reference = {"read": 4, "bash": 3, "edit": 2, "grep": 1}
        if all(t in tools for t in pi_reference):
            settled = p50(by_id.get("pi agent_settled"))
            ms = sum(tools[t]["total_p50_ms"] * n for t, n in pi_reference.items()) + (settled or 0)
            turn["pi"] = {"ms": round(ms, 1), "events_p50_ms": {"agent_settled": settled}}
    if any(r.get("section") == "pi-dispatch" for r in results):
        tools = {}
        for tool in PI_TOOLS:
            pre, post = by_id.get("pi-dispatch tool_call " + tool), by_id.get("pi-dispatch tool_result " + tool)
            if pre is None and post is None:
                continue
            total = sum(v for v in (p50(pre), p50(post)) if v is not None)
            tools[tool] = {"pre_p50_ms": p50(pre), "pre_path": (pre or {}).get("path"),
                           "post_p50_ms": p50(post), "total_p50_ms": round(total, 1)}
        per_tool["pi-dispatch (dispatch-only)"] = tools
    lifecycle = {}
    for r in results:
        if r.get("section") == "lifecycle" and r.get("wall_ms"):
            lifecycle[r["id"]] = {"wall_p50_ms": r["wall_ms"]["p50"],
                                  "cpu_p50_ms": r["cpu_ms"]["p50"] if r.get("cpu_ms") else None}
    return {
        "per_tool_call_p50_ms": per_tool,
        "reference_turn": dict(turn, definition="4 Read + 3 Bash + 2 Edit + 1 Grep + prompt + Stop, sum of p50s; "
                                                "pi at the trellis.ts handler boundary"),
        "lifecycle_p50": lifecycle,
    }


def fmt(value: Any) -> str:
    if value is None:
        return "—"
    if isinstance(value, float):
        return "{:,.1f}".format(value)
    return str(value)


def markdown(receipt: Dict[str, Any]) -> str:
    out: List[str] = []
    meta = receipt
    out.append("# Trellis latency bench: {}".format(meta["label"]))
    out.append("")
    out.append("- Condition: **{}**".format(meta["condition"]))
    out.append("- Created: {} · release {} from `{}` ({})".format(
        meta["created_utc"], meta["source"].get("version"), meta["source"].get("rev"),
        (meta["source"].get("commit") or "")[:12]))
    out.append("- Host: {} · {} CPUs · filesystem {} · gate or Bats running {} · load start {} · load end {}".format(
        meta["host"]["platform"], meta["host"]["cpu_count"], meta["host"].get("filesystem"),
        meta["host"].get("gate_or_bats_running"), meta["load"]["start"], meta["load"]["end"]))
    out.append("- Runs: hooks {} (+{} warmup), lifecycle {} · sections {}".format(
        meta["config"]["runs"], meta["config"]["warmup"], meta["config"]["lifecycle_runs"],
        ", ".join(meta["config"]["sections"])))
    if meta.get("sandbox", {}).get("setup_seconds"):
        out.append("- Sandbox setup (s): {}".format(meta["sandbox"]["setup_seconds"]))
    out.append("")
    summary = meta["summary"]
    if summary["per_tool_call_p50_ms"]:
        out.append("## Per tool call (p50 ms, pre + post)")
        out.append("")
        out.append("| Harness | Tool | Pre | Post | Total |")
        out.append("|---|---|---:|---:|---:|")
        for harness, tools in summary["per_tool_call_p50_ms"].items():
            for tool, entry in tools.items():
                pre = entry["pre_p50_ms"]
                if pre is None and entry.get("pre_path") == "in-process":
                    pre = "in-process"
                out.append("| {} | {} | {} | {} | {} |".format(harness, tool, fmt(pre), fmt(entry["post_p50_ms"]),
                                                              fmt(entry["total_p50_ms"])))
        out.append("")
    turn = {k: v for k, v in summary["reference_turn"].items() if k != "definition"}
    if turn:
        out.append("## Reference turn ({})".format(summary["reference_turn"]["definition"]))
        out.append("")
        out.append("| Harness | ms |")
        out.append("|---|---:|")
        for harness, entry in turn.items():
            out.append("| {} | {} |".format(harness, fmt(entry["ms"])))
        out.append("")
    out.append("## All cases")
    out.append("")
    out.append("p99 is shown only at n ≥ {}.".format(P99_MIN_N))
    out.append("")
    out.append("| Case | n | p50 ms | p90 ms | p99 ms | CPU p50 ms | exits | over timeout | load start→end |")
    out.append("|---|---:|---:|---:|---:|---:|---|---:|---|")
    for r in meta["results"]:
        wall = r.get("wall_ms")
        if not wall:
            out.append("| {} | — | — | — | — | — | {} | — | — |".format(r["id"], r.get("note", "")))
            continue
        members = r.get("members", [])
        exits = ";".join("{}={}".format(m["name"], ",".join(str(c) for c in m["exit_codes"])) for m in members) \
            or r.get("boundary", "")
        over = sum(m["runs_over_registered_timeout"] for m in members)
        cpu = r.get("cpu_ms") or {}
        out.append("| {} | {} | {} | {} | {} | {} | {} | {} | {}→{} |".format(
            r["id"], wall["n"], fmt(wall["p50"]), fmt(wall["p90"]), fmt(wall["p99"]), fmt(cpu.get("p50")),
            exits, over, r["load_start"][0], r["load_end"][0]))
    out.append("")
    gate = meta.get("gate")
    if gate:
        out.append("## Gate ({})".format(gate["tsv"]))
        out.append("")
        out.append("- Stages {} (failed {}), stage-seconds sum {}, wall {} ({}), max stage {}".format(
            gate["stages"], gate["failed_stages"], fmt(gate["stage_seconds_sum"]), fmt(gate["wall_seconds"]),
            gate["wall_source"] or "no wall source", fmt(gate["max_stage_seconds"])))
        out.append("")
        out.append("| Stage | s | share |")
        out.append("|---|---:|---:|")
        for row in gate["top_stages"]:
            out.append("| {} | {} | {} |".format(row["stage"], fmt(row["seconds"]), fmt(row["share"])))
        out.append("")
    if meta.get("notes"):
        out.append("## Notes")
        out.append("")
        for note in meta["notes"]:
            out.append("- " + note)
        out.append("")
    return "\n".join(out)


def parse_args(argv: Sequence[str]):
    parser = argparse.ArgumentParser(prog="trellis bench", description=__doc__.split("\n\n")[0],
                                     epilog=__doc__.split("\n\n", 1)[1],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--suite", action="append", default=[],
                        help="hooks, lifecycle or gate (repeatable or comma list; default hooks,lifecycle)")
    parser.add_argument("--n", type=int, help="timed runs for every hook and lifecycle case")
    parser.add_argument("--out", default=".", help="directory for bench-<date>-<label>.{json,md} (default .)")
    parser.add_argument("--label", default="run")
    parser.add_argument("--sections", help="finer than --suite; comma list from: " + ",".join(ALL_SECTIONS))
    parser.add_argument("--runs", type=int, help="timed runs per hook case (default --n, else 30)")
    parser.add_argument("--warmup", type=int, default=2, help="untimed runs before each hook case (default 2)")
    parser.add_argument("--lifecycle-runs", type=int, help="timed runs per lifecycle item (default --n, else 5)")
    parser.add_argument("--hooks", help="regex; only hook cases whose id matches (e.g. 'claude PostToolUse Read')")
    parser.add_argument("--lifecycle-items", default=",".join(LIFECYCLE_ITEMS),
                        help="comma list from: " + ",".join(LIFECYCLE_ITEMS))
    parser.add_argument("--gate-tsv", help="run-tests-local aggregate timing TSV to summarize")
    parser.add_argument("--gate-wall", type=float, help="battery wall seconds (the TSV has none)")
    parser.add_argument("--gate-top", type=int, default=10)
    parser.add_argument("--source", help="checkout to build the release from (default: this checkout, or the "
                                         "caller's installed active release when run as `trellis bench`)")
    parser.add_argument("--rev", default="HEAD", help="committed revision to install with --source (default HEAD)")
    parser.add_argument("--sandbox-base", default=None, help="parent for the sandbox (default $TMPDIR)")
    parser.add_argument("--condition", default="normal",
                        help="measurement condition recorded in the receipt (e.g. load-contended)")
    parser.add_argument("--keep", action="store_true", help="keep the sandbox and print its path")
    parser.add_argument("--reuse", help="reuse a sandbox kept by --keep instead of building one")
    args = parser.parse_args(argv)
    suites = [s for value in args.suite for s in value.split(",") if s]
    unknown = set(suites) - set(SUITES)
    if unknown:
        parser.error("unknown suites: " + ",".join(sorted(unknown)))
    if args.sections:
        args.sections = [s for s in args.sections.split(",") if s]
    else:
        args.sections = [section for suite in (suites or ["hooks", "lifecycle"]) for section in SUITES[suite]]
    if args.gate_tsv and "gate" not in args.sections:
        args.sections.append("gate")
    unknown = set(args.sections) - set(ALL_SECTIONS)
    if unknown:
        parser.error("unknown sections: " + ",".join(sorted(unknown)))
    if "gate" in args.sections and not args.gate_tsv:
        parser.error("the gate section needs --gate-tsv")
    args.lifecycle_items = [s for s in args.lifecycle_items.split(",") if s]
    unknown = set(args.lifecycle_items) - set(LIFECYCLE_ITEMS)
    if unknown:
        parser.error("unknown lifecycle items: " + ",".join(sorted(unknown)))
    args.runs = args.runs or args.n or 30
    args.lifecycle_runs = args.lifecycle_runs or args.n or 5
    if args.runs < 1 or args.lifecycle_runs < 1 or args.warmup < 0:
        parser.error("--n, --runs and --lifecycle-runs must be >= 1, --warmup >= 0")
    if args.hooks:
        re.compile(args.hooks)
    return args


# --------------------------------------------------------------------------
# Redaction: receipts are published, so no home, temp, sandbox or user string
# survives the write.


class Redactor:
    def __init__(self, pairs: Sequence[Tuple[Optional[str], str]], user: Optional[str]):
        expanded: Dict[str, str] = {}
        for value, token in pairs:
            if not value or len(value.rstrip("/")) < 2:
                continue
            value = value.rstrip("/")
            for form in {value, canonical(value)}:
                expanded.setdefault(form, token)
        self.pairs = sorted(expanded.items(), key=lambda pair: len(pair[0]), reverse=True)
        # A name this short would rewrite ordinary words; the path tokens cover it.
        self.user = user if user and len(user) >= 3 else None

    def text(self, value: str) -> str:
        for old, new in self.pairs:
            value = value.replace(old, new)
        if self.user:
            value = value.replace(self.user, "<USER>")
        return value

    def tree(self, value: Any) -> Any:
        if isinstance(value, str):
            return self.text(value)
        if isinstance(value, list):
            return [self.tree(item) for item in value]
        if isinstance(value, dict):
            return {self.text(key): self.tree(item) for key, item in value.items()}
        return value


def host_redactor(extra: Sequence[Tuple[Optional[str], str]]) -> Redactor:
    try:
        import pwd
        entry = pwd.getpwuid(os.getuid())
        home, user = entry.pw_dir, entry.pw_name
    except (ImportError, KeyError):
        home, user = None, None
    pairs = list(extra) + [
        (os.environ.get("TMPDIR"), "<TMPDIR>"), (tempfile.gettempdir(), "<TMPDIR>"),
        (os.environ.get("HOME"), "<HOME>"), (home, "<HOME>"),
    ]
    return Redactor(pairs, os.environ.get("USER") or user)


def filesystem_of(path: str) -> Optional[str]:
    mounts = subprocess.run(["mount"], capture_output=True, text=True).stdout
    best, kind = "", None
    for line in mounts.splitlines():
        match = re.search(r" on (/.*?) (?:\(([^,)]+)|type (\S+))", line)
        if not match:
            continue
        point = match.group(1)
        if (path == point or path.startswith(point.rstrip("/") + "/")) and len(point) >= len(best):
            best, kind = point, match.group(2) or match.group(3)
    return kind


def gate_or_bats_running() -> bool:
    # Any gate, individual Bats group, or ambiguous/unavailable probe counts as
    # contention, not just the full battery. Anchor on interpreter identity, not
    # arbitrary prompt or shell-command text. An unavailable snapshot must not
    # label a potentially contended measurement as quiet.
    return subprocess.run(["bash", str(SCRIPT_DIR.parent / "check-process-liveness.sh"), "--gate"],
                          capture_output=True).returncode != 0


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    created = datetime.now(timezone.utc)
    load_start = loadavg()
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    results: List[Dict[str, Any]] = []
    notes: List[str] = [
        "Claude and Codex hooks are read from the attach-rendered .claude/settings.local.json and "
        ".codex/hooks.json (templates claude-settings.local.json and codex-hooks.local.json); the "
        "direct-copy claude-settings.json manifest is not what attached projects run.",
        "Hook payloads are scripts/bench/payloads/*.json with @PROJECT@/@TRANSCRIPT@ filled in; Codex "
        "receives the Claude-shaped payloads.",
        "Fixture tree is clean and has no package.json, so post-edit-verify, stop-verify and "
        "code-review-subagent take their no-toolchain, below-threshold paths.",
        "pi rows time the trellis.ts handlers (the C1 boundary); pi-dispatch rows time dispatch.sh alone "
        "and are dispatch-only diagnostics.",
    ]
    sb: Optional[Sandbox] = None
    needs_sandbox = any(s in args.sections for s in ("claude", "codex", "pi", "pi-dispatch", "lifecycle"))
    source = canonical(args.source) if args.source else (
        str(DEFAULT_SOURCE) if is_checkout(str(DEFAULT_SOURCE)) else None)
    base = canonical(args.sandbox_base or os.environ.get("TMPDIR") or tempfile.gettempdir())
    exit_code = 0
    gate = None
    try:
        if needs_sandbox:
            if args.reuse:
                sb = reuse_sandbox(args.reuse)
            else:
                log("building sandbox under " + base)
                sb = build_sandbox(base, source, args.rev)
            log("sandbox " + sb.root)
        for section in args.sections:
            if section in ("claude", "codex"):
                bench_hook_harness(section, sb, args, results)
            elif section == "pi":
                bench_pi(sb, args, results)
            elif section == "pi-dispatch":
                bench_pi_dispatch(sb, args, results)
            elif section == "lifecycle":
                bench_lifecycle(sb, args, results)
            elif section == "gate":
                gate = bench_gate(args.gate_tsv, args.gate_wall, args.gate_top)
                if gate["wall_seconds"] is None:
                    notes.append("Gate wall is unknown: the TSV carries none and --gate-wall was not given.")
    except BenchError as exc:
        log("error: " + str(exc))
        notes.append("ABORTED: " + str(exc))
        exit_code = 1
    receipt = {
        "schema": SCHEMA,
        "label": args.label,
        "condition": args.condition,
        "created_utc": created.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "host": {"platform": platform.platform(), "machine": platform.machine(), "cpu_count": os.cpu_count(),
                 "python": sys.version.split()[0], "filesystem": filesystem_of(base),
                 "gate_or_bats_running": gate_or_bats_running()},
        "source": {k: (sb.meta.get(k) if sb else None) for k in ("release_mode", "rev", "commit", "version")},
        "config": {"runs": args.runs, "warmup": args.warmup, "lifecycle_runs": args.lifecycle_runs,
                   "sections": args.sections, "hooks_filter": args.hooks,
                   "lifecycle_items": args.lifecycle_items if "lifecycle" in args.sections else []},
        "load": {"start": load_start, "end": loadavg()},
        "sandbox": {"kept": bool(sb and (args.keep or args.reuse)),
                    "setup_seconds": sb.meta.get("setup_seconds") if sb else None,
                    "path_counts": sb.path_counts if sb else None},
        "results": results,
        "summary": summarize(results),
        "gate": gate,
        "notes": notes,
        "status": "ok" if exit_code == 0 else "aborted",
    }
    redactor = host_redactor([(sb.root if sb else None, "<SANDBOX>"), (base, "<SANDBOX_BASE>"),
                              (source, "<SOURCE>"), (canonical(str(out_dir)), "<OUT>")])
    receipt = redactor.tree(receipt)
    stem = "bench-{}-{}".format(created.strftime("%Y-%m-%d"), args.label)
    json_path = out_dir / (stem + ".json")
    md_path = out_dir / (stem + ".md")
    json_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    md_path.write_text(markdown(receipt), encoding="utf-8")
    print(json_path)
    print(md_path)
    if sb is not None:
        if args.keep or args.reuse:
            log("kept sandbox: " + sb.root)
        else:
            remove_tree(sb.root)
    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
