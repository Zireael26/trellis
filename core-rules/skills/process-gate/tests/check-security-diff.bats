#!/usr/bin/env bats
# Tests for check-security-diff.sh — the adapter to security-gate/run-diff.sh.
#
# This is a thin adapter: its whole job is to locate run-diff.sh and pass its
# exit code through verbatim (0 pass / 2 warn / 1 fail) when the child printed
# the matching `Overall:` verdict; no verdict, or a disagreeing one, FAILs.
# SECURITY_GATE_SKIP=1 is never a pass: an unperformed scan reports BLOCKED in
# every mode. An unavailable gate FAILs. We stub run-diff.sh in the executing
# payload's sibling skill so passthrough can be exercised without real engines.
# Project-authored gates are planted only as hostile candidates. The stub echoes
# its argv so we can assert --no-llm is added iff
# PG_MODE=push.
#
# Exit codes: 0=pass, 1=fail, 2=warn (per pg_exit_code / run-diff contract).

setup() {
  # Isolate the adapter from the real sibling security-gate, so absence and
  # locator mutations cannot accidentally fall back to a host/payload scanner.
  SOURCE_SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts"
  ADAPTER="$BATS_TEST_TMPDIR/process-gate"
  mkdir -p "$ADAPTER/scripts/lib"
  cp "$SOURCE_SCRIPTS/check-security-diff.sh" "$ADAPTER/scripts/"
  cp "$SOURCE_SCRIPTS/lib/common.sh" "$SOURCE_SCRIPTS/lib/diff-base.sh" "$ADAPTER/scripts/lib/"
  # The payload's baseline-schema validator, without its run-diff.sh: the
  # adapter judges Baseline rows with it, and absence tests still find no gate.
  mkdir -p "$BATS_TEST_TMPDIR/security-gate/scripts/lib"
  cp "$SOURCE_SCRIPTS/../../security-gate/scripts/lib/baseline_state.py" \
    "$SOURCE_SCRIPTS/../../security-gate/scripts/lib/engine.sh" \
    "$SOURCE_SCRIPTS/../../security-gate/scripts/lib/osv.sh" "$BATS_TEST_TMPDIR/security-gate/scripts/lib/"
  VALIDATOR="$BATS_TEST_TMPDIR/security-gate/scripts/lib/baseline_state.py"
  SCRIPT="${PG_TEST_SCRIPT:-$ADAPTER/scripts/check-security-diff.sh}"
  PROJECT_DIR="$(mktemp -d)"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git commit --allow-empty -q -m "init"
    # run_check gates HEAD~1..HEAD; its base must resolve for config to load.
    git commit --allow-empty -q -m "change"
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  unset CODEX_PROJECT_DIR
  unset PG_MODE
  unset SECURITY_GATE_SKIP
}

teardown() {
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    rm -rf "$PROJECT_DIR"
  fi
}

# Default to the sibling payload; an explicit harness dir plants a hostile
# project candidate. A fourth argument overrides the verdict ("none" prints none).
stub_run_diff() {
  local rc="$1" dir="${2:-payload}" mode="${3:-755}" verdict="${4:-}"
  local baseline="${STUB_BASELINE_ROW-Baseline:          complete — 2026-01-01-baseline-project.json}"
  local d
  if [ "$dir" = payload ]; then d="$BATS_TEST_TMPDIR/security-gate/scripts"
  else d="$PROJECT_DIR/$dir/skills/security-gate/scripts"
  fi
  if [ -z "$verdict" ]; then
    case "$rc" in 0) verdict=MERGEABLE ;; 2) verdict="NEEDS CHANGES" ;; *) verdict=BLOCKED ;; esac
  fi
  local line="Overall: $verdict"
  [ "$verdict" != none ] || line=""
  mkdir -p "$d"
  cat > "$d/run-diff.sh" <<EOF
#!/usr/bin/env bash
echo "STUB-RUN-DIFF argv: \$*"
echo "$baseline"
echo "$line"
exit $rc
EOF
  chmod "$mode" "$d/run-diff.sh"
}

run_check() {
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
}

# Exercise the real gate with a baseline in the range base and a dependency
# change. Test scanners are external to the checkout and deterministic.
stage_real_gate() {
  local sg="$BATS_TEST_TMPDIR/security-gate/scripts" bin="$BATS_TEST_TMPDIR/scanner-bin"
  cp "$SOURCE_SCRIPTS/../../security-gate/scripts/run-diff.sh" "$sg/run-diff.sh"
  cp "$SOURCE_SCRIPTS/../../security-gate/scripts/lib/osv.sh" "$sg/lib/osv.sh"
  mkdir -p "$bin" "$PROJECT_DIR/audits" "$PROJECT_DIR/.tools"
  printf '%s\n' '{"findings":[]}' > "$PROJECT_DIR/audits/2026-01-01-baseline-project.json"
  git -C "$PROJECT_DIR" add audits
  git -C "$PROJECT_DIR" commit -qm baseline
  printf '%s\n' '{"name":"x"}' > "$PROJECT_DIR/package.json"
  git -C "$PROJECT_DIR" add package.json
  git -C "$PROJECT_DIR" commit -qm dependency
  cat > "$bin/gitleaks" <<'SH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = --report-path ]; then shift; printf '[]\n' > "$1"; fi
  shift
done
SH
  cat > "$bin/osv-scanner" <<'SH'
#!/bin/sh
echo 'No package sources found, --help for usage information.' >&2
exit 128
SH
  chmod +x "$bin/gitleaks" "$bin/osv-scanner"
  export PATH="$bin:$PATH" SECURITY_GATE_PROJECT_NAME=project SECURITY_GATE_STACK_PROFILE=web-next
}

@test "the real diff gate refuses a project-linked osv helper before execution" {
  stage_real_gate
  run_check
  [ "$status" -eq 1 ] && [[ "$output" == *"Deps:"*"fail"*"Overall: BLOCKED"* ]] \
    || { echo "control rc=$status; $output"; false; }
  printf ': > "%s"\n' "$BATS_TEST_TMPDIR/project-osv-ran" > "$PROJECT_DIR/.tools/osv.sh"
  mv "$BATS_TEST_TMPDIR/security-gate/scripts/lib/osv.sh" "$BATS_TEST_TMPDIR/safe-osv.sh"
  ln -s "$PROJECT_DIR/.tools/osv.sh" "$BATS_TEST_TMPDIR/security-gate/scripts/lib/osv.sh"
  run_check
  [ ! -e "$BATS_TEST_TMPDIR/project-osv-ran" ] || { echo "project osv ran; rc=$status; $output"; false; }
  [ "$status" -eq 1 ] && [[ "$output" == *"osv.sh"* ]] || { echo "rc=$status; $output"; false; }
}

@test "the real diff gate refuses a project-linked baseline validator before execution" {
  stage_real_gate
  printf 'open(%s, "w").write("ran")\nprint("bad state")\n' "'$BATS_TEST_TMPDIR/project-validator-ran'" > "$PROJECT_DIR/.tools/baseline_state.py"
  mv "$VALIDATOR" "$BATS_TEST_TMPDIR/safe-validator.py"
  ln -s "$PROJECT_DIR/.tools/baseline_state.py" "$VALIDATOR"
  run_check
  [ ! -e "$BATS_TEST_TMPDIR/project-validator-ran" ] || { echo "project validator ran; rc=$status; $output"; false; }
  [ "$status" -eq 1 ] && [[ "$output" == *"baseline_state.py"* ]] || { echo "rc=$status; $output"; false; }
}

@test "a linked real diff gate refuses the engine next to its resolved path" {
  stage_real_gate
  local alt="$BATS_TEST_TMPDIR/alternate/security-gate/scripts"
  mkdir -p "$alt/lib"
  cp "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh" "$alt/run-diff.sh"
  cp "$BATS_TEST_TMPDIR/security-gate/scripts/lib/"{osv.sh,baseline_state.py} "$alt/lib/"
  printf ': > "%s"\n' "$BATS_TEST_TMPDIR/project-engine-ran" > "$PROJECT_DIR/.tools/engine.sh"
  ln -s "$PROJECT_DIR/.tools/engine.sh" "$alt/lib/engine.sh"
  mv "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh" "$BATS_TEST_TMPDIR/safe-diff.sh"
  ln -s "$alt/run-diff.sh" "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh"
  run_check
  [ ! -e "$BATS_TEST_TMPDIR/project-engine-ran" ] || { echo "project engine ran; rc=$status; $output"; false; }
  [ "$status" -eq 1 ] && [[ "$output" == *"$alt/lib/engine.sh"* ]] || { echo "rc=$status; $output"; false; }
}

@test "the real diff gate refuses the adapter-relative diff-base when common is linked outside" {
  stage_real_gate
  local alt="$BATS_TEST_TMPDIR/alternate/lib"
  mkdir -p "$alt"
  cp "$ADAPTER/scripts/lib/common.sh" "$ADAPTER/scripts/lib/diff-base.sh" "$alt/"
  printf ': > "%s"\n' "$BATS_TEST_TMPDIR/project-diff-base-ran" > "$PROJECT_DIR/.tools/diff-base.sh"
  mv "$ADAPTER/scripts/lib/common.sh" "$BATS_TEST_TMPDIR/safe-common.sh"
  mv "$ADAPTER/scripts/lib/diff-base.sh" "$BATS_TEST_TMPDIR/safe-diff-base.sh"
  ln -s "$alt/common.sh" "$ADAPTER/scripts/lib/common.sh"
  ln -s "$PROJECT_DIR/.tools/diff-base.sh" "$ADAPTER/scripts/lib/diff-base.sh"
  run_check
  [ ! -e "$BATS_TEST_TMPDIR/project-diff-base-ran" ] || { echo "project diff-base ran; rc=$status; $output"; false; }
  [ "$status" -eq 1 ] && [[ "$output" == *"$ADAPTER/scripts/lib/diff-base.sh"* ]] || { echo "rc=$status; $output"; false; }
}

@test "a linked common helper refuses its own project-linked diff-base" {
  stage_real_gate
  local alt="$BATS_TEST_TMPDIR/alternate/lib"
  mkdir -p "$alt"
  cp "$ADAPTER/scripts/lib/common.sh" "$alt/common.sh"
  printf ': > "%s"\n' "$BATS_TEST_TMPDIR/project-diff-base-ran" > "$PROJECT_DIR/.tools/diff-base.sh"
  ln -s "$PROJECT_DIR/.tools/diff-base.sh" "$alt/diff-base.sh"
  mv "$ADAPTER/scripts/lib/common.sh" "$BATS_TEST_TMPDIR/safe-common.sh"
  ln -s "$alt/common.sh" "$ADAPTER/scripts/lib/common.sh"
  run bash -c 'cd "$1" && "$2" --base=main' _ "$PROJECT_DIR" "$SCRIPT"
  [ ! -e "$BATS_TEST_TMPDIR/project-diff-base-ran" ] || { echo "project diff-base ran; rc=$status; $output"; false; }
  [ "$status" -eq 1 ] && [[ "$output" == *"$alt/diff-base.sh"* ]] || { echo "rc=$status; $output"; false; }
}

@test "a linked real diff gate refuses a project-linked process-gate beside its resolved path" {
  # The gate's own diff-base resolver sits next to the RESOLVED gate, which is
  # not the adapter's skills dir here, so checking the lexical sibling misses it.
  stage_real_gate
  local alt="$BATS_TEST_TMPDIR/alternate"
  mkdir -p "$alt/security-gate" "$PROJECT_DIR/.tools/pg/scripts/lib"
  cp -R "$BATS_TEST_TMPDIR/security-gate/scripts" "$alt/security-gate/scripts"
  printf ': > "%s"\n' "$BATS_TEST_TMPDIR/project-diff-base-ran" > "$PROJECT_DIR/.tools/pg/scripts/lib/diff-base.sh"
  ln -s "$PROJECT_DIR/.tools/pg" "$alt/process-gate"
  mv "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh" "$BATS_TEST_TMPDIR/safe-diff.sh"
  ln -s "$alt/security-gate/scripts/run-diff.sh" "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh"
  run_check
  [ ! -e "$BATS_TEST_TMPDIR/project-diff-base-ran" ] || { echo "project diff-base ran; rc=$status; $output"; false; }
  [ "$status" -eq 1 ] && [[ "$output" == *"unsafe or missing process-gate payload helper"*"/alternate/process-gate/scripts/lib/diff-base.sh"* ]] \
    || { echo "rc=$status; $output"; false; }
}

@test "the payload manifest inventories source dot and interpreter targets" {
  local helper="$SOURCE_SCRIPTS/../tests/payload-inventory.py" copy="$BATS_TEST_TMPDIR/inventory-run-diff.sh" line
  local missed=0
  local -a args=("$SOURCE_SCRIPTS/check-security-diff.sh" "$copy"
    "$SOURCE_SCRIPTS/../../security-gate/scripts/lib/osv.sh"
    "$SOURCE_SCRIPTS/../../security-gate/scripts/lib/engine.sh"
    "$SOURCE_SCRIPTS/lib/common.sh" "$SOURCE_SCRIPTS/lib/diff-base.sh")
  cp "$SOURCE_SCRIPTS/../../security-gate/scripts/run-diff.sh" "$copy"
  run python3 -I "$helper" "${args[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # Each line loads a file the manifest does not name. The later entries are
  # spellings an earlier, line-anchored inventory let through.
  local -a fixtures=(
    'builtin source "$SKILL_DIR/scripts/lib/new-source.sh"'
    '. "$SKILL_DIR/scripts/lib/new-dot.sh"'
    '"$PYTHON3_BIN" -I "$SKILL_DIR/scripts/lib/new-parser.py"'
    '"$PYTHON3_BIN" "$SKILL_DIR/scripts/lib/new-unisolated.py"'
    '"$SG_BASH" -p "$SKILL_DIR/scripts/lib/new-wrapper.sh"'
    'bash "$SKILL_DIR/scripts/lib/new-direct.sh"'
    'exec "$SKILL_DIR/scripts/lib/new-exec.sh"'
    '"$SKILL_DIR/scripts/lib/new-script.sh"'
    'command source "$SKILL_DIR/scripts/lib/x.sh"'
    'if . "$SKILL_DIR/scripts/lib/x.sh"; then :; fi'
    'for x in a; do . "$SKILL_DIR/scripts/lib/x.sh"; done'
    '{ . "$SKILL_DIR/scripts/lib/x.sh"; }'
    'eval ". $SKILL_DIR/scripts/lib/x.sh"'
    'bash -c '"'"'. "$1"'"'"' _ "$SKILL_DIR/scripts/lib/x.sh"'
    '"$SG_BASH" -p -c '"'"'. "$1"'"'"' _ "$SKILL_DIR/scripts/lib/x.sh"'
    '"$PYTHON3_BIN" -I -c "exec(open('"'"'$SKILL_DIR/scripts/lib/x.py'"'"').read())"'
    '"$PYTHON3_BIN" -I - "$SKILL_DIR/scripts/lib/x.py" < /dev/null'
    '"$PYTHON3_BIN" -IB "$SKILL_DIR/scripts/lib/x.py"'
    '"$BASH" "$SKILL_DIR/scripts/lib/x.sh"'
    '"$SG_BASH" -pe "$SKILL_DIR/scripts/lib/x.sh"'
    $'echo "usage: x <<END"\n. "$SKILL_DIR/scripts/lib/hidden.sh"'
  )
  for line in "${fixtures[@]}"; do
    cp "$SOURCE_SCRIPTS/../../security-gate/scripts/run-diff.sh" "$copy"
    printf '\n%s\n' "$line" >> "$copy"
    run python3 -I "$helper" "${args[@]}"
    [ "$status" -ne 0 ] && [[ "$output" == *"unrecognized"* ]] || { echo "inventory missed: $line; $output"; missed=1; }
  done
  # An inline literal script that loads no file stays allowed.
  for line in \
    '"$PYTHON3_BIN" -I -c '"'"'import sys; print(sys.version)'"'"'' \
    $'"$PYTHON3_BIN" -I - "$WORK/data.json" <<\'PY\'\nimport json, sys\nprint(json.load(open(sys.argv[1])))\nPY'; do
    cp "$SOURCE_SCRIPTS/../../security-gate/scripts/run-diff.sh" "$copy"
    printf '\n%s\n' "$line" >> "$copy"
    run python3 -I "$helper" "${args[@]}"
    [ "$status" -eq 0 ] || { echo "inventory refused a literal inline script: $line; $output"; missed=1; }
  done
  [ "$missed" -eq 0 ]
}

# --- exit-code passthrough ---

@test "a missing payload never runs a project-authored gate from any fallback path" {
  local rel gate failures=0
  for rel in \
    .claude/skills/security-gate/scripts/run-diff.sh \
    .agents/skills/security-gate/scripts/run-diff.sh \
    core-rules/skills/security-gate/scripts/run-diff.sh; do
    gate="$PROJECT_DIR/$rel"
    mkdir -p "${gate%/*}"
    printf '#!/bin/sh\n: > "%s"\necho "Baseline:          complete — b.json"\necho "Overall: MERGEABLE"\nexit 0\n' \
      "$BATS_TEST_TMPDIR/project-gate-ran" > "$gate"
    run_check
    [ "$status" -eq 1 ] && [[ "$output" == *"security-gate payload"*"$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh"* ]] \
      && [ ! -e "$BATS_TEST_TMPDIR/project-gate-ran" ] \
      || { echo "$rel: rc=$status; $output"; failures=1; }
    mv "$gate" "$BATS_TEST_TMPDIR/previous-project-gate"
    if [ -e "$BATS_TEST_TMPDIR/project-gate-ran" ]; then
      mv "$BATS_TEST_TMPDIR/project-gate-ran" "$BATS_TEST_TMPDIR/previous-project-gate-marker"
    fi
  done
  [ "$failures" -eq 0 ]
}

@test "a sibling gate symlinked into the scanned project is refused" {
  local gate="$PROJECT_DIR/.tools/project-gate"
  mkdir -p "${gate%/*}"
  printf '#!/bin/sh\n: > "%s"\necho "Baseline:          complete — b.json"\necho "Overall: MERGEABLE"\n' \
    "$BATS_TEST_TMPDIR/project-gate-ran" > "$gate"
  ln -s "$gate" "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh"
  run_check
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"security-gate payload"* ]] || { echo "$output"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/project-gate-ran" ]
}

@test "a sibling gate cannot follow a project link back to an outside file" {
  local gate="$BATS_TEST_TMPDIR/trusted-gate"
  printf '#!/bin/sh\n: > "%s"\necho "Baseline:          complete — b.json"\necho "Overall: MERGEABLE"\n' \
    "$BATS_TEST_TMPDIR/gate-ran" > "$gate"
  mkdir -p "$PROJECT_DIR/.tools"
  ln -s "$gate" "$PROJECT_DIR/.tools/bounce"
  ln -s "$PROJECT_DIR/.tools/bounce" "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh"
  run_check
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/gate-ran" ]
  [[ "$output" == *"unsafe security-gate payload"* ]] || { echo "$output"; false; }
}

@test "a sibling gate symlink whose chain stays outside the project is accepted" {
  local scripts="$BATS_TEST_TMPDIR/trusted/security-gate/scripts" gate
  mkdir -p "$scripts/lib"
  cp "$BATS_TEST_TMPDIR/security-gate/scripts/lib/"{engine.sh,baseline_state.py,osv.sh} "$scripts/lib/"
  gate="$scripts/run-diff.sh"
  printf '#!/bin/sh\necho SAFE-LINKED-GATE\necho "Baseline:          complete — b.json"\necho "Overall: MERGEABLE"\n' > "$gate"
  ln -s "$gate" "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh"
  run_check
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"SAFE-LINKED-GATE"* ]] || { echo "$output"; false; }
}

@test "a sibling engine helper symlinked into the project is refused before sourcing" {
  local helper="$PROJECT_DIR/.tools/engine.sh"
  mkdir -p "${helper%/*}"
  printf ': > "%s"\n' "$BATS_TEST_TMPDIR/project-helper-ran" > "$helper"
  mv "$BATS_TEST_TMPDIR/security-gate/scripts/lib/engine.sh" "$BATS_TEST_TMPDIR/safe-engine.sh"
  ln -s "$helper" "$BATS_TEST_TMPDIR/security-gate/scripts/lib/engine.sh"
  mkdir -p "$BATS_TEST_TMPDIR/security-gate/scripts"
  printf '#!/bin/sh\necho "Baseline:          complete — b.json"\necho "Overall: MERGEABLE"\n' \
    > "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh"
  run_check
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/project-helper-ran" ] || { echo "project helper was sourced"; false; }
  [[ "$output" == *"security-gate payload"* ]] || { echo "$output"; false; }
}

@test "an adapter common helper symlinked into the project is refused before sourcing" {
  local helper="$PROJECT_DIR/.tools/common.sh"
  mkdir -p "${helper%/*}"
  printf ': > "%s"\n' "$BATS_TEST_TMPDIR/project-common-ran" > "$helper"
  mv "$ADAPTER/scripts/lib/common.sh" "$BATS_TEST_TMPDIR/safe-common.sh"
  ln -s "$helper" "$ADAPTER/scripts/lib/common.sh"
  stub_run_diff 0
  run_check
  [ ! -e "$BATS_TEST_TMPDIR/project-common-ran" ] || { echo "project common helper was sourced"; false; }
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"process-gate payload helper"*"common.sh"* ]] || { echo "$output"; false; }
}

@test "an adapter diff-base helper symlinked into the project is refused before sourcing" {
  local helper="$PROJECT_DIR/.tools/diff-base.sh"
  mkdir -p "${helper%/*}"
  printf ': > "%s"\n' "$BATS_TEST_TMPDIR/project-diff-base-ran" > "$helper"
  mv "$ADAPTER/scripts/lib/diff-base.sh" "$BATS_TEST_TMPDIR/safe-diff-base.sh"
  ln -s "$helper" "$ADAPTER/scripts/lib/diff-base.sh"
  stub_run_diff 0
  run bash -c 'cd "$1" && "$2" --base=main' _ "$PROJECT_DIR" "$SCRIPT"
  [ ! -e "$BATS_TEST_TMPDIR/project-diff-base-ran" ] || { echo "project diff-base helper was sourced"; false; }
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"process-gate payload helper"*"diff-base.sh"* ]] || { echo "$output"; false; }
}

@test "a sibling baseline validator symlinked into the project is refused before execution" {
  local validator="$PROJECT_DIR/.tools/baseline_state.py"
  mkdir -p "${validator%/*}"
  printf 'open(%s, "w").write("ran")\nprint("baseline-row: accepted")\n' \
    "'$BATS_TEST_TMPDIR/project-validator-ran'" > "$validator"
  mv "$BATS_TEST_TMPDIR/security-gate/scripts/lib/baseline_state.py" "$BATS_TEST_TMPDIR/safe-validator.py"
  ln -s "$validator" "$BATS_TEST_TMPDIR/security-gate/scripts/lib/baseline_state.py"
  printf '#!/bin/sh\necho "Baseline:          complete — b.json"\necho "Overall: MERGEABLE"\n' \
    > "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh"
  run_check
  [ ! -e "$BATS_TEST_TMPDIR/project-validator-ran" ] || { echo "project validator ran"; false; }
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"security-gate payload"* ]] || { echo "$output"; false; }
}

@test "the adapter refuses a git helper linked into the scanned project" {
  local linkbin="$BATS_TEST_TMPDIR/helper-bin" git_path
  git_path="$(command -v git)"
  mkdir -p "$linkbin" "$PROJECT_DIR/.tools"
  printf '#!/bin/sh\n: > "%s"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR/project-git-ran" "$git_path" \
    > "$PROJECT_DIR/.tools/git"
  chmod +x "$PROJECT_DIR/.tools/git"
  ln -s "$PROJECT_DIR/.tools/git" "$linkbin/git"
  printf '#!/bin/sh\necho "Baseline:          complete — b.json"\necho "Overall: MERGEABLE"\n' \
    > "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh"
  run env PATH="$linkbin:$PATH" bash -c 'cd "$1" && "$2" --range=HEAD~1..HEAD' _ "$PROJECT_DIR" "$SCRIPT"
  [ ! -e "$BATS_TEST_TMPDIR/project-git-ran" ] || { echo "project git ran"; false; }
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"git"*"$linkbin/git"* ]] || { echo "$output"; false; }
}

stage_source_checkout() {
  SOURCE_SKILLS="$PROJECT_DIR/core-rules/skills"
  mkdir -p "$SOURCE_SKILLS/process-gate/scripts/lib" "$SOURCE_SKILLS/security-gate/scripts/lib"
  cp "$SOURCE_SCRIPTS/check-security-diff.sh" "$SOURCE_SKILLS/process-gate/scripts/"
  cp "$SOURCE_SCRIPTS/lib/common.sh" "$SOURCE_SCRIPTS/lib/diff-base.sh" "$SOURCE_SKILLS/process-gate/scripts/lib/"
  cp "$BATS_TEST_TMPDIR/security-gate/scripts/lib/baseline_state.py" \
    "$BATS_TEST_TMPDIR/security-gate/scripts/lib/engine.sh" \
    "$BATS_TEST_TMPDIR/security-gate/scripts/lib/osv.sh" "$SOURCE_SKILLS/security-gate/scripts/lib/"
}

@test "the invoking Trellis source checkout may run its own sibling gate" {
  stage_source_checkout
  printf '#!/bin/sh\necho SOURCE-GATE\necho "Baseline:          complete — b.json"\necho "Overall: MERGEABLE"\n' \
    > "$SOURCE_SKILLS/security-gate/scripts/run-diff.sh"
  run env CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$SOURCE_SKILLS/process-gate/scripts/check-security-diff.sh" --range=HEAD~1..HEAD
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"SOURCE-GATE"* ]] || { echo "$output"; false; }
}

@test "a changed project identity after config loading fails before the gate" {
  local other="$BATS_TEST_TMPDIR/other-project"
  mkdir -p "$other"
  # Instrument the trusted helper: pg_load_config sees the real project, but
  # the later pg_project_dir call reports a different identity (review X5).
  cat >> "$ADAPTER/scripts/lib/common.sh" <<'SH'
pg_project_dir() {
  if [ -n "${PG_CONFIG_BASE:-}" ]; then printf '%s' "$PG_OTHER_PROJECT"
  else printf '%s' "$CLAUDE_PROJECT_DIR"; fi
}
SH
  printf '#!/bin/sh\n: > "%s"\necho "Baseline:          complete — b.json"\necho "Overall: MERGEABLE"\n' \
    "$BATS_TEST_TMPDIR/project-identity-gate-ran" > "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh"
  run env PG_OTHER_PROJECT="$other" bash -c 'cd "$1" && "$2" --range=HEAD~1..HEAD' _ "$PROJECT_DIR" "$SCRIPT"
  [ ! -e "$BATS_TEST_TMPDIR/project-identity-gate-ran" ] || { echo "gate ran despite identity change; $output"; false; }
  [ "$status" -eq 1 ] && [[ "$output" == *"project identity changed"* ]] || { echo "rc=$status; $output"; false; }
}

@test "a source-shaped tree without a git marker is not development mode" {
  stage_source_checkout
  mv "$PROJECT_DIR/.git" "$BATS_TEST_TMPDIR/saved-git-dir"
  printf '#!/bin/sh\n: > "%s"\necho "Baseline:          complete — b.json"\necho "Overall: MERGEABLE"\n' \
    "$BATS_TEST_TMPDIR/no-git-gate-ran" > "$SOURCE_SKILLS/security-gate/scripts/run-diff.sh"
  run env CLAUDE_PROJECT_DIR="$PROJECT_DIR" GIT_DIR="$BATS_TEST_TMPDIR/saved-git-dir" GIT_WORK_TREE="$PROJECT_DIR" \
    bash "$SOURCE_SKILLS/process-gate/scripts/check-security-diff.sh" --range=HEAD~1..HEAD
  [ ! -e "$BATS_TEST_TMPDIR/no-git-gate-ran" ] || { echo "source gate ran without a git marker; $output"; false; }
  [ "$status" -eq 1 ] && [[ "$output" == *"unsafe security-gate payload"* ]] || { echo "rc=$status; $output"; false; }
}

@test "source development cannot redirect its sibling gate to other project code" {
  stage_source_checkout
  mkdir -p "$PROJECT_DIR/.tools"
  printf '#!/bin/sh\n: > "%s"\necho "Baseline:          complete — b.json"\necho "Overall: MERGEABLE"\n' \
    "$BATS_TEST_TMPDIR/project-gate-ran" > "$PROJECT_DIR/.tools/project-gate"
  ln -s "$PROJECT_DIR/.tools/project-gate" "$SOURCE_SKILLS/security-gate/scripts/run-diff.sh"
  run env CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$SOURCE_SKILLS/process-gate/scripts/check-security-diff.sh" --range=HEAD~1..HEAD
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/project-gate-ran" ] || { echo "project gate ran"; false; }
  [[ "$output" == *"unsafe security-gate payload"* ]] || { echo "$output"; false; }
}

@test "passthrough: run-diff rc 0 -> pass (exit 0)" {
  stub_run_diff 0
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUB-RUN-DIFF"* ]]
}

@test "passthrough: run-diff rc 2 -> warn (exit 2)" {
  stub_run_diff 2
  run_check
  [ "$status" -eq 2 ]
  [[ "$output" == *"STUB-RUN-DIFF"* ]]
}

@test "passthrough: run-diff rc 1 -> fail (exit 1) and output echoed" {
  stub_run_diff 1
  run_check
  [ "$status" -eq 1 ]
  # Critical: a fail must still echo run-diff's output (set -e must not have
  # swallowed it on the non-zero capture).
  [[ "$output" == *"STUB-RUN-DIFF"* ]]
}

# --- fail closed when absent (adapter has no sibling payload in this fixture) ---

@test "missing security-gate payload fails and names the path" {
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"security-gate payload unavailable"*"$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh"* ]]
  [[ "$output" != *"skipped"* ]]
}

# --- HIGH-1/HIGH-3 regression: located-but-non-executable run-diff.sh ---
#
# A present-but-mode-644 run-diff.sh is the steady state after a fresh clone /
# tarball / mirror-sync that does not preserve the exec bit (cp without -p,
# archive extraction, core.fileMode=false). The location test MUST be -f (a
# regular file), not -x (executable). With -f the located 644 script is invoked
# via `bash` and its REAL rc (here: 1, a Critical secret found) flows through —
# the gate stays hard. With the pre-fix -x test the 644 file fails the predicate,
# RUNDIFF stays empty, and the script warn-skips (rc 2, "security-gate not
# installed") — fail-OPEN: a Critical secret in the diff slips the merge gate.
#
# The invocation marker distinguishes a real security FAIL from a missing-gate
# FAIL. The locator mutation below proves -x loses that marker; absence must
# still fail closed, never restore the old warn-skip.
@test "located run-diff.sh present but non-executable (644) is still invoked (real rc passes through), not warn-skipped" {
  # Narrative fidelity: stage a file carrying a fake secret in the diff. The
  # stub ignores argv content — rc 1 IS the simulated Critical finding — but a
  # real diff makes the fail-OPEN scenario concrete.
  ( cd "$PROJECT_DIR" \
    && printf 'aws_secret_access_key = AKIAIOSFODNN7EXAMPLE\n' > leak.env \
    && git add leak.env \
    && git -c user.email=test@example.com -c user.name=test commit -q -m "add secret" )

  stub_run_diff 1 payload 644   # located, mode 644 (NOT executable), returns FAIL
  [ ! -x "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh" ]

  run_check
  [ "$status" -eq 1 ]                                  # the gate's own rc, passed through
  [[ "$output" == *"STUB-RUN-DIFF"* ]] || { echo "$output"; false; }  # the 644 script was actually invoked
  [[ "$output" != *"not installed"* ]] || { echo "$output"; false; }  # NOT downgraded to a warn-skip
  [[ "$output" != *"skipped"* ]]
}

# --- SECURITY_GATE_SKIP ---

@test "push mode SECURITY_GATE_SKIP=1 -> BLOCKED (exit 1), never a pass" {
  stub_run_diff 0
  run bash -c "cd '$PROJECT_DIR' && PG_MODE=push SECURITY_GATE_SKIP=1 '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" != *"STUB-RUN-DIFF"* ]]
}

@test "merge mode SECURITY_GATE_SKIP=1 -> BLOCKED (exit 1), run-diff not invoked" {
  stub_run_diff 0
  run bash -c "cd '$PROJECT_DIR' && PG_MODE=merge SECURITY_GATE_SKIP=1 '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" != *"STUB-RUN-DIFF"* ]]
}

@test "SECURITY_GATE_SKIP=1 with PG_MODE unset is merge mode -> BLOCKED" {
  stub_run_diff 0
  run bash -c "cd '$PROJECT_DIR' && SECURITY_GATE_SKIP=1 '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
}

# --- a verdict is required, not just an exit code ---

@test "run-diff rc 0 without an Overall line fails (push mode)" {
  stub_run_diff 0 payload 755 none
  run bash -c "cd '$PROJECT_DIR' && PG_MODE=push '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"without an Overall verdict"* ]] || { echo "$output"; false; }
}

@test "run-diff rc 0 without an Overall line fails (merge mode)" {
  stub_run_diff 0 payload 755 none
  run bash -c "cd '$PROJECT_DIR' && PG_MODE=merge '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "a silent payload run-diff fails" {
  stub_run_diff 0 payload 755 none
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "run-diff rc 0 with Overall: BLOCKED fails" {
  stub_run_diff 0 payload 755 BLOCKED
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"reported Overall: BLOCKED"* ]] || { echo "$output"; false; }
}

@test "mismatched NEEDS CHANGES and MERGEABLE verdicts fail closed" {
  stub_run_diff 0 payload 755 'NEEDS CHANGES'
  run_check
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"reported Overall: NEEDS CHANGES"* ]] || { echo "$output"; false; }
  stub_run_diff 2 payload 755 MERGEABLE
  run_check
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"reported Overall: MERGEABLE"* ]] || { echo "$output"; false; }
}

# --- baseline completeness (review R3/F2) ---
# Inversion: the adapter passed any matching MERGEABLE/0 pair, so a gate that
# rested its verdict on an incomplete baseline, or never said, passed the row.

@test "a passing verdict over an incomplete baseline fails" {
  STUB_BASELINE_ROW='Baseline:          ❌ incomplete (semgrep failed) — b.json' stub_run_diff 0
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"without exactly one complete Baseline row"* ]] || { echo "$output"; false; }
  STUB_BASELINE_ROW='Baseline:          ❌ incomplete (semgrep failed) — b.json' stub_run_diff 2
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "a passing verdict with two Baseline rows fails even when the first is complete" {
  STUB_BASELINE_ROW=$'Baseline:          complete — b.json\nBaseline:          ❌ incomplete (semgrep failed) — b.json' stub_run_diff 0
  run_check
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"without exactly one complete Baseline row"* ]] || { echo "$output"; false; }
}

@test "a passing verdict that names no baseline completeness fails" {
  STUB_BASELINE_ROW='' stub_run_diff 0
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"without exactly one complete Baseline row"* ]] || { echo "$output"; false; }
}

@test "a pre-1.4.2 baseline of unknown completeness passes through as before" {
  STUB_BASELINE_ROW='Baseline:          baseline completeness unknown (pre-1.4.2 baseline) — b.json' stub_run_diff 2
  run_check
  [ "$status" -eq 2 ] || { echo "$output"; false; }
}

@test "without the shared baseline validator a passing verdict fails closed" {
  rm "$BATS_TEST_TMPDIR/security-gate/scripts/lib/baseline_state.py"
  stub_run_diff 0
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"baseline validator"* ]] || { echo "$output"; false; }
}

# A python3 the checkout controls, which would accept any row.
hostile_python() {
  mkdir -p "$PROJECT_DIR/.tools"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s"\necho "baseline-row: accepted"\nexit 0\n' \
    "$BATS_TEST_TMPDIR/hostile-python-ran" > "$PROJECT_DIR/.tools/python3"
  chmod +x "$PROJECT_DIR/.tools/python3"
}

@test "the row check never runs a python3 from the scanned project" {
  # Inversion (review r3 Sol N2 / Astra R3-F2): the adapter ran bare python3
  # from PATH, so a project .tools/python3 accepted an incomplete row.
  hostile_python
  STUB_BASELINE_ROW='Baseline:          ❌ incomplete (semgrep failed) — b.json' stub_run_diff 0
  run bash -c "cd '$PROJECT_DIR' && PATH='$PROJECT_DIR/.tools':\"\$PATH\" '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/hostile-python-ran" ] || { echo "project python3 ran: $(cat "$BATS_TEST_TMPDIR/hostile-python-ran")"; false; }

  # The trusted interpreter still accepts a complete row past the project entry.
  stub_run_diff 0
  run bash -c "cd '$PROJECT_DIR' && PATH='$PROJECT_DIR/.tools':\"\$PATH\" '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/hostile-python-ran" ]

  # A symlink outside the project that resolves into it is refused too.
  mkdir -p "$BATS_TEST_TMPDIR/linkbin"
  ln -s "$PROJECT_DIR/.tools/python3" "$BATS_TEST_TMPDIR/linkbin/python3"
  run bash -c "cd '$PROJECT_DIR' && PATH='$BATS_TEST_TMPDIR/linkbin':\"\$PATH\" '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"refusing python3 at $BATS_TEST_TMPDIR/linkbin/python3"* ]] || { echo "$output"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/hostile-python-ran" ]
}

@test "a python3 shim on PATH cannot let project state pick the row checker" {
  # Inversion (review r4 Sol R4-N1): the adapter ran the vetted shim itself.
  # Its `#!/usr/bin/env bash` found the project's .tools/bash, and a pyenv-like
  # shim took the project's .python-version; either accepted any row.
  local real shims="$BATS_TEST_TMPDIR/shims" versions="$BATS_TEST_TMPDIR/pyenv/versions"
  real="$(python3 -I -c 'import os, sys; print(os.path.realpath(sys.executable))')"
  mkdir -p "$shims" "$versions/hostile/bin" "$PROJECT_DIR/.tools"
  printf '#!/bin/sh\n: > "%s"\necho "baseline-row: accepted"\nexit 0\n' "$BATS_TEST_TMPDIR/hostile-version-ran" \
    > "$versions/hostile/bin/python3"
  printf '#!/bin/sh\n: > "%s"\necho "baseline-row: accepted"\nexit 0\n' "$BATS_TEST_TMPDIR/project-bash-ran" \
    > "$PROJECT_DIR/.tools/bash"
  cat > "$shims/python3" <<SH
#!/usr/bin/env bash
version="\${PYENV_VERSION:-}"
[ -n "\$version" ] || [ ! -f .python-version ] || version="\$(cat .python-version)"
[ -z "\$version" ] || exec "$versions/\$version/bin/python3" "\$@"
exec "$real" "\$@"
SH
  chmod +x "$shims/python3" "$versions/hostile/bin/python3" "$PROJECT_DIR/.tools/bash"
  printf 'hostile\n' > "$PROJECT_DIR/.python-version"

  STUB_BASELINE_ROW='Baseline:          ❌ incomplete (semgrep failed) — b.json' stub_run_diff 0
  # run-all launches the adapter with an absolute bash; so does this.
  run bash -c "cd '$PROJECT_DIR' && PATH='$PROJECT_DIR/.tools:$shims':\"\$PATH\" '$BASH' '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/project-bash-ran" ] || { echo "project bash ran"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/hostile-version-ran" ] || { echo "project-chosen interpreter ran"; false; }

  # The real interpreter behind the shim still accepts a complete row.
  stub_run_diff 0
  run bash -c "cd '$PROJECT_DIR' && PYENV_VERSION=hostile PATH='$PROJECT_DIR/.tools:$shims':\"\$PATH\" '$BASH' '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/project-bash-ran" ] && [ ! -e "$BATS_TEST_TMPDIR/hostile-version-ran" ]
}

@test "an empty or silent validator never passes a row" {
  # Inversion (review r3 Astra R3-F3): exit 0 from a zero-byte validator was
  # read as an accepted row.
  STUB_BASELINE_ROW='Baseline:          ❌ incomplete (semgrep failed) — b.json' stub_run_diff 0
  : > "$VALIDATOR"
  run_check
  [ "$status" -eq 1 ] || { echo "empty: $output"; false; }
  printf 'import sys\nsys.exit(0)\n' > "$VALIDATOR"
  run_check
  [ "$status" -eq 1 ] || { echo "early exit: $output"; false; }
}

@test "a BLOCKED verdict passes through whatever its baseline row" {
  STUB_BASELINE_ROW='' stub_run_diff 1
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" != *"Baseline row"* ]] || { echo "$output"; false; }
}

@test "two Overall lines are not one verdict and fail" {
  local d="$BATS_TEST_TMPDIR/security-gate/scripts"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho "Overall: BLOCKED"\necho "Overall: MERGEABLE"\nexit 0\n' > "$d/run-diff.sh"
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "an exported set function cannot forge the adapter's pass" {
  stub_run_diff 1
  run env 'BASH_FUNC_set%%=() { printf "\nOverall: MERGEABLE\n"; exit 0; }' \
    bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"STUB-RUN-DIFF"* ]] || { echo "$output"; false; }
}

@test "an exported printf function cannot intercept the adapter" {
  run env 'BASH_FUNC_printf%%=() { builtin printf imported; }' bash -c 'printf x'
  [ "$status" -eq 0 ] && [ "$output" = imported ] || skip "Bash does not import BASH_FUNC_name%%"
  stub_run_diff 0
  run env PURGE_MARK="$BATS_TEST_TMPDIR/printf-ran" \
    'BASH_FUNC_printf%%=() { : > "$PURGE_MARK"; builtin printf "$@"; }' \
    bash -c 'cd "$1" && "$2" --range=HEAD~1..HEAD' _ "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/printf-ran" ] || { echo "exported printf ran"; false; }
}

@test "a symlinked adapter file uses its real payload, not a project source lookalike" {
  stage_source_checkout
  local adapter="$SOURCE_SKILLS/process-gate/scripts/check-security-diff.sh"
  mv "$adapter" "$BATS_TEST_TMPDIR/source-adapter-copy"
  ln -s "$ADAPTER/scripts/check-security-diff.sh" "$adapter"
  printf '#!/bin/sh\n: > "%s"\necho PROJECT-SOURCE-IMPOSTOR\necho "Baseline:          complete — b.json"\necho "Overall: MERGEABLE"\n' \
    "$BATS_TEST_TMPDIR/impostor-gate-ran" > "$SOURCE_SKILLS/security-gate/scripts/run-diff.sh"
  printf '#!/bin/sh\necho REAL-PAYLOAD\necho "Baseline:          complete — b.json"\necho "Overall: MERGEABLE"\n' \
    > "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh"
  run env CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$adapter" --range=HEAD~1..HEAD
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"REAL-PAYLOAD"* && "$output" != *"PROJECT-SOURCE-IMPOSTOR"* ]] || { echo "$output"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/impostor-gate-ran" ]
}

@test "a symlinked adapter refuses a system readlink inside the scanned project" {
  [ -x /usr/bin/readlink ] || skip "system readlink is unavailable"
  local adapter="$BATS_TEST_TMPDIR/adapter-link"
  ln -s "$ADAPTER/scripts/check-security-diff.sh" "$adapter"
  run env CLAUDE_PROJECT_DIR=/usr bash "$adapter" --range=HEAD~1..HEAD
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"unsafe readlink helper at /usr/bin/readlink"* ]] || { echo "$output"; false; }
}

@test "a symlinked process-gate skill resolves its executing payload sibling" {
  local skills="$PROJECT_DIR/.claude/skills"
  mkdir -p "$skills"
  ln -s "$ADAPTER" "$skills/process-gate"
  stub_run_diff 0 .claude
  printf '#!/bin/sh\necho LINKED-PAYLOAD\necho "Baseline:          complete — b.json"\necho "Overall: MERGEABLE"\n' \
    > "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh"
  run env CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$skills/process-gate/scripts/check-security-diff.sh" --range=HEAD~1..HEAD
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"LINKED-PAYLOAD"* && "$output" != *"STUB-RUN-DIFF"* ]] || { echo "$output"; false; }
}

@test "the executing payload wins over a project-authored gate" {
  stub_run_diff 0 .claude
  mkdir -p "$BATS_TEST_TMPDIR/security-gate/scripts"
  printf '#!/bin/bash\necho PAYLOAD-GATE\necho "Overall: BLOCKED"\nexit 1\n' \
    > "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh"
  run_check
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"PAYLOAD-GATE"* ]] || { echo "$output"; false; }
  [[ "$output" != *"STUB-RUN-DIFF"* ]] || { echo "$output"; false; }
}

# Project gates never substitute for a missing sibling payload. The source
# checkout control above invokes the source adapter itself, not a project lookup.
@test "a project .agents gate is refused when the payload is absent" {
  stub_run_diff 0 ".agents"
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"security-gate payload unavailable"* ]]
  [[ "$output" != *"STUB-RUN-DIFF"* ]]
}

@test "a project in-tree gate is refused when the payload is absent" {
  local d="$PROJECT_DIR/core-rules/skills/security-gate/scripts"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho "STUB-CORE-RULES argv: $*"\necho "Baseline:          complete — b.json"\necho "Overall: MERGEABLE"\nexit 0\n' > "$d/run-diff.sh"
  chmod 755 "$d/run-diff.sh"
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"security-gate payload unavailable"* ]]
  [[ "$output" != *"STUB-CORE-RULES"* ]]
}

@test "neither .claude nor an in-tree project gate may replace an absent payload" {
  stub_run_diff 0 ".claude"
  local d="$PROJECT_DIR/core-rules/skills/security-gate/scripts"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho "STUB-CORE-RULES argv: $*"\necho "Overall: BLOCKED"\nexit 1\n' > "$d/run-diff.sh"
  chmod 755 "$d/run-diff.sh"
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"security-gate payload unavailable"* ]]
  [[ "$output" != *"STUB-RUN-DIFF"* && "$output" != *"STUB-CORE-RULES"* ]]
}

# --- --no-llm keyed on PG_MODE ---

@test "PG_MODE=push -> --no-llm passed to run-diff" {
  stub_run_diff 0
  run bash -c "cd '$PROJECT_DIR' && PG_MODE=push '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-llm"* ]]
}

@test "PG_MODE=merge (or unset) -> --no-llm NOT passed" {
  stub_run_diff 0
  run bash -c "cd '$PROJECT_DIR' && PG_MODE=merge '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--no-llm"* ]]
}

@test "the adapter forwards merge mode and the exact requested range" {
  stub_run_diff 0
  run bash -c 'cd "$1" && PG_MODE=merge "$2" --range=HEAD~1..HEAD' _ "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"--range=HEAD~1..HEAD"* ]] || { echo "$output"; false; }
  [[ "$output" == *"--mode=merge"* ]] || { echo "$output"; false; }
}

@test "the adapter forwards the main-target flag on push" {
  stub_run_diff 0
  run bash -c 'cd "$1" && PG_MODE=push "$2" --range=HEAD~1..HEAD --target=main' _ "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"--target=main"* ]] || { echo "$output"; false; }
}

# Locator mutation: the 644 positive control loses its invocation under -x.
# Even this rejected candidate must now FAIL, not restore the old warn-skip.
@test "RED driver: -x locator rejects the 644 file but missing gate now fails closed" {
  # 1) Copy the WHOLE scripts/ tree (check-security-diff.sh + lib/common.sh + the
  #    rest) into a fresh mktemp -d so the copy's SKILL_DIR/lib/common.sh source
  #    resolves. A bare single-file copy would crash command-not-found at the
  #    `. "$SKILL_DIR/scripts/lib/common.sh"` line instead of exercising the
  #    -x/-f locator we are testing.
  local SRC COPY GATE
  SRC="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts"
  COPY="$(mktemp -d "$BATS_TEST_TMPDIR/adapter-copy.XXXXXX")"
  cp -R "$SRC" "$COPY/"                 # -> $COPY/scripts/{check-security-diff.sh,lib/common.sh,...}
  GATE="$COPY/scripts/check-security-diff.sh"

  # 2) sed-flip the located-run-diff predicate in the COPY back to the pre-fix -x.
  #    Single-quote the program so the bats shell does not expand $cand to empty;
  #    write to a temp then mv (in-place -i is non-portable across BSD/GNU sed).
  sed 's/-f "$RUNDIFF"/-x "$RUNDIFF"/' "$GATE" > "$GATE.tmp" && mv "$GATE.tmp" "$GATE"
  # The rewrite drops the exec bit (umask on the temp + mv); run_check execs
  # $SCRIPT directly (not via bash), so restore it or we'd see status 126.
  chmod +x "$GATE"
  # grep-confirm the substitution actually hit (a sed miss should fail loudly
  # HERE, not as a confusing assertion failure later). -F -- guards the dash.
  grep -qF -- '-x "$RUNDIFF"' "$GATE"
  # Use -F (fixed string): without it the leading `-f`-as-flag is dodged by `--`
  # but `$` is a regex end-anchor, so a plain `grep -c` would report 0 even when
  # the predicate is PRESENT — a tautological guard. -F makes this a real check.
  [[ "$(grep -cF -- '-f "$RUNDIFF"' "$GATE")" -eq 0 ]] || { grep -nF -- '-f "$RUNDIFF"' "$GATE"; false; }  # the -f predicate is gone

  # 3) Point the harness at the copy. PG_TEST_SCRIPT makes the comment-promised
  #    plumbing real for any child; SCRIPT is the lever run_check actually reads
  #    (setup() already ran, so the export alone cannot re-derive SCRIPT).
  export PG_TEST_SCRIPT="$GATE"
  SCRIPT="$PG_TEST_SCRIPT"

  # 4) The same 644 run-diff scenario as the green invocation control.
  ( cd "$PROJECT_DIR" \
    && printf 'aws_secret_access_key = AKIAIOSFODNN7EXAMPLE\n' > leak.env \
    && git add leak.env \
    && git -c user.email=test@example.com -c user.name=test commit -q -m "add secret" )

  stub_run_diff 1 payload 644   # located, mode 644 (NOT executable), would FAIL if invoked
  [ ! -x "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh" ]

  run_check

  # The locator mutation loses the scan, but cannot reopen a warn-skip path.
  [ "$status" -eq 1 ]
  [[ "$output" == *"security-gate payload unavailable"* ]]
  [[ "$output" != *"skipped"* ]]
  [[ "$output" != *"STUB-RUN-DIFF"* ]]

  # Glob-free cleanup on a verified-nonempty full path (mirrors teardown; never a
  # glob on a possibly-empty var, which would trip the rm safety prompt).
  [ -n "${COPY:-}" ] && [ -d "$COPY" ] && rm -rf "$COPY"
}
