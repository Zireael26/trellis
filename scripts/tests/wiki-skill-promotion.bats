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


append_history_receipt() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
sha, score, best_before, verdict = sys.argv[2:]
date = "2026-08-28"
relative = pathlib.Path("skill-impact") / "one-skill" / (date + "-" + sha[:12] + ".json")
sidecar = root / "wiki" / relative
sidecar.parent.mkdir(parents=True, exist_ok=True)
receipt = {
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
sidecar.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
pr = "https://github.com/example/project/pull/" + str(int(sha[0], 16) + 100) if verdict in {"accepted", "rejected"} else "not-opened"
row = "| {date} | one-skill | diff={base}..{head}; patterns=valid; new-evidence=none | {score} | {best} | {verdict} | {pr} | [run receipt]({relative}) |\n".format(
    date=date,
    base="0" * 40,
    head=sha,
    score=score,
    best=best_before,
    verdict=verdict,
    pr=pr,
    relative=relative.as_posix(),
)
ledger = root / "wiki" / "skill-impact.md"
with ledger.open("a") as handle:
    handle.write(row)
PY
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

@test "impact record creates one exact eight-column row and linked nine-field receipt" {
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
assert set(receipt) == {"skill", "proposal_sha", "eval_cmd", "score", "best_before", "baseline", "verdict", "run_at", "runner_model"}
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
  run proposal_check
  [ "$status" -eq 1 ]

  cp "$EVAL_FIXTURES/receipt-pass.json" "$RECEIPT"
  set_runner_models "$RECEIPT" "gpt::openai/gpt-5.6" "gemini::google/gemini-3.1-pro" "gpt::openai/gpt-5.6"
  write_proposal_diff
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
