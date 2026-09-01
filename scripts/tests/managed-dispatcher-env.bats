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
