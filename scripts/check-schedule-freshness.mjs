#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const TASKS = ['conductor', 'dep-currency', 'dep-vulnerabilities']

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

function addDay(date) {
  const next = new Date(date)
  next.setUTCDate(next.getUTCDate() + 1)
  return next
}

function compareDates(left, right) {
  return left.getTime() - right.getTime()
}

function parseArgs(argv) {
  const args = { root: ROOT, asOf: null, from: null, executionReceipts: null }
  for (let index = 2; index < argv.length; index += 1) {
    const option = argv[index]
    if (option === '--help') return { help: true }
    if (!['--root', '--as-of', '--from', '--execution-receipts'].includes(option)) fail(`unknown option: ${option}`)
    const value = argv[index + 1]
    if (!value || value.startsWith('--')) fail(`missing value for ${option}`)
    index += 1
    if (option === '--root') args.root = path.resolve(value)
    if (option === '--as-of') args.asOf = value
    if (option === '--from') args.from = value
    if (option === '--execution-receipts') args.executionReceipts = value
  }
  if (!args.asOf) fail('--as-of is required')
  args.asOf = parseDate(args.asOf, '--as-of')
  if (args.from) args.from = parseDate(args.from, '--from')
  if (args.from && compareDates(args.from, args.asOf) > 0) fail('--from must not be after --as-of')
  return args
}

function usage() {
  process.stdout.write(`Usage: node scripts/check-schedule-freshness.mjs --as-of YYYY-MM-DD [options]\n\nChecks persisted conductor, dep-currency, and dep-vulnerabilities audit artifacts against their declared cadence. Output is JSON and never reads the current date.\n\nOptions:\n  --root PATH                  Repository root (default: this repository)\n  --as-of YYYY-MM-DD           Required inclusive end of the check window\n  --from YYYY-MM-DD            Optional inclusive start; otherwise first dated evidence\n  --execution-receipts PATH    JSON {"runs":[{"task":"conductor","scheduled_for":"YYYY-MM-DD","status":"completed"}]}\n\nMissing artifacts are \"missed\" only when a completed execution receipt exists.\nWithout that evidence they are \"execution-unknown\", never clean by inference.\n`)
}

function cells(line) {
  return line.split('|').slice(1, -1).map((cell) => cell.trim())
}

function parseDay(value, task) {
  if (!/^\d$/.test(value)) fail(`unsupported ${task} cron day: ${value}`)
  const day = Number(value)
  if (day < 0 || day > 7) fail(`unsupported ${task} cron day: ${value}`)
  return day === 7 ? 0 : day
}

function parseDays(value, task) {
  if (value === '*') return null
  const days = new Set()
  for (const part of value.split(',')) {
    const range = part.match(/^(\d)-(\d)$/)
    if (!range) {
      days.add(parseDay(part, task))
      continue
    }
    const start = parseDay(range[1], task)
    const end = parseDay(range[2], task)
    if (start > end) fail(`unsupported ${task} cron day range: ${part}`)
    for (let day = start; day <= end; day += 1) days.add(day)
  }
  return days
}

function parseCron(cron, task) {
  const fields = cron.trim().split(/\s+/)
  if (fields.length !== 5 || fields[2] !== '*' || fields[3] !== '*') fail(`unsupported ${task} cron: ${cron}`)
  return { cron, days: parseDays(fields[4], task) }
}

function readCadences(root) {
  const readme = path.join(root, 'scheduled-tasks', 'README.md')
  const found = new Map()
  for (const line of fs.readFileSync(readme, 'utf8').split(/\r?\n/)) {
    if (!line.startsWith('|')) continue
    const row = cells(line)
    const task = row[0]?.replaceAll('`', '')
    if (!TASKS.includes(task)) continue
    const cron = row[2]?.match(/`([^`]+)`/)?.[1]
    if (!cron) fail(`missing declared cron for ${task} in ${readme}`)
    found.set(task, parseCron(cron, task))
  }
  for (const task of TASKS) {
    if (!found.has(task)) fail(`missing ${task} cadence in ${readme}`)
  }
  return found
}

function isScheduled(date, cadence) {
  return cadence.days === null || cadence.days.has(date.getUTCDay())
}

function readArtifacts(root, asOf) {
  const artifacts = new Map(TASKS.map((task) => [task, new Set()]))
  const audits = path.join(root, 'audits')
  for (const entry of fs.readdirSync(audits, { withFileTypes: true })) {
    if (!entry.isFile()) continue
    const match = entry.name.match(/^(\d{4}-\d{2}-\d{2})-(conductor|dep-currency|dep-vulnerabilities)\.md$/)
    if (!match) continue
    const date = parseDate(match[1], `artifact date in ${entry.name}`)
    if (compareDates(date, asOf) <= 0) artifacts.get(match[2]).add(match[1])
  }
  return artifacts
}

function readReceipts(root, receiptPath, asOf) {
  const receipts = new Map(TASKS.map((task) => [task, new Map()]))
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
    if (!TASKS.includes(run.task) || (run.status !== 'completed' && run.completed !== true)) continue
    const date = parseDate(run.scheduled_for, `execution receipt ${index} scheduled_for`)
    if (compareDates(date, asOf) > 0) continue
    receipts.get(run.task).set(run.scheduled_for, {
      path: path.relative(root, resolved).replaceAll(path.sep, '/'),
      status: 'completed',
    })
  }
  return receipts
}

function earliest(dates) {
  return dates.length === 0 ? null : dates.sort()[0]
}

function checkTask(task, cadence, artifacts, receipts, asOf, from) {
  const artifactDates = [...artifacts].sort()
  const receiptDates = [...receipts.keys()].sort()
  const coverageStart = from ? formatDate(from) : earliest([...artifactDates, ...receiptDates])
  const report = {
    task,
    cadence: { cron: cadence.cron, source: 'scheduled-tasks/README.md' },
    artifacts: artifactDates.map((date) => `audits/${date}-${task}.md`),
    execution_receipt_dates: receiptDates,
    coverage: coverageStart ? { from: coverageStart, through: formatDate(asOf) } : null,
    expected_runs: 0,
    observed_runs: 0,
    missed_runs: 0,
    execution_unknown_runs: 0,
  }

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
        cadence: cadence.cron,
        reason: 'No persisted dated artifact or completed scheduler receipt establishes a coverage window; absence is not clean or missed.',
      }],
    }
  }

  const findings = []
  for (let date = parseDate(coverageStart, `${task} coverage start`); compareDates(date, asOf) <= 0; date = addDay(date)) {
    if (!isScheduled(date, cadence)) continue
    const scheduledFor = formatDate(date)
    report.expected_runs += 1
    if (artifacts.has(scheduledFor)) {
      report.observed_runs += 1
      continue
    }
    const receipt = receipts.get(scheduledFor)
    if (receipt) {
      report.missed_runs += 1
      findings.push({
        kind: 'schedule-freshness',
        severity: 'warning',
        task,
        status: 'missed',
        scheduled_for: scheduledFor,
        cadence: cadence.cron,
        expected_artifact: `audits/${scheduledFor}-${task}.md`,
        evidence: { execution_receipt: receipt.path, status: receipt.status },
        reason: 'A completed scheduler receipt proves the run occurred, but its dated audit artifact is absent.',
      })
    } else {
      report.execution_unknown_runs += 1
      findings.push({
        kind: 'schedule-freshness',
        severity: 'warning',
        task,
        status: 'execution-unknown',
        scheduled_for: scheduledFor,
        cadence: cadence.cron,
        expected_artifact: `audits/${scheduledFor}-${task}.md`,
        reason: 'No persisted audit artifact or completed scheduler receipt proves this scheduled run occurred; cadence alone does not prove a missed run.',
      })
    }
  }
  return { report, findings }
}

function run(args) {
  const cadences = readCadences(args.root)
  const artifacts = readArtifacts(args.root, args.asOf)
  const receipts = readReceipts(args.root, args.executionReceipts, args.asOf)
  const results = TASKS.map((task) => checkTask(task, cadences.get(task), artifacts.get(task), receipts.get(task), args.asOf, args.from))
  const findings = results.flatMap((result) => result.findings)
  return {
    schema_version: 1,
    as_of: formatDate(args.asOf),
    tasks: results.map((result) => result.report),
    summary: {
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
