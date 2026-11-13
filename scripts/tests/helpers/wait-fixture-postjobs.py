#!/usr/bin/env python3
"""Wait for release-store postjobs that can still access one private fixture.

They are detached grandchildren, so the fixture shell cannot reap them. Match
literal fixture paths in the full process command, retain each discovered PID's
birth time until it exits (even if it execs something else), and rescan for
late arrivals. Never signal a process. A failed/indeterminate scan is an error,
not evidence that the fixture is safe to delete.
"""

from __future__ import annotations

import math
import os
import re
import subprocess
import sys
import time


def main() -> int:
    if len(sys.argv) != 3:
        print("fixture postjob wait: expected FIXTURE and TIMEOUT", file=sys.stderr)
        return 1
    fixture = sys.argv[1]
    try:
        timeout = float(sys.argv[2])
    except ValueError:
        timeout = 0
    if (
        not os.path.isabs(fixture)
        or fixture == "/"
        or os.path.normpath(fixture) != fixture
        or os.path.realpath(fixture) != fixture
        or "\n" in fixture
        or "\r" in fixture
        or not math.isfinite(timeout)
        or timeout <= 0
    ):
        print("fixture postjob wait: unsafe fixture path or timeout", file=sys.stderr)
        return 1

    # Fixture homes are direct children, with the standard release layout.
    # Match a complete path rather than unrelated substrings in flattened ps
    # argv; re.escape keeps spaces and regexp metacharacters literal.
    postjob_path = re.compile(
        r"(?<!\S)"
        + re.escape(fixture + "/")
        + r"[^/\r\n]+/releases/[^/\r\n]+/payload/scripts/lib/attach-postjob\.sh(?=\s|$)"
    )
    deadline = time.monotonic() + timeout
    tracked: dict[int, str] = {}
    quiet_scans = 0
    ps_env = dict(os.environ, LC_ALL="C")
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print(
                f"fixture postjob wait: timed out for {fixture}; "
                f"live pids: {', '.join(map(str, sorted(tracked))) or 'unknown'}",
                file=sys.stderr,
            )
            return 1
        try:
            snapshot = subprocess.run(
                ["/bin/ps", "-axww", "-o", "pid=,state=,lstart=,command="],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                errors="replace",
                env=ps_env,
                timeout=min(remaining, 15),
            ).stdout
        except (OSError, subprocess.SubprocessError) as error:
            print(f"fixture postjob wait: process scan failed: {error}", file=sys.stderr)
            return 1

        processes: dict[int, tuple[str, str, str]] = {}
        for line in snapshot.splitlines():
            fields = line.strip().split(None, 7)
            if len(fields) < 7 or not fields[0].isdigit():
                continue
            pid = int(fields[0])
            birth = " ".join(fields[2:7])
            command = fields[7] if len(fields) == 8 else ""
            processes[pid] = (birth, fields[1], command)
        if os.getpid() not in processes:
            print("fixture postjob wait: incomplete process snapshot", file=sys.stderr)
            return 1

        for pid, birth in list(tracked.items()):
            current = processes.get(pid)
            if current is None:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    del tracked[pid]
                    continue
                except OSError as error:
                    print(f"fixture postjob wait: cannot inspect pid {pid}: {error}", file=sys.stderr)
                    return 1
                print(f"fixture postjob wait: live pid {pid} missing from process snapshot", file=sys.stderr)
                return 1
            if current[0] != birth or current[1].startswith(("Z", "X")):
                del tracked[pid]
        for pid, (birth, state, command) in processes.items():
            if (
                pid != os.getpid()
                and not state.startswith(("Z", "X"))
                and postjob_path.search(command)
            ):
                tracked[pid] = birth

        if tracked:
            quiet_scans = 0
        else:
            # Spawn returns only after the detached child exists. Two quiet
            # scans reduce, but cannot eliminate, an argv/exec observation gap.
            quiet_scans += 1
            if quiet_scans >= 2:
                return 0
        time.sleep(min(0.1, max(0, deadline - time.monotonic())))


if __name__ == "__main__":
    sys.exit(main())
