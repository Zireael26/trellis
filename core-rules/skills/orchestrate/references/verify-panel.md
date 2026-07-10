# Reference — the verify-panel recipe

Cross-model diversity verification for hard findings. Realizes two things the
process reserved but never wired: the **"second-opinion → the other model"**
routing row (`docs/codex-routing.md` §2) and the parked **"v2 parallel
multi-angle reviewers"** note (`core-rules/hooks.md`). Recipe:
`recipes/verify-panel.wf.js`.

## When to use

After a review surfaces a **hard / `critical`** finding (from the
`code-review-subagent`, a `security-gate` pass, or an `orchestrate`
adversarial-verify stage) and the cost of being wrong is high enough to want a
second, *independent, different-model* opinion before acting. Not for routine
minor findings — that is what the single-model reviewer already covers.

## The panel mechanic

For each finding, two reviewers judge **independently and in parallel**:

- **Claude reviewer** — on the orchestrator, with a strict `REVIEW` schema
  (`real`, `confidence`, `reason`). Prompted to *refute*, not rubber-stamp.
- **Codex reviewer** — via the **canonical wrapped tracked path**
  (`agent(prompt, { agentType: 'codex:codex-rescue' })`), read-only, at the
  **declared per-run tier** (`args.effort` — required, never defaulted),
  **forced foreground** (§4 discipline). No output schema on the Codex leg (the
  forwarder returns raw stdout), so its verdict is parsed leniently.

The two verdicts merge into a `consensus`:

| consensus | meaning | caller action |
|---|---|---|
| `agree-real` | both models independently call it real | act on it (high signal) |
| `agree-not-real` | both call it a false positive | drop it |
| `split` | the models disagree | **surface for a human** — the diversity payoff |
| `single-model` | Codex was absent; Claude only | treat as the normal single-model verdict |

Cross-model diversity is the point: a `split` is where one model caught what the
other missed — exactly the case a single-model verify cannot produce.

## Inputs (`args`)

- `findings[]` — `{ id, claim, file, line, severity }`, the hard findings to verify.
- `context` — the diff / code excerpt / evidence the reviewers judge against.
- `effort` — **required** reasoning tier for the Codex leg (enum
  `medium|high|xhigh|max`; review passes are xhigh-band per the
  `docs/codex-routing.md` §3 ladder). Omitted → validation error, never a
  default; `ultra` is hard-rejected in recipes until the D4a prerequisites
  exist; `max` requires a non-empty `justification` (spec 011 D1/D4a).
- `justification` — required when `effort` is an exception tier (`max`); echoed
  into every returned verdict record alongside `effort`.
- `supportedEfforts` — accepted tiers probed from the installed surface,
  threaded from the main loop's D6 preflight; absent → conservative
  `['medium','high','xhigh']`.
- `codexAvailable` — presence-gate result threaded from the main loop; probed via
  `setup --json` if absent.

## Degrade-to-single-model

Codex is a **runtime-detected capability**, never a dependency (same contract as
`codex-executor`). With Codex absent — public mirror, plugin missing, or a
limit-hit/failed reviewer (a null / empty / **job-handle** result) — that
finding is judged by Claude alone, `consensus = single-model`, and the degrade
is `log()`'d (no-silent-caps). The panel never blocks on the Codex leg: a
finding's Codex reviewer degrading does not delay its Claude reviewer.

**Fail-closed tier rejection (spec 011 D6b):** if the declared `effort` is not
in `supportedEfforts`, the **whole Codex leg is turned OFF for the run** —
every finding is judged single-model, the refusal is `log()`'d, and the tier is
**never silently clamped** to a supported one. Same degrade shape as
Codex-absent; the run still completes.

## Loop safety

One-shot fan-out over the findings list (a single dispatch barrier, no rounds):
`no_progress_iterations: null`, ceilings inherit the resolved baseline. Codex
tokens attribute at `codex_usd_per_mtok` (`core-rules/loop-safety.md`).

## See also

- `docs/codex-routing.md` — §2 second-opinion routing, §4.5 the wrapped tracked path.
- `references/codex-executor.md` — the presence-gate + degrade contract this recipe reuses.
- `core-rules/hooks.md` — the `code-review-subagent` this panel escalates from.
