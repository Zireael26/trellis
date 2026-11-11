#!/usr/bin/env bats
# Scanner libs run engines by absolute PATH path. An exported shell function
# (`BASH_FUNC_python3%%`) never answers for an engine or its parser, and
# osv.sh additionally refuses an osv-scanner that lives in the scanned tree and
# hands osv-scanner the config file it is given instead of letting it discover
# the tree's own osv-scanner.toml. Each stub produces a finding; a hijacked
# engine or parser produces none.

setup() {
  TEST_ROOT="$(mktemp -d)"
  PROJECT="$TEST_ROOT/project"
  BIN="$TEST_ROOT/bin"
  mkdir -p "$PROJECT" "$BIN"
  SCRIPT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LIB="$SCRIPT_ROOT/scripts/lib"
  OUT="$TEST_ROOT/out.jsonl"
  export OSV_ARGS_LOG="$TEST_ROOT/osv.args"

  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email "security-gate@trellis.test"
  git -C "$PROJECT" config user.name "trellis test"
  printf '%s\n' 'export const a = 1;' > "$PROJECT/a.ts"
  # osv.sh keeps findings only for tracked sources; the OSV stub reports this one.
  printf '%s\n' '{}' > "$PROJECT/package.json"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm seed

  cat > "$BIN/osv-scanner" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { echo "osv-scanner version: 2.6.0"; exit 0; }
printf '%s\n' "$@" > "$OSV_ARGS_LOG"
for a in "$@"; do dir="$a"; done
printf '{"results":[{"source":{"path":"%s/package.json","type":"lockfile"},"packages":[{"package":{"name":"fixture","version":"1.0","ecosystem":"npm"},"groups":[],"vulnerabilities":[{"id":"FIXTURE-HIGH","summary":"seeded","database_specific":{"severity":"HIGH"}}]}]}]}\n' "$dir"
exit 1
SH
  cat > "$BIN/semgrep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"results":[{"check_id":"fixture-rule","path":"a.ts","start":{"line":1},"extra":{"severity":"ERROR","message":"fixture"}}]}'
SH
  cat > "$BIN/gitleaks" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-path) printf '%s\n' '[{"RuleID":"fixture-rule","Description":"fixture","File":"a.ts","StartLine":1}]' > "$2"; shift 2 ;;
    *) shift ;;
  esac
done
exit 1
SH
  cat > "$BIN/garak" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report_prefix) prefix="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' '{"entry_type":"start_run setup","transient.run_id":"fixture"}' '{"entry_type":"init","run":"fixture"}' \
  '{"entry_type":"attempt","uuid":"u1","status":1,"probe_classname":"fixture.Probe","detector_results":{}}' \
  '{"entry_type":"attempt","uuid":"u1","status":2,"probe_classname":"fixture.Probe","detector_results":{"d":[1.0]}}' \
  '{"entry_type":"completion","run":"fixture"}' > "${prefix}.test.report.jsonl"
SH
  cat > "$BIN/llm" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"ok":1}'
SH
  cat > "$BIN/timeout" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--preserve-status" ] && shift
shift
exec "$@"
SH
  chmod +x "$BIN"/*
}

teardown() {
  rm -rf "$TEST_ROOT"
}

# Verify this Bash really imports modern exported-function syntax before using
# it as a purge oracle (macOS also ships an older Bash).
require_function_import() {
  run env 'BASH_FUNC_git%%=() { printf imported; }' bash -c 'git'
  [ "$status" -eq 0 ] && [ "$output" = imported ] || skip "Bash does not import BASH_FUNC_name%%"
}

# A python3 that swallows its script and prints nothing: a parser hijack.
PY_HIJACK='BASH_FUNC_python3%%=() { cat >/dev/null; }'

# A scanner/helper selected from the checkout must be refused before it runs,
# even when another scanner of the same name is available outside it.
plant_project_binary() {
  mkdir -p "$PROJECT/.tools"
  printf '#!/bin/sh\n: > "%s"\nexit 42\n' "$TEST_ROOT/project-binary-ran" > "$PROJECT/.tools/$1"
  chmod +x "$PROJECT/.tools/$1"
}

@test "semgrep.sh refuses a semgrep on PATH inside the project" {
  plant_project_binary semgrep
  run env PATH="$PROJECT/.tools:$BIN:$PATH" bash "$LIB/semgrep.sh" "$PROJECT" web-next "$OUT"
  [ "$status" -eq 2 ] || { echo "rc=$status; $output"; false; }
  [ ! -e "$TEST_ROOT/project-binary-ran" ]
}

@test "gitleaks.sh refuses a gitleaks on PATH inside the project" {
  plant_project_binary gitleaks
  run env PATH="$PROJECT/.tools:$BIN:$PATH" bash "$LIB/gitleaks.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 2 ] || { echo "rc=$status; $output"; false; }
  [ ! -e "$TEST_ROOT/project-binary-ran" ]
}

@test "garak.sh refuses a garak on PATH inside the project" {
  plant_project_binary garak
  run env PATH="$PROJECT/.tools:$BIN:$PATH" SECURITY_GATE_GARAK_TARGET=openai:test \
    bash "$LIB/garak.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 2 ] || { echo "rc=$status; $output"; false; }
  [ ! -e "$TEST_ROOT/project-binary-ran" ]
}

@test "garak.sh refuses a timeout on PATH inside the project" {
  plant_project_binary timeout
  run env PATH="$PROJECT/.tools:$BIN:$PATH" SECURITY_GATE_GARAK_TARGET=openai:test \
    bash "$LIB/garak.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 2 ] || { echo "rc=$status; $output"; false; }
  [ ! -e "$TEST_ROOT/project-binary-ran" ]
}

@test "gitleaks.sh refuses a git helper linked into the project" {
  plant_project_binary git
  ln -s "$PROJECT/.tools/git" "$BIN/git"
  run env PATH="$BIN:$PATH" bash "$LIB/gitleaks.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 2 ] || { echo "rc=$status; $output"; false; }
  [ ! -e "$TEST_ROOT/project-binary-ran" ]
}

@test "semgrep.sh refuses a mktemp helper linked into the project" {
  plant_project_binary mktemp
  ln -s "$PROJECT/.tools/mktemp" "$BIN/mktemp"
  run env PATH="$BIN:$PATH" bash "$LIB/semgrep.sh" "$PROJECT" web-next "$OUT"
  [ "$status" -eq 2 ] || { echo "rc=$status; $output"; false; }
  [ ! -e "$TEST_ROOT/project-binary-ran" ]
}

@test "llm-call.sh refuses an llm linked into the project" {
  plant_project_binary llm
  mv "$BIN/llm" "$BIN/safe-llm"
  ln -s "$PROJECT/.tools/llm" "$BIN/llm"
  printf 'system\n' > "$TEST_ROOT/prompt.md"
  printf '{}\n' > "$TEST_ROOT/input.json"
  run env PATH="$BIN:$PATH" LLM_PROVIDER=anthropic bash "$LIB/llm-call.sh" \
    "$TEST_ROOT/prompt.md" "$TEST_ROOT/input.json" "$OUT" "$PROJECT"
  [ "$status" -eq 2 ] || { echo "rc=$status; $output"; false; }
  [ ! -e "$TEST_ROOT/project-binary-ran" ]
}

@test "llm-call.sh refuses a timeout on PATH inside the project" {
  plant_project_binary timeout
  printf 'system\n' > "$TEST_ROOT/prompt.md"
  printf '{}\n' > "$TEST_ROOT/input.json"
  run env PATH="$PROJECT/.tools:$BIN:$PATH" LLM_PROVIDER=anthropic bash "$LIB/llm-call.sh" \
    "$TEST_ROOT/prompt.md" "$TEST_ROOT/input.json" "$OUT" "$PROJECT"
  [ "$status" -eq 2 ] || { echo "rc=$status; $output"; false; }
  [ ! -e "$TEST_ROOT/project-binary-ran" ]
}

@test "engine resolution refuses an outside script with a project interpreter" {
  local scripts="$TEST_ROOT/hostile-shebang"
  mkdir -p "$scripts" "$PROJECT/.tools"
  # Native on purpose: refusal must come from containment, not the separate
  # rule that rejects script shims as interpreters.
  cp /bin/sh "$PROJECT/.tools/interpreter"
  chmod +x "$PROJECT/.tools/interpreter"
  printf '#!%s\n' "$PROJECT/.tools/interpreter" > "$scripts/semgrep"
  chmod +x "$scripts/semgrep"
  run env PATH="$scripts:$BIN:$PATH" bash -p -c 'source "$1/engine.sh"; sg_resolve_engine semgrep "$2"' _ "$LIB" "$PROJECT"
  [ "$status" -eq 3 ] || { echo "rc=$status; $output"; false; }
}

@test "engine resolution refuses env interpreters linked into the project" {
  local scripts="$TEST_ROOT/hostile-env"
  mkdir -p "$scripts" "$PROJECT/.tools"
  cp /bin/sh "$PROJECT/.tools/interpreter"
  chmod +x "$PROJECT/.tools/interpreter"
  ln -s "$PROJECT/.tools/interpreter" "$scripts/hostile-interpreter"
  printf '#!/usr/bin/env hostile-interpreter\n' > "$scripts/semgrep"
  chmod +x "$scripts/semgrep"
  run env PATH="$scripts:$BIN:$PATH" bash -p -c 'source "$1/engine.sh"; sg_resolve_engine semgrep "$2"' _ "$LIB" "$PROJECT"
  [ "$status" -eq 3 ] || { echo "rc=$status; $output"; false; }
}

@test "engine resolution refuses a symlink chain through the project" {
  local links="$TEST_ROOT/hostile-links"
  mkdir -p "$links" "$PROJECT/.tools"
  ln -s "$BIN/semgrep" "$PROJECT/.tools/bounce"
  ln -s "$PROJECT/.tools/bounce" "$links/semgrep"
  run env PATH="$links:$BIN:$PATH" bash -p -c 'source "$1/engine.sh"; sg_resolve_engine semgrep "$2"' _ "$LIB" "$PROJECT"
  [ "$status" -eq 3 ] || { echo "rc=$status; $output"; false; }
}

@test "osv.sh purges exported git and ignores an exported python3 function" {
  require_function_import
  run env PATH="$BIN:$PATH" PURGE_MARK="$TEST_ROOT/purge-mark" "$PY_HIJACK" \
    'BASH_FUNC_git%%=() { : > "$PURGE_MARK"; return 1; }' bash "$LIB/osv.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$TEST_ROOT/purge-mark" ]
  grep -q 'FIXTURE-HIGH' "$OUT"
}

@test "osv.sh purges exported mktemp and ignores an exported osv-scanner function" {
  require_function_import
  run env PATH="$BIN:$PATH" PURGE_MARK="$TEST_ROOT/purge-mark" \
    'BASH_FUNC_mktemp%%=() { : > "$PURGE_MARK"; return 1; }' \
    'BASH_FUNC_osv-scanner%%=() { printf "%s\n" "{\"results\":[]}"; }' \
    bash "$LIB/osv.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$TEST_ROOT/purge-mark" ]
  grep -q 'FIXTURE-HIGH' "$OUT"
}

@test "osv.sh refuses an osv-scanner from a PATH directory inside the project" {
  mkdir -p "$PROJECT/.tools"
  printf '#!/usr/bin/env bash\n: > "%s/pwned"\nprintf "%%s\\n" "{\\"results\\":[]}"\n' "$TEST_ROOT" > "$PROJECT/.tools/osv-scanner"
  chmod +x "$PROJECT/.tools/osv-scanner"
  run env PATH="$PROJECT/.tools:$BIN:$PATH" bash "$LIB/osv.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"osv-scanner"*"$PROJECT/.tools/osv-scanner"* ]] || { echo "$output"; false; }
  [ ! -e "$TEST_ROOT/pwned" ]
}

@test "osv.sh refuses an osv-scanner symlinked into the project" {
  mkdir -p "$PROJECT/.tools" "$TEST_ROOT/linkbin"
  printf '#!/usr/bin/env bash\n: > "%s/pwned"\n' "$TEST_ROOT" > "$PROJECT/.tools/osv-scanner"
  chmod +x "$PROJECT/.tools/osv-scanner"
  ln -s "$PROJECT/.tools/osv-scanner" "$TEST_ROOT/linkbin/osv-scanner"
  run env PATH="$TEST_ROOT/linkbin:$BIN:$PATH" bash "$LIB/osv.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 2 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"resolves inside the scanned project"* ]] || { echo "$output"; false; }
  [ ! -e "$TEST_ROOT/pwned" ]
}

@test "osv.sh passes its config file as --config" {
  : > "$TEST_ROOT/osv-config.toml"
  run env PATH="$BIN:$PATH" bash "$LIB/osv.sh" "$PROJECT" "$OUT" --config "$TEST_ROOT/osv-config.toml"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx -- '--config' "$OSV_ARGS_LOG"
  grep -qx -- "$TEST_ROOT/osv-config.toml" "$OSV_ARGS_LOG"
}

@test "semgrep.sh purges exported mktemp and ignores an exported python3 function" {
  require_function_import
  run env PATH="$BIN:$PATH" PURGE_MARK="$TEST_ROOT/purge-mark" "$PY_HIJACK" \
    'BASH_FUNC_mktemp%%=() { : > "$PURGE_MARK"; return 1; }' \
    bash "$LIB/semgrep.sh" "$PROJECT" web-next "$OUT"
  [ "$status" -eq 0 ] && [ ! -e "$TEST_ROOT/purge-mark" ] || { echo "rc=$status; $output"; false; }
  grep -q 'fixture-rule' "$OUT" || { echo "rc=$status; $output"; false; }
}

@test "gitleaks.sh purges exported git and ignores an exported python3 function" {
  require_function_import
  run env PATH="$BIN:$PATH" PURGE_MARK="$TEST_ROOT/purge-mark" "$PY_HIJACK" \
    'BASH_FUNC_git%%=() { : > "$PURGE_MARK"; return 1; }' \
    bash "$LIB/gitleaks.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 0 ] && [ ! -e "$TEST_ROOT/purge-mark" ] || { echo "rc=$status; $output"; false; }
  grep -q 'fixture-rule' "$OUT" || { echo "rc=$status; $output"; false; }
}

@test "garak.sh purges exported mkdir and ignores an exported python3 function" {
  require_function_import
  run env PATH="$BIN:$PATH" PURGE_MARK="$TEST_ROOT/purge-mark" "$PY_HIJACK" \
    'BASH_FUNC_mkdir%%=() { : > "$PURGE_MARK"; return 1; }' SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    bash "$LIB/garak.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 0 ] && [ ! -e "$TEST_ROOT/purge-mark" ] || { echo "rc=$status; $output"; false; }
  grep -q 'fixture.Probe' "$OUT" || { echo "rc=$status; $output"; false; }
}

@test "llm-call.sh purges exported cat and ignores an exported timeout function" {
  require_function_import
  printf 'system\n' > "$TEST_ROOT/prompt.md"
  printf '{}\n' > "$TEST_ROOT/input.json"
  run env PATH="$BIN:$PATH" LLM_PROVIDER=anthropic PURGE_MARK="$TEST_ROOT/purge-mark" \
    'BASH_FUNC_cat%%=() { : > "$PURGE_MARK"; return 1; }' \
    'BASH_FUNC_timeout%%=() { printf "%s\n" "{\"hijacked\":1}"; }' \
    bash "$LIB/llm-call.sh" "$TEST_ROOT/prompt.md" "$TEST_ROOT/input.json" "$OUT" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [ ! -e "$TEST_ROOT/purge-mark" ]
  grep -qx '{"ok":1}' "$OUT"
}

@test "osv.sh never imports a module from the scanned tree" {
  printf 'import sys\nsys.exit(0)\n' > "$PROJECT/json.py"
  run env PATH="$BIN:$PATH" bash -c 'cd "$1" && shift && exec bash "$@"' _ "$PROJECT" "$LIB/osv.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q 'FIXTURE-HIGH' "$OUT"
}

@test "OSV no-sources parser invokes the vetted interpreter with isolation" {
  command -v cc >/dev/null || skip "a C compiler is needed for the native interpreter probe"
  local real pybin="$TEST_ROOT/python-probe"
  real="$(python3 -I -c 'import os,sys; print(os.path.realpath(sys.executable))')"
  mkdir -p "$pybin"
  cat > "$TEST_ROOT/python-probe.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
int main(int argc, char **argv) {
  char path[PATH_MAX];
  if (argc == 4 && !strcmp(argv[1], "-I") && !strcmp(argv[2], "-c") &&
      !strcmp(argv[3], "import sys; print(sys.executable)")) {
    if (!realpath(argv[0], path)) return 2;
    puts(path);
    return 0;
  }
  FILE *log = fopen(getenv("PYTHON_PROBE_LOG"), "a");
  if (!log) return 2;
  fprintf(log, "%s %s\n", argc > 1 ? argv[1] : "", argc > 2 ? argv[2] : "");
  fclose(log);
  argv[0] = getenv("REAL_PYTHON");
  execv(argv[0], argv);
  return 2;
}
C
  cc -o "$pybin/python3" "$TEST_ROOT/python-probe.c"
  cat > "$BIN/osv-scanner" <<'SH'
#!/bin/sh
[ "${1:-}" != --version ] || { echo 'osv-scanner version: 2.6.0'; exit 0; }
echo 'End status: 1 dirs visited, 1 inodes visited, 0 Extract calls, 1ms elapsed' >&2
echo 'No package sources found, --help for usage information.' >&2
exit 128
SH
  chmod +x "$BIN/osv-scanner"
  run env PATH="$pybin:$BIN:$PATH" REAL_PYTHON="$real" PYTHON_PROBE_LOG="$TEST_ROOT/python.args" \
    bash "$LIB/osv.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  grep -qx -- '-I -' "$TEST_ROOT/python.args" || { echo "no-sources parser was not isolated"; false; }
}

@test "wrappers invoke the checked engine path even if PATH later changes" {
  local instrumented="$TEST_ROOT/path-instrumented" wrapper engine
  mkdir -p "$instrumented" "$PROJECT/.tools"
  cp "$LIB/engine.sh" "$instrumented/engine.sh"
  for engine in semgrep gitleaks garak llm; do
    printf '#!/bin/sh\n: > "$UNSAFE_MARK"\nexit 42\n' > "$PROJECT/.tools/$engine"
    chmod +x "$PROJECT/.tools/$engine"
  done
  for wrapper in semgrep gitleaks garak llm-call; do
    # Simulate a PATH change after resolution, immediately before invocation.
    python3 -I - "$LIB/$wrapper.sh" "$instrumented/$wrapper.sh" "$wrapper" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text()
anchors = {
    "semgrep": '# --metrics off: no telemetry.\n',
    "gitleaks": '# Gitleaks exits 1 when leaks are found; that is a successful scanner run.\n',
    "garak": '# Garak writes a JSONL report under the report dir; capture its status and path.\n',
    "llm-call": '# SAFETY: SECURITY_GATE_LLM_TIMEOUT_S, default 120 seconds per the env contract above, bounds external provider I/O.\n',
}
anchor = anchors[sys.argv[3]]
assert src.count(anchor) == 1
pathlib.Path(sys.argv[2]).write_text(src.replace(anchor, anchor + 'PATH="$PATH_INJECT:$PATH"\n', 1))
PY
    local args=("$PROJECT" "$OUT")
    case "$wrapper" in
      semgrep) args=("$PROJECT" web-next "$OUT") ;;
      llm-call) printf 'system\n' > "$TEST_ROOT/prompt.md"; printf '{}\n' > "$TEST_ROOT/input.json";
                args=("$TEST_ROOT/prompt.md" "$TEST_ROOT/input.json" "$OUT" "$PROJECT") ;;
    esac
    run env PATH="$BIN:$PATH" PATH_INJECT="$PROJECT/.tools" UNSAFE_MARK="$TEST_ROOT/bare-engine-ran" \
      SECURITY_GATE_GARAK_TARGET=openai:test LLM_PROVIDER=anthropic \
      bash "$instrumented/$wrapper.sh" "${args[@]}"
    [ "$status" -eq 0 ] || { echo "$wrapper: rc=$status; $output"; false; }
    [ ! -e "$TEST_ROOT/bare-engine-ran" ] || { echo "$wrapper used PATH after resolution"; false; }
  done
}

@test "initial function purge protects calls before the general purge" {
  require_function_import
  local instrumented="$TEST_ROOT/instrumented" wrapper
  mkdir -p "$instrumented"
  cp "$LIB/engine.sh" "$instrumented/engine.sh"
  for wrapper in osv semgrep gitleaks garak llm-call; do
    # Exercise each initial-purge name in the interval before the general
    # purge. This is deliberately instrumented: the current scripts do not
    # otherwise call those bare names in that interval.
    python3 -I - "$LIB/$wrapper.sh" "$instrumented/$wrapper.sh" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text()
anchor = 'builtin unset POSIXLY_CORRECT\nfor _sg_fn'
assert src.count(anchor) == 1
probe = ('builtin unset POSIXLY_CORRECT\n'
         'type -P bash >/dev/null || :\ncommand true\ncompgen -A function >/dev/null || :\n'
         'set +o posix\nunset -v _sg_probe_unused\nfor _sg_fn')
pathlib.Path(sys.argv[2]).write_text(src.replace(anchor, probe))
PY
    local args=("$PROJECT" "$OUT")
    case "$wrapper" in
      semgrep) args=("$PROJECT" web-next "$OUT") ;;
      llm-call) printf 'system\n' > "$TEST_ROOT/prompt.md"; printf '{}\n' > "$TEST_ROOT/input.json";
                args=("$TEST_ROOT/prompt.md" "$TEST_ROOT/input.json" "$OUT" "$PROJECT") ;;
    esac
    run env PATH="$BIN:$PATH" PURGE_MARK="$TEST_ROOT/initial-purge-ran" LLM_PROVIDER=anthropic \
      SECURITY_GATE_GARAK_TARGET=openai:test \
      'BASH_FUNC_type%%=() { printf type >> "$PURGE_MARK"; return 0; }' \
      'BASH_FUNC_command%%=() { printf command >> "$PURGE_MARK"; return 0; }' \
      'BASH_FUNC_compgen%%=() { printf compgen >> "$PURGE_MARK"; return 0; }' \
      'BASH_FUNC_set%%=() { printf set >> "$PURGE_MARK"; return 0; }' \
      'BASH_FUNC_unset%%=() { printf unset >> "$PURGE_MARK"; return 0; }' \
      bash "$instrumented/$wrapper.sh" "${args[@]}"
    [ "$status" -eq 0 ] || { echo "$wrapper: rc=$status; $output"; false; }
    [ ! -e "$TEST_ROOT/initial-purge-ran" ] || { echo "$wrapper: early purge was bypassed"; false; }
  done
}

@test "osv.sh: an exported builtin function cannot cut the scan short" {
  run env PATH="$BIN:$PATH" 'BASH_FUNC_builtin%%=() { exit 0; }' bash "$LIB/osv.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q 'FIXTURE-HIGH' "$OUT"
}

# A pyenv-style shim outside the project that picks its interpreter from the
# cwd's .python-version or PYENV_VERSION, as the real pyenv shim does, and a
# "version" that is hostile. The shim itself is trusted; its choice is not.
pyenv_shim_fixture() {
  REAL_PYTHON="$(python3 -I -c 'import os, sys; print(os.path.realpath(sys.executable))')"
  SHIMS="$TEST_ROOT/shims"
  FAKE_PYENV="$TEST_ROOT/pyenv"
  HOSTILE_MARK="$TEST_ROOT/hostile-python-ran"
  mkdir -p "$SHIMS" "$FAKE_PYENV/versions/hostile/bin"
  printf '#!/bin/sh\n: > "%s"\necho "baseline-row: accepted"\nexit 0\n' "$HOSTILE_MARK" \
    > "$FAKE_PYENV/versions/hostile/bin/python3"
  cat > "$SHIMS/python3" <<SH
#!/usr/bin/env bash
version="\${PYENV_VERSION:-}"
[ -n "\$version" ] || [ ! -f .python-version ] || version="\$(cat .python-version)"
[ -z "\$version" ] || exec "$FAKE_PYENV/versions/\$version/bin/python3" "\$@"
exec "$REAL_PYTHON" "\$@"
SH
  chmod +x "$SHIMS/python3" "$FAKE_PYENV/versions/hostile/bin/python3"
  printf 'hostile\n' > "$PROJECT/.python-version"
}

@test "a script engine cannot run a project-selected interpreter through a shim" {
  pyenv_shim_fixture
  local engines="$TEST_ROOT/shimmed-engine" kind failures=0
  mkdir -p "$engines"
  for kind in env direct; do
    if [ "$kind" = env ]; then
      printf '#!/usr/bin/env python3\nprint("{}")\n' > "$engines/semgrep"
    else
      printf '#!%s/python3\nprint("{}")\n' "$SHIMS" > "$engines/semgrep"
    fi
    chmod +x "$engines/semgrep"
    run env PATH="$engines:$SHIMS:$BIN:$PATH" bash -p -c 'source "$1/engine.sh"; sg_resolve_engine semgrep "$2"' _ "$LIB" "$PROJECT"
    [ "$status" -eq 3 ] || { echo "$kind: resolver accepted shim rc=$status; $output"; failures=1; }
    run env PATH="$engines:$SHIMS:$BIN:$PATH" bash -c 'cd "$1" && shift && exec bash "$@"' _ "$PROJECT" \
      "$LIB/semgrep.sh" "$PROJECT" web-next "$OUT"
    if [ -e "$HOSTILE_MARK" ]; then
      echo "$kind: project-selected interpreter ran"
      mv "$HOSTILE_MARK" "$TEST_ROOT/hostile-ran-$kind"
      failures=1
    fi
    [ "$status" -eq 2 ] || { echo "$kind: rc=$status; $output"; failures=1; }
  done
  [ "$failures" -eq 0 ]
}

@test "sg_resolve_python runs the real interpreter behind a shim, not the project's choice" {
  # Inversion (review r4 Sol R4-N1): the resolver returned the shim, which
  # then took .python-version or PYENV_VERSION from the checkout's cwd.
  pyenv_shim_fixture
  run env PATH="$SHIMS:$PATH" PYENV_VERSION=hostile bash -c \
    'cd "$1" && source "$2/engine.sh" && sg_resolve_python "$1"' _ "$PROJECT" "$LIB"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$REAL_PYTHON" ] || { echo "resolved: $output, want $REAL_PYTHON"; false; }
  [ ! -e "$HOSTILE_MARK" ] || { echo "the project-chosen interpreter ran"; false; }
}

@test "sg_resolve_python refuses an interpreter that reports a script as itself" {
  mkdir -p "$TEST_ROOT/scriptbin"
  printf '#!/bin/sh\necho "$0"\n' > "$TEST_ROOT/scriptbin/python3"
  chmod +x "$TEST_ROOT/scriptbin/python3"
  run env PATH="$TEST_ROOT/scriptbin:$PATH" bash -c \
    'source "$2/engine.sh" && sg_resolve_python "$1"' _ "$PROJECT" "$LIB"
  [ "$status" -eq 3 ] || { echo "rc=$status: $output"; false; }
}

@test "osv.sh parses with the real interpreter behind a shim the project steers" {
  pyenv_shim_fixture
  run env PATH="$SHIMS:$BIN:$PATH" bash -c 'cd "$1" && shift && exec bash "$@"' _ "$PROJECT" "$LIB/osv.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$HOSTILE_MARK" ] || { echo "the project-chosen interpreter ran"; false; }
  grep -q 'FIXTURE-HIGH' "$OUT"
}

@test "the baseline wrappers parse with the real interpreter behind a shim" {
  pyenv_shim_fixture
  run env PATH="$SHIMS:$BIN:$PATH" bash -c 'cd "$1" && shift && exec bash "$@"' _ "$PROJECT" "$LIB/semgrep.sh" "$PROJECT" web-next "$OUT"
  [ ! -e "$HOSTILE_MARK" ] || { echo "semgrep.sh ran the project-chosen interpreter"; false; }
  grep -q 'fixture-rule' "$OUT"
  run env PATH="$SHIMS:$BIN:$PATH" bash -c 'cd "$1" && shift && exec bash "$@"' _ "$PROJECT" "$LIB/gitleaks.sh" "$PROJECT" "$OUT"
  [ ! -e "$HOSTILE_MARK" ] || { echo "gitleaks.sh ran the project-chosen interpreter"; false; }
  grep -q 'fixture-rule' "$OUT"
  run env PATH="$SHIMS:$BIN:$PATH" SECURITY_GATE_GARAK_TARGET="openai:test-model" bash -c 'cd "$1" && shift && exec bash "$@"' _ "$PROJECT" "$LIB/garak.sh" "$PROJECT" "$OUT"
  [ ! -e "$HOSTILE_MARK" ] || { echo "garak.sh ran the project-chosen interpreter"; false; }
  grep -q 'fixture.Probe' "$OUT"
}

@test "sg_resolve_python discovers under an empty environment: no inherited shim control runs" {
  # Inversion (review r5 Astra R5-F1): PYENV_HOOK_PATH (and any other shim
  # control the resolver did not list) reached the shim, so a project hook ran
  # during discovery. Discovery now runs under env -i.
  REAL_PYTHON="$(python3 -I -c 'import os, sys; print(os.path.realpath(sys.executable))')"
  mkdir -p "$TEST_ROOT/hookshims" "$PROJECT/hooks/exec"
  # pyenv-exec sources every <hook-path>/exec/*.bash before it runs python.
  cat > "$TEST_ROOT/hookshims/python3" <<SH
#!/usr/bin/env bash
for dir in \${PYENV_HOOK_PATH//:/ }; do
  for hook in "\$dir"/exec/*.bash; do [ ! -f "\$hook" ] || source "\$hook"; done
done
[ -z "\${SHIM_STEER:-}" ] || : > "$TEST_ROOT/steered"
printf '%s\n' "\$0" > "$TEST_ROOT/shim-argv0"
exec "$REAL_PYTHON" "\$@"
SH
  chmod +x "$TEST_ROOT/hookshims/python3"
  printf ': > "%s"\n' "$TEST_ROOT/project-hook-ran" > "$PROJECT/hooks/exec/steal.bash"
  mkdir -p "$TEST_ROOT/linkbin"
  ln -s "$TEST_ROOT/hookshims/python3" "$TEST_ROOT/linkbin/python3"
  run env PATH="$TEST_ROOT/linkbin:$PATH" PYENV_HOOK_PATH="$PROJECT/hooks" SHIM_STEER=1 bash -c \
    'cd "$1" && source "$2/engine.sh" && sg_resolve_python "$1"' _ "$PROJECT" "$LIB"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$REAL_PYTHON" ] || { echo "resolved: $output, want $REAL_PYTHON"; false; }
  [ ! -e "$TEST_ROOT/project-hook-ran" ] || { echo "a project hook ran during discovery"; false; }
  [ ! -e "$TEST_ROOT/steered" ] || { echo "an inherited variable reached the shim"; false; }
  # Inversion (review r5 Sol R5-N3): the checked target runs, not the lexical
  # symlink path whose links could change in between.
  local checked
  checked="$(cd -P "$TEST_ROOT/hookshims" && pwd -P)/python3"
  [ "$(cat "$TEST_ROOT/shim-argv0")" = "$checked" ] || { echo "ran: $(cat "$TEST_ROOT/shim-argv0"), want $checked"; false; }
}

@test "an alternate spelling of the project path is still the project" {
  # Inversion (review r5 Sol R5-N1): containment compared Bash-cached path
  # spellings case-sensitively; on a case-insensitive volume projectroot and
  # ProjectRoot are one directory, and its python3 ran.
  local root="$TEST_ROOT/ProjectRoot" alias="$TEST_ROOT/projectroot"
  mkdir -p "$root/.tools"
  [ "$root" -ef "$alias" ] || skip "volume is case-sensitive"
  REAL_PYTHON="$(python3 -I -c 'import os, sys; print(os.path.realpath(sys.executable))')"
  printf '#!/bin/sh\n: > "%s"\nexec "%s" "$@"\n' "$TEST_ROOT/project-python-ran" "$REAL_PYTHON" > "$root/.tools/python3"
  chmod +x "$root/.tools/python3"
  # A PATH entry naming the project by another spelling is dropped.
  run env PATH="$alias/.tools:$PATH" bash -c 'source "$2/engine.sh" && sg_resolve_python "$1"' _ "$root" "$LIB"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$REAL_PYTHON" ] || { echo "resolved: $output"; false; }
  [ ! -e "$TEST_ROOT/project-python-ran" ] || { echo "the project's python3 ran"; false; }
  # An outside symlink whose target spells the project differently is refused.
  mkdir -p "$TEST_ROOT/casebin"
  ln -s "$alias/.tools/python3" "$TEST_ROOT/casebin/python3"
  run env PATH="$TEST_ROOT/casebin:$PATH" bash -c 'source "$2/engine.sh" && sg_resolve_python "$1"' _ "$root" "$LIB"
  [ "$status" -eq 3 ] || { echo "rc=$status: $output"; false; }
  [ ! -e "$TEST_ROOT/project-python-ran" ] || { echo "the project's python3 ran"; false; }
  run bash -c 'source "$3/engine.sh" && sg_inside "$1/.tools/python3" "$2"' _ "$alias" "$root" "$LIB"
  [ "$status" -eq 0 ]
}

@test "a symlink spelling of the project is still inside on every filesystem" {
  local alias="$TEST_ROOT/project-alias" real
  ln -s "$PROJECT" "$alias"
  mkdir -p "$PROJECT/.tools"
  real="$(python3 -I -c 'import os,sys; print(os.path.realpath(sys.executable))')"
  printf '#!/bin/sh\n: > "%s"\nexec "%s" "$@"\n' "$TEST_ROOT/alias-python-ran" "$real" > "$PROJECT/.tools/python3"
  chmod +x "$PROJECT/.tools/python3"
  run env PATH="$PROJECT/.tools:$PATH" bash -p -c 'source "$1/engine.sh"; sg_resolve_python "$2"' _ "$LIB" "$alias"
  [ "$status" -eq 0 ] && [ "$output" = "$real" ] || { echo "rc=$status; $output"; false; }
  [ ! -e "$TEST_ROOT/alias-python-ran" ]
}

@test "sg_resolve_python accepts only a native executable, not text without a shebang" {
  # Inversion (review r5 Astra R5-F2): only a leading #! was refused, so an
  # executable text file Bash would interpret passed as the interpreter.
  mkdir -p "$TEST_ROOT/textbin"
  printf 'echo not python\n' > "$TEST_ROOT/text-exe"
  chmod +x "$TEST_ROOT/text-exe"
  printf '#!/bin/sh\necho "%s"\n' "$TEST_ROOT/text-exe" > "$TEST_ROOT/textbin/python3"
  chmod +x "$TEST_ROOT/textbin/python3"
  run env PATH="$TEST_ROOT/textbin:$PATH" bash -c 'source "$2/engine.sh" && sg_resolve_python "$1"' _ "$PROJECT" "$LIB"
  [ "$status" -eq 3 ] || { echo "rc=$status: $output"; false; }
}

@test "sg_inside ends quickly on relative and odd inputs" {
  # Inversion (review r6 Sol R6-N1): for a relative path ${p%/*} made no
  # progress, so a non-contained relative input never terminated.
  mkdir -p "$TEST_ROOT/elsewhere/sub"
  local input rc
  for input in relative a/b/c ./x ../y '' / //double//slashes; do
    run perl -e 'alarm 5; exec @ARGV' bash -c 'cd "$1" && source "$2/engine.sh" && sg_inside "$3" "$4"' _ \
      "$TEST_ROOT/elsewhere/sub" "$LIB" "$input" "$PROJECT"
    [ "$status" -eq 1 ] || { echo "input '$input': rc=$status (142 = killed by the 5s alarm)"; false; }
  done
  # A relative path that does name something inside the project still counts.
  mkdir -p "$PROJECT/inner"
  run perl -e 'alarm 5; exec @ARGV' bash -c 'cd "$1" && source "$2/engine.sh" && sg_inside inner/file "$1"' _ "$PROJECT" "$LIB"
  [ "$status" -eq 0 ] || { echo "rc=$status"; false; }
}

@test "a project path deeper than any walk limit is still inside the project" {
  # Inversion (security review of the R6-N1 fix): a 256-ancestor cap returned
  # "outside" for anything nested deeper, so a deep project python3 was trusted.
  local deep="$PROJECT" i
  for i in $(seq 300); do deep="$deep/d"; done
  run perl -e 'alarm 20; exec @ARGV' bash -c 'source "$1/engine.sh" && sg_inside "$2/python3" "$3"' _ "$LIB" "$deep" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "rc=$status: a 300-deep project path was not inside"; false; }

  # End to end: a python3 300 directories down in the project, first on PATH.
  mkdir -p "$deep"
  REAL_PYTHON="$(python3 -I -c 'import os, sys; print(os.path.realpath(sys.executable))')"
  printf '#!/bin/sh\n: > "%s"\nexec "%s" "$@"\n' "$TEST_ROOT/deep-python-ran" "$REAL_PYTHON" > "$deep/python3"
  chmod +x "$deep/python3"
  run perl -e 'alarm 60; exec @ARGV' env PATH="$deep:$PATH" bash -c 'source "$2/engine.sh" && sg_resolve_python "$1"' _ "$PROJECT" "$LIB"
  [ "$status" -eq 0 ] || { echo "rc=$status: $output"; false; }
  [ "$output" = "$REAL_PYTHON" ] || { echo "resolved: $output"; false; }
  [ ! -e "$TEST_ROOT/deep-python-ran" ] || { echo "the deep project python3 ran"; false; }
}
