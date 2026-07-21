# Loop-safety contract — design spec

**Date:** 2026-06-09
**Status:** Approved design (brainstorming). Next: writing-plans → implementation.
**Owner:** __MAINTAINER_NAME__ (solo maintainer)
**Related:**
- Research brief: `docs/research/2026-06-09-agent-loops-and-nested-subagents.md`
- Sibling sub-projects (separate spec→plan cycles, dependency order): **(this) loop-safety contract** → nesting-depth budget in `orchestrate` → "Mayor" loops-supervising-loops recipe.

---

## 1. Problem & intent

Trellis is already a loop system: the 16 `scheduled-tasks/` are agentic cron loops ("cron plus a decision-maker in the body"), the `orchestrate` skill drives fan-out workflows, and `/loop` / `/goal` run unbounded agent loops on infra time. The current generation of agent loops moves the expensive resource from *writing code* to *running the loop*; the dominant production failure mode is the loop that does not stop (infinite iteration, no-progress thrash, runaway spend).

Trellis has **no single, named contract** that guarantees every loop halts. Halting logic is scattered and implicit: the Workflow tool carries a token budget, `autonomy.md` bounds some behavior, individual scheduled-tasks hardcode ad-hoc caps (test-health: 5 min/project, 20-commit bisect), and the dangerous-rm memory note flags overnight-run risk. Nothing enforces the three hard stops every serious 2026 loop design converges on.

**Intent:** ship a canonical **loop-safety contract** — a doctrine spec plus structured fields — that requires every Trellis loop to declare and honor three ceilings and to halt on any one. Safe-by-default: a loop authored with no thought still halts. The contract is **policy**; the ceiling **values** live in configuration so any instance can relax or tighten them without touching code or prose.

This is the foundational sub-project: the nesting-depth budget extends it (depth is a halting dimension) and the Mayor recipe must honor it.

### Non-goals
- Mechanical interception/enforcement that physically kills a running loop (a hook that blocks at tool-use time). Explicitly deferred — the contract is doctrine + declared fields + audit, not engine interception. A mechanical enforcement hook may follow as a separate sub-project once the contract's shape is proven.
- The nesting-depth budget and the Mayor recipe (separate specs).

---

## 2. The contract

Every Trellis loop **declares and honors three ceilings** and **halts on any one**:

1. **`max_iterations`** — hard cap on loop iterations / agent-dispatch rounds. Baseline **100**. Complements (does not replace) the Workflow engine's existing 1000-agent lifetime backstop.
2. **`no_progress_iterations`** — halt after N consecutive iterations that make no measurable progress. Baseline **3**. "Progress" is a per-loop **progress signal** (catalog below); when the signal is unchanged for N consecutive iterations, the loop halts.
3. **`budget_ceiling_usd`** — spend ceiling per loop run, in US dollars (human-meaningful unit). Baseline **1000**. The Workflow tool's `budget.total` is **token-native** (output tokens), so the contract documents a token-equivalent conversion and maps the dollar ceiling onto `budget.total` where the engine exposes it; `/loop` and scheduled-tasks track or estimate spend against the declared dollar ceiling.

### Progress-signal catalog
A loop declares which signal defines "progress" for its class. Canonical signals:
- **commit/PR** — a new commit or opened PR since the last iteration (fleet-mutation loops).
- **file delta** — at least one file changed (edit loops).
- **new finding** — an audit/review surfaced a new item (audit loops).
- **work-list drain** — the remaining work-list shrank (queue/pipeline loops).
- **state-hash change** — a declared state hash differs from the prior iteration (catch-all).

If no signal is declared, the catch-all **state-hash change** applies.

### Halt behavior
On any ceiling trip:
- **Hard stop** — never auto-continue past a tripped ceiling.
- **Structured halt report** — emit which ceiling tripped, the last progress marker, and the work completed so far.
- **Surface for unattended loops** — overnight / cron / `--run-in-background` loops surface the halt in their run report (and notification where wired) rather than dying silently.

---

## 3. Configuration

The ceiling **values** live in `trellis.config.json` so policy and configuration are separable.

### New `loop_safety` block (`trellis.config.json`)
```json
"loop_safety": {
  "max_iterations": 100,
  "no_progress_iterations": 3,
  "budget_ceiling_usd": 1000
}
```
Mirrored in `scripts/lib/trellis.config.schema.json` (types, descriptions, defaults). The block is optional; absence falls back to documented built-in constants identical to the baselines above.

### Resolution order (most specific wins)
Modeled on the existing `autonomy` resolution (`core-rules/CLAUDE.md` §Autonomy):

1. **Per-loop `safety` override** — a recipe's `safety` block or a scheduled-task's "Loop safety" stanza explicitly sets a value.
2. **Project-local `.trellis.config.json.loop_safety`** — optional, for a project that needs different ceilings.
3. **Central `trellis.config.json.loop_safety`** — the instance baseline.
4. **Built-in fallback constants** — documented in `core-rules/loop-safety.md`, so a loop in a broken/misconfigured/non-Trellis context still halts.

---

## 4. Materialization (where it lives)

- **`core-rules/loop-safety.md`** (new) — the canonical **policy** spec: the three dimensions, halt behavior, progress-signal catalog, resolution order, and the built-in fallback constants. References the config keys; contains **no hardcoded operational values baked into recipe code or prose** beyond the documented fallback constants.
- **`core-rules/CLAUDE.md`** — new **`## Loops`** section (the parent-rules entry point agents load at runtime). Short: states the contract exists, every loop honors the three ceilings, and points at `core-rules/loop-safety.md` and the `loop_safety` config resolution. Without this entry agents won't load the contract.
- **`core-rules/autonomy.md`** — a cross-reference clause: loops are an autonomy surface; the loop-safety contract is the halting guarantee that lets higher autonomy levels run loops unattended.
- **`orchestrate` skill:**
  - `recipes/template.wf.js` — gains a documented `safety` block (the three fields) in the recipe scaffold.
  - `SKILL.md` + `recipes/MANIFEST.md` — reference the contract; authoring a recipe without a `safety` declaration is non-compliant.
  - `recipes/fanout-verify.wf.js` — updated to declare its `safety` block (demonstrates an override where justified).
- **Scheduled-tasks** — a uniform **"Loop safety"** stanza added to each of the 16 `prompt.md` files (or `targets.md`), declaring the three values. Most inherit defaults; `test-health`'s 5 min/project + 20-commit bisect become **explicit overrides** expressed in the stanza.

---

## 5. Verification

Keep the contract honest the way `parent-hook-drift` keeps hooks honest: a **drift check folded into the existing weekly `cross-project-process-audit`** (no new 17th cron). The check scans `orchestrate` recipes and scheduled-task prompts for a present, non-blank loop-safety declaration and flags any loop missing one as a compliance finding. Authoring a loop without the stanza is additionally a `process-gate` / review finding.

---

## 6. Documentation & rollout updates

Every agent-setup and rollout document that should mention the new contract, with the specific change each needs. (This section satisfies the explicit requirement that all setup/rollout docs reflect the update.)

| Doc | Change |
|---|---|
| `core-rules/CLAUDE.md` | New `## Loops` section (see §4) — the runtime entry point. **Load-bearing.** |
| `core-rules/loop-safety.md` | New canonical policy file (see §4). |
| `core-rules/autonomy.md` | Cross-reference clause (loops as an autonomy surface). |
| `engineering-process.md` §3.1 (`trellis.config.json`) | Document the `loop_safety` block + resolution order. |
| `engineering-process.md` (new subsection, near §5b skills / autonomy) | Narrate the loop-safety contract: what it is, the three ceilings, where declared, how audited. |
| `engineering-process.md` §11 (scheduled audits) | Note the `cross-project-process-audit` now checks loop-safety stanza presence. |
| `AGENT_ONBOARD_PROJECT.md` | Step 7 verification: confirm the inherited rules surface `loop-safety.md` is reachable (parent-rules symlink already covers delivery; add the reachability assertion). Note in the prompt that onboarded projects inherit the contract automatically. |
| `README.md` §Configuration (`trellis.config.json`, ~line 89) | Document the `loop_safety` block. |
| `README.md` §Day-to-day commands / fleet rollouts | Add the rollout entry (see §7) if a `rollout-loop-safety.sh` is created. |
| `CHANGELOG.md` | Entry for the loop-safety contract; bump `trellis_version` (drives the `version-drift` audit). |
| `scripts/lib/trellis.config.schema.json` | Add the `loop_safety` schema definition (types, defaults, descriptions). |

**Rollout-doc principle:** because the contract ships as **parent rules + central config**, registered projects inherit `loop-safety.md` through the existing `.claude/rules/trellis.md` symlink and read `loop_safety` from the central config — there is **no per-project file copy** for the policy itself. Onboarding and the rollout scripts therefore need *reference* updates (so future onboarding/rollout mention and verify the contract), not a new per-project distribution mechanism. The `## Loops` entry in `core-rules/CLAUDE.md` is what makes the inherited contract discoverable to agents at runtime.

---

## 7. Distribution

Follows the established Trellis ship pattern (cf. `SHIP.md`, debrief/orchestrate rollouts):

1. **Canonical PR** against `~/projects/trellis-instance/` (a feature branch; never direct-to-main) containing: `core-rules/loop-safety.md`, the `core-rules/CLAUDE.md` `## Loops` entry, the `autonomy.md` clause, the `trellis.config.json` + schema `loop_safety` block, the `orchestrate` recipe-template + `fanout-verify` + MANIFEST/SKILL updates, the 16 scheduled-task stanzas, the `cross-project-process-audit` check, and all §6 documentation edits.
2. **Self-review + merge** (squash, per engineering-process §6.5).
3. **Public mirror sync** via the canonical content sync to the public template checkout (the `loop_safety` *values* in `trellis.config.json` are deployment-local and stay redacted per `template.redact_paths`; the **policy** file, the schema, and the docs are public).
4. **Fleet verification** — inheritance health check / the next `cross-project-process-audit` confirms every registered project surfaces the contract and every loop declares its stanza.
5. **`rollout-loop-safety.sh`** (create only if a concrete per-project action emerges; otherwise rely on inheritance + the audit). Decision deferred to writing-plans once the exact per-project delta, if any, is known.

---

## 8. Out of scope (separate spec→plan cycles)

- **Nesting-depth budget** in `orchestrate` (depth-5 nested subagents) — extends this contract; its own spec.
- **"Mayor" loops-supervising-loops recipe** — honors this contract and the depth budget; its own spec.
- **Mechanical enforcement hook** — possible later sub-project; not part of doctrine-first delivery.

---

## 9. Success criteria

- `core-rules/loop-safety.md` exists and is referenced from `core-rules/CLAUDE.md` (`## Loops`), `autonomy.md`, and `engineering-process.md`.
- `trellis.config.json` + schema carry a `loop_safety` block; resolution order is documented and matches the autonomy pattern.
- The `orchestrate` recipe template carries a `safety` block; `fanout-verify.wf.js` declares one.
- All 16 scheduled-task prompts carry a "Loop safety" stanza; `test-health`'s existing caps are expressed as overrides.
- `cross-project-process-audit` flags a loop missing its declaration.
- Every doc in §6 is updated; `trellis_version` bumped; `CHANGELOG.md` entry present.
- The change is merged to canonical `main` and synced to the public mirror.

---

## 10. Open questions & risks

- **Token↔dollar conversion** — the dollar ceiling needs a documented, maintainable token-per-dollar rate (model-dependent). Risk: rate drift as model pricing changes. Mitigation: document the rate as a single constant in `loop-safety.md` (or a `loop_safety.usd_per_mtok` config key) so it updates in one place. **Resolve during writing-plans.**
- **`no_progress` for fan-out loops** — "iteration" is well-defined for sequential loops but fuzzier for a single-barrier fan-out. Mitigation: for fan-out recipes, `max_iterations` governs dispatch rounds and `no_progress` keys on the work-list-drain signal across rounds; a one-shot fan-out with no rounds is exempt from `no_progress` (declared `null`). **Confirm in plan.**
- **Scheduled-task retrofit volume** — 16 prompts to edit uniformly. Mitigation: a single shared stanza template; most are pure inheritance (defaults), only `test-health` (and any other with existing caps) needs override values.
