# Trellis Engineering-Process Enforcement — UNIFIED Design

*Status: authoritative design (the merge deliverable). Date: 2026-06-02. Scope: cross-cutting change to the canonical `core-rules/` tree + seeding machinery. This is itself a heavyweight change and belongs in `specs/NNN-process-enforcement/` when scaffolded.*

*Merges four inputs: WF#1 (spec→plan→execute skills redesign, `/tmp/wf1-plan.md`); the process-vs-enforcement audit (`audits/2026-06-02-process-vs-enforcement-map.md`); and the three enforcement-layer designs E1 (dead-gate completions: code-review + ui-verify), E2 (turn-level hard guards: receipts + re-read + fail-counter), E3 (merge-boundary gates: process-gate auto-fire + security #7).*

---

## 1. Executive summary

The audit's root finding is a **prescribed-vs-actual divergence**: the manual describes a Definition-of-Done regime stronger than what ships. Two Tier-2 Stop hooks are skeletons that `exit 0` (`code-review-subagent.sh`, `ui-verify.sh` — audit G4/G5, the P0); receipts are unenforced prose (G1); re-read-before-edit is the highest-frequency mechanical bug with zero guardrail (F5); `process-gate` is "mandatory" but never auto-fires (H1); per-PR security is none at the diff that introduces it (I8). In parallel, WF#1 finds the **skills spine is amputated at both ends** — no canonical builder (`execute`) and no principle-compliance check — with a dangling `brainstorming → writing-plans` handoff into an uninstalled skill. This design unifies the enforcement fixes and the skills work into **ONE dependency-ordered program** (not "fix everything then build"), because the skills layer (`execute`) and the hooks layer (receipts) are co-dependent: execute's value *assumes* receipts are real, and on hook-less AntiGravity the execute skill body is the *sole* carrier of code-review + ui-verify + receipts — so they land in lockstep, decomposed into 13 phases of ≤7 files each.

### Locked decisions (design to these; do not relitigate)

1. **Combined program.** Interleave enforcement-layer fixes (hooks/gates) with skills-layer work (execute/constitution/tracks/brainstorming) into a single dependency-ordered phased rollout, ≤7 files per phase (Trellis rule). Order by real dependency, not by category.
2. **Hard gates, slider tunes cadence.** `process-gate` auto-fires as a real pre-merge hook (not just an agent-invoked skill); receipts HARD-BLOCK in `stop-verify`; re-read-before-edit WARNS then BLOCKS; code-review and ui-verify ACTUALLY RUN and BLOCK on critical. Gates ALWAYS fire where their harness can run them; the L1–L5 autonomy slider changes only WHO answers and the RHYTHM (warns-before-block), never WHETHER a gate fires. Bright-line guardrails hold at every level.
3. **Render-only constitution.** `/constitution` is a render-only command over the resolved rule stack (parent `core-rules/CLAUDE.md` + presets + project `CLAUDE.md`, §14.8 order); writes NO file; introduces NO new authority layer. `analyze`'s new 9th "constitution-compliance" category assembles the rule stack directly from those files — it does not consume the command's stdout.

### Remaining operator decisions (full detail in §6)

1. **Code-review confidence floor** — flip the floor on by default, or ship plumbing default-off and flip on if the Phase 2a smoke-test shows flaky blocks? *Recommend: ship default-off; the day-one false-block risk is bounded by the new per-turn `TRELLIS_REVIEW_OVERRIDE` escape.*
2. **Re-read concurrent-worktree limitation** — accept the documented fail-OPEN collision, or key state on session-id if the envelope exposes one? *Recommend: accept and document.*

**The single most important cross-cutting fact this merge closes:** E2 was written not knowing `execute` existed (it flagged "WF#1 doc not found in-tree" as an open dependency). As the merge, this design **declares the E2 receipt grammar canonical** — `<!-- dod-receipt cmd="…" exit=<int> diff="+N/-M (K files)" -->` — maps it 1:1 to `core-rules/CLAUDE.md:43` ("the verification command you ran, its exit code, and the diff lines that prove the change"), and requires the `execute` skill body to emit byte-identically what `stop-verify` checks. That byte-identity is what lets one parser serve every harness that *runs the hook* (§4).

---

## 2. The unified enforcement architecture

### 2.1 Three layers × three harnesses — the whole system

```
                         ENGINEERING ACTIVITY (audit §1 inventory)
                                        │
   ┌────────────────────────────────────────────────────────────────────────┐
   │ SKILLS LAYER  (the spec→plan→execute spine — model-invoked, harness-     │
   │               neutral SKILL.md, symlinked byte-identical to all harnesses)│
   │  brainstorming(front-door) → [surgical | lightweight | heavyweight]      │
   │   → execute (one loop, enforcement IN THE BODY) → process-gate           │
   │  constitution (render-only) ─┐                                           │
   │  analyze (9th: compliance) ──┴─ assemble §14.8 rule stack from files     │
   └────────────────────────────────────────────────────────────────────────┘
                                        │  (defense-in-depth; sole turn-level path on AntiGravity)
   ┌────────────────────────────────────────────────────────────────────────┐
   │ HOOKS LAYER  (turn-level, fail-OPEN on infra / fail-CLOSED on finding;    │
   │               Claude + Codex ONLY — AntiGravity runs no workspace hooks)  │
   │  PreToolUse:  reread-guard.sh (Edit|MultiEdit|Write — warn→block)        │
   │               track-read.sh (Read recorder)                              │
   │  PostEdit:    post-edit-verify.sh (live: per-file lint)                  │
   │  Stop:        stop-verify.sh  ── todos + typecheck/lint/test (live)      │
   │                              ╰─ + RECEIPTS (E2, new) + FAIL-COUNTER (E2) │
   │               code-review-subagent.sh (E1 — reviewer ladder, BLOCK crit) │
   │               ui-verify.sh (E1 — presence-gate→probe→screenshot, BLOCK)  │
   └────────────────────────────────────────────────────────────────────────┘
                                        │
   ┌────────────────────────────────────────────────────────────────────────┐
   │ GATES LAYER  (merge boundary — the cross-harness fail-closed-at-push tier;│
   │               deterministic checks only — no LLM/visual gates live here)  │
   │  pre-push (husky + githooks): run-all.sh --mode=merge — runs on EVERY      │
   │       harness incl. AntiGravity (which runs git hooks but no workspace     │
   │       hooks)  (8 gates: PR/secrets/bypass/tests/docs/stack/SECURITY-diff/  │
   │       ANALYZE) — blocks at push; only escape is an explicit bypass         │
   │       (--no-verify / direct-push), itself a logged tripwire …              │
   │  … caught by the daily bypass-tripwire scheduled audit (the backstop)      │
   └────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Activity → new enforcement strength (the layer × harness matrix)

Legend: **HARD** = hook blocks turn / gate fails PR / pre-push blocks. **MED** = skill-guided or cron-caught. **SOFT** = advisory / model-discipline only, no automated reject. Arrows show what this program upgrades. The AntiGravity column tells the truth about what actually blocks there: it runs no hooks, and the deterministic merge gate (`run-all.sh`) contains *no* code-review, ui-verify, or receipt check — so those three are skill-body discipline only on AntiGravity (SOFT), with no merge backstop. See §2.4.

| Activity (audit ID) | Was | NOW | Mechanism (layer) | Claude | Codex | AntiGravity |
|---|---|---|---|---|---|---|
| **G4** code-review on edit-heavy turns | NONE (skeleton) | **HARD** | E1 reviewer ladder; BLOCK on `critical` (security/data-loss/broken-build) | Stop hook | Stop hook (lean) | **SOFT** (execute-body discipline; no merge backstop) |
| **G5** visual verification for UI | NONE (skeleton) | **HARD** | E1 ui-verify: presence-gate→probe→screenshot; BLOCK on visual fail | Stop hook | Stop hook | **SOFT** (execute-body discipline; no merge backstop) |
| **G1** receipts in done-claim | SOFT | **HARD** | E2 `<!-- dod-receipt … -->` parsed in `stop-verify`; structural done-detection | Stop hook | Stop hook (contingent on `transcript_path` — see I/Phase 2b) | **SOFT** (execute-body emits marker; no parser on AntiGravity) |
| **F5** re-read before edit | SOFT | **HARD (warn→block, all levels)** | E2 `reread-guard.sh` PreToolUse; known-set = Read∪Written this turn | PreToolUse | PreToolUse | **SOFT** (execute-body discipline) |
| **G7** two-attempts-then-stop | SOFT | **MED (advisory inject)** | E2 fail-counter wraps `emit_block`; same-file-set hash | Stop hook | Stop hook (transcript-state contingent) | — |
| **H1** process-gate pre-PR | MED (manual) | **HARD** | E3 auto-fire: pre-push `run-all.sh --mode=merge` (all harnesses) + branch protection (require-PR) | pre-push+PreToolUse | pre-push+PreToolUse | **pre-push (all harnesses)** + branch protection (require-PR) |
| **I8/P5** per-PR security | NONE | **HARD** | E3 gate #7 `check-security-diff.sh` → `run-diff.sh` (Critical/High → block) | run-all | run-all | run-all (pre-push, all harnesses) |
| **E1→9** analyze constitution-compliance | (n/a) | **MED (advisory)** | WF#1 9th category; assembles §14.8 stack from files; verdict line, never gates | analyze skill | analyze skill | analyze skill |
| **Build** (the missing builder) | NONE | **MED→HARD via gates** | WF#1 `execute`: per-task verify + receipt in body; ticks durable checkbox | execute | execute | **execute (sole turn-level carrier)** |
| **P4/B1** pipeline-skip detection | SOFT | **MED** (audit #6) | qualifying-change nudge; cross-project-process-audit cron | — | — | — |
| **I1/P9** gotchas self-correction | SOFT+opt-in | **MED** (audit #9) | promote `propose-rules.sh` default-on, non-blocking, edit-heavy-gated | Stop hook | — | — |
| **G6** inversion-test rigor | SOFT | **SOFT→MED** (audit #10) | optional single-assertion-flip in `check-tests.sh` (deferred) | run-all | run-all | run-all |
| F9 per-file lint | HARD | HARD (unchanged) | `post-edit-verify.sh` | PostToolUse | PostToolUse | — |
| G2 open-todos = not done | HARD | HARD (unchanged) | `stop-verify.sh` step 1 | Stop hook | Stop hook | — |
| G3 typecheck+lint+test green | HARD | HARD (unchanged) | `stop-verify.sh` + pre-push | Stop hook | Stop hook | pre-push (all harnesses) |
| H2 conventional commits | HARD | HARD (unchanged) | `commit-msg` commitlint | git | git | git |
| H3 no direct push to main | HARD | HARD (unchanged) | pre-push guard + branch protection | git | git | git |

### 2.3 The skills spine (the second figure — track selection → one execute loop)

```
   IDEA → brainstorming (canonical front-door + trigger-evaluator, /brainstorm)
              │  pure ideation → docs/brainstorm/*.md  (EPHEMERAL, never source of truth)
     ┌────────┼─────────────────────────────────┐
  SURGICAL          LIGHTWEIGHT               HEAVYWEIGHT
  (floor)           docs/plans/<topic>.md     specs/NNN-slug/ (5-doc bundle)
  test→fix→PR       (+opt docs/specs design)  clarify→spec→plan→tasks→analyze(9 cats)
     │                    │                          │
     └────────────────────┴──────── execute ─────────┘   ONE loop, TWO input contracts
                              (subagent-per-task; per-task verify + dod-receipt
                               IN THE BODY; ticks durable checkbox in lockstep)
                                          │
                              process-gate (auto-fire) + security-gate
```

`constitution` (render-only) and `analyze`'s 9th category both assemble the standing rule stack directly from `core-rules/CLAUDE.md` + presets + project `CLAUDE.md` in §14.8 order. `constitution` renders the layered stack with provenance for humans; the 9th category reads the same files and flags prose that contradicts a higher layer's stated rule. Neither *adjudicates* between layers (§14.8 is explicit that rules are additive, not last-wins, with no engine-level override — there is no machine-resolvable precedence to claim); both just assemble-and-surface. Neither writes a file; neither couples to the other's output.

### 2.4 The AntiGravity story (ONE story, load-bearing — and honest about its gap)

AntiGravity runs **no workspace hooks** (`inheritance.md:172–190`; ADR `2026-05-20-antigravity-third-harness.md`). Tier-1/Tier-2 turn-level enforcement is structurally **not available**. The guarantee is delivered by two carriers, but they do **not** cover every gate — the cross-harness coverage is split honestly:

- **(a) The `execute` skill body** carries code-review (E1 reviewer ladder, invoked in-body), ui-verify (E1 decision core / computer-use for the visual path), and receipts (emits the byte-identical `<!-- dod-receipt … -->` marker) — because the SKILL.md is symlinked into `.agents/skills/` and AntiGravity loads it. This is the *only* turn-level path on AntiGravity. **It is model discipline, not enforcement:** a skill body cannot reject the turn, so code-review / ui-verify / receipts are **advisory-only (SOFT)** on AntiGravity.
- **(b) The merge boundary** — the **local `pre-push` git hook** (both `core-rules/husky/pre-push` and `core-rules/githooks/pre-push`, calling `run-all.sh --mode=merge`) — is the cross-harness catch-all for **the deterministic gate set**: the 8-gate process-gate (PR-hygiene/secrets/bypass/tests/docs/stack/security-diff/analyze) and per-PR security and tests. **Git hooks are Tier-3 and run on EVERY harness, including AntiGravity** (which runs no workspace hooks but DOES run git hooks), so pre-push is the *uniform* cross-harness merge gate — AntiGravity is no longer special-cased. It is **fail-closed at push but not un-bypassable**: the only escape is an explicit bypass (`--no-verify` / direct-push), which is itself a logged tripwire caught by the daily **`bypass-tripwire`** scheduled audit (`scheduled-tasks/bypass-tripwire/`, which already scans git history + reflog for `--no-verify`, direct-to-main pushes, husky-hook bypasses, and force-pushes — the after-the-fact backstop).

**The honest gap:** `run-all.sh` contains no code-review, ui-verify, or receipt gate (verified — its gates are PR/secrets/bypass/tests/docs/stack, plus the new security/analyze in Phase 7). So on AntiGravity those three have **zero automated enforcement at any layer** — they are advisory. This is a known, scoped limitation, not a contradiction of locked decision #2: that decision means "block where hooks run," and AntiGravity's lack of hooks is a pre-existing documented gap. The routing answer is `inheritance.md`'s existing posture: **run risky / UI / edit-heavy changes through Claude or Codex**, where the turn-level hooks actually block. We deliberately do **not** add code-review/ui-verify as `run-all.sh` gates — an LLM reviewer and a visual screenshot check are a poor fit for a deterministic, non-flaky merge gate (appendix A-2).

State this once in `hooks.md` Tier 3, `engineering-process.md` §5.5/§6.4, `inheritance.md` "Known gap: AntiGravity native hooks," and `docs/antigravity-steering.md`. **The local `pre-push` git hook (every harness, AntiGravity included) backstopped by the daily `bypass-tripwire` audit is what makes the deterministic gate set "hard" cross-harness** — it blocks at push everywhere and the only escape (an explicit `--no-verify` / direct-push) is a logged tripwire the audit catches. Code-review/ui-verify/receipts are explicitly out of that guarantee on AntiGravity.

---

## 3. The combined-program phase plan (dependency-ordered, ≤7 files/phase)

Each enforcement design exceeds 7 files on its own (E1 ≈13, E2 ≈10, E3 ≈12 — Codex mirrors and bats suites count). So phases are **sub-decomposed and interleaved by dependency**, not "phase = E1." Every phase below lists **one filesystem path per file-touching bullet**; action-only bullets (re-seed, rollout, verify-only) are marked **(action — touches no file)** and excluded from the count. The declared count is the number of enumerated file paths, audited per-path (not per-bullet). Macro-order (advisor-confirmed):

> **P0 seeding + receipt-contract → P1 E1 cores → P2a/P2b E1-wiring + receipts + fail-counter → P3 constitution/analyze-9th → P4 execute → P5a/P5b E2 re-read → P6 brainstorming + dangling-refs → P7a/P7b E3 merge gates → P8a doctor + cheap audit flips → P8b pipeline-skip + steering + doc reconciliation.** (13 phases.)
>
> Note: constitution/analyze-9th (P3) lands before execute (P4) so the builder can render the rule stack and so analyze covers principle drift before the loop runs; this is the one place this program orders a skills-layer item ahead of a turn-guard, and it is safe because P3 is advisory-only and depends on nothing in P5–P8.

Dependency edges that fix the order: receipt grammar must be canonical before both `stop-verify` and `execute` use it (P0); E1's invokable reviewer + ui-verify core must exist before `execute` calls them in-body (P1→P4); E1 (G4/G5) precedes E2-receipts (G1) per the audit's own §6 recommendation; seeding machinery precedes any new skill reaching projects (P0); `execute` must exist before the brainstorming/plan-header repoints target it (P4→P6).

---

### Phase 0 — Seeding machinery + canonical receipt contract (foundation)
**Goal:** new skills can reach projects; the receipt grammar is locked before any consumer is built.
**Files (6):**
- `scripts/onboard-project.sh` — add `execute` + `brainstorming` to both `untrack_if_tracked` blocks (`.claude` lines 389–408 region, `.agents` 401+).
- `core-rules/templates/project.gitignore.fragment` — add `execute` + `brainstorming` lines (×2, `.claude` 13–19 / `.agents` 27–33); update header line 1 "7-skill set" → "9-skill set".
- `scripts/rollout-builder-skills.sh` — **NEW** separate rollout path for `execute`/`brainstorming` (mirrors why `rollout-process-gate-skill.sh` is separate; they are NOT pipeline writers so they do NOT join `FEATURE_SKILLS` in `rollout-feature-skills.sh:45`).
- `core-rules/CLAUDE.md` — add the canonical `<!-- dod-receipt cmd="…" exit=<int> diff="+N/-M (K files)" -->` grammar note at the DoD/`:43` receipt definition (declares the marker authoritative; maps to the existing prose).
- `core-rules/hooks.md` — document the receipt marker grammar as the single canonical anchor checked by hooks + emitted by execute.
- `scripts/lib/health-checks.sh` — placeholder `hc_*` stubs registered for the checks Phases 1/3/8 will fill (so doctor wiring lands incrementally without a later >7-file phase).

**Gate/verification:** `scripts/onboard-project.sh` dry-run on a scratch repo lists `execute`/`brainstorming`; `rollout-builder-skills.sh --dry-run` resolves; `bash scripts/doctor.sh` passes. **Unblocks:** every later phase that ships a new skill or hook check.

---

### Phase 1 — E1 invokable cores: reviewer ladder + ui-verify decision core
**Goal:** build the two enforcement cores that BOTH the Stop hooks (Phase 2a) and the `execute` body (Phase 4) call — single source of verdict.
**Files (5):**
- `core-rules/hooks/lib/code-reviewer.sh` — **NEW** canonical LLM reviewer (rung 2): embeds the reviewer prompt; pipes the `{diff, autonomy_level, decisions_log}` envelope into a one-turn `claude -p` call. The base invocation follows the verified `propose-rules.sh:116` pattern — `timeout 55 claude -p --max-turns 1 --output-format text` — **NOT** `--agent code-reviewer` (which exists only in the skeleton's own TODO). The bounded-budget / permission flags (`--permission-mode bypassPermissions --max-budget-usd 0.50`) follow the **evals runner** (`run-evals.sh:188,261,272`), which uses them with `--output-format json`; Phase 1 verification must confirm those flags behave with `--output-format text` in a one-turn hook context before they ship. **[SUPERSEDED by DL-SEC-01 (AMENDED): `--permission-mode bypassPermissions` is a prompt-injection→RCE vector on the untrusted diff and was removed; the shipped reviewer runs `--tools Read` (exclusive available-set = `{Read, advisor}`), airtight regardless of host `permissions.defaultMode`.]** Emits `{"findings":[{severity,file,line,msg,confidence?}]}`. Narrow `critical` = security-hole / data-loss / broken-build only. The deterministic rung (rung 3, clusterbid-style secret/stub regex) is folded into this same file as the no-`claude` fallback.
- `core-rules/hooks/agents/code-reviewer.md` — **NEW** reviewer prompt as a profile doc (source-of-truth for the embedded prompt; future `--agent` target).
- `core-rules/hooks/lib/ui-verify-core.sh` — **NEW** factored ui-verify decision (presence-gate → dev-server probe → screenshot → block-decision) callable by both hook and skill body.
- `core-rules/hooks.md` — document the reviewer ladder (`$CODE_REVIEWER_CMD` → `lib/code-reviewer.sh` → deterministic), the stdin contract (JSON envelope with `.diff` OR raw diff → findings JSON), and fail-open/fail-closed.
- `core-rules/hooks/tests/code-reviewer-ladder.bats` — **NEW** — ladder resolution, JSON-envelope contract, fail-open on missing `claude`.

**Gate/verification:** bats green; the ladder returns findings JSON for a seeded diff fixture and degrades (exit 0, no findings) when `claude` absent; the `text`+budget+permission flag combo is confirmed in a real one-turn invocation. **Unblocks:** Phase 2a (hooks call the cores), Phase 4 (execute calls the cores in-body — the AntiGravity advisory path).

---

### Phase 2a — E1 hard-block wiring + E2 receipts + fail-counter (Claude Stop hooks)
**Goal:** the dead skeletons fire and block; receipts hard-block; fail-counter rings — on Claude first. This closes the audit P0 (G4/G5) and P1 (G1) for the Claude harness.
**Files (3):**
- `core-rules/hooks/code-review-subagent.sh` — add `TRELLIS_REVIEW_IN_PROGRESS` guard at top (the mandatory fork-bomb sentinel, since `stop_hook_active` is FALSE in the `claude -p` child); export it before the reviewer call; call `lib/code-reviewer.sh`; remove the "skeleton exits 0" TODO. Idempotency marker `.review-done-<sha256(diff)>` so hook+execute-body don't double-charge. Add the per-turn `TRELLIS_REVIEW_OVERRIDE=1` escape (acknowledged-and-deferred, logged to the decisions-log, mirroring `TRELLIS_ALLOW_MAIN_PUSH`'s tripwire pattern) so a false `critical` has a documented exit that does not train `--no-verify`.
- `core-rules/hooks/ui-verify.sh` — reorder to **presence-gate FIRST** (UI-glob → tool-present? → probe → screenshot); detect `npx playwright` on PATH; flip empty-screenshot to `emit_block` on the tool-present path; call `lib/ui-verify-core.sh`.
- `core-rules/hooks/stop-verify.sh` — add receipts step (structural done-detection: tree-dirty ∧ no-open-todos ∧ checks-pass → require parseable `<!-- dod-receipt … -->` in turn-scoped transcript via the `save-context-log.sh` transcript pattern; doc-only skip; `PROCESS_GATE_NO_RECEIPTS=1` opt-out; missing-transcript → advisory-pass). Wrap `emit_block()` with the fail-counter (hash changed-file set with `cksum`; same hash → increment; at ≥2 inject "STOP: re-read top-down, state the wrong assumption").

**Gate/verification:** **smoke-test on a real project, not just fixtures** (per worktree-inheritance memory note) — confirm a real edit-heavy turn blocks on a seeded critical, a real done-claim without a receipt blocks, and `TRELLIS_REVIEW_OVERRIDE=1` cleanly defers a (deliberately) false critical with a decisions-log entry. **Unblocks:** Phase 2b mirrors; execute (Phase 4) can rely on receipts being real on Claude.

---

### Phase 2b — Codex Stop-hook mirrors + bats coverage
**Goal:** port the Phase-2a hard blocks to Codex (lean variants) and lock all of E1/E2-receipts behaviour with tests.
**Precondition (empirical, blocking) — RESOLVED 2026-06-02 (primary-source schema; runtime population deferred):** The codex-cli 0.135.0 binary embeds its hook JSON schema. The `stop.command.input` object **requires** the keys `transcript_path` AND `last_assistant_message` (both `NullableString`), plus `stop_hook_active`, `session_id`, `turn_id`, `cwd`, `model`, `permission_mode`. The `stop.command.output` is Claude-compatible: `decision:"block"` (requires non-empty `reason`), `continue`, `systemMessage`, `additionalContext`/`hookSpecificOutput`, and the exit-2-+-stderr path. Stdin-JSON delivery (the existing `save-context-log.sh` already `jq`-parses it). **Caveat — "required" ≠ "populated":** `NullableString` means the key is always present but the value may be `null`. The contract *shape* is confirmed; runtime *population* of the two fields was NOT positively confirmed in this env (`codex exec` intermittently hangs on an auth `invalid_grant` refresh; the `context-log.md` artifact is written by *both* harnesses' `save-context-log.sh`, so a populated copy is not Codex-exclusive proof). **Consequence (the design's pre-planned fork):** the *code* fails-open on null sources (missing/null → advisory-pass) so it is correct regardless — built now. The *matrix claim* G1 Codex = HARD is conditional: **HARD\*** = hard-blocks when the fields are populated, advisory-pass when null. Positive population confirmation is deferred to the live Codex Stop smoke-test at fleet rollout (co-scheduled with the live fork-bomb-chain check); if population proves reliably null there, relabel G1 Codex → SOFT (zero code change). Receipt detection therefore **unions both sources** (`last_assistant_message` OR turn-scoped `transcript_path` parse → pass; block only on a done-claim with NO receipt in *either*) — `last_assistant_message` is robust against a null transcript but only sees the final message, while the transcript parse catches a receipt emitted before the final tool call. The fail-counter is **git-derived** (`git diff HEAD --name-only | sort | cksum`), so `NullableString` never touches it.
**Files (6):**
- `core-rules/codex/hooks/code-review-subagent.sh` — sentinel + reviewer call (lean variant: raw diff, no autonomy/decisions-log envelope); same `TRELLIS_REVIEW_OVERRIDE` escape.
- `core-rules/codex/hooks/ui-verify.sh` — presence-gate-first mirror.
- `core-rules/codex/hooks/stop-verify.sh` — receipts (byte-identical marker) + fail-counter mirror, contingent on the precondition above.
- `core-rules/hooks/tests/stop-verify-receipts.bats` — **NEW** — receipt-present-passes / done-claim-without-receipt-blocks / conversational-turn-never-blocks / doc-only-skip / missing-transcript-advisory-pass.
- `core-rules/hooks/tests/fail-counter.bats` — **NEW** — same-file-set increments; pass or different-set resets; ≥2 injects.
- `core-rules/hooks/tests/code-review-block.bats` — **NEW** — sentinel-prevents-recursion, presence-gate (UI files + no tool = advisory not block), block-on-critical, fail-open-on-missing-reviewer, override-defers.

**Gate/verification:** all bats green; Codex stop-hook smoke-test blocks identically *iff* the precondition holds; otherwise the Codex receipt downgrade is applied and recorded. **Unblocks:** the "hard gates" decision is true for code-review/ui-verify on both hook-running harnesses, and for receipts on both *subject to the verified precondition*.

---

### Phase 3 — `constitution` (render-only) + `analyze` 9th category
**Goal:** fill the upstream principle layer; add compliance drift detection — both advisory, neither couples.
**Files (3):**
- `core-rules/commands/constitution.md` — **NEW** render-only command (mirrors `core-rules/commands/primer-check.md` read-only posture); renders the §14.8-layered rule stack to stdout **with provenance labels**; writes nothing; **assembles** the stack (parent + presets + project, in §14.8 order) and never *adjudicates* between layers (§14.8 has no engine-level override; "priority" is a deference hint, not a resolution rule).
- `core-rules/skills/analyze/SKILL.md` — add 9th "constitution compliance" category to the overview; **caps at advisory** — a finding emits a `## Verdict: BLOCKED` *line* but never hard-gates (the locked hard-gates decision keeps process-gate as the only hard gate).
- `core-rules/skills/analyze/references/drift-checks.md` — add category #9: assembles parent `CLAUDE.md` + presets + project `CLAUDE.md` in §14.8 order directly from files; **flags prose that contradicts a higher layer's stated rule** (plus DoD-receipt-less tasks, perf-budget breach); severity critical/warning/info. Phrased as detect-and-surface, not resolve.

**Gate/verification:** `/constitution` renders a merged, provenance-labeled stack on a registered project and writes no file (`git status` clean); `analyze` on a fixture spec surfaces a planted higher-layer contradiction as a verdict line without changing exit semantics. **Unblocks:** execute can run `/constitution` for rendering; analyze covers principle drift.

---

### Phase 4 — `execute` (the load-bearing builder)
**Goal:** the single canonical builder both lineages converge on; sole turn-level enforcement carrier on AntiGravity (advisory there).
**Files (4):**
- `core-rules/skills/execute/SKILL.md` — **NEW** harness-neutral builder (WF#1 §4.2 sketch): two input contracts (`specs/NNN/tasks.md` OR `docs/plans/<topic>.md` checkboxes), one loop; subagent-per-task; per-task verify → emit the canonical `<!-- dod-receipt … -->` → tick the box in lockstep; calls `lib/code-reviewer.sh` + `lib/ui-verify-core.sh` in-body (the AntiGravity advisory path); cites `CLAUDE.md:43` for the receipt (does not redefine); refuses to author/edit spec/plan/tasks prose, refuses monolithic-inline `/implement`, stops at process-gate; inherits `autonomy.md` cadence verbatim.
- `core-rules/skills/execute/references/verification-step.md` — **NEW** per-task verify + receipt template.
- `core-rules/skills/execute/references/loop.md` — **NEW** the shared-loop / dual-dialect parse-tick spec (isolates the one divergence point, Risk R1).
- `core-rules/skills/execute/tests/dual-dialect.bats` — **NEW** — checkbox parse/tick for both `docs/plans` and `specs/NNN/tasks.md`.
- *(action — touches no file)* Verify `scripts/seed-inheritance-symlinks.sh` auto-inherits `execute` once main is re-seeded (it mirrors `find -type l`, line 219 — no hardcode change needed; confirm in this phase).
- *(action — touches no file)* Re-seed the main checkout + run `scripts/rollout-builder-skills.sh` to push `execute` symlinks to registered projects.

**Gate/verification:** bats green; **smoke-test on a real project**: run `execute` against a small real plan, confirm it ticks boxes only after a receipt and stops at process-gate. **Unblocks:** brainstorming + plan-header repoints (Phase 6) now have a live target.

---

### Phase 5a — E2 re-read guard, Claude side (warn→block at all levels)
**Goal:** close F5, the highest-frequency mechanical mistake, warn-first to de-risk false-positives. De-risked last among turn guards.
**Files (5):**
- `core-rules/hooks/reread-guard.sh` — **NEW** PreToolUse on `Edit|MultiEdit|Write`: known-set = files Read this turn ∪ Written/Edited this turn; stale-`old_string` only bites untracked files; **warns then blocks at every level** (honors locked decision #2 literally — the slider tunes *how many warns precede the block*, shrinking to a single warn at L5, but never to zero, so the gate's trigger condition is level-invariant); `TRELLIS_REREAD_OVERRIDE=1` escape; concurrent-worktree collision is a documented fail-OPEN limitation.
- `core-rules/hooks/track-read.sh` — **NEW** PostToolUse on `Read` recorder (timestamp-keyed state at `<canonical-root>/.claude/.reread-state/<hash(transcript_path)>.tsv`); `stop-verify` stamps `turn_epoch` when `stop_hook_active != true`.
- `core-rules/templates/claude-settings.json` — register the two new PreToolUse/PostToolUse matchers.
- `scripts/rollout-settings.sh` — one-line array addition to roll the new matchers to registered projects.
- `core-rules/hooks/tests/reread-guard.bats` — **NEW** — known-after-Read passes; stale unread-file warns-then-blocks; new-file Write exempt; override escapes; warn-then-block fires at L5 too (no immediate-block).

**Gate/verification:** bats green; smoke-test that re-read warns on a real stale edit (at every level) and that a just-Read file passes silently. **Unblocks:** Phase 5b mirror.

---

### Phase 5b — E2 re-read guard, Codex mirror
**Goal:** port the warn→block re-read guard to Codex.
**Files (3):**
- `core-rules/codex/hooks/reread-guard.sh` — **NEW** mirror (same warn-then-block-at-all-levels semantics).
- `core-rules/codex/hooks/track-read.sh` — **NEW** mirror.
- `core-rules/codex/hooks.json` — register the Codex PreToolUse/PostToolUse matchers.

**Gate/verification:** Codex smoke-test warns then blocks on a real stale edit. **Unblocks:** turn-level guard set complete on both hook-running harnesses.

---

### Phase 6 — Brainstorming rehome + repoint + dangling plan-header repoints
**Goal:** fix the dead handoff; give the ideation lineage a canonical home; repoint everything at `execute`.
**Files (5):**
- `core-rules/skills/brainstorming/SKILL.md` — **NEW** (canonical body moved in); repurpose as front-door + trigger-evaluator (routes surgical/lightweight/heavyweight); terminal state → route-by-weight then hand to `clarify`/`spec` (heavy) or author `docs/plans/<topic>.md` then `execute` (light); add `docs/brainstorm/` ephemeral lane (committed, header-marked ephemeral — WF#1 Q5 default A).
- `~/.claude/skills/brainstorming/SKILL.md` — repoint the global path as a **symlink** to the canonical body, superseding the stale references at lines 32,48,62,66,135,136 that point at the uninstalled `writing-plans` (single source, global availability preserved — WF#1 I2 resolution). *(One filesystem target: the symlink replaces the file; the line-edits are subsumed by the move.)*
- `docs/plans/2026-05-20-trellis-autonomy.md:3` — repoint header → harness-neutral `execute` (drop `superpowers:`).
- `docs/plans/2026-05-19-primer-freshness-loop.md:3` — same repoint.
- `core-rules/inheritance.md` — name the lightweight track at the `:63` "spec-kit pipeline" blind spot.
- *(action — touches no file)* Re-seed main + `rollout-builder-skills.sh` to push `brainstorming` symlinks.

**Gate/verification:** `find -type l` shows brainstorming symlinked on a registered project; the global path resolves to canonical; no live ref names `writing-plans` (`CHANGELOG.md:229,313` LEFT as immutable history). **Unblocks:** the skills spine is whole and self-consistent.

---

### Phase 7a — E3 merge gates: process-gate gate scripts (security #7 + analyze #8 + bypass)
**Goal:** extend the deterministic gate set with per-PR security and the conditional analyze gate.
**Files (4):**
- `core-rules/skills/process-gate/scripts/run-all.sh` — add `--mode` (push/merge); extend `LABELS`/`RESULTS`/`FINDINGS` 6→8; add `run_gate 6` (security) + `run_gate 7` (analyze); **update BOTH `for i in 0 1 2 3 4 5` loops** (line ~150 verdict render + line ~156 findings render) to `0..7`; mode-aware fail→warn downgrade for PR-shape gates at `--mode=push`.
- `core-rules/skills/process-gate/scripts/check-security-diff.sh` — **NEW** ~25-line adapter → `security-gate/scripts/run-diff.sh` (`.claude`→`.agents` fallback, warn-skip if absent); `SECURITY_GATE_SKIP=1` honored; `--no-llm` when `PG_MODE=push`; passes 0/2/1 through.
- `core-rules/skills/process-gate/scripts/check-analyze.sh` — **NEW** deterministic spec-dir gate: if no `specs/NNN/` touched → pass; else grep `## Verdict:` (PASS→pass, NEEDS-REVISION/BLOCKED→warn, missing analyze.md→warn); **never exits 1** (constitution caps analyze at warn).
- `core-rules/skills/process-gate/scripts/check-bypass.sh` — flag `PROCESS_GATE_SKIP=1` trailers (warn) like `TRELLIS_ALLOW_MAIN_PUSH`.

**Gate/verification:** `run-all.sh --mode=push` warns (not fails) on PR-shape but fails on secrets/tests/security; `--mode=merge` hard-fails any ❌; the dual render loops emit all 8 gates. **Unblocks:** Phase 7b wires the gate into the boundary carriers.

---

### Phase 7b — E3 boundary carrier: the cross-harness merge gate — local pre-push on all harnesses
**Goal:** the cross-harness merge gate — local `pre-push` (both hook flavors) calling `run-all.sh --mode=merge`, fail-closed at push on every harness incl. AntiGravity (which runs git hooks), backstopped by the daily `bypass-tripwire` audit.
**Files (2):**
- `core-rules/husky/pre-push` — delete standalone typecheck/test (lines 66–75; `check-tests.sh` is a strict superset — no regression) + standalone security block (lines 78–105); keep PR-flow guard first untouched; call `run-all.sh` branching on the target ref read from stdin — `--mode=merge` (the full 8-gate check) when the push targets `main` (the real merge boundary), `--mode=push` (lenient) for WIP feature-branch pushes. The full merge check now runs locally at the boundary — there is no CI tier behind it.
- `core-rules/githooks/pre-push` — **NEW** byte-identical mirror (so the PM-agnostic migration carries the gate, and so AntiGravity — which runs git hooks but no workspace hooks — gets the deterministic merge gate; `githooks/` currently has only `post-checkout`).

**Gate/verification:** pre-push smoke-test blocks a seeded Critical security finding; `run-all.sh --mode=merge` at push rejects any ❌; the git-hook gate fires on every harness incl. AntiGravity. **Unblocks:** merge-boundary hard gate live for all harnesses incl. AntiGravity (deterministic gates only; the `hooks.md` Tier 3 / `engineering-process.md` §6.4 doc edits stating the local pre-push — backstopped by `bypass-tripwire` — is the cross-harness merge gate land in Phase 8b with the other doc edits).

---

### Phase 8a — Doctor loophole-closers + near-free audit flips (#9/#10)
**Goal:** close the "just don't configure a gate" loophole at audit altitude; land the two cheap top-10 items.
**Files (5):**
- `scripts/lib/health-checks.sh` — fill the Phase-0 `hc_*` stubs: registered projects have a resolvable reviewer (any rung) (E1); UI projects have a screenshot path (E1); registered projects have `pre-push` wired to `run-all.sh` (E3 — locally verifiable); receipt-grammar present in CLAUDE.md.
- `scripts/doctor.sh` — wire the new health checks into the doctor run order.
- `core-rules/hooks/propose-rules.sh` — promote default-on for registered projects, still non-blocking, **gated behind the same edit-heavy threshold as code-review** (≥3 files or ≥200 lines) so it does not stack a second per-Stop `claude -p` dispatch on every turn (audit #9).
- `core-rules/templates/claude-settings.json` — register `propose-rules.sh` in the default Stop chain (edit-heavy-gated).
- `core-rules/skills/process-gate/scripts/check-tests.sh` — optional single-assertion-flip inversion spot-check on changed test files, report-as-warn (audit #10; full mutation testing deferred).

**Gate/verification:** `bash scripts/doctor.sh` flags a deliberately reviewer-less / pre-push-unwired scratch project; `propose-rules.sh` surfaces a candidate gotcha without blocking and only on edit-heavy stops. **Unblocks:** loophole-closer shipped with the mirror.

---

### Phase 8b — Remaining audit item (#6), steering docs, doc reconciliation
**Goal:** land pipeline-skip detection; ship the cross-harness steering split + its drift audit; reconcile all the doc edits this program touched.
**Files (6):**
- `scheduled-tasks/` cross-project-process-audit — add pipeline-skip nudge category (audit #6) + steering-doc/skill-name drift category (WF#1 Q6) + flag projects whose `pre-push` is not wired to `run-all.sh` (E3 §4); the existing daily `bypass-tripwire` audit (`scheduled-tasks/bypass-tripwire/`) remains the after-the-fact backstop that catches anyone who bypassed the local hook (`--no-verify` / direct-push / force-push).
- `docs/gpt-5.5-steering.md` — **NEW** (effort medium→high at plan/analyze; verbosity low; progress floor every 6 steps/10 tool calls; `update_plan` + `multi_tool_use.parallel`).
- `docs/antigravity-steering.md` — **NEW** (no-hooks reality; execute-body is advisory-only, NOT enforcement; code-review/ui-verify/receipts have no automated backstop on AntiGravity; route high-risk / UI / edit-heavy runs through Claude or Codex).
- `core-rules/autonomy.md` — add ui-verify to bright-line guardrail #6 (currently names only "Code-review subagent on edit-heavy turns — always runs").
- `engineering-process.md` — the three-track framing + execute stage at §14.7; skill-body compensates (advisory) on AntiGravity at §5.5; the local `pre-push` git hook (every harness incl. AntiGravity), backstopped by the daily `bypass-tripwire` audit, is the cross-harness merge gate *for the deterministic gate set* at §6.4 — fail-closed at push, the only escape an audited bypass (the deferred Phase-7 note).
- `core-rules/hooks.md` — Tier 3 note carrying the matching pre-push/skill-body framing (the local `pre-push` git hook runs on every harness incl. AntiGravity and is fail-closed at push for the deterministic gates, backstopped by the daily `bypass-tripwire` audit; code-review/ui-verify/receipts advisory-only on AntiGravity).

**Gate/verification:** audit cron dry-run reports the new categories; `engineering-process.md`/`autonomy.md`/`hooks.md` describe the live regime (no skeleton/"mandatory-but-manual" language remains; the merge gate is described honestly as fail-closed-at-push on every harness, not un-bypassable; no overclaim that the merge gate covers code-review/ui-verify/receipts on AntiGravity). **Unblocks:** program complete; all top-10 interventions placed.

---

### WF#1 5-phase ↔ audit top-10 reconciliation (one table)

| This program | WF#1 phase | Audit interventions |
|---|---|---|
| Phase 0 | §7 seeding (P1/P3 prereq) | — (foundation) |
| Phase 1 | — | #1/#2 invokable cores |
| Phase 2a | — | **#1 code-review, #2 ui-verify, #3 receipts, #8 fail-counter** (Claude) |
| Phase 2b | — | same, Codex mirrors + bats (receipts contingent on `transcript_path`) |
| Phase 3 | §7 Phase 2 (constitution + analyze 9th) | spec-kit §2 constitution |
| Phase 4 | §7 Phase 1 (execute) | spec-kit §3 implement-as-builder |
| Phase 5a / 5b | — | **#4 re-read** (Claude / Codex) |
| Phase 6 | §7 Phase 3+4 (brainstorming + dangling refs) | — |
| Phase 7a / 7b | — | **#5 process-gate auto-fire, #7 per-PR security**, spec-kit §4 analyze-gate |
| Phase 8a | — | **#9 propose-rules, #10 inversion-test** + doctor loophole-closers |
| Phase 8b | §7 Phase 5 (steering) | **#6 pipeline-skip** + steering split + doc reconciliation |

---

## 4. Cross-harness + autonomy consistency

**Cross-harness.** One guarantee, delivered by the layer that each harness can actually run — and stated honestly where a harness cannot. **Claude Code + Codex** get all three layers: turn-level hooks (E1 reviewer ladder, E2 receipts/re-read/fail-counter — Codex via lean mirrors with `{"decision":"block"}`+exit 2, receipts contingent on the verified `transcript_path` precondition), the merge gates, and the execute body as defense-in-depth (the per-turn diff-hash idempotency marker prevents double-charging the LLM review where both fire). **AntiGravity** runs no workspace hooks, but it DOES run git hooks, so it gets exactly two carriers: (1) the **deterministic merge gate** — the local `pre-push` git hook (`run-all.sh --mode=merge`), which fires on every harness incl. AntiGravity and is fail-closed at push (not un-bypassable: the only escape is an explicit `--no-verify` / direct-push, itself a logged tripwire caught by the daily `bypass-tripwire` audit), plus plain branch protection (require-PR) — covering PR-hygiene/secrets/bypass/tests/docs/stack/security-diff/analyze; and (2) the `execute` skill body, which is **advisory-only**: it emits the byte-identical receipt marker and runs code-review/ui-verify in-body, but nothing rejects the turn, and `run-all.sh` has no code-review/ui-verify/receipt gate to catch them at merge. So on AntiGravity, code-review, ui-verify, and receipts are **SOFT (model discipline, no automated backstop)** — a scoped, documented limitation with the standing mitigation "route risky/UI/edit-heavy runs through Claude or Codex." The receipt grammar (`<!-- dod-receipt … -->`) is the single canonical anchor every *hook-running* harness reads/emits identically. No in-file model conditionals exist or are introduced (ADR 2026-05-08); the two genuine deltas (progress cadence, dispatch verb) live in per-harness steering docs.

**Autonomy.** Every gate in this design is a **bright-line guardrail that fires identically at L1–L5 on the harnesses that can run it**; the slider changes only the consultation surface and rhythm. Code-review and ui-verify block on `critical` at every level — even L5 cannot waive a critical (the whole point of bright-line); L5 only *auto-dispositions the advisory findings* with logged reasoning and renders them at end-of-turn / in the PR, while L1–L3 surface them to the user. Receipts hard-block at all levels; the fail-counter rings at all levels; **re-read warns-then-blocks at all levels — at no level is the warn skipped** (the slider tunes only how many warns precede the block, which can shrink to one at L5 but never to zero, so the *trigger condition* is level-invariant; this honors locked decision #2 literally). `process-gate` is fail-closed at every level (`--mode=push` vs `--mode=merge` is a *boundary* distinction — WIP feature-branch push vs push-to-`main` — not an autonomy one). The L4/L5 decisions-log-completeness clause layers *on top of* the auto-firing gate, verified by the code-review reviewer's expanded prompt, not by process-gate. `analyze`'s 9th category stays advisory at every level (a `BLOCKED` verdict line informs the human/PR but never hard-gates).

---

## 5. Risks & mitigations

| # | Risk | Mitigation |
|---|---|---|
| **NEW-1** | **Flaky-LLM false hard-block** (E1 top failure) — reviewer non-deterministically tags a non-critical issue `critical`, trapping the agent. | Narrow `critical` (security/data-loss/broken-build only, embedded in prompt); fail-OPEN on every infra failure; per-turn `TRELLIS_REVIEW_OVERRIDE=1` escape (logged, decisions-log auditable) so a cornered operator never has to reach for `--no-verify`; block-once-per-real-stop via diff-hash marker bounds blast radius; optional `confidence` floor (Open Decision 1); bounded budget (`--max-budget-usd 0.50` + 55s timeout). |
| **NEW-2** | **Fork bomb** (E1) — `claude -p` child's own Stop re-fires code-review → unbounded recursion (`stop_hook_active` is FALSE in the child). | `TRELLIS_REVIEW_IN_PROGRESS=1` sentinel checked at hook top, exported before the reviewer call — deterministic kill, mandatory in both Claude + Codex variants. |
| **NEW-3** | **Receipts cause workflow pain** (E2) — false-block on conversational/WIP turns, marker drift, or silent fail-open on a harness whose envelope lacks `transcript_path`. | Structural done-detection (tree-dirty ∧ no-open-todos ∧ checks-pass) means conversational/no-op turns never reach the receipt check — zero conversational false-blocks by construction; doc-only skip; `PROCESS_GATE_NO_RECEIPTS=1` opt-out; self-correcting block message prints the exact marker to paste; missing-transcript → advisory-pass; **Codex `transcript_path` presence is an empirically-verified precondition in Phase 2b** — if absent, receipts on Codex are honestly downgraded to advisory rather than asserted hard. |
| **NEW-4** | **Re-read false-positives** (E2) — prior-turn-unchanged files flagged. | known-set = Read∪Written this turn (Write targets self-register); warn-first before any block **at every level**; `TRELLIS_REREAD_OVERRIDE=1`; concurrent-worktree collision is a documented fail-OPEN limitation; ship last among turn guards. |
| **NEW-5** | **process-gate friction trains `--no-verify`** (E3 top failure) — full merge-semantics on every WIP push → habitual bypass kills the gate and everything behind it. | The lenient `--mode=push` (hard-fails only the always-valid four — secrets/bypass/tests/security — and downgrades PR-shape gates to warn) is available for WIP pushes; full BLOCKED semantics run at the merge boundary via the local `pre-push` git hook (`run-all.sh --mode=merge`) on every harness incl. AntiGravity; every documented skip (`PROCESS_GATE_SKIP=1`) is a `check-bypass.sh` tripwire, and any `--no-verify` / direct-push that bypasses the local hook is itself a logged tripwire caught by the daily `bypass-tripwire` audit backstop. |
| **NEW-6** | **AntiGravity overclaim** — operator assumes code-review/ui-verify/receipts are enforced on AntiGravity, ships an unreviewed risky change. | Matrix §2.2, §2.4, and §4 all state these are SOFT (advisory) on AntiGravity with no merge backstop; `docs/antigravity-steering.md` makes "route risky/UI/edit-heavy through Claude or Codex" the standing rule; the deterministic merge gate still catches secrets/tests/security/PR-shape there. |
| R1 | Checkbox-dialect drift (execute reads two formats). | Single loop; isolate parse/tick in `references/loop.md`; dual-dialect fixture test. |
| R2 | Steering-doc drift. | Steering-drift audit category (Phase 8b); spine stays model-agnostic so only the two genuine deltas live per-harness. |
| R3 | Lightweight track becomes a heavyweight bypass. | Trigger is countable; process-gate at merge is the backstop (analyze cannot fire on the lightweight track, so it structurally can't catch this). |
| R4 | Execute contaminates the five writers. | Hard boundary in execute SKILL.md ("never edits spec/plan/tasks prose"); writers' read-only boundaries unchanged. |
| R5 | AntiGravity enforcement hole — in-body verification skipped (the SOFT cells). | Degradation behaviour is non-negotiable skill text; `docs/antigravity-steering.md` documents "route risky runs through Claude/Codex"; the local `pre-push` git hook (fires on AntiGravity too) is the deterministic floor — fail-closed at push, with `--no-verify`/direct-push escapes caught by the daily `bypass-tripwire` audit (but it does NOT cover code-review/ui-verify/receipts — that gap is accepted, A-2). |
| R6 | Constitution becomes a 4th authority layer. | Render-only command, writes nothing; §14.8 is the single (additive, non-adjudicating) reference; 9th category assembles from files, not a new artifact. |
| R7 | Public-mirror leak (operator-specific paths in seeded files). | Mirror-clean review each phase; release/audit cadence catches drift. |
| R8 | Seeding-machinery omission — new skills never reach projects. | Phase 0 lands first (skills); the `pre-push` git hook ships via the existing hook-sync mechanism; dependency order documented. |

---

## 6. Open decisions

The three locked decisions resolve most of WF#1's opens: **Q2 (does the 9th category gate?) is RESOLVED** — advisory, never gates (locked hard-gates decision keeps process-gate as the only hard gate; constitution-compliance informs it). **Q3 (constitution command vs skill?) is RESOLVED** — render-only command (locked). WF#1 **Q1** (surgical↔lightweight boundary → default A: lightweight only when work needs a durable cross-session plan or ≥2 sequenced steps), **Q4** (builder named `execute` → adopted), **Q5** (`docs/brainstorm/` committed-but-marked-ephemeral → adopted), **Q6** (steering-drift audit now, Phase 8b → adopted) are all adopted at their defaults; none conflicts with the locked decisions.

Genuinely-new opens from the enforcement merge (small):
1. **Code-review confidence floor (E1).** Ship the optional `confidence`-floor knob (drop criticals below a threshold to advisory) on day one, or only if false-blocks are observed in the Phase 2a smoke-test? *Recommend:* ship the plumbing, default the floor off — the day-one false-block risk is now bounded by the new per-turn `TRELLIS_REVIEW_OVERRIDE` escape (so a cornered operator is never trapped without an audited exit), and the Phase 2a real-project smoke-test flips the floor on if blocks prove flaky. (See appendix A-1 for why default-off, not default-on.)
2. **Re-read concurrent-worktree limitation (E2).** Accept the fail-OPEN collision (two sessions sharing a transcript-hash key in one worktree) as a documented limitation, or key state on session-id if the envelope exposes one? *Recommend:* accept fail-open and document; revisit only if collisions surface.

---

## 7. Public-mirror + versioning

- **VERSION bump:** `core-rules/VERSION` 0.8.0 → **0.9.0** (minor — additive: new skills `execute`/`brainstorming`, new command `constitution`, new gates #7/#8, new hooks, finished E1 skeletons; no breaking removal). Land the bump in the final phase (8b) so a half-shipped program never advertises completeness.
- **CHANGELOG:** add a v0.9.0 entry summarizing the enforcement program (finished code-review + ui-verify gates; receipts/re-read/fail-counter; process-gate auto-fire + security #7; execute builder; render-only constitution; brainstorming rehome). **Leave `CHANGELOG.md:229,313` history untouched** (immutable; do not rewrite the `superpowers:` references).
- **What propagates to the public template:** every Phase change touching `core-rules/` (the seeded canonical tree) is mirror-bound and must be mirror-clean (no operator-specific paths): `execute`/`brainstorming` skills, `constitution.md`, the analyze 9th category, `lib/code-reviewer.sh` + `lib/ui-verify-core.sh`, the finished `code-review-subagent.sh`/`ui-verify.sh`, `stop-verify.sh` receipts/fail-counter, `reread-guard.sh`/`track-read.sh`, `run-all.sh` + `check-security-diff.sh` + `check-analyze.sh`, both `pre-push` variants (`husky/` + `githooks/`), and the steering docs. Roll new symlinks to registered projects via `rollout-builder-skills.sh` + the gitignore-fragment mechanism. Sync via `scripts/sync-to-template.sh` / `scripts/sync-hooks.sh` / `scripts/sync-codex-hooks.sh` per the existing v0.7.x/v0.8.0 release cadence.
- **Doctor as the loophole-closer that ships with the mirror:** the Phase 8a `health-checks.sh` additions (resolvable reviewer, UI screenshot path, `pre-push` wired to `run-all.sh`, receipt grammar present) propagate so every public-template consumer audits its own gate completeness.

---

## Appendix A — Rejected / partially-rejected findings (one line each)

- **A-1 — Confidence floor default-ON (rejected; default-OFF kept).** The critique recommended flipping the `confidence` floor on by default to prevent a day-one false hard-block from training bypass. Rejected because the same concern is now answered by the per-turn `TRELLIS_REVIEW_OVERRIDE` escape (the per-turn override, adopted): an operator hit by a false `critical` has an audited exit without disabling the Stop hook, so a calibration knob that silently downgrades real criticals is the larger risk on day one. The Phase 2a real-project smoke-test flips the floor on if blocks prove flaky — empirical, not default.
- **A-2 — Add code-review/ui-verify as `run-all.sh` gates (rejected; gap accepted).** The critique offered, as one option for the AntiGravity coverage hole, adding code-review and ui-verify as actual merge gates so they hard-block cross-harness. Rejected: a non-deterministic LLM reviewer and a flaky visual/screenshot check are a poor fit for a deterministic, must-pass merge gate (they would either reintroduce the flaky-hard-block risk NEW-1 at the merge boundary or have to fail-open, defeating the point). The honest scoping — SOFT on AntiGravity, "route risky/UI/edit-heavy runs through Claude or Codex" — is kept instead, consistent with `inheritance.md`'s existing posture.
