#!/usr/bin/env bats
# Turn baselines and Stop verification with Git's index visibility flags.
load helpers
bats_require_minimum_version 1.5.0

setup() {
  export HOME="$BATS_TEST_TMPDIR/home" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  cat > "$BATS_TEST_TMPDIR/bin/pnpm" <<'EOF'
#!/bin/sh
printf x >> "$RUN_MARKER"
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/pnpm"
}

fixture() {
  local name="$1"
  PROJECT_DIR="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$PROJECT_DIR/.claude" "$PROJECT_DIR/.codex"
  git -C "$PROJECT_DIR" init -q
  git -C "$PROJECT_DIR" config user.name 'Trellis CI'
  git -C "$PROJECT_DIR" config user.email ci-bats@trellis.test
  printf 'export const x = 1;\n' > "$PROJECT_DIR/app.js"
  printf '# documentation\n' > "$PROJECT_DIR/notes.md"
  printf '%s\n' '{"scripts":{"test":"echo ok"}}' > "$PROJECT_DIR/package.json"
  : > "$PROJECT_DIR/pnpm-lock.yaml"
  git -C "$PROJECT_DIR" add app.js notes.md package.json pnpm-lock.yaml
  git -C "$PROJECT_DIR" commit -qm base
  printf '%s\n' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"turn-baseline.sh"}]}]}}' > "$PROJECT_DIR/.claude/settings.local.json"
  printf '%s\n' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"turn-baseline.sh"}]}]}}' > "$PROJECT_DIR/.codex/hooks.json"
  printf '/.claude/\n/.codex/\n' >> "$PROJECT_DIR/.git/info/exclude"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR" CODEX_PROJECT_DIR="$PROJECT_DIR"
  export RUN_MARKER="$BATS_TEST_TMPDIR/calls-$name"
}

prompt() {
  local hook
  if [ "$1" = codex ]; then hook="$CODEX_HOOKS_DIR/turn-baseline.sh"; else hook="$HOOKS_DIR/turn-baseline.sh"; fi
  run bash "$hook" <<<'{"session_id":"flags-session"}'
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

stop() {
  local hook
  if [ "$1" = codex ]; then hook="$CODEX_HOOKS_DIR/stop-verify.sh"; else hook="$HOOKS_DIR/stop-verify.sh"; fi
  run bash "$hook" <<<'{"session_id":"flags-session","last_assistant_message":"Done."}'
}

make_index_scan_counter() {
  local dir="$BATS_TEST_TMPDIR/index-counter"
  mkdir -p "$dir"
  export REAL_GIT="$(command -v git)" INDEX_SCAN_LOG="$BATS_TEST_TMPDIR/index-scans"
  export INDEX_HASH_LOG="$BATS_TEST_TMPDIR/index-hashes"
  cat > "$dir/git" <<'EOF'
#!/bin/sh
lsfiles=0 verbose=0
for arg in "$@"; do
  [ "$arg" != ls-files ] || lsfiles=1
  [ "$arg" != -v ] || verbose=1
  [ "$arg" != hash-object ] || printf 'hash\n' >> "$INDEX_HASH_LOG"
done
[ "$lsfiles" -ne 1 ] || [ "$verbose" -ne 1 ] || printf 'scan\n' >> "$INDEX_SCAN_LOG"
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$dir/git"
  COUNTER_BIN="$dir"
}

_r5_l1_corrupt_cache() {
  local side="$1" shape="$2" lib cache
  if [ "$side" = claude ]; then lib="$HOOKS_DIR/lib/deps.sh"; else lib="$CODEX_HOOKS_DIR/lib/deps.sh"; fi
  fixture "cache-corrupt-$side-$shape"
  git -C "$PROJECT_DIR" update-index --assume-unchanged app.js
  printf 'changed\n' >> "$PROJECT_DIR/app.js"
  make_index_scan_counter
  cache="$BATS_TEST_TMPDIR/cache-$side-$shape"
  mkdir -p "$cache"
  : > "$INDEX_SCAN_LOG"
  run env PATH="$COUNTER_BIN:$PATH" /bin/bash -c '
    . "$1"; __se_flag_cache="$2"; __se_cache_epoch=$(date +%s); project="$3"; shape="$4"
    first=$(_se_flagged_changed_lines "$project") || exit 1
    case "$first" in *app.js*) ;; *) echo "initial flagged edit missing"; exit 1 ;; esac
    second=$(_se_flagged_changed_lines "$project") || exit 1
    [ "$second" = "$first" ] || exit 1
    [ "$(wc -l < "$INDEX_SCAN_LOG" | tr -d " ")" -eq 1 ] || { echo "valid cache was not reused"; exit 1; }
    case "$shape" in
      truncated)
        python3 -I - "$__se_flag_cache/records" <<"PY"
from pathlib import Path
import sys
p = Path(sys.argv[1]); data = p.read_bytes(); assert data.endswith(b"\0")
p.write_bytes(data[:-1])
PY
        ;;
      garbage) printf "malformed row\\0" > "$__se_flag_cache/records" ;;
      empty) : > "$__se_flag_cache/records" ;;
      marker-only) printf "trellis-stop-flags-cache-v1\\0" > "$__se_flag_cache/records" ;;
      valid-other) printf "h other.js\\0trellis-stop-flags-cache-v1\\0" > "$__se_flag_cache/records" ;;
      directory) mv "$__se_flag_cache/records" "$__se_flag_cache/records.saved"; mkdir "$__se_flag_cache/records" ;;
      symlink) mv "$__se_flag_cache/records" "$__se_flag_cache/records.saved"; ln -s records.saved "$__se_flag_cache/records" ;;
      unreadable) chmod 000 "$__se_flag_cache/records" ;;
      valid) exit 0 ;;
      *) exit 1 ;;
    esac
    if result=$(_se_flagged_changed_lines "$project"); then
      # A fresh successful scan is also safe; accepting stale empty data is not.
      case "$result" in *app.js*) ;; *) echo "corrupt cache hid flagged edit"; exit 1 ;; esac
      [ "$(wc -l < "$INDEX_SCAN_LOG" | tr -d " ")" -ge 2 ] || { echo "corrupt cache was reused"; exit 1; }
    fi
  ' _ "$lib" "$cache" "$PROJECT_DIR" "$shape"
  [ "$status" -eq 0 ] || { echo "$side $shape: $output"; false; }
}

@test "R5 L1: Claude truncated cached rows fail closed" { _r5_l1_corrupt_cache claude truncated; }
@test "R5 L1: Codex truncated cached rows fail closed" { _r5_l1_corrupt_cache codex truncated; }
@test "R5 L1: Claude garbage cached rows fail closed" { _r5_l1_corrupt_cache claude garbage; }
@test "R5 L1: Codex garbage cached rows fail closed" { _r5_l1_corrupt_cache codex garbage; }
@test "R5 L1: Claude empty cached rows fail closed" { _r5_l1_corrupt_cache claude empty; }
@test "R5 L1: Codex empty cached rows fail closed" { _r5_l1_corrupt_cache codex empty; }
@test "R5 L1: Claude marker-only replacement cannot erase flagged rows" { _r5_l1_corrupt_cache claude marker-only; }
@test "R5 L1: Codex marker-only replacement cannot erase flagged rows" { _r5_l1_corrupt_cache codex marker-only; }
@test "R5 L1: Claude valid-looking replacement cannot erase flagged rows" { _r5_l1_corrupt_cache claude valid-other; }
@test "R5 L1: Codex valid-looking replacement cannot erase flagged rows" { _r5_l1_corrupt_cache codex valid-other; }
@test "R5 L1: Claude symlinked cached rows fail closed" { _r5_l1_corrupt_cache claude symlink; }
@test "R5 L1: Codex symlinked cached rows fail closed" { _r5_l1_corrupt_cache codex symlink; }
@test "R5 L1: Claude directory cached rows fail closed" { _r5_l1_corrupt_cache claude directory; }
@test "R5 L1: Codex directory cached rows fail closed" { _r5_l1_corrupt_cache codex directory; }
@test "R5 L1: Claude unreadable cached rows fail closed" {
  [ "$(id -u)" -ne 0 ] || skip 'root can read mode-000 files'
  _r5_l1_corrupt_cache claude unreadable
}
@test "R5 L1: Codex unreadable cached rows fail closed" {
  [ "$(id -u)" -ne 0 ] || skip 'root can read mode-000 files'
  _r5_l1_corrupt_cache codex unreadable
}
@test "R5 L1: valid Claude and Codex flagged caches are reused" {
  _r5_l1_corrupt_cache claude valid
  _r5_l1_corrupt_cache codex valid
}

_r5_l1_stop_tamper() {
  local harness="$1" mode project bin temp state hook
  if [ "$harness" = claude ]; then hook="$HOOKS_DIR/stop-verify.sh"; else hook="$CODEX_HOOKS_DIR/stop-verify.sh"; fi
  for mode in corrupt valid; do
    project="$BATS_TEST_TMPDIR/stop-$harness-$mode"
    bin="$project/.fakebin"; temp="$BATS_TEST_TMPDIR/tmp-$harness-$mode"; state="$BATS_TEST_TMPDIR/state-$harness-$mode"
    mkdir -p "$project" "$bin" "$temp" "$state"
    git -C "$project" init -q
    git -C "$project" config user.name 'Trellis CI'
    git -C "$project" config user.email ci-bats@trellis.test
    printf 'x = 1\n' > "$project/app.py"; : > "$project/ruff.toml"
    git -C "$project" add app.py ruff.toml
    git -C "$project" commit -qm base
    printf '/.fakebin/\n' >> "$project/.git/info/exclude"
    git -C "$project" update-index --assume-unchanged app.py
    printf 'x = 2\n' > "$project/app.py"
    cat > "$bin/ruff" <<'EOF'
#!/usr/bin/perl
if (@ARGV && $ARGV[0] eq '--version') { print "ruff 1\n"; exit 0 }
open(my $calls, '>>', "$ENV{R5_STATE}/calls") or die; print $calls "run\n"; close $calls;
if ($ENV{R5_MODE} eq 'corrupt') {
  my @records = glob("$ENV{TMPDIR}/trellis-stop-flags.*/records");
  @records == 1 or die "expected one Stop cache";
  open(my $f, '>', $records[0]) or die; close $f;
}
exit 0;
EOF
    chmod +x "$bin/ruff"
    run env GIT_OPTIONAL_LOCKS=0 PATH="$bin:$PATH" CLAUDE_PROJECT_DIR="$project" \
      CODEX_PROJECT_DIR="$project" TMPDIR="$temp" R5_STATE="$state" R5_MODE="$mode" \
      bash "$hook" <<<'{"session_id":"r5-cache","last_assistant_message":"Done, without a receipt."}'
    [ -s "$state/calls" ] || { echo 'fixture did not execute ruff'; false; }
    if [ "$harness" = claude ]; then [ "$status" -eq 2 ]; else [ "$status" -eq 0 ]; fi
    if [ "$mode" = corrupt ]; then
      printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("git changed files:"))' >/dev/null
    else
      printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("receipts:"))' >/dev/null
    fi
  done
}

@test "R5 L1: Claude Stop blocks when a check erases cached flagged rows" { _r5_l1_stop_tamper claude; }
@test "R5 L1: Codex Stop blocks when a check erases cached flagged rows" { _r5_l1_stop_tamper codex; }

@test "R5 L1: valid Claude and Codex unflagged caches are reused" {
  local lib cache
  fixture cache-valid-empty
  make_index_scan_counter
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    cache="$BATS_TEST_TMPDIR/empty-$(printf '%s' "$lib" | cksum | awk '{print $1}')"
    mkdir -p "$cache"; : > "$INDEX_SCAN_LOG"
    run env PATH="$COUNTER_BIN:$PATH" /bin/bash -c '
      . "$1"; __se_flag_cache="$2"; __se_cache_epoch=$(date +%s)
      _se_flagged_changed_lines "$3" && _se_flagged_changed_lines "$3"
    ' _ "$lib" "$cache" "$PROJECT_DIR"
    [ "$status" -eq 0 ]; [ -z "$output" ]
    [ "$(wc -l < "$INDEX_SCAN_LOG" | tr -d ' ')" -eq 1 ]
  done
}

@test "R5 L1: unflagged cache remains usable without Perl" {
  local lib bin="$BATS_TEST_TMPDIR/no-perl-cache" cache epoch
  fixture cache-valid-no-perl
  mkdir -p "$bin"
  ln -s "$(command -v git)" "$bin/git"
  ln -s "$(command -v mv)" "$bin/mv"
  epoch=$(date +%s)
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    cache="$BATS_TEST_TMPDIR/no-perl-$(printf '%s' "$lib" | cksum | awk '{print $1}')"
    mkdir -p "$cache"
    run env PATH="$bin" R5_EPOCH="$epoch" /bin/bash -c '
      . "$1"; __se_flag_cache="$2"; __se_cache_epoch="$R5_EPOCH"
      _se_flagged_changed_lines "$3" && _se_flagged_changed_lines "$3"
    ' _ "$lib" "$cache" "$PROJECT_DIR"
    [ "$status" -eq 0 ]; [ -z "$output" ]
  done
}

_r5_l1_empty_corrupt() {
  local side="$1" shape="$2" lib cache
  if [ "$side" = claude ]; then lib="$HOOKS_DIR/lib/deps.sh"; else lib="$CODEX_HOOKS_DIR/lib/deps.sh"; fi
  fixture "empty-cache-$side-$shape"
  make_index_scan_counter
  cache="$BATS_TEST_TMPDIR/empty-cache-$side-$shape"; mkdir -p "$cache"; : > "$INDEX_SCAN_LOG"
  run env PATH="$COUNTER_BIN:$PATH" /bin/bash -c '
    . "$1"; __se_flag_cache="$2"; __se_cache_epoch=$(date +%s); project="$3"
    _se_flagged_changed_lines "$project" || exit 1
    _se_flagged_changed_lines "$project" || exit 1
    [ "$(wc -l < "$INDEX_SCAN_LOG" | tr -d " ")" -eq 1 ] || exit 1
    case "$4" in
      empty) : > "$__se_flag_cache/records" ;;
      garbage) printf "invalid\\0" > "$__se_flag_cache/records" ;;
      extra) printf "trellis-stop-flags-cache-v1\\0h app.js\\0" > "$__se_flag_cache/records" ;;
      partial) printf "trellis-stop-flags-cache-v1\\0partial" > "$__se_flag_cache/records" ;;
    esac
    if _se_flagged_changed_lines "$project"; then
      [ "$(wc -l < "$INDEX_SCAN_LOG" | tr -d " ")" -ge 2 ] || { echo "corrupt empty cache reused"; exit 1; }
    fi
  ' _ "$lib" "$cache" "$PROJECT_DIR" "$shape"
  [ "$status" -eq 0 ] || { echo "$side $shape: $output"; false; }
}

@test "R5 L1: Claude empty-scan cache cannot be erased" { _r5_l1_empty_corrupt claude empty; }
@test "R5 L1: Codex empty-scan cache cannot be erased" { _r5_l1_empty_corrupt codex empty; }
@test "R5 L1: Claude empty-scan cache cannot contain garbage" { _r5_l1_empty_corrupt claude garbage; }
@test "R5 L1: Codex empty-scan cache cannot contain garbage" { _r5_l1_empty_corrupt codex garbage; }
@test "R5 L1: Claude empty-scan cache cannot have a trailing complete row" { _r5_l1_empty_corrupt claude extra; }
@test "R5 L1: Codex empty-scan cache cannot have a trailing complete row" { _r5_l1_empty_corrupt codex extra; }
@test "R5 L1: Claude empty-scan cache cannot have trailing partial bytes" { _r5_l1_empty_corrupt claude partial; }
@test "R5 L1: Codex empty-scan cache cannot have trailing partial bytes" { _r5_l1_empty_corrupt codex partial; }

@test "R5 L1: cached row parser rejects malformed records and missing terminators" {
  local lib case_ engine
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    for engine in perl shell; do
      for case_ in garbage truncated empty empty-path after-marker; do
        run /bin/bash -c '
        . "$1"
        if [ "$3" = shell ]; then
          command() { [ "$1" != -v ] || [ "$2" != perl ] || return 1; builtin command "$@"; }
        fi
        case "$2" in
          garbage) printf "garbage\\0trellis-stop-flags-cache-v1\\0" ;;
          truncated) printf "h app.js" ;;
          empty) : ;;
          empty-path) printf "h \\0trellis-stop-flags-cache-v1\\0" ;;
          after-marker) printf "trellis-stop-flags-cache-v1\\0h app.js\\0" ;;
        esac | _se_flagged_candidates false cached
        ' _ "$lib" "$case_" "$engine"
        [ "$status" -ne 0 ] || { echo "$lib $engine accepted $case_"; false; }
      done
      run /bin/bash -c '
        . "$1"
        if [ "$2" = shell ]; then
          command() { [ "$1" != -v ] || [ "$2" != perl ] || return 1; builtin command "$@"; }
        fi
        printf "h app.js\\0trellis-stop-flags-cache-v1\\0" | _se_flagged_candidates false cached
      ' _ "$lib" "$engine"
      [ "$status" -eq 0 ]; [ "$output" = app.js ]
    done
  done
}

_r4_m1_sparse_stop() {
  local harness="$1" toggle="$2" hook
  PROJECT_DIR="$BATS_TEST_TMPDIR/sparse-$harness-$toggle"
  local bin="$PROJECT_DIR/.fakebin" state="$BATS_TEST_TMPDIR/state-$harness-$toggle"
  mkdir -p "$PROJECT_DIR" "$bin" "$state"
  git -C "$PROJECT_DIR" init -q
  git -C "$PROJECT_DIR" config user.name 'Trellis CI'
  git -C "$PROJECT_DIR" config user.email ci-bats@trellis.test
  printf 'x = 1\n' > "$PROJECT_DIR/b.py"
  : > "$PROJECT_DIR/ruff.toml"
  git -C "$PROJECT_DIR" add b.py ruff.toml
  git -C "$PROJECT_DIR" commit -qm base
  printf '/.fakebin/\n' >> "$PROJECT_DIR/.git/info/exclude"
  git -C "$PROJECT_DIR" config core.sparseCheckout true
  git -C "$PROJECT_DIR" update-index --skip-worktree b.py
  printf 'x = 2\n' > "$PROJECT_DIR/b.py"
  cat > "$bin/ruff" <<'EOF'
#!/usr/bin/perl
if (@ARGV && $ARGV[0] eq '--version') { print "ruff 1\n"; exit 0 }
open(my $calls, '>>', "$ENV{R4_STATE}/calls") or die;
print $calls "ruff @ARGV\n"; close $calls;
if ($ENV{R4_TOGGLE} eq 'yes') {
  system('git', 'config', 'core.sparseCheckout', 'false') == 0 or die;
}
exit 0;
EOF
  chmod +x "$bin/ruff"
  if [ "$harness" = claude ]; then hook="$HOOKS_DIR/stop-verify.sh"; else hook="$CODEX_HOOKS_DIR/stop-verify.sh"; fi
  run env GIT_OPTIONAL_LOCKS=0 PATH="$bin:$PATH" CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
    CODEX_PROJECT_DIR="$PROJECT_DIR" R4_STATE="$state" R4_TOGGLE="$toggle" \
    bash "$hook" <<<'{"session_id":"sparse-config-change","last_assistant_message":"all done, no receipt here"}'
  [ -s "$state/calls" ] || { echo 'fixture did not execute ruff'; false; }
  if [ "$harness" = claude ]; then [ "$status" -eq 2 ]; else [ "$status" -eq 0 ]; fi
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("receipts:"))' >/dev/null
}

@test "R4 M1: Claude sparse config changed by a check cannot hide a receipt" {
  _r4_m1_sparse_stop claude yes
}

@test "R4 M1: Codex sparse config changed by a check cannot hide a receipt" {
  _r4_m1_sparse_stop codex yes
}

@test "R4 M1: Claude sparse change without a config toggle still requires a receipt" {
  _r4_m1_sparse_stop claude no
}

@test "R4 M1: Codex sparse change without a config toggle still requires a receipt" {
  _r4_m1_sparse_stop codex no
}

@test "R4 M1: cached flags survive both sparse config changes without an index rewrite" {
  local lib change cache
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    for change in sparse expect; do
      fixture "config-$change-$(printf '%s' "$lib" | cksum | awk '{print $1}')"
      git -C "$PROJECT_DIR" config core.sparseCheckout true
      git -C "$PROJECT_DIR" update-index --skip-worktree app.js
      printf 'changed\n' >> "$PROJECT_DIR/app.js"
      cp "$PROJECT_DIR/.git/index" "$BATS_TEST_TMPDIR/index-before-config"
      cache="$BATS_TEST_TMPDIR/cache-$change-$(printf '%s' "$lib" | cksum | awk '{print $1}')"
      mkdir -p "$cache"
      run env GIT_OPTIONAL_LOCKS=0 bash -c '
        . "$1"; __se_flag_cache="$2"; __se_cache_epoch=$(date +%s); project="$3"
        _se_flagged_changed_lines "$project" >/dev/null || exit 1
        if [ "$4" = sparse ]; then
          git -C "$project" config core.sparseCheckout false || exit 1
        else
          git -C "$project" config sparse.expectFilesOutsideOfPatterns true || exit 1
        fi
        _se_flagged_changed_lines "$project"
      ' _ "$lib" "$cache" "$PROJECT_DIR" "$change"
      [ "$status" -eq 0 ]; [[ "$output" == *app.js* ]]
      cmp "$PROJECT_DIR/.git/index" "$BATS_TEST_TMPDIR/index-before-config"
    done
  done
}

@test "R3 L8: each Stop shares one index visibility scan, flagged or ordinary" {
  local h flag hook
  make_index_scan_counter
  for h in claude codex; do
    if [ "$h" = claude ]; then hook="$HOOKS_DIR/stop-verify.sh"; else hook="$CODEX_HOOKS_DIR/stop-verify.sh"; fi
    for flag in ordinary assume-unchanged skip-worktree; do
      fixture "cache-$h-$flag"
      if [ "$flag" != ordinary ]; then git -C "$PROJECT_DIR" update-index "--$flag" app.js; fi
      printf 'export const changed = 2;\n' >> "$PROJECT_DIR/app.js"
      : > "$INDEX_SCAN_LOG"
      run env PATH="$COUNTER_BIN:$PATH" bash "$hook" \
        <<<'{"last_assistant_message":"Done. <!-- dod-receipt cmd=fixture exit=0 diff=+1 --> <!-- follow-ups: none -->"}'
      [ "$status" -eq 0 ] || { echo "$h $flag: $output"; false; }
      [[ "$output" != *'"decision":"block"'* ]] || false
      [ -s "$RUN_MARKER" ]
      [ "$(wc -l < "$INDEX_SCAN_LOG" | tr -d ' ')" -eq 1 ] || { echo "$h $flag rescanned:"; cat "$INDEX_SCAN_LOG"; false; }
    done
  done
}

@test "R3 L8: a changed Git index invalidates the cached flagged paths" {
  local lib out cache
  fixture cache-invalidated
  make_index_scan_counter
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    git -C "$PROJECT_DIR" update-index --no-assume-unchanged app.js
    git -C "$PROJECT_DIR" checkout -- app.js
    cache="$BATS_TEST_TMPDIR/cache-${lib#"$HOOKS_DIR"}"
    mkdir -p "$cache"
    : > "$INDEX_SCAN_LOG"
    run env PATH="$COUNTER_BIN:$PATH" bash -c '
      . "$1"; __se_flag_cache="$2"; project="$3"
      _se_flagged_changed_lines "$project" || exit 1
      git -C "$project" update-index --assume-unchanged app.js || exit 1
      printf "new flagged bytes\n" >> "$project/app.js"
      _se_flagged_changed_lines "$project"
    ' _ "$lib" "$cache" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *app.js* ]] || false
    [ "$(wc -l < "$INDEX_SCAN_LOG" | tr -d ' ')" -eq 2 ]
  done
}

@test "R3 L8: old unchanged index metadata avoids repeated content hashing" {
  local lib cache
  fixture stable-index
  make_index_scan_counter
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    cache="$BATS_TEST_TMPDIR/stable-$(printf '%s' "$lib" | cksum | awk '{print $1}')"
    mkdir -p "$cache"
    : > "$INDEX_SCAN_LOG"; : > "$INDEX_HASH_LOG"
    # Simulate an old unchanged index without making the suite sleep.
    run env PATH="$COUNTER_BIN:$PATH" bash -c '
      . "$1"; __se_flag_cache="$2"; __se_cache_epoch=$(($(date +%s) + 10))
      _se_flagged_changed_lines "$3" && _se_flagged_changed_lines "$3"
    ' _ "$lib" "$cache" "$PROJECT_DIR"
    [ "$status" -eq 0 ]; [ -z "$output" ]
    [ "$(wc -l < "$INDEX_SCAN_LOG" | tr -d ' ')" -eq 1 ]
    [ "$(wc -l < "$INDEX_HASH_LOG" | tr -d ' ')" -eq 0 ]
  done
}

@test "R3 L8: recent index metadata is never enough to reuse a digest" {
  local lib cache
  fixture racy-index
  make_index_scan_counter
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    git -C "$PROJECT_DIR" update-index --no-assume-unchanged app.js
    git -C "$PROJECT_DIR" checkout -- app.js
    cache="$BATS_TEST_TMPDIR/racy-$(printf '%s' "$lib" | cksum | awk '{print $1}')"
    mkdir -p "$cache"
    : > "$INDEX_SCAN_LOG"; : > "$INDEX_HASH_LOG"
    # Emulate a coarse filesystem returning the same recent timestamp across
    # an index rewrite: the recent-time rule must force a content hash.
    run env PATH="$COUNTER_BIN:$PATH" bash -c '
      . "$1"; _se_load_heavy || exit 1; __se_flag_cache="$2"; __se_cache_epoch=$(date +%s); project="$3"
      _se_index_stamp() { printf "1:2:3:%s:%s:coarse" "$__se_cache_epoch" "$__se_cache_epoch"; }
      _se_flagged_changed_lines "$project" || exit 1
      git -C "$project" update-index --assume-unchanged app.js || exit 1
      printf "changed\n" >> "$project/app.js"
      _se_flagged_changed_lines "$project"
    ' _ "$lib" "$cache" "$PROJECT_DIR"
    [ "$status" -eq 0 ]; [[ "$output" == *app.js* ]]
    [ "$(wc -l < "$INDEX_SCAN_LOG" | tr -d ' ')" -eq 2 ]
    [ "$(wc -l < "$INDEX_HASH_LOG" | tr -d ' ')" -ge 3 ]
  done
}

@test "R4 L2: same-inode index rewrites with restored mtime invalidate old stamps" {
  local lib cache alternate project attempt
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    fixture "inplace-$(printf '%s' "$lib" | cksum | awk '{print $1}')"
    project="$PROJECT_DIR"
    git -C "$project" update-index --assume-unchanged notes.md
    alternate="$BATS_TEST_TMPDIR/alternate-$(printf '%s' "$lib" | cksum | awk '{print $1}')"
    cp "$project/.git/index" "$alternate"
    GIT_INDEX_FILE="$alternate" git -C "$project" update-index --assume-unchanged app.js
    [ "$(wc -c < "$project/.git/index")" -eq "$(wc -c < "$alternate")" ]
    # Retry only if the operating system crossed a whole-second boundary. This
    # makes the oracle specifically require ctime's sub-second component.
    for attempt in 1 2 3 4 5 6; do
      cache="$BATS_TEST_TMPDIR/inplace-$attempt-$(printf '%s' "$lib" | cksum | awk '{print $1}')"
      mkdir -p "$cache"
      run env GIT_OPTIONAL_LOCKS=0 /bin/bash -c '
        . "$1"; __se_flag_cache="$2"; __se_cache_epoch=$(($(date +%s) + 10)); project="$3"; alt="$4"; info="$5"
        python3 -I - "$project/.git/index" "$info" <<"PY"
import json, os, sys, time
fraction = time.time() % 1
if fraction > 0.35:
    time.sleep(1 - fraction + 0.01)
p = sys.argv[1]; st = os.stat(p)
os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
st = os.stat(p)
with open(sys.argv[2], "w") as f:
    json.dump([st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns], f)
PY
        first=$(_se_unmasked_index "$project") || exit 1
        [ -n "$first" ] || exit 1
        before=$(tr "\0" "\n" < "$first/paths")
        rm -rf "${first:?}"
        case "$before" in *notes.md*) ;; *) exit 1 ;; esac
        python3 -I - "$project/.git/index" "$alt" "$info" <<"PY"
import json, os, sys
p, alternate, info = sys.argv[1:]
with open(info) as f:
    ino, size, mtime_ns, ctime_ns = json.load(f)
data = open(alternate, "rb").read()
assert len(data) == size
st = os.stat(p)
with open(p, "r+b", buffering=0) as f:
    f.write(data)
os.utime(p, ns=(st.st_atime_ns, mtime_ns))
after = os.stat(p)
assert (after.st_ino, after.st_size, after.st_mtime_ns) == (ino, size, mtime_ns)
if after.st_ctime_ns // 10**9 != ctime_ns // 10**9 or after.st_ctime_ns == ctime_ns:
    sys.exit(75)
PY
        rc=$?; [ "$rc" -eq 0 ] || exit "$rc"
        second=$(_se_unmasked_index "$project") || exit 1
        [ -n "$second" ] || exit 1
        after=$(tr "\0" "\n" < "$second/paths")
        rm -rf "${second:?}"
        case "$after" in *app.js*notes.md*) exit 0 ;; *) printf "stale flags: %s\n" "$after"; exit 1 ;; esac
      ' _ "$lib" "$cache" "$project" "$alternate" "$BATS_TEST_TMPDIR/index-info"
      [ "$status" -eq 75 ] || break
      # Restore the original index in place before retrying the timed window.
      GIT_INDEX_FILE="$alternate" git -C "$project" update-index --no-assume-unchanged app.js
      cp "$alternate" "$project/.git/index"
      GIT_INDEX_FILE="$alternate" git -C "$project" update-index --assume-unchanged app.js
    done
    [ "$status" -eq 0 ] || { echo "in-place stamp test failed (rc=$status): $output"; false; }
  done
}

@test "R3 L8: an explicitly selected index remains authoritative" {
  local lib cache alternate="$BATS_TEST_TMPDIR/other.index"
  fixture alternate-index
  cp "$PROJECT_DIR/.git/index" "$alternate"
  printf 'staged only in alternate\n' >> "$PROJECT_DIR/app.js"
  GIT_INDEX_FILE="$alternate" git -C "$PROJECT_DIR" add app.js
  GIT_INDEX_FILE="$alternate" git -C "$PROJECT_DIR" update-index --assume-unchanged app.js
  cp "$PROJECT_DIR/app.js" "$BATS_TEST_TMPDIR/alternate-clean"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    cp "$BATS_TEST_TMPDIR/alternate-clean" "$PROJECT_DIR/app.js"
    cache="$BATS_TEST_TMPDIR/alternate-$(printf '%s' "$lib" | cksum | awk '{print $1}')"
    mkdir -p "$cache"
    run env GIT_INDEX_FILE="$alternate" bash -c '
      . "$1"; __se_flag_cache="$2"; __se_cache_epoch=$(date +%s)
      _se_flagged_changed_lines "$3"
    ' _ "$lib" "$cache" "$PROJECT_DIR"
    [ "$status" -eq 0 ]; [ -z "$output" ]
    printf 'unstaged hidden change\n' >> "$PROJECT_DIR/app.js"
    run env GIT_INDEX_FILE="$alternate" bash -c '
      . "$1"; __se_flag_cache="$2"; __se_cache_epoch=$(date +%s)
      _se_flagged_changed_lines "$3"
    ' _ "$lib" "$cache" "$PROJECT_DIR"
    [ "$status" -eq 0 ]; [[ "$output" == *app.js* ]]
  done
}

@test "R3 L8: an index symlink cannot hide changes to its target" {
  local lib cache project
  make_index_scan_counter
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    fixture "index-link-$(printf '%s' "$lib" | cksum | awk '{print $1}')"
    project="$PROJECT_DIR"
    mv "$project/.git/index" "$project/.git/index-real"
    ln -s index-real "$project/.git/index"
    cache="$BATS_TEST_TMPDIR/link-$(printf '%s' "$lib" | cksum | awk '{print $1}')"
    mkdir -p "$cache"
    : > "$INDEX_SCAN_LOG"
    run env PATH="$COUNTER_BIN:$PATH" bash -c '
      . "$1"; __se_flag_cache="$2"; __se_cache_epoch=$(($(date +%s) + 10)); project="$3"
      _se_flagged_changed_lines "$project" || exit 1
      GIT_INDEX_FILE="$project/.git/index-real" git -C "$project" update-index --assume-unchanged app.js || exit 1
      printf "changed through link\n" >> "$project/app.js"
      _se_flagged_changed_lines "$project"
    ' _ "$lib" "$cache" "$project"
    [ "$status" -eq 0 ]; [[ "$output" == *app.js* ]]
    [ "$(wc -l < "$INDEX_SCAN_LOG" | tr -d ' ')" -eq 2 ]
  done
}

@test "R3 L8: sparse paths appearing after a cached scan remain visible" {
  local lib cache
  make_index_scan_counter
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    fixture "sparse-cache-${lib##*/}-$(printf '%s' "$lib" | cksum | awk '{print $1}')"
    git -C "$PROJECT_DIR" config core.sparseCheckout true
    git -C "$PROJECT_DIR" update-index --skip-worktree app.js
    mv "$PROJECT_DIR/app.js" "$BATS_TEST_TMPDIR/sparse-original"
    cache="$BATS_TEST_TMPDIR/sparse-shared-cache"
    mkdir -p "$cache"
    : > "$INDEX_SCAN_LOG"
    run env PATH="$COUNTER_BIN:$PATH" bash -c '
      . "$1"; __se_flag_cache="$2"; project="$3"
      _se_flagged_changed_lines "$project" || exit 1
      cp "$4" "$project/app.js"; printf "new content\n" >> "$project/app.js"
      _se_flagged_changed_lines "$project"
    ' _ "$lib" "$cache" "$PROJECT_DIR" "$BATS_TEST_TMPDIR/sparse-original"
    [ "$status" -eq 0 ]
    [[ "$output" == *app.js* ]] || false
    [ "$(wc -l < "$INDEX_SCAN_LOG" | tr -d ' ')" -eq 1 ]
  done
}

@test "R3 L8: failed index-cache validation blocks instead of certifying clean" {
  local h hook dir="$BATS_TEST_TMPDIR/hash-failure" real_git
  mkdir -p "$dir"
  real_git="$(command -v git)"
  cat > "$dir/git" <<'EOF'
#!/bin/sh
for arg in "$@"; do [ "$arg" != hash-object ] || exit 73; done
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$dir/git"
  for h in claude codex; do
    fixture "hash-error-$h"
    printf 'changed\n' >> "$PROJECT_DIR/app.js"
    if [ "$h" = claude ]; then hook="$HOOKS_DIR/stop-verify.sh"; else hook="$CODEX_HOOKS_DIR/stop-verify.sh"; fi
    run env PATH="$dir:$PATH" REAL_GIT="$real_git" bash "$hook" <<<'{"last_assistant_message":"Done."}'
    if [ "$h" = claude ]; then [ "$status" -eq 2 ]; else [ "$status" -eq 0 ]; fi
    printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("git changed files:"))' >/dev/null
    run bash "$hook" <<<'{"last_assistant_message":"Done. <!-- dod-receipt cmd=fixture exit=0 diff=+1 --> <!-- follow-ups: none -->"}'
    [ "$status" -eq 0 ]; [[ "$output" != *'"decision":"block"'* ]]
  done
}

@test "R3 L8: the private index cache is removed on pass and block" {
  local h hook temp="$BATS_TEST_TMPDIR/hook-tmp"
  mkdir -p "$temp"
  for h in claude codex; do
    fixture "cleanup-$h"
    printf 'changed\n' >> "$PROJECT_DIR/app.js"
    if [ "$h" = claude ]; then hook="$HOOKS_DIR/stop-verify.sh"; else hook="$CODEX_HOOKS_DIR/stop-verify.sh"; fi
    run env TMPDIR="$temp" bash "$hook" <<<'{"last_assistant_message":"Done."}'
    if [ "$h" = claude ]; then [ "$status" -eq 2 ]; else [ "$status" -eq 0 ]; fi
    printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
    [ -z "$(find "$temp" -name 'trellis-stop-flags.*' -print)" ]
    run env TMPDIR="$temp" bash "$hook" <<<'{"last_assistant_message":"Done. <!-- dod-receipt cmd=fixture exit=0 diff=+1 --> <!-- follow-ups: none -->"}'
    [ "$status" -eq 0 ]; [[ "$output" != *'"decision":"block"'* ]]
    [ -z "$(find "$temp" -name 'trellis-stop-flags.*' -print)" ]
  done
}

@test "R2 M1: unflagged index entries do not each enter a bash read loop" {
  fixture large-clean-index
  local oid lib trace="$BATS_TEST_TMPDIR/read-trace"
  oid="$(printf 'fixture\n' | git -C "$PROJECT_DIR" hash-object -w --stdin)"
  # Thousands of index entries need no on-disk files for this enumeration test.
  awk -v oid="$oid" 'BEGIN { for (i=0; i<3000; i++) printf "100644 %s\tbulk/%05d.js%c", oid, i, 0 }' \
    | git -C "$PROJECT_DIR" update-index -z --index-info
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    : > "$trace"
    run env READ_TRACE="$trace" bash -c '
      source "$1"
      read() { printf x >> "$READ_TRACE"; builtin read "$@"; }
      _se_unmasked_index "$2"
    ' _ "$lib" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(wc -c < "$trace" | tr -d " ")" -le 3 ]
  done
}

@test "R2 M1: a no-flags index still works when Perl is absent" {
  fixture no-perl
  local bin="$BATS_TEST_TMPDIR/no-perl" lib
  mkdir -p "$bin"
  ln -s "$(command -v git)" "$bin/git"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    run env PATH="$bin" /bin/bash -c 'source "$1"; _se_unmasked_index "$2"' _ "$lib" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "R2 M1: failed index enumeration cannot read as no flagged entries" {
  fixture index-error
  local bin="$BATS_TEST_TMPDIR/broken-index" real_git lib
  mkdir -p "$bin"
  real_git="$(command -v git)"
  cat > "$bin/git" <<'EOF'
#!/bin/sh
for arg in "$@"; do [ "$arg" != -v ] || exit 73; done
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$bin/git"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    run env PATH="$bin:$PATH" REAL_GIT="$real_git" /bin/bash -c 'source "$1"; _se_unmasked_index "$2"' _ "$lib" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

@test "143-stop flagged code edits demand a receipt and execute verification" {
  local h flag
  for h in claude codex; do
    for flag in assume-unchanged skip-worktree; do
      fixture "$h-$flag"
      git -C "$PROJECT_DIR" update-index "--$flag" app.js
      prompt "$h"
      stop "$h"
      [ "$status" -eq 0 ]
      [ ! -e "$RUN_MARKER" ]
      prompt "$h"
      printf 'export const y = 2;\n' >> "$PROJECT_DIR/app.js"
      stop "$h"
      if [ "$h" = claude ]; then [ "$status" -eq 2 ]; else [ "$status" -eq 0 ]; fi
      printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("receipts:"))' >/dev/null
      [ -s "$RUN_MARKER" ]
    done
  done
}

@test "143-stop toggling a clean visibility flag is not a code edit" {
  local h flag
  for h in claude codex; do
    for flag in assume-unchanged skip-worktree; do
      fixture "toggle-$h-$flag"
      prompt "$h"
      git -C "$PROJECT_DIR" update-index "--$flag" app.js
      stop "$h"
      [ "$status" -eq 0 ]
      [[ "$output" != *'"decision":"block"'* ]] || false
      [ ! -e "$RUN_MARKER" ]
    done
  done
}

@test "143-stop flagging a pre-existing dirty file does not invent a turn edit" {
  local h flag
  for h in claude codex; do
    for flag in assume-unchanged skip-worktree; do
      fixture "dirty-toggle-$h-$flag"
      printf 'pre-existing change\n' >> "$PROJECT_DIR/app.js"
      prompt "$h"
      git -C "$PROJECT_DIR" update-index "--$flag" app.js
      stop "$h"
      [ "$status" -eq 0 ] || { echo "$h $flag: $output"; false; }
      [[ "$output" != *'"decision":"block"'* ]] || false
      [ ! -e "$RUN_MARKER" ]
    done
  done
}

@test "143-stop flag inspection detects same-size edits and never mutates the real index" {
  fixture index-integrity
  git -C "$PROJECT_DIR" update-index --assume-unchanged app.js
  git -C "$PROJECT_DIR" update-index --skip-worktree notes.md
  git -C "$PROJECT_DIR" config core.trustctime false
  cp "$PROJECT_DIR/.git/index" "$BATS_TEST_TMPDIR/index-before"
  python3 -I -c 'import os,pathlib,sys
for name in sys.argv[1:]:
 p=pathlib.Path(name); s=p.stat(); data=p.read_bytes(); p.write_bytes(bytes([data[0] ^ 1]) + data[1:]); os.utime(p, ns=(s.st_atime_ns, s.st_mtime_ns))' "$PROJECT_DIR/app.js" "$PROJECT_DIR/notes.md"
  local lib
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    run bash -c 'source "$1"; _se_flagged_changed_lines "$2"' _ "$lib" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'app.js'* ]] || false
    [[ "$output" == *'notes.md'* ]] || false
    cmp "$PROJECT_DIR/.git/index" "$BATS_TEST_TMPDIR/index-before"
    [ "$(git -C "$PROJECT_DIR" ls-files -v app.js)" = 'h app.js' ]
    [ "$(git -C "$PROJECT_DIR" ls-files -v notes.md)" = 'S notes.md' ]
  done
}

@test "143-stop flagged inspection supports a split index without changing it" {
  fixture split-index
  git -C "$PROJECT_DIR" update-index --split-index
  git -C "$PROJECT_DIR" update-index --skip-worktree app.js
  cp "$PROJECT_DIR/.git/index" "$BATS_TEST_TMPDIR/split-before"
  printf 'flagged change\n' >> "$PROJECT_DIR/app.js"
  local lib
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    run bash -c 'source "$1"; _se_flagged_changed_lines "$2"' _ "$lib" "$PROJECT_DIR"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'app.js'* ]] || false
    cmp "$PROJECT_DIR/.git/index" "$BATS_TEST_TMPDIR/split-before"
  done
}

@test "143-stop expected sparse checkout absences do not turn docs into code edits" {
  local h
  for h in claude codex; do
    fixture "sparse-$h"
    git -C "$PROJECT_DIR" config core.sparseCheckout true
    printf '/*\n!/app.js\n' > "$PROJECT_DIR/.git/info/sparse-checkout"
    git -C "$PROJECT_DIR" update-index --skip-worktree app.js
    mv "$PROJECT_DIR/app.js" "$BATS_TEST_TMPDIR/absent-$h"
    prompt "$h"
    printf 'more documentation\n' >> "$PROJECT_DIR/notes.md"
    stop "$h"
    [ "$status" -eq 0 ] || { echo "$h: $output"; false; }
    [[ "$output" != *'"decision":"block"'* ]] || false
    [ ! -e "$RUN_MARKER" ]
  done
}

@test "143-stop flagged inspection errors fail closed rather than certifying clean" {
  local h real_git dir temp
  real_git="$(command -v git)"
  dir="$BATS_TEST_TMPDIR/failing-git"
  mkdir -p "$dir"
  cat > "$dir/git" <<'EOF'
#!/bin/sh
for arg in "$@"; do [ "$arg" != --stage ] || exit 73; done
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$dir/git"
  export REAL_GIT="$real_git"
  for h in claude codex; do
    fixture "error-$h"
    git -C "$PROJECT_DIR" update-index --assume-unchanged app.js
    prompt "$h"
    printf 'changed\n' >> "$PROJECT_DIR/app.js"
    temp="$BATS_TEST_TMPDIR/failure-tmp-$h"; mkdir -p "$temp"
    PATH="$dir:$PATH" TMPDIR="$temp" stop "$h"
    if [ "$h" = claude ]; then [ "$status" -eq 2 ]; else [ "$status" -eq 0 ]; fi
    printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("git changed files:"))' >/dev/null
    [ -z "$(find "$temp" -type d -name 'trellis-flags.*' -print)" ] || { echo "$h left an unmasked temporary index"; return 1; }
  done
}

@test "143-stop flagged documentation-only edits remain exempt" {
  local h flag
  for h in claude codex; do
    for flag in assume-unchanged skip-worktree; do
      fixture "docs-$h-$flag"
      git -C "$PROJECT_DIR" update-index "--$flag" notes.md
      prompt "$h"
      printf 'more documentation\n' >> "$PROJECT_DIR/notes.md"
      stop "$h"
      [ "$status" -eq 0 ]
      [[ "$output" != *'"decision":"block"'* ]] || false
      [ ! -e "$RUN_MARKER" ]
    done
  done
}
