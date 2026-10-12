#!/usr/bin/env bats
# L-B (spec 069 B1-B3) on the landed L-0 contract: pnpm user-level
# enableGlobalVirtualStore:true, uv link/volume rows and per-project rows.
#
# Contract: every test calls through hc_dep_sharing_rows USER_HOME
# TRELLIS_HOME FIX_MODE (off|dry-run|apply) and asserts the row contract
# (STATUS<TAB>MESSAGE on stdout, always returns 0). No test calls an inner
# helper directly.
#
# Hermetic: HOME is faked per test, all home-relative paths come from the
# USER_HOME argument, stubs live under the sandbox caller bin or tool-path
# dir, PATH is sanitized like doctor (/usr/bin:/bin:/usr/sbin:/sbin) and the
# caller's toolchain arrives only via TRELLIS_ATTACH_CALLER_PATH. Nothing is
# read or created under the real HOME.
#
# bash 3.2 / bats 1.x. REPO resolves to the worktree root (no hardcoded paths).

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
DEP_SHARING="$REPO_ROOT/scripts/lib/dep-sharing.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/dep-sharing.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  STUB_BIN="$SANDBOX/caller-bin"
  FAKE_HOME="$SANDBOX/home"
  FAKE_TRELLIS="$SANDBOX/trellis-home"
  mkdir -p "$STUB_BIN" "$FAKE_HOME" "$FAKE_TRELLIS"
  # shellcheck disable=SC1090
  . "$DEP_SHARING"
  REAL_HOME="$HOME"
  PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH
  HOME="$FAKE_HOME"
  export HOME
  TRELLIS_ATTACH_CALLER_PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export TRELLIS_ATTACH_CALLER_PATH
  unset ONLY_PROJECT UV_LINK_MODE UV_CONFIG_FILE
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
  unset STUB_PNPM_VERSION STUB_PNPM_GET_VALUE STUB_PNPM_ARGV_LOG
  unset STUB_PNPM_DIR_LOG STUB_PNPM_STATE STUB_PNPM_SET_EXIT
  unset STUB_UV_CACHE_DIR STUB_UV_ARGV_LOG
}

teardown() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }

# --- stub builders (all under the sandbox, never on PATH directly) -----------

stub_pnpm() {
  cat > "$STUB_BIN/pnpm" <<'EOF'
#!/bin/sh
# Stub pnpm: resolves via TRELLIS_ATTACH_CALLER_PATH, honours --dir at a
# neutral temp dir, answers version/get from env and persists set into state.
printf '%s\n' "$*" >> "${STUB_PNPM_ARGV_LOG:-/dev/null}"
if [ "$1" = "--dir" ]; then
  _dir="$2"
  shift 2
  if [ -f "$_dir/package.json" ]; then
    printf 'HAS_PKG %s\n' "$_dir" >> "${STUB_PNPM_DIR_LOG:-/dev/null}"
  else
    printf 'NO_PKG %s\n' "$_dir" >> "${STUB_PNPM_DIR_LOG:-/dev/null}"
  fi
fi
if [ "$1" = "--version" ]; then
  printf '%s\n' "${STUB_PNPM_VERSION:-11.23.0}"
  exit 0
fi
if [ "$1" = "config" ] && [ "$2" = "get" ]; then
  if [ -n "${STUB_PNPM_STATE:-}" ] && [ -f "$STUB_PNPM_STATE" ]; then
    cat "$STUB_PNPM_STATE"
  else
    printf '%s\n' "${STUB_PNPM_GET_VALUE:-undefined}"
  fi
  exit 0
fi
if [ "$1" = "config" ] && [ "$2" = "set" ]; then
  rc="${STUB_PNPM_SET_EXIT:-0}"
  if [ "$rc" -eq 0 ] && [ -n "${STUB_PNPM_STATE:-}" ]; then
    printf '%s\n' "$5" > "$STUB_PNPM_STATE"
  fi
  exit "$rc"
fi
exit 0
EOF
  chmod 755 "$STUB_BIN/pnpm"
}

stub_uv() {
  cat > "$STUB_BIN/uv" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_UV_ARGV_LOG:-/dev/null}"
if [ "$1" = "cache" ] && [ "$2" = "dir" ]; then
  printf '%s\n' "${STUB_UV_CACHE_DIR:-$HOME/.cache/uv}"
  exit 0
fi
exit 0
EOF
  chmod 755 "$STUB_BIN/uv"
}

stub_uv_in_dir() {
  cat > "$1/uv" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_UV_ARGV_LOG:-/dev/null}"
if [ "$1" = "cache" ] && [ "$2" = "dir" ]; then
  printf '%s\n' "${STUB_UV_CACHE_DIR:-$HOME/.cache/uv}"
  exit 0
fi
exit 0
EOF
  chmod 755 "$1/uv"
}

stub_stat_devices() {
  cat > "$STUB_BIN/stat" <<EOF
#!/bin/sh
cache="\${STUB_UV_CACHE_DIR:-\$HOME/.cache/uv}"
if [ "\$*" = "-f %d \$cache" ]; then printf '%s\n' "$1"; exit 0; fi
if [ "\$*" = "-f %d \$HOME/projects" ]; then printf '%s\n' "$2"; exit 0; fi
if [ "\$*" = "-c %d \$cache" ]; then printf '%s\n' "$1"; exit 0; fi
if [ "\$*" = "-c %d \$HOME/projects" ]; then printf '%s\n' "$2"; exit 0; fi
exec /usr/bin/stat "\$@"
EOF
  chmod 755 "$STUB_BIN/stat"
}

write_registry() {
  local home="$1"; shift
  mkdir -p "$home"
  {
    printf '{"schema_version":1,"projects":{'
    local first=1 root key
    for root in "$@"; do
      key="personal/$(basename "$root")"
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '"%s":{"fleet":"personal","project_id":"%s","status":"active","metadata":{},"checkouts":{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":{"root":"%s","git_common_dir":"%s/.git","harnesses":["claude"],"worktrees":{}}}}' \
        "$key" "$(basename "$root")" "$root" "$root"
    done
    printf '}}\n'
  } > "$home/registry.json"
  chmod 600 "$home/registry.json"
}

pnpm_defaults() {
  stub_pnpm
  export STUB_PNPM_VERSION=11.23.0 STUB_PNPM_GET_VALUE=true
  export STUB_PNPM_ARGV_LOG="$SANDBOX/pnpm-argv.log" STUB_PNPM_DIR_LOG="$SANDBOX/pnpm-dir.log"
  export STUB_PNPM_STATE="$SANDBOX/pnpm-state"
  : > "$SANDBOX/pnpm-argv.log"; : > "$SANDBOX/pnpm-dir.log"; rm -f "$SANDBOX/pnpm-state"
}

# --- B.1: host rows through the row function ----------------------------------

@test "healthy store is silent and returns 0" {
  pnpm_defaults; stub_uv
  export STUB_UV_CACHE_DIR="$SANDBOX/uv-cache"
  mkdir -p "$STUB_UV_CACHE_DIR"
  stub_stat_devices 11 11
  PATH="$STUB_BIN:$PATH"; export PATH
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }
}

@test "pnpm off reports enableGlobalVirtualStore, never virtualStoreType" {
  pnpm_defaults; stub_uv
  export STUB_PNPM_GET_VALUE=undefined
  : > "$SANDBOX/pnpm-argv.log"; : > "$SANDBOX/pnpm-dir.log"; rm -f "$SANDBOX/pnpm-state"
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"enableGlobalVirtualStore"* ]] || { echo "$output"; false; }
  [[ "$output" == *"doctor --fix"* ]] || { echo "$output"; false; }
  [[ "$output" != *"virtualStoreType"* ]] || { echo "$output"; false; }
}

@test "pnpm below 10.12.1 is unsupported and returns 0" {
  pnpm_defaults; stub_uv
  export STUB_PNPM_VERSION=9.5.0 STUB_PNPM_GET_VALUE=undefined
  : > "$SANDBOX/pnpm-argv.log"; : > "$SANDBOX/pnpm-dir.log"; rm -f "$SANDBOX/pnpm-state"
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"below 10.12.1"* ]] || { echo "$output"; false; }
  [[ "$output" == *"not upgraded"* ]] || { echo "$output"; false; }
}

@test "pnpm absent is INFO and returns 0" {
  unset TRELLIS_ATTACH_CALLER_PATH
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"pnpm not found"* ]] || { echo "$output"; false; }
}

# --- P1: tool resolution from the caller PATH and the tool-path file ---------

@test "pnpm resolves from TRELLIS_ATTACH_CALLER_PATH under a sanitized PATH" {
  stub_pnpm; stub_uv
  export STUB_PNPM_VERSION=11.23.0 STUB_PNPM_GET_VALUE=undefined
  export STUB_PNPM_ARGV_LOG="$SANDBOX/pnpm-argv.log" STUB_PNPM_DIR_LOG="$SANDBOX/pnpm-dir.log"
  export STUB_PNPM_STATE="$SANDBOX/pnpm-state"
  : > "$SANDBOX/pnpm-argv.log"; : > "$SANDBOX/pnpm-dir.log"; rm -f "$SANDBOX/pnpm-state"
  unset TRELLIS_ATTACH_CALLER_PATH
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"pnpm not found"* ]] || { echo "$output"; false; }
  export TRELLIS_ATTACH_CALLER_PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"enableGlobalVirtualStore"* ]] || { echo "$output"; false; }
  [[ "$output" != *"pnpm not found"* ]] || { echo "$output"; false; }
}

@test "pnpm with env-node shebang runs under the caller PATH" {
  cat > "$STUB_BIN/node" <<'EOF'
#!/bin/sh
# Stub node: argv is <pnpm-path> <pnpm-args...>; drop the script path.
shift
printf '%s\n' "$*" >> "${STUB_PNPM_ARGV_LOG:-/dev/null}"
if [ "$1" = "--dir" ]; then
  _dir="$2"
  shift 2
  if [ -f "$_dir/package.json" ]; then
    printf 'HAS_PKG %s\n' "$_dir" >> "${STUB_PNPM_DIR_LOG:-/dev/null}"
  else
    printf 'NO_PKG %s\n' "$_dir" >> "${STUB_PNPM_DIR_LOG:-/dev/null}"
  fi
fi
if [ "$1" = "--version" ]; then
  printf '%s\n' "${STUB_PNPM_VERSION:-11.23.0}"
  exit 0
fi
if [ "$1" = "config" ] && [ "$2" = "get" ]; then
  if [ -n "${STUB_PNPM_STATE:-}" ] && [ -f "$STUB_PNPM_STATE" ]; then
    cat "$STUB_PNPM_STATE"
  else
    printf '%s\n' "${STUB_PNPM_GET_VALUE:-undefined}"
  fi
  exit 0
fi
if [ "$1" = "config" ] && [ "$2" = "set" ]; then
  rc="${STUB_PNPM_SET_EXIT:-0}"
  if [ "$rc" -eq 0 ] && [ -n "${STUB_PNPM_STATE:-}" ]; then
    printf '%s\n' "$5" > "$STUB_PNPM_STATE"
  fi
  exit "$rc"
fi
exit 0
EOF
  chmod 755 "$STUB_BIN/node"
  printf '#!/usr/bin/env node\n// stub pnpm: needs node from the caller PATH\n' > "$STUB_BIN/pnpm"
  chmod 755 "$STUB_BIN/pnpm"
  stub_uv
  export STUB_PNPM_VERSION=11.23.0 STUB_PNPM_GET_VALUE=undefined
  export STUB_PNPM_ARGV_LOG="$SANDBOX/pnpm-argv.log" STUB_PNPM_DIR_LOG="$SANDBOX/pnpm-dir.log"
  export STUB_PNPM_STATE="$SANDBOX/pnpm-state"
  : > "$SANDBOX/pnpm-argv.log"; : > "$SANDBOX/pnpm-dir.log"; rm -f "$SANDBOX/pnpm-state"
  PATH="/usr/bin:/bin:/usr/sbin:/sbin"; export PATH
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"enableGlobalVirtualStore"* ]] || { echo "$output"; false; }
  [[ "$output" != *"version unreadable"* ]] || { echo "$output"; false; }
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" apply
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"enabled the pnpm global virtual store"* ]] || { echo "$output"; false; }
  [ "$(cat "$SANDBOX/pnpm-state")" = "true" ] || { cat "$SANDBOX/pnpm-state"; false; }
}

@test "uv resolves from the disk-janitor tool-path file" {
  pnpm_defaults
  mkdir -p "$SANDBOX/tools"
  stub_uv_in_dir "$SANDBOX/tools"
  export TRELLIS_ATTACH_CALLER_PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export STUB_UV_CACHE_DIR="$SANDBOX/uv-cache"
  mkdir -p "$STUB_UV_CACHE_DIR" "$FAKE_HOME/projects"
  stub_stat_devices 11 22
  PATH="$STUB_BIN:$PATH"; export PATH
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" != *"different device"* ]] || { echo "$output"; false; }
  mkdir -p "$FAKE_TRELLIS/state/disk-janitor"
  printf '%s\n' "$SANDBOX/tools" > "$FAKE_TRELLIS/state/disk-janitor/tool-path"
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"different device"* ]] || { echo "$output"; false; }
}

# --- pnpm --dir at a neutral temp dir -----------------------------------------

@test "every pnpm probe runs with --dir at a neutral dir without package.json" {
  pnpm_defaults; stub_uv
  export STUB_PNPM_GET_VALUE=undefined
  : > "$SANDBOX/pnpm-argv.log"; : > "$SANDBOX/pnpm-dir.log"; rm -f "$SANDBOX/pnpm-state"
  mkdir -p "$SANDBOX/proj-pin"
  printf '{"name":"pinned","packageManager":"pnpm@11.9.0"}\n' > "$SANDBOX/proj-pin/package.json"
  old_pwd="$PWD"
  cd "$SANDBOX/proj-pin"
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  cd "$old_pwd"
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  grep -q -- "--dir" "$SANDBOX/pnpm-argv.log" || { cat "$SANDBOX/pnpm-argv.log"; false; }
  grep -qx "NO_PKG .*" "$SANDBOX/pnpm-dir.log" || { cat "$SANDBOX/pnpm-dir.log"; false; }
  ! grep -q "$SANDBOX/proj-pin" "$SANDBOX/pnpm-dir.log" || { cat "$SANDBOX/pnpm-dir.log"; false; }
}

# --- B.2: dry-run and apply live inside the row function ----------------------

@test "dry-run prints the enableGlobalVirtualStore plan and changes nothing" {
  pnpm_defaults; stub_uv
  export STUB_PNPM_GET_VALUE=undefined
  : > "$SANDBOX/pnpm-argv.log"; : > "$SANDBOX/pnpm-dir.log"; rm -f "$SANDBOX/pnpm-state"
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" dry-run
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"would run: pnpm config set --location=global enableGlobalVirtualStore true"* ]] || { echo "$output"; false; }
  [[ "$output" != *"virtualStoreType"* ]] || { echo "$output"; false; }
  ! grep -q "config set" "$SANDBOX/pnpm-argv.log" || { cat "$SANDBOX/pnpm-argv.log"; false; }
  [ ! -f "$SANDBOX/pnpm-state" ] || { cat "$SANDBOX/pnpm-state"; false; }
}

@test "apply writes enableGlobalVirtualStore true at user level" {
  pnpm_defaults; stub_uv
  export STUB_PNPM_GET_VALUE=undefined
  : > "$SANDBOX/pnpm-argv.log"; : > "$SANDBOX/pnpm-dir.log"; rm -f "$SANDBOX/pnpm-state"
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" apply
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  grep -Fq -- "--location=global enableGlobalVirtualStore true" "$SANDBOX/pnpm-argv.log" || { cat "$SANDBOX/pnpm-argv.log"; false; }
  ! grep -q "virtualStoreType" "$SANDBOX/pnpm-argv.log" || { cat "$SANDBOX/pnpm-argv.log"; false; }
  [[ "$output" == *"enabled the pnpm global virtual store"* ]] || { echo "$output"; false; }
  [[ "$output" != *"virtualStoreType"* ]] || { echo "$output"; false; }
  [ "$(cat "$SANDBOX/pnpm-state")" = "true" ] || { cat "$SANDBOX/pnpm-state"; false; }
}

@test "apply under ONLY_PROJECT never writes the global setting" {
  pnpm_defaults; stub_uv
  export STUB_PNPM_GET_VALUE=undefined
  : > "$SANDBOX/pnpm-argv.log"; : > "$SANDBOX/pnpm-dir.log"; rm -f "$SANDBOX/pnpm-state"
  export ONLY_PROJECT="personal/foo"
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" apply
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  ! grep -q "config set" "$SANDBOX/pnpm-argv.log" || { cat "$SANDBOX/pnpm-argv.log"; false; }
  [[ "$output" == *"deferred"* ]] || { echo "$output"; false; }
  [[ "$output" == *"--project personal/foo"* ]] || { echo "$output"; false; }
  [ ! -f "$SANDBOX/pnpm-state" ] || { cat "$SANDBOX/pnpm-state"; false; }
}

# --- B.3: per-project rows -----------------------------------------------------

@test "project pinned below 10.12.1 cannot honour the user-level setting" {
  pnpm_defaults; stub_uv
  mkdir -p "$SANDBOX/proj-old"
  printf '{"name":"old","packageManager":"pnpm@9.5.0"}\n' > "$SANDBOX/proj-old/package.json"
  write_registry "$FAKE_TRELLIS" "$SANDBOX/proj-old"
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"cannot honour user-level enableGlobalVirtualStore:true"* ]] || { echo "$output"; false; }
  [[ "$output" == *"not shared"* ]] || { echo "$output"; false; }
  [[ "$output" == *"not upgraded"* ]] || { echo "$output"; false; }
}

@test "project opt-out in pnpm-workspace.yaml blocks user-level sharing" {
  pnpm_defaults; stub_uv
  mkdir -p "$SANDBOX/proj-optout"
  printf '{"name":"optout","packageManager":"pnpm@11.23.0"}\n' > "$SANDBOX/proj-optout/package.json"
  printf 'packages:\n  - apps/*\nenableGlobalVirtualStore: false\n' > "$SANDBOX/proj-optout/pnpm-workspace.yaml"
  write_registry "$FAKE_TRELLIS" "$SANDBOX/proj-optout"
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"enableGlobalVirtualStore:false"* ]] || { echo "$output"; false; }
  [[ "$output" == *"per-repo PR"* ]] || { echo "$output"; false; }
}

@test "root install scripts alone are never flagged as a store risk" {
  pnpm_defaults; stub_uv
  mkdir -p "$SANDBOX/proj-scripts"
  printf '{"name":"scripts","packageManager":"pnpm@11.23.0","scripts":{"postinstall":"node build.js","prepare":"husky"}}\n' > "$SANDBOX/proj-scripts/package.json"
  write_registry "$FAKE_TRELLIS" "$SANDBOX/proj-scripts"
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" != *"at risk"* ]] || { echo "$output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }
}

@test "dependency builds via onlyBuiltDependencies are flagged as a store risk" {
  pnpm_defaults; stub_uv
  mkdir -p "$SANDBOX/proj-a" "$SANDBOX/proj-b"
  printf '{"name":"a","packageManager":"pnpm@11.23.0","pnpm":{"onlyBuiltDependencies":["esbuild"]}}\n' > "$SANDBOX/proj-a/package.json"
  printf '{"name":"b","packageManager":"pnpm@11.23.0"}\n' > "$SANDBOX/proj-b/package.json"
  printf 'packages:\n  - apps/*\nonlyBuiltDependencies:\n  - esbuild\n' > "$SANDBOX/proj-b/pnpm-workspace.yaml"
  write_registry "$FAKE_TRELLIS" "$SANDBOX/proj-a" "$SANDBOX/proj-b"
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"$SANDBOX/proj-a"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$SANDBOX/proj-b"* ]] || { echo "$output"; false; }
  [[ "$output" == *"write into shared package dirs"* ]] || { echo "$output"; false; }
}

@test "clean project on a current pin has no project row" {
  pnpm_defaults; stub_uv
  mkdir -p "$SANDBOX/proj-clean"
  printf '{"name":"clean","packageManager":"pnpm@11.23.0"}\n' > "$SANDBOX/proj-clean/package.json"
  write_registry "$FAKE_TRELLIS" "$SANDBOX/proj-clean"
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }
}

# --- B3: uv rows from USER_HOME ------------------------------------------------

@test "UV_LINK_MODE=copy in env warns and returns 0" {
  pnpm_defaults; stub_uv
  export UV_LINK_MODE=copy
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"UV_LINK_MODE=copy"* ]] || { echo "$output"; false; }
}

@test "uv.toml link-mode copy under USER_HOME warns naming the fake file" {
  pnpm_defaults; stub_uv
  mkdir -p "$FAKE_HOME/.config/uv"
  printf 'link-mode = "copy"\n' > "$FAKE_HOME/.config/uv/uv.toml"
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *'link-mode'* ]] || { echo "$output"; false; }
  [[ "$output" == *"$FAKE_HOME/.config/uv/uv.toml"* ]] || { echo "$output"; false; }
}

@test "uv cache on a different device than USER_HOME projects warns" {
  pnpm_defaults; stub_uv
  export STUB_UV_CACHE_DIR="$SANDBOX/uv-cache"
  mkdir -p "$STUB_UV_CACHE_DIR" "$FAKE_HOME/projects"
  stub_stat_devices 11 22
  PATH="$STUB_BIN:$PATH"; export PATH
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"different device"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$FAKE_HOME/projects"* ]] || { echo "$output"; false; }
}

@test "uv cache on the same device is silent" {
  pnpm_defaults; stub_uv
  export STUB_UV_CACHE_DIR="$SANDBOX/uv-cache"
  mkdir -p "$STUB_UV_CACHE_DIR" "$FAKE_HOME/projects"
  stub_stat_devices 11 11
  PATH="$STUB_BIN:$PATH"; export PATH
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }
}

# --- hermeticity and row contract ----------------------------------------------

@test "reads home-relative paths from USER_HOME, never the ambient HOME" {
  pnpm_defaults; stub_uv
  mkdir -p "$SANDBOX/other-home" "$FAKE_HOME/.config/uv"
  printf 'link-mode = "copy"\n' > "$FAKE_HOME/.config/uv/uv.toml"
  HOME="$SANDBOX/other-home"
  export HOME
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" off
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"$FAKE_HOME/.config/uv/uv.toml"* ]] || { echo "$output"; false; }
  [[ "$output" != *"$SANDBOX/other-home"* ]] || { echo "$output"; false; }
  [[ "$output" != *"$REAL_HOME/.config/uv/uv.toml"* ]] || { echo "$output"; false; }
}

@test "library never reads the ambient HOME for paths" {
  run grep -q '\$HOME/' "$DEP_SHARING"
  [ "$status" -ne 0 ] || { echo "library reads \$HOME directly"; false; }
}

@test "bad FIX_MODE warns and still returns 0" {
  pnpm_defaults; stub_uv
  run hc_dep_sharing_rows "$FAKE_HOME" "$FAKE_TRELLIS" bogus
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"bad FIX_MODE"* ]] || { echo "$output"; false; }
}
