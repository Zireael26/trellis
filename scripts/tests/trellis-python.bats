#!/usr/bin/env bats
# scripts/lib/trellis-python.sh and its hook callers never run a
# version-manager shim while a real CPython exists (spec 072 T1).
#
# A fake pyenv shim is first on PATH. It records a sentinel and then runs a real
# interpreter, so a caller that reaches it still works and only the sentinel
# tells. The probe-and-cache path uses fake candidates through
# TRELLIS_PYTHON_CANDIDATES. HOME, TRELLIS_HOME and TMPDIR are private to each
# test.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/lib/trellis-python.sh"

setup() {
  unset TRELLIS_PYTHON HC_SCOPE HC_TERMINAL_ID HC_TERMINAL_SOCKET
  export HOME="$BATS_TEST_TMPDIR/home"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$HOME" "$TRELLIS_HOME/state" "$TMPDIR"

  REAL=""
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [ -x "$candidate" ]; then REAL="$candidate"; break; fi
  done
  SENTINEL="$BATS_TEST_TMPDIR/shim-ran"
  SHIMS="$BATS_TEST_TMPDIR/pyenv/shims"
  mkdir -p "$SHIMS"
  cat >"$SHIMS/python3" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$SENTINEL"
exec "$REAL" "\$@"
EOF
  chmod +x "$SHIMS/python3"
  SHIM_PATH="$SHIMS:$PATH"

  PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT/.trellis"
  git -C "$PROJECT" -c core.hooksPath=/dev/null -c init.templateDir= init -q
  git -C "$PROJECT" -c user.name=Test -c user.email=test@example.invalid \
    commit --allow-empty -q -m init
  # The hooks find the payload resolver through the runtime link, as attached.
  ln -s "$REPO_ROOT" "$PROJECT/.trellis/runtime"
}

needs_real_python() {
  [ -n "$REAL" ] || skip "no python3 at a fixed candidate path"
}

assert_shim_never_ran() {
  [ ! -e "$SENTINEL" ] || { echo "shim ran: $(cat "$SENTINEL")"; return 1; }
}

resolve() {  # [env assignments...]
  run env "$@" bash -c '. "$1" && trellis_python && printf "%s|%s\n" "$TRELLIS_PYTHON" "$(env | grep -c "^TRELLIS_PYTHON=")"' _ "$LIB"
}

# --- resolver --------------------------------------------------------------

@test "resolver picks a fixed candidate over a shim first on PATH and exports it" {
  needs_real_python
  resolve PATH="$SHIM_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "$REAL|1" ]
  assert_shim_never_ran
}

# Two fake candidates: an install stub that fails --version (as the macOS
# /usr/bin/python3 does without the Command Line Tools) and a working one.
# Both log every invocation to $PROBES.
fake_candidates() {
  PROBES="$BATS_TEST_TMPDIR/probes"
  STUB="$BATS_TEST_TMPDIR/stub/usr/bin/python3"
  GOOD="$BATS_TEST_TMPDIR/good/bin/python3"
  CACHE="$TRELLIS_HOME/state/python"
  mkdir -p "${STUB%/*}" "${GOOD%/*}"
  : >"$PROBES"
  cat >"$STUB" <<EOF
#!/bin/sh
printf 'stub %s\n' "\$*" >>"$PROBES"
echo 'xcrun: error: invalid active developer path' >&2
exit 1
EOF
  cat >"$GOOD" <<EOF
#!/bin/sh
printf 'good %s\n' "\$*" >>"$PROBES"
exit 0
EOF
  chmod +x "$STUB" "$GOOD"
}

@test "a candidate failing the probe is skipped; the first that runs is cached 0600" {
  fake_candidates
  resolve PATH="$SHIM_PATH" TRELLIS_PYTHON_CANDIDATES="$STUB:$GOOD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "$GOOD|1" ]
  [ "$(cat "$PROBES")" = "stub --version
good --version" ] || { cat "$PROBES"; return 1; }
  [ "$(cat "$CACHE")" = "$GOOD" ]
  [ "$(ls -l "$CACHE" | cut -c1-10)" = "-rw-------" ]
  [ -z "$(find "$TRELLIS_HOME/state" -name '*.tmp')" ]
  assert_shim_never_ran
}

@test "a trusted cache hit runs no probe" {
  fake_candidates
  resolve PATH="$SHIM_PATH" TRELLIS_PYTHON_CANDIDATES="$STUB:$GOOD"
  [ "$status" -eq 0 ]
  : >"$PROBES"
  resolve PATH="$SHIM_PATH" TRELLIS_PYTHON_CANDIDATES="$STUB:$GOOD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "$GOOD|1" ]
  [ ! -s "$PROBES" ] || { cat "$PROBES"; return 1; }
  assert_shim_never_ran
}

@test "a PATH-found or shim interpreter serves the process but is never cached" {
  fake_candidates
  # Every listed candidate fails, so resolution falls through to PATH.
  resolve PATH="${GOOD%/*}:$SHIM_PATH" TRELLIS_PYTHON_CANDIDATES="$STUB"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "$GOOD|1" ]
  [ ! -e "$CACHE" ]
  needs_real_python
  # Only the shim offers python3 on this PATH.
  local tools="$BATS_TEST_TMPDIR/tools" tool
  mkdir -p "$tools"
  for tool in bash env grep perl mv rm; do ln -s "$(command -v "$tool")" "$tools/$tool"; done
  resolve PATH="$SHIMS:$tools" TRELLIS_PYTHON_CANDIDATES="$STUB"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "$SHIMS/python3|1" ]
  [ ! -e "$CACHE" ]
}

@test "a group- or other-writable candidate is never run, cached or not; the next trusted one wins" {
  local writable="$BATS_TEST_TMPDIR/writable/bin/python3" mode
  fake_candidates
  mkdir -p "${writable%/*}"
  printf '#!/bin/sh\nprintf "writable %%s\\n" "$*" >>"%s"\nexit 0\n' "$PROBES" >"$writable"
  for mode in 775 757 777; do
    chmod "$mode" "$writable"
    for cached in "$writable" ""; do
      rm -f "$CACHE"
      if [ -n "$cached" ]; then printf '%s\n' "$cached" >"$CACHE"; chmod 600 "$CACHE"; fi
      : >"$PROBES"
      resolve PATH="$SHIM_PATH" TRELLIS_PYTHON_CANDIDATES="$writable:$GOOD"
      [ "$output" = "$GOOD|1" ] || { echo "$mode cache=$cached: $output"; return 1; }
      [ "$(cat "$PROBES")" = "good --version" ] || { echo "$mode cache=$cached:"; cat "$PROBES"; return 1; }
      [ "$(cat "$CACHE")" = "$GOOD" ]
    done
  done
  # The same file at 0755 is trusted: the mode alone decided.
  chmod 755 "$writable"
  rm -f "$CACHE"
  : >"$PROBES"
  resolve PATH="$SHIM_PATH" TRELLIS_PYTHON_CANDIDATES="$writable:$GOOD"
  [ "$output" = "$writable|1" ] || { echo "$output"; return 1; }
  [ "$(cat "$PROBES")" = "writable --version" ]
}

@test "a cache naming an interpreter outside the candidate list is ignored" {
  fake_candidates
  # Trusted owner and mode, but not a listed candidate (e.g. a project venv).
  printf '%s\n' "$GOOD" >"$CACHE"
  chmod 600 "$CACHE"
  : >"$PROBES"
  resolve PATH="$SHIM_PATH" TRELLIS_PYTHON_CANDIDATES="$STUB"
  [ "$output" != "$GOOD|1" ] || { echo "unlisted cache was trusted"; return 1; }
  [ "$(sed -n 1p "$PROBES")" = "stub --version" ]
}

@test "a cache file that is not 0600 or is a symlink is ignored" {
  fake_candidates
  printf '%s\n' "$GOOD" >"$CACHE"
  chmod 644 "$CACHE"
  : >"$PROBES"
  resolve PATH="$SHIM_PATH" TRELLIS_PYTHON_CANDIDATES="$GOOD"
  grep -qx 'good --version' "$PROBES"
  printf '%s\n' "$GOOD" >"$BATS_TEST_TMPDIR/elsewhere"
  chmod 600 "$BATS_TEST_TMPDIR/elsewhere"
  rm -f "$CACHE"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$CACHE"
  : >"$PROBES"
  resolve PATH="$SHIM_PATH" TRELLIS_PYTHON_CANDIDATES="$GOOD"
  grep -qx 'good --version' "$PROBES"
}

# Calls the trust check directly; the optional uids stand in for "this user"
# so the foreign-owner branches run on a host with no third user.
trusted() {  # <cache> <interpreter> [<cache-uid> <owner-uid>]
  run bash -c '. "$1"; shift; _trellis_python_trusted "$@"' _ "$LIB" "$@"
}

@test "the trust check rejects a cache, interpreter or link owned by another uid" {
  local me other interpreter link="$BATS_TEST_TMPDIR/link/python3" rootlink="$BATS_TEST_TMPDIR/rootlink/python3"
  me="$(id -u)"
  [ "$me" -ne 0 ] || skip "root owns every fixture, so no uid is foreign"
  other=$((me + 1))
  fake_candidates
  printf '%s\n' "$GOOD" >"$CACHE"
  chmod 600 "$CACHE"
  mkdir -p "${link%/*}" "${rootlink%/*}"
  ln -s "$GOOD" "$link"
  ln -s /bin/sh "$rootlink"
  # Baseline: everything here is ours, or root's.
  for interpreter in "$GOOD" "$link" "$rootlink" /bin/sh; do
    trusted "$CACHE" "$interpreter"
    [ "$status" -eq 0 ] || { echo "rejected own $interpreter"; return 1; }
  done
  # Our interpreter, and our link to a root-owned one, are foreign to $other.
  trusted "$CACHE" "$GOOD" "$me" "$other"
  [ "$status" -eq 1 ] || { echo "accepted a foreign-owned interpreter"; return 1; }
  trusted "$CACHE" "$rootlink" "$me" "$other"
  [ "$status" -eq 1 ] || { echo "accepted a foreign-owned link"; return 1; }
  # Root stays trusted whoever the user is.
  trusted "$CACHE" /bin/sh "$me" "$other"
  [ "$status" -eq 0 ] || { echo "rejected root-owned /bin/sh"; return 1; }
  # A cache file owned by another uid is refused before the interpreter.
  trusted "$CACHE" "$GOOD" "$other" "$me"
  [ "$status" -eq 1 ] || { echo "accepted a foreign-owned cache"; return 1; }
}

@test "an inherited EUID does not change whose files the trust check accepts" {
  local me other
  me="$(id -u)"
  other=$((me + 1))
  fake_candidates
  printf '%s\n' "$GOOD" >"$CACHE"
  chmod 600 "$CACHE"
  # bash takes $EUID from its environment; the check must judge the real one.
  run env EUID="$other" bash -c '. "$1"; shift; _trellis_python_trusted "$@"' _ "$LIB" "$CACHE" "$GOOD"
  [ "$status" -eq 0 ] || { echo "judged our own files against EUID=$other"; return 1; }
  # So the production path still takes the cache without a probe.
  resolve EUID="$other" PATH="$SHIM_PATH" TRELLIS_PYTHON_CANDIDATES="$STUB:$GOOD"
  [ "$output" = "$GOOD|1" ] || { echo "$output"; return 1; }
  [ ! -s "$PROBES" ] || { cat "$PROBES"; return 1; }
}

@test "a cache naming a file owned by another user, or a link to one, is ignored" {
  local foreign="" link="$BATS_TEST_TMPDIR/link/python3"
  fake_candidates
  # Never executed: GOOD is listed first, so the probe stops there.
  foreign="$(find /usr/bin /usr/sbin /bin /sbin -maxdepth 1 -type f -perm -u+x \
    ! -user 0 ! -user "$(id -u)" 2>/dev/null | head -n 1)"
  [ -n "$foreign" ] || skip "no executable owned by another user on this host"
  printf '%s\n' "$foreign" >"$CACHE"
  chmod 600 "$CACHE"
  : >"$PROBES"
  resolve PATH="$SHIM_PATH" TRELLIS_PYTHON_CANDIDATES="$GOOD:$foreign"
  [ "$output" = "$GOOD|1" ] || { echo "$output"; return 1; }
  grep -qx 'good --version' "$PROBES"
  mkdir -p "${link%/*}"
  ln -s "$foreign" "$link"
  printf '%s\n' "$link" >"$CACHE"
  chmod 600 "$CACHE"
  : >"$PROBES"
  resolve PATH="$SHIM_PATH" TRELLIS_PYTHON_CANDIDATES="$GOOD:$link"
  [ "$output" = "$GOOD|1" ] || { echo "$output"; return 1; }
  grep -qx 'good --version' "$PROBES"
}

@test "a cache naming a vanished or non-executable interpreter is probed again" {
  local plain="$BATS_TEST_TMPDIR/plain/python3"
  fake_candidates
  mkdir -p "${plain%/*}"
  printf 'not a program\n' >"$plain"
  for stale in "$BATS_TEST_TMPDIR/gone/python3" "$plain" python3; do
    printf '%s\n' "$stale" >"$CACHE"
    : >"$PROBES"
    resolve PATH="$SHIM_PATH" TRELLIS_PYTHON_CANDIDATES="$STUB:$GOOD"
    [ "$output" = "$GOOD|1" ] || { echo "$stale: $output"; return 1; }
    [ "$(cat "$PROBES")" = "stub --version
good --version" ] || { echo "$stale"; cat "$PROBES"; return 1; }
    [ "$(cat "$CACHE")" = "$GOOD" ]
  done
}

@test "without a state directory nothing is cached and each resolution probes" {
  local fresh="$BATS_TEST_TMPDIR/fresh-home"
  fake_candidates
  resolve PATH="$SHIM_PATH" TRELLIS_HOME="$fresh" TRELLIS_PYTHON_CANDIDATES="$GOOD"
  [ "$output" = "$GOOD|1" ]
  resolve PATH="$SHIM_PATH" TRELLIS_HOME="$fresh" TRELLIS_PYTHON_CANDIDATES="$GOOD"
  [ "$output" = "$GOOD|1" ]
  [ "$(grep -c '^good --version$' "$PROBES")" -eq 2 ]
  [ ! -e "$fresh" ]
}

@test "when no candidate runs, resolution fails and nothing is cached" {
  local bin="$BATS_TEST_TMPDIR/perl-only"
  fake_candidates
  # perl for the trust check, and no python3 anywhere on PATH.
  mkdir -p "$bin"
  ln -s "$(command -v perl)" "$bin/perl"
  run env -i PATH="$bin" TRELLIS_HOME="$TRELLIS_HOME" \
    TRELLIS_PYTHON_CANDIDATES="$STUB" \
    /bin/bash -c '. "$1" && trellis_python' _ "$LIB"
  [ "$status" -eq 1 ]
  [ "$(cat "$PROBES")" = "stub --version" ]
  [ ! -e "$CACHE" ]
}

@test "an executable absolute TRELLIS_PYTHON is reused as the override" {
  local override="$BATS_TEST_TMPDIR/override/python3"
  mkdir -p "${override%/*}"
  printf '#!/bin/sh\nexit 0\n' >"$override"
  chmod +x "$override"
  resolve PATH="$SHIM_PATH" TRELLIS_PYTHON="$override"
  [ "$status" -eq 0 ]
  [ "$output" = "$override|1" ]
}

@test "a relative, missing or non-executable TRELLIS_PYTHON is ignored" {
  needs_real_python
  local plain="$BATS_TEST_TMPDIR/plain-python3"
  printf 'not a program\n' >"$plain"
  chmod 644 "$plain"
  for value in python3 "$BATS_TEST_TMPDIR/absent/python3" "$plain" "$BATS_TEST_TMPDIR"; do
    resolve PATH="$SHIM_PATH" TRELLIS_PYTHON="$value"
    [ "$status" -eq 0 ] || { echo "$value: $output"; return 1; }
    [ "$output" = "$REAL|1" ] || { echo "$value: $output"; return 1; }
  done
  assert_shim_never_ran
}

# --- hooks -----------------------------------------------------------------

# One pi event in a private 0700 directory as a 0600 file, as the bridge writes it.
pi_event_file() {  # <json>
  local dir="$BATS_TEST_TMPDIR/events"
  mkdir -p "$dir" && chmod 700 "$dir"
  (umask 077 && printf '%s' "$1" >"$dir/event.json")
  printf '%s' "$dir/event.json"
}

@test "pi dispatch.sh reads the event file without the shim" {
  needs_real_python
  local event file
  event="$(jq -nc --arg cwd "$PROJECT" '{schema_version:1,harness:"pi",cwd:$cwd,session_id:"s1",session_file:"",phase:"pre_action",native_event:"tool_call",action:{id:"c1",tool_name:"grep",family:"local_tool",target_coverage:"none",targets:[],input:{pattern:"x",path:"."}},result:null}')"
  file="$(pi_event_file "$event")"
  run env PATH="$SHIM_PATH" bash -c 'cd "$1" && exec bash "$2" --event-file "$3"' _ \
    "$PROJECT" "$PROJECT/.trellis/runtime/core-rules/pi/hooks/dispatch.sh" "$file"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s' "$output" | jq -e '.decision != "deny"' >/dev/null || { echo "$output"; return 1; }
  assert_shim_never_ran
}

@test "pi session_start runs the Codex session-context hook without the shim" {
  needs_real_python
  local event file
  printf '{"fetchedAt":"2026-01-01T00:00:00Z","lanes":{"alpha":{"remaining":0.9}}}\n' \
    >"$TRELLIS_HOME/state/lane-availability.json"
  event="$(jq -nc --arg cwd "$PROJECT" '{schema_version:1,harness:"pi",cwd:$cwd,session_id:"s1",session_file:"",phase:"lifecycle",native_event:"session_start",reason:"startup"}')"
  file="$(pi_event_file "$event")"
  run env PATH="$SHIM_PATH" bash -c 'cd "$1" && exec bash "$2" --event-file "$3"' _ \
    "$PROJECT" "$PROJECT/.trellis/runtime/core-rules/pi/hooks/dispatch.sh" "$file"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Lane availability: alpha"* ]] || { echo "$output"; return 1; }
  assert_shim_never_ran
}

@test "Claude and Codex session-context run lane and task context without the shim" {
  needs_real_python
  local hook
  printf '{"fetchedAt":"2026-01-01T00:00:00Z","lanes":{"alpha":{"remaining":0.9}}}\n' \
    >"$TRELLIS_HOME/state/lane-availability.json"
  printf '%s\n' '- [x] one' '- [ ] two' >"$PROJECT/tasks.md"
  "$REAL" -I "$REPO_ROOT/core-rules/hooks/lib/task-state.py" capture \
    --cwd "$PROJECT" --tasks tasks.md --harness claude >/dev/null
  for hook in core-rules/hooks/session-context.sh core-rules/codex/hooks/session-context.sh; do
    run env PATH="$SHIM_PATH" CLAUDE_PROJECT_DIR="$PROJECT" CODEX_PROJECT_DIR="$PROJECT" \
      bash -c 'cd "$1" && exec bash "$2"' _ "$PROJECT" "$PROJECT/.trellis/runtime/$hook" <<<'{"source":"startup"}'
    [ "$status" -eq 0 ] || { echo "$hook: $output"; return 1; }
    [[ "$output" == *"Lane availability: alpha"* ]] || { echo "$hook: $output"; return 1; }
    [[ "$output" == *"status=available documents=1"* ]] || { echo "$hook: $output"; return 1; }
  done
  assert_shim_never_ran
}

@test "herdr-foreman-session (both twins) runs its Python without the shim" {
  needs_real_python
  local bin="$BATS_TEST_TMPDIR/bin" hook
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 0\n' >"$bin/pi"
  cat >"$bin/herdr" <<'EOF'
#!/bin/sh
printf '%s\n' '{"result":{"agents":[]}}'
EOF
  chmod +x "$bin/pi" "$bin/herdr"
  mkdir -p "$HOME/.trellis"
  printf '{"active_cli_release":"9.9.9"}\n' >"$HOME/.trellis/config.json"
  for hook in core-rules/hooks/herdr-foreman-session.sh core-rules/codex/hooks/herdr-foreman-session.sh; do
    run env PATH="$bin:$SHIM_PATH" TRELLIS_HOME= HC_SCOPE=s1 HC_TERMINAL_ID=t1 \
      bash "$PROJECT/.trellis/runtime/$hook"
    [ "$status" -eq 0 ] || { echo "$hook: $output"; return 1; }
    # The release check ran in Python and refused the absent 9.9.9 payload.
    [[ "$output" == *"DEGRADED: active Trellis release resolver"* ]] || { echo "$hook: $output"; return 1; }
  done
  assert_shim_never_ran
}

@test "code-reviewer.sh reads the roles config and the deciding artifact without the shim" {
  needs_real_python
  local lib="$PROJECT/.trellis/runtime/core-rules/hooks/lib/code-reviewer.sh"
  local payload="$TRELLIS_HOME/releases/1.0.0/payload"
  mkdir -p "$payload/core-rules/skills/herdr-foreman" "$HOME/.trellis/state"
  printf '{}\n' >"$payload/core-rules/skills/herdr-foreman/roles.json"
  printf '{"active_cli_release":"1.0.0"}\n' >"$TRELLIS_HOME/config.json"
  run env PATH="$SHIM_PATH" bash -c '. "$1" && reviewer_roles_config' _ "$lib"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == */1.0.0/payload/core-rules/skills/herdr-foreman/roles.json ]] || { echo "$output"; return 1; }
  # An empty artifact is refused in Python, after the config lookup.
  printf '{}\n' >"$HOME/.trellis/state/roles-resolved.json"
  run env PATH="$SHIM_PATH" HC_SCOPE=s1 HC_TERMINAL_ID=t1 \
    bash -c '. "$1" && resolve_reviewer_model' _ "$lib"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  assert_shim_never_ran
}

@test "aeo-gate-warn.sh runs its trampoline and watchdog without the shim, also through a link" {
  needs_real_python
  local repo="$BATS_TEST_TMPDIR/aeo" runner="$BATS_TEST_TMPDIR/run-diff" hook
  mkdir -p "$repo/.codex/hooks/lib"
  git -C "$repo" -c init.templateDir= init -q
  printf 'base\n' >"$repo/page.tsx"
  git -C "$repo" add page.tsx
  git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit -qm base
  printf 'changed\n' >>"$repo/page.tsx"
  git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit -qam changed
  printf '{"schema":"aeo-gate.baseline.v1"}\n' >"$repo/baseline.json"
  printf '%s\n' '{"aeo_gate":{"enabled":true,"project":"fixture","url":"https://example.test","marker_file":"page.tsx","marker":"changed","baseline":"baseline.json"}}' \
    >"$repo/.trellis.config.json"
  printf '#!/bin/sh\necho "AEO warn-only: status=PASS; merge_policy=non-blocking"\n' >"$runner"
  chmod +x "$runner"
  # pre-push reaches the payload file through a mapped .codex/hooks/lib link.
  ln -s "$PROJECT/.trellis/runtime/core-rules/hooks/lib/aeo-gate-warn.sh" "$repo/.codex/hooks/lib/aeo-gate-warn.sh"
  for hook in "$PROJECT/.trellis/runtime/core-rules/hooks/lib/aeo-gate-warn.sh" .codex/hooks/lib/aeo-gate-warn.sh; do
    run env PATH="$SHIM_PATH" AEO_GATE_RANGE=HEAD~1..HEAD AEO_GATE_RUNNER="$runner" \
      bash -c 'cd "$1" && bash "$2"' _ "$repo" "$hook"
    [ "$status" -eq 0 ] || { echo "$hook: $output"; return 1; }
    [[ "$output" == *"status=PASS"* ]] || { echo "$hook: $output"; return 1; }
  done
  assert_shim_never_ran
}

@test "a mapped hook copy outside a payload keeps the plain PATH lookup" {
  needs_real_python
  local deploy="$BATS_TEST_TMPDIR/deploy/.codex/hooks"
  mkdir -p "$deploy/lib"
  cp "$REPO_ROOT/core-rules/codex/hooks/session-context.sh" "$deploy/"
  cp "$REPO_ROOT/core-rules/codex/hooks/lib/"*.sh "$deploy/lib/"
  cp "$REPO_ROOT/core-rules/hooks/lib/task-context.sh" "$REPO_ROOT/core-rules/hooks/lib/task-state.py" "$deploy/lib/"
  # A project-controlled scripts/lib beside the copy must never be sourced.
  mkdir -p "$BATS_TEST_TMPDIR/deploy/scripts/lib" "$BATS_TEST_TMPDIR/scripts/lib"
  printf 'trellis_python() { : >"%s"; return 1; }\n' "$BATS_TEST_TMPDIR/planted" |
    tee "$BATS_TEST_TMPDIR/deploy/scripts/lib/trellis-python.sh" >"$BATS_TEST_TMPDIR/scripts/lib/trellis-python.sh"
  printf '{"fetchedAt":"2026-01-01T00:00:00Z","lanes":{"alpha":{"remaining":0.9}}}\n' \
    >"$TRELLIS_HOME/state/lane-availability.json"
  run env PATH="$SHIM_PATH" CODEX_PROJECT_DIR="$PROJECT" \
    bash -c 'cd "$1" && exec bash "$2"' _ "$PROJECT" "$deploy/session-context.sh" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Lane availability: alpha"* ]] || { echo "$output"; return 1; }
  [ ! -e "$BATS_TEST_TMPDIR/planted" ]
  # Outside a payload the shim on PATH is what a bare python3 reaches.
  [ -s "$SENTINEL" ]
}
