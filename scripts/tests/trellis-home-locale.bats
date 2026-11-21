#!/usr/bin/env bats
# Regression for Bash 5.3/macOS runtime locale changes after fork.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LIB="${HOME_LOCALE_TEST_LIB:-$REPO_ROOT/scripts/lib}"

@test "home byte predicates match the original C verdicts in every caller locale" {
  run python3 -I -B -X utf8 - "$BASH" "$LIB" <<'PY'
import os
import subprocess
import sys

bash, lib = sys.argv[1:]
# Original predicates at ef6efc6bb, run only in a shell STARTED in C. Keeping
# the oracle separate catches accidental widening/narrowing of the byte sets.
oracle = r'''
trellis_home_has_unsafe_chars() {
  local LC_ALL=C value
  value="$1"
  case "$value" in
    *[$'\001'-$'\037'$'\177']*|*$'\302'[$'\200'-$'\237']*) return 0 ;;
    *) return 1 ;;
  esac
}
trellis_home_native_entry_path_is_safe() {
  local LC_ALL=C path="$1"
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path" in
    *=*|*[$'\001'-$'\037'$'\177']*|*$'\302'[$'\200'-$'\237']*) return 1 ;;
  esac
  return 0
}
'''
probe = r'''
while IFS= read -r -d '' value; do
  trellis_home_has_unsafe_chars "$value"; printf '%s:' "$?"
  trellis_home_native_entry_path_is_safe "$value"; printf '%s\n' "$?"
done
'''
values = [b"", b"relative", b"/safe", b"/a=b", "/café/日本/K".encode(),
          b"/bad\xc0\x80", b"/bad\xf5\xff", b"/partial\xe2\x82"]
values += [b"/x" + bytes([n]) + b"z" for n in range(1, 256)]
values += [b"/x\xc2" + bytes([n]) + b"z" for n in range(1, 256)]
# C1 adjacent to a printable UTF-8 character, or embedded in invalid UTF-8.
values += ["/é".encode() + b"\xc2" + bytes([n]) + b"\xff" for n in range(128, 160)]
payload = b"\0".join(values) + b"\0"
base = {k: v for k, v in os.environ.items()
        if k not in ("LANG", "LANGUAGE") and not k.startswith("LC_")}
def run(program, additions):
    result = subprocess.run([bash, "-c", program, "_", lib], input=payload,
                            env=dict(base, **additions), capture_output=True)
    assert result.returncode == 0, (result.returncode, result.stderr)
    return result.stdout.splitlines()
expected = run(oracle + probe, {"LC_ALL": "C"})
assert len(expected) == len(values)
locales = [{}, {"LANG": "C"}, {"LANG": "en_US.UTF-8"},
           {"LC_ALL": ""}, {"LC_ALL": "C"}, {"LC_ALL": "en_US.UTF-8"}]
available = subprocess.check_output(["locale", "-a"], env=dict(base, LC_ALL="C")).decode("ascii", "replace")
c_utf8 = next((name for name in available.splitlines() if name.lower().replace("-", "") == "c.utf8"), None)
if c_utf8:
    locales.append({"LC_ALL": c_utf8})
else:
    print("C.UTF-8 locale unavailable on this host; en_US.UTF-8 cases remain in the matrix")
for locale in locales:
    actual = run('. "$1/trellis-home.sh"\n' + probe, locale)
    assert actual == expected, (locale, [(values[i].hex(), a, e)
                                for i, (a, e) in enumerate(zip(actual, expected)) if a != e])
print(f"{len(values)} byte inputs x {len(locales)} caller locales match original C verdicts")
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
}

@test "captured home resolution survives 500 fresh sessions with locale unset" {
  run python3 -I -B -X utf8 - "$BASH" "$LIB" "$BATS_TEST_TMPDIR" <<'PY'
import os
import subprocess
import sys

bash, lib, scratch = sys.argv[1:]
env = dict(os.environ)
for name in ("LANG", "LANGUAGE", "LC_ALL"):
    env.pop(name, None)
env.update(HOME=scratch, TRELLIS_HOME=scratch + "/trellis-home")
program = '''
. "$1/trellis-home.sh"
output="$(trellis_home_resolve "$2")"; rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
[ "$output" = "$2" ]
'''
attempts = 500
failures = []
for n in range(1, attempts + 1):
    result = subprocess.run([bash, "-c", program, "_", lib, env["TRELLIS_HOME"]],
                            env=env, start_new_session=True, capture_output=True)
    if result.returncode:
        failures.append((n, result.returncode, result.stderr.decode(errors="replace")))
segv = sum(rc in (-11, 139) for _, rc, _ in failures)
print(f"attempts={attempts} failures={len(failures)} segv={segv}")
for n, rc, stderr in failures:
    print(f"iteration={n} exit={rc}: {stderr.strip()}")
sys.exit(bool(failures))
PY
  echo "# $output" >&3
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
}
