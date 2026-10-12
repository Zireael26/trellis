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
  # Keep that incomplete record visible. Detach names doctor --fix rather than
  # a bare config write (spec 055 R4.6); doctor --fix repairs only .husky/_, so
  # set the managed path by hand before checking detach restores the prior hook.
  run t14_owner_for_root "$T14_PROJECT"
  [ "$status" -eq 0 ] && [ -f "$output" ]
  owner="$output"
  jq -e --arg release "$T14_RELEASE" '.release == $release and .git_hooks.enabled == true' "$owner"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  run t14_detach
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *'refusing detach: core.hooksPath is'* ]]
  [[ "$output" == *'run trellis doctor --fix'* ]]
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

# --- spec 055 R2.3 / A2.2: seeding copies the donor's toolchain ---------------
#
# `git worktree add` runs the managed post-checkout dispatcher, which reconciles
# the new worktree through the control payload under the sanitized control PATH.
# The whole add also runs from a control-only environment, so nothing but the
# donor record can supply a real toolchain.

control_worktree_add() {
  run /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME="$T14_SANDBOX" \
    TRELLIS_HOME="$TRELLIS_HOME" \
    /usr/bin/git -C "$T14_PROJECT" worktree add -q -b "$1" "$T14_WORKTREE"
}

@test "seeding under the control env records the donor's toolchain array" {
  fx="$T14_SANDBOX/fx"
  mkdir -p "$fx/a" "$fx/b"
  run env TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_ATTACH_CALLER_PATH="$fx/a:$fx/b" \
    bash "$REPO_ROOT/scripts/attach-project.sh" attach \
    --home "$TRELLIS_HOME" --fleet personal --release "$T14_RELEASE" "$T14_PROJECT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  donor_owner="$(t14_owner_for_root "$T14_PROJECT")"
  jq -e --arg a "$fx/a" --arg b "$fx/b" '.toolchain_path == [$a,$b]' "$donor_owner" >/dev/null

  T14_WORKTREE="$T14_SANDBOX/donor toolchain linked worktree"
  control_worktree_add t14-donor-toolchain
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  linked_owner="$(t14_owner_for_root "$T14_WORKTREE")"
  [ -f "$linked_owner" ] || { printf 'linked worktree was not seeded\n%s\n' "$output"; false; }
  jq -e --arg a "$fx/a" --arg b "$fx/b" '.toolchain_path == [$a,$b]' "$linked_owner" >/dev/null ||
    { jq -c '.toolchain_path' "$linked_owner"; false; }
}

make_control_only_donor() {
  t14_attach
  [ "$?" -eq 0 ] || return 1
  donor_owner="$(t14_owner_for_root "$T14_PROJECT")"
  jq -cS '.toolchain_path = ["/usr/bin","/bin"]' "$donor_owner" > "$T14_SANDBOX/donor.next"
  mv -f "$T14_SANDBOX/donor.next" "$donor_owner"
  chmod 600 "$donor_owner"
}

@test "a control-only donor is copied with exactly one warning" {
  make_control_only_donor
  T14_WORKTREE="$T14_SANDBOX/control donor warned worktree"
  git -C "$T14_PROJECT" -c core.hooksPath=/dev/null worktree add -q -b t14-control-warned "$T14_WORKTREE"
  run /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/dev/null TRELLIS_HOME="$TRELLIS_HOME" \
    /bin/bash "$TRELLIS_HOME/releases/$T14_RELEASE/payload/scripts/seed-inheritance-symlinks.sh" \
    --target "$T14_WORKTREE" --quiet
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  warnings="$(printf '%s\n' "$output" | grep -c 'donor toolchain is the sanitized control PATH' || true)"
  [ "$warnings" -eq 1 ] || { printf 'warnings=%s\n%s\n' "$warnings" "$output"; false; }
  linked_owner="$(t14_owner_for_root "$T14_WORKTREE")"
  jq -e '.toolchain_path == ["/usr/bin","/bin"]' "$linked_owner" >/dev/null
}

@test "unattended: a control-only donor is copied and the next push is refused with the refresh remedy" {
  make_control_only_donor
  managed="$(dispatcher_path)"

  T14_WORKTREE="$T14_SANDBOX/control donor linked worktree"
  control_worktree_add t14-control-donor
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  linked_owner="$(t14_owner_for_root "$T14_WORKTREE")"
  [ -f "$linked_owner" ] || { printf 'linked worktree was not attached\n%s\n' "$output"; false; }
  jq -e '.toolchain_path == ["/usr/bin","/bin"]' "$linked_owner" >/dev/null

  printf '%s\n' 'refs/heads/x deadbeef refs/heads/x abcdef' > "$T14_SANDBOX/refs"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c 'cd "$1" && "$2" origin fixture < "$3"' \
    _ "$T14_WORKTREE" "$managed/pre-push" "$T14_SANDBOX/refs"
  [ "$status" -eq 1 ] || { printf 'status=%s\n%s\n' "$status" "$output"; false; }
  printf '%s\n' "$output" | grep -F "trellis attach --refresh-toolchain $T14_WORKTREE" >/dev/null ||
    { printf '%s\n' "$output"; false; }
}

# --- 1.3.12 A1: branch-flag guard and executed-file release check ------------
#
# Git passes 0 as post-checkout's third argument for a file checkout
# (`git checkout -- <path>`, `git restore`). That changes no branch and adds no
# worktree, so the dispatcher runs the prior hook but skips the reconcile. A
# linked worktree made before the attach stays unattached until a reconcile
# runs, which makes "did the reconcile run" observable from real git commands.

add_unattached_worktree() {
  T14_WORKTREE="$T14_SANDBOX/$1 worktree"
  git -C "$T14_PROJECT" worktree add -q -b "$1" "$T14_WORKTREE"
  t14_attach
  [ "$?" -eq 0 ] || return 1
  run t14_owner_for_root "$T14_WORKTREE"
  [ "$status" -eq 1 ]
}

@test "a file checkout runs the prior hook but does not reconcile" {
  marker="$T14_SANDBOX/file checkout prior"
  write_prior_hook "$T14_PROJECT/.git/hooks" "$marker" 0
  add_unattached_worktree t14-file-checkout
  rm -f "$marker.args" "$marker.stdin"
  printf 'changed\n' > "$T14_WORKTREE/README.md"

  run git -C "$T14_WORKTREE" checkout -- README.md
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }

  [ "$(cat "$T14_WORKTREE/README.md")" = fixture ]
  [ "$(sed -n '3p' "$marker.args")" = 0 ] || { cat "$marker.args"; false; }
  run t14_owner_for_root "$T14_WORKTREE"
  [ "$status" -eq 1 ] || { printf 'file checkout reconciled: %s\n' "$output"; false; }
}

@test "a branch switch still reconciles" {
  add_unattached_worktree t14-switch

  run git -C "$T14_WORKTREE" switch -q -c t14-switch-next
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }

  linked_owner="$(t14_owner_for_root "$T14_WORKTREE")"
  [ -f "$linked_owner" ]
}

@test "a rebase still reconciles" {
  base="$(git -C "$T14_PROJECT" symbolic-ref --short HEAD)"
  add_unattached_worktree t14-rebase
  printf 'rebased\n' > "$T14_WORKTREE/rebased.txt"
  git -C "$T14_WORKTREE" add rebased.txt
  git -C "$T14_WORKTREE" commit -qm 'fixture rebased change'
  printf 'upstream\n' > "$T14_PROJECT/upstream.txt"
  git -C "$T14_PROJECT" add upstream.txt
  git -C "$T14_PROJECT" commit -qm 'fixture upstream change'

  run git -C "$T14_WORKTREE" rebase -q "$base"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }

  [ -f "$T14_WORKTREE/upstream.txt" ]
  linked_owner="$(t14_owner_for_root "$T14_WORKTREE")"
  [ -f "$linked_owner" ]
}

# Rewrites one sealed payload file and puts its read-only mode back, so only a
# content check can catch it. The appended line touches $2 if anything runs it.
tamper_payload_file() {
  local file="$TRELLIS_HOME/releases/$T14_RELEASE/payload/$1" mode
  mode="$(stat -f '%Lp' "$file" 2>/dev/null)" || mode="$(stat -c '%a' "$file")"
  cat "$file" > "$T14_SANDBOX/tamper.${1##*/}"
  chmod u+w "$(dirname "$file")" "$file"
  printf '/usr/bin/touch %q\n' "$2" >> "$file"
  chmod "$mode" "$file"
  chmod a-w "$(dirname "$file")"
}

restore_payload_file() {
  local file="$TRELLIS_HOME/releases/$T14_RELEASE/payload/$1" mode
  mode="$(stat -f '%Lp' "$file" 2>/dev/null)" || mode="$(stat -c '%a' "$file")"
  chmod u+w "$(dirname "$file")" "$file"
  cat "$T14_SANDBOX/tamper.${1##*/}" > "$file"
  chmod "$mode" "$file"
  chmod a-w "$(dirname "$file")"
}

@test "post-checkout refuses a tampered executed file before the reconcile runs" {
  t14_attach
  [ "$?" -eq 0 ]
  managed="$(dispatcher_path)"
  for path in scripts/seed-inheritance-symlinks.sh scripts/lib/semver.sh \
      scripts/lib/local-registry.sh scripts/attach-project.sh; do
    marker="$T14_SANDBOX/executed tamper ran"
    tamper_payload_file "$path" "$marker"

    run env TRELLIS_HOME="$TRELLIS_HOME" bash -c 'cd "$1" && "$2" old new 1' \
      _ "$T14_PROJECT" "$managed/post-checkout"

    [ "$status" -ne 0 ] || { printf '%s: status=%s\n%s\n' "$path" "$status" "$output"; false; }
    [[ "$output" == *'attachment reconciliation failed'* ]] || { printf '%s\n%s\n' "$path" "$output"; false; }
    [[ "$output" == *'managed release reconciliation payload is unavailable'* ]] ||
      { printf '%s\n%s\n' "$path" "$output"; false; }
    [ ! -e "$marker" ] || { printf 'tampered %s ran\n' "$path"; false; }
    restore_payload_file "$path"
  done
}

@test "a tampered non-executed file passes the post-checkout check and pre-push's full verify refuses it" {
  t14_attach
  [ "$?" -eq 0 ]
  managed="$(dispatcher_path)"
  tamper_payload_file core-rules/CLAUDE.md "$T14_SANDBOX/never runs"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c 'cd "$1" && "$2" old new 1' \
    _ "$T14_PROJECT" "$managed/post-checkout"
  # The narrowed check lets the reconcile start; its own full release verify
  # (release_store_locate) still refuses the changed file.
  [ "$status" -ne 0 ] || { printf '%s\n' "$output"; false; }
  [[ "$output" != *'managed release reconciliation payload is unavailable'* ]] || { printf '%s\n' "$output"; false; }
  [[ "$output" == *'changed release content: core-rules/CLAUDE.md'* ]] || { printf '%s\n' "$output"; false; }

  printf '%s\n' 'refs/heads/x deadbeef refs/heads/x abcdef' > "$T14_SANDBOX/refs"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c 'cd "$1" && "$2" origin fixture < "$3"' \
    _ "$T14_PROJECT" "$managed/pre-push" "$T14_SANDBOX/refs"
  [ "$status" -eq 1 ] || { printf 'status=%s\n%s\n' "$status" "$output"; false; }
  [[ "$output" == *'managed immutable release carrier is unavailable'* ]] || { printf '%s\n' "$output"; false; }
}

# The post-checkout check hashes a fixed list of payload files. Anything the
# dispatcher, attach or worktree paths source, run (bash, python3, a helper
# path) or load by file name must be on that list, or a hook would run a file
# nobody checked. The walk starts at every scripts/ file
# trellis_managed_payload_file lets a dispatcher run, plus attach-project.sh,
# and follows every payload script or python helper a non-comment line names,
# so a new helper on these paths fails here until it joins the list.
# trellis-launcher.sh is read for two function bodies, never run, so it is
# listed but not walked. health-checks.sh names two scripts that only doctor
# runs (hc_conformance_passes runs the project's own conformance-check.sh,
# hc_codex_plugin_surface runs check-codex-plugin-surface.sh); the walk skips
# those two names there and fails if any walked file calls either check.
executed_list() {
  sed -n '/^  local -a paths=($/,/^  )$/p' "$REPO_ROOT/scripts/lib/attachment.sh" | sed '1d;$d;s/^ *//'
}

dispatcher_scripts() {
  sed -n '/^trellis_managed_payload_file() {$/,/^  esac$/p' "$REPO_ROOT/scripts/lib/attachment.sh" |
    grep -oE 'scripts/[A-Za-z0-9_./-]+\.(sh|py)'
}

@test "the executed-file list covers every payload file the dispatcher, attach and worktree paths run" {
  listed="$(executed_list)"
  [ -n "$listed" ] || { echo 'no executed-file list in attachment.sh'; false; }
  dispatcher_scripts | grep -qxF scripts/seed-inheritance-symlinks.sh ||
    { echo 'no dispatcher allowlist in attachment.sh'; false; }
  queue=()
  while IFS= read -r root; do
    queue+=("$root")
  done < <(dispatcher_scripts; echo scripts/attach-project.sh)
  seen=" "
  while [ "${#queue[@]}" -gt 0 ]; do
    file="${queue[0]}"
    queue=("${queue[@]:1}")
    case "$seen" in *" $file "*) continue ;; esac
    seen="$seen$file "
    printf '%s\n' "$listed" | grep -qxF "$file" || { echo "unlisted: $file"; false; }
    [ "$file" != scripts/trellis-launcher.sh ] || continue
    if grep -v '^[[:space:]]*#' "$REPO_ROOT/$file" |
        grep -vE '^hc_(conformance_passes|codex_plugin_surface)\(\)' |
        grep -qE '\bhc_(conformance_passes|codex_plugin_surface)\b'; then
      echo "$file runs a doctor-only check"; false
    fi
    while IFS= read -r name; do
      case "$file:$name" in
        scripts/lib/health-checks.sh:conformance-check.sh|scripts/lib/health-checks.sh:check-codex-plugin-surface.sh) continue ;;
        # disk-janitor.sh and pi-spill-watchdog.sh are resolved with [ -f ]
        # guards (or OID-checked) and skipped when absent, and the watchdog
        # runs externally via launchd: neither is executed on hook paths.
        scripts/lib/disk-janitor-agents.sh:disk-janitor.sh|scripts/lib/disk-janitor-agents.sh:pi-spill-watchdog.sh) continue ;;
        # check-process-liveness runs only inside janitor/doctor flows on
        # complete trees, never on dispatcher/attach/worktree hook paths.
        scripts/lib/disk-janitor-lib.sh:check-process-liveness.sh) continue ;;
        # check-process-liveness only compares process command names against
        # the runner's (comm == "run-tests-local.py"), it never executes it.
        scripts/check-process-liveness.sh:run-tests-local.py|scripts/check-process-liveness.sh:run-tests.sh) continue ;;
      esac
      for candidate in "scripts/$name" "scripts/lib/$name"; do
        if [ -f "$REPO_ROOT/$candidate" ]; then
          queue+=("$candidate")
        fi
      done
    done < <(grep -v '^[[:space:]]*#' "$REPO_ROOT/$file" | grep -oE '[A-Za-z0-9_.-]+\.(sh|py)\b' | sort -u)
  done
  for name in semver.sh attach-project.sh skill-roots.sh trellis-launcher.sh \
      attach-postjob.sh health-checks.sh disk-janitor-agents.sh attach-fastpath.py release-executed.py; do
    [[ "$seen" == *"/$name "* ]] || { echo "walk missed $name: $seen"; false; }
  done
}

# 1.3.12 A4 runs attach-postjob.sh from attach (the post-checkout reconcile
# reaches it) and from the pre-push dispatcher; it sources the libraries below
# and attach-project.sh. A5b's donor fast path runs attach-fastpath.py, which
# loads release-executed.py.
@test "the executed-file list carries the A4 and A5b files and everything attach-postjob.sh sources" {
  listed="$(executed_list)"
  for path in scripts/lib/attach-fastpath.py scripts/lib/release-executed.py \
      scripts/lib/attach-postjob.sh scripts/lib/trellis-home.sh scripts/lib/semver.sh \
      scripts/lib/release-store.sh scripts/lib/local-registry.sh scripts/lib/skill-roots.sh \
      scripts/lib/surface-plan.sh scripts/lib/attachment.sh scripts/lib/health-checks.sh \
      scripts/lib/disk-janitor-agents.sh scripts/attach-project.sh; do
    printf '%s\n' "$listed" | grep -qxF "$path" || { echo "unlisted: $path"; false; }
  done
}

@test "every listed executed file exists and each one missing refuses the reconcile" {
  local -a paths=()
  while IFS= read -r path; do
    [ -f "$REPO_ROOT/$path" ] || { echo "listed but absent: $path"; false; }
    paths+=("$path")
  done < <(executed_list)

  t14_attach
  [ "$?" -eq 0 ]
  managed="$(dispatcher_path)"
  payload="$TRELLIS_HOME/releases/$T14_RELEASE/payload"
  for path in "${paths[@]}"; do
    dir="$payload/${path%/*}"
    mode="$(stat -f '%Lp' "$dir" 2>/dev/null)" || mode="$(stat -c '%a' "$dir")"
    chmod u+w "$dir"
    mv "$payload/$path" "$T14_SANDBOX/missing"
    chmod "$mode" "$dir"

    run env TRELLIS_HOME="$TRELLIS_HOME" bash -c 'cd "$1" && "$2" old new 1' \
      _ "$T14_PROJECT" "$managed/post-checkout"

    chmod u+w "$dir"
    mv "$T14_SANDBOX/missing" "$payload/$path"
    chmod "$mode" "$dir"
    [ "$status" -ne 0 ] || { printf '%s: status=%s\n%s\n' "$path" "$status" "$output"; false; }
    [[ "$output" == *'managed release reconciliation payload is unavailable'* ]] ||
      { printf '%s\n%s\n' "$path" "$output"; false; }
  done

  # Every file back in place: the same run reconciles.
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c 'cd "$1" && "$2" old new 1' \
    _ "$T14_PROJECT" "$managed/post-checkout"
  [ "$status" -eq 0 ] || { printf 'status=%s\n%s\n' "$status" "$output"; false; }
}

# macOS prints "@" after the mode for a file with extended attributes, and that
# hides the "+" an ACL would add, so a mode-column check misses an ACL that
# grants write on a file that also carries an xattr. The content is unchanged,
# so only the ACL check can refuse this.
@test "post-checkout refuses an executed file with a write ACL hidden behind an xattr" {
  [ "$(uname -s)" = Darwin ] || skip 'macOS ACLs'
  t14_attach
  [ "$?" -eq 0 ]
  managed="$(dispatcher_path)"
  file="$TRELLIS_HOME/releases/$T14_RELEASE/payload/scripts/lib/semver.sh"
  mode="$(stat -f '%Lp' "$file")"
  chmod u+w "$file"
  xattr -w com.trellis.fixture 1 "$file"
  chmod "$mode" "$file"
  chmod +a "$(id -un) allow write" "$file"
  [[ "$(LC_ALL=C /bin/ls -ld "$file")" != *+* ]]

  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c 'cd "$1" && "$2" old new 1' \
    _ "$T14_PROJECT" "$managed/post-checkout"
  chmod -a# 0 "$file"

  [ "$status" -ne 0 ] || { printf '%s\n' "$output"; false; }
  [[ "$output" == *'managed release reconciliation payload is unavailable'* ]] || { printf '%s\n' "$output"; false; }
}
