#!/usr/bin/env bats
#
# T14 clone-local post-checkout dispatcher contracts. The tracked compatibility
# hook is intentionally inert; attachment owns the local dispatcher.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
load helpers/t14-worktree

setup() {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  T14_WORKTREE=""
}

teardown() {
  if [ -n "${T14_WORKTREE:-}" ] && [ -d "$T14_WORKTREE" ] && [ -d "${T14_PROJECT:-}" ]; then
    git -C "$T14_PROJECT" worktree remove --force "$T14_WORKTREE" 2>/dev/null || true
  fi
  t14_teardown_sandbox
}

dispatcher_path() {
  local owner
  owner="$(t14_owner_for_root "$T14_PROJECT")"
  jq -r '.git_hooks.managed_hooks_path' "$owner"
}

write_prior_hook() {
  local hooks="$1" marker="$2" exit_status="$3"
  mkdir -p "$hooks"
  cat > "$hooks/post-checkout" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$@" > "$marker.args"
cat > "$marker.stdin"
exit $exit_status
EOF
  chmod +x "$hooks/post-checkout"
}

@test "dispatcher chains the default Git hook with unchanged arguments stdin and exit status" {
  marker="$T14_SANDBOX/default prior"
  write_prior_hook "$T14_PROJECT/.git/hooks" "$marker" 23

  t14_attach
  [ "$?" -eq 0 ]
  managed="$(dispatcher_path)"
  [ "$(git -C "$T14_PROJECT" config --local --get core.hooksPath)" = "$managed" ]

  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    'cd "$1" && printf "hook stdin\\n" | "$2" old new 1' \
    dispatcher "$T14_PROJECT" "$managed/post-checkout"

  [ "$status" -eq 23 ]
  [ "$(cat "$marker.args")" = $'old\nnew\n1' ]
  [ "$(cat "$marker.stdin")" = "hook stdin" ]
}

@test "dispatcher chains a symlinked configured hook manager and preserves its status" {
  target="$T14_SANDBOX/configured hooks target"
  previous="$T14_SANDBOX/configured hooks link"
  marker="$T14_SANDBOX/configured prior"
  write_prior_hook "$target" "$marker" 29
  ln -s "$target" "$previous"
  git -C "$T14_PROJECT" config --local core.hooksPath "$previous"

  t14_attach
  [ "$?" -eq 0 ]
  managed="$(dispatcher_path)"
  owner="$(t14_owner_for_root "$T14_PROJECT")"
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$owner")" = "$previous" ]

  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    'cd "$1" && printf "configured stdin\\n" | "$2" first second 1' \
    dispatcher "$T14_PROJECT" "$managed/post-checkout"

  [ "$status" -eq 29 ]
  [ "$(cat "$marker.args")" = $'first\nsecond\n1' ]
  [ "$(cat "$marker.stdin")" = "configured stdin" ]
}

@test "first and linked attachments preserve dispatcher lifecycle until final detach restores prior hooks" {
  previous="$T14_SANDBOX/lifecycle prior"
  marker="$T14_SANDBOX/lifecycle marker"
  write_prior_hook "$previous" "$marker" 0
  git -C "$T14_PROJECT" config --local core.hooksPath "$previous"

  t14_attach
  [ "$?" -eq 0 ]
  managed="$(dispatcher_path)"
  first_owner="$(t14_owner_for_root "$T14_PROJECT")"
  first_owner_hash="$(t14_sha256_text "$(cat "$first_owner")")"
  t14_attach
  [ "$?" -eq 0 ]
  [ "$(t14_sha256_text "$(cat "$first_owner")")" = "$first_owner_hash" ]
  [ "$(git -C "$T14_PROJECT" config --local --get core.hooksPath)" = "$managed" ]

  T14_WORKTREE="$T14_SANDBOX/lifecycle linked worktree"
  git -C "$T14_PROJECT" worktree add -q -b t14-lifecycle "$T14_WORKTREE"
  t14_attach "$T14_WORKTREE"
  [ "$?" -eq 0 ]
  [ -f "$(t14_owner_for_root "$T14_WORKTREE")" ]

  t14_detach "$T14_PROJECT"
  linked_owner="$(t14_owner_for_root "$T14_WORKTREE")"
  jq -e --arg managed "$managed" '.git_hooks.enabled == true and .git_hooks.managed_hooks_path == $managed' "$linked_owner"
  [ -d "$managed" ]
  [ "$(git -C "$T14_WORKTREE" config --local --get core.hooksPath)" = "$managed" ]

  t14_detach "$T14_WORKTREE"
  [ "$(git -C "$T14_PROJECT" config --local --get core.hooksPath)" = "$previous" ]
  [ ! -e "$managed" ]
  [ -x "$previous/post-checkout" ]
}

@test "dispatcher pins the managed custom home under a hostile process environment" {
  t14_attach
  [ "$?" -eq 0 ]
  managed="$(dispatcher_path)"
  T14_WORKTREE="$T14_SANDBOX/hostile dispatcher linked worktree"
  git -C "$T14_PROJECT" -c core.hooksPath=/dev/null worktree add -q -b t14-hostile-dispatcher "$T14_WORKTREE"

  marker="$T14_SANDBOX/hostile dispatcher ran"
  hostile_bin="$T14_SANDBOX/hostile bin"
  hostile_home="$T14_SANDBOX/hostile home"
  hostile_tmp="$T14_SANDBOX/hostile tmp"
  hostile_env="$T14_SANDBOX/hostile bash env"
  hostile_monitor="$T14_SANDBOX/hostile fsmonitor"
  hostile_config="$T14_SANDBOX/hostile gitconfig"
  mkdir -p "$hostile_bin" "$hostile_home" "$hostile_tmp"
  cat > "$hostile_bin/bash" <<EOF
#!/bin/sh
/usr/bin/touch "$marker"
exec /bin/bash "\$@"
EOF
  cat > "$hostile_bin/git" <<EOF
#!/bin/sh
/usr/bin/touch "$marker"
exec /usr/bin/git "\$@"
EOF
  cat > "$hostile_env" <<EOF
/usr/bin/touch "$marker"
EOF
  cat > "$hostile_monitor" <<EOF
#!/bin/sh
/usr/bin/touch "$marker"
printf '%s\n' token
EOF
  chmod 755 "$hostile_bin/bash" "$hostile_bin/git" "$hostile_monitor"
  printf '[core]\n\tfsmonitor = %s\n' "$hostile_monitor" > "$hostile_config"
  hostile_function="() { /usr/bin/touch '$marker'; }"

  cd "$T14_WORKTREE"
  run env \
    "PATH=$hostile_bin" "HOME=$hostile_home" "TRELLIS_HOME=$hostile_home/.trellis" \
    "TMPDIR=$hostile_tmp" "TMP=$hostile_tmp" "TEMP=$hostile_tmp" \
    "BASH_ENV=$hostile_env" "ENV=$hostile_env" \
    "GIT_CONFIG_NOSYSTEM=0" "GIT_CONFIG_GLOBAL=$hostile_config" \
    "GIT_CONFIG_COUNT=1" "GIT_CONFIG_KEY_0=core.fsmonitor" "GIT_CONFIG_VALUE_0=$hostile_monitor" \
    "BASH_FUNC_bash%%=$hostile_function" \
    "$managed/post-checkout" old new 1

  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  [ -L "$T14_WORKTREE/.trellis/runtime" ]
  [ "$(readlink "$T14_WORKTREE/.trellis/runtime")" = "$TRELLIS_HOME/releases/$T14_RELEASE/payload" ]
  [ -f "$(t14_owner_for_root "$T14_WORKTREE")" ]
}

install_broken_generator_release() {
  local kind="$1" repo="$T14_SANDBOX/release source"
  T14_RELEASE=1.2.4
  printf '%s\n' "$T14_RELEASE" > "$repo/core-rules/VERSION"
  case "$kind" in
    failure) rm "$repo/scripts/trellis-launcher.sh" ;;
    empty)
      cat > "$repo/scripts/lib/attachment.sh" <<'GENERATOR'
_attachment_hooks_post_checkout_dispatcher_body() { return 0; }
_attachment_hooks_pre_push_dispatcher_body() { return 0; }
GENERATOR
      ;;
    *) return 1 ;;
  esac
  git -C "$repo" add -A
  git -C "$repo" commit -qm 'fixture malformed generator'
  git -C "$repo" tag -a "v$T14_RELEASE" -m 'fixture malformed generator'
  TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    '. "$1"; release_store_install "$2" "$3" "" >/dev/null' \
    t14-broken-generator "$REPO_ROOT/scripts/lib/release-store.sh" "$T14_RELEASE" "$repo"
}

assert_broken_generator_attach_is_recoverable() {
  local marker="$T14_SANDBOX/preserved prior" before owner managed
  write_prior_hook "$T14_PROJECT/.git/hooks" "$marker" 23
  before="$(t14_sha256_text "$(cat "$T14_PROJECT/.git/hooks/post-checkout")")"

  run t14_attach
  [ "$status" -eq 4 ] || { echo "attach status=$status"; echo "$output"; false; }
  [[ "$output" == *'managed hook generation failed'* ]] || { echo "$output"; false; }
  [ "$(t14_sha256_text "$(cat "$T14_PROJECT/.git/hooks/post-checkout")")" = "$before" ]
  [ -x "$T14_PROJECT/.git/hooks/post-checkout" ]
  [ ! -e "$T14_PROJECT/.trellis/runtime" ] && [ ! -L "$T14_PROJECT/.trellis/runtime" ]
  [ ! -e "$marker.args" ] && [ ! -e "$marker.stdin" ]
  run git -C "$T14_PROJECT" config --local --get core.hooksPath
  [ "$status" -eq 1 ]
  [ -z "$(find "$TRELLIS_HOME/state/git-hooks" -type f -print 2>/dev/null)" ]
  # The established transaction commits ownership before installing hooks.
  # Keep that incomplete record visible and exercise the explicit recovery
  # instruction from detach before checking that it restores the prior hook.
  run t14_owner_for_root "$T14_PROJECT"
  [ "$status" -eq 0 ] && [ -f "$output" ]
  owner="$output"
  jq -e --arg release "$T14_RELEASE" '.release == $release and .git_hooks.enabled == true' "$owner"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  run t14_detach
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *'refusing detach: core.hooksPath is'* ]]
  [[ "$output" == *'config core.hooksPath'* ]]
  git -C "$T14_PROJECT" config core.hooksPath "$managed"
  run t14_detach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run t14_owner_for_root "$T14_PROJECT"
  [ "$status" -eq 1 ]
  [ "$(t14_sha256_text "$(cat "$T14_PROJECT/.git/hooks/post-checkout")")" = "$before" ]
}

@test "failed release hook generation refuses attach without publishing empty hooks" {
  install_broken_generator_release failure
  assert_broken_generator_attach_is_recoverable
}

@test "empty successful release hook generation refuses attach without publishing empty hooks" {
  install_broken_generator_release empty
  assert_broken_generator_attach_is_recoverable
}

@test "owned-state verification refuses blank hooks when the pinned generator becomes unavailable" {
  local owner managed launcher
  t14_attach
  owner="$(t14_owner_for_root "$T14_PROJECT")"
  managed="$(dispatcher_path)"
  launcher="$TRELLIS_HOME/releases/$T14_RELEASE/payload/scripts/trellis-launcher.sh"
  # Simulate corrupt state produced by the old unchecked generator path.
  chmod u+w "$(dirname "$launcher")"
  rm "$launcher"
  printf '\n' > "$managed/post-checkout"
  printf '\n' > "$managed/pre-push"

  run bash -c '. "$1"; _attachment_hooks_state_owned_matches_data "$2" "$(cat "$3")"' \
    t14-owned-state "$REPO_ROOT/scripts/lib/attachment.sh" "$TRELLIS_HOME" "$owner"
  [ "$status" -eq 3 ] || { echo "ownership status=$status"; echo "$output"; false; }
}
