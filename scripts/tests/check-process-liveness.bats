#!/usr/bin/env bats
# Regression coverage for scripts/check-process-liveness.sh. Process-table rows
# are injected through a PATH-local ps shim; no live process gate is started.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
CHECK="$REPO_ROOT/scripts/check-process-liveness.sh"
UNSAFE_RE='(^|[^[:alnum:]_])pgrep([^[:alnum:]_]|$).*-[[:alnum:]-]*f[[:alnum:]-]*|(^|[^[:alnum:]_])ps([^[:alnum:]_]|$).*[|][[:space:]]*(grep|egrep|fgrep)([^[:alnum:]_]|$)'

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/liveness"
  BIN="$SANDBOX/bin"
  mkdir -p "$BIN"
  cat > "$BIN/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${PS_FIXTURE:-}"
exit "${PS_EXIT:-0}"
SH
  chmod +x "$BIN/ps"
}

check_gate() {
  run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE="$1" PS_EXIT="${2:-0}" "$CHECK" --gate
}

@test "gate check ignores prompt text and shell command strings" {
  local fixture
  fixture="101 1 101 herdr herdr agent prompt reminder pgrep -f run-all.sh
102 1 102 bash bash -lc herdr-agent-prompt-run-all.sh
103 1 103 python3 python3 -c print-run-tests-local.py"

  check_gate "$fixture"

  [ "$status" -eq 0 ]
  [ "$output" = "CLEAR no process-gate or Bats process detected" ]
}

@test "gate check matches an interpreter script position and deduplicates one process group" {
  local fixture
  fixture="200 1 200 bash bash /repo/core-rules/skills/process-gate/scripts/run-all.sh --range=origin/main..HEAD
201 200 200 bash bash /repo/core-rules/skills/process-gate/scripts/run-all.sh --range=origin/main..HEAD"

  check_gate "$fixture"

  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *$'pgid=200\tcomm=bash\ttarget=run-all.sh'* ]]
}

@test "gate check recognizes the Python runner and direct Bats groups" {
  local fixture
  fixture="300 1 300 python3 python3 /repo/scripts/run-tests-local.py
400 1 400 bash bash /opt/homebrew/bin/bats /repo/scripts/tests/doctor.bats"

  check_gate "$fixture"

  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *$'pgid=300\tcomm=python3\ttarget=run-tests-local.py'* ]]
  [[ "$output" == *$'pgid=400\tcomm=bash\ttarget=bats'* ]]
}

@test "build check anchors on the primary runtime program before project argv" {
  local fixture
  fixture="500 1 500 node node /repo/node_modules/vite/bin/vite.js build
501 1 501 node node /other/node_modules/vite/bin/vite.js build
502 1 502 node node /opt/herdr.js agent prompt /repo vite build"

  run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE="$fixture" PS_EXIT=0 "$CHECK" --build /repo

  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *$'pgid=500\tcomm=node\ttarget=vite.js'* ]]
}

@test "a failed process snapshot is an error rather than clear" {
  check_gate "" 3

  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR process-table snapshot unavailable"* ]]
}

@test "source detector catches full-argv probes and permits exact identity checks" {
  local bad="$SANDBOX/bad" good="$SANDBOX/good"
  cat > "$bad" <<'BAD'
pgrep -f "$matcher"
pgrep -fl .
pgrep -lf run-all.sh
ps -eo pid=,args= | grep run-tests.sh
BAD
  cat > "$good" <<'GOOD'
pgrep -x WindowServer
ps -p "$pid" -o lstart=
GOOD

  run grep -nE "$UNSAFE_RE" "$bad"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]

  run grep -nE "$UNSAFE_RE" "$good"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "tracked live sources contain no full-argv process identity probe" {
  local file hits="" found
  while IFS= read -r file; do
    case "$file" in
      notes/*|*/tests/*|*/fixtures/*) continue ;;
    esac
    found="$(grep -nE "$UNSAFE_RE" "$REPO_ROOT/$file" 2>/dev/null || true)"
    [ -z "$found" ] || hits="${hits}${file}:${found}"$'\n'
  done < <(git -C "$REPO_ROOT" ls-files)

  [ -z "$hits" ] || { printf '%s' "$hits"; false; }
}
