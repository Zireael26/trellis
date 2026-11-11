#!/usr/bin/env bats

load helpers
bats_require_minimum_version 1.5.0

CORE="$HOOKS_DIR/lib/ui-verify-core.sh"
CANONICAL_HOOK="$HOOKS_DIR/ui-verify.sh"
CODEX_HOOK="$CODEX_HOOKS_DIR/ui-verify.sh"

setup() {
  PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR"
  git -C "$PROJECT_DIR" init -q
  printf '%s\n' 'export const View = () => null;' > "$PROJECT_DIR/view.tsx"
  git -C "$PROJECT_DIR" add view.tsx
  git -C "$PROJECT_DIR" -c user.name=test -c user.email=test@example.com commit -q -m init
  printf '%s\n' '// changed' >> "$PROJECT_DIR/view.tsx"
}

run_core() {
  local stderr_file="$BATS_TEST_TMPDIR/core.stderr"
  if output="$(env "$@" /bin/bash "$CORE" "$PROJECT_DIR" 2>"$stderr_file")"; then
    status=0
  else
    status=$?
  fi
  stderr="$(cat "$stderr_file")"
}

json_field() {
  printf '%s' "$output" | jq -r "$1"
}

make_path_without_perl() {
  local out="$BATS_TEST_TMPDIR/no-perl-bin" cmd source
  mkdir -p "$out"
  for cmd in git grep sort awk head jq sed tr; do
    source="$(command -v "$cmd")"
    ln -sf "$source" "$out/$cmd"
  done
  cat > "$out/npx" <<'SH'
#!/bin/sh
: > "$PROBE_MARKER"
exit 0
SH
  chmod +x "$out/npx"
  printf '%s' "$out"
}

make_failing_git_path() {
  local out="$BATS_TEST_TMPDIR/failing-git-bin" cmd source real_git
  mkdir -p "$out"
  real_git="$(command -v git)"
  for cmd in grep sort awk head jq sed tr perl; do
    source="$(command -v "$cmd")"
    ln -sf "$source" "$out/$cmd"
  done
  cat > "$out/git" <<SH
#!/bin/sh
if [ "\${1:-}" = "diff" ]; then
  exit 73
fi
exec "$real_git" "\$@"
SH
  chmod +x "$out/git"
  printf '%s' "$out"
}

deploy_wrapper() {
  local harness="$1" wrapper="$2" deps="$3" deploy
  deploy="$BATS_TEST_TMPDIR/$harness/hooks"
  mkdir -p "$deploy/lib"
  cp "$wrapper" "$deploy/ui-verify.sh"
  cp "$deps" "$deploy/lib/deps.sh"
  cp "$CORE" "$deploy/lib/ui-verify-core.sh"
  printf '%s' "$deploy/ui-verify.sh"
}

run_wrapper() {
  local hook="$1" tool_path="$2" stderr_file="$BATS_TEST_TMPDIR/wrapper.stderr"
  shift 2
  if output="$(printf '%s' '{}' | env PATH="$tool_path:$PATH" CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
    UI_SHOT_CMD=/usr/bin/true UI_VERIFY_TIMEOUT=2 "$@" /bin/bash "$hook" 2>"$stderr_file")"; then
    status=0
  else
    status=$?
  fi
  stderr="$(cat "$stderr_file")"
}

@test "T27 R1: only Boolean true suppresses active UI verification on both twins" {
  local harness hook input bin="$BATS_TEST_TMPDIR/strict-ui-tools"
  mkdir -p "$bin"
  cat > "$bin/curl" <<'STRICT_UI'
#!/bin/sh
printf 'probe\n' >> "$PROBE_MARKER"
exit 0
STRICT_UI
  chmod +x "$bin/curl"
  for harness in claude codex; do
    if [ "$harness" = claude ]; then hook=$(deploy_wrapper "$harness" "$CANONICAL_HOOK" "$HOOKS_DIR/lib/deps.sh");
    else hook=$(deploy_wrapper "$harness" "$CODEX_HOOK" "$CODEX_HOOKS_DIR/lib/deps.sh"); fi
    export PROBE_MARKER="$BATS_TEST_TMPDIR/probe-$harness"
    run --separate-stderr env PATH="$bin:$PATH" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CODEX_PROJECT_DIR="$PROJECT_DIR" \
      UI_SHOT_CMD=/usr/bin/true UI_VERIFY_TIMEOUT=10 bash "$hook" <<< '{"stop_hook_active":true}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$PROBE_MARKER" ]
    for input in '{"stop_hook_active":"true"}' '{"stop_hook_active":"true\u0000\n"}'; do
      run --separate-stderr env PATH="$bin:$PATH" CLAUDE_PROJECT_DIR="$PROJECT_DIR" CODEX_PROJECT_DIR="$PROJECT_DIR" \
        UI_SHOT_CMD=/usr/bin/true UI_VERIFY_TIMEOUT=10 bash "$hook" <<< "$input"
      if [ "$harness" = claude ]; then [ "$status" -eq 2 ]; else [ "$status" -eq 0 ]; fi
      printf '%s' "$output" | jq -e '.decision == "block" and (.reason | contains("screenshot produced no artifact"))' >/dev/null
      [ -e "$PROBE_MARKER" ]
    done
  done
}

@test "R2 M2: many changed paths use a bounded number of grep processes" {
  local bin="$BATS_TEST_TMPDIR/grep-bin" trace="$BATS_TEST_TMPDIR/grep-trace" real_grep i
  mkdir -p "$bin" "$PROJECT_DIR/many"
  real_grep="$(command -v grep)"
  cat > "$bin/grep" <<'EOF'
#!/bin/sh
printf x >> "$GREP_TRACE"
exec "$REAL_GREP" "$@"
EOF
  chmod +x "$bin/grep"
  git -C "$PROJECT_DIR" checkout -- view.tsx
  for ((i=0; i<250; i++)); do printf 'ordinary\n' > "$PROJECT_DIR/many/file-$i.txt"; done
  : > "$trace"
  run_core PATH="$bin:$PATH" GREP_TRACE="$trace" REAL_GREP="$real_grep"
  [ "$status" -eq 0 ]
  [ "$(json_field '.verdict')" = skip ]
  [ "$(wc -c < "$trace" | tr -d ' ')" -le 3 ]
}

_r2_l3_load_deps() {
  # Source each twin in its own test; the functions use the same storage wire format.
  # shellcheck disable=SC1090
  . "$1"
  R2_NOW=1700000000
  date() { printf '%s\n' "$R2_NOW"; }
  R2_FP="$(printf '%040d' 0) $(printf '%064d' 0)"
  R2_FILE="$BATS_TEST_TMPDIR/ui.$2"
}

_r2_l3_count_cap() {
  local deps="$1" harness="$2" i nonce
  _r2_l3_load_deps "$deps" "$harness"
  for ((i=1; i<=65; i++)); do
    nonce=$(printf '%032x' "$i")
    _se_ui_baseline_append "$R2_FILE" "$nonce" "$R2_FP"
  done
  # 64 retained entries plus at most one explicit unknown marker.
  [ "$(wc -l < "$R2_FILE" | tr -d ' ')" -le 65 ]
  [ "$(wc -l < "$R2_FILE.nonces" | tr -d ' ')" -le 64 ]
  if grep -q "$(printf '%032x' 1)" "$R2_FILE"; then return 1; fi
  grep -q "$(printf '%032x' 2)" "$R2_FILE"
  grep -q "$(printf '%032x' 65)" "$R2_FILE"
  _se_ui_baseline_load "$R2_FILE"
  [ "$UI_TURN_STATUS" = unknown ] # evicted history is never a guessed baseline
  unset -f date
}

_r2_l3_age_cap() {
  local deps="$1" harness="$2" first second
  _r2_l3_load_deps "$deps" "$harness"
  first=$(printf '%032x' 1); second=$(printf '%032x' 2)
  _se_ui_baseline_append "$R2_FILE" "$first" "$R2_FP"
  _se_ui_baseline_load "$R2_FILE"
  [ "$UI_TURN_STATUS" = known ] # a fresh, valid baseline stays usable
  R2_NOW=$((R2_NOW + 86401))
  _se_ui_baseline_load "$R2_FILE"
  [ "$UI_TURN_STATUS" = unknown ] # stale even without another prompt
  _se_ui_baseline_append "$R2_FILE" "$second" "$R2_FP"
  if grep -q "$first" "$R2_FILE" || grep -q "$first" "$R2_FILE.nonces"; then return 1; fi
  grep -q "$second" "$R2_FILE"
  _se_ui_baseline_load "$R2_FILE"
  [ "$UI_TURN_STATUS" = unknown ] # pruning must not bless the remaining head
  unset -f date
}

@test "R2 L3: Claude UI baseline evicts oldest entries at the count cap" {
  _r2_l3_count_cap "$HOOKS_DIR/lib/deps.sh" claude
}

@test "R2 L3: Codex UI baseline evicts oldest entries at the count cap" {
  _r2_l3_count_cap "$CODEX_HOOKS_DIR/lib/deps.sh" codex
}

@test "R2 L3: Claude UI baseline evicts expired entries and remains unknown" {
  _r2_l3_age_cap "$HOOKS_DIR/lib/deps.sh" claude
}

@test "R2 L3: Codex UI baseline evicts expired entries and remains unknown" {
  _r2_l3_age_cap "$CODEX_HOOKS_DIR/lib/deps.sh" codex
}

_r2_l3_busy_writer() {
  local deps="$1" harness="$2" first second
  _r2_l3_load_deps "$deps" "$harness"
  first=$(printf '%032x' 1); second=$(printf '%032x' 2)
  _se_ui_baseline_append "$R2_FILE" "$first" "$R2_FP"
  _se_ui_baseline_load "$R2_FILE"; [ "$UI_TURN_STATUS" = known ]
  mkdir "$R2_FILE.lock"
  _se_ui_baseline_append "$R2_FILE" "$second" "$R2_FP" || true
  rmdir "$R2_FILE.lock"
  _se_ui_baseline_load "$R2_FILE"; [ "$UI_TURN_STATUS" = unknown ]
  _se_ui_baseline_append "$R2_FILE" "$second" "$R2_FP"
  _se_ui_baseline_load "$R2_FILE"; [ "$UI_TURN_STATUS" = unknown ]
  unset -f date
}

@test "R2 L3: Claude concurrent UI baseline writers leave unknown state" {
  _r2_l3_busy_writer "$HOOKS_DIR/lib/deps.sh" claude
}

@test "R2 L3: Codex concurrent UI baseline writers leave unknown state" {
  _r2_l3_busy_writer "$CODEX_HOOKS_DIR/lib/deps.sh" codex
}

@test "R2 L3: unknown baseline still checks the full uncommitted UI diff" {
  local tools="$BATS_TEST_TMPDIR/unknown-ui-tools"
  mkdir -p "$tools"
  printf '#!/bin/sh\nexit 0\n' > "$tools/curl"
  chmod +x "$tools/curl"
  run_core PATH="$tools:$PATH" UI_TURN_STATUS=unknown UI_SHOT_CMD=/usr/bin/true UI_VERIFY_TIMEOUT=2
  [ "$status" -eq 0 ]
  [ "$(json_field '.verdict')" = block ]
}

@test "143-stop committed UI changes remain visible after Stop consumes its baseline" {
  local tools="$BATS_TEST_TMPDIR/ui-turn-tools" harness hook prompt verify project event
  mkdir -p "$tools" "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/trellis"
  export HOME="$BATS_TEST_TMPDIR/home" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis"
  export TRELLIS_ROOT="$(cd "$HOOKS_DIR/../.." && pwd -P)"
  printf '#!/bin/sh\nexit 0\n' > "$tools/curl"
  printf '#!/bin/sh\nprintf image > "$2"\n' > "$tools/screenshot"
  chmod +x "$tools/curl" "$tools/screenshot"
  # The production macOS Bash 3.2 must parse both wrappers and the core.
  ln -s /bin/bash "$tools/bash"
  for harness in claude codex; do
    project="$BATS_TEST_TMPDIR/ui-turn-$harness"
    mkdir -p "$project/.claude" "$project/.codex"
    git -C "$project" init -q
    git -C "$project" config user.name test
    git -C "$project" config user.email test@example.invalid
    printf 'export const view = 1;\n' > "$project/view.tsx"
    git -C "$project" add view.tsx
    git -C "$project" commit -qm base
    printf '%s\n' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"turn-baseline.sh"}]}]}}' > "$project/.claude/settings.local.json"
    cp "$project/.claude/settings.local.json" "$project/.codex/hooks.json"
    printf '/.claude/\n/.codex/\n' >> "$project/.git/info/exclude"
    export CLAUDE_PROJECT_DIR="$project" CODEX_PROJECT_DIR="$project"
    if [ "$harness" = claude ]; then
      hook="$CANONICAL_HOOK"; prompt="$HOOKS_DIR/turn-baseline.sh"; verify="$HOOKS_DIR/stop-verify.sh"
    else
      hook="$CODEX_HOOK"; prompt="$CODEX_HOOKS_DIR/turn-baseline.sh"; verify="$CODEX_HOOKS_DIR/stop-verify.sh"
    fi
    event='{"session_id":"ui-turn"}'
    run /bin/bash "$prompt" <<<"$event"
    [ "$status" -eq 0 ]
    local initial_state
    initial_state="$(find "$TRELLIS_HOME/state/turn-baseline" -type f -name "ui.$harness.*" ! -name '*.nonces' | head -1)"
    [ -n "$initial_state" ]
    perl -e 'for (@ARGV) { my @s=stat($_); exit 1 unless @s && ($s[2] & 0777) == 0600 }' "$initial_state" "$initial_state.nonces"
    printf 'export const later = 2;\n' >> "$project/view.tsx"
    git -C "$project" add view.tsx
    git -C "$project" commit -qm ui-change
    # A different session cannot borrow or consume this session's baseline.
    run --separate-stderr env PATH="$tools:$PATH" UI_SHOT_CMD=/usr/bin/true UI_VERIFY_TIMEOUT=2 /bin/bash "$hook" <<<'{"session_id":"other-session"}'
    [ "$status" -eq 0 ]; [[ "$output" == *'turn baseline unavailable'* ]]
    # A second prompt before Stop must not erase the first prompt's baseline.
    run /bin/bash "$prompt" <<<"$event"
    [ "$status" -eq 0 ]
    run /bin/bash "$verify" <<<'{"session_id":"ui-turn","last_assistant_message":"Done. <!-- dod-receipt cmd=fixture exit=0 diff=+1 --> <!-- follow-ups: none -->"}'
    [ "$status" -eq 0 ]
    run --separate-stderr env PATH="$tools:$PATH" UI_SHOT_CMD=/usr/bin/true UI_VERIFY_TIMEOUT=2 /bin/bash "$hook" <<<"$event"
    if [ "$harness" = claude ]; then [ "$status" -eq 2 ]; else [ "$status" -eq 0 ]; fi
    printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
    # A blocked Stop retains its UI baseline until a screenshot succeeds.
    run --separate-stderr env PATH="$tools:$PATH" UI_SHOT_CMD=/usr/bin/true UI_VERIFY_TIMEOUT=2 bash "$hook" <<<"$event"
    printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
    run --separate-stderr env PATH="$tools:$PATH" UI_SHOT_CMD="$tools/screenshot" UI_VERIFY_TIMEOUT=2 bash "$hook" <<<"$event"
    [ "$status" -eq 0 ]
    [[ "$output" == *'screenshot saved'* ]]
    run /bin/bash "$prompt" <<<"$event"
    [ "$status" -eq 0 ]
    run --separate-stderr env PATH="$tools:$PATH" UI_SHOT_CMD=/usr/bin/true UI_VERIFY_TIMEOUT=2 bash "$hook" <<<"$event"
    [ "$status" -eq 0 ]; [ -z "$output" ]

    # An unreadable or forged baseline is unknown, never a silent no-UI skip.
    run /bin/bash "$prompt" <<<"$event"
    [ "$status" -eq 0 ]
    local state
    state="$(find "$TRELLIS_HOME/state/turn-baseline" -type f -name "ui.$harness.*" ! -name '*.nonces' | head -1)"
    [ -n "$state" ]
    printf 'trellis-turn-baseline v2 unknown\n' > "$state"
    printf '// another change\n' >> "$project/view.tsx"
    git -C "$project" add view.tsx
    git -C "$project" commit -qm another-ui-change
    run --separate-stderr env PATH="$tools:$PATH" UI_SHOT_CMD=/usr/bin/true UI_VERIFY_TIMEOUT=2 bash "$hook" <<<"$event"
    [ "$status" -eq 0 ]
    [[ "$output" == *'turn baseline unavailable'* ]]

    run /bin/bash "$prompt" <<<"$event"
    [ "$status" -eq 0 ]
    state="$(find "$TRELLIS_HOME/state/turn-baseline" -type f -name "ui.$harness.*" ! -name '*.nonces' | head -1)"
    [ -n "$state" ]
    printf '%032d\n' 0 > "$state.nonces"
    printf '// nonce check\n' >> "$project/view.tsx"
    git -C "$project" add view.tsx
    git -C "$project" commit -qm nonce-check
    run --separate-stderr env PATH="$tools:$PATH" UI_SHOT_CMD=/usr/bin/true UI_VERIFY_TIMEOUT=2 /bin/bash "$hook" <<<"$event"
    [ "$status" -eq 0 ]; [[ "$output" == *'turn baseline unavailable'* ]]
  done
}

@test "143-stop UI baseline absence is advisory only when the project is armed" {
  git -C "$PROJECT_DIR" checkout -- view.tsx
  export HOME="$BATS_TEST_TMPDIR/home" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis"
  mkdir -p "$HOME" "$TRELLIS_HOME"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR" CODEX_PROJECT_DIR="$PROJECT_DIR"
  export TRELLIS_ROOT="$(cd "$HOOKS_DIR/../.." && pwd -P)"
  local hook
  for hook in "$CANONICAL_HOOK" "$CODEX_HOOK"; do
    run --separate-stderr bash "$hook" <<<'{"session_id":"missing"}'
    [ "$status" -eq 0 ]; [ -z "$output" ]
  done
  mkdir -p "$PROJECT_DIR/.claude" "$PROJECT_DIR/.codex"
  printf '%s\n' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"turn-baseline.sh"}]}]}}' > "$PROJECT_DIR/.claude/settings.local.json"
  cp "$PROJECT_DIR/.claude/settings.local.json" "$PROJECT_DIR/.codex/hooks.json"
  printf '/.claude/\n/.codex/\n' >> "$PROJECT_DIR/.git/info/exclude"
  for hook in "$CANONICAL_HOOK" "$CODEX_HOOK"; do
    run --separate-stderr bash "$hook" <<<'{"session_id":"missing"}'
    [ "$status" -eq 0 ]; [[ "$output" == *'turn baseline unavailable'* ]]
    [[ "$output" != *'"decision":"block"'* ]]
  done
}

@test "143-stop UI gate detects unusual untracked and tracked filenames" {
  local tools="$BATS_TEST_TMPDIR/ui-tools" file="$PROJECT_DIR/Café.tsx"
  mkdir -p "$tools"
  printf '#!/bin/sh\nexit 0\n' > "$tools/curl"
  chmod +x "$tools/curl"
  git -C "$PROJECT_DIR" checkout -- view.tsx
  printf 'export const café = 1;\n' > "$file"
  run_core PATH="$tools:$PATH" UI_SHOT_CMD=/usr/bin/true UI_VERIFY_TIMEOUT=2
  [ "$status" -eq 0 ]
  [ "$(json_field '.verdict')" = block ]
  git -C "$PROJECT_DIR" add 'Café.tsx'
  git -C "$PROJECT_DIR" -c user.name=test -c user.email=test@example.com commit -qm unicode
  printf '// change\n' >> "$file"
  run_core PATH="$tools:$PATH" UI_SHOT_CMD=/usr/bin/true UI_VERIFY_TIMEOUT=2
  [ "$status" -eq 0 ]
  [ "$(json_field '.verdict')" = block ]
  git -C "$PROJECT_DIR" checkout -- 'Café.tsx'
  printf 'not a UI file\n' > "$PROJECT_DIR/"$'fake.tsx\nnotes.txt'
  run_core PATH="$tools:$PATH" UI_SHOT_CMD=/usr/bin/true UI_VERIFY_TIMEOUT=2
  [ "$(json_field '.verdict')" = skip ]
  printf 'export const x = 1;\n' > "$PROJECT_DIR/quote\"file.tsx"
  run_core PATH="$tools:$PATH" UI_SHOT_CMD=/usr/bin/true UI_VERIFY_TIMEOUT=2
  [ "$(json_field '.verdict')" = block ]
  run_core PATH="$tools:$PATH" UI_SHOT_CMD=/usr/bin/true UI_VERIFY_TIMEOUT=2 UI_REGEX='\.css$'
  [ "$(json_field '.verdict')" = skip ]
}

@test "143-stop UI gate still skips unusual non-UI filenames" {
  git -C "$PROJECT_DIR" checkout -- view.tsx
  printf 'not a UI file\n' > "$PROJECT_DIR/Café.txt"
  run_core
  [ "$status" -eq 0 ]
  [ "$(json_field '.verdict')" = skip ]
}

@test "Codex wrapper selects .pi config only for TRELLIS_HARNESS=pi" {
  local codex tools
  tools="$BATS_TEST_TMPDIR/wrapper-tools"
  mkdir -p "$tools" "$PROJECT_DIR/.codex/hooks" "$PROJECT_DIR/.pi/hooks"
  printf '%s\n' "UI_REGEX='['" > "$PROJECT_DIR/.codex/hooks/config.sh"
  printf '%s\n' "UI_REGEX='\\.never-matches$'" > "$PROJECT_DIR/.pi/hooks/config.sh"
  codex="$(deploy_wrapper codex "$CODEX_HOOK" "$CODEX_HOOKS_DIR/lib/deps.sh")"

  run_wrapper "$codex" "$tools" TRELLIS_HARNESS=pi CODEX_PROJECT_DIR="$PROJECT_DIR"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "invalid UI_REGEX produces an advisory rather than a skip" {
  run_core UI_REGEX='['

  [ "$status" -eq 0 ]
  [ "$(json_field '.verdict')" = "advisory" ]
  [[ "$(json_field '.reason')" == *"UI_REGEX"* ]]
}

@test "git inspection failure produces an advisory rather than a skip" {
  local tool_path
  tool_path="$(make_failing_git_path)"

  run_core PATH="$tool_path"

  [ "$status" -eq 0 ]
  [ "$(json_field '.verdict')" = "advisory" ]
  [[ "$(json_field '.reason')" == *"git"* ]]
}

@test "missing Perl is advisory and does not invoke an uncapped visual probe" {
  local tool_path marker
  marker="$BATS_TEST_TMPDIR/probe-invoked"
  tool_path="$(make_path_without_perl)"

  run_core PATH="$tool_path" PROBE_MARKER="$marker"

  [ "$status" -eq 0 ]
  [ "$(json_field '.verdict')" = "advisory" ]
  [[ "$(json_field '.reason')" == *"Perl"* ]]
  [ ! -e "$marker" ]
}

@test "canonical exits 2 and Codex exits 0 with the same block JSON" {
  local canonical codex tools canonical_output canonical_status
  tools="$BATS_TEST_TMPDIR/wrapper-tools"
  mkdir -p "$tools"
  cat > "$tools/curl" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$tools/curl"

  canonical="$(deploy_wrapper canonical "$CANONICAL_HOOK" "$HOOKS_DIR/lib/deps.sh")"
  codex="$(deploy_wrapper codex "$CODEX_HOOK" "$CODEX_HOOKS_DIR/lib/deps.sh")"

  run_wrapper "$canonical" "$tools"
  canonical_output="$output"
  canonical_status="$status"

  run_wrapper "$codex" "$tools"

  [ "$canonical_status" -eq 2 ]
  [ "$status" -eq 0 ]
  [ "$canonical_output" = "$output" ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "block" ]
  [[ "$(printf '%s' "$output" | jq -r '.reason')" == "UI-visible change requires visual verification. "* ]]
}

@test "sweep-fx1: run_with_timeout kills the whole process group (no orphan)" {
  # shellcheck disable=SC1090
  . "$CORE"
  local _sweep_start _sweep_end _sweep_elapsed
  _sweep_start=$(date +%s)
  run run_with_timeout 1 sh -c 'sleep 47 & wait'
  [ "$status" -eq 142 ]
  _sweep_end=$(date +%s)
  _sweep_elapsed=$((_sweep_end - _sweep_start))
  [ "$_sweep_elapsed" -lt 5 ]
  sleep 0.5
  # An orphaned sleep would be reparented to PID 1; the test harness itself
  # contains "sleep 47" in its command line but with a different PPID, so only
  # PPID 1 counts as an orphan.
  ! ps -eo ppid,command 2>/dev/null | awk '$1==1 && $2=="sleep" && $3=="47" { found=1 } END { exit !found }' || {
    pkill -f "sleep 47" 2>/dev/null || true
    false
  }
  pkill -f "sleep 47" 2>/dev/null || true
}

@test "sweep-fx1: non-numeric timeout falls back to bounded default" {
  # shellcheck disable=SC1090
  . "$CORE"
  run run_with_timeout abc sh -c 'echo hi; exit 7'
  [ "$status" -eq 7 ]
  [[ "$output" == *"hi"* ]]
  run run_with_timeout abc sleep 25
  [ "$status" -eq 142 ]
}
