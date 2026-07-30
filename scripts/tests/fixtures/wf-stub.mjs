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

export async function runWorkflow(recipePath, recipeArgs = {}) {
  const prompts = []
  const logs = []
  let result = null
  let error = null

  try {
    const original = await readFile(recipePath, 'utf8')
    const source = original.replace(/\bexport\s+(?=const\s+meta\s*=)/, '')
    if (source === original) {
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
