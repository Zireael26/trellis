#!/usr/bin/env bats

load helpers

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

@test "canonical and Codex wrappers emit the same block JSON and exit 2" {
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
  [ "$status" -eq 2 ]
  [ "$canonical_output" = "$output" ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "block" ]
  [[ "$(printf '%s' "$output" | jq -r '.reason')" == "UI-visible change requires visual verification. "* ]]
}
