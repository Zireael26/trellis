// An attached project reaches the extension through a symlink chain:
// <worktree>/.pi/extensions/trellis.ts -> ../../.trellis/runtime/core-rules/pi/extensions/trellis.ts,
// with .trellis/runtime itself a link to the release payload. pi loads the
// extension by that symlink path, so the rules directory must come from the
// real file; resolved from the link it lands in <worktree>/hooks/rules, which
// does not exist, and every tool call is refused (1.4.0 regression).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { guardRulesDirectory, loadGuardRules } from '../extensions/trellis.ts';

const payload = resolve(fileURLToPath(new URL('../../..', import.meta.url)));
const realRules = realpathSync(resolve(payload, 'core-rules/hooks/rules'));

test('an extension loaded through the attached symlink chain finds the release rules', t => {
  const worktree = mkdtempSync(resolve(tmpdir(), 'trellis-pi-rules-'));
  t.after(() => rmSync(worktree, { recursive: true, force: true }));
  mkdirSync(resolve(worktree, '.trellis'));
  symlinkSync(payload, resolve(worktree, '.trellis/runtime'));
  mkdirSync(resolve(worktree, '.pi/extensions'), { recursive: true });
  const link = resolve(worktree, '.pi/extensions/trellis.ts');
  symlinkSync('../../.trellis/runtime/core-rules/pi/extensions/trellis.ts', link);

  const directory = guardRulesDirectory(pathToFileURL(link));
  assert.equal(directory, realRules);
  const rules = loadGuardRules(directory);
  assert.ok(rules, 'rules load from the resolved directory');
});

test('the default directory is the release rules directory', () => {
  assert.equal(guardRulesDirectory(), realRules);
  assert.ok(loadGuardRules());
});
