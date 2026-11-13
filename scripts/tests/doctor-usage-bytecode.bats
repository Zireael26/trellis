#!/usr/bin/env bats
# Doctor's advisory usage probes run Python by shebang, outside the shared
# owner verifier. Neither their HOME cache nor their library may gain pyc files.
REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  export USAGE_STAGE="$BATS_TEST_TMPDIR/usage" USAGE_HOME="$BATS_TEST_TMPDIR/home"
  export USAGE_SCRATCH="$BATS_TEST_TMPDIR/scratch" USAGE_EVENTS="$BATS_TEST_TMPDIR/events"
  mkdir -p "$USAGE_STAGE/lib/usage_federation" "$USAGE_HOME" "$USAGE_SCRATCH"
  chmod 700 "$USAGE_HOME" "$USAGE_SCRATCH"
  printf '# fixture package\n' > "$USAGE_STAGE/lib/usage_federation/__init__.py"
  printf 'VALUE = 1\n' > "$USAGE_STAGE/lib/usage_federation/cli.py"
  cat > "$USAGE_STAGE/usage-federation.py" <<'PY'
#!/usr/bin/env -S python3 -S
import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'lib'))
from usage_federation import cli
with open(os.environ['USAGE_EVENTS'], 'a') as events:
    events.write(sys.argv[1] + ' ' + str(sys.dont_write_bytecode) + '\n')
if sys.argv[1] == 'doctor':
    print('{"store":{"available":false}}')
    sys.exit(5)
PY
  chmod 755 "$USAGE_STAGE/usage-federation.py"
  awk '/^hc_usage_cli\(\) \{/ { printing=1 } /^hc_usage_receipts\(\) \{/ { exit } printing { print }' \
    "$REPO_ROOT/scripts/doctor.sh" > "$BATS_TEST_TMPDIR/usage-function.bash"
  [ -s "$BATS_TEST_TMPDIR/usage-function.bash" ]
}

run_usage_probe() {
  run env -i "HOME=$USAGE_HOME" "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    "USAGE_EVENTS=$USAGE_EVENTS" "$BASH" --noprofile --norc -c '
      set -u
      SCRIPT_DIR=$1
      DOCTOR_SCRATCH_DIR=$2
      HC_WARN=1
      doctor_scratch_require() { return 0; }
      . "$3"
      hc_usage_cli "$4"
    ' doctor-usage-test "$USAGE_STAGE" "$USAGE_SCRATCH" \
      "$BATS_TEST_TMPDIR/usage-function.bash" "$BATS_TEST_TMPDIR/trellis"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [[ "$output" == *'usage-federation CLI validated end-to-end'* ]] || { echo "$output"; return 1; }
}

assert_no_python_cache() {
  local paths
  paths="$(find "$USAGE_HOME" "$USAGE_STAGE" \( -name __pycache__ -o -name '*.pyc' -o -path '*/Library/Caches/com.apple.python' \) -print)"
  [ -z "$paths" ] || { printf 'unexpected Python cache:\n%s\n' "$paths"; return 1; }
}

@test "usage help probes suppress bytecode for every route" {
  run_usage_probe
  for route in strip watch report receipt; do
    grep -Fxq "$route True" "$USAGE_EVENTS" || { echo "missing bytecode guard for $route"; false; }
  done
  assert_no_python_cache
}

@test "usage doctor probe suppresses bytecode in a private HOME and library" {
  run_usage_probe
  grep -Fxq 'doctor True' "$USAGE_EVENTS" || { echo 'missing bytecode guard for doctor'; false; }
  [ "$(wc -l < "$USAGE_EVENTS" | tr -d ' ')" -eq 5 ]
  assert_no_python_cache
}

@test "the real usage CLI probe leaves no Python cache in a private HOME" {
  rm -rf "$USAGE_STAGE/lib/usage_federation"
  cp -R "$REPO_ROOT/scripts/lib/usage_federation" "$USAGE_STAGE/lib/usage_federation"
  find "$USAGE_STAGE/lib/usage_federation" -type d -name __pycache__ -prune -exec rm -rf {} +
  cp "$REPO_ROOT/scripts/usage-federation.py" "$USAGE_STAGE/usage-federation.py"
  chmod 755 "$USAGE_STAGE/usage-federation.py"
  # The copied library resolves the release catalog relative to its own tree.
  # Supply the real catalog, otherwise doctor reports invalid configuration
  # before it can check the intentionally missing store.
  mkdir -p "$BATS_TEST_TMPDIR/core-rules/usage-federation"
  cp "$REPO_ROOT/core-rules/usage-federation/lane-catalog.json" \
    "$BATS_TEST_TMPDIR/core-rules/usage-federation/lane-catalog.json"
  run env -i "HOME=$USAGE_HOME" "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    "$BASH" --noprofile --norc -c '
      set -u
      SCRIPT_DIR=$1
      DOCTOR_SCRATCH_DIR=$2
      HC_WARN=1
      doctor_scratch_require() { return 0; }
      . "$3"
      hc_usage_cli "$4"
    ' doctor-usage-test "$USAGE_STAGE" "$USAGE_SCRATCH" \
      "$BATS_TEST_TMPDIR/usage-function.bash" "$BATS_TEST_TMPDIR/trellis"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ] || { echo "$output"; false; }
  case "$output" in
    'usage-federation CLI validated end-to-end'*|'usage-federation '*'help route failed validation') ;;
    *) echo "unexpected usage probe result: $output"; false ;;
  esac
  assert_no_python_cache
}
