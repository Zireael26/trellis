// Shared policy oracle: every parity-cases.json row, including legacy envelopes
// Pi cannot emit. Native malformed-target/content/override policy is stricter.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { loadGuardRules, destructiveMatches, rereadBudget, rereadDecision, responseFailed, recordReadTargets } from '../extensions/trellis.ts';
import { deliveredFixture } from './delivered-fixture.mjs';
import { normalizeStep, tableFixture } from './table-adapter.mjs';

const hooks = fileURLToPath(new URL('../../hooks/', import.meta.url));
const table = JSON.parse(readFileSync(resolve(hooks, 'tests/parity-cases.json'), 'utf8'));
const destructiveRules = JSON.parse(readFileSync(resolve(hooks, 'rules/destructive.json'), 'utf8')).rules;
const rules = loadGuardRules(resolve(hooks, 'rules'));
const expectation = (row, engine = 'pi') => {
  const value = typeof row.expect === 'string' ? row.expect : row.expect[engine] ?? (engine === 'pi' ? row.expect.codex : undefined);
  assert.equal(typeof value, 'string', `${row.id}: missing ${engine} expectation (rows must not be omitted)`);
  return value;
};
function totals(t, section, checked, multiplier = 1) {
  assert.deepEqual(checked, table[section].map(row => row.id), 'every table row ran in order');
  assert.equal(new Set(checked).size, table[section].length, 'unique row names');
  t.diagnostic(`checked ${checked.length}/${table[section].length} ${section} rows (${checked.length * multiplier} case/engine evaluations)`);
}

test('shared rule parity: destructive', async t => {
  const checked = [];
  for (const row of table.destructive) await t.test(row.id, () => {
    checked.push(row.id);
    // Claude's exemption requires every simple command to be allowlisted; Pi uses Codex.
    for (const engine of ['claude', 'codex']) {
      const matches = destructiveMatches(rules, row.command, engine);
      assert.equal(matches.map(({ effect, id }) => `${effect}:${id}`).join(',') || 'allow',
        expectation(row, engine === 'codex' ? 'pi' : engine), engine);
      for (const match of matches) assert.ok(match.reason, `${engine} ${match.id}: visible reason`);
    }
  });
  totals(t, 'destructive', checked, 2);
});

test('shared rule parity: ASCII fold and exact line anchors', () => {
  for (const [command, expected] of [
    ['drop database prod', 'deny:sql-drop-truncate'],
    ['DROP DATABAſE prod', 'allow'],
    ['DROP\u00a0TABLE users', 'allow'],
    ['git push -f\u2028', 'allow'],
    ['git reset --hard HEAD\u2029', 'allow'],
    ['rm -rf ..\u2028', 'allow'],
    ['git push -f\n', 'deny:git-force-push'],
  ]) for (const engine of ['claude', 'codex']) {
    assert.equal(destructiveMatches(rules, command, engine).map(({ effect, id }) => `${effect}:${id}`).join(',') || 'allow',
      expected, `${engine}: ${JSON.stringify(command)}`);
  }
});

test('shared rule parity: reread', async t => {
  const checked = [];
  for (const row of table.reread) await t.test(row.id, child => {
    checked.push(row.id);
    const f = tableFixture(child, row), steps = [];
    for (const step of row.steps ?? [row]) {
      const action = normalizeStep(step, f.project), events = [];
      if (action) {
        const state = f.stateFor(action), budget = rereadBudget(f.project, rules);
        for (const target of action.targets.filter(target => target.operation !== 'read')) {
          const path = resolve(action.cwd, target.path);
          const decision = rereadDecision(rules, path, state, budget, row.env?.TRELLIS_REREAD_OVERRIDE === '1');
          if (decision.decision === 'warn') {
            const warn = decision.reason?.match(/^reread-guard: about to edit (.*) not Read this turn \(warn ([0-9]+)\/([0-9]+)\)\. /);
            assert.ok(warn, 'well-formed warning');
            assert.equal(state.warns.get(path), Number(warn[2]), 'warning count persisted');
            events.push(`warn:${warn[2]}/${warn[3]}:${f.relpath(warn[1])}`);
          } else if (decision.decision === 'deny') {
            const block = decision.reason?.match(/^reread-guard: BLOCKED edit of (.*) — it was not Read this turn/);
            assert.ok(block, 'well-formed blocking reason');
            events.push(`block:${f.relpath(block[1])}`); break;
          } else assert.equal(decision.decision, 'allow');
        }
      }
      steps.push(events.join(';') || 'allow');
    }
    assert.equal(steps.join(' | '), expectation(row));
  });
  totals(t, 'reread', checked);
});

test('shared rule parity: track_read', async t => {
  const checked = [];
  for (const row of table.track_read) await t.test(row.id, child => {
    checked.push(row.id);
    const f = tableFixture(child, row), action = normalizeStep(row, f.project);
    let events = [];
    if (action) {
      const state = f.stateFor(action), before = new Set(state.known);
      recordReadTargets(state, action.targets, action.cwd, responseFailed(rules, action.response, action.toolName));
      const alias = action.source === 'parity-session' ? '' : `[${action.source}]`;
      events = [...state.known].filter(path => !before.has(path)).map(path => `record${alias}:${f.relpath(path)}`);
    }
    assert.equal(events.join(';') || 'skip', expectation(row));
  });
  totals(t, 'track_read', checked);
});

for (const native of ['tool_call', 'user_bash']) {
  test(`native shared rule parity: ${native}`, async t => {
    const f = await deliveredFixture(t), checked = [];
    for (const row of table.destructive) await t.test(row.id, async () => {
      checked.push(row.id);
      const before = f.notifications.length, calls = f.calls.length;
      // Query the handlers only: none of the table's shell commands execute.
      const result = native === 'tool_call'
        ? await f.fire(native, f.call('bash', { command: row.command }))
        : await f.fire(native, { command: row.command, cwd: f.cwd, excludeFromContext: true });
      const expected = expectation(row).split(',');
      const denied = expected.find(event => event.startsWith('deny:'));
      const output = native === 'tool_call' ? result?.reason : result?.result?.output;
      if (denied) {
        assert.equal(native === 'tool_call' ? result?.block : result?.result?.exitCode, native === 'tool_call' ? true : 1);
        assert.ok(output?.includes(destructiveRules.find(rule => rule.id === denied.slice(5)).reason), 'matching deny reason');
      } else assert.equal(result, undefined, 'safe/warn-only commands proceed');
      const messages = [...f.notifications.slice(before).map(([message]) => message), output ?? ''].join('\n');
      const warns = destructiveRules.filter(rule => rule.effect === 'warn' && messages.includes(rule.message_by_engine?.codex ?? rule.message))
        .map(rule => `warn:${rule.id}`);
      assert.deepEqual(warns, expected.filter(event => event.startsWith('warn:')), 'native warnings match the table');
      assert.equal(f.calls.length, calls, 'non-gh pre-action policy must not dispatch');
    });
    totals(t, 'destructive', checked);
  });
}
