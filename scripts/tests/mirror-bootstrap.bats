#!/usr/bin/env bats
# Reuse only the existing stable-release fixture helpers, never its test cases.
# Each case commits and seals its own synthetic release before launcher entry.
fixture_helpers="$(awk '/^@test / { exit } { print }' "$BATS_TEST_DIRNAME/sync-to-template-dry-run.bats")"
[ -n "$fixture_helpers" ] || exit 1
eval "$fixture_helpers"
unset fixture_helpers

# Test containment independently of launcher provenance: these calls deliberately
# supply identity fields themselves, and make no authentication claim.
check_scratch_candidate() {
  local candidate="$1" expected="$2" release_status
  run /bin/bash -c "$release_predicates
release_entry_scratch_is_admissible \"\$1\" \"\$2\"" _ "$candidate" "$TRELLIS_HOME"
  echo "release containment candidate=<$candidate> raw_exit=$status"
  release_status="$status"
  run /usr/bin/env -i "HOME=$HOME" "TRELLIS_HOME=$TRELLIS_HOME" \
    "TRELLIS_VERIFIED_PAYLOAD=$PAYLOAD" "TRELLIS_VERIFIED_RELEASE_VERSION=$RELEASE_VERSION" \
    "TMPDIR=$candidate" "TMP=$SANDBOX/outside" "TEMP=$SANDBOX/outside" \
    "TRELLIS_MIRROR_SCRATCH_CANDIDATE=$admitted" \
    "BASH_ENV=$HOME/startup-poison" "ENV=$HOME/startup-poison" "PATH=$SANDBOX/outside" \
    /bin/sh "$PAYLOAD/scripts/sync-to-template.sh"
  echo "mirror containment candidate=<$candidate> raw_exit=$status $output"
  [ "$release_status" -eq "$expected" ] || return 1
  if [ "$expected" -eq 0 ]; then
    [ "$status" -eq 0 ] || return 1
    [ "$output" = "$candidate" ] || return 1
    [ -f "$HOME/body-executed" ] || return 1
    rm "$HOME/body-executed"
  else
    [ "$status" -eq 4 ] || return 1
    [[ "$output" == *'command scratch directory is missing or not an admissible private Trellis temp directory'* ]] || return 1
    [ ! -e "$HOME/body-executed" ] || return 1
  fi
  [ ! -e "$HOME/startup-executed" ]
}

replace_mirror_body() {
  awk '/^# -- trellis mirror body --$/ { exit } { print }' \
    "$REPO_ROOT/scripts/sync-to-template.sh" > "$SOURCE/scripts/sync-to-template.sh"
  printf '%s\n' '# -- trellis mirror body --' >> "$SOURCE/scripts/sync-to-template.sh"
}

@test "mirror scratch admission matches release containment for valid and hostile candidates" {
  release_predicates="$(awk '/^release_entry_(path_is_clean|private_directory|scratch_is_admissible)\(\) \{/ { inside = 1 }
    inside { print }
    inside && /^\}/ { inside = 0 }' "$REPO_ROOT/scripts/release.sh")"
  [ -n "$release_predicates" ]
  replace_mirror_body
  cat >> "$SOURCE/scripts/sync-to-template.sh" <<'SH'
[ "${TRELLIS_MIRROR_SCRATCH_CANDIDATE-unset}" = unset ] || exit 91
[ "${TMP-unset}:${TEMP-unset}:${BASH_ENV-unset}:${ENV-unset}" = unset:unset:unset:unset ] || exit 92
[ "$PATH" = /usr/bin:/bin:/usr/sbin:/sbin ] || exit 93
printf executed > "$HOME/body-executed"
printf '%s\n' "$TMPDIR"
SH
  reseal_source_release 'scratch containment sentinel'
  printf 'printf executed > "$HOME/startup-executed"\n' > "$HOME/startup-poison"
  admitted="$TRELLIS_HOME/state/scratch/.cmd.valid"
  mkdir -p "$admitted" "$SANDBOX/outside"
  chmod 700 "$TRELLIS_HOME" "$TRELLIS_HOME/state" "$TRELLIS_HOME/state/scratch" "$admitted"
  check_scratch_candidate "$admitted" 0
  for candidate in '' "$SANDBOX/outside" "$admitted/" "$admitted/../.cmd.valid" \
    "$TRELLIS_HOME/state/scratch/.cmd." "$TRELLIS_HOME/state/scratch/.cmd.bad!"; do
    check_scratch_candidate "$candidate" 1
  done
  ln -s "$admitted" "$TRELLIS_HOME/state/scratch/.cmd.link"
  check_scratch_candidate "$TRELLIS_HOME/state/scratch/.cmd.link" 1
  for directory in "$TRELLIS_HOME" "$TRELLIS_HOME/state" "$TRELLIS_HOME/state/scratch" "$admitted"; do
    chmod 750 "$directory"
    check_scratch_candidate "$admitted" 1
    chmod 700 "$directory"
  done
  # Exercise actual ACL metadata on macOS, the OS fence qualification host.
  if [ "$(uname -s)" = Darwin ]; then
    for directory in "$TRELLIS_HOME" "$TRELLIS_HOME/state" "$TRELLIS_HOME/state/scratch" "$admitted"; do
      /usr/bin/xattr -w org.trellis.bootstrap-test private "$directory"
      echo "xattr-only control: $directory"
      check_scratch_candidate "$admitted" 0
      chmod +a "$(id -un) allow read" "$directory"
      LC_ALL=C /bin/ls -lde "$directory"
      check_scratch_candidate "$admitted" 1
      chmod -N "$directory"
      echo "ACL-removed control: $directory"
      check_scratch_candidate "$admitted" 0
      /usr/bin/xattr -d org.trellis.bootstrap-test "$directory"
    done
  fi
  mv "$TRELLIS_HOME/state/scratch" "$TRELLIS_HOME/state/real-scratch"
  ln -s real-scratch "$TRELLIS_HOME/state/scratch"
  check_scratch_candidate "$admitted" 1
  rm "$TRELLIS_HOME/state/scratch"
  mv "$TRELLIS_HOME/state/real-scratch" "$TRELLIS_HOME/state/scratch"
  check_scratch_candidate "$admitted" 0
}

@test "mirror actual allocations receive the admitted launcher scratch identity" {
  # Observe, but never replace, real mktemp: every original allocation still
  # executes under the unchanged OS fence. Launcher cleanup owns the directory.
  python3 - "$SOURCE/scripts/sync-to-template.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
marker = '\n# -- trellis mirror body --\n'
assert text.count(marker) == 1
probe = '''
mktemp() {
  local allocated rc
  allocated="$(/usr/bin/mktemp "$@")"
  rc=$?
  printf '%s\\t%s\\t%s\\n' "$TMPDIR" "$allocated" "$rc" >> "$HOME/allocations"
  printf '%s\\n' "$allocated"
  return "$rc"
}
'''
path.write_text(text.replace(marker, marker + probe))
PY
  reseal_source_release 'observe actual mirror allocations'
  run_sync --dry-run
  echo "observed publisher raw_exit=$status $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *'simulated mirror clean.'* ]]
  python3 - "$HOME/allocations" "$TRELLIS_HOME" <<'PY'
from pathlib import Path
import sys
rows = [line.split('\t') for line in Path(sys.argv[1]).read_text().splitlines()]
assert rows
scratch = rows[0][0]
assert Path(scratch).parent == Path(sys.argv[2]) / 'state/scratch'
assert Path(scratch).name.startswith('.cmd.')
assert not Path(scratch).exists(), 'launcher scratch cleanup did not run'
for candidate, allocated, rc in rows:
    assert candidate == scratch and rc == '0', (candidate, allocated, rc)
    if Path(allocated).is_absolute():
        assert Path(allocated).parent == Path(scratch), allocated
for prefix in ('trellis-mirror-stage.', 'trellis-mirror-refs.', 'trellis-mirror-files.', 'trellis-mirror-diff.'):
    assert any(Path(row[1]).name.startswith(prefix) for row in rows), prefix
print('actual allocation rows=' + str(len(rows)) + ' scratch=' + scratch)
PY
}

@test "mirror bootstrap actual publisher applies reviewed bytes without global temp writes" {
  run_sync --dry-run
  echo "publisher dry-run raw_exit=$status $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *'simulated mirror clean.'* ]]
  [ ! -e "$MIRROR/engineering-process.md" ]
  run_sync --apply
  echo "publisher raw_exit=$status $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *'applied.'* ]]
  [ "$(git -C "$SOURCE" rev-parse HEAD:engineering-process.md)" = \
    "$(git hash-object --no-filters "$MIRROR/engineering-process.md")" ]
  [ -f "$MIRROR/core-rules/pi/extensions/trellis.ts" ]
  [ ! -e "$MIRROR/core-rules/pi/agents" ]
}

@test "mirror bootstrap preserves stdin argv clean environment options and body EXIT status" {
  replace_mirror_body
  cat >> "$SOURCE/scripts/sync-to-template.sh" <<'SH'
case "$-" in *u*) ;; *) exit 91 ;; esac
[ "$(umask)" = 0077 ] || exit 92
[ "${BOOTSTRAP_POISON-unset}" = unset ] || exit 93
[ "${TRELLIS_MIRROR_SCRATCH_CANDIDATE-unset}" = unset ] || exit 97
[ "${TMP-unset}:${TEMP-unset}:${BASH_ENV-unset}:${ENV-unset}" = unset:unset:unset:unset ] || exit 98
case "$TMPDIR" in "$TRELLIS_HOME"/state/scratch/.cmd.?*) ;; *) exit 99 ;; esac
[ "$TRELLIS_MIRROR_SOURCE_DIR" = "$TRELLIS_VERIFIED_PAYLOAD/scripts" ] || exit 94
[ "$TRELLIS_VERIFIED_RELEASE_VERSION" = 1.2.3 ] || exit 95
[ "${TRELLIS_VERIFIED_SSH_AUTH_SOCK-unset}" = "" ] || exit 96
trap 'printf "exit-status=%s\n" "$?"' EXIT
IFS= read -r line
printf 'stdin=<%s> argc=%s first=<%s> second=<%s>\n' "$line" "$#" "$1" "$2"
(exit 42)
SH
  reseal_source_release 'mirror stdin and traps probe'
  run env BOOTSTRAP_POISON=present /bin/bash -c '
    printf "%s\n" "caller stdin: spaces and backslash \\" | "$1" mirror "with space" ""
  ' _ "$LAUNCHER"
  echo "stdin/argv/trap raw_exit=$status $output"
  [ "$status" -eq 42 ]
  [ "$output" = "$(printf '%s\n' 'stdin=<caller stdin: spaces and backslash \> argc=2 first=<with space> second=<>' 'exit-status=42')" ]
}

@test "mirror bootstrap rejects missing marker and empty body before execution" {
  for variant in missing empty; do
    replace_mirror_body
    if [ "$variant" = missing ]; then
      python3 - "$SOURCE/scripts/sync-to-template.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace('\n# -- trellis mirror body --\n', '\n'))
PY
      printf 'printf executed > "$HOME/body-executed"\n' >> "$SOURCE/scripts/sync-to-template.sh"
    fi
    reseal_source_release "mirror $variant body"
    run "$LAUNCHER" mirror
    echo "$variant raw_exit=$status $output"
    [ "$status" -eq 5 ]
    [[ "$output" == *'trellis mirror: could not prepare trusted bootstrap'* ]]
    [ ! -e "$HOME/body-executed" ]
  done
}

@test "mirror bootstrap refuses partial awk output when extraction exits nonzero" {
  replace_mirror_body
  printf 'printf executed > "$HOME/body-executed"\n' >> "$SOURCE/scripts/sync-to-template.sh"
  # Fault only the fixture extractor: real awk emits the executable body, then
  # exits 17. A streaming or unchecked extraction would execute the sentinel.
  python3 - "$SOURCE/scripts/sync-to-template.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
needle = 'body { print } /^# -- trellis mirror body --'
assert text.count(needle) == 1
path.write_text(text.replace(needle, 'END { exit 17 } body { print } /^# -- trellis mirror body --'))
PY
  reseal_source_release 'mirror partial extraction failure'
  run "$LAUNCHER" mirror
  echo "partial extraction raw_exit=$status $output"
  [ "$status" -eq 5 ]
  [[ "$output" == *'trellis mirror: could not prepare trusted bootstrap'* ]]
  [ ! -e "$HOME/body-executed" ]
}
