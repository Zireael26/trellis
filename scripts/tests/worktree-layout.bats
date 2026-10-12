#!/usr/bin/env bats
# Spec 069 A8, A10, A12: `trellis worktree root-init` and the doctor rows in
# scripts/lib/worktree-layout.sh (hc_wt_layout_rows).
#
# Hermetic: HOME and TRELLIS_HOME are sandboxes; tmutil and mdfind are stubs
# that record their argv and answer from files, so the real Time Machine and
# Spotlight state are never read or changed.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/worktree.sh"
LIB="$REPO_ROOT/scripts/lib/worktree-layout.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/wt-layout.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis-home"
  unset TRELLIS_WORKTREE_ROOT TRELLIS_CONFIG_PATH CODEX_HOME
  mkdir -p "$HOME" "$TRELLIS_HOME" "$SANDBOX/bin"
  ROOT="$HOME/projects/worktrees"
  export STUB_LOG="$SANDBOX/stub.log" TM_EXCLUDED="$SANDBOX/tm-excluded" MD_HITS="$SANDBOX/md-hits"
  : > "$STUB_LOG"; : > "$MD_HITS"
  cat > "$SANDBOX/bin/tmutil" <<'SH'
#!/bin/sh
printf 'tmutil %s\n' "$*" >> "$STUB_LOG"
case "$1" in
  addexclusion) printf '%s\n' "$2" >> "$TM_EXCLUDED" ;;
  isexcluded)
    if grep -Fxq "$2" "$TM_EXCLUDED" 2>/dev/null; then printf '[Excluded]    %s\n' "$2"
    else printf '[Included]    %s\n' "$2"; fi ;;
esac
SH
  cat > "$SANDBOX/bin/mdfind" <<'SH'
#!/bin/sh
printf 'mdfind %s\n' "$*" >> "$STUB_LOG"
cat "$MD_HITS"
SH
  chmod 755 "$SANDBOX/bin/tmutil" "$SANDBOX/bin/mdfind"
  ln -s "$(command -v jq)" "$SANDBOX/bin/jq"
  export PATH="$SANDBOX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}

teardown() {
  [ -z "${SANDBOX:-}" ] || rm -rf "$SANDBOX"
}

rows() {
  run bash -c 'set -euo pipefail; . "$1"; hc_wt_layout_rows "$2" "$3" "$4"' _ "$LIB" "$HOME" "$TRELLIS_HOME" "${1:-off}"
}

@test "root-init creates the root with its marker and a Time Machine exclusion, idempotently" {
  run bash "$SCRIPT" root-init
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -d "$ROOT" ] && [ -e "$ROOT/.metadata_never_index" ]
  [ "$(stat -f %Lp "$ROOT" 2>/dev/null || stat -c %a "$ROOT")" = 755 ]
  grep -Fxq "tmutil addexclusion $ROOT" "$STUB_LOG"
  [[ "$output" == *"[Excluded]"* ]] || { echo "$output"; return 1; }
  run bash "$SCRIPT" root-init
  [ "$status" -eq 0 ]
  [ "$(grep -c 'addexclusion' "$STUB_LOG")" -eq 1 ]
}

@test "root-init exits 5 without tmutil but still makes the root and marker" {
  # /usr/bin holds the real tmutil, so run on a PATH of named tools only.
  mkdir -p "$SANDBOX/minbin"
  for tool in dirname mkdir chmod head; do ln -s "$(command -v "$tool")" "$SANDBOX/minbin/$tool"; done
  run env PATH="$SANDBOX/minbin" /bin/bash "$SCRIPT" root-init
  [ "$status" -eq 5 ] || { echo "$output"; return 1; }
  [ -e "$ROOT/.metadata_never_index" ]
}

@test "doctor rows: a missing root warns with the root-init remedy" {
  rows
  [ "$status" -eq 0 ]
  [[ "$output" == *$'2\t'"worktree root $ROOT does not exist; run: trellis worktree root-init"* ]] || { echo "$output"; return 1; }
}

@test "doctor rows: an initialised root reports Time Machine, marker and Spotlight OK" {
  bash "$SCRIPT" root-init >/dev/null
  rows
  [ "$status" -eq 0 ]
  [[ "$output" == *$'0\t'"worktree root $ROOT is excluded from Time Machine"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *$'0\tworktree root carries .metadata_never_index'* ]]
  [[ "$output" == *$'0\t'"Spotlight returns no hits under $ROOT"* ]]
  grep -q "mdfind -onlyin $ROOT" "$STUB_LOG"
}

@test "doctor rows: Spotlight hits print the manual Privacy step instead of claiming exclusion" {
  bash "$SCRIPT" root-init >/dev/null
  printf '%s/alpha/x/file.txt\n' "$ROOT" > "$MD_HITS"
  rows
  [[ "$output" == *$'2\t'"Spotlight still indexes $ROOT; in System Settings > Siri & Spotlight"*"Spotlight Privacy, add the folder $ROOT"* ]] || { echo "$output"; return 1; }
}

@test "doctor rows: an included root and a missing marker warn" {
  mkdir -p "$ROOT"
  rows
  [[ "$output" == *$'2\t'"worktree root $ROOT is not excluded from Time Machine"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *$'2\tworktree root has no .metadata_never_index'* ]]
}

@test "doctor --fix runs root-init; --fix --dry-run only says it would" {
  rows dry-run
  [[ "$output" == *$'3\tworktree root: --fix would run trellis worktree root-init'* ]] || { echo "$output"; return 1; }
  [ ! -e "$ROOT" ]
  rows apply
  [ -e "$ROOT/.metadata_never_index" ]
  [[ "$output" == *$'0\t'"worktree root $ROOT is excluded from Time Machine"* ]] || { echo "$output"; return 1; }
}

@test "doctor rows: Codex worktrees and a Cursor worktree root warn (A8, A10)" {
  mkdir -p "$HOME/.codex/worktrees/abcd" "$HOME/.cursor/worktrees"
  rows
  [[ "$output" == *$'2\t'"1 entr(ies) under $HOME/.codex/worktrees: in the Codex app set Settings > Worktrees > Worktree root to $ROOT/_codex"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *$'2\t'"$HOME/.cursor/worktrees exists: Cursor's cleanup keeps 25 worktrees"* ]]
  CODEX_HOME="$SANDBOX/codex" rows
  [[ "$output" != *"entr(ies) under"* ]] || { echo "$output"; return 1; }
}
