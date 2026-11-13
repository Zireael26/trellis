#!/usr/bin/env bats
# lib/deps.sh keeps the helpers every hook needs; the Stop, edit-verification,
# spec, receipt, context-save and doctor helpers live in lib/deps-heavy.sh and
# load on first call through _se_load_heavy (both twins). These cases prove the
# split changed no behaviour, that the light hooks never trigger the heavy
# load, and that a missing heavy lib fails closed.
#
# HERMETIC: every run uses a private HOME, TRELLIS_HOME, Git config and a
# scratch repository under `mktemp -d`.

REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../.." && pwd )"
TREES="core-rules/hooks core-rules/codex/hooks"

# Hooks and libraries that use deps-heavy.sh (they load it eagerly). Every other
# hook or library that sources deps.sh is light and must never reference a
# moved function.
HEAVY_USERS="stop-verify.sh post-edit-verify.sh turn-baseline.sh ui-verify.sh save-context-log.sh
spec-gate.sh spec-gate-core.sh decision-receipt-core.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis-home" GIT_CONFIG_GLOBAL="$SANDBOX/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME" "$TRELLIS_HOME"
  chmod 700 "$TRELLIS_HOME"
  : > "$GIT_CONFIG_GLOBAL"
  git init -q "$SANDBOX/repo"
  git -C "$SANDBOX/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$SANDBOX/template"
  cp -Rp "$SANDBOX/repo" "$HOME" "$TRELLIS_HOME" "$SANDBOX/template/"
}

teardown() {
  [ -n "${SANDBOX:-}" ] || return 0
  chmod -R u+rwx "${SANDBOX:?}" 2>/dev/null || true
  rm -rf "${SANDBOX:?}"
}

moved() { grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$REPO_ROOT/$1/lib/deps-heavy.sh" | tr -d '()'; }

# call_one <deps.sh> <preload 0|1> <function> [args...]: run one function in a
# fresh shell, with a ten-second ceiling; stdout, stderr and status to files.
call_one() {
  local deps="$1" preload="$2" fn="$3" out="$SANDBOX/out.$2" rc=0
  shift 3
  # Identical starting state at identical paths: some helpers take locks or
  # write state, which a previous call must not leave behind.
  chmod -R u+rwx "${SANDBOX:?}/repo" "${HOME:?}" "${TRELLIS_HOME:?}" 2>/dev/null || true
  rm -rf "${SANDBOX:?}/repo" "${HOME:?}" "${TRELLIS_HOME:?}"
  cp -Rp "$SANDBOX/template/repo" "$SANDBOX/repo"
  cp -Rp "$SANDBOX/template/home" "$HOME"
  cp -Rp "$SANDBOX/template/trellis-home" "$TRELLIS_HOME"
  (cd "$SANDBOX/repo" && perl -e 'alarm 10; exec @ARGV' /bin/bash --noprofile --norc -c '
    . "$1" || exit 99
    if [ "$2" = 1 ]; then _se_load_heavy || exit 98; fi
    fn=$3; shift 3
    "$fn" "$@"' x "$deps" "$preload" "$fn" "$@" </dev/null >"$out.stdout" 2>"$out.stderr") || rc=$?
  echo "$rc" >"$out.status"
}

@test "every moved function behaves identically loaded lazily and preloaded, in both twins" {
  local tree fn deps count=0
  for tree in $TREES; do
    deps="$REPO_ROOT/$tree/lib/deps.sh"
    for fn in $(moved "$tree"); do
      for args in "" "$SANDBOX/repo"; do
        # Preloaded twice: where those two runs already differ (an inode,
        # ctime or pid of the restored fixture), compare with digits and hex masked.
        # shellcheck disable=SC2086
        call_one "$deps" 1 "$fn" $args
        for part in stdout stderr status; do cp "$SANDBOX/out.1.$part" "$SANDBOX/base.$part"; done
        # shellcheck disable=SC2086
        call_one "$deps" 1 "$fn" $args
        # shellcheck disable=SC2086
        call_one "$deps" 0 "$fn" $args
        for part in stdout stderr status; do
          if cmp -s "$SANDBOX/base.$part" "$SANDBOX/out.1.$part"; then
            cmp -s "$SANDBOX/out.1.$part" "$SANDBOX/out.0.$part" || {
              echo "$tree $fn ($args): $part differs"; diff "$SANDBOX/out.1.$part" "$SANDBOX/out.0.$part" | head -5; false; }
          else
            [ "$(sed -E 's/[0-9a-f]{8,}/H/g; s/[0-9]+/N/g' "$SANDBOX/out.1.$part")" = "$(sed -E 's/[0-9a-f]{8,}/H/g; s/[0-9]+/N/g' "$SANDBOX/out.0.$part")" ] || {
              echo "$tree $fn ($args): $part differs beyond nondeterministic digits"; diff "$SANDBOX/out.1.$part" "$SANDBOX/out.0.$part" | head -5; false; }
          fi
        done
        count=$((count + 1))
      done
    done
  done
  [ "$count" -gt 100 ] || { echo "only $count calls"; false; }
}

@test "the split is exactly the original definitions: core plus heavy equals one library" {
  local tree
  for tree in $TREES; do
    run /bin/bash --noprofile --norc -c '
      . "$1" && _se_load_heavy || exit 9
      # Every moved function was redefined by the heavy lib, not left a stub.
      for fn in $(grep -oE "^[A-Za-z_][A-Za-z0-9_]*\(\)" "$2" | tr -d "()"); do
        declare -f "$fn" | grep -q "_se_load_heavy || exit 70" && { echo "stub left: $fn"; exit 1; }
      done
      exit 0' x "$REPO_ROOT/$tree/lib/deps.sh" "$REPO_ROOT/$tree/lib/deps-heavy.sh"
    [ "$status" -eq 0 ] || { echo "$tree: $output"; false; }
  done
}

@test "sourcing deps.sh again after the heavy load still reaches the real definitions" {
  local tree
  for tree in $TREES; do
    run perl -e 'alarm 20; exec @ARGV' /bin/bash --noprofile --norc -c '
      . "$1"; _se_stat_lines "s:$1" >/dev/null || exit 3
      . "$1"; _se_stat_lines "s:$1" >/dev/null || exit 4
      _se_load_heavy && . "$1" && _se_stat_lines "s:$1" >/dev/null || exit 5
      echo ok' x "$REPO_ROOT/$tree/lib/deps.sh"
    [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$tree: $status $output"; false; }
  done
}

@test "no light hook or core helper references a moved function" {
  local tree file names hits=""
  for tree in $TREES; do
    names="$(moved "$tree" | paste -sd'|' -)"
    [ -n "$names" ]
    for file in "$REPO_ROOT/$tree"/*.sh "$REPO_ROOT/$tree"/lib/*.sh "$REPO_ROOT/core-rules/pi/hooks/dispatch.sh"; do
      case " $(echo $HEAVY_USERS) deps-heavy.sh " in *" ${file##*/} "*) continue ;; esac
      if [ "${file##*/}" = deps.sh ]; then
        # The core may name a moved function only in its own first-call stub.
        hits="$hits$(grep -nwE "$names" "$file" | grep -vE '^[0-9]+:([A-Za-z_][A-Za-z0-9_]*)\(\) \{ _se_load_heavy \|\| exit 70; \2 "\$@"; \}$' || true)"
      else
        hits="$hits$(grep -nwE "$names" "$file" | sed "s#^#${file#"$REPO_ROOT"/}:#" || true)"
      fi
    done
  done
  [ -z "$hits" ] || { printf '%s\n' "$hits"; false; }
}

# light_tree <tree>: a copy of the hook tree with deps-heavy.sh removed.
light_tree() {
  mkdir -p "$SANDBOX/runtime"
  cp -R "$REPO_ROOT/core-rules" "$SANDBOX/runtime/core-rules"
  rm -f "$SANDBOX/runtime/$1/lib/deps-heavy.sh"
  printf '%s\n' "$SANDBOX/runtime/$1"
}

@test "light hooks run to completion without deps-heavy.sh and never try to load it" {
  local tree dir hook event
  for tree in $TREES; do
    dir="$(light_tree "$tree")"
    for hook in block-destructive pr-gate-shiftleft reread-guard track-read truncation-check slop-tripwire \
                wiki-skill-suggest hookspath-guard session-context inject-primer-index primer-capture-nudge \
                post-compact-context propose-rules stamp-turn code-review-subagent session-start; do
      [ -f "$dir/$hook.sh" ] || continue
      for event in \
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm install"},"cwd":"@R@"}' \
        '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"@R@/a.txt","old_string":"a","new_string":"b"},"cwd":"@R@"}' \
        '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"@R@/a.txt"},"tool_response":"x","cwd":"@R@"}' \
        '{"hook_event_name":"SessionStart","source":"startup","cwd":"@R@"}' \
        '{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"@R@"}'; do
        run env -u BASH_ENV TRELLIS_ROOT="$SANDBOX/runtime" CLAUDE_PROJECT_DIR="$SANDBOX/repo" CODEX_PROJECT_DIR="$SANDBOX/repo" \
          /bin/bash --noprofile --norc -c 'cd "$1" && perl -e "alarm 20; exec @ARGV" /bin/bash --noprofile --norc "$2" <<<"$3"' \
          x "$SANDBOX/repo" "$dir/$hook.sh" "${event//@R@/$SANDBOX/repo}"
        [[ "$output" != *"deps-heavy.sh is missing"* ]] || { echo "$tree/$hook: $output"; false; }
        [ "$status" -ne 70 ] || { echo "$tree/$hook exited 70: $output"; false; }
      done
    done
  done
}

@test "a missing heavy lib fails closed: stubs exit 70, heavy hooks refuse" {
  local tree dir
  for tree in $TREES; do
    dir="$(light_tree "$tree")"
    run /bin/bash --noprofile --norc -c '. "$1"; _se_stat_lines /dev/null; echo unreachable' x "$dir/lib/deps.sh"
    [ "$status" -eq 70 ] || { echo "$tree: $status $output"; false; }
    [[ "$output" == *"deps-heavy.sh is missing or failed to load; refusing"* ]] || { echo "$output"; false; }
    [[ "$output" != *unreachable* ]] || false
    run env TRELLIS_ROOT="$SANDBOX/runtime" CLAUDE_PROJECT_DIR="$SANDBOX/repo" CODEX_PROJECT_DIR="$SANDBOX/repo" \
      /bin/bash --noprofile --norc "$dir/post-edit-verify.sh" <<<"{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$SANDBOX/repo/a.txt\"}}"
    [ "$status" -eq 1 ] || { echo "$tree post-edit-verify: $status $output"; false; }
    [[ "$output" == *"missing sibling lib deps-heavy.sh"* ]] || { echo "$output"; false; }
    # A symlinked heavy lib is refused as well.
    ln -s "$REPO_ROOT/$tree/lib/deps-heavy.sh" "$dir/lib/deps-heavy.sh"
    run /bin/bash --noprofile --norc -c '. "$1"; _se_load_heavy' x "$dir/lib/deps.sh"
    [ "$status" -eq 70 ] || { echo "$tree symlink: $status $output"; false; }
    rm -rf "${SANDBOX:?}/runtime"
  done
}
