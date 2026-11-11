"""Real stat-dirty index regression in an owned fixture; never source indexes."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

source, root, harness = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
status_only = harness.endswith('-status')
harness = harness.removesuffix('-status')
shell = os.environ.get('HOOK_OPTIONAL_LOCKS_TEST_BASH', '/bin/bash')
project = root / 'project'
project.mkdir()
real_git = os.environ.get('TRELLIS_TEST_REAL_GIT') or shutil.which('git')
fenced_git = shutil.which('git')
assert real_git and fenced_git

def git(*args):
    subprocess.run([fenced_git, '-C', str(project), '-c', 'gc.auto=0', '-c', 'maintenance.auto=false', *args], check=True, capture_output=True)

git('init', '-q')
tracked = project / 'view.tsx'
tracked.write_text('export const View = () => null;\n')
git('add', 'view.tsx')
git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')
index = project / '.git/index'

def snapshot():
    info = index.stat()
    return hashlib.sha256(index.read_bytes()).hexdigest(), info.st_mtime_ns

def entries():
    return subprocess.check_output([fenced_git, '-C', str(project), 'ls-files', '-s', '-z'])

def dirty():
    info = tracked.stat()
    os.utime(tracked, ns=(info.st_atime_ns, info.st_mtime_ns + 1_000_000_000))

# The runner fence intentionally suppresses every optional Git write. Permit
# only this one real read-only argv, only in this owned repository, so it does
# not mask the production bug. All other Git calls retain the canonical fence.
bin_dir = root / 'bin'
bin_dir.mkdir()
trace = root / 'ui-git.trace'
real_argv = (['-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', 'status', '--porcelain']
             if status_only else ['diff', 'HEAD', '--name-only', '-z'])
proxy = bin_dir / 'git'
proxy.write_text(f'''#!{sys.executable} -I
import os
from pathlib import Path
import sys

args = sys.argv[1:]
if args == {real_argv!r} and Path.cwd().resolve() == Path({str(project.resolve())!r}):
    with open({str(trace)!r}, 'a') as log:
        log.write(os.environ.get('GIT_OPTIONAL_LOCKS', 'unset') + '\\n')
    os.execv({real_git!r}, [{real_git!r}] + args)
os.execv({fenced_git!r}, [{fenced_git!r}] + args)
''')
proxy.chmod(0o755)
env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'], GIT_OPTIONAL_LOCKS='1',
           CLAUDE_PROJECT_DIR=str(project), CODEX_PROJECT_DIR=str(project),
           TRELLIS_ROOT=str(source), TRELLIS_HARNESS=harness)
# Prove stat-only dirtiness is observable and plain Git actually rewrites this
# fixture; no diagnostic diff/status is run between snapshots below.
dirty()
before = snapshot()
subprocess.run([str(proxy), *real_argv], cwd=project, env=env, check=True, capture_output=True)
assert snapshot() != before, 'vacuous fixture: optional-lock-enabled Git did not refresh the index'
trace.unlink()
dirty()
before = snapshot()
before_entries = entries()
payload = json.dumps(dict(stop_hook_active=False, session_id='optional-locks', hook_event_name=('SessionStart' if status_only else 'Stop'), source=('startup' if status_only else 'Stop')))
if harness in ('claude', 'codex'):
    hooks = source / ('core-rules/hooks' if harness == 'claude' else 'core-rules/codex/hooks')
    hook_name = 'session-context.sh' if status_only else 'ui-verify.sh'
    result = subprocess.run([shell, str(hooks / hook_name)], input=payload, cwd=project, env=env, text=True, capture_output=True)
else:
    runtime = project / '.trellis/runtime'
    target = runtime / 'core-rules/codex/hooks'
    target.mkdir(parents=True)
    # Other lifecycle members are controlled no-ops; UI uses the real wrapper,
    # real dependencies and real decision core through the actual dispatcher.
    for name in ('spec-gate', 'decision-receipt', 'primer-capture-nudge', 'stamp-turn'):
        path = target / (name + '.sh')
        path.write_text('#!/bin/bash\nexit 0\n')
        path.chmod(0o755)
    hook_name = 'session-context.sh' if status_only else 'ui-verify.sh'
    shutil.copy2(source / 'core-rules/codex/hooks' / hook_name, target / hook_name)
    if status_only:
        primer = target / 'inject-primer-index.sh'
        primer.write_text('#!/bin/bash\nexit 0\n')
        primer.chmod(0o755)
    shutil.copytree(source / 'core-rules/codex/hooks/lib', target / 'lib')
    shutil.copy2(source / 'core-rules/hooks/lib/ui-verify-core.sh', target / 'lib/ui-verify-core.sh')
    event_dir = root / 'event'
    event_dir.mkdir(mode=0o700)
    event = event_dir / 'event.json'
    event.write_text(json.dumps(dict(schema_version=1,harness='pi',cwd=str(project),phase='lifecycle',native_event=('session_start' if status_only else 'agent_settled'),session_id='optional-locks')))
    event.chmod(0o600)
    env['TRELLIS_ROOT'] = str(runtime)
    result = subprocess.run([shell, str(source / 'core-rules/pi/hooks/dispatch.sh'), '--event-file', str(event)], cwd=project, env=env, text=True, capture_output=True)
(root / 'hook.stdout').write_text(result.stdout)
(root / 'hook.stderr').write_text(result.stderr)
assert result.returncode == 0, (harness,result.returncode,result.stdout,result.stderr)
assert trace.is_file(), 'real Git inspection was not reached'
assert entries() == before_entries, (harness, 'hook changed index entries/object IDs')
if status_only:
    assert snapshot() == before, (harness, 'status rewrote index bytes or mtime', before, snapshot())
assert set(trace.read_text().splitlines()) == {'0'}, (harness, 'optional locks were not suppressed', trace.read_text())
# Owner ruling: diff may refresh stat-cache bytes; semantic entries must not
# change. Unlike diff, status must preserve both raw bytes and nanosecond mtime.
print(harness + ': entries/object IDs unchanged; optional locks suppressed' +
      ('; status bytes/mtime unchanged' if status_only else '; diff stat refresh permitted'))
