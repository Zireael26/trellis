# Recon: Neev + TGSC engineering process catalog

Purpose: inventory engineering-process artifacts in the two reference projects, classify each as LIFT / LEAVE / DEFER, and justify what lands in the parent layer vs. stays project-local vs. waits for a third data point.

Method: two parallel Explore subagents, one per project, each produced a structured catalog of rules, hooks, skills, tooling, process artifacts, CI, and gotchas with an initial classification. This document consolidates and reconciles both catalogs.

Rule of Three discipline: n=2 is below the safe threshold for extraction. For each candidate, we require (a) presence in both projects and (b) clear evidence it would apply to any of the five active projects. When in doubt → DEFER.

---

## Summary table

| # | Item | Neev | TGSC | Decision |
|---|------|------|------|----------|
| 1 | Plan before code (no code until plan approved) | ✓ | ✓ | **LIFT** |
| 2 | Multi-file refactors in phases (max 7 files/phase) | ✓ | ✓ | **LIFT** |
| 3 | Delete dead code before refactoring files >300 LOC | ✓ | ✓ | **LIFT** |
| 4 | Sub-agent dispatch for tasks touching >5 files | ✓ | ✓ | **LIFT** |
| 5 | Re-read files at ctx ≥40% or after 25 messages (compaction defense) | ✓ | ✓ | **LIFT** |
| 6 | Chunked reads for files >1500 LOC (offset/limit) | ✓ | ✓ | **LIFT** |
| 7 | Re-read before AND after every edit | ✓ | ✓ | **LIFT** |
| 8 | Exhaustive search on rename/signature change | ✓ | ✓ | **LIFT** |
| 9 | Never delete file without verifying references | ✓ | ✓ | **LIFT** |
| 10 | "Yes / do it / push" → execute, no replay | ✓ | ✓ | **LIFT** |
| 11 | Study referenced code, match patterns exactly | ✓ | ✓ | **LIFT** |
| 12 | Log corrections to `gotchas.md` | ✓ | ✓ | **LIFT** |
| 13 | Stop after two failed fixes, re-read, rethink | ✓ | ✓ | **LIFT** |
| 14 | Senior-dev override on "simplest approach" dogma | ✓ | ✓ | **LIFT** |
| 15 | Minimal comments, no robotic blocks | ✓ | ✓ | **LIFT** |
| 16 | No imaginary scenarios / speculative code | ✓ | ✓ | **LIFT** |
| 17 | Proactive `/compact` + save to `context-log.md` | ✓ | ✓ | **LIFT** |
| 18 | Tool result truncation at 100K → narrow scope | ✓ | ✓ | **LIFT** |
| 19 | Use `monitor` for long-running streams (never tail/poll) | ✓ | — | **LIFT** (user explicit) |
| 20 | Work from raw error data, don't guess | ✓ | — | **LIFT** |
| 21 | `block-destructive.sh` PreToolUse hook | ✓ | ✓ | **LIFT** |
| 22 | Pre-commit hook (typecheck + lint, staged scope) | ✓ | ✓ | **LIFT** |
| 23 | Session-start context injection hook | ✓ | — | **LIFT** |
| 24 | PreCompact → save context-log.md hook | ✓ | — | **LIFT** |
| 25 | SessionStart post-compact recovery hook | ✓ | — | **LIFT** |
| 26 | PostToolUse per-file lint on Edit/Write | implied | ✓ | **LIFT** |
| 27 | PostToolUse truncation-check on Grep/Bash | — | ✓ | **LIFT** |
| 28 | Stop hook with full verification (typecheck+lint+test) | pre-push only | ✓ | **LIFT** |
| 29 | Conventional commits (enforced) | ✓ (scoped) | ✓ (unscoped) | **LIFT** (unscoped default) |
| 30 | Husky manager for git hooks | ✓ | ✓ | **LIFT** |
| 31 | lint-staged pattern for pre-commit | implied | ✓ | **LIFT** |
| 32 | CI baseline: install → lint → typecheck → test → build | ✓ | ✓ | **LIFT** |
| 33 | Playwright E2E as a test tier | ✓ | ✓ | **LIFT** (pattern) |
| 34 | `gotchas.md` as a project-local file (pattern) | ✓ (1 entry) | ✓ (referenced) | **LIFT** (pattern) |
| 35 | `process-gate` skill (pattern; contents vary) | ✓ | ✓ | **LIFT** (wrapper) |
| 36 | Design source-of-truth doc (pattern; contents vary) | ✓ `design.md` | ✓ `DESIGN.md` | **LIFT** (pattern only) |
| 37 | Two-perspective review (perfectionist vs pragmatist) | ✓ | — | **DEFER** |
| 38 | Fresh-eyes / new-user testing persona | ✓ | — | **DEFER** |
| 39 | Bug autopsy after fix (explain root cause) | ✓ | — | **DEFER** |
| 40 | PR size soft-target 400 / hard-ceiling 800 | — | ✓ | **DEFER** |
| 41 | ADR numbered-sequential doc folder | — | ✓ | **DEFER** |
| 42 | Tech-spec-check CI job blocking merges | ✓ | — | **DEFER** |
| 43 | PR-size-check CI job | ✓ | — | **DEFER** |
| 44 | Module boundary check / cross-module import block | ✓ | — | **LEAVE** (Neev monorepo) |
| 45 | `tenant_id` check script + schema rule | ✓ | — | **LEAVE** (Neev multi-tenancy) |
| 46 | Commitlint scopes list (orders, inventory, …) | ✓ | — | **LEAVE** (Neev packages) |
| 47 | Lighthouse CI budgets (a11y 1.0, SEO 0.95, CLS 0.05) | — | ✓ | **LEAVE** (TGSC marketing site) |
| 48 | Tailwind v4 `@theme` + `tokens:sync` script | — | ✓ | **LEAVE** (TGSC design system) |
| 49 | Forbidden-phrases brand-voice enforcement | — | ✓ | **LEAVE** (TGSC voice) |
| 50 | Sentry error tracking config | — | ✓ | **LEAVE** (TGSC observability) |
| 51 | Vercel CLI preview deploy job | — | ✓ | **LEAVE** (TGSC hosting) |
| 52 | Neev Sprint Zero P0/P1/P2/P3 bug list | ✓ | — | **LEAVE** (Neev-specific) |
| 53 | Makefile with docker-compose orchestration + port offsets | ✓ | — | **LEAVE** (Neev local dev) |
| 54 | axe-core a11y tests in CI | — | ✓ | **DEFER** |

54 items. 36 LIFT. 7 DEFER. 11 LEAVE.

---

## LIFT bucket — detail

These belong in the parent `CLAUDE.md` or parent hook set. Evidence from both projects except where noted.

### Process directives (CLAUDE.md content)

**Planning discipline** — plan-before-code, execute-only-on-approval, multi-file refactors in phases of max 7 files, interview on non-trivial features. Both projects. Strongest signal.

**Edit safety** — re-read before every edit, re-read after, chunked reads >1500 LOC, exhaustive search on rename (direct calls + type refs + string literals + dynamic imports + re-exports + barrel files + test mocks). Both projects. Directly attacks the "claimed done but missed a callsite" failure pattern.

**Context management** — sub-agent dispatch for >5 files, re-read files at ctx ≥40% or after 25 messages, proactive `/compact`, write state to `context-log.md`, tool-result truncation handling. Both projects.

**Code quality override** — ignore "try the simplest approach" dogma when architecture is flawed; minimal comments; no imaginary scenarios. Both projects.

**Self-correction** — log corrections to `gotchas.md`, stop after two failed fixes and re-read top-down, treat user-pointed-to code as a spec. Both projects.

**Communication** — "yes / do it / push" executes without replay, work from raw error data (Neev explicit). Both projects in substance.

**Monitor rule** — user explicit request; Neev already has it. For any long-running stream use `monitor`, never `tail -f` or polling. LIFT.

### Hooks (all cross-cutting, both projects have an instance)

**Fast-local tier** (every turn):
- `block-destructive.sh` (PreToolUse Bash) — both projects, near-identical intent. Blocks `rm -rf /`, force pushes, hard resets, DB DROP, `.env` reads.
- `post-edit-verify.sh` (PostToolUse Write/Edit/MultiEdit) — TGSC explicit, Neev via pre-commit. Per-file lint on modified files. Blocks agent on failure.
- `truncation-check.sh` (PostToolUse Grep/Bash) — TGSC only but clearly cross-cutting (it's a Claude Code failure mode, not a project one). LIFT.
- `session-context.sh` (SessionStart) — Neev only, but the pattern is universal: inject branch, uncommitted changes, recent commits, reminders to read `gotchas.md` + `context-log.md`. LIFT.
- `save-context-log.sh` (PreCompact) — Neev only. Universal value. LIFT.
- `post-compact-context.sh` (SessionStart compact) — Neev only. Universal value. LIFT.

**Heavy-gated tier** (wrap-up):
- `stop-verify.sh` (Stop) — TGSC has this at the Stop event (typecheck + lint + tests, with `stop_hook_active` infinite-loop guard). Neev runs the same checks at pre-push. Stop is earlier and directly solves the "claimed done" problem; lift TGSC's version as the default.

**Git boundary tier** (husky):
- `pre-commit` — lint-staged (typecheck + lint on staged files only). Both projects.
- `pre-push` — full verification as safety net. Neev has it; TGSC delegates to Stop hook. LIFT pre-push as optional belt-and-suspenders.
- `commit-msg` — commitlint conventional-commits. Both projects. LIFT with unscoped type list by default.

### Patterns (the shape, not the contents)

**`gotchas.md`** — both projects have or reference one. Parent should require every project to maintain one and to read it at session start.

**`process-gate` skill wrapper** — both projects have a `process-gate` skill with different contents. The wrapper (a skill that runs project-specific checks before PR open) is cross-cutting; the contents are not.

**Design source-of-truth doc** — Neev has `design.md`, TGSC has `DESIGN.md`. Pattern is cross-cutting; contents are not.

**CI baseline** — both projects run install → lint → typecheck → unit tests → build, plus E2E. Parent specs this baseline; individual projects add domain-specific jobs.

---

## DEFER bucket — detail

Seen once, or seen in both with meaningful differences. Promote to LIFT after a third active project confirms.

**Two-perspective review** (Neev only) — present perfectionist critique vs. pragmatist acceptance for non-trivial work. Valuable but unproven cross-project.

**Fresh-eyes / new-user testing persona** (Neev only) — adopt new-user persona when testing own output. Useful but unclear if it fits every project class.

**Bug autopsy after fix** (Neev only) — explain root cause and whether a category-level prevention is possible. Good practice but requires meaningful bug volume to be useful; smaller projects may not benefit.

**PR size soft-target 400 / hard-ceiling 800** (TGSC only) — useful default but Neev's monorepo PRs are often larger by necessity. Numbers may need per-project tuning.

**ADR numbered-sequential doc folder** (TGSC only) — good pattern. Neev uses tech-specs in a different layout. Defer until a third project validates the shape.

**Tech-spec-check CI job** (Neev only) — blocks merges without a tech spec for sizeable changes. Worth lifting eventually; currently very Neev-EPM-coupled.

**PR-size-check CI job** (Neev only) — same logic as item 40 but as a CI gate. Defer with its sibling.

**axe-core a11y tests in CI** (TGSC only) — TGSC is a marketing site with a11y as a launch gate. Other active projects may not need this floor; revisit per project.

---

## LEAVE bucket — detail (project-specific)

Neev-specific:
- Module boundary checker — Neev monorepo architecture rule (@neev/orders cannot import @neev/inventory).
- `tenant_id` checks — Neev multi-tenancy invariant.
- Commitlint scope enum — Neev's 16 package names.
- Makefile docker-compose orchestration with +20000 port offsets — Neev local dev.
- Sprint Zero P0/P1/P2/P3 bug list — Neev MVP state.

TGSC-specific:
- Lighthouse CI budgets (a11y 1.0, best-practices 0.95, SEO 0.95, CLS 0.05) — TGSC marketing-site launch gate.
- `tokens:sync` + Tailwind v4 `@theme` — TGSC design system implementation.
- Forbidden-phrases brand-voice enforcement — TGSC voice rules.
- Sentry config — TGSC observability choice.
- Vercel CLI preview deploy — TGSC hosting choice.

---

## Gaps — what neither project has (net-new additions)

Driven by user-reported failure patterns rather than extraction. Flagged so we don't pretend these were "lifted."

**G1. Stop-hook TodoWrite-completion guard.** If `TodoWrite` has items in `in_progress` or `pending` when the agent tries to stop, block with a specific reason listing the incomplete items. Neither project has this — it depends on TodoWrite telemetry we introduce at parent level. Purpose: defeats "claimed done while todos still open."

**G2. Code-review subagent gate.** On edit-heavy turns (threshold TBD in Phase 2), spawn a subagent running the code-review skill against the diff before allowing the Stop event. Findings either get resolved or explicitly acknowledged. Neither project has this — user has been manually invoking code review; automation is net new.

**G3. UI-verify default behavior.** For UI-visible changes in dev-server-able projects, spin up the dev server, take a computer-use screenshot, attach it. Fallback: headless Playwright. Neither project has this — UI testing has been ad-hoc.

**G4. Receipts-required completion format.** When declaring done, include verification command + exit code + relevant diff lines. Written rule in parent CLAUDE.md; Stop hook enforces the underlying checks. Neither project formalizes the "receipts" presentation.

These four go into the parent with clear labelling as "new policy, not extracted."

### Status as of 2026-05-08

| Gap | Status | Where | Plan refs |
|---|---|---|---|
| G1 — TodoWrite-completion guard | **shipped** | [`core-rules/hooks/stop-verify.sh`](core-rules/hooks/stop-verify.sh) Step 1 — TodoWrite check; runs before the dirty-tree skip per P1.3. Bats coverage in [`core-rules/hooks/tests/stop-verify.bats`](core-rules/hooks/tests/stop-verify.bats). | P1.3, P3.1 |
| G2 — Code-review subagent gate | **skeleton** | [`core-rules/hooks/code-review-subagent.sh`](core-rules/hooks/code-review-subagent.sh) exists and is wired in canonical `settings.json` template. Edit-heavy threshold and subagent dispatch logic are placeholders. | P5.4 / P5.10 |
| G3 — UI-verify default behavior | **skeleton** | [`core-rules/hooks/ui-verify.sh`](core-rules/hooks/ui-verify.sh) exists and is wired. Dev-server spawn + computer-use screenshot path is not yet invoked automatically. | P5.10 |
| G4 — Receipts-required completion format | **policy + partial enforcement** | Written rule in [`core-rules/CLAUDE.md`](core-rules/CLAUDE.md) "Definition of done". Stop hook enforces the underlying TodoWrite check (G1) but does not yet format-check the receipts presentation itself. | P5.10 |

This is a snapshot, not a rewrite of the original gap list. The
analytical history is preserved above; new status rows go below the
**Status as of YYYY-MM-DD** heading on subsequent updates.

---

## Scope stats

- Neev CLAUDE.md: ~30 KB, ~35 distinct rules in § 0-9 + sizable project reference appendix. Bloat risk: high.
- TGSC CLAUDE.md: ~3.5 KB, ~15 rules. Appropriately lean.
- Parent target: <5 KB. Lift the rules; leave the project-reference appendices in each project.
- Hook count: 8 Neev + 4 TGSC → ~8 cross-cutting hook specs at parent (the union of lifted items).
