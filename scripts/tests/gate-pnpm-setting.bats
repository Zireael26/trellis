#!/usr/bin/env bats

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
bats_require_minimum_version 1.5.0

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/gate-pnpm-setting.XXXXXX")"
  SANDBOX="$(CDPATH= cd "$SANDBOX" && pwd -P)"
  mkdir -p "$SANDBOX/scratch"
  # shellcheck source=scripts/lib/attachment.sh
  source "$REPO_ROOT/scripts/lib/attachment.sh"
  local body
  body="$(_attachment_hooks_dispatcher_common_body "$SANDBOX/payload" \
    "core-rules/githooks/pre-push" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")"
  printf '%s\n' "$body" > "$SANDBOX/dispatcher.txt"
  extract_shell_function "$SANDBOX/dispatcher.txt" trellis_sync_pnpm_global_virtual_store \
    > "$SANDBOX/pnpm-setting-function.sh"
  [ -s "$SANDBOX/pnpm-setting-function.sh" ]
  # shellcheck disable=SC1090
  source "$SANDBOX/pnpm-setting-function.sh"
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

prepare_config_dirs() {
  USER_HOME="$SANDBOX/user-home"
  USER_XDG="$SANDBOX/user-xdg"
  GATE_HOME="$SANDBOX/gate-home"
  GATE_XDG="$SANDBOX/gate-xdg"
  GATE_CACHE="$SANDBOX/gate-cache"
  mkdir -p "$USER_HOME" "$USER_XDG" "$GATE_HOME" "$GATE_XDG" "$GATE_CACHE"
  chmod 700 "$USER_HOME" "$USER_XDG" "$GATE_HOME" "$GATE_XDG" "$GATE_CACHE"
}

@test "invalid pnpm setting output refuses without copying config" {
  prepare_config_dirs
  mkdir -p "$SANDBOX/stub-bin"
  cat > "$SANDBOX/stub-bin/pnpm" <<EOF
#!/bin/sh
case " \$* " in
  *" config get --location=global enableGlobalVirtualStore "*) printf 'maybe\\n' ;;
  *) printf 'write\\n' >> '$SANDBOX/pnpm-writes.log' ;;
esac
EOF
  chmod 700 "$SANDBOX/stub-bin/pnpm"
  if trellis_sync_pnpm_global_virtual_store \
    "$SANDBOX/stub-bin:/usr/bin:/bin" "$USER_HOME" x "$USER_XDG" \
    "$GATE_HOME" "$GATE_XDG" "$GATE_CACHE" "$GATE_CACHE/corepack" "$SANDBOX/scratch"; then
    echo 'invalid pnpm config output was accepted'
    false
  fi
  [ ! -e "$SANDBOX/pnpm-writes.log" ]
}

@test "pnpm setting lookup works after the dispatcher makes PATH readonly" {
  prepare_config_dirs
  mkdir -p "$SANDBOX/stub-bin"
  cat > "$SANDBOX/stub-bin/pnpm" <<EOF
#!/bin/sh
case " \$* " in
  *" config get --location=global enableGlobalVirtualStore "*) printf 'true\\n' ;;
  *" config set --location=global enableGlobalVirtualStore true "*) printf 'true\\n' > '$SANDBOX/copied-setting' ;;
  *) exit 9 ;;
esac
EOF
  chmod 700 "$SANDBOX/stub-bin/pnpm"
  run --separate-stderr bash -c '
    . "$1"
    shift
    readonly PATH
    trellis_sync_pnpm_global_virtual_store "$@"
  ' _ "$SANDBOX/pnpm-setting-function.sh" \
    "$SANDBOX/stub-bin:/usr/bin:/bin" "$USER_HOME" x "$USER_XDG" \
    "$GATE_HOME" "$GATE_XDG" "$GATE_CACHE" "$GATE_CACHE/corepack" "$SANDBOX/scratch"
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; return 1; }
  [ -z "$stderr" ]
  [ "$(< "$SANDBOX/copied-setting")" = true ]
}

@test "real pnpm preserves true, false, unset default and workspace precedence" {
  prepare_config_dirs
  local pnpm_bin pnpm_version pnpm_dir corepack_home toolchain_path project
  pnpm_bin="$(command -v pnpm)" || skip 'pnpm is absent'
  pnpm_dir="${pnpm_bin%/*}"
  corepack_home="${COREPACK_HOME:-${XDG_CACHE_HOME:-${LOCALAPPDATA:-$HOME/.cache}}/node/corepack}"
  run env -i PATH="$PATH" HOME="$SANDBOX/corepack-home" COREPACK_HOME="$corepack_home" \
    COREPACK_ENABLE_NETWORK=0 COREPACK_ENABLE_PROJECT_SPEC=0 COREPACK_DEFAULT_TO_LATEST=0 \
    "$pnpm_bin" --version
  [ "$status" -eq 0 ] || skip 'pnpm version is unavailable offline'
  pnpm_version="$output"
  [[ "$pnpm_version" == 11.* ]] || skip "pnpm major is not 11 ($pnpm_version)"
  toolchain_path="$pnpm_dir:$PATH"
  project="$SANDBOX/project"
  mkdir -p "$project" "$USER_XDG/pnpm"
  chmod 700 "$project" "$USER_XDG/pnpm"
  printf '%s\n' '{"name":"gate-setting-fixture","version":"1.0.0","private":true,"scripts":{"typecheck":"node gate-verify.cjs"}}' \
    > "$project/package.json"
  printf 'if (process.env.HOME !== "%s" || process.env.XDG_CONFIG_HOME !== "%s") process.exit(9);\n' \
    "$GATE_HOME" "$GATE_XDG" > "$project/gate-verify.cjs"
  printf 'verifyDepsBeforeRun: error\n' > "$project/pnpm-workspace.yaml"

  local -a user_env gate_env
  user_env=(
    "PATH=$PATH" "HOME=$USER_HOME" "XDG_CONFIG_HOME=$USER_XDG"
    "COREPACK_HOME=$corepack_home" "COREPACK_ENABLE_NETWORK=0"
    "COREPACK_ENABLE_PROJECT_SPEC=0" "COREPACK_DEFAULT_TO_LATEST=0"
    "TMPDIR=$SANDBOX/scratch" "LC_ALL=C" "npm_config_userconfig=/dev/null"
    'pnpm_config_offline=true' 'pnpm_config_frozen_lockfile=false'
    'pnpm_config_update_notifier=false' 'GIT_CONFIG_GLOBAL=/dev/null' 'GIT_CONFIG_NOSYSTEM=1'
  )
  gate_env=(
    "PATH=$PATH" "HOME=$GATE_HOME" "XDG_CONFIG_HOME=$GATE_XDG"
    "XDG_CACHE_HOME=$GATE_CACHE" "COREPACK_HOME=$corepack_home"
    "COREPACK_ENABLE_NETWORK=0" "COREPACK_ENABLE_PROJECT_SPEC=0" "COREPACK_DEFAULT_TO_LATEST=0"
    "TMPDIR=$SANDBOX/scratch" "LC_ALL=C" "npm_config_userconfig=/dev/null"
    'pnpm_config_offline=true' 'pnpm_config_verify_deps_before_run=error'
    'pnpm_config_update_notifier=false' 'GIT_CONFIG_GLOBAL=/dev/null' 'GIT_CONFIG_NOSYSTEM=1'
  )

  run env -i "${user_env[@]}" "$pnpm_bin" --dir "$project" config set \
    --location=global enableGlobalVirtualStore true
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  run env -i "${user_env[@]}" "$pnpm_bin" --dir "$project" install --offline
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  printf 'user_rc_install_exit=%s\n' "$status"
  [ -f "$project/node_modules/.pnpm-workspace-state-v1.json" ]

  # Reproduce the original failure under gate HOME/XDG before the fix is applied.
  run env -i "${gate_env[@]}" "$pnpm_bin" --dir "$project" run typecheck
  [ "$status" -eq 1 ] || { echo "expected pnpm setting-change exit 1, got $status"; false; }
  printf 'gate_before_sync_exit=%s\n' "$status"
  [[ "$output" == *ERR_PNPM_VERIFY_DEPS_BEFORE_RUN* ]] || { printf '%s\n' "$output"; false; }

  trellis_sync_pnpm_global_virtual_store \
    "$toolchain_path" "$USER_HOME" x "$USER_XDG" "$GATE_HOME" "$GATE_XDG" \
    "$GATE_CACHE" "$corepack_home" "$SANDBOX/scratch"
  [ "$(<"$GATE_XDG/pnpm/config.yaml")" = 'enableGlobalVirtualStore: true' ]
  run env -i "${gate_env[@]}" "$pnpm_bin" --dir "$project" run typecheck
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  printf 'gate_after_sync_true_exit=%s\n' "$status"

  # An explicit false is copied as false, not normalized to true.
  run env -i "${user_env[@]}" "$pnpm_bin" --dir "$project" config set \
    --location=global enableGlobalVirtualStore false
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  run env -i "${user_env[@]}" "$pnpm_bin" --dir "$project" install --offline
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  trellis_sync_pnpm_global_virtual_store \
    "$toolchain_path" "$USER_HOME" x "$USER_XDG" "$GATE_HOME" "$GATE_XDG" \
    "$GATE_CACHE" "$corepack_home" "$SANDBOX/scratch"
  [ "$(<"$GATE_XDG/pnpm/config.yaml")" = 'enableGlobalVirtualStore: false' ]
  run env -i "${gate_env[@]}" "$pnpm_bin" --dir "$project" run typecheck
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  printf 'gate_after_sync_false_exit=%s\n' "$status"

  # An unset user value clears a prior private override and retains pnpm's default.
  run env -i "${user_env[@]}" "$pnpm_bin" --dir "$project" config delete \
    --location=global enableGlobalVirtualStore
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  run env -i "${user_env[@]}" "$pnpm_bin" --dir "$project" install --offline
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  trellis_sync_pnpm_global_virtual_store \
    "$toolchain_path" "$USER_HOME" x "$USER_XDG" "$GATE_HOME" "$GATE_XDG" \
    "$GATE_CACHE" "$corepack_home" "$SANDBOX/scratch"
  [ ! -e "$GATE_XDG/pnpm/config.yaml" ]
  run env -i "${gate_env[@]}" "$pnpm_bin" --dir "$project" run typecheck
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  printf 'gate_default_exit=%s\n' "$status"

  # A project workspace false override remains higher precedence than the copied user true.
  run env -i "${user_env[@]}" "$pnpm_bin" --dir "$project" config set \
    --location=global enableGlobalVirtualStore true
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  printf 'verifyDepsBeforeRun: error\nenableGlobalVirtualStore: false\n' \
    > "$project/pnpm-workspace.yaml"
  run env -i "${user_env[@]}" "$pnpm_bin" --dir "$project" install --offline
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  trellis_sync_pnpm_global_virtual_store \
    "$toolchain_path" "$USER_HOME" x "$USER_XDG" "$GATE_HOME" "$GATE_XDG" \
    "$GATE_CACHE" "$corepack_home" "$SANDBOX/scratch"
  [ "$(<"$GATE_XDG/pnpm/config.yaml")" = 'enableGlobalVirtualStore: true' ]
  run env -i "${gate_env[@]}" "$pnpm_bin" --dir "$project" config get enableGlobalVirtualStore
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$output" = false ]
  run env -i "${gate_env[@]}" "$pnpm_bin" --dir "$project" run typecheck
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  printf 'gate_workspace_override_exit=%s\n' "$status"
}
