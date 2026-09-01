#!/usr/bin/env node

import { readFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

function cannedAgentResult(opts = {}) {
  const label = String(opts.label ?? '')
  const required = opts.schema?.required ?? []

  if (required.includes('available')) {
    return { available: true, notes: 'wf-stub canned presence result' }
  }
  if (required.includes('complete')) {
    return {
      complete: true,
      refs: [{ project: 'repo', repo_path: '/tmp/repo', main_sha: '1111111111111111111111111111111111111111' }],
      notes: 'wf-stub canned immutable ref receipt',
    }
  }
  if (required.includes('real')) {
    return { real: true, confidence: 1, reason: 'wf-stub canned review result' }
  }
  if (required.includes('generated_for')) {
    return { generated_for: 'wf-stub', ranked: [] }
  }
  if (required.includes('target')) {
    return {
      target: label.replace(/^fanout:/, ''),
      branch: '',
      pushed: false,
      green: false,
      pr_url: '',
      worktree_path: '',
      notes: 'wf-stub canned held verdict',
    }
  }
  if (required.includes('project') && required.includes('synced')) {
    return {
      project: label.replace(/^drift:/, ''),
      branch: '',
      pr_url: '',
      synced: false,
      notes: 'wf-stub canned held drift verdict',
    }
  }
  if (required.includes('id') && required.includes('spec_path')) {
    return {
      id: label.replace(/^spec:/, ''),
      branch: '',
      spec_path: '',
      ready: false,
      notes: 'wf-stub canned spec verdict',
    }
  }
  if (required.includes('id') && required.includes('rationale')) {
    return {
      id: label.replace(/^triage:/, ''),
      title: 'wf-stub proposal',
      route: 'watch',
      rationale: 'wf-stub canned triage',
      skeptic_upheld: true,
    }
  }
  if (required.includes('id') && required.includes('gate_green')) {
    return {
      id: label.replace(/^build:/, ''),
      route: 'surgical',
      branch: '',
      pr_number: 0,
      pr_state: 'NONE',
      pr_url: '',
      gate_green: false,
      notes: 'wf-stub canned held build verdict',
    }
  }
  if (required.includes('unit')) {
    return {
      unit: label.replace(/^verify:/, ''),
      harness: 'stub',
      branch: 'stub-branch',
      green: true,
      reviewed: true,
      notes: 'wf-stub canned verdict',
    }
  }
  if (required.includes('repo')) {
    return {
      repo: label.replace(/^verify:/, ''),
      harness: 'stub',
      fixes: [],
      overallStatus: 'success',
    }
  }
  if (label.startsWith('claude-verify:')) {
    return { real: true, confidence: 1, reason: 'wf-stub canned Claude review' }
  }
  if (label.startsWith('codex-verify:')) {
    return 'real: true\nreason: wf-stub canned Codex review'
  }
  if (label === 'codex-presence') return 'yes'
  return 'wf-stub canned agent output'
}

function capturedError(error) {
  if (error == null) return null
  return {
    name: typeof error.name === 'string' ? error.name : 'Error',
    message: typeof error.message === 'string' ? error.message : String(error),
  }
}

function injectedLabel(control, label) {
  if (Array.isArray(control)) return control.includes(label) ? true : undefined
  if (control && Object.prototype.hasOwnProperty.call(control, label)) return control[label]
  return undefined
}

// Strip the whole `export const meta = {...}` declaration, mirroring the production
// Workflow engine.
//
// The engine extracts the exported metadata for phase/safety handling and then executes
// only the remainder of the recipe, WITHOUT injecting `meta` as a body-local binding. So
// any `meta.` dereference inside a recipe function throws `meta is not defined` at
// runtime. Proven on 2026-08-03: a real digest-adopt run crashed at currentCostLine(),
// and all three stack frames sat at a constant 69-line offset from source — exactly the
// span of the banner plus the `meta` declaration (source lines 1-69, body starts at 70).
//
// This stub previously removed only the `export ` keyword, leaving `const meta` bound in
// the executed scope. That made the entire recipe suite a false negative: digest-adopt.bats
// passed 7/7 while executing the exact statement that throws in production.
//
// Blank the declaration rather than deleting it so line numbers — and therefore stack
// traces and `//# sourceURL` mapping — stay aligned with the source file.
function stripMetaDeclaration(source) {
  const declaration = /(^|\n)[ \t]*(?:export[ \t]+)?const[ \t]+meta[ \t]*=[ \t]*\{/
  const match = declaration.exec(source)
  if (!match) return null

  // Walk from the opening brace to its match, skipping string and comment contexts so a
  // brace inside a description (meta blocks are pure literals, but they do carry prose)
  // cannot terminate the scan early.
  const open = match.index + match[0].length - 1
  let depth = 0
  let i = open
  let context = null // "'" | '"' | '`' | '//' | '/*'

  for (; i < source.length; i += 1) {
    const ch = source[i]
    const next = source[i + 1]

    if (context === '//') {
      if (ch === '\n') context = null
      continue
    }
    if (context === '/*') {
      if (ch === '*' && next === '/') { context = null; i += 1 }
      continue
    }
    if (context) {
      if (ch === '\\') { i += 1; continue }
      if (ch === context) context = null
      continue
    }

    if (ch === '/' && next === '/') { context = '//'; i += 1; continue }
    if (ch === '/' && next === '*') { context = '/*'; i += 1; continue }
    if (ch === "'" || ch === '"' || ch === '`') { context = ch; continue }

    if (ch === '{') depth += 1
    else if (ch === '}') {
      depth -= 1
      if (depth === 0) break
    }
  }

  if (depth !== 0) return null

  let end = i + 1
  if (source[end] === ';') end += 1

  const start = match.index + (match[1] ? match[1].length : 0)
  const removed = source.slice(start, end)
  const blanked = removed.replace(/[^\n]/g, '')
  return source.slice(0, start) + blanked + source.slice(end)
}

export async function runWorkflow(recipePath, recipeArgs = {}) {
  const prompts = []
  const logs = []
  let result = null
  let error = null

  try {
    const original = await readFile(recipePath, 'utf8')
    const source = stripMetaDeclaration(original)
    if (source === null) {
      throw new Error(`wf-stub: export const meta statement not found in ${recipePath}`)
    }

    const agent = async (prompt, opts = {}) => {
      prompts.push({ prompt: String(prompt), opts })
      const label = String(opts.label ?? '')
      const injectedThrow = injectedLabel(recipeArgs.__agentThrowByLabel, label)
      if (injectedThrow !== undefined) {
        throw new Error(typeof injectedThrow === 'string' ? injectedThrow : `wf-stub injected failure for ${label}`)
      }
      if (injectedLabel(recipeArgs.__agentNullByLabel, label) !== undefined) return null
      if (Object.prototype.hasOwnProperty.call(recipeArgs.__agentOutputByLabel ?? {}, label)) {
        return recipeArgs.__agentOutputByLabel[label]
      }
      return cannedAgentResult(opts)
    }
    const parallel = async (thunks) => Promise.all(thunks.map(async (thunk) => {
      try {
        return await thunk()
      } catch {
        return null
      }
    }))
    const pipeline = async (items, ...stages) => Promise.all(items.map(async (originalItem, index) => {
      let value = originalItem
      for (const stage of stages) {
        if (value == null) return null
        try {
          value = await stage(value, originalItem, index)
        } catch {
          return null
        }
      }
      return value == null ? null : value
    }))
    const phase = () => {}
    const log = (line) => { logs.push(String(line)) }
    const budget = () => {}
    if (Object.prototype.hasOwnProperty.call(recipeArgs, '__budgetSpentTokens')) {
      budget.spent = () => recipeArgs.__budgetSpentTokens
    }

    const execute = new AsyncFunction(
      'agent',
      'parallel',
      'pipeline',
      'phase',
      'log',
      'args',
      'budget',
      `${source}\n//# sourceURL=${pathToFileURL(recipePath).href}`,
    )
    result = await execute(agent, parallel, pipeline, phase, log, recipeArgs, budget)
  } catch (caught) {
    error = capturedError(caught)
  }

  return { result, prompts, logs, error }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const recipePath = process.argv[2]
  if (!recipePath) {
    process.stderr.write('usage: node wf-stub.mjs <recipe.wf.js> [args-json]\n')
    process.exitCode = 2
  } else {
    let recipeArgs = {}
    try {
      recipeArgs = JSON.parse(process.argv[3] ?? '{}')
    } catch (error) {
      process.stderr.write(`wf-stub: invalid args JSON: ${error.message}\n`)
      process.exitCode = 2
    }
    if (process.exitCode == null) {
      const captured = await runWorkflow(recipePath, recipeArgs)
      process.stdout.write(`${JSON.stringify(captured)}\n`)
    }
  }
}
