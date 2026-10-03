#!/usr/bin/env bats
# End-to-end delegated hooks: DOCKER_HOST is caller-owned, DOCKER_CONTEXT is not.
REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/docker-host-forward.XXXXXX")"
  ROOT="$(CDPATH= cd "$ROOT" && pwd -P)"
  export HOME="$ROOT/home" TRELLIS_HOME="$ROOT/trellis-home"
  mkdir -p "$HOME" "$TRELLIS_HOME"
  source "$REPO_ROOT/scripts/lib/attachment.sh"
  PROJECT="$ROOT/project"
  PRIOR="$ROOT/prior"
  MANAGED="$TRELLIS_HOME/state/git-hooks/test-id"
  RECORD="$ROOT/hook-env"
  mkdir -p "$PROJECT" "$PRIOR" "$MANAGED"
  git init -q "$PROJECT"
  cat > "$ROOT/project-hook" <<SH
#!/bin/sh
printf 'DOCKER_HOST=%s\\n' "\${DOCKER_HOST-__UNSET__}" > "$RECORD"
printf 'DOCKER_CONTEXT=%s\\n' "\${DOCKER_CONTEXT-__UNSET__}" >> "$RECORD"
SH
  chmod 700 "$ROOT/project-hook"
  cp "$ROOT/project-hook" "$PRIOR/pre-push"
  cp "$ROOT/project-hook" "$PRIOR/pre-commit"
  printf '%s\n' "$PRIOR" > "$MANAGED/previous-hooks-path"
  chmod 700 "$PRIOR/pre-push" "$PRIOR/pre-commit"
  printf '%s\n' "$(_attachment_hooks_passthrough_shim_body pre-commit)" > "$MANAGED/pre-commit"
  chmod 700 "$MANAGED/pre-commit"
}

teardown() {
  chmod -R u+w "$ROOT" 2>/dev/null || true
  rm -rf "$ROOT"
}

# A real generated pre-push dispatcher needs sealed release and owner state.
# Keep the fixture small but run the exact generated script, not a mock env -i.
prepare_pre_push() {
  local payload="$TRELLIS_HOME/releases/1.2.3/payload" release carrier carrier_oid manifest
  local common checkout worktree owner
  carrier="$payload/core-rules/githooks/pre-push"
  release="${payload%/payload}"
  mkdir -p "$(dirname "$carrier")" "$TRELLIS_HOME/state/attachments" "$ROOT/bin" "$ROOT/tmp"
  printf '#!/bin/sh\n[ "${DOCKER_HOST+x}" != x ] || exit 41\n' > "$carrier"
  chmod 700 "$carrier"
  carrier_oid="$(git hash-object "$carrier")" || return 1
  jq -n --arg oid "$carrier_oid" \
    '{schema_version:1,version:"1.2.3",tag:"v1.2.3",commit:"0000000000000000000000000000000000000000",remote:"fixture",tree:[{path:"core-rules/githooks/pre-push",mode:"100755",oid:$oid}]}' \
    > "$release/release.json"
  manifest="$(_attachment_hooks_release_manifest_sha256 "$payload")" || return 1
  printf '%s\n' "$(_attachment_hooks_pre_push_dispatcher_body "$payload" 'core-rules/githooks/pre-push' "$manifest")" > "$MANAGED/pre-push"
  printf '%s\n' "$payload" > "$MANAGED/release-payload"
  printf '%s\n' 'core-rules/githooks/pre-push' > "$MANAGED/pre-push-source"
  chmod 700 "$MANAGED/pre-push"
  chmod 600 "$MANAGED/previous-hooks-path" "$MANAGED/release-payload" "$MANAGED/pre-push-source"
  common="$(git -C "$PROJECT" rev-parse --git-common-dir)" || return 1
  case "$common" in /*) ;; *) common="$PROJECT/$common" ;; esac
  common="$(CDPATH= cd "$common" && pwd -P)" || return 1
  checkout="$(_attachment_hash_text "$common")" || return 1
  worktree="$(_attachment_hash_text "$PROJECT")" || return 1
  owner="$TRELLIS_HOME/state/attachments/$checkout/$worktree.json"
  mkdir -p "$(dirname "$owner")"
  jq -n --arg checkout "$checkout" --arg worktree "$worktree" \
    --arg root "$PROJECT" --arg payload "$payload" --arg managed "$MANAGED" \
    --arg prior "$PRIOR" --arg recorded "$ROOT/bin" '
    {schema_version:1,status:"committed",fleet:"personal",project_id:"docker-fixture",
     checkout_id:$checkout,worktree_id:$worktree,
     attachment_id:"00000000-0000-0000-0000-000000000002",
     project_root:$root,worktree_root:$root,release:"1.2.3",
     toolchain_path:[$recorded],
     artifacts:[{path:".trellis/runtime",kind:"symlink",target:$payload}],
     git_hooks:{enabled:true,managed_hooks_path:$managed,previous_hooks_path:$prior,
                pre_push_source:"core-rules/githooks/pre-push"}}' > "$owner"
  chmod 600 "$owner"
  _attachment_owner_json_valid "$owner" || return 1
  chmod 700 "$TRELLIS_HOME" "$TRELLIS_HOME/state" "$TRELLIS_HOME/state/git-hooks" \
    "$TRELLIS_HOME/releases" "$release" "$payload" "$payload/core-rules" \
    "$payload/core-rules/githooks" "$MANAGED" "$ROOT/bin" "$PRIOR"
  chmod 400 "$release/release.json"
  chmod 500 "$carrier" "$payload/core-rules/githooks" "$payload/core-rules" "$payload" "$release"
  printf 'refs/heads/main deadbeef refs/heads/main abcdef\n' > "$ROOT/refs"
}

run_prior() {
  prepare_pre_push || return 1
  run /usr/bin/env -u DOCKER_HOST -u DOCKER_CONTEXT \
    "PATH=$ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin" "HOME=$HOME" \
    "TMPDIR=$ROOT/tmp" "HOOK_RECORD=$RECORD" "$@" \
    /bin/bash -c 'cd "$1" && "$2" origin fixture < "$3"' \
    _ "$PROJECT" "$MANAGED/pre-push" "$ROOT/refs"
}

run_shim() {
  run /usr/bin/env -u DOCKER_HOST -u DOCKER_CONTEXT \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "HOME=$HOME" \
    "HOOK_RECORD=$RECORD" "$@" \
    /bin/bash -c 'cd "$1" && "$2"' _ "$PROJECT" "$MANAGED/pre-commit"
}

assert_hook_env() {
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  grep -Fx "DOCKER_HOST=$1" "$RECORD"
  grep -Fx 'DOCKER_CONTEXT=__UNSET__' "$RECORD"
}

@test "pre-push prior hook forwards set DOCKER_HOST" {
  run_prior DOCKER_HOST=unix:///fixture/colima.sock
  assert_hook_env unix:///fixture/colima.sock
}

@test "pre-push prior hook keeps unset DOCKER_HOST unset" {
  run_prior
  assert_hook_env __UNSET__
}

@test "pre-push prior hook keeps an explicitly empty DOCKER_HOST set" {
  run_prior DOCKER_HOST=
  assert_hook_env ''
}

@test "pre-push prior hook drops DOCKER_CONTEXT even alongside DOCKER_HOST" {
  run_prior DOCKER_HOST=unix:///fixture/colima.sock DOCKER_CONTEXT=desktop-linux
  assert_hook_env unix:///fixture/colima.sock
}

@test "passthrough shim forwards set DOCKER_HOST" {
  run_shim DOCKER_HOST=unix:///fixture/colima.sock
  assert_hook_env unix:///fixture/colima.sock
}

@test "passthrough shim keeps unset DOCKER_HOST unset" {
  run_shim
  assert_hook_env __UNSET__
}

@test "passthrough shim keeps an explicitly empty DOCKER_HOST set" {
  run_shim DOCKER_HOST=
  assert_hook_env ''
}

@test "passthrough shim drops DOCKER_CONTEXT even alongside DOCKER_HOST" {
  run_shim DOCKER_HOST=unix:///fixture/colima.sock DOCKER_CONTEXT=desktop-linux
  assert_hook_env unix:///fixture/colima.sock
}
