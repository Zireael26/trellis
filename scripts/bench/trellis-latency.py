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


class TeardownError(BenchError):
    """A case could not restore its fixture; the sandbox is kept as evidence."""


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
    """One hook command. argv may be a callable, evaluated at each start.

    A native entry (T34) is one process that runs several fused members;
    `fused` names them, and each is reported with the entry's measurements."""

    def __init__(self, name: str, argv: Any, timeout_s: Optional[float] = None, cwd: Any = None,
                 fused: Optional[List[str]] = None):
        self.name = name
        self.argv = argv
        self.timeout_s = timeout_s
        self.cwd = cwd
        self.verified_argv = None
        self.fused = fused

    def command(self) -> List[str]:
        return self.argv() if callable(self.argv) else self.argv


def run_group(members: Sequence[Member], stdin: bytes, cwd: str, env: Dict[str, str],
              scratch: Path, deadline: Optional[float] = None) -> Dict[str, Any]:
    """Start every member at once; return group wall, per-member wall, CPU, exits."""
    procs = []
    results: List[Dict[str, Any]] = [{} for _ in members]
    cpu0 = children_cpu()
    start = time.perf_counter()
    try:
        for index, member in enumerate(members):
            out = scratch / "m{}.out".format(index)
            err = scratch / "m{}.err".format(index)
            with open(out, "wb") as fout, open(err, "wb") as ferr:
                try:
                    member_cwd = member.cwd() if callable(member.cwd) else member.cwd or cwd
                    argv = member.command()
                    if member.verified_argv is not None and tuple(argv) != member.verified_argv:
                        raise BenchError("measured command differs from its hook-execution proof")
                    proc = subprocess.Popen(argv, cwd=member_cwd, env=env, stdin=subprocess.PIPE,
                                            stdout=fout, stderr=ferr, start_new_session=True)
                except OSError as error:
                    proc = None
                    ferr.write(str(error).encode("utf-8", errors="replace"))
                    results[index] = {"rc": 127, "raw_rc": None, "exec_error": True,
                                      "exec_error_message": str(error), "timed_out": False,
                                      "wall_ms": None}
            procs.append((proc, out, err))
    except BaseException:
        for proc, _, _ in procs:
            if proc is not None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()
        raise

    def feed_and_wait(index: int) -> None:
        proc = procs[index][0]
        if proc is None:
            return
        # The watchdog is independent of input delivery: a worker that never
        # reads stdin must not block us before wait(timeout) is even reached.
        expired = threading.Event()

        def kill() -> None:
            expired.set()
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

        cap = COMMAND_TIMEOUT if deadline is None else max(0, deadline - time.monotonic())
        watchdog = threading.Timer(cap, kill)
        watchdog.daemon = True
        watchdog.start()
        try:
            proc.communicate(input=stdin)
        finally:
            watchdog.cancel()
            watchdog.join()
        results[index]["timed_out"] = expired.is_set()
        results[index]["wall_ms"] = (time.perf_counter() - start) * 1000.0
        results[index]["raw_rc"] = proc.returncode
        results[index]["rc"] = 124 if expired.is_set() else proc.returncode
        results[index]["exec_error"] = False

    threads = [threading.Thread(target=feed_and_wait, args=(i,), daemon=True) for i in range(len(procs))]
    for thread in threads:
        thread.start()
    try:
        for thread in threads:
            thread.join()
    except BaseException:
        # Cleanup and re-raise control-flow interrupts; never turn them into
        # ordinary case failures or continue with later measurements.
        for proc, _, _ in procs:
            if proc is not None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        for thread in threads:
            thread.join(timeout=1)
        raise
    wall = (time.perf_counter() - start) * 1000.0
    cpu = (children_cpu() - cpu0) * 1000.0
    for index, (_, out, err) in enumerate(procs):
        results[index]["stdout"] = tail(out)
        results[index]["stderr"] = tail(err)
    return {"wall_ms": wall, "cpu_ms": cpu, "members": results}


class CallbackTimeout(BenchError):
    pass


def callback_call(callback, deadline: float, *args):
    """Bound fixture callbacks by the observation deadline, outside wall_ms."""
    if callback is None:
        return None
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise CallbackTimeout("observation deadline exhausted")

    def expired(_signal, _frame):
        raise CallbackTimeout("fixture callback deadline exceeded")

    previous = signal.signal(signal.SIGALRM, expired)
    previous_timer = signal.setitimer(signal.ITIMER_REAL, remaining)
    try:
        return callback(*args)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
        if previous_timer[0]:
            signal.setitimer(signal.ITIMER_REAL, *previous_timer)


def failure_detail(error: BaseException, phase: str) -> Dict[str, str]:
    return {"phase": phase, "type": type(error).__name__, "message": str(error)}


def finalize_record(record: Dict[str, Any], status: Optional[str] = None) -> Dict[str, Any]:
    """Only final ok records may expose timing aggregates."""
    if status is not None:
        record["status"] = status
    # The ordinary SC13 fixture lacks independently bound execution/source
    # proofs. Never let a caller or a cleanup transition promote it to evidence.
    if record.get("id") == "pre-push-dispatcher-ordinary":
        record["sc13_eligible"] = False
        if record["status"] == "ok":
            record["status"] = "diagnostic"
    if record["status"] not in ("ok", "failed", "diagnostic", "not-measured"):
        raise BenchError("unknown case status")
    for observation in record.get("observations", []):
        observation["aggregation_eligible"] = record["status"] == "ok" and not observation.get("warmup", False)
    if record["status"] != "ok":
        if record.get("id") == "pre-push-dispatcher-ordinary":
            record["sc13_eligible"] = False
        for field in ("wall_ms", "cpu_ms", "serial_sum_p50_ms"):
            record[field] = None
        for member in record.get("members", []):
            member["wall_ms"] = None
    return record


def blocked_case(identity: Dict[str, Any], section: str, reason: str) -> Dict[str, Any]:
    return finalize_record(dict(identity, section=section, status="not-measured", blocked=True,
                                observations=[], members=[], note="blocked by an earlier sandbox-integrity failure",
                                error={"phase": "skipped-after-sandbox-integrity-failure", "type": "SandboxQuarantined",
                                       "message": reason}))


def measure(case_id: str, members: Sequence[Member], stdin: bytes, cwd: str, env: Dict[str, str],
            runs: int, warmup: int, scratch: Path, before=None, after=None,
            extra: Optional[Dict[str, Any]] = None, readiness=None) -> Dict[str, Any]:
    extra = extra or {}
    observations, walls, cpus = [], [], []
    member_walls = [[] for _ in members]
    rcs = [set() for _ in members]
    timed_out, over_registered = [0 for _ in members], [0 for _ in members]
    load_start, sample, failure = loadavg(), None, None
    kind = extra.get("readiness_kind", "proven" if readiness else "no-denial")
    for iteration in range(warmup + runs):
        deadline = time.monotonic() + COMMAND_TIMEOUT
        observation = {
            "case_id": case_id, "fixture_id": extra.get("fixture_id", "bench-fixture-v1"),
            "boundary_id": extra.get("boundary_id", case_id), "warmup": iteration < warmup,
            "exit": None, "member_exits": [], "exec_error": False,
            "readiness": False, "readiness_kind": kind, "readiness_ms": None,
            "timeout": False, "callback_timeout": False, "wall_ms": None,
        }
        phase, outcome = "before", None
        try:
            callback_call(before, deadline, iteration)
            phase = "operation"
            if not members:
                raise BenchError("no registered members")
            outcome = run_group(members, stdin, cwd, env, scratch, deadline=deadline)
            exits = [result["rc"] for result in outcome["members"]]
            observation.update(wall_ms=outcome["wall_ms"], member_exits=exits,
                               exit=next((rc for rc in exits if rc != 0), 0),
                               timeout=any(row["timed_out"] for row in outcome["members"]),
                               exec_error=any(row.get("exec_error", False) for row in outcome["members"]))
            if observation["exec_error"]:
                observation["exec_errors"] = [row.get("exec_error_message") for row in outcome["members"] if row.get("exec_error")]
            phase = "readiness"
            ready_start = time.perf_counter()
            try:
                valid = (not observation["timeout"] and not observation["exec_error"] and
                         all(rc in extra.get("expected_exit_codes", [0]) for rc in exits))
                observation["readiness"] = valid and (readiness is None or callback_call(readiness, deadline) is True)
                observation["readiness_kind"] = extra.get("readiness_kind", kind)
            finally:
                observation["readiness_ms"] = (time.perf_counter() - ready_start) * 1000.0
            if not observation["readiness"]:
                raise BenchError("incomplete readiness, unexpected exit, exec failure or timeout")
        except Exception as error:
            failure = error
            if getattr(error, "path_proof", None) is not None and isinstance(extra.get("checkout_proof"), list):
                extra["checkout_proof"].append(error.path_proof)
            observation["error"] = failure_detail(error, phase)
            observation["readiness"] = False
            if isinstance(error, CallbackTimeout):
                observation.update(callback_timeout=True, callback_timeout_phase=phase)
        finally:
            try:
                callback_call(after, deadline, iteration)
            except Exception as error:
                detail = failure_detail(error, "after")
                observation["readiness"] = False
                if failure is None:
                    failure = error
                    observation["error"] = detail
                else:
                    observation["teardown_error"] = detail
                if isinstance(error, CallbackTimeout):
                    observation.update(callback_timeout=True, callback_timeout_phase="after")
            observations.append(observation)
        if failure:
            break
        if iteration == warmup:
            sample = [{"name": member.name, "rc": result["rc"], "stdout_tail": result["stdout"],
                       "stderr_tail": result["stderr"]} for member, result in zip(members, outcome["members"])]
        if iteration < warmup:
            continue
        walls.append(observation["wall_ms"])
        cpus.append(outcome["cpu_ms"])
        for index, result in enumerate(outcome["members"]):
            member_walls[index].append(result["wall_ms"])
            rcs[index].add(result["rc"])
            timed_out[index] += int(result["timed_out"])
            limit = members[index].timeout_s
            over_registered[index] += int(limit is not None and result["wall_ms"] > limit * 1000.0)
    kind = "proven" if observations and all(row["readiness_kind"] == "proven" for row in observations) else "no-denial"
    record = dict(extra, id=case_id, runs=runs, warmup=warmup,
                  status="failed" if failure else "diagnostic" if extra.get("diagnostic") else "ok", observations=observations,
                  wall_ms=None if failure else stats(walls), cpu_ms=None if failure else stats(cpus),
                  serial_sum_p50_ms=None if failure else round(sum(percentile(w, .5) for w in member_walls if w), 1),
                  bench_cap_s=COMMAND_TIMEOUT, load_start=load_start, load_end=loadavg(),
                  first_run=sample, readiness_kind=kind, fixture_id=extra.get("fixture_id", "bench-fixture-v1"),
                  boundary_id=extra.get("boundary_id", case_id), variant=extra.get("variant", "warm"),
                  warmups_completed=sum(row["warmup"] and row["readiness"] for row in observations),
                  runs_completed=sum(not row["warmup"] and row["readiness"] for row in observations),
                  members=[dict({"name": name, "registered_timeout_s": member.timeout_s,
                                 "wall_ms": None if failure else stats(member_walls[index]),
                                 "exit_codes": sorted(rcs[index]), "runs_killed_at_bench_cap": timed_out[index],
                                 "runs_over_registered_timeout": over_registered[index]},
                                **({"native_entry": member.name} if member.fused else {}))
                           for index, member in enumerate(members)
                           for name in (member.fused or [member.name])])
    finalize_record(record)
    if failure:
        record["error"] = observations[-1]["error"]
        if "teardown_error" in observations[-1]:
            record["teardown_error"] = observations[-1]["teardown_error"]
        error = failure if isinstance(failure, BenchError) else BenchError(str(failure))
        error.record = record
        raise error
    return record


# --------------------------------------------------------------------------
# I-A4 case expansion. Kept below measure(): process timing has a separate owner.

TOOLS = TOOLS + ("MultiEdit",)
TURN_EVENTS = TURN_EVENTS + ("PreCompact", "UserPromptExpansion", "SessionEnd")
PI_LIFECYCLE = dict(PI_LIFECYCLE, session_compact="pi-session_compact.json",
                    session_shutdown="pi-session_shutdown.json", user_bash="pi-user_bash.json",
                    agent_before_settle="pi-agent_before_settle.json")
PI_HANDLER_EVENTS = tuple(PI_LIFECYCLE) + ("before_agent_start", "input", "session_before_compact")
LIFECYCLE_ITEMS = LIFECYCLE_ITEMS + (
    "git-switch-fast", "git-switch-memo-miss", "attach-new-worktree", "attach-current",
    "launcher-show-config-multi-root", "launcher-heavy-status", "launcher-heavy-check",
    "pre-push-dispatcher", "pre-push-dispatcher-ordinary", "claude WorktreeCreate", "claude WorktreeRemove",
)


def case_extra(args, fixture: str, boundary_kind: str, variant: str = "warm", **extra) -> Dict[str, Any]:
    return dict(fixture_id=fixture, boundary_id=boundary_kind, variant=variant,
                load="contended" if args.condition != "normal" else "normal", **extra)


def unmeasured(case_id: str, note: str, **extra) -> Dict[str, Any]:
    return dict(id=case_id, wall_ms=None, observations=[], registered=0, status="not-measured", note=note, **extra)


def corpus(name: str) -> List[Dict[str, Any]]:
    """Closed v1 corpus, no executable snippets or filesystem paths from data."""
    schemas = {"native-cases.json": "trellis-native-cases/1", "skill-cases.json": "trellis-skill-cases/1"}
    document = json.loads((PAYLOADS / name).read_text(encoding="utf-8"))
    if (not isinstance(document, dict) or set(document) != {"schema", "cases"} or
            document["schema"] != schemas[name] or not isinstance(document["cases"], list)):
        raise BenchError("unknown case corpus schema: " + name)
    keys = ({"id", "surfaces", "event", "tool", "payload", "patch", "fixture", "decision", "expected_exit_codes"}
            if name == "native-cases.json" else
            {"id", "name", "fixture", "bytes", "encoding", "decision", "expected_exit_codes"})
    seen = set()
    for row in document["cases"]:
        if (not isinstance(row, dict) or set(row) != keys or not isinstance(row["id"], str) or
                not re.fullmatch(r"[a-z0-9-]+", row["id"]) or row["id"] in seen):
            raise BenchError("invalid or duplicate corpus case in " + name)
        seen.add(row["id"])
        exits = row["expected_exit_codes"]
        if not isinstance(exits, list) or not exits or any(type(code) is not int for code in exits):
            raise BenchError("invalid expected exits in " + name)
        if row["decision"] not in ("allow", "warn", "deny", "unsupported"):
            raise BenchError("invalid expected decision in " + name)
        if "payload" in row:
            if (not isinstance(row["payload"], str) or Path(row["payload"]).name != row["payload"] or
                    not (PAYLOADS / row["payload"]).is_file()):
                raise BenchError("unsafe/missing corpus payload")
            if (not isinstance(row["patch"], dict) or not isinstance(row["surfaces"], list) or not row["surfaces"] or
                    any(surface not in ("claude", "codex", "pi-dispatch") for surface in row["surfaces"]) or
                    not isinstance(row["event"], str) or (row["tool"] is not None and not isinstance(row["tool"], str))):
                raise BenchError("invalid native corpus types")
            if row["fixture"] not in ("clean", "pr-branch", "reread-known", "reread-warn", "reread-block", "missing-jq", "active-python"):
                raise BenchError("unknown native fixture recipe")
        else:
            if (not isinstance(row["name"], str) or not re.fullmatch(r"[a-z0-9:-]+", row["name"]) or
                    (row["bytes"] is not None and (type(row["bytes"]) is not int or row["bytes"] < 128)) or
                    row["encoding"] not in ("utf8", "invalid-utf8") or
                    not isinstance(row["fixture"], str) or not re.fullmatch(r"skill-[a-z-]+", row["fixture"])):
                raise BenchError("invalid Skill corpus types")
    return document["cases"]


def case_matrix() -> List[Dict[str, Any]]:
    """Expand the complete candidate denominator without starting a sandbox."""
    table = json.loads((SCRIPT_DIR / "cases.json").read_text())
    if (set(table) != {"schema", "status", "hook_groups", "pi_tools", "pi_handler_events", "anchors"} or
            table["schema"] != "trellis-bench-case-table/1"):
        raise BenchError("invalid I-A4 case table")
    rows = []

    def add(case_id, fixture="clean", boundary="rendered-hook-group", owner="T2", variant="warm"):
        rows.append(dict(id=case_id, fixture_id=fixture, boundary_id=boundary, owner=owner, variant=variant))

    hooks = table["hook_groups"]
    if (tuple(hooks["tools"]) != TOOLS or tuple(hooks["events"]) != TURN_EVENTS or
            tuple(table["pi_tools"]) != tuple(PI_TOOLS) or tuple(table["pi_handler_events"]) != PI_HANDLER_EVENTS):
        raise BenchError("case table and executable families have drifted")
    for surface in hooks["surfaces"]:
        for tool in hooks["tools"]:
            for phase in hooks["phases"]:
                add(surface + " " + phase + " " + tool)
        for event in hooks["events"]:
            add(surface + " " + event)
    for row in corpus("native-cases.json"):
        for surface in row["surfaces"]:
            surfaces = ("claude", "claude R1", "claude R2") if surface == "claude" else (surface,)
            for name in surfaces:
                add(name + " " + row["event"] + (" " + row["tool"] if row["tool"] else "") + " " + row["id"],
                    row["fixture"], "pi-compatibility-dispatch" if surface == "pi-dispatch" else "rendered-hook-group")
    for row in corpus("skill-cases.json"):
        for surface in ("claude", "claude R1", "claude R2"):
            for event in ("PreToolUse Skill", "UserPromptExpansion"):
                add(surface + " " + event + " " + row["id"], row["fixture"])
    for surface, boundary in (("pi", "pi-handler"), ("pi-dispatch", "pi-compatibility-dispatch")):
        for tool in table["pi_tools"]:
            for event in ("tool_call", "tool_result"):
                add(surface + " " + event + " " + tool, boundary=boundary)
        for event in (table["pi_handler_events"] if surface == "pi" else PI_LIFECYCLE):
            add(surface + " " + event, boundary=boundary)
    for tool in ("edit", "write"):
        for shape in ("failed", "native"):
            for event in ("tool_call", "tool_result"):
                add("pi " + event + " " + tool + " " + shape, "result-" + shape, "pi-handler")
    for owner, anchored in table["anchors"].items():
        for row in anchored:
            if set(row) != {"id", "fixture_id", "boundary_id", "variant"}:
                raise BenchError("invalid anchored case row")
            add(row["id"], row["fixture_id"], row["boundary_id"], owner, row["variant"])
    if len({row["id"] for row in rows}) != len(rows):
        raise BenchError("duplicate I-A4 case ID")
    return rows


def fixture_unlink(sb, path: Path) -> None:
    """Only delete a regular fixture leaf beneath the sandbox (never follow links)."""
    if not canonical(str(path.parent)).startswith(sb.root + os.sep) or path.is_symlink():
        raise TeardownError("refusing fixture unlink outside private sandbox: " + str(path))
    if path.exists():
        if not path.is_file():
            raise TeardownError("fixture leaf is not a regular file: " + str(path))
        path.unlink()


def patch_payload(data: bytes, patch: Dict[str, Any], sb) -> bytes:
    # Top-level replacement, NOT JSON merge-patch: native shapes replace the
    # Claude-shaped tool_input/result completely, including false/null values.
    document = json.loads(data)
    text = json.dumps(patch).replace("@PROJECT@", json.dumps(sb.project)[1:-1])
    document.update(json.loads(text))
    return json.dumps(document).encode("utf-8")


def setup_skills(sb) -> None:
    collection = Path(sb.home, ".claude", "skills")
    collection.mkdir(parents=True, exist_ok=True)
    for row in corpus("skill-cases.json"):
        if row["bytes"] is None:
            continue
        names = [row["fixture"]] if row["fixture"] != "skill-ambiguous" else ["skill-ambiguous-a", "skill-ambiguous-b"]
        for directory in names:
            root = collection / directory
            root.mkdir(exist_ok=True)
            prefix = ("---\nname: " + row["name"].split(":")[-1] + "\ndescription: Deterministic bench fixture\n---\n").encode()
            data = prefix + b"x" * (row["bytes"] - len(prefix))
            if row["encoding"] == "invalid-utf8":
                data = data[:-1] + b"\xff"
            (root / "SKILL.md").write_bytes(data)


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
    # A pre-cut checkout ships the next release's native manifest before the
    # cut bumps VERSION, and the paired launcher publisher (like every real
    # install) refuses a manifest whose version is not the release's. Stamp
    # the manifest version into this private release source, as the cut does.
    stamped_from = None
    manifest = Path(release_src, "core-rules", "native", "artifacts.json")
    if manifest.is_file():
        native_version = json.loads(manifest.read_text(encoding="utf-8")).get("version")
        if isinstance(native_version, str) and native_version and native_version != version:
            stamped_from, version = version, native_version
            Path(release_src, "core-rules", "VERSION").write_text(version + "\n", encoding="utf-8")
    for args in (["init", "-q"], ["config", "user.email", "bench@example.invalid"],
                 ["config", "user.name", "Trellis Bench"], ["config", "commit.gpgsign", "false"],
                 ["config", "tag.gpgSign", "false"], ["config", "core.autocrlf", "false"],
                 ["add", "-f", "-A"], ["commit", "-qm", "release " + version]):
        sb.git(args, release_src, hooks=False)
    # Match the installed-route fixture: tag the real deletion-only payload,
    # never a native-bearing unfiltered source tree. The builder writes only
    # to this private repository, not the operator's source checkout.
    packaged = subprocess.run(["/bin/bash", str(SCRIPT_DIR.parent / "release-payload-commit.sh"), "HEAD"],
                              cwd=release_src, env=sb.env(), capture_output=True, timeout=COMMAND_TIMEOUT)
    if packaged.returncode != 0:
        raise BenchError("release payload packaging failed: " + packaged.stderr.decode(errors="replace")[-800:])
    payload_commit = packaged.stdout.decode().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", payload_commit):
        raise BenchError("release payload builder returned an invalid commit")
    sb.git(["tag", "-a", "v" + version, "-m", "release " + version, payload_commit], release_src, hooks=False)
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
    return {"mode": "checkout", "rev": rev, "commit": commit, "version": version, "source_root": release_src,
            "version_stamped_from": stamped_from}


def install_launcher_pair(sb: Sandbox, version: str, timings: Dict[str, float]) -> str:
    """Publish the launcher the way a real install does (configure/upgrade:
    trellis_home_install_launcher with HOME and RELEASE). For a native-bearing
    release that installs this host's verified companion under
    TRELLIS_HOME/bin/native and pins it in the launcher; without one it is the
    plain launcher copy. Uses the sandbox release's own verified libraries."""
    t0 = time.perf_counter()
    payload = os.path.join(sb.trellis_home, "releases", version, "payload")
    proc = subprocess.run(
        ["/bin/bash", "-c", '. "$1" && . "$2" && trellis_home_install_launcher "$3" "$4" "$5" "$6"',
         "bench-launcher-install", os.path.join(payload, "scripts", "lib", "trellis-home.sh"),
         os.path.join(payload, "scripts", "lib", "release-store.sh"),
         os.path.join(payload, "scripts", "trellis-launcher.sh"), sb.launcher, sb.trellis_home, version],
        env=sb.env(), cwd=sb.root, capture_output=True, timeout=COMMAND_TIMEOUT)
    if proc.returncode != 0:
        raise BenchError("launcher install failed ({}): {}".format(proc.returncode,
                                                                    proc.stderr.decode(errors="replace")[-800:]))
    timings["launcher_install_s"] = round(time.perf_counter() - t0, 2)
    native = Path(payload, "core-rules", "native", "artifacts.json")
    return "paired" if native.is_file() else "plain"


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
    # A valid, private management-policy fixture, distinct from the attested
    # installed runtime. An empty source directory makes show-config exit 4.
    shutil.copyfile(os.path.join(releases, version, "payload", "trellis.config.json"),
                    os.path.join(source_root, "trellis.config.json"))
    return {"mode": "installed", "rev": record.get("tag"), "commit": record.get("commit"), "version": version,
            "source_root": source_root}


def build_sandbox(base: str, source: Optional[str], rev: str) -> Sandbox:
    allocated = []
    try:
        return _build_sandbox(base, source, rev, allocated)
    except BaseException:
        for sandbox in allocated:
            remove_tree(sandbox.root)
        raise


def _build_sandbox(base: str, source: Optional[str], rev: str, allocated: list) -> Sandbox:
    root = canonical(tempfile.mkdtemp(prefix="trellis-bench.", dir=base))
    sb = Sandbox(root)
    allocated.append(sb)
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
    launcher_mode = install_launcher_pair(sb, release["version"], timings)
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
    # Untimed fixture preparation may wait for its audit. Readiness probes for
    # measured operations never turn an asynchronous return into ready success.
    if not attachment_ready(sb, sb.project, join=True):
        raise BenchError("sandbox's initial attachment is not ready")
    timings["attach_s"] = round(time.perf_counter() - t0, 2)
    sb.git(["branch", "bench-a"], sb.project, hooks=False)
    sb.meta = {"root": root, "source": source, "release_mode": release["mode"], "rev": release["rev"],
               "commit": release["commit"], "version": release["version"], "setup_seconds": timings,
               "launcher_install": launcher_mode, "version_stamped_from": release.get("version_stamped_from")}
    Path(root, "sandbox.json").write_text(json.dumps(sb.meta, indent=2) + "\n", encoding="utf-8")
    return sb


def reuse_sandbox(root: str) -> Sandbox:
    root = canonical(root)
    sb = Sandbox(root)
    sb.meta = json.loads(Path(root, "sandbox.json").read_text(encoding="utf-8"))
    sb.meta["reused"] = True
    sb.scratch.mkdir(exist_ok=True)
    return sb


def _process_birth(pid: int) -> Optional[str]:
    """The shared pid+birth identity (scripts/lib/trellis-home.sh), or None."""
    try:
        probe = subprocess.run(
            ["bash", "-c", '. "$1"; trellis_process_birth "$2"', "_",
             str(SCRIPT_DIR.parent / "lib" / "trellis-home.sh"), str(pid)],
            capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return probe.stdout.strip() if probe.returncode == 0 and probe.stdout.strip() else None


def _job_lock_pid(lock: Path) -> Optional[int]:
    """The live process holding an attach-postjob job lock (pid + birth), else None."""
    try:
        pid_text, birth = lock.joinpath("pid").read_text(encoding="utf-8").rstrip("\n").split(" ", 1)
        pid = int(pid_text)
    except (OSError, ValueError):
        return None
    if pid <= 0 or pid == os.getpid():
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except PermissionError:
        pass
    return pid if _process_birth(pid) == birth else None


def _tree_processes(root: str) -> Optional[set]:
    """Processes that can still mutate ROOT: those working inside it, and the
    attach postjobs whose pid+birth job locks live in it. Identity is never
    taken from argv text, which also matches unrelated commands that merely
    name the path. None when the process table cannot be read."""
    real = os.path.realpath(root)
    inside = lambda path: path == real or path.startswith(real.rstrip("/") + "/")
    pids = set()
    if os.path.isdir("/proc/self"):
        for entry in os.listdir("/proc"):
            if entry.isdigit():
                try:
                    if inside(os.readlink("/proc/" + entry + "/cwd")):
                        pids.add(int(entry))
                except OSError:
                    pass
    else:
        try:
            probe = subprocess.run(["lsof", "-w", "-n", "-P", "-d", "cwd", "-F", "pn"],
                                   capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            return None
        if not probe.stdout:
            return None
        pid = None
        for line in probe.stdout.splitlines():
            if line.startswith("p") and line[1:].isdigit():
                pid = int(line[1:])
            elif line.startswith("n") and pid is not None and inside(os.path.realpath(line[1:])):
                pids.add(pid)
    for lock in Path(real).glob("**/state/attachment-status/*/*.job"):
        pid = _job_lock_pid(lock)
        if pid is not None:
            pids.add(pid)
    pids.discard(os.getpid())
    return pids


def remove_tree(root: str) -> bool:
    # Never delete while detached work may still mutate this tree. Known
    # integrity failures skip cleanup entirely; ordinary cleanup also confirms
    # a bounded process drain, retaining evidence on errors or a slow exit.
    pids = _tree_processes(root)
    if pids is None:
        log("retained sandbox: process drain unavailable: " + root)
        return False
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.monotonic() + 3
    while pids:
        if time.monotonic() >= deadline:
            log("retained sandbox: process drain incomplete: " + root)
            return False
        time.sleep(.02)
        pids = _tree_processes(root)
        if pids is None:
            log("retained sandbox: process drain unavailable: " + root)
            return False
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
    return not os.path.lexists(root)


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


# The T34 hook inventory (reports/150/lean-core.md): the members each native
# entry fuses. Per tool, a native entry runs exactly the legacy registrations
# it replaced, read from the release's pinned legacy provider; this table is
# the bound they must stay within.
T34_FUSED: Dict[Tuple[str, str], Tuple[str, ...]] = {
    ("claude", "PreToolUse"): ("block-destructive", "pr-gate-shiftleft", "skill-preload-guard", "reread-guard"),
    ("claude", "UserPromptExpansion"): ("skill-slash-guard",),
    ("claude", "UserPromptSubmit"): ("turn-baseline",),
    ("claude", "PostToolUse"): ("post-edit-verify", "slop-tripwire", "track-read", "wiki-skill-suggest", "hookspath-guard"),
    ("claude", "PreCompact"): ("save-context-log",),
    ("claude", "Stop"): ("spec-gate", "decision-receipt", "stop-verify", "code-review-subagent", "ui-verify", "stamp-turn"),
    ("claude", "WorktreeCreate"): ("trellis-worktree-create",),
    ("claude", "WorktreeRemove"): ("trellis-worktree-remove",),
    ("codex", "PreToolUse"): ("block-destructive", "pr-gate-shiftleft", "reread-guard"),
    ("codex", "UserPromptSubmit"): ("turn-baseline",),
    ("codex", "PostToolUse"): ("post-edit-verify", "slop-tripwire", "track-read", "wiki-skill-suggest", "hookspath-guard"),
    ("codex", "Stop"): ("spec-gate", "save-context-log", "decision-receipt", "stop-verify", "code-review-subagent",
                        "ui-verify", "stamp-turn"),
}
NATIVE_ADAPTER = re.compile(r"trellis-hooks '([^']*/bin/native/[^']*/trellis-hooks)' '(claude|codex)' '([A-Za-z]+)'")
# T34b user worktree callbacks: a shell-form `env -i ... <companion> event-client`.
NATIVE_SHELL_CLIENT = re.compile(r"'?[^' ]*/bin/native/[^' ]*/trellis-hooks'? event-client (claude|codex) ([A-Za-z]+)")


def native_entry(argv: List[str]) -> Optional[Tuple[str, str]]:
    """(harness, event) of a rendered native registration, else None."""
    if "event-client" in argv:
        index = argv.index("event-client")
        if index > 0 and "/bin/native/" in argv[index - 1] and len(argv) > index + 2:
            return argv[index + 1], argv[index + 2]
    text = " ".join(argv)
    match = NATIVE_ADAPTER.search(text)
    if match:
        return match.group(2), match.group(3)
    match = NATIVE_SHELL_CLIENT.search(text)
    return (match.group(1), match.group(2)) if match else None


def fused_members(project: str, harness: str, event: str, tool: Optional[str],
                  payload_bytes: Optional[bytes]) -> List[str]:
    if event in ("WorktreeCreate", "WorktreeRemove"):
        name = "claude-user-settings.json"
    else:
        name = "claude-settings.local.json" if harness == "claude" else "codex-hooks.local.json"
    legacy = load_hooks(os.path.join(project, ".trellis", "runtime", "core-rules", "legacy-hooks", name))
    names = [member.name for member in matched_hooks(legacy, event, tool, project, payload_bytes)]
    inventory = T34_FUSED.get((harness, event))
    if not names or inventory is None or not set(names) <= set(inventory):
        raise BenchError("native {} {} entry has no fused members in the T34 inventory: {!r}".format(
            harness, event, names))
    return names


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
            else:
                argv = ["/bin/sh", "-c", command]
            native = native_entry(argv)
            if native is not None:
                members.append(Member("native:{} {}".format(*native), argv, hook.get("timeout"),
                                      fused=fused_members(project, native[0], native[1], tool, payload_bytes)))
            else:
                members.append(Member(hook_label(" ".join(argv) if "args" in hook else command), argv, hook.get("timeout")))
    return members


def load_hooks(path: str) -> Dict[str, Any]:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8")).get("hooks", {})
    except FileNotFoundError:
        raise BenchError("rendered hook settings missing from the attached fixture: " + path)


def wanted(case_id: str, pattern: Optional[str]) -> bool:
    return pattern is None or re.search(pattern, case_id) is not None


def claude_forms(sb: Sandbox) -> List[Tuple[str, Dict[str, Any], Dict[str, Any]]]:
    """Render both paths with the RELEASE'S renderer, never translate argv by hand.

    Selection is forced for these candidate fixtures, not by installing a fake
    Claude binary. The actual version probe and forced selection are labelled
    separately; an older/absent CLI cannot qualify R1 host support.
    """
    if hasattr(sb, "_claude_forms"):
        return sb._claude_forms
    version, version_exit = None, None
    executable = shutil.which("claude", path=sb.env()["PATH"])
    if executable:
        try:
            probe = subprocess.run([executable, "--version"], env=sb.env(), cwd=sb.root,
                                   capture_output=True, timeout=10, text=True)
            version, version_exit = probe.stdout.strip(), probe.returncode
        except subprocess.TimeoutExpired:
            version, version_exit = "version probe timed out", 124
    runtime = os.path.join(sb.project, ".trellis", "runtime")
    actual = load_hooks(os.path.join(sb.project, ".claude", "settings.local.json"))
    selected = "R1" if any("args" in hook for groups in actual.values() for group in groups
                                      for hook in group.get("hooks", [])) else "R2"
    metadata = {"claude_version": version, "claude_version_exit": version_exit,
                "historical_140_form": "R2", "minimum_r1_version": "2.1.295"}
    forms = [("claude", actual, dict(metadata, registration_form=selected, render_selection="attached"))]
    script = ('. "$1/scripts/lib/attachment.sh" || exit $?; '
              'context=$(attachment_contextual_render_context "$TRELLIS_HOME") || exit $?; '
              'attachment_claude_on_failure_supported() { return "$selection"; }; '
              'attachment_contextual_template_render "$1/core-rules/templates/claude-settings.local.json" '
              'core-rules/templates/claude-settings.local.json "$context" "$2"')
    for form, selection in (("R1", "0"), ("R2", "1")):
        # Native registrations name the project root (T34), as the attach render does.
        proc = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c", script, "bench-render", runtime, sb.project],
                              env=sb.env(selection=selection), cwd=sb.project, capture_output=True,
                              timeout=COMMAND_TIMEOUT, text=True)
        if proc.returncode != 0:
            raise BenchError("Claude {} rendering failed: {}".format(form, proc.stderr[-800:]))
        rendered = json.loads(proc.stdout)
        (sb.scratch / ("claude-" + form + ".json")).write_text(json.dumps(rendered, indent=2) + "\n")
        forms.append(("claude " + form, rendered["hooks"], dict(metadata, registration_form=form,
                      render_selection="forced-renderer-fixture", primary_sc5=form == "R1")))
    sb._claude_forms = forms
    return forms


def hook_readiness(sb: Sandbox, members: Sequence[Member], decision: str = "allow",
                   evidence: Optional[Dict[str, Any]] = None) -> bool:
    # A silent exit-zero hook is not positive evidence that it recognized the
    # payload. Preserve the Boolean callback API, but expose the proof strength.
    if evidence is not None:
        evidence["readiness_kind"] = "no-denial"
    denied = False
    warnings = False
    unsupported = False
    for index in range(len(members)):
        output = (sb.scratch / "m{}.out".format(index)).read_text(errors="replace")
        error = (sb.scratch / "m{}.err".format(index)).read_text(errors="replace")
        warnings = warnings or "reread-guard:" in error
        # Hook output is usually one document; tolerate advice before/after it
        # only for detection, not as a replacement for the protocol tests.
        for line in output.splitlines():
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if not isinstance(value, dict):
                continue
            denied = denied or value.get("decision") in ("block", "deny") or value.get("block") is True
            unsupported = unsupported or (value.get("capability_status") == "unsupported" and value.get("decision") == "allow")
            specific = value.get("hookSpecificOutput", {})
            denied = denied or (isinstance(specific, dict) and specific.get("permissionDecision") == "deny")
    ready = {"deny": denied, "warn": not denied and warnings,
             "allow": not denied, "unsupported": not denied and unsupported}.get(decision, False)
    if evidence is not None and ready and decision in ("deny", "warn", "unsupported"):
        evidence["readiness_kind"] = "proven"
    return ready


def seed_group(members, stdin, sb, env) -> None:
    outcome = run_group(members, stdin, sb.project, env, sb.scratch)
    if any(row["rc"] != 0 or row["timed_out"] for row in outcome["members"]):
        raise BenchError("fixture preparation failed: " + repr(outcome))


def missing_jq_env(sb: Sandbox, env: Dict[str, str]) -> Dict[str, str]:
    directory = Path(sb.root, "without-jq")
    directory.mkdir(exist_ok=True)
    for name in ("bash", "sh", "env", "perl", "git", "cat", "dirname", "basename", "awk", "grep", "head",
                 "tr", "cut", "mkdir", "chmod", "date", "shasum", "sha256sum", "python3", "stat", "ls", "od", "wc", "iconv"):
        source = shutil.which(name, path=env["PATH"])
        if source and not (directory / name).exists():
            (directory / name).symlink_to(source)
    return dict(env, PATH=str(directory))


def reset_reread(sb: Sandbox, harness: str) -> None:
    directory = Path(sb.project, "." + harness, ".reread-state")
    if directory.is_symlink():
        raise BenchError("reread fixture state is symlinked")
    if directory.exists():
        for path in directory.iterdir():
            fixture_unlink(sb, path)


def active_python_fixture(sb: Sandbox, event: str, env: Dict[str, str]):
    """Functional, instrumented work; NOT a qualified ruff/reviewer benchmark.

    The adapter is deliberately named for the hook's discovery ABI, but runs
    Python's real AST parser. Stop uses its existing private host-only fast
    suite setting to run real unittest assertions, without package installs.
    """
    folder = Path(sb.root, "active-python")
    folder.mkdir(exist_ok=True)
    marker = sb.scratch / "active-python.proof"
    checker = folder / "check.py"
    checker.write_text(
        "import ast, hashlib, pathlib, runpy, sys, unittest\n"
        "source = pathlib.Path(sys.argv[2])\n"
        "data = source.read_bytes()\n"
        "if sys.argv[1] == 'lint':\n"
        "    ast.parse(data, filename=str(source))\n"
        "else:\n"
        "    namespace = runpy.run_path(str(source))\n"
        "    class Addition(unittest.TestCase):\n"
        "        def test_add(self):\n"
        "            self.assertEqual(namespace['add'](2, 3), 5)\n"
        "            self.assertEqual(namespace['add'](-4, 4), 0)\n"
        "    outcome = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(Addition))\n"
        "    if not outcome.wasSuccessful() or outcome.testsRun != 1: sys.exit(1)\n"
        "pathlib.Path(sys.argv[3]).write_text(sys.argv[1] + ':' + hashlib.sha256(data).hexdigest())\n",
        encoding="utf-8")
    quote = lambda value: "'" + str(value).replace("'", "'\\''") + "'"
    adapter = folder / "ruff"
    adapter.write_text("#!/bin/sh\n[ \"$1\" = check ] || exit 2\nshift\nexec " + quote(sys.executable) +
                       " -I " + quote(checker) + " lint \"$1\" " + quote(marker) + "\n")
    adapter.chmod(0o700)
    source = Path(sb.project, "src", "b.py")
    original_source = source.read_bytes()
    config = Path(sb.trellis_home, "config.json")
    original_config = config.read_bytes()
    if event == "Stop":
        settings = json.loads(original_config)
        settings.setdefault("projects", {}).setdefault(sb.project, {}).setdefault("stop_checks", {})["fast"] = (
            quote(sys.executable) + " -I " + quote(checker) + " test " + quote(source) + " " + quote(marker))
        config.write_text(json.dumps(settings) + "\n")
        config.chmod(0o600)

    def reset() -> None:
        fixture_unlink(sb, marker)
        source.write_bytes(original_source)

    def mutate(iteration: int) -> None:
        source.write_bytes(original_source + ("\n# instrumented active observation {}\n".format(iteration)).encode())

    def ready() -> bool:
        import hashlib
        expected = ("test" if event == "Stop" else "lint") + ":" + hashlib.sha256(source.read_bytes()).hexdigest()
        return marker.is_file() and marker.read_text() == expected

    def cleanup() -> None:
        source.write_bytes(original_source)
        config.write_bytes(original_config)
        config.chmod(0o600)
        fixture_unlink(sb, marker)

    return reset, mutate, ready, cleanup, dict(env, PATH=str(folder) + os.pathsep + env["PATH"])


def bench_hook_harness(harness: str, sb: Sandbox, args, results: List[Dict[str, Any]]) -> None:
    setup_skills(sb)
    env = sb.env(**{("CLAUDE_PROJECT_DIR" if harness == "claude" else "CODEX_PROJECT_DIR"): sb.project})
    surfaces = claude_forms(sb) if harness == "claude" else [("codex", load_hooks(
        os.path.join(sb.project, ".codex", "hooks.json")), {"registration_form": "R4"})]
    for surface, hooks, metadata in surfaces:
        jobs = [(phase, tool, None) for tool in TOOLS for phase in ("PreToolUse", "PostToolUse")]
        jobs += [(event, None, None) for event in TURN_EVENTS]
        jobs += [(row["event"], row["tool"], row) for row in corpus("native-cases.json") if harness in row["surfaces"]]
        if harness == "claude":
            for row in corpus("skill-cases.json"):
                for event in ("PreToolUse", "UserPromptExpansion"):
                    jobs.append((event, "Skill" if event == "PreToolUse" else None,
                                 dict(row, payload="hook-PreToolUse-Skill.json" if event == "PreToolUse" else
                                      "hook-UserPromptExpansion.json", patch={"tool_input": {"skill": row["name"]}}
                                      if event == "PreToolUse" else {"command_name": row["name"]})))
        for event, tool, variant in jobs:
            case_id = surface + " " + event + (" " + tool if tool else "")
            if variant:
                case_id += " " + variant["id"]
            if not wanted(case_id, args.hooks):
                continue
            fixture = variant["fixture"] if variant else "clean"
            extra = case_extra(args, fixture, "rendered-hook-group", section=harness, harness=harness,
                               event=event, tool=tool, **metadata)
            # SessionEnd and Codex PreCompact/expansion remain genuinely N/A.
            members = matched_hooks(hooks, event, tool, sb.project)
            if not members:
                results.append(unmeasured(case_id, "N/A: no registered matcher; no synthetic registration added", **extra))
                continue
            filename = variant["payload"] if variant else "hook-{}{}.json".format(event, "-" + tool if tool else "")
            stdin = payload(filename, sb)
            if variant:
                stdin = patch_payload(stdin, variant["patch"], sb)
            # Re-evaluate Claude's conditional matcher using the actual payload.
            members = matched_hooks(hooks, event, tool, sb.project, stdin)
            if not members:
                results.append(unmeasured(case_id, "no hook selected by the rendered conditional matcher", **extra))
                continue
            active = active_python_fixture(sb, event, env) if fixture == "active-python" else None
            if active:
                extra.update(timing_claim_eligible=False, fixture_toolchain="instrumented AST adapter / real Python unittest via host fast-suite config",
                             reviewer="not exercised; below review threshold", functional_proofs=[])
                stdin = patch_payload(stdin, {"tool_input": {"file_path": sb.project + "/src/b.py"}}, sb) if event != "Stop" else patch_payload(
                    stdin, {"last_assistant_message": 'Fixture structural receipt input only: <!-- dod-receipt cmd="fixture unittest" exit=0 diff="+1/-0 (1 files)" --> <!-- follow-ups: none -->'}, sb)
            run_env = active[4] if active else missing_jq_env(sb, env) if fixture == "missing-jq" else env
            expectation = variant["decision"] if variant else "allow"
            if variant:
                extra["expected_exit_codes"] = variant["expected_exit_codes"]
            extra.update(registered=len(members), expected_decision=expectation, readiness_kind="no-denial")
            restore_branch = fixture == "pr-branch"
            if restore_branch:
                sb.git(["switch", "-q", "bench-a"], sb.project, hooks=False)
                sb.git(["config", "--unset-all", "branch.bench-a.trellisPrBase"], sb.project, check=False, hooks=False)

            def before(_i: int) -> None:
                extra["readiness_kind"] = "no-denial"
                if restore_branch:
                    # Require a fresh branch-base write on every observation.
                    sb.git(["config", "--unset-all", "branch.bench-a.trellisPrBase"], sb.project, check=False, hooks=False)
                if active:
                    active[0]()
                if event == "Stop":
                    seed_group(matched_hooks(hooks, "UserPromptSubmit", None, sb.project),
                               payload("hook-UserPromptSubmit.json", sb), sb, env)
                if active:
                    active[1](_i)
                if event == "PreToolUse" and tool in ("Edit", "MultiEdit", "Write"):
                    reset_reread(sb, harness)
                    if fixture not in ("reread-warn", "reread-block", "missing-jq"):
                        read = payload("hook-PostToolUse-Read.json", sb)
                        seed_group(matched_hooks(hooks, "PostToolUse", "Read", sb.project, read), read, sb, env)
                    elif fixture == "reread-block":
                        for _ in range(2):
                            seed_group(members, stdin, sb, env)

            def ready() -> bool:
                if not hook_readiness(sb, members, expectation, evidence=extra):
                    return False
                if active:
                    if not active[2]():
                        return False
                    extra["functional_proofs"].append((sb.scratch / "active-python.proof").read_text())
                    extra["readiness_kind"] = "proven"
                if event == "PreCompact" and not Path(sb.project, "context-log.md").is_file():
                    return False
                if fixture == "pr-branch":
                    recorded = sb.git(["config", "--get", "branch.bench-a.trellisPrBase"], sb.project,
                                      check=False, hooks=False).stdout.decode().strip()
                    if recorded != "main":
                        return False
                    extra["readiness_kind"] = "proven"
                return True

            try:
                results.append(measure(case_id, members, stdin, sb.project, run_env, args.runs, args.warmup,
                                       sb.scratch, before=before, readiness=ready, extra=extra))
            finally:
                if active:
                    active[3]()
                if restore_branch:
                    sb.git(["config", "--unset-all", "branch.bench-a.trellisPrBase"], sb.project, check=False, hooks=False)
                    sb.git(["switch", "-q", "main"], sb.project, hooks=False)


def samples_record(case_id: str, values: List[float], runs: int, warmup: int, load_start: List[float],
                   extra: Dict[str, Any]) -> Dict[str, Any]:
    record = {"id": case_id, "runs": runs, "warmup": warmup, "wall_ms": stats(values), "cpu_ms": None,
              "load_start": load_start, "load_end": loadavg(), "members": [], "first_run": None,
              "status": "ok", "readiness_kind": "no-denial"}
    record.update(extra)
    return record


def bench_pi(sb: Sandbox, args, results: List[Dict[str, Any]]) -> None:
    """Consume independent worker observations, NOT inferred pre/post totals."""
    setup_skills(sb)
    runner = str(SCRIPT_DIR / "pi-handler-runner.mjs")
    env = sb.env()
    node = shutil.which("node", path=env["PATH"])
    base = {"section": "pi", "harness": "pi", "boundary": "trellis.ts handler", "path": "extension handler"}
    jobs = [("tool", tool, "text") for tool in PI_TOOLS]
    jobs += [("tool", tool, shape) for tool in ("edit", "write") for shape in ("failed", "native")]
    jobs += [("event", event, "text") for event in PI_HANDLER_EVENTS]
    for kind, name, shape in jobs:
        events = ["tool_call", "tool_result"] if kind == "tool" else [name]
        suffix = "" if shape == "text" else " " + shape
        ids = ["pi " + event + (" " + name if kind == "tool" else "") + suffix for event in events]
        selected = [(case_id, event) for case_id, event in zip(ids, events) if wanted(case_id, args.hooks)]
        if not selected:
            continue
        extra = case_extra(args, "clean" if shape == "text" else "result-" + shape, "pi-handler", **base)

        def row_extra(event: str) -> Dict[str, Any]:
            metadata = dict(extra, event=event, tool=name if kind == "tool" else None)
            if kind == "tool" and shape != "text" and event == "tool_call":
                metadata["alias_of"] = "pi tool_call " + name
            return metadata

        if node is None:
            for case_id, event in selected:
                results.append(unmeasured(case_id, "node is not on PATH", **row_extra(event)))
            continue
        load_start = loadavg()
        try:
            proc = subprocess.run([node, "--no-warnings", runner, "--project", sb.project, "--session-file",
                                   sb.transcript, "--runs", str(args.runs), "--warmup", str(args.warmup),
                                   "--result-shape", shape, "--skill-path", str(Path(sb.home, ".claude", "skills", "skill-known", "SKILL.md")),
                                   "--" + kind, name], cwd=sb.project, env=env, capture_output=True,
                                  timeout=COMMAND_TIMEOUT)
            runner_exit = proc.returncode
            try:
                report = json.loads(proc.stdout.decode().strip().splitlines()[-1])
                if not isinstance(report, dict):
                    raise ValueError("runner report is not an object")
            except (ValueError, IndexError):
                report = dict(failed=True, error="pi runner returned no valid report: " +
                              proc.stderr.decode(errors="replace")[-800:])
        except subprocess.TimeoutExpired:
            runner_exit = 124
            report = dict(failed=True, error_kind="timeout", error="pi coordinator timed out")
        except OSError as error:
            runner_exit = 127
            report = dict(failed=True, exec_error=True, error="pi coordinator could not run: " + str(error))
        # Exit 3 alone is not an exemption. Only the independent host probe may
        # identify absent TS support; extension import/factory failures are fatal.
        runtime_absent = (runner_exit == 3 and report.get("runtime_supported") is False and
                          report.get("error_kind") == "unsupported-typescript-runtime" and not report.get("failed") and
                          report.get("observations") == [])
        optional_absent = (kind == "event" and name == "agent_before_settle" and runner_exit == 0 and
                           report.get("registered") is False and report.get("missing_handlers") == [name] and
                           not report.get("failed") and report.get("observations") == [])
        if runtime_absent or optional_absent:
            for case_id, event in selected:
                results.append(unmeasured(case_id, "TypeScript runtime unavailable on this host" if runtime_absent else
                                          "optional agent_before_settle handler is not registered", **row_extra(event)))
            continue
        raw = report.get("observations", [])
        malformed = not isinstance(raw, list) or any(not isinstance(row, dict) for row in raw)
        raw = [] if malformed else raw
        failures = []
        for case_id, event in selected:
            observations = [dict(row) for row in raw if row.get("event") == event]
            for row in observations:
                row.setdefault("exec_error", False)
                row.setdefault("readiness_kind", "no-denial")
            complete = (len(observations) == args.runs + args.warmup and
                        all(type(row.get("warmup")) is bool for row in observations) and
                        [row.get("warmup") for row in observations] == [True] * args.warmup + [False] * args.runs)
            sound = all(row.get("case_id") == case_id and row.get("fixture_id") == extra["fixture_id"] and
                        row.get("boundary_id") == extra["boundary_id"] and type(row.get("exit")) is int and row["exit"] == 0 and
                        isinstance(row.get("member_exits"), list) and bool(row["member_exits"]) and
                        all(type(code) is int and code == 0 for code in row["member_exits"]) and
                        type(row.get("exec_calls", 0)) is int and row.get("exec_calls", 0) >= 0 and
                        row.get("timeout") is False and row.get("exec_error") is False and
                        not row.get("transport_failed") and not row.get("blocked") and
                        row.get("readiness_kind") in ("proven", "no-denial") and
                        isinstance(row.get("wall_ms"), (int, float)) and not isinstance(row.get("wall_ms"), bool) and
                        0 <= row["wall_ms"] < float("inf") for row in observations)
            unsupported = bool(observations) and all(row.get("unsupported") is True for row in observations)
            valid = (not malformed and complete and sound and runner_exit == 0 and not report.get("failed") and
                     report.get("registered") is True and
                     (unsupported or all(row.get("readiness") is True for row in observations)))
            values = [row["wall_ms"] for row in observations if not row["warmup"]] if valid and not unsupported else []
            readiness_kind = "proven" if valid and all(row["readiness_kind"] == "proven" for row in observations) else "no-denial"
            exec_calls = sum(row.get("exec_calls", 0) for row in observations if type(row.get("exec_calls", 0)) is int)
            record = samples_record(case_id, values, args.runs, args.warmup, load_start,
                                    dict(row_extra(event), observations=observations, expected_exit_codes=[0],
                                         registered=int(report.get("registered") is True), runner_exit=runner_exit,
                                         readiness_kind=readiness_kind, exec_error=bool(report.get("exec_error")),
                                         runner_error_kind=report.get("error_kind"),
                                         exec_calls=exec_calls,
                                         exec_calls_per_run=exec_calls / len(observations) if observations else None,
                                         blocked_runs=sum(bool(row.get("blocked")) for row in observations)))
            if not valid:
                record.update(note=report.get("error", "blocked, failed or incomplete handler observations"))
                finalize_record(record, "failed")
                failures.append(record)
            elif unsupported:
                record.update(note="unsupported baseline capability; raw observations are diagnostic only")
                finalize_record(record, "diagnostic")
            results.append(record)
        if failures:
            error = BenchError("pi handler observation failed: " + failures[0]["id"])
            error.record = failures[0]
            raise error


def pi_event_files(sb: Sandbox, name: str, data: Optional[bytes] = None):
    """Recreate trellis.ts's transport per call: fresh 0700 dir, 0600 event file."""
    data = payload(name, sb) if data is None else data
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
    base = case_extra(args, "clean", "pi-compatibility-dispatch", section="pi-dispatch", harness="pi", boundary="dispatch-only")
    cases: List[Tuple[str, Optional[str], Dict[str, Any]]] = []
    for tool, phases in PI_TOOLS.items():
        for event, name in phases.items():
            cases.append(("pi-dispatch {} {}".format(event, tool), name, dict(base, event=event, tool=tool)))
    for event, name in PI_LIFECYCLE.items():
        cases.append(("pi-dispatch {}".format(event), name, dict(base, event=event, tool=None)))
    for row in corpus("native-cases.json"):
        if "pi-dispatch" in row["surfaces"]:
            cases.append(("pi-dispatch {} {} {}".format(row["event"], row["tool"], row["id"]), row["payload"],
                          dict(base, event=row["event"], tool=row["tool"], corpus_case=row)))
    for case_id, name, extra in cases:
        if not wanted(case_id, args.hooks):
            continue
        if name is None:
            results.append(unmeasured(case_id, "trellis.ts decides this pre-action in-process (localPreAction); no dispatcher call",
                                      path="in-process", **extra))
            continue
        variant = extra.pop("corpus_case", None)
        data = patch_payload(payload(name, sb), variant["patch"], sb) if variant else payload(name, sb)
        if variant:
            extra.update(fixture_id=variant["fixture"], expected_exit_codes=variant["expected_exit_codes"],
                         expected_decision=variant["decision"])
        prepare, after, state = pi_event_files(sb, name, data)
        member = Member(case_id, lambda state=state: [dispatcher, "--event-file", state["file"]], 300.0)
        verdict: Dict[str, Any] = {}
        decision_evidence: List[Dict[str, Any]] = []
        extra.update(path="dispatch.sh", readiness_kind="no-denial", decision_evidence=decision_evidence)

        def before(iteration: int) -> None:
            extra["readiness_kind"] = "no-denial"
            prepare(iteration)

        def ready() -> bool:
            extra["readiness_kind"] = "no-denial"
            verdict.clear()
            try:
                value = json.loads((sb.scratch / "m0.out").read_text())
            except (OSError, ValueError):
                return False
            if not isinstance(value, dict):
                return False
            verdict.update(value)
            capability = verdict.get("capability_status")
            decision = verdict.get("decision")
            # Unsupported is a capability, not a wire decision. It matches the
            # corpus only as an explicit unsupported/allow pair, never as a
            # supported allow (or a malformed unsupported deny/warn).
            if (verdict.get("schema_version") != 1 or decision not in ("allow", "warn", "deny") or
                    capability not in ("enforced", "advisory", "unsupported") or
                    (capability == "unsupported" and decision != "allow")):
                return False
            observed = "unsupported" if capability == "unsupported" else decision
            decision_evidence.append(dict(verdict, observed_decision=observed))
            expected = extra.get("expected_decision")
            matched = observed == expected if expected is not None else observed in ("allow", "warn", "unsupported")
            if matched:
                extra["readiness_kind"] = "proven"
            return matched

        record = measure(case_id, [member], b"", sb.project, env, args.runs, args.warmup, sb.scratch,
                         before=before, after=after, readiness=ready, extra=extra)
        if verdict.get("capability_status") == "unsupported":
            record.update(note="unsupported baseline capability; observations are dispatch-only diagnostics")
            finalize_record(record, "diagnostic")
        results.append(record)


# --------------------------------------------------------------------------
# Lifecycle


def registry_worktree(sb: Sandbox, root: str) -> Optional[Tuple[str, str, Optional[str]]]:
    """(checkout_id, worktree_id, bound attachment_id or None) of root's registry row, or None."""
    try:
        registry = json.loads(Path(sb.trellis_home, "registry.json").read_text(encoding="utf-8"))
        rows = [(checkout_id, worktree_id, row.get("attachment_id"))
                for project in registry["projects"].values()
                for checkout_id, checkout in project["checkouts"].items()
                for worktree_id, row in checkout["worktrees"].items() if row["root"] == root]
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        raise TeardownError("unreadable registry {}: {!r}".format(sb.trellis_home, exc))
    if len(rows) > 1:
        raise TeardownError("{} registry rows for {}".format(len(rows), root))
    return rows[0] if rows else None


# How long a just-spawned attach postjob may take to take its lock.
JOB_START_GRACE_S = 30.0


def join_postjob(sb: Sandbox, root: str, checkout_id: str, worktree_id: str, owner: str) -> None:
    """Wait for root's detached attach postjob to exit; it must have recorded ok for this owner."""
    # The job holds <status dir>/<worktree>.job with its pid + birth for its
    # whole run and removes it on exit; wait on that identity, never on argv.
    lock = Path(sb.trellis_home, "state", "attachment-status", checkout_id, worktree_id + ".job")
    status = Path(sb.trellis_home, "state", "attachment-status", checkout_id, worktree_id + ".json")

    def unsettled() -> bool:
        try:
            return json.loads(status.read_text(encoding="utf-8")).get("state") in ("pending", "running")
        except (OSError, ValueError):
            return True
    # T14 amended: attach returns once the job is spawned, so the detached job
    # may not hold its lock yet. Join while a job holds the lock; while the
    # verdict is unsettled and no job has been seen yet, allow it
    # JOB_START_GRACE_S to start. A job that ended, or never started, with
    # the verdict still pending falls through to the "ended pending" refusal.
    deadline = time.monotonic() + COMMAND_TIMEOUT
    start_by = time.monotonic() + JOB_START_GRACE_S
    seen = False
    while True:
        if os.path.lexists(lock) and _job_lock_pid(lock) is not None:
            seen = True
        elif not unsettled() or seen or time.monotonic() > start_by:
            break
        if time.monotonic() > deadline:
            raise TeardownError("attach postjob for {} still running after {:.0f} s".format(root, COMMAND_TIMEOUT))
        time.sleep(0.05)
    try:
        attachment_id = json.loads(Path(owner).read_text(encoding="utf-8"))["attachment_id"]
        record = json.loads(status.read_text(encoding="utf-8"))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise TeardownError("no attach postjob verdict for {}: {!r}".format(root, exc))
    if record.get("state") != "ok" or record.get("attachment_id") != attachment_id:
        raise TeardownError("attach postjob for {} ended {} (attachment {}, live {}): {}".format(
            root, record.get("state"), record.get("attachment_id"), attachment_id,
            tail(status.with_suffix(".log"))))


def teardown_worktree(sb: Sandbox, path: str, branch: str, attached: bool) -> None:
    """Return the fixture to its one attached checkout after a git-worktree-add sample.

    An attached worktree is detached through the sandbox launcher once its
    attach postjob has finished; its owner record and registry binding must be
    gone before the worktree and branch are removed, and its registry row after.
    Removing it any other way orphans the owner record, and every later attach
    in the checkout exits 3. A failure raises TeardownError, which keeps the
    sandbox as evidence.
    """
    def launcher(argv: List[str]) -> None:
        proc = subprocess.run([sb.launcher] + argv, cwd=sb.project, env=sb.env(), capture_output=True,
                              timeout=COMMAND_TIMEOUT)
        if proc.returncode != 0:
            raise TeardownError("trellis {} exited {}: {}".format(" ".join(argv), proc.returncode,
                                                                  proc.stderr.decode(errors="replace")[-800:]))

    row = registry_worktree(sb, path)
    if (row is not None) != attached:
        raise TeardownError("{} is {}registered after a hooks-{} worktree add".format(
            path, "" if row else "not ", "on" if attached else "off"))
    if row is not None:
        checkout_id, worktree_id, _ = row
        owner = os.path.join(sb.trellis_home, "state", "attachments", checkout_id, worktree_id + ".json")
        join_postjob(sb, path, checkout_id, worktree_id, owner)
        launcher(["detach", path])
        if os.path.lexists(owner):
            raise TeardownError("owner record survived trellis detach: " + owner)
        row = registry_worktree(sb, path)
        if row is None or row[2] is not None:
            raise TeardownError("trellis detach left registry row {!r} for {}".format(row, path))
    for args in (["worktree", "remove", path], ["branch", "-D", branch]):
        proc = sb.git(args, sb.project, check=False, hooks=False)
        if proc.returncode != 0:
            raise TeardownError("git {} exited {}: {}".format(" ".join(args), proc.returncode,
                                                             proc.stderr.decode(errors="replace")[-600:]))
    if attached:
        launcher(["registry", "deregister", "--fleet", "personal", "--worktree-root", path])
        if registry_worktree(sb, path) is not None:
            raise TeardownError("registry row survived trellis registry deregister: " + path)


def checkout_hook_proof(sb: Sandbox, member: Member, env: Dict[str, str]) -> Dict[str, Any]:
    """Untimed positive trace2 proof for the exact argv used by the timed row."""
    import hashlib
    argv = member.command()
    original = sb.git(["symbolic-ref", "--short", "HEAD"], sb.project, hooks=False).stdout.decode().strip()
    hook = Path(sb.git(["config", "--get", "core.hooksPath"], sb.project).stdout.decode().strip(), "post-checkout")
    source_hash = hashlib.sha256(hook.read_bytes()).hexdigest()
    fd, filename = tempfile.mkstemp(prefix="checkout-trace2-", suffix=".jsonl", dir=str(sb.scratch))
    os.close(fd)
    interrupted = False
    try:
        process = subprocess.run(argv, cwd=sb.project, env=dict(env, GIT_TRACE2_EVENT=filename),
                                 capture_output=True, timeout=COMMAND_TIMEOUT)
        events = [json.loads(line) for line in Path(filename).read_text().splitlines()]
        starts = [event for event in events if event.get("event") == "child_start" and
                  event.get("child_class") == "hook" and event.get("hook_name") == "post-checkout" and
                  event.get("argv", [None])[0] == str(hook)]
        exits = [event for event in events if event.get("event") == "child_exit" and event.get("code") == 0 and
                 event.get("child_id") in {start["child_id"] for start in starts}]
        if (process.returncode != 0 or not starts or not exits or
                hashlib.sha256(hook.read_bytes()).hexdigest() != source_hash):
            raise BenchError("exact checkout argv did not execute the expected post-checkout hook successfully")
        member.verified_argv = tuple(argv)
        return {"kind": "untimed-exact-argv-trace2", "hook_ran": True, "hook_exit": 0,
                "hook_path": str(hook), "hook_sha256": source_hash, "argv": argv,
                "trace_file": filename, "trace_sha256": hashlib.sha256(Path(filename).read_bytes()).hexdigest()}
    except (CallbackTimeout, KeyboardInterrupt, SystemExit):
        interrupted = True
        raise
    finally:
        # SIGALRM is one-shot. Once it fired, starting another cleanup/join
        # here would outlive the shared deadline; quarantine retains the tree.
        if not interrupted:
            sb.git(["switch", "-q", original], sb.project, hooks=False)
            attachment_ready(sb, sb.project, join=True)


def checkout_snapshot(sb: Sandbox) -> Dict[str, Any]:
    """Bind checkout classification to the real memo, dispatcher and audit writes."""
    import hashlib
    def digest(path):
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()
    checkout, worktree, _ = registry_worktree(sb, sb.project)
    managed = Path(sb.trellis_home, "state", "git-hooks", checkout)
    owner = Path(sb.trellis_home, "state", "attachments", checkout, worktree + ".json")
    status = Path(sb.trellis_home, "state", "attachment-status", checkout, worktree + ".json")
    memos = []
    for path in Path(sb.trellis_home, "state", "hook-digests").glob("*.json"):
        value = json.loads(path.read_text())
        if canonical(value["payload"]) != canonical(str(Path(sb.project, ".trellis/runtime"))):
            continue
        valid = (not path.is_symlink() and stat.S_IMODE(path.stat().st_mode) == 0o600 and
                 value["post_checkout"] == digest(managed / "post-checkout") and
                 value["pre_push"] == digest(managed / "pre-push"))
        memos.append({"path": str(path), "sha256": digest(path), "valid": valid})
    return {"memos": memos, "memo_valid": len(memos) == 1 and memos[0]["valid"],
            "owner_sha256": digest(owner), "postjob_sha256": digest(status),
            "dispatcher_sha256": digest(managed / "post-checkout")}


def checkout_memo_reproof(sb: Sandbox, before: Dict[str, Any], after: Dict[str, Any]) -> Dict[str, Any]:
    """Untimed missing-only readiness: full canonical proof and generator agreement.

    A driver copies the installed predicate, not its behavior, into private
    scratch. Its managed_dispatcher binding still names the unchanged installed
    hook, so the exact hook-set check sees no extra files. This is a readiness
    reproof, not a claim that internal T17 spans were observed in the timed hook.
    """
    import hashlib
    import secrets
    import shlex

    proof = {"kind": "untimed-canonical-current-worktree-and-generator", "full_proof_ran": False,
             "full_proof_succeeded": False, "generator_verified": False, "memo_rewritten": False}

    def refuse(message: str) -> None:
        error = BenchError(message)
        error.path_proof = {"path": "unknown", "memo_repair": dict(proof)}
        raise error

    def digest(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    if before.get("memos") or not after.get("memo_valid") or len(after.get("memos", [])) != 1:
        refuse("missing-only memo repair requires absent-before and valid rewritten memo")
    memo = Path(after["memos"][0]["path"])
    record = json.loads(memo.read_text(encoding="utf-8"))
    checkout, _, _ = registry_worktree(sb, sb.project)
    hook = Path(sb.trellis_home, "state", "git-hooks", checkout, "post-checkout")
    payload = Path(canonical(str(Path(sb.project, ".trellis/runtime"))))
    library = payload / "scripts/lib/attachment.sh"
    for source in (memo, hook, library):
        if not canonical(str(source)).startswith(sb.root + os.sep) or not source.is_file():
            refuse("memo reproof source outside private sandbox: " + str(source))
    source_hashes = {str(source): digest(source) for source in (memo, hook, library)}
    proof.update(memo_rewritten=True, installed_sources=source_hashes, memo_sha256=digest(memo))
    original = hook.read_text(encoding="utf-8")
    marker = "# Git passes 0 as the third argument for a file checkout"
    binding = 'managed_dispatcher="${TRELLIS_MANAGED_DISPATCHER:?}"'
    if original.count(marker) != 1 or original.count(binding) != 1:
        refuse("unsupported installed full-proof driver seams")
    directory = Path(tempfile.mkdtemp(prefix="memo-reproof-", dir=str(sb.scratch)))
    token = "A4-FULL-PROOF-" + secrets.token_hex(32)
    driver = directory / "full-proof.sh"
    prefix = original.split(marker, 1)[0].replace(binding, "managed_dispatcher=" + shlex.quote(str(hook)), 1)
    driver.write_text(prefix + '\ntrellis_enter_command_scratch\nif trellis_worktree_current "$@"; then\n'
                      + "  printf '%s\\n' " + shlex.quote(token) + '\nelse\n  exit 1\nfi\n', encoding="utf-8")
    driver.chmod(0o700)
    head = sb.git(["rev-parse", "HEAD"], sb.project, hooks=False).stdout.decode().strip()
    process = subprocess.run(["/bin/bash", str(driver), head, head, "1"], cwd=sb.project, env=sb.env(),
                             capture_output=True, timeout=COMMAND_TIMEOUT)
    (directory / "full-proof.stdout").write_bytes(process.stdout)
    (directory / "full-proof.stderr").write_bytes(process.stderr)
    proof.update(full_proof_ran=True, full_proof_exit=process.returncode, driver_sha256=digest(driver),
                 evidence_directory=str(directory))
    if process.returncode != 0 or process.stdout.decode(errors="replace").splitlines().count(token) != 1:
        refuse("canonical full current-worktree reproof did not succeed")
    proof["full_proof_succeeded"] = True
    expected_home = directory / "expected-home"
    expected_home.mkdir(mode=0o700)
    # The canonical writer creates hook-digests, not its state parent. A
    # normal Trellis home already has state; this isolated generator home must
    # establish the same private precondition without touching the real memo.
    (expected_home / "state").mkdir(mode=0o700)
    generation = subprocess.run(["/bin/bash", "-c",
        '. "$1" || exit $?; _attachment_hooks_digest_memo_write "$2" "$3" "$4" "$5"',
        "bench-verified-memo-generator", str(library), str(expected_home), str(payload),
        record["manifest_sha256"], record["pre_push_source"]], cwd=sb.project, env=sb.env(),
        capture_output=True, timeout=COMMAND_TIMEOUT)
    (directory / "generator.stdout").write_bytes(generation.stdout)
    (directory / "generator.stderr").write_bytes(generation.stderr)
    generated = list((expected_home / "state/hook-digests").glob("*.json"))
    proof["generator_exit"] = generation.returncode
    if (generation.returncode != 0 or len(generated) != 1 or
            json.loads(generated[0].read_text(encoding="utf-8")) != record or
            any(digest(Path(path)) != checksum for path, checksum in source_hashes.items())):
        refuse("rewritten memo does not match the unchanged verified generator")
    proof["generator_verified"] = True
    return proof


def checkout_path_proof(sb: Sandbox, before: Dict[str, Any], expected: Optional[str] = None,
                        repair_proof: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    after = checkout_snapshot(sb)
    stable = all(before[key] == after[key] for key in ("owner_sha256", "postjob_sha256", "dispatcher_sha256", "memos"))
    hook_ran = before.get("hook_execution", {}).get("hook_ran") is True
    if hook_ran and before["memo_valid"] and after["memo_valid"] and stable:
        path = "fast"
    elif hook_ran and after["memo_valid"] and before["postjob_sha256"] != after["postjob_sha256"]:
        path = "full-reconcile"
    elif (hook_ran and not before["memos"] and after["memo_valid"] and repair_proof and
          all(repair_proof.get(key) is True for key in
              ("full_proof_ran", "full_proof_succeeded", "generator_verified", "memo_rewritten")) and
          all(before[key] == after[key] for key in ("owner_sha256", "postjob_sha256", "dispatcher_sha256"))):
        path = "verified-generator-rebuild"
    else:
        path = "unknown"
    proof = {"path": path, "kind": "verified-memo-and-audit-effects", "before": before, "after": after}
    if repair_proof is not None:
        proof["memo_repair"] = repair_proof
    repair_ready = (repair_proof is not None and not before["memos"] and after["memo_valid"] and
                    all(repair_proof.get(key) is True for key in
                        ("full_proof_ran", "full_proof_succeeded", "generator_verified", "memo_rewritten")))
    matches = (path in ("full-reconcile", "verified-generator-rebuild") and repair_ready
               if expected == "memo-repair" else expected is None or path == expected)
    if path == "unknown" or not matches:
        error = BenchError("post-checkout path {} did not match {}".format(path, expected or "fast/full-reconcile"))
        error.path_proof = proof
        raise error
    return proof


def bench_lifecycle(sb: Sandbox, args, results: List[Dict[str, Any]]) -> None:
    runs = args.lifecycle_runs
    items = args.lifecycle_items
    env = sb.env()
    base = case_extra(args, "clean", "installed-launcher-or-git", section="lifecycle")

    def launcher(item: str, argv: List[str], cwd: str) -> None:
        if item in items:
            results.append(measure(item, [Member(item, [sb.launcher] + argv)], b"", cwd, env, runs, args.warmup,
                                   sb.scratch, extra=dict(base, command="trellis " + " ".join(argv))))

    launcher("launcher-version", ["--version"], sb.root)
    launcher("launcher-help", ["help"], sb.root)
    launcher("launcher-show-config", ["show-config"], sb.project)
    launcher("launcher-heavy", ["heavy", "--lane", "bench", "--", "true"], sb.project)
    launcher("launcher-heavy-status", ["heavy", "--status"], sb.project)
    launcher("launcher-heavy-check", ["heavy", "--check"], sb.project)

    for harness, settings, project_var in (
            ("claude", os.path.join(sb.project, ".claude", "settings.local.json"), "CLAUDE_PROJECT_DIR"),
            ("codex", os.path.join(sb.project, ".codex", "hooks.json"), "CODEX_PROJECT_DIR")):
        item = "session-start-" + harness
        if item not in items:
            continue
        members = matched_hooks(load_hooks(settings), "SessionStart", None, sb.project)
        hook_env = sb.env(**{project_var: sb.project})
        results.append(measure(item, members, payload("hook-SessionStart.json", sb), sb.project, hook_env,
                               runs, args.warmup, sb.scratch, extra=dict(base, harness=harness, event="SessionStart")))

    def git_member(name: str, git_args: Any, hooks: bool = True) -> Member:
        prefix = ["git"] + ([] if hooks else ["-c", "core.hooksPath=/dev/null"])
        if callable(git_args):
            return Member(name, lambda: prefix + git_args())
        return Member(name, prefix + git_args)

    if "git-switch" in items:
        sb.git(["switch", "-q", "main"], sb.project, hooks=False)
        for hooks in (False, True):
            sb.git(["switch", "-q", "main"], sb.project, hooks=False)
            name = "git-switch" + ("" if hooks else " (hooks off)")
            state = {"next": "bench-a"}
            proofs = []

            def before(_i: int, state=state) -> None:
                state["argv"] = state["next"]
                if hooks:
                    attachment_ready(sb, sb.project, join=True)
                    hook_proof = checkout_hook_proof(sb, member, env)
                    state["checkout_before"] = dict(checkout_snapshot(sb), hook_execution=hook_proof)

            def ready() -> bool:
                attachment_ready(sb, sb.project, join=True)
                proofs.append(checkout_path_proof(sb, state["checkout_before"]))
                return True

            def after(_i: int, state=state) -> None:
                state["next"] = "main" if state["next"] == "bench-a" else "bench-a"

            member = git_member(name, lambda state=state: ["switch", "-q", state["argv"]], hooks)
            results.append(measure(name, [member], b"", sb.project, env, runs, args.warmup, sb.scratch, before, after,
                                   readiness=ready if hooks else None,
                                   extra=dict(base, hooks=hooks, checkout_proof=proofs)))
        sb.git(["switch", "-q", "main"], sb.project, hooks=False)

    if "git-checkout-file" in items:
        readme = Path(sb.project, "README.md")

        def dirty(_i: int) -> None:
            readme.write_text(FIXTURE_FILES["README.md"] + "changed\n", encoding="utf-8")

        for hooks in (False, True):
            name = "git-checkout-file" + ("" if hooks else " (hooks off)")
            results.append(measure(name, [git_member(name, ["checkout", "--", "README.md"], hooks)], b"",
                                   sb.project, env, runs, args.warmup, sb.scratch, before=dirty,
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

            def after(_i: int, state=state, hooks=hooks) -> None:
                teardown_worktree(sb, state["path"], state["branch"], attached=hooks)

            member = git_member(name, lambda state=state: ["worktree", "add", "-q", "-b", state["branch"],
                                                           state["path"]], hooks)
            record = measure(name, [member], b"", sb.project, env, runs, args.warmup, sb.scratch, before, after,
                             readiness=(lambda: attachment_ready(sb, state["path"])) if hooks else None,
                             extra=dict(base, hooks=hooks, **({"sc1_eligible": False,
                                   "timing_scope": "completion-readiness-diagnostic-only"} if hooks else {})))
            if hooks:
                record.update(note="no event-driven ready-worktree completion boundary")
                finalize_record(record, "diagnostic")
            results.append(record)

    bench_lifecycle_expansion(sb, args, results)


def attachment_ready(sb: Sandbox, root: str, join: bool = True) -> bool:
    row = registry_worktree(sb, root)
    if row is None or row[2] is None:
        raise BenchError("readiness: missing registered attachment")
    checkout, worktree, attachment = row
    owner = Path(sb.trellis_home, "state", "attachments", checkout, worktree + ".json")
    if join:
        join_postjob(sb, root, checkout, worktree, str(owner))
    try:
        record = json.loads(owner.read_text())
        status = json.loads(Path(sb.trellis_home, "state", "attachment-status", checkout, worktree + ".json").read_text())
        if record.get("status") != "committed" or record.get("attachment_id") != attachment:
            raise BenchError("readiness: owner is not committed to the registry attachment")
        if status.get("state") != "ok" or status.get("attachment_id") != attachment:
            raise BenchError("readiness: postjob state {} does not verify attachment".format(status.get("state")))
        if Path(sb.trellis_home, "state", "release-adoptions", checkout).exists():
            raise BenchError("readiness: release adoption is pending")
        for artifact in record.get("artifacts", []) + record.get("renders", []):
            path = Path(root, artifact["path"])
            if not path.exists():
                raise BenchError("readiness: missing owned artifact " + str(path))
        for relative in (".trellis/runtime", ".agents/rules/trellis.md", ".claude/settings.local.json", ".codex/hooks.json"):
            if not Path(root, relative).exists():
                raise BenchError("readiness: missing required leaf " + relative)
        hooks = sb.git(["config", "--get", "core.hooksPath"], root).stdout.decode().strip()
        expected = Path(sb.trellis_home, "state", "git-hooks", checkout)
        if hooks != str(expected) or not all(os.access(expected / name, os.X_OK) for name in ("post-checkout", "pre-push")):
            raise BenchError("readiness: managed hooksPath or dispatcher executable mismatch")
        return True
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise BenchError("readiness: invalid attachment evidence: {}".format(error)) from error


def launcher_setup(sb: Sandbox, argv: List[str]) -> None:
    proc = subprocess.run([sb.launcher] + argv, cwd=sb.project, env=sb.env(), capture_output=True,
                          timeout=COMMAND_TIMEOUT)
    if proc.returncode != 0:
        raise TeardownError("fixture launcher {} failed {}: {}".format(argv, proc.returncode,
                                                                     proc.stderr.decode(errors="replace")[-800:]))


def prepush_trace_fixture(sb: Sandbox, dispatcher: Path) -> Tuple[Path, Dict[str, Any]]:
    """Trace a private dispatcher copy, never replace installed entrypoints/payloads.

    env -i prevents caller xtrace from reaching the dispatcher body or its
    payloads. Only this adjacent diagnostic copy enables tracing at those seams.
    Keeping its directory preserves managed_home derivation; all payload bytes
    and the installed pre-push remain unchanged and subject to normal verification.
    """
    import hashlib

    def fingerprint(path: Path) -> Dict[str, str]:
        if not canonical(str(path)).startswith(sb.root + os.sep) or not path.is_file():
            raise BenchError("pre-push proof source outside private fixture: " + str(path))
        return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}

    installed_dispatcher = fingerprint(dispatcher)
    original = dispatcher.read_text(encoding="utf-8")
    marker = "# trellis-managed-dispatcher-body\n"
    invocation = '/bin/bash --noprofile --norc "$executable" "$@"'
    if original.count(marker) != 1 or original.count(invocation) != 2:
        raise BenchError("unsupported managed dispatcher tracing seams; no pre-push proof")
    instrumented = original.replace(marker, marker + "PS4='+A4TRACE '\nset -x\n", 1).replace(
        invocation, "PS4='+A4TRACE ' /bin/bash --noprofile --norc -x \"$executable\" \"$@\"")
    payload_root = Path((dispatcher.parent / "release-payload").read_text().strip())
    source = (dispatcher.parent / "pre-push-source").read_text().strip()
    sources = [dispatcher, payload_root / source, payload_root / "scripts/lib/attach-postjob.sh",
               payload_root / "core-rules/skills/process-gate/scripts/run-all.sh"]
    fingerprints = [installed_dispatcher] + [fingerprint(path) for path in sources[1:]]
    # A fresh regular sibling, not core.hooksPath's pre-push. Never follow or
    # overwrite a pre-existing leaf, even in the private fixture.
    fd, name = tempfile.mkstemp(prefix=".bench-pre-push-trace-", dir=str(dispatcher.parent))
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(instrumented)
    os.chmod(name, 0o700)
    proof = {"kind": "private-dispatcher-xtrace", "sc13_eligible": False,
             "installed_sources": fingerprints, "diagnostic_dispatcher": fingerprint(Path(name)),
             "instrumentation": "xtrace only in dispatcher body and two payload interpreter seams",
             "samples": []}
    return Path(name), proof


def prepush_trace_ready(sb: Sandbox, proof: Dict[str, Any], iteration: int) -> bool:
    """Positive, ordered execution evidence; discovery/assignments are not calls."""
    import hashlib
    import shlex

    trace_bytes = (sb.scratch / "m0.err").read_bytes()
    stdout = (sb.scratch / "m0.out").read_text(encoding="utf-8")
    commands = []
    for line in trace_bytes.decode("utf-8", errors="replace").splitlines():
        match = re.match(r"^\++A4TRACE (.*)$", line)
        if match:
            try:
                commands.append((line, shlex.split(match.group(1))))
            except ValueError:
                continue  # Multiline traced data, not a command.
    evidence = []
    expected = ["precheck-call", "precheck-ran", "precheck-ok", "postcheck-call",
                "postcheck-ran", "postcheck-ok", "carrier-call", "classified", "ref-seen", "deletion-verdict"]
    stage = 0
    battery_calls = []
    for line, words in commands:
        if not words:
            continue
        command = words[0]
        executable = Path(command).name
        # Tests/assignments which discover RUNALL are not execution. The
        # carrier is traced internally, so a real bash -p "$RUNALL" is visible.
        if (executable in ("bash", "sh", "env", "exec") and
                any(Path(word).name in ("run-all.sh", "run-tests.sh", "run-tests-local.sh")
                    for word in words[1:] if word.startswith("/"))) or executable in (
                        "run-all.sh", "run-tests.sh", "run-tests-local.sh", "run_gate_range") and "=" not in command:
            battery_calls.append(line)
        event = None
        if command == "trellis_run_control_payload" and len(words) == 5 and words[2:] == ["prepush", "--target", sb.project]:
            if words[1] == proof["installed_sources"][2]["path"]:
                event = "precheck-call" if stage == 0 else "postcheck-call"
        elif command == "attach_postjob_prepush" and words[1:] == [sb.trellis_home, sb.project]:
            event = "precheck-ran" if stage == 1 else "postcheck-ran"
        elif words == ["attach_status=0"]:
            event = "precheck-ok" if stage == 2 else "postcheck-ok"
        elif command == "trellis_run_gate_payload" and words[1:] == [proof["installed_sources"][1]["path"], "origin", "fixture://bench"]:
            event = "carrier-call"
        elif words == ["classify_refs"]:
            event = "classified"
        elif words == ["REFS_SEEN=1"]:
            event = "ref-seen"
        elif words == ["echo", "[pre-push] no new commits to gate (deletes only)."]:
            event = "deletion-verdict"
        if stage < len(expected) and event == expected[stage]:
            evidence.append({"event": event, "trace_line": line})
            stage += 1
    unchanged = all(Path(row["path"]).is_file() and
                    hashlib.sha256(Path(row["path"]).read_bytes()).hexdigest() == row["sha256"]
                    for row in proof["installed_sources"] + [proof["diagnostic_dispatcher"]])
    archive = Path(sb.root, "bench-proofs")
    archive.mkdir(exist_ok=True)
    trace_path = archive / ("prepush-{}.trace".format(iteration))
    trace_path.write_bytes(trace_bytes)
    sample = {"iteration": iteration, "events": evidence, "battery_calls": battery_calls,
              "sources_unchanged": unchanged, "trace_file": str(trace_path),
              "trace_sha256": hashlib.sha256(trace_bytes).hexdigest(),
              "deletion_stdout": "[pre-push] no new commits to gate (deletes only)." in stdout.splitlines()}
    proof["samples"].append(sample)
    if stage != len(expected) or battery_calls or not unchanged or not sample["deletion_stdout"]:
        raise BenchError("pre-push execution proof failed (events {}/{}, battery calls {}, unchanged {})".format(
            stage, len(expected), len(battery_calls), unchanged))
    return True


# SC13 uses a separate sealed release whose only changed blobs are these gate
# stand-ins. The dispatcher, carrier, postjob and diff-base resolver remain the
# verified candidate bytes; no installed entrypoint is replaced or traced.
SC13_GATE_STUBS = {
    "core-rules/hooks/spec-gate.sh": b'#!/bin/sh\nprintf "SC13-STUB:spec %s\\n" "$*"\n',
    "core-rules/codex/hooks/spec-gate.sh": b'#!/bin/sh\nprintf "SC13-STUB:spec %s\\n" "$*"\n',
    "core-rules/hooks/lib/aeo-gate-warn.sh": b'#!/bin/sh\nprintf "SC13-STUB:aeo %s\\n" "$AEO_GATE_RANGE"\n',
    "core-rules/skills/process-gate/scripts/run-all.sh": (
        b'#!/bin/sh\nprintf "SC13-STUB:run-all %s\\n" "$*"\n'
        b'printf "## process-gate verdict\\n\\nOverall: MERGEABLE\\n"\n'),
}


def sc13_compare_release_trees(base: Dict[str, Any], fixture: Dict[str, Any]) -> bool:
    import hashlib
    if set(base) != set(fixture) or not set(SC13_GATE_STUBS).issubset(base):
        raise BenchError("SC13 fixture release inventory differs from the candidate")
    for path, old in base.items():
        new = fixture[path]
        if path in SC13_GATE_STUBS:
            data = SC13_GATE_STUBS[path]
            oid = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
            if new != {"mode": old["mode"], "oid": oid} or old == new:
                raise BenchError("SC13 fixture gate stub identity mismatch: " + path)
        elif old != new:
            raise BenchError("SC13 fixture changed a non-gate asset: " + path)
    return True


def sc13_fixture(sb: Sandbox) -> Dict[str, Any]:
    """Build and independently verify a private, gate-stubbed release and attachment."""
    import hashlib

    def digest(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def tree(record: Dict[str, Any]) -> Dict[str, Any]:
        rows = record["tree"]
        result = {row["path"]: {"mode": row["mode"], "oid": row["oid"]} for row in rows}
        if len(result) != len(rows):
            raise BenchError("SC13 duplicate release inventory path")
        return result

    def verify_release(owner: Sandbox, release: Path, version: str) -> None:
        library = SCRIPT_DIR.parent / "lib/release-store.sh"
        proc = subprocess.run(["/bin/bash", "-c", '. "$1" || exit $?; release_store_verify_path "$2" "$3"',
                               "sc13-verify", str(library), str(release), version],
                              cwd=owner.root, env=owner.env(), capture_output=True, timeout=COMMAND_TIMEOUT)
        if proc.returncode != 0:
            raise BenchError("SC13 release verification failed: " + proc.stderr.decode(errors="replace")[-800:])

    version = sb.meta.get("version", "")
    source_commit = sb.meta.get("commit", "")
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit or "") or not re.fullmatch(r"[0-9A-Za-z.+-]+", version or ""):
        raise BenchError("SC13 requires a source commit and release version")
    release = Path(sb.trellis_home, "releases", version)
    if release.is_symlink() or not canonical(str(release)).startswith(sb.root + os.sep):
        raise BenchError("SC13 candidate release is outside the sandbox")
    verify_release(sb, release, version)
    original = json.loads((release / "release.json").read_text())
    parent = Path(tempfile.mkdtemp(prefix="sc13-ordinary-", dir=sb.root))
    case = Sandbox(str(parent))
    for path in (case.home, case.trellis_home, case.tmp, str(case.scratch), os.path.dirname(case.launcher)):
        os.makedirs(path, exist_ok=True)
    source = parent / "fixture-release"
    shutil.copytree(release / "payload", source, symlinks=True)
    for directory, names, files in os.walk(source):
        os.chmod(directory, os.stat(directory).st_mode | stat.S_IWUSR | stat.S_IXUSR)
        for name in files:
            path = Path(directory, name)
            if not path.is_symlink():
                path.chmod(path.stat().st_mode | stat.S_IWUSR)
    for relative, data in SC13_GATE_STUBS.items():
        path = source / relative
        if path.is_symlink() or not path.is_file():
            raise BenchError("SC13 gate is not a regular release file: " + relative)
        path.write_bytes(data)
    for argv in (["init", "-q"], ["config", "user.email", "bench@example.invalid"],
                 ["config", "user.name", "Trellis Bench"], ["config", "commit.gpgsign", "false"],
                 ["config", "tag.gpgSign", "false"], ["config", "core.autocrlf", "false"],
                 ["add", "-f", "-A"], ["commit", "-qm", "SC13 sealed fixture"],
                 ["tag", "-a", "v" + version, "-m", "SC13 sealed fixture"]):
        case.git(argv, str(source), hooks=False)
    shutil.copyfile(source / "scripts/trellis-launcher.sh", case.launcher)
    os.chmod(case.launcher, 0o755)
    proc = subprocess.run(["/bin/bash", "-c", '. "$1" || exit $?; release_store_install "$2" "$3" ""',
                           "sc13-install", str(SCRIPT_DIR.parent / "lib/release-store.sh"), version, str(source)],
                          cwd=case.root, env=case.env(), capture_output=True, timeout=COMMAND_TIMEOUT)
    if proc.returncode != 0:
        raise BenchError("SC13 fixture install failed: " + proc.stderr.decode(errors="replace")[-800:])
    installed = Path(case.trellis_home, "releases", version)
    verify_release(case, installed, version)
    # The fixture attach renders native registrations; publish this host's
    # companion with the launcher exactly as the main sandbox does.
    install_launcher_pair(case, version, {})
    derived = json.loads((installed / "release.json").read_text())
    sc13_compare_release_trees(tree(original), tree(derived))
    for record in (original, derived):
        if not re.fullmatch(r"[0-9a-f]{40}", record.get("commit", "")):
            raise BenchError("SC13 release commit missing")
    payload_root = installed / "payload"
    config = {"schema_version": 1, "source_root": str(source), "release_remote": "fixture://sc13",
              "active_cli_release": version, "default_fleet": "personal",
              "fleets": {"personal": {"discovery_roots": [str(Path(case.project).parent)]}}}
    Path(case.trellis_home, "config.json").write_text(json.dumps(config) + "\n")
    os.chmod(Path(case.trellis_home, "config.json"), 0o600)
    os.makedirs(case.project)
    case.git(["-c", "init.defaultBranch=main", "init", "-q"], case.project, hooks=False)
    for key, value in (("user.email", "bench@example.invalid"), ("user.name", "Trellis Bench"),
                       ("commit.gpgsign", "false")):
        case.git(["config", key, value], case.project, hooks=False)
    Path(case.project, ".trellis.json").write_text('{"schema_version":1,"project_id":"bench-fixture"}\n')
    Path(case.project, "README.md").write_text("base\n")
    case.git(["add", "-A"], case.project, hooks=False)
    case.git(["commit", "-qm", "base"], case.project, hooks=False)
    base = case.git(["rev-parse", "HEAD"], case.project, hooks=False).stdout.decode().strip()
    case.git(["update-ref", "refs/remotes/origin/main", base], case.project, hooks=False)
    Path(case.project, "README.md").write_text("ordinary branch update\n")
    case.git(["add", "README.md"], case.project, hooks=False)
    case.git(["commit", "-qm", "ordinary update"], case.project, hooks=False)
    head = case.git(["rev-parse", "HEAD"], case.project, hooks=False).stdout.decode().strip()
    case.git(["update-ref", "refs/heads/bench-sc13", head], case.project, hooks=False)
    if not re.fullmatch(r"[0-9a-f]{40}", base) or not re.fullmatch(r"[0-9a-f]{40}", head) or base == head:
        raise BenchError("SC13 invalid ordinary update fixture")
    launcher_setup(case, ["attach", "--fleet", "personal", case.project])
    attachment_ready(case, case.project, join=True)
    hooks = case.git(["config", "--get", "core.hooksPath"], case.project).stdout.decode().strip()
    dispatcher = Path(hooks, "pre-push")
    if dispatcher.is_symlink() or not dispatcher.is_file() or not os.access(dispatcher, os.X_OK):
        raise BenchError("SC13 installed dispatcher is not an executable regular file")
    actual_payload = Path((dispatcher.parent / "release-payload").read_text().strip())
    source_name = (dispatcher.parent / "pre-push-source").read_text().strip()
    if actual_payload != payload_root or source_name not in ("core-rules/githooks/pre-push", "core-rules/husky/pre-push"):
        raise BenchError("SC13 dispatcher release/source sidecars differ from the fixture")
    previous = (dispatcher.parent / "previous-hooks-path").read_text().strip()
    prior_dir = Path(previous) if previous else Path(case.project, ".git/hooks")
    if not prior_dir.is_absolute():
        prior_dir = Path(case.project, prior_dir)
    predecessor = prior_dir / "pre-push"
    if predecessor.exists() or predecessor.is_symlink():
        raise BenchError("SC13 fixture has a predecessor pre-push hook")
    gate_links = []
    for project_path, release_path in ((".claude/hooks/spec-gate.sh", "core-rules/hooks/spec-gate.sh"),
                                       (".claude/hooks/lib/aeo-gate-warn.sh", "core-rules/hooks/lib/aeo-gate-warn.sh")):
        link, target = Path(case.project, project_path), payload_root / release_path
        if canonical(str(link)) != canonical(str(target)):
            raise BenchError("SC13 fixture gate link does not resolve to its sealed stub: " + project_path)
        gate_links.append({"path": str(link), "target": str(target)})
    library = payload_root / "scripts/lib/attachment.sh"
    manifest_sha = digest(installed / "release.json")
    generated = subprocess.run(["/bin/bash", "-c",
        '. "$1" || exit $?; _attachment_hooks_pre_push_dispatcher_body "$2" "$3" "$4"',
        "sc13-generator", str(library), str(payload_root), source_name, manifest_sha],
        cwd=case.project, env=case.env(), capture_output=True, timeout=COMMAND_TIMEOUT)
    if generated.returncode != 0 or generated.stdout != dispatcher.read_bytes():
        raise BenchError("SC13 installed dispatcher does not match its verified generator")
    paths = [dispatcher, dispatcher.parent / "release-payload", dispatcher.parent / "pre-push-source",
             dispatcher.parent / "previous-hooks-path", Path(case.project, ".git/config"), installed / "release.json", library,
             payload_root / source_name, payload_root / "scripts/lib/attach-postjob.sh",
             payload_root / "core-rules/skills/process-gate/scripts/lib/diff-base.sh"]
    paths += [payload_root / relative for relative in SC13_GATE_STUBS]
    assets = [{"path": str(path), "sha256": digest(path)} for path in paths]
    proof = {"kind": "sealed-ordinary-update", "source_commit": source_commit,
             "base_release_commit": original["commit"], "fixture_release_commit": derived["commit"],
             "base_release_sha256": digest(release / "release.json"), "fixture_release_sha256": manifest_sha,
             "dispatcher_sha256": digest(dispatcher), "generated_dispatcher_matches": True,
             "fixture_tree_verified": True, "assets": assets, "gate_links": gate_links,
             "predecessor": str(predecessor), "samples": []}
    refs = "refs/heads/bench-sc13 {} refs/heads/bench-sc13 {}\n".format(head, base).encode()
    return {"sandbox": case, "proof": proof, "argv": [str(dispatcher), "origin", "fixture://bench"],
            "refs": refs, "base": base, "head": head}


def sc13_assets_unchanged(proof: Dict[str, Any]) -> bool:
    import hashlib
    return (all(Path(row["path"]).is_file() and not Path(row["path"]).is_symlink() and
                hashlib.sha256(Path(row["path"]).read_bytes()).hexdigest() == row["sha256"]
                for row in proof["assets"]) and
            all(Path(row["path"]).is_file() and canonical(row["path"]) == canonical(row["target"])
                for row in proof["gate_links"]) and
            not os.path.lexists(proof["predecessor"]))


def sc13_sample_ready(sb: Sandbox, proof: Dict[str, Any], iteration: int, base: str, head: str) -> bool:
    output = (sb.scratch / "m0.out").read_text(encoding="utf-8")
    lines = output.splitlines()
    expected = ["SC13-STUB:spec --gate --ref refs/heads/bench-sc13 --head {} --range {}..{}".format(head, base, head),
                "SC13-STUB:aeo {}..{}".format(base, head),
                "SC13-STUB:run-all --mode=push --range={}..{}".format(base, head)]
    unchanged = sc13_assets_unchanged(proof)
    markers = [line for line in lines if line.startswith("SC13-STUB:")]
    valid = (markers == expected and "[pre-push] Trellis verification starting (mode=push)..." in lines and
             "[pre-push] process-gate ok" in lines and not any("deletes only" in line for line in lines))
    proof["samples"].append({"iteration": iteration, "gate_markers": markers, "assets_unchanged": unchanged})
    if not unchanged or not valid:
        raise BenchError("SC13 ordinary update did not execute the expected sealed gate stubs or assets changed")
    return True


def sc13_measure(dispatcher: str, cwd: str, env: Dict[str, str], scratch: Path, refs: bytes,
                 runs: int, warmup: int, before, readiness, extra: Dict[str, Any]) -> Dict[str, Any]:
    raise BenchError("SC13 ordinary-push measurement disabled: execution and source proofs are incomplete")


def bench_lifecycle_expansion(sb: Sandbox, args, results: List[Dict[str, Any]]) -> None:
    items, runs, env = args.lifecycle_items, args.lifecycle_runs, sb.env()
    base = case_extra(args, "attached-checkout", "installed-launcher-or-git", section="lifecycle")
    if "attach-current" in items:
        record = measure("attach-current", [Member("attach-current", [sb.launcher, "attach", "--fleet", "personal", sb.project])],
                         b"", sb.project, env, runs, args.warmup, sb.scratch, readiness=lambda: attachment_ready(sb, sb.project),
                         extra=dict(base, sc1_eligible=False, timing_scope="completion-readiness-diagnostic-only"))
        record.update(note="no event-driven ready-attachment completion boundary")
        finalize_record(record, "diagnostic")
        results.append(record)
    for item in ("git-switch-fast", "git-switch-memo-miss"):
        if item not in items:
            continue
        state: Dict[str, Any] = {"next": "bench-a", "memos": []}
        proofs = []
        sb.git(["switch", "-q", "main"], sb.project, hooks=False)

        def before(_i: int) -> None:
            attachment_ready(sb, sb.project, join=True)
            state["hook_execution"] = checkout_hook_proof(sb, member, env)
            if item == "git-switch-memo-miss":
                state["memos"] = []
                directory = Path(sb.trellis_home, "state", "hook-digests")
                for path in directory.glob("*.json"):
                    record = json.loads(path.read_text())
                    if canonical(record["payload"]) == canonical(os.path.join(sb.project, ".trellis", "runtime")):
                        state["memos"].append(path)
                        fixture_unlink(sb, path)
                if not state["memos"]:
                    raise BenchError("missing-memo fixture found no current safe memo")
            state["checkout_before"] = dict(checkout_snapshot(sb), hook_execution=state["hook_execution"])

        def ready() -> bool:
            attachment_ready(sb, sb.project, join=True)
            if not all(path.is_file() for path in state["memos"]):
                raise BenchError("missing-memo repair did not regenerate its memo")
            repair = (checkout_memo_reproof(sb, state["checkout_before"], checkout_snapshot(sb))
                      if item.endswith("miss") else None)
            proofs.append(checkout_path_proof(sb, state["checkout_before"],
                          "memo-repair" if item.endswith("miss") else "fast", repair))
            return True

        def after(_i: int) -> None:
            state["next"] = "main" if state["next"] == "bench-a" else "bench-a"

        member = Member(item, lambda: ["git", "switch", "-q", state["next"]])
        results.append(measure(item, [member], b"", sb.project,
                               env, runs, args.warmup, sb.scratch, before=before, after=after, readiness=ready,
                               extra=dict(base, checkout_proof=proofs, variant="memo-miss" if item.endswith("miss") else "warm",
                                          spans_status="creation-base/generator/reproof spans not instrumented; whole boundary only")))
        sb.git(["switch", "-q", "main"], sb.project, hooks=False)

    for item in ("attach-new-worktree", "launcher-show-config-multi-root"):
        if item not in items:
            continue
        state = {"count": 0, "output_inspected": False}
        folder = Path(sb.root, "expansion-worktrees")
        folder.mkdir(exist_ok=True)

        def before(_i: int) -> None:
            state["count"] += 1
            state["output_inspected"] = False
            state["branch"] = "bench-expand-" + str(state["count"])
            state["path"] = str(folder / state["branch"])
            sb.git(["worktree", "add", "-q", "-b", state["branch"], state["path"]], sb.project, hooks=False)
            if item == "launcher-show-config-multi-root":
                launcher_setup(sb, ["attach", "--fleet", "personal", state["path"]])
                if not attachment_ready(sb, state["path"], join=True):
                    raise BenchError("multi-root setup is not ready")

        output_proof: List[Dict[str, Any]] = []

        def inspect_output() -> List[str]:
            outputs = [(sb.scratch / ("m{}.out".format(index))).read_text(encoding="utf-8") for index in range(2)]
            output = "\n".join(outputs)
            reported = [line.split(":", 1)[1].strip() for line in output.splitlines()
                        if line.strip().startswith("project root:")]
            missing = [root for root in (sb.project, state["path"]) if root not in reported]
            output_proof.append({"reported_roots": reported, "missing_roots": missing, "outputs": outputs})
            state["output_inspected"] = True
            return missing

        def after(_i: int) -> None:
            # Preserve the output even when a nonzero command exit prevents the
            # readiness callback from running. Never turn that exit into success.
            if item == "launcher-show-config-multi-root" and not state["output_inspected"] and (sb.scratch / "m0.out").is_file():
                inspect_output()
            teardown_worktree(sb, state["path"], state["branch"], attached=True)

        def ready() -> bool:
            if item == "launcher-show-config-multi-root":
                missing = inspect_output()
                if missing:
                    raise BenchError("multi-root show-config did not report both exact project roots: " + repr(missing))
            return attachment_ready(sb, state["path"])

        argv = lambda: [sb.launcher, "attach", "--fleet", "personal", state["path"]]
        diagnostic = {"sc1_eligible": False, "timing_scope": "completion-readiness-diagnostic-only"} if item == "attach-new-worktree" else {"sc2_eligible": False, "timing_scope": "two-complete-show-config-invocations"}
        members = ([Member(item, argv)] if item == "attach-new-worktree" else
                   [Member(item + ":main", [sb.launcher, "show-config"], cwd=sb.project),
                    Member(item + ":linked", [sb.launcher, "show-config"], cwd=lambda: state["path"])])
        record = measure(item, members, b"", sb.project, env, runs, args.warmup, sb.scratch,
                         before=before, after=after, readiness=ready,
                         extra=dict(base, output_proof=output_proof, **diagnostic,
                                    fixture_id="two-attached-roots" if item.endswith("multi-root") else "unattached-linked-worktree"))
        if diagnostic:
            record.update(note="no event-driven ready-attachment completion boundary" if item == "attach-new-worktree" else
                          "two concurrent show-config invocations are diagnostic, not the SC2 single-command multi-root boundary")
            finalize_record(record, "diagnostic")
        results.append(record)

    if "pre-push-dispatcher" in items:
        hooks = sb.git(["config", "--get", "core.hooksPath"], sb.project).stdout.decode().strip()
        # The installed dispatcher deliberately drops inherited tracing. Use a
        # private adjacent copy with xtrace-only changes; never replace carriers
        # or battery scripts, and never count this diagnostic as SC13 timing.
        dispatcher = Path(hooks, "pre-push")
        head = sb.git(["rev-parse", "HEAD"], sb.project, hooks=False).stdout.decode().strip()
        refs = "(delete) {} refs/heads/bench-deleted {}\n".format("0" * len(head), head).encode()
        traced, proof = prepush_trace_fixture(sb, dispatcher)
        iteration = {"value": -1}

        def before(_i: int) -> None:
            iteration["value"] = _i

        try:
            record = measure("pre-push-dispatcher", [Member("diagnostic-managed-pre-push", [str(traced), "origin", "fixture://bench"])],
                             refs, sb.project, env, runs, args.warmup, sb.scratch, before=before,
                             readiness=lambda: prepush_trace_ready(sb, proof, iteration["value"]),
                             extra=dict(base, boundary_id="managed-pre-push-deletion-no-battery", fixture_id="deletion-ref",
                                        execution_proof=proof, sc13_eligible=False, gate_battery="must have no traced invocation",
                                        timing_scope="instrumented-dispatcher-diagnostic-only",
                                        note="private xtrace dispatcher copy; original installed sources hashed and unchanged; no SC13 claim"))
            finalize_record(record, "diagnostic")
            results.append(record)
        finally:
            fixture_unlink(sb, traced)
    if "pre-push-dispatcher-ordinary" in items:
        # Do not construct a fixture or launch a process until the positive
        # execution, source identity, Git ABI and setup-quarantine gaps close.
        results.append(finalize_record(unmeasured(
            "pre-push-dispatcher-ordinary",
            "SC13 unavailable: execution/source proof, Git ABI and setup quarantine are incomplete",
            **dict(base, fixture_id="ordinary-push-sealed-noop-gates",
                   boundary_id="managed-pre-push-ordinary-no-battery", sc13_eligible=False,
                   timing_scope="disabled-pending-sc13-proof"))))
    bench_worktree_callbacks(sb, args, results)


def join_callback_job(sb: Sandbox, event: str, worktree: str) -> Dict[str, Any]:
    """Verify the callback finished its work in the foreground (spec 074 T48/T49).

    Both callbacks are synchronous: create attaches before printing the path
    and remove detaches and removes before exiting 0. A detached sync pid or a
    background-completion line means the old premature-success path ran, which
    is refused rather than joined.
    """
    state = Path(sb.trellis_home, "state", "worktree-hooks")
    key = os.path.relpath(worktree, str(Path(sb.root, "callback-worktrees"))).replace(os.sep, "_")
    if event == "WorktreeCreate":
        if os.path.lexists(state / (key + ".sync.pid")):
            raise TeardownError("create callback left a detached sync job; refusing a premature-success path")
    else:
        stderr = (sb.scratch / "m0.err").read_text()
        if "continue in the background" in stderr:
            raise TeardownError("remove callback deferred its work to a background job; refusing premature success")
        log_path = state / (key + ".remove.log")
        if not any(line.endswith("removed " + worktree) for line in log_path.read_text().splitlines()):
            raise TeardownError("remove callback exited without a removal verdict: " + str(log_path))
    return {"joined": True, "method": "synchronous callback, verified result", "sc1_eligible": False}


def worktree_callback_hooks(sb: Sandbox) -> Dict[str, Any]:
    """The user-global WorktreeCreate/Remove registrations as Claude runs them.

    Since T34b the user template is native (a __TRELLIS_LAUNCHER__ placeholder
    that only the renderer turns into this host's companion entry), so the
    callbacks are what `trellis attach --user` renders into the sandbox user's
    ~/.claude/settings.json, never the raw template. A legacy-host render still
    calls the hook scripts under ~/.claude/hooks, linked from the runtime.
    """
    settings = Path(sb.home, ".claude", "settings.json")
    if not settings.is_file():
        launcher_setup(sb, ["attach", "--user"])
    # Only after attach --user, so its owned leaves are never pre-empted.
    runtime = Path(sb.project, ".trellis", "runtime")
    user_hooks = Path(sb.home, ".claude", "hooks")
    user_hooks.mkdir(parents=True, exist_ok=True)
    for name in ("trellis-worktree-create.sh", "trellis-worktree-remove.sh"):
        path = user_hooks / name
        if not os.path.lexists(path):
            path.symlink_to(runtime / "core-rules" / "hooks" / name)
    hooks = load_hooks(str(settings))
    for event in ("WorktreeCreate", "WorktreeRemove"):
        if not hooks.get(event):
            raise BenchError("attach --user rendered no {} callback in {}".format(event, settings))
    return hooks


def bench_worktree_callbacks(sb: Sandbox, args, results: List[Dict[str, Any]]) -> None:
    selected = [event for event in ("WorktreeCreate", "WorktreeRemove") if "claude " + event in args.lifecycle_items]
    if not selected:
        return
    hooks = worktree_callback_hooks(sb)
    root = Path(sb.root, "callback-worktrees")
    root.mkdir(exist_ok=True)
    worktree = str(root / "bench-fixture" / "cc-bench-callback")
    branch = "worktree-bench-callback"
    env = sb.env(TRELLIS_WORKTREE_ROOT=str(root))
    # No external merge service in this fixture: absence means unknown merge,
    # never a fake merged proof. HEAD is shared with main, so safe removal need
    # not delete the branch. Exclude gh without dropping the other caller tools.
    tools = Path(sb.root, "callback-bin")
    tools.mkdir(exist_ok=True)
    for directory in env["PATH"].split(os.pathsep):
        if not os.path.isdir(directory):
            continue
        for source in Path(directory).iterdir():
            if source.name != "gh" and os.access(source, os.X_OK) and source.is_file() and not (tools / source.name).exists():
                (tools / source.name).symlink_to(source)
    env["PATH"] = str(tools)
    for event in selected:
        case_id = "claude " + event
        members = matched_hooks(hooks, event, None, sb.project)
        data = payload("hook-" + event + ".json", sb).replace(b"@WORKTREE@", json.dumps(worktree)[1:-1].encode())
        if not members:
            raise BenchError("no registered callback members for " + event)
        completion_proof: List[Dict[str, Any]] = []
        state = {"joined": False}

        def before(_i: int) -> None:
            state["joined"] = False
            if event == "WorktreeRemove":
                Path(worktree).parent.mkdir(parents=True, exist_ok=True)
                sb.git(["worktree", "add", "-q", "-b", branch, worktree], sb.project, hooks=False)
                launcher_setup(sb, ["attach", "--fleet", "personal", worktree])
                if not attachment_ready(sb, worktree, join=True):
                    raise BenchError("remove callback fixture is not ready")

        def ready() -> bool:
            completion_proof.append(join_callback_job(sb, event, worktree))
            state["joined"] = True
            if event == "WorktreeCreate":
                stdout = (sb.scratch / "m0.out").read_text()
                return stdout == worktree + "\n" and attachment_ready(sb, worktree)
            row = registry_worktree(sb, worktree)
            return not os.path.lexists(worktree) and (row is None or row[2] is None)

        def after(_i: int) -> None:
            if not state["joined"]:
                raise TeardownError("callback completion not joined; preserving fixture instead of racing detached work")
            if event == "WorktreeCreate":
                teardown_worktree(sb, worktree, branch, attached=True)
            else:
                row = registry_worktree(sb, worktree)
                if row is not None:
                    launcher_setup(sb, ["registry", "deregister", "--fleet", "personal", "--worktree-root", worktree])
                remaining = sb.git(["show-ref", "--verify", "--quiet", "refs/heads/" + branch], sb.project,
                                   check=False, hooks=False)
                if remaining.returncode == 0:
                    sb.git(["branch", "-d", branch], sb.project, hooks=False)
                elif remaining.returncode != 1:
                    raise TeardownError("could not verify callback branch cleanup")

        record = measure(case_id, members, data, sb.project, env, args.lifecycle_runs, args.warmup, sb.scratch,
                         before=before, after=after, readiness=ready,
                         extra=case_extra(args, "registered-shared-head-worktree", "claude-user-registered-callback",
                                          section="lifecycle", harness="claude", event=event, completion_proof=completion_proof,
                                          sc1_eligible=False, timing_scope="callback-diagnostic-only",
                                          note="detached completion verified by polling; no ready-worktree latency claim",
                                          external_merge_service="absent; no merged claim"))
        finalize_record(record, "diagnostic")
        results.append(record)


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
    if not record or record.get("status") != "ok" or not record.get("wall_ms"):
        return None
    return record["wall_ms"]["p50"]


def summarize(results: List[Dict[str, Any]]) -> Dict[str, Any]:
    results = [record for record in results if record.get("status") == "ok"]
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
    rendered = {(r.get("registration_form"), r.get("claude_version"), r.get("render_selection"))
                for r in meta["results"] if r.get("claude_version_exit") is not None or r.get("registration_form") in ("R1", "R2")}
    for form, version, selection in sorted(rendered, key=str):
        out.append("- Claude {}: version `{}`; {}. R1 primary, R2 fallback; historical 1.4.0 receipt used R2.".format(
            form, version or "unavailable", selection))
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
    out.append("| Case | Status | n | p50 ms | p90 ms | p99 ms | CPU p50 ms | exits | over timeout | load start→end |")
    out.append("|---|---|---:|---:|---:|---:|---:|---|---:|---|")
    for r in meta["results"]:
        wall = r.get("wall_ms") if r.get("status") == "ok" else None
        if not wall:
            out.append("| {} | {} | — | — | — | — | — | {} | — | — |".format(
                r["id"], r["status"], r.get("note", r.get("error", {}).get("message", ""))))
            continue
        members = r.get("members", [])
        exits = ";".join("{}={}".format(m["name"], ",".join(str(c) for c in m["exit_codes"])) for m in members) \
            or r.get("boundary", "")
        over = sum(m["runs_over_registered_timeout"] for m in members)
        cpu = r.get("cpu_ms") or {}
        out.append("| {} | {} | {} | {} | {} | {} | {} | {} | {} | {}→{} |".format(
            r["id"], r["status"], wall["n"], fmt(wall["p50"]), fmt(wall["p90"]), fmt(wall["p99"]), fmt(cpu.get("p50")),
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
    parser.add_argument("--list-cases", action="store_true", help="print the complete candidate I-A4 matrix as JSON; no sandbox or measurement")
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
    cleanup = {}
    result = 1
    try:
        result = _main(argv, cleanup)
    finally:
        sandbox = cleanup.get("sandbox")
        if sandbox is not None:
            if cleanup.get("keep"):
                log("kept sandbox: " + sandbox.root)
            elif remove_tree(sandbox.root) is False:
                result = 1
                path = cleanup.get("receipt_path")
                if path is not None and path.is_file():
                    receipt = json.loads(path.read_text())
                    receipt["sandbox"].update(kept=True, quarantined="cleanup process drain incomplete")
                    receipt["status"] = "failed"
                    receipt["notes"].append("sandbox retained: cleanup process drain incomplete")
                    for row in receipt["results"]:
                        if row["status"] == "ok":
                            row["error"] = {"phase": "cleanup", "type": "TeardownError", "message": "sandbox process drain incomplete"}
                            finalize_record(row, "failed")
                    receipt["summary"] = summarize(receipt["results"])
                    path.write_text(json.dumps(receipt, indent=2) + "\n")
                    path.with_suffix(".md").write_text(markdown(receipt))
    path = cleanup.get("receipt_path")
    if path is not None and path.is_file():
        for row in json.loads(path.read_text())["results"]:
            if row["status"] == "ok" and row.get("wall_ms"):
                log("{}: ok p50 {} ms".format(row["id"], row["wall_ms"]["p50"]))
            else:
                log("{}: {}".format(row["id"], row["status"]))
    return result


def _main(argv: Sequence[str], cleanup: dict) -> int:
    args = parse_args(argv)
    if args.list_cases:
        print(json.dumps({"schema": "trellis-bench-case-matrix/1", "status": "candidate-not-frozen", "cases": case_matrix()}, indent=2))
        return 0
    case_matrix()  # Reject a drifted denominator before any fixture work.
    created = datetime.now(timezone.utc)
    load_start = loadavg()
    # Classification is not a liveness gate: functional suites may run, but
    # their observations must never masquerade as quiet release measurements.
    declared_condition = args.condition
    if args.condition == "normal" and (load_start[0] >= (os.cpu_count() or 1) or gate_or_bats_running()):
        args.condition = "load-contended"
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    results: List[Dict[str, Any]] = []
    notes: List[str] = [
        "Claude and Codex hooks are read from the attach-rendered .claude/settings.local.json and "
        ".codex/hooks.json (templates claude-settings.local.json and codex-hooks.local.json); the "
        "direct-copy claude-settings.json manifest is not what attached projects run.",
        "Hook payloads are scripts/bench/payloads/*.json with @PROJECT@/@TRANSCRIPT@ filled in. Retained "
        "Codex rows use the legacy Claude-shaped envelope; native-cases.json separately defines actual "
        "exec_command/apply_patch/result shapes. Unmatched native aliases stay unmeasured, not remapped to pretend registrations.",
        "Default fixtures are clean/no-toolchain. Explicit active-python rows run an instrumented AST "
        "adapter and real unittest via private host fast-suite config, with proof markers; these are "
        "functional boundary diagnostics, not qualified linter/reviewer timing claims.",
        "I-A4 is candidate-not-frozen: quiet pinned baseline and U1/E2-E4 launched-process traces are not "
        "collected here. No source-derived process count is an observed trace; candidate rows do not establish release qualification.",
        "pi rows time the trellis.ts handlers (the C1 boundary); pi-dispatch rows time dispatch.sh alone "
        "and are dispatch-only diagnostics.",
    ]
    sb: Optional[Sandbox] = None
    needs_sandbox = any(s in args.sections for s in ("claude", "codex", "pi", "pi-dispatch", "lifecycle"))
    source = canonical(args.source) if args.source else (
        str(DEFAULT_SOURCE) if is_checkout(str(DEFAULT_SOURCE)) else None)
    base = canonical(args.sandbox_base or os.environ.get("TMPDIR") or tempfile.gettempdir())
    exit_code = 0
    keep_evidence = False
    gate = None
    uncontained_failure = False
    try:
        if needs_sandbox:
            if args.reuse:
                sb = reuse_sandbox(args.reuse)
            else:
                log("building sandbox under " + base)
                sb = build_sandbox(base, source, args.rev)
            cleanup.update(sandbox=sb, keep=bool(args.keep or args.reuse))
            log("sandbox " + sb.root)
        for section in args.sections:
            if cleanup.get("quarantined") and section != "gate":
                matrix = case_matrix()
                if section == "lifecycle":
                    ids = [case_id for item in args.lifecycle_items for case_id in
                           ([item + " (hooks off)", item] if item in ("git-switch", "git-checkout-file", "git-worktree-add") else [item])]
                    identities = [next(row for row in matrix if row["id"] == case_id) for case_id in ids]
                else:
                    identities = [row for row in matrix if row["id"].startswith(section + " ") and wanted(row["id"], args.hooks)]
                results.extend(blocked_case(row, section, cleanup["quarantined"]) for row in identities)
                continue
            if section in ("claude", "codex"):
                bench_hook_harness(section, sb, args, results)
            elif section == "pi":
                bench_pi(sb, args, results)
            elif section == "pi-dispatch":
                bench_pi_dispatch(sb, args, results)
            elif section == "lifecycle":
                # A failed observation is a row, not permission to drop the
                # remainder of the requested lifecycle denominator.
                quarantine = None
                for item in args.lifecycle_items:
                    if quarantine is not None:
                        ids = [item + " (hooks off)", item] if item in ("git-switch", "git-checkout-file", "git-worktree-add") else [item]
                        for case_id in ids:
                            identity = next(row for row in case_matrix() if row["id"] == case_id)
                            results.append(blocked_case(identity, "lifecycle", quarantine))
                        continue
                    log("lifecycle start: " + item)
                    item_args = argparse.Namespace(**dict(vars(args), lifecycle_items=[item]))
                    try:
                        bench_lifecycle(sb, item_args, results)
                    except Exception as error:
                        record = getattr(error, "record", None)
                        if record is None:
                            identity = next(row for row in case_matrix() if row["id"] == item)
                            record = dict(identity, section="lifecycle", status="failed", observations=[],
                                          members=[], error=failure_detail(error, "setup"))
                        if record not in results:
                            results.append(finalize_record(record, "failed"))
                        notes.append("FAILED lifecycle {}: {}".format(item, error))
                        log("{}: failed: {}; teardown: {}".format(item, error,
                            record.get("teardown_error", {}).get("message", "none")))
                        exit_code = 1
                        if (isinstance(error, (TeardownError, CallbackTimeout)) or record.get("teardown_error") or
                                any(row.get("timeout") or row.get("callback_timeout") for row in record.get("observations", []))):
                            quarantine = "{}: {}".format(item, error)
                            keep_evidence = True
                            cleanup["keep"] = True
                            cleanup["quarantined"] = quarantine
                    finally:
                        log("lifecycle finished: " + item)
            elif section == "gate":
                gate = bench_gate(args.gate_tsv, args.gate_wall, args.gate_top)
                if gate["wall_seconds"] is None:
                    notes.append("Gate wall is unknown: the TSV carries none and --gate-wall was not given.")
    except (Exception, KeyboardInterrupt) as exc:
        uncontained_failure = True
        if getattr(exc, "record", None) is not None:
            if exc.record not in results:
                results.append(exc.record)
        else:
            results.append(dict(id="{} error".format(locals().get("section", "setup")), status="failed",
                                wall_ms=None, cpu_ms=None, observations=[],
                                error=failure_detail(exc, locals().get("section", "setup"))))
        log("error: " + str(exc))
        notes.append("ABORTED: " + str(exc))
        exit_code = 1
        keep_evidence = isinstance(exc, (TeardownError, CallbackTimeout, KeyboardInterrupt))
        cleanup["keep"] = bool(args.keep or args.reuse or keep_evidence)
    for record in results:
        finalize_record(record)
    load_end = loadavg()
    busy = gate_or_bats_running()
    if args.condition == "normal" and (load_end[0] >= (os.cpu_count() or 1) or busy):
        args.condition = "load-contended"
    if args.condition != "normal":
        for record in results:
            record["load"] = "contended"
    receipt = {
        "schema": SCHEMA,
        "label": args.label,
        "condition": args.condition,
        "declared_condition": declared_condition,
        "created_utc": created.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "host": {"platform": platform.platform(), "machine": platform.machine(), "cpu_count": os.cpu_count(),
                 "python": sys.version.split()[0], "filesystem": filesystem_of(base),
                 "gate_or_bats_running": busy},
        "source": {k: (sb.meta.get(k) if sb else None) for k in ("release_mode", "rev", "commit", "version")},
        "config": {"runs": args.runs, "warmup": args.warmup, "lifecycle_runs": args.lifecycle_runs,
                   "sections": args.sections, "hooks_filter": args.hooks,
                   "lifecycle_items": args.lifecycle_items if "lifecycle" in args.sections else []},
        "load": {"start": load_start, "end": load_end},
        "sandbox": {"kept": bool(sb and (args.keep or args.reuse or keep_evidence)),
                    "quarantined": cleanup.get("quarantined"),
                    "setup_seconds": sb.meta.get("setup_seconds") if sb else None,
                    "path_counts": sb.path_counts if sb else None},
        "results": results,
        "summary": summarize(results),
        "gate": gate,
        "notes": notes,
        "status": "ok" if exit_code == 0 else "aborted" if uncontained_failure else "failed",
    }
    redactor = host_redactor([(sb.root if sb else None, "<SANDBOX>"), (base, "<SANDBOX_BASE>"),
                              (source, "<SOURCE>"), (canonical(str(out_dir)), "<OUT>")])
    receipt = redactor.tree(receipt)
    stem = "bench-{}-{}".format(created.strftime("%Y-%m-%d"), args.label)
    json_path = out_dir / (stem + ".json")
    md_path = out_dir / (stem + ".md")
    cleanup["receipt_path"] = json_path
    json_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    md_path.write_text(markdown(receipt), encoding="utf-8")
    print(json_path)
    print(md_path)
    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
