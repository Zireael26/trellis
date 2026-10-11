#!/usr/bin/env bats
# Test runs must never read the operator's real ~/.trellis.
#
# session-context.sh and hookspath-guard.sh (through hooks/lib/hookspath-check.sh)
# resolve Trellis state as $TRELLIS_HOME, else $HOME/.trellis. Suites that ran
# those hooks without fencing TRELLIS_HOME read the live lane-availability
# snapshot and attachment records: harmless to the state, but nondeterministic
# during a concurrent attach/detach, and the reason test runs were serialized
# under a lock. Two fences close that: run-tests.sh points TRELLIS_HOME into
# each shard's fence root, and every suite that runs a reader exports a private
# TRELLIS_HOME in setup(), so a bare `bats <file>` is fenced too.
#
# HOME is deliberately not fenced globally: tool caches and credentials hang off
# it. The HOME-first readers (code-reviewer.sh, herdr-foreman-session.sh) are
# kept off live state by the HERDR_* scrub, not by this guard.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
SENTINEL="LB8-REAL-TRELLIS-HOME-SENTINEL"

# Suites that name a reader but do not fence TRELLIS_HOME in setup(). Each entry
# is `<path>|<why it is fenced anyway>`; the last case keeps the list honest.
FENCE_EXEMPT=(
  "scripts/tests/doctor-fix-part1.bats|names the hook only as a payload file; doctor runs under an explicit TRELLIS_HOME"
  "scripts/tests/hook-inventory.bats|parses hook sources; the only execution renders hook config through attachment.sh with HOME=\$RENDER_HOME and an explicit sandbox Trellis home, never a reader"
  "scripts/tests/non-trellis-inert.bats|t25_inert_env sets HOME and TRELLIS_HOME for every hook run"
  "scripts/tests/release-store.bats|names payload leaves only; every CLI call passes a sandbox TRELLIS_HOME"
  "scripts/tests/test-fencing.bats|this guard; it runs readers only through the suites it checks"
  "scripts/tests/wiki-skill-suggest.bats|both hook runners pass a sandbox HOME and TRELLIS_HOME through env"
  "core-rules/hooks/tests/session-context-worktree.bats|every test builds a fixture that exports a sandbox TRELLIS_HOME"
)

names_reader() {
  sed -E '/^[[:space:]]*#/d' "$1" | grep -qE '(session-context|hookspath-guard)\.sh'
}

# True when setup() exports TRELLIS_HOME and every export points into a temp
# dir: "$BATS_TEST_TMPDIR/...", or "$VAR/..." where setup() assigned VAR from
# BATS_TEST_TMPDIR, `mktemp -d`, or another such VAR (directly or through
# `cd`/`canonical_dir`). A later "$(canonical_dir "$TRELLIS_HOME")" re-export of
# an already-fenced value is allowed. `export TRELLIS_HOME="$HOME/.trellis"`
# is an export, not a fence.
setup_fences_trellis_home() {
  awk -v sq="'" '
    function rooted(v,   r, name) {
      if (v ~ /^"\$\(mktemp -d/) return 1
      r = v
      if (r ~ /^"\$\(/) {
        r = substr(r, 4)
        sub("^CDPATH=(" sq sq ")? ", "", r)
        if (r !~ /^(cd|canonical_dir) /) return 0
        sub(/^[a-z_]+ /, "", r)
      }
      if (r ~ /^"\$[{]?BATS_TEST_TMPDIR[}]?["\/]/) return 1
      for (name in sandbox)
        if (index(r, "\"$" name "/") == 1 || index(r, "\"$" name "\"") == 1) return 1
      return 0
    }
    /^setup\(\)[[:space:]]*\{/ { f = 1; next }
    f && /^\}/ { exit }
    !f { next }
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    line ~ /^export TRELLIS_HOME=/ {
      value = substr(line, length("export TRELLIS_HOME=") + 1)
      if (rooted(value) && value !~ /^"\$\(cd /) fenced = 1
      else if (fenced && value ~ /^"\$\([a-z_]+ "\$TRELLIS_HOME"\)"$/) fenced = 1
      else bad = 1
      next
    }
    line ~ /^(local )?[A-Za-z_][A-Za-z_0-9]*=/ {
      sub(/^local /, "", line)
      name = line; sub(/=.*/, "", name)
      value = substr(line, length(name) + 2)
      if (rooted(value)) sandbox[name] = 1; else delete sandbox[name]
    }
    END { exit !(fenced && !bad) }' "$1"
}

# Suites that drop an inherited TRELLIS_HOME (`unset ... TRELLIS_HOME` or
# `env -u TRELLIS_HOME`), which would let a reader fall back to $HOME/.trellis.
# Each entry is `<path>|<exact count>|<why HOME is a sandbox there>`; a count
# that no longer matches the suite fails as stale.
RESET_ALLOWED=(
  "scripts/tests/setup-runbooks.bats|6|persistent-home case: setup() already moved HOME into the sandbox, so the launcher's ~/.trellis default is the sandbox"
  "core-rules/skills/process-gate/tests/check-bypass.bats|2|§4 points HOME at a BATS_TEST_TMPDIR home before the unset; R1 unsets HOME as well"
  "scripts/tests/rollout-hooks-part6.bats|1|passes HOME=\$HOME, which setup() made the sandbox, and an explicit --home"
  "core-rules/hooks/tests/pi-review-route.bats|1|restores the caller's value after a run under a fake HOME and its own TRELLIS_HOME"
  "scripts/tests/configure.bats|1|setup() exports a sandbox HOME before the unset"
  "scripts/tests/config-load.bats|1|every loader call passes a sandbox HOME and TRELLIS_HOME through env"
  "scripts/tests/usage-federation.bats|1|the same env call sets HOME to the case's sandbox home"
  "core-rules/hooks/tests/session-context-task.bats|1|teardown() only, after the test has run"
  "scripts/tests/test-fencing.bats|1|the canary; the suite under test re-fences in setup() and HOME is a fake account"
)

reset_sites() {
  sed -E '/^[[:space:]]*(#|@test )/d' "$1" |
    grep -cE '(^|[^A-Za-z_])unset( [^;&|]*)? TRELLIS_HOME([^A-Za-z_0-9]|$)|-u[[:space:]]+TRELLIS_HOME([^A-Za-z_0-9]|$)' || true
}

reset_allowance() {
  local entry rest
  for entry in "${RESET_ALLOWED[@]}"; do
    [ "${entry%%|*}" = "$1" ] || continue
    rest="${entry#*|}"
    printf '%s\n' "${rest%%|*}"
    return 0
  done
  printf '0\n'
}

# Print each given suite whose TRELLIS_HOME resets differ from its allowance.
unallowed_resets() {
  local f rel count
  for f in "$@"; do
    rel="${f#"$REPO_ROOT"/}"
    count="$(reset_sites "$f")"
    [ "$count" -eq "$(reset_allowance "$rel")" ] || printf '%s (%s reset(s))\n' "$rel" "$count"
  done
}

exempt_reason() {
  local entry
  for entry in "${FENCE_EXEMPT[@]}"; do
    [ "${entry%%|*}" = "$1" ] && { printf '%s\n' "${entry#*|}"; return 0; }
  done
  return 1
}

@test "run-tests.sh points TRELLIS_HOME into the shard fence root" {
  local body
  body="$(awk '/^install_test_git_fence\(\) \{/ { f = 1 } f { print } f && /^\}/ { exit }' \
    "$REPO_ROOT/scripts/run-tests.sh")"
  [ -n "$body" ] || { echo 'install_test_git_fence not found in run-tests.sh'; false; }
  printf '%s\n' "$body" | grep -qxF '  TRELLIS_HOME="$fence_root/trellis-home"' ||
    { echo 'run-tests.sh does not set TRELLIS_HOME inside the fence root'; false; }
  printf '%s\n' "$body" | grep -qE '^  export( [A-Z_]+)* TRELLIS_HOME( |$)' ||
    { echo 'run-tests.sh does not export TRELLIS_HOME'; false; }
  ! printf '%s\n' "$body" | grep -qE '^[[:space:]]*(export )?HOME=' ||
    { echo 'run-tests.sh must not redirect HOME globally'; false; }
}

# Print each given suite that names a reader without a setup() fence or an
# exemption, relative to the repository root.
unfenced_suites() {
  local f rel
  for f in "$@"; do
    [ -f "$f" ] || continue
    rel="${f#"$REPO_ROOT"/}"
    names_reader "$f" || continue
    setup_fences_trellis_home "$f" && continue
    exempt_reason "$rel" >/dev/null && continue
    printf '%s\n' "$rel"
  done
}

all_suites() {
  local f
  for f in "$REPO_ROOT"/scripts/tests/*.bats "$REPO_ROOT"/core-rules/hooks/tests/*.bats \
           "$REPO_ROOT"/core-rules/codex/hooks/tests/*.bats "$REPO_ROOT"/core-rules/skills/*/tests/*.bats; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

# A synthetic reader suite whose setup() body is "$1".
synthetic_suite() {
  local path="$BATS_TEST_TMPDIR/synthetic-$2.bats"
  printf 'HOOK="$HOOKS_DIR/session-context.sh"\n\nsetup() {\n%s\n}\n' "$1" > "$path"
  printf '%s\n' "$path"
}

@test "every suite that runs a Trellis-home reader fences TRELLIS_HOME in setup()" {
  local missing
  missing="$(all_suites | while IFS= read -r f; do unfenced_suites "$f"; done)"
  [ -z "$missing" ] || {
    printf 'runs a ~/.trellis reader without a temp-rooted TRELLIS_HOME in setup(): %s\n' $missing
    false
  }
}

@test "a setup() fence must point TRELLIS_HOME into a temp dir, not just export it" {
  local suite
  suite="$(synthetic_suite '  export TRELLIS_HOME="$HOME/.trellis"' home)"
  [ "$(unfenced_suites "$suite")" = "$suite" ] ||
    { echo 'accepted export TRELLIS_HOME="$HOME/.trellis" as a fence'; false; }
  suite="$(synthetic_suite '  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"' bats-tmp)"
  [ -z "$(unfenced_suites "$suite")" ] || { echo 'rejected a BATS_TEST_TMPDIR fence'; false; }
  suite="$(synthetic_suite '  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export TRELLIS_HOME="$SANDBOX/trellis home"
  export TRELLIS_HOME="$(canonical_dir "$TRELLIS_HOME")"' sandbox)"
  [ -z "$(unfenced_suites "$suite")" ] || { echo 'rejected a mktemp sandbox fence'; false; }
  suite="$(synthetic_suite '  SANDBOX="$HOME"
  export TRELLIS_HOME="$SANDBOX/.trellis"' home-alias)"
  [ "$(unfenced_suites "$suite")" = "$suite" ] ||
    { echo 'accepted a sandbox variable that aliases HOME'; false; }
}

@test "every fence exemption still names a reader and still lacks a setup() fence" {
  local entry rel
  for entry in "${FENCE_EXEMPT[@]}"; do
    rel="${entry%%|*}"
    [ -f "$REPO_ROOT/$rel" ] || { echo "stale exemption, no such suite: $rel"; false; }
    names_reader "$REPO_ROOT/$rel" || { echo "stale exemption, names no reader: $rel"; false; }
    ! setup_fences_trellis_home "$REPO_ROOT/$rel" || { echo "stale exemption, now fenced in setup(): $rel"; false; }
  done
}

@test "no suite drops an inherited TRELLIS_HOME outside the allowlist" {
  local bad
  # shellcheck disable=SC2046  # all_suites prints space-free repository paths
  bad="$(unallowed_resets $(all_suites))"
  [ -z "$bad" ] || { printf 'drops TRELLIS_HOME without a RESET_ALLOWED entry: %s\n' "$bad"; false; }
}

@test "every reset allowance names a suite with exactly that many resets" {
  local entry rel want have
  for entry in "${RESET_ALLOWED[@]}"; do
    rel="${entry%%|*}"
    want="${entry#*|}"; want="${want%%|*}"
    [ -f "$REPO_ROOT/$rel" ] || { echo "stale reset allowance, no such suite: $rel"; false; }
    have="$(reset_sites "$REPO_ROOT/$rel")"
    [ "$have" -eq "$want" ] || { echo "stale reset allowance: $rel allows $want, has $have"; false; }
  done
}

@test "an unlisted unset or env -u of TRELLIS_HOME is reported" {
  local name=TRELLIS_HOME suite
  suite="$BATS_TEST_TMPDIR/synthetic-reset.bats"
  printf '@test "x" {\n  unset %s\n  run env -u %s bash "$HOOK"\n}\n' "$name" "$name" > "$suite"
  [ "$(unallowed_resets "$suite")" = "$suite (2 reset(s))" ] ||
    { echo "not reported: $(unallowed_resets "$suite")"; false; }
}

# Canary: run one real case of each suite with HOME pointing at a fake account
# whose ~/.trellis holds a sentinel. Each case runs twice: with TRELLIS_HOME
# unset, as from an unconfigured shell, and with TRELLIS_HOME inherited as the
# account's ~/.trellis, as from a shell that exports it. Shimmed jq and python3
# log the TRELLIS_HOME they inherit, their parent's command line, and their argv.
# session-context.sh reads lane-availability.json through python3 and owner
# records through jq, so a read of the fake account's state shows up as its path
# in the log, and the parent column proves the hook itself ran.
canary_suite() {
  local suite="$1" filter="$2" shim="$BATS_TEST_TMPDIR/shim" tool real ps_bin
  FAKE_HOME="$BATS_TEST_TMPDIR/account"
  NESTED_TMP="$BATS_TEST_TMPDIR/nested"
  CANARY_LOG="$BATS_TEST_TMPDIR/readers.log"
  mkdir -p "$FAKE_HOME/.trellis/state/attachments/$SENTINEL" "$NESTED_TMP" "$shim"
  chmod 700 "$FAKE_HOME/.trellis" "$FAKE_HOME/.trellis/state"
  FAKE_HOME="$(CDPATH='' cd "$FAKE_HOME" && pwd -P)"
  NESTED_TMP="$(CDPATH='' cd "$NESTED_TMP" && pwd -P)"
  printf '{"fetchedAt":"2099-01-01T00:00:00Z","lanes":{"%s":{"remaining":100}}}\n' "$SENTINEL" \
    > "$FAKE_HOME/.trellis/state/lane-availability.json"
  printf '{"git_hooks":{"enabled":true,"managed_hooks_path":"/%s"}}\n' "$SENTINEL" \
    > "$FAKE_HOME/.trellis/state/attachments/$SENTINEL/$SENTINEL.json"
  printf '{"projects":{"%s":{}}}\n' "$SENTINEL" > "$FAKE_HOME/.trellis/registry.json"
  # Absolute: missing-tool-behavior.bats runs hooks on a PATH of a few links.
  ps_bin="$(command -v ps)"
  for tool in jq python3; do
    real="$(command -v "$tool")"
    {
      printf '#!/bin/bash\n'
      printf 'parent="$(%q -o command= -p "$PPID" 2>/dev/null || true)"\n' "$ps_bin"
      printf 'printf "%%s\\t%%s\\t%%s\\n" "${TRELLIS_HOME-<unset>}" "$parent" "$*" >> %q\n' "$CANARY_LOG"
      printf 'exec %q "$@"\n' "$real"
    } > "$shim/$tool"
    chmod 755 "$shim/$tool"
  done

  canary_pass "$suite" "$filter" unset -u TRELLIS_HOME
  canary_pass "$suite" "$filter" inherited TRELLIS_HOME="$FAKE_HOME/.trellis"
}

canary_pass() {
  local suite="$1" filter="$2" mode="$3"
  shift 3
  : > "$CANARY_LOG"
  run env -u HERDR_ENV -u HERDR_WORKSPACE_ID -u HERDR_PANE_ID "$@" \
    HOME="$FAKE_HOME" TMPDIR="$NESTED_TMP" PATH="$BATS_TEST_TMPDIR/shim:$PATH" \
    bats --filter "$filter" "$REPO_ROOT/$suite"

  if [[ "$output" == *"$SENTINEL"* ]]; then
    echo "$suite ($mode): the account's ~/.trellis sentinel reached the suite output"; echo "$output"; false
  fi
  if grep -F "$FAKE_HOME/.trellis" "$CANARY_LOG"; then
    echo "$suite ($mode): read the account's ~/.trellis (TRELLIS_HOME not fenced before the hook ran)"; false
  fi
  awk -F '\t' '$2 ~ /session-context\.sh/' "$CANARY_LOG" > "$BATS_TEST_TMPDIR/hook.log"
  [ -s "$BATS_TEST_TMPDIR/hook.log" ] ||
    { echo "$suite ($mode): session-context.sh never ran under the canary"; echo "$output"; false; }
  if awk -F '\t' -v tmp="$NESTED_TMP/" 'index($1, tmp) != 1' "$BATS_TEST_TMPDIR/hook.log" | grep -q .; then
    echo "$suite ($mode): session-context.sh ran with a TRELLIS_HOME outside the suite's own temp dir:"
    cut -f1 "$BATS_TEST_TMPDIR/hook.log" | sort -u
    false
  fi
}

@test "canary: session-context.bats never reads the account's ~/.trellis" {
  canary_suite core-rules/hooks/tests/session-context.bats 'matches a heading line'
}

@test "canary: Claude session-context-autonomy.bats never reads the account's ~/.trellis" {
  canary_suite core-rules/hooks/tests/session-context-autonomy.bats 'no policy defaults to L3'
}

@test "canary: Codex session-context-autonomy.bats never reads the account's ~/.trellis" {
  canary_suite core-rules/codex/hooks/tests/session-context-autonomy.bats 'defaults to L3 when no config exists'
}

@test "canary: verification-receipt.bats never reads the account's ~/.trellis" {
  canary_suite core-rules/hooks/tests/verification-receipt.bats 'never replay raw output'
}

@test "canary: missing-tool-behavior.bats never reads the account's ~/.trellis" {
  canary_suite core-rules/hooks/tests/missing-tool-behavior.bats 'missing git degrades visibly in session-context'
}
