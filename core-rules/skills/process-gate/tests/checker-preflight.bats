#!/usr/bin/env bats
# Tests for checker-preflight.sh's fail-closed binary identity contract.

setup() {
  export TRELLIS_GATE_STATE_DIR="$BATS_TEST_TMPDIR/trellis-gate-state"
  REAL_SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts"
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/checker-preflight.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"

  local checker
  for checker in gitleaks semgrep osv-scanner jq; do
    cat > "$BIN/$checker" <<EOF
#!/bin/bash
printf '%s\n' '$checker 1.0'
EOF
    chmod +x "$BIN/$checker"
  done
}

@test "all delegated checker binaries resolve with path and version" {
  run /usr/bin/env PATH="$BIN" /bin/bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gitleaks=$BIN/gitleaks version=gitleaks 1.0"* ]]
  [[ "$output" == *"semgrep=$BIN/semgrep version=semgrep 1.0"* ]]
  [[ "$output" == *"osv-scanner=$BIN/osv-scanner version=osv-scanner 1.0"* ]]
  [[ "$output" == *"jq=$BIN/jq version=jq 1.0"* ]]
}

@test "missing jq fails closed" {
  chmod -x "$BIN/jq"

  run /usr/bin/env PATH="$BIN" /bin/bash "$SCRIPT"
  [ "$status" -eq 4 ]
  [[ "$output" == *"fail checker-preflight: jq not found on PATH"* ]]
}

@test "checker version failure fails closed" {
  printf '#!/bin/bash\nexit 9\n' > "$BIN/jq"
  chmod +x "$BIN/jq"

  run /usr/bin/env PATH="$BIN" /bin/bash "$SCRIPT"
  [ "$status" -eq 4 ]
  [[ "$output" == *"fail checker-preflight: jq version check failed at $BIN/jq"* ]]
}

jq_missing_fixture() {
  STUB="$BATS_TEST_TMPDIR/skill"
  PROJECT="$BATS_TEST_TMPDIR/project"
  ENGINE="$BATS_TEST_TMPDIR/security-gate/scripts/lib/engine.sh"
  mkdir -p "$STUB/scripts/lib" "$PROJECT" "${ENGINE%/*}"
  cp "$REAL_SCRIPTS/run-all.sh" "$STUB/scripts/run-all.sh"
  cp "$REAL_SCRIPTS/check-slop.sh" "$STUB/scripts/check-slop.sh"
  cp "$REAL_SCRIPTS/lib/common.sh" "$STUB/scripts/lib/common.sh"
  cp "$REAL_SCRIPTS/lib/diff-base.sh" "$STUB/scripts/lib/diff-base.sh"
  cp "$REAL_SCRIPTS/../../security-gate/scripts/lib/engine.sh" "$ENGINE"
  local checker utility
  for checker in check-pr.sh check-secrets.sh check-bypass.sh check-tests.sh \
    check-docs.sh check-security-diff.sh check-analyze.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$STUB/scripts/$checker"
  done
  git -C "$PROJECT" init -q -b main
  git -C "$PROJECT" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false \
    commit --allow-empty -qm one
  mkdir -p "$PROJECT/src"
  printf 'const value = input as any;\n' > "$PROJECT/src/slop.ts"
  git -C "$PROJECT" add src/slop.ts
  git -C "$PROJECT" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false \
    commit -qm two
  for utility in bash dirname head tail awk git env mktemp rm mkdir sed cat cut sort wc tr date; do
    ln -s "$(type -P "$utility")" "$BIN/$utility"
  done
  ln -s "$(python3 -I -c 'import os, sys; print(os.path.realpath(sys.executable))')" "$BIN/python3"
  mv "$BIN/jq" "$BIN/jq.masked"
}

run_slop_without_jq() {
  run /usr/bin/env PATH="$BIN" CLAUDE_PROJECT_DIR="$PROJECT" \
    /bin/bash "$STUB/scripts/check-slop.sh" --range=HEAD~1..HEAD
}

run_all_without_jq() {
  run /usr/bin/env PATH="$BIN" CLAUDE_PROJECT_DIR="$PROJECT" \
    PROCESS_GATE_STACK_PROFILE=n-a /bin/bash "$STUB/scripts/run-all.sh" \
    --mode=merge --range=HEAD~1..HEAD
}

@test "jq missing: advisory stays n/a but both entry points say the scan did not run" {
  jq_missing_fixture
  printf '%s\n' '{"gate_profiles":{"anti_slop":{"posture":"advisory"}}}' > "$PROJECT/.trellis.json"
  run_slop_without_jq
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == info* && "$output" == *'jq unavailable'* && "$output" == *'check did not run'* ]] || { echo "$output"; false; }
  run_all_without_jq
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'Anti-slop:'*'n/a'* && "$output" == *'check did not run'* && "$output" == *'Overall: MERGEABLE'* ]] || { echo "$output"; false; }
  run /usr/bin/env PATH="$BIN" /bin/bash "$SCRIPT"
  [ "$status" -eq 4 ]
  [[ "$output" == *'fail checker-preflight: jq not found on PATH'* ]]
}

@test "jq missing: enforced and unknown posture fail at both entry points" {
  jq_missing_fixture
  printf '%s\n' '{"gate_profiles":{"anti_slop":{"posture":"enforced"}}}' > "$PROJECT/.trellis.json"
  run_slop_without_jq
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == fail* && "$output" == *'jq unavailable'* ]] || { echo "$output"; false; }
  run_all_without_jq
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *'Anti-slop:'*'fail'* && "$output" == *'Overall: BLOCKED'* ]] || { echo "$output"; false; }

  mv "$ENGINE" "$ENGINE.available"
  printf 'sg_resolve_python() { return 1; }\n' > "$ENGINE"
  run_slop_without_jq
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == fail* && "$output" == *'posture unknown'* ]] || { echo "$output"; false; }
  run_all_without_jq
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *'Anti-slop:'*'fail'* && "$output" == *'Overall: BLOCKED'* ]] || { echo "$output"; false; }
}

@test "jq missing: project and caller PATH python cannot forge the posture" {
  local poison="$BATS_TEST_TMPDIR/poison-ran"
  jq_missing_fixture
  printf '%s\n' '{"gate_profiles":{"anti_slop":{"posture":"enforced"}}}' > "$PROJECT/.trellis.json"
  mkdir -p "$PROJECT/bin"
  printf '#!/bin/bash\nprintf invoked > "%s"\nprintf "ok:off\\n"\n' "$poison" > "$PROJECT/bin/python3"
  chmod +x "$PROJECT/bin/python3"
  run /usr/bin/env PATH="$PROJECT/bin:$BIN" CLAUDE_PROJECT_DIR="$PROJECT" \
    /bin/bash "$STUB/scripts/check-slop.sh" --range=HEAD~1..HEAD
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == fail* && "$output" == *'jq unavailable'* ]] || { echo "$output"; false; }
  [ ! -e "$poison" ]
}

@test "jq missing: off or undeclared remains n/a and malformed remains advisory" {
  local manifest
  jq_missing_fixture
  for manifest in '{"gate_profiles":{"anti_slop":{"posture":"off"}}}' '{}'; do
    printf '%s\n' "$manifest" > "$PROJECT/.trellis.json"
    run_slop_without_jq
    [ "$status" -eq 0 ] && [[ "$output" == info* && "$output" == *'n/a'* ]] || { echo "$output"; false; }
    run_all_without_jq
    [ "$status" -eq 0 ] && [[ "$output" == *'Anti-slop:'*'n/a'* && "$output" == *'Overall: MERGEABLE'* ]] || { echo "$output"; false; }
  done
  printf '%s\n' '{bad json' > "$PROJECT/.trellis.json"
  run_slop_without_jq
  [ "$status" -eq 0 ] && [[ "$output" == warn* && "$output" == *'treated as advisory'* && "$output" == *'jq unavailable'* ]] || { echo "$output"; false; }
  run_all_without_jq
  [ "$status" -eq 2 ] && [[ "$output" == *'Overall: NEEDS CHANGES'* ]] || { echo "$output"; false; }
}
