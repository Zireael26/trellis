#!/usr/bin/env bats
# Explicit adapter tests; no integration or historical receipt semantics changed.
load helpers

setup() {
  setup_project_dir
  ADAPTER="$HOOKS_DIR/lib/verification-bash.py"
  printf 'echo valid\n' > "$PROJECT_DIR/a.sh"
}

teardown() { teardown_project_dir; }

check_bash() { run python3 -I "$ADAPTER" --cwd "$PROJECT_DIR" --harness "${1:-claude}"; }
field() { printf '%s' "$output" | jq -r ".$1"; }

@test "CLI executes then cross-harness reuses and HEAD is provenance only" {
  check_bash; [ "$status" -eq 0 ]; [ "$(field status)" = executed ]
  check_bash pi; [ "$status" -eq 0 ]; [ "$(field status)" = reused ]
  git -C "$PROJECT_DIR" commit --allow-empty -qm next
  check_bash codex; [ "$status" -eq 0 ]; [ "$(field status)" = reused ]
}

@test "valid first and invalid second retains actual exit two; failures rerun" {
  printf 'if then\n' > "$PROJECT_DIR/b.sh"
  check_bash; [ "$status" -eq 2 ]; [ "$(field exit_status)" = 2 ]; [ "$(field status)" = executed ]
  [ "$(field receipt)" = null ]
  check_bash pi; [ "$status" -eq 2 ]; [ "$(field status)" = executed ]
}

@test "byte add rename tracked delete and untracked delete invalidate" {
  git -C "$PROJECT_DIR" add a.sh
  check_bash; [ "$status" -eq 0 ]
  printf 'echo changed\n' > "$PROJECT_DIR/a.sh"
  check_bash; [ "$status" -eq 0 ]; [ "$(field status)" = executed ]
  printf 'true\n' > "$PROJECT_DIR/b.sh"
  check_bash; [ "$status" -eq 0 ]; [ "$(field status)" = executed ]
  mv "$PROJECT_DIR/b.sh" "$PROJECT_DIR/c.sh"
  check_bash; [ "$status" -eq 0 ]; [ "$(field status)" = executed ]
  rm "$PROJECT_DIR/a.sh"
  check_bash; [ "$status" -eq 0 ]; [ "$(field status)" = executed ]
  rm "$PROJECT_DIR/c.sh"
  check_bash; [ "$status" -eq 3 ]; [ "$(field reason)" = no_inputs ]
}

@test "BASH_ENV is neither executed nor part of the key; ignored files are outside coverage" {
  printf 'touch "%s"\n' "$PROJECT_DIR/marker" > "$BATS_TEST_TMPDIR/env"
  export BASH_ENV="$BATS_TEST_TMPDIR/env"
  check_bash; [ "$status" -eq 0 ]; [ ! -e "$PROJECT_DIR/marker" ]
  export BASH_ENV="$BATS_TEST_TMPDIR/missing"
  printf 'ignored.sh\n' > "$PROJECT_DIR/.gitignore"
  printf 'if then\n' > "$PROJECT_DIR/ignored.sh"
  check_bash; [ "$status" -eq 0 ]; [ "$(field status)" = reused ]
}

@test "distinct worktrees sharing common storage cannot reuse" {
  git -C "$PROJECT_DIR" add a.sh
  git -C "$PROJECT_DIR" commit -qm script
  check_bash; [ "$status" -eq 0 ]
  git -C "$PROJECT_DIR" worktree add -q -b other "$BATS_TEST_TMPDIR/other"
  run python3 -I "$ADAPTER" --cwd "$BATS_TEST_TMPDIR/other" --harness pi
  [ "$status" -eq 0 ]; [ "$(field status)" = executed ]
}

@test "symlink files and parents and unsafe storage permissions are refused" {
  ln -s a.sh "$PROJECT_DIR/b.sh"
  check_bash; [ "$status" -eq 3 ]; [ "$(field reason)" = unsafe_input ]
  rm "$PROJECT_DIR/b.sh"
  mkdir "$PROJECT_DIR/dir"
  printf 'true\n' > "$PROJECT_DIR/dir/c.sh"
  git -C "$PROJECT_DIR" add dir/c.sh
  mv "$PROJECT_DIR/dir" "$PROJECT_DIR/real"
  ln -s real "$PROJECT_DIR/dir"
  check_bash; [ "$status" -eq 3 ]; [ "$(field reason)" = unsafe_input ]
  rm "$PROJECT_DIR/dir"
  git -C "$PROJECT_DIR" rm --cached -q dir/c.sh
  mkdir "$PROJECT_DIR/.git/trellis-bash-verification-v1"
  chmod 755 "$PROJECT_DIR/.git/trellis-bash-verification-v1"
  check_bash; [ "$status" -eq 3 ]; [ "$(field reason)" = unsafe_storage ]
}

@test "strict malformed identity version output and numeric type receipts miss" {
  check_bash; [ "$status" -eq 0 ]
  local receipt original mutation
  receipt="$(field receipt)"; original="$BATS_TEST_TMPDIR/original"
  cp "$receipt" "$original"
  for mutation in '.version=true' '.version=null' '.version=2' '.exit_status=false' '.executed=1' '.started_ns=true' '.finished_ns=null' '.identity.roots.worktree="/wrong"' '.identity.inputs[0][1]="bad"' '.output.sha256="bad"' '.output.bytes=false' '.output.base64="!!!!"' '.extra=1' '.harness=null'; do
    jq "$mutation" "$original" > "$receipt"
    check_bash; [ "$status" -eq 0 ]; [ "$(field status)" = executed ]
    rm "$(field receipt)"
  done
  for mutation in float duplicate NaN Infinity -Infinity; do
    python3 -I - "$original" "$receipt" "$mutation" <<'PY'
import pathlib, sys
source, target, mutation = sys.argv[1:]
raw = pathlib.Path(source).read_text()
if mutation == 'float':
    assert '"exit_status":0' in raw
    raw = raw.replace('"exit_status":0', '"exit_status":0.0')
elif mutation == 'duplicate':
    raw = raw.replace('"exit_status":0', '"exit_status":1,"exit_status":0')
else:
    import re
    raw = re.sub(r'"head":(?:null|"[^"]*")', '"head":' + mutation, raw, count=1)
pathlib.Path(target).write_text(raw)
PY
    check_bash; [ "$status" -eq 0 ]; [ "$(field status)" = executed ]
    rm "$(field receipt)"
  done
  printf '{' > "$receipt"
  check_bash; [ "$status" -eq 0 ]; [ "$(field status)" = executed ]
}

# The imported-module seam remains test-owned: no CLI/env override can supply
# another executable, timeout, implementation identity or parser result.
@test "internal observation witnesses reuse without Bash and both binding mutants" {
  run python3 -I - "$ADAPTER" "$PROJECT_DIR" <<'PY'
import importlib.util, pathlib, sys
p, root = sys.argv[1:]
spec = importlib.util.spec_from_file_location('adapter', p)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
original = m.parse_file
calls = []
def counted(path, end):
    calls.append(path)
    return original(path, end)
m.parse_file = counted
assert m.verify(root, 'claude')['status'] == 'executed'
assert m.verify(root, 'pi')['status'] == 'reused'
assert len(calls) == 1, calls
pathlib.Path(root, 'a.sh').write_text('echo changed\n')
assert m.verify(root, 'codex')['status'] == 'executed', 'content-binding business assertion'
assert len(calls) == 2
runtime = m.runtime
def changed(end):
    value = runtime(end)
    value['bash']['sha256'] = '1' * 64
    return value
m.runtime = changed
assert m.verify(root, 'pi')['status'] == 'executed', 'runtime-binding business assertion'
assert len(calls) == 3
print('content/runtime business assertions passed; counted Bash calls: 3')
PY
  [ "$status" -eq 0 ]
}

@test "source drift cleanup persistence and deadline retain distinct outcomes" {
  run python3 -I - "$ADAPTER" "$PROJECT_DIR" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location('adapter', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root = sys.argv[2]; path = pathlib.Path(root, 'a.sh')
parse = m.parse_file
def drift(p, end):
    result = parse(p, end)
    path.write_text('echo after\n')
    return result
m.parse_file = drift
r = m.verify(root, 'pi'); assert (r['status'], r['reason'], r['exit_status']) == ('unavailable', 'source_drift', 0), r
m.parse_file = parse
clean = m.cleanup
def fail(*args, **kwargs): raise OSError('test-owned failure')
m.cleanup = fail
r = m.verify(root, 'pi'); assert (r['reason'], r['exit_status']) == ('cleanup_failed', 0), r
m.cleanup = clean
replace = m.os.replace; m.os.replace = fail
r = m.verify(root, 'pi'); assert (r['status'], r['reason'], r['exit_status'], r['receipt']) == ('executed', 'persistence_failed', 0, None), r
m.os.replace = replace
def expire(p, end): return parse(p, 0)
m.parse_file = expire
r = m.verify(root, 'pi'); assert r['reason'] == 'deadline_exceeded', r
store = pathlib.Path(root, '.git', m.STORE)
assert not list(store.glob('*.json'))
print('drift/cleanup/persistence/deadline assertions passed')
PY
  [ "$status" -eq 0 ]
}

@test "source bytes and loaded code are independently bound with filename-only normalization" {
  run python3 -I - "$ADAPTER" "$PROJECT_DIR" "$BATS_TEST_TMPDIR" <<'PY'
import importlib.util, pathlib, sys, time
original, root, temp = map(pathlib.Path, sys.argv[1:])
copy = temp / 'adapter.py'; copy.write_bytes(original.read_bytes())
def load(path):
    spec = importlib.util.spec_from_file_location('adapter', path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
m = load(copy)
a = m.runtime(time.monotonic()+30)
assert m.verify(str(root), 'claude')['status'] == 'executed'
alias = temp / 'alias.py'; alias.symlink_to(copy)
n = load(alias)
assert n.runtime(time.monotonic()+30) == a
assert n.verify(str(root), 'pi')['status'] == 'reused'
copy.write_bytes(copy.read_bytes() + b'\n# source changed after load\n')
b = m.runtime(time.monotonic()+30)
assert b['implementation']['source'] != a['implementation']['source']
assert b['implementation']['loaded'] == a['implementation']['loaded']
assert m.verify(str(root), 'pi')['status'] == 'executed'
copy.write_bytes(copy.read_bytes().replace(b'OUTPUT_CAP = 65536', b'OUTPUT_CAP = 65535'))
c = load(copy).runtime(time.monotonic()+30)
assert c['implementation']['loaded'] != b['implementation']['loaded']
PY
  [ "$status" -eq 0 ]
}

@test "streaming parser bounds output and reaps only its owned child" {
  run python3 -I - "$ADAPTER" "$PROJECT_DIR" <<'PY'
import importlib.util, pathlib, subprocess, sys, time
spec = importlib.util.spec_from_file_location('adapter', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root = sys.argv[2]; popen = subprocess.Popen; children = []
def noisy(argv, **kwargs):
    child = popen([sys.executable, '-I', '-c',
                   'import os,time; os.write(1,b"x"*65537); time.sleep(10)'], **kwargs)
    children.append(child)
    return child
m.subprocess.Popen = noisy
try:
    m.parse_file('unused', time.monotonic()+2)
    raise AssertionError('output overflow accepted')
except m.Unavailable as exc:
    assert str(exc) == 'output_limit', exc
assert children[-1].returncode is not None
m.subprocess.Popen = popen
# Known success followed by aggregate diagnostic overflow must not publish.
pathlib.Path(root, 'b.sh').write_text('true\n')
m.parse_file = lambda p, end: (0, b'x' * 40000)
r = m.verify(root, 'pi')
assert (r['reason'], r['exit_status'], r['receipt']) == ('output_limit', 0, None), r
assert not list(pathlib.Path(root, '.git', m.STORE).glob('*.json'))
print('bounded output, owned child reaped, known exit retained, no truncated receipt')
PY
  [ "$status" -eq 0 ]
}

@test "raw snapshot reads enforce per-file and aggregate limits without trusting stat size" {
  run python3 -I - "$ADAPTER" "$PROJECT_DIR" <<'PY'
import importlib.util, os, pathlib, sys, time
spec = importlib.util.spec_from_file_location('adapter', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root = sys.argv[2]
assert m.INPUT_FILE_CAP == 16*1024*1024 and m.INPUT_TOTAL_CAP == 64*1024*1024
# Small internal limits keep the test cheap; real descriptor reads must carry
# them, not a metadata-only check. The synthetic read models a growing file.
m.INPUT_FILE_CAP = 16; m.INPUT_TOTAL_CAP = 64
original = m.os.read; consumed = []
def growing(fd, size):
    consumed.append(size)
    return b'x' * size
m.os.read = growing
try:
    # Enumeration is independently supplied so the read seam is file-only.
    m.git_call = lambda *a, **k: b'a.sh\0'
    try:
        m.snapshot('unused', root, time.monotonic()+2)
        raise AssertionError('per-file overflow accepted')
    except m.Unavailable as exc:
        assert str(exc) == 'unsafe_input', exc
    assert sum(consumed) == 17, consumed
finally:
    m.os.read = original
for n in range(5):
    pathlib.Path(root, str(n)+'.sh').write_bytes(b'x'*16)
m.git_call = lambda *a, **k: b'\0'.join(str(n).encode()+b'.sh' for n in range(4))
assert sum(len(data) for _, _, data in m.snapshot('unused', root, time.monotonic()+2)) == 64
m.git_call = lambda *a, **k: b'\0'.join(str(n).encode()+b'.sh' for n in range(5))
try:
    m.snapshot('unused', root, time.monotonic()+2)
    raise AssertionError('aggregate overflow accepted')
except m.Unavailable as exc:
    assert str(exc) == 'unsafe_input', exc
print('raw per-file and aggregate byte limits enforced')
PY
  [ "$status" -eq 0 ]
}

@test "storage failures stay distinct from dependencies publication and cleanup" {
  run python3 -I - "$ADAPTER" "$PROJECT_DIR" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location('adapter', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root = sys.argv[2]; calls = []; parse = m.parse_file
m.parse_file = lambda p, end: (calls.append(p) or parse(p, end))
def fail(*args, **kwargs): raise OSError('test-owned boundary failure')
for owner, key in [(m, 'records'), (m.os, 'mkdir'), (m.os, 'open'), (m, 'create_file')]:
    original = getattr(owner, key)
    fired = []
    def injected(*args, **kwargs):
        target = key not in ('mkdir', 'open') or (
            isinstance(args[0], str) and args[0].startswith('scratch-'))
        if target and not fired:
            fired.append(True)
            fail()
        return original(*args, **kwargs)
    setattr(owner, key, injected)
    try:
        r = m.verify(root, 'pi')
    finally:
        setattr(owner, key, original)
    assert fired and not calls, (key, fired, calls)
    assert (r['status'], r['reason'], r['exit_status'], r['receipt']) == (
        'unavailable', 'unsafe_storage', None, None), (key, r)
    assert not list(pathlib.Path(root, '.git', m.STORE).iterdir()), key
# These failures are outside the storage boundary and must not be relabeled.
for key in ('git_call', 'runtime', 'parse_file'):
    original = getattr(m, key); setattr(m, key, fail)
    try:
        r = m.verify(root, 'pi')
    finally:
        setattr(m, key, original)
    assert (r['reason'], r['exit_status']) == ('dependency_unavailable', None), (key, r)
original = m.os.replace; m.os.replace = fail
try:
    r = m.verify(root, 'pi')
finally:
    m.os.replace = original
assert (r['status'], r['reason'], r['exit_status'], r['receipt'], r['diagnostic']) == (
    'executed', 'persistence_failed', 0, None, 'Verification persistence failed.'), r
original = m.cleanup; m.cleanup = fail
try:
    r = m.verify(root, 'pi')
finally:
    m.cleanup = original
assert (r['status'], r['reason'], r['exit_status'], r['receipt']) == (
    'unavailable', 'cleanup_failed', 0, None), r
assert not list(pathlib.Path(root, '.git', m.STORE).glob('*.json'))
print('storage/dependency/publication/cleanup taxonomy and persistence diagnostic passed')
PY
  [ "$status" -eq 0 ]
}

@test "nonisolated Python refuses execution" {
  run python3 "$ADAPTER" --cwd "$PROJECT_DIR" --harness pi
  [ "$status" -eq 3 ]; [ "$(field reason)" = dependency_unavailable ]
}
