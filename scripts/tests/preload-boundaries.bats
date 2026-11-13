#!/usr/bin/env bats
# A preload marker is valid only in the shell that actually sourced libraries.
REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/preload-boundaries.XXXXXX")"
  mkdir -p "$SANDBOX/scripts/lib" "$SANDBOX/project"
}

@test "direct dispatcher and worktree do not pass their inherited preload marker" {
  cp "$REPO_ROOT/scripts/trellis" "$SANDBOX/scripts/trellis"
  cp "$REPO_ROOT/scripts/worktree.sh" "$SANDBOX/scripts/worktree.sh"
  for child in attach-project.sh seed-inheritance-symlinks.sh; do
    printf '%s\n' '#!/bin/bash' 'printf "marker=%s args=%s\n" "${TRELLIS_LIBS_PRELOADED-unset}" "$*"' > "$SANDBOX/scripts/$child"
    chmod +x "$SANDBOX/scripts/$child"
  done
  chmod +x "$SANDBOX/scripts/trellis" "$SANDBOX/scripts/worktree.sh"

  run env TRELLIS_LIBS_PRELOADED=1 "$SANDBOX/scripts/trellis" attach "$SANDBOX/project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "marker=unset args=attach $SANDBOX/project" ] || { echo "$output"; false; }
  run env TRELLIS_LIBS_PRELOADED=1 /bin/bash "$SANDBOX/scripts/worktree.sh" sync "$SANDBOX/project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "marker=unset args=--target $SANDBOX/project" ] || { echo "$output"; false; }
}

@test "direct surface planner executes despite an inherited preload marker" {
  run env TRELLIS_LIBS_PRELOADED=1 /bin/bash "$REPO_ROOT/scripts/lib/surface-plan.sh" --help
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"--payload"* ]] || { echo "planner returned success without a plan or usage: $output"; false; }
}

@test "sh execution never silently skips a direct attach or surface planner" {
  local script
  for script in "$REPO_ROOT/scripts/attach-project.sh" "$REPO_ROOT/scripts/lib/surface-plan.sh"; do
    # macOS sh is Bash in POSIX mode; Linux sh is commonly dash. Neither is
    # a supported interpreter for these Bash-specific programs.
    run env TRELLIS_LIBS_PRELOADED=1 /bin/sh "$script" --help
    [ "$status" -ne 0 ] && [[ "$output" == *"requires Bash"* ]] || { echo "sh did not refuse: $script: $output"; false; }
    if [ -x /bin/dash ]; then
      run env TRELLIS_LIBS_PRELOADED=1 /bin/dash "$script" --help
      [ "$status" -ne 0 ] && [[ "$output" == *"requires Bash"* ]] || { echo "dash did not refuse: $script: $output"; false; }
    fi
  done
}

@test "preloaded Bash stdin bundles do not reload pathname libraries" {
  local script
  for script in "$REPO_ROOT/scripts/attach-project.sh" "$REPO_ROOT/scripts/lib/surface-plan.sh"; do
    run env TRELLIS_LIBS_PRELOADED=1 /bin/bash -s < "$script"
    [ "$status" -eq 0 ] || { echo "stdin bundle failed: $script: $output"; false; }
    [ -z "$output" ] || { echo "stdin bundle ran direct main: $script: $output"; false; }
  done
}

@test "worktree migration clears the marker when it executes attach and detach children" {
  printf '%s\n' '#!/bin/bash' 'printf "marker=%s args=%s\n" "${TRELLIS_LIBS_PRELOADED-unset}" "$*"' > "$SANDBOX/scripts/attach-project.sh"
  chmod +x "$SANDBOX/scripts/attach-project.sh"
  run env TRELLIS_LIBS_PRELOADED=1 TRELLIS_HOME="$SANDBOX/trellis" bash -c '
    . "$1"
    _WM_LIB_DIR="$2" WM_LOG="$3"
    wm_attach_cmd attach "$4" 1.2.3 && wm_attach_cmd detach "$4"
  ' _ "$REPO_ROOT/scripts/lib/worktree-migrate-apply.sh" "$SANDBOX/scripts/lib" "$SANDBOX/migrate.log" "$SANDBOX/project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run grep '^marker=unset args=' "$SANDBOX/migrate.log"
  [ "$status" -eq 0 ] && [ "${#lines[@]}" -eq 2 ] || { echo "$output"; false; }
}

@test "the health planner bundle keeps its preload marker shell-local" {
  prefix="$(python3 - "$REPO_ROOT/scripts/lib/health-checks.sh" <<'PY'
import ast
import pathlib
import re
import sys
text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r'^\s+output = (\[b"TRELLIS_LIBS_PRELOADED=1\\n.*\])$', text, re.M)
if not match:
    raise SystemExit('health planner bundle prefix not found')
sys.stdout.buffer.write(b''.join(ast.literal_eval(match.group(1))))
PY
  )" || false
  run env TRELLIS_LIBS_PRELOADED=1 /bin/bash -c "$prefix"$'\n''
    [ "$TRELLIS_LIBS_PRELOADED" = 1 ] && ( [ "$TRELLIS_LIBS_PRELOADED" = 1 ] ) &&
      /bin/bash -c '\''[ -z "${TRELLIS_LIBS_PRELOADED+x}" ]'\'''
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "an inherited hygiene scalar does not stand in for a loaded library" {
  run env _HY_REGENERABLE_ALWAYS=poison /bin/bash -c '
    set -u
    . "$1"
    dj_find_caches "$2" || exit $?
    declare -F hy_last_git_activity >/dev/null || exit 1
    [ "$_HY_REGENERABLE_ALWAYS" != poison ] && [ -n "$_HY_DIST_BUILD_MARKERS" ] && [ -n "$_HY_TARGET_MARKERS" ]
  ' _ "$REPO_ROOT/scripts/lib/disk-janitor-lib.sh" "$SANDBOX/project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
