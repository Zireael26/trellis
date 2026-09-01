#!/usr/bin/env python3
"""Run the local process-gate test battery in four isolated shard processes.

The process-gate invokes this wrapper without arguments. The
TRELLIS_LOCAL_GATE_* environment variables are deliberately small seams for
hermetic tests; normal gate runs use the fixed runner, four shards, and the
3600-second deadline below.
"""

from __future__ import annotations

import math
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

SHARD_COUNT = 4
GLOBAL_DEADLINE_SECONDS = 3600.0
TERM_GRACE_SECONDS = 0.5
# Public timing TSV schema: ordinal, stage name, elapsed seconds, and exit code.
# `ordinal` is the 1-based position in the complete unsharded stage inventory.
RECEIPT_HEADER = "ordinal\tstage\telapsed_seconds\texit"


def _usage() -> str:
    return "usage: scripts/run-tests-local.py"


def _resolve_path(root: Path, value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = root / path
    return path


def _positive_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        value = float(raw)
    except ValueError as exc:
        raise ValueError("{} must be a positive number".format(name)) from exc
    if not math.isfinite(value) or value <= 0:
        raise ValueError("{} must be a positive number".format(name))
    return value


class _SignalExit(Exception):
    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


def _raise_if_interrupted(signum: Optional[int]) -> None:
    if signum is not None:
        raise _SignalExit(signum)


def _spawn_shard(
    record: Dict[str, Any],
    root: Path,
    runner: Path,
    environment: Dict[str, str],
    shard: int,
) -> None:
    """Register Popen before unblocking signals so no child escapes cleanup."""
    previous_mask = signal.pthread_sigmask(
        signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM}
    )
    try:
        process = subprocess.Popen(
            [
                "bash",
                str(runner),
                "--scope=local",
                "--shard={}/{}".format(shard, SHARD_COUNT),
            ],
            cwd=str(root),
            env=environment,
            stdout=record["output_file"],
            stderr=subprocess.STDOUT,
            start_new_session=True,
            # The child inherits the temporary parent mask across fork; restore
            # it before exec so TERM remains effective for the shard.
            preexec_fn=lambda: signal.pthread_sigmask(
                signal.SIG_SETMASK, previous_mask
            ),
        )
        record["process"] = process
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def _signal_group(process: subprocess.Popen, signum: int) -> None:
    """Signal a shard's session/process group, tolerating an exited leader."""
    try:
        os.killpg(process.pid, signum)
    except OSError:
        # The leader may have exited and its process group may already be gone.
        pass


def _terminate_groups(records: Sequence[Dict[str, Any]], grace: float) -> None:
    """TERM every shard group, then KILL every known group after the grace."""
    processes = [record["process"] for record in records if record["process"] is not None]
    for process in processes:
        _signal_group(process, signal.SIGTERM)

    grace_deadline = time.monotonic() + grace
    while time.monotonic() < grace_deadline:
        time.sleep(min(0.05, max(0.0, grace_deadline - time.monotonic())))

    # Signal every known group, not just leaders still reporting live.  A
    # shell can exit while a descendant keeps the group's work alive.
    for process in processes:
        _signal_group(process, signal.SIGKILL)
    for process in processes:
        try:
            process.wait()
        except OSError:
            pass


def _close_output_handles(records: Sequence[Dict[str, Any]]) -> None:
    for record in records:
        output_file = record.get("output_file")
        if output_file is None:
            continue
        try:
            output_file.close()
        except (OSError, ValueError):
            pass


def _write_aggregate(path: Path, records: Sequence[Dict[str, Any]]) -> None:
    rows: List[Tuple[int, int, str]] = []
    for record in records:
        receipt = record["receipt"]
        if not receipt.exists():
            continue
        with receipt.open("r", encoding="utf-8", newline="") as shard_receipt:
            for line_number, line in enumerate(shard_receipt, start=1):
                row = line.rstrip("\r\n")
                if not row or row == RECEIPT_HEADER:
                    continue
                fields = row.split("\t")
                if len(fields) != 4:
                    raise ValueError(
                        "invalid timing receipt row {}:{}: expected {} columns".format(
                            receipt, line_number, len(RECEIPT_HEADER.split("\t"))
                        )
                    )
                try:
                    ordinal = int(fields[0])
                except ValueError as exc:
                    raise ValueError(
                        "invalid timing receipt ordinal {}:{}".format(receipt, line_number)
                    ) from exc
                if ordinal < 1:
                    raise ValueError(
                        "invalid timing receipt ordinal {}:{}: {}".format(
                            receipt, line_number, ordinal
                        )
                    )
                rows.append((ordinal, record["shard"], row))

    rows.sort(key=lambda item: (item[0], item[1]))
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as aggregate:
        aggregate.write(RECEIPT_HEADER + "\n")
        for _, _, row in rows:
            aggregate.write(row + "\n")


def _replay_output(records: Sequence[Dict[str, Any]]) -> None:
    previous_had_bytes = False
    previous_ended_newline = True
    output = sys.stdout.buffer
    for record in records:
        data = record["output"].read_bytes() if record["output"].exists() else b""
        if not data:
            continue
        if previous_had_bytes and not previous_ended_newline:
            output.write(b"\n")
        output.write(data)
        previous_had_bytes = True
        previous_ended_newline = data.endswith(b"\n")
    if previous_had_bytes and not previous_ended_newline:
        output.write(b"\n")
    output.flush()


def _planned_totals(root: Path, runner: Path) -> List[str]:
    """Run the shard planner and return one total weight for every shard."""
    try:
        completed = subprocess.run(
            [
                "bash",
                str(runner),
                "--scope=local",
                "--shard=1/{}".format(SHARD_COUNT),
                "--plan",
            ],
            cwd=str(root),
            env=os.environ.copy(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    except OSError as exc:
        raise ValueError("could not start shard plan: {}".format(exc)) from exc

    if completed.returncode != 0:
        detail = completed.stderr.strip()
        message = "shard plan failed with status {}".format(completed.returncode)
        if detail:
            message += ": {}".format(detail)
        raise ValueError(message)

    totals: Dict[int, str] = {}
    for line in completed.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) != 3 or fields[0] != "total":
            continue
        try:
            shard = int(fields[1])
        except ValueError:
            continue
        if 1 <= shard <= SHARD_COUNT and fields[2]:
            totals[shard] = fields[2]

    missing = [
        str(shard)
        for shard in range(1, SHARD_COUNT + 1)
        if shard not in totals
    ]
    if missing:
        raise ValueError(
            "shard plan missing total rows for shard(s): {}".format(", ".join(missing))
        )
    return [totals[shard] for shard in range(1, SHARD_COUNT + 1)]


def _parse_arguments(argv: Sequence[str]) -> Optional[int]:
    """Validate before any temporary files or child processes are created."""
    if not argv:
        return None
    if len(argv) == 1 and argv[0] in ("-h", "--help"):
        print(_usage())
        return 0
    print("run-tests-local: invalid arguments", file=sys.stderr)
    print(_usage(), file=sys.stderr)
    return 64


def _new_aggregate_path(root: Path) -> Path:
    configured = os.environ.get("TRELLIS_LOCAL_GATE_RECEIPT")
    if configured:
        return _resolve_path(root, configured)
    fd, name = tempfile.mkstemp(prefix="trellis-run-tests-aggregate-", suffix=".tsv")
    os.close(fd)
    return Path(name)


def _status(record: Dict[str, Any], timed_out: Set[int]) -> int:
    shard = record["shard"]
    if shard in timed_out:
        return 124
    if record["process"] is None:
        return 127
    returncode = record["process"].returncode
    return int(returncode) if returncode is not None else 1


def main(argv: Sequence[str]) -> int:
    argument_status = _parse_arguments(argv)
    if argument_status is not None:
        return argument_status

    root = Path(__file__).resolve().parent.parent
    runner_value = os.environ.get("TRELLIS_LOCAL_GATE_RUNNER")
    runner = _resolve_path(root, runner_value) if runner_value else root / "scripts" / "run-tests.sh"
    try:
        deadline = _positive_float("TRELLIS_LOCAL_GATE_DEADLINE", GLOBAL_DEADLINE_SECONDS)
        grace = _positive_float("TRELLIS_LOCAL_GATE_TERM_GRACE", TERM_GRACE_SECONDS)
        aggregate = _new_aggregate_path(root)
    except (OSError, ValueError) as exc:
        print("run-tests-local: {}".format(exc), file=sys.stderr)
        return 64

    timed_out_shards: Set[int] = set()
    records: List[Dict[str, Any]] = []
    temporary_root = tempfile.TemporaryDirectory(prefix="trellis-run-tests-")
    previous_handlers = {
        signal.SIGINT: signal.getsignal(signal.SIGINT),
        signal.SIGTERM: signal.getsignal(signal.SIGTERM),
    }
    interrupt_signum: Optional[int] = None

    def remember_signal(signum: int, _frame: Any) -> None:
        nonlocal interrupt_signum
        if interrupt_signum is None:
            interrupt_signum = signum

    signal.signal(signal.SIGINT, remember_signal)
    signal.signal(signal.SIGTERM, remember_signal)
    completed_normally = False
    groups_terminated = False
    result_status: Optional[int] = None
    try:
        temp_root = Path(temporary_root.name)
        deadline_at = time.monotonic() + deadline
        try:
            planned_totals = _planned_totals(root, runner)
        except ValueError as exc:
            _raise_if_interrupted(interrupt_signum)
            print("run-tests-local: {}".format(exc), file=sys.stderr)
            return 1
        print(
            "run-tests-local: planned shard totals: {}".format(
                ", ".join(
                    "shard {}={}".format(shard, planned_totals[shard - 1])
                    for shard in range(1, SHARD_COUNT + 1)
                )
            )
        )
        for shard in range(1, SHARD_COUNT + 1):
            _raise_if_interrupted(interrupt_signum)
            output_path = temp_root / "shard-{}.out".format(shard)
            receipt_path = temp_root / "shard-{}.tsv".format(shard)
            receipt_path.write_text(RECEIPT_HEADER + "\n", encoding="utf-8")
            output_file = output_path.open("wb")
            started = time.monotonic()
            environment = os.environ.copy()
            environment["TRELLIS_TEST_TSV"] = str(receipt_path)
            record: Dict[str, Any] = {
                "shard": shard,
                "output": output_path,
                "receipt": receipt_path,
                "output_file": output_file,
                "process": None,
                "spawn_error": None,
                "started": started,
                "finished": None,
            }
            records.append(record)
            try:
                _spawn_shard(record, root, runner, environment, shard)
            except OSError as exc:
                # A successful Popen is already recorded.  Only an unstarted
                # shard is converted into the normal 127 spawn-error result.
                if record["process"] is not None:
                    raise
                record["spawn_error"] = exc
                record["finished"] = started
                output_file.write(
                    "run-tests-local: could not start shard {}: {}\n".format(shard, exc).encode()
                )
                output_file.flush()
            _raise_if_interrupted(interrupt_signum)

        pending = [record for record in records if record["process"] is not None]
        while pending:
            _raise_if_interrupted(interrupt_signum)
            now = time.monotonic()
            still_pending: List[Dict[str, Any]] = []
            for record in pending:
                process = record["process"]
                if process.poll() is None:
                    still_pending.append(record)
                else:
                    record["finished"] = now
            pending = still_pending
            if not pending:
                break
            remaining = deadline_at - time.monotonic()
            if remaining <= 0:
                timed_out_shards = {record["shard"] for record in pending}
                _terminate_groups(records, grace)
                groups_terminated = True
                finished = time.monotonic()
                for record in pending:
                    record["finished"] = finished
                break
            time.sleep(min(0.05, remaining))

        _raise_if_interrupted(interrupt_signum)
        for record in records:
            output_file = record["output_file"]
            output_file.close()
            if record["process"] is not None:
                record["process"].poll()

        _raise_if_interrupted(interrupt_signum)
        _write_aggregate(aggregate, records)
        _raise_if_interrupted(interrupt_signum)
        _replay_output(records)

        _raise_if_interrupted(interrupt_signum)
        for record in records:
            finished = record["finished"] or time.monotonic()
            elapsed = max(0.0, finished - record["started"])
            print(
                "run-tests-local: shard {}/{} elapsed_seconds={:.3f} status={}".format(
                    record["shard"], SHARD_COUNT, elapsed, _status(record, timed_out_shards)
                )
            )
        if timed_out_shards:
            print(
                "run-tests-local: global deadline exceeded; terminated then killed live process groups",
                file=sys.stderr,
            )
        print("run-tests-local: aggregate receipt: {}".format(aggregate))
        _raise_if_interrupted(interrupt_signum)
        result_status = (
            124
            if timed_out_shards
            else 0
            if all(_status(record, timed_out_shards) == 0 for record in records)
            else 1
        )
        completed_normally = True
    except _SignalExit as interruption:
        result_status = 128 + interruption.signum
        print(
            "run-tests-local: interrupted by {}".format(
                signal.Signals(interruption.signum).name
            ),
            file=sys.stderr,
        )
    finally:
        try:
            if not completed_normally and not groups_terminated:
                _terminate_groups(records, grace)
                groups_terminated = True
        finally:
            _close_output_handles(records)
            try:
                temporary_root.cleanup()
            except (OSError, ValueError):
                pass
            for signum, handler in previous_handlers.items():
                try:
                    signal.signal(signum, handler)
                except (OSError, ValueError):
                    pass

    if interrupt_signum is not None:
        return 128 + interrupt_signum
    if result_status is None:
        return 1
    return result_status


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
