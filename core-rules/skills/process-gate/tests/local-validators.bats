#!/usr/bin/env bats
# Tests for the S5 advisory stack validators (spec 050 T11, plan §4 files 13-16).
#
# Contract under test (plan §3): each validator exits 0 pass, 2 warn, anything
# else fail. An absent binary exits 2 with FIRST line
# `unavailable: <tool> not on PATH` — warn, never pass, never a block.
#
# Determinism: every case builds a restricted PATH shim holding symlinks to the
# host tools the validators need plus a fake binary written BY THE TEST, with
# four behaviours across the suite — (a) report a violation, (b) exit 0 clean,
# (c) crash (exit >= 2), (d) be absent. actionlint/shfmt are absent on this host
# by design, so nothing here can pass by invoking the real tool. The shfmt tree
# enumeration is a stub lister seeded per test (the real lint-shell-tree.sh is
# covered by its own suite); the validator's job — mapping tool result to
# verdict — is what is asserted.

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../../.." && pwd)"
  ACTIONLINT="$ROOT/.claude/skills/process-gate-local/validators/actionlint.sh"
  SHFMT_CHECK="$ROOT/.claude/skills/process-gate-local/validators/shfmt-check.sh"
  [ -f "$ACTIONLINT" ] || skip "actionlint validator not found"
  [ -f "$SHFMT_CHECK" ] || skip "shfmt validator not found"

  REPO="$(mktemp -d)"
  (
    cd "$REPO" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "test"
  )
  export CLAUDE_PROJECT_DIR="$REPO"
  unset CODEX_PROJECT_DIR

  SHIM="$(mktemp -d)"
}

teardown() {
  [ -z "${REPO:-}" ] || rm -rf "$REPO"
  [ -z "${SHIM:-}" ] || rm -rf "$SHIM"
}

# shim_base — symlink the host tools the validators (and the stub lister) need,
# so the fake binary under test is the only unpinned behaviour on PATH. Never
# includes actionlint/shfmt themselves: presence is staged per test.
shim_base() {
  local tool
  for tool in bash git find awk tr xargs head cat dirname sort rm mktemp; do
    ln -s "$(command -v "$tool")" "$SHIM/$tool" || return 1
  done
}

# fake_tool <name> <mode> — write the fake binary. Modes: clean | defect | crash.
fake_tool() {
  case "$2" in
    clean)
      printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIM/$1"
      ;;
    defect)
      printf '#!/usr/bin/env bash\necho "%s: canned violation for %s" \nexit 1\n' "$1" "$3" > "$SHIM/$1"
      ;;
    crash)
      printf '#!/usr/bin/env bash\necho "%s: simulated crash" >&2\nexit 2\n' "$1" > "$SHIM/$1"
      ;;
  esac
  chmod +x "$SHIM/$1"
}

seed_workflow() {
  mkdir -p "$REPO/.github/workflows"
  printf 'name: %s\non: push\njobs:\n  ok:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ok\n' "$1" \
    > "$REPO/.github/workflows/$1.yml"
}

# seed_lister <relpath> — stub scripts/lint-shell-tree.sh listing one seed file.
seed_lister() {
  mkdir -p "$REPO/scripts"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$1" > "$REPO/scripts/lint-shell-tree.sh"
  chmod +x "$REPO/scripts/lint-shell-tree.sh"
  printf '#!/usr/bin/env bash\necho ok\n' > "$REPO/$1"
}

# --- actionlint ------------------------------------------------------------

@test "actionlint validator: absent binary renders unavailable (warn), never pass" {
  seed_workflow ok
  shim_base
  ! PATH="$SHIM" command -v actionlint
  run bash -c "cd '$REPO' && PATH='$SHIM' CLAUDE_PROJECT_DIR='$REPO' bash '$ACTIONLINT' --range=HEAD"
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "unavailable: actionlint not on PATH — workflow lint skipped (advisory)" ] \
    || { echo "$output"; false; }
  [[ "$output" != pass* ]] || { echo "$output"; false; }
}

@test "actionlint validator: present binary over a clean tree passes" {
  seed_workflow ok
  shim_base
  fake_tool actionlint clean
  run bash -c "cd '$REPO' && PATH='$SHIM' CLAUDE_PROJECT_DIR='$REPO' bash '$ACTIONLINT' --range=HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == pass* ]] || { echo "$output"; false; }
}

@test "actionlint validator: a seeded workflow defect fails" {
  seed_workflow bad
  shim_base
  fake_tool actionlint defect bad.yml
  run bash -c "cd '$REPO' && PATH='$SHIM' CLAUDE_PROJECT_DIR='$REPO' bash '$ACTIONLINT' --range=HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad.yml"* ]] || { echo "$output"; false; }
  [[ "$output" != pass* ]] || { echo "$output"; false; }
}

@test "actionlint validator: a crashing binary warns, never passes" {
  seed_workflow ok
  shim_base
  fake_tool actionlint crash
  run bash -c "cd '$REPO' && PATH='$SHIM' CLAUDE_PROJECT_DIR='$REPO' bash '$ACTIONLINT' --range=HEAD"
  [ "$status" -eq 2 ]
  [[ "$output" == warn* ]] || { echo "$output"; false; }
  [[ "$output" != pass* ]] || { echo "$output"; false; }
}

# --- shfmt -----------------------------------------------------------------

@test "shfmt validator: absent binary renders unavailable (warn), never pass" {
  shim_base
  ! PATH="$SHIM" command -v shfmt
  run bash -c "cd '$REPO' && PATH='$SHIM' CLAUDE_PROJECT_DIR='$REPO' bash '$SHFMT_CHECK' --range=HEAD"
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "unavailable: shfmt not on PATH — shell format check skipped (advisory)" ] \
    || { echo "$output"; false; }
  [[ "$output" != pass* ]] || { echo "$output"; false; }
}

@test "shfmt validator: present binary over a clean tree passes" {
  seed_lister clean.sh
  shim_base
  fake_tool shfmt clean
  run bash -c "cd '$REPO' && PATH='$SHIM' CLAUDE_PROJECT_DIR='$REPO' bash '$SHFMT_CHECK' --range=HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == pass* ]] || { echo "$output"; false; }
}

@test "shfmt validator: a misformatted script fails, and nothing is rewritten" {
  seed_lister ugly.sh
  printf '#!/usr/bin/env bash\nif  [  x  ] ;then\necho hi\nfi\n' > "$REPO/ugly.sh"
  shim_base
  fake_tool shfmt defect ugly.sh
  run bash -c "cd '$REPO' && PATH='$SHIM' CLAUDE_PROJECT_DIR='$REPO' bash '$SHFMT_CHECK' --range=HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ugly.sh"* ]] || { echo "$output"; false; }
  [[ "$output" != pass* ]] || { echo "$output"; false; }
  # Check-only: the seed is byte-identical after the run (no reformat).
  [ "$(cat "$REPO/ugly.sh")" = "$(printf '#!/usr/bin/env bash\nif  [  x  ] ;then\necho hi\nfi\n')" ] \
    || { echo "validator rewrote the seed"; false; }
}

@test "shfmt validator: a crashing binary warns, never passes" {
  seed_lister clean.sh
  shim_base
  fake_tool shfmt crash
  run bash -c "cd '$REPO' && PATH='$SHIM' CLAUDE_PROJECT_DIR='$REPO' bash '$SHFMT_CHECK' --range=HEAD"
  [ "$status" -eq 2 ]
  [[ "$output" == warn* ]] || { echo "$output"; false; }
  [[ "$output" != pass* ]] || { echo "$output"; false; }
}

# --- wiring ----------------------------------------------------------------

@test "stack config: PROCESS_GATE_STACK_VALIDATORS lists both advisory validators" {
  CONFIG="$ROOT/.claude/skills/process-gate-local/local.config.sh"
  [ -f "$CONFIG" ] || skip "local.config.sh not found"
  run bash -c "set -u; . '$CONFIG'; printf '%s\n' \"\${PROCESS_GATE_STACK_VALIDATORS[@]}\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"validators/actionlint.sh"* ]] || { echo "$output"; false; }
  [[ "$output" == *"validators/shfmt-check.sh"* ]] || { echo "$output"; false; }
  [ -f "$ROOT/.claude/skills/process-gate-local/validators/actionlint.sh" ] \
    || { echo "actionlint.sh missing"; false; }
  [ -f "$ROOT/.claude/skills/process-gate-local/validators/shfmt-check.sh" ] \
    || { echo "shfmt-check.sh missing"; false; }
}
