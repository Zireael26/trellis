#!/usr/bin/env bats
# Tests for run-all.sh — the Phase 7a aggregator changes:
#   - 8-gate parallel arrays (idx 0-7) + dual indexed render loops.
#   - --mode=push|merge (DL-P7-02) PR-shape downgrade: at push a FAIL in
#     {0 PR hygiene, 4 Docs discipline, 7 Analyze} -> WARN; the always-hard
#     gates {1 Secrets, 2 Bypass markers, 3 Tests, 6 Security} NEVER downgrade.
#   - At merge: strict, no downgrade.
#   - Exit-code contract preserved: MERGEABLE 0 / NEEDS CHANGES 2 / BLOCKED 1.
#
# Strategy (FILE A is the aggregator; check-security-diff.sh / check-analyze.sh
# are authored by sibling agents and may not exist yet). We unit-test the
# aggregator in ISOLATION against STUB gate scripts: a throwaway skill dir holds
# run-all.sh + lib/common.sh + seven stub check-*.sh that each `exit
# "${STUB_RC_<idx>:-0}"`. SKILL_DIR resolves to the tmp dir, so every run_gate
# call lands on a stub whose rc we drive via env. PROCESS_GATE_STACK_PROFILE=n-a
# keeps idx 5 (inline, not a script) at n/a so it never affects the verdict.

setup() {
  REAL_SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts"
  STUB="$(mktemp -d)"
  mkdir -p "$STUB/scripts/lib"
  cp "$REAL_SCRIPTS/run-all.sh"      "$STUB/scripts/run-all.sh"
  cp "$REAL_SCRIPTS/lib/common.sh"   "$STUB/scripts/lib/common.sh"
  chmod +x "$STUB/scripts/run-all.sh"

  # One stub per run_gate idx. Each exits with STUB_RC_<idx> (default 0=pass).
  # The stub echoes a marker so we can assert it actually ran if needed.
  _stub() {
    local name="$1" envvar="$2"
    cat > "$STUB/scripts/$name" <<EOF
#!/usr/bin/env bash
echo "[stub:$name] ran"
exit "\${$envvar:-0}"
EOF
    chmod +x "$STUB/scripts/$name"
  }
  _stub check-pr.sh            STUB_RC_0
  _stub check-secrets.sh       STUB_RC_1
  _stub check-bypass.sh        STUB_RC_2
  _stub check-tests.sh         STUB_RC_3
  _stub check-docs.sh          STUB_RC_4
  _stub check-security-diff.sh STUB_RC_6
  _stub check-analyze.sh       STUB_RC_7

  # A fixture git repo so common.sh range/project resolution does not error.
  PROJECT_DIR="$(mktemp -d)"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git commit --allow-empty -q -m "init"
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  unset CODEX_PROJECT_DIR
  # idx 5 inline stack-profile -> n/a (no validators).
  export PROCESS_GATE_STACK_PROFILE="n-a"
}

teardown() {
  [ -n "${STUB:-}" ] && [ -d "$STUB" ] && rm -rf "$STUB"
  [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ] && rm -rf "$PROJECT_DIR"
}

# run_all <mode> — invoke the staged aggregator from inside the fixture so the
# default range resolves cleanly. Per-gate rc comes from STUB_RC_<idx> env.
run_all() {
  local mode="$1"
  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=$mode"
}

# --- 8-gate render --------------------------------------------------------

@test "render: all 8 gate labels emitted (verdict loop), all-pass -> MERGEABLE 0" {
  run_all merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR hygiene"* ]]
  [[ "$output" == *"Secrets"* ]]
  [[ "$output" == *"Bypass markers"* ]]
  [[ "$output" == *"Tests & coverage"* ]]
  [[ "$output" == *"Docs discipline"* ]]
  [[ "$output" == *"Stack profile"* ]]
  [[ "$output" == *"Security (diff)"* ]]
  [[ "$output" == *"Analyze"* ]]
  [[ "$output" == *"Overall: MERGEABLE"* ]]
}

@test "render: findings loop also surfaces idx 6/7 labels when not MERGEABLE" {
  # Security (6) fails -> BLOCKED -> findings section renders. Analyze (7) warn
  # so its label shows in findings too.
  STUB_RC_6=1 STUB_RC_7=2 run bash -c "cd '$PROJECT_DIR' && STUB_RC_6=1 STUB_RC_7=2 '$STUB/scripts/run-all.sh' --mode=merge"
  [ "$status" -eq 1 ]
  [[ "$output" == *"## Findings"* ]]
  [[ "$output" == *"### Security (diff)"* ]]
  [[ "$output" == *"### Analyze"* ]]
}

# --- mode default (fail-closed) -------------------------------------------

@test "mode: missing --mode defaults to merge (strict)" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_0=1 '$STUB/scripts/run-all.sh'"
  # idx 0 (PR hygiene) fails; merge default => no downgrade => BLOCKED.
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode=merge"* ]]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

@test "mode: garbage --mode value resolves to merge (fail-closed, never lenient)" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_0=1 '$STUB/scripts/run-all.sh' --mode=bogus"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode=merge"* ]]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

# --- push: PR-shape downgrade ---------------------------------------------

@test "push: PR hygiene (idx 0) FAIL downgrades to WARN -> NEEDS CHANGES 2" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_0=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Overall: NEEDS CHANGES"* ]]
  [[ "$output" == *"downgraded to WARN"* ]]
}

@test "push: Docs discipline (idx 4) FAIL downgrades to WARN -> NEEDS CHANGES 2" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_4=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Overall: NEEDS CHANGES"* ]]
}

@test "push: Analyze (idx 7) FAIL downgrades to WARN -> NEEDS CHANGES 2" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_7=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Overall: NEEDS CHANGES"* ]]
}

# --- push: always-hard gates NEVER downgrade (fail-open guard) -------------

@test "push: Secrets (idx 1) FAIL still BLOCKS (no downgrade) -> 1" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_1=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

@test "push: Bypass markers (idx 2) FAIL still BLOCKS (no downgrade) -> 1" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_2=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

@test "push: Tests (idx 3) FAIL still BLOCKS (no downgrade) -> 1" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_3=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

@test "push: Security (idx 6) FAIL still BLOCKS (no downgrade) -> 1" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_6=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

# --- merge: strict, every FAIL blocks (incl PR-shape) ---------------------

@test "merge: PR hygiene (idx 0) FAIL hard-blocks (no downgrade at merge) -> 1" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_0=1 '$STUB/scripts/run-all.sh' --mode=merge"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

@test "merge: Docs discipline (idx 4) FAIL hard-blocks -> 1" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_4=1 '$STUB/scripts/run-all.sh' --mode=merge"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

@test "merge: Analyze (idx 7) FAIL hard-blocks -> 1" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_7=1 '$STUB/scripts/run-all.sh' --mode=merge"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

# --- warn handling preserved ----------------------------------------------

@test "any gate WARN (rc 2) -> NEEDS CHANGES 2 at both modes" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_1=2 '$STUB/scripts/run-all.sh' --mode=merge"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Overall: NEEDS CHANGES"* ]]
}

@test "push: a real fail + a warn -> still BLOCKED when fail is always-hard" {
  # idx 6 always-hard fail + idx 0 PR-shape fail (downgraded). Overall BLOCKED.
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_6=1 STUB_RC_0=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

# --- PG_MODE is exported to child gates -----------------------------------

@test "PG_MODE is exported so child gates observe the mode" {
  # Replace the analyze stub with one that records the PG_MODE it observed to a
  # side file. run_gate captures child stdout (only rendered on non-MERGEABLE),
  # so the side file is the reliable channel for a passing child.
  local seen="$STUB/pg_mode_seen.txt"
  cat > "$STUB/scripts/check-analyze.sh" <<EOF
#!/usr/bin/env bash
printf '%s' "\${PG_MODE:-<unset>}" > '$seen'
exit 0
EOF
  chmod +x "$STUB/scripts/check-analyze.sh"
  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 0 ]
  [ "$(cat "$seen")" = "push" ]
}
