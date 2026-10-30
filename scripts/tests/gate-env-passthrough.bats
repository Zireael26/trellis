#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/gate-env-passthrough.XXXXXX")"
  PROJECT="$SANDBOX/project"
  mkdir -p "$PROJECT" "$SANDBOX/scratch" "$SANDBOX/managed"
  # shellcheck source=scripts/lib/attachment.sh
  source "$REPO_ROOT/scripts/lib/attachment.sh"
  local body
  body="$(_attachment_hooks_dispatcher_common_body "$SANDBOX/payload" \
    "core-rules/githooks/pre-push" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")"
  printf '%s\n' "$body" > "$SANDBOX/dispatcher.sh"
  /bin/bash -p -n "$SANDBOX/dispatcher.sh"
}

teardown() {
  if [ -n "${SANDBOX:-}" ]; then
    (CDPATH='' cd "${SANDBOX%/*}" && rm -rf "${SANDBOX##*/}")
  fi
}

extract_shell_function() {
  /usr/bin/awk -v open="$2() {" '
    $0 == open { opens++; depth = 1 }
    depth { print }
    depth && $0 == "}" { depth = 0; closes++ }
    END { if (opens != 1 || closes != 1 || depth) exit 1 }
  ' "$1"
}

load_gate_env_functions() {
  extract_shell_function "$SANDBOX/dispatcher.sh" trellis_gate_env_name_safe > "$SANDBOX/gate-env-functions.sh"
  extract_shell_function "$SANDBOX/dispatcher.sh" trellis_collect_gate_env >> "$SANDBOX/gate-env-functions.sh"
  extract_shell_function "$SANDBOX/dispatcher.sh" trellis_run_gate_payload >> "$SANDBOX/gate-env-functions.sh"
  # shellcheck disable=SC1090
  source "$SANDBOX/gate-env-functions.sh"
}

seed_protected_manifest() {
  if [ ! -d "$PROJECT/.git" ]; then
    git -C "$PROJECT" init -q
    git -C "$PROJECT" config user.email "gate-env@trellis.test"
    git -C "$PROJECT" config user.name "gate env test"
  fi
  printf '%s\n' "$1" > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" commit -qm "protected project manifest"
  git -C "$PROJECT" branch -M main
  git -C "$PROJECT" update-ref refs/remotes/origin/main HEAD
  git -C "$PROJECT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

@test "gate payload receives only remote-default approved values, preserving literal and empty values" {
  seed_protected_manifest '{"schema_version":1,"project_id":"fixture","gate":{"env_passthrough":["APP_MODE","EMPTY_OK","ABSENT_OK","name","LOCAL_ONLY"]},"security_gate":{"semgrep_timeout":73}}'
  printf '%s\n' '{"schema_version":1,"project_id":"fixture","gate":{"env_passthrough":["HEAD_ONLY"]},"security_gate":{"semgrep_timeout":73}}' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" commit -qm "untrusted head manifest"
  load_gate_env_functions
  export APP_MODE='literal=$(touch injected);a=b'
  export EMPTY_OK=''
  export HEAD_ONLY='head value'
  export API_TOKEN='must not pass'
  export name='caller lowercase value'
  LOCAL_ONLY='not exported'
  export -n LOCAL_ONLY
  trellis_collect_gate_env "$PROJECT"
  [ "${#caller_gate_env[@]}" -eq 3 ]
  [ "${caller_gate_env[0]}" = "APP_MODE=$APP_MODE" ]
  [ "${caller_gate_env[1]}" = 'EMPTY_OK=' ]
  [ "${caller_gate_env[2]}" = 'name=caller lowercase value' ]
  [ ! -e "$PROJECT/injected" ]
  [ "$(local_registry_manifest_project_id "$PROJECT/.trellis.json")" = fixture ]

  # Run the exact generated bootstrap too: parsing the emitter alone cannot
  # catch quoting errors in its nested -c program or argument-count framing.
  /usr/bin/awk '{print} /^# trellis-managed-dispatcher-body$/ {exit}' \
    "$SANDBOX/dispatcher.sh" > "$SANDBOX/bootstrap.sh"
  cat >> "$SANDBOX/bootstrap.sh" <<'SH'
set -u
[ "${APP_MODE+x}" != x ] && [ "${name+x}" != x ] || exit 99
printf '%s\n' "${caller_gate_env[@]}" > "$1"
SH
  (cd "$PROJECT" && /bin/bash -p "$SANDBOX/bootstrap.sh" "$SANDBOX/bootstrap-env")
  [ "$(<"$SANDBOX/bootstrap-env")" = "APP_MODE=$APP_MODE
EMPTY_OK=
name=caller lowercase value" ]
  [ ! -e "$PROJECT/injected" ]

  export TMPDIR="$SANDBOX/scratch"
  managed_home="$SANDBOX/managed"
  gate_xdg_config="$SANDBOX/managed/config"
  gate_xdg_cache="$SANDBOX/managed/cache"
  COREPACK_HOME="$SANDBOX/managed/cache/node/corepack"
  caller_home="$SANDBOX/caller-home"
  caller_xdg_config_set=''
  caller_xdg_config=''
  cat > "$SANDBOX/gate-payload.sh" <<'SH'
#!/bin/bash
printf 'APP_MODE_SET=%s\nAPP_MODE=%s\nEMPTY_OK_SET=%s\nEMPTY_OK=%s\nABSENT_OK_SET=%s\nHEAD_ONLY_SET=%s\nAPI_TOKEN_SET=%s\n' \
  "${APP_MODE+x}" "${APP_MODE-}" "${EMPTY_OK+x}" "${EMPTY_OK-}" \
  "${ABSENT_OK+x}" "${HEAD_ONLY+x}" "${API_TOKEN+x}" > "$TMPDIR/payload-env"
SH
  trellis_gate_toolchain_path() { printf '/usr/bin:/bin:/usr/sbin:/sbin\n'; }
  trellis_sync_pnpm_global_virtual_store() { return 0; }
  trellis_run_gate_payload "$SANDBOX/gate-payload.sh"
  [ "$(<"$SANDBOX/scratch/payload-env")" = "APP_MODE_SET=x
APP_MODE=$APP_MODE
EMPTY_OK_SET=x
EMPTY_OK=
ABSENT_OK_SET=
HEAD_ONLY_SET=
API_TOKEN_SET=" ]
}

@test "manifest validator and dispatcher reject malformed, secret, and reserved names" {
  local bad_name manifest
  for bad_name in 'bad-name' 'API_TOKEN' 'api_secret' 'BUILD_KEY' 'DB_PASSWORD' 'PATH' 'home' \
    'TMPDIR' 'XDG_CONFIG_HOME' 'BASH_ENV' 'SHELLOPTS' 'IFS' 'CDPATH' 'GIT_DIR' \
    'TRELLIS_HOME' 'PROCESS_GATE_TEST_CMD' 'SECURITY_GATE_SKIP' 'NODE_OPTIONS' \
    'PYTHONPATH' 'LD_PRELOAD' 'caller_home' 'PWD' 'SHLVL' '_' 'LC_ALL' 'LANG' \
    'DOCKER_CONFIG' 'COREPACK_HOME' 'PERL5LIB' 'NODE_PATH' 'RANDOM'; do
    seed_protected_manifest "{\"schema_version\":1,\"project_id\":\"fixture\",\"gate\":{\"env_passthrough\":[\"$bad_name\"]}}"
    manifest="$PROJECT/.trellis.json"
    if local_registry_manifest_project_id "$manifest" >/dev/null 2>&1; then
      echo "manifest validator accepted $bad_name"
      false
    fi
    load_gate_env_functions
    export SAFE_VALUE='not authorized by this manifest'
    trellis_collect_gate_env "$PROJECT"
    [ "${#caller_gate_env[@]}" -eq 0 ] || { echo "dispatcher accepted $bad_name"; false; }
  done
}
