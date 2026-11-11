#!/usr/bin/env python3
"""Execute one requirements-bound command and retain acquired runtime evidence."""
import argparse
import math
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True
# -B/dont_write_bytecode alone still read a matching source-tree .pyc. Start
# local imports with an empty private cache prefix, before identity validation.
sys.pycache_prefix = tempfile.mkdtemp(prefix="qualification-import-cache-")
sys.path.insert(0, str(Path(__file__).resolve().parent))
from model import BASELINE, acquire_artifacts, digest, git, host_snapshot, make_scratch, recorder_identity, safe_relative, snapshot, value_digest
from schema import EvidenceError, load, loads, validate_named

RECORDER_ROOT = Path(__file__).resolve().parents[2]


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def expand_command(requirement, root, cwd, revision, variant):
    substitutions = {"{runtime}": os.path.relpath(root, cwd), "{recorder}": os.path.relpath(RECORDER_ROOT, cwd),
                     "{candidate_sha}": revision, "{variant}": variant}
    result = []
    for value in requirement["argv"]:
        for token, replacement in substitutions.items():
            value = value.replace(token, replacement)
        result.append(value)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--requirements", type=Path, required=True)
    parser.add_argument("--requirement", required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--runtime-kind", choices=("source", "installed"), default="source")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--scratch-base", type=Path, help="Private parent on the measured/runtime filesystem; defaults to TMPDIR.")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--phase", choices=("oracle", "build", "before", "after"), default="oracle")
    parser.add_argument("--variant", default="warm")
    parser.add_argument("--generation", help="Explicitly label a non-clean diagnostic input generation; not qualification.")
    parser.add_argument("--timeout", type=float)
    parser.add_argument("--emulated", action="store_true", help="Label known emulation; never forces a native claim.")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    try:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", args.run_id):
            raise EvidenceError("unsafe run ID")
        if args.timeout is not None and (not math.isfinite(args.timeout) or args.timeout <= 0):
            raise EvidenceError("timeout must be positive")
        requirements_bytes = args.requirements.read_bytes()
        requirements = loads(requirements_bytes.decode("utf-8"))
        validate_named("requirements", requirements)
        matches = [item for item in requirements["commands"] if item["id"] == args.requirement]
        if len(matches) != 1:
            raise EvidenceError("requirement must identify one command")
        requirement = matches[0]
        root = args.runtime.resolve(strict=True)
        if args.runtime_kind == "source" and Path(git(root, "rev-parse", "--show-toplevel").decode().strip()).resolve() != root:
            raise EvidenceError("runtime must name its checkout root")
        runtime_root = root if args.runtime_kind == "source" else root / "payload"
        cwd = (runtime_root / safe_relative(requirement["cwd"])).resolve(strict=True)
        if cwd != runtime_root and runtime_root not in cwd.parents:
            raise EvidenceError("command cwd escapes selected runtime")
        scope = "native-build" if requirement["kind"] == "build" else "runtime"
        revision, expected, inputs, installed_digest = snapshot(root, args.runtime_kind, requirements, requirement, scope)
        clean = inputs == expected
        if not clean and not args.generation:
            raise EvidenceError("qualified runtime inputs differ from committed bytes; explicit generation required")
        if args.phase == "before" and revision != BASELINE:
            raise EvidenceError("before runtime must be pinned 3661cb5f2")
        recorder_sha, recorder_digest, harness_inputs = recorder_identity(RECORDER_ROOT, include_inputs=True)
        command = expand_command(requirement, runtime_root, cwd, revision, args.variant)
        supplied = args.command[1:] if args.command[:1] == ["--"] else args.command
        if supplied and supplied != command:
            raise EvidenceError("command does not match requirements binding")
        if args.out.is_symlink():
            raise EvidenceError("output must be a real directory")
        output = args.out.resolve()
        output.mkdir(parents=True, exist_ok=True, mode=0o700)
        reservation = output / ("." + args.run_id + ".reserved")
        with reservation.open("x") as handle:
            handle.write(str(os.getpid()) + "\n")
        stdout_path = output / (args.run_id + ".stdout.log")
        stderr_path = output / (args.run_id + ".stderr.log")
        record_path = output / (args.run_id + ".json")
        if record_path.exists():
            raise EvidenceError("run ID already has a record")
        policy_path = output / ("policy-" + digest(requirements_bytes) + ".json")
        if policy_path.is_symlink():
            raise EvidenceError("requirements snapshot is a symlink")
        try:
            with policy_path.open("xb") as handle:
                handle.write(requirements_bytes)
        except FileExistsError:
            if policy_path.read_bytes() != requirements_bytes:
                raise EvidenceError("requirements snapshot differs from its digest")
        scratch_base = (args.scratch_base or Path(tempfile.gettempdir())).resolve(strict=True)
        scratch, measurement = make_scratch(runtime_root, scratch_base, args.run_id)
        host = host_snapshot(scratch, scratch)
        bound = [definition["platform"]["filesystems"] for definition in requirements["cells"] + requirements["benches"]
                 if args.requirement in definition["requirements"]]
        # Shared oracles may serve both APFS and fallback cells; their caller
        # chooses the cell later, where T73b checks the stricter platform policy.
        if bound and all(bound) and host["platform"]["filesystem"] not in {item for group in bound for item in group}:
            raise EvidenceError("measured TMPDIR filesystem differs from requirement")
        child_env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        child_env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0",
                         TMPDIR=str(scratch), PYTHONPYCACHEPREFIX=str(scratch / "pycache"), PYTHONDONTWRITEBYTECODE="1")
        if args.runtime_kind == "installed":
            if root.parent.name != "releases":
                raise EvidenceError("installed runtime must name a versioned release, not an execution snapshot")
            home = root.parent.parent
            if load(home / "config.json")["active_cli_release"] != root.name:
                raise EvidenceError("selected installed release is not the active runtime")
            child_env["TRELLIS_HOME"] = str(home)
        started, clock = timestamp(), time.monotonic()
        exec_error, timed_out, interrupted = False, False, False
        with stdout_path.open("xb") as stdout, stderr_path.open("xb") as stderr:
            try:
                process = subprocess.Popen(command, cwd=cwd, env=child_env, stdout=stdout, stderr=stderr, start_new_session=True)
            except OSError as error:
                stderr.write(str(error).encode())
                exit_code, exec_error = 127, True
            else:
                try:
                    exit_code = process.wait(timeout=args.timeout)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    exit_code, timed_out = process.wait(), True
                except KeyboardInterrupt:
                    os.killpg(process.pid, signal.SIGKILL)
                    exit_code, interrupted = process.wait(), True
        ended, duration = timestamp(), (time.monotonic() - clock) * 1000
        acquisition_error = "recorder interrupted" if interrupted else None
        end_digest, stable = None, False
        try:
            end_revision, _, end_inputs, end_manifest = snapshot(root, args.runtime_kind, requirements, requirement, scope)
            end_digest = value_digest(end_inputs)
            stable = end_revision == revision and end_inputs == inputs and end_manifest == installed_digest
            if not stable:
                acquisition_error = "runtime inputs changed during command"
        except (EvidenceError, OSError, ValueError, KeyError) as error:
            acquisition_error = str(error)
        try:
            if recorder_identity(RECORDER_ROOT, include_inputs=True) != (recorder_sha, recorder_digest, harness_inputs):
                raise EvidenceError("recorder/harness inputs changed during command")
        except (EvidenceError, OSError, ValueError, KeyError) as error:
            acquisition_error = (acquisition_error + "; " if acquisition_error else "") + str(error)
        if args.requirements.read_bytes() != requirements_bytes:
            acquisition_error = (acquisition_error + "; " if acquisition_error else "") + "requirements changed during command"
        artifacts = None
        if requirement["kind"] == "build":
            try:
                artifacts = acquire_artifacts(runtime_root, requirements["manifest_path"])
            except (EvidenceError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                acquisition_error = "artifact acquisition: " + str(error)
        end_host = host_snapshot(scratch, scratch)
        if end_host["platform"]["filesystem"] != host["platform"]["filesystem"] or scratch.stat().st_dev != measurement["scratch_device"]:
            acquisition_error = (acquisition_error + "; " if acquisition_error else "") + "measurement filesystem changed during command"
        contended = (host["battery_running"] or end_host["battery_running"] or
                     host["load_average"][0] >= host["logical_cores"] or
                     end_host["load_average"][0] >= end_host["logical_cores"])
        record = {"schema": "trellis-qualification-run/1", "run_id": args.run_id, "requirement_id": args.requirement,
                  "requirements_sha256": digest(requirements_bytes), "requirements_snapshot": policy_path.name, "recorder_sha": recorder_sha,
                  "recorder_input_digest": recorder_digest, "harness_inputs": harness_inputs, "measurement": measurement, "candidate_sha": revision, "runtime_input_digest": value_digest(inputs),
                  "runtime": {"kind": args.runtime_kind, "scope": scope, "clean": clean, "stable": stable,
                              "generation": args.generation, "committed_input_digest": value_digest(expected),
                              "end_input_digest": end_digest, "installed_manifest_sha256": installed_digest, "inputs": inputs},
                  "argv": command, "cwd": requirement["cwd"], "cwd_base": "runtime", "phase": args.phase, "variant": args.variant,
                  "host_id": host["host_id"], "platform": dict(host["platform"], emulated=bool(args.emulated or host["platform"]["emulated"])),
                  "load": "contended" if contended else "normal",
                  "load_facts": {"start": host["load_average"], "end": end_host["load_average"],
                                 "logical_cores": host["logical_cores"], "battery_running": bool(host["battery_running"] or end_host["battery_running"])},
                  "started_at": started, "ended_at": ended, "duration_ms": duration, "exit": exit_code,
                  "exec_error": exec_error, "timeout": timed_out, "acquisition_error": acquisition_error, "artifacts": artifacts,
                  "logs": {"stdout": {"path": stdout_path.name, "sha256": digest(stdout_path.read_bytes())},
                           "stderr": {"path": stderr_path.name, "sha256": digest(stderr_path.read_bytes())}}}
        validate_named("run-record", record)
        # Exclusive publication: a later invocation never overwrites pinned evidence.
        with record_path.open("x", encoding="utf-8") as handle:
            import json
            json.dump(record, handle, indent=2, allow_nan=False)
            handle.write("\n")
        print(record_path)
        return 130 if interrupted else 2 if acquisition_error else 124 if timed_out else exit_code if exit_code >= 0 else 128 - exit_code
    except (EvidenceError, OSError, ValueError, KeyError) as error:
        print("qualification record: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
