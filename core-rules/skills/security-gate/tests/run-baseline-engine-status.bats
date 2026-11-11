#!/usr/bin/env bats
# A baseline is clean only when every engine completed. An engine that failed,
# was skipped, or left output that does not parse makes the baseline
# incomplete: in the JSON, in the narrative and in the exit status.

setup() {
  TEST_ROOT="$(mktemp -d)"
  PROJECT="$TEST_ROOT/project"
  BIN="$TEST_ROOT/bin"
  mkdir -p "$PROJECT" "$BIN"
  unset CODEX_PROJECT_DIR CLAUDE_PROJECT_DIR SECURITY_GATE_PROJECT_NAME
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  printf '%s\n' '{"lockfileVersion":3,"packages":{}}' > "$PROJECT/package-lock.json"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" add package-lock.json

  # Each stub answers its version probe, and exits 42 on a scan when its name
  # is listed in STUB_FAIL: the synthetic fault from the 2026-11-02 audit.
  cat > "$BIN/semgrep" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { echo "1.157.0"; exit 0; }
case " ${STUB_FAIL:-} " in *" semgrep "*) exit 42 ;; esac
[ -n "${SEMGREP_STDOUT:-}" ] && { printf '%s\n' "$SEMGREP_STDOUT"; exit 0; }
echo '{"results":[]}'
SH
  cat > "$BIN/osv-scanner" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { printf '%s\n' "${OSV_VERSION_LINE-osv-scanner version: 2.6.0}" "osv-scalibr version: 0.5.2"; exit 0; }
[ -z "${OSV_RAN:-}" ] || : > "$OSV_RAN"
case " ${STUB_FAIL:-} " in *" osv-scanner "*) exit 42 ;; esac
root="$(cd "${!#}" && pwd)" || exit 2
# Real osv-scanner 2.6.0 progress lines; OSV_EXTRA_STDERR adds others.
printf 'Scanning dir %s\nStarting filesystem walk for root: /\n' "$root" >&2
# OSV_NO_SOURCES: osv-scanner 2.6.0 on a tree with nothing it can read.
if [ -n "${OSV_NO_SOURCES:-}" ]; then
  printf 'End status: 3 dirs visited, 9 inodes visited, %s Extract calls, 1ms elapsed, 1ms wall time\n' "${OSV_EXTRACT_CALLS:-0}" >&2
  for lock in ${OSV_RECEIPTS-}; do
    printf 'Scanned %s/%s file and found 0 packages\n' "$root" "$lock" >&2
  done
  [ -z "${OSV_EXTRA_STDERR:-}" ] || printf '%s\n' "$OSV_EXTRA_STDERR" >&2
  [ -z "${OSV_STDOUT:-}" ] || printf '%s\n' "$OSV_STDOUT"
  echo "${OSV_NO_SOURCES_MESSAGE-No package sources found, --help for usage information.}" >&2
  exit 128
fi
[ -z "${OSV_EXTRA_STDERR:-}" ] || printf '%s\n' "$OSV_EXTRA_STDERR" >&2
[ -z "${OSV_EXIT:-}" ] || exit "$OSV_EXIT"
echo '{"results":[]}'
# OSV_RECEIPTS: the lockfiles this run reports as scanned (default: the root one).
for lock in ${OSV_RECEIPTS-package-lock.json}; do
  printf 'Scanned %s/%s file and found 0 packages\n' "$root" "$lock" >&2
done
SH
  cat > "$BIN/gitleaks" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "version" ] && { echo "8.30.1"; exit 0; }
case " ${STUB_FAIL:-} " in *" gitleaks "*) exit 42 ;; esac
report=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-path) report="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '[]\n' > "$report"
SH
  # Garak writes its report under --report_prefix; GARAK_REPORT is its body.
  cat > "$BIN/garak" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report_prefix) prefix="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$GARAK_REPORT" > "$prefix.stub.report.jsonl"
SH
  cat > "$BIN/timeout" <<'SH'
#!/usr/bin/env bash
shift 2
exec "$@"
SH
  chmod +x "$BIN/semgrep" "$BIN/osv-scanner" "$BIN/gitleaks" "$BIN/garak" "$BIN/timeout"

  SCRIPT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  BASELINE="$PROJECT/audits/$(date +%Y-%m-%d)-baseline-project.json"
  NARRATIVE="${BASELINE%.json}.md"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

# engines <json>: prints "name=status:exit" per engine, sorted, and "complete=<bool>".
engines() {
  python3 - "$1" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
for name, engine in sorted(doc["engines"].items()):
    print("{}={}:{}".format(name, engine["status"], engine["exit"]))
print("complete={}".format(str(doc["complete"]).lower()))
PY
}

@test "baseline refuses executable or unknown local configuration without running it" {
  local cfg="$PROJECT/.claude/skills/security-gate-local/local.config.sh"
  mkdir -p "${cfg%/*}"
  printf 'SECURITY_GATE_STACK_PROFILE="web-next"\nprintf pwned > "%s"\n' "$TEST_ROOT/config-ran" > "$cfg"
  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"local.config.sh"*"line 2"* ]] || { echo "$output"; false; }
  [ ! -e "$TEST_ROOT/config-ran" ]

  printf 'SECURITY_GATE_UNKNOWN="value"\n' > "$cfg"
  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"local.config.sh"*"line 1"* ]] || { echo "$output"; false; }

  # Documented shared keys and a literal default are data, not shell code.
  printf '%s\n' 'SECURITY_GATE_STACK_PROFILE="web-next"' \
    'SECURITY_GATE_SEMGREP_TIMEOUT=30' 'SECURITY_GATE_SHELLCHECK="0"' \
    'SECURITY_GATE_SHELLCHECK_EXCLUDE_GLOBS="vendor/*"' 'LLM_PROVIDER="none"' \
    'SECURITY_GATE_AUDIT_DIR="${SECURITY_GATE_AUDIT_DIR:-audits}"' > "$cfg"
  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$TEST_ROOT/config-ran" ]
}

@test "baseline refuses an absolute audit directory" {
  local cfg="$PROJECT/.claude/skills/security-gate-local/local.config.sh"
  mkdir -p "${cfg%/*}"
  printf 'SECURITY_GATE_AUDIT_DIR=/absolute-audits\n' > "$cfg"
  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 1 ] && [[ "$output" == *"SECURITY_GATE_AUDIT_DIR"* ]] || { echo "rc=$status; $output"; false; }
}

@test "baseline refuses parent segments in the audit directory without outside writes" {
  local cfg="$PROJECT/.claude/skills/security-gate-local/local.config.sh" failures=0
  mkdir -p "${cfg%/*}" "$TEST_ROOT/outside"
  printf 'SECURITY_GATE_AUDIT_DIR=../outside/nested\n' > "$cfg"
  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ ! -e "$TEST_ROOT/outside/nested" ] && [ "$status" -eq 1 ] && [[ "$output" == *"SECURITY_GATE_AUDIT_DIR"* ]] \
    || { echo "outside parent: rc=$status; $output"; failures=1; }
  # Even a traversal that returns inside is refused before making its first
  # component, so the literal no-parent rule has its own behavioral oracle.
  printf 'SECURITY_GATE_AUDIT_DIR=nested/../inside\n' > "$cfg"
  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ ! -e "$PROJECT/nested" ] && [ "$status" -eq 1 ] && [[ "$output" == *"SECURITY_GATE_AUDIT_DIR"* ]] \
    || { echo "inside parent: rc=$status; $output"; failures=1; }
  [ "$failures" -eq 0 ]
}

@test "baseline refuses project names that escape the report directory" {
  local cfg="$PROJECT/.claude/skills/security-gate-local/local.config.sh" tag
  tag="$(date +%Y-%m-%d)"
  mkdir -p "${cfg%/*}" "$PROJECT/audits/${tag}-baseline-x" "$TEST_ROOT/victim"
  printf '%s\n' 'SECURITY_GATE_PROJECT_NAME=x/../../../victim/CLAUDE' > "$cfg"
  printf 'unchanged-md\n' > "$TEST_ROOT/victim/CLAUDE.md"
  printf 'unchanged-json\n' > "$TEST_ROOT/victim/CLAUDE.json"
  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$(<"$TEST_ROOT/victim/CLAUDE.md")" = unchanged-md ] || { echo "outside markdown overwritten; rc=$status; $output"; false; }
  [ "$(<"$TEST_ROOT/victim/CLAUDE.json")" = unchanged-json ] || { echo "outside JSON overwritten; rc=$status; $output"; false; }
  [ "$status" -eq 1 ] && [[ "$output" == *"SECURITY_GATE_PROJECT_NAME"* ]] || { echo "rc=$status; $output"; false; }
}

@test "baseline names reports after any project directory, and holds only a configured name to the alphabet" {
  local name dir tag failures=0 report mode
  tag="$(date +%Y-%m-%d)"
  umask 022
  for name in 'my project' 'a+b' 'café'; do
    dir="$TEST_ROOT/$name"
    mkdir -p "$dir"
    cp "$PROJECT/package-lock.json" "$dir/"
    git -C "$dir" init -q
    git -C "$dir" add package-lock.json
    run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$dir" --no-llm
    report="$dir/audits/${tag}-baseline-${name}"
    mode="$(python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$report.json" 2>&1)" || mode=missing
    [ "$status" -eq 0 ] && [ -f "$report.md" ] && [ "$mode" = 0o644 ] \
      || { echo "$name: rc=$status mode=$mode; $output"; failures=1; }
  done
  # The same spelling, configured, is still refused before any report is written.
  run env PATH="$BIN:$PATH" SECURITY_GATE_PROJECT_NAME='my project' \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 1 ] && [[ "$output" == *"SECURITY_GATE_PROJECT_NAME is not a safe path component: my project"* ]] \
    && [ ! -e "$PROJECT/audits" ] || { echo "configured: rc=$status; $output"; failures=1; }
  [ "$failures" -eq 0 ]
}

@test "baseline refuses an audit symlink outside before making descendants" {
  mkdir -p "$TEST_ROOT/outside"
  ln -s "$TEST_ROOT/outside" "$PROJECT/audits"
  run env PATH="$BIN:$PATH" SECURITY_GATE_AUDIT_DIR=audits/nested \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ ! -e "$TEST_ROOT/outside/nested" ] || { echo "outside directory created; rc=$status; $output"; false; }
  [ "$status" -eq 1 ] && [[ "$output" == *"audit"*"outside"* ]] || { echo "rc=$status; $output"; false; }
}

@test "baseline refuses symlinked report files before writing" {
  local ext dir dest report failures=0 tag
  tag="$(date +%Y-%m-%d)"
  mkdir -p "$TEST_ROOT/outside"
  for ext in json md; do
    dir="$PROJECT/audits-$ext"; dest="$TEST_ROOT/outside/victim-$ext"
    mkdir -p "$dir"
    printf 'unchanged\n' > "$dest"
    report="$dir/${tag}-baseline-project.$ext"
    ln -s "$dest" "$report"
    run env PATH="$BIN:$PATH" SECURITY_GATE_AUDIT_DIR="audits-$ext" \
      bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
    [ "$(<"$dest")" = unchanged ] && [ "$status" -eq 1 ] && [[ "$output" == *"report"*"$report"* ]] \
      || { echo "$ext: outside report overwritten or not refused; rc=$status; $output"; failures=1; }
  done
  [ "$failures" -eq 0 ]
}

@test "baseline replaces hardlinked reports without changing the outside inode" {
  mkdir -p "$PROJECT/audits" "$TEST_ROOT/outside"
  printf 'unchanged\n' > "$TEST_ROOT/outside/victim.json"
  ln "$TEST_ROOT/outside/victim.json" "$BASELINE"
  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [ "$(<"$TEST_ROOT/outside/victim.json")" = unchanged ] || { echo "outside hardlink overwritten"; false; }
  [ ! "$BASELINE" -ef "$TEST_ROOT/outside/victim.json" ]
}

@test "baseline permits an audit symlink resolving inside the project" {
  mkdir -p "$PROJECT/inside-audits"
  ln -s "$PROJECT/inside-audits" "$PROJECT/audits"
  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [ -f "$BASELINE" ] && [ -f "$NARRATIVE" ]
}

@test "baseline records an unsafe selected semgrep rather than substituting another" {
  mkdir -p "$PROJECT/.tools"
  printf '#!/bin/sh\n: > "%s"\nexit 0\n' "$TEST_ROOT/project-semgrep-ran" > "$PROJECT/.tools/semgrep"
  chmod +x "$PROJECT/.tools/semgrep"
  run env PATH="$PROJECT/.tools:$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] && [[ "$output" == *"semgrep did not complete: unsafe selected engine"* ]] \
    || { echo "rc=$status; $output"; false; }
  [ ! -e "$TEST_ROOT/project-semgrep-ran" ]
  run engines "$BASELINE"
  [[ "$output" == *"semgrep=failed:2"*"complete=false"* ]] || { echo "$output"; false; }
}

@test "baseline project autodetection never runs git from the project" {
  mkdir -p "$PROJECT/sub" "$PROJECT/.tools"
  printf '#!/bin/sh\n: > "%s"\nexit 1\n' "$TEST_ROOT/autodetect-git-ran" > "$PROJECT/.tools/git"
  chmod +x "$PROJECT/.tools/git"
  run env -u CODEX_PROJECT_DIR -u CLAUDE_PROJECT_DIR PATH="$PROJECT/.tools:$BIN:$PATH" \
    bash -c 'cd "$1" && exec bash "$2" --no-llm' _ "$PROJECT/sub" "$SCRIPT_ROOT/scripts/run-baseline.sh"
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [ ! -e "$TEST_ROOT/autodetect-git-ran" ]
  # The gate prints the physical path; a default macOS temp dir is /var -> /private/var.
  local printed
  printed="$(printf '%s\n' "$output" | sed -n 's/^ *path: *//p' | head -n 1)"
  [ -n "$printed" ] && [ "$(realpath "$printed")" = "$(realpath "$PROJECT")" ] \
    || { echo "printed=$printed; $output"; false; }
}

@test "baseline never runs an unsafe engine even for its version probe" {
  mkdir -p "$PROJECT/.tools"
  printf '#!/bin/sh\n: > "%s"\nexit 42\n' "$TEST_ROOT/project-engine-ran" > "$PROJECT/.tools/semgrep"
  chmod +x "$PROJECT/.tools/semgrep"
  mv "$BIN/semgrep" "$BIN/safe-semgrep"
  ln -s "$PROJECT/.tools/semgrep" "$BIN/semgrep"
  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [ ! -e "$TEST_ROOT/project-engine-ran" ]
}

@test "every engine completing is the only way to a clean baseline" {
  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run engines "$BASELINE"
  [ "$status" -eq 0 ]
  [ "$output" = $'gitleaks=ok:0\nosv-scanner=ok:0\nsemgrep=ok:0\ncomplete=true' ] || { echo "$output"; false; }
  grep -Fq 'Verdict: **clean current tree**' "$NARRATIVE"
}

@test "engines that all exit 42 give an incomplete baseline and a nonzero exit, never clean" {
  run env PATH="$BIN:$PATH" STUB_FAIL="semgrep osv-scanner gitleaks" \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"baseline incomplete: "*"semgrep"* ]] || { echo "$output"; false; }

  run engines "$BASELINE"
  [ "$status" -eq 0 ]
  [ "$output" = $'gitleaks=failed:2\nosv-scanner=failed:2\nsemgrep=failed:2\ncomplete=false' ] || { echo "$output"; false; }
  grep -Fq 'Verdict: **incomplete**' "$NARRATIVE"
  [ "$(grep -c '^Verdict:' "$NARRATIVE")" -eq 1 ]
}

@test "one failed engine is enough to make the baseline incomplete" {
  run env PATH="$BIN:$PATH" STUB_FAIL="osv-scanner" \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }

  run engines "$BASELINE"
  [ "$status" -eq 0 ]
  [ "$output" = $'gitleaks=ok:0\nosv-scanner=failed:2\nsemgrep=ok:0\ncomplete=false' ] || { echo "$output"; false; }
  grep -Fq 'Verdict: **incomplete**' "$NARRATIVE"
  grep -Fq -- '- osv-scanner: **failed** (exit 2)' "$NARRATIVE"
}

@test "semgrep output that is not JSON does not pass for an empty result" {
  run env PATH="$BIN:$PATH" SEMGREP_STDOUT='Traceback: not a semgrep report' \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"semgrep did not complete: missing or malformed JSON"* ]] || { echo "$output"; false; }

  run engines "$BASELINE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"semgrep=failed:2"*"complete=false" ]] || { echo "$output"; false; }
}

@test "a wrapper that exits 0 with unparseable findings is invalid output, not clean" {
  # The aggregator's own check, independent of how any one wrapper fails.
  local skill="$TEST_ROOT/skill"
  cp -R "$SCRIPT_ROOT" "$skill"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "{not-json" > "$3"' 'exit 0' > "$skill/scripts/lib/semgrep.sh"

  run env PATH="$BIN:$PATH" bash "$skill/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }

  run engines "$BASELINE"
  [ "$status" -eq 0 ]
  [ "$output" = $'gitleaks=ok:0\nosv-scanner=ok:0\nsemgrep=invalid_output:0\ncomplete=false' ] || { echo "$output"; false; }
  grep -Fq -- '- semgrep: **invalid output**' "$NARRATIVE"
  grep -Fq 'Verdict: **incomplete**' "$NARRATIVE"
}

# findings <json>: prints "tool/rule@file" per current-tree finding.
findings() {
  python3 - "$1" <<'PY'
import json, sys
for f in json.load(open(sys.argv[1]))["findings"]:
    print("{}/{}@{}".format(f["tool"], f["rule"], f["file"]))
PY
}

@test "a semgrep timeout at exit 0 makes the baseline incomplete and keeps the partial findings" {
  # Inversion (review R1/F1): rc 0 and a parseable report with a Timeout in
  # errors[] was recorded ok, complete and clean.
  run env PATH="$BIN:$PATH" SEMGREP_STDOUT='{"results":[{"check_id":"js.eval","path":"app.ts","start":{"line":3},"extra":{"severity":"ERROR","message":"eval"}}],"errors":[{"type":"Timeout","level":"warn","message":"rule timed out","path":"app.ts"}],"paths":{"scanned":["app.ts"]}}' \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"semgrep did not complete: partial scan: JSON errors non-empty (Timeout)"* ]] || { echo "$output"; false; }

  run engines "$BASELINE"
  [ "$output" = $'gitleaks=ok:0\nosv-scanner=ok:0\nsemgrep=failed:2\ncomplete=false' ] || { echo "$output"; false; }
  run findings "$BASELINE"
  [ "$output" = "semgrep/js.eval@app.ts" ] || { echo "$output"; false; }
  grep -Fq -- '- semgrep: **failed** (exit 2): partial scan: JSON errors non-empty (Timeout)' "$NARRATIVE"
  grep -Fq 'Verdict: **incomplete**' "$NARRATIVE"
  if grep -Fq 'Verdict: **clean' "$NARRATIVE"; then false; fi
}

@test "a semgrep partial parse of a non-shell file at exit 0 makes the baseline incomplete" {
  run env PATH="$BIN:$PATH" SEMGREP_STDOUT='{"results":[],"errors":[{"type":["PartialParsing",[{"path":"app.py"}]],"level":"warn","message":"partial","path":"app.py"}],"paths":{"scanned":["app.py"]}}' \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"JSON errors non-empty (PartialParsing)"* ]] || { echo "$output"; false; }

  run engines "$BASELINE"
  [ "$output" = $'gitleaks=ok:0\nosv-scanner=ok:0\nsemgrep=failed:2\ncomplete=false' ] || { echo "$output"; false; }
  grep -Fq 'Verdict: **incomplete**' "$NARRATIVE"
}

@test "baseline semgrep shell parse errors are incomplete without ShellCheck" {
  # Baseline does not run ShellCheck, so it cannot transfer parse coverage.
  mkdir -p "$PROJECT/scripts"
  printf '#!/usr/bin/env bash\necho hi\n' > "$PROJECT/scripts/hook"
  run env PATH="$BIN:$PATH" SEMGREP_STDOUT='{"results":[],"errors":[{"type":["PartialParsing",[]],"path":"scripts/a.sh"},{"type":"Syntax error","path":"scripts/hook"}],"paths":{"scanned":["scripts/a.sh","scripts/hook"]}}' \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"JSON errors non-empty (PartialParsing, Syntax error)"* ]] || { echo "$output"; false; }
  [[ "$output" != *"shell parse errors not counted"* ]] || { echo "$output"; false; }
  run engines "$BASELINE"
  [ "$output" = $'gitleaks=ok:0\nosv-scanner=ok:0\nsemgrep=failed:2\ncomplete=false' ] || { echo "$output"; false; }

  run env PATH="$BIN:$PATH" SEMGREP_STDOUT='{"results":[],"errors":[{"type":"Timeout","path":"scripts/a.sh"}],"paths":{"scanned":["scripts/a.sh"]}}' \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  run engines "$BASELINE"
  [ "$output" = $'gitleaks=ok:0\nosv-scanner=ok:0\nsemgrep=failed:2\ncomplete=false' ] || { echo "$output"; false; }

  # A shell path the project carves out of ShellCheck gets no exemption.
  run env PATH="$BIN:$PATH" SECURITY_GATE_SHELLCHECK_EXCLUDE_GLOBS='scripts/*' \
    SEMGREP_STDOUT='{"results":[],"errors":[{"type":"Syntax error","path":"scripts/a.sh"}],"paths":{"scanned":["scripts/a.sh"]}}' \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
}

@test "a garak report that stops after its start record leaves a web-rag-llm baseline incomplete" {
  run env PATH="$BIN:$PATH" SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    GARAK_REPORT='{"entry_type":"start_run setup","transient.run_id":"truncated"}' \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --profile=web-rag-llm --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  run engines "$BASELINE"
  [ "$output" = $'garak=failed:2\ngitleaks=ok:0\nosv-scanner=ok:0\nsemgrep=ok:0\ncomplete=false' ] || { echo "$output"; false; }
  grep -Fq -- '- garak: **failed** (exit 2): report has no attempt record' "$NARRATIVE"

  # Evaluated attempts without a completion record are still truncated.
  run env PATH="$BIN:$PATH" SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    GARAK_REPORT=$'{"entry_type":"start_run setup","transient.run_id":"r1"}\n{"entry_type":"init","run":"r1"}\n{"entry_type":"attempt","uuid":"u1","status":1,"probe_classname":"safe.Probe","detector_results":{}}\n{"entry_type":"attempt","uuid":"u1","status":2,"probe_classname":"safe.Probe","detector_results":{"d":[0.0]}}' \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --profile=web-rag-llm --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  run engines "$BASELINE"
  [[ "$output" == *"garak=failed:2"*"complete=false"* ]] || { echo "$output"; false; }

  # The same run with its attempts and completion record is complete.
  run env PATH="$BIN:$PATH" SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    GARAK_REPORT=$'{"entry_type":"start_run setup","transient.run_id":"r1"}\n{"entry_type":"init","run":"r1"}\n{"entry_type":"attempt","uuid":"u1","status":1,"probe_classname":"safe.Probe","detector_results":{}}\n{"entry_type":"attempt","uuid":"u1","status":2,"probe_classname":"safe.Probe","detector_results":{"d":[0.0]}}\n{"entry_type":"completion","run":"r1"}' \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --profile=web-rag-llm --no-llm
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run engines "$BASELINE"
  [ "$output" = $'garak=ok:0\ngitleaks=ok:0\nosv-scanner=ok:0\nsemgrep=ok:0\ncomplete=true' ] || { echo "$output"; false; }
}

@test "an OSV run with no receipt for a tracked lockfile leaves the baseline incomplete" {
  # Inversion (review R2): exit 0 and {"results":[]} with nothing scanned on a
  # repository with a tracked lockfile was a complete, clean baseline.
  run env PATH="$BIN:$PATH" OSV_RECEIPTS="" \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  run engines "$BASELINE"
  [ "$output" = $'gitleaks=ok:0\nosv-scanner=failed:2\nsemgrep=ok:0\ncomplete=false' ] || { echo "$output"; false; }
  grep -Fq -- '- osv-scanner: **failed** (exit 2): tracked lockfile not scanned: package-lock.json' "$NARRATIVE"

  # Every tracked lockfile needs its own receipt, not just one of them.
  mkdir -p "$PROJECT/svc"
  printf '# yarn lockfile v1\n' > "$PROJECT/svc/yarn.lock"
  git -C "$PROJECT" add svc/yarn.lock
  run env PATH="$BIN:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"osv-scanner did not complete: tracked lockfile not scanned: svc/yarn.lock"* ]] || { echo "$output"; false; }

  run env PATH="$BIN:$PATH" OSV_RECEIPTS="package-lock.json svc/yarn.lock" \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run engines "$BASELINE"
  [ "$output" = $'gitleaks=ok:0\nosv-scanner=ok:0\nsemgrep=ok:0\ncomplete=true' ] || { echo "$output"; false; }
}

@test "OSV is not applicable only on the scanner's own no-sources proof, and the baseline can be clean" {
  git -C "$PROJECT" rm -q --cached package-lock.json
  rm "$PROJECT/package-lock.json"
  printf 'export const a = 1;\n' > "$PROJECT/app.ts"
  git -C "$PROJECT" add app.ts
  run env PATH="$BIN:$PATH" OSV_RAN="$TEST_ROOT/osv-ran" OSV_NO_SOURCES=1 \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -e "$TEST_ROOT/osv-ran" ] || { echo "osv-scanner never ran"; false; }
  run engines "$BASELINE"
  [ "$output" = $'gitleaks=ok:0\nosv-scanner=not_applicable:3\nsemgrep=ok:0\ncomplete=true' ] || { echo "$output"; false; }
  grep -Fq -- '- osv-scanner: not applicable (osv-scanner found no package sources and scanned nothing)' "$NARRATIVE"
  grep -Fq 'Verdict: **clean current tree** — no gating findings produced by any scanner. Not applicable: osv-scanner.' "$NARRATIVE"
}

@test "a scanner that ran and failed, or a skipped Garak target, is never not applicable" {
  # osv-scanner reads a tracked lockfile here, so its failure is a failure.
  run env PATH="$BIN:$PATH" OSV_EXIT=128 \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  run engines "$BASELINE"
  [ "$output" = $'gitleaks=ok:0\nosv-scanner=failed:2\nsemgrep=ok:0\ncomplete=false' ] || { echo "$output"; false; }

  # web-rag-llm with no Garak target is a configuration gap, not nothing to scan.
  run env PATH="$BIN:$PATH" SECURITY_GATE_GARAK_TARGET= \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --profile=web-rag-llm --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  run engines "$BASELINE"
  [ "$output" = $'garak=failed:2\ngitleaks=ok:0\nosv-scanner=ok:0\nsemgrep=ok:0\ncomplete=false' ] || { echo "$output"; false; }
  grep -Fq -- '- garak: **failed** (exit 2): SECURITY_GATE_GARAK_TARGET is not set' "$NARRATIVE"

  # Exit 3 alone is not the wrapper's precondition proof.
  local skill="$TEST_ROOT/skill"
  cp -R "$SCRIPT_ROOT" "$skill"
  printf '%s\n' '#!/usr/bin/env bash' ': > "$2"' 'exit 3' > "$skill/scripts/lib/osv.sh"
  run env PATH="$BIN:$PATH" bash "$skill/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  run engines "$BASELINE"
  [ "$output" = $'gitleaks=ok:0\nosv-scanner=failed:3\nsemgrep=ok:0\ncomplete=false' ] || { echo "$output"; false; }
}

@test "a shell shebang on a non-shell extension earns no baseline parse exemption" {
  # Inversion (security review): evil.ts starting #!/bin/sh had its partial
  # parse exempted as shell, and the baseline was complete and clean.
  for path in evil.ts evil.cgi; do
    printf '#!/bin/sh\nexport const x = 1;\n' > "$PROJECT/$path"
    run env PATH="$BIN:$PATH" SEMGREP_STDOUT='{"results":[],"errors":[{"type":["PartialParsing",[]],"path":"'"$path"'"}],"paths":{"scanned":["'"$path"'"]}}' \
      bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
    [ "$status" -eq 2 ] || { echo "$path: $output"; false; }
    [[ "$output" != *"shell parse errors not counted"* ]] || { echo "$path: $output"; false; }
    run engines "$BASELINE"
    [ "$output" = $'gitleaks=ok:0\nosv-scanner=ok:0\nsemgrep=failed:2\ncomplete=false' ] || { echo "$path: $output"; false; }
  done
}

@test "a manifest outside any filename list is scanned, never not applicable" {
  # Inversion (security review): a hand-kept list decided "nothing to scan"
  # before osv-scanner ran, so an SBOM or deps.json it missed was not
  # applicable and the baseline complete and clean.
  git -C "$PROJECT" rm -q --cached package-lock.json
  rm "$PROJECT/package-lock.json"
  printf '{"bomFormat":"CycloneDX"}\n' > "$PROJECT/bom.cdx.json"
  printf '{"targets":{}}\n' > "$PROJECT/App.deps.json"
  git -C "$PROJECT" add bom.cdx.json App.deps.json
  run env PATH="$BIN:$PATH" OSV_RAN="$TEST_ROOT/osv-ran" OSV_RECEIPTS="bom.cdx.json App.deps.json" \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ -e "$TEST_ROOT/osv-ran" ] || { echo "osv-scanner never ran: $output"; false; }
  run engines "$BASELINE"
  [[ "$output" == *"osv-scanner=ok:0"* ]] || { echo "$output"; false; }
}

@test "tracked SBOM and dotnet dependency manifests prevent no-sources classification" {
  git -C "$PROJECT" rm -q --cached package-lock.json
  local failures=0
  for manifest in bom.cdx.json App.deps.json; do
    printf '{}\n' > "$PROJECT/$manifest"
    git -C "$PROJECT" add "$manifest"
    run env PATH="$BIN:$PATH" OSV_NO_SOURCES=1 OSV_RECEIPTS="" \
      bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
    [ "$status" -eq 2 ] || { echo "$manifest: rc=$status; $output"; failures=1; }
    run engines "$BASELINE"
    [[ "$output" == *"osv-scanner=failed:2"*"complete=false"* ]] || { echo "$manifest: $output"; failures=1; }
    git -C "$PROJECT" rm -q --cached "$manifest"
  done
  [ "$failures" -eq 0 ]
}

@test "an exit-128 no-sources run is incomplete when it scanned something or a manifest is tracked" {
  # Remove the tracked lockfile so it cannot mask the receipt check.
  git -C "$PROJECT" rm -q --cached package-lock.json
  run env PATH="$BIN:$PATH" OSV_NO_SOURCES=1 OSV_RECEIPTS="package-lock.json" \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  run engines "$BASELINE"
  [[ "$output" == *"osv-scanner=failed:2"* ]] || { echo "$output"; false; }

  # A tracked dependency file the scanner could not read is a gap, not nothing.
  git -C "$PROJECT" add package-lock.json
  run env PATH="$BIN:$PATH" OSV_NO_SOURCES=1 OSV_RECEIPTS="" \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"osv-scanner did not complete: no lockfile osv-scanner can read (scanner exit 128); tracked dependency file: package-lock.json"* ]] || { echo "$output"; false; }

  # Exit 128 without the no-sources message proves nothing.
  git -C "$PROJECT" rm -q --cached package-lock.json
  run env PATH="$BIN:$PATH" OSV_NO_SOURCES=1 OSV_NO_SOURCES_MESSAGE="" \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  run engines "$BASELINE"
  [[ "$output" == *"osv-scanner=failed:2"* ]] || { echo "$output"; false; }
}

@test "the baseline never imports a module planted in the scanned project" {
  # Inversion (security review): run-baseline.sh's own python3 heredocs ran
  # without -I, so a json.py in the cwd loaded first.
  printf 'open(%s, "w").write("imported")\nraise SystemExit(0)\n' "'$TEST_ROOT/planted-json'" > "$PROJECT/json.py"
  git -C "$PROJECT" add json.py
  run env PATH="$BIN:$PATH" bash -c 'cd "$1" && shift && exec bash "$@"' _ "$PROJECT" \
    "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$TEST_ROOT/planted-json" ] || { echo "planted json.py imported"; false; }
  run engines "$BASELINE"
  [ "$output" = $'gitleaks=ok:0\nosv-scanner=ok:0\nsemgrep=ok:0\ncomplete=true' ] || { echo "$output"; false; }

  run env PATH="$BIN:$PATH" SECURITY_GATE_GARAK_TARGET=openai:test \
    GARAK_REPORT=$'{"entry_type":"start_run setup","transient.run_id":"r1"}\n{"entry_type":"init","run":"r1"}\n{"entry_type":"attempt","uuid":"u1","status":1,"probe_classname":"safe.Probe","detector_results":{}}\n{"entry_type":"attempt","uuid":"u1","status":2,"probe_classname":"safe.Probe","detector_results":{"d":[0.0]}}\n{"entry_type":"completion","run":"r1"}' \
    bash -c 'cd "$1" && shift && exec bash "$@"' _ "$PROJECT" \
    "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --profile=web-rag-llm --no-llm
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$TEST_ROOT/planted-json" ] || { echo "garak imported planted json.py"; false; }
}

@test "a dotted or dotfile name with a shell shebang earns no baseline parse exemption" {
  for path in .x.ts ..ts a.b .foo; do
    printf '#!/bin/sh\ntrue\n' > "$PROJECT/$path"
    run env PATH="$BIN:$PATH" SEMGREP_STDOUT='{"results":[],"errors":[{"type":"Syntax error","path":"'"$path"'"}],"paths":{"scanned":["'"$path"'"]}}' \
      bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
    [ "$status" -eq 2 ] || { echo "$path: $output"; false; }
    [[ "$output" != *"shell parse errors not counted"* ]] || { echo "$path: $output"; false; }
  done
}

@test "an OSV extraction error before no-sources is incomplete, never not applicable" {
  # Inversion (review r2 Sol F2, real osv-scanner 2.6.0): a malformed SBOM
  # fails extraction, then OSV says "No package sources found" at exit 128;
  # that was not applicable and the baseline complete and clean.
  git -C "$PROJECT" rm -q --cached package-lock.json
  printf '{"bomFormat":"CycloneDX", broken\n' > "$PROJECT/bom.cdx.json"
  git -C "$PROJECT" add bom.cdx.json
  run env PATH="$BIN:$PATH" OSV_NO_SOURCES=1 OSV_RECEIPTS="" OSV_EXTRACT_CALLS=1 \
    OSV_EXTRA_STDERR="Error during extraction: (extracting as sbom/cdx) $PROJECT/bom.cdx.json: invalid character 'b' looking for beginning of object key string" \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  run engines "$BASELINE"
  [[ "$output" == *"osv-scanner=failed:2"*"complete=false" ]] || { echo "$output"; false; }
  grep -Fq -- '- osv-scanner: **failed** (exit 2): scanner reported: Error during extraction: (extracting as sbom/cdx)' "$NARRATIVE"

  # Any line outside a failure-free no-source run, or any raw output, also
  # keeps it incomplete.
  run env PATH="$BIN:$PATH" OSV_NO_SOURCES=1 OSV_RECEIPTS="" OSV_EXTRACT_CALLS=1 \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "extract calls: $output"; false; }
  run env PATH="$BIN:$PATH" OSV_NO_SOURCES=1 OSV_RECEIPTS="" OSV_STDOUT='{"results":[{"source":{"path":"bom.cdx.json"}}]}' \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "raw output: $output"; false; }
}

@test "an OSV extraction error in a run that found other sources is incomplete" {
  printf '{"bomFormat":"CycloneDX", broken\n' > "$PROJECT/bom.cdx.json"
  git -C "$PROJECT" add bom.cdx.json
  run env PATH="$BIN:$PATH" \
    OSV_EXTRA_STDERR="Error during extraction: (extracting as sbom/cdx) $PROJECT/bom.cdx.json: invalid character 'b' looking for beginning of object key string" \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"osv-scanner did not complete: scanner reported: Error during extraction"* ]] || { echo "$output"; false; }
}

@test "real osv-scanner: an empty tree is not applicable, a malformed SBOM is incomplete" {
  real="$(command -v osv-scanner)" || skip "osv-scanner not installed"
  "$real" --version 2>/dev/null | grep -q 'osv-scanner version: 2\.' || skip "needs osv-scanner 2.x"
  local real_bin="$TEST_ROOT/real-bin"
  mkdir -p "$real_bin"
  ln -s "$BIN/semgrep" "$real_bin/semgrep"
  ln -s "$BIN/gitleaks" "$real_bin/gitleaks"
  ln -s "$real" "$real_bin/osv-scanner"
  git -C "$PROJECT" rm -q --cached package-lock.json
  rm "$PROJECT/package-lock.json"
  printf 'export const a = 1;\n' > "$PROJECT/app.ts"
  git -C "$PROJECT" add app.ts
  run env PATH="$real_bin:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run engines "$BASELINE"
  [[ "$output" == *"osv-scanner=not_applicable:3"*"complete=true" ]] || { echo "$output"; false; }

  printf '{"bomFormat":"CycloneDX", broken\n' > "$PROJECT/bom.cdx.json"
  git -C "$PROJECT" add bom.cdx.json
  run env PATH="$real_bin:$PATH" bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"Error during extraction"* ]] || { echo "$output"; false; }
  run engines "$BASELINE"
  [[ "$output" == *"osv-scanner=failed:2"*"complete=false" ]] || { echo "$output"; false; }
}

@test "a startup file in BASH_ENV cannot stand in for the scanner wrappers" {
  # Inversion (review r2 Sol F3): the wrappers ran as plain `bash`, so an
  # inherited BASH_ENV could create their outputs and exit 0 before any
  # scanner ran, and every failing engine read as ok.
  cat > "$TEST_ROOT/startup.sh" <<'SH'
case "$0" in
  */lib/semgrep.sh) : > "$3"; : > "$BASH_ENV_MARK"; exit 0 ;;
  */lib/osv.sh|*/lib/gitleaks.sh) : > "$2"; : > "$BASH_ENV_MARK"; exit 0 ;;
esac
SH
  run env PATH="$BIN:$PATH" BASH_ENV="$TEST_ROOT/startup.sh" ENV="$TEST_ROOT/startup.sh" \
    BASH_ENV_MARK="$TEST_ROOT/startup-ran" STUB_FAIL="semgrep osv-scanner gitleaks" \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [ ! -e "$TEST_ROOT/startup-ran" ] || { echo "a wrapper ran BASH_ENV"; false; }
  run engines "$BASELINE"
  [ "$output" = $'gitleaks=failed:2\nosv-scanner=failed:2\nsemgrep=failed:2\ncomplete=false' ] || { echo "$output"; false; }
}

@test "a web-rag-llm baseline whose garak detectors scored nothing is incomplete" {
  run env PATH="$BIN:$PATH" SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    GARAK_REPORT=$'{"entry_type":"start_run setup","transient.run_id":"r1"}\n{"entry_type":"init","run":"r1"}\n{"entry_type":"attempt","uuid":"u1","status":1,"probe_classname":"safe.Probe","detector_results":{}}\n{"entry_type":"attempt","uuid":"u1","status":2,"probe_classname":"safe.Probe","detector_results":{}}\n{"entry_type":"completion","run":"r1"}' \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --profile=web-rag-llm --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  run engines "$BASELINE"
  [ "$output" = $'garak=failed:2\ngitleaks=ok:0\nosv-scanner=ok:0\nsemgrep=ok:0\ncomplete=false' ] || { echo "$output"; false; }
  grep -Fq -- '- garak: **failed** (exit 2): report has 1 evaluated attempt(s) with no detector score (u1)' "$NARRATIVE"

  run env PATH="$BIN:$PATH" SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    GARAK_REPORT=$'{"entry_type":"start_run setup","transient.run_id":"r1"}\n{"entry_type":"init","run":"r1"}\n{"entry_type":"attempt","uuid":"u1","status":1,"probe_classname":"safe.Probe","detector_results":{}}\n{"entry_type":"attempt","uuid":"u1","status":2,"probe_classname":"safe.Probe","detector_results":{"d":[null]}}\n{"entry_type":"completion","run":"r1"}' \
    bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --profile=web-rag-llm --no-llm
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  run engines "$BASELINE"
  [[ "$output" == *"garak=failed:2"*"complete=false"* ]] || { echo "$output"; false; }
}

@test "a baseline OSV stage with an osv-scanner other than 2.x is incomplete" {
  # Its diagnostics are parsed in osv-scanner 2.x's dialect (qualified on
  # 2.6.0); another major version's wording is unverified, so it is not
  # taken as a clean scan.
  for line in "osv-scanner version: 3.0.0" "osv-scanner version: 1.9.2" "something else"; do
    run env PATH="$BIN:$PATH" OSV_VERSION_LINE="$line" \
      bash "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
    [ "$status" -eq 2 ] || { echo "$line: $output"; false; }
    [[ "$output" == *"osv-scanner did not complete: unsupported osv-scanner version for diagnostic parsing"* ]] || { echo "$line: $output"; false; }
    run engines "$BASELINE"
    [[ "$output" == *"osv-scanner=failed:2"* ]] || { echo "$line: $output"; false; }
  done
}

# A pyenv-style python3 shim outside the project, steered by the project's
# .python-version (or PYENV_VERSION) to a hostile "version" that marks it ran.
pyenv_shim() {
  local real versions="$1/pyenv/versions"
  real="$(python3 -I -c 'import os, sys; print(os.path.realpath(sys.executable))')"
  SHIMS="$1/shims"; HOSTILE_MARK="$1/hostile-python-ran"
  mkdir -p "$SHIMS" "$versions/hostile/bin"
  printf '#!/bin/sh\n: > "%s"\nexit 0\n' "$HOSTILE_MARK" > "$versions/hostile/bin/python3"
  cat > "$SHIMS/python3" <<SH
#!/usr/bin/env bash
version="\${PYENV_VERSION:-}"
[ -n "\$version" ] || [ ! -f .python-version ] || version="\$(cat .python-version)"
[ -z "\$version" ] || exec "$versions/\$version/bin/python3" "\$@"
exec "$real" "\$@"
SH
  chmod +x "$SHIMS/python3" "$versions/hostile/bin/python3"
  printf 'hostile\n' > "$2/.python-version"
}

@test "the baseline runs the real python3 behind a shim the project steers" {
  pyenv_shim "$TEST_ROOT" "$PROJECT"
  run env PATH="$SHIMS:$BIN:$PATH" PYENV_VERSION=hostile bash -c 'cd "$1" && shift && exec bash "$@"' _ "$PROJECT" \
    "$SCRIPT_ROOT/scripts/run-baseline.sh" "$PROJECT" --no-llm
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$HOSTILE_MARK" ] || { echo "the baseline ran the project-chosen interpreter"; false; }
  run engines "$BASELINE"
  [ "$output" = $'gitleaks=ok:0\nosv-scanner=ok:0\nsemgrep=ok:0\ncomplete=true' ] || { echo "$output"; false; }
}
