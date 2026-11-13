#!/usr/bin/env bash
# Shared behavioral cases for the Claude and Codex primer-nudge suites.
# The caller supplies HOOK, PROJECT_DIR, run_hook, and context. All temporary
# files and the fake git live outside the fixture repository.
PCN_PROCESS_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/primer-capture-nudge-process.py"

pcn_isolate_environment() {
  # Keep common language-manager shims usable after isolating HOME. Neither
  # these tests nor a failing hook should write the operator's global state.
  if [ -z "${PYENV_ROOT:-}" ] && [ -d "${HOME:-}/.pyenv" ]; then
    export PYENV_ROOT="$HOME/.pyenv"
  fi
  if [ -z "${ASDF_DATA_DIR:-}" ] && [ -d "${HOME:-}/.asdf" ]; then
    export ASDF_DATA_DIR="$HOME/.asdf"
  fi
  export HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" CODEX_HOME="$BATS_TEST_TMPDIR/codex-home"
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-config"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  unset BASH_ENV ENV PYTHONPATH PYTHONHOME PYTHONOPTIMIZE
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
  unset GIT_TRACE GIT_TRACE_SETUP GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE2_PERF
  mkdir -p "$HOME"
}

# Optional test-only override, including for a standalone `git show` copy. Use
# this suite's checked-in sibling libraries in a private deployment, never a
# hook or library in the fixture project (which would change the scan inputs).
pcn_prepare_hook() {
  [ -n "${PRIMER_TEST_HOOK:-}" ] || return 0
  [ -f "$PRIMER_TEST_HOOK" ] || {
    printf 'PRIMER_TEST_HOOK is not a file: %s\n' "$PRIMER_TEST_HOOK" >&2
    return 1
  }
  local deploy="$BATS_TEST_TMPDIR/primer-hook-copy"
  mkdir -p "$deploy"
  cp -R "${HOOK%/*}/lib" "$deploy/lib"
  cp "$PRIMER_TEST_HOOK" "$deploy/primer-capture-nudge.sh"
  HOOK="$deploy/primer-capture-nudge.sh"
}

pcn_process_case() {
  python3 "$PCN_PROCESS_HELPER" "$1" "$HOOK" "$PROJECT_DIR" "$BATS_TEST_TMPDIR"
}

# Unlike command substitution, these files preserve trailing blank stderr
# lines, so the degradation assertions really do check exactly one line.
pcn_run_recorded() {
  PCN_STDOUT_FILE="$BATS_TEST_TMPDIR/primer-bound.stdout"
  PCN_STDERR_FILE="$BATS_TEST_TMPDIR/primer-bound.stderr"
  if bash "$HOOK" >"$PCN_STDOUT_FILE" 2>"$PCN_STDERR_FILE" <<<'{}'; then
    status=0
  else
    status=$?
  fi
  # Read by the caller's context() and Bats assertions.
  # shellcheck disable=SC2034
  output="$(<"$PCN_STDOUT_FILE")"
  stderr="$(<"$PCN_STDERR_FILE")"
}

pcn_assert_one_stderr_line() {
  [ "$(wc -l < "$PCN_STDERR_FILE" | tr -d '[:space:]')" = 1 ]
  [ "$(awk 'END { print NR + 0 }' "$PCN_STDERR_FILE")" = 1 ]
  grep -F "$1" "$PCN_STDERR_FILE" >/dev/null
}

pcn_make_tracked_changes() {
  local count="$1" i path
  mkdir -p "$PROJECT_DIR/src"
  i=1
  while [ "$i" -le "$count" ]; do
    printf -v path 'src/change-%03d.py' "$i"
    printf 'before\n' > "$PROJECT_DIR/$path"
    i=$((i + 1))
  done
  git -C "$PROJECT_DIR" add src
  git -C "$PROJECT_DIR" commit -q -m 'seed tracked scan boundary'
  i=1
  while [ "$i" -le "$count" ]; do
    printf -v path 'src/change-%03d.py' "$i"
    printf 'after\n' >> "$PROJECT_DIR/$path"
    i=$((i + 1))
  done
}

pcn_exact_200_case() {
  pcn_make_tracked_changes 200
  pcn_run_recorded
  [ "$status" -eq 0 ]
  [ ! -s "$PCN_STDERR_FILE" ]
  case "$(context)" in *'/primer change-001'*) ;; *) return 1 ;; esac
}

pcn_exact_201_case() {
  pcn_make_tracked_changes 201
  pcn_run_recorded
  [ "$status" -eq 0 ]
  pcn_assert_one_stderr_line 'scan limit'
}

pcn_mixed_boundary_case() {
  pcn_make_tracked_changes 199
  mkdir -p "$PROJECT_DIR/src/newthing"
  printf 'one\n' > "$PROJECT_DIR/src/newthing/one.py"
  pcn_run_recorded
  [ "$status" -eq 0 ]
  [ ! -s "$PCN_STDERR_FILE" ]
  [ -s "$PCN_STDOUT_FILE" ]
  printf 'two\n' > "$PROJECT_DIR/src/newthing/two.py"
  pcn_run_recorded
  [ "$status" -eq 0 ]
  [ ! -s "$PCN_STDOUT_FILE" ]
  pcn_assert_one_stderr_line 'scan limit'
}

pcn_nested_ignore_case() {
  # The nested .gitignore itself and only.py are the only two visible paths.
  # In particular, a collapsed --directory result must not make the ignored
  # children appear changed when it is expanded.
  printf 'src/ignored-root/\n' > "$PROJECT_DIR/.gitignore"
  git -C "$PROJECT_DIR" add .gitignore
  git -C "$PROJECT_DIR" commit -q -m 'seed root ignore'
  mkdir -p "$PROJECT_DIR/src/new-subsystem/nested" "$PROJECT_DIR/src/ignored-root"
  printf '*.py\n!keep.py\n' > "$PROJECT_DIR/src/new-subsystem/nested/.gitignore"
  printf 'keep\n' > "$PROJECT_DIR/src/new-subsystem/only.py"
  printf 'ignored\n' > "$PROJECT_DIR/src/new-subsystem/nested/one.py"
  printf 'ignored\n' > "$PROJECT_DIR/src/new-subsystem/nested/two.py"
  printf 'ignored\n' > "$PROJECT_DIR/src/new-subsystem/nested/three.py"
  printf 'ignored\n' > "$PROJECT_DIR/src/ignored-root/one.py"
  printf 'ignored\n' > "$PROJECT_DIR/src/ignored-root/two.py"
  printf 'ignored\n' > "$PROJECT_DIR/src/ignored-root/three.py"

  pcn_run_recorded
  [ "$status" -eq 0 ]
  [ ! -s "$PCN_STDOUT_FILE" ]
  [ ! -s "$PCN_STDERR_FILE" ]

  # A negated ignore rule must restore this third visible path. Treating the
  # matching negation as an ignored file would leave the tree below threshold.
  printf 'keep\n' > "$PROJECT_DIR/src/new-subsystem/nested/keep.py"
  pcn_run_recorded
  [ "$status" -eq 0 ]
  [ ! -s "$PCN_STDERR_FILE" ]
  case "$(context)" in *'/primer new-subsystem'*) ;; *) return 1 ;; esac
  case "$(context)" in *'/primer ignored-root'*) return 1 ;; esac
}

pcn_ignored_bulk_case() {
  printf 'node_modules/\n' > "$PROJECT_DIR/.gitignore"
  git -C "$PROJECT_DIR" add .gitignore
  git -C "$PROJECT_DIR" commit -q -m 'seed ignored dependency tree'
  mkdir -p "$PROJECT_DIR/newpkg/src" "$PROJECT_DIR/newpkg/node_modules"
  printf 'a\n' > "$PROJECT_DIR/newpkg/src/a.py"
  printf 'b\n' > "$PROJECT_DIR/newpkg/src/b.py"
  printf 'c\n' > "$PROJECT_DIR/newpkg/src/c.py"
  python3 - "$PROJECT_DIR/newpkg/node_modules" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for i in range(300):
    (root / ("dependency-%04d.js" % i)).write_text("ignored\n")
PY
  pcn_run_recorded
  [ "$status" -eq 0 ]
  [ ! -s "$PCN_STDERR_FILE" ] || { printf '%s\n' "$stderr" >&2; return 1; }
  case "$(context)" in *'/primer newpkg'*) ;; *) return 1 ;; esac
}

pcn_nested_repo_bulk_case() {
  mkdir -p "$PROJECT_DIR/newpkg/src" "$PROJECT_DIR/newpkg/vendor"
  git -C "$PROJECT_DIR/newpkg/vendor" init -q
  printf 'a\n' > "$PROJECT_DIR/newpkg/src/a.py"
  printf 'b\n' > "$PROJECT_DIR/newpkg/src/b.py"
  printf 'c\n' > "$PROJECT_DIR/newpkg/src/c.py"
  python3 - "$PROJECT_DIR/newpkg/vendor" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for i in range(300):
    (root / ("vendor-%04d.js" % i)).write_text("nested\n")
PY
  pcn_run_recorded
  [ "$status" -eq 0 ]
  [ ! -s "$PCN_STDERR_FILE" ] || { printf '%s\n' "$stderr" >&2; return 1; }
  case "$(context)" in *'/primer newpkg'*) ;; *) return 1 ;; esac
}

pcn_literal_root_case() {
  mkdir -p "$PROJECT_DIR/pkg[ab]"
  printf 'a\n' > "$PROJECT_DIR/pkg[ab]/a.py"
  printf 'b\n' > "$PROJECT_DIR/pkg[ab]/b.py"
  printf 'c\n' > "$PROJECT_DIR/pkg[ab]/c.py"
  pcn_run_recorded
  [ "$status" -eq 0 ]
  [ ! -s "$PCN_STDERR_FILE" ]
  case "$(context)" in *'/primer pkg-ab'*) ;; *) return 1 ;; esac
}

pcn_untracked_spaces_and_lines_case() {
  local path="$PROJECT_DIR/src/space subsystem/large file.py" i
  mkdir -p "${path%/*}"
  i=1
  while [ "$i" -le 199 ]; do
    printf 'line %s\n' "$i" >> "$path"
    i=$((i + 1))
  done
  pcn_run_recorded
  [ "$status" -eq 0 ]
  [ ! -s "$PCN_STDOUT_FILE" ]
  [ ! -s "$PCN_STDERR_FILE" ]

  printf 'line 200\n' >> "$path"
  pcn_run_recorded
  [ "$status" -eq 0 ]
  [ ! -s "$PCN_STDERR_FILE" ]
  case "$(context)" in *'/primer space-subsystem'*) ;; *) return 1 ;; esac
}

pcn_pipe_signals_case() {
  local fakebin="$BATS_TEST_TMPDIR/primer-signal-bin" real_git old_path
  mkdir -p "$PROJECT_DIR/src/known" "$fakebin"
  python3 - "$PROJECT_DIR/src/known" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for i in range(400):
    (root / ("file-%04d.py" % i)).write_text("x = 1\n")
PY
  real_git="$(command -v git)"
  cat > "$fakebin/git" <<'EOF'
#!/bin/bash
ulimit -c 0
if [[ " $* " == *" ls-files "* && " $* " == *" --others "* ]]; then
  for sig in PIPE XFSZ; do
    if /bin/bash -c 'kill -s "$1" "$$"' _ "$sig" >/dev/null 2>&1; then
      printf 'ignored ' >> "$PCN_SIGNAL_MARKER"
    else
      printf 'default ' >> "$PCN_SIGNAL_MARKER"
    fi
  done
  printf '\n' >> "$PCN_SIGNAL_MARKER"
fi
exec "$PCN_REAL_GIT" "$@"
EOF
  chmod +x "$fakebin/git"
  export PCN_REAL_GIT="$real_git" PCN_SIGNAL_MARKER="$BATS_TEST_TMPDIR/primer-pipe-signals"
  old_path="$PATH"
  PATH="$fakebin:$PATH"
  pcn_run_recorded
  PATH="$old_path"
  [ "$status" -eq 0 ]
  pcn_assert_one_stderr_line 'scan limit'
  [ -s "$PCN_SIGNAL_MARKER" ]
  if grep -v '^default default $' "$PCN_SIGNAL_MARKER"; then
    printf 'Git inherited ignored PIPE or XFSZ\n' >&2
    return 1
  fi
  unset PCN_REAL_GIT PCN_SIGNAL_MARKER
}

pcn_output_limit_case() {
  local i slug
  i=1
  while [ "$i" -le 3 ]; do
    printf -v slug 'long-%0170d' "$i"
    mkdir -p "$PROJECT_DIR/src/$slug"
    printf 'changed\n' > "$PROJECT_DIR/src/$slug/file.py"
    i=$((i + 1))
  done
  pcn_run_recorded
  [ "$status" -eq 0 ]
  [ ! -s "$PCN_STDOUT_FILE" ]
  pcn_assert_one_stderr_line 'atomic output limit'
}

pcn_fsmonitor_disabled_case() {
  local hook="$BATS_TEST_TMPDIR/primer-fsmonitor.sh"
  cat > "$hook" <<'EOF'
#!/bin/bash
: > "$PCN_FSMONITOR_MARKER"
exit 0
EOF
  chmod +x "$hook"
  make_unknown_files
  git -C "$PROJECT_DIR" config core.fsmonitor "$hook"
  export PCN_FSMONITOR_MARKER="$BATS_TEST_TMPDIR/primer-fsmonitor-called"
  pcn_run_recorded
  [ "$status" -eq 0 ]
  [ ! -e "$PCN_FSMONITOR_MARKER" ]
  [ ! -s "$PCN_STDERR_FILE" ]
  case "$(context)" in *'/primer new-subsystem'*) ;; *) return 1 ;; esac
  unset PCN_FSMONITOR_MARKER
}

pcn_untracked_symlink_lines_case() {
  local i
  i=1
  while [ "$i" -le 200 ]; do
    printf 'line %s\n' "$i" >> "$PROJECT_DIR/target.txt"
    i=$((i + 1))
  done
  git -C "$PROJECT_DIR" add target.txt
  git -C "$PROJECT_DIR" commit -q -m 'seed symlink target'
  mkdir -p "$PROJECT_DIR/src/linked"
  ln -s ../../target.txt "$PROJECT_DIR/src/linked/alias.py"
  pcn_run_recorded
  [ "$status" -eq 0 ]
  [ ! -s "$PCN_STDERR_FILE" ]
  case "$(context)" in *'/primer linked'*) ;; *) return 1 ;; esac
}

pcn_subdirectory_tracked_case() {
  local name previous
  mkdir -p "$PROJECT_DIR/child" "$PROJECT_DIR/src/billing"
  for name in a b c; do printf 'before\n' > "$PROJECT_DIR/src/billing/$name.py"; done
  git -C "$PROJECT_DIR" add src/billing
  git -C "$PROJECT_DIR" commit -q -m 'seed sibling changes'
  for name in a b c; do printf 'after\n' >> "$PROJECT_DIR/src/billing/$name.py"; done
  if [ -n "${CODEX_PROJECT_DIR:-}" ]; then
    previous="$CODEX_PROJECT_DIR"
    export CODEX_PROJECT_DIR="$PROJECT_DIR/child"
    pcn_run_recorded
    export CODEX_PROJECT_DIR="$previous"
  else
    previous="$CLAUDE_PROJECT_DIR"
    export CLAUDE_PROJECT_DIR="$PROJECT_DIR/child"
    pcn_run_recorded
    export CLAUDE_PROJECT_DIR="$previous"
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$PCN_STDERR_FILE" ]
  case "$(context)" in *'/primer billing'*) ;; *) return 1 ;; esac
}

pcn_tracked_spaces_case() {
  local name
  mkdir -p "$PROJECT_DIR/src/tracked area"
  for name in 'one file.py' 'two file.py' 'three file.py'; do
    printf 'before\n' > "$PROJECT_DIR/src/tracked area/$name"
  done
  git -C "$PROJECT_DIR" add 'src/tracked area'
  git -C "$PROJECT_DIR" commit -q -m 'seed tracked paths with spaces'
  for name in 'one file.py' 'two file.py' 'three file.py'; do
    printf 'after\n' >> "$PROJECT_DIR/src/tracked area/$name"
  done
  pcn_run_recorded
  [ "$status" -eq 0 ]
  [ ! -s "$PCN_STDERR_FILE" ]
  case "$(context)" in *'/primer tracked-area'*) ;; *) return 1 ;; esac
}
