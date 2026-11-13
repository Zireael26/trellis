#!/usr/bin/env bats
# Compare the batch-backed listings with the unchanged shell classifier. The
# test runner's Git fence stays in PATH for *all* fixture and classifier calls.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/lib/local-registry.sh"

setup() {
  # The launcher runs under env -i, so the batch never sees a caller's GIT_*
  # variables; the helper (rightly) refuses any it does not allow, which would
  # make these tests depend on the developer's shell (an exported GIT_EDITOR).
  local name
  for name in $(compgen -e); do
    case "$name" in
      GIT_CONFIG_GLOBAL|GIT_CONFIG_NOSYSTEM|GIT_OPTIONAL_LOCKS|GIT_TERMINAL_PROMPT) ;;
      GIT_*) unset "$name" ;;
    esac
  done
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/registry-batch.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export TRELLIS_HOME="$SANDBOX/home" BATCH_PROOF="$SANDBOX/proof.json"
  mkdir -m 700 "$TRELLIS_HOME"
  MAIN="$SANDBOX/main repo"
  LINKED="$SANDBOX/linked repo"
  FOREIGN="$SANDBOX/foreign repo"
  mkdir -p "$MAIN" "$FOREIGN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.name Fixture
  git -C "$MAIN" config user.email fixture@example.invalid
  printf 'fixture\n' > "$MAIN/file"
  git -C "$MAIN" add file
  git -C "$MAIN" commit -qm fixture
  git -C "$MAIN" worktree add -q -b topic "$LINKED"
  git -C "$FOREIGN" init -q -b main
  git -C "$FOREIGN" config user.name Fixture
  git -C "$FOREIGN" config user.email fixture@example.invalid
  printf 'foreign\n' > "$FOREIGN/file"
  git -C "$FOREIGN" add file
  git -C "$FOREIGN" commit -qm fixture
  bash -c '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" personal alpha "$2" "" "[]" "" "{}"' _ "$LIB" "$MAIN"
  bash -c '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" personal alpha "$2" "" "[]" "" "{}"' _ "$LIB" "$LINKED"
  bash -c '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" work beta "$2" "" "[]" "" "{}"' _ "$LIB" "$FOREIGN"
  bash -c '. "$1"; local_registry_record_unavailable_root "$TRELLIS_HOME" personal offline "$2" "{}"' _ "$LIB" "$SANDBOX/unavailable"
  cp "$TRELLIS_HOME/registry.json" "$SANDBOX/pristine.json"
}

# The production admission guard refuses the test runner's Git shim. Invoke
# the same post-admission protocol directly, never the unfenced Git binary.
# The scalar run disables just the optimization, leaving all shell functions
# and diagnostics intact. Compare bytes and exit status, not merely row counts.
compare_listing() {
  local function="$1" fleet="${2:-}" mode rc scalar_rc batch_rc
  for mode in scalar batch; do
    if env BATCH_MODE="$mode" bash -c '
      . "$1"
      if [ "$BATCH_MODE" = scalar ]; then
        _local_registry_batch_run() { return 1; }
      else
        _local_registry_batch_run() {
          _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)" || return 1
          _local_registry_batch_recheck "$2" "$3" || return 1
          cp "$3/proof" "$BATCH_PROOF"
        }
      fi
      "$2" "$TRELLIS_HOME" "$3"
    ' _ "$LIB" "$function" "$fleet" > "$SANDBOX/$mode.out" 2> "$SANDBOX/$mode.err"; then
      rc=0
    else
      rc=$?
    fi
    if [ "$mode" = scalar ]; then scalar_rc="$rc"; else batch_rc="$rc"; fi
  done
  [ "$scalar_rc" -eq "$batch_rc" ] || { echo "exit mismatch: $scalar_rc vs $batch_rc"; return 1; }
  cmp "$SANDBOX/scalar.out" "$SANDBOX/batch.out" || return 1
  cmp "$SANDBOX/scalar.err" "$SANDBOX/batch.err" || return 1
}

compare_both() {
  compare_listing local_registry_list_json "${1:-}" || return 1
  compare_listing local_registry_list_diagnostic_json "${1:-}" || return 1
}

@test "one batch and shell classifier agree on mixed healthy, unavailable, foreign, symlinked, moved and corrupt rows" {
  compare_both || false
  # A passing comparison must actually exercise positive batch answers.
  jq -e 'all(.checkouts[]; . == true) and ([.rows[] | select(.)] | length) >= 4' "$BATCH_PROOF" >/dev/null || false

  # Relative global config resolves after git -C. A broken config visible only
  # in one linked worktree must not be certified from the primary's config.
  : > "$MAIN/relative-config"
  printf '[broken\n' > "$LINKED/relative-config"
  saved_global="$GIT_CONFIG_GLOBAL"
  export GIT_CONFIG_GLOBAL=relative-config
  compare_both || false
  jq -e 'all(.checkouts[]; . == false)' "$BATCH_PROOF" >/dev/null || false
  export GIT_CONFIG_GLOBAL="$saved_global"
  rm "$MAIN/relative-config" "$LINKED/relative-config"

  # A linked worktree whose .git points at a different, real checkout.
  mv "$LINKED/.git" "$LINKED/.git.saved"
  printf 'gitdir: %s/.git\n' "$FOREIGN" > "$LINKED/.git"
  compare_both || false
  jq -e 'any(.rows[]; . == true) and any(.rows[]; . == false)' "$BATCH_PROOF" >/dev/null || false
  rm "$LINKED/.git"
  mv "$LINKED/.git.saved" "$LINKED/.git"

  # Invalid linked-worktree metadata and per-worktree configuration both
  # require the scalar Git observation rather than a positive batch guess.
  gitdir="$(git -C "$LINKED" rev-parse --absolute-git-dir)"
  cp "$gitdir/HEAD" "$SANDBOX/HEAD.saved"
  printf 'broken HEAD\n' > "$gitdir/HEAD"
  compare_both || false
  cp "$SANDBOX/HEAD.saved" "$gitdir/HEAD"
  git -C "$MAIN" config extensions.worktreeConfig true
  printf '[core]\n\tworktree = %s\n' "$FOREIGN" > "$gitdir/config.worktree"
  compare_both || false
  jq -e 'any(.checkouts[]; . == false)' "$BATCH_PROOF" >/dev/null || false
  rm "$gitdir/config.worktree"
  git -C "$MAIN" config --unset extensions.worktreeConfig

  # A stored canonical root replaced by an alias, and then a moved checkout.
  mv "$LINKED" "$LINKED.moved"
  ln -s "$LINKED.moved" "$LINKED"
  compare_both || false
  rm "$LINKED"
  mv "$LINKED.moved" "$LINKED"
  mv "$MAIN" "$MAIN.moved"
  compare_both || false
  mv "$MAIN.moved" "$MAIN"

  # A wrong worktree ID must be classified before reachability. A healthy
  # sibling in the same batch remains fast while the corrupt row falls back.
  jq '.projects["personal/alpha"].checkouts |= with_entries(
      .value.worktrees |= (to_entries | .[0].key = ("0" * 64) | from_entries))' \
    "$SANDBOX/pristine.json" > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  compare_both || false
  jq -e 'any(.rows[]; . == true) and any(.rows[]; . == false)' "$BATCH_PROOF" >/dev/null || false
  compare_both personal || false
  compare_both work || false

  printf '{broken\n' > "$TRELLIS_HOME/registry.json"
  compare_both || false
}

@test "healthy linked rows share three Git observations per checkout per pass" {
  export FENCED_GIT="$(command -v git)" COUNT_LOG="$SANDBOX/git-count.log"
  local counter="$SANDBOX/git-count"
  printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$*" >> "$COUNT_LOG"' 'exec "$FENCED_GIT" "$@"' > "$counter"
  chmod 700 "$counter"
  export BATCH_COUNTER="$counter"
  bash -c '
    . "$1"
    _local_registry_batch_run() {
      _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$BATCH_COUNTER" || return 1
      _local_registry_batch_recheck "$2" "$3" || return 1
      cp "$3/proof" "$BATCH_PROOF"
    }
    local_registry_list_json "$TRELLIS_HOME" >/dev/null
  ' _ "$LIB" || false
  jq -e 'all(.checkouts[]; . == true) and ([.rows[] | select(.)] | length) >= 4' "$BATCH_PROOF" >/dev/null || false
  # Initial proof plus the immediate and post-miss full-identity rechecks.
  [ "$(wc -l < "$COUNT_LOG" | tr -d ' ')" -eq 18 ] || false
}

@test "in-memory manifest programs classify identically without snapshot paths" {
  export BATCH_SOURCE="$REPO_ROOT/scripts/lib/registry_identity_batch.py"
  export FS_SOURCE="$REPO_ROOT/scripts/lib/attachment_fs.py"
  for function in local_registry_list_json local_registry_list_diagnostic_json; do
    bash -c '. "$1"; _local_registry_batch_run() { return 1; }; "$2" "$TRELLIS_HOME"' \
      _ "$LIB" "$function" > "$SANDBOX/scalar.out" 2> "$SANDBOX/scalar.err"
    bash -c '
      . "$1"
      _TRELLIS_BUNDLED_REGISTRY_BATCH_PROGRAM="$(< "$BATCH_SOURCE")"
      _TRELLIS_BUNDLED_ATTACHMENT_FS_PROGRAM="$(< "$FS_SOURCE")"
      _local_registry_batch_run() {
        _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)" 1 || return 1
        _local_registry_batch_recheck "$2" "$3" || return 1
        cp "$3/proof" "$BATCH_PROOF"
      }
      "$2" "$TRELLIS_HOME"
    ' _ "$LIB" "$function" > "$SANDBOX/batch.out" 2> "$SANDBOX/batch.err"
    cmp "$SANDBOX/scalar.out" "$SANDBOX/batch.out" || false
    cmp "$SANDBOX/scalar.err" "$SANDBOX/batch.err" || false
    jq -e 'all(.checkouts[]; . == true) and ([.rows[] | select(.)] | length) >= 4' "$BATCH_PROOF" >/dev/null || false
  done
}

@test "sync reuses a pinned root proof and falls back after Git or registry drift" {
  mkdir -m 700 "$SANDBOX/pins" "$SANDBOX/git-config"
  printf '[user]\n name = Fixture\n email = fixture@example.invalid\n' > "$SANDBOX/git-config/config"
  # Pins apply only under an explicit global config and no system config
  # (write_sync_pins); set both here rather than inherit them from the runner,
  # which clears GIT_CONFIG_NOSYSTEM in its hook-safe environment.
  export GIT_CONFIG_GLOBAL="$SANDBOX/git-config/config" GIT_CONFIG_NOSYSTEM=1 SYNC_PROOF_DIR="$SANDBOX/pins"
  export TEST_LINKED="$LINKED" TEST_MAIN="$MAIN" TEST_FOREIGN="$FOREIGN" TEST_MARK="$SANDBOX/resolver-called"
  : > "$TEST_MARK"
  bash -c '
    . "$1"
    _local_registry_batch_run() {
      _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)" 0 "$4" "$5" || return 1
      _local_registry_batch_recheck "$2" "$3"
    }
    expected="$(local_registry_resolve_root "$TRELLIS_HOME" "$TEST_LINKED")" || exit 10
    linked_id="$(printf "%s" "$TEST_LINKED" | sha256sum | awk "{print \$1}")"
    main_id="$(printf "%s" "$TEST_MAIN" | sha256sum | awk "{print \$1}")"
    before="$(_local_registry_diagnostic_token "$TRELLIS_HOME")" || exit 11
    _local_registry_list_json_for_sync "$TRELLIS_HOME" "" "$SYNC_PROOF_DIR" >/dev/null || exit 12
    after="$(_local_registry_diagnostic_token "$TRELLIS_HOME")" || exit 13
    [ "$before" = "$after" ] && [ "$_LOCAL_REGISTRY_SYNC_PROOF_READY" = 1 ] || exit 14
    [ -f "$SYNC_PROOF_DIR/$linked_id.ready" ] && [ -f "$SYNC_PROOF_DIR/$main_id.ready" ] || exit 15
    eval "$(awk '\''$0 == "sync_resolve_root() {" {in_fn=1} in_fn {print} in_fn && $0 == "}" {exit}'\'' "$2")"
    HOME_PATH="$TRELLIS_HOME"; SYNC_PROOF_STAT_OS="$(/usr/bin/uname -s)"
    local_registry_resolve_root() { printf "called\\n" >> "$TEST_MARK"; _local_registry_resolve_root "$1" "$2" 0; }
    actual="$(sync_resolve_root "$TEST_LINKED" "$linked_id")" || exit 16
    [ "$actual" = "$expected" ] && [ ! -s "$TEST_MARK" ] || exit 17
    for suffix in resolution watched ancestors; do
      proof="$SYNC_PROOF_DIR/$linked_id.$suffix"
      cp "$proof" "$proof.saved"
      : > "$proof"; : > "$TEST_MARK"
      set -u
      actual="$(sync_resolve_root "$TEST_LINKED" "$linked_id")" || exit 22
      set +u
      [ "$actual" = "$expected" ] && [ -s "$TEST_MARK" ] || exit 23
      cp "$proof.saved" "$proof"
    done
    : > "$TEST_MARK"
    mv "$TEST_LINKED/.git" "$TEST_LINKED/.git.saved"
    printf "gitdir: %s/.git\\n" "$TEST_FOREIGN" > "$TEST_LINKED/.git"
    sync_resolve_root "$TEST_LINKED" "$linked_id" >/dev/null 2>&1 && exit 18
    [ -s "$TEST_MARK" ] || exit 19
    : > "$TEST_MARK"
    printf " " >> "$TRELLIS_HOME/registry.json"
    sync_resolve_root "$TEST_MAIN" "$main_id" >/dev/null || exit 20
    [ -s "$TEST_MARK" ] || exit 21
  ' _ "$LIB" "$REPO_ROOT/scripts/sync-hooks.sh" || false
}

@test "a root lost after the batch observation is reclassified by the shell" {
  export LATE_ROOT="$LINKED"
  for function in local_registry_list_json local_registry_list_diagnostic_json; do
    bash -c '
      . "$1"
      _local_registry_batch_run() {
        _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)" || return 1
        mv "$LATE_ROOT" "$LATE_ROOT.moved" || return 1
        _local_registry_batch_recheck "$2" "$3" || return 1
        cp "$3/proof" "$BATCH_PROOF"
      }
      "$2" "$TRELLIS_HOME"
    ' _ "$LIB" "$function" > "$SANDBOX/batch.out" 2> "$SANDBOX/batch.err"
    batch_rc="$?"
    bash -c '. "$1"; _local_registry_batch_run() { return 1; }; "$2" "$TRELLIS_HOME"' \
      _ "$LIB" "$function" > "$SANDBOX/scalar.out" 2> "$SANDBOX/scalar.err"
    scalar_rc="$?"
    [ "$batch_rc" -eq "$scalar_rc" ] || false
    cmp "$SANDBOX/scalar.out" "$SANDBOX/batch.out" || false
    cmp "$SANDBOX/scalar.err" "$SANDBOX/batch.err" || false
    jq -e 'any(.rows[]; . == false)' "$BATCH_PROOF" >/dev/null || false
    mv "$LINKED.moved" "$LINKED"
  done
}

@test "symlink and gitdir swaps after batch observation fall back to the shell" {
  export LATE_ROOT="$LINKED" LATE_FOREIGN="$FOREIGN"
  local function swap rc scalar_rc
  for function in local_registry_list_json local_registry_list_diagnostic_json; do
    for swap in symlink gitdir; do
      export SWAP_KIND="$swap"
      if bash -c '
        . "$1"
        _local_registry_batch_run() {
          _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)" || return 1
          if [ "$SWAP_KIND" = symlink ]; then
            mv "$LATE_ROOT" "$LATE_ROOT.moved" && ln -s "$LATE_FOREIGN" "$LATE_ROOT" || return 1
          else
            mv "$LATE_ROOT/.git" "$LATE_ROOT/.git.saved" || return 1
            printf "gitdir: %s/.git\n" "$LATE_FOREIGN" > "$LATE_ROOT/.git" || return 1
          fi
          _local_registry_batch_recheck "$2" "$3"
        }
        "$2" "$TRELLIS_HOME"
      ' _ "$LIB" "$function" > "$SANDBOX/batch.out" 2> "$SANDBOX/batch.err"; then rc=0; else rc=$?; fi
      if bash -c '. "$1"; _local_registry_batch_run() { return 1; }; "$2" "$TRELLIS_HOME"' \
        _ "$LIB" "$function" > "$SANDBOX/scalar.out" 2> "$SANDBOX/scalar.err"; then scalar_rc=0; else scalar_rc=$?; fi
      [ "$rc" -eq "$scalar_rc" ] || false
      cmp "$SANDBOX/scalar.out" "$SANDBOX/batch.out" || false
      cmp "$SANDBOX/scalar.err" "$SANDBOX/batch.err" || false
      if [ "$function" = local_registry_list_json ]; then
        jq -e --arg root "$LINKED" 'any(.entries[]; .root == $root and .availability == "identity_error")' "$SANDBOX/batch.out" >/dev/null || false
      else
        jq -e --arg root "$LINKED" 'any(.entries[]; .root == $root and .identity.state == "identity_error")' "$SANDBOX/batch.out" >/dev/null || false
      fi
      if [ "$swap" = symlink ]; then rm "$LINKED"; mv "$LINKED.moved" "$LINKED"; else rm "$LINKED/.git"; mv "$LINKED/.git.saved" "$LINKED/.git"; fi
    done
  done
}

@test "a swap during scalar misses is rechecked and reclassified before projection" {
  # Force one genuine scalar miss while another worktree starts as positive.
  jq '.projects["work/beta"].checkouts |= with_entries(
      .value.worktrees |= (to_entries | .[0].key = ("0" * 64) | from_entries))' \
    "$SANDBOX/pristine.json" > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  export LATE_ROOT="$LINKED" LATE_FOREIGN="$FOREIGN" LATE_MARK="$SANDBOX/late-mark"
  local function rc scalar_rc
  for function in local_registry_list_json local_registry_list_diagnostic_json; do
    rm -f "$LATE_MARK"
    if bash -c '
      . "$1"
      _local_registry_batch_run() {
        _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)" || return 1
        _local_registry_batch_recheck "$2" "$3"
      }
      def="$(declare -f local_registry_list_row_availability)"
      eval "${def/local_registry_list_row_availability/_original_availability}"
      def="$(declare -f local_registry_diagnostic_identity)"
      eval "${def/local_registry_diagnostic_identity/_original_diagnostic}"
      swap_once() {
        [ -e "$LATE_MARK" ] && return 0
        : > "$LATE_MARK" || return 1
        mv "$LATE_ROOT/.git" "$LATE_ROOT/.git.saved" || return 1
        printf "gitdir: %s/.git\n" "$LATE_FOREIGN" > "$LATE_ROOT/.git"
      }
      local_registry_list_row_availability() { swap_once || return 1; _original_availability "$@"; }
      local_registry_diagnostic_identity() { swap_once || return 1; _original_diagnostic "$@"; }
      "$2" "$TRELLIS_HOME"
    ' _ "$LIB" "$function" > "$SANDBOX/batch.out" 2> "$SANDBOX/batch.err"; then rc=0; else rc=$?; fi
    [ -e "$LATE_MARK" ] || { echo 'scalar miss did not trigger swap'; false; }
    if bash -c '. "$1"; _local_registry_batch_run() { return 1; }; "$2" "$TRELLIS_HOME"' \
      _ "$LIB" "$function" > "$SANDBOX/scalar.out" 2> "$SANDBOX/scalar.err"; then scalar_rc=0; else scalar_rc=$?; fi
    [ "$rc" -eq "$scalar_rc" ] || false
    cmp "$SANDBOX/scalar.out" "$SANDBOX/batch.out" || false
    if [ "$function" = local_registry_list_json ]; then
      jq -e --arg root "$LINKED" 'any(.entries[]; .root == $root and .availability == "identity_error")' "$SANDBOX/batch.out" >/dev/null || false
    else
      jq -e --arg root "$LINKED" 'any(.entries[]; .root == $root and .identity.state == "identity_error")' "$SANDBOX/batch.out" >/dev/null || false
    fi
    rm "$LINKED/.git"; mv "$LINKED/.git.saved" "$LINKED/.git"
  done
}

@test "a late checkout drift folds onto rows already classified as scalar misses" {
  jq '.projects["personal/alpha"].checkouts |= with_entries(
      .value.worktrees |= (to_entries | .[0].key = ("0" * 64) | from_entries))' \
    "$SANDBOX/pristine.json" > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  export LATE_CHECKOUT="$MAIN" LATE_FOREIGN="$FOREIGN" LATE_MARK="$SANDBOX/late-checkout"
  local function rc scalar_rc
  for function in local_registry_list_json local_registry_list_diagnostic_json; do
    rm -f "$LATE_MARK"
    if bash -c '
      . "$1"
      _local_registry_batch_run() {
        _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)" || return 1
        _local_registry_batch_recheck "$2" "$3"
      }
      def="$(declare -f local_registry_list_row_availability)"
      eval "${def/local_registry_list_row_availability/_original_availability}"
      def="$(declare -f local_registry_diagnostic_identity)"
      eval "${def/local_registry_diagnostic_identity/_original_diagnostic}"
      swap_once() {
        [ -e "$LATE_MARK" ] && return 0
        [ "$(printf "%s\n" "$1" | jq -r .kind)" = worktree ] || return 0
        : > "$LATE_MARK" || return 1
        mv "$LATE_CHECKOUT/.git" "$LATE_CHECKOUT/.git.saved" || return 1
        ln -s "$LATE_FOREIGN/.git" "$LATE_CHECKOUT/.git"
      }
      local_registry_list_row_availability() { swap_once "$1" || return 1; _original_availability "$@"; }
      local_registry_diagnostic_identity() { swap_once "$1" || return 1; _original_diagnostic "$@"; }
      "$2" "$TRELLIS_HOME"
    ' _ "$LIB" "$function" > "$SANDBOX/batch.out" 2> "$SANDBOX/batch.err"; then rc=0; else rc=$?; fi
    [ -e "$LATE_MARK" ] || { echo 'checkout swap was not triggered'; false; }
    if bash -c '. "$1"; _local_registry_batch_run() { return 1; }; "$2" "$TRELLIS_HOME"' \
      _ "$LIB" "$function" > "$SANDBOX/scalar.out" 2> "$SANDBOX/scalar.err"; then scalar_rc=0; else scalar_rc=$?; fi
    [ "$rc" -eq "$scalar_rc" ] || false
    cmp "$SANDBOX/scalar.out" "$SANDBOX/batch.out" || false
    if [ "$function" = local_registry_list_diagnostic_json ]; then
      jq -e 'all(.entries[] | select(.project_key == "personal/alpha");
        .identity.state == "identity_error" and .identity.scope == "checkout")' "$SANDBOX/batch.out" >/dev/null || false
    fi
    rm "$MAIN/.git"; mv "$MAIN/.git.saved" "$MAIN/.git"
  done
}

@test "recheck deltas preserve newline and backslash fields with NUL framing" {
  local dir="$SANDBOX/delta" root=$'line\nbreak\\tail'
  mkdir "$dir"
  printf '%s\n' '{"checkouts":[true],"rows":[true]}' > "$dir/proof.previous"
  printf '%s\n' '{"checkouts":[false],"rows":[false]}' > "$dir/proof"
  jq -cn --arg root "$root" '{kind:"checkout", root:$root}' > "$dir/checkouts"
  jq -cn --arg root "$root" '{kind:"worktree", root:$root}' > "$SANDBOX/rows"
  bash -c '. "$1"; _local_registry_batch_delta "$2" "$3"' _ "$LIB" "$SANDBOX/rows" "$dir" || false
  cmp "$dir/checkouts" "$dir/checkout-delta" || false
  cmp "$SANDBOX/rows" "$dir/row-delta" || false
}

@test "a failed reobservation demotes all positives to the scalar classifier" {
  export REAL_PYTHON="$(command -v python3)" OBSERVE_COUNT="$SANDBOX/observe-count"
  printf '%s\n' '#!/bin/sh' \
    '[ ! -e "$OBSERVE_COUNT" ] || exit 71' \
    ': > "$OBSERVE_COUNT"' 'exec "$REAL_PYTHON" "$@"' > "$SANDBOX/python-once"
  chmod 700 "$SANDBOX/python-once"
  export PYTHON_ONCE="$SANDBOX/python-once"
  local function
  for function in local_registry_list_json local_registry_list_diagnostic_json; do
    rm -f "$OBSERVE_COUNT"
    bash -c '. "$1"; _local_registry_batch_run() { return 1; }; "$2" "$TRELLIS_HOME"' \
      _ "$LIB" "$function" > "$SANDBOX/scalar.out" 2> "$SANDBOX/scalar.err" || false
    bash -c '
      . "$1"
      _local_registry_batch_run() {
        _local_registry_batch_execute "$1" "$2" "$3" "$PYTHON_ONCE" "$(command -v git)" || return 1
        _local_registry_batch_recheck "$2" "$3"
      }
      "$2" "$TRELLIS_HOME"
    ' _ "$LIB" "$function" > "$SANDBOX/batch.out" 2> "$SANDBOX/batch.err" || false
    [ -e "$OBSERVE_COUNT" ] || false
    cmp "$SANDBOX/scalar.out" "$SANDBOX/batch.out" || false
    # The failed helper is announced once (690a75772), then the scalar
    # classifier's own diagnostics follow unchanged.
    [ "$(head -n 1 "$SANDBOX/batch.err")" = 'trellis registry: identity batch unavailable (exit status only); classifying rows one by one' ] ||
      { cat "$SANDBOX/batch.err"; false; }
    tail -n +2 "$SANDBOX/batch.err" | cmp - "$SANDBOX/scalar.err" || false
  done
}

@test "successful but truncated checkout and row generators cannot hide rows" {
  local function mode truncate generator rc
  export REAL_JQ="$(command -v jq)"
  mkdir "$SANDBOX/truncate-bin"
  printf '%s\n' '#!/bin/sh' \
    'if [ "$1" = -c ] && [ "$2" = --arg ] && [ "$3" = fleet ]; then' \
    '  if [ "$TRUNCATE" = zero ]; then exit 0; fi' \
    '  "$REAL_JQ" "$@" | head -n 1; exit 0' \
    'fi' 'exec "$REAL_JQ" "$@"' > "$SANDBOX/truncate-bin/jq"
  chmod 700 "$SANDBOX/truncate-bin/jq"
  for function in local_registry_list_json local_registry_list_diagnostic_json; do
    for mode in scalar batch; do
      for truncate in zero one; do
        for generator in checkout row; do
          if env BATCH_MODE="$mode" TRUNCATE="$truncate" GENERATOR="$generator" \
            PATH="$SANDBOX/truncate-bin:$PATH" bash -c '
              . "$1"
              if [ "$GENERATOR" = checkout ]; then
                def="$(declare -f local_registry_checkout_rows)"
                eval "${def/local_registry_checkout_rows/_original_checkout_rows}"
                local_registry_checkout_rows() {
                  if [ "$TRUNCATE" = zero ]; then return 0; fi
                  _original_checkout_rows "$@" | head -n 1
                }
              fi
              if [ "$GENERATOR" != row ]; then PATH="${PATH#*:}"; export PATH; fi
              if [ "$BATCH_MODE" = scalar ]; then _local_registry_batch_run() { return 1; }
              else
                _local_registry_batch_run() {
                  _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)"
                }
              fi
              "$2" "$TRELLIS_HOME"
            ' _ "$LIB" "$function" > "$SANDBOX/truncated.out" 2> "$SANDBOX/truncated.err"; then rc=0; else rc=$?; fi
          [ "$rc" -eq 4 ] || { echo "$function $mode $truncate $generator returned $rc"; false; }
          [ ! -s "$SANDBOX/truncated.out" ] || { echo 'truncated generator produced a listing'; false; }
        done
      done
    done
  done
}

# A derived stream can be truncated even when its input and producer status
# looked sound. Each omission must discard the optimization or fail the list.
compare_cut_partition() {
  local function
  export CUT_PART="$1"
  for function in local_registry_list_json local_registry_list_diagnostic_json; do
    bash -c '. "$1"; _local_registry_batch_run() { return 1; }; "$2" "$TRELLIS_HOME"' \
      _ "$LIB" "$function" > "$SANDBOX/scalar.out" 2> "$SANDBOX/scalar.err" || return 1
    bash -c '
      . "$1"
      jq() {
        for argument in "$@"; do
          if [ "$CUT_PART" = checkouts ]; then
            case "$argument" in *"select(\$p[0].checkouts[\$i] | not)"*) return 0 ;; esac
          else
            case "$argument" in *"select(\$p[0].rows[\$i] | not)"*) return 0 ;; esac
          fi
        done
        command jq "$@"
      }
      _local_registry_batch_run() {
        _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)" || return 1
        _local_registry_batch_recheck "$2" "$3"
      }
      "$2" "$TRELLIS_HOME"
    ' _ "$LIB" "$function" > "$SANDBOX/batch.out" 2> "$SANDBOX/batch.err" || return 1
    cmp "$SANDBOX/scalar.out" "$SANDBOX/batch.out" || return 1
    cmp "$SANDBOX/scalar.err" "$SANDBOX/batch.err" || return 1
  done
}

@test "a truncated checkout-miss partition cannot hide checkout drift" {
  mv "$MAIN" "$MAIN.moved"
  ln -s "$FOREIGN" "$MAIN"
  mv "$LINKED" "$LINKED.moved"
  compare_cut_partition checkouts || false
  jq -e 'any(.entries[]; .project_key == "personal/alpha" and .identity.state == "identity_error")' \
    "$SANDBOX/batch.out" >/dev/null || false
}

@test "a truncated row-miss partition cannot hide a corrupt worktree" {
  jq '.projects["work/beta"].checkouts |= with_entries(
      .value.worktrees |= (to_entries | .[0].key = ("0" * 64) | from_entries))' \
    "$SANDBOX/pristine.json" > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  compare_cut_partition rows || false
  jq -e 'any(.entries[]; .project_key == "work/beta" and .identity.state == "identity_error")' \
    "$SANDBOX/batch.out" >/dev/null || false
}

@test "an exit-0 truncated late-delta stream cannot omit a demoted row" {
  jq '.projects["work/beta"].checkouts |= with_entries(
      .value.worktrees |= (to_entries | .[0].key = ("0" * 64) | from_entries))' \
    "$SANDBOX/pristine.json" > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  export LATE_CHECKOUT="$MAIN" LATE_FOREIGN="$FOREIGN" LATE_MARK="$SANDBOX/cut-delta"
  local function cut rc
  for function in local_registry_list_json local_registry_list_diagnostic_json; do
    for cut in zero one; do
      export CUT_DELTA="$cut"
      rm -f "$LATE_MARK"
      if bash -c '
        . "$1"
        jq() {
          for argument in "$@"; do
            case "$argument" in
              *"checkouts\\u0000"*)
                if [ "$CUT_DELTA" = zero ]; then return 0; fi
                command jq "$@" | python3 -I -c "import sys; d=sys.stdin.buffer.read().split(bytes([0])); sys.stdout.buffer.write(bytes([0]).join(d[:3]) + bytes([0]))"
                return 0 ;;
            esac
          done
          command jq "$@"
        }
        _local_registry_batch_run() {
          _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)" || return 1
          _local_registry_batch_recheck "$2" "$3"
        }
        def="$(declare -f local_registry_list_row_availability)"
        eval "${def/local_registry_list_row_availability/_original_availability}"
        def="$(declare -f local_registry_diagnostic_identity)"
        eval "${def/local_registry_diagnostic_identity/_original_diagnostic}"
        swap_once() {
          [ -e "$LATE_MARK" ] && return 0
          [ "$(printf "%s\n" "$1" | jq -r .kind)" = worktree ] || return 0
          : > "$LATE_MARK" || return 1
          mv "$LATE_CHECKOUT/.git" "$LATE_CHECKOUT/.git.saved" || return 1
          ln -s "$LATE_FOREIGN/.git" "$LATE_CHECKOUT/.git"
        }
        local_registry_list_row_availability() { swap_once "$1" || return 1; _original_availability "$@"; }
        local_registry_diagnostic_identity() { swap_once "$1" || return 1; _original_diagnostic "$@"; }
        "$2" "$TRELLIS_HOME"
      ' _ "$LIB" "$function" > "$SANDBOX/batch.out" 2> "$SANDBOX/batch.err"; then rc=0; else rc=$?; fi
      [ -e "$LATE_MARK" ] || { echo 'delta swap was not triggered'; false; }
      if [ "$rc" -eq 0 ]; then
        bash -c '. "$1"; _local_registry_batch_run() { return 1; }; "$2" "$TRELLIS_HOME"' \
          _ "$LIB" "$function" > "$SANDBOX/scalar.out" 2> "$SANDBOX/scalar.err" || false
        cmp "$SANDBOX/scalar.out" "$SANDBOX/batch.out" || false
      else
        [ "$rc" -eq 4 ] && [ ! -s "$SANDBOX/batch.out" ] || false
      fi
      rm "$MAIN/.git"; mv "$MAIN/.git.saved" "$MAIN/.git"
    done
  done
}

@test "an exit-0 empty previous proof cannot hide a late checkout demotion" {
  # The linked worktree is a scalar miss while its checkout remains positive.
  # If the copied proof is empty, the subsequent checkout demotion must not
  # disappear just because the scalar row was already written to the buffer.
  local gitdir function rc
  gitdir="$(git -C "$LINKED" rev-parse --absolute-git-dir)"
  : > "$gitdir/config.worktree"
  jq --arg root "$LINKED" '.projects["personal/alpha"].checkouts |= with_entries(
    .value.worktrees |= with_entries(select(.value.root == $root)))' \
    "$SANDBOX/pristine.json" > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  export LATE_CHECKOUT="$MAIN" LATE_FOREIGN="$FOREIGN" LATE_LINKED="$LINKED" LATE_MARK="$SANDBOX/empty-proof"
  for function in local_registry_list_json local_registry_list_diagnostic_json; do
    rm -f "$LATE_MARK"
    if bash -c '
      . "$1"
      cp() {
        case "${2:-}" in
          */proof.previous)
            : > "$LATE_MARK" || return 1
            mv "$LATE_CHECKOUT/.git" "$LATE_CHECKOUT/.git.saved" || return 1
            ln -s "$LATE_FOREIGN/.git" "$LATE_CHECKOUT/.git" || return 1
            : > "$2" ;;
          *) command cp "$@" ;;
        esac
      }
      _local_registry_batch_run() {
        _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)" || return 1
        _local_registry_batch_recheck "$2" "$3" || return 1
        jq -e --arg root "$LATE_LINKED" --slurpfile r "$2" "
          . as \$p | any(range(0; \$r | length); . as \$i | \$r[\$i].root == \$root and (\$p.rows[\$i] | not))
        " "$3/proof" >/dev/null
      }
      "$2" "$TRELLIS_HOME"
    ' _ "$LIB" "$function" > "$SANDBOX/proof.out" 2> "$SANDBOX/proof.err"; then rc=0; else rc=$?; fi
    [ -e "$LATE_MARK" ] || { echo 'previous-proof copy was not reached'; false; }
    if [ "$rc" -eq 0 ]; then
      bash -c '. "$1"; _local_registry_batch_run() { return 1; }; "$2" "$TRELLIS_HOME"' \
        _ "$LIB" "$function" > "$SANDBOX/scalar.out" 2> "$SANDBOX/scalar.err" || false
      cmp "$SANDBOX/scalar.out" "$SANDBOX/proof.out" || false
    else
      [ "$rc" -eq 4 ] && [ ! -s "$SANDBOX/proof.out" ] || false
    fi
    rm "$MAIN/.git"; mv "$MAIN/.git.saved" "$MAIN/.git"
  done
  rm "$gitdir/config.worktree"
}

@test "an exit-0 truncated positive projection cannot produce an incomplete listing" {
  local function rc
  for function in local_registry_list_json local_registry_list_diagnostic_json; do
    if bash -c '
      . "$1"
      jq() {
        for argument in "$@"; do
          case "$argument" in *"select(\$p[0].rows[\$i])"*) return 0 ;; esac
        done
        command jq "$@"
      }
      _local_registry_batch_run() {
        _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)" || return 1
        _local_registry_batch_recheck "$2" "$3"
      }
      "$2" "$TRELLIS_HOME"
    ' _ "$LIB" "$function" > "$SANDBOX/projection.out" 2> "$SANDBOX/projection.err"; then rc=0; else rc=$?; fi
    [ "$rc" -eq 4 ] && [ ! -s "$SANDBOX/projection.out" ] || { echo "$function returned $rc"; false; }
  done
}

assert_missing_final_newline() {
  local function rc
  export CUT_GENERATOR="$1" REAL_JQ="$(command -v jq)"
  mkdir -p "$SANDBOX/no-newline-bin"
  printf '%s\n' '#!/bin/sh' \
    'if [ "$CUT_GENERATOR" = row ] && [ "$1" = -c ] && [ "$2" = --arg ] && [ "$3" = fleet ]; then' \
    '  "$REAL_JQ" "$@" | python3 -I -c "import sys; d=sys.stdin.buffer.read(); sys.stdout.buffer.write(d[:-1])"; exit 0' \
    'fi' 'exec "$REAL_JQ" "$@"' > "$SANDBOX/no-newline-bin/jq"
  chmod 700 "$SANDBOX/no-newline-bin/jq"
  for function in local_registry_list_json local_registry_list_diagnostic_json; do
    if env PATH="$SANDBOX/no-newline-bin:$PATH" bash -c '
      . "$1"
      _local_registry_batch_run() { return 1; }
      if [ "$CUT_GENERATOR" = checkout ]; then
        def="$(declare -f local_registry_checkout_rows)"
        eval "${def/local_registry_checkout_rows/_original_checkout_rows}"
        local_registry_checkout_rows() {
          _original_checkout_rows "$@" | python3 -I -c "import sys; d=sys.stdin.buffer.read(); sys.stdout.buffer.write(d[:-1])"
        }
      fi
      "$2" "$TRELLIS_HOME"
    ' _ "$LIB" "$function" > "$SANDBOX/nonl.out" 2> "$SANDBOX/nonl.err"; then rc=0; else rc=$?; fi
    [ "$rc" -eq 4 ] && [ ! -s "$SANDBOX/nonl.out" ] || { echo "$CUT_GENERATOR $function returned $rc"; return 1; }
  done
}

@test "an unterminated checkout generator record is refused" {
  assert_missing_final_newline checkout || false
}

@test "an unterminated listing generator record is refused" {
  assert_missing_final_newline row || false
}

@test "production admission checks tools, overrides and bundle attestation" {
  local trusted_git='' trusted_python='' candidate
  for candidate in /opt/homebrew/bin/git /usr/local/bin/git /usr/bin/git; do
    [ ! -x "$candidate" ] || { trusted_git="$candidate"; break; }
  done
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [ ! -x "$candidate" ] || { trusted_python="$candidate"; break; }
  done
  [ -n "$trusted_git" ] && [ -n "$trusted_python" ] || skip 'no admitted native tool paths'
  export TRUSTED_GIT="$trusted_git" TRUSTED_PYTHON="$trusted_python" ADMISSION_MARK="$SANDBOX/admitted"
  # Hashing these names changes lookup only. The stubbed executor returns
  # before Git runs, so the test runner's mutation fence is never bypassed.
  bash -c '
    . "$1"
    hash -p "$TRUSTED_GIT" git
    hash -p "$TRUSTED_PYTHON" python3
    _local_registry_batch_execute() { : > "$ADMISSION_MARK"; return 1; }
    _local_registry_batch_run unused unused "$2" || :
    [ -f "$ADMISSION_MARK" ] || exit 1
    rm "$ADMISSION_MARK"
    local_registry_checkout_class_for() { printf "4\\n"; }
    _local_registry_batch_run unused unused "$2" || :
    [ ! -e "$ADMISSION_MARK" ] || exit 2
  ' _ "$LIB" "$SANDBOX" || false
  bash -c '
    . "$1"
    hash -p "$TRUSTED_GIT" git
    hash -p "$TRUSTED_PYTHON" python3
    _local_registry_batch_execute() { : > "$ADMISSION_MARK"; return 1; }
    TRELLIS_LIBS_PRELOADED=1
    _TRELLIS_BUNDLED_REGISTRY_BATCH_PROGRAM=fixture
    _TRELLIS_BUNDLED_ATTACHMENT_FS_PROGRAM=fixture
    trellis_command_bundle_is_verified() { return 1; }
    _local_registry_batch_run unused unused "$2" || :
    [ ! -e "$ADMISSION_MARK" ] || exit 3
    trellis_command_bundle_is_verified() { return 0; }
    _local_registry_batch_run unused unused "$2" || :
    [ -f "$ADMISSION_MARK" ] || exit 4
  ' _ "$LIB" "$SANDBOX" || false
}

@test "changed classifier helpers invalidate batch admission" {
  bash -c '
    . "$1"
    before="$_LOCAL_REGISTRY_BATCH_HELPERS_ORIGINAL"
    local_registry_checkout_class_for() { printf "4\\n"; }
    [ "$(_local_registry_batch_helpers)" != "$before" ]
  ' _ "$LIB" || false
  bash -c '
    . "$1"
    before="$_LOCAL_REGISTRY_BATCH_HELPERS_ORIGINAL"
    local_registry_require_absolute_safe_path() { return 5; }
    [ "$(_local_registry_batch_helpers)" != "$before" ]
  ' _ "$LIB" || false
  bash -c '
    . "$1"
    TRELLIS_LIBS_PRELOADED=1
    _TRELLIS_BUNDLED_REGISTRY_BATCH_PROGRAM=untrusted
    _TRELLIS_BUNDLED_ATTACHMENT_FS_PROGRAM=untrusted
    trellis_command_bundle_is_verified() { return 1; }
    if _local_registry_batch_run unused unused "$2"; then exit 1; fi
    [ ! -e "$2/checkouts" ]
  ' _ "$LIB" "$SANDBOX" || false
}

@test "checkout diagnostic precedes a row-flattening failure" {
  jq '.projects["personal/alpha"].checkouts |= (to_entries | .[0].key = ("0" * 64) | from_entries)' \
    "$SANDBOX/pristine.json" > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  mkdir "$SANDBOX/bin"
  export REAL_JQ="$(command -v jq)"
  printf '%s\n' '#!/bin/sh' \
    'if [ "$1" = -c ] && [ "$2" = --arg ] && [ "$3" = fleet ]; then' \
    '  echo "synthetic flatten failure" >&2; exit 2' \
    'fi' 'exec "$REAL_JQ" "$@"' > "$SANDBOX/bin/jq"
  chmod 700 "$SANDBOX/bin/jq"
  if env PATH="$SANDBOX/bin:$PATH" bash -c '. "$1"; local_registry_list_json "$TRELLIS_HOME"' \
      _ "$LIB" > "$SANDBOX/flatten.out" 2> "$SANDBOX/flatten.err"; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 4 ] || false
  python3 -I - "$SANDBOX/flatten.err" <<'PY'
import sys
with open(sys.argv[1], 'rb') as stream:
    output = stream.read()
assert output.index(b'checkout ID does not match recorded Git common directory') < output.index(b'synthetic flatten failure')
PY
}

@test "a failed row generator with no output fails the listing instead of appearing empty" {
  local function mode rc
  for function in local_registry_list_json local_registry_list_diagnostic_json; do
    for mode in scalar batch; do
      if env BATCH_MODE="$mode" bash -c '
        . "$1"
        local_registry_checkout_rows() { return 71; }
        if [ "$BATCH_MODE" = scalar ]; then
          _local_registry_batch_run() { return 1; }
        else
          _local_registry_batch_run() {
            _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)"
          }
        fi
        "$2" "$TRELLIS_HOME"
      ' _ "$LIB" "$function" > "$SANDBOX/generator.out" 2> "$SANDBOX/generator.err"; then
        rc=0
      else
        rc=$?
      fi
      [ "$rc" -eq 4 ] || { echo "$function $mode returned $rc"; false; }
      [ ! -s "$SANDBOX/generator.out" ] || { echo 'failed generator appeared as a listing'; false; }
    done
  done
}

@test "invalid batch protocol is discarded and the scalar listing decides" {
  local fake="$SANDBOX/python-broken"
  printf '#!/bin/sh\nprintf "{\\\"checkouts\\\":[true]}\\n"\n' > "$fake"
  chmod 700 "$fake"
  export BROKEN_PYTHON="$fake"
  bash -c '. "$1"; _local_registry_batch_run() { return 1; }; local_registry_list_json "$TRELLIS_HOME"' \
    _ "$LIB" > "$SANDBOX/scalar.out" 2> "$SANDBOX/scalar.err"
  bash -c '. "$1"; _local_registry_batch_run() { _local_registry_batch_execute "$1" "$2" "$3" "$BROKEN_PYTHON" "$(command -v git)"; }; local_registry_list_json "$TRELLIS_HOME"' \
    _ "$LIB" > "$SANDBOX/batch.out" 2> "$SANDBOX/batch.err"
  cmp "$SANDBOX/scalar.out" "$SANDBOX/batch.out" || false
  cmp "$SANDBOX/scalar.err" "$SANDBOX/batch.err" || false
}

# The installed launcher pins PATH, so the batch can run any interpreter its
# admission accepts, including macOS's /usr/bin/python3 (3.9). Each one present
# must certify the healthy rows: a 3.10-only API would otherwise turn every row
# into a silent scalar fallback (os.path.realpath(strict=True) did).
@test "every interpreter the production admission accepts certifies healthy rows" {
  local py found=0
  for py in /usr/bin/python3 /usr/local/bin/python3 /opt/homebrew/bin/python3; do
    [ -x "$py" ] && "$py" -I -c 'import sys' >/dev/null 2>&1 || continue
    found=$((found + 1))
    rm -f "$BATCH_PROOF"
    # The launcher runs under env -i; drop caller GIT_* variables the helper
    # (rightly) treats as unsafe, such as an inherited GIT_EDITOR, so only the
    # interpreter differs between iterations.
    run env BATCH_PY="$py" bash -c '
      for name in $(compgen -e); do
        case "$name" in GIT_CONFIG_GLOBAL|GIT_CONFIG_NOSYSTEM|GIT_OPTIONAL_LOCKS|GIT_TERMINAL_PROMPT) ;; GIT_*) unset "$name" ;; esac
      done
      . "$1"
      _local_registry_batch_run() {
        _local_registry_batch_execute "$1" "$2" "$3" "$BATCH_PY" "$(command -v git)" || return 1
        _local_registry_batch_recheck "$2" "$3" || return 1
        cp "$3/proof" "$BATCH_PROOF"
      }
      local_registry_list_json "$TRELLIS_HOME" >/dev/null
    ' _ "$LIB"
    [ "$status" -eq 0 ] || { echo "$py: $output"; false; }
    [ -f "$BATCH_PROOF" ] || { echo "$py ($("$py" -V 2>&1)): the batch fell back: $output"; false; }
    jq -e 'all(.checkouts[]; . == true) and ([.rows[] | select(.)] | length) >= 4' "$BATCH_PROOF" >/dev/null ||
      { echo "$py ($("$py" -V 2>&1)): $(cat "$BATCH_PROOF")"; false; }
  done
  [ "$found" -gt 0 ] || skip "no admitted python3 on this host"
}

# A programming error inside the helper is not "unproved": the helper exits
# non-zero, every row takes the scalar classifier, and one stderr line names
# the degradation. Injected through the bundled-program path, so no file in
# the repository changes.
@test "a helper programming error falls back visibly, with one stderr line and identical rows" {
  local program="$SANDBOX/broken-batch.py"
  python3 -I - "$REPO_ROOT/scripts/lib/registry_identity_batch.py" "$program" <<'PY'
import sys
source = open(sys.argv[1]).read()
anchor = 'if __name__ == "__main__":'
assert source.count(anchor) == 1
open(sys.argv[2], "w").write(source.replace(anchor, 'def verify_group(*args):\n    raise RuntimeError("probe")\n\n\n' + anchor))
PY
  export BROKEN="$program" FS_SOURCE="$REPO_ROOT/scripts/lib/attachment_fs.py"
  bash -c 'for name in $(compgen -e); do case "$name" in GIT_CONFIG_GLOBAL|GIT_CONFIG_NOSYSTEM|GIT_OPTIONAL_LOCKS|GIT_TERMINAL_PROMPT) ;; GIT_*) unset "$name" ;; esac; done; . "$1"; _local_registry_batch_run() { return 1; }; local_registry_list_json "$TRELLIS_HOME"' \
    _ "$LIB" > "$SANDBOX/scalar.out" 2> "$SANDBOX/scalar.err"
  bash -c '
    for name in $(compgen -e); do case "$name" in GIT_CONFIG_GLOBAL|GIT_CONFIG_NOSYSTEM|GIT_OPTIONAL_LOCKS|GIT_TERMINAL_PROMPT) ;; GIT_*) unset "$name" ;; esac; done;
    . "$1"
    _TRELLIS_BUNDLED_REGISTRY_BATCH_PROGRAM="$(< "$BROKEN")"
    _TRELLIS_BUNDLED_ATTACHMENT_FS_PROGRAM="$(< "$FS_SOURCE")"
    _local_registry_batch_run() {
      _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)" 1 || return 1
      _local_registry_batch_recheck "$2" "$3"
    }
    local_registry_list_json "$TRELLIS_HOME"
  ' _ "$LIB" > "$SANDBOX/batch.out" 2> "$SANDBOX/batch.err"
  cmp "$SANDBOX/scalar.out" "$SANDBOX/batch.out" || false
  [ "$(head -n 1 "$SANDBOX/batch.err")" = 'trellis registry: identity batch unavailable (registry_identity_batch: RuntimeError: probe); classifying rows one by one' ] ||
    { cat "$SANDBOX/batch.err"; false; }
  tail -n +2 "$SANDBOX/batch.err" | cmp - "$SANDBOX/scalar.err" || false
}

# A caller GIT_* variable outside the allowlist, alone: the batch proves no
# checkout and every listing is byte-identical to the scalar classifier, so a
# fallback there can never change a result.
@test "a GIT_EDITOR-only environment falls back and lists exactly what the scalar classifier lists" {
  export GIT_EDITOR=true
  compare_both || false
  jq -e 'all(.checkouts[]; . == false)' "$BATCH_PROOF" >/dev/null || { cat "$BATCH_PROOF"; false; }
}

# Stage B item 3: the create path's bound-row validation of a donor candidate
# set. Batch positives skip the scalar classifier; misses and failures do not.
bound_rows_fixture() {
  local name
  for name in second third; do
    git -C "$MAIN" worktree add -q -b "$name" "$SANDBOX/$name repo"
    bash -c '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" personal alpha "$2" "" "[]" "" "{}"' _ "$LIB" "$SANDBOX/$name repo"
  done
  CHECKOUT="$(jq -r '.projects[] | select(.project_id == "alpha") | .checkouts | keys[0]' "$TRELLIS_HOME/registry.json")"
  WORKTREES=()
  while IFS= read -r name; do
    WORKTREES+=("$name")
  done < <(jq -r --arg c "$CHECKOUT" '.projects[] | .checkouts[$c].worktrees // {} | keys[]' "$TRELLIS_HOME/registry.json")
}

bound_rows() {
  local mode="$1"
  shift
  env BATCH_MODE="$mode" SCALAR_LOG="$SANDBOX/scalar.log" SANDBOX="$SANDBOX" \
    MUTATE_ROOT="${MUTATE_ROOT:-}" MUTATE_CMD="${MUTATE_CMD:-}" bash -c '
    . "$1"; shift
    if [ "$BATCH_MODE" = scalar ]; then
      _local_registry_batch_run() { return 1; }
    else
      _local_registry_batch_run() {
        _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)" || return 1
        _local_registry_batch_recheck "$2" "$3"
      }
    fi
    eval "$(declare -f local_registry_validate_identity_row | sed "1s/local_registry_validate_identity_row/t152_scalar_row/")"
    local_registry_validate_identity_row() {
      local root
      root="$(printf "%s\n" "$1" | jq -r .root)"
      printf "%s\n" "$root" >> "$SCALAR_LOG"
      # MUTATE_ROOT/MUTATE_CMD: change the world once, while this row is checked.
      if [ -n "${MUTATE_ROOT:-}" ] && [ "${root##*/}" = "$MUTATE_ROOT" ]; then
        MUTATE_ROOT=""
        eval "$MUTATE_CMD"
      fi
      t152_scalar_row "$@"
    }
    state="$(local_registry_read_diagnostic_state "$TRELLIS_HOME")" || exit 90
    local_registry_validate_bound_rows "$state" "$@"
  ' _ "$LIB" "$CHECKOUT" "$@"
}

bound_worktree_id() {
  jq -r --arg c "$CHECKOUT" --arg name "$1" '
    .projects[] | .checkouts[$c].worktrees // {} | to_entries[]
    | select(.value.root | endswith("/" + $name)) | .key' "$TRELLIS_HOME/registry.json"
}

@test "bound rows: a candidate set takes one batch pass and no scalar row" {
  bound_rows_fixture
  [ "${#WORKTREES[@]}" -ge 3 ] || { echo "worktrees: ${WORKTREES[*]}"; return 1; }
  : > "$SANDBOX/scalar.log"
  run bound_rows batch "${WORKTREES[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c . "$SANDBOX/scalar.log")" -eq 0 ] || { echo "scalar rows: $(grep -c . "$SANDBOX/scalar.log")"; return 1; }
}

@test "bound rows: a batch failure validates every row with the scalar classifier" {
  bound_rows_fixture
  : > "$SANDBOX/scalar.log"
  run bound_rows scalar "${WORKTREES[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c . "$SANDBOX/scalar.log")" -eq $(( ${#WORKTREES[@]} + 1 )) ] || { echo "scalar rows: $(grep -c . "$SANDBOX/scalar.log")"; return 1; }
}

# r152-create-3: a batch miss is slow. A row the batch proved before it may
# break while the miss is checked; the old per-candidate loop checked it after
# the miss and refused, so the batch path must observe it again and refuse too.
@test "bound rows: a proven row broken while a slow miss is checked gets the scalar refusal" {
  local second third batch_status batch_output id
  local -a rest=()
  bound_rows_fixture
  second="$(bound_worktree_id "second repo")" third="$(bound_worktree_id "third repo")"
  [ -n "$second" ] && [ -n "$third" ] || { echo "ids: [$second] [$third]"; return 1; }
  for id in "${WORKTREES[@]}"; do
    [ "$id" = "$second" ] || [ "$id" = "$third" ] || rest+=("$id")
  done
  git -C "$SANDBOX/second repo" checkout -q --detach
  : > "$SANDBOX/scalar.log"
  MUTATE_ROOT="second repo" MUTATE_CMD='printf "gitdir: /not-a-real-gitdir\n" > "$SANDBOX/third repo/.git"' \
    run bound_rows batch "$second" "$third" "${rest[@]+"${rest[@]}"}"
  batch_status=$status batch_output=$output
  grep -q '/second repo$' "$SANDBOX/scalar.log" || { echo "second was no batch miss"; cat "$SANDBOX/scalar.log"; return 1; }
  [ "$batch_status" -ne 0 ] || { echo "broken proven row accepted: $batch_output"; cat "$SANDBOX/scalar.log"; return 1; }
  grep -q '/third repo$' "$SANDBOX/scalar.log" || { echo "third never observed again"; cat "$SANDBOX/scalar.log"; return 1; }
  run bound_rows scalar "$second" "$third" "${rest[@]+"${rest[@]}"}"
  [ "$status" -eq "$batch_status" ] && [ "$output" = "$batch_output" ] ||
    { printf 'batch %s: %s\nscalar %s: %s\n' "$batch_status" "$batch_output" "$status" "$output"; return 1; }
}

# r152-create-3 L1 (the r152-registry L3 class): a selected-row generator
# that succeeds with an empty, short, duplicated, substituted or broken stream
# refuses; it never drops or replaces a broken candidate.
@test "bound rows: a faulty row generator refuses instead of dropping a candidate" {
  local second fault
  bound_rows_fixture
  second="$(bound_worktree_id "second repo")"
  [ -n "$second" ] || { echo "no id for second repo"; return 1; }
  # A broken gitdir: the per-candidate scalar check refuses this candidate.
  printf 'gitdir: /not-a-real-gitdir\n' > "$SANDBOX/second repo/.git"
  # extra: the broken candidate's row becomes another valid row plus a field,
  # so every line differs and the count holds.
  cat > "$SANDBOX/extra.awk" <<'AWK'
{ line[NR] = $0 }
END {
  for (i = 1; i <= NR; i++) if (line[i] ~ /second repo"/) bad = i
  for (i = 1; i <= NR; i++) if (i != bad && line[i] ~ /"kind":"worktree"/) { other = i; break }
  for (i = 1; i <= NR; i++) {
    if (i == bad) { s = line[other]; sub(/}$/, ",\"extra\":1}", s); print s } else print line[i]
  }
}
AWK
  for fault in empty first-line duplicate substitute cut extra; do
    run env FAULT="$fault" EXTRA_AWK="$SANDBOX/extra.awk" bash -c '
      . "$1"; shift
      state="$(local_registry_read_diagnostic_state "$TRELLIS_HOME")" || exit 90
      local_registry_validate_bound_row_identity "$state" "$1" "$2" >/dev/null 2>&1 && exit 91
      jq() {
        case "$*" in
          *"reduce .[] as \$w"*)
            case "$FAULT" in
              empty) command jq "$@" >/dev/null ;;
              first-line) command jq "$@" | head -n 1 ;;
              duplicate) command jq "$@" | awk "NR == 1 { first = \$0 } { line[NR] = \$0 } END { for (i = 1; i < NR; i++) print line[i]; print first }" ;;
              substitute) command jq "$@" | sed "s#/second repo\"#/second moved\"#" ;;
              cut) command jq "$@" | sed "\$s/.\{12\}\$//" ;;
              extra) command jq "$@" | awk -f "$EXTRA_AWK" ;;
            esac
            return 0 ;;
          *) command jq "$@" ;;
        esac
      }
      local_registry_validate_bound_rows "$state" "$@"
    ' _ "$LIB" "$CHECKOUT" "$second" "${WORKTREES[@]}"
    [ "$status" -eq 4 ] || { echo "$fault: status=$status $output"; return 1; }
    [[ "$output" == *"incomplete or invalid stream"* ]] || { echo "$fault: $output"; return 1; }
  done
}

# r152-create-3: the row check reads the selected rows on stdin. As one jq
# argument, about 200 KB of healthy rows exceeded the exec limit for a single
# argument (Linux: 128 KiB) and refused a valid candidate set.
@test "bound rows: a large healthy candidate set is checked, not refused" {
  run bash -c '
    . "$1"
    local_registry_validate_identity_row() { :; }
    _local_registry_batch_run() { return 1; }
    state="$(jq -cn "{projects: {p: {checkouts: {c1: {root: \"/m\", git_common_dir: \"/m/.git\",
      worktrees: ([range(0; 600) | {key: (\"w\" + tostring),
        value: {root: (\"/a/long/worktree/root/for/the/exec/limit/case/number/\" + tostring + \"/padding/padding/padding/padding/padding/padding\")}}] | from_entries)}}}}}")"
    ids=()
    for i in $(seq 0 599); do ids+=("w$i"); done
    local_registry_validate_bound_rows "$state" c1 "${ids[@]}"
  ' _ "$LIB"
  [ "$status" -eq 0 ] || { echo "status=$status ${output:0:400}"; return 1; }
}

# A moved candidate root is an unavailable root: neither path refuses it, the
# listing names it unavailable, and validation writes nothing.
@test "bound rows: a moved candidate root is unavailable, not refused, and writes nothing" {
  bound_rows_fixture
  mv "$SANDBOX/second repo" "$SANDBOX/second moved"
  cp "$TRELLIS_HOME/registry.json" "$SANDBOX/registry.before"
  ls -lAR "$TRELLIS_HOME" > "$SANDBOX/home.before"
  run bound_rows batch "${WORKTREES[@]}"
  [ "$status" -eq 0 ] || { echo "batch status=$status $output"; return 1; }
  run bound_rows scalar "${WORKTREES[@]}"
  [ "$status" -eq 0 ] || { echo "scalar status=$status $output"; return 1; }
  cmp "$SANDBOX/registry.before" "$TRELLIS_HOME/registry.json" || { echo 'registry changed'; return 1; }
  ls -lAR "$TRELLIS_HOME" | diff "$SANDBOX/home.before" - || { echo 'trellis home changed'; return 1; }
  run bash -c '. "$1"; local_registry_list_json "$TRELLIS_HOME"' _ "$LIB"
  printf '%s\n' "$output" | jq -e '[.. | objects | select((.root // "") | endswith("/second repo")) | .status] | index("unavailable") != null' >/dev/null ||
    { echo "listing: $output"; return 1; }
}

@test "bound rows: a broken candidate gets the scalar refusal and status, batch or not" {
  local batch_status batch_output
  bound_rows_fixture
  # A broken gitdir (a moved root is an unavailable root, not a refusal).
  printf 'gitdir: /not-a-real-gitdir\n' > "$SANDBOX/second repo/.git"
  : > "$SANDBOX/scalar.log"
  run bound_rows batch "${WORKTREES[@]}"
  batch_status=$status batch_output=$output
  [ "$batch_status" -ne 0 ] || { echo "broken candidate accepted: $batch_output"; return 1; }
  run bound_rows scalar "${WORKTREES[@]}"
  [ "$status" -eq "$batch_status" ] && [ "$output" = "$batch_output" ] ||
    { printf 'batch %s: %s\nscalar %s: %s\n' "$batch_status" "$batch_output" "$status" "$output"; return 1; }
}

# Sync's root proofs (fix/152-sync-batch-roots, Sol r152-sync-batch-roots).
# sync_root_proofs_prepare, sync_root_proof, sync_root_seen and sync_resolve_root
# come from scripts/sync-hooks.sh itself; the batch runs through the same
# post-admission seam as compare_listing, so the runner's Git fence stays in
# PATH. resolve_both ROOT NAME writes the sync resolution and the original
# resolver's result to separate stdout, stderr and status files, and counts the
# sync side's calls to the original resolver (0: the proof was used).
sync_probe() {
  env SANDBOX="$SANDBOX" bash -c '
    . "$1" || exit 90
    for name in sync_root_proofs_prepare sync_root_proof sync_root_seen sync_resolve_root; do
      eval "$(awk -v name="$name" '"'"'$0 == name "() {" {emit=1} emit {print} emit && $0 == "}" {exit}'"'"' "$2")"
    done
    for name in sync_root_proofs_prepare sync_root_proof sync_resolve_root; do
      declare -F "$name" >/dev/null || exit 91
    done
    HOME_PATH="$TRELLIS_HOME"; SYNC_TMPDIR="$SANDBOX"; SYNC_PROOF_DIR=""; _LOCAL_REGISTRY_SYNC_PROOF_READY=0
    SYNC_ROOT_PROOFS=""; SYNC_ROOT_PROOF_TOKEN=""; SYNC_ROOT_PROOF_OS=""
    eval "$(declare -f _local_registry_batch_run | sed "1s/^_local_registry_batch_run/__admitted_batch_run/")"
    _local_registry_batch_run() {
      _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)" || return 1
      _local_registry_batch_recheck "$2" "$3"
    }
    eval "$(declare -f local_registry_resolve_root | sed "1s/^local_registry_resolve_root/__scalar_resolve_root/")"
    calls="$SANDBOX/scalar-calls"
    local_registry_resolve_root() { printf "scalar\n" >> "$calls"; __scalar_resolve_root "$@"; }
    resolve_both() {
      : > "$calls"
      sync_resolve_root "$1" "$(printf "%s" "$1" | shasum -a 256 | cut -d" " -f1)" > "$SANDBOX/$2.fast" 2> "$SANDBOX/$2.fast.err"
      echo "$?" > "$SANDBOX/$2.fast.rc"
      wc -l < "$calls" | tr -d " " > "$SANDBOX/$2.calls"
      __scalar_resolve_root "$TRELLIS_HOME" "$1" > "$SANDBOX/$2.scalar" 2> "$SANDBOX/$2.scalar.err"
      echo "$?" > "$SANDBOX/$2.scalar.rc"
    }
    prepare() {
      [ -z "$SYNC_ROOT_PROOFS" ] || rm -f "$SYNC_ROOT_PROOFS"
      SYNC_ROOT_PROOFS=""
      sync_root_proofs_prepare 2> "$SANDBOX/prepare.err"
    }
    eval "$3"
  ' _ "$LIB" "$REPO_ROOT/scripts/sync-hooks.sh" "$1"
}

# NAME took the proof: no fallback, rc 0, and stdout, stderr and status equal
# to the original resolver's.
assert_used() {
  [ "$(cat "$SANDBOX/$1.calls")" = 0 ] || { echo "$1: fell back"; return 1; }
  [ "$(cat "$SANDBOX/$1.fast.rc")" = 0 ] || { echo "$1: rc $(cat "$SANDBOX/$1.fast.rc")"; return 1; }
  assert_same "$1"
}

# NAME fell back once to the original resolver, with the same results.
assert_fell_back() {
  [ "$(cat "$SANDBOX/$1.calls")" = 1 ] || { echo "$1: no fallback (the stale proof was used)"; return 1; }
  assert_same "$1"
}

assert_same() {
  cmp "$SANDBOX/$1.fast" "$SANDBOX/$1.scalar" || { echo "$1: stdout differs"; return 1; }
  cmp "$SANDBOX/$1.fast.err" "$SANDBOX/$1.scalar.err" || { echo "$1: stderr differs"; return 1; }
  cmp "$SANDBOX/$1.fast.rc" "$SANDBOX/$1.scalar.rc" || { echo "$1: status differs"; return 1; }
}

@test "sync root proofs serve every registered root, byte-identical to the resolver on stdout, stderr and status" {
  sync_probe '
    prepare; [ -n "$SYNC_ROOT_PROOFS" ] || exit 10
    resolve_both "'"$MAIN"'" main; resolve_both "'"$LINKED"'" linked; resolve_both "'"$FOREIGN"'" foreign' || false
  [ ! -s "$SANDBOX/prepare.err" ] || { cat "$SANDBOX/prepare.err"; false; }
  assert_used main && assert_used linked && assert_used foreign || false
}

# Each case: a control that uses the proof, then one change the stat watch and
# registry token cannot see, after which the original resolver must decide.
sync_change_case() {
  local root="$1" change="$2" undo="$3"
  sync_probe '
    prepare; [ -n "$SYNC_ROOT_PROOFS" ] || exit 10
    resolve_both "'"$root"'" control
    '"$change"'
    resolve_both "'"$root"'" changed
    '"$undo" || false
  assert_used control || false
  assert_fell_back changed || false
}

@test "a broken primary config after the batch sends the root to the resolver" {
  cp "$MAIN/.git/config" "$SANDBOX/config.saved"
  sync_change_case "$MAIN" 'printf "[broken\n" >> "'"$MAIN"'/.git/config"' 'cp "'"$SANDBOX"'/config.saved" "'"$MAIN"'/.git/config"'
}

@test "a linked commondir pointed at another repository sends the root to the resolver" {
  local gitdir
  gitdir="$(git -C "$LINKED" rev-parse --absolute-git-dir)"
  cp "$gitdir/commondir" "$SANDBOX/commondir.saved"
  sync_change_case "$LINKED" 'printf "%s\n" "'"$FOREIGN"'/.git" > "'"$gitdir"'/commondir"' 'cp "'"$SANDBOX"'/commondir.saved" "'"$gitdir"'/commondir"'
}

@test "a malformed global Git config sends the root to the resolver" {
  export GIT_CONFIG_GLOBAL="$SANDBOX/global-config"
  : > "$GIT_CONFIG_GLOBAL"
  sync_change_case "$LINKED" 'printf "[broken\n" > "'"$GIT_CONFIG_GLOBAL"'"' ': > "'"$GIT_CONFIG_GLOBAL"'"'
}

@test "a linked gitdir moved away sends the root to the resolver" {
  local gitdir
  gitdir="$(git -C "$LINKED" rev-parse --absolute-git-dir)"
  sync_change_case "$LINKED" 'mv "'"$gitdir"'" "'"$gitdir"'.moved"' 'mv "'"$gitdir"'.moved" "'"$gitdir"'"'
}

@test "an ancestor replaced by a symlink to its moved directory sends the root to the resolver" {
  local root="$SANDBOX/ancestor/deep repo"
  mkdir -p "$SANDBOX/ancestor"
  git -C "$MAIN" worktree add -q -b ancestor "$root"
  bash -c '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" personal alpha "$2" "" "[]" "" "{}"' _ "$LIB" "$root" || false
  sync_change_case "$root" 'mv "'"$SANDBOX"'/ancestor" "'"$SANDBOX"'/ancestor.moved"; ln -s "'"$SANDBOX"'/ancestor.moved" "'"$SANDBOX"'/ancestor"' \
    'rm "'"$SANDBOX"'/ancestor"; mv "'"$SANDBOX"'/ancestor.moved" "'"$SANDBOX"'/ancestor"'
}

# Sol re-review: with refs packed, a corrupt packed-refs leaves both rev-parse
# calls working while `git worktree list` (which the resolver runs) fails. The
# use-time observation runs the resolver's own Git invocations, so it misses.
@test "a corrupt packed-refs after the batch sends the main and linked roots to the resolver" {
  git -C "$MAIN" pack-refs --all
  cp "$MAIN/.git/packed-refs" "$SANDBOX/packed-refs.saved"
  sync_change_case "$MAIN" 'printf "broken\n" > "'"$MAIN"'/.git/packed-refs"' 'cp "'"$SANDBOX"'/packed-refs.saved" "'"$MAIN"'/.git/packed-refs"'
  sync_change_case "$LINKED" 'printf "broken\n" > "'"$MAIN"'/.git/packed-refs"' 'cp "'"$SANDBOX"'/packed-refs.saved" "'"$MAIN"'/.git/packed-refs"'
}

# A real helper execution failure (a programming error in the helper, through
# the bundled-program path): sync falls back with the same results and, unlike
# the listing on its own, prints nothing, because sync discards this
# optimization's stderr exactly as it discards the listing's.
@test "a failing batch helper leaves sync's diagnostics unchanged and every root on the resolver" {
  local program="$SANDBOX/broken-batch.py"
  python3 -I - "$REPO_ROOT/scripts/lib/registry_identity_batch.py" "$program" <<'PY'
import sys
source = open(sys.argv[1]).read()
anchor = 'if __name__ == "__main__":'
assert source.count(anchor) == 1
open(sys.argv[2], "w").write(source.replace(anchor, 'def verify_group(*args):\n    raise RuntimeError("probe")\n\n\n' + anchor))
PY
  export BROKEN="$program" FS_SOURCE="$REPO_ROOT/scripts/lib/attachment_fs.py"
  sync_probe '
    _TRELLIS_BUNDLED_REGISTRY_BATCH_PROGRAM="$(< "$BROKEN")"
    _TRELLIS_BUNDLED_ATTACHMENT_FS_PROGRAM="$(< "$FS_SOURCE")"
    _local_registry_batch_run() {
      _local_registry_batch_execute "$1" "$2" "$3" "$(command -v python3)" "$(command -v git)" 1 || return 1
      _local_registry_batch_recheck "$2" "$3"
    }
    prepare; [ -z "$SYNC_ROOT_PROOFS" ] || exit 10
    resolve_both "'"$LINKED"'" failed' || false
  [ ! -s "$SANDBOX/prepare.err" ] || { echo "sync printed:"; cat "$SANDBOX/prepare.err"; false; }
  assert_fell_back failed || false
}

# Real admission, without the seam: where git and python3 are native binaries
# (no fence or wrapper first in PATH) the batch must certify the roots.
@test "with native tools in PATH the real admission yields root proofs" {
  local tool
  for tool in git python3; do
    case "$(/usr/bin/file -Lb "$(command -v "$tool")" 2>/dev/null)" in
      Mach-O*executable*|Mach-O*'universal binary'*|'ELF '*executable*) ;;
      *) skip "a Git fence or wrapper is first in PATH; real admission is exercised outside the fence" ;;
    esac
  done
  sync_probe '
    _local_registry_batch_run() { __admitted_batch_run "$@"; }
    prepare; [ -n "$SYNC_ROOT_PROOFS" ] || exit 10
    resolve_both "'"$LINKED"'" native' || false
  assert_used native || false
}
