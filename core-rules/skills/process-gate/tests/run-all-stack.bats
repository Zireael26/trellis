#!/usr/bin/env bats
# Tests for run-all.sh idx-5 stack-profile validator RESOLUTION (DL-P7-08).
#
# Root cause fixed here: resolve_stack_validator used `[ -x ... ]` on a script
# that is then RUN via `bash "$vpath"` (idx-5 block) — so the exec bit is
# irrelevant. A present-but-mode-644 validator (the state after a mirror-sync,
# which does NOT preserve the exec bit) failed the -x test -> vpath empty ->
# worst=fail -> idx 5 BLOCKS every merge in a stack-profile repo. Both -x tests
# (absolute-path arm + candidate-loop) were changed to `-f` (regular-file test,
# correct for a bash-invoked script).
#
# Discriminator: with -f a 644 validator is LOCATED + run via bash (its rc/output
# flows through); with -x it is treated as MISSING -> idx 5 fail -> BLOCKED.
#
# RED-GREEN (DL-P5-11 mandate): each scenario runs against BOTH the on-disk -f
# aggregator (GREEN: validator INVOKED) and a copy with -f flipped back to -x
# (RED: "validator missing" + BLOCKED). Same scenario, only the flip differs ->
# non-tautological.
#
# The staged validator is chmod 644 (NOT executable) on purpose — that is the
# whole point of the test.

setup() {
  REAL_SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts"
  STUB="$(mktemp -d)"
  mkdir -p "$STUB/scripts/lib"
  cp "$REAL_SCRIPTS/run-all.sh"      "$STUB/scripts/run-all.sh"
  cp "$REAL_SCRIPTS/lib/common.sh"   "$STUB/scripts/lib/common.sh"
  chmod +x "$STUB/scripts/run-all.sh"

  # One passing stub per run_gate idx so the only non-pass verdict driver is
  # idx 5 (the stack profile). Each exits 0 (pass).
  _stub() {
    local name="$1"
    cat > "$STUB/scripts/$name" <<EOF
#!/usr/bin/env bash
echo "[stub:$name] ran"
exit 0
EOF
    chmod +x "$STUB/scripts/$name"
  }
  _stub check-pr.sh
  _stub check-secrets.sh
  _stub check-bypass.sh
  _stub check-tests.sh
  _stub check-docs.sh
  _stub check-security-diff.sh
  _stub check-analyze.sh

  # Fixture git repo so common.sh range/project resolution does not error.
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

  # Side-file the validator writes to when INVOKED — observable regardless of
  # findings rendering (idx-5 pass suppresses the Findings section).
  INVOKED_MARKER="$(mktemp -u)"
}

teardown() {
  # Plain `&&` chains are unsafe here: a chain whose final condition is
  # legitimately false (e.g. the RED cases where INVOKED_MARKER never exists)
  # returns non-zero and bats fails the test on teardown. Use if-blocks so the
  # cleanup is a no-op-success, never a failure signal.
  if [ -n "${STUB:-}" ] && [ -d "$STUB" ]; then rm -rf "$STUB"; fi
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then rm -rf "$PROJECT_DIR"; fi
  if [ -n "${INVOKED_MARKER:-}" ] && [ -f "$INVOKED_MARKER" ]; then rm -f "$INVOKED_MARKER"; fi
  return 0
}

# Stage a 644 (NON-executable) validator that records its invocation to
# $INVOKED_MARKER and exits 0 (pass). $1 = absolute destination path.
_stage_validator_644() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<EOF
#!/usr/bin/env bash
printf 'invoked' > '$INVOKED_MARKER'
exit 0
EOF
  chmod 644 "$dest"   # deliberately NOT executable
  # Sanity: confirm the file is present and NOT executable (the test premise).
  [ -f "$dest" ]
  [ ! -x "$dest" ]
}

# Stage a local.config.sh that pg_load_config sources at runtime. It sets the
# stack profile + validators array (arrays cannot be exported, so a sourced
# config is the only path). $1 = the single validator entry (bare name or
# absolute path).
_stage_config() {
  local entry="$1"
  local cfgdir="$PROJECT_DIR/.claude/skills/process-gate-local"
  mkdir -p "$cfgdir"
  cat > "$cfgdir/local.config.sh" <<EOF
PROCESS_GATE_STACK_PROFILE="custom"
PROCESS_GATE_STACK_VALIDATORS=("$entry")
EOF
}

# Build a RED copy of the aggregator: flip the two `-f` tests back to `-x`.
# Guard: assert EXACTLY two `[ -f ` sites before the flip so we touch only the
# intended tests and nothing has drifted. Echoes the path to the red copy.
_make_red_copy() {
  local src="$STUB/scripts/run-all.sh"
  local red="$STUB/scripts/run-all-red.sh"
  local n
  n="$(grep -c '\[ -f ' "$src")"
  [ "$n" -eq 2 ]
  sed 's/\[ -f /[ -x /g' "$src" > "$red"
  chmod +x "$red"
  # The red copy must now have two `-x` tests and zero `-f` tests.
  [ "$(grep -c '\[ -x ' "$red")" -eq 2 ]
  [ "$(grep -c '\[ -f ' "$red")" -eq 0 ]
  printf '%s' "$red"
}

# --- candidate-loop arm (bare name -> resolved under a resolve dir) ----------

@test "GREEN candidate-loop: 644 validator at process-gate-local is LOCATED + INVOKED (idx5 pass)" {
  # Bare name resolves to $PROJECT_DIR/.claude/skills/process-gate-local/<name>
  # (a resolve dir for the candidate loop, line ~116).
  _stage_validator_644 "$PROJECT_DIR/.claude/skills/process-gate-local/stack-check.sh"
  _stage_config "stack-check.sh"

  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=merge"
  [ "$status" -eq 0 ]                                  # MERGEABLE: validator passed
  [[ "$output" == *"Overall: MERGEABLE"* ]]
  [[ "$output" == *"Stack profile:"* ]]
  [[ "$output" != *"validator missing"* ]]             # NOT reported missing
  [ -f "$INVOKED_MARKER" ]                             # the 644 validator RAN
  [ "$(cat "$INVOKED_MARKER")" = "invoked" ]
}

@test "RED candidate-loop: -x copy treats the 644 validator as MISSING -> idx5 fail -> BLOCKED" {
  _stage_validator_644 "$PROJECT_DIR/.claude/skills/process-gate-local/stack-check.sh"
  _stage_config "stack-check.sh"
  RED="$(_make_red_copy)"

  run bash -c "cd '$PROJECT_DIR' && '$RED' --mode=merge"
  [ "$status" -eq 1 ]                                  # BLOCKED
  [[ "$output" == *"Overall: BLOCKED"* ]]
  [[ "$output" == *"validator missing"* ]]             # reported missing under -x
  [ ! -f "$INVOKED_MARKER" ]                           # validator was NEVER run
}

# --- absolute-path arm (case /*) --------------------------------------------

@test "GREEN absolute-path: 644 validator given by absolute path is LOCATED + INVOKED (idx5 pass)" {
  # Absolute path takes the `case /*` arm (line ~81) — a separate fix site.
  local vabs="$STUB/abs-validator.sh"
  _stage_validator_644 "$vabs"
  _stage_config "$vabs"

  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=merge"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Overall: MERGEABLE"* ]]
  [[ "$output" != *"validator missing"* ]]
  [ -f "$INVOKED_MARKER" ]
  [ "$(cat "$INVOKED_MARKER")" = "invoked" ]
}

@test "RED absolute-path: -x copy treats the 644 absolute validator as MISSING -> BLOCKED" {
  local vabs="$STUB/abs-validator.sh"
  _stage_validator_644 "$vabs"
  _stage_config "$vabs"
  RED="$(_make_red_copy)"

  run bash -c "cd '$PROJECT_DIR' && '$RED' --mode=merge"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
  [[ "$output" == *"validator missing"* ]]
  [ ! -f "$INVOKED_MARKER" ]
}

# --- BRIGHT LINE survives (DL-P7-04): a PRESENT validator that RUNS + FAILS
# still hard-fails. -f must not loosen a genuine failure to warn. -----------

@test "BRIGHT LINE: a 644 validator that RUNS and exits 1 still hard-fails (idx5 fail -> BLOCKED)" {
  local vabs="$STUB/abs-failing.sh"
  mkdir -p "$(dirname "$vabs")"
  cat > "$vabs" <<EOF
#!/usr/bin/env bash
printf 'invoked' > '$INVOKED_MARKER'
echo "stack validator says NO"
exit 1
EOF
  chmod 644 "$vabs"
  _stage_config "$vabs"

  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=merge"
  [ "$status" -eq 1 ]                                  # BLOCKED (genuine fail)
  [[ "$output" == *"Overall: BLOCKED"* ]]
  [[ "$output" != *"validator missing"* ]]             # it was FOUND, not missing
  [ -f "$INVOKED_MARKER" ]                             # and it actually RAN
}
