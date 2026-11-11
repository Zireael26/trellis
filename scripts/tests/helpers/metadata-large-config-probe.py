#!/usr/bin/env python3
"""Test-only, unbounded T59 large-config comparison. Not an SC9 receipt.

Run from a checkout with history:
  python3 -I scripts/tests/helpers/metadata-large-config-probe.py --out /private/new-dir

The output directory must not exist. Retains fixtures, exact launcher sources,
per-run stdout/stderr, five observations per route, CPU times and host load.
No installation, native build, live HOME access, network, or normal-run timeout.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import signal
import subprocess
import time

CANONICAL_REF = "b7a3bddca6dc8e405695fe54fc2c4ef1fa836215"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def load():
    return list(os.getloadavg())


def capture(argv, env):
    return subprocess.run(argv, env=env, check=True, capture_output=True).stdout


def observe(launcher, env, number, label, out):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    load_start = load()
    started = time.monotonic()
    child = subprocess.Popen(
        [str(launcher), "--version"], env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
    )
    try:
        # Deliberately no timeout: this diagnoses the corpus's five-second limit.
        stdout, stderr = child.communicate()
    except BaseException:
        # Interrupted probes must not leave an owned launcher/Perl behind.
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        raise
    wall = time.monotonic() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    prefix = out / f"{label}-{number}"
    prefix.with_suffix(".stdout").write_bytes(stdout)
    prefix.with_suffix(".stderr").write_bytes(stderr)
    return {
        "route": label, "run": number, "argv": [str(launcher), "--version"],
        "exit": child.returncode, "wall_seconds": wall,
        # Sequential RUSAGE_CHILDREN deltas include waited launcher descendants.
        "user_cpu_seconds": after.ru_utime - before.ru_utime,
        "sys_cpu_seconds": after.ru_stime - before.ru_stime,
        "load_start": load_start, "load_end": load(),
        "stdout_sha256": sha256(stdout), "stderr_sha256": sha256(stderr),
    }


def fixture_bytes(size, shape):
    config = {
        "schema_version": 1, "source_root": "/opt/src", "release_remote": "fixture://r",
        "active_cli_release": "1.2.3", "default_fleet": "personal",
        "fleets": {"personal": {"discovery_roots": ["/p"]}},
    }
    encode = lambda: json.dumps(config, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if size == 0:
        return encode(), "typical-small"
    config["projects"] = "" if shape == "string" else []
    extra = size - len(encode())
    if extra < 0:
        raise ValueError("requested fixture is smaller than the core config")
    if shape == "string":
        config["projects"] = "é" * (extra // 2) + "x" * (extra % 2)
    else:
        config["projects"] = ["é"] * ((extra + 1) // 5)
    raw = encode()
    raw = raw[:-1] + b" " * (size - len(raw)) + raw[-1:]
    assert len(raw) == size
    return raw, f"projects-{shape}-{size}-bytes"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path, help="new private output directory")
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--canonical-ref", default=CANONICAL_REF)
    parser.add_argument("--host-note", default="", help="operator-supplied load/topology context")
    parser.add_argument("--config-bytes", type=int, default=1000195, help="exact bytes; 0 selects typical small config")
    parser.add_argument("--shape", choices=("string", "array"), default="string")
    parser.add_argument("--candidate-exit", type=int, choices=(0, 4), default=0, help="4 profiles the defined over-limit refusal")
    args = parser.parse_args()
    repo = args.repo.resolve(strict=True)
    out = args.out.absolute()
    # Exclusive creation; never overwrite or clean an existing operator path.
    out.mkdir(mode=0o700)
    out = out.resolve(strict=True)
    home, trellis, tmp = (out / name for name in ("home", "trellis-home", "tmp"))
    for directory in (home, trellis, tmp):
        directory.mkdir(mode=0o700)
    gitconfig = out / "gitconfig"
    gitconfig.write_text("")
    env = {
        "HOME": str(home), "TRELLIS_HOME": str(trellis), "TMPDIR": str(tmp),
        "GIT_CONFIG_GLOBAL": str(gitconfig), "GIT_CONFIG_NOSYSTEM": "1",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    }
    canonical_commit = capture(
        ["/usr/bin/git", "-C", str(repo), "rev-parse", "--verify", "--end-of-options", args.canonical_ref + "^{commit}"], env,
    ).decode().strip()
    canonical_bytes = capture(
        ["/usr/bin/git", "-C", str(repo), "show", canonical_commit + ":scripts/trellis-launcher.sh"], env,
    )
    candidate_bytes = (repo / "scripts/trellis-launcher.sh").read_bytes()
    launchers = {}
    for label, data in (("canonical-jq", canonical_bytes), ("candidate-perl", candidate_bytes)):
        launcher = out / label
        launcher.write_bytes(data)
        launcher.chmod(0o700)
        launchers[label] = launcher
    # Default remains byte-identical to review big-projects-1mb.json.
    raw, case = fixture_bytes(args.config_bytes, args.shape)
    config_path = trellis / "config.json"
    config_path.write_bytes(raw)
    config_path.chmod(0o600)
    result = {
        "kind": "T59-unbounded-functional-profile-not-SC9",
        "case": case, "shape": args.shape, "config_bytes": len(raw), "config_sha256": sha256(raw),
        "expected_candidate_exit": args.candidate_exit,
        "runs_per_route": 5, "warmups": 0, "normal_run_timeout": None,
        "host": {"platform": platform.platform(), "logical_cpus": os.cpu_count(),
                 "affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
                 "load_start": load(), "operator_context": args.host_note},
        "canonical_commit": canonical_commit,
        "launcher_sha256": {"canonical-jq": sha256(canonical_bytes), "candidate-perl": sha256(candidate_bytes)},
        "jq_version": capture(["/usr/bin/jq", "--version"], env).decode().strip(),
        "perl_version": capture(["/usr/bin/perl", "-e", 'print "$^V\\n"'], env).decode().strip(),
        "observations": [],
    }
    receipt = out / "results.json"
    receipt.write_text(json.dumps(result, indent=2) + "\n")
    for number in range(1, 6):
        # Interleaved, same fixture/environment; no warmups or omitted outliers.
        for label, launcher in launchers.items():
            print(f"START case={case} route={label} run={number} load={load()}", flush=True)
            row = observe(launcher, env, number, label, out)
            result["observations"].append(row)
            receipt.write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps(row, sort_keys=True), flush=True)
    result["host"]["load_end"] = load()
    expected = b"trellis 1.2.3 (configured; not verified)\n"
    result["all_version_outputs_match"] = all(
        row["exit"] == 0 and row["stdout_sha256"] == sha256(expected)
        and row["stderr_sha256"] == sha256(b"") for row in result["observations"]
    )
    result["all_outputs_as_expected"] = all(
        (row["exit"] == 4 and row["stdout_sha256"] == sha256(b""))
        if row["route"] == "candidate-perl" and args.candidate_exit == 4 else
        (row["exit"] == 0 and row["stdout_sha256"] == sha256(expected) and row["stderr_sha256"] == sha256(b""))
        for row in result["observations"]
    )
    receipt.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Retained {receipt}; no SC9/timing acceptance claim", flush=True)
    return 0 if result["all_outputs_as_expected"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
