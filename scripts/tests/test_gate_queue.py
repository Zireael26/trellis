"""Real-process queue tests; no planner, shards, or host state."""
import contextlib
import fcntl
import importlib.util
import io
import json
import os
import signal
import threading
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("gate_queue", Path(__file__).resolve().parents[1] / "run-tests-local.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


def worker():
    GATE.RunState.POLL_SECONDS = .03
    GATE.RunState.HEARTBEAT_SECONDS = .04
    state = GATE.RunState(sys.argv[2], no_wait=sys.argv[3] == "no-wait")
    try:
        Path(sys.argv[4]).write_text(json.dumps(state.entry))
        while not Path(sys.argv[5]).exists():
            state.check()
            time.sleep(.02)
    finally:
        state.close()


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = mock.patch.dict(os.environ, {
            "TRELLIS_GATE_STATE_DIR": str(self.root / "state"),
            "TRELLIS_LOCAL_GATE_QUEUE_WAIT": "2"})
        self.env.start()
        self.children = []

    def tearDown(self):
        for child, log in self.children:
            if child.poll() is None:
                child.kill()
            child.wait()
            log.close()
        self.env.stop()
        self.tmp.cleanup()

    def wait_for(self, predicate):
        end = time.monotonic() + 5
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(.02)
        self.fail("queue did not reach expected state")

    def start(self, name, no_wait=False, head=None, cwd=None, **environment):
        log = (self.root / (name + ".log")).open("w")
        child = subprocess.Popen([sys.executable, "-I", "-B", __file__, "worker", head or name,
                                  "no-wait" if no_wait else "wait", str(self.root / name),
                                  str(self.root / (name + ".release"))],
                                 cwd=cwd, stdout=log, stderr=log, env=os.environ | environment)
        self.children.append((child, log))
        return child

    def release(self, name, child):
        (self.root / (name + ".release")).touch()
        self.assertEqual(child.wait(timeout=5), 0, (self.root / (name + ".log")).read_text())

    def tickets(self):
        return sorted((self.root / "state/gate-queue").glob("*.json"))

    def test_serial_and_heartbeat(self):
        first = self.start("first")
        self.wait_for(lambda: (self.root / "first").exists())
        initial = json.loads((self.root / "first").read_text())["heartbeat"]
        second = self.start("second")
        self.wait_for(lambda: len(self.tickets()) == 1)
        ticket = self.tickets()[0]
        waiting = json.loads(ticket.read_text())["heartbeat"]
        holder = self.root / "state/gate-holder.json"
        self.wait_for(lambda: json.loads(holder.read_text())["heartbeat"] > initial and
                      json.loads(ticket.read_text())["heartbeat"] > waiting)
        self.assertFalse((self.root / "second").exists(), "concurrent holder admitted")
        self.release("first", first)
        self.wait_for(lambda: (self.root / "second").exists())
        self.release("second", second)
        self.assertFalse(holder.exists())
        self.assertEqual(self.tickets(), [])
        text = (self.root / "second.log").read_text()
        self.assertIn("position=1 holder=first estimated_start=7200.0s", text)

    def test_default_state_root_ignores_agent_and_cron_xdg(self):
        home = self.root / "home"
        home.mkdir()
        with mock.patch.dict(os.environ, {"HOME": str(home)}):
            os.environ.pop("TRELLIS_GATE_STATE_DIR")
            expected = home / ".local/state/trellis-gate"
            for xdg in (str(self.root / "agent-state"), str(self.root / "cron-state"), "", "relative"):
                with self.subTest(xdg=xdg), mock.patch.dict(os.environ, {"XDG_STATE_HOME": xdg}):
                    self.assertEqual(GATE.gate_state_root(), expected)
                    state = GATE.RunState("pinned", no_wait=True)
                    self.assertEqual(state.root, expected)
                    state.close()
            self.assertFalse((self.root / "agent-state").exists())
            self.assertFalse((self.root / "cron-state").exists())

    def test_state_root_refuses_relative_checkout_and_symlink_into_checkout(self):
        repo = self.root / "repo"
        repo.mkdir()
        (repo / ".git").mkdir()
        link = self.root / "checkout-link"
        link.symlink_to(repo, target_is_directory=True)
        for configured in ("relative-state", "", str(repo / "state"), str(link / "state")):
            with self.subTest(root=configured), mock.patch.dict(os.environ, {"TRELLIS_GATE_STATE_DIR": configured}):
                with self.assertRaisesRegex(GATE.ContainmentError, "state root must"):
                    GATE.RunState("refused", no_wait=True)
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(GATE.main(["--runs-status"]), 70)
                self.assertFalse((repo / "state").exists())
        # Linked worktrees use a .git file, not a directory.
        (repo / ".git").rmdir()
        (repo / ".git").write_text("gitdir: elsewhere\n")
        with mock.patch.dict(os.environ, {"TRELLIS_GATE_STATE_DIR": str(repo / "state")}):
            with self.assertRaisesRegex(GATE.ContainmentError, "outside every checkout"):
                GATE.RunState("refused", no_wait=True)
        self.assertFalse((repo / "state").exists())

    def test_holder_keeps_legacy_lock_until_close(self):
        state = GATE.RunState("current")
        try:
            self.assertEqual((state.root / "queue.lock").stat().st_mode & 0o777, 0o600)
            with (state.root / "lock").open("r+") as legacy:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(legacy.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            state.close()
        with (state.root / "lock").open("r+") as legacy:
            fcntl.flock(legacy.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(legacy.fileno(), fcntl.LOCK_UN)

    def test_legacy_holder_blocks_queue_and_no_wait(self):
        root = self.root / "state"
        root.mkdir(mode=0o700)
        fd = os.open(str(root / "lock"), os.O_RDWR | os.O_CREAT, 0o600)
        with os.fdopen(fd, "r+") as legacy:
            fcntl.flock(legacy.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            refused = self.start("legacy-no-wait", no_wait=True)
            self.assertEqual(refused.wait(timeout=5), 70)
            self.assertFalse((self.root / "legacy-no-wait").exists())
            self.assertEqual(self.tickets(), [])
            waiting = self.start("waiting")
            self.wait_for(lambda: len(self.tickets()) == 1)
            self.assertFalse((self.root / "waiting").exists())
            self.assertFalse((root / "gate-holder.json").exists())
            self.wait_for(lambda: "holder=legacy-lock" in (self.root / "waiting.log").read_text())
            fcntl.flock(legacy.fileno(), fcntl.LOCK_UN)
            self.wait_for(lambda: (self.root / "waiting").exists())
            self.release("waiting", waiting)

    def test_kill_holder(self):
        first = self.start("first")
        self.wait_for(lambda: (self.root / "first").exists())
        second = self.start("second")
        self.wait_for(lambda: len(self.tickets()) == 1)
        self.assertFalse((self.root / "second").exists())
        first.kill()
        first.wait()
        self.wait_for(lambda: (self.root / "second").exists())
        self.release("second", second)
        evidence = list((self.root / "state").glob("gate-holder.json.quarantine-*"))
        self.assertEqual(len(evidence), 1)
        self.assertEqual(json.loads(evidence[0].read_text())["pid"], first.pid)

    def test_kill_head_waiter(self):
        first = self.start("first")
        self.wait_for(lambda: (self.root / "first").exists())
        head = self.start("head")
        self.wait_for(lambda: len(self.tickets()) == 1)
        tail = self.start("tail")
        self.wait_for(lambda: len(self.tickets()) == 2)
        head.kill()
        head.wait()
        self.release("first", first)
        self.wait_for(lambda: (self.root / "tail").exists())
        self.release("tail", tail)
        evidence = list((self.root / "state/gate-queue").glob("*.quarantine-*"))
        self.assertEqual(len(evidence), 1)
        self.assertEqual(json.loads(evidence[0].read_text())["pid"], head.pid)

    def test_racing_tickets(self):
        first = self.start("first")
        self.wait_for(lambda: (self.root / "first").exists())
        racers = {name: self.start(name) for name in ("a", "b", "c", "d")}
        self.wait_for(lambda: len(self.tickets()) == 4)
        tickets = self.tickets()
        self.assertEqual(len({p.name for p in tickets}), 4)
        order = [json.loads(p.read_text())["head"] for p in tickets]
        self.release("first", first)
        for index, name in enumerate(order):
            self.wait_for(lambda: (self.root / name).exists())
            self.assertTrue(all(not (self.root / other).exists() for other in order[index + 1:]))
            self.release(name, racers[name])

    def test_bounded_and_no_wait(self):
        first = self.start("first")
        self.wait_for(lambda: (self.root / "first").exists())
        for name, no_wait in (("bounded", False), ("no-wait", True)):
            child = self.start(name, no_wait, TRELLIS_LOCAL_GATE_QUEUE_WAIT=".15")
            self.assertEqual(child.wait(timeout=5), 70)
            self.assertFalse((self.root / name).exists())
            self.assertIn("queue", (self.root / (name + ".log")).read_text())
        self.assertEqual(self.tickets(), [])
        self.release("first", first)

    def test_corrupt_counter_refuses_without_following_symlinks(self):
        state = GATE.RunState("fixture")
        state.close()
        counter = self.root / "state/gate-queue/next"
        self.assertEqual(counter.stat().st_mode & 0o777, 0o600)
        victim = self.root / "counter-victim"
        victim.write_text("100\n")
        counter.unlink()
        counter.symlink_to(victim)
        with self.assertRaisesRegex(GATE.ContainmentError, "corrupt queue next ticket"):
            GATE.RunState("blocked", no_wait=True)
        self.assertTrue(counter.is_symlink())
        self.assertEqual(victim.read_text(), "100\n")
        counter.unlink()
        counter.write_text("corrupt\n")
        counter.chmod(0o600)
        with self.assertRaisesRegex(GATE.ContainmentError, "corrupt queue next ticket"):
            GATE.RunState("blocked", no_wait=True)
        self.assertEqual(counter.read_text(), "corrupt\n")

    def test_corrupt_holder_refuses(self):
        state = GATE.RunState("fixture")
        state.close()
        holder = self.root / "state/gate-holder.json"
        holder.write_text("not json")
        holder.chmod(0o600)
        with self.assertRaisesRegex(GATE.ContainmentError, "corrupt queue entry"):
            GATE.RunState("blocked", no_wait=True)
        self.assertEqual(holder.read_text(), "not json")

    def test_corrupt_waiter_quarantined(self):
        state = GATE.RunState("fixture")
        state.close()
        waiter = self.root / "state/gate-queue/00000000000000000001.json"
        waiter.write_text("not json")
        waiter.chmod(0o600)
        state = GATE.RunState("success", no_wait=True)
        state.close()
        evidence = list(waiter.parent.glob(waiter.name + ".quarantine-*"))
        self.assertEqual(len(evidence), 1)
        self.assertEqual(evidence[0].read_text(), "not json")

    def test_heartbeat_thread_cannot_consume_registration_signals(self):
        ready = threading.Event()
        observed = []
        original = GATE.RunState._heartbeat
        def heartbeat(state):
            observed.extend(signal.pthread_sigmask(signal.SIG_BLOCK, set()))
            ready.set()
            original(state)
        before = signal.pthread_sigmask(signal.SIG_BLOCK, set())
        with mock.patch.object(GATE.RunState, "_heartbeat", heartbeat):
            state = GATE.RunState("fixture")
        try:
            self.assertTrue(ready.wait(2))
            self.assertTrue({signal.SIGINT, signal.SIGTERM, signal.SIGALRM} <= set(observed))
            self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, set()), before)
        finally:
            state.close()

    def test_shutdown_retains_lease_when_heartbeat_wedged(self):
        state = GATE.RunState("fixture")
        state.stop.set()
        state.thread.join()
        original = state.thread
        state.thread = mock.Mock()
        state.thread.is_alive.return_value = True
        try:
            with self.assertRaisesRegex(GATE.ContainmentError, "shutdown unverified"):
                state.close(time.monotonic() + .02)
            self.assertTrue(state.holder.exists())
            timeout = state.thread.join.call_args.args[0]
            self.assertGreaterEqual(timeout, 0)
            self.assertLessEqual(timeout, .02)
        finally:
            state.thread = original
            state.close()

    def test_wait_is_outside_deadline(self):
        original = GATE.RunState
        def admission(**kwargs):
            time.sleep(.2)
            return original(**kwargs)
        def capability(end, **kwargs):
            self.assertGreater(end - time.monotonic(), .25, "queue spent productive deadline")
            raise GATE.ContainmentError("stop before any planner")
        with mock.patch.dict(os.environ, {"TRELLIS_LOCAL_GATE_DEADLINE": ".4",
                "TRELLIS_LOCAL_GATE_RESERVE": ".1", "TRELLIS_LOCAL_GATE_TERM_GRACE": ".01"}), \
                mock.patch.object(GATE, "RunState", side_effect=admission), \
                mock.patch.object(GATE, "safe_capture", return_value={"head": "fixture"}), \
                mock.patch.object(GATE, "emit"), \
                mock.patch.object(GATE, "_capability", side_effect=capability), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(GATE.main([]), 70)

    def test_same_stale_rule_requires_two_checks(self):
        state = GATE.RunState("fixture")
        try:
            for path in (state.queue / "00000000000000000000.json", state.holder):
                entry = state.entry | {"token": "a" * 32, "heartbeat": time.time() - 61}
                GATE.save_record(path, entry)
                state.stale.clear()
                with mock.patch.object(GATE, "process_identity", return_value=(entry["pid"], entry["start_us"])):
                    self.assertEqual(state._live(path, holder=path == state.holder), entry)
                    self.assertIsNone(state._live(path, holder=path == state.holder))
                self.assertFalse(path.exists())
        finally:
            state.path = None
            state.close()

    def test_supersede_queued_waiter_same_worktree_and_branch(self):
        wt_other = str(self.root / "wt-other")
        wt_same = str(self.root / "wt-same")
        holder = self.start("holder", head="0" * 40,
                            TRELLIS_GATE_WORKTREE=wt_other, TRELLIS_GATE_BRANCH="feat/other")
        self.wait_for(lambda: (self.root / "holder").exists())
        older = self.start("older-waiter", head="1" * 40,
                           TRELLIS_GATE_WORKTREE=wt_same, TRELLIS_GATE_BRANCH="feat/same")
        self.wait_for(lambda: len(self.tickets()) == 1)
        newer = self.start("newer-waiter", head="2" * 40,
                           TRELLIS_GATE_WORKTREE=wt_same, TRELLIS_GATE_BRANCH="feat/same")
        self.assertEqual(older.wait(timeout=5), 70)
        self.assertFalse((self.root / "older-waiter").exists())
        older_log = (self.root / "older-waiter.log").read_text()
        self.assertIn("superseded by newer run on feat/same", older_log)
        self.wait_for(lambda: len(self.tickets()) == 1)
        self.release("holder", holder)
        self.wait_for(lambda: (self.root / "newer-waiter").exists())
        entry = json.loads((self.root / "newer-waiter").read_text())
        self.assertEqual(entry["branch"], "feat/same")
        self.assertEqual(entry["worktree"], os.path.realpath(wt_same))
        self.release("newer-waiter", newer)
        self.assertFalse((self.root / "state/gate-supersede.json").exists())

    def test_supersede_active_holder_on_new_head_and_keep_same_head(self):
        wt = str(self.root / "wt-active")
        first = self.start("holder-v1", head="1" * 40,
                           TRELLIS_GATE_WORKTREE=wt, TRELLIS_GATE_BRANCH="feat/cancel")
        self.wait_for(lambda: (self.root / "holder-v1").exists())
        # Same head does NOT cancel the active holder, though it queues cleanly.
        same_head = self.start("waiter-same-head", head="1" * 40,
                               TRELLIS_GATE_WORKTREE=wt, TRELLIS_GATE_BRANCH="feat/cancel")
        self.wait_for(lambda: len(self.tickets()) == 1)
        time.sleep(.12)
        self.assertIsNone(first.poll(), "same-head waiter must not cancel active holder")
        # Newer head supersedes BOTH the queued waiter and the active holder.
        newer = self.start("holder-v2", head="2" * 40,
                           TRELLIS_GATE_WORKTREE=wt, TRELLIS_GATE_BRANCH="feat/cancel")
        self.assertEqual(same_head.wait(timeout=5), 70)
        self.assertEqual(first.wait(timeout=5), 70)
        self.assertIn("superseded by newer run on feat/cancel (" + "2" * 40 + ")",
                      (self.root / "holder-v1.log").read_text())
        self.wait_for(lambda: (self.root / "holder-v2").exists())
        self.release("holder-v2", newer)
        self.assertFalse((self.root / "state/gate-holder.json").exists())
        self.assertFalse((self.root / "state/gate-supersede.json").exists())

    def test_parallel_worktrees_branches_main_and_killswitch_never_cancel(self):
        wt_a = str(self.root / "wt-lane-a")
        wt_b = str(self.root / "wt-lane-b")
        holder = self.start("lane-a-holder", head="1" * 40,
                            TRELLIS_GATE_WORKTREE=wt_a, TRELLIS_GATE_BRANCH="feat/shared")
        self.wait_for(lambda: (self.root / "lane-a-holder").exists())
        # Separate worktree (even same branch string) must NEVER cancel Lane A.
        lane_b = self.start("lane-b", head="2" * 40,
                            TRELLIS_GATE_WORKTREE=wt_b, TRELLIS_GATE_BRANCH="feat/shared")
        self.wait_for(lambda: len(self.tickets()) == 1)
        # Same worktree, different branch must NEVER cancel.
        other_branch = self.start("other-branch", head="3" * 40,
                                  TRELLIS_GATE_WORKTREE=wt_a, TRELLIS_GATE_BRANCH="feat/other")
        self.wait_for(lambda: len(self.tickets()) == 2)
        # Protected trunk branch (main) must NEVER cancel even on same worktree/main.
        main_one = self.start("main-1", head="4" * 40,
                              TRELLIS_GATE_WORKTREE=wt_a, TRELLIS_GATE_BRANCH="main")
        self.wait_for(lambda: len(self.tickets()) == 3)
        main_two = self.start("main-2", head="5" * 40,
                              TRELLIS_GATE_WORKTREE=wt_a, TRELLIS_GATE_BRANCH="main")
        self.wait_for(lambda: len(self.tickets()) == 4)
        # Kill-switch TRELLIS_GATE_SUPERSEDE=0 disables superseding on same (wt, branch).
        disabled = self.start("supersede-off", head="6" * 40,
                              TRELLIS_GATE_WORKTREE=wt_a, TRELLIS_GATE_BRANCH="feat/shared",
                              TRELLIS_GATE_SUPERSEDE="0")
        self.wait_for(lambda: len(self.tickets()) == 5)
        time.sleep(.12)
        self.assertIsNone(holder.poll())
        for name, proc in (("lane-a-holder", holder), ("lane-b", lane_b),
                           ("other-branch", other_branch), ("main-1", main_one),
                           ("main-2", main_two), ("supersede-off", disabled)):
            self.wait_for(lambda n=name: (self.root / n).exists())
            self.release(name, proc)

    def test_git_worktree_autodetect_and_detached_head(self):
        repo_a = self.root / "git-wt-a"
        repo_b = self.root / "git-wt-b"
        repo_a.mkdir()
        git_env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
        def git(cwd, *args):
            return subprocess.check_output(
                ["git", "-c", "user.name=T", "-c", "user.email=t@t.invalid",
                 "-c", "commit.gpgsign=false", *args],
                cwd=cwd, env=git_env, text=True, stderr=subprocess.DEVNULL,
            ).strip()
        git(repo_a, "init", "-q", "-b", "feat/auto-a")
        sha1 = git(repo_a, "commit", "--allow-empty", "-m", "c1") and git(repo_a, "rev-parse", "HEAD")
        sha1 = git(repo_a, "rev-parse", "HEAD")
        git(repo_a, "worktree", "add", "-q", "-b", "feat/auto-b", str(repo_b))
        sha_b = git(repo_b, "commit", "--allow-empty", "-m", "b1") or git(repo_b, "rev-parse", "HEAD")
        sha_b = git(repo_b, "rev-parse", "HEAD")

        a1 = self.start("auto-a1", head=sha1, cwd=repo_a)
        self.wait_for(lambda: (self.root / "auto-a1").exists())
        entry_a1 = json.loads((self.root / "auto-a1").read_text())
        self.assertEqual(entry_a1["worktree"], os.path.realpath(repo_a))
        self.assertEqual(entry_a1["branch"], "feat/auto-a")

        # Linked worktree B does not cancel worktree A.
        b1 = self.start("auto-b1", head=sha_b, cwd=repo_b)
        self.wait_for(lambda: len(self.tickets()) == 1)
        time.sleep(.1)
        self.assertIsNone(a1.poll())

        # New commit on worktree A supersedes auto-a1 while preserving auto-b1 ahead of auto-a2.
        git(repo_a, "commit", "--allow-empty", "-m", "c2")
        sha2 = git(repo_a, "rev-parse", "HEAD")
        a2 = self.start("auto-a2", head=sha2, cwd=repo_a)
        self.assertEqual(a1.wait(timeout=5), 70)
        self.wait_for(lambda: (self.root / "auto-b1").exists())
        self.release("auto-b1", b1)
        self.wait_for(lambda: (self.root / "auto-a2").exists())
        self.release("auto-a2", a2)

        # Detached HEAD omits branch.
        git(repo_a, "checkout", "-q", "--detach", sha2)
        det = self.start("auto-detached", head=sha2, cwd=repo_a)
        self.wait_for(lambda: (self.root / "auto-detached").exists())
        entry_det = json.loads((self.root / "auto-detached").read_text())
        self.assertEqual(entry_det["worktree"], os.path.realpath(repo_a))
        self.assertNotIn("branch", entry_det)
        self.release("auto-detached", det)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "worker":
        try:
            worker()
        except GATE.ContainmentError as exc:
            print(exc, file=sys.stderr)
            raise SystemExit(70)
    else:
        with contextlib.redirect_stdout(io.StringIO()):
            unittest.main()
