import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { stripTypeScriptTypes } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';

// Only these files are copied; no command ever targets the installed package.
// Override with PI_SUBAGENTS_PACKAGE_ROOT for a disposable 0.19.0 package elsewhere.
const source = process.env.PI_SUBAGENTS_PACKAGE_ROOT ?? join(homedir(), '.pi/agent/npm/node_modules/@tintinweb/pi-subagents');
const patchFile = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'pi-subagents-0.19.0-worktree-create-timeout.patch');
const files = ['package.json', 'src/worktree.ts', 'dist/worktree.js'];
const HEAD_SHA = '0123456789abcdef0123456789abcdef01234567';
const AGENT_ID = 'timeout-probe';

function patch(root, args = []) {
  const result = spawnSync('patch', ['-d', root, '-p1', '-f', '-s', ...args, '-i', patchFile], { encoding: 'utf8' });
  assert.ifError(result.error);
  return result;
}

/** Disposable copy normalized to the unpatched 0.19.0 worktree deadline. */
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'subagents-worktree-timeout-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const file of files) {
    mkdirSync(dirname(join(root, file)), { recursive: true });
    copyFileSync(join(source, file), join(root, file));
  }
  assert.equal(JSON.parse(readFileSync(join(root, 'package.json'))).version, '0.19.0');
  if (patch(root, ['-R', '--dry-run']).status === 0) assert.equal(patch(root, ['-R']).status, 0);
  const check = patch(root, ['--dry-run']);
  assert.equal(check.status, 0, check.stdout + check.stderr);
  return root;
}

/** The patched artifacts are what runs, so both are exercised as modules. */
async function load(root, flavour) {
  if (flavour === 'dist') return import(pathToFileURL(join(root, 'dist/worktree.js')).href);
  const stripped = stripTypeScriptTypes(readFileSync(join(root, 'src/worktree.ts'), 'utf8'));
  return import(`data:text/javascript,${encodeURIComponent(stripped)}`);
}

function ok(stdout) {
  return { stdout, stderr: '', code: 0, killed: false };
}

/** `repoRoot/pkg/app` has to exist on disk: createWorktree realpaths both sides. */
function repo(t) {
  const repoRoot = mkdtempSync(join(tmpdir(), 'subagents-worktree-repo-'));
  t.after(() => rmSync(repoRoot, { recursive: true, force: true }));
  mkdirSync(join(repoRoot, 'pkg/app'), { recursive: true });
  return repoRoot;
}

function fakePi(repoRoot, worktreeAdd) {
  const calls = [];
  const exec = async (command, args, options) => {
    calls.push({ command, args, timeout: options.timeout, cwd: options.cwd });
    const key = args.join(' ');
    if (key === 'rev-parse --is-inside-work-tree') return ok('true');
    if (key === 'rev-parse HEAD') return ok(HEAD_SHA);
    if (key === 'rev-parse --show-toplevel') return ok(repoRoot);
    if (args[0] === 'worktree' && args[1] === 'add') return worktreeAdd;
    throw new Error(`unexpected git ${key}`);
  };
  return { pi: { exec }, calls };
}

function addCall(calls) {
  const call = calls.find(entry => entry.args[0] === 'worktree' && entry.args[1] === 'add');
  assert.ok(call, 'no worktree add was attempted');
  return call;
}

for (const flavour of ['src', 'dist']) {
  test(`${flavour}: unpatched worktree add still uses the deadline that timed out`, async t => {
    const root = fixture(t);
    const { createWorktree } = await load(root, flavour);
    const repoRoot = repo(t);
    const { pi, calls } = fakePi(repoRoot, ok(''));
    await createWorktree(pi, join(repoRoot, 'pkg/app'), AGENT_ID);
    assert.equal(addCall(calls).timeout, 30000);
  });

  test(`${flavour}: patched worktree add waits 180s while metadata queries keep 5s`, async t => {
    const root = fixture(t);
    assert.equal(patch(root).status, 0);
    const { createWorktree } = await load(root, flavour);
    const repoRoot = repo(t);
    const { pi, calls } = fakePi(repoRoot, ok(''));
    await createWorktree(pi, join(repoRoot, 'pkg/app'), AGENT_ID);
    assert.equal(addCall(calls).timeout, 180000);
    for (const call of calls.filter(entry => entry.args[0] === 'rev-parse')) assert.equal(call.timeout, 5000);
  });

  test(`${flavour}: patched success keeps repo and subdirectory identity`, async t => {
    const root = fixture(t);
    assert.equal(patch(root).status, 0);
    const { createWorktree } = await load(root, flavour);
    const repoRoot = repo(t);
    const cwd = join(repoRoot, 'pkg/app');
    const { pi, calls } = fakePi(repoRoot, ok(''));
    const info = await createWorktree(pi, cwd, AGENT_ID);
    const call = addCall(calls);
    assert.equal(call.cwd, cwd);
    assert.deepEqual(call.args, ['worktree', 'add', '--detach', info.path, 'HEAD']);
    assert.equal(info.branch, `pi-agent-${AGENT_ID}`);
    assert.equal(info.baseSha, HEAD_SHA);
    assert.equal(info.workPath, join(info.path, 'pkg/app'));
  });

  test(`${flavour}: patched killed add with exit code 0 stays a failure and runs nothing further`, async t => {
    const root = fixture(t);
    assert.equal(patch(root).status, 0);
    const { createWorktree } = await load(root, flavour);
    const repoRoot = repo(t);
    const { pi, calls } = fakePi(repoRoot, { stdout: '', stderr: '', code: 0, killed: true });
    const info = await createWorktree(pi, join(repoRoot, 'pkg/app'), AGENT_ID);
    assert.equal(info, undefined);
    assert.equal(addCall(calls).timeout, 180000);
    // No `worktree remove`, no cleanup, no fallback command after the kill.
    assert.equal(calls.length, 4);
  });
}

test('patch dry-run, apply, and repeat converge on the disposable copy', t => {
  const root = fixture(t);
  assert.equal(patch(root, ['--dry-run']).status, 0);
  assert.equal(patch(root).status, 0);
  const applied = files.map(file => readFileSync(join(root, file), 'utf8'));
  assert.equal(patch(root, ['-R', '--dry-run']).status, 0);
  assert.notEqual(patch(root, ['--dry-run']).status, 0);
  assert.deepEqual(files.map(file => readFileSync(join(root, file), 'utf8')), applied);
});
