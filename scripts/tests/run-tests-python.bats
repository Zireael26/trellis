#!/usr/bin/env bats
# Exercise only the runner's installer, never execute a battery stage.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  export TMPDIR="$(CDPATH='' cd "$BATS_TEST_TMPDIR" && pwd -P)"
  mkdir -p "$HOME" "$TRELLIS_HOME"
  unset TRELLIS_PYTHON TRELLIS_PYTHON_CANDIDATES
  TEST_PYTHON=''
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [ -x "$candidate" ] && "$candidate" -I --version >/dev/null 2>&1; then
      TEST_PYTHON="$candidate"
      break
    fi
  done
  [ -n "$TEST_PYTHON" ] || skip "no working fixed-candidate Python"
  export TRELLIS_PYTHON_CANDIDATES="$TEST_PYTHON"
  export SHIM_SENTINEL="$TMPDIR/shim-ran"
  export SHIMS="$TMPDIR/pyenv/shims"
  mkdir -p "$SHIMS"
  printf '#!/bin/bash\nprintf "shim\\n" >> "$SHIM_SENTINEL"\nexec %q "$@"\n' \
    "$TEST_PYTHON" > "$SHIMS/python3"
  chmod +x "$SHIMS/python3"
  export PATH="$SHIMS:$PATH"

  HARNESS="$TMPDIR/install.sh"
  printf '#!/bin/bash\nset -euo pipefail\nROOT=$1\n' > "$HARNESS"
  awk '/^install_test_git_fence\(\) \{/ { f = 1 } f { print } f && /^\}/ { exit }' \
    "$REPO_ROOT/scripts/run-tests.sh" >> "$HARNESS"
  printf '\ninstall_test_git_fence\n/bin/bash "$2"\n' >> "$HARNESS"
}

@test "runner exports the resolved interpreter and bare python3 skips the shim" {
  cat > "$TMPDIR/check.sh" <<'SH'
set -euo pipefail
[ "$TRELLIS_PYTHON" = "$TRELLIS_PYTHON_CANDIDATES" ]
[ "$(command -v python3)" = "$TRELLIS_TEST_GIT_FENCE_ROOT/bin/python3" ]
python3 -I -c 'import os; assert os.environ["TRELLIS_PYTHON"] == os.environ["TRELLIS_PYTHON_CANDIDATES"]'
[ ! -e "$SHIM_SENTINEL" ]
SH
  run /bin/bash "$HARNESS" "$REPO_ROOT" "$TMPDIR/check.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$SHIM_SENTINEL" ]
}

@test "runner admission never reads or rewrites the caller's interpreter cache" {
  mkdir -p "$TRELLIS_HOME/state"
  printf '%s\n' "$SHIMS/python3" > "$TRELLIS_HOME/state/python"
  chmod 600 "$TRELLIS_HOME/state/python"
  # A trusted cached shim would win over the first fixed candidate if read.
  export TRELLIS_PYTHON_CANDIDATES="$TEST_PYTHON:$SHIMS/python3"
  printf '[ ! -e "$SHIM_SENTINEL" ]\n' > "$TMPDIR/check.sh"
  run /bin/bash "$HARNESS" "$REPO_ROOT" "$TMPDIR/check.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$TRELLIS_HOME/state/python")" = "$SHIMS/python3" ]
  # An unlisted cache entry would instead be rewritten on a cache miss.
  export TRELLIS_PYTHON_CANDIDATES="$TEST_PYTHON"
  run /bin/bash "$HARNESS" "$REPO_ROOT" "$TMPDIR/check.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$TRELLIS_HOME/state/python")" = "$SHIMS/python3" ]
}

@test "shim-only resolution pins its underlying executable for subsequent calls" {
  local tools="$TMPDIR/tools" tool
  mkdir -p "$tools"
  for tool in perl git mktemp chmod mkdir ln rm cat; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
  done
  cat > "$TMPDIR/check.sh" <<'SH'
set -euo pipefail
case "$TRELLIS_PYTHON" in */shims/*) exit 82 ;; esac
rm -f "$SHIM_SENTINEL"
python3 -I --version
"$TRELLIS_PYTHON" -I --version
[ ! -e "$SHIM_SENTINEL" ]
SH
  run env PATH="$SHIMS:$tools" TRELLIS_PYTHON_CANDIDATES=/nonexistent-runner-python \
    /bin/bash "$HARNESS" "$REPO_ROOT" "$TMPDIR/check.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$SHIM_SENTINEL" ]
}

@test "replacing PATH still exposes missing or shimmed Python instead of the runner pin" {
  cat > "$TMPDIR/check.sh" <<'SH'
set -euo pipefail
[ -n "$TRELLIS_PYTHON" ]
mkdir "$TMPDIR/no-python"
# No exported shell function or forced PATH can survive a suite's own PATH.
if env PATH="$TMPDIR/no-python" /bin/bash -c 'command -v python3'; then exit 81; fi
[ "$(env PATH="$SHIMS" /bin/bash -c 'command -v python3')" = "$SHIMS/python3" ]
env PATH="$SHIMS" /bin/bash -c 'python3 -I --version'
[ -s "$SHIM_SENTINEL" ]
SH
  run /bin/bash "$HARNESS" "$REPO_ROOT" "$TMPDIR/check.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -s "$SHIM_SENTINEL" ]
}
