#!/usr/bin/env bats
# Document-only CLI tests. Run inside the canonical isolated gate with fresh
# generated Git/mktemp launchers; no native lifecycle/SC4 claim.

setup() {
  [ -n "${TRELLIS_TEST_GIT_FENCE_ROOT:-}" ]
  PROJECT_DIR="$(mktemp -d)"
  export PROJECT_DIR
  git -C "$PROJECT_DIR" -c core.hooksPath=/dev/null -c init.templateDir= init -q
  TASK_STATE="${TASK_STATE_UNDER_TEST:-$BATS_TEST_DIRNAME/../lib/task-state.py}"
  export TASK_STATE
}

# Each Python body gets a real CLI oracle and a private unborn Git fixture.
check() {
  local prelude="$PROJECT_DIR/check.py"
  cat > "$prelude" <<'PY'
import hashlib, importlib.util, json, os, pathlib, subprocess, sys, time
root = pathlib.Path(os.environ['PROJECT_DIR']).resolve()
script = pathlib.Path(os.environ['TASK_STATE']).resolve()
source = root / 'tasks.md'
state = root / '.git/trellis-task-state-v1'
def cli(command='read', path='tasks.md', harness='pi', cwd=root, extra_env=None):
    args = [sys.executable, '-I', str(script), command, '--cwd', str(cwd)]
    if command == 'capture':
        args += ['--tasks', path, '--harness', harness]
    proc = subprocess.run(args, capture_output=True, text=True, env={**os.environ, **(extra_env or {})}, timeout=35)
    data = json.loads(proc.stdout)
    assert proc.returncode == (1 if data['status'] == 'unavailable' else 0), (proc.returncode, data, proc.stderr)
    return data
def seed(raw=b'- [ ] pending\n- [x] complete\n'):
    source.write_bytes(raw)
    result = cli('capture')
    assert result['status'] == 'available', result
    return next(state.glob('*.json'))
def save(path, record):
    path.write_text(json.dumps(record))
def unavailable():
    result = cli()
    assert result['status'] == 'unavailable', result
    assert all('tasks' not in row for row in result['documents']), result
    return result
def module():
    spec = importlib.util.spec_from_file_location('task_state', script)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.DEADLINE = time.monotonic() + 30
    return mod
PY
  cat >> "$prelude"
  run python3 -I "$prelude"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "all attributed harnesses preserve both tick dialects and quoted data" {
  check <<'PY'
raw = b'# plan\n- [ ] pending $(touch NEVER)\n  - [x] complete\n| T10 | Keep [ ] embedded | SC1 | [ ] |\n| T1 | Done | SC2 | [x] |\n'
source.write_bytes(raw)
expected = None
for harness in ('claude', 'codex', 'pi'):
    result = cli('capture', harness=harness)
    assert result['status'] == 'available', result
    data = cli()['documents'][0]
    assert data['producer_harness'] == harness
    assert [t['checked'] for t in data['tasks']] == [False, True, False, True]
    assert [t['id'] for t in data['tasks']] == [None, None, 'T10', 'T1']
    assert [t['line'] for t in data['tasks']] == [2, 3, 4, 5]
    if expected is not None: assert data['tasks'] == expected
    expected = data['tasks']
assert source.read_bytes() == raw and not (root / 'NEVER').exists()
assert len(list(state.iterdir())) == 1
assert state.stat().st_mode & 0o777 == 0o700
assert next(state.iterdir()).stat().st_mode & 0o777 == 0o600
PY
}

@test "raw LF CRLF CR hashes and line numbers survive unchanged" {
  check <<'PY'
for newline in (b'\n', b'\r\n', b'\r'):
    raw = newline.join([b'# plan', b'- [ ] first', b'- [x] second', b''])
    record = json.loads(seed(raw).read_text())
    assert record['source'] == {'path':'tasks.md', 'sha256':hashlib.sha256(raw).hexdigest(), 'bytes':len(raw)}
    assert [t['line'] for t in cli()['documents'][0]['tasks']] == [2,3]
    assert source.read_bytes() == raw
PY
}

@test "source-change business oracle never returns recovered stale tasks" {
  check <<'PY'
seed()
source.write_bytes(b'- [x] changed\n')
result = cli()
assert result['status'] == 'available', result
assert result['documents'][0]['status'] == 'stale', result
assert 'tasks' not in result['documents'][0], result
source.unlink()
result = cli()
assert result['documents'][0]['status'] == 'missing', result
assert 'tasks' not in result['documents'][0]
PY
}

@test "no records and fenced examples are not completed plans" {
  check <<'PY'
assert cli()['status'] == 'no_records'
for raw in (b'plain prose', b'```md\n- [ ] example\n```', b'~~~\n| T1 | fake | [x] |\n~~~'):
    source.write_bytes(raw)
    assert cli('capture')['status'] == 'unavailable'
source.write_bytes(b'```md\n- [ ] example\n````\n~~~\n- [x] example\n~~~\n- [ ] real')
assert [t['text'] for t in cli('capture')['documents'][0]['tasks']] == ['real']
PY
}

@test "unknown checkbox dialects controls UTF8 and bounds refuse the whole capture" {
  check <<'PY'
record = seed(); original = record.read_bytes()
for raw in (b'- [X] unknown', b'* [ ] other', b'1. [ ] other', b'- [ ] ok\n| T1 | bad | [?] |',
            b'- [ ] ok\n| T1 | bad | [ ]', b'- [ ] bad\x00text', b'- [ ] \xff',
            b'- [ ] ' + b'a'*2049, b'- [ ] a\n'*1001, b'a'*(1024*1024+1),
            b'- [ ] <!-- dod-receipt cmd="bad" exit=0 diff="+1/-0 (1 files)" -->'):
    source.write_bytes(raw)
    assert cli('capture')['status'] == 'unavailable', raw[:100]
    assert record.read_bytes() == original
source.write_bytes(b'- [ ] '+b'a'*2048)
assert cli('capture')['status'] == 'available'
source.write_bytes(b'- [ ] a\n'*1000)
assert len(cli('capture')['documents'][0]['tasks']) == 1000
PY
}

@test "checked text hash roots and strict schema corruption cannot recover" {
  check <<'PY'
record = seed(); original = json.loads(record.read_text())
changes = [lambda r:r['tasks'][0].update(checked=True), lambda r:r['tasks'][0].update(text='forged'),
           lambda r:r['source'].update(sha256='0'*64), lambda r:r['roots'].update(git_common_dir='/wrong'),
           lambda r:r.update(schema=True), lambda r:r.update(extra='bad'),
           lambda r:r['tasks'][0].update(checked=0), lambda r:r['tasks'][0].update(line=True),
           lambda r:r['tasks'][1].update(line=1), lambda r:r['source'].update(bytes=True),
           lambda r:r.update(captured_at='2026-02-30T00:00:00Z'), lambda r:r.update(tasks=[])]
for change in changes:
    record_data = json.loads(json.dumps(original)); change(record_data); save(record,record_data)
    result = cli()
    assert result['documents'][0]['status'] in ('stale','unavailable'), result
    assert 'tasks' not in result['documents'][0], result
for raw in ('{', json.dumps(original)+'{}', '{"schema":1,"schema":1}', '[]', '"text"'):
    record.write_text(raw); unavailable()
record.write_bytes(b'x'*(4*1024*1024+1)); unavailable()
PY
}

@test "unsafe source paths symlinks and Git runtime sources are refused" {
  check <<'PY'
seed()
(root/'link.md').symlink_to(source)
(root/'linked').symlink_to(root, target_is_directory=True)
(root/'.trellis/runtime').mkdir(parents=True)
(root/'.trellis/runtime/tasks.md').write_bytes(b'- [ ] hidden')
for path in ('link.md','linked/tasks.md','../tasks.md',str(source),'./tasks.md','tasks.md\n',
             '.git/tasks.md','.trellis/runtime/tasks.md'):
    assert cli('capture', path=path)['status'] == 'unavailable', path
source.unlink(); source.symlink_to(root/'missing.md')
unavailable()
PY
}

@test "unsafe state directory record permissions symlinks and hardlinks are not repaired" {
  check <<'PY'
record=seed(); original=record.read_bytes()
for mode in (0o755,0o770):
    state.chmod(mode); unavailable()
    assert cli('capture')['status']=='unavailable'
    assert state.stat().st_mode & 0o777 == mode
state.chmod(0o700)
record.chmod(0o644); unavailable(); assert cli('capture')['status']=='unavailable'
record.chmod(0o600)
other=root/'other'; other.write_bytes(original); record.unlink(); record.symlink_to(other)
unavailable(); assert cli('capture')['status']=='unavailable'
record.unlink(); os.link(other,record); record.chmod(0o600); unavailable()
record.unlink(); state.rmdir(); state.symlink_to(root, target_is_directory=True); unavailable()
PY
}

@test "document cap and scan cap refuse without erasing earlier documents" {
  check <<'PY'
record=seed(); original=record.read_bytes()
for i in range(1,20):
    (root/f'{i}.md').write_bytes(b'- [ ] item')
    assert cli('capture',path=f'{i}.md')['status']=='available'
(root/'21.md').write_bytes(b'- [ ] extra')
assert cli('capture',path='21.md')['reason']=='document_count_bound'
assert record.read_bytes()==original and len(list(state.iterdir()))==20
for i in range(81): (state/f'junk{i}').write_text('x')
assert cli()['reason']=='directory_scan_bound'
assert record.read_bytes()==original
PY
}

@test "linked worktrees exclude foreign snapshots and report count only" {
  check <<'PY'
seed()
# Orphan worktree creation needs no staging/commit and supports unborn HEAD.
linked=root.parent/(root.name+'-linked')
subprocess.run(['git','-C',str(root),'worktree','add','--orphan','-q',str(linked)],check=True)
result=cli(cwd=linked)
assert result == {'status':'no_records','documents':[],'foreign_records':1}, result
(linked/'tasks.md').write_bytes(b'- [x] linked')
assert cli('capture',cwd=linked)['status']=='available'
result=cli()
assert result['foreign_records']==1 and len(result['documents'])==1
assert result['documents'][0]['tasks'][0]['text']=='pending'
PY
}

@test "inherited Git routing config and secret environment are not stored" {
  check <<'PY'
source.write_bytes(b'- [ ] task')
result=cli('capture',extra_env={'GIT_DIR':'/missing','GIT_WORK_TREE':'/missing',
    'GIT_CONFIG_COUNT':'1','GIT_CONFIG_KEY_0':'core.worktree','GIT_CONFIG_VALUE_0':'/missing',
    'ANTHROPIC_API_KEY':'DO_NOT_STORE','OPENAI_API_KEY':'DO_NOT_STORE'})
assert result['status']=='available',result
assert b'DO_NOT_STORE' not in next(state.iterdir()).read_bytes()
PY
}

@test "source drift and persistence failure preserve the old valid record" {
  check <<'PY'
record=seed(); old=record.read_bytes(); mod=module()
active={'git_common_dir':str(root/'.git'),'worktree_root':str(root)}
replace=mod.os.replace
mod.os.replace=lambda *a,**k: (_ for _ in ()).throw(OSError('injected persistence failure'))
try: mod.capture(active,'tasks.md','pi'); assert False
except OSError: pass
assert record.read_bytes()==old and len(list(state.iterdir()))==1
mod.os.replace=replace
parse=mod.parse
def drift(raw):
    result=parse(raw); source.write_bytes(b'- [x] changed'); return result
mod.parse=drift
try: mod.capture(active,'tasks.md','pi'); assert False
except mod.Unavailable as error: assert str(error)=='source_drift'
assert record.read_bytes()==old and len(list(state.iterdir()))==1
PY
}

@test "one monotonic deadline stops substantive work" {
  check <<'PY'
record=seed(); old=record.read_bytes(); mod=module()
mod.DEADLINE=time.monotonic()-1
try: mod.capture({'git_common_dir':str(root/'.git'),'worktree_root':str(root)},'tasks.md','pi'); assert False
except mod.Unavailable as error: assert str(error)=='budget_expired'
assert record.read_bytes()==old
PY
}

@test "mixed unsupported blockquote task prefixes refuse without replacing records" {
  check <<'PY'
record=seed(); old=record.read_bytes()
for prefix in ('> - [ ]', '> > - [x]', ' >> 1. [ ]', '>\t* [ ]', '+ [ ]'):
    source.write_text('- [ ] valid\n'+prefix+' omitted\n')
    result=cli('capture')
    assert result['status']=='unavailable', result
    assert record.read_bytes()==old
    source.write_text('```md\n'+prefix+' example\n```\n- [ ] valid\n')
    assert [t['text'] for t in cli('capture')['documents'][0]['tasks']]==['valid']
    old=record.read_bytes()
PY
}

@test "post-open directory disappearance is drift not no records" {
  check <<'PY'
mod=module(); active={'git_common_dir':str(root/'.git'),'worktree_root':str(root)}
assert mod.read(active)['status']=='no_records'
state.mkdir(mode=0o700)
names=mod.names
for rename in (False,True):
    def disappear(fd):
        result=names(fd)
        if rename: state.rename(root/'moved-state')
        else: state.rmdir()
        return result
    mod.names=disappear
    try: mod.read(active); assert False, 'drift accepted as no_records'
    except mod.Unavailable as error: assert str(error)=='state_directory_drift', error
    if rename: (root/'moved-state').rename(state)
    else: state.mkdir(mode=0o700)
PY
}

@test "late alarm cannot strand owned scratch or report success after cleanup" {
  check <<'PY'
import signal
record=seed(); old=record.read_bytes(); mod=module()
active={'git_common_dir':str(root/'.git'),'worktree_root':str(root)}
unlink=mod.os.unlink
mod.os.replace=lambda *a,**k: (_ for _ in ()).throw(OSError('injected persistence failure'))
def delayed_unlink(*a,**k):
    time.sleep(.08)
    return unlink(*a,**k)
mod.os.unlink=delayed_unlink
signal.signal(signal.SIGALRM,mod.budget)
mod.DEADLINE=time.monotonic()+.04
signal.setitimer(signal.ITIMER_REAL,.04)
try:
    try: mod.capture(active,'tasks.md','pi'); assert False
    except mod.Unavailable as error: assert str(error)=='budget_expired'
finally: signal.setitimer(signal.ITIMER_REAL,0)
assert record.read_bytes()==old and list(state.iterdir())==[record], list(state.iterdir())
PY
}

@test "serialization and backpressured output share the original deadline" {
  check <<'PY'
# Internal module injection only: no production CLI timeout override.
import signal
mod=module()
mod.roots=lambda cwd: {}
def recovered(active):
    mod.DEADLINE=time.monotonic()+.04
    signal.setitimer(signal.ITIMER_REAL,.04)
    return {'status':'available','documents':[],'foreign_records':0}
mod.read=recovered
sys.argv=[str(script),'read','--cwd',str(root)]
dumps=mod.json.dumps
def slow(*a,**k):
    time.sleep(.08)
    return dumps(*a,**k)
mod.json.dumps=slow
read_fd,write_fd=os.pipe(); saved=os.dup(1)
try:
    os.dup2(write_fd,1)
    code=mod.main()
finally:
    os.dup2(saved,1); os.close(saved); os.close(write_fd)
raw=os.read(read_fd,10000); os.close(read_fd)
assert code==1 and json.loads(raw)['status']=='unavailable',(code,raw)
mod.json.dumps=dumps
read_fd,write_fd=os.pipe(); os.set_blocking(write_fd,False)
try:
    while True: os.write(write_fd,b'x'*4096)
except BlockingIOError: pass
saved=os.dup(1); started=time.monotonic()
try:
    os.dup2(write_fd,1)
    code=mod.main()
finally:
    os.dup2(saved,1); os.close(saved); os.close(write_fd)
assert code==1 and time.monotonic()-started<.5, code
raw=b''
while True:
    chunk=os.read(read_fd,65536)
    if not chunk: break
    raw+=chunk
os.close(read_fd)
assert b'available' not in raw
# Broken pipe cannot be reported as successfully delivered JSON.
read_fd,write_fd=os.pipe(); os.close(read_fd); saved=os.dup(1)
try:
    os.dup2(write_fd,1)
    assert mod.main()==1
finally:
    os.dup2(saved,1); os.close(saved); os.close(write_fd)
PY
}

@test "concurrent captures and readers only see complete current JSON" {
  check <<'PY'
seed()
processes=[subprocess.Popen([sys.executable,'-I',str(script),'capture','--cwd',str(root),
    '--tasks','tasks.md','--harness',h],stdout=subprocess.PIPE,stderr=subprocess.PIPE) for h in ('claude','codex','pi')]
for _ in range(4): assert cli()['documents'][0]['status']=='current'
for process in processes:
    out,err=process.communicate(timeout=35)
    assert process.returncode==0,(out,err)
    assert json.loads(out)['status']=='available'
assert len(list(state.iterdir()))==1
PY
}
