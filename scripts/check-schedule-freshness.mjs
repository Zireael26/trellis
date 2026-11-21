#!/usr/bin/env node

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

// The one vocabulary the human catalogue and the machine ledger share. A
// cadence outside this set is a parse error, not a guess: the previous version
// required a backticked cron column, the catalogue replaced that column with
// prose, and the tool exited 2 on the real repository while its own fixture
// stayed green.
const CADENCES = new Map([
  ['daily', 'daily'],
  ['weekdays', 'weekdays'],
  ['weekly', 'weekly'],
  ['monthly', 'monthly'],
  ['quarterly', 'quarterly'],
  ['on demand', 'on-demand'],
  ['on-demand', 'on-demand'],
  ['drafted', 'drafted'],
])
const CANONICAL = new Set(CADENCES.values())
// Cadences that never produce an expected run.
const UNSCHEDULED = new Set(['on-demand', 'drafted'])

function fail(message) {
  throw new Error(message)
}

function formatDate(date) {
  return date.toISOString().slice(0, 10)
}

function parseDate(value, label) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) fail(`${label} must be YYYY-MM-DD`)
  const date = new Date(`${value}T00:00:00.000Z`)
  if (Number.isNaN(date.getTime()) || formatDate(date) !== value) fail(`${label} is not a calendar date: ${value}`)
  return date
}

function addDays(date, days) {
  const next = new Date(date)
  next.setUTCDate(next.getUTCDate() + days)
  return next
}

function startOfWeek(date) {
  // Monday-based, matching the `weekdays` cadence.
  const day = date.getUTCDay()
  return addDays(date, day === 0 ? -6 : 1 - day)
}

function startOfMonth(date) {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1))
}

function startOfQuarter(date) {
  const month = Math.floor(date.getUTCMonth() / 3) * 3
  return new Date(Date.UTC(date.getUTCFullYear(), month, 1))
}

function endOfMonth(date) {
  return addDays(new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1)), -1)
}

function endOfQuarter(date) {
  const start = startOfQuarter(date)
  return addDays(new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + 3, 1)), -1)
}

function parseArgs(argv) {
  const args = {
    root: ROOT,
    asOf: null,
    from: null,
    home: process.env.TRELLIS_HOME || path.join(os.homedir(), '.trellis'),
    fleet: null,
    executionReceipts: null,
  }
  const valueOptions = new Set(['--root', '--as-of', '--from', '--home', '--fleet', '--execution-receipts'])
  for (let index = 2; index < argv.length; index += 1) {
    const option = argv[index]
    if (option === '--help') return { help: true }
    if (!valueOptions.has(option)) fail(`unknown option: ${option}`)
    const value = argv[index + 1]
    if (!value || value.startsWith('--')) fail(`missing value for ${option}`)
    index += 1
    if (option === '--root') args.root = path.resolve(value)
    if (option === '--as-of') args.asOf = value
    if (option === '--from') args.from = value
    if (option === '--home') args.home = path.resolve(value)
    if (option === '--fleet') args.fleet = value
    if (option === '--execution-receipts') args.executionReceipts = value
  }
  if (!args.asOf) fail('--as-of is required')
  args.asOf = parseDate(args.asOf, '--as-of')
  if (args.from) args.from = parseDate(args.from, '--from')
  if (args.from && args.from.getTime() > args.asOf.getTime()) fail('--from must not be after --as-of')
  return args
}

function usage() {
  process.stdout.write(`Usage: node scripts/check-schedule-freshness.mjs --as-of YYYY-MM-DD [options]

Measures dated run artifacts under $TRELLIS_HOME/tasks/<fleet>/<task>/output/
against the cadence declared in scheduled-tasks/README.md and
scheduled-tasks/cadence.json. Output is JSON and never reads the current date.

Options:
  --root PATH                  Repository root holding scheduled-tasks/
                               (default: this repository)
  --as-of YYYY-MM-DD           Required inclusive end of the check window
  --from YYYY-MM-DD            Optional start; otherwise the first dated evidence
  --home PATH                  Private Trellis home (default: $TRELLIS_HOME)
  --fleet NAME                 Fleet whose task outputs are measured
                               (default: config.json default_fleet, then personal)
  --execution-receipts PATH    JSON {"runs":[{"task":"conductor","scheduled_for":"YYYY-MM-DD","status":"completed"}]}

A missing artifact is "missed" only when a completed execution receipt proves
the run happened. Without that evidence it is "execution-unknown", never clean
by inference. Cadences "drafted" and "on demand" have no expected runs.
`)
}

function cells(line) {
  return line.split('|').slice(1, -1).map((cell) => cell.trim())
}

function normalizeCadence(text) {
  const key = text.trim().toLowerCase()
  if (CADENCES.has(key)) return CADENCES.get(key)
  return CANONICAL.has(key) ? key : null
}

function readCatalogue(root) {
  const readme = path.join(root, 'scheduled-tasks', 'README.md')
  const ledger = path.join(root, 'scheduled-tasks', 'cadence.json')
  const fromReadme = new Map()
  for (const line of fs.readFileSync(readme, 'utf8').split(/\r?\n/)) {
    if (!line.startsWith('|')) continue
    const row = cells(line)
    if (row.length < 2) continue
    const task = row[0].replaceAll('`', '')
    if (!/^[a-z0-9][a-z0-9._-]{0,63}$/.test(task)) continue
    const cadence = normalizeCadence(row[1])
    // A table row whose cadence column is not in the shared vocabulary is not a
    // task row (header, separator, or another table); only claim rows whose
    // first cell is backticked, which is the catalogue convention.
    if (!cadence || !row[0].startsWith('`')) continue
    if (fromReadme.has(task)) fail(`duplicate ${task} catalogue row in ${readme}`)
    fromReadme.set(task, cadence)
  }
  if (fromReadme.size === 0) fail(`no scheduled-task catalogue rows found in ${readme}`)

  let parsed
  try {
    parsed = JSON.parse(fs.readFileSync(ledger, 'utf8'))
  } catch (error) {
    fail(`cannot read ${ledger}: ${error.message}`)
  }
  if (parsed?.schema_version !== 1 || typeof parsed.tasks !== 'object' || parsed.tasks === null) {
    fail(`${ledger} must contain schema_version 1 and a tasks object`)
  }
  const fromLedger = new Map()
  for (const [task, entry] of Object.entries(parsed.tasks)) {
    const cadence = normalizeCadence(String(entry?.cadence ?? ''))
    if (!cadence) fail(`${ledger} declares an unsupported cadence for ${task}: ${entry?.cadence}`)
    fromLedger.set(task, cadence)
  }

  // Fail closed on catalogue/ledger drift. Two sources of truth are acceptable
  // only when a mismatch is a hard error; silence is what let the old checker
  // measure a column the catalogue had already deleted.
  for (const [task, cadence] of fromReadme) {
    if (!fromLedger.has(task)) fail(`${ledger} is missing a cadence entry for ${task} (README says ${cadence})`)
    if (fromLedger.get(task) !== cadence) {
      fail(`cadence mismatch for ${task}: README says ${cadence}, ${path.basename(ledger)} says ${fromLedger.get(task)}`)
    }
  }
  for (const task of fromLedger.keys()) {
    if (!fromReadme.has(task)) fail(`${path.basename(ledger)} declares ${task}, which has no catalogue row in ${readme}`)
  }
  return { sources: { readme, ledger }, cadences: fromReadme }
}

function resolveFleet(args) {
  if (args.fleet) return args.fleet
  try {
    const config = JSON.parse(fs.readFileSync(path.join(args.home, 'config.json'), 'utf8'))
    if (typeof config.default_fleet === 'string' && config.default_fleet) return config.default_fleet
  } catch {
    // No readable machine config: fall through to the documented default.
  }
  return 'personal'
}

function readArtifacts(home, fleet, task, asOf) {
  const directory = path.join(home, 'tasks', fleet, task, 'output')
  const dates = new Set()
  let entries = []
  try {
    entries = fs.readdirSync(directory, { withFileTypes: true })
  } catch {
    return { directory, dates }
  }
  for (const entry of entries) {
    const match = entry.name.match(/^(\d{4})-(\d{2})-(\d{2})/)
    if (!match) continue
    const date = `${match[1]}-${match[2]}-${match[3]}`
    const parsed = parseDate(date, `artifact date in ${entry.name}`)
    if (parsed.getTime() > asOf.getTime()) continue
    dates.add(date)
  }
  return { directory, dates }
}

function readReceipts(root, receiptPath, tasks, asOf) {
  const receipts = new Map([...tasks].map((task) => [task, new Map()]))
  if (!receiptPath) return receipts
  const resolved = path.isAbsolute(receiptPath) ? receiptPath : path.resolve(root, receiptPath)
  let parsed
  try {
    parsed = JSON.parse(fs.readFileSync(resolved, 'utf8'))
  } catch (error) {
    fail(`cannot read execution receipts ${resolved}: ${error.message}`)
  }
  if (!Array.isArray(parsed.runs)) fail(`execution receipts ${resolved} must contain a runs array`)
  for (const [index, run] of parsed.runs.entries()) {
    if (!run || typeof run !== 'object') fail(`execution receipt ${index} must be an object`)
    if (!receipts.has(run.task) || (run.status !== 'completed' && run.completed !== true)) continue
    const date = parseDate(run.scheduled_for, `execution receipt ${index} scheduled_for`)
    if (date.getTime() > asOf.getTime()) continue
    receipts.get(run.task).set(run.scheduled_for, { path: resolved, status: 'completed' })
  }
  return receipts
}

// One expected run per completed period. A period is scored only once it has
// closed, so a task that is due today is never reported late.
function periods(cadence, from, asOf) {
  const result = []
  const closedBefore = (end) => end.getTime() < asOf.getTime()
  if (cadence === 'daily' || cadence === 'weekdays') {
    for (let day = new Date(from); closedBefore(day); day = addDays(day, 1)) {
      const weekday = day.getUTCDay()
      if (cadence === 'weekdays' && (weekday === 0 || weekday === 6)) continue
      result.push({ start: formatDate(day), end: formatDate(day) })
    }
    return result
  }
  const bounds = {
    weekly: (date) => { const start = startOfWeek(date); return { start, end: addDays(start, 6) } },
    monthly: (date) => ({ start: startOfMonth(date), end: endOfMonth(date) }),
    quarterly: (date) => ({ start: startOfQuarter(date), end: endOfQuarter(date) }),
  }[cadence]
  // `from` is normalized to a period start before the loop, so the first period
  // counted is a complete one rather than a fragment of the coverage window.
  let cursor = bounds(from).start.getTime() < from.getTime() ? addDays(bounds(from).end, 1) : from
  for (let previous = null; ;) {
    const { start, end } = bounds(cursor)
    if (closedBefore(end)) {
      result.push({ start: formatDate(start), end: formatDate(end) })
    } else {
      return result
    }
    const next = addDays(end, 1)
    if (previous !== null && next.getTime() <= previous.getTime()) {
      fail(`cannot advance ${cadence} periods from ${formatDate(start)}`)
    }
    previous = next
    cursor = next
  }
}

function earliest(dates) {
  return dates.length === 0 ? null : [...dates].sort()[0]
}

function checkTask({ task, cadence, artifacts, receipts, asOf, from }) {
  const artifactDates = [...artifacts.dates].sort()
  const receiptDates = [...receipts.keys()].sort()
  const report = {
    task,
    cadence: { value: cadence, source: 'scheduled-tasks/cadence.json, scheduled-tasks/README.md' },
    output_root: artifacts.directory,
    artifacts: artifactDates.map((date) => `${date} in ${path.join(artifacts.directory)}`),
    execution_receipt_dates: receiptDates,
    coverage: null,
    expected_runs: 0,
    observed_runs: 0,
    missed_runs: 0,
    execution_unknown_runs: 0,
  }
  if (UNSCHEDULED.has(cadence)) {
    report.coverage = { state: cadence }
    return { report, findings: [] }
  }

  const coverageStart = from ? formatDate(from) : earliest([...artifactDates, ...receiptDates])
  if (!coverageStart) {
    report.execution_unknown_runs = 1
    return {
      report,
      findings: [{
        kind: 'schedule-freshness',
        severity: 'warning',
        task,
        status: 'execution-unknown',
        scheduled_for: null,
        cadence,
        output_root: artifacts.directory,
        reason: 'No dated artifact or completed scheduler receipt establishes a coverage window; absence is not clean and not missed.',
      }],
    }
  }
  report.coverage = { from: coverageStart, through: formatDate(asOf) }

  const findings = []
  for (const period of periods(cadence, parseDate(coverageStart, `${task} coverage start`), asOf)) {
    report.expected_runs += 1
    if (artifactDates.some((date) => date >= period.start && date <= period.end)) {
      report.observed_runs += 1
      continue
    }
    const receiptDate = receiptDates.find((date) => date >= period.start && date <= period.end)
    const receipt = receiptDate ? receipts.get(receiptDate) : null
    if (receipt) {
      report.missed_runs += 1
      findings.push({
        kind: 'schedule-freshness',
        severity: 'warning',
        task,
        status: 'missed',
        scheduled_for: period.end,
        cadence,
        period,
        output_root: artifacts.directory,
        evidence: { execution_receipt: receipt.path, status: receipt.status },
        reason: 'A completed scheduler receipt proves the run occurred, but no dated artifact is present for this period.',
      })
    } else {
      report.execution_unknown_runs += 1
      findings.push({
        kind: 'schedule-freshness',
        severity: 'warning',
        task,
        status: 'execution-unknown',
        scheduled_for: period.end,
        cadence,
        period,
        output_root: artifacts.directory,
        reason: 'No dated artifact or completed scheduler receipt proves this scheduled run occurred; cadence alone does not prove a missed run.',
      })
    }
  }
  return { report, findings }
}

function run(args) {
  const { sources, cadences } = readCatalogue(args.root)
  const fleet = resolveFleet(args)
  const receipts = readReceipts(args.root, args.executionReceipts, cadences.keys(), args.asOf)
  const results = []
  for (const [task, cadence] of [...cadences.entries()].sort(([left], [right]) => left.localeCompare(right))) {
    const artifacts = readArtifacts(args.home, fleet, task, args.asOf)
    results.push(checkTask({
      task,
      cadence,
      artifacts,
      receipts: receipts.get(task),
      asOf: args.asOf,
      from: args.from,
    }))
  }
  const findings = results.flatMap((result) => result.findings)
  return {
    schema_version: 2,
    as_of: formatDate(args.asOf),
    home: args.home,
    fleet,
    sources,
    tasks: results.map((result) => result.report),
    summary: {
      tasks: results.length,
      scheduled: results.filter((result) => !UNSCHEDULED.has(result.report.cadence.value)).length,
      expected_runs: results.reduce((sum, result) => sum + result.report.expected_runs, 0),
      observed_runs: results.reduce((sum, result) => sum + result.report.observed_runs, 0),
      missed: findings.filter((finding) => finding.status === 'missed').length,
      execution_unknown: findings.filter((finding) => finding.status === 'execution-unknown').length,
    },
    findings,
  }
}

try {
  const args = parseArgs(process.argv)
  if (args.help) usage()
  else process.stdout.write(`${JSON.stringify(run(args), null, 2)}\n`)
} catch (error) {
  process.stderr.write(`schedule freshness: ${error.message}\n`)
  process.exitCode = 2
}
