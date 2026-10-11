#!/usr/bin/env bats
# Synthetic, isolated ownership tests only; never execute the full battery.
# Each Inversion comment states the contrary behavior its assertions reject.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
WRAPPER="$REPO_ROOT/scripts/run-tests-local.py"

setup() {
  local parent=/tmp
  case "${TMPDIR:-}" in
    /tmp/tg-*|/private/tmp/tg-*) parent="$TMPDIR" ;;
  esac
  SANDBOX="$(mktemp -d "$parent/run-tests-local.XXXXXX")"
  export TRELLIS_GATE_STATE_DIR="$SANDBOX/state"
  export TRELLIS_LOCAL_GATE_RUNNER="$SANDBOX/fake-runner.sh"
  export TRELLIS_LOCAL_GATE_RECEIPT="$SANDBOX/aggregate.tsv"
  export TRELLIS_LOCAL_GATE_DEADLINE=15 TRELLIS_LOCAL_GATE_RESERVE=5
  export TRELLIS_LOCAL_GATE_TERM_GRACE=0.1
  export FAKE_INVOCATIONS="$SANDBOX/invocations" FAKE_CHILD_PIDS="$SANDBOX/children"
  export FAKE_SANDBOX="$SANDBOX" FAKE_MODE=pass
  : > "$FAKE_INVOCATIONS"
  : > "$FAKE_CHILD_PIDS"
  export FAKE_REAL_PYTHON FAKE_GATE_MODULE="$WRAPPER"
  FAKE_REAL_PYTHON="$(python3 -c 'import sys; print(sys.executable)')"
  "$FAKE_REAL_PYTHON" - "$SANDBOX/baseline.json" <<'PY'
import ctypes, json, sys
lib = ctypes.CDLL('/usr/lib/libproc.dylib')
count = lib.proc_listallpids(None, 0)
pids = (ctypes.c_int * (count * 2 + 64))()
used = lib.proc_listallpids(pids, ctypes.sizeof(pids))
with open(sys.argv[1], 'w') as stream:
    import os
    json.dump({'pids': list(pids[:used]), 'owner': os.getppid()}, stream)
PY
  # Test-only virtual process namespace: pre-existing host applications are
  # outside the fixture UID, while all newly created fixture work is real.
  # Exit observation is the production libc waitid implementation, unchanged.
  # No production admission seam is added.
  mkdir "$SANDBOX/bin"
  cat > "$SANDBOX/bin/python3" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "$FAKE_GATE_MODULE" ]; then
  shift
  exec "$FAKE_REAL_PYTHON" "$FAKE_SANDBOX/driver.py" "$FAKE_GATE_MODULE" hermetic "$@"
fi
exec "$FAKE_REAL_PYTHON" "$@"
SH
  chmod +x "$SANDBOX/bin/python3"
  export PATH="$SANDBOX/bin:$PATH"
  cat > "$TRELLIS_LOCAL_GATE_RUNNER" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
python3 "$FAKE_SANDBOX/admission.py" || exit 78
if [ "${3:-}" = --plan ]; then
  printf 'planner\n' >> "$FAKE_SANDBOX/planner"
  if [ "$FAKE_MODE" = planner-hang ]; then
    python3 "$FAKE_SANDBOX/fake-runner-child.py" sentinel
    while :; do sleep 0.05; done
  fi
  printf 'shard\tstage\tweight\n'
  if [ "$FAKE_MODE" != empty-plan ]; then
    for shard in 1 2 3 4 5 6 7 8; do printf '%s\tfake-stage-%s\t1\n' "$shard" "$shard"; done
    if [ "$FAKE_MODE" = multi-receipt ]; then
      for shard in 1 2 3 4 5 6 7 8; do printf '%s\tfake-stage-%s\t1\n' "$shard" "$((shard + 8))"; done
    fi
  fi
  for shard in 1 2 3 4 5 6 7 8; do printf 'total\t%s\t100\n' "$shard"; done
  exit 0
fi
shard_arg="${2#--shard=}"
shard="${shard_arg%%/*}"
printf '%s %s %s\n' "$$" "$1" "$2" >> "$FAKE_INVOCATIONS"
printf '%s\n' "$TRELLIS_TEST_TSV" >> "$FAKE_SANDBOX/receipts"
ordinal="$shard"; stage="fake-stage-$shard"; row_exit=0
if [ "$shard" -eq 3 ]; then
  case "$FAKE_MODE" in
    missing-row) ordinal='' ;;
    duplicate-row) ordinal=2; stage=fake-stage-2 ;;
    wrong-stage) stage=decoy ;;
    nonzero-row) row_exit=7 ;;
  esac
fi
if [ -n "$ordinal" ]; then
  printf '%s\t%s\t%s\t%s\n' "$ordinal" "$stage" "$shard" "$row_exit" >> "$TRELLIS_TEST_TSV"
fi
case "$FAKE_MODE" in
  pass|fail|exec-fail)
    printf 'fake-shard-%s\n' "$shard"
    if [ "$shard" -eq 3 ]; then
      [ "$FAKE_MODE" != fail ] || exit 7
      [ "$FAKE_MODE" != exec-fail ] || exit 127
    fi
    ;;
  receipt|multi-receipt)
    if [ "$FAKE_MODE" = multi-receipt ]; then
      ordinal=$((shard + 8))
      printf '%s\tfake-stage-%s\t%s\t0\n' "$ordinal" "$ordinal" "$ordinal" >> "$TRELLIS_TEST_TSV"
    fi
    ;;
  group|sentinel|cwd|open-file|environment|ignore-term|fork-term|shard-out)
    if [ "$shard" -eq 1 ]; then
      python3 "$FAKE_SANDBOX/fake-runner-child.py" "$FAKE_MODE"
    fi
    ;;
  signal|descendant)
    if [ "$shard" -eq 1 ]; then
      python3 "$FAKE_SANDBOX/fake-runner-child.py" "${FAKE_MODE/signal/ignore-term}"
    fi
    while :; do sleep 0.05; done
    ;;
esac
SH
  cat > "$SANDBOX/admission.py" <<'PY'
import importlib.util
import json
import os
import stat
import time
from pathlib import Path
spec = importlib.util.spec_from_file_location('observations', os.environ['FAKE_GATE_MODULE'])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
# Inversion: removing/delaying START emission must refuse the planner itself,
# not merely leave an end-of-run report without tool versions.
provenance = Path(os.environ['TRELLIS_LOCAL_GATE_RECEIPT'] + '.provenance.jsonl')
start = json.loads(provenance.read_text().splitlines()[0])
assert start['phase'] == 'start'
assert start['timestamp'] and start['head'] and start['command']
assert start['path'] and 'active_trellis_release' in start
assert set(start['tools']) == {'bash', 'bats', 'jq', 'git', 'node', 'pnpm'}
for tool in start['tools'].values():
    assert tool['path'] and tool['version']
run_root = Path(os.environ['TMPDIR']).parent
assert str(run_root) == os.path.realpath(run_root)
assert stat.S_IMODE(run_root.stat().st_mode) == 0o700
assert os.environ['TRELLIS_GATE_STATE_DIR'] == str(run_root / 'state')
record = Path(os.environ['FAKE_SANDBOX']) / 'state/runs' / (os.environ['TRELLIS_GATE_RUN_ID'] + '.json')
assert stat.S_IMODE(record.stat().st_mode) == 0o600
data = json.loads(record.read_text())
(Path(os.environ['FAKE_SANDBOX']) / 'admission-view').write_text(json.dumps(data))
assert data['token'] == os.environ['TRELLIS_GATE_RUN_ID']
assert data['run_root'] == str(run_root)
assert os.getppid() in {g['pgid'] for g in data['groups']}, 'exec preceded durable registration'
assert ('TRELLIS_GATE_RUN_ID=' + data['token']).encode() not in gate.process_environment(data['owner']['pid'])
output_name = 'planner.out' if os.environ.get('TRELLIS_TEST_TSV') is None else Path(os.environ['TRELLIS_TEST_TSV']).stem + '.out'
output_stat = (run_root / output_name).stat()
assert {'path': str(run_root / output_name), 'dev': output_stat.st_dev, 'ino': output_stat.st_ino} in data['output_ids'], 'output identity not recorded before exec'
assert (data['sentinel_id']['dev'], data['sentinel_id']['ino']) in {
    identity for identity, path in gate.process_files(os.getpid(), time.monotonic() + 1)}
if os.environ.get('FAKE_EXPECT_HEAVY'):
    held = os.fstat(int(os.environ['TRELLIS_HEAVY_FD']))
    expected = Path(os.environ['FAKE_EXPECT_HEAVY']).stat()
    assert (held.st_dev, held.st_ino) == (expected.st_dev, expected.st_ino)
PY
  cat > "$SANDBOX/fake-runner-child.py" <<'PY'
import os
import signal
import sys
import time
from pathlib import Path

if sys.argv[1] != 'final':
    mode = sys.argv[1]
    pidfile = Path(os.environ['FAKE_CHILD_PIDS'])
    private = Path(os.environ['TMPDIR'])
    sentinel = private.parent / 'sentinel'
    # Discover the inherited fd, not an artificial fd-number test seam.
    identity = sentinel.stat()
    held = []
    for fd in range(3, 256):
        try:
            info = os.fstat(fd)
            if (info.st_dev, info.st_ino) == (identity.st_dev, identity.st_ino):
                held.append(fd)
        except OSError:
            pass
    if not held:
        raise RuntimeError('sentinel was not inherited')
    previous = len(pidfile.read_text().splitlines())
    child = os.fork()
    if child:
        if mode == 'descendant':
            # Remain owned at scan time; the child has no other signal.
            while True:
                time.sleep(0.05)
        if mode != 'group':
            os.waitpid(child, 0)
        end = time.monotonic() + 3
        while len(pidfile.read_text().splitlines()) <= previous:
            if time.monotonic() >= end:
                raise RuntimeError('child never became ready')
            time.sleep(0.01)
        sys.exit(0)
    if mode != 'group':
        os.setsid()
    if mode not in ('group', 'descendant'):
        if os.fork():
            os._exit(0)
    # Keep the evidence file (OUTSIDE this inner run root) open. In a
    # self-hosted gate it belongs to the outer shard's TMPDIR, so these
    # deliberately stripped inner fixtures cannot escape the OUTER boundary.
    evidence_fd = os.open(str(pidfile), os.O_WRONLY | os.O_APPEND)
    os.set_inheritable(evidence_fd, True)
    keep = (held if mode == 'sentinel' else []) + [evidence_fd]
    for fd in range(256):
        if fd not in keep:
            try:
                os.close(fd)
            except OSError:
                pass
    if mode == 'shard-out':
        output = os.open(str(private.parent / 'shard-1.out'), os.O_WRONLY | os.O_APPEND)
        os.dup2(output, 1)
        os.close(output)
        os.write(evidence_fd, (str(os.getpid()) + '\n').encode())
        # A platform binary with no visible env and no fd >=3 at exec.
        for fd in range(3, 256):
            try:
                os.close(fd)
            except OSError:
                pass
        os.execve('/bin/sleep', ['/bin/sleep', '534064'], {})
    environment = {'TRELLIS_GATE_RUN_ID': os.environ['TRELLIS_GATE_RUN_ID']} if mode == 'environment' else {}
    # execve(env={}) really removes the original kernel-visible environment;
    # os.environ.clear() alone is not a sufficient ps-env isolation fixture.
    os.execve(sys.executable, [sys.executable, __file__, 'final', mode, str(pidfile), str(private), str(evidence_fd)], environment)
mode, pidname, private_name, evidence_number = sys.argv[2:]
pidfile = Path(pidname)
private = Path(private_name)
evidence_fd = int(evidence_number)
# No private-root output handles can accidentally satisfy a signal.
for fd in range(3):
    opened = os.open('/dev/null', os.O_RDWR)
    if opened != fd:
        os.dup2(opened, fd)
        os.close(opened)
os.chdir(str(private) if mode == 'cwd' else '/')
if mode == 'open-file':
    opened = os.open(str(private / 'held'), os.O_CREAT | os.O_RDWR, 0o600)

def log():
    os.write(evidence_fd, (str(os.getpid()) + '\n').encode())

if mode in ('ignore-term', 'fork-term'):
    # These are detached, so give them the cwd signal after stripping others.
    os.chdir(str(private))
    if mode == 'ignore-term':
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    else:
        def fork_again(_signum, _frame):
            if not os.fork():
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                log()
        signal.signal(signal.SIGTERM, fork_again)
log()
while True:
    time.sleep(0.05)
PY
  cat > "$SANDBOX/driver.py" <<'PY'
import importlib.util
import os
import signal
import subprocess
import sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('gate', sys.argv[1])
gate = importlib.util.module_from_spec(spec)
mutation = os.environ.get('FAKE_GATE_MUTATION')
if mutation:
    mutations = {
        'group': ('groups = {group["pgid"] for group in self.data["groups"]}', 'groups = set()'),
        'sentinel': ('if identity == sentinel:\n                    owned.add(pid)', 'if identity == sentinel:\n                    pass'),
        'file': ('if canonical == private_tmp or canonical.startswith(private_tmp + "/"):', 'if False:'),
        'output': ('elif identity in outputs:\n                    owned.add(pid)', 'elif identity in outputs:\n                    pass'),
        'output-registration': ('save_record(path, data)  # Pin inherited stdio BEFORE Popen, even on SIGKILL.', 'pass'),
        'env-absent': ('return None  # Environment absent, NOT a permission-protected process.',
                       'raise UnreadableProcess("env-absent inversion")'),
        'environment': ('if environment is not None and token in environment:', 'if False:'),
        'descendants': ('if table[pid].ppid in owned}', 'if False}'),
        'kill': ('signal_member(identity, signal.SIGKILL)', 'signal_member(identity, signal.SIGTERM)'),
        'term-first': ('signal_member(identity, signal.SIGTERM)', 'signal_member(identity, signal.SIGKILL)'),
        'identity': ('if observed != identity:', 'if False:'),
        'foreign': ('if parent is not None and parent.pid != 1 and parent.status != 5 and parent.pid not in owned:', 'if False:'),
        'empty': ('if empty_scans >= 2 and not self.ambiguous:', 'if empty_scans >= 1 and not self.ambiguous:'),
        'atomic': ('os.replace(temporary, path)\n        _fsync_directory(path.parent)', 'os.replace(temporary, path)'),
        'corrupt': ('return 70 if corrupt else 1 if records else 0', 'return 1 if records else 0'),
        'deadline': ('productive_at = deadline_at - reserve', 'productive_at = deadline_at'),
        'shards': ('SHARD_COUNT = 8', 'SHARD_COUNT = 4'),
        'aggregate': ('rows.sort()', 'rows.reverse()'),
        'empty-plan': ('if not expected:\n            raise ValueError("empty shard plan")', 'if False:\n            raise ValueError("empty shard plan")'),
        'aggregate-empty': ('if expected is not None and not expected:', 'if False:'),
        'aggregate-missing': ('if actual != list(enumerate(expected, 1)):', 'if False:'),
        'aggregate-duplicate': ('if actual != list(enumerate(expected, 1)):', 'if False:'),
        'aggregate-stage': ('if actual != list(enumerate(expected, 1)):', 'if False:'),
        'aggregate-exit': ('if int(row.split("\\t")[3]) != 0:', 'if False:'),
        'replay': ('for record in records:\n        data = record["output"].read_bytes()', 'for record in reversed(records):\n        data = record["output"].read_bytes()'),
        'failure': ('e["process"] is not None and observe_exit(e["process"]) == 0 for e in shards', 'e["process"] is not None for e in shards'),
        'state': ('environment["TRELLIS_GATE_STATE_DIR"] = str(run_root / "state")', 'pass'),
        'heavy': ('pass_fds=(fd, ready_read) + _heavy_fds(),', 'pass_fds=(fd, ready_read),'),
        'preexisting': ('and _birth(entry) >= started_us}', 'and True}'),
        'clock': ('bound = reconstructed', 'bound = started_us'),
        'retry': ('return read()\n\n\ndef bsd_info', 'raise ContainmentError("retry disabled")\n\n\ndef bsd_info'),
        'empty-argv': ('offset = 4 + ((offset - 4 + 1 + alignment - 1) // alignment) * alignment',
                       'offset += 1\n    while offset < len(raw) and raw[offset] == 0:\n        offset += 1'),
        'earlier-boot-root': ('_remove_run_root(data)\n                _receipt(data, 0, False)', 'pass\n                _receipt(data, 0, False)'),
        'unreadable-member': ('unreadable.add(pid)\n                continue', 'owned.add(pid)\n                continue'),
        'unreadable-fail': ('except UnreadableProcess:\n                unreadable.add(pid)',
                            'except UnreadableProcess:\n                raise ContainmentError("unreadable inversion")\n                unreadable.add(pid)'),
        'wait-reap': ('0x04 | 0x01 | 0x20', '0x04 | 0x01'),
        'registration': ('save_record(path, data)\n        os.write(ready_write, b"g")',
                         'os.write(ready_write, b"g")\n        while not (Path(os.environ["FAKE_SANDBOX"]) / "admission-view").exists():\n            time.sleep(.01)\n        save_record(path, data)'),
    }
    source = Path(sys.argv[1]).read_text()
    before, after = mutations[mutation]
    assert source.count(before) == 1, 'mutation must change exactly one production site'
    source = source.replace(before, after)
    assert before not in source and after in source, 'mutation did not land'
    if os.environ.get('FAKE_GATE_MUTATION_LOG'):
        with open(os.environ['FAKE_GATE_MUTATION_LOG'], 'a') as landed:
            landed.write(mutation + '\n')
    exec(compile(source, sys.argv[1], 'exec'), gate.__dict__)
else:
    spec.loader.exec_module(gate)
mode = sys.argv[2]

# Hermetic fixture UID provider. Real vnode/env/identity/signal calls are NOT
# faked. The fixture owner tree and declared orphan/record PIDs form the virtual
# UID; neither protected host apps nor other concurrent fixtures belong to it.
import ctypes
import errno
import json
fixture = Path(os.environ['FAKE_SANDBOX'])
baseline_data = json.loads((fixture / 'baseline.json').read_text())
baseline = set(baseline_data['pids'])
def fixture_table(end):
    gate._bounded(end)
    count = gate._LIBPROC.proc_listallpids(None, 0)
    pids = (ctypes.c_int * (count * 2 + 64))()
    used = gate._LIBPROC.proc_listallpids(pids, ctypes.sizeof(pids))
    ours = (ctypes.c_int * len(pids))()
    own_bytes = gate._LIBPROC.proc_listpids(4, os.getuid(), ours, ctypes.sizeof(ours))
    allowed = set(ours[:own_bytes // 4])
    ancestors = set()
    parent = os.getpid()
    while parent > 1 and parent not in ancestors:
        ancestors.add(parent)
        try:
            info = gate.bsd_info(parent)
        except gate.ContainmentError:
            break
        if info is None:
            break
        parent = info.ppid
    result = {}
    for pid in pids[:used]:
        gate._bounded(end)
        if pid <= 1 or pid not in allowed or (pid in baseline and pid not in ancestors):
            continue
        info = gate.bsd_info(pid)
        if info is not None:
            result[pid] = info
    declared = {baseline_data['owner'], os.getpid()}
    for line in (fixture / 'children').read_text().splitlines():
        if line.isdigit():
            declared.add(int(line))
    for record in (fixture / 'state/runs').glob('*.json'):
        try:
            data = json.loads(record.read_text())
            declared.add(data['owner']['pid'])
            declared.update(group['pgid'] for group in data['groups'])
        except (OSError, ValueError, KeyError, TypeError):
            pass  # Production, not this UID provider, must quarantine corruption.
    while True:
        children = {pid for pid, info in result.items() if info.ppid in declared}
        if children <= declared:
            break
        declared.update(children)
    return {pid: info for pid, info in result.items() if pid in declared or pid in ancestors}
gate.process_table = fixture_table

original_popen = gate.subprocess.Popen
def checked_popen(*args, **kwargs):
    environment = kwargs.get('env', {})
    token = environment.get('TRELLIS_GATE_RUN_ID')
    if token and kwargs.get('start_new_session'):
        record = fixture / 'state/runs' / (token + '.json')
        data = json.loads(record.read_text())
        output = kwargs['stdout']
        info = os.fstat(output.fileno())
        assert {'path': str(Path(output.name).resolve()), 'dev': info.st_dev, 'ino': info.st_ino} in data['output_ids'], 'output was not durable before Popen'
    return original_popen(*args, **kwargs)
gate.subprocess.Popen = checked_popen

original_spawn = gate._spawn
def checked_spawn(data, path, fd, processes, command, root, environment, output):
    assert os.environ.get('TRELLIS_GATE_RUN_ID') != data['token'], 'runner mutated its own environment'
    return original_spawn(data, path, fd, processes, command, root, environment, output)
gate._spawn = checked_spawn

if mode == 'interrupt-spawn':
    original = gate.subprocess.Popen
    def spawn(*args, **kwargs):
        process = original(*args, **kwargs)
        command = args[0]
        if '--shard=1/8' in command and '--plan' not in command:
            os.kill(os.getpid(), signal.SIGINT)
        return process
    gate.subprocess.Popen = spawn
elif mode == 'partial-spawn':
    original = gate.subprocess.Popen
    def spawn(*args, **kwargs):
        if '--shard=3/8' in args[0]:
            raise OSError('synthetic spawn failure')
        return original(*args, **kwargs)
    gate.subprocess.Popen = spawn
elif mode == 'unkillable':
    gate.signal_member = lambda identity, signum: False
elif mode == 'ambiguous':
    original = gate.Boundary.scan
    def scan(self, end):
        members = original(self, end)
        return {pid: None for pid in members}
    gate.Boundary.scan = scan
elif mode == 'no-identity':
    gate.process_identity = lambda pid: None
elif mode == 'no-libproc':
    gate._LIBPROC = None
elif mode == 'missing-waitid':
    gate._WAITID = None
elif mode == 'failed-waitid':
    def failed(*args):
        ctypes.set_errno(errno.EINVAL)
        return -1
    gate._WAITID = failed
elif mode == 'bad-root':
    original = gate.tempfile.mkdtemp
    def create(*args, **kwargs):
        name = original(*args, **kwargs)
        os.chmod(name, 0o755)
        return name
    gate.tempfile.mkdtemp = create
elif mode == 'bad-sentinel':
    original = gate.os.open
    def opened(path, *args, **kwargs):
        if str(path).endswith('/sentinel'):
            raise OSError('synthetic sentinel failure')
        return original(path, *args, **kwargs)
    gate.os.open = opened
elif mode == 'fast-empty':
    import time
    scans = []
    def scan(self, end):
        scans.append(True)
        return {}
    gate.Boundary.scan = scan
    started = time.monotonic()
    assert gate.Boundary({}).teardown(started + 6, 5) == 0
    assert len(scans) == 2, 'boundary did not require two empty scans'
    assert time.monotonic() - started < 0.25, 'empty boundary slept through grace'
    sys.exit(0)
elif mode in ('foreign-guard', 'outside-tmp', 'earlier-boot', 'earlier-boot-unsafe', 'stale-group', 'scan-failure', 'uid-exclusion', 'ancestor-exclusion', 'preexisting', 'clock-step'):
    import json
    import shutil
    import tempfile
    import time
    import uuid
    root = Path(tempfile.mkdtemp(prefix='tg-', dir='/tmp')).resolve()
    (root / 'tmp').mkdir(mode=0o700)
    sentinel = root / 'sentinel'
    sentinel.touch(mode=0o600)
    info = sentinel.stat()
    token = uuid.uuid4().hex
    data = {'token': token, 'uid': os.getuid(), 'owner': {'pid': 9999999, 'start_us': 1},
            'run_root': str(root), 'sentinel': str(sentinel), 'groups': [],
            'started_us': time.time_ns() // 1000,
            'sentinel_id': {'dev': info.st_dev, 'ino': info.st_ino}, 'boot_session': gate.boot_session(), 'head': '0' * 40}
    held = (root / 'tmp' / 'preexisting-stdio').open('wb')
    process = subprocess.Popen(['/bin/sleep', '60'], cwd=str(root / 'tmp') if mode == 'foreign-guard' else '/',
                               env={}, start_new_session=True, stdout=held if mode == 'preexisting' else None)
    held.close()
    try:
        identity = gate.process_identity(process.pid)
        assert identity is not None
        data['groups'] = [{'pgid': process.pid, 'start_us': identity[1]}]
        table = {pid: gate.bsd_info(pid) for pid in (os.getpid(), os.getppid(), process.pid)}
        gate.process_table = lambda end: table
        if mode == 'clock-step':
            data['started_us'] = identity[1] + 10000000
            data['started_monotonic'] = time.monotonic() - 1
            real_time = gate.time.time_ns
            gate.time.time_ns = lambda: (identity[1] + 500000) * 1000
            try:
                state = gate.RunState()
                record = state.runs / (token + '.json')
                gate.save_record(record, data)
                members = gate.Boundary(data, live=True, record_path=record).scan(time.monotonic() + 1)
                assert members == {process.pid: identity}, 'clock step excluded in-run work'
                assert data['clock_step'] == 1
                assert data['pre_run_bound_us'] <= identity[1]
                assert gate._read_record(record)['pre_run_bound_us'] == data['pre_run_bound_us'], 'safer bound was not durable'
                gate._receipt(data, len(members), True)
                record.unlink()
                state.close()
            finally:
                gate.time.time_ns = real_time
        elif mode == 'preexisting':
            data['started_us'] = time.time_ns() // 1000
            assert identity[1] < data['started_us']
            # A pre-run file holder is excluded even from a registered group,
            # token, sentinel and descendant signal; every signal is forbidden.
            assert str(root / 'tmp' / 'preexisting-stdio') in {
                path for _, path in gate.process_files(process.pid, time.monotonic() + 1)}
            table[process.pid].ppid = os.getpid()
            gate.process_environment = lambda pid: {('TRELLIS_GATE_RUN_ID=' + token).encode()}
            boundary = gate.Boundary(data, live=True)
            assert boundary.scan(time.monotonic() + 1) == {}, 'pre-run file holder became a member'
            assert boundary.teardown(time.monotonic() + 1, .05) == 0
            assert process.poll() is None, 'pre-run file holder was signaled'
            # Admission must not probe protected pre-existing host processes.
            original_files = gate.process_files
            def files(pid, end):
                assert pid != process.pid, 'capability queried a pre-run process'
                return original_files(pid, end)
            gate.process_files = files
            assert gate._capability(time.monotonic() + 2, started_us=data['started_us']) == []
        elif mode == 'uid-exclusion':
            table[process.pid].uid = os.getuid() + 1  # No real user/privilege change.
            assert gate.Boundary(data, live=True).scan(time.monotonic() + 1) == {}
            assert process.poll() is None
        elif mode == 'ancestor-exclusion':
            table.pop(process.pid)
            data['groups'] = [{'pgid': os.getpgrp(), 'start_us': 1}]
            gate.process_environment = lambda pid: {('TRELLIS_GATE_RUN_ID=' + token).encode()}
            gate.process_files = lambda pid, end: [((info.st_dev, info.st_ino), str(sentinel))]
            assert gate.Boundary(data, live=True).scan(time.monotonic() + 1) == {}
            assert process.poll() is None
        elif mode == 'foreign-guard':
            data['groups'] = []
            boundary = gate.Boundary(data)
            members = boundary.scan(time.monotonic() + 1)
            assert members == {process.pid: None}, 'foreign parent guard granted signal authority'
            assert boundary.teardown(time.monotonic() + .2, .05) > 0
            assert process.poll() is None, 'foreign process was signaled'
        elif mode == 'scan-failure':
            boundary = gate.Boundary(data)
            count = [0]
            def scan(end):
                count[0] += 1
                if count[0] == 1:
                    raise gate.ContainmentError('injected scan failure')
                return {}
            boundary.scan = scan
            assert boundary.teardown(time.monotonic() + .2, .05) > 0, 'scan failure was forgotten'
        elif mode == 'stale-group':
            # A stale record must not signal a group ID now used by foreign work.
            boundary = gate.Boundary(data, live=False)
            assert boundary.scan(time.monotonic() + 1) == {}
            assert boundary.teardown(time.monotonic() + 1, .05) == 0
            assert process.poll() is None
        elif mode in ('earlier-boot', 'earlier-boot-unsafe'):
            data['boot_session'] = 'previous-boot'
            state = gate.RunState()
            record = state.runs / (token + '.json')
            gate.save_record(record, data)
            gate.Boundary.scan = lambda self, end: (_ for _ in ()).throw(AssertionError('old boot scanned'))
            if mode == 'earlier-boot-unsafe':
                os.chmod(root, 0o755)
                assert not gate.sweep_records(state, 1, .05)
                assert root.exists() and record.exists(), 'unsafe root or its record was removed'
                os.chmod(root, 0o700)
            assert gate.sweep_records(state, 1, .05)
            assert not record.exists()
            assert not root.exists(), 'earlier-boot private root leaked'
            assert process.poll() is None
            state.close()
        else:
            # The worktree cwd and unregistered logs NEVER own work. Exact
            # output identities do: a live foreign parent makes them ambiguous,
            # while an orphan is owned, for BOTH planner and shard stdio.
            data['groups'] = []
            gate.process_environment = lambda pid: None
            for name in ('planner.out', 'shard-1.out'):
                output = root / name
                output.touch()
                output_stat = output.stat()
                file_id = (output_stat.st_dev, output_stat.st_ino)
                data['output_ids'] = [{'path': str(output), 'dev': file_id[0], 'ino': file_id[1]}]
                gate.process_files = lambda pid, end: [((0, 0), str(output)),
                                                      ((0, 0), str(Path(sys.argv[1]).resolve().parent.parent))]
                assert gate.Boundary(data).scan(time.monotonic() + 1) == {}, 'path alone matched output'
                gate.process_files = lambda pid, end: [(file_id, '/renamed-output')]
                parent = table[process.pid].ppid
                boundary = gate.Boundary(data)
                assert boundary.scan(time.monotonic() + 1) == {process.pid: None}, 'foreign output holder became owned'
                assert boundary.teardown(time.monotonic() + .15, .05) > 0
                assert process.poll() is None, 'ambiguous output holder was signaled'
                table[process.pid].ppid = 1
                assert gate.Boundary(data).scan(time.monotonic() + 1) == {process.pid: identity}, 'orphan output holder escaped'
                assert data.get('unreadable_excluded', []) == [], 'env-absent holder was listed'
                table[process.pid].ppid = parent
    finally:
        process.kill()
        process.wait()
        shutil.rmtree(root, ignore_errors=True)
    sys.exit(0)
elif mode in ('unreadable-files', 'unreadable-environment', 'unreadable-preflight-files', 'unreadable-preflight-environment'):
    import time
    foreign = None
    original = gate._spawn
    original_capability = gate._capability
    saved = []
    original_save = gate.save_record
    def save(path, data):
        result = original_save(path, data)
        if data.get('unreadable_excluded'):
            saved.append(json.loads(path.read_text()))
        return result
    gate.save_record = save
    def protected(run_root=None):
        global foreign
        foreign = subprocess.Popen(['/bin/sleep', '60'], env={}, cwd='/', start_new_session=True,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        source = 'process_files' if mode.endswith('-files') else 'process_environment'
        readable = getattr(gate, source)
        def denied(pid, *extra):
            if pid == foreign.pid:
                raise gate.UnreadableProcess('injected protected in-run process')
            return readable(pid, *extra)
        setattr(gate, source, denied)
        if run_root is not None and mode.endswith('-environment'):
            # A readable file signal must NOT override an unreadable env.
            files = gate.process_files
            gate.process_files = lambda pid, end: (
                [((0, 0), str(Path(run_root) / 'tmp' / 'held'))]
                if pid == foreign.pid else files(pid, end))
    def spawn(*args, **kwargs):
        process = original(*args, **kwargs)
        if foreign is None:
            protected(args[0]['run_root'])
        return process
    def capability(*args, **kwargs):
        if mode.startswith('unreadable-preflight-') and kwargs.get('started_us') is not None:
            protected()
        return original_capability(*args, **kwargs)
    gate._spawn = spawn
    gate._capability = capability
    try:
        result = gate.main([])
        assert result == 0, 'unreadable in-run process made the gate fail'
        assert foreign is not None and foreign.poll() is None, 'unreadable unrelated process was signaled'
        assert saved, 'unreadable exclusions were not durably recorded'
        exclusions = saved[-1]['unreadable_excluded']
        assert len(exclusions) == 1, 'unreadable process not counted once across full scans'
        entry = exclusions[0]
        assert entry['pid'] == foreign.pid
        assert entry['start_us'] == gate.process_identity(foreign.pid)[1]
        assert entry['start_us'] >= saved[-1]['started_us']
        assert entry['executable'] == '/bin/sleep', 'receipt must use proc_pidpath'
    finally:
        if foreign is not None:
            foreign.kill()
            foreign.wait()
    sys.exit(0)
elif mode == 'foreign-output':
    foreign = None
    original = gate._spawn
    def spawn(*args, **kwargs):
        global foreign
        process = original(*args, **kwargs)
        if foreign is None:
            with (Path(args[0]['run_root']) / 'planner.out').open('ab') as held:
                foreign = subprocess.Popen(['/bin/sleep', '534064'], env={}, cwd='/', start_new_session=True,
                                           close_fds=True, stdin=subprocess.DEVNULL, stdout=held, stderr=held)
        return process
    gate._spawn = spawn
    try:
        result = gate.main([])
        assert result == 71, 'foreign output holder did not quarantine the run'
        assert foreign.poll() is None, 'foreign output holder was signaled'
    finally:
        if foreign is not None:
            foreign.kill()
            foreign.wait()
    sys.exit(result)
elif mode == 'heavy-propagation':
    import fcntl
    slot = Path(os.environ['FAKE_SANDBOX']) / 'fake-heavy.slot'
    opened = os.open(str(slot), os.O_CREAT | os.O_RDWR, 0o600)
    high = fcntl.fcntl(opened, fcntl.F_DUPFD, 64)
    os.set_inheritable(high, True)
    fcntl.flock(high, fcntl.LOCK_EX | fcntl.LOCK_NB)
    os.environ['TRELLIS_HEAVY_FD'] = str(high)
    os.environ['FAKE_EXPECT_HEAVY'] = str(slot)
    try:
        result = gate.main([])
    finally:
        os.close(high)
        os.close(opened)
    sys.exit(result)
elif mode in ('exact-env', 'empty-argv', 'env-absent'):
    token = b'TRELLIS_GATE_RUN_ID=exact'
    def procargs(arguments, environment=None):
        executable = b'/bin/helper\0'
        alignment = ctypes.sizeof(ctypes.c_void_p)
        executable += b'\0' * (-len(executable) % alignment)
        raw = len(arguments).to_bytes(4, sys.byteorder) + executable
        raw += b''.join(argument + b'\0' for argument in arguments)
        if environment is not None:
            raw += b'\0'.join(environment) + b'\0\0'
        return raw
    if mode == 'empty-argv':
        for arguments in ([b''], [b'', b'arg']):
            assert gate.parse_environment(procargs(arguments, [token, b'LAST=yes'])) == {token, b'LAST=yes'}, 'empty argv swallowed first env entry'
    elif mode == 'env-absent':
        assert gate.parse_environment(procargs([b'/bin/sleep', b'3'])) is None, 'platform binary env was not absent'
        assert gate.parse_environment(procargs([b'helper'], [])) == set(), 'readable empty env is not absent'
        info = gate._BSDInfo()
        info.pid, info.ppid, info.pgid, info.uid, info.start_sec = 98765, 1, 98765, os.getuid(), 1
        data = {'token': 'test', 'owner': {'pid': 98766, 'start_us': 1}, 'started_us': 1,
                'run_root': str(fixture), 'groups': [], 'sentinel_id': {'dev': 42, 'ino': 43}}
        gate.process_table = lambda end: {info.pid: info}
        gate.process_identity = lambda pid: (pid, 1000000)
        gate.process_environment = lambda pid: None
        import time
        for source in ('sentinel', 'tmp', 'group', 'descendant'):
            data['groups'] = [{'pgid': 98765, 'start_us': 1000000}] if source == 'group' else []
            gate.process_files = lambda pid, end: ([((42, 43), '/renamed-sentinel')] if source == 'sentinel'
                                                   else [((0, 0), str(fixture / 'tmp/held'))] if source == 'tmp' else [])
            expected = {info.pid: (info.pid, 1000000)}
            if source == 'descendant':
                parent = gate._BSDInfo()
                parent.pid, parent.ppid, parent.pgid, parent.uid, parent.start_sec = 98767, 1, 98767, os.getuid(), 1
                info.ppid = parent.pid
                data['groups'] = [{'pgid': parent.pid, 'start_us': 1000000}]
                gate.process_table = lambda end: {info.pid: info, parent.pid: parent}
                expected[parent.pid] = (parent.pid, 1000000)
            assert gate.Boundary(data, live=True).scan(time.monotonic() + 1) == expected, source + ' was disabled for env-absent work'
            assert data.get('unreadable_excluded', []) == []
    else:
        raw = procargs([b'helper', token], [b'OTHER=' + token, b'TRELLIS_GATE_RUN_ID=exact-suffix'])
        assert token not in gate.parse_environment(raw), 'argv or substring treated as env token'
        assert token in gate.parse_environment(procargs([b'helper'], [token]))
    sys.exit(0)
elif mode == 'aggregate-empty':
    target = fixture / 'empty-aggregate.tsv'
    try:
        gate._write_aggregate(target, [], [])
    except ValueError as exc:
        assert 'empty shard plan' in str(exc)
    else:
        raise AssertionError('aggregate accepted empty expected stages')
    assert not target.exists()
    sys.exit(0)
elif mode == 'eio-env':
    import errno as _errno
    info = gate._BSDInfo()
    info.pid, info.ppid, info.pgid, info.uid, info.status = 98770, 1, 98770, os.getuid(), 2
    gate.bsd_info = lambda pid: info
    class _EIOLibc:
        def sysctl(self, *args):
            gate.ctypes.set_errno(_errno.EIO)
            return -1
    gate._LIBC = _EIOLibc()
    assert gate.process_environment(98770) is None, 'EIO from KERN_PROCARGS2 was not env-absent'
    class _EINVALLibc:
        def sysctl(self, *args):
            gate.ctypes.set_errno(_errno.EINVAL)
            return -1
    gate._LIBC = _EINVALLibc()
    try:
        gate.process_environment(98770)
    except gate.ContainmentError:
        pass
    else:
        raise AssertionError('a non-EIO error on a live process must stay ambiguous')
    sys.exit(0)
elif mode == 'transient-scan':
    import time
    for source in ('identity', 'files', 'environment'):
        calls = []
        def read():
            calls.append(True)
            if len(calls) == 1:
                raise gate.ContainmentError('transient ' + source, errno.EIO)
            return 'reread'
        assert gate._retry_pid(read, time.monotonic() + 1) == 'reread'
        assert len(calls) == 2
    # Exercise the scanner's actual file/env reads, not only the retry helper.
    info = gate._BSDInfo()
    info.pid, info.ppid, info.uid, info.start_sec = 98765, 1, os.getuid(), 1
    data = {'token': 'test', 'owner': {'pid': 98766, 'start_us': 1}, 'started_us': 1,
            'run_root': str(fixture), 'groups': [], 'sentinel_id': {'dev': 42, 'ino': 43}}
    gate.process_table = lambda end: {info.pid: info}
    gate.process_identity = lambda pid: (pid, 1000000)
    for source in ('process_files', 'process_environment'):
        calls = []
        gate.process_files = lambda pid, end: [((42, 43), '/renamed-sentinel')]
        gate.process_environment = lambda pid: None
        original = getattr(gate, source)
        def transient(*args):
            calls.append(True)
            if len(calls) == 1:
                raise gate.ContainmentError('transient scan', errno.EIO)
            return original(*args)
        setattr(gate, source, transient)
        assert gate.Boundary(data).scan(time.monotonic() + 1) == {info.pid: (info.pid, 1000000)}
        assert len(calls) == 2
    # A transient birth read also recovers; permission/exit errors do not retry.
    calls = []
    def identity(pid):
        calls.append(True)
        ctypes.set_errno(errno.EIO if len(calls) == 1 else 0)
        return None if len(calls) == 1 else (pid, 1000000)
    gate.process_identity = identity
    assert gate._scan_identity(info.pid, time.monotonic() + 1) == (info.pid, 1000000)
    assert len(calls) == 2
    for error in (errno.EPERM, errno.EACCES, errno.ESRCH, errno.EIO):
        calls = []
        def failed():
            calls.append(True)
            raise gate.ContainmentError('persistent', error)
        try:
            gate._retry_pid(failed, time.monotonic() + 1)
        except gate.ContainmentError:
            pass
        else:
            raise AssertionError('persistent scan failure forgotten')
        assert len(calls) == (2 if error == errno.EIO else 1)
    sys.exit(0)
elif mode == 'wnowait-support':
    import time
    assert ctypes.sizeof(gate._SigInfo) == 104
    assert gate._SigInfo.addr.offset == 24 and gate._SigInfo.value.offset == 32
    for signum in (None, signal.SIGTERM):
        child = subprocess.Popen([sys.executable, '-c', 'import os; os._exit(7)'] if signum is None
                                 else ['/bin/sleep', '60'])
        if signum is not None:
            os.kill(child.pid, signum)
        try:
            end = time.monotonic() + 2
            observed = []
            while len(observed) < 2 and time.monotonic() < end:
                status = gate.observe_exit(child)
                if status is not None:
                    observed.append(status)
                else:
                    time.sleep(.01)
            expected = 7 if signum is None else -signum
            assert observed == [expected] * 2, 'production observation reaped or misread the leader'
            assert child.returncode is None
            os.kill(child.pid, 0)  # Still allocated; explicit wait must reap it.
        finally:
            child.kill()
            assert child.wait() == expected
    gate._wait_smoke(time.monotonic() + 2)
    sys.exit(0)
elif mode == 'atomic-record':
    import json
    import stat
    import uuid
    state = gate.RunState()
    token = uuid.uuid4().hex
    record = state.runs / (token + '.json')
    events = []
    synced, replaced = gate.os.fsync, gate.os.replace
    def sync(fd):
        events.append('dir-fsync' if stat.S_ISDIR(os.fstat(fd).st_mode) else 'file-fsync')
        return synced(fd)
    def replace(source, destination):
        events.append('replace')
        assert json.loads(Path(source).read_text())['token'] == token
        result = replaced(source, destination)
        assert json.loads(Path(destination).read_text())['token'] == token
        return result
    gate.os.fsync, gate.os.replace = sync, replace
    data = {'token': token, 'groups': []}
    for pgid in (10, 11, 12):
        data['groups'].append({'pgid': pgid, 'start_us': pgid})
        gate.save_record(record, data)
        assert events[-3:] == ['file-fsync', 'replace', 'dir-fsync']
        assert json.loads(record.read_text()) == data
        assert stat.S_IMODE(record.stat().st_mode) == 0o600
    record.unlink()  # Pure serialization fixture: no child was ever launched.
    state.close()
    sys.exit(0)
elif mode == 'permission-error':
    import time
    process = subprocess.Popen(['/bin/sleep', '60'], start_new_session=True)
    original_kill = gate.os.kill
    try:
        identity = gate.process_identity(process.pid)
        assert identity is not None
        def denied(pid, signum):
            raise PermissionError('injected signal denial')
        gate.os.kill = denied
        boundary = gate.Boundary({})
        boundary.scan = lambda end: {process.pid: identity}
        assert boundary.teardown(time.monotonic() + .2, .05) > 0
        assert process.poll() is None, 'denied process was signaled'
    finally:
        gate.os.kill = original_kill
        process.kill()
        process.wait()
    sys.exit(0)
elif mode == 'identity-mismatch':
    process = subprocess.Popen(['/bin/sleep', '60'], start_new_session=True)
    try:
        original = gate.process_identity(process.pid)
        assert original is not None
        # Simulate reuse between the observation and the signal decision.
        gate.process_identity = lambda pid: (pid, original[1] + 1)
        assert not gate.signal_member(original, signal.SIGTERM)
        assert not gate.signal_member(original, signal.SIGKILL)
        assert not gate.signal_member(None, signal.SIGTERM)
        assert process.poll() is None, 'identity-mismatched decoy was signaled'
    finally:
        process.kill()
        process.wait()
    sys.exit(0)
sys.exit(gate.main(sys.argv[3:] if mode == 'hermetic' else []))
PY
}

teardown() {
  local pid
  for pid in "${SIGNAL_WRAPPER_PID:-}" "${OUTER_PID:-}" "${GATE_PID:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done < "$FAKE_CHILD_PIDS"
  # Reap any record deliberately retained by a negative test using real logic.
  env -u FAKE_GATE_MUTATION bash "$REPO_ROOT/scripts/gate-runs.sh" reap >/dev/null 2>&1 || true
  rm -rf "$SANDBOX"
}

run_wrapper() { run python3 "$WRAPPER"; }
run_driver() { run python3 "$SANDBOX/driver.py" "$WRAPPER" "$1"; }

children_dead() {
  local pid
  [ -s "$FAKE_CHILD_PIDS" ] || return 1
  while IFS= read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then return 1; fi
  done < "$FAKE_CHILD_PIDS"
}

assert_empty() {
  [[ "$output" == *"containment=qualified"*"survivors=0 record=deleted"* ]]
  run bash "$REPO_ROOT/scripts/gate-runs.sh" status
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

wait_ready() {
  local attempt
  for ((attempt=0; attempt<300; attempt++)); do
    if [ -s "$FAKE_CHILD_PIDS" ] && [ "$(wc -l < "$FAKE_INVOCATIONS" | tr -d ' ')" -eq 8 ]; then return 0; fi
    sleep 0.02
  done
  return 1
}

start_wrapper() {
  FAKE_MODE=signal python3 "$WRAPPER" > "$SANDBOX/background.out" 2>&1 &
  SIGNAL_WRAPPER_PID=$!
  wait_ready || { cat "$SANDBOX/background.out"; false; }
}

@test "launches exactly eight local shards with distinct receipts and deterministic output" {
  # Inversion: four shards, shared receipts, omitted planner, or reordered replay.
  run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$FAKE_INVOCATIONS" | tr -d ' ')" -eq 8 ]
  [ "$(sort "$SANDBOX/receipts" | uniq | wc -l | tr -d ' ')" -eq 8 ]
  [ "$(wc -l < "$SANDBOX/planner" | tr -d ' ')" -eq 1 ]
  local shard expected=''
  for shard in 1 2 3 4 5 6 7 8; do
    grep -F -- "--scope=local --shard=$shard/8" "$FAKE_INVOCATIONS"
    expected="${expected}fake-shard-$shard"$'\n'
    [[ "$output" == *"shard $shard=100"* ]]
  done
  [[ "$output" == *"${expected%$'\n'}"* ]]
  assert_empty
}

@test "a nested runner does not hand an inherited TRELLIS_TEST_TSV to its planner" {
  # Inversion: keep the caller's TRELLIS_TEST_TSV in the planner environment; the
  # admission helper then treats the planner as a shard and exits 78.
  TRELLIS_TEST_TSV="$SANDBOX/outer-shard-7.tsv" run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$FAKE_INVOCATIONS" | tr -d ' ')" -eq 8 ]
  [ ! -e "$SANDBOX/outer-shard-7.tsv" ]
  assert_empty
}

@test "planner and every shard inherit the supervisor high slot descriptor" {
  # Inversion: Popen close_fds drops the heavy slot lease despite pass_fds for sentinel.
  run_driver heavy-propagation
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$FAKE_INVOCATIONS" | tr -d ' ')" -eq 8 ]
  assert_empty
}

@test "one failing shard fails the aggregate while all eight still run" {
  # Inversion: any passing shard can turn a failure green or stop later shards.
  FAKE_MODE=fail run_wrapper
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [ "$(wc -l < "$FAKE_INVOCATIONS" | tr -d ' ')" -eq 8 ]
  [[ "$output" == *"shard 3/8"*"status=7"*"aggregate receipt:"* ]]
  assert_empty
}

@test "a failing shard keeps its TAP and timing rows after verified-empty teardown" {
  # Inversion (P1h, R40): teardown deletes the failing shard's output with the
  # run root, so naming its failing test costs a full re-run.
  FAKE_MODE=fail run_wrapper
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  local kept
  kept="$(find "$SANDBOX/state/failed-shards" -type f | sort)"
  [ "$(printf '%s\n' "$kept" | wc -l | tr -d ' ')" -eq 2 ] || { echo "$kept"; false; }
  [[ "$kept" == "$SANDBOX/state/failed-shards/"*"/shard-3.out"$'\n'"$SANDBOX/state/failed-shards/"*"/shard-3.tsv" ]]
  grep -qx 'fake-shard-3' "$SANDBOX"/state/failed-shards/*/shard-3.out
  grep -qx $'3\tfake-stage-3\t3\t0' "$SANDBOX"/state/failed-shards/*/shard-3.tsv
  [ "$(stat -f '%Lp' "$SANDBOX"/state/failed-shards/*)" = 700 ]
  [[ "$output" == *"retained failing shard 3/8 output: $SANDBOX/state/failed-shards/"*"/shard-3.out"*"survivors=0 record=deleted"* ]]
  assert_empty
}

@test "a passing run retains no shard output" {
  # Inversion: retention copies every shard, or keeps the run root.
  run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/state/failed-shards" ]
  [[ "$output" != *"retained failing shard"* ]]
  assert_empty
}

@test "reap prunes retained failing-shard output older than seven days" {
  # Inversion (P1h follow-up): retained output grows without bound, or reap
  # also drops fresh evidence.
  local old="$SANDBOX/state/failed-shards/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  local new="$SANDBOX/state/failed-shards/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  mkdir -m 700 "$SANDBOX/state" "$SANDBOX/state/failed-shards" "$old" "$new"
  printf 'not ok 1 old\n' > "$old/shard-1.out"
  printf 'not ok 1 new\n' > "$new/shard-1.out"
  touch -t "$(date -v-8d +%Y%m%d%H%M.%S)" "$old"
  touch -t "$(date -v-1d +%Y%m%d%H%M.%S)" "$new"
  run bash "$REPO_ROOT/scripts/gate-runs.sh" reap
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$old" ]
  grep -qx 'not ok 1 new' "$new/shard-1.out"
}

@test "empty stage plan fails before any shard launches" {
  # Inversion: eight total rows with no stages produce a passing empty gate.
  FAKE_MODE=empty-plan run_wrapper
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"empty shard plan"* ]]
  [ ! -s "$FAKE_INVOCATIONS" ]
  assert_empty
}

@test "aggregate independently rejects empty expected stages" {
  # Inversion: aggregate validation is skipped for an empty expected sequence.
  run_driver aggregate-empty
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "aggregate rejects a missing ordinal" {
  FAKE_MODE=missing-row run_wrapper
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"incomplete receipt"* ]]
  # A red run keeps its receipt as evidence; the exit status still fails.
  [ -s "$TRELLIS_LOCAL_GATE_RECEIPT" ]
  assert_empty
}

@test "aggregate rejects a duplicate ordinal" {
  FAKE_MODE=duplicate-row run_wrapper
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"incomplete receipt"* ]]
  # A red run keeps its receipt as evidence; the exit status still fails.
  [ -s "$TRELLIS_LOCAL_GATE_RECEIPT" ]
  assert_empty
}

@test "aggregate rejects a wrong stage" {
  FAKE_MODE=wrong-stage run_wrapper
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"incomplete receipt"* ]]
  # A red run keeps its receipt as evidence; the exit status still fails.
  [ -s "$TRELLIS_LOCAL_GATE_RECEIPT" ]
  assert_empty
}

@test "aggregate rejects a nonzero row exit even when every shard exits zero" {
  FAKE_MODE=nonzero-row run_wrapper
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"nonzero timing receipt exit"* ]]
  # A red run keeps its receipt as evidence; the exit status still fails.
  [ -s "$TRELLIS_LOCAL_GATE_RECEIPT" ]
  awk -F'\t' 'NR > 1 && $4 != 0 { found = 1 } END { exit !found }' "$TRELLIS_LOCAL_GATE_RECEIPT"
  assert_empty
}

@test "aggregate sorts every single and multiple shard row by global ordinal" {
  # Inversion: shard-order concatenation, duplicate headers, or lost rows.
  local mode count ordinal expected
  for mode in receipt multi-receipt; do
    FAKE_MODE="$mode" run_wrapper
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    count=8; [ "$mode" != multi-receipt ] || count=16
    expected=$'ordinal\tstage\telapsed_seconds\texit'
    for ((ordinal=1; ordinal<=count; ordinal++)); do
      expected="$expected"$'\n'"$ordinal"$'\t'"fake-stage-$ordinal"$'\t'"$ordinal"$'\t0'
    done
    [ "$(cat "$TRELLIS_LOCAL_GATE_RECEIPT")" = "$expected" ]
    assert_empty
  done
}

@test "normal success kills a leaderless env-i child by registered group alone" {
  # Inversion: completed_normally skips cleanup or env-i defeats group ownership.
  FAKE_MODE=group run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  children_dead
  assert_empty
}

@test "normal success kills a setsid orphan holding only the inherited sentinel" {
  # Inversion: pass_fds omitted or a new session escapes the sentinel scan.
  FAKE_MODE=sentinel run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  children_dead
  assert_empty
}

@test "normal success kills a double-fork orphan with only private-root cwd" {
  # Inversion: closed fds/cleared env/new session escape cwd ownership.
  FAKE_MODE=cwd run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  children_dead
  assert_empty
}

@test "normal success kills a detached child with only a private-root open file" {
  # Inversion: scanning cwd only misses an open-file holder that chdir'd away.
  FAKE_MODE=open-file run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  children_dead
  assert_empty
}

@test "environment token finds a tty-less orphan with no fd cwd group or parent signal" {
  # Inversion: bare ps eww only scans terminal processes, or token is ignored.
  FAKE_MODE=environment run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  children_dead
  assert_empty
}

@test "TERM-ignoring child is KILLed before success and slot release" {
  # Inversion: TERM-only teardown reports success while the child remains live.
  FAKE_MODE=ignore-term run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  children_dead
  assert_empty
}

@test "a child forked during TERM grace is caught by rescans" {
  # Inversion: a single initial snapshot misses newly forked work.
  FAKE_MODE=fork-term run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$FAKE_CHILD_PIDS" | tr -d ' ')" -ge 2 ]
  children_dead
  assert_empty
}

@test "ppid descendants with all four other signals removed are killed on timeout" {
  # Inversion: removing descendant expansion leaves the stripped child live.
  export TRELLIS_LOCAL_GATE_DEADLINE=4 TRELLIS_LOCAL_GATE_RESERVE=2
  FAKE_MODE=descendant run_wrapper
  [ "$status" -eq 124 ] || { echo "$output"; false; }
  children_dead
  assert_empty
}

@test "planner hang and detached planner child share the deadline and teardown" {
  # Inversion: unbounded planning, planner in caller group, or unowned descendants.
  export TRELLIS_LOCAL_GATE_DEADLINE=4 TRELLIS_LOCAL_GATE_RESERVE=2
  FAKE_MODE=planner-hang run_wrapper
  [ "$status" -eq 124 ] || { echo "$output"; false; }
  [[ "$output" == *"global deadline exceeded"* ]]
  [ ! -s "$FAKE_INVOCATIONS" ]
  children_dead
  assert_empty
}

@test "interrupt between Popen and registration cannot leak an in-flight child" {
  # Inversion: unblocking INT before durable registration loses the spawned child.
  export FAKE_MODE=ignore-term
  run_driver interrupt-spawn
  [ "$status" -eq 130 ] || { echo "$output"; false; }
  # Popen may be interrupted before the helper execs; emptiness is structural.
  [ ! -e "$TRELLIS_LOCAL_GATE_RECEIPT" ]
  assert_empty
}

@test "partial spawn and exec failure fail without leaving started work" {
  # Inversion: an unstarted shard / exec 127 becomes a complete passing receipt.
  export FAKE_MODE=ignore-term
  run_driver partial-spawn
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"shard 3/8"*"status=127"* ]]
  children_dead
  assert_empty
  FAKE_MODE=exec-fail run_wrapper
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  assert_empty
}

@test "SIGINT and SIGTERM preserve 130 and 143 after verified-empty teardown" {
  # Inversion: handled signals return success, wrong class, or leave descendants.
  local sig rc
  for sig in INT TERM; do
    : > "$FAKE_INVOCATIONS"; : > "$FAKE_CHILD_PIDS"
    start_wrapper
    kill "-$sig" "$SIGNAL_WRAPPER_PID"
    rc=0; wait "$SIGNAL_WRAPPER_PID" || rc=$?
    [ "$sig" != INT ] || [ "$rc" -eq 130 ]
    [ "$sig" != TERM ] || [ "$rc" -eq 143 ]
    children_dead
    output="$(cat "$SANDBOX/background.out")"
    assert_empty
    SIGNAL_WRAPPER_PID=''
  done
}

@test "SIGKILL retains a durable record and next admission reaps it before proceeding" {
  # Inversion: dead runner releases slot, record was not durable, or start skips reap.
  start_wrapper
  python3 - "$TRELLIS_GATE_STATE_DIR" <<'PY'
import json, os, stat, sys
from pathlib import Path
runs = Path(sys.argv[1]) / 'runs'
assert stat.S_IMODE(runs.stat().st_mode) == 0o700
records = list(runs.glob('*.json'))
assert len(records) == 1
record = records[0]
assert stat.S_IMODE(record.stat().st_mode) == 0o600
data = json.loads(record.read_text())
assert len(data['groups']) == 9  # planner plus eight shards
assert data['run_root'] == os.path.realpath(data['run_root'])
assert data['sentinel'] == os.path.realpath(data['sentinel'])
assert len(data['head']) == 40
PY
  kill -KILL "$SIGNAL_WRAPPER_PID"
  local rc=0
  wait "$SIGNAL_WRAPPER_PID" || rc=$?
  [ "$rc" -eq 137 ]
  SIGNAL_WRAPPER_PID=''
  run bash "$REPO_ROOT/scripts/gate-runs.sh" status
  [ "$status" -eq 1 ]
  [[ "$output" == *".json"* ]]
  run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$FAKE_INVOCATIONS" | tr -d ' ')" -eq 16 ]
  children_dead
  assert_empty
}

@test "live owner quarantines admission and explicit reap without launching another planner" {
  # Inversion: owner-alive record is reaped or permits double booking.
  start_wrapper
  run_wrapper
  [ "$status" -eq 70 ] || { echo "$output"; false; }
  [[ "$output" == *".json"* ]]
  [ "$(wc -l < "$SANDBOX/planner" | tr -d ' ')" -eq 1 ]
  run bash "$REPO_ROOT/scripts/gate-runs.sh" reap
  [ "$status" -eq 70 ]
  run bash "$REPO_ROOT/scripts/gate-runs.sh" status
  [ "$status" -eq 1 ]
  kill -TERM "$SIGNAL_WRAPPER_PID"
  wait "$SIGNAL_WRAPPER_PID" || [ "$?" -eq 143 ]
  SIGNAL_WRAPPER_PID=''
  children_dead
}

@test "synthetic supervisor and coordinator wrapper deaths do not release durable quarantine" {
  # Inversion: wrapper/holder death is mistaken for gate-owned boundary emptiness.
  local role
  for role in supervisor coordinator; do
    : > "$FAKE_INVOCATIONS"; : > "$FAKE_CHILD_PIDS"
    FAKE_MODE=signal bash -c 'python3 "$1" & echo "$!" > "$2"; wait' \
      "$role" "$WRAPPER" "$SANDBOX/runner.pid" > "$SANDBOX/outer.out" 2>&1 &
    OUTER_PID=$!
    wait_ready || { cat "$SANDBOX/outer.out"; false; }
    GATE_PID="$(cat "$SANDBOX/runner.pid")"
    kill -KILL "$OUTER_PID"
    wait "$OUTER_PID" || [ "$?" -eq 137 ]
    OUTER_PID=''
    run bash "$REPO_ROOT/scripts/gate-runs.sh" status
    [ "$status" -eq 1 ]
    run_wrapper
    [ "$status" -eq 70 ]
    kill -KILL "$GATE_PID"
    # Orphan reaping is asynchronous; reap refuses a live owner until it dies.
    local attempt
    for ((attempt=0; attempt<100; attempt++)); do
      kill -0 "$GATE_PID" 2>/dev/null || break
      sleep 0.02
    done
    GATE_PID=''
    run bash "$REPO_ROOT/scripts/gate-runs.sh" reap
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    children_dead
    run bash "$REPO_ROOT/scripts/gate-runs.sh" status
    [ "$status" -eq 0 ]
  done
}

@test "unkillable and identity-ambiguous members return 71 and retain quarantine" {
  # Inversion: failed/ambiguous signal decisions are counted as verified empty.
  local mode
  export TRELLIS_LOCAL_GATE_DEADLINE=6 TRELLIS_LOCAL_GATE_RESERVE=1
  export FAKE_MODE=ignore-term
  for mode in unkillable ambiguous; do
    : > "$FAKE_CHILD_PIDS"
    run_driver "$mode"
    [ "$status" -eq 71 ] || { echo "$output"; false; }
    [[ "$output" == *"record=retained"* ]]
    [ -s "$FAKE_CHILD_PIDS" ]
    ! children_dead
    run bash "$REPO_ROOT/scripts/gate-runs.sh" status
    [ "$status" -eq 1 ]
    run bash "$REPO_ROOT/scripts/gate-runs.sh" reap
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    children_dead
  done
}

@test "corrupt run record is named and quarantined by status reap and next start" {
  # Inversion: corrupt JSON is skipped, deleted, or crashes instead of refusing.
  mkdir -p "$TRELLIS_GATE_STATE_DIR/runs"
  chmod 700 "$TRELLIS_GATE_STATE_DIR" "$TRELLIS_GATE_STATE_DIR/runs"
  local record="$TRELLIS_GATE_STATE_DIR/runs/00000000000000000000000000000000.json"
  printf '{truncated\n' > "$record"; chmod 600 "$record"
  run bash "$REPO_ROOT/scripts/gate-runs.sh" status
  [ "$status" -eq 70 ]; [[ "$output" == *"$record"* ]]
  run bash "$REPO_ROOT/scripts/gate-runs.sh" reap
  [ "$status" -eq 70 ]; [[ "$output" == *"$record"* ]]
  run_wrapper
  [ "$status" -eq 70 ]; [[ "$output" == *"$record"* ]]
  [ -e "$record" ]; [ ! -s "$FAKE_INVOCATIONS" ]; [ ! -e "$SANDBOX/planner" ]
  [[ "$output" != *Traceback* ]]
}

@test "capability failures return 70 before any child is launched" {
  # Inversion: absent libproc, unsafe root/sentinel, or unusable state launch work.
  local mode
  run_driver no-libproc
  [ "$status" -eq 70 ]; [[ "$output" == *"libproc"* ]]
  for mode in no-identity missing-waitid failed-waitid bad-root bad-sentinel; do
    run_driver "$mode"
    [ "$status" -eq 70 ] || { echo "$output"; false; }
    case "$mode" in
      no-identity) [[ "$output" == *"birth identity unavailable"* ]] ;;
      missing-waitid|failed-waitid) [[ "$output" == *"libc waitid WNOWAIT smoke test failed"* ]] ;;
      bad-root) [[ "$output" == *"not owner-private"* ]] ;;
      bad-sentinel) [[ "$output" == *"synthetic sentinel failure"* ]] ;;
    esac
    [ ! -s "$FAKE_INVOCATIONS" ]; [ ! -e "$SANDBOX/planner" ]
  done
  printf unusable > "$SANDBOX/not-directory"
  run env TRELLIS_GATE_STATE_DIR="$SANDBOX/not-directory" python3 "$WRAPPER"
  [ "$status" -eq 70 ]; [ ! -s "$FAKE_INVOCATIONS" ]; [ ! -e "$SANDBOX/planner" ]
}

@test "native admission uses production libc waitid without a test-only adapter" {
  # Inversion: admission still depends on os.waitid or the fixture-only namespace.
  run "$FAKE_REAL_PYTHON" "$WRAPPER"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$FAKE_INVOCATIONS" | tr -d ' ')" -eq 8 ]
  assert_empty
}

@test "real-host platform sleep orphan with only shard stdout is torn down" {
  # Inversion: close_fds plus setsid plus env-absent escapes the output signal.
  FAKE_MODE=shard-out run "$FAKE_REAL_PYTHON" "$WRAPPER"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  children_dead
  [[ "$output" == *"unreadable_excluded=0"* ]]
  assert_empty
}

@test "every configured runner seam is announced on stderr including empty unknown seams" {
  # Inversion: test-only overrides can silently weaken a production invocation.
  export TRELLIS_LOCAL_GATE_UNKNOWN='' TRELLIS_LOCAL_GATE_EXTRA=value
  run bash -c 'python3 "$1" > "$2" 2> "$3"' seams "$WRAPPER" "$SANDBOX/stdout" "$SANDBOX/stderr"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local name
  for name in TRELLIS_LOCAL_GATE_RUNNER TRELLIS_LOCAL_GATE_RECEIPT TRELLIS_LOCAL_GATE_DEADLINE TRELLIS_LOCAL_GATE_RESERVE TRELLIS_LOCAL_GATE_TERM_GRACE TRELLIS_GATE_STATE_DIR TRELLIS_LOCAL_GATE_UNKNOWN TRELLIS_LOCAL_GATE_EXTRA; do
    grep -Fx "run-tests-local: seam active $name=${!name}" "$SANDBOX/stderr"
    ! grep -F "seam active $name=" "$SANDBOX/stdout"
  done
}

@test "deadline seam may shorten but cannot extend the authorized 7200 seconds" {
  local value
  for value in 7200.001 20000; do
    TRELLIS_LOCAL_GATE_DEADLINE="$value" run_wrapper
    [ "$status" -eq 64 ] || { echo "$output"; false; }
    [[ "$output" == *"must not exceed 7200"* ]]
    [ ! -s "$FAKE_INVOCATIONS" ]; [ ! -e "$SANDBOX/planner" ]
  done
  TRELLIS_LOCAL_GATE_DEADLINE=7200 run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_empty
}

@test "backwards wall clock uses a safer birth bound and records clock_step" {
  run_driver clock-step
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"clock_step=1"* ]]
}

@test "EIO from KERN_PROCARGS2 on a live process is env-absent, other errors stay ambiguous" {
  # Inversion: EIO (exec or exit in progress) raises ContainmentError and turns a
  # clean gate into a spurious 71, as gate 2 at 9f6621af recorded under load.
  run_driver eio-env
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "transient per-pid scan errors get exactly one bounded retry" {
  run_driver transient-scan
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "pre-run file holders are excluded from every signal and capability preflight" {
  # Inversion: a pre-run process holding a tmp file becomes owned or is queried.
  run_driver preexisting
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "unreadable in-run processes are excluded counted listed and never fail the gate" {
  # Inversions: treating an unreadable unrelated process as owned, or refusing it.
  local mode
  for mode in unreadable-files unreadable-environment unreadable-preflight-files unreadable-preflight-environment; do
    run_driver "$mode"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"unreadable_excluded pid="*'executable="/bin/sleep"'* ]]
    [[ "$output" == *"survivors=0 record=deleted unreadable_excluded=1"* ]]
    assert_empty
  done
}

@test "birth mismatch and unavailable identity never signal a foreign decoy" {
  # Inversion: PID-only TERM/KILL signals the still-live decoy despite changed birth.
  run_driver identity-mismatch
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "PermissionError on signal remains ambiguity and cannot release a slot" {
  # Inversion: a denied kill is ignored and counted as successful empty teardown.
  run_driver permission-error
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "empty boundary returns immediately without sleeping through TERM grace" {
  # Inversion: unconditional five-second sleep even when the first scan is empty.
  run_driver fast-empty
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "host WNOWAIT observes an exit twice and retains the zombie until explicit reap" {
  # Inversion: exit observation consumes the leader and permits PGID reuse.
  run_driver wnowait-support
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "every run-record update atomically replaces and fsyncs file and directory" {
  # Inversion: truncating/in-place appends or missing fsync publish corrupt quarantine.
  run_driver atomic-record
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "foreign structural-only matches are ambiguous and never signaled" {
  # Inversion: operator tail/cwd work with a live foreign parent is killed.
  run_driver foreign-guard
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "live foreign output holder is never signaled and exits 71 with quarantine" {
  export TRELLIS_LOCAL_GATE_RESERVE=0.5
  run_driver foreign-output
  [ "$status" -eq 71 ] || { echo "$output"; false; }
  [[ "$output" == *"survivors=1 record=retained"* ]]
  run bash "$REPO_ROOT/scripts/gate-runs.sh" status
  [ "$status" -eq 1 ]
  run bash "$REPO_ROOT/scripts/gate-runs.sh" reap
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "own PID ancestors and other UIDs cannot become boundary members" {
  # Inversion: structural signals grant authority over the runner, its parent, or another UID.
  run_driver uid-exclusion
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run_driver ancestor-exclusion
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "stale sweeps ignore group IDs and earlier-boot records send no signal" {
  # Inversion: stale/reboot PGID reuse grants authority over a new foreign process.
  run_driver stale-group
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run_driver earlier-boot
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run_driver earlier-boot-unsafe
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "pinned output holders are owned as orphans and ambiguous with live foreign parents" {
  # Inversion: output holders escape, paths alone match, or the worktree cwd owns work.
  run_driver outside-tmp
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "post-launch scan failures stay ambiguous even after later empty scans" {
  # Inversion: transient enumeration failure is forgotten and produces a green exit.
  run_driver scan-failure
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "platform argv-only response is env-absent not unreadable or listed" {
  run_driver env-absent
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run_driver outside-tmp
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "empty argv zero preserves the first environment entry" {
  run_driver empty-argv
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "environment parsing matches only exact entries after argv" {
  # Inversion: an argv token or another variable's token substring grants ownership.
  run_driver exact-env
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "receipt write stall is bounded by the same productive deadline" {
  # Inversion: clock stops when shards exit, allowing finalization to hang/pass.
  export TRELLIS_LOCAL_GATE_DEADLINE=4 TRELLIS_LOCAL_GATE_RESERVE=2
  mkfifo "$TRELLIS_LOCAL_GATE_RECEIPT"
  run_wrapper
  [ "$status" -eq 124 ] || { echo "$output"; false; }
  [ "$(wc -l < "$FAKE_INVOCATIONS" | tr -d ' ')" -eq 8 ]
  assert_empty
}

@test "invalid runner and gate-runs arguments return 64 before launch" {
  # Inversion: unknown options silently run a gate or weaken its scope.
  run python3 "$WRAPPER" --not-a-real-option
  [ "$status" -eq 64 ]; [ ! -s "$FAKE_INVOCATIONS" ]
  run bash "$REPO_ROOT/scripts/gate-runs.sh" status extra
  [ "$status" -eq 64 ]
}

@test "run-tests list is receipt-free and eight shards partition the complete inventory" {
  # Inversion: list executes tests, omits stages, overlaps shards, or writes a receipt.
  local shard combined="$SANDBOX/combined" baseline="$SANDBOX/baseline"
  run env -u TRELLIS_STAGE_WEIGHTS_TSV TRELLIS_TEST_TSV="$SANDBOX/list.tsv" \
    bash "$REPO_ROOT/scripts/run-tests.sh" --scope=local --shard=1/1 --list
  [ "$status" -eq 0 ]; [ ! -e "$SANDBOX/list.tsv" ]
  [ ! -e "$SANDBOX/list.tsv.provenance.jsonl" ]
  [[ "$output" == *"shellcheck (CI scope, severity=warning)"* ]]
  printf '%s\n' "$output" | sort > "$baseline"
  : > "$combined"
  for shard in 1 2 3 4 5 6 7 8; do
    run env -u TRELLIS_STAGE_WEIGHTS_TSV TRELLIS_TEST_TSV="$SANDBOX/list-$shard.tsv" \
      bash "$REPO_ROOT/scripts/run-tests.sh" --scope=local --shard="$shard/8" --list
    [ "$status" -eq 0 ]; [ ! -e "$SANDBOX/list-$shard.tsv" ]; [ -n "$output" ]
    [ ! -e "$SANDBOX/list-$shard.tsv.provenance.jsonl" ]
    printf '%s\n' "$output" >> "$combined"
  done
  [ "$(sort "$combined")" = "$(cat "$baseline")" ]
  [ "$(sort "$combined" | uniq -d | wc -l | tr -d ' ')" -eq 0 ]
}

@test "eight-way plan accounts for all shipped weight and defaults a missing stage to 30" {
  # Inversion: wrong shard count, weight loss, or missing weight silently drops a stage.
  local plan="$SANDBOX/plan" weights="$SANDBOX/weights" missing expected
  expected="$(awk -F '\t' 'NR>1 {sum+=$2} END {print sum+0}' "$REPO_ROOT/scripts/tests/stage-weights.tsv")"
  run env -u TRELLIS_STAGE_WEIGHTS_TSV TRELLIS_TEST_TSV="$SANDBOX/plan-receipt" \
    bash "$REPO_ROOT/scripts/run-tests.sh" --scope=local --shard=1/8 --plan
  [ "$status" -eq 0 ]; [ ! -e "$SANDBOX/plan-receipt" ]
  printf '%s\n' "$output" > "$plan"
  [ "${lines[0]}" = $'shard\tstage\tweight' ]
  awk -F '\t' -v expected="$expected" '$1~/^[0-9]+$/ {stagesum+=$3} $1=="total" {count++; sum+=$3; if ($3>max) max=$3} END {exit !(count==8 && sum==stagesum && 2*max<=expected)}' "$plan"
  missing="$(awk -F '\t' 'NR==2 {print $1; exit}' "$REPO_ROOT/scripts/tests/stage-weights.tsv")"
  awk -F '\t' -v missing="$missing" 'NR==1 || $1!=missing' "$REPO_ROOT/scripts/tests/stage-weights.tsv" > "$weights"
  run env TRELLIS_STAGE_WEIGHTS_TSV="$weights" \
    bash "$REPO_ROOT/scripts/run-tests.sh" --scope=local --shard=1/8 --plan
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$plan"
  awk -F '\t' -v missing="$missing" '$1~/^[0-9]+$/ && $2==missing {count++; if ($3!=30) wrong=1} END {exit !(count==1 && !wrong)}' "$plan"
}

@test "every FAKE_GATE_MUTATION turns its targeted test red" {
  # Inversion: passing originals with unexercised mutation seams proves nothing.
  local mutation target count=0
  local table="$SANDBOX/mutation-targets"
  cat > "$table" <<'TABLE'
group|normal success kills a leaderless env-i child by registered group alone
sentinel|normal success kills a setsid orphan holding only the inherited sentinel
file|normal success kills a detached child with only a private-root open file
output|pinned output holders are owned as orphans and ambiguous with live foreign parents
output-registration|launches exactly eight local shards with distinct receipts and deterministic output
env-absent|platform argv-only response is env-absent not unreadable or listed
environment|environment token finds a tty-less orphan with no fd cwd group or parent signal
descendants|ppid descendants with all four other signals removed are killed on timeout
kill|TERM-ignoring child is KILLed before success and slot release
term-first|a child forked during TERM grace is caught by rescans
identity|birth mismatch and unavailable identity never signal a foreign decoy
foreign|foreign structural-only matches are ambiguous and never signaled
empty|empty boundary returns immediately without sleeping through TERM grace
atomic|every run-record update atomically replaces and fsyncs file and directory
corrupt|corrupt run record is named and quarantined by status reap and next start
deadline|planner hang and detached planner child share the deadline and teardown
shards|launches exactly eight local shards with distinct receipts and deterministic output
aggregate|aggregate sorts every single and multiple shard row by global ordinal
empty-plan|empty stage plan fails before any shard launches
aggregate-empty|aggregate independently rejects empty expected stages
aggregate-missing|aggregate rejects a missing ordinal
aggregate-duplicate|aggregate rejects a duplicate ordinal
aggregate-stage|aggregate rejects a wrong stage
aggregate-exit|aggregate rejects a nonzero row exit even when every shard exits zero
replay|launches exactly eight local shards with distinct receipts and deterministic output
failure|one failing shard fails the aggregate while all eight still run
state|launches exactly eight local shards with distinct receipts and deterministic output
heavy|planner and every shard inherit the supervisor high slot descriptor
preexisting|pre-run file holders are excluded from every signal and capability preflight
clock|backwards wall clock uses a safer birth bound and records clock_step
retry|transient per-pid scan errors get exactly one bounded retry
empty-argv|empty argv zero preserves the first environment entry
earlier-boot-root|stale sweeps ignore group IDs and earlier-boot records send no signal
unreadable-member|unreadable in-run processes are excluded counted listed and never fail the gate
unreadable-fail|unreadable in-run processes are excluded counted listed and never fail the gate
wait-reap|host WNOWAIT observes an exit twice and retains the zombie until explicit reap
registration|launches exactly eight local shards with distinct receipts and deterministic output
TABLE
  # Keep the loop exhaustive when the injection dictionary changes.
  python3 - "$SANDBOX/driver.py" "$table" <<'PY'
import ast
from pathlib import Path
import sys
module = ast.parse(Path(sys.argv[1]).read_text())
mutations = next(node.value for node in ast.walk(module) if isinstance(node, ast.Assign)
                 and any(isinstance(target, ast.Name) and target.id == 'mutations' for target in node.targets))
keys = [key.value for key in mutations.keys]
rows = Path(sys.argv[2]).read_text().splitlines()
targets = [row.split('|', 1)[0] for row in rows]
assert len(targets) == len(set(targets)) and set(targets) == set(keys), 'mutation targets are not exhaustive'
PY
  while IFS='|' read -r mutation target; do
    rm -f "$SANDBOX/landed"
    run env FAKE_GATE_MUTATION="$mutation" FAKE_GATE_MUTATION_LOG="$SANDBOX/landed" bats --filter "^$target$" "$BATS_TEST_FILENAME"
    # A mutation that never lands also exits 1; require proof it was applied.
    grep -qx -- "$mutation" "$SANDBOX/landed" || { echo "mutation $mutation never landed: $output"; false; }
    [ "$status" -eq 1 ] || { echo "mutation $mutation did not turn its target red: $output"; false; }
    [[ "$output" == *"not ok 1 "* ]] || { echo "mutation $mutation did not execute its target: $output"; false; }
    [[ "$output" != *"mutation must change exactly one production site"* && "$output" != *"mutation did not land"* ]] || { echo "$output"; false; }
    count=$((count + 1))
    printf 'mutation=%s targeted_test=red\n' "$mutation"
  done < "$table"
  [ "$count" -eq 37 ]
}

inventory_fixture() {
  local i
  # Fixture repositories must live inside the suite runner's git-mutation
  # fence or every git init is refused. The ownership-boundary tests need
  # SANDBOX itself under /tmp, so only this git fixture moves — and only
  # when the fence is active.
  if [ -n "${TRELLIS_TEST_GIT_FENCE_ROOT:-}" ]; then
    GIT_FIXTURE="$TRELLIS_TEST_GIT_FENCE_ROOT/git-fixture"
  else
    GIT_FIXTURE="$SANDBOX/git-fixture"
  fi
  local fixture="$GIT_FIXTURE"
  rm -rf "$fixture"
  mkdir -p "$fixture/scripts/tests"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name Fixture
  git -C "$fixture" config user.email fixture@trellis.invalid
  git -C "$fixture" config commit.gpgsign false
  cat > "$fixture/scripts/run-tests.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = --scope=local ] && [ "$2" = --list ] || exit 64
printf 'static stage\n'
for suite in scripts/tests/*.bats; do printf 'bats %s\n' "$suite"; done
SH
  # Snapshot executes from its own root; this fixture also follows that contract.
  local script="$fixture/scripts/run-tests.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'cd "$(dirname "$0")/.." || exit 1' > "$fixture/scripts/prefix"
  tail -n +2 "$script" >> "$fixture/scripts/prefix"
  mv "$fixture/scripts/prefix" "$script"
  printf '#!/usr/bin/env bats\n# shared fixture\nsetup() { true; }\n' > "$SANDBOX/common"
  if [ "${FIXTURE_SETUP_FILE:-0}" = 1 ]; then printf 'setup_file() { true; }\n' >> "$SANDBOX/common"; fi
  cp "$SANDBOX/common" "$fixture/scripts/tests/doctor-fix.bats"
  for i in 1 2 3 4; do printf '@test "test %s" {\n  true\n}\n' "$i"; done >> "$fixture/scripts/tests/doctor-fix.bats"
  if [ "${FIXTURE_PAYLOAD_SCAN:-0}" = 1 ]; then
    printf "#!/usr/bin/env bats\nSCAN_EXEMPT_PAIRS='core-rules/hooks/lib/spec-gate-core.sh|specs/\ntrellis.config.json|specs/'\n" > "$fixture/scripts/tests/release-payload-commit.bats"
  fi
  mkdir -p "$fixture/.claude/skills/process-gate-local"
  printf 'PROCESS_GATE_TEST_CMD="python3 scripts/run-tests-local.py"\nPROCESS_GATE_TEST_TIMEOUT="${PROCESS_GATE_TEST_TIMEOUT:-3660}"\n' > "$fixture/.claude/skills/process-gate-local/local.config.sh"
  git -C "$fixture" add .; git -C "$fixture" commit -qm 'test: base'
  BASE="$(git -C "$fixture" rev-parse HEAD)"
  rm "$fixture/scripts/tests/doctor-fix.bats"
  cp "$SANDBOX/common" "$fixture/scripts/tests/doctor-fix-common.bash"
  for i in 1 2 3 4; do
    { printf '#!/usr/bin/env bats\nload doctor-fix-common\n'; printf '@test "test %s" {\n  true\n}\n' "$i"; } > "$fixture/scripts/tests/doctor-fix-part$i.bats"
  done
  git -C "$fixture" add .; git -C "$fixture" commit -qm 'test: split'
  HEAD_SHA="$(git -C "$fixture" rev-parse HEAD)"
  printf 'ordinal\tstage\telapsed_seconds\texit\n1\tstatic stage\t1\t0\n' > "$SANDBOX/inventory.tsv"
  for i in 1 2 3 4; do printf '%s\tbats scripts/tests/doctor-fix-part%s.bats\t1\t0\n' "$((i+1))" "$i"; done >> "$SANDBOX/inventory.tsv"
}

check_inventory() {
  run bash -c 'cd "$1" && bash "$2/scripts/check-gate-inventory.sh" "$3" "$4" "$5"' \
    fixture "$GIT_FIXTURE" "$REPO_ROOT" "$BASE" "$HEAD_SHA" "$SANDBOX/inventory.tsv"
}

@test "immutable inventory equivalence passes the exact four-part split" {
  # Inversion: wrong ordinal/stage mapping, base read from dirty checkout, or lost names.
  inventory_fixture
  # Poison the working copy: only immutable git-show inputs may count.
  printf '@test "dirty decoy" { true; }\n' > "$GIT_FIXTURE/scripts/tests/doctor-fix-part1.bats"
  check_inventory
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == "inventory: PASS "* ]]
}

@test "inventory rejects missing duplicate nonzero and changed stages" {
  # Inversion: counts-only validation accepts equal-size replacements or duplicates.
  inventory_fixture
  cp "$SANDBOX/inventory.tsv" "$SANDBOX/good.tsv"
  local mode
  for mode in missing duplicate nonzero changed; do
    python3 - "$SANDBOX/good.tsv" "$SANDBOX/inventory.tsv" "$mode" <<'PY'
from pathlib import Path
import sys
rows = Path(sys.argv[1]).read_text().splitlines()
mode = sys.argv[3]
if mode == 'missing': rows.pop()
if mode == 'duplicate': rows[-1] = rows[-2]
if mode == 'nonzero': rows[-1] = rows[-1][:-1] + '7'
if mode == 'changed': rows[-1] = rows[-1].replace('part4', 'decoy')
Path(sys.argv[2]).write_text('\n'.join(rows) + '\n')
PY
    check_inventory
    [ "$status" -ne 0 ] || { echo "$mode incorrectly passed"; false; }
    [[ "$output" == "inventory: FAIL "* ]]
  done
}

@test "inventory rejects changed doctor test multiset with the same count" {
  # Inversion: equal name counts conceal a removed assertion identity/replacement.
  inventory_fixture
  printf '@test "test 1" {\n true\n}\n' > "$GIT_FIXTURE/scripts/tests/doctor-fix-part4.bats"
  git -C "$GIT_FIXTURE" add .; git -C "$GIT_FIXTURE" commit -qm 'test: changed names'
  HEAD_SHA="$(git -C "$GIT_FIXTURE" rev-parse HEAD)"
  check_inventory
  [ "$status" -ne 0 ]; [[ "$output" == *"@test name multiset changed"* ]]
}

@test "inventory protects the process-gate tree and timeout-only configuration" {
  # Inversion: changing gate assertions or replacing the test command can self-pass.
  local mode fixture
  for mode in gate config; do
    inventory_fixture
    fixture="$GIT_FIXTURE"
    if [ "$mode" = gate ]; then
      mkdir -p "$fixture/core-rules/skills/process-gate"
      printf weakened > "$fixture/core-rules/skills/process-gate/check.sh"
    else
      printf 'PROCESS_GATE_TEST_CMD=":"\nPROCESS_GATE_TEST_TIMEOUT="${PROCESS_GATE_TEST_TIMEOUT:-7260}"\n' > "$fixture/.claude/skills/process-gate-local/local.config.sh"
    fi
    git -C "$fixture" add .; git -C "$fixture" commit -qm "test: changed $mode"
    HEAD_SHA="$(git -C "$fixture" rev-parse HEAD)"
    check_inventory
    [ "$status" -ne 0 ]
    if [ "$mode" = gate ]; then
      [[ "$output" == *"protected process-gate path changed"* ]]
    else
      [[ "$output" == *"changed beyond the timeout default"* ]]
    fi
    mv "$fixture" "$SANDBOX/fixture-$mode"
  done
}

@test "inventory permits only the timeout default and documented comment refresh" {
  # Inversion: a legitimate 7260 default is rejected or an unrelated config edit passes.
  inventory_fixture
  printf '# Updated deadline documentation\nPROCESS_GATE_TEST_CMD="python3 scripts/run-tests-local.py"\nPROCESS_GATE_TEST_TIMEOUT="${PROCESS_GATE_TEST_TIMEOUT:-7260}"\n' > "$GIT_FIXTURE/.claude/skills/process-gate-local/local.config.sh"
  git -C "$GIT_FIXTURE" add .; git -C "$GIT_FIXTURE" commit -qm 'test: timeout default'
  HEAD_SHA="$(git -C "$GIT_FIXTURE" rev-parse HEAD)"
  check_inventory
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "inventory proves common content and test block bytes rather than names alone" {
  # Inversion: helper changes or weaker bodies with unchanged names are accepted.
  local mode fixture
  for mode in common blocks loader; do
    inventory_fixture
    fixture="$GIT_FIXTURE"
    case "$mode" in
      common) printf '# changed helper\n' >> "$fixture/scripts/tests/doctor-fix-common.bash" ;;
      blocks) printf '#!/usr/bin/env bats\nload doctor-fix-common\n@test "test 4" {\n  false\n}\n' > "$fixture/scripts/tests/doctor-fix-part4.bats" ;;
      loader) printf 'setup_file() { true; }\n' >> "$fixture/scripts/tests/doctor-fix-part4.bats" ;;
    esac
    git -C "$fixture" add .; git -C "$fixture" commit -qm "test: changed $mode"
    HEAD_SHA="$(git -C "$fixture" rev-parse HEAD)"
    check_inventory
    [ "$status" -ne 0 ]
    case "$mode" in
      common) [[ "$output" == *"differs from original non-test content"* ]] ;;
      blocks) [[ "$output" == *"blocks changed byte-for-byte"* ]] ;;
      loader) [[ "$output" == *"unexpected doctor-fix part non-test content"* ]] ;;
    esac
    mv "$fixture" "$SANDBOX/fixture-$mode"
  done
}

@test "inventory refuses setup_file semantics and changes to unrelated existing test files" {
  # Inversion: per-file lifecycle changes or out-of-scope assertion edits self-pass.
  FIXTURE_SETUP_FILE=1 inventory_fixture
  check_inventory
  [ "$status" -ne 0 ]; [[ "$output" == *"uses setup_file/teardown_file"* ]]
  mv "$GIT_FIXTURE" "$SANDBOX/setup-file-fixture"
  inventory_fixture
  mkdir -p "$GIT_FIXTURE/core-rules/hooks/tests"
  printf '@test "weakened" { true; }\n' > "$GIT_FIXTURE/core-rules/hooks/tests/changed.bats"
  git -C "$GIT_FIXTURE" add .; git -C "$GIT_FIXTURE" commit -qm 'test: unrelated assertions'
  HEAD_SHA="$(git -C "$GIT_FIXTURE" rev-parse HEAD)"
  check_inventory
  [ "$status" -ne 0 ]; [[ "$output" == *"test file outside the split changed"* ]]
}

@test "inventory allows the release-payload scan to change only by the checker's one-prefix pair" {
  # Inversion: allow the whole release-payload test file, so a weakened A3.3 scan passes.
  FIXTURE_PAYLOAD_SCAN=1 inventory_fixture
  local scan="$GIT_FIXTURE/scripts/tests/release-payload-commit.bats"
  printf '6\tbats scripts/tests/release-payload-commit.bats\t1\t0\n' >> "$SANDBOX/inventory.tsv"
  sed -i '' "s#^SCAN_EXEMPT_PAIRS='core-rules/hooks/lib/spec-gate-core.sh|specs/\$#&\\
scripts/check-gate-inventory.sh|scripts/tests/#" "$scan"
  git -C "$GIT_FIXTURE" add .; git -C "$GIT_FIXTURE" commit -qm 'test: pair only'
  HEAD_SHA="$(git -C "$GIT_FIXTURE" rev-parse HEAD)"
  check_inventory
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '# weakened scan\n' >> "$scan"
  git -C "$GIT_FIXTURE" add .; git -C "$GIT_FIXTURE" commit -qm 'test: weakened scan'
  HEAD_SHA="$(git -C "$GIT_FIXTURE" rev-parse HEAD)"
  check_inventory
  [ "$status" -ne 0 ]; [[ "$output" == *"test file outside the split changed"* ]]
}

@test "inventory rejects an unrelated added head stage despite a complete aggregate" {
  # Inversion: complete head evidence hides changes to the base canonical inventory.
  inventory_fixture
  printf "printf 'unrelated stage\\n'\n" >> "$GIT_FIXTURE/scripts/run-tests.sh"
  git -C "$GIT_FIXTURE" add .; git -C "$GIT_FIXTURE" commit -qm 'test: extra stage'
  HEAD_SHA="$(git -C "$GIT_FIXTURE" rev-parse HEAD)"
  printf '6\tunrelated stage\t1\t0\n' >> "$SANDBOX/inventory.tsv"
  check_inventory
  [ "$status" -ne 0 ]; [[ "$output" == *"changed beyond the four-part doctor split"* ]]
}
