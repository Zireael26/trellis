#!/usr/bin/env bats
# Spec 072 T0: `trellis bench` runs end to end and writes a redacted receipt
# whose per-section schema holds.
#
# Cost: 3 minutes on a quiet host, 7-10 under load, nearly all in the first test. It
# installs a release from HEAD into a test TRELLIS_HOME (one full release
# verify), and the bench then copies that release into its own sandbox
# and attaches a fixture project there before timing anything. Both steps are
# the costs spec 072 sets out to remove, so this test gets faster with it.
# The other tests call the script directly and take seconds.

SOURCE_ROOT="$(CDPATH= cd -- "$BATS_TEST_DIRNAME/../.." && pwd -P)"
BENCH="$SOURCE_ROOT/scripts/bench/trellis-latency.py"

load helpers/release-fixture

# A caller machine: the stable launcher plus a release sealed from HEAD and
# installed through the release-store seam, as the release fixtures do.
install_caller_release() {
  local src version
  export HOME="$ROOT/home" TRELLIS_HOME="$ROOT/trellis-home"
  mkdir -p "$HOME/.local/bin" "$TRELLIS_HOME" "$ROOT/projects"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  src="$ROOT/release source"
  mkdir -p "$src"
  git -C "$SOURCE_ROOT" archive --format=tar HEAD | tar -x -C "$src"
  version="$(cat "$src/core-rules/VERSION")"
  release_fixture_seal_repo "$HOME" "$src" "$version"
  cp "$src/scripts/trellis-launcher.sh" "$HOME/.local/bin/trellis"
  chmod 755 "$HOME/.local/bin/trellis"
  HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" GIT_CONFIG_NOSYSTEM=1 bash -c \
    '. "$1"; release_store_install "$2" "$3" "" >/dev/null' \
    bench-release-bootstrap "$src/scripts/lib/release-store.sh" "$version" "$src"
  jq -n --arg source "$src" --arg version "$version" --arg root "$ROOT/projects" '{
    schema_version: 1, source_root: $source, release_remote: "fixture://bench",
    active_cli_release: $version, default_fleet: "personal",
    fleets: {personal: {discovery_roots: [$root]}}
  }' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
}

setup() {
  ROOT="$(CDPATH= cd -- "$BATS_TEST_TMPDIR" && pwd -P)"
  mkdir -p "$ROOT/out" "$ROOT/tmp"
  printf 'ordinal\tstage\telapsed_seconds\texit\n1\tshellcheck\t88\t0\n2\tbats a.bats\t5636\t0\n3\tbats b.bats\t12\t0\n' \
    > "$ROOT/aggregate.tsv"
}

teardown() {
  # The installed release is read-only by design; Bats cannot delete it otherwise.
  chmod -R u+w "$ROOT" 2>/dev/null || true
}

@test "trellis bench: one case per section through the route; per-section schema, redaction, cleanup" {
  local releases_before
  install_caller_release
  # Materialize the launcher's execution snapshot before measuring store writes.
  "$HOME/.local/bin/trellis" release list >/dev/null
  releases_before="$(ls -a "$TRELLIS_HOME/releases")"
  run "$HOME/.local/bin/trellis" bench --suite hooks,lifecycle,gate --n 2 --lifecycle-runs 1 --warmup 0 \
    --hooks '^(codex PreToolUse Bash|claude Stop|pi tool_call bash|pi tool_result bash|pi-dispatch tool_call bash)$' \
    --lifecycle-items session-start-claude,git-checkout-file \
    --gate-tsv "$ROOT/aggregate.tsv" --gate-wall 5700 --label tiny --out "$ROOT/out"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }

  local receipt md
  receipt="$(find "$ROOT/out" -name 'bench-*-tiny.json')"
  md="$(find "$ROOT/out" -name 'bench-*-tiny.md')"
  [ -f "$receipt" ] && [ -f "$md" ]
  [[ "$(basename "$receipt")" =~ ^bench-[0-9]{4}-[0-9]{2}-[0-9]{2}-tiny\.json$ ]]

  jq -e '
    def case(id): .results[] | select(.id == id);
    .schema == "trellis-latency-bench/1" and .status == "ok" and .condition == "normal"
    and .source.release_mode == "installed" and (.source.commit | test("^[0-9a-f]{40}$"))
    and (.load.start | length == 3) and (.host | has("filesystem") and has("gate_or_bats_running"))
    and .config.runs == 2 and .config.lifecycle_runs == 1
    and (.sandbox.path_counts | has("entries") and has("dropped_trellis") and has("dropped_pyenv_exec"))
    and (.results | map(.id) == ["claude Stop", "codex PreToolUse Bash", "pi tool_call bash",
         "pi tool_result bash", "pi-dispatch tool_call bash", "session-start-claude",
         "git-checkout-file (hooks off)", "git-checkout-file"])
    and all(.results[]; .wall_ms.p50 > 0 and .wall_ms.p50 <= .wall_ms.p90 and .wall_ms.p99 == null)
    and (case("codex PreToolUse Bash")
         | .wall_ms.n == 2 and (.serial_sum_p50_ms | type == "number")
         and (.members | map(.name) == ["block-destructive", "pr-gate-shiftleft"])
         and all(.members[]; .exit_codes == [0] and .runs_over_registered_timeout == 0))
    and (case("claude Stop") | (.members | length) == 6 and all(.members[]; .exit_codes == [0])
         and (.first_run | map(.stdout_tail) | all(test("\"block\"") | not)))
    and (case("pi tool_call bash") | .boundary == "trellis.ts handler" and .path == "extension handler"
         # T10 moved pre-action guards in-process; one pi.exec per run remains.
         and .blocked_runs == 0 and .exec_calls_per_run == 1)
    and (case("pi-dispatch tool_call bash") | .boundary == "dispatch-only" and .path == "dispatch.sh"
         and .members[0].exit_codes == [0])
    and (case("session-start-claude") | .wall_ms.n == 1
         # T6: one session-start dispatcher replaces the three context hooks.
         and (.members | map(.name) == ["launcher:session-start"])
         and all(.members[]; (.registered_timeout_s | type == "number")
                 and (.runs_over_registered_timeout | type == "number")))
    and (case("git-checkout-file") | .hooks == true and .members[0].exit_codes == [0])
    and (case("git-checkout-file (hooks off)") | .hooks == false)
    and .summary.per_tool_call_p50_ms.pi.bash.total_p50_ms > 0
    and (.summary.per_tool_call_p50_ms | has("pi-dispatch (dispatch-only)"))
    and .gate.stages == 3 and .gate.stage_seconds_sum == 5736 and .gate.wall_source == "--gate-wall"
  ' "$receipt" >/dev/null || { jq . "$receipt" >&2; return 1; }
  grep -q '^| pi | bash |' "$md"
  grep -q 'p99 is shown only at n ≥ 200' "$md"

  # Redacted: no home, user or sandbox path survives in either file. A bare
  # "! cmd" never fails a bats test unless it is the last line, so check status.
  run grep -l -e '/Users/' -e '/home/' -e "$(id -un)" -e "$ROOT/" "$receipt" "$md"
  [ "$status" -eq 1 ]

  # Read-only on the caller's store; no sandbox or sandbox process survives.
  [ "$(ls -a "$TRELLIS_HOME/releases")" = "$releases_before" ]
  [ -z "$(find "$TRELLIS_HOME" "$ROOT" -name 'trellis-bench.*' -print -quit)" ]
  run pgrep -f "$ROOT/.*trellis-bench\."
  [ "$status" -eq 1 ]
}

@test "contention detection checks process identity and treats a failed snapshot as busy" {
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PS_FIXTURE"
exit "${PS_EXIT:-0}"
SH
  chmod +x "$ROOT/bin/ps"
  local probe='import runpy, sys; print(runpy.run_path(sys.argv[1])["gate_or_bats_running"]())'

  run env PATH="$ROOT/bin:$PATH" PS_FIXTURE='101 1 101 bash bash -lc scripts/run-tests.sh' \
    python3 -I -c "$probe" "$BENCH"
  [ "$status" -eq 0 ] && [ "$output" = False ]
  run env PATH="$ROOT/bin:$PATH" PS_FIXTURE='102 1 102 bash bash /repo/scripts/run-tests.sh' \
    python3 -I -c "$probe" "$BENCH"
  [ "$status" -eq 0 ] && [ "$output" = True ]
  run env PATH="$ROOT/bin:$PATH" PS_FIXTURE='103 1 103 python3 python3 /repo/scripts/run-tests-local.py' \
    python3 -I -c "$probe" "$BENCH"
  [ "$status" -eq 0 ] && [ "$output" = True ]
  # Flattened whitespace-bearing script paths are ambiguous: ERROR is busy,
  # never a quiet measurement. Prompt and command-string rows still stay clear.
  run env PATH="$ROOT/bin:$PATH" PS_FIXTURE='104 1 104 bash bash /repo with spaces/scripts/run-tests.sh' \
    python3 -I -c "$probe" "$BENCH"
  [ "$status" -eq 0 ] && [ "$output" = True ]
  run env PATH="$ROOT/bin:$PATH" PS_FIXTURE='105 1 105 python3 python3 /repo with spaces/scripts/run-tests-local.py' \
    python3 -I -c "$probe" "$BENCH"
  [ "$status" -eq 0 ] && [ "$output" = True ]
  run env PATH="$ROOT/bin:$PATH" PS_FIXTURE='106 1 106 bash bash -lc python3 /repo with spaces/scripts/run-tests-local.py' \
    python3 -I -c "$probe" "$BENCH"
  [ "$status" -eq 0 ] && [ "$output" = False ]
  run env PATH="$ROOT/bin:$PATH" PS_FIXTURE='107 1 107 herdr herdr prompt /repo with spaces/scripts/run-tests.sh' \
    python3 -I -c "$probe" "$BENCH"
  [ "$status" -eq 0 ] && [ "$output" = False ]
  run env PATH="$ROOT/bin:$PATH" PS_FIXTURE='' PS_EXIT=3 python3 -I -c "$probe" "$BENCH"
  [ "$status" -eq 0 ] && [ "$output" = True ]
}

@test "contention receipt names a single Bats group rather than the full battery" {
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '108 1 108 bash bash /opt/bats/libexec/bats-core/bats-exec-file scripts/tests/foo.bats'
SH
  chmod +x "$ROOT/bin/ps"
  run env PATH="$ROOT/bin:$PATH" python3 -I "$BENCH" --suite gate \
    --gate-tsv "$ROOT/aggregate.tsv" --gate-wall 5700 --label contention --out "$ROOT/out"
  [ "$status" -eq 0 ]
  jq -e '.host.gate_or_bats_running == true and (.host | has("battery_running") | not)' \
    "$ROOT/out/"bench-*-contention.json >/dev/null
  grep -q 'gate or Bats running True' "$ROOT/out/"bench-*-contention.md
}

@test "gate: a malformed TSV aborts cleanly; a missing wall source warns" {
  printf 'ordinal\tstage\n1\tshellcheck\n' > "$ROOT/bad.tsv"
  run python3 -I "$BENCH" --suite gate --gate-tsv "$ROOT/bad.tsv" --label bad --out "$ROOT/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a run-tests-local timing receipt"* ]]
  [[ "$output" != *Traceback* ]]
  jq -e '.status == "aborted" and .gate == null and (.notes | any(startswith("ABORTED:")))' \
    "$ROOT/out/"bench-*-bad.json >/dev/null

  printf 'ordinal\tstage\telapsed_seconds\texit\n1\tshellcheck\tnot-a-number\t0\n' > "$ROOT/bad-row.tsv"
  run python3 -I "$BENCH" --suite gate --gate-tsv "$ROOT/bad-row.tsv" --label badrow --out "$ROOT/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unreadable timing receipt"* ]]

  run python3 -I "$BENCH" --suite gate --gate-tsv "$ROOT/aggregate.tsv" --label nowall --out "$ROOT/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no wall source"* ]]
  jq -e '.gate.wall_seconds == null and .gate.wall_source == null and .gate.stages == 3
         and (.notes | any(startswith("Gate wall is unknown")))' "$ROOT/out/"bench-*-nowall.json >/dev/null
}

@test "usage errors: unknown suite or section, gate without a TSV; nothing is written" {
  run python3 -I "$BENCH" --out "$ROOT/out" --suite nope
  [ "$status" -eq 2 ]
  run python3 -I "$BENCH" --out "$ROOT/out" --sections nope
  [ "$status" -eq 2 ]
  run python3 -I "$BENCH" --out "$ROOT/out" --suite gate
  [ "$status" -eq 2 ]
  [ -z "$(find "$ROOT/out" -mindepth 1 -print -quit)" ]
}

@test "pi runner: a trellis.ts node cannot load exits 3, which the bench records as unmeasured" {
  command -v node >/dev/null || skip "node is not on PATH"
  mkdir -p "$ROOT/empty-project"
  run node --no-warnings "$SOURCE_ROOT/scripts/bench/pi-handler-runner.mjs" --project "$ROOT/empty-project" \
    --session-file "$ROOT/none.jsonl" --runs 1 --warmup 0 --tool read
  [ "$status" -eq 3 ]
  [[ "$output" == *"cannot load trellis.ts"* ]]
}

@test "committed bench receipts are publishable: no home, temp or private path, no user name" {
  local receipts
  receipts="$(find "$SOURCE_ROOT/specs" -path '*/evidence/bench-*.json')"
  [ -n "$receipts" ]
  # shellcheck disable=SC2086  # one path per line, none with spaces
  run grep -l -e '/Users/' -e '/home/' -e '/var/folders/' -e '/private/' -e '/tmp/' -e "$(id -un)" $receipts
  [ "$status" -eq 1 ]
  # shellcheck disable=SC2086
  jq -e -s 'all(.[]; .sandbox | has("path_counts") and (has("path") | not) and (has("root") | not))' $receipts >/dev/null
}
