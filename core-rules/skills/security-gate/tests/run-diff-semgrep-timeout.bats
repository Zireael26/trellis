#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../../../.." && pwd -P)"
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/run-diff-semgrep-timeout.XXXXXX")"
  PROJECT="$SANDBOX/project"
  BIN="$SANDBOX/bin"
  PROJECT_NAME="${PROJECT##*/}"
  mkdir -p "$PROJECT/audits" "$BIN"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email "security-gate@trellis.test"
  git -C "$PROJECT" config user.name "security gate test"
  cat > "$BIN/semgrep" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "$SG_FIXTURE/semgrep.args"
printf '%s\n' '{"results":[],"errors":[],"paths":{"scanned":["changed.ts"]}}'
SH
  cat > "$BIN/gitleaks" <<'SH'
#!/bin/bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-path) report="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '[]\n' > "$report"
SH
  chmod 755 "$BIN/semgrep" "$BIN/gitleaks"
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}' \
    > "$PROJECT/audits/2026-01-01-baseline-$PROJECT_NAME.json"
  printf '%s\n' '{"schema_version":1,"project_id":"fixture","security_gate":{"semgrep_timeout":73}}' \
    > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm "seed base"
  SCRIPT="$REPO_ROOT/core-rules/skills/security-gate/scripts/run-diff.sh"
  PYTHON_DIR="$(dirname "$(command -v python3)")"
}

teardown() {
  if [ -n "${SANDBOX:-}" ]; then
    (CDPATH='' cd "${SANDBOX%/*}" && rm -rf "${SANDBOX##*/}")
  fi
}

commit_change() {
  printf '%s\n' '{"schema_version":1,"project_id":"fixture","security_gate":{"semgrep_timeout":9}}' \
    > "$PROJECT/.trellis.json"
  printf '%s\n' 'export const changed = true;' > "$PROJECT/changed.ts"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm "candidate change"
}

run_diff() {
  run env PATH="$BIN:$PYTHON_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    SG_FIXTURE="$SANDBOX" SECURITY_GATE_PROJECT_NAME="$PROJECT_NAME" \
    bash "$SCRIPT" "$PROJECT" --range=HEAD~1..HEAD --no-llm
}

semgrep_timeout_arg() {
  awk 'prev == "--timeout" { print; exit } { prev = $0 }' "$SANDBOX/semgrep.args"
}

@test "semgrep timeout comes from the protected range-base manifest, not the head" {
  commit_change
  run_diff
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"Overall: MERGEABLE"* ]]
  [ "$(semgrep_timeout_arg)" = 73 ]
}

@test "invalid protected semgrep timeout blocks before scanning" {
  printf '%s\n' '{"schema_version":1,"project_id":"fixture","security_gate":{"semgrep_timeout":601}}' \
    > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" commit -qm "invalid protected config"
  commit_change
  run_diff
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"base .trellis.json security_gate.semgrep_timeout"* ]]
  [[ "$output" == *"Overall: BLOCKED"* ]]
  [ ! -e "$SANDBOX/semgrep.args" ]
}
