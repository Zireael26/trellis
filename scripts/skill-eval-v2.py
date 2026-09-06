#!/usr/bin/env python3
"""Pack existing executed/graded runs; never execute native models or promote skills.

The selected plugin is executable operator-trusted code, not authenticated evidence.
Transaction: boundedly snapshot inputs; validate, aggregate and bind only that
private copy; recheck live inputs, then exclusively hard-link benchmark and final
evaluation.json last. Private storage is not hostile same-UID isolation. On failure unlink only our still-owned inodes. A crash
can leave a provisional benchmark (never an accepted evaluation); no input is erased.
The 30-second work alarm is disabled before bounded owned-file cleanup.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import stat
import sys
import tempfile
from decimal import Decimal, localcontext

sys.dont_write_bytecode = True
VALIDATOR = Path(__file__).resolve().parents[1] / "core-rules/skills/wiki-skill-propose/scripts/validate_proposal.py"


def import_file(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


FILE_LIMIT = 16 << 20
TOTAL_LIMIT = 256 << 20
ENTRY_LIMIT = 4096
CHUNK = 64 << 10


def json_chunks(value):
    """Stream strict JSON, including Decimal numbers, without whole-value dumps."""
    if value is None:
        yield "null"
    elif isinstance(value, bool):
        yield "true" if value else "false"
    elif isinstance(value, str):
        yield '"'
        for offset in range(0, len(value), CHUNK):
            yield json.dumps(value[offset:offset + CHUNK], ensure_ascii=True)[1:-1]
        yield '"'
    elif isinstance(value, (int, Decimal, float)):
        if isinstance(value, Decimal):
            require(value.is_finite(), "nonfinite JSON number")
            require(len(value.as_tuple().digits) <= FILE_LIMIT, "generated file limit exceeded")
            yield str(value)
        else:
            yield json.dumps(value, allow_nan=False)
    elif isinstance(value, (list, dict)):
        mapping = isinstance(value, dict)
        yield "{" if mapping else "["
        for index, key in enumerate(value):
            if index:
                yield ","
            if mapping:
                require(isinstance(key, str), "JSON key must be a string")
                yield from json_chunks(key)
                yield ":"
            yield from json_chunks(value[key] if mapping else key)
        yield "}" if mapping else "]"
    else:
        raise ValueError("unsupported JSON value: " + type(value).__name__)


def strict_json(value):
    payload = bytearray()
    for part in json_chunks(value):
        block = part.encode("utf-8")
        require(len(payload) + len(block) + 1 <= FILE_LIMIT, "generated file limit exceeded")
        payload.extend(block)
    payload.extend(b"\n")
    return bytes(payload)


def identity(info):
    return (info.st_mode, info.st_dev, info.st_ino, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def directory_fd(path):
    """Open every ancestor without following links, not just the final component."""
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


class Admission:
    """One bounded inventory for sources/draft plus all run entries (directories too)."""
    def __init__(self):
        self.records = {}
        self.entries = 0
        self.total = 0

    def entry(self):
        self.entries += 1
        require(self.entries <= ENTRY_LIMIT, "entry limit exceeded")

    def file(self, path, destination=None, parent_fd=None):
        self.entry()
        fd = os.open(path.name if parent_fd is not None else path,
                     os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        output = None
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode), "consumed file must be regular and non-symlink")
            require(before.st_size <= FILE_LIMIT, "file limit exceeded")
            require(self.total + before.st_size <= TOTAL_LIMIT, "aggregate limit exceeded")
            if destination is not None:
                output = destination.open("xb")
            digest, size = hashlib.sha256(), 0
            while True:
                block = os.read(fd, min(CHUNK, FILE_LIMIT - size + 1, TOTAL_LIMIT - self.total + 1))
                if not block:
                    break
                size += len(block)
                self.total += len(block)
                require(size <= FILE_LIMIT, "file limit exceeded")
                require(self.total <= TOTAL_LIMIT, "aggregate limit exceeded")
                digest.update(block)
                if output is not None:
                    output.write(block)
            require(identity(os.fstat(fd)) == identity(before), "consumed input drift while reading")
            require(identity(path.lstat()) == identity(before), "consumed input drift after reading")
            self.records[str(path)] = (stat.S_IMODE(before.st_mode), digest.hexdigest(), *identity(before))
            if output is not None:
                os.fchmod(output.fileno(), 0o600 | (before.st_mode & 0o111))
        finally:
            if output is not None:
                output.close()
            os.close(fd)

    def tree(self, path, destination=None, excluded=(), fd=None):
        if fd is None:
            fd = directory_fd(path)
        try:
            self.entry()
            before = os.fstat(fd)
            self.records[str(path)] = (stat.S_IMODE(before.st_mode), "directory", before.st_dev, before.st_ino)
            if destination is not None:
                destination.mkdir(parents=True, mode=0o700)
            with os.scandir(fd) as entries:
                for entry in entries:
                    child = path / entry.name
                    if child in excluded:
                        continue
                    target = destination / entry.name if destination is not None else None
                    info = entry.stat(follow_symlinks=False)
                    if stat.S_ISDIR(info.st_mode):
                        child_fd = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                        self.tree(child, target, excluded, child_fd)
                    else:
                        require(stat.S_ISREG(info.st_mode), "run evidence must not contain symlinks or nonregular files")
                        self.file(child, target, fd)
            require(identity(os.fstat(fd)) == identity(before), "inventory drift while copying")
            require(identity(path.lstat()) == identity(before), "inventory drift after copying")
        finally:
            os.close(fd)


def freeze(run_dir, sources=(), excluded=()):
    admission = Admission()
    for path in sources:
        parent_fd = directory_fd(path.parent)
        try:
            admission.file(path, parent_fd=parent_fd)
        finally:
            os.close(parent_fd)
    admission.tree(run_dir, excluded=excluded)
    return admission.records


def require(condition, message):
    if not condition:
        raise ValueError(message)


def prevalidate(v, root, evaluation):
    e = evaluation
    require(not e.incumbents, "initial packer requires empty incumbents")
    require(e.benchmark.sha256 == "0" * 64, "draft benchmark digest must be the zero placeholder")
    require(e.cohort.repetitions == 3, "exactly three repetitions required")
    run_dir = v.evaluation_run_directory(root, e.run_dir, "run_dir")
    base = v.EvidenceBase(root, e.run_dir, run_dir)
    candidate = v.evidence_directory(base, e.candidate_snapshot, "candidate")
    require(v.tree_digest(candidate, "candidate") == e.candidate_sha256, "candidate digest mismatch")
    tasks = {task.eval_id: task.snapshot_sha256 for task in e.cohort.tasks}
    for eval_id, relative in e.task_snapshots:
        path = v.evidence_directory(base, relative, "task snapshot")
        require(v.tree_digest(path, "task snapshot") == tasks[eval_id], "task digest mismatch")
    for pattern, relative, digest in e.provenance:
        path = v.evidence_file(base, relative, pattern)
        require(v.file_sha256(path, pattern) == digest, "provenance digest mismatch")
    # The plugin prefers legacy runs/ over direct eval-* discovery: refuse ambiguity.
    require(not (run_dir / "runs").exists(), "legacy runs directory is not the native aggregate layout")
    require({p.name for p in run_dir.glob("eval-*")} == {f"eval-{n}" for n in tasks}, "unexpected or missing eval directory")
    for eval_id in tasks:
        task_dir = run_dir / f"eval-{eval_id}"
        v.ensure_real_directory_below(root, task_dir, "eval directory")
        metadata = v.load_json(task_dir / "eval_metadata.json", "eval metadata")
        require(isinstance(metadata, dict) and type(metadata.get("eval_id")) is int and metadata["eval_id"] == eval_id, "eval metadata identity mismatch")
        require({p.name for p in task_dir.iterdir() if p.is_dir()} == set(v.CONFIGURATIONS), "unexpected or missing configuration")
        for config in v.CONFIGURATIONS:
            config_dir = task_dir / config
            v.ensure_real_directory_below(root, config_dir, "configuration")
            require({p.name for p in config_dir.iterdir() if p.is_dir() or p.name.startswith("run-")} == {"run-1", "run-2", "run-3"}, "unexpected or missing run")
    seen = {e.run_dir, e.candidate_snapshot, e.benchmark.path,
            *(p for _, p in e.task_snapshots), *(p for _, p, _ in e.provenance),
            *(a.path for a in e.artifacts)}
    expected_paths = 3 + len(e.task_snapshots) + len(e.provenance) + len(e.artifacts)
    require(len(seen) == expected_paths, "duplicate evaluation evidence path")
    authoritative = {}
    for artifact in e.artifacts:
        identity = (artifact.eval_id, artifact.configuration, artifact.run_number)
        native = run_dir / f"eval-{artifact.eval_id}" / artifact.configuration / f"run-{artifact.run_number}"
        v.ensure_real_directory_below(root, native, "native run")
        grading_path, timing_path = native / "grading.json", native / "timing.json"
        v.ensure_regular_file_below(root, grading_path, "grading")
        v.ensure_regular_file_below(root, timing_path, "timing")
        grading, timing = v.load_json(grading_path, "grading"), v.load_json(timing_path, "timing")
        require(isinstance(grading, dict) and isinstance(grading.get("summary"), dict), "grading summary unavailable")
        expectations, summary = grading.get("expectations"), grading["summary"]
        require(isinstance(expectations, list) and bool(expectations), "grading expectations unavailable")
        for expectation in expectations:
            require(isinstance(expectation, dict) and type(expectation.get("passed")) is bool, "expectation passed must be boolean")
            for key in ("text", "evidence"):
                v.require_plain_string(expectation.get(key), "expectation " + key)
        passed = sum(item["passed"] for item in expectations)
        for key, expected in (("passed", passed), ("failed", len(expectations) - passed), ("total", len(expectations))):
            require(type(summary.get(key)) is int and summary[key] == expected, "grading counts disagree with expectations")
        rate = v.decimal_from_json_number(summary.get("pass_rate"), "grading pass_rate")
        require(rate == Decimal(passed) / Decimal(len(expectations)), "grading rate disagrees with expectations")
        require(isinstance(timing, dict), "timing unavailable")
        duration = v.decimal_from_json_number(timing.get("total_duration_seconds"), "duration")
        tokens = timing.get("total_tokens")
        require(duration >= 0 and type(tokens) is int and tokens >= 0, "native timing metrics unavailable or negative")
        metrics = grading.get("execution_metrics", {})
        require(isinstance(metrics, dict), "execution metrics must be an object")
        optional = {}
        for output_key, input_key in (("tool_calls", "total_tool_calls"), ("errors", "errors_encountered")):
            value = metrics.get(input_key)
            require(value is None or (type(value) is int and value >= 0), "invalid optional native metric")
            optional[output_key] = value
        raw_path = v.evidence_file(base, artifact.path, "raw run")
        raw = v.load_json(raw_path, "raw run")
        # Canonical validation owns terminal identity, routes, treatment and all hashes.
        v.validate_run_artifact(base, e, artifact, rate, "precheck", seen)
        require(raw["grade"]["output"]["path"] == grading_path.relative_to(root).as_posix(), "grade output is not the identity's native grading.json")
        authoritative[identity] = dict(pass_rate=rate, passed=passed, failed=len(expectations) - passed,
                                       total=len(expectations), time_seconds=duration, tokens=tokens, **optional)
    return run_dir, candidate, authoritative


def aggregate(v, plugin, run_dir, skill, candidate, e, authoritative):
    value = plugin.generate_benchmark(run_dir, skill, str(candidate))
    # Only descriptive plugin floats cross here; rates are replaced from strict evidence.
    value = json.loads(strict_json(value), parse_float=Decimal,
                       parse_constant=v.reject_json_constant, object_pairs_hook=v.unique_json_object)
    require(isinstance(value, dict) and set(value) == v.BENCHMARK_TOP_LEVEL_FIELDS, "plugin aggregate top-level contract mismatch")
    metadata = value["metadata"]
    require(type(metadata["runs_per_configuration"]) is int and metadata["runs_per_configuration"] == 3, "plugin repetition mismatch")
    require(all(type(n) is int for n in metadata["evals_run"]) and sorted(metadata["evals_run"]) == sorted(t.eval_id for t in e.cohort.tasks), "plugin eval identity mismatch")
    metadata.update(executor_model=e.cohort.executor.route, analyzer_model=e.cohort.grader.route,
                    trellis_evaluation=dict(cohort_id=e.cohort_id, candidate_sha256=e.candidate_sha256, run_dir=str(e.run_dir)))
    seen, rates = set(), {config: [] for config in v.CONFIGURATIONS}
    for run in value["runs"]:
        require(type(run["eval_id"]) is int and type(run["run_number"]) is int, "plugin run identity must be integer")
        identity = (run["eval_id"], run["configuration"], run["run_number"])
        require(identity in authoritative and identity not in seen, "plugin run identity mismatch")
        seen.add(identity)
        run["result"].update(authoritative[identity])
        rates[run["configuration"]].append(authoritative[identity]["pass_rate"])
    require(seen == set(authoritative), "plugin omitted a run")
    for config, numbers in rates.items():
        value["run_summary"][config]["pass_rate"].update(mean=sum(numbers, Decimal(0)) / Decimal(len(numbers)), min=min(numbers), max=max(numbers))
        # Plugin time/token extraction can default or substitute character counts.
        for metric in ("time_seconds", "tokens"):
            numbers = [float(item[metric]) for identity, item in authoritative.items() if identity[1] == config]
            stats = plugin.calculate_stats(numbers)
            value["run_summary"][config][metric] = json.loads(strict_json(stats), parse_float=Decimal)
    summary = value["run_summary"]
    for metric in ("pass_rate", "time_seconds", "tokens"):
        summary["delta"][metric] = format(summary["with_skill"][metric]["mean"] - summary["without_skill"][metric]["mean"], "+f")
    value["notes"].append("Pass-rate mean/min/max and run metrics are evidence-derived; remaining descriptive statistics are plugin-derived. Missing optional native metrics are null, not zero.")
    return value


def pack(args, owned, temporaries):
    require(args.root.is_absolute(), "--root must be absolute")
    require(args.aggregate_script.is_absolute(), "--aggregate-script must be absolute")
    sources = [Path(__file__).resolve(), VALIDATOR, args.aggregate_script, args.evaluation.absolute()]
    private = Path(tempfile.mkdtemp(prefix="skill-eval-v2-snapshot-")).resolve()
    temporaries.append(private)
    admission, copied = Admission(), []
    for index, path in enumerate(sources):
        target = private / f"source-{index}.py"
        parent_fd = directory_fd(path.parent)
        try:
            admission.file(path, target, parent_fd)
        finally:
            os.close(parent_fd)
        copied.append(target)
    v = import_file(copied[1], "trellis_canonical_proposal")
    v.require_sha256(args.aggregate_sha256, "aggregate digest")
    require(admission.records[str(args.aggregate_script)][1] == args.aggregate_sha256, "aggregate script digest mismatch")
    require(v.SLUG_RE.fullmatch(args.skill), "skill must be a lowercase slug")
    root = v.resolve_root(str(args.root))
    draft = v.load_json(copied[3], "evaluation draft")
    e = v.parse_evaluation(draft, "evaluation draft")
    live_run = root / e.run_dir
    snapshot_root = private / "project"
    snapshot_run = snapshot_root / e.run_dir
    admission.tree(live_run, snapshot_run)
    before = admission.records
    snapshot_before = freeze(snapshot_run, copied)
    # All downstream evidence readers receive only the bounded private copy.
    run_dir, candidate, authoritative = prevalidate(v, snapshot_root, e)
    target = root / e.benchmark.path
    require(target.is_relative_to(live_run), "benchmark must be below run_dir")
    v.ensure_real_directory_below(snapshot_root, snapshot_root / e.benchmark.path.parent, "benchmark parent")
    final = target.with_name("evaluation.json")
    require(target != final, "benchmark and evaluation targets must differ")
    require(not any(p.exists() or p.is_symlink() for p in (target, final)), "output target already exists")
    plugin = import_file(copied[2], "trellis_selected_aggregate")
    value = aggregate(v, plugin, run_dir, args.skill, candidate, e, authoritative)
    require(freeze(snapshot_run, copied) == snapshot_before, "snapshot input drift after plugin")
    value["metadata"]["skill_path"] = str(root / e.candidate_snapshot)
    payload = strict_json(value)
    draft["benchmark"]["sha256"] = hashlib.sha256(payload).hexdigest()
    evaluation_payload = strict_json(draft)
    require(admission.total + len(payload) + len(evaluation_payload) <= TOTAL_LIMIT, "aggregate limit exceeded with generated outputs")
    require(admission.entries + 2 <= ENTRY_LIMIT, "entry limit exceeded with generated outputs")
    finalized = v.parse_evaluation(draft, "final evaluation")
    snapshot_benchmark = snapshot_root / e.benchmark.path
    snapshot_benchmark.write_bytes(payload)
    v.bind_evaluation(snapshot_root, finalized, args.skill, "packed evaluation",
                      expected_patterns=tuple(p for p, _, _ in finalized.provenance),
                      expected_benchmark_relative=finalized.benchmark.path,
                      expected_candidate_dir=candidate)
    require(freeze(snapshot_run, copied, excluded=(snapshot_benchmark,)) == snapshot_before, "snapshot input drift after canonical binding")
    generated = Admission()
    generated.file(snapshot_benchmark)
    require(generated.records[str(snapshot_benchmark)][1] == draft["benchmark"]["sha256"], "generated benchmark drift")
    stage = Path(tempfile.mkdtemp(prefix=".skill-eval-v2-", dir=target.parent))
    temporaries.append(stage)
    benchmark_stage, evaluation_stage = stage / "benchmark.json", stage / "evaluation.json"
    benchmark_stage.write_bytes(payload)
    evaluation_stage.write_bytes(evaluation_payload)
    # Recheck bytes, modes, identities and exact inventory immediately before links.
    require(freeze(live_run, sources, excluded=(stage,)) == before, "consumed input drift before publication")
    for staged, destination in ((benchmark_stage, target), (evaluation_stage, final)):
        info = staged.stat()
        # Register ownership before linking, so an alarm cannot fall in between.
        owned.append((destination, info.st_dev, info.st_ino))
        os.link(staged, destination)
    return final


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("root", "evaluation", "aggregate-script"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--skill", required=True)
    parser.add_argument("--aggregate-sha256", required=True)
    args = parser.parse_args()
    owned, temporaries, success = [], [], False
    previous = signal.getsignal(signal.SIGALRM)

    def expired(signum, frame):
        raise TimeoutError("30-second pack operation deadline exceeded")

    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, 30)
    try:
        with localcontext() as context:
            context.prec = 28
            final = pack(args, owned, temporaries)
        print(final, flush=True)
        success = True
        return 0
    except Exception as error:
        success = False
        diagnostic(f"unavailable: {type(error).__name__}: {error}")
        return 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
        if not success:
            for path, device, inode in reversed(owned):
                try:
                    info = path.lstat()
                    if (info.st_dev, info.st_ino) == (device, inode):
                        path.unlink()
                except FileNotFoundError:
                    pass
                except OSError as error:
                    diagnostic(f"cleanup unavailable: {path}: {error}")
        for path in reversed(temporaries):
            try:
                shutil.rmtree(path)
            except OSError as error:
                diagnostic(f"cleanup unavailable: {path}: {error}")


def diagnostic(message):
    try:
        print(message, file=sys.stderr, flush=True)
    except OSError:
        pass  # A broken diagnostic stream must not replace the primary failure.


if __name__ == "__main__":
    raise SystemExit(main())
