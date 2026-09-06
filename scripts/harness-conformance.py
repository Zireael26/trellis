#!/usr/bin/env python3
"""Source-only adapter fixture corpus. Caller supplies OS write/network containment.

No providers, native hosts, installed identity, cleanup, retries, or policy replicas.
All native outcomes remain unknown, including when an adapter says enforced.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import time

CASE_IDS = [
    'claude.reread-budget', 'claude.read-credit', 'claude.failed-read-registration',
    'codex.reread-budget', 'codex.read-credit', 'codex.failed-read',
    'codex.shell-no-credit', 'codex.patch-targets', 'codex.patch-lint',
    'codex.unsafe-targets', 'pi.pre-denial', 'pi.post-advisory',
    'pi.compact-missing', 'pi.failed-mutation', 'pi.spawner-boundary',
    'pi.command-discovery',
]
INPUT_ROOTS = ['core-rules/hooks', 'core-rules/codex/hooks', 'core-rules/pi',
               'core-rules/templates/claude-settings.local.json',
               'scripts/harness-conformance.py']
PATCH = ('*** Begin Patch\n*** Add File: new.py\n+x = 1\n'
         '*** Update File: existing.py\n@@\n-x = 0\n+x = 1\n'
         '*** Update File: old.py\n*** Move to: moved.py\n@@\n-x = 0\n+x = 1\n'
         '*** Delete File: gone.py\n*** End Patch')
TARGETS = [{'operation': 'create', 'path': 'new.py'},
           {'operation': 'update', 'path': 'existing.py'},
           {'operation': 'rename', 'path': 'old.py', 'destination': 'moved.py'},
           {'operation': 'delete', 'path': 'gone.py'}]


class Incomplete(Exception):
    """Setup, dependency, transport or deadline failure, never skipped-green."""


def check_deadline(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise Incomplete('whole corpus 180-second deadline exhausted')
    return remaining


def input_hashes(source: Path, deadline: float | None = None) -> dict:
    deadline = time.monotonic() + 180 if deadline is None else deadline
    result, visited, active = {}, set(), set()

    def resolve(path: Path, links: frozenset = frozenset()) -> Path:
        check_deadline(deadline)
        if not path.is_relative_to(source):
            raise Incomplete(f'escaping source symlink: {path}')
        current = source
        for part in path.relative_to(source).parts:
            check_deadline(deadline)
            if part == '..':
                if current == source:
                    raise Incomplete(f'escaping source symlink: {path}')
                current = current.parent
                continue
            current /= part
            if stat.S_ISLNK(current.lstat().st_mode):
                name = str(current.relative_to(source))
                if current in links:
                    raise Incomplete(f'source symlink cycle: {name}')
                text = os.readlink(current)
                result[name] = {'kind': 'symlink', 'sha256': hashlib.sha256(os.fsencode(text)).hexdigest()}
                target = Path(text)
                if not target.is_absolute():
                    target = current.parent / target
                # Resolve one hop at a time, including target ancestors. Never
                # collapse a chain before binding its intermediate link text.
                current = resolve(target, links | {current})
        return current

    def visit(path: Path):
        check_deadline(deadline)
        path = resolve(path)
        name = str(path.relative_to(source))
        if name in active:
            raise Incomplete(f'source directory cycle: {name}')
        if name in visited:
            return
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            active.add(name)
            for child in sorted(path.iterdir()):
                visit(child)
            active.remove(name)
        elif stat.S_ISREG(mode):
            digest = hashlib.sha256()
            with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as stream:
                while True:
                    check_deadline(deadline)
                    data = stream.read(1024 * 1024)
                    check_deadline(deadline)
                    if not data:
                        break
                    digest.update(data)
            result[name] = {'kind': 'file', 'sha256': digest.hexdigest()}
        else:
            raise Incomplete(f'non-regular source input: {name}')
        check_deadline(deadline)
        visited.add(name)

    for name in INPUT_ROOTS:
        visit(source / name)
    ordered = dict(sorted(result.items()))
    check_deadline(deadline)
    return ordered


class Corpus:
    def __init__(self, source: Path, scratch: Path):
        self.source, self.scratch = source, scratch
        self.deadline = time.monotonic() + 180
        self.serial = 0
        self.env = {'PATH': os.environ.get('PATH', ''), 'LC_ALL': 'C', 'TZ': 'UTC',
                    'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
                    'GIT_TERMINAL_PROMPT': '0', 'PYTHONDONTWRITEBYTECODE': '1'}
        for key, name in [('HOME', 'home'), ('TMPDIR', 'tmp'), ('TRELLIS_HOME', 'trellis-home')]:
            directory = scratch / name
            directory.mkdir()
            self.env[key] = str(directory)
        self.env['TMP'] = self.env['TEMP'] = self.env['TMPDIR']
        (scratch / 'raw').mkdir()
        self.runtime = {}

    def command(self, records, argv, cwd, payload=None, extra_env=None):
        argv = list(map(str, argv))
        stem = f'raw/{self.serial:03d}'
        self.serial += 1
        out, err = self.scratch / (stem + '.stdout'), self.scratch / (stem + '.stderr')
        record = {'argv': argv, 'cwd': str(cwd), 'exit_code': None, 'status': 'not_run',
                  'stdout_path': str(out.relative_to(self.scratch)),
                  'stderr_path': str(err.relative_to(self.scratch))}
        records.append(record)
        out.touch()
        err.touch()
        try:
            remaining = check_deadline(self.deadline)
        except Incomplete as exc:
            err.write_text(str(exc) + '\n')
            raise
        if payload is not None:
            (self.scratch / (stem + '.stdin')).write_text(payload)
        with out.open('wb') as stdout, err.open('wb') as stderr:
            try:
                child = subprocess.Popen(argv, cwd=cwd, env={**self.env, **(extra_env or {})},
                                         stdin=subprocess.PIPE, stdout=stdout, stderr=stderr,
                                         start_new_session=True)
            except OSError as exc:
                stderr.write(str(exc).encode())
                raise Incomplete(str(exc)) from exc
            try:
                child.communicate(None if payload is None else payload.encode(), timeout=min(30, remaining))
                record.update(exit_code=child.returncode, status='exited')
            except subprocess.TimeoutExpired as exc:
                os.killpg(child.pid, signal.SIGKILL)
                child.communicate()
                record['status'] = 'timeout'
                raise Incomplete(f'command timed out: {argv[0]}') from exc
        return record['exit_code'], out.read_text(errors='replace'), err.read_text(errors='replace')

    def runtimes(self):
        records = []
        missing = []
        for name in ['bash', 'python', 'node', 'jq', 'git']:
            executable = str(Path(sys.executable).resolve()) if name == 'python' else shutil.which(name, path=self.env['PATH'])
            self.runtime[name] = {'executable': executable, 'version': None}
            if executable is None:
                missing.append(name)
                continue
            code, stdout, stderr = self.command(records, [executable, '--version'], self.scratch)
            self.runtime[name]['version'] = (stdout + stderr).strip()
            if code != 0:
                missing.append(name)
        (self.scratch / 'runtime-commands.json').write_text(json.dumps(records, indent=2) + '\n')
        if missing:
            raise Incomplete('missing/unusable dependencies: ' + ', '.join(missing))
        if int(self.runtime['node']['version'].split('.')[0].lstrip('v')) < 24:
            raise Incomplete('Node >=24 required to import the actual TypeScript extension')

    def fixture(self, case):
        root = self.scratch / case['id']
        root.mkdir()
        code, _, _ = self.command(case['commands'], [self.runtime['git']['executable'],
            '-c', 'core.hooksPath=/dev/null', '-c', 'init.templateDir=', 'init', '-q', root], root)
        if code != 0:
            raise Incomplete('isolated Git fixture initialization failed')
        (root / 'existing.txt').write_text('fixture contents\n')
        (root / '.trellis.json').write_text('{"autonomy":3,"presets":[]}\n')
        return root

    def hook(self, case, root, name, event, extra_env=None):
        base = 'core-rules/hooks' if case['harness'] == 'claude' else 'core-rules/codex/hooks'
        return self.command(case['commands'], [self.runtime['bash']['executable'], self.source / base / name],
                            root, json.dumps(event), {**(extra_env or {}),
                            'CLAUDE_PROJECT_DIR': str(root), 'CODEX_PROJECT_DIR': str(root)})

    def normalize(self, case, root, event):
        result = self.command(case['commands'], [self.runtime['bash']['executable'], '-c',
            '. "$1"; _ta_normalize_action codex post_action "$2"', '_',
            self.source / 'core-rules/hooks/lib/action-normalize.sh', json.dumps(event)], root)
        if result[0] != 0:
            raise Incomplete('normalizer did not produce an envelope')
        return json.loads(result[1])

    def observe(self, case):
        ident, obs = case['id'], case['observations']
        if ident.startswith('pi.'):
            result = self.command(case['commands'], [self.runtime['node']['executable'],
                self.source / 'core-rules/pi/tests/conformance-observations.mjs', ident, self.scratch], self.scratch,
                extra_env={'CONFORMANCE_BASH': self.runtime['bash']['executable']})
            try:
                helper = json.loads(result[1])
            except ValueError as exc:
                raise Incomplete('Pi helper unavailable; see retained streams') from exc
            obs.update(helper['observations'])
            case['commands'].extend(helper['commands'])
            if helper['assertion'] == 'unknown':
                raise Incomplete(helper['reason'])
            assert helper['assertion'] == 'pass' and result[0] == 0, helper['reason']
            return
        if ident == 'claude.failed-read-registration':
            name = 'core-rules/templates/claude-settings.local.json'
            path = self.source / name
            hooks = json.loads(path.read_text())['hooks']
            registrations = [{'event': event, 'matcher': group.get('matcher'), 'hook': hook}
                             for event, groups in hooks.items() for group in groups
                             for hook in group.get('hooks', []) if 'track-read.sh' in hook.get('command', '')]
            obs.update(template_path=name, template_sha256=hashlib.sha256(path.read_bytes()).hexdigest(), registrations=registrations)
            assert any(r['event'] == 'PostToolUse' and r['matcher'] == 'Read|Write|Edit|MultiEdit' for r in registrations), 'successful Read registration absent'
            assert not any(r['event'] == 'PostToolUseFailure' for r in registrations), 'tracker registered for failed calls'
            return
        root = self.fixture(case)
        event = {'cwd': str(root), 'session_id': ident, 'hook_event_name': 'PreToolUse',
                 'tool_name': 'Edit', 'tool_input': {'file_path': str(root / 'existing.txt')}}
        if ident.endswith('reread-budget'):
            obs['event'] = event
            obs['responses'] = [dict(zip(['exit_code', 'stdout', 'stderr'], self.hook(case, root, 'reread-guard.sh', event))) for _ in range(3)]
            for number, response in enumerate(obs['responses'][:2], 1):
                assert response['exit_code'] == 0 and response['stdout'] == '' and f'warn {number}/2' in response['stderr'], 'expected two L3 stderr warnings'
            last = obs['responses'][2]
            decision = json.loads(last['stdout']) if last['stdout'].strip() else None
            obs['adapter_response'] = decision
            if case['harness'] == 'claude':
                assert last['exit_code'] == 0 and decision and decision.get('hookSpecificOutput', {}).get('permissionDecision') == 'deny', 'Claude third attempt did not return permission deny/exit0'
            else:
                assert last['exit_code'] == 2 and decision and decision.get('decision') == 'block', 'Codex third attempt did not return block/exit2'
        elif ident.endswith('read-credit') or ident in ['codex.failed-read', 'codex.shell-no-credit']:
            event.update(tool_name='Read', hook_event_name='PostToolUse', tool_response={'success': True})
            if ident == 'codex.failed-read':
                event['tool_response'] = {'is_error': True, 'error': 'denied'}
            if ident == 'codex.shell-no-credit':
                event.update(tool_name='exec_command', tool_input={'cmd': 'cat existing.txt'})
            obs['event'] = event.copy()
            obs['tracker_response'] = dict(zip(['exit_code', 'stdout', 'stderr'], self.hook(case, root, 'track-read.sh', event)))
            files = sorted((root / ('.' + case['harness']) / '.reread-state').glob('*.reads.tsv'))
            obs['known_set_files'] = {str(p.relative_to(root)): p.read_text() for p in files}
            rows = [row.split('\t') for p in files for row in p.read_text().splitlines()]
            assert obs['tracker_response']['exit_code'] == 0, 'tracker nonzero exit'
            if ident.endswith('read-credit'):
                event.update(tool_name='Edit', hook_event_name='PreToolUse')
                event.pop('tool_response')
                obs['guard_response'] = dict(zip(['exit_code', 'stdout', 'stderr'], self.hook(case, root, 'reread-guard.sh', event)))
                assert any(len(row) == 2 and row[1] == str(root / 'existing.txt') for row in rows), 'exact path missing from known set'
                assert obs['guard_response'] == {'exit_code': 0, 'stdout': '', 'stderr': ''}, 'read did not earn silent permit'
            else:
                obs['normalized'] = self.normalize(case, root, event)
                assert not rows, 'failed Read or shell earned read credit'
                if ident == 'codex.shell-no-credit':
                    assert obs['normalized']['action']['family'] == 'shell' and obs['normalized']['action']['targets'] == [], 'shell received file targets'
                else:
                    assert obs['normalized']['result']['status'] == 'failed', 'explicit Read failure not recognized'
        else:
            event.update(tool_name='apply_patch', hook_event_name='PostToolUse', tool_input={'command': PATCH})
            if ident == 'codex.patch-targets':
                event['tool_response'] = 'Success. Updated the following files:\nA new.py\nM existing.py\nM moved.py\nD gone.py'
            if ident == 'codex.unsafe-targets':
                event['tool_input']['command'] = '*** Begin Patch\n*** Add File: bad\x00name.py\n+x\n*** Add File: safe.py\n+y\n*** Mystery: opaque\n'
            obs['event'] = event.copy()
            obs['normalized'] = self.normalize(case, root, event)
            normalized = obs['normalized']
            if ident == 'codex.unsafe-targets':
                assert normalized['action']['targets'] == [{'operation': 'create', 'path': 'safe.py'}], 'unsafe patch target was not excluded'
                assert normalized['action']['target_coverage'] == 'partial' and normalized['action']['diagnostics'], 'unsafe/malformed coverage diagnostics missing'
            else:
                assert normalized['action']['targets'] == TARGETS and normalized['action']['target_coverage'] == 'complete', 'four independent patch targets differ'
                if ident == 'codex.patch-targets':
                    assert normalized['result']['status'] == 'succeeded', 'explicit patch success missing'
                else:
                    assert normalized['result']['status'] == 'unknown', 'absent response must remain unknown'
                    for name in ['new.py', 'existing.py', 'moved.py']:
                        (root / name).write_text('x = 1\n')
                    fake_bin = root / 'fixture-bin'
                    fake_bin.mkdir()
                    ruff = fake_bin / 'ruff'
                    ruff.write_text('#!/bin/bash\n# Fixture call logger, not measured lint quality.\nprintf "%s\\n" "$2" >> "$RUFF_LOG"\n')
                    ruff.chmod(0o755)
                    log = root / 'ruff.log'
                    env = {'PATH': str(fake_bin) + ':' + self.env['PATH'], 'RUFF_LOG': str(log)}
                    obs['ruff_fixture'] = ruff.read_text()
                    obs['existing_targets'] = {name: (root / name).exists() for name in ['new.py', 'existing.py', 'moved.py', 'old.py', 'gone.py']}
                    obs['unknown_response'] = dict(zip(['exit_code', 'stdout', 'stderr'], self.hook(case, root, 'post-edit-verify.sh', event, env)))
                    obs['lint_calls'] = log.read_text().splitlines() if log.exists() else []
                    event['tool_response'] = 'No files were modified.'
                    failed_log = root / 'failed-ruff.log'
                    obs['failed_normalized'] = self.normalize(case, root, event)
                    obs['failed_response'] = dict(zip(['exit_code', 'stdout', 'stderr'], self.hook(case, root, 'post-edit-verify.sh', event, {**env, 'RUFF_LOG': str(failed_log)})))
                    obs['failed_lint_calls'] = failed_log.read_text().splitlines() if failed_log.exists() else []
                    assert obs['lint_calls'] == [str(root / name) for name in ['new.py', 'existing.py', 'moved.py']], 'lint must visit exactly create/update/rename destination once'
                    assert obs['failed_normalized']['result']['status'] == 'failed' and obs['failed_lint_calls'] == [], 'failed patch triggered lint'
                    assert obs['unknown_response']['exit_code'] == obs['failed_response']['exit_code'] == 0, 'post-edit consumer exited nonzero'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--scratch', required=True, type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    scratch = args.scratch.absolute()
    if scratch.exists() or scratch.is_symlink():
        parser.error('--scratch must not exist')
    if not scratch.parent.is_dir():
        parser.error('--scratch parent must exist')
    scratch = scratch.parent.resolve() / scratch.name
    if scratch.is_relative_to(source):
        parser.error('--scratch must be outside source')
    scratch.mkdir(mode=0o700)
    receipt = {'schema_version': 1, 'evidence_class': 'fixture', 'source_root': str(source),
               'source_inputs': {}, 'scratch_root': str(scratch), 'runtime': {}, 'cases': [],
               'complete': False, 'passed': False, 'limitations': [
                   'Source fixture evidence only; no native host loading, exercise, or enforcement proof.',
                   'Caller supplies OS write/network fence; this CLI is not a sandbox.',
                   'Pi ExtensionAPI and named transport hooks, and ruff call logger, are explicit fixtures.',
                   'No installed project/release identity, doctor/store integration, lint quality, or native discovery claim.',
               ]}
    for ident in CASE_IDS:
        receipt['cases'].append({'id': ident, 'harness': ident.split('.')[0],
            'evidence_class': 'registration' if ident.endswith('registration') else 'fixture',
            'native_outcome': 'unknown', 'native_loaded': None, 'native_exercised': None,
            'assertion': 'unknown', 'reason': 'not executed', 'observations': {}, 'commands': []})
    corpus = Corpus(source, scratch)
    setup_error = None
    try:
        if not source.is_dir():
            raise Incomplete('source root does not exist')
        receipt['source_inputs'] = input_hashes(source, corpus.deadline)
        if (source / 'scripts/harness-conformance.py').read_bytes() != Path(__file__).read_bytes():
            raise Incomplete('source CLI differs from the executing corpus')
        corpus.runtimes()
    except (OSError, ValueError, RuntimeError, Incomplete) as exc:
        setup_error = str(exc)
        receipt['limitations'].append('setup incomplete: ' + setup_error)
    receipt['runtime'] = corpus.runtime
    for case in receipt['cases']:
        if setup_error:
            case['reason'] = setup_error
            continue
        try:
            check_deadline(corpus.deadline)
            corpus.observe(case)
            check_deadline(corpus.deadline)
            case.update(assertion='pass', reason='Required actual fixture observations matched')
        except AssertionError as exc:
            case.update(assertion='fail', reason=str(exc) or 'fixture assertion failed')
        except (OSError, ValueError, KeyError, TypeError, Incomplete) as exc:
            case.update(assertion='unknown', reason=str(exc))
    try:
        after = input_hashes(source, corpus.deadline)
        (scratch / 'source-inputs-after.json').write_text(json.dumps(after, indent=2) + '\n')
        stable = bool(receipt['source_inputs']) and after == receipt['source_inputs']
    except (OSError, RuntimeError, Incomplete) as exc:
        stable = False
        receipt['limitations'].append('post-run hash error: ' + str(exc))
    if not stable:
        receipt['limitations'].append('source inputs changed or could not be bound before/after execution')
    receipt['complete'] = stable and all(c['assertion'] != 'unknown' for c in receipt['cases'])
    receipt['passed'] = receipt['complete'] and all(c['assertion'] == 'pass' for c in receipt['cases'])
    output = json.dumps(receipt, indent=2)
    try:
        check_deadline(corpus.deadline)
    except Incomplete as exc:
        receipt.update(complete=False, passed=False)
        receipt['limitations'].append(str(exc))
        output = json.dumps(receipt, indent=2)
    print(output)
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
