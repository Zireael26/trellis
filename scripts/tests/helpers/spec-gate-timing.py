#!/usr/bin/env python3
"""Paired, isolated spec-gate CLI timing. Not an end-to-end push benchmark.

Example (both trees must contain the same runtime trellis.config.json):
  python3 -I perf-150-spec-gate-bench.py --baseline /path/to/base-export \
    --candidate /path/to/candidate-checkout --output /private/new-output-dir

The fixture is a fresh local repository with a tracked project manifest that
omits mandatory_pipeline, so the real resolver must read the enabled runtime
policy. Each invocation uses the explicit ref/head/range shape of pre-push.
No installed Trellis home, global Git configuration, network or real remote is
used. Every stdout/stderr/status is checked against the paired control. Counts
are obtained separately through executable shims, outside the timed samples.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load():
    try:
        return list(os.getloadavg())
    except OSError:
        return None


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def run(argv, *, cwd, env, check=True, input_bytes=None):
    p = subprocess.run(argv, cwd=cwd, env=env, input=input_bytes,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and p.returncode:
        raise RuntimeError(f"{argv!r} exited {p.returncode}: {p.stderr.decode(errors='replace')}")
    return p


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True,
                        help='new private directory; never overwrites an existing result')
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--warmups', type=int, default=2)
    parser.add_argument('--shell', default='/bin/bash')
    parser.add_argument('--max-load', type=float, default=40.0)
    args = parser.parse_args()
    if args.samples < 1 or args.warmups < 0:
        parser.error('samples must be positive and warmups nonnegative')
    base = args.baseline.resolve(strict=True)
    candidate = args.candidate.resolve(strict=True)
    shell = str(Path(args.shell).resolve(strict=True))
    root = args.output.absolute()
    root.mkdir(mode=0o700, parents=False, exist_ok=False)
    home, trellis, tmp, project, shim = (root / name for name in ('home', 'trellis', 'tmp', 'project', 'shims'))
    for directory in (home, trellis, tmp, project, shim):
        directory.mkdir(mode=0o700)
    config = root / 'gitconfig'
    config.write_text('')
    # Do not inherit untrusted Git redirects, shell startup files, or live homes.
    path = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
    env = {'HOME': str(home), 'TRELLIS_HOME': str(trellis), 'TMPDIR': str(tmp),
           'GIT_CONFIG_GLOBAL': str(config), 'GIT_CONFIG_NOSYSTEM': '1',
           'PATH': path, 'LC_ALL': 'C', 'TRELLIS_ATTACH_POSTJOB': 'off'}
    git = shutil.which('git', path=path)
    jq = shutil.which('jq', path=path)
    if not git or not jq:
        raise RuntimeError('git and jq are required on the controlled PATH')
    required = ['trellis.config.json', 'core-rules/hooks/spec-gate.sh',
                'core-rules/hooks/lib/spec-gate-core.sh', 'core-rules/hooks/lib/deps.sh',
                'core-rules/hooks/lib/autonomy.sh',
                'core-rules/skills/process-gate/scripts/lib/diff-base.sh']
    sources = {}
    for name, tree in (('baseline', base), ('candidate', candidate)):
        sources[name] = {item: digest(tree / item) for item in required}
    if sources['baseline']['trellis.config.json'] != sources['candidate']['trellis.config.json']:
        raise RuntimeError('runtime policy differs between arms')
    cfg = json.loads((base / 'trellis.config.json').read_bytes())
    if cfg.get('mandatory_pipeline', {}).get('enabled') is not True:
        raise RuntimeError('benchmark runtime mandatory_pipeline must be enabled')
    git_common = [git, '-c', 'user.name=Spec Gate Fixture',
                  '-c', 'user.email=fixture@example.invalid',
                  '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null']
    def fixture_git(*cmd):
        return run([*git_common, *cmd], cwd=project, env=env).stdout.decode().strip()
    fixture_git('init', '-q', '-b', 'main')
    (project / '.trellis.json').write_text('{"schema_version":1,"project_id":"bench-fixture"}\n')
    (project / 'README.md').write_text('fixture\n')
    fixture_git('add', '.trellis.json', 'README.md')
    fixture_git('commit', '-qm', 'base')
    base_sha = fixture_git('rev-parse', 'HEAD')
    fixture_git('update-ref', 'refs/remotes/origin/main', base_sha)
    fixture_git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
    fixture_git('checkout', '-qb', 'feature/spec-gate-bench')
    (project / 'src').mkdir()
    (project / 'src/probe.txt').write_text('one gated line\n')
    fixture_git('add', 'src/probe.txt')
    fixture_git('commit', '-qm', 'fixture change')
    head = fixture_git('rev-parse', 'HEAD')
    revision = f'{base_sha}..{head}'
    ref = 'refs/heads/feature/spec-gate-bench'
    if fixture_git('status', '--porcelain'):
        raise RuntimeError('fixture repository is dirty before timing')

    load_samples = []
    deadline = time.monotonic() + 1200
    while True:
        observed = load()
        load_samples.append({'at': stamp(), 'load': observed})
        if observed is None or observed[0] < args.max_load or time.monotonic() >= deadline:
            break
        time.sleep(30)
    (root / 'load-wait.json').write_text(json.dumps(load_samples, indent=2) + '\n')

    trees = {'baseline': base, 'candidate': candidate}
    def invoke(name, instrument=False):
        runtime = trees[name]
        execution_env = dict(env, TRELLIS_ROOT=str(runtime))
        if instrument:
            execution_env.update(PATH=str(shim) + ':' + path,
                                 SG_BENCH_TRACE=str(root / (name + '-execs.txt')),
                                 SG_BENCH_REAL_GIT=git, SG_BENCH_REAL_JQ=jq)
        argv = [shell, '-p', str(runtime / 'core-rules/hooks/spec-gate.sh'),
                '--gate', '--ref', ref, '--head', head, '--range', revision]
        before = load()
        at = stamp()
        start = time.monotonic_ns()
        result = run(argv, cwd=project, env=execution_env, check=False, input_bytes=b'')
        elapsed = (time.monotonic_ns() - start) / 1_000_000
        return {'arm': name, 'at': at, 'load_before': before, 'load_after': load(),
                'duration_ms': elapsed, 'exit': result.returncode,
                'stdout': result.stdout.decode('utf-8', errors='backslashreplace'),
                'stderr': result.stderr.decode('utf-8', errors='backslashreplace')}

    def check_pair(a, b):
        if a['exit'] != 0 or b['exit'] != 0:
            raise RuntimeError(f'gate did not pass: {a!r} / {b!r}')
        if not a['stdout'].startswith('diff-base: '):
            raise RuntimeError(f'gate did not emit its exact-range receipt: {a!r}')
        if any(a[k] != b[k] for k in ('exit', 'stdout', 'stderr')):
            raise RuntimeError(f'gate output/status differs: {a!r} / {b!r}')

    # Prove the actual verdict is enabled + sub-floor, not a disabled shortcut.
    verdicts = []
    for name, tree in trees.items():
        e = dict(env, TRELLIS_ROOT=str(tree))
        script = '. "$1"; sg_verdict "$PWD" "$2" "$3" "$4"'
        p = run([shell, '-p', '-c', script, '_', str(tree / 'core-rules/hooks/lib/spec-gate-core.sh'),
                 revision, ref, head], cwd=project, env=e)
        text = p.stdout.decode()
        if not text.startswith('pass\t') or 'sub-floor(1<=' not in text:
            raise RuntimeError(f'{name}: unexpected enabled fixture verdict: {text!r}')
        verdicts.append(text)
    if verdicts[0] != verdicts[1]:
        raise RuntimeError('preflight verdicts differ')
    (root / 'verdict.txt').write_text(verdicts[0])
    samples = []
    for i in range(args.warmups + args.samples):
        order = ('baseline', 'candidate') if i % 2 == 0 else ('candidate', 'baseline')
        pair = {name: invoke(name) for name in order}
        check_pair(pair['baseline'], pair['candidate'])
        for name in order:
            item = pair[name]
            item.update(iteration=i, warmup=i < args.warmups)
            samples.append(item)
    (root / 'samples.json').write_text(json.dumps(samples, indent=2) + '\n')

    for name in ('git', 'jq'):
        executable = shim / name
        executable.write_text('#!/bin/sh\nprintf "%s %s\\n" "' + name +
                              '" "$*" >> "$SG_BENCH_TRACE"\nexec "$SG_BENCH_REAL_' + name.upper() + '" "$@"\n')
        executable.chmod(0o700)
    baseline_counted = invoke('baseline', True)
    candidate_counted = invoke('candidate', True)
    check_pair(baseline_counted, candidate_counted)
    counts = {}
    for name in trees:
        entries = (root / (name + '-execs.txt')).read_text().splitlines()
        counts[name] = {tool: sum(x.startswith(tool + ' ') for x in entries) for tool in ('git', 'jq')}
    groups = {name: [x['duration_ms'] for x in samples if x['arm'] == name and not x['warmup']]
              for name in trees}
    summary = {'status': 'ok', 'scope': 'standalone pre-push spec-gate CLI, not full git push or SC13',
               'host': platform.platform(), 'shell': shell, 'git': git, 'jq': jq,
               'samples_per_arm': args.samples, 'warmups_per_arm': args.warmups,
               'source_sha256': sources, 'fixture_base': base_sha, 'fixture_head': head,
               'fixture_range': revision, 'fixture_ref': ref, 'command_shape':
               'bash -p <runtime>/core-rules/hooks/spec-gate.sh --gate --ref REF --head HEAD --range RANGE',
               'p50_ms': {name: statistics.median(values) for name, values in groups.items()},
               'min_ms': {name: min(values) for name, values in groups.items()},
               'max_ms': {name: max(values) for name, values in groups.items()},
               'separately_instrumented_exec_counts': counts,
               'load_wait': load_samples, 'finished_at': stamp()}
    (root / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'benchmark refused: {error}', file=sys.stderr)
        sys.exit(1)
