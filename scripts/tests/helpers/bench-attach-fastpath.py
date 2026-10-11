"""Run the A5B synchronous attach bench against a caller-owned fixture only."""
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time


def summarize(samples):
    ordered = sorted(samples)
    return {'n': len(samples), 'p50_ms': statistics.median(ordered),
            'p95_ms': ordered[math.ceil(len(ordered) * .95) - 1]}


def main():
    attach, home, project, sandbox, report = sys.argv[1:]
    # Refuse a live/nonfixture home even if this helper is invoked by hand.
    if not (Path(home).parent == Path(sandbox) and Path(sandbox).name.startswith('a5b.fixture.')):
        raise SystemExit('bench requires an a5b.fixture.* private home')
    samples = []
    load = []
    for index in range(5):
        target = str(Path(sandbox) / ('bench-%d' % index))
        subprocess.run(['git', '-C', project, 'worktree', 'add', '-qb', 'bench-%d' % index, target], check=True)
        load.append(os.getloadavg())
        start = time.monotonic()
        result = subprocess.run([attach, 'attach', '--home', home, '--fleet', 'personal', '--release', '1.2.3', target], capture_output=True, text=True)
        samples.append((time.monotonic() - start) * 1000)
        if result.returncode or 'attached (donor fast path):' not in result.stdout:
            raise AssertionError((result.returncode, result.stdout, result.stderr))
    result = dict(summarize(samples), samples_ms=samples, load_average=load,
                  fixture_home=home, scope='full synchronous attach command; worktree creation excluded')
    Path(report).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
