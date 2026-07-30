// verify-panel — cross-model diversity verification of hard findings.
//
// Realizes the "second-opinion -> THE OTHER MODEL" routing (docs/codex-routing.md
// §2) and the parked "v2 parallel multi-angle reviewers" idea (core-rules/hooks.md).
// For each hard / `critical` finding, run TWO independent reviewers in parallel —
// one on the orchestrator (Claude) and one on Codex (the wrapped tracked path) —
// and merge their verdicts. Cross-model diversity beats self-redundancy: a finding
// both models independently call real is high-signal; a split is worth a human look.
//
// Degrades cleanly: with Codex absent (public mirror, plugin missing, or limit-hit)
// each finding is judged by Claude alone and the run is logged as single-model.
// Reuses the codex-executor presence-gate + degrade contract.
//
// Inputs (from `args`, never baked literals):
//   args.findings         [{ id, claim, file, line, severity }] — the hard findings to verify.
//   args.context          string  — the diff / code excerpt / evidence the reviewers judge against.
//   args.targetCwd        string  — REQUIRED repo/worktree root for the Codex
//                          reviewer. Threaded into its work order as TARGET_CWD.
//   args.effort           string  — REQUIRED reasoning tier for the Codex leg (enum
//                          medium|high|xhigh|max per docs/codex-routing.md §3;
//                          choose by finding complexity and consequence). Omitted → validation error, never
//                          a default (spec 011 D1); `ultra` hard-rejected in recipes
//                          (D4a); `max` requires a non-empty args.justification.
//   args.justification    string  — required when effort is an exception tier (`max`);
//                          echoed into every returned verdict record.
//   args.supportedEfforts [string] — accepted tiers probed from the installed surface,
//                          threaded from the main loop (D6 preflight); absent →
//                          conservative ['medium','high','xhigh']. Declared effort ∉
//                          set → FAIL-CLOSED: whole Codex leg OFF for the run
//                          (single-model), logged, never clamped (spec 011 D6b).
//   args.codexAvailable   boolean — presence-gate result threaded from the main loop; probed if absent.
//
// This file ships in the public mirror — keep it parametric and path-neutral.

export const meta = {
  name: 'verify-panel',
  description: 'Verify each hard finding with a cross-model panel (Claude + Codex in parallel), merge verdicts, degrade to single-model when Codex is absent',
  phases: [
    { title: 'Presence', detail: 'capability-gate Codex (prefer args, else probe setup --json)' },
    { title: 'Panel', detail: 'per finding: Claude + Codex reviewers in parallel -> merged verdict' },
  ],
  // One-shot fan-out over the findings list — a single dispatch barrier, no
  // rounds. Exempt from no_progress (nothing consecutive to measure); ceilings
  // inherit the resolved baseline. Cross-harness: Codex tokens attribute at
  // `codex_usd_per_mtok` (loop-safety.md). See fanout-verify for the same shape.
  safety: {
    no_progress_iterations: null,
    progress_signal: 'verdict',
  },
}

async function settle(id, run) {
  try {
    const value = await run()
    if (value == null) return { id, ok: false, value: null, error: 'null result' }
    return { id, ok: true, value, error: null }
  } catch (error) {
    return { id, ok: false, value: null, error: typeof error?.message === 'string' ? error.message : String(error) }
  }
}

function requireStage(stage, expectedIds, receipts, minSuccess = expectedIds.length) {
  const expected = expectedIds.map(String)
  const rows = Array.isArray(receipts) ? receipts : []
  const byId = new Map()
  let malformedCount = 0
  for (const receipt of rows) {
    if (!receipt || typeof receipt.id !== 'string' || byId.has(receipt.id)) { malformedCount += 1; continue }
    byId.set(receipt.id, receipt)
  }
  const unexpectedIds = [...byId.keys()].filter((id) => !expected.includes(id))
  const missingIds = expected.filter((id) => !byId.has(id))
  const successIds = expected.filter((id) => byId.get(id)?.ok === true && byId.get(id)?.value != null)
  const failureIds = expected.filter((id) => !successIds.includes(id))
  const identityOk = rows.length === expected.length && malformedCount === 0 && unexpectedIds.length === 0 && missingIds.length === 0
  const ok = identityOk && successIds.length >= minSuccess
  log(JSON.stringify({ event: 'workflow_stage_gate', stage, expected_ids: expected, success_ids: successIds, failure_ids: failureIds, unexpected_ids: unexpectedIds, missing_ids: missingIds, expected_count: expected.length, receipt_count: rows.length, success_count: successIds.length, failure_count: failureIds.length, malformed_count: malformedCount, min_success: minSuccess, ok }))
  if (!ok) throw new Error('workflow stage "' + stage + '" failed: ' + successIds.length + '/' + expected.length + ' successful; required ' + minSuccess)
  return expected.map((id) => byId.get(id))
}

// A single reviewer's verdict on one finding. additionalProperties:false so the
// engine rejects anything off-shape.
const REVIEW = {
  type: 'object',
  additionalProperties: false,
  required: ['real', 'confidence', 'reason'],
  properties: {
    real: { type: 'boolean', description: 'true iff the finding is a genuine defect worth acting on' },
    confidence: { type: 'number', description: '0.0-1.0 confidence in the verdict' },
    reason: { type: 'string', description: 'one or two sentences: why real / why not' },
  },
}

// --- Effort validation (spec 011 D1/D4a) — runs before any dispatch --------
// Panel units are homogeneous review passes, so effort is declared once per
// run. Explicit-or-error: an omitted tier is a validation error, never a
// default (docs/codex-routing.md §3).
const EFFORT_ENUM = ['medium', 'high', 'xhigh']
const targetCwd = args.targetCwd
if (typeof targetCwd !== 'string' || targetCwd.trim() === '') {
  throw new Error('verify-panel: targetCwd is required for the Codex reviewer work order')
}
const effort = args.effort
if (effort == null || effort === '') {
  throw new Error('verify-panel: effort required for this run — no default (spec 011 D1)')
}
if (effort === 'ultra') {
  log('verify-panel: HARD-REJECT effort=ultra — the companion dispatch surface caps at xhigh and delegation is invisible/non-resumable in a deterministic workflow (docs/codex-routing.md §3; D4a satisfied 2026-07-10, reject stands on surface + visibility)')
  throw new Error('verify-panel: effort "ultra" is hard-rejected in recipes — surface caps at xhigh + delegation invisible (docs/codex-routing.md §3; spec 011 D4a)')
}
if (effort === 'max') {
  log('verify-panel: HARD-REJECT effort=max — above xhigh these models spend substantially more reasoning for very little gain, so max is never selected (doctrine: core-rules/references/model-routing.md § Effort). A justification no longer admits it.')
  throw new Error('verify-panel: effort "max" is hard-rejected in recipes — xhigh is the ceiling (core-rules/references/model-routing.md § Effort)')
}
if (!EFFORT_ENUM.includes(effort)) {
  throw new Error('verify-panel: effort "' + effort + '" not in enum [' + EFFORT_ENUM.join(', ') + '] (spec 011 D1)')
}
const justification = args.justification ?? ''
// Surface-capability floor (D6b): fail-closed, never clamp. Conservative
// default = today's verified companion reality, threaded from the D6 preflight
// when available.
const supportedEfforts = args.supportedEfforts ?? ['medium', 'high', 'xhigh']
const effortSupported = supportedEfforts.includes(effort)

const findings = args.findings ?? []
const context = args.context ?? ''
const isEmpty = (r) => r == null || (typeof r === 'string' && r.trim() === '')
// §4 discipline (shared with codex-executor): the forwarder may background a
// unit and return a job-handle string; a review must be synchronous, so a
// handle-shaped result is treated as a failed Codex reviewer (-> single-model).
const isJobHandle = (r) =>
  typeof r === 'string' &&
  /(started in the background|task-[a-z0-9]{6,}|\/codex:status|check .* for progress)/i.test(r)

function reviewPrompt(f) {
  return [
    'You are an independent verifier. Judge whether this ONE finding is a real defect worth acting on.',
    'FINDING [' + (f.severity ?? 'unknown') + '] ' + (f.file ?? '') + (f.line ? ':' + f.line : ''),
    'CLAIM: ' + (f.claim ?? ''),
    '',
    'EVIDENCE / CONTEXT:',
    context,
    '',
    'Decide independently — do not assume the finding is correct because it was reported.',
    'Try to REFUTE it: if it does not actually reproduce or is a false positive, say real=false.',
    'Return your verdict as the REVIEW object (real, confidence 0-1, one-line reason).',
  ].join('\n')
}

// Codex reviewer via the CANONICAL wrapped tracked path (docs/codex-routing.md
// §4.5). Read-only (no --write), at the declared per-run tier, forced
// foreground. A null/empty/handle result is the degrade signal for THIS
// reviewer -> the finding falls back to Claude-only. No schema on the Codex
// leg: the forwarder returns raw stdout, so we parse leniently and treat
// unusable output as a degrade.
function codexReviewPrompt(f) {
  return [
    '--effort ' + effort,
    'TARGET_CWD: ' + targetCwd,
    'RUN SYNCHRONOUSLY IN THE FOREGROUND — do NOT use --background. Return your verdict text, never a job handle.',
    'This is a READ-ONLY review; make no edits.',
    reviewPrompt(f),
    'Answer in two lines: "real: true|false" and "reason: <one line>".',
  ].join('\n')
}

function parseCodexReview(raw) {
  if (isEmpty(raw) || isJobHandle(raw)) return null
  const text = String(raw)
  const realMatch = text.match(/(?:^|\n)\s*real\s*[:=]\s*(true|false)\s*(?:\n|$)/i)
  const reasonMatch = text.match(/(?:^|\n)\s*reason\s*[:=]\s*(\S[^\n]*)/i)
  if (!realMatch || !reasonMatch) return null
  return {
    real: realMatch[1].toLowerCase() === 'true',
    confidence: 0.7,
    reason: reasonMatch[1].trim().slice(0, 400),
  }
}

async function codexReview(f) {
  try {
    // Blocking codex-worker, not the fire-and-forget rescue path (spec 013):
    // a review verdict returned as a background handle would silently degrade
    // the panel to single-model.
    const raw = await agent(codexReviewPrompt(f), {
      agentType: 'codex-worker',
      label: 'codex-verify:' + (f.id ?? f.file ?? 'finding'),
      phase: 'Panel',
    })
    const parsed = parseCodexReview(raw)
    if (parsed == null) {
      log('codex reviewer for "' + (f.id ?? f.file) + '" gave no usable verdict — single-model for this finding')
    }
    return parsed
  } catch {
    return null
  }
}

function claudeReview(f) {
  return agent(reviewPrompt(f), {
    label: 'claude-verify:' + (f.id ?? f.file ?? 'finding'),
    phase: 'Panel',
    schema: REVIEW,
  })
}

function consensusOf(claude, codex) {
  if (codex == null) return 'single-model'
  if (claude.real === codex.real) return claude.real ? 'agree-real' : 'agree-not-real'
  return 'split'
}

// --- Phase: Presence ------------------------------------------------------
// Prefer the threaded gate result; else a GENERAL probe agent (NOT the
// forwarder, which is barred from `setup`) runs the gate. Unknown -> OFF (the
// safe, public-mirror-inert degrade). A declared tier the surface does not
// support turns the WHOLE Codex leg off for the run (fail-closed, single-model
// — the existing degrade shape); the tier is never clamped (spec 011 D6b).
phase('Presence')
let codexAvailable = args.codexAvailable
if (!effortSupported) {
  log('verify-panel: FAIL-CLOSED tier=' + effort + ' not supported by surface [' + supportedEfforts.join(', ') + '] — Codex leg OFF for this run (single-model), no clamp')
  codexAvailable = false
} else if (codexAvailable === undefined) {
  const presenceReceipt = await settle('codex-presence', () => agent(
    [
      'Run this and report ONLY whether Codex is usable:',
      '  node "$CODEX_PLUGIN"/scripts/codex-companion.mjs setup --json',
      'Codex is available ONLY if ready && codex.available && auth.loggedIn.',
      'Return the single word "yes" or "no".',
    ].join('\n'),
    { label: 'codex-presence', phase: 'Presence' },
  ))
  requireStage('Presence:Codex', ['codex-presence'], [presenceReceipt], 0)
  codexAvailable = presenceReceipt.ok === true
    && typeof presenceReceipt.value === 'string'
    && /\byes\b/i.test(presenceReceipt.value)
}
log('verify-panel: ' + findings.length + ' finding(s), codex ' + (codexAvailable ? 'ON' : 'OFF (single-model)'))

// --- Phase: Panel ---------------------------------------------------------
// Per finding, both reviewers run in parallel; a finding's Codex leg degrading
// does not block its Claude leg. Findings are independent, so the whole panel
// fans out at once.
phase('Panel')
const findingIds = findings.map((f) => String(f.id ?? f.file ?? 'finding'))
const claudeReceipts = await parallel(
  findings.map((f, index) => () => settle(findingIds[index], () => claudeReview(f))),
)
requireStage('Panel:Claude', findingIds, claudeReceipts, findingIds.length)

const codexReceipts = await parallel(
  findings.map((f, index) => () => settle(findingIds[index], () => (
    codexAvailable ? codexReview(f) : Promise.resolve(null)
  ))),
)
requireStage('Panel:Codex', findingIds, codexReceipts, 0)

const results = findings.map((finding, index) => {
  const claude = claudeReceipts[index].value
  const codex = codexReceipts[index].ok ? codexReceipts[index].value : null
  // Receipt echo (spec 011 D1/SC3e): the declared tier + justification are
  // merged recipe-side into every returned record — deterministic, never
  // asked of the reviewer agents (drift risk).
  return {
    finding,
    claude,
    codex,
    consensus: consensusOf(claude, codex),
    effort,
    justification,
  }
})

// The main loop acts on these: act on agree-real, drop agree-not-real, surface
// every `split` for a human look (the diversity payoff — one model caught what
// the other missed). Nothing here merges or gates; the caller decides.
return { codexAvailable, verdicts: results }
