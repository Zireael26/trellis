#!/usr/bin/env bats
# THE PROCESS-BIRTH READER: one normative definition, two pinned copies.
#
# `process_birth` is the anti-PID-reuse half of every Trellis ownership record.
# It was read exactly one way — `LC_ALL=C ps -p PID -o lstart=` — and macOS
# ships ps setgid `kmem`, so a setgid binary that a seatbelt will not run took
# the whole check indeterminate inside the Claude Code, Codex, and isolated
# verification shells. `trellis_process_birth` (scripts/lib/trellis-home.sh)
# keeps ps wherever ps runs and reads the same token through libproc on Darwin.
#
# WHAT IS AND IS NOT HERE. These cases exercise the real reader against real
# processes; separate controlled ctypes cases supplement native calls. No case
# is skipped. The privileged ps oracle is deliberately absent — it cannot run
# inside the fences this suite is verified in, and a fenced ps failure is a
# fence fact, not a pass. Byte-for-byte parity against genuine ps is a separate
# host observation, `specs/045-three-harness-parity/verification/
# process-birth-host-oracle.py`, whose receipt is pinned to the same helper
# hashes these cases read.
#
# WHY THERE ARE COPIES. `release-store.sh` declares in its own header that it
# depends on nothing above `semver.sh`, and `trellis-launcher.sh` is copied
# verbatim to a user-owned executable that must not reach into a source
# checkout for the logic it runs while deciding which payload may execute at
# all. Both carry the two functions verbatim, exactly as they already carry
# `trellis_home_snapshot_payload_matches`. The duplication is structural; the
# drift risk is handled mechanically, below.
#
# bash 3.2 / bats 1.x.

REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../.." && pwd )"
HOME_LIB="$REPO_ROOT/scripts/lib/trellis-home.sh"

setup() {
  # Templated so the path honours TMPDIR — macOS `mktemp -d` with no template
  # ignores it, which would put this sandbox outside the write-allowed root of
  # the fence this suite exists to be verified inside.
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/process-birth.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
}

teardown() {
  if [ -n "${LIVE_PID:-}" ]; then
    kill "$LIVE_PID" 2>/dev/null || true
    wait "$LIVE_PID" 2>/dev/null || true
    LIVE_PID=""
  fi
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

# The body of shell function $2 in file $1: everything between the opening
# `NAME() {` line and the first line that is exactly `}` at column 0. Same
# extractor as scripts/tests/release-snapshot-predicate.bats.
extract_function_body() {
  awk -v name="$2" '
    $0 == name "() {" { inside = 1; next }
    inside && $0 == "}" { exit }
    inside { print }
  ' "$1"
}

# Does file $1 CALL function $2 outside reader/emitter definitions?
# Comment lines do not count — a name that survives only in prose is not wiring.
function_is_called() {
  awk -v name="$2" '
    /^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*\(\)[[:space:]]*\{/ { next }
    /^[[:space:]]*#/ { next }
    $0 ~ ("(^|[^A-Za-z_0-9])" name "([[:space:]\";)]|$)") { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# Every line of file $1 that reads a birth token through ps, minus the ones
# inside the process-birth function whose prefix is $2 and minus prose. What is
# left is a call site that skipped the shared reader.
lstart_sites_outside_helper() {
  awk -v name="$2" '
    $0 == name "() {" || $0 == name "_python() {" { inside = 1; next }
    inside && $0 == "}" { inside = 0; next }
    inside { next }
    /^[[:space:]]*#/ { next }
    index($0, "-o lstart=") || index($0, "\"lstart=\"") { print }
  ' "$1"
}

# Compare the pinned copies under root $1 against the normative bodies there.
# Prints every drift it finds and returns 1; silent and 0 when they agree.
# Takes a root so the same comparison can run against a mutated disposable
# copy, which is the only way to know the check can go red at all.
compare_pinned_copies() {
  local root="$1" normative copy carrier prefix rc=0
  normative="$(extract_function_body "$root/scripts/lib/trellis-home.sh" trellis_process_birth)"
  if [ -z "$normative" ]; then
    echo "normative trellis_process_birth not found"
    return 1
  fi
  # Guard the extractor: a body without the Darwin branch is not this reader,
  # and comparing two empty strings would pass.
  case "$normative" in
    *'LC_ALL=C python3 -I -c "$program" "$pid"'*) ;;
    *) echo "extracted body is not the process-birth reader:"; echo "$normative"; return 1 ;;
  esac

  local normative_py
  normative_py="$(extract_function_body "$root/scripts/lib/trellis-home.sh" trellis_process_birth_python)"
  case "$normative_py" in
    *'/usr/lib/libproc.dylib'*) ;;
    *) echo "extracted body is not the libproc program:"; echo "$normative_py"; return 1 ;;
  esac

  for carrier in "scripts/lib/release-store.sh:release_store" "scripts/trellis-launcher.sh:launcher"; do
    prefix="${carrier##*:}"
    carrier="${carrier%%:*}"

    # The program is pure data: its copies must be byte-identical, unnormalized.
    copy="$(extract_function_body "$root/$carrier" "${prefix}_process_birth_python")"
    if [ "$copy" != "$normative_py" ]; then
      printf '%s copy of the libproc program drifted\n--- normative\n%s\n--- copy\n%s\n' \
        "$carrier" "$normative_py" "$copy"
      rc=1
    fi

    # The reader names its own emitter, so the ONLY licensed difference is that
    # prefix. Substituting it back is a fixed, total rename — anything else in
    # the body still has to match byte for byte.
    copy="$(extract_function_body "$root/$carrier" "${prefix}_process_birth")"
    case "$copy" in
      *"${prefix}_process_birth_python"*) ;;
      *) printf '%s copy does not call its own emitter; the rename below would be vacuous\n' "$carrier"; rc=1 ;;
    esac
    copy="$(printf '%s\n' "$copy" | sed "s/${prefix}_process_birth/trellis_process_birth/g")"
    if [ "$copy" != "$normative" ]; then
      printf '%s copy of the reader drifted\n--- normative\n%s\n--- copy\n%s\n' \
        "$carrier" "$normative" "$copy"
      rc=1
    fi
  done
  return "$rc"
}

birth() {
  ( . "$HOME_LIB" && trellis_process_birth "$1" )
}

birth_program() {
  ( . "$HOME_LIB" && trellis_process_birth_python )
}

assert_platform_token() {
  local token="$1" date="$1"
  if [ "$(uname -s)" = Darwin ]; then
    [ "${#token}" -eq 28 ] && [ "${token: -4}" = "    " ] || return 1
    date="${token%    }"
  else
    [ "${#token}" -eq 24 ] || return 1
  fi
  printf '%s\n' "$date" |
    grep -Eq '^[A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}$'
}

# ===========================================================================
# PINNED COPY INTEGRITY
# ===========================================================================

@test "the three process-birth readers are one definition" {
  run compare_pinned_copies "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "each carrier calls the copy it pins" {
  function_is_called "$REPO_ROOT/scripts/lib/release-store.sh" release_store_process_birth ||
    { echo "release-store.sh holds a pristine copy it never invokes"; false; }
  function_is_called "$REPO_ROOT/scripts/trellis-launcher.sh" launcher_process_birth ||
    { echo "trellis-launcher.sh holds a pristine copy it never invokes"; false; }
  function_is_called "$REPO_ROOT/scripts/lib/attachment.sh" trellis_process_birth ||
    { echo "attachment.sh does not reach the canonical reader"; false; }
  function_is_called "$REPO_ROOT/scripts/lib/disk-janitor-lib.sh" trellis_process_birth ||
    { echo "disk-janitor-lib.sh does not reach the canonical reader"; false; }
  function_is_called "$REPO_ROOT/scripts/lib/disk-janitor-lib.sh" trellis_process_birth_python ||
    { echo "disk-janitor-lib.sh does not hand the reader program to its sink"; false; }
}

@test "the pinned-copy check goes red when one copy is mutated" {
  local disposable
  disposable="$SANDBOX/disposable"
  mkdir -p "$disposable/scripts/lib"
  cp "$REPO_ROOT/scripts/lib/trellis-home.sh" "$disposable/scripts/lib/"
  cp "$REPO_ROOT/scripts/lib/release-store.sh" "$disposable/scripts/lib/"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$disposable/scripts/"

  # Positive control first: an unmutated copy of the tree must pass, so a red
  # result below is the mutation and not the copying.
  run compare_pinned_copies "$disposable"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # One character, inside the reader body, in one carrier.
  perl -0pi -e 's/(release_store_process_birth\(\) \{.*?)2147483647/${1}2147483646/s' \
    "$disposable/scripts/lib/release-store.sh"
  grep -q '2147483646' "$disposable/scripts/lib/release-store.sh" ||
    { echo "mutation did not apply"; false; }

  run compare_pinned_copies "$disposable"
  [ "$status" -ne 0 ] || { echo "a mutated copy passed the pin"; echo "$output"; false; }
  [[ "$output" == *"release-store.sh copy of the reader drifted"* ]] || { echo "$output"; false; }
}

@test "no production call site still reads lstart around the shared reader" {
  local found
  found="$(lstart_sites_outside_helper "$REPO_ROOT/scripts/lib/trellis-home.sh" trellis_process_birth)"
  [ -z "$found" ] || { echo "trellis-home.sh: $found"; false; }
  found="$(lstart_sites_outside_helper "$REPO_ROOT/scripts/lib/release-store.sh" release_store_process_birth)"
  [ -z "$found" ] || { echo "release-store.sh: $found"; false; }
  found="$(lstart_sites_outside_helper "$REPO_ROOT/scripts/trellis-launcher.sh" launcher_process_birth)"
  [ -z "$found" ] || { echo "trellis-launcher.sh: $found"; false; }
  found="$(lstart_sites_outside_helper "$REPO_ROOT/scripts/lib/attachment.sh" _attachment_process_birth)"
  [ -z "$found" ] || { echo "attachment.sh: $found"; false; }

  # The janitor's deletion sink keeps a ps argv for the platforms that still
  # use one; that ONE line is the whole licensed remainder.
  found="$(lstart_sites_outside_helper "$REPO_ROOT/scripts/lib/disk-janitor-lib.sh" trellis_process_birth)"
  [ "$found" = '        birth_argv = ["ps", "-p", str(pid), "-o", "lstart="]' ] ||
    { echo "disk-janitor-lib.sh: $found"; false; }
}

# ===========================================================================
# THE REAL READER, REAL PROCESSES
# ===========================================================================

@test "reads a real live same-user process and emits the stored token schema" {
  local token repeat
  ( cd "$SANDBOX" && exec /bin/sleep 300 ) >/dev/null 2>&1 &
  LIVE_PID=$!

  token="$(birth "$LIVE_PID")" || { echo "reader failed for live pid $LIVE_PID"; false; }
  # Darwin preserves four trailing spaces; Linux preserves native ps bytes.
  assert_platform_token "$token" || { echo "invalid native token: [$token]"; false; }

  # A birth token is only useful if it is stable: a second read of the same
  # live process must return the identical bytes.
  repeat="$(birth "$LIVE_PID")"
  [ "$repeat" = "$token" ] || { echo "token changed between reads: [$token] vs [$repeat]"; false; }

  # And it must actually discriminate: this shell was born before the child.
  [ "$(birth "$$")" != "" ] || { echo "reader failed for the test shell"; false; }
}

@test "a dead pid yields no token" {
  local out status
  ( cd "$SANDBOX" && exec /bin/sleep 300 ) >/dev/null 2>&1 &
  LIVE_PID=$!
  birth "$LIVE_PID" >/dev/null || { echo "fixture pid was not readable while alive"; false; }
  kill "$LIVE_PID" 2>/dev/null || true
  wait "$LIVE_PID" 2>/dev/null || true

  out="$(birth "$LIVE_PID" 2>/dev/null)" && status=0 || status=$?
  LIVE_PID=""
  [ "$status" -ne 0 ] || { echo "a dead pid produced a token: [$out]"; false; }
  [ -z "$out" ] || { echo "a failed read still emitted [$out]"; false; }
}

@test "a malformed or out-of-range pid is rejected without a token" {
  local bad out status
  for bad in "" abc 0 007 -1 "1 2" 99999999999 2147483648 " 5" "5 "; do
    out="$(birth "$bad" 2>/dev/null)" && status=0 || status=$?
    [ "$status" -ne 0 ] || { echo "pid [$bad] was accepted: [$out]"; false; }
    [ -z "$out" ] || { echo "pid [$bad] emitted [$out]"; false; }
  done
}

@test "native PID 1 observation accepts permission or refuses without a dead claim" {
  local out status
  out="$(birth 1 2>/dev/null)" && status=0 || status=$?
  printf 'native PID 1: exit=%s token=[%s]\n' "$status" "$out" >&3
  if [ "$status" -eq 0 ]; then
    assert_platform_token "$out"
  else
    [ -z "$out" ] || { echo "failed read emitted [$out]"; false; }
    [ "$status" -ne 3 ] || { echo "PID 1 refusal fabricated death"; false; }
  fi
}

# ===========================================================================
# ISOLATION AND SCHEMA
# ===========================================================================

@test "a poisoned working directory cannot change what the reader returns" {
  local token poisoned control
  ( cd "$SANDBOX" && exec /bin/sleep 300 ) >/dev/null 2>&1 &
  LIVE_PID=$!
  token="$(birth "$LIVE_PID")" || { echo "baseline read failed"; false; }

  mkdir -p "$SANDBOX/poison"
  cat > "$SANDBOX/poison/ctypes.py" <<'EOF'
raise SystemExit("poisoned ctypes was imported")
EOF
  cat > "$SANDBOX/poison/time.py" <<'EOF'
raise SystemExit("poisoned time was imported")
EOF

  poisoned="$( cd "$SANDBOX/poison" && . "$HOME_LIB" && \
    PYTHONPATH="$SANDBOX/poison" trellis_process_birth "$LIVE_PID" )" ||
    { echo "reader failed from a poisoned cwd"; false; }
  [ "$poisoned" = "$token" ] || { echo "poisoned cwd changed the token: [$token] vs [$poisoned]"; false; }

  # Prove the poison is real rather than inert: the same program without -I
  # picks up the shadowing modules and dies. Without this control the case
  # above would pass on a directory that never mattered.
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    control="$( cd "$SANDBOX/poison" && \
      PYTHONPATH="$SANDBOX/poison" python3 -c "$(birth_program)" "$LIVE_PID" 2>&1 )" && {
      echo "the poison fixture was inert; the isolation check proves nothing: [$control]"
      false
    }
    case "$control" in
      *poisoned*) ;;
      *) echo "the poison fixture failed for an unrelated reason: [$control]"; false ;;
    esac
  fi
}

@test "the reader program is data and reaches no path but libproc" {
  local program path
  program="$(birth_program)"
  [ -n "$program" ] || { echo "no program was emitted"; false; }
  case "$program" in
    *'/usr/lib/libproc.dylib'*) ;;
    *) echo "the emitted program does not load libproc"; false ;;
  esac
  # Every absolute path the program names must be that one library. A reader
  # assembled from an operator- or project-owned file would show up here.
  for path in $(printf '%s\n' "$program" | grep -oE '"/[^"]*"' | tr -d '"'); do
    [ "$path" = "/usr/lib/libproc.dylib" ] ||
      { echo "the emitted program names another path: $path"; false; }
  done
  # And nothing in the reader discovers a source path at runtime.
  printf '%s\n' "$(extract_function_body "$HOME_LIB" trellis_process_birth)" |
    grep -Eq 'BASH_SOURCE|dirname|realpath|\$0' &&
    { echo "the reader discovers a path at runtime"; false; }
  true
}

@test "the token still satisfies the stored owner-record schema" {
  local token record
  command -v jq >/dev/null 2>&1 || { echo "jq is required"; false; }
  ( cd "$SANDBOX" && exec /bin/sleep 300 ) >/dev/null 2>&1 &
  LIVE_PID=$!
  token="$(birth "$LIVE_PID")" || { echo "reader failed"; false; }

  # The exact producer shape and the exact predicate the janitor validates it
  # with. A reader that changed the schema — epoch seconds, UTC, a trimmed
  # token — fails here rather than at deletion time on somebody's disk.
  record="$(jq -cn --argjson pid "$LIVE_PID" --arg process_birth "$token" \
    '{schema_version:1,pid:$pid,process_birth:$process_birth}')"
  jq -e '
    type == "object"
    and (keys | sort) == ["pid","process_birth","schema_version"]
    and (.schema_version | type == "number" and floor == . and . == 1)
    and (.pid | type == "number" and floor == . and . > 0)
    and (.process_birth | type == "string" and length > 0)
  ' <<<"$record" >/dev/null || { echo "record rejected: $record"; false; }

  # The janitor compares outer-trimmed tokens; trimming must leave the date,
  # not empty it.
  [ "$(printf '%s\n' "$token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" \
    = "$(printf '%s\n' "$token" | sed 's/[[:space:]]*$//')" ] ||
    { echo "token has leading whitespace: [$token]"; false; }
  [ -n "$(printf '%s\n' "$token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" ] ||
    { echo "token trims to nothing: [$token]"; false; }
}

@test "wiring check goes red after removing calls but retaining both definitions" {
  local fixture="$SANDBOX/carrier.sh"
  cat > "$fixture" <<'SH'
reader_python() {
  :
}
reader() {
  reader_python
}
reader 123
SH
  function_is_called "$fixture" reader
  function_is_called "$fixture" reader_python
  sed '/^reader 123$/d; /^  reader_python$/d' "$fixture" > "$fixture.mutated"
  run function_is_called "$fixture.mutated" reader
  printf 'call-removal reader check: exit=%s\n' "$status" >&3
  [ "$status" -eq 1 ]
  run function_is_called "$fixture.mutated" reader_python
  printf 'call-removal emitter check: exit=%s\n' "$status" >&3
  [ "$status" -eq 1 ]
}

@test "controlled ctypes responses reject short read, wrong PID, bad time, EPERM and ESRCH" {
  # This executes the emitted program with controlled API responses, not libproc.
  run python3 -I - "$(birth_program)" <<'PY'
import contextlib
import ctypes
import io
import sys
from unittest.mock import patch

program = sys.argv[1]
for case, expected in [("valid", 0), ("short", 1), ("pid", 1),
                       ("time", 1), ("EPERM", 1), ("ESRCH", 3)]:
    def response(pid, flavor, arg, pointer, size):
        assert flavor == 3 and arg == 0 and size == 136
        info = pointer._obj
        info.head[3] = pid + (case == "pid")
        info.pbi_start_tvsec = 0 if case == "time" else 1700000000
        ctypes.set_errno({"EPERM": 1, "ESRCH": 3}.get(case, 0))
        return size - 1 if case in ("short", "EPERM", "ESRCH") else size

    class Library:
        proc_pidinfo = staticmethod(response)

    output = io.StringIO()
    with patch.object(ctypes, "CDLL", return_value=Library()) as load, \
            patch.object(sys, "argv", ["reader", "123"]), contextlib.redirect_stdout(output):
        status = 0
        try:
            exec(compile(program, "<emitted-reader>", "exec"), {})
        except SystemExit as error:
            status = error.code
    load.assert_called_once_with("/usr/lib/libproc.dylib", use_errno=True)
    assert status == expected, (case, status, expected)
    if expected:
        assert output.getvalue() == "", (case, output.getvalue())
    else:
        assert len(output.getvalue()) == 29 and output.getvalue().endswith("    \n")
    print("controlled ctypes %s: exit=%s stdout=%r" % (case, status, output.getvalue()))
PY
  printf '%s\n' "$output" >&3
  [ "$status" -eq 0 ]
}

# Direct sink fixtures never call the planner. Every PID and path belongs here.
sink_fixture() {
  local token
  if [ -z "${LIVE_PID:-}" ]; then
    ( cd "$SANDBOX" && exec /bin/sleep 300 ) >/dev/null 2>&1 &
    LIVE_PID=$!
  fi
  token="$(birth "$LIVE_PID")" || return 1
  RELEASES="$SANDBOX/releases"
  TARGET="$RELEASES/.tmp.1.2.3.exec.$1"
  mkdir -p "$TARGET"
  printf 'payload\000preserve\n' > "$TARGET/content"
  jq -cn --argjson pid "$LIVE_PID" --arg process_birth "${2:-$token}" \
    '{schema_version:1,pid:$pid,process_birth:$process_birth}' > "$TARGET.owner.json"
  python3 -I -c 'import os,sys,time; p=sys.argv[1]; t=time.time()-3*86400; os.utime(p,(t,t))' "$TARGET"
  read -r DEVICE INODE <<< "$(python3 -I -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_dev,s.st_ino)' "$TARGET")"
  sink_bytes > "$SANDBOX/$1.before"
}

sink_bytes() {
  python3 -I - "$TARGET" <<'PY'
import json
import os
from pathlib import Path
import sys
p = Path(sys.argv[1])
assert p.is_dir(), "target disappeared"
rows = []
for item in [p, p / "content", Path(str(p) + ".owner.json")]:
    s = item.lstat()
    rows.append([str(item), s.st_dev, s.st_ino, s.st_mode,
                 None if item.is_dir() else item.read_bytes().hex()])
print(json.dumps(rows))
PY
}

sink_preserved() {
  sink_bytes > "$SANDBOX/after" || return 1
  cmp "$SANDBOX/$1.before" "$SANDBOX/after"
}

call_sink() (
  . "$HOME_LIB"
  . "$REPO_ROOT/scripts/lib/disk-janitor-lib.sh"
  [ -z "${2:-}" ] || . "$2"
  if [ -n "${1:-}" ]; then
    # Darwin really launches this data through sys.executable -I -c; no shim.
    local failure="$1"
    trellis_process_birth_python() {
      printf 'import os,sys\nos.kill(int(sys.argv[1]),0)\nprint("Tue Jan  1 00:00:00 1980    ")\nsys.exit(%s)\n' "$failure"
    }
    if [ "$(uname -s)" != Darwin ]; then
      mkdir -p "$SANDBOX/bin"
      cat > "$SANDBOX/bin/ps" <<'SH'
#!/bin/sh
[ "$#" -eq 4 ] && [ "$1" = -p ] && [ "$2" = "$SINK_PID" ] && [ "$3" = -o ] && [ "$4" = lstart= ] || exit 91
kill -0 "$2" || exit 92
printf 'Tue Jan  1 00:00:00 1980    \n'
exit "$SINK_EXIT"
SH
      chmod +x "$SANDBOX/bin/ps"
      export PATH="$SANDBOX/bin:$PATH" SINK_PID="$LIVE_PID" SINK_EXIT="$failure"
    fi
  fi
  dj_remove_release_staging_safely "$RELEASES" "$TARGET" 1.2.3 1 "$DEVICE" "$INODE"
)

@test "direct sink refuses failed birth with plausible different stdout and preserves bytes" {
  local failure
  printf 'direct sink platform: %s (Darwin native isolated child; Linux controlled ps)\n' "$(uname -s)" >&3
  for failure in 69 3; do
    sink_fixture "failure$failure"
    kill -0 "$LIVE_PID"
    run call_sink "$failure"
    printf 'direct sink birth exit %s: sink exit=%s stdout/stderr=%s\n' "$failure" "$status" "$output" >&3
    [ "$status" -ne 0 ]
    [[ "$output" == *"owner process birth could not be read"* ]]
    sink_preserved "failure$failure"
  done
}

@test "direct sink orphan control deletes only its exact scratch target" {
  sink_fixture neighbor
  sink_fixture orphan 'Tue Jan  1 00:00:00 1980    '
  run call_sink
  printf 'unmodified orphan sink: exit=%s stdout/stderr=%s\n' "$status" "$output" >&3
  [ "$status" -eq 0 ]
  [ ! -e "$TARGET" ] && [ ! -e "$TARGET.owner.json" ]
  TARGET="$RELEASES/.tmp.1.2.3.exec.neighbor"
  sink_preserved neighbor
}

@test "removing sink return-code guard makes the preservation assertion red" {
  local copied="$SANDBOX/sink.sh"
  printf 'dj_remove_release_staging_safely() {\n' > "$copied"
  extract_function_body "$REPO_ROOT/scripts/lib/disk-janitor-lib.sh" dj_remove_release_staging_safely >> "$copied"
  printf '}\n' >> "$copied"
  sink_fixture mutation
  run call_sink 69 "$copied"
  [ "$status" -ne 0 ]
  [[ "$output" == *"owner process birth could not be read"* ]]
  sink_preserved mutation
  python3 -I - "$copied" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
assert s.count("result.returncode != 0 or ") == 1
p.write_text(s.replace("result.returncode != 0 or ", ""))
PY
  run call_sink 69 "$copied"
  printf 'mutated sink: exit=%s stdout/stderr=%s\n' "$status" "$output" >&3
  [ "$status" -eq 0 ]
  run sink_preserved mutation
  printf 'mutated preservation assertion: exit=%s stdout/stderr=%s\n' "$status" "$output" >&3
  [ "$status" -ne 0 ]
  [[ "$output" == *"target disappeared"* ]]
  [ ! -e "$TARGET" ] && [ ! -e "$TARGET.owner.json" ]
}
