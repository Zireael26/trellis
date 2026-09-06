#!/usr/bin/env bats

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/managed-dispatcher-env.XXXXXX")"
  ROOT="$(CDPATH= cd "$ROOT" && pwd -P)"
  PAYLOAD="$ROOT/payload"
  MANIFEST="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/scripts/lib/attachment.sh"
  DISPATCHER_TEXT="$(_attachment_hooks_dispatcher_common_body "$PAYLOAD" "core-rules/githooks/pre-push" "$MANIFEST")"
  PRE_PUSH_TEXT="$(_attachment_hooks_pre_push_dispatcher_body "$PAYLOAD" "core-rules/githooks/pre-push" "$MANIFEST")"
  BODY="$(printf '%s\n' "$DISPATCHER_TEXT" | /usr/bin/awk 'seen{print} /^# trellis-managed-dispatcher-body$/ {seen=1}')"
}

prepare_managed_home() {
  # Place the fake dispatcher so the derived managed_home equals our temp.
  # BODY does: managed_dir=$(dirname "$managed_dispatcher") ; managed_home=$(cd "$managed_dir/../../.." && pwd -P)
  # So for managed_home == $ROOT/managed_home, dispatcher must be $ROOT/managed_home/state/git-hooks/<id>/pre-push
  local fake_managed_dir="$ROOT/managed_home/state/git-hooks/test-id"
  local fake_dispatcher="$fake_managed_dir/pre-push"
  mkdir -p "$fake_managed_dir"
  mkdir -p "$ROOT/managed_home"
  # The embedded command scratch allocator validates the Trellis home and its
  # state directory as private before it will allocate anything.
  chmod 700 "$ROOT/managed_home" "$ROOT/managed_home/state"
  : > "$fake_dispatcher"
  export TRELLIS_MANAGED_DISPATCHER="$fake_dispatcher"
  eval "$BODY"
  set +u
}

prepare_actual_pre_push_fixture() {
  local managed_home="$ROOT/managed_home"
  local managed="$managed_home/state/git-hooks/test-id"
  local payload="$managed_home/releases/1.2.3/payload"
  local release="${payload%/payload}"
  local prior_hooks="$ROOT/prior-hooks"
  local prior_hook="$prior_hooks/pre-push"
  local caller_bin="$ROOT/caller-bin"
  local recorded_bin="$ROOT/recorded-bin"
  local carrier="$payload/core-rules/githooks/pre-push"
  local common checkout worktree owner carrier_oid manifest

  FIXTURE_DISPATCHER="$managed/pre-push"
  FIXTURE_PROJECT="$ROOT/project"
  FIXTURE_REFS="$ROOT/pre-push-refs"
  FIXTURE_BIN_DIR="$caller_bin"
  FIXTURE_HOME_DIR="$ROOT/caller-home"
  FIXTURE_TMP_DIR="$ROOT/caller-tmp"

  mkdir -p "$managed" "$payload/core-rules/githooks" "$prior_hooks" \
    "$caller_bin" "$recorded_bin" "$FIXTURE_PROJECT" "$FIXTURE_HOME_DIR" "$FIXTURE_TMP_DIR"
  git config --file "$FIXTURE_HOME_DIR/.gitconfig" user.email delegated@example.invalid
  git init -q "$FIXTURE_PROJECT"
  common="$(git -C "$FIXTURE_PROJECT" rev-parse --git-common-dir)" || return 1
  case "$common" in /*) ;; *) common="$FIXTURE_PROJECT/$common" ;; esac
  common="$(CDPATH= cd "$common" && pwd -P)" || return 1
  checkout="$(_attachment_hash_text "$common")" || return 1
  worktree="$(_attachment_hash_text "$FIXTURE_PROJECT")" || return 1
  owner="$managed_home/state/attachments/$checkout/$worktree.json"
  mkdir -p "$(dirname "$owner")"
  chmod 700 \
    "$managed_home" \
    "$managed_home/state" \
    "$managed_home/state/git-hooks" \
    "$managed_home/releases" \
    "$release" \
    "$payload" \
    "$payload/core-rules" \
    "$payload/core-rules/githooks" \
    "$managed" \
    "$prior_hooks" \
    "$caller_bin" \
    "$recorded_bin"

  cat > "$caller_bin/trellis-fixture-prior-only-tool" <<'SH'
#!/bin/sh
exit 0
SH
  chmod 700 "$caller_bin/trellis-fixture-prior-only-tool"

  cat > "$prior_hook" <<EOF
#!/bin/bash
set -eu
command -v trellis-fixture-prior-only-tool >/dev/null || {
  printf 'PRIOR_TOOL_MISSING=trellis-fixture-prior-only-tool\n' >&2
  exit 1
}
trellis-fixture-prior-only-tool
expected_email='delegated@example.invalid'
actual_email="\$(git config --global user.email 2>/dev/null || true)"
if [ "\$actual_email" != "\$expected_email" ]; then
  printf 'PRIOR_GIT_CONFIG_MISSING=user.email=%s (actual=%s)\n' \
    "\$expected_email" "\${actual_email:-<unset>}" >&2
  exit 1
fi
[ "\$HOME" = "$FIXTURE_HOME_DIR" ] || exit 1
[ "\$TMPDIR" = "$FIXTURE_TMP_DIR" ] || exit 1
[ "\$TMP" = "$FIXTURE_TMP_DIR" ] || exit 1
[ "\$TEMP" = "$FIXTURE_TMP_DIR" ] || exit 1
printf 'PRIOR_CALLER_ENV=ok\n'
EOF
  chmod 700 "$prior_hook"

  cat > "$carrier" <<'SH'
#!/bin/bash
set -u
[ -z "${TRELLIS_FIXTURE_SENTINEL-}" ] || {
  printf 'managed carrier received caller sentinel\n' >&2
  exit 1
}
printf 'MANAGED_SENTINEL=absent\n'
SH
  chmod 700 "$carrier"
  carrier_oid="$(git hash-object "$carrier")"
  jq -n --arg oid "$carrier_oid" \
    '{schema_version:1,version:"1.2.3",tag:"v1.2.3",commit:"0000000000000000000000000000000000000000",remote:"fixture",tree:[{path:"core-rules/githooks/pre-push",mode:"100755",oid:$oid}]}' \
    > "$release/release.json"
  chmod 600 "$release/release.json"
  manifest="$(_attachment_hooks_release_manifest_sha256 "$payload")"

  printf '%s\n' \
    "$(_attachment_hooks_pre_push_dispatcher_body \
      "$payload" "core-rules/githooks/pre-push" "$manifest")" \
    > "$FIXTURE_DISPATCHER"
  printf '%s\n' "$prior_hooks" > "$managed/previous-hooks-path"
  printf '%s\n' "$payload" > "$managed/release-payload"
  printf '%s\n' 'core-rules/githooks/pre-push' > "$managed/pre-push-source"
  chmod 700 "$FIXTURE_DISPATCHER"
  chmod 600 \
    "$managed/previous-hooks-path" \
    "$managed/release-payload" \
    "$managed/pre-push-source"
  jq -n \
    --arg checkout "$checkout" --arg worktree "$worktree" \
    --arg root "$FIXTURE_PROJECT" --arg payload "$payload" \
    --arg managed "$managed" --arg prior "$prior_hooks" \
    --arg recorded "$recorded_bin" '
    {
      schema_version:1,
      status:"committed",
      fleet:"personal",
      project_id:"delegation-fixture",
      checkout_id:$checkout,
      worktree_id:$worktree,
      attachment_id:"00000000-0000-0000-0000-000000000002",
      project_root:$root,
      worktree_root:$root,
      release:"1.2.3",
      toolchain_path:[$recorded],
      artifacts:[{path:".trellis/runtime",kind:"symlink",target:$payload}],
      git_hooks:{
        enabled:true,
        managed_hooks_path:$managed,
        previous_hooks_path:$prior,
        pre_push_source:"core-rules/githooks/pre-push"
      }
    }' > "$owner"
  chmod 600 "$owner"
  _attachment_owner_json_valid "$owner" || return 1
  chmod 400 "$release/release.json"
  chmod 500 \
    "$carrier" \
    "$payload/core-rules/githooks" \
    "$payload/core-rules" \
    "$payload" \
    "$release"
  printf '%s\n' 'refs/heads/main deadbeef refs/heads/main abcdef' > "$FIXTURE_REFS"
}

prepare_path_stage_fixture() {
  local managed_home="$ROOT/path-managed-home"
  local release="$managed_home/releases/1.2.3"
  local payload="$release/payload"
  local common checkout worktree managed owner seed carrier seed_oid carrier_oid manifest

  PATH_STAGE_PROJECT="$ROOT/path-project"
  PATH_RECORDED_A="$ROOT/recorded-a"
  PATH_RECORDED_B="$ROOT/recorded-b"
  PATH_CALLER_BIN="$ROOT/path-caller-bin"
  PATH_CALLER_HOME="$ROOT/path-caller-home"
  PATH_CALLER_TMP="$ROOT/path-caller-tmp"
  PATH_REFS="$ROOT/path-refs"
  PATH_CONTROL_RESULT="$PATH_STAGE_PROJECT/.control-path-result"

  mkdir -p "$PATH_STAGE_PROJECT" "$PATH_RECORDED_A" "$PATH_RECORDED_B" \
    "$PATH_CALLER_BIN" "$PATH_CALLER_HOME" "$PATH_CALLER_TMP" \
    "$payload/scripts" "$payload/core-rules/githooks"
  git init -q "$PATH_STAGE_PROJECT"
  common="$(git -C "$PATH_STAGE_PROJECT" rev-parse --git-common-dir)" || return 1
  case "$common" in /*) ;; *) common="$PATH_STAGE_PROJECT/$common" ;; esac
  common="$(CDPATH= cd "$common" && pwd -P)" || return 1
  checkout="$(_attachment_hash_text "$common")" || return 1
  worktree="$(_attachment_hash_text "$PATH_STAGE_PROJECT")" || return 1
  managed="$managed_home/state/git-hooks/$checkout"
  owner="$managed_home/state/attachments/$checkout/$worktree.json"
  PATH_POST_DISPATCHER="$managed/post-checkout"
  PATH_PRE_DISPATCHER="$managed/pre-push"
  mkdir -p "$managed" "$(dirname "$owner")"
  chmod 700 "$managed_home" "$managed_home/state"

  cat > "$PATH_RECORDED_B/trellis-fixture-path-tool" <<'SH'
#!/bin/sh
printf 'RECORDED_TOOL\n'
SH
  cat > "$PATH_CALLER_BIN/trellis-fixture-path-tool" <<'SH'
#!/bin/sh
printf 'CALLER_SHIM\n'
SH
  chmod 700 \
    "$PATH_RECORDED_B/trellis-fixture-path-tool" \
    "$PATH_CALLER_BIN/trellis-fixture-path-tool"

  seed="$payload/scripts/seed-inheritance-symlinks.sh"
  cat > "$seed" <<'SH'
#!/bin/bash
set -u
target=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) target="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$target" ] || exit 2
{
  printf 'CONTROL_PATH=%s\n' "$PATH"
  if command -v trellis-fixture-path-tool >/dev/null 2>&1; then
    printf 'CONTROL_TOOL=visible:%s\n' "$(trellis-fixture-path-tool)"
  else
    printf 'CONTROL_TOOL=absent\n'
  fi
} > "$target/.control-path-result"
SH
  carrier="$payload/core-rules/githooks/pre-push"
  cat > "$carrier" <<'SH'
#!/bin/bash
set -u
printf 'GATE_PATH=%s\n' "$PATH"
printf 'GATE_TOOL_PATH=%s\n' "$(command -v trellis-fixture-path-tool)"
printf 'GATE_TOOL=%s\n' "$(trellis-fixture-path-tool)"
SH
  chmod 700 "$seed" "$carrier"
  seed_oid="$(git hash-object "$seed")" || return 1
  carrier_oid="$(git hash-object "$carrier")" || return 1
  jq -n --arg seed_oid "$seed_oid" --arg carrier_oid "$carrier_oid" '
    {
      schema_version:1,
      version:"1.2.3",
      tag:"v1.2.3",
      commit:"0000000000000000000000000000000000000000",
      remote:"fixture",
      tree:[
        {path:"core-rules/githooks/pre-push",mode:"100755",oid:$carrier_oid},
        {path:"scripts/seed-inheritance-symlinks.sh",mode:"100755",oid:$seed_oid}
      ]
    }' > "$release/release.json"
  chmod 600 "$release/release.json"
  manifest="$(_attachment_hooks_release_manifest_sha256 "$payload")" || return 1

  printf '%s\n' "$(_attachment_hooks_post_checkout_dispatcher_body "$payload" "$manifest")" \
    > "$PATH_POST_DISPATCHER"
  printf '%s\n' \
    "$(_attachment_hooks_pre_push_dispatcher_body \
      "$payload" "core-rules/githooks/pre-push" "$manifest")" \
    > "$PATH_PRE_DISPATCHER"
  printf '\n' > "$managed/previous-hooks-path"
  printf '%s\n' "$payload" > "$managed/release-payload"
  printf '%s\n' 'core-rules/githooks/pre-push' > "$managed/pre-push-source"
  chmod 700 "$PATH_POST_DISPATCHER" "$PATH_PRE_DISPATCHER"
  chmod 600 \
    "$managed/previous-hooks-path" \
    "$managed/release-payload" \
    "$managed/pre-push-source"

  jq -n \
    --arg checkout "$checkout" --arg worktree "$worktree" \
    --arg root "$PATH_STAGE_PROJECT" --arg payload "$payload" \
    --arg managed "$managed" \
    --arg recorded_a "$PATH_RECORDED_A" --arg recorded_b "$PATH_RECORDED_B" '
    {
      schema_version:1,
      status:"committed",
      fleet:"personal",
      project_id:"path-fixture",
      checkout_id:$checkout,
      worktree_id:$worktree,
      attachment_id:"00000000-0000-0000-0000-000000000001",
      project_root:$root,
      worktree_root:$root,
      release:"1.2.3",
      toolchain_path:[$recorded_a,$recorded_b],
      artifacts:[{path:".trellis/runtime",kind:"symlink",target:$payload}],
      git_hooks:{
        enabled:true,
        managed_hooks_path:$managed,
        previous_hooks_path:null,
        pre_push_source:"core-rules/githooks/pre-push"
      }
    }' > "$owner"
  chmod 600 "$owner"
  _attachment_owner_json_valid "$owner" || return 1
  jq -e \
    --arg recorded_a "$PATH_RECORDED_A" --arg recorded_b "$PATH_RECORDED_B" \
    '.toolchain_path == [$recorded_a,$recorded_b]' "$owner" >/dev/null || return 1

  chmod 400 "$release/release.json"
  find "$payload" -type f -exec chmod 500 {} \;
  find "$payload" -type d -exec chmod 500 {} \;
  chmod 500 "$release"
  printf '%s\n' 'refs/heads/main deadbeef refs/heads/main abcdef' > "$PATH_REFS"
}

teardown() {
  chmod -R u+w "$ROOT" 2>/dev/null || true
  rm -rf "$ROOT"
}

@test "generated pre-push delegates caller environment and keeps managed carrier hermetic" {
  prepare_actual_pre_push_fixture
  run env \
    "PATH=$FIXTURE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "HOME=$FIXTURE_HOME_DIR" \
    "TMPDIR=$FIXTURE_TMP_DIR" \
    TRELLIS_FIXTURE_SENTINEL=caller-secret \
    /bin/bash -c 'cd "$1" && "$2" origin fixture < "$3"' \
    _ "$FIXTURE_PROJECT" "$FIXTURE_DISPATCHER" "$FIXTURE_REFS"
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output"
  fi
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "PRIOR_CALLER_ENV=ok" >/dev/null
  echo "$output" | grep -F "MANAGED_SENTINEL=absent" >/dev/null
}


@test "generated dispatcher exec env -i forwards TRELLIS_ALLOW_MAIN_PUSH and SECURITY_GATE_SKIP" {
  printf '%s\n' "$DISPATCHER_TEXT" | grep -F "TRELLIS_ALLOW_MAIN_PUSH=\${TRELLIS_ALLOW_MAIN_PUSH-}" >/dev/null
  printf '%s\n' "$DISPATCHER_TEXT" | grep -F "SECURITY_GATE_SKIP=\${SECURITY_GATE_SKIP-}" >/dev/null
  printf '%s\n' "$PRE_PUSH_TEXT" | grep -F "TRELLIS_ALLOW_MAIN_PUSH=\${TRELLIS_ALLOW_MAIN_PUSH-}" >/dev/null
  printf '%s\n' "$PRE_PUSH_TEXT" | grep -F "SECURITY_GATE_SKIP=\${SECURITY_GATE_SKIP-}" >/dev/null
  header="$(printf '%s\n' "$DISPATCHER_TEXT" | sed -n '1,/\/bin\/bash.*-c/p')"
  echo "$header" | grep -F "TRELLIS_ALLOW_MAIN_PUSH" >/dev/null
  echo "$header" | grep -F "SECURITY_GATE_SKIP" >/dev/null
}

@test "generated body exports allowlist but does not mark it readonly" {
  printf '%s\n' "$DISPATCHER_TEXT" | grep -F "export TRELLIS_ALLOW_MAIN_PUSH SECURITY_GATE_SKIP" >/dev/null
  readonly_line="$(printf '%s\n' "$DISPATCHER_TEXT" | grep '^readonly ' | head -n1)"
  echo "$readonly_line" | grep -v "TRELLIS_ALLOW_MAIN_PUSH" >/dev/null
  echo "$readonly_line" | grep -v "SECURITY_GATE_SKIP" >/dev/null
  echo "$readonly_line" | grep -F "PATH" >/dev/null
  echo "$readonly_line" | grep -F "HOME" >/dev/null
  echo "$readonly_line" | grep -F "GIT_CONFIG_NOSYSTEM" >/dev/null
}

@test "trellis_run_control_payload definition forwards allowlist" {
  printf '%s\n' "$DISPATCHER_TEXT" | grep -F 'TRELLIS_ALLOW_MAIN_PUSH="${TRELLIS_ALLOW_MAIN_PUSH-}"' >/dev/null
  printf '%s\n' "$DISPATCHER_TEXT" | grep -F 'SECURITY_GATE_SKIP="${SECURITY_GATE_SKIP-}"' >/dev/null
  printf '%s\n' "$DISPATCHER_TEXT" | grep -F 'TRELLIS_HOME="$managed_home"' >/dev/null
}

@test "trellis_run_prior_hook does not forward allowlist" {
  prior_block="$(printf '%s\n' "$DISPATCHER_TEXT" | sed -n '/trellis_run_prior_hook()/,/^}/p')"
  echo "$prior_block" | grep -F "env -i" >/dev/null
  if printf '%s\n' "$prior_block" | grep -q "TRELLIS_ALLOW_MAIN_PUSH"; then
    echo "prior hook unexpectedly forwards TRELLIS_ALLOW_MAIN_PUSH" >&2
    printf '%s\n' "$prior_block" >&2
    false
  fi
  if printf '%s\n' "$prior_block" | grep -q "SECURITY_GATE_SKIP"; then
    echo "prior hook unexpectedly forwards SECURITY_GATE_SKIP" >&2
    printf '%s\n' "$prior_block" >&2
    false
  fi
}

@test "TRELLIS_ALLOW_MAIN_PUSH=1 is visible inside trellis_run_control_payload child" {
  prepare_managed_home
  cat > "$ROOT/payload.sh" <<'SH'
#!/bin/bash
printf 'ALLOW=%s\n' "${TRELLIS_ALLOW_MAIN_PUSH-__UNSET__}"
printf 'SKIP=%s\n' "${SECURITY_GATE_SKIP-__UNSET__}"
printf 'HOME=%s\n' "$HOME"
SH
  chmod 755 "$ROOT/payload.sh"
  export TRELLIS_ALLOW_MAIN_PUSH=1
  export SECURITY_GATE_SKIP=1
  run trellis_run_control_payload "$ROOT/payload.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "ALLOW=1" >/dev/null
  echo "$output" | grep -F "SKIP=1" >/dev/null
  echo "$output" | grep -F "HOME=/dev/null" >/dev/null
}

@test "unset allowlist does not inherit spurious value" {
  prepare_managed_home
  cat > "$ROOT/payload.sh" <<'SH'
#!/bin/bash
printf 'ALLOW=%s\n' "${TRELLIS_ALLOW_MAIN_PUSH-__UNSET__}"
printf 'SKIP=%s\n' "${SECURITY_GATE_SKIP-__UNSET__}"
SH
  chmod 755 "$ROOT/payload.sh"
  unset TRELLIS_ALLOW_MAIN_PUSH
  unset SECURITY_GATE_SKIP
  run trellis_run_control_payload "$ROOT/payload.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "ALLOW=" >/dev/null
  if printf '%s\n' "$output" | grep -q "ALLOW=1"; then false; fi
  if printf '%s\n' "$output" | grep -q "SKIP=1"; then false; fi
  echo "$output" | grep -E "ALLOW=($|__UNSET__)" >/dev/null
  echo "$output" | grep -E "SKIP=($|__UNSET__)" >/dev/null
}

@test "hostile BASH_ENV and CONTEXT_POISON are still stripped" {
  prepare_managed_home
  cat > "$ROOT/payload.sh" <<'SH'
#!/bin/bash
printf 'BASH_ENV=%s\n' "${BASH_ENV-__UNSET__}"
printf 'CONTEXT_POISON=%s\n' "${CONTEXT_POISON-__UNSET__}"
SH
  chmod 755 "$ROOT/payload.sh"
  export BASH_ENV=/tmp/hostile
  export CONTEXT_POISON=evil
  export TRELLIS_ALLOW_MAIN_PUSH=1
  run trellis_run_control_payload "$ROOT/payload.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "BASH_ENV=__UNSET__" >/dev/null
  echo "$output" | grep -F "CONTEXT_POISON=__UNSET__" >/dev/null
}

@test "HOME inside child remains /dev/null" {
  cat > "$ROOT/payload.sh" <<'SH'
#!/bin/bash
printf 'HOME=%s\n' "$HOME"
SH
  chmod 755 "$ROOT/payload.sh"
  # Parent HOME is hostile, but child must still be /dev/null. Use a fresh bash so we can set HOME
  # before the hermetic eval makes it readonly.
  run bash -c '
    REPO_ROOT="'"$REPO_ROOT"'"
    ROOT="'"$ROOT"'"
    PAYLOAD="$ROOT/payload"
    MANIFEST="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    source "$REPO_ROOT/scripts/lib/attachment.sh"
    DISPATCHER_TEXT="$(_attachment_hooks_dispatcher_common_body "$PAYLOAD" "core-rules/githooks/pre-push" "$MANIFEST")"
    BODY="$(printf "%s\n" "$DISPATCHER_TEXT" | /usr/bin/awk "seen{print} /^# trellis-managed-dispatcher-body$/ {seen=1}")"
    fake_managed_dir="$ROOT/managed_home/state/git-hooks/test-id"
    fake_dispatcher="$fake_managed_dir/pre-push"
    mkdir -p "$fake_managed_dir"
    chmod 700 "$ROOT/managed_home" "$ROOT/managed_home/state"
    : > "$fake_dispatcher"
    export TRELLIS_MANAGED_DISPATCHER="$fake_dispatcher"
    export HOME=/tmp/hostile
    export TRELLIS_ALLOW_MAIN_PUSH=1
    eval "$BODY"
    set +u
    managed_home="$ROOT/managed_home"
    trellis_run_control_payload "$ROOT/payload.sh"
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "HOME=/dev/null" >/dev/null
}

@test "outer dispatcher env -i forwards allowlist to inner body (integration)" {
  cat > "$ROOT/inner.sh" <<'SH'
#!/bin/bash
printf 'INNER_ALLOW=%s\n' "${TRELLIS_ALLOW_MAIN_PUSH-__UNSET__}"
printf 'INNER_SKIP=%s\n' "${SECURITY_GATE_SKIP-__UNSET__}"
printf 'INNER_HOME=%s\n' "$HOME"
SH
  chmod 755 "$ROOT/inner.sh"
  cat > "$ROOT/dispatcher_test.sh" <<EOS
#!/bin/sh
exec /usr/bin/env -i \\
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \\
  HOME=/dev/null \\
  TMPDIR=/tmp \\
  TMP=/tmp \\
  TEMP=/tmp \\
  LC_ALL=C \\
  GIT_CONFIG_NOSYSTEM=1 \\
  GIT_CONFIG_GLOBAL=/dev/null \\
  TRELLIS_ALLOW_MAIN_PUSH=\${TRELLIS_ALLOW_MAIN_PUSH-} \\
  SECURITY_GATE_SKIP=\${SECURITY_GATE_SKIP-} \\
  /bin/bash --noprofile --norc -c 'printf "OUTER_ALLOW=%s\\n" "\${TRELLIS_ALLOW_MAIN_PUSH-__UNSET__}"; printf "OUTER_SKIP=%s\\n" "\${SECURITY_GATE_SKIP-__UNSET__}"; printf "OUTER_HOME=%s\\n" "\$HOME"; exec "\$1" "\$2"' test-inner "$ROOT/inner.sh"
EOS
  chmod 755 "$ROOT/dispatcher_test.sh"
  run env TRELLIS_ALLOW_MAIN_PUSH=1 SECURITY_GATE_SKIP=1 HOME=/tmp/hostile BASH_ENV=/tmp/evil "$ROOT/dispatcher_test.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "OUTER_ALLOW=1" >/dev/null
  echo "$output" | grep -F "OUTER_SKIP=1" >/dev/null
  echo "$output" | grep -F "OUTER_HOME=/dev/null" >/dev/null
  echo "$output" | grep -F "INNER_ALLOW=1" >/dev/null
  echo "$output" | grep -F "INNER_SKIP=1" >/dev/null
  run env -u TRELLIS_ALLOW_MAIN_PUSH -u SECURITY_GATE_SKIP HOME=/tmp/hostile "$ROOT/dispatcher_test.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -E "OUTER_ALLOW=($|__UNSET__)" >/dev/null
  echo "$output" | grep -E "INNER_ALLOW=($|__UNSET__)" >/dev/null
}

@test "dispatcher keeps hermeticity for undocumented vars via outer env -i" {
  cat > "$ROOT/payload_check.sh" <<'SH'
#!/bin/bash
printf 'BASH_ENV=%s\n' "${BASH_ENV-__UNSET__}"
printf 'EVIL=%s\n' "${EVIL-__UNSET__}"
printf 'PATH=%s\n' "$PATH"
SH
  chmod 755 "$ROOT/payload_check.sh"
  cat > "$ROOT/dispatcher_hermetic.sh" <<EOS
#!/bin/sh
exec /usr/bin/env -i \\
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \\
  HOME=/dev/null \\
  TMPDIR=/tmp \\
  TMP=/tmp \\
  TEMP=/tmp \\
  LC_ALL=C \\
  GIT_CONFIG_NOSYSTEM=1 \\
  GIT_CONFIG_GLOBAL=/dev/null \\
  TRELLIS_ALLOW_MAIN_PUSH=\${TRELLIS_ALLOW_MAIN_PUSH-} \\
  SECURITY_GATE_SKIP=\${SECURITY_GATE_SKIP-} \\
  /bin/bash --noprofile --norc -c 'exec "\$1" "\$2"' hermetic "$ROOT/payload_check.sh"
EOS
  chmod 755 "$ROOT/dispatcher_hermetic.sh"
  run env BASH_ENV=/tmp/evil EVIL=1 TRELLIS_ALLOW_MAIN_PUSH=1 "$ROOT/dispatcher_hermetic.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "BASH_ENV=__UNSET__" >/dev/null
  echo "$output" | grep -F "EVIL=__UNSET__" >/dev/null
  echo "$output" | grep -F "PATH=/usr/bin:/bin:/usr/sbin:/sbin" >/dev/null
}

@test "control-plane stage stays hermetic when caller and recorded PATH contain a shim" {
  prepare_path_stage_fixture
  run env \
    "PATH=$PATH_CALLER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "HOME=$PATH_CALLER_HOME" \
    "TMPDIR=$PATH_CALLER_TMP" \
    /bin/bash -c 'cd "$1" && "$2" old new 1' \
    _ "$PATH_STAGE_PROJECT" "$PATH_POST_DISPATCHER"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ -f "$PATH_CONTROL_RESULT" ] || { echo 'control result did not land'; false; }
  grep -Fx 'CONTROL_PATH=/usr/bin:/bin:/usr/sbin:/sbin' "$PATH_CONTROL_RESULT" >/dev/null
  grep -Fx 'CONTROL_TOOL=absent' "$PATH_CONTROL_RESULT" >/dev/null
  if grep -F 'RECORDED_TOOL' "$PATH_CONTROL_RESULT" >/dev/null; then
    cat "$PATH_CONTROL_RESULT"
    false
  fi
  if grep -F 'CALLER_SHIM' "$PATH_CONTROL_RESULT" >/dev/null; then
    cat "$PATH_CONTROL_RESULT"
    false
  fi
}

@test "gate stage uses the attachment owner recorded toolchain PATH" {
  prepare_path_stage_fixture
  run env \
    "PATH=$PATH_CALLER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "HOME=$PATH_CALLER_HOME" \
    "TMPDIR=$PATH_CALLER_TMP" \
    /bin/bash -c 'cd "$1" && "$2" origin fixture < "$3"' \
    _ "$PATH_STAGE_PROJECT" "$PATH_PRE_DISPATCHER" "$PATH_REFS"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  printf '%s\n' "$output" | grep -Fx "GATE_PATH=$PATH_RECORDED_A:$PATH_RECORDED_B" >/dev/null
  printf '%s\n' "$output" | grep -Fx \
    "GATE_TOOL_PATH=$PATH_RECORDED_B/trellis-fixture-path-tool" >/dev/null
  printf '%s\n' "$output" | grep -Fx 'GATE_TOOL=RECORDED_TOOL' >/dev/null
  if printf '%s\n' "$output" | grep -F 'CALLER_SHIM' >/dev/null; then
    printf '%s\n' "$output"
    false
  fi
}

@test "moved recorded PATH entry names toolchain moved and re-attach instead of 127" {
  prepare_path_stage_fixture
  mv "$PATH_RECORDED_A" "$PATH_RECORDED_A.moved"
  [ ! -e "$PATH_RECORDED_A" ] || { echo 'recorded PATH mutation did not land'; false; }
  [ -x "$PATH_RECORDED_B/trellis-fixture-path-tool" ] ||
    { echo 'positive-control recorded tool disappeared'; false; }
  run env \
    "PATH=$PATH_CALLER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "HOME=$PATH_CALLER_HOME" \
    "TMPDIR=$PATH_CALLER_TMP" \
    /bin/bash -c 'cd "$1" && "$2" origin fixture < "$3"' \
    _ "$PATH_STAGE_PROJECT" "$PATH_PRE_DISPATCHER" "$PATH_REFS"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
  printf '%s\n' "$output" | grep -F \
    "toolchain moved, re-attach: $PATH_RECORDED_A" >/dev/null
  if printf '%s\n' "$output" | grep -F 'command not found' >/dev/null; then
    printf '%s\n' "$output"
    false
  fi
}

# --- private command scratch -------------------------------------------------
#
# The managed dispatcher allocates its own mode-0700 scratch under
# <managed_home>/state/scratch and points TMPDIR/TMP/TEMP at it, using the
# allocator extracted verbatim from scripts/trellis-launcher.sh at generation
# time. These cases pin the extraction parity, the allocation locations, the
# refusal paths and the exit precedence.

extract_shell_function() {
  /usr/bin/awk -v open="$2() {" '
    $0 == open { opens++; depth = 1 }
    depth { print }
    depth && $0 == "}" { depth = 0; closes++ }
    END { if (opens != 1 || closes != 1 || depth) exit 1 }
  ' "$1"
}

# A payload-shaped copy of the running generator and its sibling launcher, so
# the preloaded-bundle generation context can be exercised without attaching.
prepare_fake_payload() {
  local root="$ROOT/$1"
  FAKE_PAYLOAD="$root/payload"
  mkdir -p "$FAKE_PAYLOAD/scripts/lib"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$FAKE_PAYLOAD/scripts/trellis-launcher.sh"
  cp "$REPO_ROOT/scripts/lib/attachment.sh" "$FAKE_PAYLOAD/scripts/lib/attachment.sh"
}

generate_in_preloaded_context() {
  env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME=/dev/null \
    LC_ALL=C \
    TRELLIS_LIBS_PRELOADED=1 \
    "TRELLIS_VERIFIED_PAYLOAD=$FAKE_PAYLOAD" \
    /bin/bash --noprofile --norc -c '
      set -u
      . "$1" || exit 1
      "$2" "$3" core-rules/githooks/pre-push \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    ' preloaded-generation \
    "$FAKE_PAYLOAD/scripts/lib/attachment.sh" "$1" "$FAKE_PAYLOAD"
}

# A full pre-push/post-checkout fixture whose carrier, control payload and prior
# hook all report the environment they actually received.
prepare_scratch_fixture() {
  local carrier_body="${SCRATCH_CARRIER_BODY:-exit 0}" prior_exit="${SCRATCH_PRIOR_EXIT:-0}"
  local managed_home="$ROOT/scratch-managed-home"
  local release="$managed_home/releases/1.2.3"
  local payload="$release/payload"
  local prior_hooks="$ROOT/scratch-prior-hooks"
  local managed common checkout worktree owner carrier seed carrier_oid seed_oid manifest

  SCRATCH_MANAGED_HOME="$managed_home"
  SCRATCH_RELEASES="$managed_home/releases"
  SCRATCH_ROOT_DIR="$managed_home/state/scratch"
  SCRATCH_PROJECT="$ROOT/scratch-project"
  SCRATCH_REFS="$ROOT/scratch-refs"
  SCRATCH_CALLER_HOME="$ROOT/scratch-caller-home"
  SCRATCH_CALLER_TMP="$ROOT/scratch-caller-tmp"
  SCRATCH_WITNESS="$ROOT/scratch-witness"

  mkdir -p "$payload/core-rules/githooks" "$payload/scripts" "$prior_hooks" \
    "$SCRATCH_PROJECT" "$SCRATCH_CALLER_HOME" "$SCRATCH_CALLER_TMP" "$SCRATCH_WITNESS"
  git init -q "$SCRATCH_PROJECT"
  common="$(git -C "$SCRATCH_PROJECT" rev-parse --git-common-dir)" || return 1
  case "$common" in /*) ;; *) common="$SCRATCH_PROJECT/$common" ;; esac
  common="$(CDPATH= cd "$common" && pwd -P)" || return 1
  checkout="$(_attachment_hash_text "$common")" || return 1
  worktree="$(_attachment_hash_text "$SCRATCH_PROJECT")" || return 1
  managed="$managed_home/state/git-hooks/$checkout"
  owner="$managed_home/state/attachments/$checkout/$worktree.json"
  SCRATCH_PRE_DISPATCHER="$managed/pre-push"
  SCRATCH_POST_DISPATCHER="$managed/post-checkout"
  mkdir -p "$managed" "$(dirname "$owner")"
  chmod 700 "$managed_home" "$managed_home/state"

  cat > "$prior_hooks/pre-push" <<PRIOR
#!/bin/bash
{
  printf 'PRIOR_TMPDIR=%s\n' "\${TMPDIR-__UNSET__}"
  printf 'PRIOR_TMP=%s\n' "\${TMP-__UNSET__}"
  printf 'PRIOR_TEMP=%s\n' "\${TEMP-__UNSET__}"
  printf 'PRIOR_HOME=%s\n' "\${HOME-__UNSET__}"
  printf 'PRIOR_PATH=%s\n' "\${PATH-__UNSET__}"
} > "$SCRATCH_WITNESS/prior.txt"
exit $prior_exit
PRIOR
  chmod 700 "$prior_hooks/pre-push"

  carrier="$payload/core-rules/githooks/pre-push"
  cat > "$carrier" <<CARRIER
#!/bin/bash
set -u
{
  printf 'CARRIER_TMPDIR=%s\n' "\${TMPDIR-__UNSET__}"
  printf 'CARRIER_TMP=%s\n' "\${TMP-__UNSET__}"
  printf 'CARRIER_TEMP=%s\n' "\${TEMP-__UNSET__}"
  allocation="\$(mktemp "\$TMPDIR/carrier.XXXXXX")" && printf 'CARRIER_ALLOCATION=%s\n' "\$allocation"
} > "$SCRATCH_WITNESS/carrier.txt"
$carrier_body
CARRIER
  seed="$payload/scripts/seed-inheritance-symlinks.sh"
  cat > "$seed" <<CONTROL
#!/bin/bash
set -u
{
  printf 'CONTROL_TMPDIR=%s\n' "\${TMPDIR-__UNSET__}"
  allocation="\$(mktemp "\$TMPDIR/control.XXXXXX")" && printf 'CONTROL_ALLOCATION=%s\n' "\$allocation"
} > "$SCRATCH_WITNESS/control.txt"
exit 0
CONTROL
  chmod 700 "$carrier" "$seed"
  carrier_oid="$(git hash-object "$carrier")" || return 1
  seed_oid="$(git hash-object "$seed")" || return 1
  jq -n --arg carrier_oid "$carrier_oid" --arg seed_oid "$seed_oid" '
    {
      schema_version:1, version:"1.2.3", tag:"v1.2.3",
      commit:"0000000000000000000000000000000000000000", remote:"fixture",
      tree:[
        {path:"core-rules/githooks/pre-push",mode:"100755",oid:$carrier_oid},
        {path:"scripts/seed-inheritance-symlinks.sh",mode:"100755",oid:$seed_oid}
      ]
    }' > "$release/release.json"
  chmod 600 "$release/release.json"
  manifest="$(_attachment_hooks_release_manifest_sha256 "$payload")" || return 1

  printf '%s\n' "$(_attachment_hooks_pre_push_dispatcher_body \
    "$payload" "core-rules/githooks/pre-push" "$manifest")" > "$SCRATCH_PRE_DISPATCHER"
  printf '%s\n' "$(_attachment_hooks_post_checkout_dispatcher_body \
    "$payload" "$manifest")" > "$SCRATCH_POST_DISPATCHER"
  printf '%s\n' "$prior_hooks" > "$managed/previous-hooks-path"
  printf '%s\n' "$payload" > "$managed/release-payload"
  printf '%s\n' 'core-rules/githooks/pre-push' > "$managed/pre-push-source"
  chmod 700 "$SCRATCH_PRE_DISPATCHER" "$SCRATCH_POST_DISPATCHER"
  chmod 600 "$managed/previous-hooks-path" "$managed/release-payload" "$managed/pre-push-source"

  jq -n \
    --arg checkout "$checkout" --arg worktree "$worktree" \
    --arg root "$SCRATCH_PROJECT" --arg payload "$payload" \
    --arg managed "$managed" --arg prior "$prior_hooks" '
    {
      schema_version:1, status:"committed", fleet:"personal",
      project_id:"scratch-fixture", checkout_id:$checkout, worktree_id:$worktree,
      attachment_id:"00000000-0000-0000-0000-000000000003",
      project_root:$root, worktree_root:$root, release:"1.2.3",
      toolchain_path:["/usr/bin","/bin"],
      artifacts:[{path:".trellis/runtime",kind:"symlink",target:$payload}],
      git_hooks:{
        enabled:true, managed_hooks_path:$managed, previous_hooks_path:$prior,
        pre_push_source:"core-rules/githooks/pre-push"
      }
    }' > "$owner"
  chmod 600 "$owner"
  _attachment_owner_json_valid "$owner" || return 1
  chmod 400 "$release/release.json"
  find "$payload" -type f -exec chmod 500 {} \;
  find "$payload" -type d -exec chmod 500 {} \;
  chmod 500 "$release"
  printf '%s\n' 'refs/heads/main deadbeef refs/heads/main abcdef' > "$SCRATCH_REFS"
}

run_scratch_pre_push() {
  run env \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    "HOME=$SCRATCH_CALLER_HOME" \
    "TMPDIR=${1:-$SCRATCH_CALLER_TMP}" \
    "TMP=${1:-$SCRATCH_CALLER_TMP}" \
    "TEMP=${1:-$SCRATCH_CALLER_TMP}" \
    /bin/bash -c 'cd "$1" && "$2" origin fixture < "$3"' \
    _ "$SCRATCH_PROJECT" "$SCRATCH_PRE_DISPATCHER" "$SCRATCH_REFS"
}

@test "generated dispatcher embeds the launcher command scratch emitters byte-exactly" {
  printf '%s\n' "$DISPATCHER_TEXT" > "$ROOT/body.txt"
  for name in launcher_command_scratch_create_program launcher_command_scratch_remove_program; do
    extract_shell_function "$REPO_ROOT/scripts/trellis-launcher.sh" "$name" > "$ROOT/$name.launcher"
    extract_shell_function "$ROOT/body.txt" "$name" > "$ROOT/$name.body"
    [ -s "$ROOT/$name.launcher" ] || { echo "empty launcher extraction: $name"; false; }
    [ -s "$ROOT/$name.body" ] || { echo "empty dispatcher extraction: $name"; false; }
    diff -u "$ROOT/$name.launcher" "$ROOT/$name.body" || false
  done
  # The dispatcher must call them, not merely carry them.
  printf '%s\n' "$DISPATCHER_TEXT" | grep -F '$(launcher_command_scratch_create_program)' >/dev/null
  printf '%s\n' "$DISPATCHER_TEXT" | grep -F '$(launcher_command_scratch_remove_program)' >/dev/null
}

@test "generated bootstrap leaves temp variables absent until private scratch exists" {
  clean_bootstrap="$(printf '%s\n' "$DISPATCHER_TEXT" | sed -n '1,/^# trellis-command-scratch-begin$/p')"
  printf '%s\n' "$clean_bootstrap" | grep -Fx '# trellis-command-scratch-begin' >/dev/null
  if printf '%s\n' "$clean_bootstrap" | grep -E '^[[:space:]]*(TMPDIR|TMP|TEMP)=' >/dev/null; then
    echo 'generated clean bootstrap assigned a temp variable before private scratch allocation'
    printf '%s\n' "$clean_bootstrap"
    false
  fi
}

@test "generated verifier allocates only through readonly private TMPDIR" {
  readonly_count="$(printf '%s\n' "$BODY" | grep -Fxc 'readonly TMPDIR TMP TEMP' || true)"
  verifier_count="$(printf '%s\n' "$BODY" | grep -Fxc '  tmpdir="$(mktemp -d "$TMPDIR/verify.$version.XXXXXX")" || return 1' || true)"
  [ "$readonly_count" -eq 1 ] || { echo "readonly TMPDIR declaration count=$readonly_count"; false; }
  [ "$verifier_count" -eq 1 ] || { echo "private verifier template count=$verifier_count"; false; }
}

@test "generated pre-push refs allocate only through readonly private TMPDIR" {
  readonly_count="$(printf '%s\n' "$PRE_PUSH_TEXT" | grep -Fxc 'readonly TMPDIR TMP TEMP' || true)"
  refs_count="$(printf '%s\n' "$PRE_PUSH_TEXT" | grep -Fxc 'refs_file="$(mktemp "$TMPDIR/trellis-pre-push.XXXXXX")" || exit 1' || true)"
  [ "$readonly_count" -eq 1 ] || { echo "readonly TMPDIR declaration count=$readonly_count"; false; }
  [ "$refs_count" -eq 1 ] || { echo "private refs template count=$refs_count"; false; }
}

@test "preloaded generation context embeds the same emitters as ordinary sourcing" {
  prepare_fake_payload preloaded-ok
  run generate_in_preloaded_context _attachment_hooks_dispatcher_common_body
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  printf '%s\n' "$output" > "$ROOT/preloaded-body.txt"
  for name in launcher_command_scratch_create_program launcher_command_scratch_remove_program; do
    extract_shell_function "$REPO_ROOT/scripts/trellis-launcher.sh" "$name" > "$ROOT/$name.launcher"
    extract_shell_function "$ROOT/preloaded-body.txt" "$name" > "$ROOT/$name.preloaded"
    [ -s "$ROOT/$name.preloaded" ] || { echo "empty preloaded extraction: $name"; false; }
    diff -u "$ROOT/$name.launcher" "$ROOT/$name.preloaded" || false
  done
}

@test "a launcher missing an emitter refuses generation in both wrapper functions" {
  prepare_fake_payload preloaded-broken
  chmod u+w "$FAKE_PAYLOAD/scripts/trellis-launcher.sh"
  python3 - "$FAKE_PAYLOAD/scripts/trellis-launcher.sh" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
start = text.index("launcher_command_scratch_remove_program() {")
end = text.index("\n}\n", start) + len("\n}\n")
open(path, "w").write(text[:start] + text[end:])
PY
  ! grep -q '^launcher_command_scratch_remove_program() {$' "$FAKE_PAYLOAD/scripts/trellis-launcher.sh"
  grep -q '^launcher_command_scratch_create_program() {$' "$FAKE_PAYLOAD/scripts/trellis-launcher.sh"
  for entry in _attachment_hooks_dispatcher_common_body \
    _attachment_hooks_pre_push_dispatcher_body_in_process \
    _attachment_hooks_post_checkout_dispatcher_body_in_process; do
    run generate_in_preloaded_context "$entry"
    [ "$status" -ne 0 ] || { echo "generation unexpectedly succeeded: $entry"; printf '%s\n' "$output"; false; }
    [ -z "$output" ] || { echo "refusal still emitted a dispatcher body: $entry"; printf '%s\n' "$output"; false; }
  done
}

@test "managed execution ignores a hostile ambient TMPDIR and allocates under the private scratch" {
  SCRATCH_CARRIER_BODY='exit 0' prepare_scratch_fixture
  run_scratch_pre_push /nonexistent/hostile-tmpdir
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }

  carrier_tmpdir="$(sed -n 's/^CARRIER_TMPDIR=//p' "$SCRATCH_WITNESS/carrier.txt")"
  carrier_alloc="$(sed -n 's/^CARRIER_ALLOCATION=//p' "$SCRATCH_WITNESS/carrier.txt")"
  [ -n "$carrier_tmpdir" ] || { cat "$SCRATCH_WITNESS/carrier.txt"; false; }
  case "$carrier_tmpdir" in
    "$SCRATCH_ROOT_DIR"/.cmd.*) ;;
    *) echo "carrier TMPDIR outside the private scratch: $carrier_tmpdir"; false ;;
  esac
  grep -Fx "CARRIER_TMP=$carrier_tmpdir" "$SCRATCH_WITNESS/carrier.txt" >/dev/null
  grep -Fx "CARRIER_TEMP=$carrier_tmpdir" "$SCRATCH_WITNESS/carrier.txt" >/dev/null
  case "$carrier_alloc" in
    "$carrier_tmpdir"/carrier.*) ;;
    *) echo "carrier allocation outside the private scratch: $carrier_alloc"; false ;;
  esac

  # The prior hook keeps its original ambient environment, hostile TMPDIR included.
  grep -Fx "PRIOR_TMPDIR=/nonexistent/hostile-tmpdir" "$SCRATCH_WITNESS/prior.txt" >/dev/null
  grep -Fx "PRIOR_TMP=/nonexistent/hostile-tmpdir" "$SCRATCH_WITNESS/prior.txt" >/dev/null
  grep -Fx "PRIOR_HOME=$SCRATCH_CALLER_HOME" "$SCRATCH_WITNESS/prior.txt" >/dev/null

  # Nothing was staged beside the sealed release store, and the scratch is gone.
  found="$(find "$SCRATCH_RELEASES" -maxdepth 1 -name '.tmp.*' -print)"
  [ -z "$found" ] || { echo "release-adjacent verifier scratch survived: $found"; false; }
  [ -d "$SCRATCH_ROOT_DIR" ] || { echo "private scratch root was not created"; false; }
  leftovers="$(find "$SCRATCH_ROOT_DIR" -mindepth 1 -print)"
  [ -z "$leftovers" ] || { echo "command scratch leaked: $leftovers"; false; }
  [ ! -e "$carrier_alloc" ] || { echo "carrier allocation survived cleanup"; false; }
}

@test "control-plane stage receives the private scratch as TMPDIR" {
  SCRATCH_CARRIER_BODY='exit 0' prepare_scratch_fixture
  run env \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    "HOME=$SCRATCH_CALLER_HOME" \
    "TMPDIR=/nonexistent/hostile-tmpdir" \
    /bin/bash -c 'cd "$1" && "$2" old new 1' \
    _ "$SCRATCH_PROJECT" "$SCRATCH_POST_DISPATCHER"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  control_tmpdir="$(sed -n 's/^CONTROL_TMPDIR=//p' "$SCRATCH_WITNESS/control.txt")"
  case "$control_tmpdir" in
    "$SCRATCH_ROOT_DIR"/.cmd.*) ;;
    *) echo "control TMPDIR outside the private scratch: $control_tmpdir"; cat "$SCRATCH_WITNESS/control.txt"; false ;;
  esac
  leftovers="$(find "$SCRATCH_ROOT_DIR" -mindepth 1 -print)"
  [ -z "$leftovers" ] || { echo "command scratch leaked: $leftovers"; false; }
}

@test "prior hook failure still wins over a green carrier and the scratch is cleaned" {
  SCRATCH_PRIOR_EXIT=3 SCRATCH_CARRIER_BODY='exit 0' prepare_scratch_fixture
  run_scratch_pre_push
  [ "$status" -eq 3 ] || { echo "status=$status"; printf '%s\n' "$output"; false; }
  [ -f "$SCRATCH_WITNESS/carrier.txt" ] || { echo "carrier did not run"; false; }
  leftovers="$(find "$SCRATCH_ROOT_DIR" -mindepth 1 -print)"
  [ -z "$leftovers" ] || { echo "command scratch leaked: $leftovers"; false; }
}

@test "carrier failure propagates and the scratch is cleaned" {
  SCRATCH_CARRIER_BODY='exit 9' prepare_scratch_fixture
  run_scratch_pre_push
  [ "$status" -eq 9 ] || { echo "status=$status"; printf '%s\n' "$output"; false; }
  leftovers="$(find "$SCRATCH_ROOT_DIR" -mindepth 1 -print)"
  [ -z "$leftovers" ] || { echo "command scratch leaked: $leftovers"; false; }
}

@test "SIGTERM cleans the scratch and exits 143" {
  SCRATCH_CARRIER_BODY='kill -TERM "$PPID"
exit 0' prepare_scratch_fixture
  run_scratch_pre_push
  [ "$status" -eq 143 ] || { echo "status=$status"; printf '%s\n' "$output"; false; }
  leftovers="$(find "$SCRATCH_ROOT_DIR" -mindepth 1 -print)"
  [ -z "$leftovers" ] || { echo "command scratch leaked: $leftovers"; false; }
}

@test "a replaced scratch refuses cleanup, names the retained path and keeps the neighbour" {
  SCRATCH_CARRIER_BODY='scratch_root="$(dirname "$TMPDIR")"
mkdir -p "$scratch_root/neighbour-witness"
rm -rf "$TMPDIR"
mkdir "$TMPDIR"
: > "$TMPDIR/replacement-witness"
exit 7' prepare_scratch_fixture
  run_scratch_pre_push
  [ "$status" -eq 7 ] || { echo "status=$status"; printf '%s\n' "$output"; false; }
  carrier_tmpdir="$(sed -n 's/^CARRIER_TMPDIR=//p' "$SCRATCH_WITNESS/carrier.txt")"
  printf '%s\n' "$output" | grep -F "could not clean command scratch directory: $carrier_tmpdir" >/dev/null ||
    { printf '%s\n' "$output"; false; }
  [ -f "$carrier_tmpdir/replacement-witness" ] || { echo "replacement was destroyed"; false; }
  [ -d "$SCRATCH_ROOT_DIR/neighbour-witness" ] || { echo "neighbour was destroyed"; false; }
}

@test "a replaced scratch makes a green carrier fail while retaining replacement and neighbour" {
  SCRATCH_CARRIER_BODY='scratch_root="$(dirname "$TMPDIR")"
mkdir -p "$scratch_root/neighbour-witness"
rm -rf "$TMPDIR"
mkdir "$TMPDIR"
: > "$TMPDIR/replacement-witness"
exit 0' prepare_scratch_fixture
  run_scratch_pre_push
  [ "$status" -ne 0 ] || { echo "status=$status"; printf '%s\n' "$output"; false; }
  carrier_tmpdir="$(sed -n 's/^CARRIER_TMPDIR=//p' "$SCRATCH_WITNESS/carrier.txt")"
  printf '%s\n' "$output" | grep -F "could not clean command scratch directory: $carrier_tmpdir" >/dev/null ||
    { printf '%s\n' "$output"; false; }
  [ -f "$carrier_tmpdir/replacement-witness" ] || { echo "replacement was destroyed"; false; }
  [ -d "$SCRATCH_ROOT_DIR/neighbour-witness" ] || { echo "neighbour was destroyed"; false; }
}

@test "an unsafe managed home mode refuses before the managed payload runs" {
  SCRATCH_CARRIER_BODY='exit 0' prepare_scratch_fixture
  chmod 755 "$SCRATCH_MANAGED_HOME"
  run_scratch_pre_push
  [ "$status" -ne 0 ]
  [ ! -f "$SCRATCH_WITNESS/carrier.txt" ] || { echo "carrier ran despite an unsafe managed home"; false; }
  printf '%s\n' "$output" | grep -F "private command scratch directory" >/dev/null ||
    { printf '%s\n' "$output"; false; }
  [ ! -d "$SCRATCH_ROOT_DIR" ] || { echo "scratch root created under an unsafe home"; false; }
}

@test "a symlinked scratch root refuses before the managed payload runs" {
  SCRATCH_CARRIER_BODY='exit 0' prepare_scratch_fixture
  mkdir -p "$ROOT/scratch-symlink-target"
  ln -s "$ROOT/scratch-symlink-target" "$SCRATCH_ROOT_DIR"
  run_scratch_pre_push
  [ "$status" -ne 0 ]
  [ ! -f "$SCRATCH_WITNESS/carrier.txt" ] || { echo "carrier ran despite a symlinked scratch root"; false; }
  leftovers="$(find "$ROOT/scratch-symlink-target" -mindepth 1 -print)"
  [ -z "$leftovers" ] || { echo "allocation followed the symlink: $leftovers"; false; }
}

@test "an older foreign generator still emits its own scratch-less body" {
  local root="$ROOT/foreign-old"
  local payload="$root/payload"
  mkdir -p "$payload/scripts/lib"
  cat > "$payload/scripts/lib/attachment.sh" <<'OLD'
#!/usr/bin/env bash
_attachment_hooks_pre_push_dispatcher_body() {
  printf 'OLD_FOREIGN_BODY payload=%s source=%s manifest=%s\n' "${1:-}" "${2:-}" "${3:-}"
}
_attachment_hooks_post_checkout_dispatcher_body() {
  printf 'OLD_FOREIGN_BODY payload=%s manifest=%s\n' "${1:-}" "${2:-}"
}
OLD
  run _attachment_hooks_pre_push_dispatcher_body "$payload" core-rules/githooks/pre-push "$MANIFEST"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  printf '%s\n' "$output" | grep -F "OLD_FOREIGN_BODY payload=$payload" >/dev/null
  if printf '%s\n' "$output" | grep -q "launcher_command_scratch_create_program"; then
    echo "the new generator overwrote an older release's recorded policy"
    printf '%s\n' "$output"
    false
  fi
}

@test "a provisional payload without a bundled generator uses the running implementation" {
  local payload="$ROOT/provisional/payload"
  mkdir -p "$payload"
  [ ! -e "$payload/scripts/lib/attachment.sh" ]
  run _attachment_hooks_pre_push_dispatcher_body "$payload" core-rules/githooks/pre-push "$MANIFEST"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  printf '%s\n' "$output" | grep -F "launcher_command_scratch_create_program() {" >/dev/null
  printf '%s\n' "$output" | grep -F "launcher_command_scratch_remove_program() {" >/dev/null
}
