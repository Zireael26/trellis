#!/usr/bin/env bats
# Missing-path probes must use the trusted interpreter, not caller PATH shims.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
REGISTRY="$REPO_ROOT/scripts/registry.sh"
INSTALLER="$REPO_ROOT/scripts/install-pi-web-search.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-trusted-python.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME" "$SANDBOX/fakebin"
  FAKE="$SANDBOX/fakebin/python3" MARKER="$SANDBOX/fake-python-ran"
  printf '#!/bin/sh\nprintf invoked > "%s"\nexit 0\n' "$MARKER" > "$FAKE"
  chmod 700 "$FAKE"
}

register_project() {
  PROJECT="$SANDBOX/volume/project"
  mkdir -p "$SANDBOX/volume"
  git init -q "$PROJECT"
  jq -n --arg root "$SANDBOX" '{schema_version:1,source_root:$root,release_remote:$root,active_cli_release:"1.0.0",default_fleet:"personal",fleets:{personal:{discovery_roots:[$root]}}}' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
  bash -c '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" personal sample "$2" "" "[]" "" "{}"' _ "$REPO_ROOT/scripts/lib/local-registry.sh" "$PROJECT" >/dev/null
  cp "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-before"
}

@test "pi removal ignores a caller PATH python shim" {
  run env PATH="$SANDBOX/fakebin:$PATH" TRELLIS_PYTHON="$FAKE" TRELLIS_PYTHON_CANDIDATES="$FAKE" "$INSTALLER" remove
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$MARKER" ] || { echo 'caller python shim was executed'; false; }
}

@test "pi removal still permits a definitely missing directory with exported builtin" {
  run env FAKE="$FAKE" bash -c '
    builtin() { return 0; }
    export -f builtin
    exec "$1" remove
  ' _ "$INSTALLER"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'after: none'* ]]
  [ ! -e "$MARKER" ]
}

@test "previous-hook enumeration ignores a caller PATH python shim" {
  mkdir -p "$SANDBOX/project/.previous"
  printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/project/.previous/pre-commit"
  chmod 700 "$SANDBOX/project/.previous/pre-commit"
  run env PATH="$SANDBOX/fakebin:$PATH" TRELLIS_PYTHON="$FAKE" TRELLIS_PYTHON_CANDIDATES="$FAKE" bash -c '. "$1"; _attachment_hooks_expected_passthrough_names "$2" .previous' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$SANDBOX/project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = pre-commit ] || { echo "expected hook was dropped: $output"; false; }
  [ ! -e "$MARKER" ]
}

@test "readable nonempty hook directories enumerate without starting the scanner" {
  mkdir -p "$SANDBOX/project/.previous"
  printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/project/.previous/pre-commit"
  chmod 700 "$SANDBOX/project/.previous/pre-commit"
  printf 'unrelated\n' > "$SANDBOX/project/.previous/not-a-hook"
  run bash -c '
    . "$1"
    mktemp() { printf "scanner-started\\n" >&2; return 1; }
    _attachment_hooks_expected_passthrough_names "$2" .previous
  ' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$SANDBOX/project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = pre-commit ] || { echo "$output"; false; }
}

@test "readable empty hook directories require a successful slow scan" {
  mkdir -p "$SANDBOX/project/.previous"
  run bash -c '
    . "$1"
    mktemp() { printf "scanner-started\\n" >&2; return 1; }
    _attachment_hooks_expected_passthrough_names "$2" .previous
  ' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$SANDBOX/project"
  [ "$status" -eq 3 ] && [[ "$output" == *scanner-started* ]] || { echo "$output"; false; }
  run bash -c '. "$1"; _attachment_hooks_expected_passthrough_names "$2" .previous' \
    _ "$REPO_ROOT/scripts/lib/attachment.sh" "$SANDBOX/project"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$output"; false; }
}

@test "a readable but unsearchable hook directory refuses instead of dropping hooks" {
  mkdir -p "$SANDBOX/project/.previous"
  printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/project/.previous/pre-commit"
  chmod 700 "$SANDBOX/project/.previous/pre-commit"
  chmod 400 "$SANDBOX/project/.previous"
  if [ -x "$SANDBOX/project/.previous" ]; then
    chmod 700 "$SANDBOX/project/.previous"
    skip 'effective user can search a mode-0400 directory'
  fi
  run bash -c '. "$1"; _attachment_hooks_expected_passthrough_names "$2" .previous' \
    _ "$REPO_ROOT/scripts/lib/attachment.sh" "$SANDBOX/project"
  rc="$status"
  chmod 700 "$SANDBOX/project/.previous"
  [ "$rc" -eq 3 ] || { echo "unsearchable directory accepted: $output"; false; }
  [[ "$output" == *"$SANDBOX/project/.previous"* ]] || { echo "$output"; false; }
}

@test "registry liveness check ignores a caller PATH python shim" {
  register_project
  chmod 000 "$SANDBOX/volume"
  run env PATH="$SANDBOX/fakebin:$PATH" TRELLIS_PYTHON="$FAKE" TRELLIS_PYTHON_CANDIDATES="$FAKE" "$REGISTRY" deregister --fleet personal --worktree-root "$PROJECT"
  rc="$status"
  chmod 700 "$SANDBOX/volume"
  [ "$rc" -ne 0 ] || { echo "inaccessible checkout removed: $output"; false; }
  [ ! -e "$MARKER" ] || { echo 'caller python shim was executed'; false; }
  cmp "$SANDBOX/registry-before" "$TRELLIS_HOME/registry.json"
}

@test "pi removal names missing trusted python and the unclassified path" {
  mkdir -p "$SANDBOX/repo/scripts/lib"
  cp "$INSTALLER" "$SANDBOX/repo/scripts/install-pi-web-search.sh"
  printf '%s\n' 'trellis_python_trusted() { return 1; }' > "$SANDBOX/repo/scripts/lib/trellis-python.sh"
  run "$SANDBOX/repo/scripts/install-pi-web-search.sh" remove
  [ "$status" -ne 0 ] || { echo "missing interpreter accepted: $output"; false; }
  [[ "$output" == *python3* && "$output" == *"$HOME/.pi/agent/extensions"* ]] || { echo "$output"; false; }
}

@test "hook enumeration names missing trusted python and the unclassified path" {
  mkdir -p "$SANDBOX/project/.previous" "$SANDBOX/copied"
  cp -R "$REPO_ROOT/scripts/lib" "$SANDBOX/copied/lib"
  printf '%s\n' 'trellis_python_trusted() { return 1; }' > "$SANDBOX/copied/lib/trellis-python.sh"
  run bash -c '. "$1"; _attachment_hooks_expected_passthrough_names "$2" .previous' _ "$SANDBOX/copied/lib/attachment.sh" "$SANDBOX/project"
  [ "$status" -eq 3 ] || { echo "missing interpreter accepted: $output"; false; }
  [[ "$output" == *python3* && "$output" == *"$SANDBOX/project/.previous"* ]] || { echo "$output"; false; }
}

@test "registry names missing trusted python and the unclassified path" {
  register_project
  mv "$PROJECT" "$SANDBOX/moved"
  mkdir -p "$SANDBOX/copied"
  cp "$REGISTRY" "$SANDBOX/copied/registry.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$SANDBOX/copied/lib"
  printf '%s\n' 'trellis_python_trusted() { return 1; }' > "$SANDBOX/copied/lib/trellis-python.sh"
  run "$SANDBOX/copied/registry.sh" deregister --fleet personal --worktree-root "$PROJECT"
  [ "$status" -eq 5 ] || { echo "missing interpreter accepted: $output"; false; }
  [[ "$output" == *python3* && "$output" == *"$PROJECT"* ]] || { echo "$output"; false; }
  cmp "$SANDBOX/registry-before" "$TRELLIS_HOME/registry.json"
}

@test "preloaded attachment loads the helper from its verified payload" {
  mkdir -p "$SANDBOX/project/.previous"
  printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/project/.previous/pre-commit"
  chmod 700 "$SANDBOX/project/.previous/pre-commit"
  run env TRELLIS_LIBS_PRELOADED=1 TRELLIS_VERIFIED_PAYLOAD="$REPO_ROOT" PATH="$SANDBOX/fakebin:$PATH" TRELLIS_PYTHON="$FAKE" TRELLIS_PYTHON_CANDIDATES="$FAKE" bash -c '. "$1"; _attachment_hooks_expected_passthrough_names "$2" .previous' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$SANDBOX/project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = pre-commit ]
  [ ! -e "$MARKER" ]
}

@test "preloaded attachment without a verified helper refuses and names the path" {
  mkdir -p "$SANDBOX/project/.previous" "$SANDBOX/old-payload"
  run env TRELLIS_LIBS_PRELOADED=1 TRELLIS_VERIFIED_PAYLOAD="$SANDBOX/old-payload" bash -c '. "$1"; _attachment_hooks_expected_passthrough_names "$2" .previous' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$SANDBOX/project"
  [ "$status" -eq 3 ] || { echo "missing verified helper accepted: $output"; false; }
  [[ "$output" == *python3* && "$output" == *"$SANDBOX/project/.previous"* ]] || { echo "$output"; false; }
}

make_old_helper() {
  python3 -I - "$REPO_ROOT/scripts/lib/trellis-python.sh" "$1" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
start = source.index('\ntrellis_python_trusted() {') + 1
end = source.index('\ntrellis_python() {', start)
Path(sys.argv[2]).write_text(source[:start] + source[end:])
PY
}

@test "old preloaded helper cannot inherit a forged trusted resolver" {
  mkdir -p "$SANDBOX/project/.previous" "$SANDBOX/old-payload/scripts/lib"
  make_old_helper "$SANDBOX/old-payload/scripts/lib/trellis-python.sh"
  run env TRELLIS_LIBS_PRELOADED=1 TRELLIS_VERIFIED_PAYLOAD="$SANDBOX/old-payload" FAKE="$FAKE" bash -c '
    trellis_python_trusted() { TRELLIS_PYTHON="$FAKE"; export TRELLIS_PYTHON; return 0; }
    . "$1"; _attachment_hooks_expected_passthrough_names "$2" .previous
  ' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$SANDBOX/project"
  [ "$status" -eq 3 ] || { echo "old helper accepted an inherited resolver: $output"; false; }
  [[ "$output" == *python3* && "$output" == *"$SANDBOX/project/.previous"* ]] || { echo "$output"; false; }
  [ ! -e "$MARKER" ]
}

@test "exported builtin cannot forge the attachment resolver" {
  mkdir -p "$SANDBOX/project/.previous" "$SANDBOX/old-payload/scripts/lib"
  chmod 311 "$SANDBOX/project/.previous"
  make_old_helper "$SANDBOX/old-payload/scripts/lib/trellis-python.sh"
  run env TRELLIS_LIBS_PRELOADED=1 TRELLIS_VERIFIED_PAYLOAD="$SANDBOX/old-payload" FAKE="$FAKE" bash -c '
    builtin() { return 0; }
    trellis_python_trusted() { TRELLIS_PYTHON="$FAKE"; export TRELLIS_PYTHON; return 0; }
    export -f builtin trellis_python_trusted
    exec /bin/bash -c '\''. "$1"; _attachment_hooks_expected_passthrough_names "$2" .previous'\'' _ "$1" "$2"
  ' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$SANDBOX/project"
  rc="$status"
  chmod 700 "$SANDBOX/project/.previous"
  [ "$rc" -eq 3 ] || { echo "exported builtin forged attachment resolver: $output"; false; }
  [[ "$output" == *python3* && "$output" == *"$SANDBOX/project/.previous"* ]] || { echo "$output"; false; }
  [ ! -e "$MARKER" ]
}

@test "old pi helper cannot inherit a forged trusted resolver" {
  mkdir -p "$SANDBOX/copied/scripts/lib"
  cp "$INSTALLER" "$SANDBOX/copied/scripts/install-pi-web-search.sh"
  make_old_helper "$SANDBOX/copied/scripts/lib/trellis-python.sh"
  run env FAKE="$FAKE" bash -c '
    trellis_python_trusted() { TRELLIS_PYTHON="$FAKE"; export TRELLIS_PYTHON; return 0; }
    export -f trellis_python_trusted
    exec "$1" remove
  ' _ "$SANDBOX/copied/scripts/install-pi-web-search.sh"
  [ "$status" -eq 4 ] || { echo "old helper accepted an inherited resolver: $output"; false; }
  [[ "$output" == *python3* && "$output" == *"$HOME/.pi/agent/extensions"* ]] || { echo "$output"; false; }
  [ ! -e "$MARKER" ]
}

@test "exported builtin cannot forge the pi resolver" {
  mkdir -p "$SANDBOX/copied/scripts/lib"
  cp "$INSTALLER" "$SANDBOX/copied/scripts/install-pi-web-search.sh"
  make_old_helper "$SANDBOX/copied/scripts/lib/trellis-python.sh"
  run env FAKE="$FAKE" bash -c '
    builtin() { return 0; }
    trellis_python_trusted() { TRELLIS_PYTHON="$FAKE"; export TRELLIS_PYTHON; return 0; }
    export -f builtin trellis_python_trusted
    exec "$1" remove
  ' _ "$SANDBOX/copied/scripts/install-pi-web-search.sh"
  [ "$status" -eq 4 ] || { echo "exported builtin forged pi resolver: $output"; false; }
  [[ "$output" == *python3* && "$output" == *"$HOME/.pi/agent/extensions"* ]] || { echo "$output"; false; }
  [ ! -e "$MARKER" ]
}

@test "old registry helper cannot inherit a forged trusted resolver" {
  register_project
  mv "$PROJECT" "$SANDBOX/moved"
  mkdir -p "$SANDBOX/copied"
  cp "$REGISTRY" "$SANDBOX/copied/registry.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$SANDBOX/copied/lib"
  make_old_helper "$SANDBOX/copied/lib/trellis-python.sh"
  run env FAKE="$FAKE" bash -c '
    trellis_python_trusted() { TRELLIS_PYTHON="$FAKE"; export TRELLIS_PYTHON; return 0; }
    export -f trellis_python_trusted
    exec "$1" deregister --fleet personal --worktree-root "$2"
  ' _ "$SANDBOX/copied/registry.sh" "$PROJECT"
  [ "$status" -eq 5 ] || { echo "old helper accepted an inherited resolver: $output"; false; }
  [[ "$output" == *python3* && "$output" == *"$PROJECT"* ]] || { echo "$output"; false; }
  [ ! -e "$MARKER" ]
  cmp "$SANDBOX/registry-before" "$TRELLIS_HOME/registry.json"
}

@test "exported builtin cannot forge the registry resolver" {
  register_project
  mv "$PROJECT" "$SANDBOX/moved"
  mkdir -p "$SANDBOX/copied"
  cp "$REGISTRY" "$SANDBOX/copied/registry.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$SANDBOX/copied/lib"
  make_old_helper "$SANDBOX/copied/lib/trellis-python.sh"
  run env FAKE="$FAKE" bash -c '
    builtin() { return 0; }
    trellis_python_trusted() { TRELLIS_PYTHON="$FAKE"; export TRELLIS_PYTHON; return 0; }
    export -f builtin trellis_python_trusted
    exec "$1" deregister --fleet personal --worktree-root "$2"
  ' _ "$SANDBOX/copied/registry.sh" "$PROJECT"
  [ "$status" -eq 5 ] || { echo "exported builtin forged registry resolver: $output"; false; }
  [[ "$output" == *python3* && "$output" == *"$PROJECT"* ]] || { echo "$output"; false; }
  [ ! -e "$MARKER" ]
  cmp "$SANDBOX/registry-before" "$TRELLIS_HOME/registry.json"
}
