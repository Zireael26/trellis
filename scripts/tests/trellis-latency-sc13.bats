#!/usr/bin/env bats
# Functional tests only: no qualification runs or performance claims.

BENCH="$BATS_TEST_DIRNAME/../bench/trellis-latency.py"
SOURCE_ROOT="$(CDPATH= cd -- "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  local name isolated="$BATS_TEST_TMPDIR/sc13-isolation"
  # A direct Bats invocation must not inherit repository routing or injected
  # Git config from its caller. The canonical runner's TRELLIS_TEST_* fence
  # variables are intentionally retained.
  for name in $(compgen -A variable GIT_); do unset "$name"; done
  mkdir -p "$isolated/home" "$isolated/trellis" "$isolated/tmp" "$isolated/cargo-target"
  chmod 700 "$isolated" "$isolated/home" "$isolated/trellis" "$isolated/tmp"
  : > "$isolated/global.gitconfig"
  chmod 600 "$isolated/global.gitconfig"
  export HOME="$isolated/home" TRELLIS_HOME="$isolated/trellis"
  export GIT_CONFIG_GLOBAL="$isolated/global.gitconfig" GIT_CONFIG_NOSYSTEM=1 TMPDIR="$isolated/tmp"
  export RUSTUP_HOME="${RUSTUP_HOME:-$isolated/rustup}" CARGO_HOME="${CARGO_HOME:-$isolated/cargo}"
  export RUSTUP_AUTO_INSTALL=0 CARGO_NET_OFFLINE=true CARGO_BUILD_JOBS=4 CARGO_TARGET_DIR="$isolated/cargo-target"
}

teardown() {
  chmod -R u+w "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

@test "SC13 isolation child witness" {
  [ -z "${GIT_DIR+x}" ]
  [ -z "${GIT_WORK_TREE+x}" ]
  [ -z "${GIT_CONFIG_COUNT+x}" ]
  [ -z "${GIT_CONFIG_KEY_0+x}" ]
  [ "$HOME" = "$BATS_TEST_TMPDIR/sc13-isolation/home" ]
  [ "$TRELLIS_HOME" = "$BATS_TEST_TMPDIR/sc13-isolation/trellis" ]
  [ "$GIT_CONFIG_GLOBAL" = "$BATS_TEST_TMPDIR/sc13-isolation/global.gitconfig" ]
  [ "$TMPDIR" = "$BATS_TEST_TMPDIR/sc13-isolation/tmp" ]
  mkdir -p "$BATS_TEST_TMPDIR/git-witness"
  run git -C "$BATS_TEST_TMPDIR/git-witness" init -q
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  run git -C "$BATS_TEST_TMPDIR/git-witness" rev-parse --git-dir
  [ "$status" -eq 0 ]
  [ "$output" = .git ]
}

@test "SC13 test setup scrubs hostile inherited Git environment" {
  run env GIT_DIR="$BATS_TEST_TMPDIR/hostile-git" GIT_WORK_TREE="$BATS_TEST_TMPDIR/hostile-worktree" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
    bats --filter '^SC13 isolation child witness$' "$BATS_TEST_FILENAME"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "SC13 ordinary row stays unavailable until its evidence is trustworthy" {
  run python3 -I - "$BENCH" <<'PY'
import runpy, sys
from types import SimpleNamespace
G = runpy.run_path(sys.argv[1])['main'].__globals__
def forbidden(_sb):
    raise AssertionError('unverified ordinary row attempted fixture setup')
G['sc13_fixture'] = forbidden
G['bench_worktree_callbacks'] = lambda *args: None
args = SimpleNamespace(lifecycle_items=['pre-push-dispatcher-ordinary'], lifecycle_runs=1,
                       warmup=0, condition='functional-no-timing-claim')
for meta in ({'release_mode':'checkout'}, {'release_mode':'installed'},
             {'release_mode':'checkout', 'reused':True, 'commit':'a' * 40}):
    rows = []
    G['bench_lifecycle_expansion'](SimpleNamespace(meta=meta, env=lambda: {}), args, rows)
    assert len(rows) == 1 and rows[0]['status'] == 'not-measured', rows
    assert rows[0]['sc13_eligible'] is False and rows[0]['observations'] == [], rows
    assert rows[0]['wall_ms'] is None and 'SC13' in rows[0]['note'], rows
record = {'id':'pre-push-dispatcher-ordinary', 'status':'ok', 'sc13_eligible':True,
          'wall_ms':{'p50':1}, 'members':[], 'observations':[{'warmup':False, 'wall_ms':1}]}
G['finalize_record'](record)
assert record['status'] == 'diagnostic' and record['sc13_eligible'] is False, record
assert record['wall_ms'] is None and record['observations'][0]['aggregation_eligible'] is False
G['measure'] = lambda *a, **k: (_ for _ in ()).throw(AssertionError('disabled helper launched a measurement'))
try:
    G['sc13_measure']('/unused', '/unused', {}, None, b'', 1, 0, None, None, {})
except G['BenchError'] as error:
    assert 'disabled' in str(error), error
else:
    raise AssertionError('disabled SC13 measurement helper returned successfully')
print('SC13 unavailable on all unverified source modes')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "SC13 ordinary-push row is additive and preserves the deletion diagnostic" {
  run python3 -I - "$BENCH" <<'PY'
import json, subprocess, sys

matrix = json.loads(subprocess.run([sys.executable, '-I', sys.argv[1], '--list-cases'],
                                   capture_output=True, text=True, check=True).stdout)
rows = {row['id']: row for row in matrix['cases']}
assert 'pre-push-dispatcher-ordinary' in rows, 'missing additive ordinary-push row'
assert rows['pre-push-dispatcher-ordinary'] == {
    'id': 'pre-push-dispatcher-ordinary', 'fixture_id': 'ordinary-push-sealed-noop-gates',
    'boundary_id': 'managed-pre-push-ordinary-no-battery', 'variant': 'warm', 'owner': 'T69'}
assert rows['pre-push-dispatcher']['fixture_id'] == 'deletion-ref'
assert rows['pre-push-dispatcher']['boundary_id'] == 'managed-pre-push-deletion-no-battery'
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "SC13 real verified fixture executes the unmodified managed dispatcher on an ordinary update" {
  run python3 -I - "$BENCH" "$SOURCE_ROOT" "$BATS_TEST_TMPDIR" <<'PY'
import runpy, subprocess, sys
from pathlib import Path
G = runpy.run_path(sys.argv[1])['main'].__globals__
assert 'sc13_fixture' in G, 'missing real ordinary-push fixture'
sb = G['build_sandbox'](sys.argv[3], sys.argv[2], 'HEAD')
fixture = G['sc13_fixture'](sb)
case = fixture['sandbox']; proof = fixture['proof']; argv = fixture['argv']
assert Path(argv[0]) == Path(case.git(['config', '--get', 'core.hooksPath'], case.project).stdout.decode().strip(), 'pre-push')
assert argv[1:] == ['origin', 'fixture://bench']
assert proof['base_release_commit'] and proof['fixture_release_commit'] and proof['source_commit']
assert proof['base_release_sha256'] and proof['fixture_release_sha256'] and proof['dispatcher_sha256']
assert proof['generated_dispatcher_matches'] is True and proof['fixture_tree_verified'] is True
proc = subprocess.run(argv, cwd=case.project, env=case.env(), input=fixture['refs'], capture_output=True)
assert proc.returncode == 0, (proc.returncode, proc.stdout.decode(errors='replace'), proc.stderr.decode(errors='replace'))
(case.scratch / 'm0.out').write_bytes(proc.stdout)
assert G['sc13_sample_ready'](case, proof, 0, fixture['base'], fixture['head']) is True
assert proof['samples'][-1]['assets_unchanged'] is True
# Direct fixture execution is functional evidence only. The public row must
# not execute or qualify it while the independent proofs remain incomplete.
from types import SimpleNamespace
def forbidden(*args, **kwargs):
    raise AssertionError('disabled SC13 row started work')
G['sc13_fixture'] = forbidden
G['run_group'] = forbidden
G['bench_worktree_callbacks'] = lambda *args: None
rows = []
args = SimpleNamespace(lifecycle_items=['pre-push-dispatcher-ordinary'], lifecycle_runs=1,
                       warmup=0, condition='functional-no-timing-claim')
G['bench_lifecycle_expansion'](sb, args, rows)
assert len(rows) == 1 and rows[0]['status'] == 'not-measured' and rows[0]['sc13_eligible'] is False, rows
assert rows[0]['fixture_id'] == 'ordinary-push-sealed-noop-gates'
assert rows[0]['boundary_id'] == 'managed-pre-push-ordinary-no-battery'
assert not rows[0]['observations'] and rows[0]['wall_ms'] is None
print('real installed dispatcher ordinary-update fixture is not qualification')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "SC13 ordinary-push fixture also executes the pinned baseline dispatcher" {
  run python3 -I - "$BENCH" "$SOURCE_ROOT" "$BATS_TEST_TMPDIR" <<'PY'
import runpy, subprocess, sys
G = runpy.run_path(sys.argv[1])['main'].__globals__
sb = G['build_sandbox'](sys.argv[3], sys.argv[2], '3661cb5f2')
fixture = G['sc13_fixture'](sb)
case = fixture['sandbox']; proof = fixture['proof']
assert proof['source_commit'].startswith('3661cb5f2'), proof['source_commit']
proc = subprocess.run(fixture['argv'], cwd=case.project, env=case.env(),
                      input=fixture['refs'], capture_output=True)
assert proc.returncode == 0, (proc.returncode, proc.stdout.decode(errors='replace'), proc.stderr.decode(errors='replace'))
(case.scratch / 'm0.out').write_bytes(proc.stdout)
assert G['sc13_sample_ready'](case, proof, 0, fixture['base'], fixture['head']) is True
assert proof['samples'][-1]['assets_unchanged'] is True
print('pinned baseline ordinary-update fixture passed')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "SC13 postjob join survives a transient identity probe failure" {
  run python3 -I - "$BENCH" "$BATS_TEST_TMPDIR" <<'PY'
import json, runpy, sys
from pathlib import Path
from types import SimpleNamespace
G = runpy.run_path(sys.argv[1])['main'].__globals__
home = Path(sys.argv[2]) / 'trellis'
status_dir = home / 'state' / 'attachment-status' / 'checkout'
status_dir.mkdir(parents=True)
lock = status_dir / 'worktree.job'; lock.mkdir()
status = status_dir / 'worktree.json'
owner = home / 'owner.json'
owner.write_text(json.dumps({'attachment_id': 'fixture'}))
status.write_text(json.dumps({'state': 'running', 'attachment_id': 'fixture'}))
clock = SimpleNamespace(now=0, probes=0)
def probe(_lock):
    clock.probes += 1
    return 123 if clock.probes == 1 else None
def sleep(seconds):
    clock.now += seconds
    if clock.probes == 2:
        status.write_text(json.dumps({'state': 'ok', 'attachment_id': 'fixture'}))
        lock.rmdir()
G['_job_lock_pid'] = probe
G['time'] = SimpleNamespace(monotonic=lambda: clock.now, sleep=sleep)
G['COMMAND_TIMEOUT'] = 1.0
G['JOB_START_GRACE_S'] = 0.2
sb = SimpleNamespace(trellis_home=str(home))
join = lambda: G['join_postjob'](sb, '/fixture', 'checkout', 'worktree', str(owner))
join()
assert clock.probes == 2 and not lock.exists(), clock
# Even a settled status is not proof that a still-locked job has exited.
lock.mkdir()
clock = SimpleNamespace(now=0, probes=0)
join()
assert clock.probes == 2 and not lock.exists(), clock
# An unverifiable lock cannot certify success; the actual join deadline applies.
G['_job_lock_pid'] = lambda _lock: None
for state in ('running', 'ok'):
    lock.mkdir()
    status.write_text(json.dumps({'state': state, 'attachment_id': 'fixture'}))
    clock = SimpleNamespace(now=0, probes=0)
    try:
        join()
    except G['TeardownError'] as error:
        assert 'still running after 1 s' in str(error), error
    else:
        raise AssertionError('accepted unverifiable lock with state ' + state)
    assert 1.0 < clock.now < 1.1, clock.now
    lock.rmdir()
# A real failure or mismatched owner is still refused.
for record in ({'state': 'failed', 'attachment_id': 'fixture'},
               {'state': 'ok', 'attachment_id': 'other'}):
    status.write_text(json.dumps(record))
    try:
        join()
    except G['TeardownError']:
        pass
    else:
        raise AssertionError('accepted invalid verdict ' + repr(record))
print('postjob join retries uncertain identities and refuses unsafe verdicts')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "SC13 sealed fixture refuses any change outside the four pinned gate stubs" {
  run python3 -I - "$BENCH" <<'PY'
import copy, hashlib, runpy, sys
G = runpy.run_path(sys.argv[1])['main'].__globals__
assert 'sc13_compare_release_trees' in G, 'missing sealed-fixture tree verifier'
verify = G['sc13_compare_release_trees']
stubs = G['SC13_GATE_STUBS']
assert set(stubs) == {'core-rules/hooks/spec-gate.sh', 'core-rules/codex/hooks/spec-gate.sh',
                      'core-rules/hooks/lib/aeo-gate-warn.sh',
                      'core-rules/skills/process-gate/scripts/run-all.sh'}
def oid(data): return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
base = {path: {'mode': '100755', 'oid': 'a' * 40} for path in stubs}
base['scripts/lib/attachment.sh'] = {'mode': '100644', 'oid': 'b' * 40}
fixture = copy.deepcopy(base)
for path, data in stubs.items(): fixture[path]['oid'] = oid(data)
assert verify(base, fixture) is True
for mutation in ('changed-dispatcher', 'wrong-stub', 'added', 'deleted', 'mode'):
    broken = copy.deepcopy(fixture)
    if mutation == 'changed-dispatcher': broken['scripts/lib/attachment.sh']['oid'] = 'c' * 40
    if mutation == 'wrong-stub': broken[next(iter(stubs))]['oid'] = 'd' * 40
    if mutation == 'added': broken['extra'] = {'mode': '100644', 'oid': 'e' * 40}
    if mutation == 'deleted': del broken['scripts/lib/attachment.sh']
    if mutation == 'mode': broken[next(iter(stubs))]['mode'] = '100644'
    try: verify(base, broken)
    except G['BenchError']: pass
    else: raise AssertionError('accepted ' + mutation)
print('sealed fixture mutation assertions passed')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "SC13 refuses nonzero operation exits even with passing proof output" {
  run python3 -I - "$BENCH" "$BATS_TEST_TMPDIR" <<'PY'
import runpy, sys
from pathlib import Path
G = runpy.run_path(sys.argv[1])['main'].__globals__
assert 'sc13_measure' in G, 'missing SC13 ordinary row measurement'
root = Path(sys.argv[2]); invoked = []
def bad_group(*args, **kwargs):
    return {'wall_ms': 1, 'cpu_ms': 0, 'members': [{'rc': 7, 'timed_out': False,
            'exec_error': False, 'wall_ms': 1, 'stdout': 'passing marker', 'stderr': ''}]}
G['run_group'] = bad_group
try:
    G['measure']('pre-push-dispatcher-ordinary', [G['Member']('hook', [str(root / 'pre-push')])],
                 b'ordinary refs', str(root), {}, 1, 0, root,
                 readiness=lambda: invoked.append(True) or True,
                 extra={'section': 'lifecycle', 'sc13_eligible': False})
except G['BenchError'] as error:
    row = error.record
    assert row['status'] == 'failed' and row['sc13_eligible'] is False, row
    assert row['observations'][0]['exit'] == 7 and row['wall_ms'] is None, row
    assert row['observations'][0]['aggregation_eligible'] is False
    assert invoked == [], 'readiness cannot bless a failed operation'
else:
    raise AssertionError('accepted a failed ordinary push')
# Cleanup failure may downgrade a previously successful row after measure returns.
downgraded = {'id': 'pre-push-dispatcher-ordinary', 'status': 'ok', 'sc13_eligible': True,
              'observations': [], 'members': []}
G['finalize_record'](downgraded, 'failed')
assert downgraded['sc13_eligible'] is False, 'failed cleanup retained SC13 eligibility'
print('nonzero exit assertion passed')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "SC13 ordinary sample requires exact update range, three stub executions and unchanged assets" {
  run python3 -I - "$BENCH" "$BATS_TEST_TMPDIR" <<'PY'
import hashlib, runpy, sys
from pathlib import Path
from types import SimpleNamespace
G = runpy.run_path(sys.argv[1])['main'].__globals__
assert 'sc13_sample_ready' in G, 'missing ordinary-push execution proof'
root = Path(sys.argv[2]); scratch = root / 'scratch'; scratch.mkdir()
asset = root / 'dispatcher'; asset.write_text('installed executable\n')
sha = hashlib.sha256(asset.read_bytes()).hexdigest()
base, head = 'a' * 40, 'b' * 40
link = root / 'gate-link'; link.symlink_to(asset)
proof = {'assets': [{'path': str(asset), 'sha256': sha}],
         'gate_links': [{'path': str(link), 'target': str(asset)}],
         'predecessor': str(root / 'no-predecessor'), 'samples': []}
output = ('[pre-push] Trellis verification starting (mode=push)...\n'
          'SC13-STUB:spec --gate --ref refs/heads/bench-sc13 --head ' + head + ' --range ' + base + '..' + head + '\n'
          'SC13-STUB:aeo ' + base + '..' + head + '\n'
          'SC13-STUB:run-all --mode=push --range=' + base + '..' + head + '\n'
          '[pre-push] process-gate ok\n')
(scratch / 'm0.out').write_text(output)
sb = SimpleNamespace(scratch=scratch)
ready = G['sc13_sample_ready']
assert ready(sb, proof, 0, base, head) is True
for description in ('retargeted gate link', 'introduced predecessor'):
    broken = dict(proof)
    if description == 'retargeted gate link':
        broken['gate_links'] = [{'path': str(link), 'target': str(root / 'wrong')}]
    else:
        broken['predecessor'] = str(asset)
    try: ready(sb, broken, 0, base, head)
    except G['BenchError']: pass
    else: raise AssertionError('accepted ' + description)
for description, changed in [('missing spec', output.replace('SC13-STUB:spec', 'missing:spec')),
                              ('deletion', output + '[pre-push] no new commits to gate (deletes only).\n'),
                              ('wrong range', output.replace(base + '..' + head, head + '..' + base)),
                              ('duplicate gate', output + 'SC13-STUB:run-all duplicate\n')]:
    (scratch / 'm0.out').write_text(changed)
    try: ready(sb, proof, 1, base, head)
    except G['BenchError']: pass
    else: raise AssertionError('accepted ' + description)
(scratch / 'm0.out').write_text(output); asset.write_text('mutated executable\n')
try: ready(sb, proof, 2, base, head)
except G['BenchError']: pass
else: raise AssertionError('accepted modified dispatcher asset')
print('ordinary update execution proof assertions passed')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}
