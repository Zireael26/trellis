#!/usr/bin/env bats

# T25 contributor-state coverage exercises real scripts against a fresh local
# clone. A manifest-only clone has no Trellis leaves and stays inert.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
SEED="$REPO_ROOT/scripts/seed-inheritance-symlinks.sh"
WORKTREE="$REPO_ROOT/scripts/worktree.sh"
CLAUDE_SESSION_START="$REPO_ROOT/core-rules/hooks/session-context.sh"
CODEX_SESSION_START="$REPO_ROOT/core-rules/codex/hooks/session-context.sh"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
load helpers/release-fixture
load helpers/t25-portable

setup() {
  t25_setup_inert_fixture
}

teardown() {
  t25_teardown_sandbox
}

assert_manifest_clone_stays_inert() {
  local project_snapshot="$1" home_snapshot="$2" git_before="$3"
  local project_after="$T25_SANDBOX/inert-project.after" home_after="$T25_SANDBOX/inert-home.after"

  t25_snapshot_tree "$T25_PROJECT" "$project_after"
  t25_snapshot_tree "$T25_TRELLIS_HOME" "$home_after"
  cmp -s "$project_snapshot" "$project_after"
  cmp -s "$home_snapshot" "$home_after"
  t25_path_absent "$T25_PROJECT/.trellis/runtime"
  t25_path_absent "$T25_PROJECT/.claude"
  t25_path_absent "$T25_PROJECT/.agents"
  [ "$(t25_git_status "$T25_PROJECT")" = "$git_before" ]
}

run_inert_attachment_command() {
  t25_inert_env bash "$ATTACH" "$1" --home "$T25_TRELLIS_HOME" "$T25_PROJECT"
}

@test "manifest-only clone answers every attachment repair command without writing a byte" {
  local command project_before project_after git_before

  project_before="$T25_SANDBOX/inert-repair.before"
  project_after="$T25_SANDBOX/inert-repair.after"
  git_before="$(t25_git_status "$T25_PROJECT")"
  t25_snapshot_tree "$T25_PROJECT" "$project_before"
  # The clone has never met this machine: no Trellis home exists yet.
  t25_path_absent "$T25_TRELLIS_HOME"

  # PIN THE EXACT CLASS PER OPERATION. An earlier revision accepted 3, 4 or 5
  # interchangeably for both repair commands, which cannot distinguish the
  # documented vocabulary from a regression that swapped one class for another —
  # the whole point of naming the classes. Each expectation below is derived
  # from the refusing line in scripts/attach-project.sh:
  #
  #   detach  -> 0, 'already detached'  idempotent no-op on an unattached root
  #   relink  -> 5 (TRELLIS_EX_UNAVAILABLE), silent: attach_existing_owner finds
  #              no owner row for this checkout/worktree pair (attach-project.sh
  #              `[ -f "$owner" ] && [ ! -L "$owner" ] || return
  #              "$TRELLIS_EX_UNAVAILABLE"`). "Nothing to relink" is an
  #              environment fact, not a conflict (3) and not corrupt state (4).
  #   recover -> 5 (TRELLIS_EX_UNAVAILABLE), 'no matching attachment journal'
  #              (attach-project.sh, same class, for the same reason).
  #
  # A change that made either repair refuse as 3 or 4 must turn this red.
  for command in detach relink recover; do
    run run_inert_attachment_command "$command"

    case "$command" in
      detach)
        [ "$status" -eq 0 ] || { echo "detach exited $status: $output"; false; }
        t25_contains "$output" 'already detached'
        ;;
      relink)
        [ "$status" -eq 5 ] || { echo "relink exited $status, expected 5: $output"; false; }
        ;;
      recover)
        [ "$status" -eq 5 ] || { echo "recover exited $status, expected 5: $output"; false; }
        t25_contains "$output" 'no matching attachment journal'
        ;;
    esac
    t25_lacks "$output" 'attached:'
    t25_snapshot_tree "$T25_PROJECT" "$project_after"
    cmp -s "$project_before" "$project_after" || { echo "$command wrote to the clone"; false; }
    # An explicitly invoked command may prepare its own private machine
    # directories, but it must record no state: no owner row, no journal, no
    # registry — no ENTRY of any kind under the machine home except the
    # directories themselves.
    #
    # `-type f` alone was too narrow: it accepts a symlink, a socket, a FIFO and
    # a device node, so a command that recorded state as a symlink — exactly what
    # the owner-row readers defend against elsewhere — would pass. `-not -type d`
    # rejects every non-directory entry type instead of enumerating the ones we
    # happened to think of.
    if [ -d "$T25_TRELLIS_HOME" ]; then
      t25_attachment_state_absent "$T25_PROJECT"
      t25_path_absent "$T25_TRELLIS_HOME/registry.json"
      [ -z "$(find "$T25_TRELLIS_HOME" -mindepth 1 -not -type d -print)" ] || {
        echo "$command left a non-directory entry under the machine home:"
        find "$T25_TRELLIS_HOME" -mindepth 1 -not -type d -print
        false
      }
    fi
    t25_path_absent "$T25_PROJECT/.trellis"
    t25_path_absent "$T25_PROJECT/.claude"
    t25_path_absent "$T25_PROJECT/.agents"
    [ -z "$(t25_hooks_path_or_unset "$T25_PROJECT")" ]
    [ "$(t25_git_status "$T25_PROJECT")" = "$git_before" ]
  done
}

@test "manifest-only clone stays inert through seed worktree sync and Claude Codex SessionStart" {
  project_before="$T25_SANDBOX/inert-project.before"
  home_before="$T25_SANDBOX/inert-home.before"
  git_before="$(t25_git_status "$T25_PROJECT")"
  t25_snapshot_tree "$T25_PROJECT" "$project_before"
  t25_snapshot_tree "$T25_TRELLIS_HOME" "$home_before"

  [ -f "$T25_PROJECT/.trellis.json" ]
  t25_path_absent "$T25_PROJECT/.trellis"
  [ -z "$git_before" ]

  run t25_inert_env bash "$SEED" --target "$T25_PROJECT" --quiet

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_manifest_clone_stays_inert "$project_before" "$home_before" "$git_before"

  run t25_inert_env bash "$WORKTREE" sync "$T25_PROJECT"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_manifest_clone_stays_inert "$project_before" "$home_before" "$git_before"

  run t25_run_session_start "$CLAUDE_SESSION_START" "$T25_PROJECT"

  [ "$status" -eq 0 ]
  t25_no_attachment_warning "$output"
  assert_manifest_clone_stays_inert "$project_before" "$home_before" "$git_before"

  run t25_run_session_start "$CODEX_SESSION_START" "$T25_PROJECT"

  [ "$status" -eq 0 ]
  t25_no_attachment_warning "$output"
  assert_manifest_clone_stays_inert "$project_before" "$home_before" "$git_before"
}

