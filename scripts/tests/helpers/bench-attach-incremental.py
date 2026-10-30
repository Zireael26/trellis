"""Compare exact-owner attach with a pinned baseline on a private fixture."""
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import time


def run(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise AssertionError((args, result.returncode, result.stdout, result.stderr))
    return result.stdout


def resolve_baseline(repo, ref='2f101f0d'):
    return run(['git', '-C', str(repo), 'rev-parse', '--verify', ref + '^{commit}']).strip()


def main():
    if len(sys.argv) not in (6, 7):
        raise SystemExit('usage: bench-attach-incremental.py ATTACH HOME PROJECT SANDBOX REPORT [BASELINE_REF]')
    attach, home, project, sandbox, report = map(Path, sys.argv[1:6])
    baseline_ref = sys.argv[6] if len(sys.argv) == 7 else '2f101f0d'
    if home.parent != sandbox or not sandbox.name.startswith('a5b.fixture.'):
        raise SystemExit('bench requires an a5b.fixture.* private home')
    if os.environ.get('TRELLIS_ATTACH_POSTJOB') != 'off':
        raise SystemExit('bench requires deferred fixture jobs disabled')
    repo = attach.parent.parent
    baseline_commit = resolve_baseline(repo, baseline_ref)
    baseline = sandbox / 'baseline/scripts'
    baseline.mkdir(parents=True)
    shutil.copytree(attach.parent / 'lib', baseline / 'lib')
    for relative in ('scripts/attach-project.sh', 'scripts/lib/attachment.sh',
                     'scripts/lib/attach-fastpath.py', 'scripts/lib/health-checks.sh'):
        destination = sandbox / 'baseline' / relative
        destination.write_text(run(['git', '-C', str(repo), 'show', baseline_commit + ':' + relative]))
    for index in range(10):
        target = sandbox / ('incremental-%d' % index)
        run(['git', '-C', str(project), 'worktree', 'add', '-qb', 'incremental-%d' % index, str(target)])
        run(['/bin/bash', str(attach), 'attach', '--home', str(home), '--fleet', 'personal',
             '--release', '1.2.3', str(target)])
    owner_paths = sorted((home / 'state/attachments').glob('*/*.json'))
    assert len(owner_paths) == 11
    before = {str(path): path.read_bytes() for path in owner_paths + [home / 'registry.json']}
    samples = {'before': [], 'after': []}
    loads = []
    for _ in range(3):
        for label, script in (('before', baseline / 'attach-project.sh'), ('after', attach)):
            loads.append(list(os.getloadavg()))
            if loads[-1][0] > 22:
                raise SystemExit('load1 exceeds the worker budget; retry later')
            start = time.monotonic()
            output = run(['/bin/bash', str(script), 'attach', '--home', str(home),
                          '--fleet', 'personal', '--release', '1.2.3', str(project)])
            samples[label].append(round((time.monotonic() - start) * 1000, 2))
            assert 'already attached:' in output
            assert all(Path(path).read_bytes() == data for path, data in before.items())
    medians = {label: statistics.median(values) for label, values in samples.items()}
    result = {'owners': len(owner_paths), 'siblings': 10, 'samples_ms': samples,
              'median_ms': medians, 'saved_percent': round(100 * (1 - medians['after'] / medians['before']), 2),
              'load_average': loads, 'baseline': baseline_commit, 'baseline_ref': baseline_ref,
              'scope': 'whole synchronous exact-current attach; alternating serial runs; deferred jobs off; state byte-unchanged'}
    report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
