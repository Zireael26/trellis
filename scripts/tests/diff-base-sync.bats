#!/usr/bin/env bats
# diff-base-sync.bats — operator-only PR cache writer (spec 067 T13).

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
DB="$ROOT/core-rules/skills/process-gate/scripts/lib/diff-base.sh"
SYNC_CALL_RE="(^|[[:space:];])db_sync([[:space:];(]|$)|diff-base\\.sh['\"]?[[:space:]]+sync([[:space:];]|$)|bash[[:space:]]+[^[:space:];]+[[:space:]]+sync([[:space:];]|$)"

setup() {
  T="$BATS_TEST_TMPDIR/sync"
  BIN="$T/bin"
  BASH_BIN="$(command -v bash)"
  mkdir -p "$BIN" "$T/home" || return 1
  export HOME="$T/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q -b feature/b "$T/repo" || return 1
  cd "$T/repo" || return 1
  local cmd
  for cmd in git jq; do
    ln -s "$(command -v "$cmd")" "$BIN/$cmd" || return 1
  done
  printf '%s\n' '{"number":46,"baseRefName":"feature/a","baseRefOid":"0123456789012345678901234567890123456789"}' > "$T/pr.json"
  export GH_FIXTURE="$T/pr.json" GH_TOKEN=fixture-token GH_HOME="$HOME" GH_RC=0
  cat > "$BIN/date" <<'EOF'
#!/bin/bash
[ "$*" = '-u +%Y-%m-%dT%H:%M:%SZ' ] || exit 91
printf '2026-10-07T12:34:56Z\n'
EOF
  chmod +x "$BIN/date" || return 1
}

stub_gh() {
  cat > "$BIN/gh" <<'EOF'
#!/bin/bash
[ "$*" = 'pr view --json number,baseRefName,baseRefOid' ] || exit 91
[ "$GH_TOKEN" = fixture-token ] || exit 92
[ "$HOME" = "$GH_HOME" ] || exit 93
while IFS= read -r line; do printf '%s\n' "$line"; done < "$GH_FIXTURE"
if [ "$GH_RC" -ne 0 ]; then printf 'fixture: not authenticated\n' >&2; fi
exit "$GH_RC"
EOF
  chmod +x "$BIN/gh" || return 1
}

sync_calls() {
  grep -RInE --exclude=diff-base.sh --exclude-dir=tests --exclude-dir=evals \
    "$SYNC_CALL_RE" "$1/core-rules" "$1/scripts"
}

@test "sync writes all four local PR keys using the caller's gh environment" {
  # RED: remove any config write, the timestamp, or inherited gh environment.
  stub_gh || return 1
  run env PATH="$BIN" "$BASH_BIN" "$DB" sync
  [ "$status" -eq 0 ] || return 1
  run git config --local --get-regexp '^branch\.feature/b\.trellispr'
  [ "$status" -eq 0 ] || return 1
  [ "$output" = 'branch.feature/b.trellisprbase feature/a
branch.feature/b.trellisprbaseoid 0123456789012345678901234567890123456789
branch.feature/b.trellisprnumber 46
branch.feature/b.trellisprcheckedat 2026-10-07T12:34:56Z' ] || return 1
}

@test "sync with gh missing reports one clear error and writes no PR keys" {
  # RED: remove the gh availability guard; the error becomes pr-view failure.
  run env PATH="$BIN" "$BASH_BIN" "$DB" sync
  [ "$status" -eq 1 ] || return 1
  [ "$output" = 'diff-base: sync: gh not found; install gh and authenticate with gh auth login' ] || return 1
  run git config --local --get-regexp '^branch\..*\.trellispr'
  [ "$status" -eq 1 ] || return 1
  [ -z "$output" ] || return 1
}

@test "failed gh with valid JSON reports one error and writes no partial keys" {
  # RED: remove the failed-gh return; this stub emits complete JSON then exits 1.
  stub_gh || return 1
  export GH_RC=1
  run env PATH="$BIN" "$BASH_BIN" "$DB" sync
  [ "$status" -eq 1 ] || return 1
  [ "$output" = 'diff-base: sync: gh pr view failed; authenticate with gh auth login and retry' ] || return 1
  run git config --local --get-regexp '^branch\..*\.trellispr'
  [ "$status" -eq 1 ] || return 1
  [ -z "$output" ] || return 1
}

@test "failed gh leaves an existing PR cache byte-identical" {
  # RED: any key write before successful gh changes this config snapshot.
  stub_gh || return 1
  export GH_RC=1
  local key
  for key in trellisPrBase trellisPrBaseOid trellisPrNumber trellisPrCheckedAt; do
    git config --local "branch.feature/b.$key" old || return 1
  done
  cp .git/config "$T/config.before" || return 1
  run env PATH="$BIN" "$BASH_BIN" "$DB" sync
  [ "$status" -eq 1 ] || return 1
  cmp -s "$T/config.before" .git/config || return 1
}

@test "sync rejects incomplete PR JSON before writing any key" {
  # RED: removing JSON validation writes a cache without a PR number.
  stub_gh || return 1
  printf '%s\n' '{"baseRefName":"feature/a","baseRefOid":"0123456789012345678901234567890123456789"}' > "$GH_FIXTURE"
  cp .git/config "$T/config.before" || return 1
  run env PATH="$BIN" "$BASH_BIN" "$DB" sync
  [ "$status" -eq 1 ] || return 1
  [ "$output" = 'diff-base: sync: invalid PR data from gh pr view' ] || return 1
  cmp -s "$T/config.before" .git/config || return 1
}

@test "no gate path calls diff-base sync" {
  # RED: planting a CLI or sourced-helper sync call in a gate yields a hit.
  run sync_calls "$ROOT"
  [ "$status" -eq 1 ] || return 1
  [ -z "$output" ] || return 1
}

@test "the no-sync grep detects a direct CLI call" {
  # RED: remove the diff-base.sh arm from SYNC_CALL_RE.
  mkdir -p "$T/core-rules/githooks" "$T/scripts" || return 1
  printf './diff-base.sh sync\n' > "$T/core-rules/githooks/pre-push"
  run sync_calls "$T"
  [ "$status" -eq 0 ] || return 1
}

@test "the no-sync grep detects a variable-path CLI call" {
  # RED: remove the bash-variable arm from SYNC_CALL_RE.
  mkdir -p "$T/core-rules/hooks" "$T/scripts" || return 1
  printf 'bash "$DB" sync\n' > "$T/core-rules/hooks/stop-verify.sh"
  run sync_calls "$T"
  [ "$status" -eq 0 ] || return 1
}

@test "the no-sync grep detects a sourced helper call" {
  # RED: remove the db_sync arm from SYNC_CALL_RE.
  mkdir -p "$T/core-rules/hooks" "$T/scripts" || return 1
  printf 'db_sync\n' > "$T/core-rules/hooks/spec-gate.sh"
  run sync_calls "$T"
  [ "$status" -eq 0 ] || return 1
}
