#!/usr/bin/env bats
# T9 native Pi generation adapter — contract conformance.
# Contract: specs/045-three-harness-parity/T9-PI-ADAPTER-PHASE1.md
#
# Every native invocation in this file is a fixture executable generated at runtime
# into the caller-supplied retained evidence root. NO paid provider/model call is
# made, and a PATH tripwire proves the real `pi` was never executed.
#
# Fixtures follow installed docs/json.md and docs/session-format.md separately.
# No real native generation has been observed; native smoke is parent-owned.

setup_file() {
  export SOURCE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  : "${TRELLIS_T9_TEST_ROOT:?caller must supply a new retained directory outside source}"
  export EVIDENCE="$TRELLIS_T9_TEST_ROOT"
  export PYTHON="$(command -v python3)"
  export MODULE="$SOURCE/scripts/skill-eval-pi.py"
  export PROVIDER=fixture-provider
  export MODEL=fixture-model-1
  export THINKING=medium

  [ ! -e "$EVIDENCE" ] || { echo "evidence root must not already exist: $EVIDENCE" >&2; return 1; }
  mkdir -p "$EVIDENCE"
  case "$EVIDENCE" in "$SOURCE"/*) echo "evidence root must live outside the source tree" >&2; return 1 ;; esac

  # PATH tripwire: any resolution of a bare `pi` records itself and fails loudly.
  mkdir -p "$EVIDENCE/tripwire"
  cat > "$EVIDENCE/tripwire/pi" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$(dirname "$0")/REAL-PI-INVOKED"
exit 127
SH
  chmod 0755 "$EVIDENCE/tripwire/pi"
  export PATH="$EVIDENCE/tripwire:$PATH"

  write_fake_native "$EVIDENCE/fake-pi.py"

  # Disposable mutated copy of the module (contract §13 business-mutation negative).
  # Built here; exercised by the first @test so the negative is observed before any
  # green run while each failure stays individually attributable.
  export MUTANT="$EVIDENCE/mutated-module/skill-eval-pi.py"
  if [ -f "$MODULE" ]; then
    "$PYTHON" - "$MODULE" "$MUTANT" <<'PY'
import sys
from pathlib import Path
src, dst = map(Path, sys.argv[1:])
text = src.read_text()
i = text.find('\nif __name__')
assert i != -1, 'module lacks an `if __name__` guard (contract §12)'
patch = '''
# BUSINESS MUTATION (contract §13), disposable copy only: the identity comparison
# is inverted, so an assistant whose provider/model differs from the requested
# executor is accepted instead of rejected.
_unmutated_evaluate = evaluate


def evaluate(*args, **kwargs):
    status, reason = _unmutated_evaluate(*args, **kwargs)
    if reason == 'identity_mismatch':
        return ('executed', None)
    return (status, reason)


if __name__ == '__main__':
    import sys as _sys
    raise SystemExit(main(_sys.argv[1:]))
'''
dst.parent.mkdir(parents=True, exist_ok=True)
dst.write_text(text[:i] + patch)
PY
  fi
}

# ---------------------------------------------------------------------------
# Fixture native executable
# ---------------------------------------------------------------------------

write_fake_native() {
  cat > "$1" <<'FAKE'
#!/usr/bin/env python3
"""Fixture stand-in for the native `pi` executable.

Records generation and version invocations separately; emits saved entries to
--session-dir and documented lifecycle events to stdout. Behaviour is
driven entirely by `<self>.scenario.json`, so no environment cooperation from
the adapter under test is required. Never contacts a provider.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

SELF = Path(__file__).resolve()
SCENARIO = json.loads(Path(str(SELF) + '.scenario.json').read_text())
ARGS = sys.argv[1:]
if ARGS == ['--version']:
    Path(str(SELF) + '.version-invocation.json').write_text(json.dumps(sys.argv))
    print(SCENARIO.get('version_text', '0.85.1'))
    sys.exit(SCENARIO.get('version_exit', 0))


def flag(name):
    return ARGS[ARGS.index(name) + 1] if name in ARGS else None


stdin_text = sys.stdin.read()
with open(str(SELF) + '.invocations.jsonl', 'a') as fh:
    fh.write(json.dumps({
        'argv': sys.argv,
        'cwd': os.getcwd(),
        'realcwd': os.path.realpath(os.getcwd()),
        'pid': os.getpid(),
        'pgid': os.getpgid(0),
        'ppid': os.getppid(),
        'stdin': stdin_text,
    }) + '\n')

session_dir = flag('--session-dir')
session_id = flag('--session-id')
provider = flag('--provider')
model = flag('--model')
thinking = flag('--thinking')

header = {
    'type': 'session',
    'version': SCENARIO.get('header_version', 3),
    'id': SCENARIO.get('header_id') or session_id,
    'timestamp': SCENARIO.get('timestamp', '2026-09-06T00:00:00Z'),
    'cwd': SCENARIO.get('header_cwd') or os.path.realpath(os.getcwd()),
    'harnessVersion': SCENARIO.get('harness_version', '0.85.1'),
}


def assistant(event):
    content = []
    if event.get('thinking_text'):
        content.append({
            'type': 'thinking',
            'thinking': event['thinking_text'],
            'signature': event.get('thinking_signature', ''),
        })
    if event.get('tool'):
        content.append({'type': 'toolCall', 'id': 'call-1', 'name': 'bash',
                        'arguments': {'command': 'true'}})
    text = event.get('text', '')
    if event.get('pad_text_bytes'):
        text = text + ('x' * int(event['pad_text_bytes']))
    content.append({'type': 'text', 'text': text})
    if 'content' in event:
        content = event['content']
    message = {
        'role': 'assistant',
        'provider': event.get('provider', provider),
        'model': event.get('model', model),
        'api': event.get('api', 'messages'),
        'stopReason': event.get('stopReason', 'stop'),
        'content': content,
    }
    if event.get('usage') is not None:
        message['usage'] = event['usage']
    return {'type': 'message', 'message': message}


def build(events):
    lines = []
    for event in events:
        kind = event.get('kind')
        if kind == 'raw':
            lines.append(event['line'])
            continue
        if kind == 'model_change':
            record = {'type': 'model_change',
                      'provider': event.get('provider') or provider,
                      'modelId': event.get('modelId') or model}
        elif kind == 'thinking_level_change':
            record = {'type': 'thinking_level_change',
                      'thinkingLevel': event.get('thinkingLevel') or thinking}
        elif kind == 'user':
            record = {'type': 'message', 'message': {
                'role': 'user',
                'content': [{'type': 'text',
                             'text': event.get('text', '')
                             + ('y' * int(event.get('pad_text_bytes', 0)))}]}}
        elif kind == 'assistant':
            record = assistant(event)
        elif kind == 'record':
            record = event['record']
        elif kind == 'retry':
            record = {'type': 'retry', 'attempt': 2,
                      'reason': event.get('reason', 'provider_retry')}
        else:
            raise SystemExit('fixture: unknown event kind %r' % (kind,))
        lines.append(json.dumps(record))
    return lines


events = SCENARIO.get('events', [])
session_lines = [json.dumps(header)] + build(events)
# Persisted entries are a linear tree, not wire lifecycle records.
previous = None
for index in range(1, len(session_lines)):
    try:
        entry = json.loads(session_lines[index])
    except ValueError:
        continue
    entry.update(id='%08x' % index, parentId=previous, timestamp=header['timestamp'])
    previous = entry['id']
    if SCENARIO.get('branch_parent') and index == len(session_lines) - 1:
        entry['parentId'] = None
    session_lines[index] = json.dumps(entry)
if SCENARIO.get('duplicate_header'):
    session_lines.append(json.dumps(header))
stdout_lines = ([json.dumps(header)] if SCENARIO.get('stdout_header', True) else [])
stdout_lines.append(json.dumps({'type': 'agent_start'}))
terminal = []
turns_started = 0
wire_events = SCENARIO.get('stdout_events', events)
for event, line in zip(wire_events, build(wire_events)):
    if event.get('kind') == 'raw':
        stdout_lines.append(line)
        continue
    try:
        entry = json.loads(line)
    except ValueError:
        stdout_lines.append(line)
        continue
    if entry['type'] in ('model_change', 'thinking_level_change'):
        continue  # persisted settings entries are not stdout events
    if entry['type'] == 'message':
        message = entry['message']
        terminal.append(message)
        if message['role'] == 'assistant':
            stdout_lines.append(json.dumps({'type': 'turn_start'}))
            if SCENARIO.get('settled_in_turn') and turns_started == 0:
                # Idle settle announced while the turn is still open.
                stdout_lines.append(json.dumps({'type': 'agent_settled'}))
            turns_started += 1
        stdout_lines.append(json.dumps({'type': 'message_start', 'message': message}))
        if message['role'] == 'assistant':
            stdout_lines.append(json.dumps({'type': 'message_update', 'usage': {},
                'assistantMessageEvent': {'type': 'text_delta', 'contentIndex': 0, 'delta': 'DO NOT DUPLICATE'}}))
        stdout_lines.append(json.dumps({'type': 'message_end', 'message': message}))
        if message['role'] == 'assistant':
            stdout_lines.append(json.dumps({'type': 'turn_end', 'message': message, 'toolResults': []}))
    else:
        stdout_lines.append(line)
if not SCENARIO.get('missing_agent_end'):
    end_record = {'type': 'agent_end', 'messages': terminal}
    if 'will_retry' in SCENARIO:
        end_record['willRetry'] = SCENARIO['will_retry']
    stdout_lines.append(json.dumps(end_record))
# Installed 0.85.1 closes with a terminal `agent_settled` idle event.
for _ in range(int(SCENARIO.get('agent_settled', 0))):
    stdout_lines.append(json.dumps({'type': 'agent_settled'}))
for suffix in SCENARIO.get('stdout_suffix_lines', []):
    stdout_lines.append(suffix)
if SCENARIO.get('duplicate_stdout_header'):
    stdout_lines.append(json.dumps(header))
for prefix in SCENARIO.get('stdout_prefix_lines', []):
    stdout_lines.insert(0, prefix)

count = SCENARIO.get('session_files', 1)
if session_dir:
    base = Path(session_dir)
    for index in range(count):
        name = '%s.jsonl' % (session_id if index == 0 else '%s-%d' % (session_id, index))
        target = base / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('\n'.join(session_lines) + '\n')
        if 'session_mode' in SCENARIO:
            target.chmod(SCENARIO['session_mode'])
        if SCENARIO.get('session_symlink'):
            external = SELF.parent / 'external-session'
            target.rename(external)
            external.chmod(0o644)
            target.symlink_to(external)
        if SCENARIO.get('session_fifo'):
            target.unlink()
            os.mkfifo(target)

sys.stdout.write('\n'.join(stdout_lines) + '\n')
if SCENARIO.get('stderr_text'):
    sys.stderr.write(SCENARIO['stderr_text'])
sys.stdout.flush()
sys.stderr.flush()

for path in SCENARIO.get('drift_paths', []):
    with open(path if path != 'SELF' else str(SELF), 'ab') as fh:
        fh.write(b'\n# fixture drift\n')

if SCENARIO.get('sleep_seconds'):
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(600)'])
    Path(str(SELF) + '.pids.json').write_text(json.dumps(
        {'pid': os.getpid(), 'pgid': os.getpgid(0), 'child': child.pid}))
    time.sleep(float(SCENARIO['sleep_seconds']))

sys.exit(SCENARIO.get('exit_code', 0))
FAKE
  chmod 0755 "$1"
}

# ---------------------------------------------------------------------------
# Case helpers
# ---------------------------------------------------------------------------

mkcase() {
  CASE="$EVIDENCE/$1"
  mkdir -p "$CASE"
  PI="$CASE/pi"
  cp "$EVIDENCE/fake-pi.py" "$PI"
  chmod 0755 "$PI"
  PROMPT="$CASE/prompt.txt"
  printf 'fixture evaluation prompt\n' > "$PROMPT"
  POLICY="$CASE/policy.txt"
  printf 'FROZEN-COMMON-POLICY-TEXT\n' > "$POLICY"
  CWD="$CASE/cwd"
  mkdir -p "$CWD"
  OUT="$CASE/out"
  scenario_positive
}

# Scenario JSON is written next to the fixture executable.
scenario() { cat > "$PI.scenario.json"; }

scenario_positive() {
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "user", "text": "fixture evaluation prompt"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER",
   "usage": {"inputTokens": 11, "outputTokens": 7}}
]}
JSON
}

adapter() {  # runs the real module; extra argv appended
  run "$PYTHON" "$MODULE" \
    --pi "$PI" --cwd "$CWD" --prompt "$PROMPT" --policy "$POLICY" \
    --provider "$PROVIDER" --model "$MODEL" --thinking "$THINKING" \
    --output "$OUT" "$@"
  printf '%s\n' "$output" > "$CASE/adapter.output"
  printf '%s\n' "$status" > "$CASE/adapter.exit"
  [ ! -e "$EVIDENCE/tripwire/REAL-PI-INVOKED" ]
}

receipt() {  # <expected status> <expected reason or '-'> ; asserts the exit code too
  "$PYTHON" - "$OUT/generation.json" "$1" "$2" "$CASE/adapter.exit" <<'PY'
import json
import sys
receipt, want_status, want_reason, exit_file = sys.argv[1:]
g = json.loads(open(receipt).read())
code = int(open(exit_file).read().strip())
assert g['schema_version'] == 1, g
assert g['status'] == want_status, (g['status'], g.get('reason'))
if want_reason == '-':
    assert g['reason'] is None, g['reason']
else:
    assert g['reason'] == want_reason, (g['status'], g['reason'])
assert code == {'executed': 0, 'failed': 2, 'unavailable': 3}[want_status], code
assert isinstance(g['elapsed_seconds'], float) and g['elapsed_seconds'] > 0, g['elapsed_seconds']
PY
}

usage_error() {  # <expected usage reason>
  [ "$status" -eq 64 ]
  [ "$output" = "skill-eval-pi: $1" ]
  [ ! -e "$OUT/generation.json" ]
}

invocations() { printf '%s' "$PI.invocations.jsonl"; }

# ---------------------------------------------------------------------------
# Business-mutation negative — observed before any green run (contract §13)
# ---------------------------------------------------------------------------

@test "inverted identity comparison in a disposable copy stops the mismatch case failing" {
  [ -f "$MODULE" ]
  [ -f "$MUTANT" ]

  # Unmutated pair: positive executes, mismatch fails with identity_mismatch.
  mkcase mutation-real-positive
  adapter
  receipt executed -
  mkcase mutation-real-mismatch
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "provider": "other-provider", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt failed identity_mismatch

  # Mutated copy: the mismatch is no longer rejected.
  mkcase mutation-mutant-mismatch
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "provider": "other-provider", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  run "$PYTHON" "$MUTANT" \
    --pi "$PI" --cwd "$CWD" --prompt "$PROMPT" --policy "$POLICY" \
    --provider "$PROVIDER" --model "$MODEL" --thinking "$THINKING" --output "$OUT"
  printf '%s\n' "$output" > "$CASE/adapter.output"
  printf '%s\n' "$status" > "$CASE/adapter.exit"
  [ ! -e "$EVIDENCE/tripwire/REAL-PI-INVOKED" ]
  receipt executed -

  # And the mutated copy still executes the honest positive.
  mkcase mutation-mutant-positive
  run "$PYTHON" "$MUTANT" \
    --pi "$PI" --cwd "$CWD" --prompt "$PROMPT" --policy "$POLICY" \
    --provider "$PROVIDER" --model "$MODEL" --thinking "$THINKING" --output "$OUT"
  printf '%s\n' "$status" > "$CASE/adapter.exit"
  receipt executed -
}

# ---------------------------------------------------------------------------
# Positive path
# ---------------------------------------------------------------------------

@test "positive generation executes and binds the full contract receipt" {
  mkcase positive
  adapter
  receipt executed -
  "$PYTHON" - "$OUT" "$PI" "$PROMPT" "$POLICY" "$CWD" "$PROVIDER" "$MODEL" "$THINKING" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path
out, pi, prompt, policy, cwd, provider, model, thinking = map(str, sys.argv[1:])
out = Path(out)
g = json.loads((out / 'generation.json').read_text())
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()

assert set(g) == {
    'schema_version', 'status', 'reason', 'native_exit', 'elapsed_seconds',
    'native_session_id', 'observed_executor', 'requested_executor',
    'prompt_sha256', 'policy_sha256', 'native_executable_sha256',
    'native_executable_realpath', 'native_argv', 'final_output',
    'native_evidence', 'usage', 'version_probe'}, sorted(g)
assert g['native_exit'] == 0
assert g['requested_executor'] == {'provider': provider, 'model': model, 'thinking': thinking}
assert g['observed_executor']['provider'] == provider
assert g['observed_executor']['model'] == model
assert g['observed_executor']['thinking'] == thinking
assert g['observed_executor']['harness_version'] == '0.85.1'
v = g['version_probe']
assert v['argv'] == [pi, '--version'] and v['exit'] == 0
assert Path(v['stdout']['path']).read_text() == '0.85.1\n'
assert v['stdout']['sha256'] == sha(v['stdout']['path'])
assert v['stderr']['sha256'] == sha(v['stderr']['path'])
assert g['prompt_sha256'] == sha(prompt) and g['policy_sha256'] == sha(policy)
assert g['native_executable_sha256'] == sha(pi)
assert g['native_executable_realpath'] == os.path.realpath(pi)
assert g['usage'] == {'inputTokens': 11, 'outputTokens': 7}

# §4 fixed argv, policy text redacted, no secrets, no shell string.
argv = g['native_argv']
assert isinstance(argv, list) and all(isinstance(x, str) for x in argv)
assert argv[0] == pi
assert argv[1:12] == ['--print', '--mode', 'json', '--no-tools', '--no-extensions',
                      '--no-skills', '--no-prompt-templates', '--no-context-files',
                      '--no-themes', '--offline', '--no-approve']
pairs = dict(zip(argv[12::2], argv[13::2]))
assert pairs['--provider'] == provider and pairs['--model'] == model
assert pairs['--thinking'] == thinking
assert pairs['--system-prompt'] == '<policy>'
assert pairs['--session-id'] == g['native_session_id']
assert pairs['--session-dir'] == str(out / 'private' / 'session')
assert 'FROZEN-COMMON-POLICY-TEXT' not in json.dumps(g)

final = out / 'final-output.txt'
assert g['final_output'] == {'path': str(final), 'sha256': sha(final)}
assert final.read_text().strip() == 'FIXTURE FINAL ANSWER'
evidence = out / 'native-evidence.json'
assert g['native_evidence'] == {'path': str(evidence), 'sha256': sha(evidence)}

# §10 sanitized evidence shape.
e = json.loads(evidence.read_text())
assert e['schema_version'] == 1
assert set(e['header']) == {'id', 'cwd', 'version', 'timestamp'}
assert e['header']['id'] == g['native_session_id']
assert e['header']['cwd'] == os.path.realpath(cwd)
assert e['model_changes'] == []
assert e['thinking_changes'] == [{'thinkingLevel': thinking}]
assert len(e['assistants']) == 1
a = e['assistants'][0]
assert set(a) == {'provider', 'model', 'api', 'stopReason', 'usage', 'text', 'content_kinds'}
assert a['stopReason'] == 'stop' and a['text'] == 'FIXTURE FINAL ANSWER'
assert a['content_kinds'] == ['text']
PY
}

@test "the fixture executable is the only process launched and receives the prompt on stdin" {
  mkcase only-fixture-invoked
  adapter
  receipt executed -
  [ ! -e "$EVIDENCE/tripwire/REAL-PI-INVOKED" ]
  "$PYTHON" - "$PI.invocations.jsonl" "$PROMPT" "$CWD" <<'PY'
import json
import os
import sys
records = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(records) == 1, 'exactly one generation invocation is permitted; got %d' % len(records)
from pathlib import Path
version = json.loads(Path(sys.argv[1].replace('.invocations.jsonl', '.version-invocation.json')).read_text())
assert version[1:] == ['--version']
r = records[0]
assert r['stdin'] == open(sys.argv[2]).read()
assert r['realcwd'] == os.path.realpath(sys.argv[3])
assert r['pgid'] == r['pid'], 'child must run in a new session/process group'
PY
}

# ---------------------------------------------------------------------------
# Identity, effort and stop-reason rejections (exit 2)
# ---------------------------------------------------------------------------

@test "assistant provider differing from the request is identity_mismatch" {
  mkcase provider-mismatch
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "provider": "other-provider", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt failed identity_mismatch
}

@test "assistant model differing from the request is identity_mismatch" {
  mkcase model-mismatch
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "model": "fixture-model-9", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt failed identity_mismatch
}

@test "recorded thinking level differing from the request is thinking_mismatch" {
  mkcase thinking-mismatch
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change", "thinkingLevel": "high"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt failed thinking_mismatch
}

@test "two distinct assistant model identities are model_switch" {
  mkcase model-switch
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "first"},
  {"kind": "model_change", "modelId": "fixture-model-2"},
  {"kind": "assistant", "model": "fixture-model-2", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt failed model_switch
}

@test "a toolCall content part anywhere is tool_use_present" {
  mkcase tool-use
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "tool": true, "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt failed tool_use_present
}

@test "final stopReason length is stop_reason_rejected" {
  mkcase stop-length
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "stopReason": "length", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt failed stop_reason_rejected
}

@test "final stopReason error is stop_reason_rejected" {
  mkcase stop-error
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "stopReason": "error", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt failed stop_reason_rejected
}

@test "empty final assistant text is empty_final_text" {
  mkcase empty-final
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "   \n  "}
]}
JSON
  adapter
  receipt failed empty_final_text
}

@test "no assistant message at all is no_terminal_assistant" {
  mkcase no-assistant
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "user", "text": "fixture evaluation prompt"}
]}
JSON
  adapter
  receipt failed no_terminal_assistant
}

@test "nonzero native exit is native_exit_nonzero" {
  mkcase nonzero-exit
  scenario <<'JSON'
{"exit_code": 3,
 "events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt failed native_exit_nonzero
  "$PYTHON" - "$OUT/generation.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['native_exit'] == 3
PY
}

# ---------------------------------------------------------------------------
# Untrustworthy evidence (exit 3)
# ---------------------------------------------------------------------------

@test "no session file written is session_missing" {
  mkcase session-missing
  scenario <<'JSON'
{"session_files": 0,
 "events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt unavailable session_missing
}

@test "two session files under the session dir is session_duplicate" {
  mkcase session-duplicate
  scenario <<'JSON'
{"session_files": 2,
 "events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt unavailable session_duplicate
}

@test "session header uuid differing from the requested uuid is session_mismatch" {
  mkcase session-mismatch
  scenario <<'JSON'
{"header_id": "11111111-2222-3333-4444-555555555555",
 "events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt unavailable session_mismatch
}

@test "session header cwd differing from realpath(--cwd) is session_mismatch" {
  mkcase session-cwd-mismatch
  scenario <<'JSON'
{"header_cwd": "/tmp/not-the-requested-cwd",
 "events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt unavailable session_mismatch
}

@test "stdout terminal assistant disagreeing with the session is stdout_session_disagreement" {
  mkcase stdout-disagreement
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
 ],
 "stdout_events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "A DIFFERENT FINAL ANSWER"}
]}
JSON
  adapter
  receipt unavailable stdout_session_disagreement
}

@test "a non-JSON stdout line after the first JSON line is stream_malformed" {
  mkcase stream-malformed
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
 ],
 "stdout_events": [
  {"kind": "thinking_level_change"},
  {"kind": "raw", "line": "pi: warning, not json"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt unavailable stream_malformed
}

@test "a native auto-retry record is native_retry_observed" {
  mkcase native-retry
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "retry"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt unavailable native_retry_observed
}

@test "stdout beyond 16 MiB is stream_overflow and is never truncated and scored" {
  mkcase stream-overflow
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
 ],
 "stdout_events": [
  {"kind": "thinking_level_change"},
  {"kind": "user", "text": "pad", "pad_text_bytes": 17825792},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt unavailable stream_overflow
}

@test "timeout is unavailable and the child process group is terminated and reaped" {
  mkcase timeout
  scenario <<'JSON'
{"sleep_seconds": 600,
 "events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter --timeout 2
  receipt unavailable timeout
  "$PYTHON" - "$PI.pids.json" "$OUT/generation.json" <<'PY'
import json
import os
import sys
import time
pids = json.load(open(sys.argv[1]))
g = json.load(open(sys.argv[2]))
assert g['elapsed_seconds'] > 0, 'timeout must never report a fabricated zero elapsed'
deadline = time.time() + 10
alive = None
while time.time() < deadline:
    alive = []
    for key in ('pid', 'child'):
        try:
            os.kill(pids[key], 0)
        except OSError:
            continue
        alive.append(key)
    if not alive:
        break
    time.sleep(0.2)
assert not alive, 'still alive after cleanup: %s (%s)' % (alive, pids)
try:
    os.killpg(pids['pgid'], 0)
except OSError:
    pass
else:
    raise AssertionError('child process group %s survived cleanup' % pids['pgid'])
PY
}

# ---------------------------------------------------------------------------
# Source drift after exit (exit 3)
# ---------------------------------------------------------------------------

@test "native executable changing during the run is source_drift" {
  mkcase drift-executable
  scenario <<'JSON'
{"drift_paths": ["SELF"],
 "events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt unavailable source_drift
}

@test "prompt file changing during the run is source_drift" {
  mkcase drift-prompt
  cat > "$PI.scenario.json" <<JSON
{"drift_paths": ["$PROMPT"],
 "events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt unavailable source_drift
}

@test "policy file changing during the run is source_drift" {
  mkcase drift-policy
  cat > "$PI.scenario.json" <<JSON
{"drift_paths": ["$POLICY"],
 "events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt unavailable source_drift
}

# ---------------------------------------------------------------------------
# Usage / precondition errors (exit 64, no receipt written)
# ---------------------------------------------------------------------------

@test "an unknown flag is bad_arguments" {
  mkcase usage-unknown-flag
  adapter --not-a-real-flag
  usage_error bad_arguments
}

@test "a relative --pi path is pi_not_absolute" {
  mkcase usage-pi-relative
  run "$PYTHON" "$MODULE" --pi "pi" --cwd "$CWD" --prompt "$PROMPT" --policy "$POLICY" \
    --provider "$PROVIDER" --model "$MODEL" --thinking "$THINKING" --output "$OUT"
  usage_error pi_not_absolute
  [ ! -e "$EVIDENCE/tripwire/REAL-PI-INVOKED" ]
}

@test "a non-executable --pi path is pi_not_executable" {
  mkcase usage-pi-not-executable
  chmod 0644 "$PI"
  adapter
  usage_error pi_not_executable
}

@test "an existing --output directory is output_exists" {
  mkcase usage-output-exists
  mkdir -p "$OUT"
  adapter
  [ "$status" -eq 64 ]
  [ "$output" = "skill-eval-pi: output_exists" ]
  [ ! -e "$OUT/generation.json" ]
}

@test "an --output path that is a dangling symlink is output_exists" {
  mkcase usage-output-symlink
  ln -s "$CASE/no-such-target" "$OUT"
  adapter
  [ "$status" -eq 64 ]
  [ "$output" = "skill-eval-pi: output_exists" ]
  [ ! -e "$CASE/no-such-target" ]
}

@test "a missing --cwd is cwd_missing" {
  mkcase usage-cwd-missing
  rmdir "$CWD"
  adapter
  usage_error cwd_missing
}

@test "a --cwd holding .trellis/runtime is cwd_attached" {
  mkcase usage-cwd-attached
  mkdir -p "$CWD/.trellis/runtime"
  adapter
  usage_error cwd_attached
}

@test "a missing input file is input_missing" {
  mkcase usage-input-missing
  rm "$PROMPT"
  adapter
  usage_error input_missing
}

@test "a symlinked input file is input_symlink" {
  mkcase usage-input-symlink
  mv "$PROMPT" "$CASE/real-prompt.txt"
  ln -s "$CASE/real-prompt.txt" "$PROMPT"
  adapter
  usage_error input_symlink
}

@test "an input file that is not a regular file is input_not_regular" {
  mkcase usage-input-not-regular
  rm "$PROMPT"
  mkdir "$PROMPT"
  adapter
  usage_error input_not_regular
}

@test "an input file above 1 MiB is input_too_large" {
  mkcase usage-input-too-large
  "$PYTHON" -c "import sys; open(sys.argv[1],'wb').write(b'a'*1048577)" "$PROMPT"
  adapter
  usage_error input_too_large
}

@test "an input file at exactly 1 MiB is accepted" {
  mkcase usage-input-at-limit
  "$PYTHON" -c "import sys; open(sys.argv[1],'wb').write(b'a'*1048576)" "$PROMPT"
  adapter
  receipt executed -
}

@test "an input file that is not UTF-8 is input_not_utf8" {
  mkcase usage-input-not-utf8
  "$PYTHON" -c "import sys; open(sys.argv[1],'wb').write(b'ok\xff\xfebad')" "$POLICY"
  adapter
  usage_error input_not_utf8
}

@test "a --timeout outside 1..600 is timeout_out_of_range" {
  mkcase usage-timeout-low
  adapter --timeout 0
  usage_error timeout_out_of_range
  mkcase usage-timeout-high
  adapter --timeout 601
  usage_error timeout_out_of_range
}

# ---------------------------------------------------------------------------
# Confidentiality, usage nulling, permissions
# ---------------------------------------------------------------------------

@test "thinking text and signatures never reach the public receipt or sanitized evidence" {
  mkcase thinking-exclusion
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant",
   "thinking_text": "TTOKEN-PRIVATE-CHAIN-OF-THOUGHT",
   "thinking_signature": "TSIG-ENCRYPTED-REASONING",
   "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt executed -
  for public in generation.json native-evidence.json final-output.txt; do
    run grep -c -e TTOKEN-PRIVATE-CHAIN-OF-THOUGHT -e TSIG-ENCRYPTED-REASONING "$OUT/$public"
    [ "$status" -ne 0 ]
  done
  "$PYTHON" - "$OUT" <<'PY'
import json
import sys
from pathlib import Path
out = Path(sys.argv[1])
e = json.loads((out / 'native-evidence.json').read_text())
a = e['assistants'][0]
assert a['content_kinds'] == ['thinking', 'text'], a['content_kinds']
assert 'thinking' not in a and 'signature' not in a
blob = json.dumps(e)
assert 'TTOKEN' not in blob and 'TSIG' not in blob
# The raw private stream retains what the sanitized surface drops.
raw = (out / 'private' / 'stdout.txt').read_text()
assert 'TTOKEN-PRIVATE-CHAIN-OF-THOUGHT' in raw
PY
}

@test "usage absent from the native stream stays null and is never defaulted to 0" {
  mkcase usage-null
  scenario <<'JSON'
{"events": [
  {"kind": "thinking_level_change"},
  {"kind": "assistant", "text": "FIXTURE FINAL ANSWER"}
]}
JSON
  adapter
  receipt executed -
  "$PYTHON" - "$OUT" <<'PY'
import json
import sys
from pathlib import Path
out = Path(sys.argv[1])
g = json.loads((out / 'generation.json').read_text())
assert g['usage'] is None, g['usage']
assert json.loads((out / 'native-evidence.json').read_text())['assistants'][0]['usage'] is None
PY
}

@test "output tree permissions are 0700 for directories and 0600 for files" {
  mkcase permissions
  adapter
  receipt executed -
  "$PYTHON" - "$OUT" <<'PY'
import stat
import sys
from pathlib import Path
out = Path(sys.argv[1])
def mode(p):
    return stat.S_IMODE(p.lstat().st_mode)
for directory in [out, out / 'private', out / 'private' / 'session']:
    assert directory.is_dir() and mode(directory) == 0o700, (directory, oct(mode(directory)))
for name in ['generation.json', 'final-output.txt', 'native-evidence.json',
             'private/stdout.txt', 'private/stderr.txt',
             *[str(p.relative_to(out)) for p in (out / 'private/session').glob('*.jsonl')]]:
    f = out / name
    assert f.is_file() and not f.is_symlink(), f
    assert mode(f) == 0o600, (f, oct(mode(f)))
PY
}

@test "missing thinking evidence is unavailable" {
  mkcase missing-thinking
  scenario <<'JSON'
{"events":[{"kind":"assistant","text":"answer"}]}
JSON
  adapter
  receipt unavailable thinking_missing
}

@test "changed then restored effort is rejected" {
  mkcase effort-restored
  scenario <<'JSON'
{"events":[{"kind":"thinking_level_change","thinkingLevel":"high"},{"kind":"thinking_level_change","thinkingLevel":"medium"},{"kind":"assistant","text":"answer"}]}
JSON
  adapter
  receipt failed thinking_mismatch
}

@test "a single wrong model_change identity cannot hide behind a correct assistant" {
  mkcase model-entry-wrong
  scenario <<'JSON'
{"events":[{"kind":"thinking_level_change"},{"kind":"model_change","provider":"wrong"},{"kind":"assistant","text":"answer"}]}
JSON
  adapter
  receipt failed identity_mismatch
}

@test "missing or nonstring assistant identity is unavailable without traceback" {
  for identity in null '[]' '""'; do
    mkcase "identity-$identity"
    scenario <<JSON
{"events":[{"kind":"thinking_level_change"},{"kind":"assistant","provider":$identity,"text":"answer"}]}
JSON
    adapter
    receipt unavailable stream_malformed
    [[ "$output" != *Traceback* ]]
  done
}

@test "duplicate headers in either source are unavailable" {
  for flag in duplicate_header duplicate_stdout_header; do
    mkcase "$flag"
    scenario <<JSON
{"$flag":true,"events":[{"kind":"thinking_level_change"},{"kind":"assistant","text":"answer"}]}
JSON
    adapter
    receipt unavailable session_mismatch
  done
}

@test "missing stdout header or agent_end is unavailable" {
  for flag in '"stdout_header":false' '"missing_agent_end":true'; do
    mkcase "lifecycle-$flag"
    scenario <<JSON
{$flag,"events":[{"kind":"thinking_level_change"},{"kind":"assistant","text":"answer"}]}
JSON
    adapter
    receipt unavailable stream_malformed
  done
}

@test "earlier terminal disagreement is rejected even with identical final text" {
  mkcase earlier-disagreement
  scenario <<'JSON'
{"events":[{"kind":"thinking_level_change"},{"kind":"assistant","text":"first"},{"kind":"assistant","text":"last"}],"stdout_events":[{"kind":"assistant","text":"different"},{"kind":"assistant","text":"last"}]}
JSON
  adapter
  receipt unavailable stdout_session_disagreement
}

@test "saved message grammar on stdout is not terminal wire evidence" {
  mkcase wrong-grammar
  scenario <<'JSON'
{"events":[{"kind":"thinking_level_change"},{"kind":"assistant","text":"answer"}],"stdout_events":[{"kind":"raw","line":"{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"provider\":\"fixture-provider\",\"model\":\"fixture-model-1\",\"stopReason\":\"stop\",\"content\":[{\"type\":\"text\",\"text\":\"answer\"}]}}"}]}
JSON
  adapter
  receipt unavailable stream_malformed
}

@test "branch and compaction events are unavailable" {
  for kind in branch_summary compaction compaction_start compaction_end; do
    mkcase "$kind"
    scenario <<JSON
{"events":[{"kind":"thinking_level_change"},{"kind":"record","record":{"type":"$kind"}},{"kind":"assistant","text":"answer"}]}
JSON
    adapter
    receipt unavailable session_mismatch
  done
  mkcase branch-parent
  scenario <<'JSON'
{"branch_parent":true,"events":[{"kind":"thinking_level_change"},{"kind":"assistant","text":"answer"}]}
JSON
  adapter
  receipt unavailable session_mismatch
}

@test "toolResult and bashExecution message roles are rejected" {
  for role in toolResult bashExecution; do
    mkcase "$role"
    scenario <<JSON
{"events":[{"kind":"thinking_level_change"},{"kind":"record","record":{"type":"message","message":{"role":"$role","content":[]}}},{"kind":"assistant","text":"answer"}]}
JSON
    adapter
    receipt failed tool_use_present
  done
}

@test "tool execution events are rejected" {
  for kind in tool_execution_start tool_execution_update tool_execution_end; do
    mkcase "$kind"
    scenario <<JSON
{"events":[{"kind":"thinking_level_change"},{"kind":"assistant","text":"answer"}],"stdout_events":[{"kind":"record","record":{"type":"$kind"}},{"kind":"assistant","text":"answer"}]}
JSON
    adapter
    receipt failed tool_use_present
  done
}

@test "malformed text parts are unavailable without traceback" {
  local index=0
  for content in '[{"type":"text","text":7}]' '[{"type":"text","text":null}]' '[null]' '"text"' '[{"type":[],"text":"answer"}]'; do
    index=$((index + 1))
    mkcase "malformed-$index"
    scenario <<JSON
{"events":[{"kind":"thinking_level_change"},{"kind":"assistant","content":$content}]}
JSON
    adapter
    receipt unavailable stream_malformed
    [[ "$output" != *Traceback* ]]
  done
}

@test "version is measured from selected executable and never header format" {
  mkcase measured-version
  scenario <<'JSON'
{"version_text":"9.8.7","events":[{"kind":"thinking_level_change"},{"kind":"assistant","text":"answer"}]}
JSON
  adapter
  receipt executed -
  "$PYTHON" -c 'import json,sys; g=json.load(open(sys.argv[1])); assert g["observed_executor"]["harness_version"] == "9.8.7"' "$OUT/generation.json"
}

@test "missing malformed or failing version probe prevents generation" {
  for fields in '"version_text":""' '"version_text":"not a version"' '"version_exit":9'; do
    mkcase "version-$fields"
    scenario <<JSON
{$fields,"events":[{"kind":"thinking_level_change"},{"kind":"assistant","text":"answer"}]}
JSON
    adapter
    receipt unavailable version_unavailable
    [ ! -e "$PI.invocations.jsonl" ]
    [[ "$output" != *Traceback* ]]
  done
}

# Deterministic boundary injection: change the path AFTER validation captures A,
# before _run starts. An alarm makes FIFO regressions fail rather than hang.
binding_probe() {
  "$PYTHON" - "$MODULE" "$PI" "$CWD" "$PROMPT" "$POLICY" "$OUT" "$1" "$2" <<'PY'
import hashlib, importlib.util, json, os, signal, sys
from pathlib import Path
module, pi, cwd, prompt, policy, out, kind, selected = sys.argv[1:]
signal.signal(signal.SIGALRM, lambda *_: sys.exit(99))
signal.alarm(8)
spec = importlib.util.spec_from_file_location('adapter', module)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
args = m._parse(['--pi',pi,'--cwd',cwd,'--prompt',prompt,'--policy',policy,
                 '--output',out,'--provider','fixture-provider','--model','fixture-model-1',
                 '--thinking','medium'])
original = {key: Path(value).read_bytes() for key,value in [('prompt',prompt),('policy',policy)]}
a, b = m._validate(args)
p = Path(prompt if selected == 'prompt' else policy)
if kind == 'inplace':
    p.write_bytes(b'CHANGED B\n')
else:
    p.rename(p.with_suffix('.held'))
    if kind == 'same':
        p.write_bytes(original[selected])
    elif kind == 'fifo':
        os.mkfifo(p)
    elif kind == 'symlink':
        p.symlink_to(p.with_suffix('.held'))
    elif kind == 'large':
        p.write_bytes(b'x' * (1048576 + 1))
code = m._run(args, a, b)
g = json.loads((Path(out)/'generation.json').read_text())
native = json.loads(Path(pi+'.invocations.jsonl').read_text())
assert native['stdin'].encode() == original['prompt']
assert native['argv'][native['argv'].index('--system-prompt')+1].encode() == original['policy']
for key in original:
    assert g[key+'_sha256'] == hashlib.sha256(original[key]).hexdigest(), g
assert code == 3 and g['reason'] == 'source_drift', g
PY
}

@test "captured prompt and policy hashes bind sent bytes across input swaps" {
  for selected in prompt policy; do
    for kind in inplace same symlink fifo large; do
      mkcase "binding-$selected-$kind"
      binding_probe "$kind" "$selected"
    done
  done
}

@test "disposable source-drift guard mutant fails the same input binding oracle" {
  mkcase binding-guard-mutant
  local original_module="$MODULE"
  MODULE="$CASE/guard-mutant.py"
  "$PYTHON" - "$original_module" "$MODULE" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text()
guard = 'if current.identity != captured.identity or current.sha256 != captured.sha256:'
assert src.count(guard) == 1
Path(sys.argv[2]).write_text(src.replace(guard, 'if False:'))
PY
  run binding_probe same prompt
  printf '%s\n' "$output" > "$CASE/mutant-oracle.log"
  printf '%s\n' "$status" > "$CASE/mutant-oracle.exit"
  [ "$status" -eq 1 ]
  [[ "$output" == *AssertionError* ]]
  MODULE="$original_module"
}

@test "input open rejects a symlink swapped at the descriptor boundary" {
  mkcase open-race
  "$PYTHON" - "$MODULE" "$PROMPT" <<'PY'
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('adapter', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
p = Path(sys.argv[2])
real = os.open
def swap(path, flags, *args, **kwargs):
    if Path(path) == p:
        p.rename(p.with_suffix('.held'))
        p.symlink_to(p.with_suffix('.held'))
    return real(path, flags, *args, **kwargs)
m.os.open = swap
try:
    m._read_input(p)
except m.UsageError as exc:
    assert str(exc) == 'input_symlink'
else:
    raise AssertionError('symlink race accepted')
PY
}

@test "native session mode is tightened and symlink or FIFO sessions are rejected" {
  for field in '"session_mode":420' '"session_symlink":true' '"session_fifo":true'; do
    mkcase "session-safety-$field"
    scenario <<JSON
{$field,"events":[{"kind":"thinking_level_change"},{"kind":"assistant","text":"answer"}]}
JSON
    # Bound the whole adapter, including post-native file collection.
    run "$PYTHON" - "$MODULE" "$PI" "$CWD" "$PROMPT" "$POLICY" "$OUT" <<'PY'
import subprocess, sys
module, pi, cwd, prompt, policy, out = sys.argv[1:]
r = subprocess.run([sys.executable,module,'--pi',pi,'--cwd',cwd,'--prompt',prompt,
                    '--policy',policy,'--output',out,'--provider','fixture-provider',
                    '--model','fixture-model-1','--thinking','medium'], timeout=8)
sys.exit(r.returncode)
PY
    printf '%s\n' "$status" > "$CASE/adapter.exit"
    if [[ "$field" == *session_mode* ]]; then
      receipt executed -
      "$PYTHON" -c 'import pathlib,stat,sys; assert all(stat.S_IMODE(p.stat().st_mode)==0o600 for p in pathlib.Path(sys.argv[1]).glob("private/session/*.jsonl"))' "$OUT"
    else
      receipt unavailable stream_malformed
      [ ! -e "$OUT/native-evidence.json" ]
      [ ! -e "$OUT/final-output.txt" ]
      if [[ "$field" == *symlink* ]]; then
        "$PYTHON" -c 'import os,stat,sys; assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode)==0o644' "$CASE/external-session"
      fi
    fi
  done
}

@test "session permission verification rejects a silently ineffective fchmod" {
  mkcase mode-noop
  scenario <<'JSON'
{"session_mode":420,"events":[{"kind":"thinking_level_change"},{"kind":"assistant","text":"answer"}]}
JSON
  "$PYTHON" - "$MODULE" "$PI" "$CWD" "$PROMPT" "$POLICY" "$OUT" <<'PY'
import importlib.util, json, sys
from pathlib import Path
module, pi, cwd, prompt, policy, out = sys.argv[1:]
spec = importlib.util.spec_from_file_location('adapter', module)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.os.fchmod = lambda *args: None
code = m.main(['--pi',pi,'--cwd',cwd,'--prompt',prompt,'--policy',policy,'--output',out,
               '--provider','fixture-provider','--model','fixture-model-1','--thinking','medium'])
g = json.loads((Path(out)/'generation.json').read_text())
assert code == 3 and g['reason'] == 'stream_malformed', g
assert g['native_evidence'] is None and g['final_output'] is None
PY
}

@test "stderr overflow kills the generation before its delayed side effect" {
  mkcase stderr-overflow
  "$PYTHON" - "$PI.scenario.json" <<'PY'
import json,sys
json.dump({'stderr_text':'x' * (16 * 1048576 + 1), 'sleep_seconds':600,
           'events':[{'kind':'thinking_level_change'},{'kind':'assistant','text':'answer'}]},open(sys.argv[1],'w'))
PY
  adapter --timeout 5
  receipt unavailable stream_overflow
  "$PYTHON" - "$OUT/private/stderr.txt" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).stat().st_size == 16 * 1048576 + 1
PY
}


# ---------------------------------------------------------------------------
# Installed 0.85.1 terminal lifecycle: agent_settled and agent_end.willRetry
# ---------------------------------------------------------------------------

@test "a terminal agent_settled after the sole agent_end executes" {
  mkcase settled-terminal
  scenario <<'JSON'
{"agent_settled":1,"events":[{"kind":"thinking_level_change"},{"kind":"user","text":"fixture evaluation prompt"},{"kind":"assistant","text":"FIXTURE FINAL ANSWER"}]}
JSON
  adapter
  receipt executed -
}

@test "more than one agent_settled is stream_malformed" {
  mkcase settled-duplicate
  scenario <<'JSON'
{"agent_settled":2,"events":[{"kind":"thinking_level_change"},{"kind":"user","text":"fixture evaluation prompt"},{"kind":"assistant","text":"FIXTURE FINAL ANSWER"}]}
JSON
  adapter
  receipt unavailable stream_malformed
}

@test "agent_settled before the agent_end is stream_malformed" {
  mkcase settled-early
  scenario <<'JSON'
{"events":[{"kind":"thinking_level_change"},{"kind":"user","text":"fixture evaluation prompt"},{"kind":"assistant","text":"FIXTURE FINAL ANSWER"}],"stdout_events":[{"kind":"thinking_level_change"},{"kind":"user","text":"fixture evaluation prompt"},{"kind":"assistant","text":"FIXTURE FINAL ANSWER"},{"kind":"raw","line":"{\"type\":\"agent_settled\"}"}]}
JSON
  adapter
  receipt unavailable stream_malformed
}

@test "a wire record after the terminal agent_settled is stream_malformed" {
  mkcase settled-trailing
  scenario <<'JSON'
{"agent_settled":1,"stdout_suffix_lines":["{\"type\":\"queue_update\"}"],"events":[{"kind":"thinking_level_change"},{"kind":"user","text":"fixture evaluation prompt"},{"kind":"assistant","text":"FIXTURE FINAL ANSWER"}]}
JSON
  adapter
  receipt unavailable stream_malformed
}

# The open-turn guard is defence in depth: an idle settle inside a live turn also
# breaks the terminal position rule, so both conditions report stream_malformed.
@test "agent_settled announced inside an unfinished turn is stream_malformed" {
  mkcase settled-in-turn
  scenario <<'JSON'
{"settled_in_turn":true,"events":[{"kind":"thinking_level_change"},{"kind":"user","text":"fixture evaluation prompt"},{"kind":"assistant","text":"FIXTURE FINAL ANSWER"}]}
JSON
  adapter
  receipt unavailable stream_malformed
}

@test "agent_settled persisted as a session entry is stream_malformed" {
  mkcase settled-in-session
  scenario <<'JSON'
{"events":[{"kind":"thinking_level_change"},{"kind":"user","text":"fixture evaluation prompt"},{"kind":"assistant","text":"FIXTURE FINAL ANSWER"},{"kind":"record","record":{"type":"agent_settled"}}],"stdout_events":[{"kind":"thinking_level_change"},{"kind":"user","text":"fixture evaluation prompt"},{"kind":"assistant","text":"FIXTURE FINAL ANSWER"}]}
JSON
  adapter
  receipt unavailable stream_malformed
}

@test "agent_end willRetry false is a clean single shot and executes" {
  mkcase will-retry-false
  scenario <<'JSON'
{"agent_settled":1,"will_retry":false,"events":[{"kind":"thinking_level_change"},{"kind":"user","text":"fixture evaluation prompt"},{"kind":"assistant","text":"FIXTURE FINAL ANSWER"}]}
JSON
  adapter
  receipt executed -
}

@test "agent_end willRetry true is native_retry_observed" {
  mkcase will-retry-true
  scenario <<'JSON'
{"agent_settled":1,"will_retry":true,"events":[{"kind":"thinking_level_change"},{"kind":"user","text":"fixture evaluation prompt"},{"kind":"assistant","text":"FIXTURE FINAL ANSWER"}]}
JSON
  adapter
  receipt unavailable native_retry_observed
}

@test "a non-boolean agent_end willRetry is stream_malformed" {
  for value in '"false"' '1' '0' 'null'; do
    mkcase "will-retry-nonbool-$(printf '%s' "$value" | tr -d '\"')"
    scenario <<JSON
{"agent_settled":1,"will_retry":$value,"events":[{"kind":"thinking_level_change"},{"kind":"user","text":"fixture evaluation prompt"},{"kind":"assistant","text":"FIXTURE FINAL ANSWER"}]}
JSON
    adapter
    receipt unavailable stream_malformed
  done
}

# Verbatim copy of the retained 0.85.1 native probe stream (session
# 6d18538d-2a02-48be-9a39-30a4c0d63efa). It is replayed through the pure
# evaluate(), never re-executed against a provider.
@test "the retained native 0.85.1 probe stream replays as executed" {
  mkcase native-replay
  cat > "$CASE/native-stdout.jsonl" <<'RETAINED_STDOUT'
{"type":"session","version":3,"id":"6d18538d-2a02-48be-9a39-30a4c0d63efa","timestamp":"2026-09-06T07:56:37.258Z","cwd":"/private/tmp/trellis-pi-native-probe-3ms9sjiz/cwd"}
{"type":"agent_start"}
{"type":"turn_start"}
{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"Return exactly this JSON object and nothing else: {\"probe\":\"trellis-pi-generation-v1\"}"}],"timestamp":1788681397325}}
{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"Return exactly this JSON object and nothing else: {\"probe\":\"trellis-pi-generation-v1\"}"}],"timestamp":1788681397325}}
{"type":"message_start","message":{"role":"assistant","content":[],"api":"openai-codex-responses","provider":"openai-codex","model":"gpt-6-astra","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"pending","timestamp":1788681397329}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_start","contentIndex":0}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"{\""}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"probe"}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"\":\""}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"tre"}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"llis"}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"-p"}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"i"}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"-generation"}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"-v"}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"1"}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"\"}"}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"{\"probe\":\"trellis-pi-generation-v1\"}"}}
{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"{\"probe\":\"trellis-pi-generation-v1\"}","textSignature":"{\"v\":1,\"id\":\"msg_0dd20f80d7cb345f016a9d1cb8717887d09ac8879ef80c956e\",\"phase\":\"final_answer\"}"}],"api":"openai-codex-responses","provider":"openai-codex","model":"gpt-6-astra","usage":{"input":73,"output":15,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":88,"cost":{"input":0.0007300000000000001,"output":0.00075,"cacheRead":0,"cacheWrite":0,"total":0.00148}},"stopReason":"stop","timestamp":1788681397329,"responseId":"resp_0dd20f80d7cb345f016a9d1cb692ec87d09418bc016a4280db","rawStopReason":"completed"}}
{"type":"turn_end","message":{"role":"assistant","content":[{"type":"text","text":"{\"probe\":\"trellis-pi-generation-v1\"}","textSignature":"{\"v\":1,\"id\":\"msg_0dd20f80d7cb345f016a9d1cb8717887d09ac8879ef80c956e\",\"phase\":\"final_answer\"}"}],"api":"openai-codex-responses","provider":"openai-codex","model":"gpt-6-astra","usage":{"input":73,"output":15,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":88,"cost":{"input":0.0007300000000000001,"output":0.00075,"cacheRead":0,"cacheWrite":0,"total":0.00148}},"stopReason":"stop","timestamp":1788681397329,"responseId":"resp_0dd20f80d7cb345f016a9d1cb692ec87d09418bc016a4280db","rawStopReason":"completed"},"toolResults":[]}
{"type":"agent_end","messages":[{"role":"user","content":[{"type":"text","text":"Return exactly this JSON object and nothing else: {\"probe\":\"trellis-pi-generation-v1\"}"}],"timestamp":1788681397325},{"role":"assistant","content":[{"type":"text","text":"{\"probe\":\"trellis-pi-generation-v1\"}","textSignature":"{\"v\":1,\"id\":\"msg_0dd20f80d7cb345f016a9d1cb8717887d09ac8879ef80c956e\",\"phase\":\"final_answer\"}"}],"api":"openai-codex-responses","provider":"openai-codex","model":"gpt-6-astra","usage":{"input":73,"output":15,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":88,"cost":{"input":0.0007300000000000001,"output":0.00075,"cacheRead":0,"cacheWrite":0,"total":0.00148}},"stopReason":"stop","timestamp":1788681397329,"responseId":"resp_0dd20f80d7cb345f016a9d1cb692ec87d09418bc016a4280db","rawStopReason":"completed"}],"willRetry":false}
{"type":"agent_settled"}
RETAINED_STDOUT
  cat > "$CASE/native-session.jsonl" <<'RETAINED_SESSION'
{"type":"session","version":3,"id":"6d18538d-2a02-48be-9a39-30a4c0d63efa","timestamp":"2026-09-06T07:56:37.258Z","cwd":"/private/tmp/trellis-pi-native-probe-3ms9sjiz/cwd"}
{"type":"model_change","id":"bd749425","parentId":null,"timestamp":"2026-09-06T07:56:37.323Z","provider":"openai-codex","modelId":"gpt-6-astra"}
{"type":"thinking_level_change","id":"3c2497d6","parentId":"bd749425","timestamp":"2026-09-06T07:56:37.323Z","thinkingLevel":"low"}
{"type":"message","id":"5d8a2efc","parentId":"3c2497d6","timestamp":"2026-09-06T07:56:37.326Z","message":{"role":"user","content":[{"type":"text","text":"Return exactly this JSON object and nothing else: {\"probe\":\"trellis-pi-generation-v1\"}"}],"timestamp":1788681397325}}
{"type":"message","id":"a1a3a286","parentId":"5d8a2efc","timestamp":"2026-09-06T07:56:41.607Z","message":{"role":"assistant","content":[{"type":"text","text":"{\"probe\":\"trellis-pi-generation-v1\"}","textSignature":"{\"v\":1,\"id\":\"msg_0dd20f80d7cb345f016a9d1cb8717887d09ac8879ef80c956e\",\"phase\":\"final_answer\"}"}],"api":"openai-codex-responses","provider":"openai-codex","model":"gpt-6-astra","usage":{"input":73,"output":15,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":88,"cost":{"input":0.0007300000000000001,"output":0.00075,"cacheRead":0,"cacheWrite":0,"total":0.00148}},"stopReason":"stop","timestamp":1788681397329,"responseId":"resp_0dd20f80d7cb345f016a9d1cb692ec87d09418bc016a4280db","rawStopReason":"completed"}}
RETAINED_SESSION
  "$PYTHON" - "$MODULE" "$CASE/native-session.jsonl" "$CASE/native-stdout.jsonl" <<'PY'
import importlib.util, json, sys
module, session_path, stdout_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location('adapter', module)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
load = lambda p: [json.loads(l) for l in open(p) if l.strip()]
records, stdout_records = load(session_path), load(stdout_path)
assert [r['type'] for r in stdout_records[-2:]] == ['agent_end', 'agent_settled'], stdout_records[-2:]
assert stdout_records[-2]['willRetry'] is False
requested = {'provider': 'openai-codex', 'model': 'gpt-6-astra', 'thinking': 'low',
             'session_id': records[0]['id'], 'cwd': records[0]['cwd'], 'reasons': ()}
assert m.evaluate(records, stdout_records, requested, 0) == ('executed', None), \
    m.evaluate(records, stdout_records, requested, 0)
PY
}
