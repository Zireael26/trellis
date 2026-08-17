#!/usr/bin/env node

import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const MAIN_REF = 'refs/heads/main'
// Queued remediation refs are supplied per run, not baked in. They are local
// fleet state — which projects have an in-flight branch this week — and this
// file publishes to the public mirror, so a hardcoded list both leaks project
// names and goes stale the moment a wave finishes.
const DEFAULT_QUEUED_REFS = []

function fail(message) {
  throw new Error(message)
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex')
}

function parseDate(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) fail('--date must be YYYY-MM-DD')
  const date = new Date(`${value}T00:00:00.000Z`)
  if (Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== value) fail(`--date is not a calendar date: ${value}`)
  return value
}

function parseArgs(argv) {
  const args = { root: ROOT, projectsRoot: null, date: null, pass: null, mainRefs: {}, queuedRefs: [...DEFAULT_QUEUED_REFS] }
  for (let index = 2; index < argv.length; index += 1) {
    const option = argv[index]
    if (option === '--help') return { help: true }
    if (!['--root', '--projects-root', '--date', '--pass', '--main-ref', '--queued'].includes(option)) fail(`unknown option: ${option}`)
    const value = argv[index + 1]
    if (!value || value.startsWith('--')) fail(`missing value for ${option}`)
    index += 1
    if (option === '--root') args.root = path.resolve(value)
    if (option === '--projects-root') args.projectsRoot = path.resolve(value)
    if (option === '--date') args.date = parseDate(value)
    if (option === '--pass') args.pass = value
    if (option === '--queued') {
      const match = value.match(/^([A-Za-z0-9._-]+)=(.+)$/)
      if (!match) fail('--queued must be PROJECT=REF')
      if (args.queuedRefs.some((q) => q.project === match[1])) fail(`duplicate --queued project: ${match[1]}`)
      args.queuedRefs.push({ project: match[1], branch: match[2] })
    }
    if (option === '--main-ref') {
      const match = value.match(/^([A-Za-z0-9._-]+)=(.+)$/)
      if (!match) fail('--main-ref must be PROJECT=REF')
      if (Object.hasOwn(args.mainRefs, match[1])) fail(`duplicate --main-ref project: ${match[1]}`)
      args.mainRefs[match[1]] = match[2]
    }
  }
  if (!args.projectsRoot) fail('--projects-root is required')
  if (!args.date) fail('--date is required')
  if (!args.pass || args.pass.trim() === '') fail('--pass is required')
  return args
}

function usage() {
  process.stdout.write(`Usage: node scripts/verify-conductor-spec-inventory.mjs --projects-root PATH --date YYYY-MM-DD --pass LABEL [--root PATH] [--main-ref PROJECT=REF] [--queued PROJECT=REF]\n\nRead-only conductor collision verifier. It inventories numeric specs/ IDs from every active registry main plus any queued remediation refs supplied with --queued PROJECT=REF (repeatable). --main-ref replaces one project's main ref for a committed repair-branch verification. It emits JSON and exits 1 when auto_spec_top_n is not exactly 0 or any duplicate/collision exists.\n`)
}

function cells(line) {
  return line.split('|').slice(1, -1).map((cell) => cell.trim())
}
function unquote(value) {
  return value.replaceAll('`', '').trim()
}

function resolveRegistryPath(value, projectsRoot) {
  const registryPath = unquote(value)
  if (registryPath.startsWith('/personal/')) return path.resolve(projectsRoot, registryPath.slice('/personal/'.length))
  if (path.isAbsolute(registryPath)) return registryPath
  fail(`unsupported registry project path: ${registryPath}`)
}

function readActiveProjects(root, projectsRoot) {
  const registryPath = path.join(root, 'registry.md')
  const lines = fs.readFileSync(registryPath, 'utf8').split(/\r?\n/)
  const projects = []
  let inActiveProjects = false

  for (const line of lines) {
    if (line === '## Active projects') {
      inActiveProjects = true
      continue
    }
    if (inActiveProjects && line === '---') break
    if (!inActiveProjects || !line.startsWith('|')) continue
    const [project, projectPath] = cells(line)
    if (!project || project === 'Project' || /^-+$/.test(project)) continue
    if (!projectPath) fail(`missing registry path for active project ${project}`)
    projects.push({
      project,
      registry_path: unquote(projectPath),
      repo: resolveRegistryPath(projectPath, projectsRoot),
    })
  }

  if (projects.length === 0) fail(`no active projects found in ${registryPath}`)
  projects.sort((left, right) => left.project.localeCompare(right.project))
  for (let index = 1; index < projects.length; index += 1) {
    if (projects[index - 1].project === projects[index].project) fail(`duplicate active registry project: ${projects[index].project}`)
  }
  return projects
}

function readBacklog(root, activeProjects) {
  const backlogPath = path.join(root, 'conductor', 'backlog.yml')
  const content = fs.readFileSync(backlogPath, 'utf8')
  const byProject = new Map()
  let inProjects = false
  let current = null

  for (const line of content.split(/\r?\n/)) {
    if (line === 'projects:') {
      inProjects = true
      continue
    }
    if (!inProjects) continue
    const projectMatch = line.match(/^  ([A-Za-z0-9._-]+):\s*$/)
    if (projectMatch) {
      current = { project: projectMatch[1], repo: undefined, task_ids: [] }
      byProject.set(current.project, current)
      continue
    }
    if (!current) continue
    const repoMatch = line.match(/^    repo:\s*([^#\s]+)(?:\s+#.*)?$/)
    if (repoMatch) {
      current.repo = repoMatch[1] === 'null' ? null : repoMatch[1]
      continue
    }
    const taskMatch = line.match(/^      - id:\s*([A-Za-z0-9._-]+)\s*$/)
    if (taskMatch) current.task_ids.push(taskMatch[1])
  }

  const activeByProject = new Map(activeProjects.map((project) => [project.project, project]))
  const projects = [...byProject.values()]
    .filter((project) => project.repo != null)
    .map((project) => {
      const active = activeByProject.get(project.project)
      if (!active) fail(`repo-backed backlog project is not active: ${project.project}`)
      const expectedRepo = active.registry_path.replace(/^\//, '')
      if (project.repo !== expectedRepo) fail(`backlog repo mismatch for ${project.project}: ${project.repo} != ${expectedRepo}`)
      return { project: project.project, repo: project.repo, task_ids: [...project.task_ids].sort() }
    })
    .sort((left, right) => left.project.localeCompare(right.project))

  return { sha256: sha256(content), projects }
}

function readAutoSpecTopN(root) {
  const targetsPath = path.join(root, 'scheduled-tasks', 'conductor', 'targets.md')
  const matches = [...fs.readFileSync(targetsPath, 'utf8').matchAll(/^\|\s*`auto_spec_top_n`\s*\|\s*\*\*(\d+)\*\*\s*\|/gm)]
  if (matches.length !== 1) fail(`expected one auto_spec_top_n row in ${targetsPath}, found ${matches.length}`)
  return Number(matches[0][1])
}

function git(repo, args) {
  try {
    return execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
  } catch (error) {
    const stderr = error.stderr?.toString().trim()
    fail(`git -C ${repo} ${args.join(' ')} failed${stderr ? `: ${stderr}` : ''}`)
  }
}

function isAncestor(repo, ancestor, descendant) {
  try {
    execFileSync('git', ['-C', repo, 'merge-base', '--is-ancestor', ancestor, descendant], { stdio: ['ignore', 'ignore', 'pipe'] })
    return true
  } catch (error) {
    if (error.status === 1) return false
    const stderr = error.stderr?.toString().trim()
    fail(`git -C ${repo} merge-base --is-ancestor ${ancestor} ${descendant} failed${stderr ? `: ${stderr}` : ''}`)
  }
}

function canonicalSpecId(raw) {
  const stripped = raw.replace(/^0+(?=\d)/, '')
  return stripped === '' ? '0' : stripped
}

function listSpecIds(repo, ref) {
  const entries = git(repo, ['ls-tree', '-d', '-z', '--name-only', ref, '--', 'specs/'])
    .split('\0')
    .filter(Boolean)
    .map((entry) => entry.replace(/^specs\//, ''))
    .map((directory) => {
      const match = directory.match(/^(\d+)(?:[-_]|$)/)
      return match ? { id: canonicalSpecId(match[1]), directory } : null
    })
    .filter(Boolean)
  return entries.sort((left, right) => left.directory.localeCompare(right.directory))
}

function duplicateIds(entries) {
  const byId = new Map()
  for (const entry of entries) {
    const directories = byId.get(entry.id) ?? []
    directories.push(entry.directory)
    byId.set(entry.id, directories)
  }
  return [...byId]
    .filter(([, directories]) => directories.length > 1)
    .map(([id, directories]) => ({ id, directories: [...directories].sort() }))
    .sort((left, right) => left.id.localeCompare(right.id, undefined, { numeric: true }))
}

function inventoryProject(project, queueRefs, mainRef) {
  if (!fs.statSync(project.repo).isDirectory()) fail(`active project directory does not exist: ${project.repo}`)
  const mainSha = git(project.repo, ['rev-parse', '--verify', `${mainRef}^{commit}`])
  const main = { ref: mainRef, sha: mainSha, spec_ids: listSpecIds(project.repo, mainRef) }
  const queued = queueRefs.map((queue) => {
    const ref = `refs/heads/${queue.branch}`
    const sha = git(project.repo, ['rev-parse', '--verify', `${ref}^{commit}`])
    const mergeBase = git(project.repo, ['merge-base', mainRef, ref])
    const baseDirectories = new Set(listSpecIds(project.repo, mergeBase).map((entry) => entry.directory))
    const specIds = listSpecIds(project.repo, ref)
    return {
      branch: queue.branch,
      ref,
      sha,
      merge_base: mergeBase,
      spec_ids: specIds,
      added_spec_ids: specIds.filter((entry) => !baseDirectories.has(entry.directory)),
    }
  })
  return { project: project.project, registry_path: project.registry_path, main, queued }
}

function detectConflicts(projects) {
  const duplicates = []
  const queuedVsMain = []

  for (const project of projects) {
    for (const duplicate of duplicateIds(project.main.spec_ids)) {
      duplicates.push({ project: project.project, source: 'main', ref: project.main.ref, ...duplicate })
    }
    for (const queue of project.queued) {
      for (const duplicate of duplicateIds(queue.spec_ids)) {
        duplicates.push({ project: project.project, source: 'queued-branch', branch: queue.branch, ...duplicate })
      }
    }

    const queuedById = new Map()
    for (const queue of project.queued) {
      for (const entry of queue.added_spec_ids) {
        const rows = queuedById.get(entry.id) ?? []
        rows.push({ branch: queue.branch, directory: entry.directory })
        queuedById.set(entry.id, rows)
      }
    }
    for (const [id, rows] of queuedById) {
      const branches = [...new Set(rows.map((row) => row.branch))].sort()
      if (branches.length > 1) {
        duplicates.push({
          project: project.project,
          source: 'queued-branches',
          id,
          branches,
          directories: rows.map((row) => `${row.branch}:${row.directory}`).sort(),
        })
      }
    }

    const mainById = new Map()
    for (const entry of project.main.spec_ids) {
      const directories = mainById.get(entry.id) ?? []
      directories.push(entry.directory)
      mainById.set(entry.id, directories)
    }
    for (const queue of project.queued) {
      for (const entry of queue.added_spec_ids) {
        const mainDirectories = mainById.get(entry.id)
        if (!mainDirectories) continue
        queuedVsMain.push({
          project: project.project,
          id: entry.id,
          branch: queue.branch,
          queued_directory: entry.directory,
          main_directories: [...mainDirectories].sort(),
        })
      }
    }
  }

  const byProjectAndId = (left, right) => left.project.localeCompare(right.project)
    || String(left.id ?? '').localeCompare(String(right.id ?? ''), undefined, { numeric: true })
    || String(left.branch ?? left.ref ?? '').localeCompare(String(right.branch ?? right.ref ?? ''))
  return { duplicates: duplicates.sort(byProjectAndId), queued_vs_main_collisions: queuedVsMain.sort(byProjectAndId) }
}

function run(args) {
  const activeProjects = readActiveProjects(args.root, args.projectsRoot)
  const activeByProject = new Map(activeProjects.map((project) => [project.project, project]))
  for (const project of Object.keys(args.mainRefs)) {
    if (!activeByProject.has(project)) fail(`main-ref override project is not active: ${project}`)
  }
  const mainRefOverrides = Object.fromEntries(Object.entries(args.mainRefs).sort(([left], [right]) => left.localeCompare(right)))
  for (const [project, ref] of Object.entries(mainRefOverrides)) {
    if (!isAncestor(activeByProject.get(project).repo, MAIN_REF, ref)) fail(`main-ref override must descend from ${MAIN_REF}: ${project}=${ref}`)
  }
  const queuesByProject = new Map()
  for (const queue of args.queuedRefs) {
    if (!activeByProject.has(queue.project)) fail(`required queued project is not active: ${queue.project}`)
    const rows = queuesByProject.get(queue.project) ?? []
    rows.push(queue)
    queuesByProject.set(queue.project, rows)
  }
  const backlog = readBacklog(args.root, activeProjects)
  const autoSpecTopN = readAutoSpecTopN(args.root)
  const projects = activeProjects.map((project) => inventoryProject(project, queuesByProject.get(project.project) ?? [], mainRefOverrides[project.project] ?? MAIN_REF))
  const queuedRefCount = projects.reduce((count, project) => count + project.queued.length, 0)
  if (queuedRefCount !== args.queuedRefs.length) fail(`required queued ref count mismatch: ${queuedRefCount} != ${args.queuedRefs.length}`)
  const inventory = {
    main_ref: MAIN_REF,
    main_ref_overrides: mainRefOverrides,
    auto_spec_top_n: autoSpecTopN,
    backlog,
    projects,
  }
  const conflicts = detectConflicts(inventory.projects)
  const summary = {
    active_projects: inventory.projects.length,
    backlog_repo_projects: backlog.projects.length,
    backlog_tasks: backlog.projects.reduce((count, project) => count + project.task_ids.length, 0),
    main_spec_ids: inventory.projects.reduce((count, project) => count + project.main.spec_ids.length, 0),
    queued_spec_ids: inventory.projects.reduce((count, project) => count + project.queued.reduce((total, queue) => total + queue.added_spec_ids.length, 0), 0),
    duplicate_spec_ids: conflicts.duplicates.length,
    queued_vs_main_collisions: conflicts.queued_vs_main_collisions.length,
  }
  const autoSpecDisabled = autoSpecTopN === 0
  return {
    schema_version: 1,
    date: args.date,
    pass: args.pass,
    auto_spec_top_n: autoSpecTopN,
    auto_spec_disabled: autoSpecDisabled,
    inventory_digest: sha256(JSON.stringify(inventory)),
    inventory,
    summary,
    duplicates: conflicts.duplicates,
    queued_vs_main_collisions: conflicts.queued_vs_main_collisions,
    ok: autoSpecDisabled && summary.duplicate_spec_ids === 0 && summary.queued_vs_main_collisions === 0,
  }
}

try {
  const args = parseArgs(process.argv)
  if (args.help) usage()
  else {
    const report = run(args)
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`)
    if (!report.ok) process.exitCode = 1
  }
} catch (error) {
  process.stdout.write(`${JSON.stringify({ schema_version: 1, ok: false, error: error.message }, null, 2)}\n`)
  process.exitCode = 2
}
