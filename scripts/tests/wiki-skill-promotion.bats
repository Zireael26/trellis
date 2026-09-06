#!/usr/bin/env bats

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/wiki-skill"
PROJECT_FIXTURE="$FIXTURES/project"
QUALIFICATION_FIXTURES="$FIXTURES/qualification"
EVAL_FIXTURES="$FIXTURES/eval"
PROCESS_FIXTURES="$FIXTURES/process-gate"
WIKI_VALIDATOR="$REPO/core-rules/skills/wiki-maintain/scripts/validate_wiki.py"
PROPOSAL_VALIDATOR="$REPO/core-rules/skills/wiki-skill-propose/scripts/validate_proposal.py"

setup() {
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wiki-skill-promotion.XXXXXX")"
  PROJECT="$TEST_ROOT/project"
  cp -R "$PROJECT_FIXTURE" "$PROJECT"
  EVIDENCE_TOOL="$TEST_ROOT/evidence-tool.py"
  cat > "$EVIDENCE_TOOL" <<'EOF_EVIDENCE_TOOL'
#!/usr/bin/env python3
"""Test-side producer of version 2 cohort evaluation evidence.

Deliberately independent of validate_proposal.py: it re-implements the SCHEMA.md
tree-digest and canonical-JSON grammar, so a disagreement between producer and
verifier surfaces as a test failure instead of a shared bug.
"""

import hashlib
import json
import shutil
import sys
from decimal import Decimal
from pathlib import Path

EVAL_ID = 1
TASK_ID = "verified-deploy-order"
TASK_BYTES = b"# held-out task\nVerify the recorded dispatcher path, then verify it again.\n"
POLICY_BYTES = b"common non-treatment execution policy\n"
GRADER_CONFIG_BYTES = b"grader rubric configuration\n"
SETTINGS = {"max_output_tokens": 4096, "streaming": True, "temperature": "0.0"}
HARNESS = "claude"
HARNESS_VERSION = "1.0.0-rc.54"
OWNED_SUBDIRECTORIES = ("candidate", "tasks", "provenance", "runs")


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


def tree_digest(directory):
    entries = []
    for path in directory.rglob("*"):
        if path.is_symlink():
            raise SystemExit("snapshot must not contain a symlink: %s" % path)
        if path.is_dir():
            continue
        relative = path.relative_to(directory).as_posix().encode("utf-8")
        mode = path.lstat().st_mode
        flag = b"1" if mode & 0o111 else b"0"
        entries.append((relative, flag + b"\0" + sha_bytes(path.read_bytes()).encode("ascii")))
    if not entries:
        raise SystemExit("snapshot is empty: %s" % directory)
    entries.sort(key=lambda item: item[0])
    payload = b"".join(name + b"\0" + rest + b"\n" for name, rest in entries)
    return sha_bytes(payload)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def relative(project, path):
    return path.resolve().relative_to(project.resolve()).as_posix()


def cohort_of(executor_route, grader_route, task_digest, repetitions, seed):
    return {
        "tasks": [{"eval_id": EVAL_ID, "task_id": TASK_ID, "snapshot_sha256": task_digest}],
        "executor": {
            "route": executor_route,
            "harness": HARNESS,
            "harness_version": HARNESS_VERSION,
            "settings": SETTINGS,
            "common_policy_sha256": sha_bytes(POLICY_BYTES),
        },
        "grader": {"route": grader_route, "config_sha256": sha_bytes(GRADER_CONFIG_BYTES)},
        "repetitions": repetitions,
        "seed": seed,
    }


def synthetic_benchmark(skill, score, baseline, timestamp):
    return {
        "metadata": {
            "skill_name": skill,
            "timestamp": timestamp,
            "evals_run": [EVAL_ID],
            "runs_per_configuration": 1,
        },
        "runs": [
            {
                "eval_id": EVAL_ID,
                "eval_name": TASK_ID,
                "configuration": "with_skill",
                "run_number": 1,
                "result": {"pass_rate": float(score), "passed": 1, "failed": 0, "total": 1},
                "expectations": [],
                "notes": [],
            },
            {
                "eval_id": EVAL_ID,
                "eval_name": TASK_ID,
                "configuration": "without_skill",
                "run_number": 1,
                "result": {"pass_rate": float(baseline), "passed": 0, "failed": 1, "total": 1},
                "expectations": [],
                "notes": [],
            },
        ],
        "run_summary": {
            "with_skill": {"pass_rate": {"mean": float(score)}},
            "without_skill": {"pass_rate": {"mean": float(baseline)}},
        },
        "notes": [],
    }


def build_evaluation(
    project,
    run_dir,
    candidate_source,
    benchmark_path,
    patterns,
    executor_route,
    grader_route,
    seed="unseeded",
    repetitions=None,
):
    """Materialize one run directory and return its evaluation object."""
    run_dir.mkdir(parents=True, exist_ok=True)
    for name in OWNED_SUBDIRECTORIES:
        owned = run_dir / name
        if owned.exists():
            shutil.rmtree(owned)

    snapshot = run_dir / "candidate"
    shutil.copytree(candidate_source, snapshot)
    candidate_sha256 = tree_digest(snapshot)

    task_dir = run_dir / "tasks" / str(EVAL_ID)
    task_dir.mkdir(parents=True)
    (task_dir / "task.md").write_bytes(TASK_BYTES)
    task_digest = tree_digest(task_dir)

    benchmark = json.loads(benchmark_path.read_text())
    if repetitions is None:
        repetitions = benchmark["metadata"]["runs_per_configuration"]
    cohort = cohort_of(executor_route, grader_route, task_digest, repetitions, seed)
    cohort_id = sha_bytes(canonical(cohort))
    benchmark["metadata"]["trellis_evaluation"] = {
        "cohort_id": cohort_id,
        "candidate_sha256": candidate_sha256,
        "run_dir": relative(project, run_dir),
    }
    benchmark_path.write_text(json.dumps(benchmark, indent=2) + "\n")
    exact = json.loads(benchmark_path.read_text(), parse_float=Decimal)

    runs_dir = run_dir / "runs"
    runs_dir.mkdir(parents=True)
    artifacts = []
    for run in exact["runs"]:
        eval_id, configuration, run_number = run["eval_id"], run["configuration"], run["run_number"]
        stem = "%s-%s-%s" % (eval_id, configuration, run_number)
        output = runs_dir / (stem + ".out")
        output.write_bytes(("raw native transcript for %s\n" % stem).encode("utf-8"))
        grade_output = runs_dir / (stem + ".grade.txt")
        grade_output.write_bytes(("raw grader evidence for %s\n" % stem).encode("utf-8"))
        run_receipt = {
            "schema_version": 1,
            "eval_id": eval_id,
            "configuration": configuration,
            "run_number": run_number,
            "status": "executed",
            "exit_code": 0,
            "native_session_id": "native-session-%s" % stem,
            "observed_executor": cohort["executor"],
            "treatment_sha256": candidate_sha256 if configuration == "with_skill" else None,
            "output": {
                "path": relative(project, output),
                "sha256": sha_bytes(output.read_bytes()),
            },
            "grade": {
                "route": grader_route,
                "config_sha256": cohort["grader"]["config_sha256"],
                "pass_rate": str(run["result"]["pass_rate"]),
                "output": {
                    "path": relative(project, grade_output),
                    "sha256": sha_bytes(grade_output.read_bytes()),
                },
            },
        }
        receipt_path = runs_dir / (stem + ".json")
        receipt_path.write_text(json.dumps(run_receipt, indent=2, sort_keys=True) + "\n")
        artifacts.append(
            {
                "eval_id": eval_id,
                "configuration": configuration,
                "run_number": run_number,
                "path": relative(project, receipt_path),
                "sha256": sha_bytes(receipt_path.read_bytes()),
            }
        )

    provenance_dir = run_dir / "provenance"
    provenance_dir.mkdir(parents=True)
    provenance = []
    for slug in patterns:
        source = project / "wiki" / "patterns" / (slug + ".md")
        target = provenance_dir / (slug + ".md")
        shutil.copyfile(source, target)
        provenance.append(
            {
                "pattern": slug,
                "path": relative(project, target),
                "sha256": sha_bytes(target.read_bytes()),
            }
        )

    return {
        "cohort": cohort,
        "cohort_id": cohort_id,
        "candidate_sha256": candidate_sha256,
        "candidate_snapshot": relative(project, snapshot),
        "task_snapshots": [{"eval_id": EVAL_ID, "path": relative(project, task_dir)}],
        "provenance": provenance,
        "benchmark": {
            "path": relative(project, benchmark_path),
            "sha256": sha_bytes(benchmark_path.read_bytes()),
        },
        "run_dir": relative(project, run_dir),
        "artifacts": artifacts,
        "incumbents": [],
    }


def historical_candidate(destination, marker):
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "SKILL.md").write_text(
        "---\nname: one-skill\n---\n\n# one-skill\n\nHistorical accepted revision %s.\n" % marker
    )
    (destination / "PURPOSE.md").write_text(
        "# Purpose\n\n## Motivating patterns\n\n- [valid](../../../wiki/patterns/valid.md)\n"
    )
    return destination


def cmd_current(argv):
    project = Path(argv[0]).resolve()
    candidate = project / argv[1]
    benchmark_path = Path(argv[2]).resolve()
    receipt_path = Path(argv[3])
    patterns = [slug for slug in argv[4].split(",") if slug]
    receipt = json.loads(receipt_path.read_text())
    evaluation = build_evaluation(
        project,
        benchmark_path.parent,
        candidate,
        benchmark_path,
        patterns,
        receipt["runner_model"]["evaluator"],
        receipt["runner_model"]["judge"],
    )
    receipt["schema_version"] = 2
    receipt["evaluation"] = evaluation
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")


def append_row(project, date, sha, score, best_before, verdict, sidecar_relative):
    pull = "https://github.com/example/project/pull/%d" % (int(sha[0], 16) + 100)
    pr = pull if verdict in {"accepted", "rejected"} else "not-opened"
    row = (
        "| {date} | one-skill | diff={base}..{head}; patterns=valid; new-evidence=none "
        "| {score} | {best} | {verdict} | {pr} | [run receipt]({relative}) |\n"
    ).format(
        date=date,
        base="0" * 40,
        head=sha,
        score=score,
        best=best_before,
        verdict=verdict,
        pr=pr,
        relative=sidecar_relative,
    )
    with (project / "wiki" / "skill-impact.md").open("a") as handle:
        handle.write(row)


def base_receipt(sha, score, best_before, verdict, date):
    return {
        "skill": "one-skill",
        "proposal_sha": sha,
        "eval_cmd": "python3 -m scripts.aggregate_benchmark benchmarks/history --skill-name one-skill",
        "score": score,
        "best_before": best_before,
        "baseline": "0.60",
        "verdict": verdict,
        "run_at": date + "T12:00:00Z",
        "runner_model": {
            "proposer": "gpt::openai/gpt-5.6",
            "evaluator": "gemini::google/gemini-3.1-pro",
            "judge": "gemini::google/gemini-3.1-pro",
        },
    }


def cmd_history(argv):
    project = Path(argv[0]).resolve()
    sha, score, best_before, verdict = argv[1:5]
    seed = argv[5] if len(argv) > 5 and argv[5] else "unseeded"
    marker = argv[6] if len(argv) > 6 and argv[6] else sha[:12]
    date = "2026-08-28"
    run_dir = project / "benchmarks" / ("history-" + sha[:12])
    source = historical_candidate(run_dir / "source", marker)
    benchmark_path = run_dir / "benchmark.json"
    benchmark_path.parent.mkdir(parents=True, exist_ok=True)
    benchmark_path.write_text(
        json.dumps(synthetic_benchmark("one-skill", score, "0.60", date + "T11:55:00Z"), indent=2) + "\n"
    )
    receipt = base_receipt(sha, score, best_before, verdict, date)
    evaluation = build_evaluation(
        project,
        run_dir,
        source,
        benchmark_path,
        ["valid"],
        receipt["runner_model"]["evaluator"],
        receipt["runner_model"]["judge"],
        seed=seed,
    )
    receipt["schema_version"] = 2
    receipt["evaluation"] = evaluation
    sidecar_relative = "skill-impact/one-skill/%s-%s.json" % (date, sha[:12])
    sidecar = project / "wiki" / sidecar_relative
    sidecar.parent.mkdir(parents=True, exist_ok=True)
    sidecar.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    append_row(project, date, sha, score, best_before, verdict, sidecar_relative)


def cmd_legacy_history(argv):
    project = Path(argv[0]).resolve()
    sha, score, best_before, verdict = argv[1:5]
    date = "2026-08-28"
    receipt = base_receipt(sha, score, best_before, verdict, date)
    sidecar_relative = "skill-impact/one-skill/%s-%s.json" % (date, sha[:12])
    sidecar = project / "wiki" / sidecar_relative
    sidecar.parent.mkdir(parents=True, exist_ok=True)
    sidecar.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    append_row(project, date, sha, score, best_before, verdict, sidecar_relative)


def accepted_sidecar_for(project, sha):
    ledger = (project / "wiki" / "skill-impact.md").read_text()
    for line in ledger.splitlines():
        if (".." + sha) in line and "| accepted |" in line:
            start = line.rindex("](") + 2
            return project / "wiki" / line[start : line.rindex(")")]
    raise SystemExit("no accepted row for %s" % sha)


def cmd_incumbent(argv):
    project = Path(argv[0]).resolve()
    receipt_path = Path(argv[1])
    accepted_sha, score = argv[2], argv[3]
    reuse_run_dir = argv[4] if len(argv) > 4 else ""
    receipt = json.loads(receipt_path.read_text())
    cohort = receipt["evaluation"]["cohort"]
    sidecar = accepted_sidecar_for(project, accepted_sha)
    accepted = json.loads(sidecar.read_text())
    run_dir = project / "benchmarks" / (reuse_run_dir or ("reeval-" + accepted_sha[:12]))
    if reuse_run_dir and (run_dir / "candidate").exists():
        evaluation = json.loads((run_dir / "evaluation.json").read_text())
    else:
        source = run_dir / "source"
        if source.exists():
            shutil.rmtree(source)
        shutil.copytree(project / accepted["evaluation"]["candidate_snapshot"], source)
        benchmark_path = run_dir / "benchmark.json"
        benchmark_path.parent.mkdir(parents=True, exist_ok=True)
        benchmark_path.write_text(
            json.dumps(synthetic_benchmark("one-skill", score, "0.60", "2026-08-29T11:57:00Z"), indent=2) + "\n"
        )
        evaluation = build_evaluation(
            project,
            run_dir,
            source,
            benchmark_path,
            ["valid"],
            cohort["executor"]["route"],
            cohort["grader"]["route"],
            seed=cohort["seed"],
            repetitions=cohort["repetitions"],
        )
        evaluation.pop("incumbents")
        (run_dir / "evaluation.json").write_text(json.dumps(evaluation, indent=2) + "\n")
    receipt["evaluation"]["incumbents"].append(
        {
            "proposal_sha": accepted_sha,
            "accepted_receipt_sha256": sha_bytes(sidecar.read_bytes()),
            "evaluation": evaluation,
        }
    )
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")


def cmd_resync(argv):
    """Recompute cohort_id after a deliberate cohort mutation."""
    receipt_path = Path(argv[0])
    receipt = json.loads(receipt_path.read_text())
    evaluation = receipt["evaluation"]
    evaluation["cohort_id"] = sha_bytes(canonical(evaluation["cohort"]))
    if len(argv) > 1 and argv[1] == "--benchmark":
        project = Path(argv[2]).resolve()
        benchmark_path = project / evaluation["benchmark"]["path"]
        benchmark = json.loads(benchmark_path.read_text())
        benchmark["metadata"]["trellis_evaluation"]["cohort_id"] = evaluation["cohort_id"]
        benchmark_path.write_text(json.dumps(benchmark, indent=2) + "\n")
        evaluation["benchmark"]["sha256"] = sha_bytes(benchmark_path.read_bytes())
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")


def cmd_rehash_artifact(argv):
    """Re-point one artifact digest at its current bytes after a run mutation."""
    project = Path(argv[0]).resolve()
    receipt_path = Path(argv[1])
    receipt = json.loads(receipt_path.read_text())
    for artifact in receipt["evaluation"]["artifacts"]:
        artifact["sha256"] = sha_bytes((project / artifact["path"]).read_bytes())
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")


def cmd_two_rep(argv):
    """A two-repetition benchmark whose with_skill runs differ but mean 0.9."""
    path = Path(argv[0])
    document = synthetic_benchmark("one-skill", "0.90", "0.60", "2026-08-29T11:58:00Z")
    document["metadata"]["runs_per_configuration"] = 2
    runs = []
    for configuration, rates in (("with_skill", ["1.0", "0.8"]), ("without_skill", ["0.6", "0.6"])):
        for index, rate in enumerate(rates, start=1):
            runs.append(
                {
                    "eval_id": EVAL_ID,
                    "eval_name": TASK_ID,
                    "configuration": configuration,
                    "run_number": index,
                    "result": {"pass_rate": float(rate), "passed": 1, "failed": 0, "total": 1},
                    "expectations": [],
                    "notes": [],
                }
            )
    document["runs"] = runs
    path.write_text(json.dumps(document, indent=2) + "\n")


def cmd_legacy_receipt(argv):
    path = Path(argv[0])
    sha, score, best_before, verdict = argv[1:5]
    path.write_text(json.dumps(base_receipt(sha, score, best_before, verdict, "2026-08-28"), indent=2) + "\n")


COMMANDS = {
    "current": cmd_current,
    "two-rep": cmd_two_rep,
    "legacy-receipt": cmd_legacy_receipt,
    "history": cmd_history,
    "legacy-history": cmd_legacy_history,
    "incumbent": cmd_incumbent,
    "resync": cmd_resync,
    "rehash-artifact": cmd_rehash_artifact,
}

if __name__ == "__main__":
    COMMANDS[sys.argv[1]](sys.argv[2:])
EOF_EVIDENCE_TOOL
}

teardown() {
  rm -rf "$TEST_ROOT"
}

assert_json() {
  local expression="$1"
  CAPTURED_JSON="$output" python3 - "$expression" <<'PY'
import json
import os
import sys

try:
    document = json.loads(os.environ["CAPTURED_JSON"])
except Exception as exc:
    raise SystemExit("validator output is not JSON: %s\n%s" % (exc, os.environ["CAPTURED_JSON"]))
allowed = {
    "bool": bool,
    "all": all,
    "any": any,
    "dict": dict,
    "len": len,
    "list": list,
    "set": set,
    "sorted": sorted,
    "str": str,
}
if not eval(sys.argv[1], {"__builtins__": allowed}, {"j": document}):
    raise SystemExit("JSON assertion failed: %s\n%s" % (sys.argv[1], json.dumps(document, indent=2, sort_keys=True)))
PY
}

file_digest() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
print(hashlib.sha256(path.read_bytes()).hexdigest())
PY
}

tree_digest() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(p for p in root.rglob("*") if p.is_file()):
    digest.update(path.relative_to(root).as_posix().encode("utf-8"))
    digest.update(b"\0")
    digest.update(path.read_bytes())
    digest.update(b"\0")
print(digest.hexdigest())
PY
}

make_valid_wiki() {
  python3 - "$1" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
index = root / "wiki" / "index.md"
index.write_text("\n".join(line for line in index.read_text().splitlines() if "broken-context" not in line) + "\n")
page = root / "wiki" / "patterns" / "broken-context.md"
if page.exists():
    page.unlink()
PY
}

reset_ledger() {
  mkdir -p "$1/wiki"
  cat > "$1/wiki/skill-impact.md" <<'EOF_LEDGER'
# Skill impact ledger

Durable record of every evaluated create or patch proposal.

| date | skill | diff ref | eval score | best-before | verdict | PR | run receipt |
|---|---|---|---:|---|---|---|---|
EOF_LEDGER
  rm -rf "$1/wiki/skill-impact"
}

set_pattern_status() {
  python3 - "$1" "$2" "$3" <<'PY'
import pathlib
import sys

root, slug, status = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
page = root / "wiki" / "patterns" / (slug + ".md")
text = page.read_text()
for old in ("status: active", "status: stale", "status: retired"):
    if old in text:
        text = text.replace(old, "status: " + status, 1)
        break
page.write_text(text)
index = root / "wiki" / "index.md"
lines = []
for line in index.read_text().splitlines():
    if "](" + "patterns/" + slug + ".md)" in line:
        cells = line.split("|")
        cells[2] = " " + status + " "
        line = "|".join(cells)
    lines.append(line)
index.write_text("\n".join(lines) + "\n")
PY
}

add_superseded_pattern() {
  python3 - "$1" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
source = root / "wiki" / "patterns" / "valid.md"
target = root / "wiki" / "patterns" / "superseded.md"
text = source.read_text().replace("slug: valid", "slug: superseded", 1).replace("# Pattern: valid", "# Pattern: superseded", 1)
target.write_text(text)
index = root / "wiki" / "index.md"
index.write_text(index.read_text() + "| [superseded](patterns/superseded.md) | active | [gotchas.md#managed-dispatcher-drift](../gotchas.md#managed-dispatcher-drift) | 2026-08-20 |\n")
PY
}

materialize_rejected_sidecar() {
  python3 - "$1" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
ledger = (root / "wiki" / "skill-impact.md").read_text()
match = re.search(r"\((skill-impact/one-skill/2026-08-20-(1{7,12})\.json)\)", ledger)
if not match:
    raise SystemExit("historical rejected receipt link is missing")
path = root / "wiki" / match.group(1)
path.parent.mkdir(parents=True, exist_ok=True)
receipt = {
    "skill": "one-skill",
    "proposal_sha": "1" * 40,
    "eval_cmd": "python3 -m scripts.aggregate_benchmark benchmarks/2026-08-20T115500Z --skill-name one-skill",
    "score": "0.75",
    "best_before": "0.70",
    "baseline": "0.60",
    "verdict": "rejected",
    "run_at": "2026-08-20T12:00:00Z",
    "runner_model": {
        "proposer": "gpt::openai/gpt-5.6",
        "evaluator": "gemini::google/gemini-3.1-pro",
        "judge": "gemini::google/gemini-3.1-pro",
    },
}
path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
PY
}

write_proposal_diff() {
  python3 - "$PROPOSAL_DIFF" "$RECEIPT" "$@" <<'PY'
import json
import pathlib
import sys

output, receipt_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
receipt = json.loads(receipt_path.read_text())
paths = sys.argv[3:] or [
    "core-rules/skills/one-skill/SKILL.md",
    "core-rules/skills/one-skill/PURPOSE.md",
]
payload = {
    "base": "0" * 40,
    "head": receipt["proposal_sha"],
    "changed_paths": paths,
}
output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
}

prepare_proposal() {
  local project="$1"
  local receipt_source="$2"
  local ledger_mode="${3:-empty}"
  PROJECT="$project"
  make_valid_wiki "$PROJECT"
  if [ "$ledger_mode" = "empty" ]; then
    reset_ledger "$PROJECT"
  fi
  mkdir -p "$PROJECT/benchmarks/2026-08-29T115500Z"
  BENCHMARK="$PROJECT/benchmarks/2026-08-29T115500Z/benchmark.json"
  cp "$EVAL_FIXTURES/benchmark.json" "$BENCHMARK"
  RECEIPT="$TEST_ROOT/current-receipt.json"
  cp "$receipt_source" "$RECEIPT"
  QUALIFICATION="$TEST_ROOT/qualification-decision.json"
  python3 "$WIKI_VALIDATOR" qualify --evidence "$QUALIFICATION_FIXTURES/recurrence.json" > "$QUALIFICATION"
  PROPOSAL_DIFF="$TEST_ROOT/proposal-diff.json"
  CANDIDATE_REL="core-rules/skills/one-skill"
  SKILL_ROOT="core-rules/skills"
  PATTERNS="valid"
  PROCESS_RECEIPT="$PROCESS_FIXTURES/pass.txt"
  write_proposal_diff
  build_evaluation
}

proposal_check() {
  python3 "$PROPOSAL_VALIDATOR" check \
    --root "$PROJECT" \
    --candidate "$CANDIDATE_REL" \
    --patterns "$PATTERNS" \
    --benchmark "$BENCHMARK" \
    --receipt "$RECEIPT" \
    --process-gate-receipt "$PROCESS_RECEIPT" \
    --skill-root "$SKILL_ROOT" \
    --proposal-diff "$PROPOSAL_DIFF" \
    --qualification "$QUALIFICATION" \
    "$@"
}

proposal_record() {
  local pr="$1"
  shift
  python3 "$PROPOSAL_VALIDATOR" record \
    --root "$PROJECT" \
    --candidate "$CANDIDATE_REL" \
    --patterns "$PATTERNS" \
    --benchmark "$BENCHMARK" \
    --receipt "$RECEIPT" \
    --process-gate-receipt "$PROCESS_RECEIPT" \
    --skill-root "$SKILL_ROOT" \
    --proposal-diff "$PROPOSAL_DIFF" \
    --qualification "$QUALIFICATION" \
    --pr "$pr" \
    "$@"
}

set_receipt_fields() {
  python3 - "$1" "$2" "${@:3}" <<'PY'
import json
import pathlib
import sys

source, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
document = json.loads(source.read_text())
items = sys.argv[3:]
if len(items) % 2:
    raise SystemExit("receipt field updates must be key/value pairs")
for index in range(0, len(items), 2):
    document[items[index]] = items[index + 1]
output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
}

set_runner_models() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text())
document["runner_model"] = {
    "proposer": sys.argv[2],
    "evaluator": sys.argv[3],
    "judge": sys.argv[4],
}
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
}


# Version 2 history: a full same-cohort accepted receipt with its own retained
# run directory, so the comparator can revalidate the evidence it binds.
append_history_receipt() {
  python3 "$EVIDENCE_TOOL" history "$@"
}

# Deliberate legacy fixture: an unversioned nine-field receipt with no
# verifiable candidate-content binding.
append_legacy_history_receipt() {
  python3 "$EVIDENCE_TOOL" legacy-history "$@"
}

build_evaluation() {
  python3 "$EVIDENCE_TOOL" current "$PROJECT" "$CANDIDATE_REL" "$BENCHMARK" "$RECEIPT" "$PATTERNS"
}

add_incumbent() {
  python3 "$EVIDENCE_TOOL" incumbent "$PROJECT" "$RECEIPT" "$@"
}

resync_cohort() {
  python3 "$EVIDENCE_TOOL" resync "$RECEIPT" "$@"
}

rehash_artifacts() {
  python3 "$EVIDENCE_TOOL" rehash-artifact "$PROJECT" "$RECEIPT"
}

receipt_edit() {
  python3 - "$RECEIPT" "$1" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text())
exec(sys.argv[2], {"json": json}, {"doc": document})
path.write_text(json.dumps(document, indent=2) + "\n")
PY
}

run_receipt_edit() {
  python3 - "$PROJECT" "$RECEIPT" "$1" "$2" <<'PY'
import json
import pathlib
import sys

project, receipt_path, configuration, code = sys.argv[1:]
receipt = json.loads(pathlib.Path(receipt_path).read_text())
for artifact in receipt["evaluation"]["artifacts"]:
    if artifact["configuration"] != configuration:
        continue
    path = pathlib.Path(project) / artifact["path"]
    document = json.loads(path.read_text())
    exec(code, {"json": json}, {"doc": document})
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
  rehash_artifacts
}

init_git_project() {
  local root="$1"
  git -C "$root" init -q
  git -C "$root" config user.name "WikiSkill receipt test"
  git -C "$root" config user.email "wikiskill-receipt@example.invalid"
  git -C "$root" add .
  git -C "$root" commit -q -m "baseline"
  git -C "$root" branch -M main
}

apply_human_source_link() {
  python3 - "$1/gotchas.md" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = "**Verified repair.** Inspect the recorded hook path, restore the managed dispatcher at the configured path, run doctor, and run doctor once more to verify that the drift does not return."
new = "**Promoted procedure.** See [one-skill](core-rules/skills/one-skill/SKILL.md). The recorded incident context remains here; the skill is the sole procedure authority."
if text.count(old) != 1:
    raise SystemExit("expected exactly one source procedure")
path.write_text(text.replace(old, new))
PY
}

@test "qualification accepts two distinct recorded occurrences" {
  run python3 "$WIKI_VALIDATOR" qualify --evidence "$QUALIFICATION_FIXTURES/recurrence.json"
  [ "$status" -eq 0 ]
  assert_json "j['verdict'] == 'qualify' and j['predicate'] == 'recurrence' and len(j['occurrences']) == 2"
}

@test "qualification accepts one complete repeatable path" {
  run python3 "$WIKI_VALIDATOR" qualify --evidence "$QUALIFICATION_FIXTURES/repeatable-path.json"
  [ "$status" -eq 0 ]
  assert_json "j['verdict'] == 'qualify' and j['predicate'] == 'repeatable-path' and len(j['steps']) >= 3 and len(j['preconditions']) > 0 and bool(j['verification'])"
}

@test "qualification rejects mention-only evidence" {
  run python3 "$WIKI_VALIDATOR" qualify --evidence "$QUALIFICATION_FIXTURES/mention-only.json"
  [ "$status" -eq 1 ]
  assert_json "j['verdict'] == 'retain-as-gotcha'"
}

@test "qualification rejects a one-line fact" {
  run python3 "$WIKI_VALIDATOR" qualify --evidence "$QUALIFICATION_FIXTURES/one-line.json"
  [ "$status" -eq 1 ]
  assert_json "j['verdict'] == 'retain-as-gotcha'"
}

@test "qualification rejects an arbitrary three-item list" {
  run python3 "$WIKI_VALIDATOR" qualify --evidence "$QUALIFICATION_FIXTURES/arbitrary-list.json"
  [ "$status" -eq 1 ]
  assert_json "j['verdict'] == 'retain-as-gotcha'"
}

@test "qualification rejects an unverified occurrence" {
  run python3 "$WIKI_VALIDATOR" qualify --evidence "$QUALIFICATION_FIXTURES/unverified-occurrence.json"
  [ "$status" -eq 1 ]
  assert_json "j['verdict'] == 'retain-as-gotcha'"
}

@test "qualification rejects secret-bearing evidence without echoing a secret value" {
  run python3 "$WIKI_VALIDATOR" qualify --evidence "$QUALIFICATION_FIXTURES/secret.json"
  [ "$status" -eq 1 ]
  assert_json "j['verdict'] == 'retain-as-gotcha'"
  CAPTURED_JSON="$output" python3 - "$QUALIFICATION_FIXTURES/secret.json" <<'PY'
import json
import os
import pathlib
import sys

source = json.loads(pathlib.Path(sys.argv[1]).read_text())
rendered = os.environ["CAPTURED_JSON"]
for value in source["inputs"]:
    if value and value in rendered:
        raise SystemExit("secret-bearing input or retrieval reference was echoed")
if "DEPLOY_TOKEN" in rendered or "vault://" in rendered:
    raise SystemExit("secret name or retrieval reference escaped redaction")
PY
}

@test "pattern and evidence validator accepts the exact active contract" {
  make_valid_wiki "$PROJECT"
  run python3 "$WIKI_VALIDATOR" check --root "$PROJECT"
  [ "$status" -eq 0 ]
  assert_json "j['verdict'] == 'valid'"
  run python3 - "$PROJECT/wiki/patterns/valid.md" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
required = ["## Failure mode", "## Root cause", "## Working path", "## Dead ends", "## Evidence"]
assert all(text.count(heading) == 1 for heading in required)
assert text.count("\n1. ") == 1 and text.count("\n2. ") == 1 and "\n3. " not in text
assert "../../gotchas.md#" in text
assert "../../context-log.md#" in text or "../../decisions-log.md#" in text
assert "https://github.com/" in text and "/pull/" in text
PY
  [ "$status" -eq 0 ]
}

@test "index validator rejects a missing pattern page" {
  make_valid_wiki "$PROJECT"
  rm "$PROJECT/wiki/patterns/valid.md"
  run python3 "$WIKI_VALIDATOR" check --root "$PROJECT"
  [ "$status" -eq 1 ]
  assert_json "j['verdict'] == 'invalid'"
}

@test "index validator rejects a bad status" {
  make_valid_wiki "$PROJECT"
  python3 - "$PROJECT/wiki/patterns/valid.md" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace("status: active", "status: proposed", 1))
PY
  run python3 "$WIKI_VALIDATOR" check --root "$PROJECT"
  [ "$status" -eq 1 ]
  assert_json "j['verdict'] == 'invalid'"
}

@test "index validator rejects a duplicate slug" {
  make_valid_wiki "$PROJECT"
  python3 - "$PROJECT/wiki/index.md" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
row = next(line for line in path.read_text().splitlines() if line.startswith("| [valid]"))
path.write_text(path.read_text() + row + "\n")
PY
  run python3 "$WIKI_VALIDATOR" check --root "$PROJECT"
  [ "$status" -eq 1 ]
  assert_json "j['verdict'] == 'invalid'"
}

@test "index validator rejects a source that differs from pattern evidence" {
  make_valid_wiki "$PROJECT"
  python3 - "$PROJECT/wiki/index.md" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text().replace("../gotchas.md#managed-dispatcher-drift", "../gotchas.md#managed-dispatcher-repair", 1)
path.write_text(text)
PY
  run python3 "$WIKI_VALIDATOR" check --root "$PROJECT"
  [ "$status" -eq 1 ]
  assert_json "j['verdict'] == 'invalid'"
}

@test "broken evidence marks only its page and index row stale" {
  cp -R "$PROJECT" "$TEST_ROOT/before-stale"
  local impact_before gotcha_before skill_before
  impact_before="$(file_digest "$PROJECT/wiki/skill-impact.md")"
  gotcha_before="$(file_digest "$PROJECT/gotchas.md")"
  skill_before="$(tree_digest "$PROJECT/core-rules/skills")"
  run python3 "$WIKI_VALIDATOR" mark-stale --root "$PROJECT"
  [ "$status" -eq 0 ]
  assert_json "j['verdict'] == 'valid'"
  python3 - "$TEST_ROOT/before-stale" "$PROJECT" <<'PY'
import pathlib
import sys
before, after = map(pathlib.Path, sys.argv[1:])
changed = []
for path in sorted(p for p in after.rglob("*") if p.is_file()):
    relative = path.relative_to(after)
    old = before / relative
    if not old.exists() or old.read_bytes() != path.read_bytes():
        changed.append(relative.as_posix())
assert changed == ["wiki/index.md", "wiki/patterns/broken-context.md"], changed
assert "status: stale" in (after / "wiki/patterns/broken-context.md").read_text()
assert "[broken-context](patterns/broken-context.md) | stale |" in (after / "wiki/index.md").read_text()
assert "status: active" in (after / "wiki/patterns/valid.md").read_text()
PY
  [ "$(file_digest "$PROJECT/wiki/skill-impact.md")" = "$impact_before" ]
  [ "$(file_digest "$PROJECT/gotchas.md")" = "$gotcha_before" ]
  [ "$(tree_digest "$PROJECT/core-rules/skills")" = "$skill_before" ]
}

@test "mark-stale preserves LF CRLF and CR bytes except intended status and date edits" {
  local ending candidate
  for ending in LF CRLF CR; do
    candidate="$TEST_ROOT/$ending"
    cp -R "$PROJECT" "$candidate"
    python3 - "$candidate" "$ending" <<'PY'
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
ending = {"LF": b"\n", "CRLF": b"\r\n", "CR": b"\r"}[sys.argv[2]]
for path in [root / "wiki/index.md", *sorted((root / "wiki/patterns").glob("*.md"))]:
    path.write_bytes(ending.join(path.read_bytes().splitlines()) + ending)
PY
    cp -R "$candidate" "$TEST_ROOT/$ending-before"
    run python3 "$WIKI_VALIDATOR" mark-stale --root "$candidate"
    [ "$status" -eq 0 ]
    assert_json "j['verdict'] == 'valid' and j['changed_paths'] == ['wiki/index.md', 'wiki/patterns/broken-context.md']"
    run python3 "$WIKI_VALIDATOR" check --root "$candidate"
    [ "$status" -eq 0 ]
    assert_json "j['verdict'] == 'valid'"
    python3 - "$TEST_ROOT/$ending-before" "$candidate" <<'PY'
from datetime import date
import pathlib
import sys
before, after = map(pathlib.Path, sys.argv[1:])
old_files = {p.relative_to(before): p.read_bytes() for p in before.rglob("*") if p.is_file()}
new_files = {p.relative_to(after): p.read_bytes() for p in after.rglob("*") if p.is_file()}
expected = dict(old_files)
page = pathlib.Path("wiki/patterns/broken-context.md")
expected[page] = expected[page].replace(b"status: active", b"status: stale", 1)
index = pathlib.Path("wiki/index.md")
rows = expected[index].splitlines(keepends=True)
for position, row in enumerate(rows):
    if row.startswith(b"| [broken-context]"):
        cells = row.split(b"|")
        cells[2] = cells[2].replace(b"active", b"stale")
        old_date = cells[4].strip()
        cells[4] = cells[4].replace(old_date, max(old_date, date.today().isoformat().encode()))
        rows[position] = b"|".join(cells)
expected[index] = b"".join(rows)
assert new_files == expected, [str(p) for p in expected if new_files.get(p) != expected[p]]
PY
  done
}

@test "mark-stale fails closed when fcntl is unavailable" {
  local command wiki_before
  wiki_before="$(tree_digest "$PROJECT/wiki")"
  for command in check mark-stale; do
    run python3 - "$WIKI_VALIDATOR" "$PROJECT" "$command" <<'PY'
import builtins
import runpy
import sys

validator, root, command = sys.argv[1:]
real_import = builtins.__import__


def blocked_import(name, *args, **kwargs):
    if name == "fcntl":
        raise ImportError("fcntl blocked by test")
    return real_import(name, *args, **kwargs)


builtins.__import__ = blocked_import
sys.argv = [validator, command, "--root", root]
runpy.run_path(validator, run_name="__main__")
PY
    [ "$status" -ne 0 ]
    assert_json "j['verdict'] == 'malformed' and j['errors'][0]['code'] == 'lock'"
    [ "$(tree_digest "$PROJECT/wiki")" = "$wiki_before" ]
  done
}

@test "mark-stale reports rollback and temporary cleanup failures" {
  run python3 - "$WIKI_VALIDATOR" "$PROJECT" <<'PY'
import importlib.util
import pathlib
import sys

validator, root = sys.argv[1:]
spec = importlib.util.spec_from_file_location("validate_wiki_failure_test", validator)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
real_replace = module.os.replace
real_unlink = pathlib.Path.unlink


def injected_replace(source, target):
    source_path = pathlib.Path(source)
    target_path = pathlib.Path(target)
    if source_path.suffix == ".rollback":
        raise OSError("sentinel restore failure")
    if source_path.suffix == ".tmp" and target_path.name == "index.md":
        raise OSError("sentinel replace failure")
    return real_replace(source, target)


def injected_unlink(path, *args, **kwargs):
    if path.suffix == ".tmp" and path.exists():
        raise OSError("sentinel cleanup failure")
    return real_unlink(path, *args, **kwargs)


module.os.replace = injected_replace
pathlib.Path.unlink = injected_unlink
raise SystemExit(module.main(["mark-stale", "--root", root]))
PY
  [ "$status" -ne 0 ]
  local expected
  expected="j['verdict'] == 'malformed' and 'rollback failed' in j['errors'][0]['message']"
  expected+=" and 'sentinel restore failure' in j['errors'][0]['message']"
  expected+=" and 'temporary cleanup failed' in j['errors'][0]['message']"
  expected+=" and 'sentinel cleanup failure' in j['errors'][0]['message']"
  assert_json "$expected"
}

@test "unexpected RuntimeError is not relabelled as malformed input" {
  run python3 - "$WIKI_VALIDATOR" "$PROJECT" <<'PY'
import importlib.util
import sys

validator, root = sys.argv[1:]
spec = importlib.util.spec_from_file_location("validate_wiki_runtime_test", validator)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def fail_with_sentinel(_root):
    raise RuntimeError("sentinel runtime failure")


module._run_check = fail_with_sentinel
raise SystemExit(module.main(["check", "--root", root]))
PY
  [ "$status" -ne 0 ]
  [[ "$output" == *"sentinel runtime failure"* ]]
  [[ "$output" != *"input could not be safely validated"* ]]
}

@test "wiki validator rejects the forbidden logs layer" {
  make_valid_wiki "$PROJECT"
  printf '%s\n' '# Forbidden wiki log' > "$PROJECT/wiki/logs.md"
  run python3 "$WIKI_VALIDATOR" check --root "$PROJECT"
  [ "$status" -eq 1 ]
  assert_json "j['verdict'] == 'invalid'"
}

@test "explicit catalog read resolves the linked pattern on demand" {
  make_valid_wiki "$PROJECT"
  run python3 - "$PROJECT" <<'PY'
import pathlib
import re
import sys
root = pathlib.Path(sys.argv[1])
index = (root / "wiki" / "index.md").read_text()
match = re.search(r"\[valid\]\((patterns/valid\.md)\)", index)
assert match
page = (root / "wiki" / match.group(1)).resolve()
assert page.is_file() and page.is_relative_to((root / "wiki").resolve())
text = page.read_text()
assert "# Pattern: valid" in text and "## Working path" in text and "## Evidence" in text
PY
  [ "$status" -eq 0 ]
}

@test "check-change accepts one new indexed pattern and preserves both roots" {
  make_valid_wiki "$PROJECT"
  cp -R "$PROJECT" "$TEST_ROOT/after"
  cp -R "$PROJECT" "$TEST_ROOT/before"
  rm "$TEST_ROOT/before/wiki/patterns/valid.md"
  python3 - "$TEST_ROOT/before/wiki/index.md" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
path.write_text("\n".join(line for line in path.read_text().splitlines() if "[valid]" not in line) + "\n")
PY
  local before_hash after_hash
  before_hash="$(tree_digest "$TEST_ROOT/before")"
  after_hash="$(tree_digest "$TEST_ROOT/after")"
  run python3 "$WIKI_VALIDATOR" check-change --before "$TEST_ROOT/before" --after "$TEST_ROOT/after"
  [ "$status" -eq 0 ]
  assert_json "j['verdict'] == 'allowed' and j['transition'] == 'create'"
  [ "$(tree_digest "$TEST_ROOT/before")" = "$before_hash" ]
  [ "$(tree_digest "$TEST_ROOT/after")" = "$after_hash" ]
}

@test "check-change distinguishes merge with superseded retirement" {
  make_valid_wiki "$PROJECT"
  add_superseded_pattern "$PROJECT"
  cp -R "$PROJECT" "$TEST_ROOT/before"
  cp -R "$PROJECT" "$TEST_ROOT/after"
  set_pattern_status "$TEST_ROOT/after" superseded retired
  printf '%s\n' '- The superseded pattern is retained only as history; this page is the surviving procedure.' >> "$TEST_ROOT/after/wiki/patterns/valid.md"
  local before_hash after_hash
  before_hash="$(tree_digest "$TEST_ROOT/before")"
  after_hash="$(tree_digest "$TEST_ROOT/after")"
  run python3 "$WIKI_VALIDATOR" check-change --before "$TEST_ROOT/before" --after "$TEST_ROOT/after"
  [ "$status" -eq 0 ]
  assert_json "j['verdict'] == 'allowed' and j['transition'] == 'merge-with-retirement'"
  [ "$(tree_digest "$TEST_ROOT/before")" = "$before_hash" ]
  [ "$(tree_digest "$TEST_ROOT/after")" = "$after_hash" ]
}

@test "check-change distinguishes explicit superseded retirement" {
  make_valid_wiki "$PROJECT"
  add_superseded_pattern "$PROJECT"
  cp -R "$PROJECT" "$TEST_ROOT/before"
  cp -R "$PROJECT" "$TEST_ROOT/after"
  set_pattern_status "$TEST_ROOT/after" superseded retired
  local before_hash after_hash
  before_hash="$(tree_digest "$TEST_ROOT/before")"
  after_hash="$(tree_digest "$TEST_ROOT/after")"
  run python3 "$WIKI_VALIDATOR" check-change --before "$TEST_ROOT/before" --after "$TEST_ROOT/after"
  [ "$status" -eq 0 ]
  assert_json "j['verdict'] == 'allowed' and j['transition'] == 'retire-superseded'"
  [ "$(tree_digest "$TEST_ROOT/before")" = "$before_hash" ]
  [ "$(tree_digest "$TEST_ROOT/after")" = "$after_hash" ]
}

@test "check-change accepts an unresolved-evidence stale transition" {
  cp -R "$PROJECT" "$TEST_ROOT/before"
  cp -R "$PROJECT" "$TEST_ROOT/after"
  python3 "$WIKI_VALIDATOR" mark-stale --root "$TEST_ROOT/after" >/dev/null
  local before_hash after_hash
  before_hash="$(tree_digest "$TEST_ROOT/before")"
  after_hash="$(tree_digest "$TEST_ROOT/after")"
  run python3 "$WIKI_VALIDATOR" check-change --before "$TEST_ROOT/before" --after "$TEST_ROOT/after"
  [ "$status" -eq 0 ]
  assert_json "j['verdict'] == 'allowed' and j['transition'] == 'mark-stale'"
  [ "$(tree_digest "$TEST_ROOT/before")" = "$before_hash" ]
  [ "$(tree_digest "$TEST_ROOT/after")" = "$after_hash" ]
}

@test "check-change rejects skill gotcha impact and unrelated diffs without mutating roots" {
  local kind before after before_hash after_hash
  for kind in skill gotcha impact unrelated; do
    before="$TEST_ROOT/${kind}-before"
    after="$TEST_ROOT/${kind}-after"
    cp -R "$PROJECT" "$before"
    cp -R "$PROJECT" "$after"
    case "$kind" in
      skill) printf '%s\n' '# forbidden' >> "$after/core-rules/skills/one-skill/SKILL.md" ;;
      gotcha) printf '%s\n' 'forbidden' >> "$after/gotchas.md" ;;
      impact) printf '%s\n' 'forbidden' >> "$after/wiki/skill-impact.md" ;;
      unrelated) printf '%s\n' 'forbidden' > "$after/README.md" ;;
    esac
    before_hash="$(tree_digest "$before")"
    after_hash="$(tree_digest "$after")"
    run python3 "$WIKI_VALIDATOR" check-change --before "$before" --after "$after"
    [ "$status" -eq 1 ]
    assert_json "j['verdict'] == 'rejected'"
    [ "$(tree_digest "$before")" = "$before_hash" ]
    [ "$(tree_digest "$after")" = "$after_hash" ]
  done
}

t8_transition_cases() {
  python3 - "$WIKI_VALIDATOR" "$PROJECT" "$TEST_ROOT" "$@" <<'PY'
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

validator, project, scratch = sys.argv[1:4]
page_rel = "wiki/patterns/valid.md"
historical = "- 2026-08-20 refine prior=sha256:" + "a" * 64 + " — Recorded reassessment.\n"

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def snapshot(root):
    return {str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*") if p.is_file()}

def status(root, slug, old, new):
    page = root / ("wiki/patterns/" + slug + ".md")
    page.write_bytes(page.read_bytes().replace(("status: " + old).encode(), ("status: " + new).encode(), 1))
    index = root / "wiki/index.md"
    index.write_text(index.read_text().replace("patterns/" + slug + ".md) | " + old, "patterns/" + slug + ".md) | " + new))

for case in sys.argv[4:]:
    before = pathlib.Path(scratch) / (case + "-before")
    after = pathlib.Path(scratch) / (case + "-after")
    shutil.copytree(project, before)
    page = before / page_rel
    index = before / "wiki/index.md"
    index.write_text("\n".join(line for line in index.read_text().splitlines() if "broken-context" not in line) + "\n")
    (before / "wiki/patterns/broken-context.md").unlink()
    history_cases = {"history-append", "history-rewrite", "history-remove", "history-normalize", "merge-preserve", "merge-rewrite", "merge-remove", "date-order"}
    if case in history_cases:
        page.write_bytes(page.read_bytes() + b"\n## Provenance\n" + historical.encode())
    if case.startswith("merge-") or case in {"other-row", "other-page", "unrelated-stale"}:
        second = before / "wiki/patterns/second.md"
        second.write_text(page.read_text().split("\n## Provenance")[0].replace("slug: valid", "slug: second").replace("# Pattern: valid", "# Pattern: second"))
        index.write_text(index.read_text() + "| [second](patterns/second.md) | active | [gotchas.md#managed-dispatcher-drift](../gotchas.md#managed-dispatcher-drift) | 2026-08-20 |\n")
    reactivate = case in {"reactivate-restored", "reactivate-repaired", "reactivate-unresolved", "unrelated-stale", "retired-active", "source-repair"}
    if reactivate:
        status(before, "valid", "active", "retired" if case == "retired-active" else "stale")
        if case in {"reactivate-repaired", "reactivate-unresolved", "source-repair"}:
            page.write_text(page.read_text().replace("context-log.md#session-2026-08-20", "context-log.md#missing"))
        if case == "unrelated-stale":
            status(before, "second", "active", "stale")
    if case in {"crlf", "crlf-normalized", "history-normalize"}:
        page.write_bytes(page.read_bytes().replace(b"\n", b"\r\n"))
    shutil.copytree(before, after)
    new_page = after / page_rel
    new_index = after / "wiki/index.md"
    action = "reactivate" if reactivate else "refine"
    prior = digest(page)
    if case == "wrong-hash":
        prior = "0" * 64
    if case == "crlf-normalized":
        prior = hashlib.sha256(page.read_text().encode()).hexdigest()
        assert prior != digest(page)
    if reactivate:
        status(after, "valid", "retired" if case == "retired-active" else "stale", "active")
        if case == "reactivate-repaired":
            new_page.write_text(new_page.read_text().replace("context-log.md#missing", "context-log.md#session-2026-08-20"))
        if case == "source-repair":
            with (after / "context-log.md").open("a") as handle:
                handle.write("\n## missing\nSeparately forbidden source repair.\n")
    elif case not in {"no-op", "provenance-only", "whitespace-only", "heading-only"}:
        new_page.write_bytes(new_page.read_bytes().replace(b"## Working path", b"## Working path\nInspect the recorded dispatcher again after installation."))
    if case == "whitespace-only":
        new_page.write_bytes(new_page.read_bytes().replace(b"Preconditions:", b"  Preconditions:   "))
    if case == "heading-only":
        new_page.write_bytes(new_page.read_bytes().replace(b"## Working path", b"## Working path\n### Reassessment"))
    if case in {"history-rewrite", "merge-rewrite"}:
        new_page.write_bytes(new_page.read_bytes().replace(b"Recorded reassessment.", b"Rewritten reassessment."))
    if case in {"history-remove", "merge-remove"}:
        new_page.write_bytes(new_page.read_bytes().split(b"\n## Provenance")[0] + b"\n")
    if case == "history-normalize":
        new_page.write_text(new_page.read_text())
    if case != "no-op" and not case.startswith("merge-"):
        when = "2026-08-30"
        if case == "invalid-date":
            when = "2026-02-30"
        if case == "date-order":
            when = "2026-08-19"
        if case == "wrong-action":
            action = "reactivate"
        record = f"- {when} {action} prior=sha256:{prior} — Evidence-backed fixture correction.\n"
        if case == "empty-reason":
            record = record.replace("Evidence-backed fixture correction.", "  ")
        prefix = "\n## Provenance\n" if b"## Provenance" not in new_page.read_bytes() or case == "duplicate-section" else ""
        with new_page.open("ab") as handle:
            handle.write((prefix + record).encode())
            if case == "duplicate-section":
                handle.write(("\n## Provenance\n" + record).encode())
            if case == "extra-record":
                handle.write(record.encode())
    if case != "no-op":
        new_index.write_text(new_index.read_text().replace("2026-08-20", "2026-08-30", 1))
    if case == "date-decrease":
        new_index.write_text(new_index.read_text().replace("2026-08-30", "2026-08-19", 1))
    if case == "index-unchanged":
        new_index.write_bytes(index.read_bytes())
    if case == "other-row":
        new_index.write_text(new_index.read_text().replace("| [second]", "|  [second]"))
    if case == "other-page":
        with (after / "wiki/patterns/second.md").open("a") as handle:
            handle.write("\nUnrelated prose.\n")
    if case == "unresolved-after":
        new_page.write_bytes(new_page.read_bytes().replace(b"context-log.md#session-2026-08-20", b"context-log.md#missing"))
    if case == "forbidden-gotcha":
        with (after / "gotchas.md").open("a") as handle:
            handle.write("\nForbidden evidence edit.\n")
    if case.startswith("merge-"):
        status(after, "second", "active", "retired")
    expected = case in {"refine", "crlf", "history-append", "reactivate-restored", "reactivate-repaired", "merge-preserve"}
    old_snapshot, new_snapshot = snapshot(before), snapshot(after)
    result = subprocess.run([sys.executable, validator, "check-change", "--before", str(before), "--after", str(after)], capture_output=True, text=True)
    report = json.loads(result.stdout)
    assert result.returncode == (0 if expected else 1), (case, result.returncode, report, result.stderr)
    assert snapshot(before) == old_snapshot and snapshot(after) == new_snapshot, case
    if expected:
        transition = "merge-with-retirement" if case.startswith("merge-") else action
        assert report["verdict"] == "allowed" and report["transition"] == transition, (case, report)
        if not case.startswith("merge-"):
            assert report["changed_paths"] == ["wiki/index.md", page_rel], report
            assert report["provenance"] == {"slug": "valid", "prior_sha256": digest(page), "after_sha256": digest(new_page)}, report
    elif case in {"forbidden-gotcha", "source-repair"}:
        assert any(error["code"] == "forbidden-path" for error in report["errors"]), report
    print(case + ": " + ("allowed" if expected else "rejected"))
PY
}

@test "T8 refinement active meaningful change and retained history" {
  run t8_transition_cases refine history-append
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "T8 refinement raw digest rejects fabricated and normalized CRLF identity with positive controls" {
  run t8_transition_cases refine crlf wrong-hash crlf-normalized
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "T8 refinement reactivation permits selected restored or repaired evidence only" {
  run t8_transition_cases reactivate-restored reactivate-repaired reactivate-unresolved unrelated-stale retired-active source-repair
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "T8 refinement rejects no-op provenance whitespace and headings only" {
  run t8_transition_cases no-op provenance-only whitespace-only heading-only
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "T8 refinement rejects malformed provenance grammar dates order and duplicate sections" {
  run t8_transition_cases invalid-date date-order duplicate-section wrong-action empty-reason extra-record
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "T8 refinement preserves historical record bytes including merge survivors" {
  run t8_transition_cases merge-preserve merge-rewrite merge-remove history-rewrite history-remove history-normalize
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "T8 refinement enforces exact two paths own row date and clean evidence" {
  run t8_transition_cases date-decrease index-unchanged other-row other-page unresolved-after forbidden-gotcha
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "impact record creates one exact eight-column row and linked v2 receipt" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  run proposal_record not-opened
  [ "$status" -eq 0 ]
  run python3 - "$PROJECT" <<'PY'
import json
import pathlib
import re
import sys
root = pathlib.Path(sys.argv[1])
ledger = (root / "wiki" / "skill-impact.md").read_text()
lines = ledger.splitlines()
header = next(line for line in lines if line.startswith("| date |"))
assert [cell.strip() for cell in header.strip("|").split("|")] == ["date", "skill", "diff ref", "eval score", "best-before", "verdict", "PR", "run receipt"]
rows = [line for line in lines if re.match(r"^\| \d{4}-\d{2}-\d{2} \|", line)]
assert len(rows) == 1, rows
assert len(rows[0].strip("|").split("|")) == 8
link = re.search(r"\((skill-impact/one-skill/2026-08-29-2{12}\.json)\)", rows[0])
assert link, rows[0]
receipt = json.loads((root / "wiki" / link.group(1)).read_text())
assert set(receipt) >= {"skill", "proposal_sha", "eval_cmd", "score", "best_before", "baseline", "verdict", "run_at", "runner_model"}
assert set(receipt) == {"schema_version", "skill", "proposal_sha", "eval_cmd", "score", "best_before", "baseline", "verdict", "run_at", "runner_model", "evaluation"}
assert receipt["schema_version"] == 2
assert set(receipt["evaluation"]) == {"cohort", "cohort_id", "candidate_sha256", "candidate_snapshot", "task_snapshots", "provenance", "benchmark", "run_dir", "artifacts", "incumbents"}
assert set(receipt["runner_model"]) == {"proposer", "evaluator", "judge"}
assert receipt["proposal_sha"] == "2" * 40 and receipt["verdict"] == "eval-passed"
diff_ref = [cell.strip() for cell in rows[0].strip("|").split("|")][2]
diff_match = re.fullmatch(r"diff=([0-9a-f]{40})\.\.([0-9a-f]{40}); patterns=valid; new-evidence=none", diff_ref)
assert diff_match, diff_ref
assert diff_match.group(1) == "0" * 40
assert diff_match.group(2) == receipt["proposal_sha"]
assert "| 0.90 | 0.60 | eval-passed | not-opened |" in rows[0]
PY
  [ "$status" -eq 0 ]
  local recorded_project="$PROJECT"
  local ref_case
  for ref_case in short-base nonhex-head mismatched-head; do
    PROJECT="$TEST_ROOT/bad-diff-ref-$ref_case"
    cp -R "$recorded_project" "$PROJECT"
    python3 - "$PROJECT/wiki/skill-impact.md" "$ref_case" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
text = path.read_text()
base = "0" * 40
head = "2" * 40
original = "diff=" + base + ".." + head
replacements = {
    "short-base": "diff=" + ("0" * 39) + ".." + head,
    "nonhex-head": "diff=" + base + ".." + ("g" * 40),
    "mismatched-head": "diff=" + base + ".." + ("3" * 40),
}
assert text.count(original) == 1
path.write_text(text.replace(original, replacements[mode], 1))
PY
    run proposal_check
    [ "$status" -ne 0 ]
  done

  PROJECT="$recorded_project"
  local symlink_case outside_project outside_target outside_before symlink_path
  for symlink_case in wiki impact skill; do
    outside_project="$TEST_ROOT/symlink-$symlink_case-project"
    cp -R "$PROJECT_FIXTURE" "$outside_project"
    prepare_proposal "$outside_project" "$EVAL_FIXTURES/receipt-pass.json" empty
    outside_target="$TEST_ROOT/symlink-$symlink_case-outside"
    case "$symlink_case" in
      wiki)
        mv "$outside_project/wiki" "$outside_target"
        symlink_path="$outside_project/wiki"
        ln -s "$outside_target" "$symlink_path"
        ;;
      impact)
        mkdir -p "$outside_target"
        printf '%s\n' 'outside sentinel' > "$outside_target/sentinel"
        symlink_path="$outside_project/wiki/skill-impact"
        ln -s "$outside_target" "$symlink_path"
        ;;
      skill)
        mkdir -p "$outside_project/wiki/skill-impact" "$outside_target"
        printf '%s\n' 'outside sentinel' > "$outside_target/sentinel"
        symlink_path="$outside_project/wiki/skill-impact/one-skill"
        ln -s "$outside_target" "$symlink_path"
        ;;
    esac
    outside_before="$(tree_digest "$outside_target")"
    run proposal_record not-opened
    [ "$status" -ne 0 ]
    [ -L "$symlink_path" ]
    [ "$(tree_digest "$outside_target")" = "$outside_before" ]
  done
}

@test "same row and sidecar finalize only forward and malformed lifecycle edits fail closed" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  run proposal_record not-opened
  [ "$status" -eq 0 ]
  local eval_receipt="$RECEIPT"
  local accepted="$TEST_ROOT/accepted.json"
  set_receipt_fields "$eval_receipt" "$accepted" verdict accepted
  RECEIPT="$accepted"
  local recorded_sidecar="$PROJECT/wiki/skill-impact/one-skill/2026-08-29-222222222222.json"
  local ledger_before sidecar_before injection_dir injected_status
  local had_pythonpath=0
  local previous_pythonpath=""
  ledger_before="$(file_digest "$PROJECT/wiki/skill-impact.md")"
  sidecar_before="$(file_digest "$recorded_sidecar")"
  injection_dir="$TEST_ROOT/ledger-write-failure"
  mkdir -p "$injection_dir"
  cat > "$injection_dir/sitecustomize.py" <<'PY'
import errno
import os

_real_fsync = os.fsync
_target = os.stat(os.environ["WIKI_TEST_FAIL_FSYNC"])
_failed = False


def _fail_target_once(descriptor):
    global _failed
    current = os.fstat(descriptor)
    if not _failed and (current.st_dev, current.st_ino) == (_target.st_dev, _target.st_ino):
        _failed = True
        raise OSError(errno.EIO, "injected ledger fsync failure")
    return _real_fsync(descriptor)


os.fsync = _fail_target_once
PY
  if [ "${PYTHONPATH+x}" = x ]; then
    had_pythonpath=1
    previous_pythonpath="$PYTHONPATH"
  fi
  export WIKI_TEST_FAIL_FSYNC="$PROJECT/wiki/skill-impact.md"
  export PYTHONPATH="$injection_dir${PYTHONPATH:+:$PYTHONPATH}"
  run proposal_record https://github.com/example/project/pull/456
  injected_status="$status"
  unset WIKI_TEST_FAIL_FSYNC
  if [ "$had_pythonpath" -eq 1 ]; then
    export PYTHONPATH="$previous_pythonpath"
  else
    unset PYTHONPATH
  fi
  [ "$injected_status" -ne 0 ]
  [ "$(file_digest "$PROJECT/wiki/skill-impact.md")" = "$ledger_before" ]
  [ "$(file_digest "$recorded_sidecar")" = "$sidecar_before" ]
  run python3 - "$PROJECT/wiki/skill-impact.md" "$recorded_sidecar" <<'PY'
import json
import pathlib
import re
import sys

ledger = pathlib.Path(sys.argv[1]).read_text()
row = next(line for line in ledger.splitlines() if re.match(r"^\| \d{4}-", line))
receipt = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert "| eval-passed | not-opened |" in row
assert receipt["verdict"] == "eval-passed"
PY
  [ "$status" -eq 0 ]
  run proposal_record https://github.com/example/project/pull/456
  [ "$status" -eq 0 ]
  run python3 - "$PROJECT" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
ledger = (root / "wiki" / "skill-impact.md").read_text()
rows = [line for line in ledger.splitlines() if re.match(r"^\| \d{4}-", line)]
assert len(rows) == 1 and "| accepted | https://github.com/example/project/pull/456 |" in rows[0]
link = re.search(r"\((skill-impact/[^)]+\.json)\)", rows[0]).group(1)
assert json.loads((root / "wiki" / link).read_text())["verdict"] == "accepted"
PY
  [ "$status" -eq 0 ]

  run proposal_record https://github.com/example/project/pull/456
  [ "$status" -ne 0 ]
  RECEIPT="$eval_receipt"
  run proposal_record https://github.com/example/project/pull/456
  [ "$status" -ne 0 ]
  local rejected="$TEST_ROOT/rejected.json"
  set_receipt_fields "$eval_receipt" "$rejected" verdict rejected
  RECEIPT="$rejected"
  run proposal_record https://github.com/example/project/pull/456
  [ "$status" -ne 0 ]

  local malformed="$TEST_ROOT/malformed.json"
  python3 - "$accepted" "$malformed" <<'PY'
import json, pathlib, sys
document = json.loads(pathlib.Path(sys.argv[1]).read_text())
document["unexpected"] = True
pathlib.Path(sys.argv[2]).write_text(json.dumps(document) + "\n")
PY
  RECEIPT="$malformed"
  run proposal_record https://github.com/example/project/pull/456
  [ "$status" -ne 0 ]

  python3 - "$PROJECT/wiki/skill-impact.md" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
row = next(line for line in text.splitlines() if re.match(r"^\| \d{4}-", line))
path.write_text(text + row + "\n")
PY
  RECEIPT="$eval_receipt"
  run proposal_record not-opened
  [ "$status" -ne 0 ]
  python3 - "$PROJECT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
ledger_path = root / "wiki" / "skill-impact.md"
lines = ledger_path.read_text().splitlines()
seen_row = False
deduplicated = []
for line in lines:
    if re.match(r"^\| \d{4}-", line):
        if seen_row:
            continue
        seen_row = True
    deduplicated.append(line)
ledger_path.write_text("\n".join(deduplicated) + "\n")
ledger = ledger_path.read_text()
link = re.search(r"\((skill-impact/[^)]+\.json)\)", ledger).group(1)
(root / "wiki" / link).unlink()
PY
  run proposal_record not-opened
  [ "$status" -ne 0 ]
}

@test "accepted best uses strict decimal comparison and excludes non-accepted scores" {
  local scenario expected
  for scenario in above equal below excluded; do
    PROJECT="$TEST_ROOT/score-$scenario"
    cp -R "$PROJECT_FIXTURE" "$PROJECT"
    prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
    case "$scenario" in
      above)
        append_history_receipt "$PROJECT" "4$(printf '%039d' 0)" 0.80 0.60 accepted
        set_receipt_fields "$RECEIPT" "$TEST_ROOT/current-$scenario.json" best_before 0.80
        expected=0
        ;;
      equal)
        append_history_receipt "$PROJECT" "5$(printf '%039d' 0)" 0.90 0.60 accepted
        set_receipt_fields "$RECEIPT" "$TEST_ROOT/current-$scenario.json" best_before 0.90
        expected=1
        ;;
      below)
        append_history_receipt "$PROJECT" "6$(printf '%039d' 0)" 0.95 0.60 accepted
        set_receipt_fields "$RECEIPT" "$TEST_ROOT/current-$scenario.json" best_before 0.95
        expected=1
        ;;
      excluded)
        append_history_receipt "$PROJECT" "7$(printf '%039d' 0)" 0.80 0.60 accepted
        append_history_receipt "$PROJECT" "8$(printf '%039d' 0)" 0.99 0.80 eval-passed
        set_receipt_fields "$RECEIPT" "$TEST_ROOT/current-$scenario.json" best_before 0.80
        expected=0
        ;;
    esac
    RECEIPT="$TEST_ROOT/current-$scenario.json"
    run proposal_check
    [ "$status" -eq "$expected" ]
    if [ "$expected" -eq 0 ]; then
      assert_json "j['status'] == 'EVAL-PASSED'"
    fi
  done
}

@test "first proposal uses same-run no-skill mean and rejects equality" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  cp "$EVAL_FIXTURES/benchmark-equal.json" "$BENCHMARK"
  set_receipt_fields "$RECEIPT" "$TEST_ROOT/equal-receipt.json" score 0.60 best_before 0.60 baseline 0.60
  RECEIPT="$TEST_ROOT/equal-receipt.json"
  build_evaluation
  run proposal_check
  [ "$status" -eq 1 ]
  assert_json "j['status'] != 'EVAL-PASSED'"
}

@test "failed process gate is never review ready" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  PROCESS_RECEIPT="$PROCESS_FIXTURES/fail.txt"
  run proposal_check
  [ "$status" -eq 1 ]
  assert_json "j['status'] != 'EVAL-PASSED'"
}

@test "runner families use canonical routes differ from proposer and may share evaluator judge" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  run proposal_check
  [ "$status" -eq 0 ]
  assert_json "j['status'] == 'EVAL-PASSED'"

  cp "$EVAL_FIXTURES/receipt-same-family.json" "$RECEIPT"
  write_proposal_diff
  build_evaluation
  run proposal_check
  [ "$status" -eq 1 ]

  cp "$EVAL_FIXTURES/receipt-pass.json" "$RECEIPT"
  set_runner_models "$RECEIPT" "gpt::openai/gpt-5.6" "gemini::google/gemini-3.1-pro" "gpt::openai/gpt-5.6"
  write_proposal_diff
  build_evaluation
  run proposal_check
  [ "$status" -eq 1 ]

  set_runner_models "$RECEIPT" "openai/gpt-5.6" "gemini::google/gemini-3.1-pro" "gemini::google/gemini-3.1-pro"
  run proposal_check
  [ "$status" -eq 2 ]
}

@test "Purpose backlinks exactly match selected patterns and resolve at configured depths" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  run proposal_check
  [ "$status" -eq 0 ]

  printf '%s\n' '- [valid duplicate](../../../wiki/patterns/valid.md)' >> "$PROJECT/core-rules/skills/one-skill/PURPOSE.md"
  run proposal_check
  [ "$status" -eq 1 ]
  cp "$PROJECT_FIXTURE/core-rules/skills/one-skill/PURPOSE.md" "$PROJECT/core-rules/skills/one-skill/PURPOSE.md"
  python3 - "$PROJECT/core-rules/skills/one-skill/PURPOSE.md" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace("- [valid](../../../wiki/patterns/valid.md)\n", ""))
PY
  run proposal_check
  [ "$status" -eq 1 ]

  PROJECT="$TEST_ROOT/attached-project"
  cp -R "$PROJECT_FIXTURE" "$PROJECT"
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  mkdir -p "$PROJECT/project-skills"
  mv "$PROJECT/core-rules/skills/one-skill" "$PROJECT/project-skills/one-skill"
  python3 - "$PROJECT/project-skills/one-skill/PURPOSE.md" "$BENCHMARK" <<'PY'
import json, pathlib, sys
purpose = pathlib.Path(sys.argv[1])
purpose.write_text(purpose.read_text().replace("../../../wiki/patterns/valid.md", "../../wiki/patterns/valid.md"))
benchmark = pathlib.Path(sys.argv[2])
document = json.loads(benchmark.read_text())
document["metadata"]["skill_path"] = "project-skills/one-skill"
benchmark.write_text(json.dumps(document, indent=2) + "\n")
PY
  CANDIDATE_REL="project-skills/one-skill"
  SKILL_ROOT="project-skills"
  write_proposal_diff "project-skills/one-skill/SKILL.md" "project-skills/one-skill/PURPOSE.md"
  build_evaluation
  run proposal_check
  [ "$status" -eq 0 ]
}

@test "stale and retired pattern inputs are refused before evaluation" {
  local state
  for state in stale retired; do
    PROJECT="$TEST_ROOT/status-$state"
    cp -R "$PROJECT_FIXTURE" "$PROJECT"
    prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
    set_pattern_status "$PROJECT" valid "$state"
    BENCHMARK="$PROJECT/benchmarks/does-not-exist/benchmark.json"
    run proposal_check
    [ "$status" -eq 1 ]
    assert_json "j['status'] != 'EVAL-PASSED'"
  done
}

@test "exact final rejected pattern set is refused before evaluation" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" keep
  local ledger_before
  ledger_before="$(file_digest "$PROJECT/wiki/skill-impact.md")"
  run proposal_check
  [ "$status" -eq 1 ]
  assert_json "j['status'] != 'EVAL-PASSED'"
  [ "$(file_digest "$PROJECT/wiki/skill-impact.md")" = "$ledger_before" ]
}

@test "new cited evidence permits a fresh proposal and preserves the old rejection" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-new-evidence.json" keep
  materialize_rejected_sidecar "$PROJECT"
  local evidence="https://github.com/example/project/pull/456"
  local receipt_before old_receipt old_row_before
  old_receipt="$(python3 - "$PROJECT/wiki/skill-impact.md" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
print(re.search(r"\((skill-impact/one-skill/2026-08-20-[^)]+\.json)\)", text).group(1))
PY
)"
  old_row_before="$(python3 - "$PROJECT/wiki/skill-impact.md" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
print(next(line for line in text.splitlines() if re.match(r"^\| 2026-08-20 \|", line)))
PY
)"
  receipt_before="$(file_digest "$PROJECT/wiki/$old_receipt")"
  run proposal_check --new-evidence "$evidence"
  [ "$status" -eq 0 ]
  run proposal_record not-opened --new-evidence "$evidence"
  [ "$status" -eq 0 ]
  run python3 - "$PROJECT" "$evidence" "$receipt_before" "$old_receipt" "$old_row_before" <<'PY'
import hashlib, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
evidence, old_receipt_hash, old_receipt, old_row = sys.argv[2:]
ledger = (root / "wiki" / "skill-impact.md").read_text()
rows = [line for line in ledger.splitlines() if re.match(r"^\| \d{4}-", line)]
assert len(rows) == 2, rows
assert rows[0] == old_row
assert "| rejected |" in rows[0] and "new-evidence=none" in rows[0]
assert "new-evidence=" + evidence in rows[1]
assert hashlib.sha256((root / "wiki" / old_receipt).read_bytes()).hexdigest() == old_receipt_hash
PY
  [ "$status" -eq 0 ]
}

@test "proposal diff enforces PR-wide one-skill atomicity and safe skill roots" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  run proposal_check
  [ "$status" -eq 0 ]

  mkdir -p "$PROJECT/core-rules/skills/second-skill"
  cp "$PROJECT/core-rules/skills/one-skill/SKILL.md" "$PROJECT/core-rules/skills/second-skill/SKILL.md"
  cp "$PROJECT/core-rules/skills/one-skill/PURPOSE.md" "$PROJECT/core-rules/skills/second-skill/PURPOSE.md"
  write_proposal_diff \
    "core-rules/skills/one-skill/SKILL.md" \
    "core-rules/skills/one-skill/PURPOSE.md" \
    "core-rules/skills/second-skill/SKILL.md"
  run proposal_check
  [ "$status" -eq 1 ]
  rm -rf "$PROJECT/core-rules/skills/second-skill"
  local outside_path
  for outside_path in README.md wiki/index.md; do
    write_proposal_diff \
      "core-rules/skills/one-skill/SKILL.md" \
      "core-rules/skills/one-skill/PURPOSE.md" \
      "$outside_path"
    run proposal_check
    [ "$status" -eq 1 ]
  done

  local unsafe_root
  for unsafe_root in .git/skills .claude/skills .agents/skills; do
    mkdir -p "$PROJECT/$unsafe_root"
    cp -R "$PROJECT/core-rules/skills/one-skill" "$PROJECT/$unsafe_root/one-skill"
    CANDIDATE_REL="$unsafe_root/one-skill"
    SKILL_ROOT="$unsafe_root"
    write_proposal_diff \
      "$unsafe_root/one-skill/SKILL.md" \
      "$unsafe_root/one-skill/PURPOSE.md"
    run proposal_check
    [ "$status" -ne 0 ]
  done

  local global_root="$TEST_ROOT/userhome/.claude/skills"
  CANDIDATE_REL="$global_root/one-skill"
  SKILL_ROOT="$global_root"
  mkdir -p "$global_root"
  cp -R "$PROJECT/core-rules/skills/one-skill" "$global_root/one-skill"
  run proposal_check
  [ "$status" -ne 0 ]
}

@test "validator and advisory executables contain no landing or network command path" {
  run python3 - \
    "$WIKI_VALIDATOR" \
    "$PROPOSAL_VALIDATOR" \
    "$REPO/core-rules/hooks/wiki-skill-suggest.sh" \
    "$REPO/core-rules/codex/hooks/wiki-skill-suggest.sh" <<'PY'
import ast
import os
import pathlib
import re
import sys

paths = [pathlib.Path(value) for value in sys.argv[1:]]
assert all(path.is_file() and os.access(path, os.X_OK) for path in paths)
for path in paths:
    text = path.read_text()
    if path.suffix == ".py":
        tree = ast.parse(text)
        banned_imports = {"subprocess", "socket", "http", "requests"}
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                assert not any(alias.name.split(".")[0] in banned_imports for alias in node.names), (path, node.lineno)
            if isinstance(node, ast.ImportFrom):
                module = node.module or ""
                assert module.split(".")[0] not in banned_imports and module != "urllib.request", (path, node.lineno)
            if isinstance(node, ast.Call):
                name = ""
                if isinstance(node.func, ast.Name):
                    name = node.func.id
                elif isinstance(node.func, ast.Attribute):
                    name = node.func.attr
                assert name not in {"system", "popen", "execv", "execve", "spawn", "urlopen"}, (path, node.lineno, name)
    else:
        active = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        assert not re.search(r"\bgit\s+(?:add|commit|push|merge|checkout|switch|branch|tag|update-ref|receive-pack)\b", active)
        assert not re.search(r"\bgh\s+(?:pr|api|repo|workflow)\b", active)
        assert not re.search(r"\b(?:curl|wget|scp|rsync)\b", active)
PY
  [ "$status" -eq 0 ]
}

@test "green validation remains candidate and leaves refs protected global and release state unchanged" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  init_git_project "$PROJECT"
  local bare="$TEST_ROOT/protected.git"
  git clone -q --bare "$PROJECT" "$bare"
  local home="$TEST_ROOT/userhome"
  mkdir -p "$home" "$TEST_ROOT/bin"
  cat > "$TEST_ROOT/bin/gh" <<'EOF_GH'
#!/usr/bin/env bash
: > "${PR_STUB:?}"
EOF_GH
  chmod +x "$TEST_ROOT/bin/gh"
  local ref_before bare_ref_before source_before candidate_before release_before ledger_before inputs_before
  ref_before="$(git -C "$PROJECT" rev-parse refs/heads/main)"
  bare_ref_before="$(git --git-dir="$bare" rev-parse refs/heads/main)"
  source_before="$(file_digest "$PROJECT/gotchas.md")"
  candidate_before="$(tree_digest "$PROJECT/core-rules/skills/one-skill")"
  release_before="$(file_digest "$WIKI_VALIDATOR"):$(file_digest "$PROPOSAL_VALIDATOR"):$(file_digest "$REPO/core-rules/hooks/wiki-skill-suggest.sh"):$(file_digest "$REPO/core-rules/codex/hooks/wiki-skill-suggest.sh")"
  ledger_before="$(file_digest "$PROJECT/wiki/skill-impact.md")"
  inputs_before="$(file_digest "$BENCHMARK"):$(file_digest "$RECEIPT"):$(file_digest "$PROCESS_RECEIPT"):$(file_digest "$PROPOSAL_DIFF"):$(file_digest "$QUALIFICATION")"

  export HOME="$home"
  export PATH="$TEST_ROOT/bin:$PATH"
  export PR_STUB="$TEST_ROOT/pr-command-invoked"
  export GIT_DIR="$bare"
  run python3 "$WIKI_VALIDATOR" check --root "$PROJECT"
  [ "$status" -eq 0 ]
  run proposal_check
  [ "$status" -eq 0 ]
  assert_json "j['status'] == 'EVAL-PASSED'"
  unset GIT_DIR
  run env HOME="$home" CLAUDE_PROJECT_DIR="$PROJECT" "$REPO/core-rules/hooks/wiki-skill-suggest.sh" <<EOF_EVENT
{"tool_input":{"file_path":"$PROJECT/gotchas.md"}}
EOF_EVENT
  [ "$status" -eq 0 ]
  run env HOME="$home" CODEX_PROJECT_DIR="$PROJECT" "$REPO/core-rules/codex/hooks/wiki-skill-suggest.sh" <<EOF_EVENT
{"tool_input":{"file_path":"$PROJECT/gotchas.md"}}
EOF_EVENT
  [ "$status" -eq 0 ]

  [ "$(git -C "$PROJECT" rev-parse refs/heads/main)" = "$ref_before" ]
  [ "$(git --git-dir="$bare" rev-parse refs/heads/main)" = "$bare_ref_before" ]
  [ "$(file_digest "$PROJECT/gotchas.md")" = "$source_before" ]
  [ "$(tree_digest "$PROJECT/core-rules/skills/one-skill")" = "$candidate_before" ]
  [ "$(file_digest "$WIKI_VALIDATOR"):$(file_digest "$PROPOSAL_VALIDATOR"):$(file_digest "$REPO/core-rules/hooks/wiki-skill-suggest.sh"):$(file_digest "$REPO/core-rules/codex/hooks/wiki-skill-suggest.sh")" = "$release_before" ]
  [ "$(file_digest "$PROJECT/wiki/skill-impact.md")" = "$ledger_before" ]
  [ "$(file_digest "$BENCHMARK"):$(file_digest "$RECEIPT"):$(file_digest "$PROCESS_RECEIPT"):$(file_digest "$PROPOSAL_DIFF"):$(file_digest "$QUALIFICATION")" = "$inputs_before" ]
  [ ! -e "$home/.claude/skills" ]
  [ ! -e "$home/.agents/skills" ]
  [ ! -e "$PR_STUB" ]
  run python3 - "$PROJECT/core-rules/skills/one-skill/SKILL.md" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert "candidate remains non-authoritative" in text.lower()
assert "PROMOTED" not in text
PY
  [ "$status" -eq 0 ]
}

@test "source gotcha remains authoritative before merge and after rejection" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  local source_before candidate_before rejected_receipt
  source_before="$(file_digest "$PROJECT/gotchas.md")"
  candidate_before="$(tree_digest "$PROJECT/core-rules/skills/one-skill")"
  run proposal_check
  [ "$status" -eq 0 ]
  [ "$(file_digest "$PROJECT/gotchas.md")" = "$source_before" ]
  PROCESS_RECEIPT="$PROCESS_FIXTURES/fail.txt"
  run proposal_check
  [ "$status" -eq 1 ]
  [ "$(file_digest "$PROJECT/gotchas.md")" = "$source_before" ]
  PROCESS_RECEIPT="$PROCESS_FIXTURES/pass.txt"
  run proposal_record not-opened
  [ "$status" -eq 0 ]
  rejected_receipt="$TEST_ROOT/source-rejection.json"
  set_receipt_fields "$RECEIPT" "$rejected_receipt" verdict rejected
  RECEIPT="$rejected_receipt"
  run proposal_record https://github.com/example/project/pull/456
  [ "$status" -eq 0 ]
  [ "$(file_digest "$PROJECT/gotchas.md")" = "$source_before" ]
  run python3 - "$PROJECT/wiki/skill-impact.md" "$PROJECT/wiki/skill-impact/one-skill/2026-08-29-222222222222.json" <<'PY'
import json, pathlib, sys
ledger = pathlib.Path(sys.argv[1]).read_text()
receipt = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert "| rejected | https://github.com/example/project/pull/456 |" in ledger
assert receipt["verdict"] == "rejected"
PY
  [ "$status" -eq 0 ]
  [ "$(tree_digest "$PROJECT/core-rules/skills/one-skill")" = "$candidate_before" ]
  run python3 - "$PROJECT/gotchas.md" "$PROJECT/core-rules/skills/one-skill/SKILL.md" <<'PY'
import pathlib, sys
gotcha = pathlib.Path(sys.argv[1]).read_text()
skill = pathlib.Path(sys.argv[2]).read_text()
assert "**Verified repair.**" in gotcha
assert "candidate remains non-authoritative" in skill.lower()
PY
  [ "$status" -eq 0 ]
}

@test "controlled human merge atomically leaves one procedure authority" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-new-evidence.json" keep
  materialize_rejected_sidecar "$PROJECT"
  run proposal_check --new-evidence https://github.com/example/project/pull/456
  [ "$status" -eq 0 ]
  cp -R "$PROJECT/core-rules/skills/one-skill" "$TEST_ROOT/candidate"
  rm -rf "$PROJECT/core-rules/skills/one-skill"
  init_git_project "$PROJECT"
  git -C "$PROJECT" checkout -q -b proposal
  cp -R "$TEST_ROOT/candidate" "$PROJECT/core-rules/skills/one-skill"
  apply_human_source_link "$PROJECT"
  git -C "$PROJECT" add gotchas.md core-rules/skills/one-skill
  git -C "$PROJECT" commit -q -m "propose one-skill and retire source procedure"
  git -C "$PROJECT" checkout -q main
  git -C "$PROJECT" merge -q --no-ff proposal -m "human merge of reviewed promotion"
  run python3 - "$PROJECT" <<'PY'
import pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
changed = set(subprocess.check_output(["git", "-C", str(root), "diff", "--name-only", "HEAD^1", "HEAD"], text=True).splitlines())
assert "gotchas.md" in changed
assert "core-rules/skills/one-skill/SKILL.md" in changed
assert "core-rules/skills/one-skill/PURPOSE.md" in changed
assert not any(path.startswith("wiki/") for path in changed)
gotcha = (root / "gotchas.md").read_text()
skill = (root / "core-rules/skills/one-skill/SKILL.md").read_text()
assert "[one-skill](core-rules/skills/one-skill/SKILL.md)" in gotcha
assert "Inspect the recorded hook path, restore the managed dispatcher" not in gotcha
assert "## Procedure" in skill
PY
  [ "$status" -eq 0 ]
}

@test "controlled human revert restores source while wiki ledger and receipts remain durable" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-new-evidence.json" keep
  materialize_rejected_sidecar "$PROJECT"
  run proposal_check --new-evidence https://github.com/example/project/pull/456
  [ "$status" -eq 0 ]
  cp "$PROJECT/gotchas.md" "$TEST_ROOT/original-gotchas.md"
  cp -R "$PROJECT/core-rules/skills/one-skill" "$TEST_ROOT/candidate"
  rm -rf "$PROJECT/core-rules/skills/one-skill"
  init_git_project "$PROJECT"
  git -C "$PROJECT" checkout -q -b proposal
  cp -R "$TEST_ROOT/candidate" "$PROJECT/core-rules/skills/one-skill"
  apply_human_source_link "$PROJECT"
  git -C "$PROJECT" add gotchas.md core-rules/skills/one-skill
  git -C "$PROJECT" commit -q -m "propose one-skill and retire source procedure"
  git -C "$PROJECT" checkout -q main
  git -C "$PROJECT" merge -q --no-ff proposal -m "human merge of reviewed promotion"
  local durable_before
  durable_before="$(tree_digest "$PROJECT/wiki")"
  git -C "$PROJECT" revert -m 1 --no-edit HEAD
  cmp "$TEST_ROOT/original-gotchas.md" "$PROJECT/gotchas.md"
  [ ! -e "$PROJECT/core-rules/skills/one-skill" ]
  [ "$(tree_digest "$PROJECT/wiki")" = "$durable_before" ]
  run python3 - "$PROJECT" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
gotcha = (root / "gotchas.md").read_text()
assert "**Verified repair.** Inspect the recorded hook path" in gotcha
index = (root / "wiki" / "index.md").read_text()
ledger = (root / "wiki" / "skill-impact.md").read_text()
assert "[valid](patterns/valid.md)" in index
link = re.search(r"\((skill-impact/one-skill/2026-08-20-[^)]+\.json)\)", ledger).group(1)
assert json.loads((root / "wiki" / link).read_text())["verdict"] == "rejected"
PY
  [ "$status" -eq 0 ]
}

@test "T8 cohort version 2 evidence promotes a valid baseline and refuses unversioned or unknown receipts" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  run proposal_check
  [ "$status" -eq 0 ]
  assert_json "j['status'] == 'EVAL-PASSED'"
  run proposal_record not-opened
  [ "$status" -eq 0 ]
  run python3 - "$PROJECT" "$RECEIPT" <<'PY'
import json
import pathlib
import re
import sys

root, receipt_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
ledger = (root / "wiki" / "skill-impact.md").read_text()
link = re.search(r"\((skill-impact/one-skill/[^)]+\.json)\)", ledger).group(1)
sidecar = json.loads((root / "wiki" / link).read_text())
supplied = json.loads(receipt_path.read_text())
assert sidecar["schema_version"] == 2, sidecar
assert sidecar["evaluation"] == supplied["evaluation"], "record discarded version 2 evaluation keys"
assert list(sidecar) == [
    "schema_version", "skill", "proposal_sha", "eval_cmd", "score",
    "best_before", "baseline", "verdict", "run_at", "runner_model", "evaluation",
], list(sidecar)
PY
  [ "$status" -eq 0 ]

  local variant
  for variant in unversioned unknown-version extra-key; do
    PROJECT="$TEST_ROOT/version-$variant"
    cp -R "$PROJECT_FIXTURE" "$PROJECT"
    prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
    case "$variant" in
      unversioned) receipt_edit 'doc.pop("schema_version"); doc.pop("evaluation")' ;;
      unknown-version) receipt_edit 'doc["schema_version"] = 3' ;;
      extra-key) receipt_edit 'doc["extra_key"] = "no"' ;;
    esac
    run proposal_check
    if [ "$variant" = unversioned ]; then
      [ "$status" -eq 1 ]
      assert_json "j['status'] == 'NOT-READY'"
    else
      [ "$status" -eq 2 ]
      assert_json "j['status'] == 'MALFORMED'"
    fi
  done
}

@test "T8 cohort refuses every single mutated cohort dimension" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  local pristine="$TEST_ROOT/pristine-cohort.json"
  cp "$RECEIPT" "$pristine"
  local mutation
  for mutation in \
    'doc["evaluation"]["cohort"]["tasks"][0]["snapshot_sha256"] = "f" * 64' \
    'doc["evaluation"]["cohort"]["tasks"][0]["task_id"] = "substituted-task"' \
    'doc["evaluation"]["cohort"]["tasks"][0]["eval_id"] = 2' \
    'doc["evaluation"]["cohort"]["executor"]["route"] = "gemini::google/gemini-3.1-flash"' \
    'doc["evaluation"]["cohort"]["executor"]["harness"] = "codex"' \
    'doc["evaluation"]["cohort"]["executor"]["harness_version"] = "0.0.1"' \
    'doc["evaluation"]["cohort"]["executor"]["settings"]["temperature"] = "0.7"' \
    'doc["evaluation"]["cohort"]["executor"]["common_policy_sha256"] = "a" * 64' \
    'doc["evaluation"]["cohort"]["grader"]["route"] = "gemini::google/gemini-3.1-flash"' \
    'doc["evaluation"]["cohort"]["grader"]["config_sha256"] = "b" * 64' \
    'doc["evaluation"]["cohort"]["repetitions"] = 2' \
    'doc["evaluation"]["cohort"]["seed"] = "fabricated-seed-7"'; do
    cp "$pristine" "$RECEIPT"
    receipt_edit "$mutation"
    resync_cohort
    run proposal_check
    [ "$status" -ne 0 ] || { echo "cohort mutation was accepted: $mutation"; false; }
  done

  cp "$pristine" "$RECEIPT"
  receipt_edit 'doc["evaluation"]["cohort"]["seed"] = "fabricated-seed-7"'
  run proposal_check
  [ "$status" -eq 2 ]
  assert_json "'canonical digest' in j['error']"

  cp "$pristine" "$RECEIPT"
  run proposal_check
  [ "$status" -eq 0 ]
}

@test "T8 cohort binds executor grader and repetition identities beyond the cohort digest" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  local pristine="$TEST_ROOT/pristine-binding.json"
  cp "$RECEIPT" "$pristine"
  local case_name mutation
  for case_name in executor-route grader-route harness-version grader-config repetitions; do
    cp "$pristine" "$RECEIPT"
    case "$case_name" in
      executor-route) mutation='doc["evaluation"]["cohort"]["executor"]["route"] = "gemini::google/gemini-3.1-flash"' ;;
      grader-route) mutation='doc["evaluation"]["cohort"]["grader"]["route"] = "gemini::google/gemini-3.1-flash"' ;;
      harness-version) mutation='doc["evaluation"]["cohort"]["executor"]["harness_version"] = "0.0.1"' ;;
      grader-config) mutation='doc["evaluation"]["cohort"]["grader"]["config_sha256"] = "b" * 64' ;;
      repetitions) mutation='doc["evaluation"]["cohort"]["repetitions"] = 2' ;;
    esac
    receipt_edit "$mutation"
    resync_cohort --benchmark "$PROJECT"
    run proposal_check
    [ "$status" -ne 0 ] || { echo "binding mutation was accepted: $case_name"; false; }
  done
  cp "$pristine" "$RECEIPT"
  build_evaluation
  run proposal_check
  [ "$status" -eq 0 ]
}

@test "T8 cohort refuses incomplete duplicated or out-of-cohort run identities" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  local pristine="$TEST_ROOT/pristine-artifacts.json"
  cp "$RECEIPT" "$pristine"
  local mutation
  for mutation in \
    'doc["evaluation"]["artifacts"].pop()' \
    'doc["evaluation"]["artifacts"][1] = dict(doc["evaluation"]["artifacts"][0])' \
    'doc["evaluation"]["artifacts"].append(dict(doc["evaluation"]["artifacts"][0]))' \
    'doc["evaluation"]["artifacts"][1]["eval_id"] = 2' \
    'doc["evaluation"]["artifacts"][1]["run_number"] = 2' \
    'doc["evaluation"]["artifacts"][1]["configuration"] = "with_skill"'; do
    cp "$pristine" "$RECEIPT"
    receipt_edit "$mutation"
    run proposal_check
    [ "$status" -ne 0 ] || { echo "artifact mutation was accepted: $mutation"; false; }
  done
  cp "$pristine" "$RECEIPT"
  run proposal_check
  [ "$status" -eq 0 ]
}

@test "T8 cohort refuses changed task candidate native grader or provenance bytes" {
  local case_name run_dir
  for case_name in task-snapshot candidate-snapshot live-candidate native-output grader-output run-receipt provenance; do
    PROJECT="$TEST_ROOT/bytes-$case_name"
    cp -R "$PROJECT_FIXTURE" "$PROJECT"
    prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
    run_dir="$PROJECT/benchmarks/2026-08-29T115500Z"
    run proposal_check
    [ "$status" -eq 0 ]
    case "$case_name" in
      task-snapshot) printf '%s\n' 'substituted task' >> "$run_dir/tasks/1/task.md" ;;
      candidate-snapshot) printf '%s\n' 'substituted treatment' >> "$run_dir/candidate/SKILL.md" ;;
      live-candidate) printf '%s\n' 'post-run candidate edit' >> "$PROJECT/core-rules/skills/one-skill/SKILL.md" ;;
      native-output) printf '%s\n' 'rewritten transcript' >> "$run_dir/runs/1-with_skill-1.out" ;;
      grader-output) printf '%s\n' 'rewritten grading evidence' >> "$run_dir/runs/1-with_skill-1.grade.txt" ;;
      run-receipt) printf '%s\n' ' ' >> "$run_dir/runs/1-with_skill-1.json" ;;
      provenance) printf '%s\n' 'rewritten pattern snapshot' >> "$run_dir/provenance/valid.md" ;;
    esac
    run proposal_check
    [ "$status" -eq 1 ] || { echo "$case_name gave status $status: $output"; false; }
    assert_json "j['status'] == 'NOT-READY'"
  done
}

@test "T8 cohort refuses a per-run score mismatch behind an agreeing aggregate" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  python3 "$EVIDENCE_TOOL" two-rep "$BENCHMARK"
  build_evaluation
  run proposal_check
  [ "$status" -eq 0 ]
  assert_json "j['score'] == '0.90'"

  python3 - "$PROJECT" "$RECEIPT" <<'PY'
import json
import pathlib
import sys

project, receipt_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
receipt = json.loads(receipt_path.read_text())
paths = [
    project / artifact["path"]
    for artifact in receipt["evaluation"]["artifacts"]
    if artifact["configuration"] == "with_skill"
]
assert len(paths) == 2, paths
first, second = (json.loads(path.read_text()) for path in paths)
assert first["grade"]["pass_rate"] != second["grade"]["pass_rate"]
first["grade"]["pass_rate"], second["grade"]["pass_rate"] = (
    second["grade"]["pass_rate"],
    first["grade"]["pass_rate"],
)
for path, document in zip(paths, (first, second)):
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
  rehash_artifacts
  run proposal_check
  [ "$status" -eq 1 ]
  assert_json "'pass_rate' in j['error']"
}

@test "T8 cohort refuses unavailable failed or mislabelled native runs" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  local case_name
  for case_name in unavailable failed nonzero-exit missing-treatment leaked-treatment foreign-executor; do
    build_evaluation
    case "$case_name" in
      unavailable) run_receipt_edit with_skill 'doc["status"] = "unavailable"' ;;
      failed) run_receipt_edit with_skill 'doc["status"] = "failed"' ;;
      nonzero-exit) run_receipt_edit with_skill 'doc["exit_code"] = 1' ;;
      missing-treatment) run_receipt_edit with_skill 'doc["treatment_sha256"] = None' ;;
      leaked-treatment) run_receipt_edit without_skill 'doc["treatment_sha256"] = "a" * 64' ;;
      foreign-executor) run_receipt_edit with_skill 'doc["observed_executor"]["harness"] = "codex"' ;;
    esac
    run proposal_check
    [ "$status" -eq 1 ] || { echo "$case_name gave status $status: $output"; false; }
    assert_json "j['status'] == 'NOT-READY'"
  done
  build_evaluation
  run proposal_check
  [ "$status" -eq 0 ]
}

@test "T8 cohort refuses unsafe evidence paths and symlinked run evidence" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  local pristine="$TEST_ROOT/pristine-paths.json"
  cp "$RECEIPT" "$pristine"
  local mutation
  for mutation in \
    'doc["evaluation"]["candidate_snapshot"] = "/etc"' \
    'doc["evaluation"]["candidate_snapshot"] = "../outside"' \
    'doc["evaluation"]["candidate_snapshot"] = "wiki"' \
    'doc["evaluation"]["artifacts"][0]["path"] = "wiki/index.md"' \
    'doc["evaluation"]["run_dir"] = "../outside"'; do
    cp "$pristine" "$RECEIPT"
    receipt_edit "$mutation"
    run proposal_check
    [ "$status" -eq 2 ] || { echo "path mutation gave status $status: $mutation"; false; }
  done

  cp "$pristine" "$RECEIPT"
  local run_dir="$PROJECT/benchmarks/2026-08-29T115500Z"
  local outside="$TEST_ROOT/outside-evidence"
  local outside_before
  mkdir -p "$outside"
  printf '%s\n' 'outside sentinel' > "$outside/sentinel"
  outside_before="$(tree_digest "$outside")"
  local link_case
  for link_case in snapshot output; do
    rm -rf "$run_dir/candidate"
    build_evaluation
    case "$link_case" in
      snapshot)
        rm -rf "$run_dir/candidate"
        ln -s "$outside" "$run_dir/candidate"
        ;;
      output)
        rm -f "$run_dir/runs/1-with_skill-1.out"
        ln -s "$outside/sentinel" "$run_dir/runs/1-with_skill-1.out"
        ;;
    esac
    run proposal_check
    [ "$status" -eq 2 ] || { echo "$link_case symlink gave status $status: $output"; false; }
    [ "$(tree_digest "$outside")" = "$outside_before" ]
  done
}

@test "T8 evidence paths permit unique per-run paths with identical raw and grading bytes" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  python3 - "$PROJECT" "$RECEIPT" <<'PY'
import hashlib
import json
import pathlib
import sys

project, receipt_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
receipt = json.loads(receipt_path.read_text())
paths = set()
for artifact in receipt["evaluation"]["artifacts"]:
    path = project / artifact["path"]
    run = json.loads(path.read_text())
    for ref in (run["output"], run["grade"]["output"]):
        assert ref["path"] not in paths
        paths.add(ref["path"])
        (project / ref["path"]).write_bytes(b"identical evidence bytes\n")
        ref["sha256"] = hashlib.sha256(b"identical evidence bytes\n").hexdigest()
    path.write_text(json.dumps(run, indent=2) + "\n")
assert len(paths) == 2 * len(receipt["evaluation"]["artifacts"])
PY
  rehash_artifacts
  run proposal_check
  [ "$status" -eq 0 ]
  assert_json "j['status'] == 'EVAL-PASSED'"
}

@test "T8 evidence paths reject raw and grader reuse across roles and runs" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  local variant
  for variant in raw-grade cross-run-raw cross-run-grade benchmark provenance artifact candidate task run-dir; do
    build_evaluation
    python3 - "$PROJECT" "$RECEIPT" "$variant" <<'PY'
import hashlib
import json
import pathlib
import sys

project, receipt_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
variant = sys.argv[3]
receipt = json.loads(receipt_path.read_text())
evaluation = receipt["evaluation"]
artifacts = evaluation["artifacts"]
first_path, second_path = (project / artifact["path"] for artifact in artifacts[:2])
first, second = (json.loads(path.read_text()) for path in (first_path, second_path))
if variant == "raw-grade":
    first["grade"]["output"] = dict(first["output"])
elif variant == "cross-run-raw":
    second["output"] = dict(first["output"])
elif variant == "cross-run-grade":
    second["grade"]["output"] = dict(first["grade"]["output"])
else:
    target = {
        "benchmark": evaluation["benchmark"]["path"],
        "provenance": evaluation["provenance"][0]["path"],
        "artifact": artifacts[1]["path"],
        "candidate": evaluation["candidate_snapshot"],
        "task": evaluation["task_snapshots"][0]["path"],
        "run-dir": evaluation["run_dir"],
    }[variant]
    first["output"] = {
        "path": target,
        "sha256": hashlib.sha256((project / target).read_bytes()).hexdigest()
        if (project / target).is_file() else "0" * 64,
    }
# Keep the referenced second artifact's bytes stable for the artifact-role case.
first_path.write_text(json.dumps(first, indent=2) + "\n")
if variant.startswith("cross-run-"):
    second_path.write_text(json.dumps(second, indent=2) + "\n")
PY
    rehash_artifacts
    run proposal_check
    [ "$status" -eq 2 ] || { echo "$variant gave status $status: $output"; false; }
    assert_json "j['status'] == 'MALFORMED' and 'duplicate' in j['error']"
  done
}

@test "T8 evidence paths reject snapshots equal to run_dir before digest validation" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  local variant
  for variant in candidate task; do
    build_evaluation
    case "$variant" in
      candidate) receipt_edit 'doc["evaluation"]["candidate_snapshot"] = doc["evaluation"]["run_dir"]' ;;
      task) receipt_edit 'doc["evaluation"]["task_snapshots"][0]["path"] = doc["evaluation"]["run_dir"]' ;;
    esac
    run proposal_check
    [ "$status" -eq 2 ] || { echo "$variant gave status $status: $output"; false; }
    assert_json "j['status'] == 'MALFORMED' and 'duplicate' in j['error']"
  done
}

@test "T8 comparator covers every accepted version and refuses uncovered or legacy history" {
  local same="4$(printf '%039d' 0)"
  local other="5$(printf '%039d' 0)"
  local legacy="6$(printf '%039d' 0)"

  PROJECT="$TEST_ROOT/cover-same"
  cp -R "$PROJECT_FIXTURE" "$PROJECT"
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  append_history_receipt "$PROJECT" "$same" 0.80 0.60 accepted
  set_receipt_fields "$RECEIPT" "$TEST_ROOT/cover-same.json" best_before 0.80
  RECEIPT="$TEST_ROOT/cover-same.json"
  run proposal_check
  [ "$status" -eq 0 ]
  assert_json "j['best_before'] == '0.80'"

  PROJECT="$TEST_ROOT/cover-mixed"
  cp -R "$PROJECT_FIXTURE" "$PROJECT"
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  append_history_receipt "$PROJECT" "$same" 0.80 0.60 accepted
  append_history_receipt "$PROJECT" "$other" 0.95 0.60 accepted seeded-run-42
  set_receipt_fields "$RECEIPT" "$TEST_ROOT/cover-mixed.json" best_before 0.80
  RECEIPT="$TEST_ROOT/cover-mixed.json"
  run proposal_check
  [ "$status" -eq 1 ]
  assert_json "'different cohort' in j['error'] and '$other' in j['error']"

  add_incumbent "$other" 0.85
  set_receipt_fields "$RECEIPT" "$TEST_ROOT/cover-mixed-covered.json" best_before 0.85
  RECEIPT="$TEST_ROOT/cover-mixed-covered.json"
  run proposal_check
  [ "$status" -eq 0 ]
  assert_json "j['best_before'] == '0.85'"

  set_receipt_fields "$RECEIPT" "$TEST_ROOT/cover-mixed-old.json" best_before 0.95
  RECEIPT="$TEST_ROOT/cover-mixed-old.json"
  run proposal_check
  [ "$status" -eq 1 ]
  assert_json "j['status'] == 'NOT-READY'"

  RECEIPT="$TEST_ROOT/cover-mixed-covered.json"
  receipt_edit 'doc["evaluation"]["incumbents"][0]["proposal_sha"] = "d" * 40'
  run proposal_check
  [ "$status" -eq 1 ]
  assert_json "'does not refer to an accepted proposal' in j['error']"

  PROJECT="$TEST_ROOT/cover-legacy"
  cp -R "$PROJECT_FIXTURE" "$PROJECT"
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  append_legacy_history_receipt "$PROJECT" "$legacy" 0.70 0.60 accepted
  set_receipt_fields "$RECEIPT" "$TEST_ROOT/cover-legacy.json" best_before 0.70
  RECEIPT="$TEST_ROOT/cover-legacy.json"
  run proposal_check
  [ "$status" -eq 1 ]
  assert_json "'legacy version 1' in j['error'] and '$legacy' in j['error']"
}

@test "T8 comparator binds accepted sidecar bytes and reuses shared candidate evidence" {
  local first="7$(printf '%039d' 0)"
  local second="8$(printf '%039d' 0)"

  PROJECT="$TEST_ROOT/incumbent-binding"
  cp -R "$PROJECT_FIXTURE" "$PROJECT"
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  append_history_receipt "$PROJECT" "$first" 0.80 0.60 accepted seeded-run-42
  add_incumbent "$first" 0.85
  set_receipt_fields "$RECEIPT" "$TEST_ROOT/incumbent-bound.json" best_before 0.85
  RECEIPT="$TEST_ROOT/incumbent-bound.json"
  run proposal_check
  [ "$status" -eq 0 ]

  local bound="$TEST_ROOT/incumbent-bound.json"
  cp "$bound" "$TEST_ROOT/incumbent-broken.json"
  RECEIPT="$TEST_ROOT/incumbent-broken.json"
  receipt_edit 'doc["evaluation"]["incumbents"][0]["accepted_receipt_sha256"] = "c" * 64'
  run proposal_check
  [ "$status" -eq 1 ]
  assert_json "'accepted sidecar bytes' in j['error']"

  RECEIPT="$bound"
  append_history_receipt "$PROJECT" "$second" 0.80 0.60 accepted seeded-run-42
  add_incumbent "$second" 0.85
  cp "$RECEIPT" "$TEST_ROOT/incumbent-swapped.json"
  RECEIPT="$TEST_ROOT/incumbent-swapped.json"
  receipt_edit 'doc["evaluation"]["incumbents"][0]["proposal_sha"], doc["evaluation"]["incumbents"][1]["proposal_sha"] = doc["evaluation"]["incumbents"][1]["proposal_sha"], doc["evaluation"]["incumbents"][0]["proposal_sha"]'
  run proposal_check
  [ "$status" -eq 1 ]
  assert_json "j['status'] == 'NOT-READY'"

  PROJECT="$TEST_ROOT/incumbent-shared"
  cp -R "$PROJECT_FIXTURE" "$PROJECT"
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  append_history_receipt "$PROJECT" "$first" 0.80 0.60 accepted seeded-run-42 shared-bytes
  append_history_receipt "$PROJECT" "$second" 0.75 0.60 accepted seeded-run-42 shared-bytes
  add_incumbent "$first" 0.85 shared-reeval
  add_incumbent "$second" 0.85 shared-reeval
  set_receipt_fields "$RECEIPT" "$TEST_ROOT/incumbent-shared.json" best_before 0.85
  RECEIPT="$TEST_ROOT/incumbent-shared.json"
  run proposal_check
  [ "$status" -eq 0 ]
  assert_json "j['best_before'] == '0.85'"
  run python3 - "$RECEIPT" <<'PY'
import json
import pathlib
import sys

receipt = json.loads(pathlib.Path(sys.argv[1]).read_text())
incumbents = receipt["evaluation"]["incumbents"]
assert len(incumbents) == 2, incumbents
assert incumbents[0]["proposal_sha"] != incumbents[1]["proposal_sha"]
assert incumbents[0]["accepted_receipt_sha256"] != incumbents[1]["accepted_receipt_sha256"]
assert incumbents[0]["evaluation"]["run_dir"] == incumbents[1]["evaluation"]["run_dir"]
assert incumbents[0]["evaluation"] == incumbents[1]["evaluation"]
assert "incumbents" not in incumbents[0]["evaluation"]
PY
  [ "$status" -eq 0 ]
}

@test "T8 finalization preserves the whole evaluation and refuses legacy acceptance" {
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  run proposal_record not-opened
  [ "$status" -eq 0 ]
  local sidecar="$PROJECT/wiki/skill-impact/one-skill/2026-08-29-222222222222.json"
  local accepted="$TEST_ROOT/finalize-accepted.json"
  set_receipt_fields "$RECEIPT" "$accepted" verdict accepted
  local before_evaluation
  before_evaluation="$(python3 -c 'import hashlib,json,sys;print(hashlib.sha256(json.dumps(json.load(open(sys.argv[1]))["evaluation"],sort_keys=True).encode()).hexdigest())' "$sidecar")"
  RECEIPT="$accepted"
  run proposal_record https://github.com/example/project/pull/456
  [ "$status" -eq 0 ]
  [ "$(python3 -c 'import hashlib,json,sys;print(hashlib.sha256(json.dumps(json.load(open(sys.argv[1]))["evaluation"],sort_keys=True).encode()).hexdigest())' "$sidecar")" = "$before_evaluation" ]
  run python3 - "$sidecar" <<'PY'
import json
import pathlib
import sys

receipt = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert receipt["verdict"] == "accepted"
assert receipt["schema_version"] == 2
assert receipt["evaluation"]["cohort"]["seed"] == "unseeded"
assert receipt["evaluation"]["artifacts"], receipt
PY
  [ "$status" -eq 0 ]

  local legacy="9$(printf '%039d' 0)"
  PROJECT="$TEST_ROOT/legacy-finalization"
  cp -R "$PROJECT_FIXTURE" "$PROJECT"
  prepare_proposal "$PROJECT" "$EVAL_FIXTURES/receipt-pass.json" empty
  append_legacy_history_receipt "$PROJECT" "$legacy" 0.90 0.60 eval-passed
  RECEIPT="$TEST_ROOT/legacy-accepted.json"
  python3 "$EVIDENCE_TOOL" legacy-receipt "$RECEIPT" "$legacy" 0.90 0.60 accepted
  write_proposal_diff
  run proposal_record https://github.com/example/project/pull/456
  [ "$status" -eq 1 ]
  assert_json "'legacy version 1' in j['error']"

  RECEIPT="$TEST_ROOT/legacy-rejected.json"
  python3 "$EVIDENCE_TOOL" legacy-receipt "$RECEIPT" "$legacy" 0.90 0.60 rejected
  write_proposal_diff
  run proposal_record https://github.com/example/project/pull/456
  [ "$status" -eq 0 ]
  assert_json "j['verdict'] == 'rejected'"
  run python3 - "$PROJECT" "$legacy" <<'PY'
import json
import pathlib
import sys

root, sha = pathlib.Path(sys.argv[1]), sys.argv[2]
sidecar = json.loads((root / "wiki" / "skill-impact" / "one-skill" / ("2026-08-28-" + sha[:12] + ".json")).read_text())
assert "schema_version" not in sidecar, "legacy rejection must stay version 1"
assert sidecar["verdict"] == "rejected"
PY
  [ "$status" -eq 0 ]
}
