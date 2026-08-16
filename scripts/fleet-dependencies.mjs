#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..')
const SKIP_SEGMENTS = [
  'node_modules/', '.next/', '.nuxt/', '.turbo/', '.codex/', '.claude/worktrees/',
  '.git/', 'dist/', 'build/', 'out/', 'target/', 'Library/PackageCache/', '.venv/',
  'venv/', '.svelte-kit/', '.vercel/', '__pycache__/',
]
const TERMINAL_DISPOSITIONS = new Set([
  'fixed', 'false-positive', 'accepted-risk', 'compatibility-exception',
  'manual-gated', 'duplicate', 'superseded',
])

function fail(message, code = 2) {
  console.error(message)
  process.exit(code)
}

// A registry row that failed identity validation is reported by the listing as
// this availability. It outranks ordinary findings: 4 is the corrupt-state
// class, 1 is "this run found drift to fix". Highest class wins.
const REGISTRY_STATE_AVAILABILITY = 'identity_error'
const REGISTRY_STATE_EXIT = 4

const VALUE_OPTIONS = new Set([
  'baseline', 'ledger', 'ref', 'project', 'output', 'vulnerability-report',
  'today', 'home', 'fleet',
])
const RETIRED_OPTIONS = new Set(['registry', 'blacklist', 'projects-root'])

function parseArgs(argv) {
  const args = { command: argv[2] ?? 'check', json: false, ref: 'origin/main' }
  for (let i = 3; i < argv.length; i += 1) {
    const value = argv[i]
    if (value === '--json') args.json = true
    else if (value === '--fetch') args.fetch = true
    else if (value.startsWith('--')) {
      const option = value.slice(2)
      if (RETIRED_OPTIONS.has(option)) fail(`${value} is no longer supported; select local state with --home and --fleet`)
      if (!VALUE_OPTIONS.has(option)) fail(`unknown option: ${value}`)
      const next = argv[i + 1]
      if (!next || next.startsWith('--')) fail(`missing value for ${value}`)
      args[option.replaceAll('-', '_')] = next
      i += 1
    } else fail(`unexpected argument: ${value}`)
  }
  return args
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    fail(`cannot read JSON ${file}: ${error.message}`)
  }
}

function resolveRegistrySelection(args) {
  const resolver = [
    'set -eu',
    '. "$1"',
    'home="$(trellis_home_resolve "$2")"',
    'config="$(trellis_home_config_path "$home")"',
    'fleet="$(trellis_home_resolve_fleet "$3" "$config")"',
    "if [ -e \"$config\" ] || [ -L \"$config\" ]; then",
    "  jq -e --arg fleet \"$fleet\" '.fleets[$fleet] != null' \"$config\" >/dev/null || { printf 'trellis: selected fleet is not configured locally: %s\\n' \"$fleet\" >&2; exit \"$TRELLIS_EX_USAGE\"; }",
    'fi',
    'printf "%s\\t%s\\n" "$home" "$fleet"',
  ].join('\n')
  let output
  try {
    output = execFileSync('bash', [
      '-c', resolver, 'fleet-dependencies',
      path.join(ROOT, 'scripts/lib/trellis-home.sh'),
      args.home ?? '',
      args.fleet ?? '',
    ], { encoding: 'utf8' })
  } catch (error) {
    const detail = String(error.stderr ?? '').trim()
    fail(`cannot resolve local fleet selection: ${detail || error.message}`, error.status ?? 2)
  }
  const fields = output.endsWith('\n') ? output.slice(0, -1).split('\t') : output.split('\t')
  if (fields.length !== 2 || !fields[0] || !fields[1]) fail('cannot resolve local fleet selection')
  return { home: fields[0], fleet: fields[1] }
}

function listLocalRegistry(selection) {
  let output
  let acceptedPartial = false
  try {
    output = execFileSync('bash', [
      path.join(ROOT, 'scripts/registry.sh'),
      'list',
      '--home', selection.home,
      '--fleet', selection.fleet,
      '--json',
    ], { encoding: 'utf8' })
  } catch (error) {
    // registry.sh emits the complete listing before reporting registry state
    // errors with exit class 4; those rows must be evaluated, not abort the run.
    const partial = typeof error.stdout === 'string' ? error.stdout : ''
    if (error.status === REGISTRY_STATE_EXIT && partial.trim()) {
      output = partial
      acceptedPartial = true
    } else {
      const detail = String(error.stderr ?? '').trim()
      fail(`cannot list local registry for fleet ${selection.fleet}: ${detail || error.message}`, error.status ?? 1)
    }
  }
  let snapshot
  try {
    snapshot = JSON.parse(output)
  } catch (error) {
    fail(`local registry returned invalid JSON: ${error.message}`)
  }
  if (snapshot?.schema_version !== 1 || !Array.isArray(snapshot.entries)) {
    fail('local registry returned an unsupported snapshot')
  }
  // A class-4 exit is accepted as a PARTIAL listing only when the listing itself
  // names the rows that caused it. Exit 4 with no identity_error row is a state
  // class this process cannot attribute to anything it can report or skip, so
  // continuing would evaluate a registry whose failure is invisible in the data.
  // This mirrors the guard `run-evals.sh` applies to the same contract.
  if (acceptedPartial && !snapshot.entries.some((row) => row?.availability === REGISTRY_STATE_AVAILABILITY)) {
    fail(`local registry reported a state error with no identity-drift row for fleet ${selection.fleet}`, REGISTRY_STATE_EXIT)
  }
  return snapshot
}

function unavailableRegistryRow(row) {
  return {
    fleet: row.fleet ?? null,
    project: row.project_id ?? null,
    kind: row.kind ?? null,
    root: typeof row.root === 'string' ? row.root : null,
    status: row.status ?? null,
    availability: row.availability ?? null,
    excluded: Boolean(row.excluded),
  }
}

function isEligibleRegistryWorktree(row) {
  return row.kind === 'worktree'
    && row.availability === 'available'
    && row.status === 'active'
    && !row.excluded
    && typeof row.root === 'string'
}

function registryIneligibility(row) {
  const reasons = []
  if (row.kind !== 'worktree') reasons.push(`kind ${row.kind ?? 'unknown'}`)
  if (row.availability !== 'available') reasons.push(`availability ${row.availability ?? 'unknown'}`)
  if (row.status !== 'active') reasons.push(`status ${row.status ?? 'unknown'}`)
  if (row.excluded) reasons.push('excluded')
  if (typeof row.root !== 'string') reasons.push('no recorded worktree root')
  return reasons.length > 0 ? reasons.join(', ') : 'unknown local registry state'
}

function localRegistryProjects(snapshot, selection, requestedProject) {
  const fleetRows = snapshot.entries.filter((row) => row.fleet === selection.fleet)
  // A registry state error is a property of the REGISTRY, not of the selection.
  // Computing it from the filtered rows let a `--project P` run whose own row is
  // healthy exit 0 while the registry was corrupt, so it is computed here from
  // the full fleet listing and reported and aggregated regardless of P.
  const stateErrors = fleetRows
    .filter((row) => row.availability === REGISTRY_STATE_AVAILABILITY)
    .map(unavailableRegistryRow)
  let rows = fleetRows
  if (requestedProject) {
    rows = rows.filter((row) => row.project_id === requestedProject)
    if (rows.length === 0) {
      // A plain typo over a clean registry stays a usage error. When the
      // registry ALSO carries identity-validation failures, exiting 2 here would
      // discard every state error computed above — the corrupt registry would go
      // unreported because the caller mistyped a project name. Report the rows
      // and take the higher class.
      const message = `project is not registered in local fleet ${selection.fleet}: ${requestedProject}`
      if (stateErrors.length === 0) fail(message)
      reportUnavailable(stateErrors)
      fail(message, REGISTRY_STATE_EXIT)
    }
  }
  const unavailable = rows
    .filter((row) => row.kind !== 'worktree' || row.availability !== 'available')
    .map(unavailableRegistryRow)
  const projects = rows
    .filter(isEligibleRegistryWorktree)
    .map((row) => ({
      name: row.project_id,
      fleet: row.fleet,
      root: row.root,
      checkout_id: row.checkout_id ?? null,
      worktree_id: row.worktree_id ?? null,
    }))
  if (requestedProject && projects.length === 0) {
    const details = [...new Set(rows.map(registryIneligibility))].join('; ')
    // The selected project having no eligible row BECAUSE its own row failed
    // registry identity validation is a registry state error (class 4), not the
    // ordinary "nothing to evaluate here" finding class.
    const selectionStateError = rows.some((row) => row.availability === REGISTRY_STATE_AVAILABILITY)
    fail(
      `project is not eligible for dependency evaluation in local fleet ${selection.fleet}: ${requestedProject} (${details})`,
      selectionStateError ? REGISTRY_STATE_EXIT : 1,
    )
  }
  return { projects, unavailable, stateErrors }
}

function cleanVersion(value) {
  if (!value) return null
  let version = String(value).trim().replace(/^['"]|['"]$/g, '')
  if (version.startsWith('link:') || version.startsWith('workspace:') || version.startsWith('file:')) return null
  if (version.startsWith('npm:')) version = version.slice(version.lastIndexOf('@') + 1)
  version = version.split('(')[0]
  const match = version.match(/\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.-]+)?/)
  return match?.[0] ?? null
}

function semverParts(version) {
  const match = String(version ?? '').match(/^(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?$/)
  if (!match) return null
  return { major: Number(match[1]), minor: Number(match[2]), patch: Number(match[3] ?? 0), pre: match[4] ?? '' }
}

function compareVersions(a, b) {
  const av = semverParts(a)
  const bv = semverParts(b)
  if (!av || !bv) return String(a).localeCompare(String(b), undefined, { numeric: true })
  for (const key of ['major', 'minor', 'patch']) {
    if (av[key] !== bv[key]) return av[key] - bv[key]
  }
  if (!av.pre && bv.pre) return 1
  if (av.pre && !bv.pre) return -1
  return av.pre.localeCompare(bv.pre, undefined, { numeric: true })
}

function rangeAllows(range, version) {
  if (!range || range === '*' || range.startsWith('workspace:')) return true
  const alternatives = range.split(/\s*\|\|\s*/).filter(Boolean)
  if (alternatives.length > 1) {
    return alternatives.some((alternative) => rangeAllows(alternative, version))
  }
  const target = semverParts(version)
  if (!target) return true
  const first = cleanVersion(range)
  const current = semverParts(first)
  if (!current) return true
  if (range.trim().startsWith('^')) return target.major === current.major && compareVersions(version, first) >= 0
  if (range.trim().startsWith('~')) return target.major === current.major && target.minor === current.minor && compareVersions(version, first) >= 0
  if (range.includes('>=')) return compareVersions(version, first) >= 0
  if (/^\d+\.\d+\.\d+/.test(range.trim())) return compareVersions(version, first) === 0
  return target.major === current.major
}

class ProjectSource {
  constructor(root, ref) {
    this.root = root
    this.ref = ref
    this.files = null
  }

  listFiles() {
    if (this.files) return this.files
    if (this.ref === 'worktree') {
      const out = []
      const walk = (dir) => {
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
          if (entry.name === '.git' || entry.name === 'node_modules') continue
          const absolute = path.join(dir, entry.name)
          const relative = path.relative(this.root, absolute).replaceAll(path.sep, '/')
          if (SKIP_SEGMENTS.some((segment) => `${relative}/`.includes(segment))) continue
          if (entry.isDirectory()) walk(absolute)
          else out.push(relative)
        }
      }
      walk(this.root)
      this.files = out
    } else {
      const output = execFileSync('git', ['-C', this.root, 'ls-tree', '-r', '--name-only', this.ref], { encoding: 'utf8' })
      this.files = output.split(/\r?\n/).filter(Boolean).filter((file) => !SKIP_SEGMENTS.some((segment) => `${file}/`.includes(segment)))
    }
    return this.files
  }

  has(file) {
    return this.listFiles().includes(file)
  }

  read(file) {
    if (!this.has(file)) return null
    if (this.ref === 'worktree') return fs.readFileSync(path.join(this.root, file), 'utf8')
    return execFileSync('git', ['-C', this.root, 'show', `${this.ref}:${file}`], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
  }
}

function unquoteYamlKey(value) {
  return value.trim().replace(/:$/, '').replace(/^['"]|['"]$/g, '')
}

function parsePnpmImporters(text) {
  const resolved = new Map()
  let inImporters = false
  let importer = null
  let bucket = null
  let dependency = null
  for (const line of text.split(/\r?\n/)) {
    if (line === 'importers:') {
      inImporters = true
      continue
    }
    if (inImporters && /^\S/.test(line) && line !== 'importers:') break
    if (!inImporters) continue
    let match = line.match(/^  ([^ ].*):\s*$/)
    if (match) {
      importer = unquoteYamlKey(match[1])
      bucket = null
      dependency = null
      continue
    }
    match = line.match(/^    ([^ ].*):\s*$/)
    if (match && ['dependencies', 'devDependencies', 'optionalDependencies'].includes(match[1])) {
      bucket = match[1]
      dependency = null
      continue
    }
    match = line.match(/^      ([^ ].*):\s*$/)
    if (match && bucket) {
      dependency = unquoteYamlKey(match[1])
      continue
    }
    match = line.match(/^        version:\s*(.+?)\s*$/)
    if (match && importer && dependency) {
      const version = cleanVersion(match[1])
      if (version) resolved.set(`${importer}\0${dependency}`, version)
    }
  }
  return resolved
}

function parsePnpmGraph(text) {
  const resolved = new Map()
  let inPackages = false
  for (const line of text.split(/\r?\n/)) {
    if (line === 'packages:' || line === 'snapshots:') {
      inPackages = true
      continue
    }
    if (inPackages && /^\S/.test(line)) inPackages = false
    if (!inPackages) continue
    const match = line.match(/^  ['"]?(.+)@(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:\([^:]+\))?['"]?:\s*$/)
    if (!match) continue
    const name = match[1]
    if (!resolved.has(name)) resolved.set(name, new Set())
    resolved.get(name).add(match[2])
  }
  return resolved
}

function parseNpmLock(text) {
  const lock = JSON.parse(text)
  const resolved = new Map()
  for (const [key, value] of Object.entries(lock.packages ?? {})) {
    if (!value?.version || !key.includes('node_modules/')) continue
    const name = key.slice(key.lastIndexOf('node_modules/') + 'node_modules/'.length)
    const existing = resolved.get(name)
    if (!existing || compareVersions(value.version, existing) > 0) resolved.set(name, value.version)
  }
  return resolved
}

function npmGraph(text) {
  const lock = JSON.parse(text)
  const resolved = new Map()
  for (const [key, value] of Object.entries(lock.packages ?? {})) {
    if (!value?.version || !key.includes('node_modules/')) continue
    const name = key.slice(key.lastIndexOf('node_modules/') + 'node_modules/'.length)
    if (!resolved.has(name)) resolved.set(name, new Set())
    resolved.get(name).add(value.version)
  }
  return resolved
}

function mergeGraph(target, ecosystem, source) {
  for (const [name, versions] of source) {
    const key = `${ecosystem}\0${name}`
    if (!target.has(key)) target.set(key, new Set())
    for (const version of versions instanceof Set ? versions : [versions]) target.get(key).add(version)
  }
}

function parsePythonLock(text) {
  const resolved = new Map()
  const blocks = text.split(/^\[\[package\]\]\s*$/m).slice(1)
  for (const block of blocks) {
    const name = block.match(/^name\s*=\s*['"]([^'"]+)['"]/m)?.[1]
    const version = block.match(/^version\s*=\s*['"]([^'"]+)['"]/m)?.[1]
    if (name && version) resolved.set(name.toLowerCase().replaceAll('_', '-'), version)
  }
  return resolved
}

function parsePepRequirement(value) {
  const match = value.trim().replace(/^['"]|['"],?$/g, '').match(/^([A-Za-z0-9_.-]+)(?:\[[^\]]+\])?\s*(.*)$/)
  if (!match) return null
  return { name: match[1].toLowerCase().replaceAll('_', '-'), range: match[2].trim() || '*' }
}

function parsePyproject(text) {
  const dependencies = []
  let section = ''
  let arrayBucket = null
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/\s+#.*$/, '').trim()
    const sectionMatch = line.match(/^\[([^\]]+)\]$/)
    if (sectionMatch) {
      section = sectionMatch[1]
      arrayBucket = null
      continue
    }
    if (section === 'project' && /^dependencies\s*=\s*\[/.test(line)) {
      arrayBucket = 'dependencies'
      const rest = line.slice(line.indexOf('[') + 1)
      for (const part of rest.split(',')) {
        const parsed = parsePepRequirement(part.replace(/\]$/, ''))
        if (parsed) dependencies.push({ ...parsed, bucket: 'dependencies' })
      }
      if (line.includes(']')) arrayBucket = null
      continue
    }
    if (arrayBucket) {
      for (const part of line.split(',')) {
        const parsed = parsePepRequirement(part.replace(/\]$/, ''))
        if (parsed) dependencies.push({ ...parsed, bucket: arrayBucket })
      }
      if (line.includes(']')) arrayBucket = null
      continue
    }
    if (/^tool\.poetry(?:\.group\.[^.]+)?\.dependencies$/.test(section)) {
      const match = line.match(/^([A-Za-z0-9_.-]+)\s*=\s*(.+)$/)
      if (match && match[1].toLowerCase() !== 'python') {
        dependencies.push({ name: match[1].toLowerCase().replaceAll('_', '-'), range: match[2].replace(/^['"]|['"]$/g, ''), bucket: section.includes('.group.') ? 'devDependencies' : 'dependencies' })
      }
    }
  }
  return dependencies
}

function collectProject(project, ref) {
  const source = new ProjectSource(project.root, ref)
  const files = source.listFiles()
  const records = []
  const warnings = []
  const pnpmText = source.read('pnpm-lock.yaml')
  const pnpmResolved = pnpmText ? parsePnpmImporters(pnpmText) : new Map()
  const rootNpmLock = source.read('package-lock.json')
  const npmResolved = rootNpmLock ? parseNpmLock(rootNpmLock) : new Map()
  const resolvedGraph = new Map()
  if (pnpmText) mergeGraph(resolvedGraph, 'npm', parsePnpmGraph(pnpmText))
  if (rootNpmLock) mergeGraph(resolvedGraph, 'npm', npmGraph(rootNpmLock))

  for (const manifestPath of files.filter((file) => file.endsWith('package.json'))) {
    let manifest
    try {
      manifest = JSON.parse(source.read(manifestPath))
    } catch (error) {
      warnings.push(`${manifestPath}: invalid package.json (${error.message})`)
      continue
    }
    const workspace = path.posix.dirname(manifestPath) === '.' ? '.' : path.posix.dirname(manifestPath)
    for (const bucket of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies']) {
      for (const [name, range] of Object.entries(manifest[bucket] ?? {})) {
        if (String(range).startsWith('workspace:')) continue
        const peer = bucket === 'peerDependencies'
        const resolved = peer
          ? null
          : pnpmResolved.get(`${workspace}\0${name}`) ?? npmResolved.get(name) ?? cleanVersion(range)
        records.push({ project: project.name, workspace, ecosystem: 'npm', name, range: String(range), bucket, peer, resolved })
      }
    }
  }

  const pythonLocks = files.filter((file) => /(^|\/)(poetry|uv)\.lock$/.test(file))
  const pythonResolvedByDir = new Map()
  for (const lockPath of pythonLocks) {
    const parsed = parsePythonLock(source.read(lockPath))
    pythonResolvedByDir.set(path.posix.dirname(lockPath), parsed)
    mergeGraph(resolvedGraph, 'pypi', parsed)
  }
  for (const manifestPath of files.filter((file) => file.endsWith('pyproject.toml'))) {
    const workspace = path.posix.dirname(manifestPath) === '.' ? '.' : path.posix.dirname(manifestPath)
    const resolvedMap = pythonResolvedByDir.get(workspace) ?? pythonResolvedByDir.get('.') ?? new Map()
    for (const dependency of parsePyproject(source.read(manifestPath))) {
      records.push({ project: project.name, workspace, ecosystem: 'pypi', peer: false, resolved: resolvedMap.get(dependency.name) ?? cleanVersion(dependency.range), ...dependency })
    }
  }

  const rootManifest = files.includes('package.json') ? JSON.parse(source.read('package.json')) : {}
  const toolchains = {
    node: source.read('.nvmrc')?.trim() ?? cleanVersion(rootManifest.engines?.node),
    pnpm: String(rootManifest.packageManager ?? '').startsWith('pnpm@') ? String(rootManifest.packageManager).slice(5) : null,
    npm: String(rootManifest.packageManager ?? '').startsWith('npm@') ? String(rootManifest.packageManager).slice(4) : null,
  }
  return { ...project, records, resolvedGraph, toolchains, warnings }
}

function validateBaselineShape(baseline) {
  const errors = []
  if (baseline.schema_version !== 1) errors.push('baseline schema_version must be 1')
  if (!Array.isArray(baseline.packages)) errors.push('baseline packages must be an array')
  if (!Array.isArray(baseline.toolchains)) errors.push('baseline toolchains must be an array')
  if (!Array.isArray(baseline.security_floors)) errors.push('baseline security_floors must be an array')
  if (!Array.isArray(baseline.exceptions)) errors.push('baseline exceptions must be an array')
  const ids = new Set()
  for (const exception of baseline.exceptions ?? []) {
    for (const field of ['id', 'project', 'workspace', 'reason', 'owner', 'replacement_condition', 'expires_on']) {
      if (!exception[field]) errors.push(`exception ${exception.id ?? '(unknown)'} missing ${field}`)
    }
    if (ids.has(exception.id)) errors.push(`duplicate exception id ${exception.id}`)
    ids.add(exception.id)
    if (!/^\d{4}-\d{2}-\d{2}$/.test(exception.expires_on ?? '')) errors.push(`exception ${exception.id} has invalid expires_on`)
  }
  return errors
}

function exceptionFor(baseline, record, today) {
  return (baseline.exceptions ?? []).find((exception) => {
    if (exception.project !== record.project) return false
    if (exception.workspace !== '*' && exception.workspace !== record.workspace) return false
    if (exception.ecosystem && exception.ecosystem !== record.ecosystem) return false
    if (exception.package && exception.package !== record.name) return false
    return exception.expires_on >= today
  })
}

function laneFor(entry, project, workspace) {
  const matching = entry.lanes.filter((lane) => {
    const projects = lane.projects ?? ['*']
    const workspaces = lane.workspaces ?? ['*']
    return (projects.includes('*') || projects.includes(project)) && (workspaces.includes('*') || workspaces.includes(workspace))
  })
  return matching.sort((a, b) => {
    const specificity = (lane) => (lane.projects?.includes(project) ? 2 : 0) + (lane.workspaces?.includes(workspace) ? 1 : 0)
    return specificity(b) - specificity(a)
  })[0]
}

function checkBaseline(baseline, projects, today) {
  const errors = validateBaselineShape(baseline)
  const findings = []
  const allRecords = projects.flatMap((project) => project.records)
  const shared = new Map()
  for (const record of allRecords) {
    const key = `${record.ecosystem}\0${record.name}`
    if (!shared.has(key)) shared.set(key, new Set())
    shared.get(key).add(record.project)
  }
  const baselineKeys = new Set((baseline.packages ?? []).map((entry) => `${entry.ecosystem}\0${entry.name}`))
  for (const [key, projectNames] of shared) {
    if (projectNames.size >= baseline.policy.shared_project_minimum && !baselineKeys.has(key)) {
      const [ecosystem, name] = key.split('\0')
      findings.push({ severity: 'error', type: 'unbaselined-shared-dependency', ecosystem, package: name, projects: [...projectNames].sort() })
    }
  }
  for (const exception of baseline.exceptions ?? []) {
    if (exception.expires_on < today) findings.push({ severity: 'error', type: 'expired-exception', exception: exception.id, expired_on: exception.expires_on })
  }
  for (const floor of baseline.security_floors ?? []) {
    for (const project of projects) {
      if (floor.projects && !floor.projects.includes('*') && !floor.projects.includes(project.name)) continue
      const versions = project.resolvedGraph.get(`${floor.ecosystem}\0${floor.name}`) ?? new Set()
      if (floor.forbidden && versions.size > 0) {
        findings.push({ severity: 'error', type: 'forbidden-package', project: project.name, ecosystem: floor.ecosystem, package: floor.name, versions: [...versions].sort(compareVersions) })
        continue
      }
      for (const version of versions) {
        const current = semverParts(version)
        if (!current) continue
        const branch = floor.branches?.length === 1
          ? floor.branches[0]
          : floor.branches?.find((candidate) => candidate.major === current.major)
        if (branch && compareVersions(version, branch.minimum) < 0) {
          findings.push({ severity: 'error', type: 'security-floor', project: project.name, ecosystem: floor.ecosystem, package: floor.name, resolved: version, minimum: branch.minimum })
        }
      }
    }
  }
  for (const entry of baseline.packages ?? []) {
    for (const record of allRecords.filter((candidate) => candidate.ecosystem === entry.ecosystem && candidate.name === entry.name)) {
      const lane = laneFor(entry, record.project, record.workspace)
      if (!lane) continue
      if (exceptionFor(baseline, record, today)) continue
      if (record.peer) {
        if (!rangeAllows(record.range, lane.version)) findings.push({ severity: 'error', type: 'peer-range-incompatible', project: record.project, workspace: record.workspace, ecosystem: record.ecosystem, package: record.name, declared: record.range, expected: lane.version, lane: lane.id })
      } else if (!record.resolved) {
        findings.push({ severity: 'error', type: 'unresolved-direct-dependency', project: record.project, workspace: record.workspace, ecosystem: record.ecosystem, package: record.name, declared: record.range, expected: lane.version, lane: lane.id })
      } else if (record.resolved !== lane.version) {
        findings.push({ severity: 'error', type: 'version-drift', project: record.project, workspace: record.workspace, ecosystem: record.ecosystem, package: record.name, resolved: record.resolved, expected: lane.version, lane: lane.id })
      }
    }
    for (const lane of entry.lanes.filter((candidate) => candidate.required)) {
      for (const projectName of lane.projects.filter((name) => name !== '*')) {
        const present = allRecords.some((record) => record.project === projectName && record.ecosystem === entry.ecosystem && record.name === entry.name && !record.peer)
        if (!present) findings.push({ severity: 'error', type: 'missing-required-dependency', project: projectName, ecosystem: entry.ecosystem, package: entry.name, expected: lane.version, lane: lane.id })
      }
    }
  }
  for (const entry of baseline.toolchains ?? []) {
    for (const project of projects) {
      const lane = laneFor(entry, project.name, '.')
      if (!lane) continue
      const current = project.toolchains[entry.name]
      const excepted = exceptionFor(baseline, { project: project.name, workspace: '.', ecosystem: 'toolchain', name: entry.name }, today)
      if (excepted) continue
      if (!current) findings.push({ severity: 'error', type: 'missing-toolchain-pin', project: project.name, toolchain: entry.name, expected: lane.version, lane: lane.id })
      else if ((lane.match === 'major' ? current.split('.')[0] : current) !== (lane.match === 'major' ? lane.version.split('.')[0] : lane.version)) {
        findings.push({ severity: 'error', type: 'toolchain-drift', project: project.name, toolchain: entry.name, current, expected: lane.version, lane: lane.id })
      }
    }
  }
  return { errors, findings }
}

function snapshotBaseline(seed, projects) {
  const groups = new Map()
  for (const record of projects.flatMap((project) => project.records).filter((record) => !record.peer)) {
    const key = `${record.ecosystem}\0${record.name}`
    if (!groups.has(key)) groups.set(key, [])
    groups.get(key).push(record)
  }
  const seeded = new Map((seed.packages ?? []).map((entry) => [`${entry.ecosystem}\0${entry.name}`, entry]))
  const packages = []
  for (const [key, records] of groups) {
    const projectNames = [...new Set(records.map((record) => record.project))].sort()
    if (projectNames.length < seed.policy.shared_project_minimum && !seeded.has(key)) continue
    const [ecosystem, name] = key.split('\0')
    const existing = seeded.get(key)
    const highest = records.map((record) => record.resolved).filter(Boolean).sort(compareVersions).at(-1)
    if (!highest && !existing) continue
    packages.push(existing ?? { ecosystem, name, lanes: [{ id: 'default', version: highest, projects: projectNames }] })
  }
  for (const [key, entry] of seeded) {
    if (!groups.has(key)) packages.push(entry)
  }
  packages.sort((a, b) => `${a.ecosystem}:${a.name}`.localeCompare(`${b.ecosystem}:${b.name}`))
  return { ...seed, generated_at: new Date().toISOString(), source_ref: seed.source_ref ?? 'origin/main', packages }
}

function validateLedger(ledger, today) {
  const errors = []
  if (ledger.schema_version !== 1) errors.push('ledger schema_version must be 1')
  if (!Array.isArray(ledger.findings)) errors.push('ledger findings must be an array')
  const ids = new Set()
  for (const finding of ledger.findings ?? []) {
    if (!finding.id) errors.push('finding missing id')
    if (ids.has(finding.id)) errors.push(`duplicate finding id ${finding.id}`)
    ids.add(finding.id)
    if (!['open', ...TERMINAL_DISPOSITIONS].includes(finding.disposition)) errors.push(`${finding.id}: invalid disposition ${finding.disposition}`)
    if (finding.disposition !== 'open' && !(finding.evidence?.length > 0)) errors.push(`${finding.id}: terminal disposition requires evidence`)
    if (['accepted-risk', 'compatibility-exception', 'manual-gated'].includes(finding.disposition)) {
      for (const field of ['owner', 'expires_on', 'replacement_condition']) if (!finding[field]) errors.push(`${finding.id}: ${finding.disposition} requires ${field}`)
      if (finding.expires_on && finding.expires_on < today) errors.push(`${finding.id}: disposition expired on ${finding.expires_on}`)
    }
  }
  return errors
}

function reportUnavailable(unavailable) {
  for (const row of unavailable) {
    const root = row.root ?? '(no recorded worktree root)'
    // An identity_error row is a registry state error, not a merely absent root.
    const label = row.availability === REGISTRY_STATE_AVAILABILITY ? 'STATE-ERROR' : 'UNAVAILABLE'
    console.error(`${label} ${row.fleet}/${row.project}: ${root} (${row.kind ?? 'unknown'})`)
  }
}

// MACHINE-OUTPUT PARITY. A JSON run suppresses the stderr row reports, so a
// `--project P --json` run over a healthy P whose sibling row is drifted used to
// exit 4 while emitting a payload that named nothing wrong — the exit class said
// "corrupt registry" and the only machine-readable artifact said "clean". The
// `state_errors` field carries exactly the rows that raised the class, whether
// or not the selector included them, so a consumer reading the JSON alone can
// attribute the exit. `unavailable` keeps its meaning: rows inside the selection
// that were not eligible.
function renderFindings(result, projects, unavailable, stateErrors, json) {
  const payload = {
    projects: projects.map((project) => ({
      name: project.name,
      fleet: project.fleet,
      root: project.root,
      checkout_id: project.checkout_id,
      worktree_id: project.worktree_id,
      warnings: project.warnings,
    })),
    unavailable,
    state_errors: stateErrors,
    ...result,
  }
  if (json) console.log(JSON.stringify(payload, null, 2))
  else {
    for (const error of result.errors) console.error(`ERROR schema: ${error}`)
    for (const finding of result.findings) console.error(`ERROR ${finding.type}: ${JSON.stringify(finding)}`)
    console.log(`fleet dependency check: ${result.findings.length} finding(s), ${result.errors.length} schema error(s), ${projects.length} available worktree(s)`)
  }
}

function usage() {
  console.log(`Usage: fleet-dependencies.mjs <check|snapshot|apply|ledger-check|ledger-sync> [options]

  check        Validate fetched project refs against dependency-baseline.json
  snapshot     Merge shared dependencies discovered from refs into a seed baseline
  apply        Print exact manifest changes required for one project (no writes)
  ledger-check Validate terminal evidence and expiry in the remediation ledger
  ledger-sync  Add current baseline drift and audit appendix rows to the ledger

Public clones ship empty, schema-valid baseline and ledger shells. Register local
worktrees, then use snapshot --ref worktree --output <path> to seed your own
shared-package baseline. Tracked registry and blacklist Markdown are not inputs.

Options: --baseline PATH --ledger PATH --home PATH --fleet NAME
         --ref REF|worktree --project ID --output PATH --json --fetch
         --vulnerability-report PATH`)
}

function slug(value) {
  return String(value).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 96)
}

function ledgerFindingFromBaseline(finding) {
  const identity = [finding.type, finding.project ?? 'fleet', finding.workspace ?? '.', finding.ecosystem ?? 'toolchain', finding.package ?? finding.toolchain ?? finding.exception ?? 'policy', finding.resolved ?? finding.current ?? finding.expected ?? finding.expired_on ?? 'missing']
  return {
    id: `baseline-${slug(identity.join('-'))}`,
    source: 'dependency-baseline.json',
    project: finding.project ?? 'trellis-instance',
    workspace: finding.workspace ?? '.',
    category: finding.type,
    summary: JSON.stringify(finding),
    severity: finding.type === 'security-floor' || finding.type === 'forbidden-package' ? 'high' : 'warning',
    disposition: 'open',
    evidence: [],
  }
}

function vulnerabilityRows(reportPath) {
  if (!reportPath) return []
  const text = fs.readFileSync(reportPath, 'utf8')
  const rows = []
  for (const line of text.split(/\r?\n/)) {
    if (!line.startsWith('|')) continue
    const cells = line.split('|').slice(1, -1).map((cell) => cell.trim())
    if (cells.length < 8 || cells[0] === 'Project' || cells.every((cell) => /^-+$/.test(cell))) continue
    const [project, workspace, advisory, packageName, installed, fixed, severity, direct] = cells
    const normalizedSeverity = severity.toLowerCase()
    if (!['critical', 'high', 'moderate', 'low'].includes(normalizedSeverity)) continue
    rows.push({
      id: `vuln-${slug([project, workspace, advisory, packageName, installed].join('-'))}`,
      source: path.basename(reportPath),
      project,
      workspace,
      category: 'dependency-vulnerability',
      summary: `${advisory}: ${packageName} ${installed}; fixed ${fixed}; ${direct}`,
      severity: normalizedSeverity,
      disposition: 'open',
      evidence: [],
    })
  }
  return rows
}

function syncLedger(ledger, baselineResult, reportPath) {
  const byId = new Map((ledger.findings ?? []).map((finding) => [finding.id, finding]))
  const additions = [
    ...baselineResult.findings.map(ledgerFindingFromBaseline),
    ...vulnerabilityRows(reportPath),
  ]
  for (const finding of additions) if (!byId.has(finding.id)) byId.set(finding.id, finding)
  return { ...ledger, findings: [...byId.values()].sort((a, b) => a.id.localeCompare(b.id)) }
}

const args = parseArgs(process.argv)
if (args.command === 'help') {
  usage()
  process.exit(0)
}
const baselinePath = path.resolve(args.baseline ?? path.join(ROOT, 'dependency-baseline.json'))
const ledgerPath = path.resolve(args.ledger ?? path.join(ROOT, 'audits/fleet-remediation-ledger.json'))
const today = args.today ?? new Date().toISOString().slice(0, 10)

if (args.command === 'ledger-check') {
  const errors = validateLedger(readJson(ledgerPath), today)
  if (args.json) console.log(JSON.stringify({ errors }, null, 2))
  else console.log(errors.length ? errors.join('\n') : 'fleet remediation ledger: valid')
  process.exit(errors.length ? 1 : 0)
}

if (!['check', 'snapshot', 'apply', 'ledger-sync'].includes(args.command)) {
  usage()
  fail(`unknown command: ${args.command}`)
}

const selection = resolveRegistrySelection(args)
const registrySnapshot = listLocalRegistry(selection)
const { projects: registryProjects, unavailable, stateErrors } = localRegistryProjects(registrySnapshot, selection, args.project)
if (unavailable.length > 0 && !args.json) reportUnavailable(unavailable)
// Rows that failed registry identity validation are reported and skipped, but
// they still raise the final exit class; every other row is evaluated normally.
// `stateErrors` spans the WHOLE fleet listing, so a `--project P` run over a
// healthy P still reports and aggregates a sibling's corrupt row instead of
// exiting 0 over a registry it knows is broken. Rows already printed as part of
// the selection are not printed twice.
const unreportedStateErrors = stateErrors.filter(
  (row) => !unavailable.some((seen) => seen.project === row.project && seen.root === row.root),
)
if (unreportedStateErrors.length > 0 && !args.json) reportUnavailable(unreportedStateErrors)
const registryStateErrors = stateErrors.length
const findingsExit = (found) => (registryStateErrors > 0 ? REGISTRY_STATE_EXIT : (found ? 1 : 0))
// The artifact-writing commands used to end in a hard `process.exit(0)`, which
// bypassed `findingsExit` and made a class-4 registry state error vanish at
// exactly the point where it gets PERSISTED: a baseline or ledger derived from a
// registry whose rows failed identity validation freezes that corruption into
// the file every later run compares against. Refuse to produce the artifact at
// all — to a file or to stdout — and exit 4, the same class the non-writing
// commands already carry.
function refuseOnRegistryState(artifact) {
  if (registryStateErrors === 0) return
  // Non-JSON runs already printed these rows; JSON runs suppressed them, and a
  // refusal that names no row is unactionable.
  if (args.json) reportUnavailable(stateErrors)
  fail(
    `refusing to write ${artifact} from a local registry with ${registryStateErrors} identity-validation failure(s); resolve the STATE-ERROR rows and re-run`,
    REGISTRY_STATE_EXIT,
  )
}
if (args.fetch) {
  if (args.ref === 'worktree') fail('--fetch cannot be combined with --ref worktree')
  for (const project of registryProjects) {
    try {
      execFileSync('git', ['-C', project.root, 'fetch', '--no-tags', 'origin', '+refs/heads/main:refs/remotes/origin/main'], { stdio: 'ignore', timeout: 30_000 })
    } catch {
      fail(`fresh origin/main fetch failed for ${project.name}; dependency evaluation aborted before reading mutable project state`, 1)
    }
  }
}
const projects = registryProjects.map((project) => collectProject(project, args.ref))
const baseline = readJson(baselinePath)

if (args.command === 'snapshot') {
  refuseOnRegistryState('a dependency baseline')
  const snapshot = snapshotBaseline(baseline, projects)
  const output = `${JSON.stringify(snapshot, null, 2)}\n`
  if (args.output) fs.writeFileSync(path.resolve(args.output), output)
  else process.stdout.write(output)
  process.exit(0)
}

const result = checkBaseline(baseline, projects, today)
if (args.command === 'ledger-sync') {
  refuseOnRegistryState('a remediation ledger')
  const ledger = syncLedger(readJson(ledgerPath), result, args.vulnerability_report ? path.resolve(args.vulnerability_report) : null)
  const output = `${JSON.stringify(ledger, null, 2)}\n`
  if (args.output) fs.writeFileSync(path.resolve(args.output), output)
  else process.stdout.write(output)
  process.exit(0)
}
if (args.command === 'apply') {
  const drifts = result.findings.filter((finding) => ['version-drift', 'missing-toolchain-pin', 'toolchain-drift'].includes(finding.type))
  if (args.json) console.log(JSON.stringify({ project: args.project ?? null, unavailable, state_errors: stateErrors, changes: drifts }, null, 2))
  else {
    console.log('Read-only apply plan; update manifests, regenerate the authoritative lock, then run `trellis deps check`.')
    for (const drift of drifts) console.log(`${drift.project} ${drift.workspace ?? '.'}: ${drift.package ?? drift.toolchain} ${drift.resolved ?? drift.current ?? '(missing)'} -> ${drift.expected} [${drift.lane}]`)
  }
  process.exit(findingsExit(drifts.length > 0))
}

renderFindings(result, projects, unavailable, stateErrors, args.json)
process.exit(findingsExit(result.errors.length > 0 || result.findings.length > 0))
