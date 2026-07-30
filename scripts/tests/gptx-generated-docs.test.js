#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const {
  modeRows,
  modelRows,
  generatedDocs,
} = require('../gptx/generate-session-policy-docs');

const root = path.resolve(__dirname, '../..');
const rows120 = modeRows();
const rows24 = modelRows();
assert.strictEqual(rows120.length, 120);
assert.strictEqual(rows24.length, 24);
assert.deepStrictEqual([
  rows120[0].resolved.effective.mode,
  rows120[0].advisor,
  rows120[0].delegates,
], ['gptx', null, null]);
assert.deepStrictEqual([
  rows120.at(-1).resolved.effective.mode,
  rows120.at(-1).advisor,
  rows120.at(-1).delegates,
], ['claude', 'none', 'none']);
assert.deepStrictEqual([
  rows24[0].mode,
  rows24[0].modelClass,
], ['gptx', 'omitted']);
assert.deepStrictEqual([
  rows24.at(-1).mode,
  rows24.at(-1).modelClass,
], ['claude', 'unrecognized-explicit']);

const base = process.env.TRELLIS_TEST_TMPDIR || os.tmpdir();
const temporary = fs.mkdtempSync(path.join(base, 'gptx-generated-docs-'));
try {
  const generator = path.join(root, 'scripts/gptx/generate-session-policy-docs.js');
  const result = spawnSync(process.execPath, [generator, '--output-dir', temporary], {
    encoding: 'utf8',
  });
  assert.strictEqual(result.status, 0, result.stderr);
  assert.match(result.stdout, /mode rows=120 model rows=24/);

  for (const [filename, expected] of Object.entries(generatedDocs())) {
    const generated = fs.readFileSync(path.join(temporary, filename), 'utf8');
    const committed = fs.readFileSync(path.join(root, 'docs', filename), 'utf8');
    assert.strictEqual(generated, expected, `${filename} render drift`);
    assert.strictEqual(generated, committed, `${filename} checked-in drift`);
  }
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}

console.log('gptx-generated-docs: ok');
