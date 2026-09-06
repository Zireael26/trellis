#!/usr/bin/env bats
# Regression coverage for the canonical suite's Git mutation boundary.
#
# This file never invokes the host Git binary. FAKE_GIT only records argv and
# answers the fence's read-only common-dir/per-worktree-git-dir probes; a
# delegated config/worktree/init command is observable without mutating a repo.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
FENCE="$REPO_ROOT/scripts/tests/helpers/git-fence/git"
RUNNER="$REPO_ROOT/scripts/run-tests.sh"

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-root"
  OUTSIDE_ROOT="$BATS_TEST_TMPDIR/operator-repo"
  FAKE_GIT="$BATS_TEST_TMPDIR/fake-git"
  GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  mkdir -p "$FIXTURE_ROOT" "$OUTSIDE_ROOT"
  : > "$GIT_LOG"

  cat > "$FAKE_GIT" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FENCE_GIT_LOG"
case " $* " in
  *" rev-parse --path-format=absolute --git-common-dir "*)
    [ "${FENCE_FAKE_NO_COMMON:-0}" = "1" ] && exit 128
    printf '%s\n' "$FENCE_FAKE_COMMON_DIR"
    ;;
  *" rev-parse --path-format=absolute --absolute-git-dir "*)
    printf '%s\n' "$FENCE_FAKE_COMMON_DIR"
    ;;
esac
exit 0
SH
  chmod 755 "$FAKE_GIT"
}

run_fence() {
  run env \
    TRELLIS_TEST_GIT_FENCE_ROOT="$FIXTURE_ROOT" \
    TRELLIS_TEST_REAL_GIT="$FAKE_GIT" \
    FENCE_GIT_LOG="$GIT_LOG" \
    FENCE_FAKE_COMMON_DIR="$FENCE_FAKE_COMMON_DIR" \
    FENCE_FAKE_NO_COMMON="${FENCE_FAKE_NO_COMMON:-0}" \
    GIT_DIR="${FENCE_INHERITED_GIT_DIR:-}" \
    "$FENCE" "$@"
}

make_install_harness() {
  CONTRACT_ROOT="$BATS_TEST_TMPDIR/contract source"
  mkdir -p "$CONTRACT_ROOT/scripts/tests/helpers/git-fence" "$CONTRACT_ROOT/scripts/lib"
  cp "$RUNNER" "$CONTRACT_ROOT/scripts/run-tests.sh"
  cp "$REPO_ROOT/scripts/lib/test-suites.sh" "$CONTRACT_ROOT/scripts/lib/test-suites.sh"
  cp "$REPO_ROOT/scripts/tests/helpers/git-fence/git" "$CONTRACT_ROOT/scripts/tests/helpers/git-fence/git"
  cp "$REPO_ROOT/scripts/tests/helpers/git-fence/mktemp" "$CONTRACT_ROOT/scripts/tests/helpers/git-fence/mktemp"

  python3 - "$RUNNER" "$BATS_TEST_TMPDIR/install-harness.sh" <<'PY_HARNESS'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index("install_test_git_fence() {\n")
end = source.index('\nif [ "$LIST" -eq 0 ] && [ "$PLAN" -eq 0 ]; then', start)
function = source[start:end]
Path(sys.argv[2]).write_text("#!/bin/bash\nset -uo pipefail\n" + function + r'''
ROOT=$1
TMPDIR=$2
export TMPDIR
mode=$3
install_test_git_fence || exit $?
first_root=$TRELLIS_TEST_GIT_FENCE_ROOT
case $mode in
  driver)
    exec /bin/bash "$4" "$first_root" "$first_root/bin"
    ;;
  nested)
    install_test_git_fence || exit $?
    second_root=$TRELLIS_TEST_GIT_FENCE_ROOT
    case "$second_root/" in "$first_root"/*) ;; *) exit 81 ;; esac
    [ "$second_root" != "$first_root" ] || exit 82
    git init -q "$second_root/nested-repo"
    ;;
esac
''')
PY_HARNESS
  chmod 700 "$BATS_TEST_TMPDIR/install-harness.sh"
}

@test "config write routed to a common dir outside the fixture is refused" {
  FENCE_FAKE_COMMON_DIR="$OUTSIDE_ROOT/shared.git"
  FENCE_INHERITED_GIT_DIR="$OUTSIDE_ROOT/shared.git"

  run_fence -C "$FIXTURE_ROOT/repo" config user.name Fixture

  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [[ "$output" == *"REFUSED"*"outside test root"* ]] || { echo "$output"; false; }
  # The inherited outside route is rejected before even an identity probe.
  [ ! -s "$GIT_LOG" ]
  if grep -F ' config user.name Fixture' "$GIT_LOG"; then false; fi

  # An explicit file destination cannot hide an outside CLI repository route.
  FENCE_INHERITED_GIT_DIR=""
  run_fence --git-dir="$OUTSIDE_ROOT/shared.git" -C "$FIXTURE_ROOT/repo" \
    config --file "$FIXTURE_ROOT/local.config" user.name Fixture
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [[ "$output" == *"REFUSED"*"routed Git directory"*"outside test root"* ]] || { echo "$output"; false; }
  [ ! -s "$GIT_LOG" ]

  # Object-store writers are mutations even though they do not move refs.
  FENCE_INHERITED_GIT_DIR="$OUTSIDE_ROOT/shared.git"
  run_fence -C "$FIXTURE_ROOT/repo" hash-object -w --stdin
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [ ! -s "$GIT_LOG" ]
  run_fence -C "$FIXTURE_ROOT/repo" write-tree
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [ ! -s "$GIT_LOG" ]
}

@test "worktree remove routed to a common dir outside the fixture is refused" {
  FENCE_FAKE_COMMON_DIR="$OUTSIDE_ROOT/shared.git"
  FENCE_INHERITED_GIT_DIR="$OUTSIDE_ROOT/shared.git"

  run_fence -C "$FIXTURE_ROOT/repo" worktree remove "$OUTSIDE_ROOT/live-worktree"

  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [[ "$output" == *"REFUSED"*"git worktree remove"*"outside test root"* ]] || { echo "$output"; false; }
  [ ! -s "$GIT_LOG" ]
  ! grep -F ' worktree remove ' "$GIT_LOG"
}

@test "clean pathspec named -n cannot disguise an outside destructive clean" {
  FENCE_FAKE_COMMON_DIR="$OUTSIDE_ROOT/shared.git"
  FENCE_INHERITED_GIT_DIR="$OUTSIDE_ROOT/shared.git"

  run_fence -C "$FIXTURE_ROOT/repo" clean -fd -- -n

  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [[ "$output" == *"REFUSED"*"git clean"*"outside test root"* ]] || { echo "$output"; false; }
  [ ! -s "$GIT_LOG" ]
  ! grep -F ' clean -fd -- -n' "$GIT_LOG"
}

@test "clean long option containing n is not mistaken for dry-run" {
  FENCE_FAKE_COMMON_DIR="$OUTSIDE_ROOT/shared.git"
  FENCE_INHERITED_GIT_DIR="$OUTSIDE_ROOT/shared.git"

  run_fence -C "$FIXTURE_ROOT/repo" clean -fd --exclude=node_modules

  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [[ "$output" == *"REFUSED"*"git clean"*"outside test root"* ]] || { echo "$output"; false; }
  [ ! -s "$GIT_LOG" ]
  ! grep -F ' clean -fd --exclude=node_modules' "$GIT_LOG"
}

@test "bare init redirected outside by inherited GIT_DIR is refused before Git runs" {
  FENCE_FAKE_COMMON_DIR="$FIXTURE_ROOT/repo/.git"
  FENCE_INHERITED_GIT_DIR="$OUTSIDE_ROOT/shared.git"

  # The CLI destination is inside the fixture. The inherited route is the bug:
  # old behavior ignored this safe-looking path and reinitialized shared.git.
  run_fence init --bare "$FIXTURE_ROOT/origin.git"

  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [[ "$output" == *"REFUSED"*"routed Git directory"*"outside test root"* ]] || { echo "$output"; false; }
  [ ! -s "$GIT_LOG" ]
}

@test "mutation with a fenced common dir or unresolved fenced destination reaches only the fake backend" {
  FENCE_FAKE_COMMON_DIR="$FIXTURE_ROOT/repo/.git"

  run_fence -C "$FIXTURE_ROOT/repo" config user.name Fixture

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$GIT_LOG" | tr -d ' ')" -eq 4 ]
  grep -F -- "-C $FIXTURE_ROOT/repo config user.name Fixture" "$GIT_LOG" >/dev/null

  # A just-created fixture may not have a common dir yet. The canonical -C
  # destination is inside the fence, so this is safe rather than unprovable.
  : > "$GIT_LOG"
  FENCE_FAKE_NO_COMMON=1
  run_fence -C "$FIXTURE_ROOT/repo" config user.email fixture@trellis.invalid

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$GIT_LOG" | tr -d ' ')" -eq 2 ]
  grep -F -- "-C $FIXTURE_ROOT/repo config user.email fixture@trellis.invalid" "$GIT_LOG" >/dev/null

  # archive and hash-object without -w do not mutate repository state.
  : > "$GIT_LOG"
  FENCE_FAKE_NO_COMMON=0
  run_fence -C "$FIXTURE_ROOT/repo" archive HEAD
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run_fence -C "$FIXTURE_ROOT/repo" hash-object --stdin
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$GIT_LOG" | tr -d ' ')" -eq 2 ]

  # hash-object -w and write-tree write objects, so they require repository
  # identity proof even though neither updates refs, config, or the worktree.
  : > "$GIT_LOG"
  run_fence -C "$FIXTURE_ROOT/repo" hash-object -w --stdin
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run_fence -C "$FIXTURE_ROOT/repo" write-tree
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$GIT_LOG" | tr -d ' ')" -eq 8 ]
}

@test "installer ignores hostile inherited Python pin and installs with caller PATH Python" {
  make_install_harness
  real_python="$(python3 -c 'import os,sys; print(os.path.realpath(sys.executable))')"
  marker="$BATS_TEST_TMPDIR/hostile-python-called"
  hostile_python="$BATS_TEST_TMPDIR/hostile-python"
  printf '#!/bin/bash\n: > %q\nprintf "%%s\\n" %q\n' \
    "$marker" "$real_python" > "$hostile_python"
  chmod 700 "$hostile_python"

  cat > "$BATS_TEST_TMPDIR/python-driver.sh" <<'SH'
#!/bin/bash
set -euo pipefail
root=$1
bin=$2
[ "$TRELLIS_TEST_REAL_PYTHON" = "$EXPECTED_PYTHON" ]
[ -x "$bin/git" ] && [ -x "$bin/mktemp" ]
env -i PATH="$bin" git init -q "$root/repo"
[ -d "$root/repo/.git" ]
SH
  mkdir -p "$BATS_TEST_TMPDIR/python parent"
  run env TRELLIS_TEST_REAL_PYTHON="$hostile_python" \
    EXPECTED_PYTHON="$real_python" \
    /bin/bash "$BATS_TEST_TMPDIR/install-harness.sh" \
    "$CONTRACT_ROOT" "$BATS_TEST_TMPDIR/python parent" driver \
    "$BATS_TEST_TMPDIR/python-driver.sh"

  [ ! -e "$marker" ] || { echo "hostile inherited Python pin was executed"; false; }
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "installed launchers survive PATH-only scrubbing and overwrite caller forgeries" {
  make_install_harness
  cat > "$BATS_TEST_TMPDIR/launcher-driver.sh" <<'SH'
#!/bin/bash
set -uo pipefail
root=$1
bin=$2
outside=${root%/*}/outside-target
for tool in git mktemp python; do
  marker="$root/forged-$tool-called"
  fake="$root/fake-$tool"
  printf '#!/bin/bash\n: > %q\nexit 88\n' "$marker" > "$fake"
  chmod 700 "$fake"
done

TRELLIS_TEST_GIT_FENCE_ROOT="$outside" \
TRELLIS_TEST_REAL_GIT="$root/fake-git" \
TRELLIS_TEST_REAL_MKTEMP="$root/fake-mktemp" \
TRELLIS_TEST_REAL_PYTHON="$root/fake-python" \
env -i PATH="$bin" \
  TRELLIS_TEST_GIT_FENCE_ROOT="$outside" \
  TRELLIS_TEST_REAL_GIT="$root/fake-git" \
  TRELLIS_TEST_REAL_MKTEMP="$root/fake-mktemp" \
  TRELLIS_TEST_REAL_PYTHON="$root/fake-python" \
  git init -q "$root/repo"
[ -d "$root/repo/.git" ]
printf 'sentinel\n' > "$root/repo/file"
"$TRELLIS_TEST_REAL_GIT" -C "$root/repo" add file
"$TRELLIS_TEST_REAL_GIT" -C "$root/repo" -c user.name=Fixture \
  -c user.email=fixture@trellis.invalid -c core.hooksPath=/dev/null commit -qm seed
env -i PATH="$bin" git -C "$root/repo" worktree add -q -b scrub-safe \
  "$root/worktree" HEAD
[ -f "$root/worktree/file" ]

set +e
refusal=$(env -i PATH="$bin" git init -q "$outside" 2>&1)
refusal_status=$?
set -e
[ "$refusal_status" -eq 97 ]
case "$refusal" in *REFUSED*"outside test root"*) ;; *) exit 83 ;; esac
[ ! -e "$outside" ]

tmp=$(env -i PATH="$bin" \
  TRELLIS_TEST_GIT_FENCE_ROOT="$outside" \
  TRELLIS_TEST_REAL_GIT="$root/fake-git" \
  TRELLIS_TEST_REAL_MKTEMP="$root/fake-mktemp" \
  TRELLIS_TEST_REAL_PYTHON="$root/fake-python" \
  mktemp -d)
case "$tmp/" in "$root"/*) ;; *) exit 84 ;; esac
for tool in git mktemp python; do
  [ ! -e "$root/forged-$tool-called" ] || exit 85
done

"$TRELLIS_TEST_REAL_PYTHON" - "$root" "$bin" <<'PY_MODE'
from pathlib import Path
import os
import stat
import sys
root, bindir = map(Path, sys.argv[1:])
assert stat.S_IMODE(root.stat().st_mode) == 0o700
assert stat.S_IMODE(bindir.stat().st_mode) == 0o700
for name in ("git", "mktemp"):
    path = bindir / name
    assert path.is_file() and not path.is_symlink() and os.access(path, os.X_OK)
    assert stat.S_IMODE(path.stat().st_mode) == 0o700
    assert "trellis-test-fence-launcher-v1" in path.read_text()
PY_MODE
SH
  chmod 700 "$BATS_TEST_TMPDIR/launcher-driver.sh"

  mkdir -p "$BATS_TEST_TMPDIR/parent tmp"
  run /bin/bash "$BATS_TEST_TMPDIR/install-harness.sh" \
    "$CONTRACT_ROOT" "$BATS_TEST_TMPDIR/parent tmp" driver \
    "$BATS_TEST_TMPDIR/launcher-driver.sh"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "nested runner keeps inherited delegates and clean nested runner refuses before allocation" {
  make_install_harness

  mkdir -p "$BATS_TEST_TMPDIR/nested tmp" "$BATS_TEST_TMPDIR/clean parent" \
    "$BATS_TEST_TMPDIR/static-git-tmp" "$BATS_TEST_TMPDIR/static-mktemp-tmp"
  real_git="${TRELLIS_TEST_REAL_GIT:-$(command -v git)}"
  real_mktemp="${TRELLIS_TEST_REAL_MKTEMP:-$(command -v mktemp)}"
  real_python="${TRELLIS_TEST_REAL_PYTHON:-$(command -v python3)}"

  run env TRELLIS_TEST_REAL_GIT="$CONTRACT_ROOT/scripts/tests/helpers/git-fence/git" \
    TRELLIS_TEST_REAL_MKTEMP="$real_mktemp" TRELLIS_TEST_REAL_PYTHON="$real_python" \
    /bin/bash "$BATS_TEST_TMPDIR/install-harness.sh" \
    "$CONTRACT_ROOT" "$BATS_TEST_TMPDIR/static-git-tmp" nested
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"could not resolve the real Git executable"* ]] || { echo "$output"; false; }
  [ -z "$(/bin/ls -A "$BATS_TEST_TMPDIR/static-git-tmp")" ]

  run env TRELLIS_TEST_REAL_GIT="$real_git" \
    TRELLIS_TEST_REAL_MKTEMP="$CONTRACT_ROOT/scripts/tests/helpers/git-fence/mktemp" \
    TRELLIS_TEST_REAL_PYTHON="$real_python" \
    /bin/bash "$BATS_TEST_TMPDIR/install-harness.sh" \
    "$CONTRACT_ROOT" "$BATS_TEST_TMPDIR/static-mktemp-tmp" nested
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"could not resolve the real mktemp executable"* ]] || { echo "$output"; false; }
  [ -z "$(/bin/ls -A "$BATS_TEST_TMPDIR/static-mktemp-tmp")" ]

  run /bin/bash "$BATS_TEST_TMPDIR/install-harness.sh" \
    "$CONTRACT_ROOT" "$BATS_TEST_TMPDIR/nested tmp" nested
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  cat > "$BATS_TEST_TMPDIR/clean-driver.sh" <<'SH'
#!/bin/bash
set -uo pipefail
root=$1
bin=$2
clean_tmp=${root%/*}/clean-nested-tmp
mkdir -p "$clean_tmp"
set +e
output=$(env -i PATH="$bin" TMPDIR="$clean_tmp" \
  /bin/bash "$CONTRACT_SOURCE/scripts/run-tests.sh" --quick 2>&1)
status=$?
set -e
[ "$status" -eq 1 ]
case "$output" in *"could not resolve the real Git executable"*) ;; *) printf '%s\n' "$output"; exit 86 ;; esac
case "$output" in *"=== "*) printf '%s\n' "$output"; exit 87 ;; esac
[ -z "$(/bin/ls -A "$clean_tmp")" ]
SH
  chmod 700 "$BATS_TEST_TMPDIR/clean-driver.sh"
  run env CONTRACT_SOURCE="$CONTRACT_ROOT" \
    /bin/bash "$BATS_TEST_TMPDIR/install-harness.sh" \
    "$CONTRACT_ROOT" "$BATS_TEST_TMPDIR/clean parent" driver \
    "$BATS_TEST_TMPDIR/clean-driver.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "actual Git worktree operations preserve outside paths and permit fenced destinations" {
  run python3 - "$BATS_TEST_TMPDIR" "$FENCE" "${TRELLIS_TEST_REAL_GIT:-$(command -v git)}" <<'PY_LIVE'
import os
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]) / "actual-git"
fence, real_git = sys.argv[2:]
inside, outside = root / "inside", root / "outside"
repo = inside / "repo"
repo.mkdir(parents=True)
outside.mkdir()
env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)

def git(*args):
    return subprocess.run([real_git, "-C", str(repo), *args], env=env, capture_output=True, text=True, check=True)

def guarded(*args, expected=0):
    result = subprocess.run([fence, "-C", str(repo), *args], env={**env, "TRELLIS_TEST_GIT_FENCE_ROOT": str(inside), "TRELLIS_TEST_REAL_GIT": real_git}, capture_output=True, text=True)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)

git("init", "-q")
git("config", "user.name", "Fixture")
git("config", "user.email", "fixture@trellis.invalid")
(repo / "file").write_text("sentinel\n")
git("add", "file")
git("-c", "core.hooksPath=/dev/null", "commit", "-qm", "seed")
external = outside / "external-tree"
git("worktree", "add", "-q", str(external), "-b", "outside-fence")
for target in (str(external), "external-tree"):
    guarded("worktree", "remove", target, expected=97)
assert (external / "file").read_text() == "sentinel\n"
# Remove only this test-owned scratch tree using the real binary so the next
# assertions exercise a registry containing entirely fenced paths.
git("worktree", "remove", str(external))
local = inside / "inside-tree"
guarded("worktree", "add", "-b", "fenced-branch", str(local), "HEAD")
guarded("worktree", "lock", "--reason", "fixture lock reason", str(local))
guarded("worktree", "unlock", str(local))
guarded("worktree", "move", str(local), str(outside / "moved"), expected=97)
assert (local / "file").read_text() == "sentinel\n"
moved = inside / "moved"
guarded("worktree", "move", str(local), str(moved))
guarded("worktree", "remove", "moved")
assert not moved.exists()
guarded("worktree", "add", "--unknown-option", str(inside / "bad"), expected=97)
guarded("worktree", "add", "--", str(outside / "new"), expected=97)
assert not (outside / "new").exists()
PY_LIVE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
