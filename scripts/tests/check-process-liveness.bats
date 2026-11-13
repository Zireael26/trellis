#!/usr/bin/env bats
# Regression coverage for scripts/check-process-liveness.sh. Process-table rows
# are injected through a PATH-local ps shim, including real ps rows from inert
# runner-shaped scripts; no live process gate or battery is started.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
CHECK="$REPO_ROOT/scripts/check-process-liveness.sh"
UNSAFE_RE='(^|[^[:alnum:]_])pgrep([^[:alnum:]_]|$).*-[[:alnum:]-]*f[[:alnum:]-]*|(^|[^[:alnum:]_])ps([^[:alnum:]_]|$).*[|][[:space:]]*(grep|egrep|fgrep)([^[:alnum:]_]|$)'

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/liveness"
  BIN="$SANDBOX/bin"
  mkdir -p "$BIN"
  cat > "$BIN/ps" <<'SH'
#!/usr/bin/env bash
# Pin the portable kernel accounting name even where comm happens to be an alias.
case " $* " in
  *' pid=,ppid=,pgid=,ucomm=,args= '*) ;;
  *) echo 'expected ucomm snapshot format' >&2; exit 3 ;;
esac
printf '%s\n' "${PS_FIXTURE:-}"
exit "${PS_EXIT:-0}"
SH
  chmod +x "$BIN/ps"
}

check_gate() {
  run env PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" PS_FIXTURE="$1" PS_EXIT="${2:-0}" "$CHECK" --gate
}

@test "gate check ignores prompt text and shell command strings" {
  local fixture
  fixture="101 1 101 hc hc send reminder pgrep -f run-all.sh
102 1 102 bash bash -lc herdr-agent-prompt-run-all.sh
103 1 103 python3 python3 -c print-run-tests-local.py
104 1 104 herdr herdr prompt bash /repo with spaces/scripts/run-tests.sh
105 1 105 bash bash -lc python3 /repo with spaces/scripts/run-tests-local.py
106 1 106 python3 python3 -c prompt /repo with spaces/scripts/run-tests-local.py
107 1 107 python3 python3 -m agent prompt /repo with spaces/scripts/run-tests-local.py"

  check_gate "$fixture"

  [ "$status" -eq 0 ]
  [ "$output" = "CLEAR no process-gate or Bats process detected" ]
}

@test "gate check ignores runner arguments when primary files exist in the process cwd" {
  local pid fixture
  mkdir -p "$SANDBOX/process cwd/scripts" "$SANDBOX/absolute"
  touch "$SANDBOX/process cwd/scripts/lint.sh" \
    "$SANDBOX/process cwd/scripts/push-test-map.py" "$SANDBOX/absolute/trellis"
  cd "$SANDBOX/process cwd"
  pid="$(exec sh -c 'echo "$PPID"')"  # this shell's pid; bash 3.2 has no BASHPID
  fixture="$pid 1 $pid bash bash scripts/lint.sh --only scripts/run-tests.sh
$pid 1 $pid python3 python3 scripts/push-test-map.py scripts/run-tests-local.py
$pid 1 $pid bash bash $SANDBOX/absolute/trellis heavy --light --lane rv -- bats scripts/tests/foo.bats"

  check_gate "$fixture"

  [ "$status" -eq 0 ]
  [ "$output" = "CLEAR no process-gate or Bats process detected" ]

  # Removing false ambiguity must not discard another process's verified BUSY.
  check_gate "$fixture
220 1 220 bash bash /repo/scripts/run-tests.sh"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *$'pgid=220\tcomm=bash\ttarget=run-tests.sh'* ]] || false
}

@test "gate check keeps ambiguity for missing process cwd files even if the probe cwd has one" {
  local pid
  mkdir -p "$SANDBOX/target" "$SANDBOX/probe"
  touch "$SANDBOX/probe/agent.py"
  cd "$SANDBOX/target"
  pid="$(exec sh -c 'echo "$PPID"')"  # this shell's pid; bash 3.2 has no BASHPID
  run bash -c 'cd "$1"; PATH="$2:/usr/bin:/bin:/usr/sbin:/sbin" PS_FIXTURE="$3" "$4" --gate' \
    cwd-probe "$SANDBOX/probe" "$BIN" \
    "$pid 1 $pid python3 python3 agent.py scripts/run-tests-local.py" "$CHECK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous interpreter script path"* ]] || false

  check_gate '999999999 1 999999999 python3 python3 agent.py scripts/run-tests-local.py'
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous interpreter script path"* ]] || false
}

@test "gate check matches an interpreter script position and deduplicates one process group" {
  local fixture
  fixture="200 1 200 bash bash /repo/core-rules/skills/process-gate/scripts/run-all.sh --range=origin/main..HEAD
201 200 200 bash bash /repo/core-rules/skills/process-gate/scripts/run-all.sh --range=origin/main..HEAD"

  check_gate "$fixture"

  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *$'pgid=200\tcomm=bash\ttarget=run-all.sh'* ]] || false
}

@test "gate check recognizes the Python runner and direct Bats groups" {
  local fixture
  fixture="300 1 300 python3 python3 /repo/scripts/run-tests-local.py
400 1 400 bash bash /opt/homebrew/bin/bats /repo/scripts/tests/doctor.bats"

  check_gate "$fixture"

  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *$'pgid=300\tcomm=python3\ttarget=run-tests-local.py'* ]] || false
  [[ "$output" == *$'pgid=400\tcomm=bash\ttarget=bats'* ]] || false
}

@test "gate check fails closed on whitespace-ambiguous primary script paths" {
  local fixture
  fixture="310 1 310 bash bash /repo with spaces/scripts/run-tests.sh
311 1 311 python3 python3 -I -B /repo with spaces/scripts/run-tests-local.py
312 1 312 bash bash -- /repo with spaces/core-rules/skills/process-gate/scripts/run-all.sh
313 1 313 bash bash /repo with spaces/scripts/trellis-doctor
314 1 314 bash bash /repo with spaces/scripts/tests/doctor.bats"

  check_gate "$fixture"

  [ "$status" -eq 2 ]
  [ "${#lines[@]}" -eq 5 ]
  [[ "$output" == *$'ERROR\tpid=310\t'*"ambiguous interpreter script path"* ]] || false
  [[ "$output" == *$'ERROR\tpid=311\t'*"ambiguous interpreter script path"* ]] || false
  [[ "$output" != *CLEAR* && "$output" != *BUSY* ]] || false
}

@test "gate check never promotes an ambiguous runner argument to verified BUSY" {
  # ps flattens this argv exactly like a single whitespace-bearing script path.
  check_gate '320 1 320 python3 python3 /repo/agent.py prompt /repo with spaces/scripts/run-tests-local.py'

  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous interpreter script path"* ]] || false
  [[ "$output" != *CLEAR* && "$output" != *BUSY* ]] || false
}

@test "gate check refuses quiet for live shell and Python runner paths with spaces" {
  run python3 -I -B - "$SANDBOX" "$BIN" "$CHECK" <<'PY'
import os
import select
import shutil
import subprocess
import sys
from pathlib import Path

sandbox, bin_path, check = map(Path, sys.argv[1:])
scripts = sandbox / 'repo with spaces' / 'scripts'
scripts.mkdir(parents=True)
fixtures = [
    ('run-tests.sh', [shutil.which('bash')], "printf 'ready\\n'\nIFS= read -r line\n"),
    ('run-tests-local.py', [sys.executable, '-I', '-B'],
     "import sys\nprint('ready', flush=True)\nsys.stdin.read()\n"),
]
observed = []
for name, interpreter, source in fixtures:
    script = scripts / name
    script.write_text(source)
    # Only shell builtins / Python stdin reads: no detached or untracked child.
    child = subprocess.Popen([*interpreter, str(script)], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        assert select.select([child.stdout], [], [], 5)[0], 'fixture startup timed out'
        assert child.stdout.readline() == b'ready\n'
        snapshot = subprocess.check_output(
            ['ps', '-ww', '-p', str(child.pid), '-o', 'pid=,ppid=,pgid=,ucomm=,args='], text=True)
        environment = dict(os.environ, PATH=str(bin_path) + os.pathsep + os.environ['PATH'],
                           PS_FIXTURE=snapshot, PS_EXIT='0')
        result = subprocess.run([str(check), '--gate'], env=environment,
                                capture_output=True, text=True, timeout=5)
        observed.append((name, result.returncode, result.stdout + result.stderr, snapshot))
    finally:
        child.stdin.close()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
assert all(status == 2 and 'ambiguous interpreter script path' in output
           and 'CLEAR' not in output and 'BUSY' not in output
           for _, status, output, _ in observed), observed
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
}

@test "build check anchors on the primary runtime program before project argv" {
  local fixture project="$SANDBOX/project" other="$SANDBOX/other" pid
  mkdir -p "$project" "$other"
  cd "$other"
  pid="$(exec sh -c 'echo "$PPID"')"  # this shell's pid; bash 3.2 has no BASHPID
  fixture="500 1 500 node node $project/node_modules/vite/bin/vite.js build
$pid 1 501 node node /other/node_modules/vite/bin/vite.js build
502 1 502 node node /opt/herdr.js agent prompt $project vite build"

  run env PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" PS_FIXTURE="$fixture" PS_EXIT=0 "$CHECK" --build "$project"

  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *$'pgid=500\tcomm=node\ttarget=vite.js'* ]] || false

  run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE='503 1 503 node-MainThread node /repo/node_modules/vite/bin/vite.js build' \
    PS_EXIT=0 "$CHECK" --build /repo
  [ "$status" -eq 1 ]
  [[ "$output" == *$'pgid=503\tcomm=node-MainThread\ttarget=vite.js'* ]] || false

  run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE='504 1 504 MainThread node /repo/node_modules/vite/bin/vite.js build' \
    PS_EXIT=0 "$CHECK" --build /repo
  [ "$status" -eq 1 ]
  [[ "$output" == *$'pgid=504\tcomm=MainThread\ttarget=vite.js'* ]] || false
}

@test "build check recognizes named bundlers and default emitting actions" {
  local program fixture
  for program in astro esbuild rollup tsup parcel rspack nuxt; do
    fixture="600 1 600 node node /repo/node_modules/.bin/$program build"
    run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE="$fixture" PS_EXIT=0 "$CHECK" --build /repo
    [ "$status" -eq 1 ] || { echo "$program went clear: $output"; false; }
    [[ "$output" == *"target=$program"* ]] || false
  done
  for fixture in 'node node /repo/node_modules/.bin/webpack --mode production' \
                 'node node /repo/node_modules/.bin/tsc'; do
    run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE="601 1 601 $fixture" PS_EXIT=0 "$CHECK" --build /repo
    [ "$status" -eq 1 ] || { echo "$fixture went clear: $output"; false; }
  done
  run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE='602 1 602 node node /repo/node_modules/.bin/webpack --help' PS_EXIT=0 "$CHECK" --build /repo
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE='603 1 603 node node /repo/node_modules/.bin/tsc --noEmit' PS_EXIT=0 "$CHECK" --build /repo
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "each known build tool defaults to busy but help and version stay clear" {
  local program option fixture
  for program in next vite turbo webpack webpack-cli tsc astro esbuild rollup tsup parcel rspack nuxt; do
    fixture="620 1 620 node node /repo/node_modules/.bin/$program input.js"
    run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE="$fixture" PS_EXIT=0 "$CHECK" --build /repo
    [ "$status" -eq 1 ] || { echo "$program implicit action went clear: $output"; false; }
    for option in --help --version; do
      fixture="621 1 621 node node /repo/node_modules/.bin/$program $option"
      run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE="$fixture" PS_EXIT=0 "$CHECK" --build /repo
      [ "$status" -eq 0 ] || { echo "$program $option went busy: $output"; false; }
    done
  done
}

@test "build check skips value-taking Node runtime options" {
  local option
  for option in -r --import --loader -C --env-file; do
    run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE="610 1 610 node node $option dependency /repo/node_modules/.bin/next build" PS_EXIT=0 "$CHECK" --build /repo
    [ "$status" -eq 1 ] || { echo "$option went clear: $output"; false; }
    [[ "$output" == *'target=next'* ]] || false
  done
  run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE='611 1 611 node node -r dependency /opt/app.js /repo next build' PS_EXIT=0 "$CHECK" --build /repo
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "absolute external bundlers and symlinked projects use the live process cwd" {
  local project="$SANDBOX/project" other="$SANDBOX/other" pid fixture invocation
  mkdir -p "$project" "$other"
  ln -s "$project" "$SANDBOX/project-link"
  cd "$project"
  pid="$(exec sh -c 'echo "$PPID"')"  # this shell's pid; bash 3.2 has no BASHPID
  for invocation in \
    'node node /npx-cache/node_modules/.bin/vite build' \
    'esbuild /opt/homebrew/bin/esbuild src/x.ts --outdir=dist' \
    'node node /opt/homebrew/lib/node_modules/vite/bin/vite.js build' \
    "node node $project/node_modules/.bin/next build" \
    'node node --experimental-loader ts-node/esm ./node_modules/.bin/next build'; do
    fixture="$pid 1 $pid $invocation"
    run env PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" PS_FIXTURE="$fixture" PS_EXIT=0 "$CHECK" --build "$SANDBOX/project-link"
    [ "$status" -eq 1 ] || { echo "missed $invocation: $output"; false; }
    [[ "$output" == *'BUSY'* ]] || false
  done
  cd "$other"
  fixture="$pid 1 $pid node node /opt/homebrew/lib/node_modules/vite/bin/vite.js build"
  run env PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" PS_FIXTURE="$fixture" PS_EXIT=0 "$CHECK" --build "$project"
  [ "$status" -eq 0 ] || { echo "other project was blocked: $output"; false; }
}

@test "Node value-taking runtime flags do not hide the build script" {
  local option
  for option in --experimental-loader --title --watch-path --inspect-port \
                --conditions --disable-warning --unhandled-rejections --dns-result-order; do
    run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE="610 1 610 node node $option value /repo/node_modules/.bin/next build" PS_EXIT=0 "$CHECK" --build /repo
    [ "$status" -eq 1 ] || { echo "$option went clear: $output"; false; }
    [[ "$output" == *'target=next'* ]] || false
  done
  run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE='611 1 611 node node --experimental-loader x /opt/app.js /repo next build' PS_EXIT=0 "$CHECK" --build /repo
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "unknown Node options cannot hide later build markers" {
  local option fixture project="$SANDBOX/project" other="$SANDBOX/other" pid
  for option in --env-file-if-exists --redirect-warnings --report-dir --input-type \
                --experimental-config-file --localstorage-file --future-option; do
    fixture="610 1 610 node node $option value /repo/node_modules/.bin/next build"
    run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE="$fixture" PS_EXIT=0 "$CHECK" --build /repo
    [ "$status" -eq 1 ] || { echo "$option went clear: $output"; false; }
    [[ "$output" == *'target=next'* ]] || { echo "$output"; false; }
  done
  fixture='611 1 611 node node --future-option value -- /repo/node_modules/.bin/vite build'
  run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE="$fixture" PS_EXIT=0 "$CHECK" --build /repo
  [ "$status" -eq 1 ] && [[ "$output" == *'target=vite'* ]] || { echo "$output"; false; }
  fixture='612 1 612 node node --future-option value /opt/app.js /repo ordinary'
  run env PATH="$BIN:/usr/bin:/bin" PS_FIXTURE="$fixture" PS_EXIT=0 "$CHECK" --build /repo
  [ "$status" -eq 0 ] || { echo "ordinary non-bundler blocked: $output"; false; }

  mkdir -p "$project" "$other"
  cd "$project"
  pid="$(exec sh -c 'echo "$PPID"')"  # this shell's pid; bash 3.2 has no BASHPID
  fixture="$pid 1 $pid node node --future-option value /opt/global/vite/bin/vite.js build"
  run env PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" PS_FIXTURE="$fixture" PS_EXIT=0 "$CHECK" --build "$project"
  [ "$status" -eq 1 ] && [[ "$output" == *'target=vite.js'* ]] || { echo "$output"; false; }
  cd "$other"
  run env PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" PS_FIXTURE="$fixture" PS_EXIT=0 "$CHECK" --build "$project"
  [ "$status" -eq 0 ] || { echo "other project blocked: $output"; false; }
}

@test "relative bundler paths are attributed to the live process cwd" {
  local project="$SANDBOX/project" other="$SANDBOX/other" pid fixture
  mkdir -p "$project" "$other"
  ln -s "$project" "$SANDBOX/alias"
  cd "$project"
  pid="$(exec sh -c 'echo "$PPID"')"  # this shell's pid; bash 3.2 has no BASHPID
  fixture="$pid 1 $pid node node ./node_modules/.bin/next build"
  run env PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" PS_FIXTURE="$fixture" PS_EXIT=0 "$CHECK" --build "$SANDBOX/alias"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *'target=next'* ]] || false
  cd "$other"
  run env PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" PS_FIXTURE="$fixture" PS_EXIT=0 "$CHECK" --build "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run env PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" PS_FIXTURE='999999999 1 999999999 node node ./node_modules/.bin/next build' PS_EXIT=0 "$CHECK" --build "$project"
  [ "$status" -eq 2 ] || { echo "unreadable cwd was treated as clear: $output"; false; }
  [[ "$output" == *'build process cwd unavailable'* && "$output" == *'pid=999999999'* && \
     "$output" == *'target=next'* && "$output" == *'cwd=<unavailable>'* && \
     "$output" == *"project=$project"* ]] || { echo "$output"; false; }
  run env PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" PS_FIXTURE="$fixture" PS_EXIT=0 "$CHECK" --build "$SANDBOX/missing"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'project cwd unavailable'* && "$output" == *'cwd=<not-probed>'* && \
     "$output" == *"project=$SANDBOX/missing"* ]] || { echo "$output"; false; }
}

@test "a live cwd-relative node build is not reported clear" {
  command -v node >/dev/null || skip "node is not on PATH"
  run python3 -I -B - "$SANDBOX" "$BIN" "$CHECK" <<'PY'
import os
import select
import shutil
import subprocess
import sys
from pathlib import Path

sandbox, bin_path, check = map(Path, sys.argv[1:])
project = sandbox / 'project'
script = project / 'node_modules' / '.bin' / 'next'
script.parent.mkdir(parents=True)
script.write_text("console.log('ready'); process.stdin.resume();\n")
child = subprocess.Popen([shutil.which('node'), './node_modules/.bin/next', 'build'],
                         cwd=project, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE)
try:
    assert select.select([child.stdout], [], [], 5)[0], 'fixture startup timed out'
    assert child.stdout.readline() == b'ready\n'
    snapshot = subprocess.check_output(
        ['ps', '-ww', '-p', str(child.pid), '-o', 'pid=,ppid=,pgid=,ucomm=,args='], text=True)
    environment = dict(os.environ, PATH=str(bin_path) + os.pathsep + os.environ['PATH'],
                       PS_FIXTURE=snapshot, PS_EXIT='0')
    result = subprocess.run([str(check), '--build', str(project)], env=environment,
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 1 and 'target=next' in result.stdout, (result, snapshot)
finally:
    child.stdin.close()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a live build launched from an absolute external cache is not clear" {
  command -v node >/dev/null || skip "node is not on PATH"
  run python3 -I -B - "$SANDBOX" "$BIN" "$CHECK" <<'PY'
import os
import select
import shutil
import subprocess
import sys
from pathlib import Path

sandbox, bin_path, check = map(Path, sys.argv[1:])
project = sandbox / 'project'
project.mkdir()
script = sandbox / 'npx-cache' / 'vite.js'
script.parent.mkdir()
script.write_text("console.log('ready'); process.stdin.resume();\n")
child = subprocess.Popen([shutil.which('node'), str(script), 'build'],
                         cwd=project, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE)
try:
    assert select.select([child.stdout], [], [], 5)[0], 'fixture startup timed out'
    assert child.stdout.readline() == b'ready\n'
    snapshot = subprocess.check_output(
        ['ps', '-ww', '-p', str(child.pid), '-o', 'pid=,ppid=,pgid=,ucomm=,args='], text=True)
    environment = dict(os.environ, PATH=str(bin_path) + os.pathsep + os.environ['PATH'],
                       PS_FIXTURE=snapshot, PS_EXIT='0')
    result = subprocess.run([str(check), '--build', str(project)], env=environment,
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 1 and 'target=vite.js' in result.stdout, (result, snapshot)
finally:
    child.stdin.close()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "build check recognizes a live node bundler from its kernel executable name" {
  command -v node >/dev/null || skip "node is not on PATH"
  run python3 -I -B - "$SANDBOX" "$BIN" "$CHECK" <<'PY'
import os
import select
import shutil
import subprocess
import sys
from pathlib import Path

sandbox, bin_path, check = map(Path, sys.argv[1:])
script = sandbox / 'node_modules' / 'vite' / 'bin' / 'vite.js'
script.parent.mkdir(parents=True)
script.write_text("console.log('ready'); process.stdin.resume();\n")
child = subprocess.Popen([shutil.which('node'), str(script), 'build'],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    assert select.select([child.stdout], [], [], 5)[0], 'fixture startup timed out'
    assert child.stdout.readline() == b'ready\n'
    snapshot = subprocess.check_output(
        ['ps', '-ww', '-p', str(child.pid), '-o', 'pid=,ppid=,pgid=,ucomm=,args='], text=True)
    environment = dict(os.environ, PATH=str(bin_path) + os.pathsep + os.environ['PATH'],
                       PS_FIXTURE=snapshot, PS_EXIT='0')
    result = subprocess.run([str(check), '--build', str(sandbox)], env=environment,
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 1 and 'target=vite.js' in result.stdout, (result, snapshot)
finally:
    child.stdin.close()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
}

@test "a failed process snapshot is an error rather than clear" {
  check_gate "" 3

  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR process-table snapshot unavailable"* ]] || false
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
  local file hits="" found files
  files="$(git -C "$REPO_ROOT" ls-files)" || {
    printf 'ERROR tracked source inventory unavailable\n' >&2
    return 1
  }
  [ -n "$files" ] || {
    printf 'ERROR tracked source inventory empty\n' >&2
    return 1
  }
  while IFS= read -r file; do
    case "$file" in
      notes/*|*/tests/*|*/fixtures/*) continue ;;
      # Historical record, not live behavior. The lessons log and the dated
      # design records quote the rejected probe in order to condemn it; audit
      # evidence, receipts, and captured runner output preserve what a past run
      # actually executed. Rewriting either to satisfy a source scan would
      # falsify the record, so they are out of scope for it. Every executing
      # surface — scripts, hooks, skills, commands, workflows, and the pasteable
      # runbooks — stays in scope.
      gotchas.md|audits/*|docs/specs/*|receipts/*|*/receipts/*|*.log|*.jsonl) continue ;;
    esac
    found="$(grep -nE "$UNSAFE_RE" "$REPO_ROOT/$file" 2>/dev/null || true)"
    [ -z "$found" ] || hits="${hits}${file}:${found}"$'\n'
  done <<< "$files"

  [ -z "$hits" ] || { printf '%s' "$hits"; false; }
}

@test "source scan refuses a gitless export and an empty tracked inventory" {
  local export_root="$SANDBOX/export"
  mkdir -p "$export_root/scripts/tests"
  cp "$BATS_TEST_FILENAME" "$export_root/scripts/tests/check-process-liveness.bats"

  run env GIT_CEILING_DIRECTORIES="$SANDBOX" bats --filter '^tracked live sources' \
    "$export_root/scripts/tests/check-process-liveness.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR tracked source inventory unavailable"* ]] || false

  git -C "$export_root" init -q
  run bats --filter '^tracked live sources' "$export_root/scripts/tests/check-process-liveness.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR tracked source inventory empty"* ]] || false
}
