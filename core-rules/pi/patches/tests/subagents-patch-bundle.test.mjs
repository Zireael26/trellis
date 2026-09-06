import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

// Only these files are copied; no command ever targets the installed package.
// Override with PI_SUBAGENTS_PACKAGE_ROOT for a disposable 0.19.0 package elsewhere.
const source = process.env.PI_SUBAGENTS_PACKAGE_ROOT ?? join(homedir(), '.pi/agent/npm/node_modules/@tintinweb/pi-subagents');
const patchesDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const installer = join(patchesDir, 'apply-pi-subagents-patches.sh');
const patches = ['preserve-cleanup-worktree', 'preserve-cleanup-dist', 'follow-symlinked-skill-leaves', 'worktree-create-timeout']
  .map(name => join(patchesDir, `pi-subagents-0.19.0-${name}.patch`));
const files = ['package.json', 'src/worktree.ts', 'dist/worktree.js', 'src/skill-loader.ts', 'dist/skill-loader.js'];
function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options });
  assert.ifError(result.error);
  return result;
}
function patch(root, file, args = []) {
  return run('patch', ['-d', root, '-p1', '-f', '-s', ...args, '-i', file]);
}
function hashes(root) {
  const result = {};
  function visit(dir, prefix = '') {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const name = prefix + entry.name;
      if (entry.isDirectory()) visit(join(dir, entry.name), `${name}/`);
      else result[name] = createHash('sha256').update(readFileSync(join(dir, entry.name))).digest('hex');
    }
  }
  visit(root);
  return result;
}
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'subagents-preflight-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const file of files) {
    mkdirSync(dirname(join(root, file)), { recursive: true });
    copyFileSync(join(source, file), join(root, file));
  }
  assert.equal(JSON.parse(readFileSync(join(root, 'package.json'))).version, '0.19.0');
  for (const file of patches) {
    if (patch(root, file, ['-R', '--dry-run']).status === 0) {
      assert.equal(patch(root, file, ['-R']).status, 0);
    }
    const check = patch(root, file, ['--dry-run']);
    assert.equal(check.status, 0, check.stdout + check.stderr);
  }
  return root;
}
function install(root, options) {
  return run('bash', [installer, root], options);
}
function fullyApplied(root) {
  for (const file of patches) assert.equal(patch(root, file, ['-R', '--dry-run']).status, 0);
}

test('source-patched/dist-unpatched partial bundle converges', t => {
  const root = fixture(t);
  assert.equal(patch(root, patches[0]).status, 0);
  const result = install(root);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  fullyApplied(root);
});

test('fully patched repeated invocation changes no package bytes', t => {
  const root = fixture(t);
  assert.equal(install(root).status, 0);
  const before = hashes(root);
  assert.equal(install(root).status, 0);
  assert.deepEqual(hashes(root), before);
  fullyApplied(root);
  t.diagnostic(JSON.stringify({ fullyPatched: before }));
});

test('late patch drift refuses before any earlier applicable file changes', t => {
  const root = fixture(t);
  writeFileSync(join(root, 'dist/skill-loader.js'), 'deliberate incompatible late patch target\n');
  const before = hashes(root);
  const result = install(root);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /drifted/);
  assert.deepEqual(hashes(root), before);
  t.diagnostic(JSON.stringify({ driftUnchanged: before }));
});

test('version mismatch refuses without changes', t => {
  const root = fixture(t);
  const path = join(root, 'package.json');
  const pkg = JSON.parse(readFileSync(path));
  pkg.version = '0.19.1';
  writeFileSync(path, JSON.stringify(pkg));
  const before = hashes(root);
  const result = install(root);
  assert.equal(result.status, 65);
  assert.deepEqual(hashes(root), before);
});

test('real apply failure after preflight is nonzero and explicitly not rolled back', t => {
  const root = fixture(t);
  const bin = mkdtempSync(join(tmpdir(), 'subagents-patch-shim-'));
  t.after(() => rmSync(bin, { recursive: true, force: true }));
  const realPatch = run('which', ['patch']).stdout.trim();
  // Simulate a concurrent deletion only at mutation time, then run the real patch.
  writeFileSync(join(bin, 'patch'), `#!/usr/bin/env bash\nfor arg in "$@"; do\n  if [[ "$arg" == --dry-run ]]; then exec "${realPatch}" "$@"; fi\ndone\nrm -- "$2/src/worktree.ts"\nexec "${realPatch}" "$@"\n`, { mode: 0o755 });
  const result = install(root, { env: { ...process.env, PATH: `${bin}:${process.env.PATH}` } });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /apply failed.*not rolled back/);
});
