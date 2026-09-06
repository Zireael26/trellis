#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skill-eval-v2.XXXXXX")"
  export REPO TEST_ROOT
  : "${AGGREGATE_SCRIPT:?explicit installed aggregate script required}"
  export AGGREGATE_SCRIPT
  cat > "$TEST_ROOT/check.py" <<'PY'
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from decimal import Decimal

sys.dont_write_bytecode = True
repo, temporary = Path(os.environ['REPO']), Path(os.environ['TEST_ROOT'])
packer = Path(os.environ.get('PACKER', repo / 'scripts/skill-eval-v2.py'))
plugin = Path(os.environ['AGGREGATE_SCRIPT'])
validator_path = repo / 'core-rules/skills/wiki-skill-propose/scripts/validate_proposal.py'
spec = importlib.util.spec_from_file_location('canonical', validator_path)
v = importlib.util.module_from_spec(spec)
sys.modules['canonical'] = v
spec.loader.exec_module(v)


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(65536), b''):
            digest.update(block)
    return digest.hexdigest()


def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value) + '\n')


def tree(path):
    # Independent SCHEMA grammar, as in wiki-skill-promotion's evidence producer.
    records = []
    for child in path.rglob('*'):
        if child.is_file():
            name = child.relative_to(path).as_posix().encode()
            executable = b'1' if child.stat().st_mode & 0o111 else b'0'
            records.append((name, executable + b'\0' + sha(child).encode()))
    return hashlib.sha256(b''.join(n + b'\0' + rest + b'\n' for n, rest in sorted(records))).hexdigest()


def fixture(name):
    root = temporary / name
    run = root / 'evidence'
    candidate = run / 'candidate'
    candidate.mkdir(parents=True)
    (candidate / 'SKILL.md').write_text('---\nname: sample\n---\nFixture only, not native evidence.\n')
    # The SCHEMA grammar digests the executable bit: keep one before candidate_hash.
    helper = candidate / 'run.sh'
    helper.write_text('#!/bin/sh\necho fixture helper\n')
    helper.chmod(0o755)
    tasks, snapshots = [], []
    for n in range(1, 5):
        task = run / 'tasks' / str(n)
        task.mkdir(parents=True)
        (task / 'prompt.md').write_text('Held out fixture task ' + str(n))
        tasks.append(dict(eval_id=n, task_id='task-' + str(n), snapshot_sha256=tree(task)))
        snapshots.append(dict(eval_id=n, path=task.relative_to(root).as_posix()))
    cohort = dict(tasks=tasks, executor=dict(route='openai::openai/gpt-test', harness='pi', harness_version='fixture-1', settings={'temperature': '0'}, common_policy_sha256='a' * 64), grader=dict(route='anthropic::anthropic/claude-test', config_sha256='b' * 64), repetitions=3, seed='unseeded')
    candidate_hash = tree(candidate)
    provenance = run / 'provenance.md'
    provenance.write_text('Retained fixture provenance, not an authenticity claim.\n')
    artifacts = []
    for task in tasks:
        n = task['eval_id']
        dump(run / f'eval-{n}/eval_metadata.json', {'eval_id': n})
        for config in ('with_skill', 'without_skill'):
            for repetition in range(1, 4):
                native = run / f'eval-{n}' / config / f'run-{repetition}'
                passed = config == 'with_skill' and (n, repetition) != (4, 3)
                grade = dict(summary=dict(passed=int(passed), failed=int(not passed), total=1, pass_rate=int(passed)), expectations=[dict(text='fixture assertion', passed=passed, evidence='fixture output')])
                dump(native / 'grading.json', grade)
                dump(native / 'timing.json', dict(total_duration_seconds=0, total_tokens=0))
                output = native / 'output.txt'
                output.write_text('Synthetic native transcript fixture\n')
                ref = lambda p: dict(path=p.relative_to(root).as_posix(), sha256=sha(p))
                receipt = dict(schema_version=1, eval_id=n, configuration=config, run_number=repetition, status='executed', exit_code=0, native_session_id=f'fixture-{n}-{config}-{repetition}', observed_executor=cohort['executor'], treatment_sha256=candidate_hash if config == 'with_skill' else None, output=ref(output), grade=dict(route=cohort['grader']['route'], config_sha256=cohort['grader']['config_sha256'], pass_rate=str(int(passed)), output=ref(native / 'grading.json')))
                raw = native / 'receipt.json'
                dump(raw, receipt)
                artifacts.append(dict(eval_id=n, configuration=config, run_number=repetition, **ref(raw)))
    evaluation = dict(cohort=cohort, cohort_id=hashlib.sha256(json.dumps(cohort, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()).hexdigest(), candidate_sha256=candidate_hash, candidate_snapshot='evidence/candidate', task_snapshots=snapshots, provenance=[dict(pattern='sample', path='evidence/provenance.md', sha256=sha(provenance))], benchmark=dict(path='evidence/benchmark.json', sha256='0' * 64), run_dir='evidence', artifacts=artifacts, incumbents=[])
    dump(root / 'draft.json', evaluation)
    return root, evaluation


def invoke(root, evaluation, selected=plugin, digest=None):
    dump(root / 'draft.json', evaluation)
    inputs = {str(p.relative_to(root)): sha(p) for p in root.rglob('*') if p.is_file() and not p.is_symlink()}
    argv = [sys.executable, str(packer), '--root', str(root), '--evaluation', str(root / 'draft.json'), '--skill', 'sample', '--aggregate-script', str(selected), '--aggregate-sha256', digest or sha(selected)]
    result = subprocess.run(argv, capture_output=True, text=True, timeout=35)
    print(json.dumps(dict(command=argv, raw_exit=result.returncode, stdout=result.stdout, stderr=result.stderr)))
    for name, digest in inputs.items():
        assert sha(root / name) == digest, 'earlier input modified: ' + name
    return result


def reject(name, change, selected=plugin, digest=None):
    root, e = fixture(name)
    change(root, e)
    result = invoke(root, e, selected, digest)
    assert result.returncode != 0, 'invalid evidence accepted: ' + name
    assert not (root / 'evidence/evaluation.json').exists(), 'finalized success artifact leaked'
    if name != 'preexisting':
        assert not (root / 'evidence/benchmark.json').exists(), 'provisional benchmark leaked'


def raw_change(root, e, change):
    artifact = e['artifacts'][0]
    path = root / artifact['path']
    raw = json.loads(path.read_text())
    change(raw)
    dump(path, raw)
    artifact['sha256'] = sha(path)


def grade_change(root, e, change):
    artifact = e['artifacts'][0]
    raw_path = root / artifact['path']
    raw = json.loads(raw_path.read_text())
    path = root / raw['grade']['output']['path']
    grade = json.loads(path.read_text())
    change(grade)
    dump(path, grade)
    raw['grade']['output']['sha256'] = sha(path)
    dump(raw_path, raw)
    artifact['sha256'] = sha(raw_path)


def command(root, selected=plugin):
    return [sys.executable, str(packer), '--root', str(root), '--evaluation', str(root / 'draft.json'), '--skill', 'sample', '--aggregate-script', str(selected), '--aggregate-sha256', sha(selected)]


def execute(argv):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=35)
    print(json.dumps(dict(command=argv, raw_exit=result.returncode, stdout=result.stdout, stderr=result.stderr)))
    return result


def no_outputs(root):
    assert not (root / 'evidence/evaluation.json').exists(), 'finalized success artifact leaked'
    assert not (root / 'evidence/benchmark.json').exists(), 'provisional benchmark leaked'


def sparse(path, size):
    with path.open('wb') as stream:
        stream.truncate(size)


case = sys.argv[1]
if case == 'valid':
    root, e = fixture('valid')
    assert invoke(root, e).returncode == 0
    final = v.parse_evaluation(v.load_json(root / 'evidence/evaluation.json', 'final'), 'final')
    bound = v.bind_evaluation(root, final, 'sample', 'test', expected_patterns=('sample',), expected_benchmark_relative=final.benchmark.path, expected_candidate_dir=root / 'evidence/candidate')
    assert bound.score == Decimal(11) / Decimal(12)
    assert (root / 'evidence/candidate/run.sh').stat().st_mode & 0o111, 'executable candidate fixture lost its mode'
    assert final.candidate_sha256 == tree(root / 'evidence/candidate') == e['candidate_sha256'], 'executable-sensitive candidate digest did not survive publication'
    benchmark = v.load_json(root / 'evidence/benchmark.json', 'benchmark')
    assert set(benchmark) == v.BENCHMARK_TOP_LEVEL_FIELDS
    assert benchmark['metadata']['skill_path'] == str(root / 'evidence/candidate')
    assert benchmark['metadata']['executor_model'] == e['cohort']['executor']['route']
    assert benchmark['metadata']['analyzer_model'] == e['cohort']['grader']['route']
    assert all(r['result']['tokens'] == 0 and r['result']['tool_calls'] is None for r in benchmark['runs'])
    assert benchmark['run_summary']['with_skill']['pass_rate']['mean'] == Decimal('0.9166666666666666666666666667')
    assert benchmark['run_summary']['delta']['pass_rate'] == '+0.9166666666666666666666666667'
elif case == 'identity':
    changes = {'identity': lambda r: r.update(eval_id=2), 'executor': lambda r: r['observed_executor'].update(harness_version='wrong'), 'grade-route': lambda r: r['grade'].update(route='other::other/model'), 'grade-config': lambda r: r['grade'].update(config_sha256='c'*64), 'treatment': lambda r: r.update(treatment_sha256='c'*64), 'failed': lambda r: r.update(exit_code=1), 'unavailable': lambda r: r.update(status='unavailable'), 'bool-exit': lambda r: r.update(exit_code=False), 'raw-hash': lambda r: r['output'].update(sha256='c'*64), 'grade-rate': lambda r: r['grade'].update(pass_rate='0')}
    for name, change in changes.items():
        reject(name, lambda root, e: raw_change(root, e, change))
elif case == 'inventory':
    reject('missing-artifact', lambda root, e: e['artifacts'].pop())
    reject('duplicate', lambda root, e: e['artifacts'].__setitem__(1, e['artifacts'][0]))
    reject('unexpected-run', lambda root, e: (root / 'evidence/eval-1/with_skill/run-4').mkdir())
    reject('missing-run', lambda root, e: shutil.rmtree(root / 'evidence/eval-1/with_skill/run-3'))
    reject('unexpected-config', lambda root, e: (root / 'evidence/eval-1/old_skill').mkdir())
    reject('metadata', lambda root, e: dump(root / 'evidence/eval-1/eval_metadata.json', {'eval_id': True}))
    reject('unsafe-path', lambda root, e: e.update(candidate_snapshot='../escape'))
    reject('symlink', lambda root, e: (root / 'evidence/link').symlink_to(root / 'evidence/candidate'))
    reject('candidate-hash', lambda root, e: (root / 'evidence/candidate/SKILL.md').write_text('drift'))
elif case == 'metrics':
    for filename in ('grading.json', 'timing.json'):
        reject('missing-' + filename, lambda root, e: (root / 'evidence/eval-1/with_skill/run-1' / filename).unlink())
    for key in ('passed', 'failed', 'total', 'pass_rate'):
        reject('missing-' + key, lambda root, e: grade_change(root, e, lambda g: g['summary'].pop(key)))
    reject('bool-rate', lambda root, e: grade_change(root, e, lambda g: g['summary'].update(pass_rate=True)))
    reject('fractional-rounded-rate', lambda root, e: grade_change(root, e, lambda g: g.update(summary=dict(passed=2, failed=1, total=3, pass_rate=0.6667), expectations=[dict(text='a', evidence='b', passed=p) for p in (True, True, False)])))
    for content in ('{"total_tokens":0}', '{"total_tokens":0,"total_duration_seconds":NaN}', '{"total_tokens":0,"total_tokens":1,"total_duration_seconds":0}'):
        reject('bad-timing-' + str(len(content)), lambda root, e: (root / 'evidence/eval-1/with_skill/run-1/timing.json').write_text(content))
    reject('duplicate-grade-json', lambda root, e: (root / 'evidence/eval-1/with_skill/run-1/grading.json').write_text('{"summary":{},"summary":{}}'))
elif case == 'publication':
    reject('wrong-plugin-digest', lambda root, e: None, digest='0'*64)
    reject('preexisting', lambda root, e: (root / 'evidence/benchmark.json').write_text('earlier run'))
    root, e = fixture('preexisting-evaluation')
    final = root / 'evidence/evaluation.json'
    final.write_text('earlier evaluation')
    assert invoke(root, e).returncode != 0 and final.read_text() == 'earlier evaluation'
    drifting = temporary / 'drifting.py'
    drifting.write_text(plugin.read_text().replace('    results = load_run_results(benchmark_dir)', '    (benchmark_dir / "provenance.md").write_text("drift")\n    results = load_run_results(benchmark_dir)'))
    root, e = fixture('drift')
    result = subprocess.run([sys.executable, str(packer), '--root', str(root), '--evaluation', str(root / 'draft.json'), '--skill', 'sample', '--aggregate-script', str(drifting), '--aggregate-sha256', sha(drifting)], capture_output=True, text=True, timeout=35)
    print(json.dumps(dict(raw_exit=result.returncode, stderr=result.stderr)))
    assert result.returncode != 0 and 'drift' in result.stderr
    assert not (root / 'evidence/evaluation.json').exists()
    # Observe the real hard-link destinations, not merely their post-flush presence.
    root, e = fixture('publication-order')
    driver = root / 'order.py'
    driver.write_text('''import importlib.util, json, os, pathlib, sys
spec = importlib.util.spec_from_file_location('packer_order', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sys.argv = sys.argv[1:]
root = pathlib.Path(sys.argv[sys.argv.index('--root') + 1])
destinations = []
original_link = os.link
def link(source, destination, *args, **kwargs):
    destinations.append(str(destination))
    return original_link(source, destination, *args, **kwargs)
os.link = link
result = m.main()
(root / 'link-order.json').write_text(json.dumps(dict(result=result, destinations=destinations)))
raise SystemExit(result)
''')
    result = execute([sys.executable, str(driver), *command(root)[1:]])
    order = json.loads((root / 'link-order.json').read_text())
    assert result.returncode == 0 and order['result'] == 0, 'publication driver did not publish'
    assert order['destinations'] == [str(root / 'evidence/benchmark.json'), str(root / 'evidence/evaluation.json')], 'publication hard-link order is not benchmark then evaluation: ' + json.dumps(order['destinations'])
elif case == 'final-binding':
    tampered = temporary / 'tampered.py'
    text = plugin.read_text()
    assert text.count('    return benchmark\n') == 1
    tampered.write_text(text.replace('    return benchmark\n', '    benchmark["metadata"]["skill_name"] = "wrong-skill"\n    return benchmark\n'))
    reject('tampered-generated-benchmark', lambda root, e: None, selected=tampered)
elif case == 'bounds-files':
    for name in ('unused', 'draft', 'grading', 'plugin'):
        root, e = fixture('oversized-' + name)
        selected = plugin
        path = {'unused': root / 'evidence/unused', 'draft': root / 'draft.json', 'grading': root / 'evidence/eval-1/with_skill/run-1/grading.json', 'plugin': root / 'oversized-plugin.py'}[name]
        sparse(path, (16 << 20) + 1)
        if name == 'plugin':
            selected = path
        before = sha(path)
        result = execute(command(root, selected))
        assert result.returncode != 0 and 'file limit exceeded' in result.stderr, 'oversized admission not enforced: ' + name
        assert sha(path) == before
        no_outputs(root)
    root, e = fixture('generated')
    selected = temporary / 'generated.py'
    text = plugin.read_text()
    assert text.count('    return benchmark\n') == 1
    selected.write_text(text.replace('    return benchmark\n', '    benchmark["notes"].append("x" * (17 << 20))\n    return benchmark\n'))
    result = execute(command(root, selected))
    assert result.returncode != 0 and 'generated file limit exceeded' in result.stderr, 'generated output limit not enforced'
    no_outputs(root)
elif case == 'bounds-inventory':
    for kind in ('files', 'directories'):
        root, e = fixture('count-' + kind)
        for index in range(4097):
            path = root / 'evidence' / f'extra-{index}'
            path.mkdir() if kind == 'directories' else path.touch()
        result = execute(command(root))
        assert result.returncode != 0 and 'entry limit exceeded' in result.stderr, 'total entry admission not enforced: ' + kind
        no_outputs(root)
    root, e = fixture('aggregate')
    for index in range(17):
        sparse(root / 'evidence' / f'large-{index}', 16 << 20)
    result = execute(command(root))
    assert result.returncode != 0 and 'aggregate limit exceeded' in result.stderr, 'aggregate admission not enforced'
    no_outputs(root)
elif case == 'snapshot-drift':
    for mutation in ('grow', 'replace', 'add', 'remove', 'source'):
        root, e = fixture('live-' + mutation)
        selected = temporary / ('live-' + mutation + '.py')
        live = root / 'evidence/eval-1/with_skill/run-1/grading.json'
        marker = root / 'bounded-copy-observed'
        if mutation == 'grow':
            change = f'    with open({str(live)!r}, "ab") as live_file: live_file.truncate((16 << 20) + 1)\n'
        elif mutation == 'replace':
            replacement = live.with_name('replacement')
            change = f'    Path({str(replacement)!r}).write_bytes(Path({str(live)!r}).read_bytes())\n    Path({str(replacement)!r}).replace(Path({str(live)!r}))\n'
        elif mutation == 'add':
            # Every surviving original entry stays byte- and identity-identical.
            change = f'    Path({str(root / "evidence/added-entry")!r}).write_text("appeared during plugin execution\\n")\n'
        elif mutation == 'remove':
            change = f'    Path({str(root / "evidence/provenance.md")!r}).unlink()\n'
        else:
            change = f'    with open({str(selected)!r}, "a") as source: source.write("\\n# live source drift\\n")\n'
        probe = f'    assert benchmark_dir != Path({str(root / "evidence")!r}), "dependency received live evidence"\n' + change + f'    copied_grade = benchmark_dir / "eval-1/with_skill/run-1/grading.json"\n    assert copied_grade.stat().st_size < (16 << 20)\n    assert json.loads(copied_grade.read_text())["summary"]["total"] == 1\n    Path({str(marker)!r}).write_text("bounded copy read")\n'
        text = plugin.read_text()
        assert text.count('    results = load_run_results(benchmark_dir)') == 1
        selected.write_text(text.replace('    results = load_run_results(benchmark_dir)', probe + '    results = load_run_results(benchmark_dir)'))
        result = execute(command(root, selected))
        assert marker.exists(), 'plugin did not read bounded private evidence'
        assert result.returncode != 0 and ('drift' in result.stderr or 'file limit exceeded' in result.stderr), 'original drift accepted: ' + mutation
        if mutation in ('add', 'remove'):
            assert 'consumed input drift before publication' in result.stderr, 'exact original inventory not revalidated: ' + mutation
        no_outputs(root)
elif case == 'stdout-rollback':
    for failure in ('broken', 'alarm', 'replacement', 'cleanup'):
        root, e = fixture('stdout-' + failure)
        driver = root / 'driver.py'
        driver.write_text('''import importlib.util, pathlib, signal, sys
spec = importlib.util.spec_from_file_location('packer_test', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sys.argv = sys.argv[1:]
root = pathlib.Path(sys.argv[sys.argv.index('--root') + 1])
failure = ''' + repr(failure) + '''
arms = []
original_timer = signal.setitimer
def timer(which, seconds, *args):
    arms.append(seconds)
    return original_timer(which, seconds, *args)
signal.setitimer = timer
original_unlink = pathlib.Path.unlink
def unlink(path, *args, **kwargs):
    if failure == 'cleanup' and path == root / 'evidence/evaluation.json':
        raise PermissionError('controlled cleanup failure')
    return original_unlink(path, *args, **kwargs)
pathlib.Path.unlink = unlink
class Output:
    def write(self, value):
        return len(value)
    def flush(self):
        assert (root / 'evidence/evaluation.json').is_file(), 'flush before final artifact'
        assert arms == [30] and signal.getitimer(signal.ITIMER_REAL)[0] > 0, 'original alarm not active'
        if failure == 'alarm':
            signal.getsignal(signal.SIGALRM)(signal.SIGALRM, None)
        if failure == 'replacement':
            final = root / 'evidence/evaluation.json'
            other = final.with_name('other')
            other.write_text('not owned')
            other.replace(final)
        raise BrokenPipeError('controlled stdout failure')
previous = sys.stdout
sys.stdout = Output()
try:
    result = m.main()
finally:
    sys.stdout = previous
assert arms == [30, 0], arms
raise SystemExit(result)
''')
        result = execute([sys.executable, str(driver), *command(root)[1:]])
        expected = 'TimeoutError: 30-second' if failure == 'alarm' else 'BrokenPipeError: controlled stdout failure'
        assert result.returncode == 1 and expected in result.stderr, 'publication failure not controlled: ' + failure
        assert not (root / 'evidence/benchmark.json').exists(), 'benchmark leaked on stdout failure'
        if failure == 'replacement':
            assert (root / 'evidence/evaluation.json').read_text() == 'not owned', 'unowned replacement removed'
        elif failure == 'cleanup':
            assert 'cleanup unavailable:' in result.stderr and 'controlled cleanup failure' in result.stderr
        else:
            no_outputs(root)
    root, e = fixture('closed-pipe')
    read_fd, write_fd = os.pipe()
    os.close(read_fd)
    argv = command(root)
    try:
        result = subprocess.run(argv, stdout=write_fd, stderr=subprocess.PIPE, text=True, timeout=35)
    finally:
        os.close(write_fd)
    print(json.dumps(dict(command=argv, raw_exit=result.returncode, stderr=result.stderr)))
    assert result.returncode != 0 and 'BrokenPipeError' in result.stderr
    no_outputs(root)
else:
    raise AssertionError('unknown case')
PY
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "strict packer binds canonical four-task evidence with exact 11/12 mean" {
  python3 "$TEST_ROOT/check.py" valid
}

@test "strict packer rejects raw identity route treatment status and hash mismatches" {
  python3 "$TEST_ROOT/check.py" identity
}

@test "strict packer rejects incomplete unexpected duplicate and unsafe inventory" {
  python3 "$TEST_ROOT/check.py" inventory
}

@test "strict packer refuses unavailable malformed and rounded metrics" {
  python3 "$TEST_ROOT/check.py" metrics
}

@test "strict packer refuses plugin drift digest mismatch and preexisting publication" {
  python3 "$TEST_ROOT/check.py" publication
}

@test "strict packer final binding rejects tampered generated benchmark" {
  python3 "$TEST_ROOT/check.py" final-binding
}

@test "strict packer bounds evidence draft plugin and generated serialization" {
  python3 "$TEST_ROOT/check.py" bounds-files
}

@test "strict packer bounds total entries including directories and aggregate bytes" {
  python3 "$TEST_ROOT/check.py" bounds-inventory
}

@test "strict packer dependencies read private copies and reject live growth replacement and source drift" {
  python3 "$TEST_ROOT/check.py" snapshot-drift
}

@test "strict packer rolls back failed flushed stdout under its original alarm" {
  python3 "$TEST_ROOT/check.py" stdout-rollback
}
