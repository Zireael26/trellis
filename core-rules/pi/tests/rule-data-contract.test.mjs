// Closed-schema loading and data-driven exemption behavior, independent of the
// current gcloud/kubectl spellings. The shared table pins the actual policy.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { loadGuardRules, destructiveMatches } from '../extensions/trellis.ts';
import { deliveredFixture } from './delivered-fixture.mjs';

const destructive = JSON.parse(readFileSync(new URL('../../hooks/rules/destructive.json', import.meta.url), 'utf8'));
const reread = JSON.parse(readFileSync(new URL('../../hooks/rules/reread.json', import.meta.url), 'utf8'));
function fixture(t, mutate) {
  const directory = mkdtempSync(resolve(tmpdir(), 'trellis-rule-contract-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const documents = { destructive: structuredClone(destructive), reread: structuredClone(reread) };
  mutate(documents);
  for (const [name, doc] of Object.entries(documents)) writeFileSync(resolve(directory, `${name}.json`), JSON.stringify(doc));
  return directory;
}

for (const [name, mutate] of [
  ['document', docs => { docs.destructive.future_policy = true; }],
  ['rule', docs => { docs.destructive.rules[0].future_policy = true; }],
  ['superseded rewrite', docs => { docs.destructive.rules.at(-1).rewrite = {}; }],
  ['exemption', docs => { docs.destructive.rules.at(-1).exempt.future_policy = true; }],
  ['superseded exemption field', docs => { docs.destructive.rules.at(-1).exempt.commands = ['gcloud']; }],
  ['reread budget', docs => { docs.reread.warn_budget.future_policy = 0; }],
  ['failure markers', docs => { docs.reread.edit_failure_markers.future_policy = true; }],
]) {
  test(`H1 unknown ${name} keys refuse load instead of silently weakening policy`, t => {
    assert.throws(() => loadGuardRules(fixture(t, mutate)), /guard rule keys/);
  });
}

test('H1 schema drift blocks both native execution gates', async t => {
  const f = await deliveredFixture(t, undefined, runtime => {
    const path = resolve(runtime, 'core-rules/hooks/rules/destructive.json');
    const doc = JSON.parse(readFileSync(path, 'utf8'));
    doc.rules.at(-1).exempt.future_policy = true;
    writeFileSync(path, JSON.stringify(doc));
  });
  assert.equal((await f.fire('tool_call', f.call('bash', { command: 'printf harmless' }))).block, true);
  assert.equal((await f.fire('user_bash', { command: 'printf harmless', cwd: f.cwd })).result.exitCode, 1);
  assert.equal(f.calls.length, 0);
});

function dataPolicy(t, mutate = () => {}) {
  return loadGuardRules(fixture(t, docs => {
    const rule = {
      id: 'data-rule', effect: 'deny', reason: 'data denial', match: ['resource/|<exempt-identifier>'],
      exempt: {
        engines: ['codex'], allowed_commands: ['catalog inspect'], command_prefixes: ['asuser'],
        refuse_if_line_matches: ['BLOCK'], refuse_short_flags: ['-x'], boundaries: '%',
        identifier: 'resource/[A-Za-z0-9_-]+/', identifier_boundary: '[^A-Za-z0-9_./~-]', replacement: '<from-data>',
      },
    };
    mutate(rule);
    docs.destructive.rules = [rule];
  }));
}
const decision = (policy, command, engine = 'codex') => destructiveMatches(policy, command, engine).map(match => match.effect).join(',') || 'allow';

test('H1 exemption commands, prefixes, refusals, boundaries and replacement all come from data', t => {
  const policy = dataPolicy(t);
  for (const [command, expected] of [
    ['catalog inspect resource/id/', 'allow'],
    ['asuser catalog inspect resource/id/', 'allow'],
    ['sudo catalog inspect resource/id/', 'deny'],
    ['asuser asuser catalog inspect resource/id/', 'deny'],
    ['catalog list resource/id/', 'deny'],
    ['catalog inspect BLOCK resource/id/', 'deny'],
    ['catalog inspect -xfile resource/id/', 'deny'],
    ['catalog inspect -f resource/id/', 'allow'],
    ['catalog inspect -q=resource/id/', 'deny'],
    ['catalog inspect --arg resource/id/', 'deny'],
    ['catalog inspect --arg=plain resource/id/', 'allow'],
    ['catalog inspect --arg plain resource/id/', 'allow'],
    ['catalog inspect resource/id/%grep resource/id/', 'deny'],
    ['catalog inspect resource/id/\ngrep resource/id/', 'deny'],
    ['catalog inspect resource/id/%catalog inspect resource/two/', 'allow'],
    ['catalog inspect abcresource/id/', 'deny'],
    ['catalog inspect ~resource/id/', 'deny'],
  ]) assert.equal(decision(policy, command), expected, command);
  assert.equal(decision(policy, 'catalog inspect resource/id/', 'claude'), 'deny', 'engine selection is data too');
});

test('H1 exemption identifier and boundary changes are honored without TS changes', t => {
  const policy = dataPolicy(t, rule => {
    rule.match = ['archive/'];
    rule.exempt.identifier = 'archive/[A-Za-z0-9_-]+/';
    rule.exempt.identifier_boundary = '[ ]';
  });
  assert.equal(decision(policy, 'catalog inspect archive/id/'), 'allow');
  assert.equal(decision(policy, 'catalog inspect :archive/id/'), 'deny');
});

test('H1 identifier replacement uses POSIX leftmost-longest spans and preserves anchors', t => {
  for (const [identifier, command, span, expected] of [
    ['projects/p|projects/p/secrets/', 'gcloud secrets describe tail projects/p/secrets/s', ' projects/p/secrets/', 'allow'],
    ['projects/p|projects/p/secrets/', 'gcloud secrets describe tail projects/p/secrets/a projects/p/secrets/b', ' projects/p/secrets/', 'allow'],
    ['projects/p|projects/p/secrets/$', 'gcloud secrets describe tail projects/p/secrets/s', ' projects/p', 'deny'],
    ['projects/p|projects/p/secrets/$', 'gcloud secrets describe tail projects/p/secrets/', ' projects/p/secrets/', 'allow'],
  ]) {
    const directory = fixture(t, docs => { docs.destructive.rules.at(-1).exempt.identifier = identifier; });
    const boundary = destructive.rules.at(-1).exempt.identifier_boundary;
    const bash = spawnSync('bash', ['--noprofile', '--norc', '-c',
      '[[ "$1" =~ $2 ]] || exit 1; printf "%s" "${BASH_REMATCH[0]}"', 'posix-span', command, `(${boundary})(${identifier})`], {
      encoding: 'utf8', timeout: 10_000,
      env: { PATH: process.env.PATH, LC_ALL: 'C', HOME: directory, TRELLIS_HOME: resolve(directory, 'state'), TMPDIR: directory },
    });
    assert.equal(bash.error, undefined);
    assert.equal(bash.status, 0, bash.stderr);
    assert.equal(bash.stdout, span, 'actual bash POSIX match span');
    assert.equal(decision(loadGuardRules(directory), command, 'claude'), expected, `${identifier}: ${command}`);
  }
});

test('H1 data-driven exemption keeps ASCII-only ignore_case semantics', t => {
  const policy = dataPolicy(t, rule => {
    rule.ignore_case = true;
    rule.exempt.allowed_commands = ['Catalog Inspect'];
    rule.exempt.identifier = 'Resource/[A-Z]+/';
  });
  assert.equal(decision(policy, 'cAtAlOg iNsPeCt ReSoUrCe/ID/'), 'allow');
  assert.equal(decision(policy, 'catalog inspect resource/K/'), 'deny');
});
