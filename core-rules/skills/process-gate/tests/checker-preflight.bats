#!/usr/bin/env bats
# Tests for checker-preflight.sh's fail-closed binary identity contract.

setup() {
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

@test "known jq fail-open: run-all merges while preflight refuses" {
  local stub="$BATS_TEST_TMPDIR/skill"
  local project="$BATS_TEST_TMPDIR/project"
  mkdir -p "$stub/scripts/lib" "$project"
  cp "$REAL_SCRIPTS/run-all.sh" "$stub/scripts/run-all.sh"
  cp "$REAL_SCRIPTS/check-slop.sh" "$stub/scripts/check-slop.sh"
  cp "$REAL_SCRIPTS/lib/common.sh" "$stub/scripts/lib/common.sh"

  local checker
  for checker in check-pr.sh check-secrets.sh check-bypass.sh check-tests.sh \
    check-docs.sh check-security-diff.sh check-analyze.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$stub/scripts/$checker"
  done
  printf '%s\n' '{"gate_profiles":{"anti_slop":{"posture":"advisory"}}}' > "$project/.trellis.json"

  local utility
  for utility in bash dirname head awk; do
    ln -s "$(type -P "$utility")" "$BIN/$utility"
  done
  mv "$BIN/jq" "$BIN/jq.masked"

  run /usr/bin/env PATH="$BIN" CLAUDE_PROJECT_DIR="$project" \
    PROCESS_GATE_STACK_PROFILE=n-a /bin/bash "$stub/scripts/run-all.sh" \
    --mode=merge --range=HEAD~1..HEAD
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Anti-slop:"*"n/a"* ]]
  [[ "$output" == *"Overall: MERGEABLE"* ]]

  run /usr/bin/env PATH="$BIN" /bin/bash "$SCRIPT"
  [ "$status" -eq 4 ]
  [[ "$output" == *"fail checker-preflight: jq not found on PATH"* ]]
}
