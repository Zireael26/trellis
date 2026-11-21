#!/usr/bin/env bats
# Spec 072 T0: `trellis bench` runs end to end and writes a redacted receipt
# whose per-section schema holds.
#
# Cost: 3 minutes on a quiet host, 7-10 under load, nearly all in the first test. It
# installs a release from HEAD into a test TRELLIS_HOME (one full release
# verify), and the bench then copies that release into its own sandbox
# and attaches a fixture project there before timing anything. Both steps are
# the costs spec 072 sets out to remove, so this test gets faster with it.
# The other tests call the script directly and take seconds. The 30-iteration
# worktree test is in trellis-latency-bench-repeat.bats, on the slow tier.

SOURCE_ROOT="$(CDPATH= cd -- "$BATS_TEST_DIRNAME/../.." && pwd -P)"
BENCH="$SOURCE_ROOT/scripts/bench/trellis-latency.py"

load helpers/release-fixture

# A caller machine: the stable launcher plus a release sealed from HEAD and
# installed through the release-store seam, as the release fixtures do.
install_caller_release() {
  local src version payload
  export HOME="$ROOT/home" TRELLIS_HOME="$ROOT/trellis-home"
  mkdir -p "$HOME/.local/bin" "$TRELLIS_HOME" "$ROOT/projects"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  src="$ROOT/release source"
  mkdir -p "$src"
  git -C "$SOURCE_ROOT" archive --format=tar HEAD | tar -x -C "$src"
  # Exercise the candidate bench, including uncommitted T2 files, inside the
  # sealed fixture. Otherwise the route only tests the previous HEAD's runner.
  cp -R "$SOURCE_ROOT/scripts/bench/." "$src/scripts/bench/"
  version="$(cat "$src/core-rules/VERSION")"
  # A caller machine runs a cut release: its VERSION is its native manifest's
  # (a pre-cut checkout ships the next manifest first). Real installs refuse
  # the mismatch, so the caller fixture is the cut release.
  if [ -f "$src/core-rules/native/artifacts.json" ]; then
    version="$(jq -r .version "$src/core-rules/native/artifacts.json")"
    printf '%s\n' "$version" > "$src/core-rules/VERSION"
  fi
  release_fixture_seal_repo "$HOME" "$src" "$version"
  # Package only inside this private repo: read-tree/commit-tree must never
  # write to the source checkout outside the runner's Git fence. Native-bearing
  # releases reject root build sources, so tag the real deletion-only payload.
  payload="$(cd "$src" && bash scripts/release-payload-commit.sh HEAD)" || return 1
  release_fixture_git "$HOME" -C "$src" tag -d "v$version" >/dev/null
  release_fixture_git "$HOME" -C "$src" tag -a "v$version" -m "release $version" "$payload"
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

write_family_evidence_helper() {
  cat > "$ROOT/family-evidence.py" <<'PY'
import json, os, shutil, sys, tempfile, traceback
from pathlib import Path

def preserve_family_failure(base, output, error):
    # Outside the transient Git fence: both Bats and run-tests delete their
    # own scratch on exit, including a failed test's --keep sandbox.
    fence = Path(os.environ.get('TRELLIS_TEST_GIT_FENCE_ROOT', os.environ['TMPDIR'])).resolve()
    store = fence.parent / 'trellis-bench-test-evidence'
    if store.is_symlink():
        raise RuntimeError('refusing symlinked evidence directory')
    store.mkdir(mode=0o700, parents=True, exist_ok=True)
    destination = Path(tempfile.mkdtemp(prefix='test18-failure-', dir=store))
    manifest = {'error_type':type(error).__name__, 'error':str(error),
                'traceback':''.join(traceback.format_exception(type(error),error,error.__traceback__)),
                'original_base':str(base), 'original_output':str(output), 'copy_errors':[]}
    for source, name in ((Path(base),'sandboxes'), (Path(output),'logs')):
        if source.exists():
            try:
                shutil.copytree(source,destination/name,symlinks=True)
            except (OSError,shutil.Error) as copy_error:
                manifest['copy_errors'].append(str(copy_error))
    (destination/'failure.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (destination/'failure.json').chmod(0o600)
    print('retained test 18 sandbox/log snapshot: '+str(destination),file=sys.stderr,flush=True)
    return destination
PY
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

@test "T59 metadata row selection emits version help heavy-status and heavy-check at installed entry" {
  run python3 -I - "$BENCH" "$ROOT" <<'PY'
import runpy,sys
from types import SimpleNamespace
G=runpy.run_path(sys.argv[1])['bench_lifecycle'].__globals__
root=sys.argv[2];seen=[]
sb=SimpleNamespace(root=root,project=root,launcher=root+'/installed-trellis',scratch=root,env=lambda:{})
items=['launcher-version','launcher-help','launcher-heavy-status','launcher-heavy-check']
def capture(case,members,*args,**kwargs):
    seen.append((case,members[0].argv))
    return {'id':case,'status':'ok','observations':[]}
G['measure']=capture
rows=[]
G['bench_lifecycle'](sb,SimpleNamespace(lifecycle_items=items,lifecycle_runs=1,warmup=0,condition='normal'),rows)
expected=[['--version'],['help'],['heavy','--status'],['heavy','--check']]
assert [r['id'] for r in rows]==items,rows
assert seen==[(case,[sb.launcher]+argv) for case,argv in zip(items,expected)],seen
assert all(case in G['LIFECYCLE_ITEMS'] for case in items)
print('four selectable metadata rows target the installed entry, no timing performed')
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "T60 launcher-heavy row uses the complete executable entry not metadata" {
  run python3 -I - "$BENCH" "$ROOT" <<'PY'
import runpy,sys
from types import SimpleNamespace
G=runpy.run_path(sys.argv[1])['bench_lifecycle'].__globals__
root=sys.argv[2];seen=[]
sb=SimpleNamespace(root=root,project=root+'/project',launcher=root+'/installed-trellis',scratch=root,env=lambda:{})
def capture(case,members,stdin,cwd,*args,**kwargs):
    seen.append((case,members[0].argv,cwd))
    return {'id':case,'status':'ok','observations':[]}
G['measure']=capture
rows=[]
G['bench_lifecycle'](sb,SimpleNamespace(lifecycle_items=['launcher-heavy'],lifecycle_runs=1,warmup=0,condition='normal'),rows)
assert [row['id'] for row in rows]==['launcher-heavy'],rows
assert seen==[('launcher-heavy',[sb.launcher,'heavy','--lane','bench','--','true'],sb.project)],seen
print('complete installed launcher-heavy argv selected; no timing performed')
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
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
  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    for receipt in "$ROOT/out/"bench-*-tiny.json; do
      [ ! -f "$receipt" ] || jq -c '{status,notes,results:[.results[] | select(.status == "failed") | {id,status,error,observations}]}' "$receipt" >&2
    done
    return 1
  }

  local receipt md
  receipt="$(find "$ROOT/out" -name 'bench-*-tiny.json')"
  md="$(find "$ROOT/out" -name 'bench-*-tiny.md')"
  [ -f "$receipt" ] && [ -f "$md" ]
  [[ "$(basename "$receipt")" =~ ^bench-[0-9]{4}-[0-9]{2}-[0-9]{2}-tiny\.json$ ]] || false

  jq -e '
    def case(id): .results[] | select(.id == id);
    .schema == "trellis-latency-bench/1" and .status == "ok"
    and .declared_condition == "normal" and (.condition == "normal" or .condition == "load-contended")
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
         # Count actual per-handler calls, not the old combined pre+post count.
         and .blocked_runs == 0 and .exec_calls_per_run == 0)
    # T18 handles shell results in-process; it must not fork the dispatcher
    # merely to return the captured native content-block array.
    and (case("pi tool_result bash") | .exec_calls_per_run == 0)
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
  run env LC_ALL=C pgrep -f "$ROOT/.*trellis-bench\."
  [ "$status" -eq 1 ] || {
    local survivor_status="$status" survivor_pids="$output" survivor_pid
    printf 'bench survivor check: exit=%s root=%s\n%s\n' "$survivor_status" "$ROOT" "$survivor_pids" >&2
    env LC_ALL=C pgrep -fl "$ROOT/.*trellis-bench\." >&2 || true
    for survivor_pid in $survivor_pids; do
      case "$survivor_pid" in ''|*[!0-9]*) continue ;; esac
      ps -p "$survivor_pid" -o pid=,ppid=,pgid=,etime=,command= >&2 || true
    done
    return 1
  }
}

# A fixture sandbox with no Trellis attached and a stub launcher, handed to
# main() in place of build_sandbox. SCENARIO seeds what the hooks-on teardown
# finds for bench-wt-on-1.
write_teardown_probe() {
  cat > "$ROOT/probe.py" <<'PY'
import json, os, runpy, subprocess, sys
bench, base, scenario = sys.argv[1], sys.argv[2], sys.argv[3]
G = runpy.run_path(bench)["main"].__globals__

def fake_build(_base, _source, _rev):
    root = os.path.realpath(os.path.join(base, "trellis-bench.fake"))
    sb = G["Sandbox"](root)
    for path in (sb.home, sb.trellis_home, sb.tmp, os.path.dirname(sb.launcher), str(sb.scratch), sb.project):
        os.makedirs(path)
    with open(sb.launcher, "w") as stub:
        stub.write('#!/bin/sh\nprintf "%s\\n" "$*" >> "$HOME/launcher.log"\nexit {}\n'.format(
            1 if scenario == "detach-fails" else 0))
    os.chmod(sb.launcher, 0o755)
    git = lambda *a: subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-C", sb.project] + list(a),
                                    check=True, capture_output=True, env=sb.env())
    git("-c", "init.defaultBranch=main", "init", "-q")
    git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "i")
    wt = os.path.join(root, "worktrees", "bench-wt-on-1")
    rows = {"w0": {"root": sb.project, "attachment_id": "a0"}}
    if scenario != "not-attached":
        rows["w1"] = {"root": wt, "attachment_id": "a1"}
        for kind, record in (("attachments", {"attachment_id": "a1"}),
                             ("attachment-status", {"state": "pending" if scenario == "postjob-pending" else "ok",
                                                    "attachment_id": "a1"})):
            os.makedirs(os.path.join(sb.trellis_home, "state", kind, "c1"))
            with open(os.path.join(sb.trellis_home, "state", kind, "c1", "w1.json"), "w") as f:
                json.dump(record, f)
    with open(os.path.join(sb.trellis_home, "registry.json"), "w") as f:
        json.dump({"projects": {"personal/fx": {"checkouts": {"c1": {"worktrees": rows}}}}}, f)
    sb.meta = {"setup_seconds": {}}
    return sb

G["build_sandbox"] = fake_build
sys.exit(G["main"](["--sections", "lifecycle", "--lifecycle-items", "git-worktree-add", "--lifecycle-runs", "1", "--warmup", "0",
                    "--label", scenario, "--out", os.path.join(base, "out"), "--sandbox-base", base]))
PY
}

@test "git-worktree-add: a teardown failure fails the bench and keeps the sandbox, worktree and owner as evidence" {
  write_teardown_probe
  local scenario sb expect
  for scenario in not-attached postjob-pending detach-fails owner-survives; do
    case "$scenario" in
      not-attached) expect='is not registered after a hooks-on worktree add' ;;
      postjob-pending) expect='attach postjob for .* ended pending' ;;
      detach-fails) expect='trellis detach .* exited 1' ;;
      owner-survives) expect='owner record survived trellis detach' ;;
    esac
    mkdir -p "$ROOT/$scenario"
    run python3 -I "$ROOT/probe.py" "$BENCH" "$ROOT/$scenario" "$scenario"
    [ "$status" -eq 1 ] || { printf '%s: %s\n' "$scenario" "$output" >&2; return 1; }
    [[ "$output" =~ $expect ]] || { printf '%s: %s\n' "$scenario" "$output" >&2; return 1; }
    [[ "$output" == *"kept sandbox: "* ]] || false
    jq -e '.status == "failed" and .sandbox.kept == true and (.notes[-1] | startswith("FAILED lifecycle "))' \
      "$ROOT/$scenario/out/"bench-*-"$scenario".json >/dev/null
    sb="$ROOT/$scenario/trellis-bench.fake"
    # Nothing past the failure ran: worktree, branch and owner record stay.
    [ -d "$sb/worktrees/bench-wt-on-1" ]
    git -C "$sb/projects/bench-fixture" rev-parse -q --verify refs/heads/bench-wt-on-1 >/dev/null
    [ "$scenario" = not-attached ] || [ -f "$sb/trellis-home/state/attachments/c1/w1.json" ]
    # The hooks-off pass before it cleaned up after itself.
    [ ! -e "$sb/worktrees/bench-wt-off-1" ]
  done
  # Only the scenarios that reach detach ran it, against the worktree alone.
  [ "$(cat "$ROOT/detach-fails/trellis-bench.fake/home/launcher.log")" = "detach $ROOT/detach-fails/trellis-bench.fake/worktrees/bench-wt-on-1" ]
  [ ! -e "$ROOT/postjob-pending/trellis-bench.fake/home/launcher.log" ]
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
  jq -e '.host.gate_or_bats_running == true and .condition == "load-contended"
         and (.host | has("battery_running") | not)' \
    "$ROOT/out/"bench-*-contention.json >/dev/null
  grep -q 'gate or Bats running True' "$ROOT/out/"bench-*-contention.md
}

@test "gate: a malformed TSV aborts cleanly; a missing wall source warns" {
  printf 'ordinal\tstage\n1\tshellcheck\n' > "$ROOT/bad.tsv"
  run python3 -I "$BENCH" --suite gate --gate-tsv "$ROOT/bad.tsv" --label bad --out "$ROOT/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a run-tests-local timing receipt"* ]] || false
  [[ "$output" != *Traceback* ]] || false
  jq -e '.status == "aborted" and .gate == null and (.notes | any(startswith("ABORTED:")))' \
    "$ROOT/out/"bench-*-bad.json >/dev/null

  printf 'ordinal\tstage\telapsed_seconds\texit\n1\tshellcheck\tnot-a-number\t0\n' > "$ROOT/bad-row.tsv"
  run python3 -I "$BENCH" --suite gate --gate-tsv "$ROOT/bad-row.tsv" --label badrow --out "$ROOT/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unreadable timing receipt"* ]] || false

  run python3 -I "$BENCH" --suite gate --gate-tsv "$ROOT/aggregate.tsv" --label nowall --out "$ROOT/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no wall source"* ]] || false
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

@test "pi runner: a trellis.ts import failure is failed, never an unavailable runtime" {
  command -v node >/dev/null || skip "node is not on PATH"
  mkdir -p "$ROOT/empty-project"
  run node --no-warnings "$SOURCE_ROOT/scripts/bench/pi-handler-runner.mjs" --project "$ROOT/empty-project" \
    --session-file "$ROOT/none.jsonl" --runs 1 --warmup 0 --tool read
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | jq -e '.failed and .runtime_supported
    and .error_kind == "extension-import" and (.error | contains("cannot load trellis.ts"))'
  local extension="$ROOT/empty-project/.trellis/runtime/core-rules/pi/extensions/trellis.ts"
  mkdir -p "$(dirname "$extension")"
  printf '%s\n' 'throw new Error("deliberate import regression"); export default () => {};' > "$extension"
  run node --no-warnings "$SOURCE_ROOT/scripts/bench/pi-handler-runner.mjs" --project "$ROOT/empty-project" \
    --session-file "$ROOT/none.jsonl" --runs 1 --warmup 0 --tool read
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | jq -e '.failed and .error_kind == "extension-import"
    and (.error | contains("deliberate import regression"))'
}

# Fast T2 probes exercise the real timing engine without installing a release.
write_measure_probe() {
  cat > "$ROOT/measure-probe.py" <<'PY'
import json, os, runpy, signal, subprocess, sys, time
G = runpy.run_path(sys.argv[1])
mode, scratch = sys.argv[2:]
G = G['measure'].__globals__
G['COMMAND_TIMEOUT'] = 1 if mode == 'grandchild' else 0.2
Member = G['Member']
code = 'pass'
payload = b''
if mode == 'nonzero': code = 'raise SystemExit(7)'
if mode == 'warmup-failure': code = 'raise SystemExit(7)'
if mode == 'blocked-stdin':
    code = 'import time; time.sleep(30)'
    payload = b'x' * (4 * 1024 * 1024)
if mode == 'completion': code = 'import time; time.sleep(0.06)'
if mode == 'grandchild':
    code = ('import subprocess,sys,time; child=subprocess.Popen([sys.executable,"-I","-c","import time; time.sleep(30)"]); '
            + 'open(' + repr(os.path.join(scratch, 'child.pid')) + ',"w").write(str(child.pid)); time.sleep(30)')
ready = (lambda: False) if mode == 'not-ready' else None
start = time.monotonic()
try:
    argv = ['/nonexistent/trellis-bench-worker'] if mode == 'exec-failure' else [sys.executable, '-I', '-c', code]
    record = G['measure']('probe', [Member('probe', argv)],
        payload, scratch, dict(os.environ), 2, 2, G['Path'](scratch), readiness=ready,
        extra={'fixture_id': 'fixture-v1', 'boundary_id': 'blocking-v1'})
    print(json.dumps({'accepted': True, 'record': record, 'elapsed': time.monotonic()-start}))
except G['BenchError'] as error:
    group_clean = True
    if mode == 'grandchild':
        pid = int(open(os.path.join(scratch, 'child.pid')).read())
        for _ in range(100):
            state = subprocess.run(['ps','-o','stat=','-p',str(pid)], capture_output=True, text=True).stdout.strip()
            if not state or state.startswith('Z'): break
            time.sleep(0.01)
        group_clean = not state or state.startswith('Z')
        if not group_clean:
            os.kill(pid, signal.SIGKILL)
    print(json.dumps({'accepted': False, 'record': error.record, 'elapsed': time.monotonic()-start, 'group_clean': group_clean}))
PY
}

@test "T2 observations retain warmups, exact exits, readiness and blocking completion" {
  write_measure_probe
  run python3 -I "$ROOT/measure-probe.py" "$BENCH" completion "$ROOT/tmp"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  printf '%s\n' "$output" | tail -1 > "$ROOT/measure.json"
  jq -e '.accepted and (.record.observations | length == 4)
    and (.record.observations | map(.warmup) == [true,true,false,false])
    and all(.record.observations[]; .case_id == "probe" and .fixture_id == "fixture-v1"
      and .boundary_id == "blocking-v1" and .exit == 0 and .readiness == true
      and .timeout == false and .wall_ms >= 60)
    and .record.wall_ms.n == 2' "$ROOT/measure.json"
}

@test "T2 rejects nonzero success exits and incomplete readiness including warmups" {
  write_measure_probe
  local mode
  for mode in nonzero not-ready warmup-failure exec-failure; do
    run python3 -I "$ROOT/measure-probe.py" "$BENCH" "$mode" "$ROOT/tmp"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
    printf '%s\n' "$output" | tail -1 > "$ROOT/measure.json"
    jq -e '.accepted == false and (.record.observations | length == 1)
      and .record.observations[0].warmup == true
      and (.record.observations[0] | .exit != 0 or .readiness == false)' "$ROOT/measure.json"
  done
}

@test "T2 independent watchdog bounds blocked stdin and kills process groups" {
  write_measure_probe
  local mode
  for mode in blocked-stdin grandchild; do
    run python3 -I "$ROOT/measure-probe.py" "$BENCH" "$mode" "$ROOT/tmp"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
    printf '%s\n' "$output" | tail -1 > "$ROOT/measure.json"
    jq -e '.accepted == false and .elapsed < 5 and .group_clean
      and .record.observations[0].timeout == true' "$ROOT/measure.json"
  done
}

@test "T2 Pi runner retains handler observations and independently bounds synchronous hangs" {
  command -v node >/dev/null || skip "node is not on PATH"
  local extension="$ROOT/pi/.trellis/runtime/core-rules/pi/extensions/trellis.ts"
  mkdir -p "$(dirname "$extension")"
  printf '%s\n' 'export default pi => { pi.on("tool_call", async () => {}); pi.on("tool_result", async () => {}); };' > "$extension"
  run node --no-warnings "$SOURCE_ROOT/scripts/bench/pi-handler-runner.mjs" --project "$ROOT/pi" \
    --runs 2 --warmup 2 --tool read --timeout-ms 2000
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  printf '%s\n' "$output" > "$ROOT/pi.json"
  jq -e '.registered and (.observations | length == 8)
    and ([.observations[] | select(.warmup)] | length == 4)
    and all(.observations[]; .exit == 0 and .readiness and (.timeout | not))' "$ROOT/pi.json"
  printf '%s\n' 'export default pi => { pi.on("tool_call", () => { while (true) {} }); pi.on("tool_result", () => {}); };' > "$extension"
  run node --no-warnings "$SOURCE_ROOT/scripts/bench/pi-handler-runner.mjs" --project "$ROOT/pi" \
    --runs 1 --warmup 0 --tool read --timeout-ms 500
  [ "$status" -eq 1 ] || { printf '%s\n' "$output" >&2; return 1; }
  printf '%s\n' "$output" > "$ROOT/pi.json"
  jq -e '.failed and (.observations | length == 1)
    and .observations[0].timeout and (.observations[0].readiness | not)' "$ROOT/pi.json"
}

@test "T2 corpus preserves required r2 variants, bounded Skill fixtures and explicit payloads" {
  run python3 -I -c '
import runpy,sys
from pathlib import Path
G=runpy.run_path(sys.argv[1]); rows=G["corpus"]("native-cases.json"); skills=G["corpus"]("skill-cases.json")
ids={r["id"] for r in rows}
assert {"bash-non-pr","bash-pr-create","bash-pr-prose","reread-known","reread-warn","reread-block","reread-missing-parser","edit-tracking-enabled","edit-tracking-disabled","write-tracking-enabled","write-tracking-disabled","edit-failed","write-failed","edit-native-result","write-native-result"} <= ids
assert any(r["bytes"] == 65536 for r in skills)
assert any(r["bytes"] == 65537 for r in skills)
assert any(r["encoding"] == "invalid-utf8" for r in skills)
root=Path(sys.argv[1]).parent / "payloads"
for name in ("hook-PreToolUse-MultiEdit.json","hook-PostToolUse-MultiEdit.json","hook-PreCompact.json","hook-UserPromptExpansion.json","hook-WorktreeCreate.json","hook-WorktreeRemove.json","pi-user_bash.json","pi-agent_before_settle.json","pi-session_compact.json","pi-session_shutdown.json"):
    assert (root/name).is_file(),name
' "$BENCH"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "R2 readiness overhead is separate, callback failures erase stats, and exec failures are distinct" {
  run python3 -I - "$BENCH" "$ROOT/tmp" <<'PY'
import json, os, runpy, sys, time
from pathlib import Path
G = runpy.run_path(sys.argv[1])['measure'].__globals__
G['COMMAND_TIMEOUT'] = 2
scratch = Path(sys.argv[2]); original = G['run_group']; operations = []
def observed(*a, **k):
    value = original(*a, **k); operations.append(value['wall_ms']); return value
G['run_group'] = observed
member = G['Member']('python', [sys.executable, '-I', '-c', 'pass'])
def slow(): time.sleep(.08); return True
record = G['measure']('slow-readiness', [member], b'', str(scratch), dict(os.environ), 1, 0, scratch, readiness=slow)
assert record['observations'][0]['wall_ms'] == operations[-1], 'readiness inflated operation wall'
assert record['observations'][0]['readiness_ms'] >= 60
assert record['observations'][0]['readiness'] is True
for phase in ('before', 'readiness', 'after'):
    def broken(*a): raise KeyError('deliberate callback error')
    try:
        G['measure']('broken-'+phase, [member], b'', str(scratch), dict(os.environ), 1, 0, scratch, **{phase: broken}, extra={'section':'pi', 'harness':'pi'})
        raise AssertionError('exception accepted')
    except G['BenchError'] as error:
        rec = error.record
        assert rec['status'] == 'failed' and rec['wall_ms'] is None and rec['cpu_ms'] is None
        assert rec['section'] == 'pi' and rec['harness'] == 'pi'
        assert rec['observations'][-1]['error']['phase'] == phase
        assert rec['observations'][-1]['error']['type'] == 'KeyError'
calls = 0
def fail_third():
    global calls
    calls += 1
    return calls < 3
try:
    G['measure']('partial', [member], b'', str(scratch), dict(os.environ), 3, 0, scratch, readiness=fail_third, extra={'section':'lifecycle'})
    raise AssertionError('partial accepted')
except G['BenchError'] as error:
    rec = error.record
    assert rec['runs_completed'] == 2 and rec['wall_ms'] is None
    assert 'partial' not in G['summarize']([rec])['lifecycle_p50']
for argv, exec_error in (([sys.executable,'-I','-c','raise SystemExit(127)'], False), (['/nonexistent/bench-exec'], True)):
    try:
        rec = G['measure']('exit-127', [G['Member']('127',argv)], b'', str(scratch), dict(os.environ), 1, 0, scratch, extra={'expected_exit_codes':[127]})
        assert not exec_error
    except G['BenchError'] as error:
        rec = error.record
        assert exec_error
    assert rec['observations'][0]['exec_error'] is exec_error
    assert rec['observations'][0]['exit'] == 127
print('round2 core assertions passed')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "R2 callback deadlines, positive decision evidence and pre-push execution proof" {
  run python3 -I - "$BENCH" "$ROOT/tmp" <<'PY'
import hashlib, json, os, runpy, shlex, sys, time
from pathlib import Path
from types import SimpleNamespace
G=runpy.run_path(sys.argv[1])['measure'].__globals__; root=Path(sys.argv[2]); sb=G['Sandbox'](str(root/'private'))
for path in (sb.home,sb.tmp,sb.project,str(sb.scratch),sb.trellis_home): Path(path).mkdir(parents=True,exist_ok=True)
# All callback phases share a hard deadline; a hanging probe cannot leak a receipt.
G['COMMAND_TIMEOUT']=.08
original=G['run_group']
G['run_group']=lambda *a,**k: {'wall_ms':1,'cpu_ms':0,'members':[{'rc':0,'timed_out':False,'exec_error':False,'wall_ms':1,'stdout':'','stderr':''}]}
for phase in ('before','readiness','after'):
    def slow(*a): time.sleep(5); return True
    try: G['measure']('deadline-'+phase,[G['Member']('unused',['true'])],b'',sb.project,sb.env(),1,0,sb.scratch,**{phase:slow}); raise AssertionError('deadline ignored')
    except G['BenchError'] as error:
        obs=error.record['observations'][0]
        assert obs['callback_timeout'] and not obs['timeout'] and obs['error']['phase']==phase
        assert obs['exit'] == (None if phase == 'before' else 0)
G['run_group']=original; G['COMMAND_TIMEOUT']=5
# Quiet legacy hooks get no-denial, not invented positive evidence.
(sb.scratch/'m0.out').write_text(''); (sb.scratch/'m0.err').write_text(''); evidence={}
assert G['hook_readiness'](sb,[G['Member']('quiet',['true'])],evidence=evidence)
assert evidence['readiness_kind']=='no-denial'
(sb.scratch/'m0.out').write_text('{"decision":"block"}\n')
assert not G['hook_readiness'](sb,[G['Member']('quiet',['true'])],evidence=evidence)
assert G['hook_readiness'](sb,[G['Member']('deny',['true'])],decision='deny',evidence=evidence)
assert evidence['readiness_kind']=='proven'
# A supported allow MUST NOT satisfy a corpus row expecting unsupported.
dispatch=Path(sb.project,'.trellis/runtime/core-rules/pi/hooks/dispatch.sh'); dispatch.parent.mkdir(parents=True)
args=SimpleNamespace(hooks=r'^pi-dispatch tool_result edit edit-failed$',condition='normal',runs=1,warmup=0)
for capability,valid in (('enforced',False),('unsupported',True)):
    dispatch.write_text('#!/bin/sh\nprintf \'%s\\n\' \''+json.dumps({'schema_version':1,'capability_status':capability,'decision':'allow'})+'\'\n'); dispatch.chmod(0o700)
    try:
        rows=[]; G['bench_pi_dispatch'](sb,args,rows); assert valid
        assert rows[0]['status']=='diagnostic' and rows[0]['readiness_kind']=='proven'
    except G['BenchError'] as error:
        assert not valid and error.record['status']=='failed'
# Parser-level proof killers, in addition to the real dispatcher family smoke.
sources=[]
for name in ('dispatcher','carrier','postjob','run-all.sh','diagnostic'):
    path=root/name; path.write_text(name)
    sources.append({'path':str(path),'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
proof={'installed_sources':sources[:4],'diagnostic_dispatcher':sources[4],'samples':[]}
commands=[]
for _ in range(2):
    commands += [['trellis_run_control_payload',sources[2]['path'],'prepush','--target',sb.project],['attach_postjob_prepush',sb.trellis_home,sb.project],['attach_status=0']]
commands += [['trellis_run_gate_payload',sources[1]['path'],'origin','fixture://bench'],['classify_refs'],['REFS_SEEN=1'],['echo','[pre-push] no new commits to gate (deletes only).']]
trace=''.join('+A4TRACE '+shlex.join(row)+'\n' for row in commands)
# Discovering and assigning the battery path is not a battery invocation.
trace += '+A4TRACE candidate='+sources[3]['path']+'\n+A4TRACE RUNALL='+sources[3]['path']+'\n'
(sb.scratch/'m0.out').write_text('[pre-push] no new commits to gate (deletes only).\n'); (sb.scratch/'m0.err').write_text(trace)
assert G['prepush_trace_ready'](sb,proof,0)
for invalid in (trace+'+A4TRACE bash -p '+sources[3]['path']+'\n', trace.replace('+A4TRACE classify_refs\n',''), trace.replace('+A4TRACE '+shlex.join(commands[3])+'\n','',1)):
    (sb.scratch/'m0.err').write_text(invalid)
    try: G['prepush_trace_ready'](sb,proof,1); raise AssertionError('false pre-push proof accepted')
    except G['BenchError']: pass
print('round2 deadline and positive proof assertions passed')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "R2 unexpected family errors still write a failed receipt and clean sandbox" {
  run python3 -I - "$BENCH" "$ROOT" <<'PY'
import json, runpy, sys
from pathlib import Path
G = runpy.run_path(sys.argv[1])['main'].__globals__; root = Path(sys.argv[2]); sandbox = root/'failed-sandbox'
def build(*a):
    sb = G['Sandbox'](str(sandbox)); sandbox.mkdir(); sb.meta = {}; return sb
def fail(*a): raise KeyError('family failure')
G['build_sandbox'] = build; G['bench_pi'] = fail
G['gate_or_bats_running'] = lambda: False
assert G['main'](['--sections','pi','--hooks','^pi user_bash$','--label','failure','--out',str(root/'out')]) == 1
assert not sandbox.exists(), 'sandbox leaked'
receipt = json.loads(next((root/'out').glob('bench-*-failure.json')).read_text())
assert receipt['status'] == 'aborted'
assert receipt['results'][-1]['status'] == 'failed'
assert receipt['results'][-1]['error']['type'] == 'KeyError'
# A receipt writer failure must still trigger finally cleanup.
G['markdown'] = fail
try: G['main'](['--sections','pi','--label','writer-failure','--out',str(root/'out')])
except KeyError: pass
assert not sandbox.exists(), 'writer failure leaked sandbox'
print('round2 exception cleanup assertions passed')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

# R2 M7/L1: denominator/runner equivalence and real installed-family coverage.
# Deliberately appended: existing T2/R2 probes and their helpers stay unchanged.
@test "R2 M7 actual runner routing emits exactly the listed identities, including unmeasured paths" {
  run python3 -I - "$BENCH" "$ROOT/tmp" <<'PY'
import json, runpy, subprocess, sys
from pathlib import Path
from unittest.mock import patch
G = runpy.run_path(sys.argv[1])['main'].__globals__
root = Path(sys.argv[2]) / 'dry-routing'
root.mkdir()
keys = ('id', 'fixture_id', 'boundary_id', 'variant')
def identities(rows):
    result = {row['id']: {key: row[key] for key in keys} for row in rows}
    assert len(result) == len(rows), 'duplicate runner IDs'
    return result
# Exercise the public listing too, before any seams are replaced.
listed = json.loads(subprocess.run([sys.executable, '-I', sys.argv[1], '--list-cases'],
                                  check=True, capture_output=True, text=True).stdout)
assert listed['schema'] == 'trellis-bench-case-matrix/1'
expected = identities(G['case_matrix']())
assert identities(listed['cases']) == expected
sb = G['Sandbox'](str(root))
for directory in (sb.home, sb.trellis_home, sb.tmp, sb.scratch, sb.project):
    Path(directory).mkdir(parents=True, exist_ok=True)
dispatcher = Path(sb.project, '.trellis/runtime/core-rules/pi/hooks/dispatch.sh')
dispatcher.parent.mkdir(parents=True)
dispatcher.write_text('not executed\n')
args = G['parse_args'](['--n', '1', '--warmup', '0'])
calls = {'measure': [], 'unmeasured': [], 'samples': [], 'pi-runner': []}
original_unmeasured = G['unmeasured']
def measure_spy(case_id, members, stdin, cwd, env, runs, warmup, scratch,
                before=None, after=None, extra=None, readiness=None, **kwargs):
    # Record actual calls from the runner loops; never iterate the matrix here.
    # Callbacks/commands are fixture seams, not work performed by a dry route.
    assert members and all(isinstance(member, G['Member']) for member in members)
    calls['measure'].append(case_id)
    extra = extra or {}
    return dict(extra, id=case_id, fixture_id=extra.get('fixture_id', 'bench-fixture-v1'),
                boundary_id=extra.get('boundary_id', case_id), variant=extra.get('variant', 'warm'),
                status='ok', observations=[], wall_ms=None)
def unmeasured_spy(case_id, note, **extra):
    calls['unmeasured'].append(case_id)
    return original_unmeasured(case_id, note, **extra)
def samples_spy(case_id, values, runs, warmup, load_start, extra):
    calls['samples'].append(case_id)
    return dict(extra, id=case_id, status='ok', wall_ms=None)
def fake_process(argv, **kwargs):
    # Only the Pi coordinator is mocked here. Build its transport report from
    # the invocation the real bench_pi made, not from case_matrix/list-cases.
    assert Path(argv[2]).name == 'pi-handler-runner.mjs', argv
    option = lambda name: argv[argv.index(name) + 1]
    shape = option('--result-shape')
    tool = option('--tool') if '--tool' in argv else None
    events = ('tool_call', 'tool_result') if tool else (option('--event'),)
    calls['pi-runner'].append((tool, tuple(events), shape))
    observations = []
    for event in events:
        case_id = 'pi ' + event + (' ' + tool if tool else '') + ('' if shape == 'text' else ' ' + shape)
        observations.append(dict(case_id=case_id, fixture_id='clean' if shape == 'text' else 'result-' + shape,
                                 boundary_id='pi-handler', event=event, warmup=False, exit=0, member_exits=[0],
                                 readiness=True, readiness_kind='no-denial', exec_error=False, timeout=False,
                                 exec_calls=0, wall_ms=0))
    return subprocess.CompletedProcess(argv, 0, json.dumps(dict(registered=True, failed=False,
                                                               observations=observations)).encode(), b'')
def fake_git(argv, cwd, **kwargs):
    # Lifecycle preparation requests paths/refs, but never runs git in a dry pass.
    value = str(root / 'hooks') if argv[:2] == ['config', '--get'] else 'a' * 40
    return subprocess.CompletedProcess(argv, 0, (value + '\n').encode(), b'')
def fake_trace(_sb, _dispatcher):
    path = sb.scratch / 'diagnostic-pre-push'
    path.write_text('not executed\n')
    return path, {}
def forbidden(*args, **kwargs):
    raise AssertionError('dry routing tried to execute a command/callback')
# Registered and absent hook routes are both observed. The matching/command
# implementations are out of scope here; the installed tests below use them.
G['measure'] = measure_spy
G['unmeasured'] = unmeasured_spy
G['samples_record'] = samples_spy
G['setup_skills'] = lambda sb: None
G['missing_jq_env'] = lambda sb, env: env  # No executable fixture preparation in dry routing.
G['claude_forms'] = lambda sb: [(name, {}, {}) for name in ('claude', 'claude R1', 'claude R2')]
G['load_hooks'] = lambda path: {}
G['worktree_callback_hooks'] = lambda sb: {}  # attach --user renders fixture state: dry routing never runs it.
G['matched_hooks'] = lambda hooks, event, *a, **k: [] if event == 'SessionEnd' else [G['Member']('dry', forbidden)]
G['active_python_fixture'] = lambda sb, event, env: (forbidden, forbidden, forbidden, lambda: None, env)
G['prepush_trace_fixture'] = fake_trace
G['sc13_fixture'] = lambda _sb: {'sandbox': sb, 'proof': {}, 'argv': [str(root / 'hooks/pre-push'), 'origin', 'fixture://bench'],
                               'refs': b'ordinary update', 'base': 'a' * 40, 'head': 'b' * 40}
G['launcher_setup'] = forbidden
G['run_group'] = forbidden  # Accepts deadline= too; no dry operation may reach it.
sb.git = fake_git
sb.env = lambda **extra: dict(PATH=str(root / 'empty-bin'), **extra)
Path(root, 'empty-bin').mkdir()
rows = []
with patch.object(G['shutil'], 'which', return_value='/mock/node'), \
     patch.object(G['subprocess'], 'run', side_effect=fake_process):
    G['bench_hook_harness']('claude', sb, args, rows)
    G['bench_hook_harness']('codex', sb, args, rows)
    G['bench_pi'](sb, args, rows)
    G['bench_pi_dispatch'](sb, args, rows)
    G['bench_lifecycle'](sb, args, rows)
actual = identities(rows)
assert actual == expected, dict(missing=sorted(expected.keys() - actual.keys()),
                               unexpected=sorted(actual.keys() - expected.keys()),
                               changed={key: (expected[key], actual[key]) for key in expected.keys() & actual.keys()
                                        if actual[key] != expected[key]})
assert calls['measure'] and calls['unmeasured'] and calls['samples'] and calls['pi-runner']
assert 'claude SessionEnd' in calls['unmeasured']
assert 'pi-dispatch tool_call read' in calls['unmeasured']
assert 'pi tool_result edit native' in calls['samples']
# Missing node takes a genuinely different branch: it must preserve identities
# instead of silently dropping the Pi denominator or reusing successful rows.
absent = []
with patch.object(G['shutil'], 'which', return_value=None), \
     patch.object(G['subprocess'], 'run', side_effect=forbidden):
    G['bench_pi'](sb, args, absent)
assert identities(absent) == identities([row for row in rows if row.get('section') == 'pi'])
assert all(row['status'] == 'not-measured' and not row['observations'] for row in absent)
print('R2 M7: complete actual runner identity map equals case_matrix and --list-cases')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "R2 L1 corpus pins deny and warn exits, literal tracking flags and closed schemas" {
  run python3 -I - "$BENCH" "$ROOT/tmp" <<'PY'
import copy, json, runpy, sys
from pathlib import Path
G = runpy.run_path(sys.argv[1])['corpus'].__globals__
native = {row['id']: row for row in G['corpus']('native-cases.json')}
skills = {row['id']: row for row in G['corpus']('skill-cases.json')}
for case_id, decision, exits in (('reread-warn', 'warn', [0]), ('reread-block', 'deny', [0, 2]),
                                 ('reread-missing-parser', 'deny', [0, 2])):
    assert (native[case_id]['decision'], native[case_id]['expected_exit_codes']) == (decision, exits), case_id
for case_id in ('ambiguous', 'over-budget', 'invalid-utf8'):
    assert (skills[case_id]['decision'], skills[case_id]['expected_exit_codes']) == ('deny', [0, 2]), case_id
for tool in ('edit', 'write'):
    for suffix, flag in (('enabled', False), ('disabled', True)):
        row = native[tool + '-tracking-' + suffix]
        assert row['patch'] == {'in_process_read_tracking': flag}, row
        # Equality alone also accepts 0/1; the wire contract requires booleans.
        assert row['patch']['in_process_read_tracking'] is flag
        assert row['decision'] == 'allow' and row['expected_exit_codes'] == [0]
    assert native[tool + '-failed']['decision'] == 'unsupported'
    assert native[tool + '-failed']['expected_exit_codes'] == [0]
original_payloads = G['PAYLOADS']
private = Path(sys.argv[2]) / 'closed-corpus'
private.mkdir()
# Resolve real payload leaves while substituting only private corpus documents.
for path in original_payloads.iterdir():
    if path.is_file() and path.name not in ('native-cases.json', 'skill-cases.json'):
        (private / path.name).symlink_to(path)
try:
    for name in ('native-cases.json', 'skill-cases.json'):
        original = json.loads((original_payloads / name).read_text())
        G['PAYLOADS'] = private
        (private / name).write_text(json.dumps(original))
        assert G['corpus'](name) == original['cases']
        for mutation in ('document-field', 'row-field', 'schema-version'):
            document = copy.deepcopy(original)
            if mutation == 'document-field': document['unknown_r2_field'] = True
            elif mutation == 'row-field': document['cases'][0]['unknown_r2_field'] = True
            else: document['schema'] = 'unknown/99'
            (private / name).write_text(json.dumps(document))
            try:
                G['corpus'](name)
            except G['BenchError']:
                pass
            else:
                raise AssertionError((name, mutation, 'accepted unknown corpus contract'))
finally:
    G['PAYLOADS'] = original_payloads
print('R2 L1: decisions/exits/tracking literals and unknown-field rejection pinned')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "R2 M7 new families execute through private sealed installed routes with honest readiness" {
  # One seal/install. On failure, copy sandbox/state/Trace2 and command logs
  # outside the transient fence before cleanup, so flakes remain diagnosable.
  write_family_evidence_helper
  install_caller_release
  run python3 -I - "$BENCH" "$ROOT" "$HOME/.local/bin/trellis" <<'PY'
import json, re, runpy, subprocess, sys
from pathlib import Path
G = runpy.run_path(sys.argv[1])['main'].__globals__
root, launcher = Path(sys.argv[2]), sys.argv[3]
base = root / 'tmp'
expected = {row['id']: row for row in G['case_matrix']()}
seen = set()
ordinal = 0
preserve_family_failure = runpy.run_path(str(root/'family-evidence.py'))['preserve_family_failure']

def recorded_process(argv, label, timeout):
    output=root/'out'; output.mkdir(exist_ok=True)
    (output/(label+'.command.json')).write_text(json.dumps({'argv':argv},indent=2)+'\n')
    def save(stdout,stderr):
        for name,data in (('stdout',stdout),('stderr',stderr)):
            if isinstance(data,bytes): data=data.decode(errors='replace')
            (output/(label+'.'+name)).write_text(data or '')
    try: process=subprocess.run(argv,capture_output=True,text=True,timeout=timeout)
    except subprocess.TimeoutExpired as error:
        save(error.stdout,error.stderr)
        raise
    save(process.stdout,process.stderr)
    return process

def cleanup_family_sandboxes():
    try:
        for path in base.glob('trellis-bench.*'):
            G['remove_tree'](str(path))
        assert not list(base.glob('trellis-bench.*')), 'family sandbox could not drain'
    except BaseException as error:
        preserve_family_failure(base,root/'out',error)
        raise

def route(sb, section, case_id):
    global ordinal
    ordinal += 1
    label = 'r2-family-' + str(ordinal)
    count = 2 if section == 'lifecycle' else 1
    argv = [launcher, 'bench', '--sections', section, '--n', str(count), '--warmup', '0',
            '--condition', 'functional-r2-no-timing-claim', '--label', label,
            '--out', str(root / 'out'), '--sandbox-base', str(base)]
    argv += ['--reuse', str(sb)] if sb else ['--keep']
    argv += (['--lifecycle-items', case_id] if section == 'lifecycle' else ['--hooks', '^' + re.escape(case_id) + '$'])
    # Setup has its own operation and untimed readiness budgets. The outer
    # test must not kill a valid first route at 600s before its 900s operation
    # deadline. Reused rows still get a bounded operation/readiness allowance.
    route_budget = G['COMMAND_TIMEOUT'] * (count + (2 if sb is None else 1))
    proc = recorded_process(argv,label,route_budget)
    receipts = list((root / 'out').glob('bench-*-' + label + '.json'))
    assert len(receipts) == 1, (case_id, proc.returncode, proc.stdout, proc.stderr)
    receipt = json.loads(receipts[0].read_text())
    assert receipt['source']['release_mode'] == 'installed', receipt['source']
    assert receipt['declared_condition'] == 'functional-r2-no-timing-claim'
    assert receipt['config']['runs'] == count and receipt['config']['warmup'] == 0
    assert len(receipt['results']) == 1, receipt['results']
    record = receipt['results'][0]
    assert record['id'] == case_id, (case_id, record, proc.stderr)
    for key in ('fixture_id', 'boundary_id', 'variant'):
        assert record[key] == expected[case_id][key], (case_id, key, record)
    assert record['status'] in ('ok', 'failed', 'diagnostic', 'not-measured'), record
    assert proc.returncode == (1 if record['status'] == 'failed' else 0), (record, proc.stderr)
    assert receipt['status'] == (('failed' if section == 'lifecycle' else 'aborted') if record['status'] == 'failed' else 'ok')
    observations = record['observations']
    assert len(observations) == count, ('family must complete every observation, not merely be listed/N/A', record, proc.stderr)
    for observation in observations:
        assert observation['case_id'] == case_id
        assert observation['fixture_id'] == record['fixture_id']
        assert observation['boundary_id'] == record['boundary_id']
        assert observation['warmup'] is False
        assert observation['exec_error'] is False and observation['timeout'] is False, record
        assert observation['readiness_kind'] in ('proven', 'no-denial')
        if section == 'pi' and record['status'] == 'diagnostic':
            # An executed unsupported transport is a diagnostic, not a ready
            # handler timing. Missing node/TS support has no observations and
            # is deliberately rejected above for these end-to-end cases.
            assert observation['unsupported'] is True and observation['readiness'] is False, record
            assert observation['exit'] == 0 and observation['transport_results'], record
            assert all(result['exit'] == 0 and result['exec_error'] is False
                       and result['verdict']['capability_status'] == 'unsupported'
                       and result['verdict']['decision'] == 'allow'
                       for result in observation['transport_results']), record
        elif record['status'] != 'failed':
            assert observation['readiness'] is True and observation['exit'] in record.get('expected_exit_codes', [0]), record
            assert observation['wall_ms'] >= 0
        if section != 'pi' and observation['wall_ms'] is not None:
            assert observation['readiness_ms'] is not None and observation['readiness_ms'] >= 0
    if record['status'] == 'failed':
        assert record['wall_ms'] is None and record.get('cpu_ms') is None
        assert any(observation['readiness'] is False for observation in observations)
        assert record.get('error') or record.get('note'), record
    elif record['status'] == 'ok':
        assert record['wall_ms']['n'] == count
    else:
        assert record['wall_ms'] is None, record
    sandboxes = list(base.glob('trellis-bench.*'))
    assert len(sandboxes) == 1, sandboxes
    seen.add(case_id)
    return sandboxes[0], record

def group(cases):
    sandbox = None
    try:
        for section, case_id, outcome in cases:
            sandbox, record = route(sandbox, section, case_id)
            status = record['status']
            if outcome == 'ok':
                assert status == 'ok', record
                if case_id == 'git-switch-fast':
                    assert len(record['checkout_proof']) == 2 and all(p['path'] == 'fast' for p in record['checkout_proof']), record
            elif outcome == 'attach':
                assert status == 'diagnostic' and record['sc1_eligible'] is False, record
                assert all(obs['readiness'] and obs['exit'] == 0 for obs in record['observations']), record
            elif outcome == 'unsupported':
                assert section == 'pi' and status == 'diagnostic', record
                assert 'unsupported baseline capability' in record['note'], record
            elif outcome == 'multi-root':
                assert status == 'diagnostic' and record['sc2_eligible'] is False, record
                assert 'SC2 single-command multi-root boundary' in record['note']
                assert 'ready-attachment' not in record['note']
                proofs = record['output_proof']
                assert len(proofs) == 2 and all(not p['missing_roots'] and len(set(p['reported_roots'])) == 2 for p in proofs), record
                assert all(obs['member_exits'] == [0, 0] for obs in record['observations']), record
            elif outcome == 'memo':
                assert status == 'ok', record
                assert len(record['checkout_proof']) == 2
                assert all(p['path'] in ('full-reconcile','verified-generator-rebuild') for p in record['checkout_proof']), record
                assert all(all(p['memo_repair'][key] for key in ('full_proof_ran','full_proof_succeeded','generator_verified','memo_rewritten'))
                           for p in record['checkout_proof']), record
            elif outcome == 'callback':
                assert record['sc1_eligible'] is False and record['timing_scope'] == 'callback-diagnostic-only'
                assert status == 'diagnostic', record
                assert len(record['completion_proof']) == 2 and all(proof['joined'] for proof in record['completion_proof'])
            elif outcome == 'prepush':
                assert status == 'diagnostic' and record['sc13_eligible'] is False, record
                assert record['timing_scope'] == 'instrumented-dispatcher-diagnostic-only'
                proof = record['execution_proof']
                assert proof['kind'] == 'private-dispatcher-xtrace'
                assert len(proof['installed_sources']) == 4 and len(proof['samples']) == 2
                sample = proof['samples'][0]
                assert [event['event'] for event in sample['events']] == [
                    'precheck-call', 'precheck-ran', 'precheck-ok', 'postcheck-call', 'postcheck-ran',
                    'postcheck-ok', 'carrier-call', 'classified', 'ref-seen', 'deletion-verdict'], proof
                assert sample['battery_calls'] == [] and sample['sources_unchanged'] and sample['deletion_stdout']
                assert not list(sandbox.rglob('.bench-pre-push-trace-*')), 'diagnostic dispatcher leaked'
            else:
                raise AssertionError(outcome)
            if record.get('fixture_id') == 'active-python':
                assert record['timing_claim_eligible'] is False and record['readiness_kind'] == 'proven'
                assert len(record['functional_proofs']) == 1 and all(p.startswith('lint:') for p in record['functional_proofs'])
            if ' R1 ' in case_id or ' R2 ' in case_id:
                assert record['registration_form'] == case_id.split()[1]
                assert record['render_selection'] == 'forced-renderer-fixture'
            if record.get('expected_decision') in ('deny', 'warn'):
                assert record['readiness_kind'] == 'proven', record
            if record.get('fixture_id') == 'pr-branch':
                assert record['readiness_kind'] == 'proven', record
            if section == 'pi-dispatch':
                assert record['boundary'] == 'dispatch-only'
                assert record['decision_evidence'] and all(
                    proof['observed_decision'] == record['expected_decision'] for proof in record['decision_evidence'])
            if status == 'failed':
                assert case_id == cases[-1][1], 'never reuse an aborted fixture'
    except BaseException as error:
        preserve_family_failure(base,root/'out',error)
        raise
    finally:
        cleanup_family_sandboxes()

# Every entry is an actual launcher route, not a call to a mocked family.
group([
    ('claude', 'claude R1 PreToolUse Edit reread-warn', 'ok'),
    ('claude', 'claude R2 PreToolUse Edit reread-warn', 'ok'),
    ('codex', 'codex PreToolUse Bash bash-pr-create', 'ok'),
    ('claude', 'claude R1 PreToolUse Skill over-budget', 'ok'),
    ('claude', 'claude R2 UserPromptExpansion over-budget', 'ok'),
    ('claude', 'claude R1 PostToolUse Edit edit-post-active', 'ok'),
    ('pi', 'pi user_bash', 'ok'),
    ('pi', 'pi session_compact', 'ok'),
    ('pi', 'pi session_shutdown', 'unsupported'),
    ('pi', 'pi tool_result edit failed', 'ok'),
    ('pi', 'pi tool_result edit native', 'ok'),
    ('pi', 'pi tool_result write failed', 'ok'),
    ('pi', 'pi tool_result write native', 'ok'),
    ('pi-dispatch', 'pi-dispatch tool_result edit edit-tracking-enabled', 'ok'),
    ('pi-dispatch', 'pi-dispatch tool_result edit edit-tracking-disabled', 'ok'),
    ('pi-dispatch', 'pi-dispatch tool_result write write-native-result', 'ok'),
    ('lifecycle', 'attach-current', 'attach'),
    ('lifecycle', 'git-switch-fast', 'ok'),
    ('lifecycle', 'pre-push-dispatcher', 'prepush'),
    ('lifecycle', 'attach-new-worktree', 'attach'),
    ('lifecycle', 'launcher-show-config-multi-root', 'multi-root'),
    ('lifecycle', 'git-switch-memo-miss', 'memo'),
    ('lifecycle', 'claude WorktreeCreate', 'callback'),
    ('lifecycle', 'claude WorktreeRemove', 'callback'),
])
assert len(seen) == 24, seen
# One actual lifecycle invocation, one sandbox, two measured observations and a
# warmup per item. No early failure may silently discard the later families.
items=['git-switch','git-switch-memo-miss','attach-new-worktree','pre-push-dispatcher','claude WorktreeCreate','claude WorktreeRemove']
try:
    command=[launcher,'bench','--sections','lifecycle','--lifecycle-items',','.join(items),
             '--n','2','--warmup','1','--keep','--condition','functional-r3-no-timing-claim',
             '--label','r3-multi','--out',str(root/'out'),'--sandbox-base',str(base)]
    process=recorded_process(command,'r3-multi',G['COMMAND_TIMEOUT'] * (2 + len(items)))
    receipt=json.loads(next((root/'out').glob('bench-*-r3-multi.json')).read_text())
    assert process.returncode==0 and receipt['status']=='ok', (receipt,process.stderr)
    assert [row['id'] for row in receipt['results']]==['git-switch (hooks off)']+items, receipt
    for row in receipt['results']:
        assert row['status']==('ok' if row['id'].startswith('git-switch') else 'diagnostic'), row
        if row['id']=='git-switch':
            assert len(row['checkout_proof'])==3 and all(p['path'] in ('fast','full-reconcile') for p in row['checkout_proof']), row
        assert len(row['observations'])==3 and [o['warmup'] for o in row['observations']]==[True,False,False]
        assert all(o['readiness'] and o['exit']==0 and not o['timeout'] and not o.get('callback_timeout') for o in row['observations']), row
        if row['status']!='ok':
            assert row['wall_ms'] is None and all(m['wall_ms'] is None for m in row['members']), row
            assert all('p50' not in line for line in process.stderr.splitlines() if line.startswith('trellis-latency: '+row['id']+':')), process.stderr
    assert len(list(base.glob('trellis-bench.*')))==1
except BaseException as error:
    preserve_family_failure(base,root/'out',error)
    raise
finally:
    cleanup_family_sandboxes()
print('R3: 24 strict families, two-observation lifecycle rows and a six-item same-sandbox pass')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  run env LC_ALL=C pgrep -f "$ROOT/.*trellis-bench\."
  [ "$status" -eq 1 ]
}

@test "R3 a failed lifecycle row does not abort later requested items" {
  run python3 -I - "$BENCH" "$ROOT" <<'PY'
import json,runpy,sys
from pathlib import Path
G=runpy.run_path(sys.argv[1])['main'].__globals__; root=Path(sys.argv[2]); called=[]
def build(*a):
    sb=G['Sandbox'](str(root/'fake-lifecycle')); Path(sb.root).mkdir(); sb.meta={}; return sb
def family(sb,args,results):
    item=args.lifecycle_items[0]; called.append(item)
    if item=='git-switch-memo-miss':
        error=G['BenchError']('postjob deadline'); error.record={'id':item,'status':'failed','observations':[], 'members':[], 'error':{'phase':'readiness','type':'CallbackTimeout','message':'postjob deadline'}}
        raise error
    results.append({'id':item,'status':'diagnostic','observations':[],'members':[]})
G['build_sandbox']=build; G['bench_lifecycle']=family; G['gate_or_bats_running']=lambda:False
assert G['main'](['--sections','lifecycle','--lifecycle-items','git-switch-memo-miss,launcher-help','--label','contained','--out',str(root/'out')])==1
receipt=json.loads(next((root/'out').glob('bench-*-contained.json')).read_text())
assert called==['git-switch-memo-miss','launcher-help']
assert receipt['status']=='failed' and len(receipt['results'])==2
assert not any(note.startswith('ABORTED') for note in receipt['notes'])
assert not (root/'fake-lifecycle').exists()
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "R3 errors preserve operation exit and diagnostic status owns every aggregate" {
  run python3 -I - "$BENCH" "$ROOT/tmp" <<'PY'
import contextlib, io, os, runpy, sys, time
from pathlib import Path
G=runpy.run_path(sys.argv[1])['measure'].__globals__; scratch=Path(sys.argv[2]); G['COMMAND_TIMEOUT']=2
member=G['Member']('operation',[sys.executable,'-I','-c','raise SystemExit(7)'])
def broken(*a): raise KeyError('teardown failed')
try: G['measure']('both-fail',[member],b'',str(scratch),dict(os.environ),1,0,scratch,after=broken); raise AssertionError('accepted')
except G['BenchError'] as e:
    rec=e.record; obs=rec['observations'][0]
    assert rec['error']['phase']=='readiness' and rec['error']['type']=='BenchError', rec
    assert obs['exit']==7 and obs['teardown_error']['type']=='KeyError', obs
    assert rec['teardown_error']==obs['teardown_error']
member=G['Member']('operation',[sys.executable,'-I','-c','pass'])
G['COMMAND_TIMEOUT']=.5
def slow(): time.sleep(3); return True
try: G['measure']('callback-timeout',[member],b'',str(scratch),dict(os.environ),1,0,scratch,readiness=slow); raise AssertionError('accepted')
except G['BenchError'] as e:
    obs=e.record['observations'][0]
    assert obs['exit']==0 and obs['member_exits']==[0], obs
    assert obs['callback_timeout'] and not obs['timeout'], obs
G['COMMAND_TIMEOUT']=2
stderr=io.StringIO()
with contextlib.redirect_stderr(stderr):
    rec=G['measure']('diag',[member],b'',str(scratch),dict(os.environ),2,0,scratch,extra={'diagnostic':True,'sc1_eligible':False})
assert rec['status']=='diagnostic' and rec['wall_ms'] is None and rec['cpu_ms'] is None
assert all(m['wall_ms'] is None for m in rec['members'])
assert 'p50' not in stderr.getvalue(), stderr.getvalue()
print('round3 primary/teardown error, callback exit and diagnostic assertions passed')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "R3 memo readiness joins a pending audit and fast labels reject reconciliation" {
  run python3 -I - "$BENCH" "$ROOT/tmp" <<'PY'
import json,runpy,subprocess,sys
from pathlib import Path
from types import SimpleNamespace
G=runpy.run_path(sys.argv[1])['measure'].__globals__; root=Path(sys.argv[2]); sb=G['Sandbox'](str(root/'join-proof'))
memo=Path(sb.trellis_home,'state/hook-digests/proof.json'); memo.parent.mkdir(parents=True); payload=str(Path(sb.project,'.trellis/runtime'))
memo.write_text(json.dumps({'payload':payload})); pending=False; joins=[]
sb.git=lambda *a,**k: subprocess.CompletedProcess([],0,b'main\n',b'')
def ready(sb,root,join=False):
    global pending
    joins.append(join)
    if pending and not join: raise G['BenchError']('audit still pending')
    if join: pending=False
    return True
G['attachment_ready']=ready; G['checkout_snapshot']=lambda sb: {}
G['checkout_hook_proof']=lambda *a: {'hook_ran':True}
G['checkout_memo_reproof']=lambda *a: {'full_proof_ran':True,'full_proof_succeeded':True,'generator_verified':True,'memo_rewritten':True}
G['checkout_path_proof']=lambda sb,before,expected,repair=None: {'path':expected}
def measured(case_id,members,stdin,cwd,env,runs,warmup,scratch,before=None,after=None,readiness=None,extra=None,**kwargs):
    global pending
    before(0); assert not memo.exists()
    pending=True; memo.write_text(json.dumps({'payload':payload}))
    assert readiness() is True and pending is False
    after(0)
    return dict(extra,id=case_id,status='ok',members=[],observations=[])
G['measure']=measured
G['bench_lifecycle_expansion'](sb,SimpleNamespace(lifecycle_items=['git-switch-memo-miss'],lifecycle_runs=1,runs=1,warmup=0,condition='normal'),[])
assert joins==[True,True], joins
# Check the actual path classifier, not the stub used by the routing probe.
F=runpy.run_path(sys.argv[1])['checkout_path_proof'].__globals__
before={'memo_valid':True,'memos':['valid'],'owner_sha256':'owner','postjob_sha256':'before','dispatcher_sha256':'hook','hook_execution':{'hook_ran':True}}
after=dict(before,postjob_sha256='after')
F['checkout_snapshot']=lambda sb: after
assert F['checkout_path_proof'](sb,before)['path']=='full-reconcile'
try: F['checkout_path_proof'](sb,before,'fast'); raise AssertionError('reconcile mislabeled fast')
except F['BenchError']: pass
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "R4 integrity failures quarantine the sandbox and interrupts stop later rows" {
  run python3 -I - "$BENCH" "$ROOT" <<'PY'
import json,runpy,sys
from pathlib import Path
G=runpy.run_path(sys.argv[1])['main'].__globals__; root=Path(sys.argv[2]); called=[]; current={}
G['gate_or_bats_running']=lambda:False
for kind in ('TeardownError','CallbackTimeout','secondary','KeyboardInterrupt'):
    called.clear(); location=root/kind
    def build(*args):
        sb=G['Sandbox'](str(location)); location.mkdir(); sb.meta={}; return sb
    def family(sb,args,rows):
        item=args.lifecycle_items[0]; called.append(item)
        error=KeyboardInterrupt() if kind=='KeyboardInterrupt' else G['BenchError']('wrong exit') if kind=='secondary' else G[kind]('postjob unsafe')
        if kind!='KeyboardInterrupt':
            error.record={'id':item,'status':'failed','members':[],'observations':[], 'error':{'phase':'readiness','type':type(error).__name__,'message':str(error)}}
            if kind=='secondary': error.record['teardown_error']={'phase':'after','type':'KeyError','message':'cleanup failed'}
        raise error
    G['build_sandbox']=build; G['bench_lifecycle']=family
    def forbidden(*args): raise AssertionError('measured a later section in quarantined sandbox')
    G['bench_pi']=forbidden
    result=G['main'](['--sections','lifecycle,pi','--hooks','^pi user_bash$','--lifecycle-items','git-switch-memo-miss,launcher-show-config,launcher-help,git-switch','--label',kind,'--out',str(root/'out')])
    assert result==1 and called==['git-switch-memo-miss'], (kind,called)
    receipt=json.loads(next((root/'out').glob('bench-*-'+kind+'.json')).read_text())
    if kind=='KeyboardInterrupt':
        assert receipt['status']=='aborted', receipt
    else:
        assert receipt['status']=='failed' and receipt['sandbox']['kept'], receipt
        assert [r['id'] for r in receipt['results'][1:]]==['launcher-show-config','launcher-help','git-switch (hooks off)','git-switch','pi user_bash']
        for row in receipt['results'][1:]:
            assert row['status']=='not-measured' and row['blocked'] and not row['observations'], row
            assert row['error']['phase']=='skipped-after-sandbox-integrity-failure', row
        assert not receipt['summary']['lifecycle_p50']
        assert location.exists(), 'unsafe sandbox was deleted'
    if location.exists(): G['remove_tree'](str(location))
# An unavailable cleanup drain must retain the sandbox and revise the receipt,
# not emit successful stats and silently delete while detached work may exist.
location=root/'drain-unknown'
def healthy(sb,args,rows): rows.append({'id':'launcher-help','section':'lifecycle','status':'ok','members':[],'observations':[{'wall_ms':1}], 'wall_ms':G['stats']([1]),'cpu_ms':None,'load_start':[0,0,0],'load_end':[0,0,0]})
G['bench_lifecycle']=healthy; real_remove=G['remove_tree']; G['remove_tree']=lambda root:False
try: assert G['main'](['--sections','lifecycle','--lifecycle-items','launcher-help','--label','drain','--out',str(root/'out')])==1
finally: G['remove_tree']=real_remove
receipt=json.loads(next((root/'out').glob('bench-*-drain.json')).read_text())
assert receipt['sandbox']['kept'] and receipt['sandbox']['quarantined']=='cleanup process drain incomplete'
assert receipt['status']=='failed' and receipt['results'][0]['status']=='failed'
assert receipt['results'][0]['observations'][0]['aggregation_eligible'] is False
assert location.exists(); real_remove(str(location))
# Interrupts must escape measure too, rather than being converted into a row failure.
scratch=root/'interrupt-scratch'; scratch.mkdir()
def interrupt(): raise KeyboardInterrupt()
try: G['measure']('interrupt',[G['Member']('true',['true'])],b'',str(root),dict(__import__('os').environ),1,0,scratch,readiness=interrupt); raise AssertionError('interrupt swallowed')
except KeyboardInterrupt: pass
print('round4 quarantine and interrupt assertions passed')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "R4 checkout requires actual hook execution and non-ok raw walls never aggregate" {
  run python3 -I - "$BENCH" "$ROOT/tmp" <<'PY'
import os,runpy,sys
from pathlib import Path
from types import SimpleNamespace
G=runpy.run_path(sys.argv[1])['main'].__globals__; root=Path(sys.argv[2]); sb=G['Sandbox'](str(root/'hook-proof'))
for directory in (sb.home,sb.trellis_home,sb.tmp,sb.scratch,sb.project): Path(directory).mkdir(parents=True,exist_ok=True)
hooks=Path(sb.root,'hooks'); hooks.mkdir(); hook=hooks/'post-checkout'; hook.write_text('#!/bin/sh\nexit 0\n'); hook.chmod(0o700)
for args in (['init','-q','-b','main'],['config','user.name','fixture'],['config','user.email','fixture@example.invalid'],['commit','-qm','init','--allow-empty'],['branch','bench-a'],['config','core.hooksPath',str(hooks)]): sb.git(args,sb.project,hooks=False)
G['attachment_ready']=lambda *a,**k:True
member=G['Member']('switch',['git','switch','-q','bench-a'])
proof=G['checkout_hook_proof'](sb,member,sb.env())
assert proof['hook_ran'] and proof['hook_exit']==0 and proof['hook_path']==str(hook), proof
try: G['checkout_hook_proof'](sb,G['Member']('no-hook',['git','-c','core.hooksPath=/dev/null','switch','-q','bench-a']),sb.env()); raise AssertionError('no-hook proof accepted')
except G['BenchError']: pass
# Drive the real fast-row constructor, so changing its member to /dev/null is killed.
G['attachment_ready']=lambda *a,**k:True; G['checkout_snapshot']=lambda sb:{}
def measured(case_id,members,stdin,cwd,env,runs,warmup,scratch,before=None,**kwargs):
    before(0)
    assert tuple(members[0].command())==members[0].verified_argv
    return dict(kwargs['extra'],id=case_id,status='ok',members=[],observations=[])
G['measure']=measured
G['bench_lifecycle_expansion'](sb,SimpleNamespace(lifecycle_items=['git-switch-fast'],lifecycle_runs=1,runs=1,warmup=0,condition='normal'),[])
G['measure']=lambda case_id,*a,**k:dict(k['extra'],id=case_id,status='ok',members=[],observations=[])
rows=[]
G['bench_lifecycle_expansion'](sb,SimpleNamespace(lifecycle_items=['launcher-show-config-multi-root'],lifecycle_runs=1,runs=1,warmup=0,condition='normal'),rows)
assert rows[0]['sc2_eligible'] is False and 'SC2 single-command multi-root boundary' in rows[0]['note']
assert 'ready-attachment' not in rows[0]['note']
for status in ('failed','diagnostic','not-measured'):
    row={'id':'launcher-show-config','status':status,'section':'lifecycle','members':[{'wall_ms':{'n':1,'p50':999}}], 'observations':[{'wall_ms':999}], 'wall_ms':{'n':1,'p50':999}, 'cpu_ms':None}
    G['finalize_record'](row)
    assert row['observations'][0]['aggregation_eligible'] is False
    assert row['observations'][0]['wall_ms']==999  # Evidence only, not an aggregation input.
    row['wall_ms']=G['stats']([row['observations'][0]['wall_ms']])  # Even a consumer reaggregation cannot become eligible.
    assert not G['summarize']([row])['lifecycle_p50'] and G['p50'](row) is None
print('round4 positive hook and raw-wall exclusion assertions passed')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "R5 warmups are ineligible and hook-proof deadline cleanup does not restart a join" {
  run python3 -I - "$BENCH" "$ROOT/tmp" <<'PY'
import os,runpy,subprocess,sys
from pathlib import Path
from types import SimpleNamespace
G=runpy.run_path(sys.argv[1])['measure'].__globals__; root=Path(sys.argv[2]); scratch=root/'warmups'; scratch.mkdir()
record=G['measure']('warmups',[G['Member']('python',[sys.executable,'-I','-c','pass'])],b'',str(root),dict(os.environ),1,1,scratch)
assert [o['aggregation_eligible'] for o in record['observations']]==[False,True], record
assert record['wall_ms']['n']==1
hooks=root/'hooks'; hooks.mkdir(); (hooks/'post-checkout').write_text('hook bytes')
calls=[]
def git(args,*a,**k):
    calls.append(args)
    if args[0]=='switch': raise AssertionError('cleanup restarted after callback timeout')
    return subprocess.CompletedProcess(args,0,(str(hooks) if args[0]=='config' else 'main').encode(),b'')
sb=SimpleNamespace(project=str(root),scratch=scratch,git=git)
original=G['subprocess'].run
def timeout(*a,**k): raise G['CallbackTimeout']('observation deadline')
G['subprocess'].run=timeout
G['attachment_ready']=lambda *a,**k: (_ for _ in ()).throw(AssertionError('post-timeout join started'))
try:
    try: G['checkout_hook_proof'](sb,G['Member']('switch',['git','switch','other']),{}); raise AssertionError('timeout accepted')
    except G['CallbackTimeout']: pass
finally: G['subprocess'].run=original
assert all(args[0]!='switch' for args in calls), calls
print('R5 warmup eligibility and deadline cleanup assertions passed')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "R5 family failure hook retains forensic sandbox and logs beyond fence cleanup" {
  write_family_evidence_helper
  run python3 -I - "$BENCH" "$ROOT" "$BATS_TEST_FILENAME" <<'PY'
import ast,json,os,runpy,sys
from pathlib import Path
G=runpy.run_path(sys.argv[1])['main'].__globals__; root=Path(sys.argv[2]); fence=root/'transient-fence'; base=fence/'sandboxes'; output=fence/'out'; sandbox=base/'trellis-bench.probe'
for relative in ('trellis-home/state/attachment-status','trellis-home/state/attachments','trellis-home/state/hook-digests','bench-scratch'):
    path=sandbox/relative; path.mkdir(parents=True,exist_ok=True); (path/'proof.json').write_text(relative)
output.mkdir(); (output/'case.stderr').write_text('full reconcile instead of fast')
os.environ['TRELLIS_TEST_GIT_FENCE_ROOT']=str(fence)
preserve=runpy.run_path(str(root/'family-evidence.py'))['preserve_family_failure']
# Exercise the actual test-18 failure handler, not a duplicate test wrapper.
source=Path(sys.argv[3]).read_text(); section=source.split('@test "R2 M7 new families',1)[1]; python=section.split("<<'PY'\n",1)[1].split('\nPY\n',1)[0]
tree=ast.parse(python); functions=[node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name in ('group','cleanup_family_sandboxes')]
namespace={'base':base,'root':fence,'G':G,'preserve_family_failure':preserve}
def route(*a): raise AssertionError('deliberate family failure')
namespace['route']=route
exec(compile(ast.Module(body=functions,type_ignores=[]),'<test18-failure-handler>','exec'),namespace)
try: namespace['group']([('lifecycle','git-switch-fast','ok')]); raise AssertionError('failure swallowed')
except AssertionError as error: assert str(error)=='deliberate family failure',error
G['remove_tree'](str(fence))
retained=list((root/'trellis-bench-test-evidence').glob('test18-failure-*'))
assert len(retained)==1,retained
assert (retained[0]/'logs/case.stderr').read_text()=='full reconcile instead of fast'
assert (retained[0]/'sandboxes/trellis-bench.probe/bench-scratch/proof.json').exists()
manifest=json.loads((retained[0]/'failure.json').read_text()); assert manifest['error_type']=='AssertionError' and not manifest['copy_errors'],manifest
print('R5 failure evidence survives original sandbox and fence cleanup')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "R5 installed native-bearing fixture seals the real packaged payload inside the Git fence" {
  install_caller_release
  local src version release payload parent
  src="$ROOT/release source"
  version="$(< "$src/core-rules/VERSION")"
  release="$TRELLIS_HOME/releases/$version"
  payload="$(release_fixture_git "$HOME" -C "$src" rev-parse "v$version^{commit}")"
  parent="$(release_fixture_git "$HOME" -C "$src" rev-parse HEAD)"
  [ "$payload" != "$parent" ]
  [ "$(release_fixture_git "$HOME" -C "$src" rev-parse "$payload^")" = "$parent" ]
  [ -d "$src/native" ]
  [ -f "$release/payload/core-rules/native/artifacts.json" ]
  [ -f "$release/payload/scripts/trellis" ]
  [ ! -e "$release/payload/native" ]
  [ ! -e "$release/payload/specs" ]
  [ ! -e "$release/payload/scripts/tests" ]
  jq -e --arg commit "$payload" '.commit == $commit' "$release/release.json"
}

@test "R5 Pi transport consumes the nonce-bound decision before the completion marker" {
  command -v node >/dev/null || skip "node is not on PATH"
  local extension="$ROOT/pi/.trellis/runtime/core-rules/pi/extensions/trellis.ts" mode
  mkdir -p "$(dirname "$extension")" "$ROOT/pi/.trellis/runtime/core-rules/pi/hooks"
  cat > "$ROOT/pi/.trellis/runtime/core-rules/pi/hooks/dispatch.sh" <<'SH'
#!/bin/sh
printf '%s\n' '{"schema_version":1,"capability_status":"advisory","decision":"allow"}'
SH
  chmod 755 "$ROOT/pi/.trellis/runtime/core-rules/pi/hooks/dispatch.sh"
  cat > "$extension" <<'JS'
export default pi => {
  pi.on('session_compact', async (_event, ctx) => {
    if (process.env.TRELLIS_BENCH_PROTOCOL_MODE === 'legacy') {
      await pi.exec(ctx.cwd + '/.trellis/runtime/core-rules/pi/hooks/dispatch.sh', [], {cwd:ctx.cwd});
      return;
    }
    const nonce = 'a'.repeat(64);
    const emit = `
      const mode = process.env.TRELLIS_BENCH_PROTOCOL_MODE;
      const decision = {schema_version:1, capability_status:'advisory', decision:'allow'};
      const marker = {schema_version:1, type:'trellis_dispatch_complete', nonce:'a'.repeat(64), complete:true};
      if (mode === 'wrong-nonce') marker.nonce = 'b'.repeat(64);
      if (mode === 'extra-key') marker.extra = true;
      if (mode === 'wrong-version') marker.schema_version = 2;
      if (mode === 'bad-decision') delete decision.capability_status;
      let records = mode === 'marker-only' ? [marker] : [decision, marker];
      if (mode === 'missing-marker' || mode === 'legacy') records = [decision];
      if (mode === 'extra-record') records.push(marker);
      process.stdout.write(records.map(record => JSON.stringify(record)).join('\\n') + (mode === 'missing-newline' ? '' : '\\n'));
    `;
    const argv = [process.execPath, '-e', emit];
    if (process.env.TRELLIS_BENCH_PROTOCOL_MODE !== 'legacy') argv.unshift(`TRELLIS_PI_DISPATCH_NONCE=${nonce}`);
    await pi.exec('/usr/bin/env', argv, {cwd:ctx.cwd});
  });
};
JS
  for mode in valid legacy wrong-nonce extra-key wrong-version bad-decision marker-only missing-marker extra-record missing-newline; do
    run env TRELLIS_BENCH_PROTOCOL_MODE="$mode" node --no-warnings "$SOURCE_ROOT/scripts/bench/pi-handler-runner.mjs" \
      --project "$ROOT/pi" --runs 1 --warmup 0 --event session_compact --timeout-ms 5000
    case "$mode" in valid|legacy) [ "$status" -eq 0 ] ;; *) [ "$status" -eq 1 ] ;; esac || {
      printf '%s: %s\n' "$mode" "$output" >&2; return 1;
    }
    printf '%s\n' "$output" > "$ROOT/transport-$mode.json"
    jq -e '(.observations | length == 1) and (.observations[0].transport_results | length == 1)
      and (.observations[0].transport_results[0] | keys == ["exec_error","exit","signal","verdict"])
      and .observations[0].member_exits == [0]
      and (.observations[0].exec_error | not) and (.observations[0].timeout | not)' "$ROOT/transport-$mode.json"
    case "$mode" in
      valid|legacy)
        jq -e '(.failed | not) and .observations[0].exit == 0 and .observations[0].readiness
          and .observations[0].readiness_kind == "proven" and (.observations[0].transport_failed | not)
          and .observations[0].transport_results[0].verdict.decision == "allow"' "$ROOT/transport-$mode.json" ;;
      *)
        jq -e '.failed and .observations[0].exit == 1 and (.observations[0].readiness | not)
          and .observations[0].transport_failed' "$ROOT/transport-$mode.json" ;;
    esac
  done
}

@test "R6 Pi text members retain observed output while policy members still fail closed" {
  command -v node >/dev/null || skip "node is not on PATH"
  local project="$ROOT/pi" extension="$ROOT/pi/.trellis/runtime/core-rules/pi/extensions/trellis.ts" mode
  mkdir -p "$(dirname "$extension")" "$project/.trellis/runtime/core-rules/pi/hooks"
  cat > "$project/.trellis/runtime/core-rules/pi/hooks/dispatch.sh" <<'SH'
#!/bin/sh
if [ "$TRELLIS_BENCH_MEMBER_MODE" = policy-valid ]; then
  printf '%s\n' '{"schema_version":1,"capability_status":"advisory","decision":"allow"}'
else
  printf '%s\n' 'not a policy record'
fi
SH
  chmod 755 "$project/.trellis/runtime/core-rules/pi/hooks/dispatch.sh"
  cat > "$extension" <<'JS'
export default pi => {
  pi.on('session_compact', async (_event, ctx) => {
    const mode = process.env.TRELLIS_BENCH_MEMBER_MODE;
    if (mode.startsWith('policy-')) {
      await pi.exec(ctx.cwd + '/.trellis/runtime/core-rules/pi/hooks/dispatch.sh', [], {cwd:ctx.cwd});
    } else if (mode === 'text-spawn-failure') {
      await pi.exec(ctx.cwd + '/missing-executable', [], {cwd:ctx.cwd});
    } else {
      const emit = `
        const mode = process.env.TRELLIS_BENCH_MEMBER_MODE;
        process.stdout.write(mode === 'text-json' ? '{"schema_version":1,"capability_status":"advisory","decision":"allow"}\\n' : 'ordinary Git output\\n');
        process.stderr.write('observed stderr\\n');
        if (mode === 'text-signal') process.kill(process.pid, 'SIGTERM');
        process.exitCode = mode === 'text-nonzero' ? 7 : 0;
      `;
      // No dispatch contract: even JSON-looking stdout is ordinary output.
      await pi.exec(process.execPath, ['-e', emit], {cwd:ctx.cwd});
    }
  });
};
JS
  for mode in text-ok text-nonzero text-json text-spawn-failure text-signal policy-invalid policy-valid; do
    run env TRELLIS_BENCH_MEMBER_MODE="$mode" node --no-warnings "$SOURCE_ROOT/scripts/bench/pi-handler-runner.mjs" \
      --project "$project" --runs 1 --warmup 0 --event session_compact --timeout-ms 5000
    case "$mode" in text-ok|text-nonzero|text-json|policy-valid) [ "$status" -eq 0 ] ;; *) [ "$status" -eq 1 ] ;; esac || {
      printf '%s: %s\n' "$mode" "$output" >&2; return 1;
    }
    printf '%s\n' "$output" > "$ROOT/member-$mode.json"
    jq -e '(.observations | length == 1) and (.observations[0].transport_results | length == 1)' "$ROOT/member-$mode.json"
    case "$mode" in
      text-ok|text-nonzero|text-json)
        jq -e --arg mode "$mode" '(.failed | not) and .observations[0].exit == 0
          and .observations[0].readiness and .observations[0].readiness_kind == "no-denial"
          and (.observations[0].transport_failed | not)
          and .observations[0].member_exits == [if $mode == "text-nonzero" then 7 else 0 end]
          and (.observations[0].transport_results[0] | .verdict == null
            and (.stdout | contains(if $mode == "text-json" then "schema_version" else "ordinary Git output" end))
            and .stderr == "observed stderr\n")' "$ROOT/member-$mode.json" ;;
      policy-valid)
        jq -e '(.failed | not) and .observations[0].readiness and .observations[0].readiness_kind == "proven"
          and (.observations[0].transport_failed | not)
          and .observations[0].transport_results[0].verdict.decision == "allow"' "$ROOT/member-$mode.json" ;;
      *)
        jq -e '.failed and (.observations[0].readiness | not) and .observations[0].transport_failed' "$ROOT/member-$mode.json" ;;
    esac
  done
}

@test "R6 missing-only memo repair admits reconcile or verified rebuild with full reproof" {
  run python3 -I - "$BENCH" <<'PY'
import copy,runpy,sys
G=runpy.run_path(sys.argv[1])['main'].__globals__
before={'memos':[], 'memo_valid':False, 'owner_sha256':'owner', 'postjob_sha256':'old-audit',
        'dispatcher_sha256':'hook', 'hook_execution':{'hook_ran':True}}
after=dict(before,memos=[{'path':'memo','sha256':'new-memo','valid':True}],memo_valid=True)
evidence={'full_proof_ran':True,'full_proof_succeeded':True,'generator_verified':True,'memo_rewritten':True}
G['checkout_snapshot']=lambda _sb: after
for path,audit in [('full-reconcile','new-audit'),('verified-generator-rebuild','old-audit')]:
    after['postjob_sha256']=audit
    result=G['checkout_path_proof'](None,before,'memo-repair',evidence)
    assert result['path']==path and result['memo_repair']==evidence, result
    for missing in evidence:
        incomplete=dict(evidence,**{missing:False})
        try: G['checkout_path_proof'](None,before,'memo-repair',incomplete)
        except G['BenchError']: pass
        else: raise AssertionError(('accepted missing repair evidence',path,missing))
# Existing malformed/drifted memo cannot become a missing-only rebuild.
for valid in (False,True):
    present=copy.deepcopy(before); present['memos']=[{'path':'memo','sha256':'old-memo','valid':valid}]; present['memo_valid']=valid
    after['postjob_sha256']='old-audit'
    try: G['checkout_path_proof'](None,present,'memo-repair',evidence)
    except G['BenchError']: pass
    else: raise AssertionError('present malformed/drifted memo relabelled as rebuild')
    after['postjob_sha256']='new-audit'
    assert G['checkout_path_proof'](None,present,'full-reconcile')['path']=='full-reconcile'
# No memo rewrite is not repair, and no hook execution is never proof.
after['memos']=[]; after['memo_valid']=False
try: G['checkout_path_proof'](None,before,'memo-repair',evidence)
except G['BenchError']: pass
else: raise AssertionError('accepted absent memo after repair')
after['memos']=[{'path':'memo','sha256':'new-memo','valid':True}]; after['memo_valid']=True
no_hook=dict(before,hook_execution={'hook_ran':False})
try: G['checkout_path_proof'](None,no_hook,'memo-repair',evidence)
except G['BenchError']: pass
else: raise AssertionError('accepted repair without hook execution')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "R6 memo readiness actually runs the canonical full proof and verified generator" {
  run python3 -I - "$BENCH" "$ROOT" <<'PY'
import hashlib,json,os,runpy,shlex,sys
from pathlib import Path
from types import SimpleNamespace
G=runpy.run_path(sys.argv[1])['main'].__globals__; root=Path(sys.argv[2]); sb=G['Sandbox'](str(root/'probe'))
managed=Path(sb.trellis_home,'state/git-hooks/c'); managed.mkdir(parents=True)
sb.scratch.mkdir(parents=True); Path(sb.project,'.trellis').mkdir(parents=True)
payload=Path(sb.root,'payload'); (payload/'scripts/lib').mkdir(parents=True)
Path(sb.project,'.trellis/runtime').symlink_to(payload,target_is_directory=True)
hook=managed/'post-checkout'
hook.write_text('''#!/bin/bash
# trellis-managed-dispatcher-body
managed_dispatcher="${TRELLIS_MANAGED_DISPATCHER:?}"
trellis_enter_command_scratch() { :; }
trellis_worktree_current() { [ "$BENCH_FULL_PROOF" = yes ]; }
# Git passes 0 as the third argument for a file checkout
exit 0
'''); hook.chmod(0o700)
memo=Path(sb.trellis_home,'state/hook-digests/memo.json'); memo.parent.mkdir(parents=True)
record={'schema_version':2,'manifest_sha256':'a'*64,'payload':str(payload),'pre_push_source':'core-rules/githooks/pre-push'}
memo.write_text(json.dumps(record)); memo.chmod(0o600)
golden=payload/'golden.json'; golden.write_text(json.dumps(record))
library=payload/'scripts/lib/attachment.sh'
# Use the real private-directory guard: unlike mkdir -p, it requires its
# state parent to exist. The old permissive fake masked a Linux formal failure.
source_library=Path(sys.argv[1]).resolve().parents[1]/'lib/attachment.sh'
library.write_text('. '+shlex.quote(str(source_library))+'\n_attachment_hooks_digest_memo_write() { '
                   '_attachment_ensure_private_dir "$1/state/hook-digests" || return 1; cp '
                   +shlex.quote(str(golden))+' "$1/state/hook-digests/memo.json"; }\n')
G['registry_worktree']=lambda *_: ('c','w','a')
sb.git=lambda *_args,**_kwargs: SimpleNamespace(stdout=b'a'*40+b'\n')
sb.env=lambda **extra: dict(os.environ,BENCH_FULL_PROOF='yes',**extra)
before={'memos':[], 'memo_valid':False}
after={'memos':[{'path':str(memo),'sha256':hashlib.sha256(memo.read_bytes()).hexdigest(),'valid':True}],'memo_valid':True}
proof=G['checkout_memo_reproof'](sb,before,after)
assert all(proof[key] for key in ('full_proof_ran','full_proof_succeeded','generator_verified','memo_rewritten')), proof
state=Path(proof['evidence_directory'],'expected-home/state')
assert state.is_dir() and not state.is_symlink() and state.stat().st_mode & 0o777 == 0o700
assert hook.read_text().endswith('exit 0\n') and len(list(managed.iterdir()))==1
# Generator output alone is not a full reproof: the predicate must succeed.
sb.env=lambda **extra: dict(os.environ,BENCH_FULL_PROOF='no',**extra)
try: G['checkout_memo_reproof'](sb,before,after)
except G['BenchError'] as error: assert 'full' in str(error).lower(), str(error)
else: raise AssertionError('generator rebuild without a successful full reproof passed')
# A successful predicate does not authorize arbitrary memo contents.
sb.env=lambda **extra: dict(os.environ,BENCH_FULL_PROOF='yes',**extra)
golden.write_text(json.dumps(dict(record,manifest_sha256='b'*64)))
try: G['checkout_memo_reproof'](sb,before,after)
except G['BenchError'] as error: assert 'generator' in str(error).lower(), str(error)
else: raise AssertionError('memo differed from the verified generator')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "T48/T49 callback verification accepts only synchronous results, never a detached job" {
  run python3 -I - "$BENCH" "$ROOT" <<'PY'
import runpy,sys
from pathlib import Path
G=runpy.run_path(sys.argv[1])['main'].__globals__
sb=G['Sandbox'](str(Path(sys.argv[2])/'callback-sync'))
state=Path(sb.trellis_home,'state/worktree-hooks'); state.mkdir(parents=True)
sb.scratch.mkdir(parents=True)
worktree=str(Path(sb.root,'callback-worktrees/bench-fixture/cc-bench-callback'))
key='bench-fixture_cc-bench-callback'
def refused(event,needle):
    try: G['join_callback_job'](sb,event,worktree)
    except G['TeardownError'] as error: assert needle in str(error), str(error)
    else: raise AssertionError('accepted: '+event+' '+needle)
proof=G['join_callback_job'](sb,'WorktreeCreate',worktree)
assert proof=={'joined':True,'method':'synchronous callback, verified result','sc1_eligible':False}, proof
(state/(key+'.sync.pid')).write_text('12345\n')
refused('WorktreeCreate','detached sync')
(sb.scratch/'m0.err').write_text('')
(state/(key+'.remove.log')).write_text('t kept '+worktree+': reason\n')
refused('WorktreeRemove','without a removal verdict')
(state/(key+'.remove.log')).write_text('t removed '+worktree+'\n')
assert G['join_callback_job'](sb,'WorktreeRemove',worktree)['joined']
(sb.scratch/'m0.err').write_text('detach and git worktree remove continue in the background (pid 1)\n')
refused('WorktreeRemove','background job')
print('synchronous create/remove verdicts accepted; detached jobs refused')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "T54 source-checkout fixture installs the real native-bearing packaged payload" {
  run python3 -I - "$BENCH" "$SOURCE_ROOT" "$ROOT" <<'PY'
import json,runpy,sys
from pathlib import Path
G=runpy.run_path(sys.argv[1])['main'].__globals__
sb=G['Sandbox'](str(Path(sys.argv[3])/'source-fixture'))
for directory in (Path(sb.home),Path(sb.trellis_home),Path(sb.tmp),Path(sb.launcher).parent,sb.scratch):
    directory.mkdir(parents=True,exist_ok=True)
for directory in (Path(sb.home),Path(sb.trellis_home),Path(sb.tmp)): directory.chmod(0o700)
metadata=G['install_from_checkout'](sb,sys.argv[2],'HEAD',{})
source=Path(metadata['source_root']); release=Path(sb.trellis_home,'releases',metadata['version'])
assert (source/'native').is_dir(), 'source tree fixture must actually contain native build sources'
assert (release/'payload/core-rules/native/artifacts.json').is_file()
assert (release/'payload/scripts/bench/trellis-latency.py').is_file()
assert not any((release/'payload'/path).exists() for path in ('native','specs','scripts/tests'))
tag=sb.git(['rev-parse','v'+metadata['version']+'^{commit}'],str(source),hooks=False).stdout.decode().strip()
head=sb.git(['rev-parse','HEAD'],str(source),hooks=False).stdout.decode().strip()
assert tag!=head and json.loads((release/'release.json').read_text())['commit']==tag
assert sb.git(['rev-parse',tag+'^'],str(source),hooks=False).stdout.decode().strip()==head
# Archived, tracked-but-ignored paths must survive resealing, including the
# four core-rules instruction files. No fixture edits are intended here.
original_tree=sb.git(['rev-parse',metadata['commit']+'^{tree}'],sys.argv[2],hooks=False).stdout.strip()
fixture_tree=sb.git(['rev-parse','HEAD^{tree}'],str(source),hooks=False).stdout.strip()
# The only permitted edit: a pre-cut checkout gets its native manifest's
# version stamped into core-rules/VERSION (T34B), exactly as the cut does.
def listing(repo, tree):
    rows=sb.git(['ls-tree','-rz',tree],repo,hooks=False).stdout.split(b'\0')
    return {row.split(b'\t',1)[1].decode(): row.split(b'\t',1)[0] for row in rows if row}
before, after = listing(sys.argv[2], original_tree.decode()), listing(str(source), fixture_tree.decode())
changed=sorted(k for k in set(before)|set(after) if before.get(k)!=after.get(k))
assert changed==(['core-rules/VERSION'] if metadata['version_stamped_from'] else []), 'resealed source tree differs from pinned source tree (tracked ignored files lost): '+repr(changed)
assert (release/'payload/core-rules/AGENTS.md').is_file(), 'installed payload lost tracked-but-ignored instructions'
expected=[]
for row in sb.git(['ls-tree','-rz',tag],str(source),hooks=False).stdout.split(b'\0'):
    if not row: continue
    meta,path=row.split(b'\t',1); mode,kind,oid=meta.decode().split()
    assert kind=='blob'
    expected.append({'path':path.decode(),'mode':mode,'oid':oid})
assert json.loads((release/'release.json').read_text())['tree']==expected, 'installed fixture is not the exact filtered source tree'
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "T34B source-checkout sandbox publishes the native companion pair so the fixture attach renders natively" {
  case "$(uname -s)/$(uname -m)" in
    Darwin/arm64|Linux/x86_64) ;;
    *) skip 'no shipped native asset for this host' ;;
  esac
  run python3 -I - "$BENCH" "$SOURCE_ROOT" "$ROOT" <<'PY'
import json,os,platform,runpy,stat,sys
from pathlib import Path
G=runpy.run_path(sys.argv[1])['main'].__globals__
base=Path(sys.argv[3])/'native-sandbox'; base.mkdir()
sb=G['build_sandbox'](str(base),sys.argv[2],'HEAD')
payload=Path(sb.trellis_home,'releases',sb.meta['version'],'payload')
manifest=json.loads((payload/'core-rules/native/artifacts.json').read_text())
target={('Darwin','arm64'):'aarch64-apple-darwin',('Linux','x86_64'):'x86_64-unknown-linux-musl'}[(platform.system(),platform.machine())]
companion=Path(sb.trellis_home,'bin/native',manifest['version'],target,manifest['assets'][target]['sha256'],'trellis-hooks')
info=os.lstat(companion)
assert stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode)==0o500, oct(info.st_mode)
assert sb.meta['launcher_install']=='paired' and sb.meta['version']==manifest['version'], sb.meta
launcher=Path(sb.launcher).read_text()
assert "launcher_native_entry='"+str(companion)+"'" in launcher, 'launcher is not pinned to the installed companion'
def strings(v):
    if isinstance(v,str): yield v
    elif isinstance(v,list):
        for x in v: yield from strings(x)
    elif isinstance(v,dict):
        for x in v.values(): yield from strings(x)
for name in ('.claude/settings.local.json','.codex/hooks.json'):
    rendered=list(strings(json.loads(Path(sb.project,name).read_text())))
    assert any(str(companion) in x for x in rendered), name+' does not render the native companion'
    assert any(sb.project in x for x in rendered), name+' does not name the fixture root'
print('ok', sb.meta['launcher_install'], sb.meta['version_stamped_from'])
PY
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *'ok paired'* ]] || false
}

@test "T34b worktree callbacks are the rendered user settings, never the raw native template" {
  run python3 -I - "$BENCH" "$SOURCE_ROOT" "$ROOT" <<'PY'
import json,runpy,sys
from pathlib import Path
G=runpy.run_path(sys.argv[1])['main'].__globals__
base=Path(sys.argv[3])/'callback-sandbox'; base.mkdir()
sb=G['build_sandbox'](str(base),sys.argv[2],'HEAD')
template=json.loads(Path(sb.project,'.trellis/runtime/core-rules/templates/claude-user-settings.json').read_text())
assert '__TRELLIS_LAUNCHER__' in json.dumps(template), 'fixture premise: the user template is native-shaped'
hooks=G['worktree_callback_hooks'](sb)
for event in ('WorktreeCreate','WorktreeRemove'):
    members=G['matched_hooks'](hooks,event,None,sb.project)
    assert members, event
    for m in members:
        argv=' '.join(m.command())
        assert '__TRELLIS_' not in argv, (event, argv)
    print(event, [m.name for m in members], [m.fused for m in members])
PY
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WorktreeCreate"*"trellis-worktree-create"* ]] || false
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
