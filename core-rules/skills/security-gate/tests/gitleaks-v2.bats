#!/usr/bin/env bats
# Regression coverage for the v2 current-tree/history Gitleaks boundary.

setup() {
  TEST_ROOT="$(mktemp -d)"
  PROJECT="$TEST_ROOT/project"
  BIN="$TEST_ROOT/bin"
  mkdir -p "$PROJECT/src" "$PROJECT/tests/fixtures" "$BIN"
  printf '%s\n' 'const current = "secret";' > "$PROJECT/src/current.ts"
  printf '%s\n' 'const oldFixture = "fixture";' > "$PROJECT/tests/fixtures/client.ts"
  printf '%s\n' 'ignored.env' > "$PROJECT/.gitignore"
  printf '%s\n' 'IGNORED_SECRET=secret' > "$PROJECT/ignored.env"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" add .gitignore src/current.ts tests/fixtures/client.ts

  cat > "$BIN/gitleaks" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "version" ]; then
  echo "8.30.1"
  exit 0
fi

report=""
source_dir=""
no_git=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-path) report="$2"; shift 2 ;;
    --source) source_dir="$2"; shift 2 ;;
    --no-git) no_git=1; shift ;;
    *) shift ;;
  esac
done

if [ "$no_git" -eq 1 ]; then
  if [ -n "${GITLEAKS_CURRENT_TREE_LOG:-}" ]; then
    (cd "$source_dir" && find . -type f | sort) > "$GITLEAKS_CURRENT_TREE_LOG"
  fi
  python3 - "$source_dir" "$report" <<'PY'
import json
import os
import sys

source, report = sys.argv[1:]
findings = [{
    "RuleID": "generic-api-key",
    "Description": "current secret",
    "File": os.path.join(source, "src/current.ts"),
    "StartLine": 12,
    "Commit": "",
    "Fingerprint": os.path.join(source, "src/current.ts:generic-api-key:12"),
}]
ignored = os.path.join(source, "ignored.env")
if os.path.exists(ignored):
    findings.append({
        "RuleID": "generic-api-key",
        "Description": "ignored secret",
        "File": ignored,
        "StartLine": 1,
        "Commit": "",
        "Fingerprint": f"{ignored}:generic-api-key:1",
    })
with open(report, "w") as fh:
    json.dump(findings, fh)
PY
else
  cat > "$report" <<'JSON'
[
  {"RuleID":"generic-api-key","Description":"current secret","File":"src/current.ts","StartLine":1,"Commit":"def456","Fingerprint":"def456:src/current.ts:generic-api-key:1"},
  {"RuleID":"generic-api-key","Description":"historical fixture","File":"tests/fixtures/client.ts","StartLine":7,"Commit":"abc123","Fingerprint":"abc123:tests/fixtures/client.ts:generic-api-key:7"}
]
JSON
fi

# Gitleaks uses 1 to mean findings were produced.
exit 1
SH
  chmod +x "$BIN/gitleaks"

  cat > "$BIN/semgrep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "1.157.0"; else echo '{"results":[]}'; fi
SH
  chmod +x "$BIN/semgrep"

  cat > "$BIN/osv-scanner" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "osv-scanner version 2.3.8"; else echo '{"results":[]}'; fi
SH
  chmod +x "$BIN/osv-scanner"

  cat > "$BIN/llm" <<'SH'
#!/usr/bin/env bash
python3 -c '
import json, os, sys
rows = [json.loads(line) for line in sys.stdin if line.strip()]
log = os.environ.get("LLM_INPUT_LOG")
if log:
    with open(log, "w") as fh:
        json.dump(rows, fh)
for row in rows:
    print(json.dumps({
        "id": row["id"],
        "decision": "kept",
        "reason": "test decision",
        "exploit_steps": "test exploit",
        "suggested_fix": "test fix",
        "severity_override": "low",
    }))
'
SH
  chmod +x "$BIN/llm"

  SCRIPT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "gitleaks JSONL separates current and history while accepting exit 1 from both scans" {
  out="$TEST_ROOT/gitleaks.jsonl"

  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/lib/gitleaks.sh" "$PROJECT" "$out"
  [ "$status" -eq 0 ]

  run python3 -c '
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
current = [r for r in rows if r["bucket"] == "findings"]
history = [r for r in rows if r["bucket"] == "historical_findings"]
assert len(current) == 1, current
assert len(history) == 1, history
assert current[0]["file"] == "src/current.ts"
assert current[0]["line"] == 12
assert current[0]["fingerprint"] == "src/current.ts:generic-api-key:12"
assert history[0]["file"] == "tests/fixtures/client.ts"
assert history[0]["fingerprint"] == "abc123:tests/fixtures/client.ts:generic-api-key:7"
' "$out"
  [ "$status" -eq 0 ]
}

@test "gitignored files are absent from the materialized current tree and gating findings" {
  out="$TEST_ROOT/gitleaks.jsonl"
  current_tree_log="$TEST_ROOT/current-tree-files"

  run env PATH="$BIN:$PATH" GITLEAKS_CURRENT_TREE_LOG="$current_tree_log" \
    bash "$SCRIPT_ROOT/scripts/lib/gitleaks.sh" "$PROJECT" "$out"
  [ "$status" -eq 0 ]

  run grep -Fx './ignored.env' "$current_tree_log"
  [ "$status" -eq 1 ]

  run python3 -c '
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
assert not any(r["bucket"] == "findings" and r["file"] == "ignored.env" for r in rows), rows
' "$out"
  [ "$status" -eq 0 ]
}

@test "line drift keeps a current secret out of the historical bucket" {
  out="$TEST_ROOT/gitleaks.jsonl"

  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/lib/gitleaks.sh" "$PROJECT" "$out"
  [ "$status" -eq 0 ]

  run python3 -c '
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
matches = [r for r in rows if r["rule"] == "generic-api-key" and r["file"] == "src/current.ts"]
assert len(matches) == 1, matches
assert matches[0]["bucket"] == "findings", matches
assert matches[0]["line"] == 12, matches
' "$out"
  [ "$status" -eq 0 ]
}

@test "baseline v2 persists a triaged historical disposition by fingerprint" {
  audit_dir="$PROJECT/audits"
  mkdir -p "$audit_dir"
  baseline="$audit_dir/$(date +%Y-%m-%d)-baseline-project.json"
  cat > "$baseline" <<'JSON'
{
  "schema": "security-gate.baseline.v2",
  "findings": [],
  "historical_findings": [
    {
      "fingerprint": "abc123:tests/fixtures/client.ts:generic-api-key:7",
      "triage": "dropped",
      "triage_reason": "synthetic fixture"
    }
  ]
}
JSON

  llm_log="$TEST_ROOT/llm-input.json"
  run env PATH="$BIN:$PATH" LLM_PROVIDER=openai LLM_INPUT_LOG="$llm_log" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT"
  [ "$status" -eq 0 ]

  run python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["schema"] == "security-gate.baseline.v2"
assert len(doc["findings"]) == 1
assert doc["findings"][0]["triage"] == "kept"
assert len(doc["historical_findings"]) == 1
historical = doc["historical_findings"][0]
assert historical["fingerprint"] == "abc123:tests/fixtures/client.ts:generic-api-key:7"
assert historical["triage"] == "dropped"
assert historical["triage_reason"] == "synthetic fixture"
assert historical["severity"] == "high"
assert doc["summary"]["historical"]["dropped"] == 1
' "$baseline"
  [ "$status" -eq 0 ]

  run python3 -c '
import json, sys
rows = json.load(open(sys.argv[1]))
assert len(rows) == 1, rows
assert rows[0]["bucket"] == "findings"
' "$llm_log"
  [ "$status" -eq 0 ]
}

@test "historical severity cannot be downgraded by triage" {
  llm_log="$TEST_ROOT/llm-input.json"
  run env PATH="$BIN:$PATH" LLM_PROVIDER=openai LLM_INPUT_LOG="$llm_log" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT"
  [ "$status" -eq 0 ]

  baseline="$PROJECT/audits/$(date +%Y-%m-%d)-baseline-project.json"
  run python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["findings"][0]["severity"] == "low"
historical = doc["historical_findings"][0]
assert historical["triage"] == "kept"
assert historical["severity"] == "high"
assert doc["summary"]["historical"]["by_severity"]["high"] == 1
' "$baseline"
  [ "$status" -eq 0 ]
}
