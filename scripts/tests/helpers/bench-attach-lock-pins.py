#!/usr/bin/env python3
"""Diagnostic A/B of T13's lock pins, not an SC1 or release benchmark.

Functional mode exercises the same private lock fixture without reading a
clock. Measurement requires an exact clean candidate, explicit liveness, a
quiet host and at least 30 interleaved observations per arm. Every timed arm
acquires/releases the three real canonical locks and starts the same Python
interpreter. Single-pin arms add only that lock's real pin/close work; the
full arm additionally runs the real Python lock scope and its four explicit
preflight/journal rechecks. No project, live home, Git hooks or release is used.
"""
import argparse
import ast
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time

ARMS = ('baseline', 'checkout-pin', 'attachment-pin', 'registry-pin', 'full')
BATTERIES = re.compile(
    r'(?:^|[ /])(?:bats(?:-core)?|cargo\s+(?:test|build|check|bench)|rustc|'
    r'run-tests(?:-local)?\.sh|run-all\.sh)(?:\s|$)'
)

# This no-op or full-proof child is launched once in every arm. The full arm
# uses the real module and all six checks: entry, four explicit points, exit.
PROBE = r'''
import importlib.util, os, sys
arm, source, home, common, checkout, worktree, attachment, checkout_pid, attachment_pid, registry_pid = sys.argv[1:]
expected = {'baseline': (), 'checkout-pin': (31,), 'attachment-pin': (32,),
            'registry-pin': (33,), 'full': (31, 32, 33)}[arm]
opened = []
for fd in (31, 32, 33):
    try:
        os.fstat(fd)
        opened.append(fd)
    except OSError:
        pass
if tuple(opened) != expected:
    raise RuntimeError('benchmark pin layout differs: ' + repr(opened))
spec = importlib.util.spec_from_file_location('t13_lockbench_fastpath', source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
if arm == 'full':
    module.require_private_lock_fds((31, 32, 33))
module.load_integrity()
if arm == 'full':
    binding = {'checkout_id': checkout, 'worktree_id': worktree, 'git_common_dir': common}
    with module.transaction_lock_scope(home, binding, attachment, checkout_pid, attachment_pid, registry_pid) as locks:
        locks.recheck()
        locks.recheck()
        locks.recheck()
        locks.recheck()
print('PROBE_READY ' + arm)
'''

WORKER = r'''
set -u
. "$T13_ATTACH"
_T13_OWN_31=0; _T13_OWN_32=0; _T13_OWN_33=0; T13_PARENT_COPY=0
_TRELLIS_HOME_LOCK_DIR=''
cleanup() {
  attach_t13_close_fast_pins >/dev/null 2>&1 || :
  if [ "$T13_PARENT_COPY" = 1 ]; then exec 34<&-; fi
  _attachment_lock_release >/dev/null 2>&1 || :
  trellis_home_lock_release >/dev/null 2>&1 || :
  _attachment_checkout_lock_release >/dev/null 2>&1 || :
}
trap cleanup EXIT
_attachment_checkout_lock_acquire "$T13_HOME" "$T13_CHECKOUT" "$T13_COMMON" || exit 11
checkout_pid="$_ATTACHMENT_PROCESS_PID"
case "$T13_ARM" in
  checkout-pin|full) exec 31<"$_ATTACHMENT_CHECKOUT_LOCK_HOLDER" || exit 12; _T13_OWN_31=1 ;;
esac
# Stand in for the checkout fd retained by the waiting outer attach subshell.
if [ "$T13_ARM" = full ]; then exec 34<&31 || exit 12; T13_PARENT_COPY=1; fi
_attachment_lock_acquire "$T13_HOME" "$T13_CHECKOUT" "$T13_WORKTREE" "$T13_ATTACHMENT" || exit 13
attachment_pid="$_ATTACHMENT_PROCESS_PID"
case "$T13_ARM" in
  attachment-pin|full) exec 32<"$_ATTACHMENT_LOCK_HOLDER" || exit 14; _T13_OWN_32=1 ;;
esac
trellis_home_lock_acquire "$T13_HOME" registry 0 >/dev/null 2>&1 || exit 15
case "$T13_ARM" in
  registry-pin|full) exec 33<"$_TRELLIS_HOME_LOCK_DIR" || exit 16; _T13_OWN_33=1 ;;
esac
/usr/bin/python3 -I -B "$T13_PROBE" "$T13_ARM" "$T13_FASTPATH" "$T13_HOME" "$T13_COMMON" \
  "$T13_CHECKOUT" "$T13_WORKTREE" "$T13_ATTACHMENT" "$checkout_pid" "$attachment_pid" "$$" || exit 17
attach_t13_close_fast_pins || exit 18
if [ "$T13_PARENT_COPY" = 1 ]; then
  attach_t13_pin_matches 34 "$_ATTACHMENT_CHECKOUT_LOCK_HOLDER" "$_ATTACHMENT_CHECKOUT_LOCK_LINK" || exit 18
  exec 34<&-; T13_PARENT_COPY=0
fi
_attachment_lock_release || exit 19
trellis_home_lock_release || exit 20
_attachment_checkout_lock_release || exit 21
trap - EXIT
printf 'LOCKBENCH_OK %s\n' "$T13_ARM"
'''


def arm_order(round_number):
    offset = round_number % len(ARMS)
    return ARMS[offset:] + ARMS[:offset]


def validate_run(measured, samples, liveness_clear):
    if samples < 1:
        raise ValueError('sample count must be positive')
    if measured and (samples < 30 or not liveness_clear):
        raise ValueError('measurement requires liveness CLEAR and at least 30 samples per arm')


def battery_status():
    result = subprocess.run(['ps', '-Ao', 'pid=,args='], capture_output=True, text=True, check=True, timeout=10)
    matches = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and int(fields[0]) != os.getpid() and BATTERIES.search(fields[1]):
            matches.append(line.strip())
    return {'state': 'CLEAR' if not matches else 'BUSY', 'matches': matches}


def quiet_state():
    return list(os.getloadavg()), battery_status()


def require_quiet(load, battery, limit):
    if load[0] >= limit or battery['state'] != 'CLEAR':
        raise RuntimeError('host not quiet: load={} battery={}'.format(load, battery))


def run_samples(run, record, *, measured, samples, warmups, load_limit, verify=None):
    for round_number in range(samples + warmups):
        for arm in arm_order(round_number):
            before, battery_before = quiet_state() if measured else (None, None)
            if measured:
                require_quiet(before, battery_before, load_limit)
            started = time.perf_counter_ns() if measured else None
            result = run(arm)
            elapsed = (time.perf_counter_ns() - started) / 1_000_000 if measured else None
            if verify is not None:
                verify(arm, result)
            after, battery_after = quiet_state() if measured else (None, None)
            record({'round': round_number, 'arm': arm, 'warmup': round_number < warmups,
                    'elapsed_ms': elapsed, 'load_before': before, 'load_after': after,
                    'battery_before': battery_before, 'battery_after': battery_after})
            if measured:
                require_quiet(after, battery_after, load_limit)


def percentiles(values):
    ordered = sorted(values)
    if not ordered:
        raise ValueError('no measured observations')
    return {'p50_ms': statistics.median(ordered), 'p90_ms': ordered[math.ceil(0.9 * len(ordered)) - 1]}


def summarize(rows):
    measured = [row for row in rows if not row['warmup']]
    by_round = {}
    for row in measured:
        by_round.setdefault(row['round'], {})[row['arm']] = row['elapsed_ms']
    result = {}
    for arm in ARMS:
        times = [row['elapsed_ms'] for row in measured if row['arm'] == arm]
        differences = [row[arm] - row['baseline'] for row in by_round.values()]
        result[arm] = {'count': len(times), 'absolute': percentiles(times),
                       'within_round_difference_from_baseline': percentiles(differences)}
    return result


def git(repo, *args, gitconfig):
    env = {'HOME': str(gitconfig.parent), 'TMPDIR': str(gitconfig.parent),
           'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'LC_ALL': 'C',
           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': str(gitconfig), 'GIT_OPTIONAL_LOCKS': '0'}
    return subprocess.run(['git', '-C', str(repo), *args], env=env,
                          capture_output=True, text=True, check=True).stdout.strip()


def tool_info(command):
    path = shutil.which(command[0]) if not command[0].startswith('/') else command[0]
    if not path:
        raise ValueError('missing benchmark tool: ' + command[0])
    result = subprocess.run([path, *command[1:]], capture_output=True, text=True, check=True, timeout=10)
    return {'path': path, 'realpath': os.path.realpath(path),
            'version': (result.stdout or result.stderr).splitlines()[0]}


def validate_recheck_count(source):
    tree = ast.parse(source.read_text(encoding='utf-8'))
    functions = {node.name: node for node in tree.body if isinstance(node, ast.FunctionDef)}
    def count(function, receiver):
        return sum(1 for node in ast.walk(function) if isinstance(node, ast.Call) and
                   isinstance(node.func, ast.Attribute) and node.func.attr == 'recheck' and
                   isinstance(node.func.value, ast.Name) and node.func.value.id == receiver)
    if ('main' not in functions or 'transaction_lock_scope' not in functions or
            count(functions['main'], 'locks') != 4 or count(functions['transaction_lock_scope'], 'scope') != 2):
        raise ValueError('T13 lock recheck count changed; update this diagnostic before use')
    return 4


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path, help='new private output directory outside the checkout')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--functional', action='store_true', help='one untimed functional observation per arm')
    mode.add_argument('--measure', action='store_true', help='time interleaved arms, only in an authorized quiet window')
    parser.add_argument('--candidate', help='exact candidate commit, required for measurement')
    parser.add_argument('--liveness-clear', action='store_true', help='operator confirms the release battery is stopped')
    parser.add_argument('--samples', type=int, default=30)
    parser.add_argument('--warmups', type=int, default=2)
    parser.add_argument('--max-load', type=float, default=2.0)
    args = parser.parse_args(argv)
    validate_run(args.measure, args.samples, args.liveness_clear)
    if args.warmups < 0 or not 0 < args.max_load <= 2:
        raise ValueError('warmups must be nonnegative and max load must be at most 2')
    if args.measure and (not args.candidate or not re.fullmatch(r'[0-9a-f]{40}', args.candidate) or args.warmups < 2):
        raise ValueError('measurement requires a full candidate SHA and at least two warmups per arm')
    repo = args.repo.resolve(strict=True)
    output = args.output
    if not output.is_absolute() or output.parent.resolve(strict=True) != output.parent:
        raise ValueError('output must be absolute with an existing canonical parent')
    if output == repo or repo in output.parents:
        raise ValueError('output must be outside the checkout')
    output.mkdir(mode=0o700)
    os.chmod(output, 0o700)
    gitconfig = output / 'gitconfig'
    gitconfig.write_text('', encoding='utf-8')
    gitconfig.chmod(0o600)
    head = git(repo, 'rev-parse', '--verify', 'HEAD^{commit}', gitconfig=gitconfig)
    if not re.fullmatch(r'[0-9a-f]{40}', head):
        raise ValueError('invalid source commit')
    if args.measure:
        candidate = git(repo, 'rev-parse', '--verify', args.candidate + '^{commit}', gitconfig=gitconfig)
        if candidate != head:
            raise ValueError('checked-out HEAD differs from the candidate')
        status = git(repo, 'status', '--porcelain', '--', 'scripts/attach-project.sh', 'scripts/lib',
                     'scripts/tests/helpers/bench-attach-lock-pins.py', gitconfig=gitconfig)
        if status:
            raise ValueError('candidate executable inputs or driver are not clean')
    source = repo / 'scripts/lib/attach-fastpath.py'
    explicit_checks = validate_recheck_count(source)
    source_paths = ['scripts/attach-project.sh', 'scripts/lib/attach-fastpath.py',
                    'scripts/lib/attachment.sh', 'scripts/lib/trellis-home.sh',
                    'scripts/lib/local-registry.sh', 'scripts/lib/release-executed.py',
                    'scripts/lib/release-store.sh', 'scripts/lib/surface-plan.sh',
                    'scripts/lib/semver.sh', 'scripts/lib/settings-hooks-merge.sh',
                    'scripts/lib/attach-postjob.sh']
    sources = {path: hashlib.sha256((repo / path).read_bytes()).hexdigest() for path in source_paths}
    tools = {name: tool_info(command) for name, command in {
        'bash': ['/bin/bash', '--version'], 'python': ['/usr/bin/python3', '--version'],
        'git': ['git', '--version'], 'jq': ['jq', '--version']}.items()}
    for relative in ('home', 'tmp', 'trellis', 'trellis/state', 'trellis/state/locks',
                     'trellis/locks', 'common', 'worktree', 'logs'):
        (output / relative).mkdir(mode=0o700)
    home = output / 'trellis'
    common = output / 'common'
    checkout = hashlib.sha256(os.fsencode(str(common))).hexdigest()
    worktree = hashlib.sha256(os.fsencode(str(output / 'worktree'))).hexdigest()
    attachment = '12345678-1234-4123-8123-123456789abc'
    worker, probe = output / 'worker.sh', output / 'probe.py'
    worker.write_text(WORKER, encoding='utf-8')
    probe.write_text(PROBE, encoding='utf-8')
    worker.chmod(0o600)
    probe.chmod(0o600)
    env = {'HOME': str(output / 'home'), 'TRELLIS_HOME': str(home), 'TMPDIR': str(output / 'tmp'),
           'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'LC_ALL': 'C',
           'GIT_CONFIG_GLOBAL': str(output / 'gitconfig'), 'GIT_CONFIG_NOSYSTEM': '1',
           'T13_ATTACH': str(repo / 'scripts/attach-project.sh'), 'T13_FASTPATH': str(source),
           'T13_PROBE': str(probe), 'T13_HOME': str(home), 'T13_COMMON': str(common),
           'T13_CHECKOUT': checkout, 'T13_WORKTREE': worktree, 'T13_ATTACHMENT': attachment}
    observations = []
    sequence = 0
    def run(arm):
        child_env = dict(env, T13_ARM=arm)
        return subprocess.run(['/bin/bash', str(worker)], env=child_env, capture_output=True, text=True, timeout=90)
    def verify(arm, result):
        nonlocal sequence
        sequence += 1
        (output / 'logs' / ('%04d-%s.stdout' % (sequence, arm))).write_text(result.stdout, encoding='utf-8')
        (output / 'logs' / ('%04d-%s.stderr' % (sequence, arm))).write_text(result.stderr, encoding='utf-8')
        expected = ['PROBE_READY ' + arm, 'LOCKBENCH_OK ' + arm]
        if result.returncode != 0 or result.stdout.splitlines() != expected:
            raise RuntimeError('lock fixture failed for {}: exit {} (see logs)'.format(arm, result.returncode))
        if any((home / 'state/locks').iterdir()) or any((home / 'locks').iterdir()):
            raise RuntimeError('lock fixture left a holder or alias after ' + arm)
    def record(row):
        observations.append(row)
        with (output / 'observations.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(row, sort_keys=True) + '\n')
            stream.flush()
            os.fsync(stream.fileno())
    measured = args.measure
    run_samples(run, record, measured=measured, samples=args.samples if measured else 1,
                warmups=args.warmups if measured else 0, load_limit=args.max_load, verify=verify)
    summary = {'schema': 1, 'mode': 'measurement' if measured else 'functional', 'head': head,
               'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'source_files': sources,
               'host': dict(platform.uname()._asdict()), 'tools': tools, 'path': env['PATH'],
               'operator_liveness_clear': args.liveness_clear,
               'driver_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               'worker_sha256': hashlib.sha256(WORKER.encode()).hexdigest(),
               'probe_sha256': hashlib.sha256(PROBE.encode()).hexdigest(),
               'arms': list(ARMS), 'explicit_rechecks': explicit_checks, 'implicit_scope_rechecks': 2,
               'samples': args.samples if measured else 1, 'warmups': args.warmups if measured else 0,
               'max_load': args.max_load if measured else None, 'observations': observations,
               'results': summarize(observations) if measured else None,
               'scope': 'synthetic canonical lock acquire/release; single-pin arms measure open and checked close; '
                        'full also includes Python scope entry, four explicit rechecks and exit; not full attach or SC1',
               'limitations': 'checkout and attachment locks belong to the same fixture shell, unlike the real '
                              'nested donor shell; a duplicated checkout fd models the parent close but not its fork; '
                              'baseline uses the same Python startup but no authorization check; within-round '
                              'differences are diagnostics, not SC1 percentile savings'}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    print(json.dumps({'mode': summary['mode'], 'output': str(output), 'head': head}, sort_keys=True))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print('lock-pin benchmark refused: ' + str(error), file=sys.stderr)
        sys.exit(1)
