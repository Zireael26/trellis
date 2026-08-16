#!/usr/bin/env bats
# Regression coverage for per-vulnerability OSV severity normalization.

setup() {
  TEST_ROOT="$(mktemp -d)"
  PROJECT="$TEST_ROOT/project"
  BIN="$TEST_ROOT/bin"
  OSV_FIXTURE_FILE="$TEST_ROOT/osv.json"
  mkdir -p "$PROJECT" "$BIN"
  printf '%s\n' '{"lockfileVersion":3,"packages":{}}' > "$PROJECT/package-lock.json"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" add package-lock.json

  cat > "$OSV_FIXTURE_FILE" <<'JSON'
{
  "results": [{
    "source": {"path": "PROJECT_PATH/package-lock.json", "type": "lockfile"},
    "packages": [{
      "package": {"name": "fixture", "version": "1.0.0", "ecosystem": "npm"},
      "vulnerabilities": [
        {"id": "DB-CRITICAL", "summary": "database critical", "database_specific": {"severity": "CRITICAL"}},
        {"id": "DB-HIGH", "summary": "database high", "database_specific": {"severity": "HIGH"}},
        {"id": "DB-MODERATE", "summary": "database moderate", "database_specific": {"severity": "MODERATE"}},
        {"id": "DB-LOW", "summary": "database low", "database_specific": {"severity": "LOW"}},
        {"id": "CVSS3-HIGH", "summary": "CVSS 3 high", "severity": [{"type": "CVSS_V3", "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:N/A:N"}]},
        {"id": "CVSS4-HIGH", "summary": "CVSS 4 high", "severity": [{"type": "CVSS_V4", "score": "CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:N/VI:N/VA:H/SC:N/SI:N/SA:N"}]},
        {"id": "ISOLATED-LOW", "summary": "isolated low", "severity": [{"type": "CVSS_V3", "score": "CVSS:3.1/AV:L/AC:H/PR:H/UI:R/S:U/C:L/I:N/A:N"}]},
        {"id": "CONFLICT", "summary": "group score wins", "database_specific": {"severity": "LOW"}, "severity": [{"type": "CVSS_V3", "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"}]},
        {"id": "UNKNOWN", "summary": "unknown severity", "severity": [{"type": "OTHER", "score": "not-a-score"}]},
        {"id": "MALFORMED-GROUP", "summary": "malformed group falls back", "database_specific": {"severity": "HIGH"}},
        {"id": "NAN-GROUP", "summary": "non-finite group falls back", "database_specific": {"severity": "LOW"}},
        {"id": "OUT-OF-RANGE", "summary": "out-of-range group uses conservative default"},
        {"id": "BOUNDARY-CRITICAL", "summary": "critical boundary"},
        {"id": "BOUNDARY-HIGH", "summary": "high boundary"},
        {"id": "BOUNDARY-MEDIUM", "summary": "medium boundary"},
        {"id": "BOUNDARY-LOW", "summary": "low boundary"}
      ],
      "groups": [
        {"ids": ["CVSS3-HIGH"], "max_severity": "7.5"},
        {"ids": ["CVSS4-HIGH"], "max_severity": "8.7"},
        {"ids": ["ISOLATED-LOW"], "max_severity": "2.9"},
        {"ids": ["CONFLICT"], "max_severity": "9.8"},
        {"ids": ["MALFORMED-GROUP"], "max_severity": "not-a-score"},
        {"ids": ["NAN-GROUP"], "max_severity": "NaN"},
        {"ids": ["OUT-OF-RANGE"], "max_severity": "10.1"},
        {"ids": ["BOUNDARY-CRITICAL"], "max_severity": "9.0"},
        {"ids": ["BOUNDARY-HIGH"], "max_severity": "7.0"},
        {"ids": ["BOUNDARY-MEDIUM"], "max_severity": "4.0"},
        {"ids": ["BOUNDARY-LOW"], "max_severity": "3.999"},
        {"ids": ["NOT-PRESENT"], "max_severity": "10.0"}
      ]
    }]
  }]
}
JSON
  python3 - "$OSV_FIXTURE_FILE" "$PROJECT" <<'PY'
import sys
path, project = sys.argv[1:]
with open(path) as fh:
    data = fh.read().replace("PROJECT_PATH", project)
with open(path, "w") as fh:
    fh.write(data)
PY
  export OSV_FIXTURE_FILE

  cat > "$BIN/osv-scanner" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "osv-scanner version 2.4.0"
  exit 0
fi
cat "$OSV_FIXTURE_FILE"
# OSV-Scanner uses 1 to mean vulnerabilities were found.
exit 1
SH
  chmod +x "$BIN/osv-scanner"

  cat > "$BIN/semgrep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "1.157.0"
else
  echo '{"results":[]}'
fi
SH
  chmod +x "$BIN/semgrep"

  cat > "$BIN/gitleaks" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "version" ]; then
  echo "8.30.1"
  exit 0
fi
report=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-path) report="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '[]\n' > "$report"
SH
  chmod +x "$BIN/gitleaks"

  SCRIPT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "database-specific severities map to the normalized four-level scale" {
  out="$TEST_ROOT/osv.jsonl"

  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/lib/osv.sh" "$PROJECT" "$out"
  [ "$status" -eq 0 ]

  run python3 - "$out" <<'PY'
import json, sys
rows = {row["rule"]: row for row in map(json.loads, open(sys.argv[1]))}
assert rows["DB-CRITICAL"]["severity"] == "critical", rows
assert rows["DB-HIGH"]["severity"] == "high", rows
assert rows["DB-MODERATE"]["severity"] == "medium", rows
assert rows["DB-LOW"]["severity"] == "low", rows
assert all(row["file"] == "package-lock.json" for row in rows.values()), rows
PY
  [ "$status" -eq 0 ]
}

@test "matched package groups classify CVSS 3 and 4 without cross-vulnerability leakage" {
  out="$TEST_ROOT/osv.jsonl"

  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/lib/osv.sh" "$PROJECT" "$out"
  [ "$status" -eq 0 ]

  run python3 - "$out" <<'PY'
import json, sys
rows = {row["rule"]: row for row in map(json.loads, open(sys.argv[1]))}
assert rows["CVSS3-HIGH"]["severity"] == "high", rows
assert rows["CVSS4-HIGH"]["severity"] == "high", rows
assert rows["ISOLATED-LOW"]["severity"] == "low", rows
assert rows["CONFLICT"]["severity"] == "critical", rows
assert rows["UNKNOWN"]["severity"] == "medium", rows
assert rows["MALFORMED-GROUP"]["severity"] == "high", rows
assert rows["NAN-GROUP"]["severity"] == "low", rows
assert rows["OUT-OF-RANGE"]["severity"] == "medium", rows
assert rows["BOUNDARY-CRITICAL"]["severity"] == "critical", rows
assert rows["BOUNDARY-HIGH"]["severity"] == "high", rows
assert rows["BOUNDARY-MEDIUM"]["severity"] == "medium", rows
assert rows["BOUNDARY-LOW"]["severity"] == "low", rows
PY
  [ "$status" -eq 0 ]
}

@test "baseline summary preserves normalized OSV severity totals" {
  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 0 ]

  baseline="$PROJECT/audits/$(date +%Y-%m-%d)-baseline-project.json"
  run python3 - "$baseline" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["summary"]["total_raw"] == 16, doc["summary"]
assert doc["summary"]["no_llm_pass"] == 16, doc["summary"]
assert doc["summary"]["by_severity"] == {
    "critical": 3,
    "high": 5,
    "medium": 4,
    "low": 4,
}, doc["summary"]
assert {finding["tool"] for finding in doc["findings"]} == {"osv"}, doc["findings"]
PY
  [ "$status" -eq 0 ]
}
