// Legacy hook envelopes are not native Pi calls. Adapt only their transport,
// targets and persisted state; all policy decisions come from trellis.ts.
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';

const unsafe = /[\u0000-\u001f\u007f]/;
const alt = (...values) => values.find(value => value !== undefined && value !== null && value !== false);
// _TA_JQ's ta_r: jq -r / command substitution, including numeric session IDs.
const text = value => (typeof value === 'string' ? value : JSON.stringify(value, null, 2) ?? '')
  .replace(/\0/g, '').replace(/\n+$/, '');
const key = source => createHash('sha256').update(source).digest('hex').slice(0, 16);
const pathOf = input => {
  const path = alt(input.file_path, input.filePath, input.path, '');
  return typeof path === 'string' && !unsafe.test(path) ? text(path) : '';
};

// Port ta_patch's directive state machine, including partial declarations and
// consuming (not interpreting) a first directive preceding *** Begin Patch.
function patchTargets(command) {
  const targets = [];
  let begin = false, end = false, operation = '', path = '';
  const sanitized = (typeof command === 'string' ? command : '').split('\n').map(line => {
    const directive = line.match(/^\*\*\* (?:Add File|Delete File|Update File|Move to): /);
    return directive && unsafe.test(line.slice(directive[0].length)) ? '*** Invalid Path Directive' : line;
  }).join('\n');
  for (const line of text(sanitized).split('\n')) {
    if (!begin) {
      if (line !== '') begin = true;
      continue;
    }
    if (end) continue;
    if (line === '*** End Patch') { end = true; operation = ''; continue; }
    const mutation = line.match(/^\*\*\* (Add|Delete|Update) File: /);
    if (mutation) {
      operation = { Add: 'create', Delete: 'delete', Update: 'update' }[mutation[1]];
      path = line.slice(mutation[0].length);
      if (path !== '' && !/[\t\n\r]/.test(path)) targets.push({ operation, path });
    } else if (line.startsWith('*** Move to: ')) {
      const destination = line.slice('*** Move to: '.length);
      if (operation === 'update' && path !== '') {
        if (destination !== '' && !/[\t\n\r]/.test(destination)) {
          Object.assign(targets.at(-1), { operation: 'rename', destination });
        }
        operation = '';
      }
    } else if (line.startsWith('*** ')) operation = '';
  }
  return targets;
}

// Fields consumed by _ta_guard_fields, not a second policy implementation.
// Exactly one object is required: malformed and multi-document JSON normalize
// to no action even when their first document contains a usable target.
export function normalizeStep(step, project) {
  const raw = (Object.hasOwn(step, 'raw') ? step.raw : JSON.stringify(step.envelope))
    .replaceAll('{project}', project).replace(/\0/g, '').replace(/\n+$/, '');
  let input;
  try { input = JSON.parse(raw); } catch { return undefined; }
  if (!input || typeof input !== 'object' || Array.isArray(input)) return undefined;
  const toolName = text(alt(input.tool_name, input.toolName, ''));
  const toolInput = alt(input.tool_input, input.input, {});
  if (!toolInput || typeof toolInput !== 'object' || Array.isArray(toolInput)) return undefined;
  let targets = [];
  if (toolName === 'apply_patch') targets = patchTargets(alt(toolInput.command, ''));
  else if (toolName === 'MultiEdit') {
    const edits = alt(toolInput.edits, []);
    if (!Array.isArray(edits)) return undefined;
    const paths = [pathOf(toolInput), ...edits.map(edit => pathOf(edit ?? {}))];
    targets = [...new Set(paths.filter(Boolean))].sort().map(path => ({ operation: 'update', path }));
  } else if (['Read', 'Edit', 'Write', ''].includes(toolName)) {
    const path = pathOf(toolInput);
    if (path) targets = [{ operation: toolName === 'Read' ? 'read' : 'update', path }];
  }
  let cwd = text(alt(input.cwd, ''));
  try { if (!statSync(cwd).isDirectory()) cwd = project; } catch { cwd = project; }
  const source = text(alt(input.session_id, '')) || text(alt(input.transcript_path, '')) || 'default';
  return { toolName, targets, cwd, source, key: key(source), response: alt(input.tool_response, input.result, null) };
}

export function tableFixture(t, row) {
  const project = mkdtempSync(resolve(tmpdir(), 'trellis-rule-table-'));
  t.after(() => rmSync(project, { recursive: true, force: true }));
  mkdirSync(resolve(project, '.git'));
  for (const file of row.files ?? []) {
    const path = resolve(project, file);
    mkdirSync(resolve(path, '..'), { recursive: true });
    writeFileSync(path, 'x\n');
  }
  if (row.autonomy !== undefined) writeFileSync(resolve(project, '.trellis.json'), JSON.stringify({ autonomy: row.autonomy }));
  if (row.session_autonomy !== undefined) {
    mkdirSync(resolve(project, '.claude'));
    writeFileSync(resolve(project, '.claude/session-autonomy'), `${row.session_autonomy}\n`);
  }
  // The shell reads only the epoch's first line and removes POSIX whitespace;
  // absent/corrupt epochs become zero. Reads use >=, warns use this epoch only.
  const rawEpoch = row.epoch_raw ?? (row.turn_epoch === undefined ? '' : `${row.turn_epoch}\n`);
  const token = rawEpoch.split('\n')[0].replace(/[ \t\r\f\v]/g, '');
  const epoch = /^[0-9]+$/.test(token) ? Number(token) : 0;
  const expand = value => value.replaceAll('{project}', project);
  const states = new Map();
  const seeded = { known: new Set(), warns: new Map() };
  for (const [timestamp, path] of row.reads ?? []) if (Number(timestamp) >= epoch) seeded.known.add(expand(path));
  for (const [timestamp, path] of row.warns ?? []) if (Number(timestamp) === epoch) {
    const target = expand(path);
    seeded.warns.set(target, (seeded.warns.get(target) ?? 0) + 1);
  }
  states.set(key(row.key_source ?? 'parity-session'), seeded);
  const stateFor = action => {
    if (!states.has(action.key)) states.set(action.key, { known: new Set(), warns: new Map() });
    return states.get(action.key);
  };
  return { project, stateFor, relpath: path => path.startsWith(project) ? `{project}${path.slice(project.length)}` : path };
}
