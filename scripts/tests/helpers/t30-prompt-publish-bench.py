#!/usr/bin/env python3
"""Paired, isolated prompt-baseline diagnostic; not a Stop latency benchmark.

Build exact before/after Git commits in private archives, then interleave
shell and native module prompt publications. No live HOME/TRELLIS_HOME or Git
configuration is touched. The native arm includes process startup, a Proof::None
measurement dispatch, parsing and the baseline Stage; it is not a registered
native hook, a release artifact, or a T30 SC7 receipt.
"""

import argparse
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import resource
import shutil
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time


RUST_DRIVER = r"""use std::path::Path;
use trellis_hooks::{event::{self, EventCtx, ParsedEvent, Proof}, protocol::{Harness, StageStatus}, stop::baseline};
fn main() {
    let a: Vec<String> = std::env::args().collect();
    assert_eq!(a.len(), 6);
    let harness = match a[1].as_str() { "claude" => Harness::Claude, "codex" => Harness::Codex, _ => panic!("bad harness") };
    let ctx = EventCtx { harness, event: "UserPromptSubmit".into(), proof: Proof::None,
        trellis_home: Some(a[3].clone()), project_root: a[2].clone(), rules_path: Some(a[5].clone()), proven: None };
    let input = serde_json::json!({"session_id":a[4]});
    let parsed = ParsedEvent::parse(&ctx, &serde_json::to_vec(&input).unwrap()).unwrap();
    let member = event::members(harness, "UserPromptSubmit", None).unwrap()[0];
    let result = event::dispatch_call(&ctx, &[], &[], |shared| baseline::stage(shared, &parsed, &member)).unwrap();
    assert_eq!(result.status, StageStatus::Allow, "{result:?}");
    assert!(Path::new(&a[2]).is_dir());
}
"""
SHELL_DRIVER = 'source "$1"; _se_turn_baseline_publish "$2" "$3" "$4"'
SESSION = "t30-prompt-benchmark"


def run(command, env, cwd=None, capture=True):
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        check=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def load():
    try:
        return list(os.getloadavg())
    except OSError:
        return None


def summarize(values):
    ordered = sorted(values)
    return {
        "p50_ms": statistics.median(ordered),
        "p95_ms": ordered[math.ceil(0.95 * len(ordered)) - 1],
    }


def require_exact_commit(repo, sha, env):
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", sha):
        raise ValueError("both revisions must be full lowercase commit IDs")
    resolved = (
        run(["git", "-C", str(repo), "rev-parse", "--verify", sha + "^{commit}"], env)
        .stdout.decode()
        .strip()
    )
    if resolved != sha:
        raise ValueError(f"{sha} did not resolve to the exact commit")


def archive(repo, sha, destination, env):
    data = run(["git", "-C", str(repo), "archive", sha], env).stdout
    destination.mkdir(mode=0o700)
    # Git paths are repository-owned, but reject absolute and parent paths so
    # the test-only extraction cannot escape its private directory.
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as tar:
        for member in tar.getmembers():
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("unsafe archive path")
        tar.extractall(destination, filter="data")


def verify_baseline(home, project, harness, expected_lines):
    worktree_key = hashlib.sha256(os.fsencode(str(project.resolve()))).hexdigest()[:16]
    session_key = hashlib.sha256(SESSION.encode()).hexdigest()[:16]
    directory = home / "state" / "turn-baseline" / worktree_key
    ident = f"{harness}.{session_key}"
    lines = (directory / ident).read_text().splitlines()
    if len(lines) != expected_lines:
        raise RuntimeError(
            f"prompt did not publish exactly one new baseline: {len(lines)} lines"
        )
    fields = lines[-1].split()
    if len(fields) != 5 or fields[:2] != ["trellis-turn-baseline", "v2"]:
        raise RuntimeError("prompt wrote an unknown or malformed baseline")
    if (
        f"{ident} {fields[2]}"
        not in (directory / "nonces.log").read_text().splitlines()
    ):
        raise RuntimeError("prompt baseline nonce was not logged")
    if len(lines) > 1 and lines[-2].split()[2] == fields[2]:
        raise RuntimeError("prompt reused the previous nonce")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo", type=Path, default=Path(__file__).resolve().parents[3]
    )
    parser.add_argument(
        "--before", required=True, help="full commit ID before nonce lock"
    )
    parser.add_argument("--after", required=True, help="full commit ID with nonce lock")
    parser.add_argument(
        "--runs", type=int, default=30, help="paired samples per route and harness"
    )
    parser.add_argument(
        "--output", type=Path, required=True, help="new private JSON result path"
    )
    args = parser.parse_args()
    if args.runs < 10:
        parser.error("at least 10 paired samples are required")
    repo = args.repo.resolve(strict=True)
    cargo_home = Path(
        os.environ.get("CARGO_HOME", str(Path.home() / ".cargo"))
    ).resolve(strict=True)
    rustup_home = Path(
        os.environ.get("RUSTUP_HOME", str(Path.home() / ".rustup"))
    ).resolve(strict=True)
    parent = Path(os.environ.get("TMPDIR", tempfile.gettempdir())).resolve(strict=True)
    started_load = load()
    with tempfile.TemporaryDirectory(
        prefix="t30-prompt-paired-", dir=parent
    ) as temporary:
        root = Path(temporary).resolve()
        user = root / "user"
        user.mkdir(mode=0o700)
        gitconfig = root / "gitconfig"
        gitconfig.write_text(
            "[user]\n\tname = Benchmark\n\temail = benchmark@example.invalid\n[commit]\n\tgpgSign = false\n"
        )
        os.chmod(gitconfig, 0o600)
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env.update(
            {
                "HOME": str(user),
                "TRELLIS_HOME": str(root / "unused-trellis"),
                "GIT_CONFIG_GLOBAL": str(gitconfig),
                "GIT_CONFIG_NOSYSTEM": "1",
                "TMPDIR": str(root),
                "RUSTUP_HOME": str(rustup_home),
                "CARGO_HOME": str(cargo_home),
                "RUSTUP_AUTO_INSTALL": "0",
                "CARGO_NET_OFFLINE": "true",
                "CARGO_BUILD_JOBS": "2",
                "PATH": f"{cargo_home / 'bin'}:/usr/bin:/bin:/usr/sbin:/sbin",
            }
        )
        require_exact_commit(repo, args.before, env)
        require_exact_commit(repo, args.after, env)
        rustc = run(["rustc", "+1.97.1", "--version"], env).stdout.decode().strip()
        bash = run(["/bin/bash", "--version"], env).stdout.decode().splitlines()[0]
        git = run(["git", "--version"], env).stdout.decode().strip()
        project = root / "project"
        project.mkdir(mode=0o700)
        run(["git", "init", "-q", str(project)], env)
        (project / "app.py").write_text("value = 1\n")
        run(["git", "-C", str(project), "add", "app.py"], env)
        run(["git", "-C", str(project), "commit", "-qm", "benchmark fixture"], env)
        (project / "app.py").write_text("value = 2\n")
        rules = root / "rules.json"
        rules.write_text("{}\n")
        trees = {}
        for arm, sha in [("before", args.before), ("after", args.after)]:
            tree = root / arm
            archive(repo, sha, tree, env)
            driver = (
                tree
                / "native"
                / "trellis-hooks"
                / "src"
                / "bin"
                / "t30-prompt-bench.rs"
            )
            driver.parent.mkdir(parents=True, exist_ok=True)
            driver.write_text(RUST_DRIVER)
            build_env = dict(env, CARGO_TARGET_DIR=str(root / f"target-{arm}"))
            print(f"building {arm} {sha}", file=sys.stderr, flush=True)
            run(
                [
                    "cargo",
                    "+1.97.1",
                    "build",
                    "--release",
                    "--locked",
                    "--offline",
                    "--manifest-path",
                    str(tree / "native/trellis-hooks/Cargo.toml"),
                    "--bin",
                    "t30-prompt-bench",
                ],
                build_env,
            )
            trees[arm] = tree
        after_build_load = load()
        rows = []
        for harness in ("claude", "codex"):
            for route in ("shell", "native"):
                arms = {}
                for arm in ("before", "after"):
                    home = root / f"home-{harness}-{route}-{arm}"
                    home.mkdir(mode=0o700)
                    child_env = dict(env, TRELLIS_HOME=str(home))
                    if route == "shell":
                        subdir = "hooks" if harness == "claude" else "codex/hooks"
                        deps = trees[arm] / "core-rules" / subdir / "lib/deps.sh"
                        command = [
                            "/bin/bash",
                            "-c",
                            SHELL_DRIVER,
                            "_",
                            str(deps),
                            str(project),
                            harness,
                            SESSION,
                        ]
                    else:
                        binary = root / f"target-{arm}" / "release" / "t30-prompt-bench"
                        command = [
                            str(binary),
                            harness,
                            str(project),
                            str(home),
                            SESSION,
                            str(rules),
                        ]
                    run(command, child_env, cwd=project)
                    verify_baseline(home, project, harness, 1)
                    seed = root / f"seed-{harness}-{route}-{arm}"
                    shutil.copytree(home / "state", seed)
                    arms[arm] = (home, seed, command, child_env)
                for iteration in range(args.runs):
                    order = (
                        ("before", "after")
                        if iteration % 2 == 0
                        else ("after", "before")
                    )
                    for arm in order:
                        home, seed, command, child_env = arms[arm]
                        shutil.rmtree(home / "state")
                        shutil.copytree(seed, home / "state")
                        pre_load = load()
                        usage0 = resource.getrusage(resource.RUSAGE_CHILDREN)
                        start = time.perf_counter_ns()
                        run(command, child_env, cwd=project)
                        elapsed = (time.perf_counter_ns() - start) / 1_000_000
                        usage1 = resource.getrusage(resource.RUSAGE_CHILDREN)
                        post_load = load()
                        verify_baseline(home, project, harness, 2)
                        rows.append(
                            {
                                "harness": harness,
                                "route": route,
                                "iteration": iteration,
                                "arm": arm,
                                "wall_ms": elapsed,
                                "user_ms": (usage1.ru_utime - usage0.ru_utime) * 1000,
                                "sys_ms": (usage1.ru_stime - usage0.ru_stime) * 1000,
                                "load_before": pre_load,
                                "load_after": post_load,
                            }
                        )
        summaries = {}
        for harness in ("claude", "codex"):
            for route in ("shell", "native"):
                subset = [
                    r for r in rows if r["harness"] == harness and r["route"] == route
                ]
                entry = {}
                for metric in ("wall_ms", "user_ms", "sys_ms"):
                    before = [r[metric] for r in subset if r["arm"] == "before"]
                    after = [r[metric] for r in subset if r["arm"] == "after"]
                    entry[metric] = {
                        "before": summarize(before),
                        "after": summarize(after),
                        "paired_after_minus_before": summarize(
                            [a - b for a, b in zip(after, before)]
                        ),
                    }
                summaries[f"{harness}/{route}"] = entry
        result = {
            "schema": 1,
            "kind": "diagnostic_prompt_publication_not_stop_latency",
            "before": args.before,
            "after": args.after,
            "runs_per_arm": args.runs,
            "rustc": rustc,
            "bash": bash,
            "git": git,
            "uname": list(os.uname()),
            "cpu_count": os.cpu_count(),
            "load_at_start": started_load,
            "load_after_build": after_build_load,
            "load_at_end": load(),
            "native_driver_sha256": hashlib.sha256(RUST_DRIVER.encode()).hexdigest(),
            "summaries": summaries,
            "samples": rows,
        }
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(result, stream, indent=2, sort_keys=True)
            stream.write("\n")
        print(json.dumps(result["summaries"], indent=2, sort_keys=True))
        print(f"raw samples: {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
