#!/usr/bin/env bats
# spec-gate resolves the default branch once per verdict (diff-base.sh memo),
# and the Stop early warning skips the diff range when the policy or the
# protected branch already decides a pass. Verdicts and pre-push receipts are
# unchanged.

load helpers

GATE="$HOOKS_DIR/spec-gate.sh"
CODEX_GATE="$CODEX_HOOKS_DIR/spec-gate.sh"
RESOLVER="$HOOKS_DIR/../skills/process-gate/scripts/lib/diff-base.sh"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  mkdir -p "$HOME"
  REPO_DIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO_DIR"
  REPO_DIR="$(cd "$REPO_DIR" && pwd -P)"
  cd "$REPO_DIR" || return 1
  git init -q -b main
  git config user.email t@t.t
  git config user.name t
  echo seed > README.md
  git add -A && git commit -qm init
  TRELLIS_FIXTURE="$BATS_TEST_TMPDIR/trellis"
  mkdir -p "$TRELLIS_FIXTURE/core-rules/presets" \
    "$TRELLIS_FIXTURE/core-rules/skills/process-gate/scripts/lib"
  cp "$RESOLVER" "$TRELLIS_FIXTURE/core-rules/skills/process-gate/scripts/lib/diff-base.sh"
  export TRELLIS_ROOT="$TRELLIS_FIXTURE"
  printf '{ "template": { "branch": "main" }, "mandatory_pipeline": { "enabled": true, "spec_required_diff_lines": 80, "surgical_max_diff_lines": 400 } }\n' \
    > "$TRELLIS_FIXTURE/trellis.config.json"
  # Count Git invocations through a logging shim; the real git runs them.
  SHIM="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$SHIM"
  export REAL_GIT GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  REAL_GIT="$(command -v git)"
  printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$GIT_LOG"' 'exec "$REAL_GIT" "$@"' > "$SHIM/git"
  chmod +x "$SHIM/git"
  # Deployed Codex layout: the shared core beside the Codex hook and its libs.
  CODEX_DEPLOY="$BATS_TEST_TMPDIR/codex-hooks"
  mkdir -p "$CODEX_DEPLOY/lib"
  cp "$CODEX_GATE" "$CODEX_DEPLOY/spec-gate.sh"
  cp "$HOOKS_DIR/lib/spec-gate-core.sh" "$CODEX_HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps-heavy.sh" \
    "$CODEX_HOOKS_DIR/lib/autonomy.sh" "$CODEX_DEPLOY/lib/"
}

big_branch() {
  git checkout -q -b feat/big
  local i
  for i in $(seq 1 120); do echo "const l$i = $i;"; done > src.js
  git add -A && git commit -qm big
}

# gate_counted <gate> [args] — run with the shim first on PATH and no cache.
gate_counted() {
  local gate="$1"; shift
  : > "$GIT_LOG"
  run env PATH="$SHIM:$PATH" bash "$gate" "$@" <<< '{}'
}
calls() { grep -c -- "$1" "$GIT_LOG" || true; }

@test "a Stop on the protected branch resolves the default branch once and skips the range" {
  local gate
  for gate in "$GATE" "$CODEX_DEPLOY/spec-gate.sh"; do
    gate_counted "$gate"
    [ "$status" -eq 0 ] || { echo "$gate: $output"; return 1; }
    [ "$(calls '^check-ref-format --branch')" -eq 1 ] || { echo "$gate"; cat "$GIT_LOG"; return 1; }
    [ "$(calls '^remote$')" -le 1 ]
    [ "$(calls '^merge-base')" -eq 0 ] || { echo "$gate: range resolved on a decided pass"; return 1; }
  done
}

@test "a blocking Stop resolves the default branch once and keeps its receipt" {
  big_branch
  local gate
  for gate in "$GATE" "$CODEX_DEPLOY/spec-gate.sh"; do
    gate_counted "$gate"
    # Claude blocks with exit 2; the Codex twin emits the same decision on exit 0.
    [[ "$output" == *'"decision":"block"'* ]] || { echo "$gate: $status $output"; return 1; }
    [[ "$output" == *"diff-base: "* ]] || { echo "$gate lost its receipt: $output"; return 1; }
    [[ "$output" == *"gated lines over floor"* ]] || false
    [ "$(calls '^check-ref-format --branch')" -eq 1 ] || { echo "$gate"; cat "$GIT_LOG"; return 1; }
  done
}

@test "the pre-push gate keeps the receipt on the protected branch" {
  gate_counted "$GATE" --gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"diff-base: "* ]] || { echo "$output"; return 1; }
  [ "$(calls '^check-ref-format --branch')" -eq 1 ] || { cat "$GIT_LOG"; return 1; }
}

@test "a disabled pipeline passes a Stop without resolving any branch" {
  big_branch
  local core="$HOOKS_DIR/lib/spec-gate-core.sh" disabled
  # Instrument every branch-resolver entry point instead of counting Git
  # commands: a no-remote fallback can resolve without either probe.
  for disabled in runtime project; do
    if [ "$disabled" = runtime ]; then
      printf '{ "mandatory_pipeline": { "enabled": false } }\n' > "$TRELLIS_FIXTURE/trellis.config.json"
    else
      printf '{ "mandatory_pipeline": { "enabled": false } }\n' > .trellis.json
    fi
    # Callers capture these functions' stdout, so each entry is logged to a file.
    : > "$BATS_TEST_TMPDIR/resolver-calls"
    run bash -c '. "$1"
      _sg_defbranch_memo() { echo memo >> "$2"; return 1; }
      sg_trusted_protected_branch() { echo protected >> "$2"; return 1; }
      _sg_resolve_diff_with_root() { echo range >> "$2"; return 1; }
      sg_verdict "$PWD" "" "" "" stop' x "$core" "$BATS_TEST_TMPDIR/resolver-calls"
    [ "$status" -eq 0 ] || { echo "$disabled: $output"; return 1; }
    [ "$output" = $'pass\tdisabled' ] || { echo "$disabled: $output"; return 1; }
    [ ! -s "$BATS_TEST_TMPDIR/resolver-calls" ] || { echo "$disabled resolved:"; cat "$BATS_TEST_TMPDIR/resolver-calls"; return 1; }
    rm -f .trellis.json
  done
  # The gate itself agrees end to end.
  gate_counted "$GATE"
  [ "$status" -eq 0 ]
}

@test "a memo applies only to its own checkout and policy override" {
  local other="$BATS_TEST_TMPDIR/other"
  git init -q -b trunk "$other"
  git -C "$other" -c user.name=t -c user.email=t@t.t commit -q --allow-empty -m init
  run bash -c '
    . "$1"
    db_defbranch; printf "fresh:%s:%s\n" "$?" "$_dd_ref"
    ( cd "$2" && db_defbranch; printf "fresh-other:%s:%s\n" "$?" "$_dd_ref" )
    memo=$(db_memo_print)
    IFS=$'"'"'\037'"'"' read -r _db_memo_key _db_memo_remote _db_memo_base_policy _db_memo_dd_rc \
      _db_memo_dd_ref _db_memo_dd_tip _db_memo_dd_reason <<< "$memo"
    _db_memo_rkey=$_db_memo_key; _db_memo_bkey=$_db_memo_key
    _db_memo_dd_ref=planted
    db_defbranch; printf "same:%s:%s\n" "$?" "$_dd_ref"
    DB_POLICY_OVERRIDE=trunk; db_defbranch; printf "override:%s:%s\n" "$?" "$_dd_ref"
    DB_POLICY_OVERRIDE=""; cd "$2" && db_defbranch; printf "other:%s:%s\n" "$?" "$_dd_ref"
  ' x "$RESOLVER" "$other"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local fresh fresh_other
  fresh=$(printf '%s\n' "$output" | sed -n 's/^fresh:0://p')
  fresh_other=$(printf '%s\n' "$output" | sed -n 's/^fresh-other://p')
  [ -n "$fresh" ] || { echo "$output"; return 1; }
  # The memo answers in its own checkout (the planted value proves no Git ran),
  printf '%s\n' "$output" | grep -qx 'same:0:planted' || { echo "$output"; return 1; }
  # but never under another policy override or in another checkout.
  ! printf '%s\n' "$output" | grep -q '^override:.*planted' || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx "other:$fresh_other" || { echo "$output"; return 1; }
}

@test "a memo inherited from the environment is never trusted" {
  # A direct resolver caller (pre-push) with a forged exported memo for this
  # checkout must resolve the real default branch.
  run env _db_memo_key="$REPO_DIR|" _db_memo_rkey="$REPO_DIR|" _db_memo_bkey="$REPO_DIR|" \
    _db_memo_dd_rc=0 _db_memo_dd_ref=refs/heads/forged _db_memo_dd_tip=0000000000000000000000000000000000000000 \
    _db_memo_dd_reason=forged _db_memo_remote="" _db_memo_base_policy="" \
    bash -c 'cd "$2" && . "$1" && db_defbranch; printf "%s\n" "$_dd_ref"' x "$RESOLVER" "$REPO_DIR"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *forged* ]] || { echo "$output"; return 1; }
  # The gate itself still decides from the real branch.
  run env _db_memo_key="$REPO_DIR|" _db_memo_dd_rc=0 _db_memo_dd_ref=refs/heads/forged bash "$GATE" --gate
  [[ "$output" != *forged* ]] || { echo "$output"; return 1; }
}

@test "a policy branch holding the memo separator or a newline yields no memo" {
  local value
  for value in 'main\u001f0\u001frefs/heads/forged' 'main\nforged'; do
    git checkout -q main
    printf '{ "template": { "branch": "%s" } }\n' "$value" > .trellis.json
    git add .trellis.json && git commit -qm "policy $value"
    run bash -c 'cd "$2" && . "$1" && db_memo_print' x "$RESOLVER" "$REPO_DIR"
    [ "$status" -ne 0 ] && [ -z "$output" ] || { echo "$value: $status $output"; return 1; }
  done
}
