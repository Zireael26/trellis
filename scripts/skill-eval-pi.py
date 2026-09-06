#!/usr/bin/env python3
"""Native Pi generation adapter for disposable evaluation fixtures.

One invocation, no tools, no retry, no fallback. Emits a generation receipt bound
to sanitized evidence; raw native streams stay private under `<output>/private/`.
Exit 0 only when every acceptance check holds — exit 0 from native is never
sufficient on its own. This is a generation receipt, not graded run evidence.

Stdout uses docs/json.md lifecycle events (message_end is authoritative);
persisted entries use docs/session-format.md. Deltas are never final text.
Fixture-verified only: this module does not claim an observed native generation.
"""
from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import selectors
import re
import subprocess
import sys
import time
import uuid
from typing import NamedTuple

SCHEMA_VERSION = 1
FAILED_REASONS = ('native_exit_nonzero', 'identity_mismatch', 'thinking_mismatch',
                  'model_switch', 'tool_use_present', 'stop_reason_rejected',
                  'empty_final_text', 'no_terminal_assistant')
UNAVAILABLE_REASONS = ('timeout', 'stream_overflow', 'session_missing', 'session_duplicate',
                       'session_mismatch', 'stdout_session_disagreement', 'stream_malformed',
                       'native_retry_observed', 'source_drift', 'cleanup_incomplete',
                       'thinking_missing', 'version_unavailable', 'native_unavailable')
REASONS = frozenset(FAILED_REASONS + UNAVAILABLE_REASONS)
USAGE_REASONS = frozenset([
    'bad_arguments', 'pi_not_absolute', 'pi_not_executable', 'output_exists',
    'cwd_missing', 'cwd_attached', 'input_missing', 'input_symlink',
    'input_not_regular', 'input_too_large', 'input_not_utf8', 'timeout_out_of_range',
])
# Highest first; several conditions may hold at once and exactly one is reported.
PRECEDENCE = ('timeout', 'stream_overflow', 'version_unavailable', 'native_unavailable',
              'session_missing', 'session_duplicate',
              'session_mismatch', 'stream_malformed', 'stdout_session_disagreement',
              'native_retry_observed', 'source_drift', 'thinking_missing', 'native_exit_nonzero',
              'no_terminal_assistant', 'model_switch', 'identity_mismatch',
              'thinking_mismatch', 'tool_use_present', 'stop_reason_rejected',
              'empty_final_text', 'cleanup_incomplete')
NATIVE_FLAGS = ('--print', '--mode', 'json', '--no-tools', '--no-extensions', '--no-skills',
                '--no-prompt-templates', '--no-context-files', '--no-themes', '--offline',
                '--no-approve')
STATUS_EXIT = {'executed': 0, 'failed': 2, 'unavailable': 3}
MAX_INPUT_BYTES = 1048576
MAX_STREAM_BYTES = 16 * 1048576
MAX_FINAL_BYTES = 1048576
MAX_TIMEOUT = 600
DEFAULT_TIMEOUT = 120
TOOL_KINDS = frozenset(['toolCall', 'toolResult'])


class UsageError(Exception):
    """Precondition failure. No generation.json is written; exit 64."""


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError('bad_arguments')


def build_argv(pi, provider, model, thinking, policy_text, session_id, session_dir) -> list[str]:
    return [pi, *NATIVE_FLAGS, '--provider', provider, '--model', model,
            '--thinking', thinking, '--system-prompt', policy_text,
            '--session-id', session_id, '--session-dir', session_dir]


def _parts(message: dict) -> list[dict]:
    content = message.get('content')
    return [p for p in content if isinstance(p, dict)] if isinstance(content, list) else []


def _text_of(message: dict) -> str:
    return ''.join(p['text'] for p in _parts(message)
                   if p.get('type') == 'text' and isinstance(p.get('text'), str))


def _typed(records: list[dict], kind: str) -> list[dict]:
    return [r for r in records if r.get('type') == kind]


def _messages(records: list[dict], kind: str = 'message') -> list[dict]:
    return [r['message'] for r in _typed(records, kind) if isinstance(r.get('message'), dict)]


def _assistants(records: list[dict]) -> list[dict]:
    return [m for m in _messages(records) if m.get('role') == 'assistant']


def _header(records: list[dict]) -> dict | None:
    sessions = _typed(records, 'session')
    return sessions[0] if sessions else None


def _thinking_levels(records: list[dict]) -> list:
    return [r.get('thinkingLevel') for r in _typed(records, 'thinking_level_change')]


def sanitize_records(records: list[dict]) -> dict:
    """Sanitized evidence: identity, stop reason, usage and TEXT only.

    Never carries thinking text, signatures or encrypted reasoning; `content_kinds`
    records that a thinking part existed, never its content.
    """
    header = _header(records)
    return {
        'schema_version': SCHEMA_VERSION,
        'header': None if header is None else {k: header.get(k) for k in ('id', 'cwd', 'version', 'timestamp')},
        'model_changes': [{'provider': r.get('provider'), 'modelId': r.get('modelId')}
                          for r in _typed(records, 'model_change')],
        'thinking_changes': [{'thinkingLevel': level} for level in _thinking_levels(records)],
        'assistants': [{'provider': m.get('provider'), 'model': m.get('model'), 'api': m.get('api'),
                        'stopReason': m.get('stopReason'), 'usage': m.get('usage'),
                        'text': _text_of(m),
                        'content_kinds': [p.get('type') for p in _parts(m)]}
                       for m in _assistants(records)],
    }


def _sequence(messages: list[dict]) -> list:
    return [(m.get('role'), m.get('provider'), m.get('model'), m.get('stopReason'), _text_of(m))
            for m in messages if m.get('role') == 'assistant']


def evaluate(records: list[dict], stdout_records: list[dict], requested: dict,
             native_exit: int | None) -> tuple[str, str | None]:
    """Return (status, reason) by literal precedence. Pure: no I/O, no clock.

    `requested` carries provider/model/thinking, the requested session_id and the
    realpath of --cwd, plus `reasons` — the conditions only the caller can observe
    (timeout, stream_overflow, session_missing/duplicate, stream_malformed,
    source_drift, cleanup_incomplete). They rank with the rest, they do not skip it.
    """
    found = set(requested.get('reasons') or ())
    if native_exit != 0:
        found.add('native_exit_nonzero')

    for source in (records, stdout_records):
        headers = _typed(source, 'session')
        if len(headers) > 1:
            found.add('session_mismatch')
        if not headers or not source or source[0].get('type') != 'session':
            found.add('stream_malformed')
        for header in headers:
            if (header.get('id') != requested.get('session_id')
                    or header.get('cwd') != requested.get('cwd')
                    or header.get('version') != 3 or header.get('parentSession')):
                found.add('session_mismatch')

    previous, ids = None, set()
    for entry in records[1:]:
        identity = entry.get('id')
        if not isinstance(identity, str) or not identity or identity in ids:
            found.add('stream_malformed')
        else:
            ids.add(identity)
        if entry.get('parentId') != previous:
            found.add('session_mismatch')
        previous = identity

    terminal = _messages(stdout_records, 'message_end')
    ends = _typed(stdout_records, 'agent_end')
    # Installed 0.85.1 closes a run with agent_end and then an optional terminal
    # agent_settled idle event. Older fixtures stop at agent_end; both are valid,
    # nothing may follow the settle, and settle is a stdout-only wire event.
    settled = _typed(stdout_records, 'agent_settled')
    if len(_typed(stdout_records, 'agent_start')) != 1 or len(ends) != 1 or not stdout_records:
        found.add('stream_malformed')
    if len(settled) > 1 or _typed(records, 'agent_settled'):
        found.add('stream_malformed')
    elif len(settled) == 1:
        if (len(stdout_records) < 3 or stdout_records[-1].get('type') != 'agent_settled'
                or stdout_records[-2].get('type') != 'agent_end'):
            found.add('stream_malformed')
    elif not stdout_records or stdout_records[-1].get('type') != 'agent_end':
        found.add('stream_malformed')
    for end in ends:
        # `willRetry` is absent on pre-0.85.1 streams; when present it is a bool
        # and a true value is a native auto-retry, never a clean single shot.
        if 'willRetry' in end:
            if not isinstance(end['willRetry'], bool):
                found.add('stream_malformed')
            elif end['willRetry']:
                found.add('native_retry_observed')
    if len(ends) == 1:
        completed = ends[0].get('messages')
        if not isinstance(completed, list) or any(not isinstance(m, dict) for m in completed):
            found.add('stream_malformed')
        elif _sequence(completed) != _sequence(terminal):
            found.add('stdout_session_disagreement')

    # Validate boundary shapes before hashing identities or extracting text.
    all_messages = [*_messages(records), *terminal]
    if len(ends) == 1 and isinstance(ends[0].get('messages'), list):
        all_messages.extend(m for m in ends[0]['messages'] if isinstance(m, dict))
    active_message, active_turn = False, False
    if len(stdout_records) < 2 or stdout_records[1].get('type') != 'agent_start':
        found.add('stream_malformed')
    for event in stdout_records[2:]:
        kind = event.get('type')
        if isinstance(kind, str) and kind not in (
                'session', 'agent_end', 'agent_settled', 'message_start', 'message_end',
                'message_update', 'turn_start', 'turn_end', 'queue_update') and not any(
                marker in kind.lower() for marker in ('tool_execution_', 'retry', 'branch', 'compaction', 'bash')):
            found.add('stream_malformed')
        if kind == 'message_start':
            if active_message:
                found.add('stream_malformed')
            active_message = True
        elif kind == 'message_end':
            if not active_message:
                found.add('stream_malformed')
            active_message = False
        elif kind == 'message_update' and not active_message:
            found.add('stream_malformed')
        elif kind == 'turn_start':
            if active_turn:
                found.add('stream_malformed')
            active_turn = True
        elif kind == 'turn_end':
            if not active_turn or active_message:
                found.add('stream_malformed')
            active_turn = False
        elif kind in ('agent_end', 'agent_settled') and (active_turn or active_message):
            found.add('stream_malformed')
    for record in [*records, *stdout_records]:
        kind = record.get('type')
        if not isinstance(kind, str):
            found.add('stream_malformed')
            continue
        if 'retry' in kind.lower() or record.get('retry'):
            found.add('native_retry_observed')
        if 'branch' in kind.lower() or 'compaction' in kind.lower():
            found.add('session_mismatch')
        if kind.startswith('tool_execution_') or kind.lower().startswith('bash'):
            found.add('tool_use_present')
        if kind in ('message', 'message_start', 'message_end', 'turn_end'):
            if not isinstance(record.get('message'), dict):
                found.add('stream_malformed')
            elif kind in ('message_start', 'turn_end'):
                all_messages.append(record['message'])
        if kind == 'turn_end' and record.get('toolResults'):
            found.add('tool_use_present')
        if kind == 'message_update':
            update = record.get('assistantMessageEvent')
            if not isinstance(update, dict) or not isinstance(update.get('type'), str):
                found.add('stream_malformed')
            elif update['type'].startswith('toolcall_'):
                found.add('tool_use_present')
    if _typed(stdout_records, 'message'):
        found.add('stream_malformed')
    for message in all_messages:
        role = message.get('role')
        if role in ('toolResult', 'bashExecution'):
            found.add('tool_use_present')
        if role in ('branchSummary', 'compactionSummary'):
            found.add('session_mismatch')
        elif role not in ('user', 'assistant', 'toolResult', 'bashExecution'):
            found.add('stream_malformed')
        content = message.get('content')
        if role == 'assistant' and (not isinstance(content, list) or any(
                not isinstance(message.get(key), str) or not message[key]
                for key in ('provider', 'model', 'stopReason'))):
            found.add('stream_malformed')
        if isinstance(content, list):
            for part in content:
                if (not isinstance(part, dict) or not isinstance(part.get('type'), str)
                        or (part.get('type') == 'text' and not isinstance(part.get('text'), str))):
                    found.add('stream_malformed')
                elif part['type'] in TOOL_KINDS:
                    found.add('tool_use_present')

    assistants = _assistants(records)
    reported = [m for m in terminal if m.get('role') == 'assistant']
    messages = _messages(records)
    if not assistants or not messages or messages[-1].get('role') != 'assistant':
        found.add('no_terminal_assistant')
    if _sequence(assistants) != _sequence(reported):
        found.add('stdout_session_disagreement')
    identities = [(m.get('provider'), m.get('model')) for m in assistants]
    if any(identity != identities[0] for identity in identities[1:]) or len(_typed(records, 'model_change')) > 1:
        found.add('model_switch')
    for change in _typed(records, 'model_change'):
        if any(not isinstance(change.get(key), str) or not change[key] for key in ('provider', 'modelId')):
            found.add('stream_malformed')
        if change.get('provider') != requested.get('provider') or change.get('modelId') != requested.get('model'):
            found.add('identity_mismatch')
    if any(m.get('provider') != requested.get('provider') or m.get('model') != requested.get('model')
           for m in [*assistants, *reported]):
        found.add('identity_mismatch')
    levels = _thinking_levels(records)
    if not levels:
        found.add('thinking_missing')
    elif any(not isinstance(level, str) or not level for level in levels):
        found.add('stream_malformed')
    elif any(level != requested.get('thinking') for level in levels):
        found.add('thinking_mismatch')
    if any(m.get('stopReason') != 'stop' for m in assistants):
        found.add('stop_reason_rejected')
    if assistants and not _text_of(assistants[-1]).strip():
        found.add('empty_final_text')

    for reason in PRECEDENCE:
        if reason in found:
            return ('failed' if reason in FAILED_REASONS else 'unavailable'), reason
    return 'executed', None


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def _write(path: Path, data: bytes) -> dict:
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
        stream.write(data)
    os.chmod(path, 0o600)
    return {'path': str(path), 'sha256': hashlib.sha256(data).hexdigest()}


def _mkdir(path: Path) -> Path:
    path.mkdir(mode=0o700)
    os.chmod(path, 0o700)
    return path


class _Input(NamedTuple):
    data: bytes
    text: str
    sha256: str
    identity: tuple[int, int]


def _read_input(path: Path) -> _Input:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as exc:
        reason = ('input_symlink' if exc.errno == errno.ELOOP else
                  'input_missing' if exc.errno == errno.ENOENT else 'input_not_regular')
        raise UsageError(reason) from exc
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise UsageError('input_not_regular')
    except BaseException:
        os.close(fd)
        raise
    with os.fdopen(fd, 'rb') as stream:
        data = stream.read(MAX_INPUT_BYTES + 1)
    if len(data) > MAX_INPUT_BYTES:
        raise UsageError('input_too_large')
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError as exc:
        raise UsageError('input_not_utf8') from exc
    return _Input(data, text, hashlib.sha256(data).hexdigest(), (info.st_dev, info.st_ino))


def _parse(argv: list[str]) -> argparse.Namespace:
    parser = _Parser(prog='skill-eval-pi', description=__doc__, add_help=False)
    for name in ['--pi', '--cwd', '--prompt', '--policy', '--output']:
        parser.add_argument(name, required=True, type=Path)
    for name in ['--provider', '--model', '--thinking']:
        parser.add_argument(name, required=True)
    parser.add_argument('--timeout', type=int, default=DEFAULT_TIMEOUT)
    return parser.parse_args(argv)


def _validate(args: argparse.Namespace) -> tuple[_Input, _Input]:
    if not 1 <= args.timeout <= MAX_TIMEOUT:
        raise UsageError('timeout_out_of_range')
    if not args.pi.is_absolute():
        raise UsageError('pi_not_absolute')
    if not (args.pi.is_file() and os.access(args.pi, os.X_OK)):
        raise UsageError('pi_not_executable')
    if os.path.lexists(args.output):
        raise UsageError('output_exists')
    if not args.cwd.is_dir():
        raise UsageError('cwd_missing')
    if os.path.lexists(args.cwd / '.trellis' / 'runtime'):
        raise UsageError('cwd_attached')
    return _read_input(args.prompt), _read_input(args.policy)


def _parse_jsonl(text: str, banner: bool) -> list[dict]:
    """One JSON object per line. A non-JSON prefix is tolerated on stdout only."""
    records, seen = [], False
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except ValueError:
            if seen or not banner:
                raise
            continue
        if not isinstance(record, dict):
            raise ValueError('non-object native record')
        seen = True
        records.append(record)
    return records


def _cleanup(child: subprocess.Popen) -> bool:
    """Signal only the group created by our Popen, then reap its leader."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            break
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        return False
    return True


def _collect(argv: list[str], cwd: Path, data: bytes, timeout: int,
             stdout_path: Path, stderr_path: Path) -> tuple[int | None, float, list[str]]:
    """Event-wait collection with one deadline and per-stream limit+1 evidence.

    No raw stream is redirected to an unbounded file. The first overflow byte is
    retained to prove rejection, never scored. Session files are native-owned:
    their size is checked after exit, not monitored while native is writing.
    """
    started = time.monotonic()
    deadline = started + timeout
    reasons, child = [], None
    with stdout_path.open('wb') as out, stderr_path.open('wb') as err, selectors.DefaultSelector() as selector:
        os.chmod(stdout_path, 0o600)
        os.chmod(stderr_path, 0o600)
        try:
            child = subprocess.Popen(argv, cwd=str(cwd), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     start_new_session=True, umask=0o077)
            pending = memoryview(data)
            sinks = {child.stdout: out, child.stderr: err}
            counts = {child.stdout: 0, child.stderr: 0}
            for pipe in sinks:
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ)
            os.set_blocking(child.stdin.fileno(), False)
            if pending:
                selector.register(child.stdin, selectors.EVENT_WRITE)
            else:
                child.stdin.close()
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    reasons.append('timeout')
                    break
                ready = selector.select(remaining)
                if not ready:
                    reasons.append('timeout')
                    break
                for key, _ in ready:
                    pipe = key.fileobj
                    if pipe is child.stdin:
                        try:
                            written = os.write(pipe.fileno(), pending[:65536])
                            pending = pending[written:]
                        except BrokenPipeError:
                            pending = memoryview(b'')
                        if not pending:
                            selector.unregister(pipe)
                            pipe.close()
                    else:
                        block = os.read(pipe.fileno(), min(65536, MAX_STREAM_BYTES + 1 - counts[pipe]))
                        if not block:
                            selector.unregister(pipe)
                            pipe.close()
                            continue
                        sinks[pipe].write(block)
                        counts[pipe] += len(block)
                        if counts[pipe] > MAX_STREAM_BYTES:
                            reasons.append('stream_overflow')
                            break
                if reasons:
                    break
            if not reasons:
                try:
                    child.wait(timeout=max(0, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    reasons.append('timeout')
        except OSError:
            reasons.append('native_unavailable')
        finally:
            if child is not None:
                if reasons and not _cleanup(child):
                    reasons.append('cleanup_incomplete')
                for pipe in (child.stdin, child.stdout, child.stderr):
                    pipe.close()
    return None if child is None else child.returncode, time.monotonic() - started, reasons


def _bounded_records(path: Path, banner: bool, private_session: bool = False) -> list[dict]:
    # Verify the same descriptor we chmod and read; never follow a native link
    # or block opening a replacement FIFO. Native live disk growth is not capped.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('non-regular stream')
        if private_session:
            os.fchmod(stream.fileno(), 0o600)
            if stat.S_IMODE(os.fstat(stream.fileno()).st_mode) != 0o600:
                raise ValueError('session mode not private')
        if info.st_size > MAX_STREAM_BYTES:
            raise OverflowError('stream_overflow')
        data = stream.read(MAX_STREAM_BYTES)
        if stream.read(1):
            raise OverflowError('stream_overflow')
    return _parse_jsonl(data.decode('utf-8'), banner)


def _run(args: argparse.Namespace, prompt: _Input, policy: _Input) -> int:
    output = _mkdir(args.output)
    private = _mkdir(output / 'private')
    session_dir = _mkdir(private / 'session')
    inputs = {'prompt': (args.prompt, prompt), 'policy': (args.policy, policy)}
    before = {'pi': _sha256(args.pi), 'prompt': prompt.sha256, 'policy': policy.sha256}
    session_id = str(uuid.uuid4())
    argv = build_argv(str(args.pi), args.provider, args.model, args.thinking,
                      policy.text, session_id, str(session_dir))
    stdout_path, stderr_path = private / 'stdout.txt', private / 'stderr.txt'

    version_argv = [str(args.pi), '--version']
    version_out, version_err = private / 'version.stdout.txt', private / 'version.stderr.txt'
    version_exit, version_elapsed, version_reasons = _collect(
        version_argv, args.cwd, b'', min(10, args.timeout), version_out, version_err)
    with version_out.open('rb') as stream:
        version_raw = stream.read(513)
    version = version_raw.decode('utf-8', errors='replace').strip()
    version_ok = (version_exit == 0 and not version_reasons and len(version_raw) <= 512
                  and re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?', version))
    version_probe = {'argv': version_argv, 'exit': version_exit,
                     'elapsed_seconds': version_elapsed, 'reasons': version_reasons,
                     'stdout': {'path': str(version_out), 'sha256': _sha256(version_out)},
                     'stderr': {'path': str(version_err), 'sha256': _sha256(version_err)}}
    if version_ok:
        native_exit, elapsed, reasons = _collect(argv, args.cwd, prompt.data, args.timeout,
                                                stdout_path, stderr_path)
    else:
        native_exit, elapsed, reasons = None, version_elapsed, ['version_unavailable']
        _write(stdout_path, b'')
        _write(stderr_path, b'')

    try:
        if _sha256(args.pi) != before['pi']:
            reasons.append('source_drift')
        for path, captured in inputs.values():
            current = _read_input(path)
            if current.identity != captured.identity or current.sha256 != captured.sha256:
                reasons.append('source_drift')
    except (OSError, UsageError):
        reasons.append('source_drift')

    sessions = sorted(session_dir.rglob('*.jsonl'))
    records, stdout_records = [], []
    if not sessions:
        reasons.append('session_missing')
    elif len(sessions) > 1:
        reasons.append('session_duplicate')
    else:
        try:
            records = _bounded_records(sessions[0], banner=False, private_session=True)
        except OverflowError:
            reasons.append('stream_overflow')
        except (OSError, ValueError):
            reasons.append('stream_malformed')
    if 'stream_overflow' not in reasons:
        try:
            stdout_records = _bounded_records(stdout_path, banner=False)
        except OverflowError:
            reasons.append('stream_overflow')
        except (OSError, ValueError):
            reasons.append('stream_malformed')

    assistants = _assistants(records)
    final_text = _text_of(assistants[-1]) if assistants else ''
    if len(final_text.encode()) > MAX_FINAL_BYTES and 'stream_overflow' not in reasons:
        reasons.append('stream_overflow')

    requested = {'provider': args.provider, 'model': args.model, 'thinking': args.thinking,
                 'session_id': session_id, 'cwd': os.path.realpath(args.cwd), 'reasons': reasons}
    status, reason = evaluate(records, stdout_records, requested, native_exit)

    evidence = None
    if records:
        evidence = _write(output / 'native-evidence.json',
                          json.dumps(sanitize_records(records), indent=2).encode() + b'\n')
    final_output = None
    if final_text.strip() and 'stream_overflow' not in reasons:
        final_output = _write(output / 'final-output.txt', final_text.encode())

    observed = None
    if assistants:
        levels = _thinking_levels(records)
        observed = {'provider': assistants[-1].get('provider'), 'model': assistants[-1].get('model'),
                    'thinking': levels[-1] if levels else None,
                    'harness_version': version if version_ok else None}
    receipt = {
        'schema_version': SCHEMA_VERSION,
        'status': status,
        'reason': reason,
        'native_exit': native_exit,
        'version_probe': version_probe,
        'elapsed_seconds': elapsed,
        'native_session_id': session_id,
        'observed_executor': observed,
        'requested_executor': {'provider': args.provider, 'model': args.model, 'thinking': args.thinking},
        'prompt_sha256': before['prompt'],
        'policy_sha256': before['policy'],
        'native_executable_sha256': before['pi'],
        'native_executable_realpath': os.path.realpath(args.pi),
        'native_argv': ['<policy>' if index and argv[index - 1] == '--system-prompt' else value
                        for index, value in enumerate(argv)],
        'final_output': final_output,
        'native_evidence': evidence,
        'usage': assistants[-1].get('usage') if assistants else None,
    }
    _write(output / 'generation.json', json.dumps(receipt, indent=2).encode() + b'\n')
    return STATUS_EXIT[status]


def main(argv: list[str]) -> int:
    try:
        args = _parse(argv)
        prompt, policy = _validate(args)
    except UsageError as exc:
        print(f'skill-eval-pi: {exc}', file=sys.stderr)
        return 64
    return _run(args, prompt, policy)


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
