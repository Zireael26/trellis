#!/usr/bin/env bats

setup() {
  HOOK="$BATS_TEST_DIRNAME/../lib/aeo-gate-warn.sh"
  REPO="$BATS_TEST_TMPDIR/repo"
  RUNNER="$BATS_TEST_TMPDIR/run-diff"
  CALLS="$BATS_TEST_TMPDIR/calls"
  unset AEO_TEST_RESULT AEO_TEST_EXIT
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email test@example.test
  git -C "$REPO" config user.name "AEO Test"
  printf 'base\n' >"$REPO/page.tsx"
  git -C "$REPO" add page.tsx
  git -C "$REPO" commit -qm base
  printf 'changed\n' >>"$REPO/page.tsx"
  git -C "$REPO" commit -qam changed
  printf '{"schema":"aeo-gate.baseline.v1"}\n' >"$REPO/baseline.json"
  cat >"$RUNNER" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$AEO_TEST_CALLS"
printf '%s\n' "${AEO_TEST_RESULT:-AEO warn-only: status=PASS; merge_policy=non-blocking}"
exit "${AEO_TEST_EXIT:-0}"
EOF
  chmod +x "$RUNNER"
  export AEO_GATE_RANGE=HEAD~1..HEAD
  export AEO_GATE_RUNNER="$RUNNER"
  export AEO_TEST_CALLS="$CALLS"
}

write_config() {
  local enabled="$1" baseline="${2:-baseline.json}"
  cat >"$REPO/.trellis.config.json" <<EOF
{
  "aeo_gate": {
    "enabled": $enabled,
    "project": "fixture",
    "url": "https://example.test",
    "marker_file": "page.tsx",
    "marker": "changed",
    "baseline": "$baseline"
  }
}
EOF
}

run_hook() {
  run bash -c 'cd "$1" && bash "$2"' _ "$REPO" "$HOOK"
}

link_python3() {
  # The real interpreter, never a PATH shim: pyenv's python3 is a bash script
  # that cannot start on a PATH without bash (R44). The hook itself still
  # resolves python3 from PATH; only the test's link target changes.
  ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$1/python3"
}

@test "disabled-default gate is byte-silent and does not invoke runner" {
  write_config false
  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$CALLS" ]
}

@test "missing accepted baseline warns exactly once and never blocks" {
  write_config true missing.json
  run_hook
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^\[aeo-gate\]')" -eq 1 ]
  [[ "$output" == *"status=INDETERMINATE"* ]] || { echo "$output"; false; }
  [[ "$output" == *"accepted baseline missing"* ]] || { echo "$output"; false; }
  [ ! -e "$CALLS" ]
}

@test "regression verdict is visible exactly once and remains non-blocking" {
  write_config true
  export AEO_TEST_RESULT='AEO warn-only: status=REGRESSION; new=1; unchanged=2; resolved=0; merge_policy=non-blocking'
  run_hook
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^\[aeo-gate\]')" -eq 1 ]
  [[ "$output" == *"status=REGRESSION"* ]] || { echo "$output"; false; }
  [[ "$output" == *"merge_policy=non-blocking"* ]] || { echo "$output"; false; }
  [ "$(wc -l <"$CALLS")" -eq 1 ]
}

@test "runner failure collapses to one indeterminate non-blocking verdict" {
  write_config true
  export AEO_TEST_RESULT=$'first failure line\nsecond failure line'
  export AEO_TEST_EXIT=2
  run_hook
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^\[aeo-gate\]')" -eq 1 ]
  [[ "$output" == *"status=INDETERMINATE"* ]] || { echo "$output"; false; }
  [[ "$output" == *"diff runner failed"* ]]
}

@test "irrelevant diff is silent and does not invoke runner" {
  write_config true
  printf 'text\n' >"$REPO/data.json"
  git -C "$REPO" add data.json
  git -C "$REPO" commit -qm data
  export AEO_GATE_RANGE=HEAD~1..HEAD
  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$CALLS" ]
}

@test "Astro page diff invokes warn-only runner" {
  write_config true
  printf '<h1>changed</h1>\n' >"$REPO/page.astro"
  git -C "$REPO" add page.astro
  git -C "$REPO" commit -qm astro
  export AEO_GATE_RANGE=HEAD~1..HEAD
  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=PASS"* ]] || { echo "$output"; false; }
  [ "$(wc -l <"$CALLS")" -eq 1 ]
}

@test "page rename to non-page suffix still invokes warn-only runner" {
  write_config true
  git -C "$REPO" mv page.tsx page.txt
  git -C "$REPO" commit -qm rename
  export AEO_GATE_RANGE=HEAD~1..HEAD
  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=PASS"* ]] || { echo "$output"; false; }
  [ "$(wc -l <"$CALLS")" -eq 1 ]
}

@test "malformed enabled flag warns exactly once and never blocks" {
  printf '{"aeo_gate":{"enabled":"yes"}}\n' >"$REPO/.trellis.config.json"
  run_hook
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^\[aeo-gate\]')" -eq 1 ]
  [[ "$output" == *"status=INDETERMINATE"* ]] || { echo "$output"; false; }
  [[ "$output" == *"malformed enabled flag"* ]] || { echo "$output"; false; }
  [ ! -e "$CALLS" ]
}

@test "unavailable runner warns exactly once and never blocks" {
  write_config true
  export AEO_GATE_RUNNER="$BATS_TEST_TMPDIR/missing-runner"
  run_hook
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^\[aeo-gate\]')" -eq 1 ]
  [[ "$output" == *"status=INDETERMINATE"* ]] || { echo "$output"; false; }
  [[ "$output" == *"runner unavailable"* ]] || { echo "$output"; false; }
  [ ! -e "$CALLS" ]
}

@test "runner wall-clock timeout warns exactly once and never blocks" {
  write_config true
  cat >"$RUNNER" <<'EOF'
#!/usr/bin/env bash
exec sleep 5
EOF
  chmod +x "$RUNNER"
  export AEO_GATE_HOOK_TIMEOUT=1
  run_hook
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^\[aeo-gate\]')" -eq 1 ]
  [[ "$output" == *"status=INDETERMINATE"* ]] || { echo "$output"; false; }
  [[ "$output" == *"exceeded 1s wall-clock budget"* ]]
}

@test "stripped-PATH python3 is a real interpreter even behind a bash-script shim" {
  # P1i (R44): a pyenv shim is a bash script; linked onto a PATH without bash
  # it dies with "env: bash: No such file or directory".
  mkdir -p "$BATS_TEST_TMPDIR/shims" "$BATS_TEST_TMPDIR/bare-bin"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$(python3 -c 'import sys; print(sys.executable)')" \
    >"$BATS_TEST_TMPDIR/shims/python3"
  chmod +x "$BATS_TEST_TMPDIR/shims/python3"
  (PATH="$BATS_TEST_TMPDIR/shims:$PATH"; link_python3 "$BATS_TEST_TMPDIR/bare-bin")
  run env PATH="$BATS_TEST_TMPDIR/bare-bin" /bin/bash -c 'python3 --version'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Python "* ]]
}

@test "configured gate without jq warns exactly once" {
  write_config true
  mkdir -p "$BATS_TEST_TMPDIR/no-jq-bin"
  ln -s /usr/bin/dirname "$BATS_TEST_TMPDIR/no-jq-bin/dirname"
  ln -s "$(command -v git)" "$BATS_TEST_TMPDIR/no-jq-bin/git"
  link_python3 "$BATS_TEST_TMPDIR/no-jq-bin"
  run env PATH="$BATS_TEST_TMPDIR/no-jq-bin" /bin/bash -c '
    ! command -v jq && python3 --version && git -C "$1" rev-parse --show-toplevel
  ' _ "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Python "* ]]
  [[ "$output" == *"$REPO"* ]]
  run env PATH="$BATS_TEST_TMPDIR/no-jq-bin" /bin/bash -c 'cd "$1" && /bin/bash "$2"' _ "$REPO" "$HOOK"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^\[aeo-gate\]')" -eq 1 ]
  [[ "$output" == *"status=INDETERMINATE"* ]] || { echo "$output"; false; }
  [[ "$output" == *"jq unavailable"* ]] || { echo "$output"; false; }
  [ ! -e "$CALLS" ]
}

@test "without AEO_GATE_RANGE the runner gets the diff-base resolver's range" {
  # Inversion: an origin/main..HEAD default has no origin here, so the git
  # range is unavailable and the runner is never called.
  write_config true
  git -C "$REPO" checkout -qb feature/a
  printf 'a\n' >>"$REPO/page.tsx"
  git -C "$REPO" commit -qam a1
  local atip head
  atip=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" checkout -qb feature/b
  printf 'b\n' >>"$REPO/page.tsx"
  git -C "$REPO" commit -qam b1
  head=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" config branch.feature/b.trellisParent feature/a
  git -C "$REPO" config branch.feature/b.trellisBase "$atip"
  cat >"$RUNNER" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in --range) printf '%s\n' "$2" >"$AEO_TEST_CALLS"; shift 2 ;; *) shift ;; esac
done
printf 'AEO warn-only: status=PASS; merge_policy=non-blocking\n'
SH
  unset AEO_GATE_RANGE
  export TRELLIS_ROOT="$BATS_TEST_DIRNAME/../../.."
  run_hook
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "$atip..$head" ] || { echo "$output"; cat "$CALLS"; false; }
}

@test "without AEO_GATE_RANGE or a resolver the gate is indeterminate and never runs" {
  write_config true
  unset AEO_GATE_RANGE TRELLIS_ROOT
  run_hook
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^\[aeo-gate\]')" -eq 1 ]
  [[ "$output" == *"reason=diff-base resolver unavailable"* ]] || { echo "$output"; false; }
  [ ! -e "$CALLS" ]
}

@test "a cyclic link to the hook ends the walk at 40 hops and keeps the PATH lookup" {
  write_config true
  local hooks="$BATS_TEST_TMPDIR/hooks" bin="$BATS_TEST_TMPDIR/swap-bin" jq
  jq="$(command -v jq)"
  mkdir -p "$hooks" "$bin" "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/tmp"
  ln -s "$HOOK" "$hooks/aeo-gate-warn.sh"
  # bash refuses to open a cyclic link, so the first jq call turns the link the
  # hook runs through into a two-link cycle once bash has the file open.
  cat >"$bin/jq" <<EOF
#!/bin/sh
if [ ! -L "$hooks/next" ]; then
  ln -s aeo-gate-warn.sh "$hooks/next"
  rm -f "$hooks/aeo-gate-warn.sh"
  ln -s next "$hooks/aeo-gate-warn.sh"
fi
exec "$jq" "\$@"
EOF
  chmod +x "$bin/jq"
  # Without a hop cap the walk never ends; the alarm turns that into a failure.
  run env PATH="$bin:$PATH" HOME="$BATS_TEST_TMPDIR/home" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home" \
    TMPDIR="$BATS_TEST_TMPDIR/tmp" perl -e 'alarm shift; exec @ARGV or exit 127' 10 \
    bash -c 'cd "$1" && bash "$2"' _ "$REPO" "$hooks/aeo-gate-warn.sh"
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"status=PASS"* ]] || { echo "$output"; false; }
  [ "$(readlink "$hooks/aeo-gate-warn.sh")" = next ]
}
