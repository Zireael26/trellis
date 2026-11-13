#!/usr/bin/env python3
"""Isolated process fixtures shared by both primer-capture-nudge suites.

The git symlink executes this file as an adapter. Only changed-name discovery
is faked; every other invocation is exec'd as the original git, including
ls-files --others --directory --exclude-standard in the flood case. The test
driver supervises the real PATH-selected bash hook, not a copy or a stub.
"""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time


# PID plus ps lstart avoids signalling a different process after PID reuse.
# A zombie is not alive, even on systems whose init has not reaped it yet.
def process_table():
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,stat=,lstart="],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    entries = {}
    for line in result.stdout.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4:
            continue
        try:
            pid, ppid = int(fields[0]), int(fields[1])
        except ValueError:
            continue
        entries[pid] = {"pid": pid, "ppid": ppid, "state": fields[2], "birth": fields[3]}
    return entries


def alive(identity, table):
    pid = identity["pid"]
    entry = table.get(pid)
    if not entry or entry["birth"] != identity["birth"] or entry["state"].startswith("Z"):
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def signal_exact(identity, signum):
    pid = identity["pid"]
    assert pid not in {1, os.getpid(), os.getppid()}, "refusing to signal the test runner"
    assert alive(identity, process_table()), "fixture PID no longer has the recorded identity: %d" % pid
    os.kill(pid, signum)


def write_record(path, data):
    temporary = str(path) + ".tmp"
    Path(temporary).write_text(json.dumps(data), encoding="utf-8")
    os.replace(temporary, path)


def record_self(kind, **extra):
    pid = os.getpid()
    entry = process_table()[pid]
    entry.update(extra)
    write_record(Path(os.environ["PCN_BOUND_DIR"]) / ("%s-%d.json" % (kind, pid)), entry)


def ignore_term():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)


def default_term():
    signal.signal(signal.SIGTERM, signal.SIG_DFL)


def git_command(args):
    # Skip git's global options without mistaking -c's value for a command.
    with_value = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"}
    index = 0
    while index < len(args):
        if args[index] in with_value:
            index += 2
        elif args[index].startswith("-"):
            index += 1
        else:
            return args[index]
    return ""


def fake_git():
    args = sys.argv[1:]
    command = git_command(args)
    mode = os.environ["PCN_BOUND_MODE"]
    names = command == "diff" and "--name-only" in args
    untracked = command == "ls-files" and "--others" in args

    if mode == "untracked-flood" and untracked and "--directory" in args:
        sys.stdout.write("src/flood/\n")
        return
    if (mode == "flood" and names) or (mode == "untracked-flood" and untracked):
        record_self("producer")
        separator = "\0" if "-z" in args else "\n"
        try:
            # Lazy production matters: completing this loop is a test failure,
            # even if sorting/buffering all 500,000 names happens to be fast.
            for number in range(500000):
                sys.stdout.write("src/synthetic-%06d.py%s" % (number, separator))
            sys.stdout.flush()
        except BrokenPipeError:
            os._exit(0)  # Avoid a second BrokenPipeError during interpreter shutdown.
        Path(os.environ["PCN_BOUND_DIR"], "complete-%d" % os.getpid()).touch()
        return

    if mode == "stall" and (names or untracked):
        record_self("git")
        # SIG_IGN survives exec. The child records that it really inherited the
        # disposition; the driver also sends it a TERM before testing cleanup.
        subprocess.Popen(
            [sys.executable, os.path.realpath(__file__), "--stall-child"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            preexec_fn=ignore_term,
        )
        while True:
            time.sleep(60)

    os.execv(os.environ["PCN_BOUND_REAL_GIT"], [os.environ["PCN_BOUND_REAL_GIT"]] + args)


def fake_jq():
    if os.environ["PCN_BOUND_MODE"] == "partial" and "-nc" in sys.argv[1:]:
        record_self("jq")
        sys.stdout.write('{"systemMessage":"incomplete"}\n')
        sys.stdout.flush()
        while True:
            time.sleep(60)
    os.execv(os.environ["PCN_BOUND_REAL_JQ"], [os.environ["PCN_BOUND_REAL_JQ"]] + sys.argv[1:])


def stall_child():
    record_self("child", ignored=signal.getsignal(signal.SIGTERM) == signal.SIG_IGN)
    while True:
        time.sleep(60)


def launch_hook(env):
    def dispositions():
        if env["PCN_BOUND_IGNORE_TERM"] == "1":
            ignore_term()
        else:
            default_term()
        if env["PCN_BOUND_IGNORE_CHLD"] == "1":
            signal.signal(signal.SIGCHLD, signal.SIG_IGN)

    directory = Path(env["PCN_BOUND_DIR"])
    # File redirection avoids a leaked descendant retaining a Bats capture pipe.
    with (directory / "stdin").open("rb") as stdin, \
         (directory / "stdout").open("wb") as stdout, \
         (directory / "stderr").open("wb") as stderr:
        read_fd = write_fd = None
        if env["PCN_BOUND_MODE"] in ("stdout-stall", "stderr-stall"):
            read_fd, write_fd = os.pipe()
            os.set_blocking(write_fd, False)
            for chunk in (b"x" * 512, b"x"):
                while True:
                    try:
                        os.write(write_fd, chunk)
                    except BlockingIOError:
                        break
            os.set_blocking(write_fd, True)
        try:
            proc = subprocess.Popen(
                [env["PCN_BOUND_BASH"], env["PCN_BOUND_HOOK"]],
                cwd=env["PCN_BOUND_PROJECT"], env=env,
                stdin=subprocess.PIPE if env["PCN_BOUND_OPEN_STDIN"] == "1" else stdin,
                stdout=write_fd if env["PCN_BOUND_MODE"] == "stdout-stall" else stdout,
                stderr=write_fd if env["PCN_BOUND_MODE"] == "stderr-stall" else stderr,
                start_new_session=True,
                preexec_fn=dispositions,
            )
        except (OSError, subprocess.SubprocessError):
            if read_fd is not None:
                os.close(read_fd)
            raise
        finally:
            if write_fd is not None:
                os.close(write_fd)
        proc.pcn_pipe_read = read_fd
        return proc


def launcher():
    # The driver kills THIS direct parent, not the test runner or its group.
    hook = launch_hook(os.environ)
    table = process_table()
    write_record(Path(os.environ["PCN_BOUND_DIR"]) / "hook.json", table[hook.pid])
    hook.wait()


def descendants(root, table):
    found = {root}
    while True:
        children = {pid for pid, entry in table.items() if entry["ppid"] in found}
        new = children - found
        if not new:
            return found
        found.update(new)


class Observer:
    def __init__(self, directory):
        self.directory = directory
        self.identities = {}
        self.root = None

    def remember(self, identity):
        self.identities[identity["pid"]] = identity

    def sample(self):
        table = process_table()
        # Include processes reparented after hook/launcher death. Their records
        # were written by the individual fixture processes before the event.
        for pattern in ("producer-*.json", "git-*.json", "child-*.json", "jq-*.json"):
            for path in self.directory.glob(pattern):
                self.remember(json.loads(path.read_text(encoding="utf-8")))
        if self.root and alive(self.root, table):
            for pid in descendants(self.root["pid"], table):
                self.remember(table[pid])
        return table

    def living(self, table):
        return [entry for entry in self.identities.values() if alive(entry, table)]

    def cleanup(self):
        # Never use killpg/pkill. Only independently identified fixture PIDs
        # and observed descendants are eligible; recheck birth before SIGKILL.
        protected = {1, os.getpid(), os.getppid()}
        for _ in range(4):
            table = self.sample()
            remaining = self.living(table)
            if not remaining:
                return
            for identity in remaining:
                pid = identity["pid"]
                if pid not in protected:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except (ProcessLookupError, PermissionError):
                        pass
            time.sleep(0.05)
        remaining = self.living(self.sample())
        assert not remaining, "fixture cleanup left live PIDs: %r" % [p["pid"] for p in remaining]


def wait_for(predicate, observer, deadline, description):
    while time.monotonic() < deadline:
        table = observer.sample()
        value = predicate(table)
        if value:
            if time.monotonic() <= deadline:
                return value
            break
        time.sleep(0.03)
    raise AssertionError("timed out waiting for " + description)


def assert_one_line(path, fragment):
    raw = path.read_bytes()
    assert raw.endswith(b"\n") and len(raw.splitlines()) == 1, "expected one stderr line, got %r" % raw
    assert fragment.encode() in raw, "missing %r in stderr %r" % (fragment, raw)


def install_slow_python(fakebin):
    # Inject stalls only into the hook supervisor, without changing its code or
    # affecting the test driver and Git fence. Python isolated mode still runs
    # the exact inline program passed by the hook.
    wrapper = fakebin / "python3"
    wrapper.write_text("""#!/bin/bash
if [ "${1:-}" != -I ] || [ "${2:-}" != -c ]; then
  exec "$PCN_BOUND_REAL_PYTHON" "$@"
fi
exec "$PCN_BOUND_REAL_PYTHON" -I -c '
import builtins, os, shutil, sys, time
code = sys.argv.pop(1)
mode = os.environ["PCN_BOUND_MODE"]
real_mkdir, real_open, real_rmtree = os.mkdir, builtins.open, shutil.rmtree
def mark():
    with real_open(os.path.join(os.environ["PCN_BOUND_DIR"], "filesystem-blocked"), "w") as f:
        f.write("ready")
def mkdir(path, *args, **kwargs):
    if mode in ("mkdir-stall", "mkdir-parent-death", "mkdir-supervisor-death") and os.path.basename(str(path)).startswith("trellis-primer-nudge."):
        mark()
        time.sleep(60)
    return real_mkdir(path, *args, **kwargs)
def opened(path, access="r", *args, **kwargs):
    if mode in ("output-read-stall", "output-read-signal") and access == "rb" and str(path).endswith("/stdout"):
        mark()
        time.sleep(60)
    return real_open(path, access, *args, **kwargs)
def rmtree(path, *args, **kwargs):
    if mode == "cleanup-stall" and os.path.basename(str(path)).startswith("trellis-primer-nudge."):
        mark()
        time.sleep(60)
    return real_rmtree(path, *args, **kwargs)
os.mkdir, builtins.open, shutil.rmtree = mkdir, opened, rmtree
if mode == "parent-one":
    real_getppid, supervisor_pid = os.getppid, os.getpid()
    os.getppid = lambda: 1 if os.getpid() == supervisor_pid else real_getppid()
if mode == "mkdir-collision":
    os.urandom = lambda n: bytes(n)
exec(code)
' "$3" "${@:4}"
""", encoding="utf-8")
    wrapper.chmod(0o755)


def run_case(mode, hook, project, tmpdir):
    directory = Path(tmpdir) / ("primer-bound-" + mode)
    directory.mkdir()
    fakebin = directory / "bin"
    fakebin.mkdir()
    (fakebin / "git").symlink_to(Path(__file__).resolve())
    if mode == "partial-output":
        (fakebin / "jq").symlink_to(Path(__file__).resolve())
    slow_modes = ("mkdir-stall", "mkdir-parent-death", "mkdir-supervisor-death", "mkdir-collision",
                  "output-read-stall", "output-read-signal", "cleanup-stall")
    if mode in slow_modes or mode == "parent-one":
        install_slow_python(fakebin)
    if mode == "mkdir-collision":
        collision = directory / ("trellis-primer-nudge." + "00" * 16)
        collision.mkdir()
        (collision / "keep").write_text("owned by someone else", encoding="utf-8")
    (directory / "stdin").write_text("{}\n", encoding="utf-8")
    real_git = shutil.which("git")
    real_jq = shutil.which("jq")
    selected_bash = shutil.which("bash")
    assert real_git and real_jq and selected_bash, "git, jq and the PATH-selected bash are required"
    env = os.environ.copy()
    env.update({
        "PATH": str(fakebin) + os.pathsep + env["PATH"],
        "TMPDIR": str(directory),
        "PCN_BOUND_DIR": str(directory),
        "PCN_BOUND_MODE": (mode if mode in ("flood", "untracked-flood") else "partial" if mode == "partial-output"
                           else mode if mode in slow_modes or mode in ("stdout-stall", "stderr-stall", "parent-one") else "stall"),
        "PCN_BOUND_REAL_GIT": real_git,
        "PCN_BOUND_REAL_JQ": real_jq,
        "PCN_BOUND_REAL_PYTHON": sys.executable,
        "PCN_BOUND_BASH": selected_bash,
        "PCN_BOUND_HOOK": hook,
        "PCN_BOUND_PROJECT": project,
        "PCN_BOUND_IGNORE_TERM": "1" if mode in ("signal-ignored", "parent-death", "mkdir-parent-death") else "0",
        "PCN_BOUND_IGNORE_CHLD": "1" if mode == "sigchld-ignored" else "0",
        "PCN_BOUND_OPEN_STDIN": "1" if mode in ("stdin", "stderr-stall") else "0",
    })
    observer = Observer(directory)
    control = None
    started = time.monotonic()
    try:
        if mode in ("parent-death", "mkdir-parent-death"):
            with (directory / "launcher.log").open("wb") as log:
                control = subprocess.Popen(
                    [sys.executable, os.path.realpath(__file__), "--launcher"],
                    env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                    start_new_session=True, preexec_fn=default_term,
                )
            table = process_table()
            observer.root = table[control.pid]
            observer.remember(observer.root)
            hook_record = directory / "hook.json"
            wait_for(lambda _table: hook_record.exists(), observer, started + 1.2, "hook launch")
            root = json.loads(hook_record.read_text(encoding="utf-8"))
        else:
            control = launch_hook(env)
            table = process_table()
            assert control.pid in table, "hook exited before process observation"
            root = table[control.pid]

        observer.root = root
        observer.remember(root)
        if mode in ("stdout-stall", "stderr-stall"):
            wait_for(lambda table: not observer.living(table), observer,
                     started + 4.0, "blocked output budget and descendant cleanup")
            assert control.wait(timeout=0.5) == 0
            if mode == "stdout-stall":
                assert_one_line(directory / "stderr", "time budget")
            return
        if mode == "parent-one":
            wait_for(lambda table: not observer.living(table), observer,
                     started + 3.5, "healthy PID-1 parent")
            assert control.wait(timeout=0.5) == 0
            assert b"/primer new-subsystem" in (directory / "stdout").read_bytes()
            return
        if mode == "mkdir-collision":
            wait_for(lambda table: not observer.living(table), observer,
                     started + 3.0, "temp-name collision fail-open")
            assert control.wait(timeout=0.5) == 0
            assert (collision / "keep").read_text(encoding="utf-8") == "owned by someone else"
            return
        if mode in slow_modes:
            wait_for(lambda _table: (directory / "filesystem-blocked").exists(), observer,
                     started + 2.5, "injected filesystem stall")
            if mode in ("mkdir-parent-death", "mkdir-supervisor-death"):
                event_at = time.monotonic()
                if mode == "mkdir-parent-death":
                    signal_exact(observer.identities[control.pid], signal.SIGKILL)
                    control.wait(timeout=0.5)
                else:
                    signal_exact(root, signal.SIGKILL)
                wait_for(lambda table: not observer.living(table), observer,
                         event_at + 1.5, "death during stalled directory creation")
                return
            if mode == "output-read-signal":
                event_at = time.monotonic()
                signal_exact(root, signal.SIGTERM)
                wait_for(lambda table: not observer.living(table), observer,
                         event_at + 1.5, "signal during stalled output read")
                assert not (directory / "stdout").read_bytes()
                return
            wait_for(lambda table: not observer.living(table), observer,
                     started + 4.0, "bounded filesystem stall and cleanup")
            assert control.wait(timeout=0.5) == 0
            if mode == "cleanup-stall":
                assert (directory / "stdout").read_bytes(), "completed advisory was lost"
                assert not (directory / "stderr").read_bytes()
            else:
                assert not (directory / "stdout").read_bytes()
                assert_one_line(directory / "stderr", "time budget")
            return
        if mode == "partial-output":
            wait_for(lambda _table: list(directory.glob("jq-*.json")), observer,
                     started + 2.0, "partial-output jq")
            assert not (directory / "stdout").read_bytes(), "partial JSON escaped the worker"
            wait_for(lambda table: not observer.living(table), observer,
                     started + 4.0, "partial-output deadline and cleanup")
            assert control.wait(timeout=0.5) == 0
            assert not (directory / "stdout").read_bytes(), "timed-out JSON escaped the worker"
            assert_one_line(directory / "stderr", "time budget")
            return
        if mode == "stdin":
            # Keep the input pipe open without sending EOF: the deadline must
            # cover cat as well as Git, and must clean the entire process tree.
            wait_for(lambda table: not observer.living(table), observer,
                     started + 4.0, "blocked stdin budget and descendant cleanup")
            assert control.wait(timeout=0.5) == 0, "blocked-stdin hook did not fail open"
            assert_one_line(directory / "stderr", "time budget")
            assert not list(directory.glob("trellis-primer-nudge.*")), "temporary directory survived"
            return
        if mode in ("flood", "untracked-flood"):
            # The outer limit protects the suite even against an unbounded old hook.
            wait_for(lambda table: not alive(root, table), observer, started + 6.0, "flood hook exit")
            elapsed = time.monotonic() - started
            assert control.wait(timeout=0.5) == 0, "flood hook did not fail open"
            assert elapsed <= 6.0, "flood scan exceeded six seconds: %.3f" % elapsed
            assert list(directory.glob("producer-*.json")), "fake Git producer was never invoked"
            wait_for(lambda table: not observer.living(table), observer,
                     time.monotonic() + 0.8, "all flood descendants to exit")
            assert not list(directory.glob("complete-*")), "all 500,000 names were consumed"
            assert_one_line(directory / "stderr", "scan limit")
            return

        def stalled(table):
            gits = [json.loads(path.read_text(encoding="utf-8"))
                    for path in directory.glob("git-*.json")]
            children = [json.loads(path.read_text(encoding="utf-8"))
                        for path in directory.glob("child-*.json")]
            for git in gits:
                for child in children:
                    if (child["ppid"] == git["pid"] and alive(root, table)
                            and alive(git, table) and alive(child, table)):
                        return git, child
            return None

        readiness_limit = 2.0 if mode == "deadline" else 1.2
        git, child = wait_for(stalled, observer, started + readiness_limit, "stalled git and its child")
        assert child.get("ignored") is True, "child did not inherit ignored SIGTERM"
        table = observer.sample()
        assert git["pid"] in descendants(root["pid"], table), "fake git is not a hook descendant"
        assert child["pid"] in descendants(root["pid"], table), "stalled child is not a hook descendant"
        # Establish that this is genuinely TERM-ignoring, not just recorded so.
        signal_exact(child, signal.SIGTERM)
        time.sleep(0.05)
        assert alive(child, observer.sample()), "stalled child did not ignore SIGTERM"

        if mode == "deadline":
            wait_for(lambda table: not observer.living(table), observer,
                     started + 4.0, "three-second budget and descendant cleanup")
            elapsed = time.monotonic() - started
            assert control.wait(timeout=0.5) == 0, "deadline hook did not fail open"
            assert elapsed <= 4.0, "three-second deadline took %.3f seconds" % elapsed
            assert_one_line(directory / "stderr", "time budget")
            return

        # Events must happen early enough that the ordinary three-second budget
        # cannot masquerade as prompt signal/parent-death handling.
        assert time.monotonic() - started < 1.2, "stall was reached too late to distinguish the deadline"
        table = observer.sample()
        assert alive(root, table) and alive(git, table) and alive(child, table), "stall ended before the event"
        event_at = time.monotonic()
        if mode == "parent-death":
            assert table[root["pid"]]["ppid"] == control.pid, "launcher is not the hook's immediate parent"
            signal_exact(observer.identities[control.pid], signal.SIGKILL)
            control.wait(timeout=0.5)
        elif mode == "supervisor-death":
            signal_exact(root, signal.SIGKILL)
        else:
            signal_exact(root, signal.SIGTERM)
        wait_for(lambda table: not observer.living(table), observer,
                 event_at + 1.5, "prompt event-driven descendant cleanup")
        assert not list(directory.glob("trellis-primer-nudge.*")), "temporary directory survived"
    finally:
        observer.cleanup()
        if control is not None:
            if control.stdin is not None:
                control.stdin.close()
            if getattr(control, "pcn_pipe_read", None) is not None:
                os.close(control.pcn_pipe_read)
            try:
                control.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                pass


def main():
    if os.path.basename(sys.argv[0]) == "git":
        fake_git()
    elif os.path.basename(sys.argv[0]) == "jq":
        fake_jq()
    elif sys.argv[1:] == ["--stall-child"]:
        stall_child()
    elif sys.argv[1:] == ["--launcher"]:
        launcher()
    else:
        if len(sys.argv) != 5:
            raise SystemExit("usage: primer-capture-nudge-process.py MODE HOOK PROJECT TMPDIR")
        # A cancelled Bats invocation still runs our PID-specific cleanup.
        def cancelled(signum, _frame):
            raise RuntimeError("test fixture interrupted by signal %d" % signum)
        signal.signal(signal.SIGTERM, cancelled)
        signal.signal(signal.SIGINT, cancelled)
        run_case(*sys.argv[1:])


if __name__ == "__main__":
    main()
