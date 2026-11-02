#!/usr/bin/env bats
# Regression coverage for the canonical suite's Git mutation boundary.
#
# Most cases use FAKE_GIT to record argv and answer the fence's read-only
# identity probes. The actual-Git case below mutates only sandbox repositories.

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
    TRELLIS_TEST_REAL_PYTHON="${FENCE_PYTHON:-${TRELLIS_TEST_REAL_PYTHON:-}}" \
    FENCE_GIT_LOG="$GIT_LOG" \
    FENCE_FAKE_COMMON_DIR="$FENCE_FAKE_COMMON_DIR" \
    FENCE_FAKE_NO_COMMON="${FENCE_FAKE_NO_COMMON:-0}" \
    GIT_DIR="${FENCE_INHERITED_GIT_DIR:-}" \
    bash "$FENCE" "$@"
}

make_install_harness() {
  CONTRACT_ROOT="$BATS_TEST_TMPDIR/contract source"
  mkdir -p "$CONTRACT_ROOT/scripts/tests/helpers/git-fence" "$CONTRACT_ROOT/scripts/lib"
  cp "$RUNNER" "$CONTRACT_ROOT/scripts/run-tests.sh"
  cp "$REPO_ROOT/scripts/lib/test-suites.sh" "$CONTRACT_ROOT/scripts/lib/test-suites.sh"
  cp "$REPO_ROOT/scripts/lib/trellis-python.sh" "$CONTRACT_ROOT/scripts/lib/trellis-python.sh"
  cp "$REPO_ROOT/scripts/tests/helpers/git-fence/git" "$CONTRACT_ROOT/scripts/tests/helpers/git-fence/git"
  cp "$REPO_ROOT/scripts/tests/helpers/git-fence/mktemp" "$CONTRACT_ROOT/scripts/tests/helpers/git-fence/mktemp"

  python3 -I - "$RUNNER" "$BATS_TEST_TMPDIR/install-harness.sh" <<'PY_HARNESS'
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
  run_fence -C "$FIXTURE_ROOT/repo" mktag
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

  # hash-object -w, write-tree and mktag write objects, so they require
  # repository identity proof even though none updates refs, config, or the
  # worktree.
  : > "$GIT_LOG"
  run_fence -C "$FIXTURE_ROOT/repo" hash-object -w --stdin
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run_fence -C "$FIXTURE_ROOT/repo" write-tree
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run_fence -C "$FIXTURE_ROOT/repo" mktag
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$GIT_LOG" | tr -d ' ')" -eq 12 ]
}

@test "existing directory routes use shell resolution without starting Python" {
  mkdir -p "$FIXTURE_ROOT/repo/.git"
  ln -s "$FIXTURE_ROOT/repo" "$FIXTURE_ROOT/repo-link"
  FENCE_FAKE_COMMON_DIR="$FIXTURE_ROOT/repo-link/.git"
  FENCE_PYTHON="$BATS_TEST_TMPDIR/no-python"
  printf '#!/bin/bash\nexit 88\n' > "$FENCE_PYTHON"
  chmod 700 "$FENCE_PYTHON"
  cd "$FIXTURE_ROOT"

  run_fence -C repo-link --git-dir .git --work-tree "$FIXTURE_ROOT/repo-link" config user.name Fixture

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -F -- 'config user.name Fixture' "$GIT_LOG" >/dev/null
}

@test "missing destinations retain the Python resolver fallback" {
  FENCE_FAKE_COMMON_DIR="$FIXTURE_ROOT/repo/.git"
  FENCE_PYTHON="$BATS_TEST_TMPDIR/python-spy"
  export FENCE_REAL_PYTHON="${TRELLIS_TEST_REAL_PYTHON:-$(command -v python3)}"
  export FENCE_PYTHON_LOG="$BATS_TEST_TMPDIR/python.log"
  cat > "$FENCE_PYTHON" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FENCE_PYTHON_LOG"
exec "$FENCE_REAL_PYTHON" "$@"
SH
  chmod 700 "$FENCE_PYTHON"

  run_fence init "$FIXTURE_ROOT/new/nested-repo"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -F -- "-I - $FIXTURE_ROOT/new/nested-repo" "$FENCE_PYTHON_LOG" >/dev/null
  grep -F -- "init $FIXTURE_ROOT/new/nested-repo" "$GIT_LOG" >/dev/null
}

@test "symlinked directories and config files cannot escape the fixture" {
  FENCE_FAKE_COMMON_DIR="$FIXTURE_ROOT/repo/.git"
  FENCE_FAKE_NO_COMMON=1
  ln -s "$OUTSIDE_ROOT" "$FIXTURE_ROOT/outside-link"
  printf 'sentinel\n' > "$OUTSIDE_ROOT/config"
  ln -s "$OUTSIDE_ROOT/config" "$FIXTURE_ROOT/config-link"
  ln -s "$OUTSIDE_ROOT/not-created" "$FIXTURE_ROOT/dangling-link"

  for target in outside-link/new dangling-link/new; do
    run_fence init "$FIXTURE_ROOT/$target"
    [ "$status" -eq 97 ] || { echo "$output"; false; }
    [[ "$output" == *"outside test root"* ]]
  done
  run_fence -C "$FIXTURE_ROOT/outside-link" config user.name Fixture
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  run_fence config --file "$FIXTURE_ROOT/config-link" user.name Fixture
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [ "$(< "$OUTSIDE_ROOT/config")" = sentinel ]
  run grep -E ' (init|config|clean)( |$)' "$GIT_LOG"
  [ "$status" -eq 1 ]
}

@test "dot segments and relative chained C routes cannot escape the fixture" {
  FENCE_FAKE_COMMON_DIR="$FIXTURE_ROOT/repo/.git"
  FENCE_FAKE_NO_COMMON=1
  mkdir -p "$FIXTURE_ROOT/subdir"
  cd "$FIXTURE_ROOT"

  run_fence init "../operator-repo/new"
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  run_fence -C subdir -C ../../operator-repo config user.name Fixture
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  run_fence -Csubdir -C../../operator-repo config user.name Fixture
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  run_fence config --file "./subdir/../../operator-repo/config" user.name Fixture
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  run grep -E ' (init|config|clean)( |$)' "$GIT_LOG"
  [ "$status" -eq 1 ]
}

@test "relative git-dir work-tree and inherited GIT_DIR symlink escapes are refused" {
  FENCE_FAKE_COMMON_DIR="$FIXTURE_ROOT/repo/.git"
  ln -s "$OUTSIDE_ROOT" "$FIXTURE_ROOT/escape"
  cd "$FIXTURE_ROOT"

  run_fence -C "$FIXTURE_ROOT" --git-dir escape config user.name Fixture
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  run_fence -C "$FIXTURE_ROOT" --git-dir=escape config user.name Fixture
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  run_fence -C "$FIXTURE_ROOT" --work-tree escape clean -fd
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  run_fence -C "$FIXTURE_ROOT" --work-tree=escape clean -fd
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  FENCE_INHERITED_GIT_DIR=escape
  run_fence -C "$FIXTURE_ROOT" init --bare "$FIXTURE_ROOT/new.git"
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [ ! -s "$GIT_LOG" ]
}

@test "actual Git cannot traverse symlink parents through destinations or routing options" {
  mkdir -p "$OUTSIDE_ROOT/deep"
  ln -s "$OUTSIDE_ROOT/deep" "$FIXTURE_ROOT/link"
  FAKE_GIT="${TRELLIS_TEST_REAL_GIT:-$(command -v git)}"
  FENCE_FAKE_COMMON_DIR=""

  run_fence init -q "$FIXTURE_ROOT/link/../escaped-repo"
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  run_fence -C "$FIXTURE_ROOT/link/.." init -q escaped-cwd
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  run_fence --git-dir="$FIXTURE_ROOT/link/../outside.git" init --bare "$FIXTURE_ROOT/new.git"
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  run_fence --work-tree="$FIXTURE_ROOT/link/../outside-tree" clean -fd
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  run_fence config --file "$FIXTURE_ROOT/link/../config" user.name Fixture
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  FENCE_INHERITED_GIT_DIR="$FIXTURE_ROOT/link/../inherited.git"
  run_fence init --bare "$FIXTURE_ROOT/another.git"
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [ ! -e "$OUTSIDE_ROOT/escaped-repo" ]
  [ ! -e "$OUTSIDE_ROOT/escaped-cwd" ]
  [ ! -e "$OUTSIDE_ROOT/outside.git" ]
  [ ! -e "$OUTSIDE_ROOT/inherited.git" ]
  [ ! -e "$OUTSIDE_ROOT/config" ]
}

@test "shell resolver matches Python for symlinks dot segments and unusual paths" {
  run python3 -I - "$BATS_TEST_TMPDIR" "$FENCE" "$FAKE_GIT" <<'PY_PATHS'
import os
from pathlib import Path
import shutil
import subprocess
import sys

root, fence, git = map(Path, sys.argv[1:])
inside, outside = root / "inside", root / "outside"
for directory in (inside / "dir", outside / "dir"):
    directory.mkdir(parents=True)
(inside / "link").symlink_to(outside / "dir")
(inside / "dangling").symlink_to(outside / "missing")
(inside / "loop").symlink_to("loop")
(inside / "file").write_text("fixture\n")
for name in ("space dir", "tab\tdir", "line\ndir", "trailing\n", "-", "-dash", "[glob]"):
    (inside / name).mkdir()
# Use the checked-in function body rather than a second shell implementation.
prefix = fence.read_text().split('\nFENCE_ROOT="$(canonical_path', 1)[0]
driver = root / "resolver.sh"
driver.write_text(prefix + '''
for path in "$@"; do
  resolved="$(canonical_path "$path")" || exit $?
  printf '%s\\0' "$resolved"
done
''')
paths = ["", ".", "..", "-", "/", "//", "///", str(inside) + "/"]
for base in (inside, outside, inside / "link", inside / "dangling", inside / "loop", inside / "file"):
    for suffix in ("", "/.", "/..", "/../dir", "/missing/../dir", "/./dir", "//dir", "/new/child"):
        absolute = str(base) + suffix
        paths.extend((absolute, os.path.relpath(base, inside) + suffix))
paths.extend(str(path) for path in inside.iterdir())
os.chdir(inside)
expected = [os.path.realpath(path).rstrip("\n") for path in paths]
env = dict(os.environ, TRELLIS_TEST_GIT_FENCE_ROOT=str(inside), TRELLIS_TEST_REAL_GIT=str(git), CDPATH=str(outside), OLDPWD=str(outside))
for bash in dict.fromkeys(("/bin/bash", shutil.which("bash"))):
    result = subprocess.run([bash, str(driver), *paths], cwd=inside, env=env, capture_output=True, check=True)
    actual = [os.fsdecode(value) for value in result.stdout.split(b"\0")[:-1]]
    assert actual == expected, [(path, want, got) for path, want, got in zip(paths, expected, actual) if want != got]
    print(bash, len(paths), "paths matched")
PY_PATHS
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "installer ignores hostile fence Python pin and installs with the shared resolver" {
  make_install_harness
  real_python="$(
    . "$REPO_ROOT/scripts/lib/trellis-python.sh"
    TRELLIS_HOME=/dev/null trellis_python &&
      "$TRELLIS_PYTHON" -I -c 'import os,sys; print(os.path.realpath(sys.executable))'
  )"
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

"$TRELLIS_TEST_REAL_PYTHON" -I - "$root" "$bin" <<'PY_MODE'
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
  run python3 -I - "$BATS_TEST_TMPDIR" "$FENCE" "${TRELLIS_TEST_REAL_GIT:-$(command -v git)}" <<'PY_LIVE'
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
    result = subprocess.run(["bash", fence, "-C", str(repo), *args], env={**env, "TRELLIS_TEST_GIT_FENCE_ROOT": str(inside), "TRELLIS_TEST_REAL_GIT": real_git}, capture_output=True, text=True)
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
guarded("worktree", "add", "-battached-branch", str(inside / "attached-tree"), "HEAD")
assert (inside / "attached-tree" / "file").read_text() == "sentinel\n"
guarded("worktree", "add", "-Battached-outside", str(outside / "attached-out"), "HEAD", expected=97)
assert not (outside / "attached-out").exists()
guarded("worktree", "add", "--unknown-option", str(inside / "bad"), expected=97)
guarded("worktree", "add", "--", str(outside / "new"), expected=97)
assert not (outside / "new").exists()
PY_LIVE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
