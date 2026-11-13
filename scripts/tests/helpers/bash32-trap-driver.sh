#!/bin/bash
# Test-only driver: exercise the production function body with deterministic
# failures at its external seams. Each case is run by /bin/bash -c under an
# isolated Bats fixture; no production fault switch is introduced.
set -u
case_name=$1
root=$2
TEST_ROOT=$3
TRELLIS_EX_USAGE=2 TRELLIS_EX_CONFLICT=3 TRELLIS_EX_STATE=4 TRELLIS_EX_UNAVAILABLE=5
export TRELLIS_EX_USAGE TRELLIS_EX_CONFLICT TRELLIS_EX_STATE TRELLIS_EX_UNAVAILABLE

load_function() {
  # Top-level subshell functions in these files end with a column-zero ')'.
  local file=$1 name=$2 body
  body=$(awk -v name="$name" '$0 == name "() (" {p=1} p{print} p && /^\)$/{exit}' "$file")
  [ -n "$body" ] || { echo "function missing: $name" >&2; return 1; }
  eval "$body"
}
load_command() {
  local file=$1 name=$2 body
  body=$(awk -v name="$name" '$0 == name "() {" {p=1} p{print} p && /^}$/{exit}' "$file")
  [ -n "$body" ] || { echo "function missing: $name" >&2; return 1; }
  eval "$body"
}
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
no_matching() {
  local found
  found=$(find "$1" -mindepth 1 -maxdepth 1 -name "$2" -print) || return 1
  [ -z "$found" ] || { printf 'leftover: %s\n' "$found" >&2; return 1; }
}
signal_this_shell() { /bin/sh -c 'kill -TERM "$PPID"'; }

# Test cleanup against a second TERM exactly as EXIT is disarmed. On Bash 3.2
# the same signal can be deferred; independently require the order itself.
order_case=false
case "$case_name" in
  r2-order-*)
    order_case=true
    case_name=${case_name#r2-order-}
    trap() {
      if [ "${1-}" = '' ] && [ "${2-}" = HUP ] && [ "${3-}" = INT ] && [ "${4-}" = TERM ]; then
        : > "$TEST_ROOT/signals-blocked"
      fi
      if [ "${1-}" = - ] && [ "${2-}" = EXIT ]; then
        [ -f "$TEST_ROOT/signals-blocked" ] || : > "$TEST_ROOT/wrong-trap-order"
        builtin trap -- "$@"
        if [ ! -f "$TEST_ROOT/second-term" ]; then
          : > "$TEST_ROOT/second-term"
          signal_this_shell
        fi
      else
        builtin trap -- "$@"
      fi
    }
    ;;
esac

case "$case_name" in
  release-owned|release-render)
    printf 'old\n' > "$TEST_ROOT/destination"
    printf 'old\n' > "$TEST_ROOT/expected"
    printf 'new\n' > "$TEST_ROOT/replacement"
    chmod 600 "$TEST_ROOT/destination" "$TEST_ROOT/expected" "$TEST_ROOT/replacement"
    _attachment_canonical_dir() { [ -d "$1" ]; }
    _attachment_mode_matches() { :; }
    _attachment_identity_matches() { :; }
    _attachment_fs_identity() { printf '%s' synthetic-id; }
    adoption_private_render_file_matches() { :; }
    adoption_render_live_matches() { cmp -s "$1" "$2"; }
    max_status() { if [ "$1" -gt "$2" ]; then printf %s "$1"; else printf %s "$2"; fi; }
    MARKER="$TEST_ROOT/signalled"
    release_store_rename_swap() {
      mv "$1" "$1.swap" && mv "$2" "$1" && mv "$1.swap" "$2" || return "$TRELLIS_EX_STATE"
      if [ ! -e "$MARKER" ]; then : > "$MARKER"; signal_this_shell; fi
    }
    if [ "$case_name" = release-owned ]; then
      load_function "$root/scripts/release.sh" replace_owned_file || exit 1
      replace_owned_file "$TEST_ROOT/destination" "$TEST_ROOT/expected" "$TEST_ROOT/replacement"; rc=$?
      pattern='.destination.release-adopt.*'
    else
      load_function "$root/scripts/release.sh" adoption_publish_render || exit 1
      plan=$(jq -cn --arg dest "$TEST_ROOT/destination" --arg old "$TEST_ROOT/expected" --arg new "$TEST_ROOT/replacement" \
        '{destination:$dest,source:$old,source_identity:"id",source_sha256:"old-hash",source_mode:"0600",path_identity:"id",candidate:$new,candidate_identity:"id",candidate_sha256:"new-hash",candidate_mode:"0600"}')
      adoption_publish_render "$plan" forward; rc=$?
      pattern='.destination.release-adopt-render.*'
    fi
    [ "$rc" -eq "$TRELLIS_EX_UNAVAILABLE" ] || fail "wrong signal status: $rc"
    cmp -s "$TEST_ROOT/destination" "$TEST_ROOT/expected" || fail 'interrupted exchange not rolled back'
    no_matching "$TEST_ROOT" "$pattern" || exit 1
    ;;
  release-hooks)
    mkdir "$TEST_ROOT/managed"
    hook_payload_matches() { [ -d "$1" ]; }
    _attachment_hooks_read_sidecar() { printf '%s' fixture; }
    _attachment_hooks_release_manifest_sha256() { printf '%s' manifest; }
    _attachment_hooks_post_checkout_dispatcher_body() { printf '%s' '#!/bin/sh'; }
    _attachment_hooks_pre_push_dispatcher_body() { printf '%s' '#!/bin/sh'; }
    _attachment_hooks_expected_passthrough_names() { :; }
    write_hook_state_file() { printf '%s\n' "$2" > "$1" && chmod "$3" "$1"; }
    release_store_rename_swap() { [ -s "$1/release-payload" ] || return 91; return "$TRELLIS_EX_STATE"; }
    max_status() { if [ "$1" -gt "$2" ]; then printf %s "$1"; else printf %s "$2"; fi; }
    load_function "$root/scripts/release.sh" replace_hook_payload || exit 1
    replace_hook_payload "$TEST_ROOT/managed" old new "$TEST_ROOT"; rc=$?
    [ "$rc" -eq "$TRELLIS_EX_STATE" ] || fail "wrong failed-swap status: $rc"
    [ -d "$TEST_ROOT/managed" ] || fail 'managed hook directory lost'
    no_matching "$TEST_ROOT" '.managed.release-adopt.*' || exit 1
    ;;
  migrate-publish)
    printf 'original\n' > "$TEST_ROOT/source"
    migrate_copy_file_exclusive() { cp "$1" "$2" && chmod "$3" "$2"; printf '%s\n' synthetic-id; }
    migrate_file_link_count() { echo 1; }
    migrate_file_identity() { echo synthetic-id; }
    migrate_sha256_file() {
      if [ -x /usr/bin/sha256sum ]; then /usr/bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
      else /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; fi
    }
    release_store_rename_no_clobber() { signal_this_shell; return "$TRELLIS_EX_STATE"; }
    load_function "$root/scripts/migrate-project.sh" migrate_publish_file_exclusive || exit 1
    migrate_publish_file_exclusive "$TEST_ROOT/source" "$TEST_ROOT/destination" 644; rc=$?
    [ "$rc" -eq 143 ] || fail "wrong signal status: $rc"
    [ ! -e "$TEST_ROOT/destination" ] || fail 'interrupted migration published'
    no_matching "$TEST_ROOT" '.trellis-migrate-publish.*' || exit 1
    ;;
  migrate-prepare)
    /bin/mkdir "$TEST_ROOT/project" "$TEST_ROOT/tmp" "$TEST_ROOT/home"
    migrate_real_root() { printf '%s\n' "$1"; }
    trellis_home_resolve() { printf '%s\n' "$TEST_ROOT/home"; }
    trellis_home_prepare_home() { :; }
    trellis_home_require_jq() { :; }
    local_registry_require_project_id() { :; }
    mkdir() { case "$1" in */transforms) signal_this_shell; return 1 ;; *) /bin/mkdir "$@" ;; esac; }
    load_function "$root/scripts/migrate-project.sh" migrate_prepare || exit 1
    TMPDIR="$TEST_ROOT/tmp" migrate_prepare "$TEST_ROOT/project"; rc=$?
    [ "$rc" -eq 143 ] || fail "wrong signal status: $rc"
    no_matching "$TEST_ROOT/tmp" 'trellis-migrate.*' || exit 1
    ;;
  materialize)
    mkdir -p "$TEST_ROOT/home" "$TEST_ROOT/release/payload"
    printf '%s\n' '{"active_cli_release":"1","fleets":{"personal":{}}}' > "$TEST_ROOT/home/config.json"
    printf '%s\n' '{"commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' > "$TEST_ROOT/release/release.json"
    trellis_home_require_fleet_name() { :; }
    require_task_name() { :; }
    local_registry_home() { printf '%s\n' "$TEST_ROOT/home"; }
    trellis_home_prepare_home() { :; }
    trellis_home_config_path() { printf '%s\n' "$1/config.json"; }
    trellis_home_validate_config() { :; }
    release_store_locate() { printf '%s\n' "$TEST_ROOT/release"; }
    trellis_home_prepare_private_dir() { mkdir -p "$1"; chmod 700 "$1"; }
    materialize_directory_identity() { printf '%s\n' "$1"; }
    validate_existing_task_root() { :; }
    task_publish_identity() { echo id; }
    pin_verified_release_manifest() { return "$TRELLIS_EX_STATE"; }
    body=$(awk '/^cmd_materialize\(\) [{(]$/{p=1} p{print} p && (/^}$/ || /^\)$/){exit}' "$root/scripts/materialize-scheduled-task.sh")
    [ -n "$body" ] || fail 'materialize function missing'
    eval "$body"
    ( cmd_materialize --fleet personal example; exit "$?" ); rc=$?
    [ "$rc" -eq "$TRELLIS_EX_STATE" ] || fail "wrong failure status: $rc"
    no_matching "$TEST_ROOT/home/tasks/personal" '.example.tmp.*' || exit 1
    ;;
  configure|fleet-add|fleet-default)
    mkdir "$TEST_ROOT/tmp" "$TEST_ROOT/home"
    TMPDIR="$TEST_ROOT/tmp"; export TMPDIR
    trellis_home_require_fleet_name() { :; }
    trellis_home_resolve() { printf '%s\n' "$TEST_ROOT/home"; }
    trellis_home_canonical_home() { printf '%s\n' "$1"; }
    trellis_home_prepare_home() { :; }
    trellis_home_config_path() { printf '%s\n' "$TEST_ROOT/home/config.json"; }
    trellis_home_lock_acquire() { :; }
    trellis_home_lock_release() { :; }
    attachment_user_lock_release() { :; }
    trellis_home_validate_config() { :; }
    trellis_home_die() { exit "$1"; }
    if [ "$case_name" = fleet-default ]; then
      printf '{}\n' > "$TEST_ROOT/home/config.json"
      trellis_home_require_jq() { :; }
      jq() { [ "${1:-}" = -e ] && return 0; return "$TRELLIS_EX_STATE"; }
      load_command "$root/scripts/configure.sh" cmd_fleet_set_default || exit 1
      ( cmd_fleet_set_default fleet ); rc=$?
      [ "$rc" -eq "$TRELLIS_EX_STATE" ] || fail "wrong set-default status: $rc"
      no_matching "$TEST_ROOT/tmp" 'trellis.default.proposed.*' || exit 1
    else
      trellis_home_require_jq() { return "$TRELLIS_EX_UNAVAILABLE"; }
      if [ "$case_name" = configure ]; then
        load_command "$root/scripts/configure.sh" cmd_configure || exit 1
        ( cmd_configure ); rc=$?
        pattern='trellis.roots.*'
      else
        load_command "$root/scripts/configure.sh" cmd_fleet_add_or_update || exit 1
        ( cmd_fleet_add_or_update add fleet ); rc=$?
        pattern='trellis.fleet.roots.*'
      fi
      [ "$rc" -eq "$TRELLIS_EX_UNAVAILABLE" ] || fail "wrong configure/fleet status: $rc"
      no_matching "$TEST_ROOT/tmp" "$pattern" || exit 1
    fi
    ;;
  jq)
    mkdir "$TEST_ROOT/tmp" "$TEST_ROOT/bin"
    printf '#!/bin/sh\nkill -TERM "$PPID"\n' > "$TEST_ROOT/bin/jq"; chmod 700 "$TEST_ROOT/bin/jq"
    load_function "$root/scripts/lib/trellis-home.sh" trellis_jq || exit 1
    big=$(printf '%065536d' 0); big="\"$big\""
    PATH="$TEST_ROOT/bin:$PATH" TMPDIR="$TEST_ROOT/tmp" trellis_jq --argjson payload "$big" -n '$payload'; rc=$?
    [ "$rc" -eq 143 ] || fail "wrong signal status: $rc"
    no_matching "$TEST_ROOT/tmp" 'trellis-jq.*' || exit 1
    ;;
  user-attach|user-detach|user-relink)
    mkdir "$TEST_ROOT/tmp" "$TEST_ROOT/user" "$TEST_ROOT/home" "$TEST_ROOT/release"
    # Assigned values are read by the extracted production function via eval.
    # shellcheck disable=SC2034
    attach_user_parse_common() { ATTACH_USER_HOME_OPT="$TEST_ROOT/home"; ATTACH_USER_RELEASE_OPT=1; ATTACH_USER_CONFIGURE_LOCK_HELD=0; ATTACH_USER_RECOVER_ONLY=0; }
    trellis_home_resolve() { printf '%s\n' "$1"; }
    trellis_home_canonical_home() { printf '%s\n' "$1"; }
    trellis_home_config_path() { printf '%s\n' "$1/config.json"; }
    trellis_home_resolve_release() { echo 1; }
    attach_locate_release() { _ATTACH_LOCATED_RELEASE="$TEST_ROOT/release"; }
    _attachment_user_runtime_home() { printf '%s\n' "$TEST_ROOT/user"; }
    attach_uuid() { echo uid; }
    _attachment_signal_exit() { trap - HUP INT TERM; exit "${TRELLIS_EX_UNAVAILABLE:-5}"; }
    attach_user_repair_remedy() {
      printf '%s' "${1-}" > "$TEST_ROOT/remedy-home"
      printf '%s' "${2-}" > "$TEST_ROOT/remedy-status"
    }
    _attachment_user_lock_release() { : > "$TEST_ROOT/released"; }
    # A missing signal must take a distinct return path and fail the test.
    attachment_user_lock_reclaim() { signal_this_shell; return "$TRELLIS_EX_STATE"; }
    name="attach_cmd_user_${case_name#user-}"
    load_function "$root/scripts/attach-project.sh" "$name" || exit 1
    TMPDIR="$TEST_ROOT/tmp" "$name"; rc=$?
    [ "$rc" -eq "$TRELLIS_EX_UNAVAILABLE" ] || fail "wrong signal status: $rc"
    [ -f "$TEST_ROOT/released" ] || fail 'user lock cleanup not attempted'
    [ -f "$TEST_ROOT/remedy-home" ] || fail 'user recovery remedy not attempted'
    [ "$(<"$TEST_ROOT/remedy-home")" = "$TEST_ROOT/home" ] || fail 'remedy lost home binding'
    [ "$(<"$TEST_ROOT/remedy-status")" = 5 ] || fail 'remedy lost signal status'
    no_matching "$TEST_ROOT/tmp" 'trellis.user.plan.*' || exit 1
    ;;
  reconcile-bound|reconcile-owner)
    mkdir "$TEST_ROOT/tmp" "$TEST_ROOT/home"
    printf '%s\n' '{"fleet":"personal","project_id":"test","attachment_id":"uuid"}' > "$TEST_ROOT/owner.json"
    _ATTACHMENT_CHECKOUT_LOCK_HOLDER=held
    trellis_home_registry_lock_acquire() { :; }
    trellis_home_lock_release() { : > "$TEST_ROOT/released"; }
    _attachment_signal_exit() { trap - HUP INT TERM; exit "${TRELLIS_EX_UNAVAILABLE:-5}"; }
    attach_reconcile_load_registry() { signal_this_shell; return "$TRELLIS_EX_STATE"; }
    if [ "$case_name" = reconcile-bound ]; then name=attach_reconcile_bound_harnesses; else name=attach_reconcile_owner_registry; fi
    load_function "$root/scripts/attach-project.sh" "$name" || exit 1
    TMPDIR="$TEST_ROOT/tmp" "$name" "$TEST_ROOT/home" "$TEST_ROOT/owner.json" '{"checkout_id":"co","worktree_id":"wt"}'; rc=$?
    [ "$rc" -eq "$TRELLIS_EX_UNAVAILABLE" ] || fail "wrong signal status: $rc"
    [ -f "$TEST_ROOT/released" ] || fail 'registry lock cleanup not attempted'
    no_matching "$TEST_ROOT/tmp" 'trellis.reconcile.*' || exit 1
    ;;
  fastpath)
    mkdir -p "$TEST_ROOT/tmp" "$TEST_ROOT/lib" "$TEST_ROOT/home/state/attachments/co" "$TEST_ROOT/project" \
      "$TEST_ROOT/attach-holder" "$TEST_ROOT/home-lock"
    # --begin runs inside the digest command substitution, so its parent is
    # that subshell; signal the grandparent, the shell running the function.
    printf '%s\n' 'import os, signal, subprocess' \
      'parent = subprocess.check_output(["/bin/ps", "-o", "ppid=", "-p", str(os.getppid())])' \
      'os.kill(int(parent), signal.SIGTERM)' > "$TEST_ROOT/lib/attach-fastpath.py"
    printf '# test stub\n' > "$TEST_ROOT/lib/release-executed.py"
    # Consumed by the extracted production fastpath function.
    # shellcheck disable=SC2034
    SCRIPT_DIR="$TEST_ROOT"; unset TRELLIS_LIBS_PRELOADED
    # B4b: the caller owns the checkout pin; the function pins the other two.
    # shellcheck disable=SC2034
    _T13_OWN_31=1; _T13_CHECKOUT_PID=$$
    trellis_attach_postjob_spawn() { :; }
    attach_uuid() { echo uid; }
    # shellcheck disable=SC2034
    _attachment_lock_acquire() { _ATTACHMENT_LOCK_HOLDER="$TEST_ROOT/attach-holder"; _ATTACHMENT_PROCESS_PID=$$; }
    # shellcheck disable=SC2034
    trellis_home_lock_acquire() { _TRELLIS_HOME_LOCK_DIR="$TEST_ROOT/home-lock"; }
    _local_registry_diagnostic_token() { printf '%s\n' token; }
    local_registry_read_diagnostic_state() { printf '%s\n' '{}'; }
    attach_t13_close_fast_pins() { printf 'pins\n' >> "$TEST_ROOT/cleanup-order"; }
    _attachment_lock_release() { printf 'attachment-lock\n' >> "$TEST_ROOT/cleanup-order"; }
    trellis_home_lock_release() { printf 'registry-lock\n' >> "$TEST_ROOT/cleanup-order"; }
    load_function "$root/scripts/attach-project.sh" attach_try_donor_fastpath || exit 1
    TMPDIR="$TEST_ROOT/tmp" attach_try_donor_fastpath "$TEST_ROOT/home" "$TEST_ROOT/project" personal p '{"checkout_id":"co","worktree_id":"wt"}' 1 '[]' donor rootpin commonpin ''; rc=$?
    [ "$rc" -eq 143 ] || fail "wrong signal status: $rc"
    [ "$(cat "$TEST_ROOT/cleanup-order" 2>/dev/null)" = "$(printf 'pins\nattachment-lock\nregistry-lock')" ] ||
      fail "fastpath cleanup order: $(tr '\n' ' ' < "$TEST_ROOT/cleanup-order" 2>/dev/null)"
    no_matching "$TEST_ROOT/tmp" 'trellis.fast-plan.*' || exit 1
    ;;
  detach-return)
    mkdir "$TEST_ROOT/tmp"
    TMPDIR="$TEST_ROOT/tmp"; export TMPDIR
    printf 'keep\n' > "$TEST_ROOT/caller-owned"
    # Force the real helper's early-return branch, then return from a caller
    # whose distinct local has the same name as the helper's scratch variable.
    chmod() { return 1; }
    load_command "$root/scripts/lib/attachment.sh" _attachment_detach_owner_data_valid || exit 1
    outer() {
      local tmp="$TEST_ROOT/caller-owned"
      _attachment_detach_owner_data_valid '{}' || :
      [ -f "$tmp" ] || fail 'caller file removed before return'
    }
    outer
    [ -f "$TEST_ROOT/caller-owned" ] || fail 'RETURN trap escaped and deleted caller-owned file'
    no_matching "$TEST_ROOT/tmp" 'trellis.detach.owner.*' || exit 1
    ;;
  flagged-diff-claude|flagged-diff-codex)
    mkdir "$TEST_ROOT/project" "$TEST_ROOT/tmp"
    git -C "$TEST_ROOT/project" init -q || exit 1
    if [ "$case_name" = flagged-diff-claude ]; then deps="$root/core-rules/hooks/lib/deps.sh"; else deps="$root/core-rules/codex/hooks/lib/deps.sh"; fi
    # The test deliberately exercises either real harness twin.
    # shellcheck disable=SC1090
    . "$deps"
    # Load deps-heavy.sh before installing the seams: its first-call stubs
    # source it again, which would replace them with the real definitions.
    _se_load_heavy || exit 1
    _se_unmasked_index() {
      local allocated
      allocated=$(mktemp -d "$TEST_ROOT/tmp/trellis-flags.XXXXXX") || return 1
      : > "$allocated/index"; : > "$allocated/paths"; printf '%s' "$allocated"
    }
    _se_hook_state_git() { return 17; }
    ( set -e; _se_flagged_changed_files "$TEST_ROOT/project" ) 2>"$TEST_ROOT/err"; rc=$?
    [ "$rc" -ne 0 ] || fail 'flagged diff unexpectedly succeeded'
    if grep -q 'unbound variable' "$TEST_ROOT/err"; then fail 'flagged diff EXIT trap lost its directory'; fi
    no_matching "$TEST_ROOT/tmp" 'trellis-flags.*' || exit 1
    ;;
  flagged-claude|flagged-codex)
    mkdir "$TEST_ROOT/project" "$TEST_ROOT/tmp"
    git -C "$TEST_ROOT/project" init -q || exit 1
    printf 'initial\n' > "$TEST_ROOT/project/app.js"
    git -C "$TEST_ROOT/project" add app.js || exit 1
    git -C "$TEST_ROOT/project" -c user.name=Test -c user.email=test@example.invalid commit -qm seed || exit 1
    git -C "$TEST_ROOT/project" update-index --assume-unchanged app.js || exit 1
    if [ "$case_name" = flagged-claude ]; then deps="$root/core-rules/hooks/lib/deps.sh"; else deps="$root/core-rules/codex/hooks/lib/deps.sh"; fi
    # The test deliberately exercises either real harness twin.
    # shellcheck disable=SC1090
    . "$deps"
    # Fail after allocation, at the real index-copy operation.
    cp() { return 17; }
    TMPDIR="$TEST_ROOT/tmp"; export TMPDIR
    result=$(_se_unmasked_index "$TEST_ROOT/project" 2>"$TEST_ROOT/err"); rc=$?
    [ "$rc" -ne 0 ] || fail 'unmasked-index failure unexpectedly succeeded'
    [ -z "$result" ] || fail 'failed index allocation returned a path'
    if grep -q 'unbound variable' "$TEST_ROOT/err"; then fail 'EXIT trap lost its temporary directory'; fi
    no_matching "$TEST_ROOT/tmp" 'trellis-flags.*' || exit 1
    ;;
  r2-render-*|r2-owner-*|r2-hooks-*)
    # Signal from callees with the same locals as the actual production
    # verification/rename helpers. Each case signals only once, even if the
    # rollback itself calls the same helper again.
    phase=${case_name##*-}
    case "$case_name" in r2-render-*) kind=render ;; r2-owner-*) kind=owner ;; *) kind=hooks ;; esac
    MARKER="$TEST_ROOT/swapped"; SIGNALLED="$TEST_ROOT/signalled"
    maybe_signal() {
      if [ "$phase" = "$1" ] && [ ! -e "$SIGNALLED" ]; then
        : > "$SIGNALLED"
        signal_this_shell
      fi
    }
    max_status() { if [ "$1" -gt "$2" ]; then printf %s "$1"; else printf %s "$2"; fi; }
    _attachment_canonical_dir() { [ -d "$1" ]; }
    _attachment_fs_identity() { printf '%s' synthetic-id; }
    _attachment_mode_matches() { local path="$1" expected="$2"; [ -e "$path" ] && [ -n "$expected" ]; }
    _attachment_identity_matches() {
      # `destination` is an additional shadow stressor for owner cleanup;
      # the current identity helper itself uses path/expected/kind locals.
      local path="$1" expected="$2" kind="$3" destination="$1"
      if [ "$kind" = file ] && [ "$case_name" != "r2-render-$phase" ] && [ "$case_name" != "r2-hooks-$phase" ]; then
        if [ -e "$MARKER" ]; then
          case "$path" in ./.destination.release-adopt.*) maybe_signal old ;; ./destination) maybe_signal new ;; esac
        else
          maybe_signal pre
        fi
      fi
      [ -n "$expected" ] && [ -e "$path" ]
    }
    adoption_private_render_file_matches() { :; }
    adoption_render_live_matches() {
      local destination="$1" source="$2" identity="$3" expected_hash="$4" expected_mode="$5"
      if [ -e "$MARKER" ]; then
        if [ "$source" = "$TEST_ROOT/expected" ]; then maybe_signal old; else maybe_signal new; fi
      else
        maybe_signal pre
      fi
      [ -z "$identity" ] || _attachment_identity_matches "$destination" "$identity" file || return 1
      [ -n "$expected_hash" ] && [ -n "$expected_mode" ] && cmp -s "$destination" "$source"
    }
    release_store_rename_swap() {
      # release_store_atomic_rename has source and destination locals.
      local source="$1" destination="$2"
      mv "$source" "$source.swap" && mv "$destination" "$source" && mv "$source.swap" "$destination" || return "$TRELLIS_EX_STATE"
      if [ ! -e "$MARKER" ]; then : > "$MARKER"; maybe_signal swap; fi
    }
    if [ "$kind" = hooks ]; then
      mkdir "$TEST_ROOT/managed"
      printf 'old\n' > "$TEST_ROOT/managed/release-payload"
      hook_payload_matches() {
        local managed="$1" expected="$2" root="$3"
        if [ -e "$MARKER" ]; then
          if [ "$expected" = old ]; then maybe_signal old; else maybe_signal new; fi
        else
          maybe_signal pre
        fi
        [ -d "$managed" ] && [ -n "$root" ] && printf '%s\n' "$expected" | cmp -s - "$managed/release-payload"
      }
      _attachment_hooks_read_sidecar() { printf '%s' fixture; }
      _attachment_hooks_release_manifest_sha256() { printf '%s' manifest; }
      _attachment_hooks_post_checkout_dispatcher_body() { printf '%s' '#!/bin/sh'; }
      _attachment_hooks_pre_push_dispatcher_body() { printf '%s' '#!/bin/sh'; }
      _attachment_hooks_expected_passthrough_names() { :; }
      write_hook_state_file() { printf '%s\n' "$2" > "$1" && chmod "$3" "$1"; }
      load_function "$root/scripts/release.sh" replace_hook_payload || exit 1
      replace_hook_payload "$TEST_ROOT/managed" old new "$TEST_ROOT"; rc=$?
      [ "$rc" -eq "$TRELLIS_EX_STATE" ] || fail "wrong hook signal status: $rc"
      [ "$(<"$TEST_ROOT/managed/release-payload")" = old ] || fail 'hook payload not restored'
      no_matching "$TEST_ROOT" '.managed.release-adopt.*' || exit 1
    else
      printf 'old\n' > "$TEST_ROOT/destination"
      printf 'old\n' > "$TEST_ROOT/expected"
      printf 'new\n' > "$TEST_ROOT/replacement"
      chmod 600 "$TEST_ROOT/destination" "$TEST_ROOT/expected" "$TEST_ROOT/replacement"
      if [ "$kind" = owner ]; then
        load_function "$root/scripts/release.sh" replace_owned_file || exit 1
        replace_owned_file "$TEST_ROOT/destination" "$TEST_ROOT/expected" "$TEST_ROOT/replacement"; rc=$?
        pattern='.destination.release-adopt.*'
      else
        load_function "$root/scripts/release.sh" adoption_publish_render || exit 1
        plan=$(jq -cn --arg dest "$TEST_ROOT/destination" --arg old "$TEST_ROOT/expected" --arg new "$TEST_ROOT/replacement" \
          '{destination:$dest,source:$old,source_identity:"id",source_sha256:"old-hash",source_mode:"0600",path_identity:"id",candidate:$new,candidate_identity:"id",candidate_sha256:"new-hash",candidate_mode:"0600"}')
        adoption_publish_render "$plan" forward; rc=$?
        pattern='.destination.release-adopt-render.*'
      fi
      [ "$rc" -eq "$TRELLIS_EX_UNAVAILABLE" ] || fail "wrong exchange signal status: $rc"
      cmp -s "$TEST_ROOT/destination" "$TEST_ROOT/expected" || fail 'exchange did not restore the original'
      no_matching "$TEST_ROOT" "$pattern" || exit 1
    fi
    [ -f "$SIGNALLED" ] || fail 'the intended signal site was not reached'
    ;;
  adopt-group)
    body=$(awk '/^  adopt_group_cleanup\(\) \{$/{p=1} p{print} p && /^  \}$/{exit}' "$root/scripts/release.sh")
    [ -n "$body" ] || fail 'adopt group cleanup missing'
    (
      cleanup_started=false committed=true lock_held=false durable=false
      # These bindings are consumed by the extracted cleanup body.
      : "$cleanup_started" "$committed" "$lock_held" "$durable"
      eval "$body"
      trap 'adopt_group_cleanup "$?"' EXIT
      trap 'adopt_group_cleanup 5; exit "$?"' HUP INT TERM
      signal_this_shell
      exit 99
    ); rc=$?
    [ "$rc" -eq 5 ] || fail "wrong group cleanup signal status: $rc"
    ;;
  r2-materialize-lock-registry|r2-materialize-lock-scheduled-tasks|r2-materialize-lock-foreign|r2-materialize-lock-different|r2-materialize-lock-different-set|r2-materialize-lock-missing)
    # Inject TERM after the pid record, before the helper/caller flags. Use
    # the real release/owner checks against an isolated lock directory.
    target_lock=${case_name#r2-materialize-lock-}
    lock_kind=ours holder=''
    case "$target_lock" in
      foreign) lock_kind=foreign; target_lock=registry; /bin/sleep 60 & holder=$! ;;
      different|different-set|missing) lock_kind="$target_lock"; target_lock=registry ;;
    esac
    mkdir -p "$TEST_ROOT/home" "$TEST_ROOT/release/payload"
    printf '%s\n' '{"active_cli_release":"1","fleets":{"personal":{}}}' > "$TEST_ROOT/home/config.json"
    printf '%s\n' '{"commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' > "$TEST_ROOT/release/release.json"
    _TRELLIS_HOME_LOCK_DIR=''
    load_command "$root/scripts/lib/trellis-home.sh" trellis_home_lock_release || exit 1
    # Record every attempted release, while still executing its real checks.
    release_body=$(declare -f trellis_home_lock_release)
    release_body=${release_body/trellis_home_lock_release/_fixture_real_lock_release}
    eval "$release_body"
    trellis_home_lock_release() {
      printf '%s\n' "${_TRELLIS_HOME_LOCK_DIR:-}" >> "$TEST_ROOT/release-trace"
      _fixture_real_lock_release
    }
    load_command "$root/scripts/lib/trellis-home.sh" trellis_home_lock_read_pid || exit 1
    load_command "$root/scripts/lib/trellis-home.sh" trellis_home_lock_has_only_pid || exit 1
    trellis_home_require_fleet_name() { :; }
    require_task_name() { :; }
    local_registry_home() { printf '%s\n' "$TEST_ROOT/home"; }
    trellis_home_prepare_home() { :; }
    trellis_home_config_path() { printf '%s\n' "$1/config.json"; }
    trellis_home_validate_config() { :; }
    release_store_locate() { printf '%s\n' "$TEST_ROOT/release"; }
    trellis_home_prepare_private_dir() { mkdir -p "$1"; chmod 700 "$1"; }
    materialize_directory_identity() { printf '%s\n' "$1"; }
    validate_existing_task_root() { :; }
    task_publish_identity() { echo id; }
    pin_verified_release_manifest() { echo digest; }
    stage_release_task_assets() { mkdir -p "$4/.release-assets"; }
    materialize_error() { printf 'fixture materialize: %s\n' "$*" >&2; }
    verify_pinned_release_manifest() { :; }
    verify_staged_release_asset() { :; }
    render_template() { : > "$2"; }
    task_requires_checkout() { return 1; }
    trellis_home_lock_acquire() {
      local lock_dir="$TEST_ROOT/home/locks/$2.lock" recorded_pid="$$"
      if [ "$2" = "$target_lock" ]; then
        case "$lock_kind" in foreign) recorded_pid="$holder" ;; different*) recorded_pid=99999999 ;; esac
      fi
      mkdir -p "$lock_dir" || return 4
      if [ "$2" = "$target_lock" ] && [ "$lock_kind" = missing ]; then
        : > "$TEST_ROOT/lock-reached"; signal_this_shell
      fi
      printf '%s\n' "$recorded_pid" > "$lock_dir/pid" || return 4
      if [ "$2" = "$target_lock" ]; then
        [ "$lock_kind" != different-set ] || _TRELLIS_HOME_LOCK_DIR="$lock_dir"
        : > "$TEST_ROOT/lock-reached"; signal_this_shell
      fi
      _TRELLIS_HOME_LOCK_DIR="$lock_dir"
    }
    if grep -q '^materialize_lock_acquire() {' "$root/scripts/materialize-scheduled-task.sh"; then
      load_command "$root/scripts/materialize-scheduled-task.sh" materialize_lock_acquire || exit 1
    fi
    if [ "$target_lock" = registry ]; then
      # Exercise the real registry-acquire call, not a test stand-in.
      load_command "$root/scripts/materialize-scheduled-task.sh" capture_registry_snapshot || exit 1
    else
      capture_registry_snapshot() {
        if declare -F materialize_lock_acquire >/dev/null; then
          materialize_lock_acquire "$1" registry 30 || return "$?"
        else
          trellis_home_lock_acquire "$1" registry 30 || return "$?"
        fi
        trellis_home_lock_release || return "$?"
        printf '%s\n' '{"entries":[]}' > "$3"
      }
    fi
    canonicalize_registry_snapshot() { cp "$1" "$2"; }
    body=$(awk '/^cmd_materialize\(\) [{(]$/{p=1} p{print} p && (/^}$/ || /^\)$/){exit}' "$root/scripts/materialize-scheduled-task.sh")
    [ -n "$body" ] || fail 'materialize function missing'
    eval "$body"
    ( cmd_materialize --fleet personal example; exit "$?" ); rc=$?
    lock_path="$TEST_ROOT/home/locks/$target_lock.lock"
    kept=false; holder_alive=false
    case "$lock_kind" in
      foreign)
        [ -f "$lock_path/pid" ] && [ "$(<"$lock_path/pid")" = "$holder" ] && kept=true
        kill -0 "$holder" 2>/dev/null && holder_alive=true
        kill "$holder" 2>/dev/null || true
        wait "$holder" 2>/dev/null || true
        ;;
      different*) [ -f "$lock_path/pid" ] && [ "$(<"$lock_path/pid")" = 99999999 ] && kept=true ;;
      missing) [ -d "$lock_path" ] && [ ! -e "$lock_path/pid" ] && kept=true ;;
    esac
    [ "$rc" -eq 143 ] || fail "wrong signal status at $target_lock lock: $rc"
    [ -f "$TEST_ROOT/lock-reached" ] || fail "did not reach $target_lock lock"
    if [ "$lock_kind" = ours ]; then
      [ ! -e "$lock_path" ] || fail "owned $target_lock lock leaked after TERM"
      grep -Fx "$lock_path" "$TEST_ROOT/release-trace" >/dev/null || fail 'owned lock bypassed the real release checker'
    else
      [ "$kept" = true ] || fail 'foreign lock or its PID record was removed'
      [ ! -e "$TEST_ROOT/release-trace" ] || fail 'attempted to release a different PID lock'
      [ "$lock_kind" != foreign ] || [ "$holder_alive" = true ] || fail 'foreign holder was not alive'
    fi
    no_matching "$TEST_ROOT/home/tasks/personal" '.example.tmp.*' || exit 1
    ;;
  r2-materialize-signal)
    # The signalled PID is the script itself, not its process group. Wait for
    # the actual blocked helper and later for stage cleanup, so an orphaned
    # publisher cannot pass merely because the parent already exited.
    "$BASH" --noprofile --norc "$root/scripts/tests/helpers/bash32-trap-driver.sh" \
      r2-materialize-worker "$root" "$TEST_ROOT" > "$TEST_ROOT/worker.log" 2>&1 &
    worker=$!
    i=0
    while [ ! -f "$TEST_ROOT/ready" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
    if [ ! -f "$TEST_ROOT/ready" ]; then
      kill -TERM "$worker" 2>/dev/null || true
      wait "$worker" 2>/dev/null || true
      fail 'materializer never reached the blocked verified-manifest helper'
    fi
    kill -TERM "$worker" || fail 'could not signal materializer PID'
    : > "$TEST_ROOT/go"
    wait "$worker"; rc=$?
    [ "$rc" -eq 143 ] || fail "wrong materializer signal status: $rc"
    i=0
    while [ "$i" -lt 200 ]; do
      stages=$(find "$TEST_ROOT/home/tasks/personal" -maxdepth 1 -name '.example.tmp.*' -print)
      [ -n "$stages" ] || break
      sleep 0.05; i=$((i + 1))
    done
    no_matching "$TEST_ROOT/home/tasks/personal" '.example.tmp.*' || exit 1
    [ ! -e "$TEST_ROOT/continued" ] || fail 'child continued toward publication after parent TERM'
    ;;
  r2-materialize-worker)
    mkdir -p "$TEST_ROOT/home" "$TEST_ROOT/release/payload"
    printf '%s\n' '{"active_cli_release":"1","fleets":{"personal":{}}}' > "$TEST_ROOT/home/config.json"
    printf '%s\n' '{"commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' > "$TEST_ROOT/release/release.json"
    trellis_home_require_fleet_name() { :; }
    require_task_name() { :; }
    local_registry_home() { printf '%s\n' "$TEST_ROOT/home"; }
    trellis_home_prepare_home() { :; }
    trellis_home_config_path() { printf '%s\n' "$1/config.json"; }
    trellis_home_validate_config() { :; }
    release_store_locate() { printf '%s\n' "$TEST_ROOT/release"; }
    trellis_home_prepare_private_dir() { mkdir -p "$1"; chmod 700 "$1"; }
    materialize_directory_identity() { printf '%s\n' "$1"; }
    validate_existing_task_root() { :; }
    task_publish_identity() { echo id; }
    pin_verified_release_manifest() {
      : > "$TEST_ROOT/ready"
      while [ ! -f "$TEST_ROOT/go" ]; do sleep 0.05; done
      printf '%s\n' digest
    }
    stage_release_task_assets() { : > "$TEST_ROOT/continued"; return "$TRELLIS_EX_STATE"; }
    body=$(awk '/^cmd_materialize\(\) [{(]$/{p=1} p{print} p && (/^}$/ || /^\)$/){exit}' "$root/scripts/materialize-scheduled-task.sh")
    [ -n "$body" ] || fail 'materialize function missing'
    eval "$body"
    cmd_materialize --fleet personal example
    ;;
  r2-jq-errexit)
    mkdir "$TEST_ROOT/tmp" "$TEST_ROOT/bin"
    printf '#!/bin/sh\nexit 7\n' > "$TEST_ROOT/bin/jq"; chmod 700 "$TEST_ROOT/bin/jq"
    load_function "$root/scripts/lib/trellis-home.sh" trellis_jq || exit 1
    big=$(printf '%065536d' 0)
    ( set -e; PATH="$TEST_ROOT/bin:$PATH" TMPDIR="$TEST_ROOT/tmp" trellis_jq --arg payload "$big" -n '$payload'; : > "$TEST_ROOT/continued" ) 2> "$TEST_ROOT/err"; rc=$?
    [ "$rc" -eq 7 ] || fail "wrong jq errexit status: $rc"
    [ ! -e "$TEST_ROOT/continued" ] || fail 'errexit did not stop the caller'
    ! grep -q 'unbound variable' "$TEST_ROOT/err" || fail 'jq cleanup lost its scratch binding'
    no_matching "$TEST_ROOT/tmp" 'trellis-jq.*' || exit 1
    ;;
  r2-user-*)
    parts=${case_name#r2-user-}; verb=${parts%%-*}; step=${parts#*-}
    mkdir "$TEST_ROOT/tmp" "$TEST_ROOT/user" "$TEST_ROOT/home" "$TEST_ROOT/release"
    attach_user_parse_common() {
      ATTACH_USER_HOME_OPT="$TEST_ROOT/home"; ATTACH_USER_RELEASE_OPT=1
      ATTACH_USER_CONFIGURE_LOCK_HELD=0; ATTACH_USER_RECOVER_ONLY=0
      [ "$step" != planlock ] || ATTACH_USER_CONFIGURE_LOCK_HELD=1
      # The extracted user command consumes these names through eval.
      : "$ATTACH_USER_HOME_OPT" "$ATTACH_USER_RELEASE_OPT" "$ATTACH_USER_CONFIGURE_LOCK_HELD" "$ATTACH_USER_RECOVER_ONLY"
    }
    trellis_home_resolve() { printf '%s\n' "$1"; }
    trellis_home_canonical_home() { printf '%s\n' "$1"; }
    trellis_home_config_path() { printf '%s\n' "$1/config.json"; }
    trellis_home_resolve_release() { echo 1; }
    attach_locate_release() { _ATTACH_LOCATED_RELEASE="$TEST_ROOT/release"; }
    _attachment_user_runtime_home() { printf '%s\n' "$TEST_ROOT/user"; }
    attach_uuid() { echo uid; }
    _attachment_signal_exit() { trap - HUP INT TERM; exit "${TRELLIS_EX_UNAVAILABLE:-5}"; }
    attach_user_repair_remedy() {
      printf '%s' "${1-}" > "$TEST_ROOT/remedy-home"
      printf '%s' "${2-}" > "$TEST_ROOT/remedy-status"
      printf '%s' "${3-}" > "$TEST_ROOT/remedy-lock"
    }
    _attachment_user_lock_release() { : > "$TEST_ROOT/released"; }
    maybe_user_signal() { if [ "$step" = "$1" ]; then : > "$TEST_ROOT/signalled"; signal_this_shell; fi; }
    # Model the same dynamic-scope collision as attach_user_recover_pending
    # and attach_user_repair_missing_symlinks, including the lock flag.
    attachment_user_lock_reclaim() { local home=wrong plan_file='' configure_lock_validated=0; maybe_user_signal reclaim; return 0; }
    attachment_user_lock_acquire() { local home=wrong plan_file='' configure_lock_validated=0; maybe_user_signal acquire; return 0; }
    attach_user_recover_pending() {
      local home="$1" plan_file=''
      # This is the real helper's local shape at the reported leak site.
      if [ "$step" = realrecover ]; then maybe_user_signal realrecover; fi
      local configure_lock_validated=0
      home=wrong; maybe_user_signal recover
      return 0
    }
    attach_user_configure_lock_valid() { return 0; }
    _attachment_user_owner_path() { printf '%s\n' "$TEST_ROOT/home/owner"; }
    attach_user_internal() {
      local home=wrong plan_file='' configure_lock_validated=0
      maybe_user_signal "$step"
      : "$home" "$plan_file" "$configure_lock_validated"
      return "$TRELLIS_EX_STATE"
    }
    name="attach_cmd_user_$verb"
    load_function "$root/scripts/attach-project.sh" "$name" || exit 1
    TMPDIR="$TEST_ROOT/tmp" "$name"; rc=$?
    [ "$rc" -eq "$TRELLIS_EX_UNAVAILABLE" ] || fail "wrong user signal status: $rc"
    [ -f "$TEST_ROOT/signalled" ] || fail 'the intended signal site was not reached'
    [ -f "$TEST_ROOT/released" ] || fail 'user lock cleanup not attempted'
    no_matching "$TEST_ROOT/tmp" 'trellis.user.plan.*' || exit 1
    no_matching "$TEST_ROOT/tmp" 'trellis.user-relink.plan.*' || exit 1
    [ "$(<"$TEST_ROOT/remedy-home")" = "$TEST_ROOT/home" ] || fail 'remedy lost original home'
    [ "$(<"$TEST_ROOT/remedy-status")" = 5 ] || fail 'remedy lost signal status'
    if [ "$step" = planlock ]; then
      [ "$(<"$TEST_ROOT/remedy-lock")" = 1 ] || fail 'remedy lost validated configure lock'
    fi
    ;;
  *) fail "unknown case: $case_name" ;;
esac
if [ "$order_case" = true ]; then
  [ -f "$TEST_ROOT/second-term" ] || fail 'cleanup did not disarm EXIT'
  [ -f "$TEST_ROOT/signals-blocked" ] || fail 'cleanup did not ignore signals'
  [ ! -f "$TEST_ROOT/wrong-trap-order" ] || fail 'cleanup disarmed EXIT before ignoring signals'
fi
