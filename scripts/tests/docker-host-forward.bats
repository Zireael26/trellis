#!/usr/bin/env bats
# End-to-end hooks: resolve caller contexts before isolation; forward only DOCKER_HOST.
REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  bats_require_minimum_version 1.5.0
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
  git -C "$PROJECT" config --local core.hooksPath "$MANAGED"
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
  # Recording stub, always green: the gate payload must observe the caller's
  # DOCKER_HOST exactly (set stays set, empty stays empty, unset stays
  # absent), so it records rather than refuses. Prior-hook assertions keep
  # reading $RECORD; gate assertions read $ROOT/gate-env.
  cat > "$carrier" <<GATE
#!/bin/sh
printf 'DOCKER_HOST=%s\\n' "\${DOCKER_HOST-__UNSET__}" > "$ROOT/gate-env"
printf 'DOCKER_CONTEXT=%s\\n' "\${DOCKER_CONTEXT-__UNSET__}" >> "$ROOT/gate-env"
printf 'DOCKER_CONFIG=%s\\n' "\${DOCKER_CONFIG-__UNSET__}" >> "$ROOT/gate-env"
printf 'HOME=%s\\n' "\${HOME-__UNSET__}" >> "$ROOT/gate-env"
exit 0
GATE
  chmod 700 "$carrier"
  # The pre-push dispatcher runs the deferred attachment checks first: the
  # fixture payload must carry an executable postjob, as real releases do.
  mkdir -p "$payload/scripts/lib" || return 1
  printf '#!/bin/sh\nexit 0\n' > "$payload/scripts/lib/attach-postjob.sh" || return 1
  chmod 700 "$payload/scripts/lib/attach-postjob.sh" || return 1
  carrier_oid="$(git hash-object "$carrier")" || return 1
  postjob_oid="$(git hash-object "$payload/scripts/lib/attach-postjob.sh")" || return 1
  jq -n --arg oid "$carrier_oid" --arg postjob_oid "$postjob_oid" \
    '{schema_version:1,version:"1.2.3",tag:"v1.2.3",commit:"0000000000000000000000000000000000000000",remote:"fixture",tree:[{path:"core-rules/githooks/pre-push",mode:"100755",oid:$oid},{path:"scripts/lib/attach-postjob.sh",mode:"100755",oid:$postjob_oid}]}' \
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
  chmod 500 "$carrier" "$payload/scripts/lib/attach-postjob.sh" \
    "$payload/core-rules/githooks" "$payload/core-rules" \
    "$payload/scripts/lib" "$payload/scripts" "$payload" "$release"
  printf 'refs/heads/main deadbeef refs/heads/main abcdef\n' > "$ROOT/refs"
}

run_prior() {
  prepare_pre_push || return 1
  run --separate-stderr /usr/bin/env -u DOCKER_HOST -u DOCKER_CONTEXT \
    "PATH=$ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin" "HOME=$HOME" \
    "TMPDIR=$ROOT/tmp" "HOOK_RECORD=$RECORD" "$@" \
    /bin/bash -c 'cd "$1" && "$2" origin fixture < "$3"' \
    _ "$PROJECT" "$MANAGED/pre-push" "$ROOT/refs"
}

run_shim() {
  run --separate-stderr /usr/bin/env -u DOCKER_HOST -u DOCKER_CONTEXT \
    "PATH=$ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin" "HOME=$HOME" \
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

@test "render context reports missing launcher with path" {
  local fake_home="$ROOT/fake-home-missing"
  mkdir -p "$fake_home"
  run env HOME="$fake_home" bash -c 'source "$1" && attachment_contextual_render_context "$2"' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$TRELLIS_HOME"
  [ "$status" -eq "$TRELLIS_EX_UNAVAILABLE" ] || return 1
  [[ "$output" == *"launcher missing at"* ]] || return 1
  [[ "$output" == *"$fake_home/.local/bin/trellis"* ]] || return 1
}

@test "render context reports non-executable launcher with path" {
  local fake_home="$ROOT/fake-home-nonexec"
  mkdir -p "$fake_home/.local/bin"
  printf '#!/bin/sh\nexit 0\n' > "$fake_home/.local/bin/trellis"
  chmod 644 "$fake_home/.local/bin/trellis"
  run env HOME="$fake_home" bash -c 'source "$1" && attachment_contextual_render_context "$2"' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$TRELLIS_HOME"
  [ "$status" -eq "$TRELLIS_EX_STATE" ] || return 1
  [[ "$output" == *"not executable"* ]] || return 1
  [[ "$output" == *"$fake_home/.local/bin/trellis"* ]] || return 1
}

run_gate() {
  prepare_pre_push || return 1
  rm -f "$ROOT/gate-env"
  run --separate-stderr /usr/bin/env -u DOCKER_HOST -u DOCKER_CONTEXT \
    "PATH=$ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin" "HOME=$HOME" \
    "TMPDIR=$ROOT/tmp" "$@" \
    /bin/bash -c 'cd "$1" && "$2" origin fixture < "$3"' \
    _ "$PROJECT" "$MANAGED/pre-push" "$ROOT/refs"
}

assert_gate_env() {
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  grep -Fx "DOCKER_HOST=$1" "$ROOT/gate-env"
}

@test "gate payload receives DOCKER_HOST when the caller sets it" {
  run_gate DOCKER_HOST=unix:///fixture/colima.sock
  assert_gate_env unix:///fixture/colima.sock
}

@test "gate payload keeps unset DOCKER_HOST unset" {
  run_gate
  assert_gate_env __UNSET__
}

@test "gate payload receives an explicitly empty DOCKER_HOST as empty" {
  run_gate DOCKER_HOST=
  assert_gate_env ''
}

stub_docker_context() {
  mkdir -p "$ROOT/bin"
  printf 'unix://%s/docker.sock\n' "$ROOT" > "$HOME/docker-endpoint"
  cat > "$ROOT/bin/docker" <<SH
#!/bin/sh
printf '%s\\n' "\$HOME" > "$ROOT/docker-home"
printf '%s\\n' "\$@" > "$ROOT/docker-args"
[ "${1:-0}" -eq 0 ] || exit 1
/bin/cat "\$HOME/docker-endpoint"
SH
  chmod 700 "$ROOT/bin/docker"
}

assert_context_resolution() {
  grep -Fx "$HOME" "$ROOT/docker-home"
  printf '%s\n' context inspect "$1" --format '{{.Endpoints.docker.Host}}' > "$ROOT/expected-args"
  cmp "$ROOT/expected-args" "$ROOT/docker-args"
}

@test "pre-push resolves caller DOCKER_CONTEXT before isolation" {
  stub_docker_context
  run_prior DOCKER_CONTEXT=colima
  assert_hook_env "unix://$ROOT/docker.sock"
  assert_context_resolution colima
  [ -z "$stderr" ] || { printf 'unexpected stderr: %s\n' "$stderr"; false; }
}

@test "passthrough shim bytes remain compatible with existing husky attachments" {
  local digest
  digest="$(printf '%s\n' "$(_attachment_hooks_passthrough_shim_body pre-commit)" | shasum -a 256)"
  # Pin the pre-1.3.16 bytes: shim verification is not release-versioned.
  [ "${digest%% *}" = 36b82c9dd9a6bb366ca127f7d3ff22d30eb2ad0a907dad6da442fdf2a952369f ]
}

@test "gate receives only the resolved Docker endpoint without context metadata" {
  stub_docker_context
  run_gate DOCKER_CONTEXT=colima "DOCKER_CONFIG=$HOME/context-store"
  assert_gate_env "unix://$ROOT/docker.sock"
  assert_context_resolution colima
  grep -Fx 'DOCKER_CONTEXT=__UNSET__' "$ROOT/gate-env"
  grep -Fx 'DOCKER_CONFIG=__UNSET__' "$ROOT/gate-env"
  ! grep -Fx "HOME=$HOME" "$ROOT/gate-env"
}

@test "pre-push does not resolve DOCKER_CONTEXT when DOCKER_HOST is explicitly empty" {
  stub_docker_context
  run_prior DOCKER_HOST= DOCKER_CONTEXT=colima
  assert_hook_env ''
  [ ! -e "$ROOT/docker-args" ]
}

@test "passthrough shim does not resolve DOCKER_CONTEXT when DOCKER_HOST is explicitly empty" {
  stub_docker_context
  run_shim DOCKER_HOST= DOCKER_CONTEXT=colima
  assert_hook_env ''
  [ ! -e "$ROOT/docker-args" ]
}

@test "pre-push context resolution failure warns on stderr and preserves unset host" {
  stub_docker_context 1
  run_prior DOCKER_CONTEXT=missing
  assert_hook_env __UNSET__
  assert_context_resolution missing
  [ -z "$output" ]
  [ "$stderr" = 'Trellis: cannot resolve Docker context "missing"; continuing without DOCKER_HOST.' ]
}

@test "pre-push context resolution failure prints one sanitized stderr line" {
  stub_docker_context 1
  run_prior "DOCKER_CONTEXT="$'missing\ncontext'
  assert_hook_env __UNSET__
  [ -z "$output" ]
  [ "$stderr" = 'Trellis: cannot resolve Docker context "missing?context"; continuing without DOCKER_HOST.' ]
}

@test "gate continues with unset host when Docker context endpoint is empty" {
  stub_docker_context
  : > "$HOME/docker-endpoint"
  run_gate DOCKER_CONTEXT=empty
  assert_gate_env __UNSET__
  [ "$stderr" = 'Trellis: cannot resolve Docker context "empty"; continuing without DOCKER_HOST.' ]
}
