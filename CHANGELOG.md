# Changelog

All notable changes to Trellis are documented here.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project uses Conventional Commits. Versioning is rolling — entries are dated, not numbered, since Trellis is the meta-repo for personal projects rather than a published artifact.

## Unreleased

## [v0.3.1] — 2026-05-19

Primer freshness loop. Makes the v0.3.0 primer system close the loop on
updates and usage without per-turn LLM cost.

### Added

- **`inject-primer-index` SessionStart hook (both harnesses).** Deterministic
  shell hook reads `<canonical-root>/.claude/primers/INDEX.md`, computes
  drift per primer (FRESH / WARM / STALE / MISSING_PATHS / UNREACHABLE_PIN
  / BROKEN / NO_ENTRY_POINTS) via `git rev-list <pinned>..HEAD -- <entry-points>`,
  and injects a compact ~300-token INDEX-with-flags block into every session.
  Skips silently when INDEX absent (opt-in projects unaffected). Wired in
  `core-rules/templates/claude-settings.json` and `core-rules/codex/hooks.json`
  alongside `session-context.sh` and `post-compact-context.sh`. Bats
  coverage at `core-rules/hooks/tests/inject-primer-index.bats` (7 cases).
  Added to the `parent-hook-drift` canonical manifest (now Ten canonical hooks).
- **`primer-drift` Tier-1 scheduled task.** Weekly Monday 12:15 (after
  preset-drift). Same checks as the SessionStart hook, fleet-wide, one
  audit file per run. Backstop for projects no one's touched recently.
  `scheduled-tasks/primer-drift/{prompt.md,targets.md}`. Scheduled-tasks
  README count bumped to Sixteen.
- ADR `docs/adr/2026-05-19-primer-freshness-loop.md` documenting the
  SessionStart-injection + weekly-backstop architecture and rejected
  alternatives (post-commit LLM hook, PostToolUse dirty-marker, eager-
  load every primer).

### Changed

- **Parent `core-rules/CLAUDE.md` Feature-primers block:** "lean toward
  loading" → "MUST read primer when task names a primer-listed
  feature/dir". Auto-injection means INDEX is always in context; the rule
  shifts "available" → "used". Loading policy line updated:
  agent-decides → auto-injected (since v0.3.1).
- `core-rules/VERSION` 0.3.0 → 0.3.1.

## [v0.3.0] — 2026-05-18

Anthropic large-codebase best-practices bundle plus the late-2026-05 follow-ups
(frontend-quality references, Codex `[features].hooks` rename, brand-sweep
cleanup, Obsidian dep retire). Tagged on the public mirror at
`__GITHUB_USER__/trellis@v0.3.0`.

### Added

- **Anthropic best-practices bundle — ten changes mapping the Claude blog onto Trellis.** Ten commits land the changes from the 2026-05 Anthropic "How Claude Code works in large codebases" guide that Trellis didn't already cover. Grouped into three phases:
  - **Phase 1 (quick wins).** (1A) `permissions.deny` baseline in `core-rules/templates/claude-settings.json` covering `node_modules`, `.next`, `dist`, `build`, `out`, `target`, `vendor`, `.venv`, `__pycache__`, every cache dir, and every lockfile, plus a new `scripts/rollout-settings.sh` that jq-merges canonical + project-local entries idempotently. New projects pick it up via `onboard-project.sh`; existing projects converge via the rollout script. (1B) Mandatory `## Codebase map` section in project `CLAUDE.md` for any project with ≥5 top-level directories — one line per top-level dir, role only; sub-threshold projects skip the section. Convention added to `engineering-process.md` §9.1 and the `AGENT_ONBOARD_PROJECT.md` Step 4 playbook. (1C) New quarterly `obsolete-rules` audit (Q1/Q2/Q3/Q4 1st 09:00). Walks `core-rules/CLAUDE.md`, presets, `engineering-process.md`, and every project `CLAUDE.md` + `gotchas.md`; classifies each rule as load-bearing / model-compensating / harness-compensating / stylistic / process; surfaces model-or-harness-compensating rules that have aged out of usefulness. Removal-only audit — never proposes additions; gotchas-rollup retains promotion ownership.
  - **Phase 2 (monorepo scoping).** (2D) `stop-verify.sh` is now subtree-aware: when every changed file in a turn sits under one subdirectory carrying its own manifest (`package.json`, `go.mod`, `pyproject.toml`, `Cargo.toml`), the hook `cd`s into that subtree before typecheck / lint / test. Mixed-subtree changes and missing nested manifests fall back to repo root. Escape hatch: `PROCESS_GATE_FORCE_ROOT=1`. Patched in both Claude and Codex parity copies. (2E) Optional `scope.json` convention for project-local skills — `{ "paths": ["services/**"], "reason": "..." }` next to a non-canonical `SKILL.md` limits auto-invocation to matching paths. Engine-unenforced; agent-followed via `core-rules/CLAUDE.md` directive. Canonical skills stay global. (2F) `cross-project-process-audit` extended with check 10: warning when a ≥5-top-level-dir project lacks a `## Codebase map` heading; info when the heading exists but the list is stub-only; warning when the listed dirs no longer exist.
  - **Phase 3 (subagent + LSP + governance).** (3G) New `/explore <subsystem>` canonical slash command — read-only subagent maps a subsystem and writes the summary to `<canonical-root>/.claude/primers/_explore/<slug>-<sha>.md`; editing session loads it before touching code. Ephemeral counterpart to `/primer`. Symlinked into `.claude/commands/` and `.agents/commands/` by `onboard-project.sh`; sentinel bumped to "7-skill set + presets + primer/explore commands". (3H) LSP recommendation for polyglot projects added to `engineering-process.md` §8.3 — install per-language LSP binaries (`gopls`, `typescript-language-server`, `pyright`, etc.) plus a Claude Code LSP plugin for ≥2-language repos. Recommendation only; no audit, no hook coupling. (3I) New experimental Tier-2 hook `propose-rules.sh`. Opt-in via `PROCESS_GATE_PROPOSE_RULES=1`. Dispatches a one-shot `claude -p --max-turns 1` subagent at end of turn to read transcript tail + project `gotchas.md` and propose a single candidate entry (or `NONE`). Three layers of cost control: opt-in gate, `stop_hook_active`/pure-chat guards, and a transcript-tail heuristic that only fires the subagent when an explicit-correction signal ("no", "don't", "actually", "stop doing", "that's wrong", "never do") appears in the last ~200 lines. Pairs with `gotchas-rollup` (monthly) — propose-rules surfaces n=1 candidates per turn; the rollup clusters n≥3 into parent-rule promotions. `parent-hook-drift` accepts absence of a settings.json entry for experimental hooks. (3J) Optional `approved_mcps` field added to `scripts/lib/trellis.config.schema.json` and the example config — array of `{ name, purpose, scope: "fleet" | "per-project" }` entries. Documentation-only today; reserved for a future parked `mcp-drift` audit. Sized for solo-DRI use: explicit allowlist now, audit when n=2 projects diverge.
- **Frontend-quality references bundle** — four sibling reference docs at `core-rules/skills/process-gate/references/web-{perf,a11y,seo,agent-readiness}.md`, synthesizing Lighthouse (Performance, Accessibility, Best Practices, SEO, Agentic Browsing), web.dev Learn Accessibility / pa11y / axe-core, Google's AI Optimization Guide, and Cloudflare's `isitagentready.com` scorecard into a single Trellis-stamped checklist. Closes the previously-empty frontend-guidelines slot (gate #6 in `process-gate/SKILL.md:36` is the destination for any future automation). Three-way disagreement on `llms.txt` between Google (debunks), Lighthouse Agentic Browsing (rewards), and Cloudflare (rewards implicitly) explicitly resolved in `web-agent-readiness.md` — Trellis adopts `llms.txt` as a hedge for projects with substantive public docs and skips the speculative WebMCP / MCP-card / x402 / UCP / ACP protocol layer until n=2 ships an agent-served API. a11y tool stance is **axe-core canonical, pa11y fallback for static-HTML projects** — matches TGSC's existing project-local `check-a11y.sh`; rationale (WCAG 2.2 support, Deque-maintained, Chrome DevTools Issues panel, `@axe-core/react`, shared rule engine with Lighthouse) documented in `web-a11y.md`. Automation (Lighthouse CI, axe-core in CI) remains deferred per `core-rules/deferred.md:57` until Rule of Three; the new references cite that deferral so future agents don't accidentally promote prematurely. Wired in via one cross-profile section appended to `stack-profiles.md` and a new §9.6 in `engineering-process.md`. No parent `CLAUDE.md` edit, no new skill / command / hook / scheduled audit / primer. Capture date 2026-05-16; `web-perf.md`/`web-seo.md`/`web-a11y.md` re-verify semi-annually, `web-agent-readiness.md` quarterly (fastest-shifting axis).

### Changed

- **Codex feature-flag rename: `[features].codex_hooks` → `[features].hooks`.** Codex CLI 0.129+ emits a deprecation warning when it sees `[features].codex_hooks` in `$CODEX_HOME/config.toml`; the canonical key is now `[features].hooks`. The legacy key still works as an alias but should not be used in new installs. Doc references updated across `README.md`, `AGENT_ONBOARD_PROJECT.md`, `engineering-process.md` (§5a hook-tier section and §10.3 onboarding checklist), `core-rules/inheritance.md`, and the `scripts/onboard-project.sh` post-onboarding echo. Each touch points new operators at `hooks = true` while noting the alias for users who still have the legacy key in their config. The bash function name `seed_codex_hooks()` (script-internal — copies `.codex/hooks/*.sh`) is unaffected — it describes a category of hooks, not the deprecated TOML key.
- **Retired Obsidian dependency from the `monthly-documentation-audit` description.** The Neev-scoped monthly doc audit in `scheduled-tasks/README.md` no longer claims to check "Obsidian sync" — the audit covers EPM currency and ADR coverage; doc-write target is the project filesystem (already mounted), so the MCP path is unnecessary overhead.
- **Brand sweep follow-ups.** `security-gate-plan.md` had three stale "SE Core" / `se-core` mentions left over from the 2026-05-12 rebrand (§1 purpose paragraph, §3 infrastructure reuse line, §11 per-project flow); all three now read "Trellis" / "Trellis instance". Historical references in `CHANGELOG.md` (rebrand entry), audit filenames under `audits/`, ADR PR URLs at `__GITHUB_USER__/se-core`, and `scripts/rollout-rebrand.sh` (whose purpose is the migration itself) are intentionally preserved.

### Added

- **Feature primer system — canonical `commands/` slot + opt-in primer infra.** A primer is a compact, hand-validated context document (~150 lines max) pinned to a commit SHA. Future sessions read the primer instead of re-exploring the feature — the goal is replacing 350K-token exploration runs with 30–50K-token primer-assisted runs for testing, debugging, and extending stable features. Three new canonical commands at `core-rules/commands/{primer.md,primer-refresh.md,primer-check.md}` — first occupants of the new `core-rules/commands/` distribution slot, parallel to `core-rules/skills/`. Templates at `core-rules/commands/templates/{primer-template,primer-index-template}.md`. Reference docs at `docs/primers/{plot-md-integration,handoff-integration}.md`. Parent `core-rules/CLAUDE.md` gains a `## Commands` section and a Feature primers block (cascades to all managed projects via `@`-import — no per-project CLAUDE.md edits required). `scripts/onboard-project.sh` extended to symlink the three commands into `.claude/commands/` and `.agents/commands/` (Codex parity) and seed an empty `.claude/primers/INDEX.md` (copied, not symlinked — primer INDEX is project-state and tracked in git, individual primers too). `core-rules/templates/project.gitignore.fragment` sentinel bumped to `(7-skill set + presets + primer commands)`; covers the three new symlinked commands per harness while explicitly preserving primer content files. `scripts/sync-to-template.sh` SYNC_PATHS gains `core-rules/commands/` and `docs/primers/`. Primer files resolve via `git rev-parse --git-common-dir` (canonical-root convention, same pattern as `context-log.md`) so worktree sessions see the same primer set as the main checkout. The three context-log hooks remain untouched. Opt-in per project: projects without `.claude/primers/INDEX.md` skip primer logic entirely. Forward-looking integrations (`active_primers:` in local `plot.md`, post-commit refresh hooks) documented in `docs/primers/` but not implemented in this phase. Each preset is a single markdown file at `core-rules/presets/<name>.md` that layers on top of the parent rules. Two example presets ship: `compliance-strict` (mandatory ADR per architectural change, two-human PR sign-off, no `--no-verify`, hard-fail secrets, mandatory CHANGELOG, deploy SHA encoding) and `experimental-loose` (direct commits to main, skip the spec-kit pipeline, optional CHANGELOG, PR-size warn-only, test coverage optional; time-bound). Projects opt in via the `presets` array in their own `<project>/.trellis.config.json`. Schema (`scripts/lib/trellis.config.schema.json`) carries an optional `presets` field with kebab-case validation + uniqueItems. Per-project preset selection is read directly by `onboard-project.sh` and `scripts/rollout-presets.sh` from each project's own `<project>/.trellis.config.json` — not via the parent `config-load.sh` loader (presets are a per-project concept). `scripts/rollout-presets.sh` (new, idempotent) installs the declared symlinks under `.claude/rules/preset-<name>.md` and `.agents/rules/preset-<name>.md` and prunes ones no longer declared. `onboard-project.sh` extended with `seed_presets()` (no-op when no project-local config). `core-rules/templates/project.gitignore.fragment` sentinel bumped to `(7-skill set + presets)`; covers `preset-*.md` symlinks via glob. `scheduled-tasks/preset-drift/` runs weekly (Mon 12:00) catching declared-vs-installed mismatches across the registry. Narrative documentation: `engineering-process.md` §14.7 + `core-rules/inheritance.md` extended with the skills-vs-presets symmetry table. (spec-kit Phase D, plan: `docs/plans/2026-05-12-spec-kit-adoption.md`)

### Changed

- **Repo rebrand: SE Core → Trellis.** Full sweep across config files, env vars, JSON keys, scripts, scheduled-tasks prompts, core-rules docs, audit prompts, hook libs, husky pre-push, ADRs, and root docs. Highlights: `se-core.config.json` → `trellis.config.json` (with schema + example); JSON root key `se_core_root` → `trellis_root`; env vars `SE_CORE_ROOT`, `SE_CORE_CONFIG`, `SE_CORE_CONFIG_PATH`, `SE_CORE_TEMPLATE_DIR`, `SE_CORE_SKIP_SECURITY_BASELINE`, `SE_CORE_ALLOW_MAIN_PUSH`, `SE_CORE_NO_JQ_DEGRADE` → `TRELLIS_*`; in-project symlink `.claude/rules/se-core.md` → `.claude/rules/trellis.md` (existing projects re-linked by `scripts/rollout-rebrand.sh`); hardcoded `__USER_HOME__/projects/se-core/` paths → `__TRELLIS_PATH__/`; public mirror remote → `__GITHUB_USER__/trellis`; default `TRELLIS_TEMPLATE_DIR` → `$USER_HOME/projects/trellis`; brand text "SE Core" / "Software Engineering Core" → "Trellis" everywhere except (a) historical audit filenames under `audits/`, (b) the historical PR URLs in `docs/adr/0001-...md` (the legacy `__GITHUB_USER__/se-core` GitHub repo still resolves those references).

### Added

- **Versioning + upgrade flow (spec-kit Phase A)** — `core-rules/VERSION` is the canonical semver pin (initial value `0.1.0`). Optional `trellis_version` field added to `scripts/lib/trellis.config.schema.json` for downstream consumers to pin against. `scripts/upgrade.sh` compares the pinned version to the highest `v*.*.*` tag on `origin` (or `template.remote` fallback) and prints a stat diff of `core-rules/`; `--opt-in` rewrites the pin in config and revalidates against the schema; `--check` exits non-zero on drift for CI. `scheduled-tasks/version-drift/` runs weekly (Mon 11:45) classifying each project as current / no-pin / patch-drift / minor-drift / major-drift / ahead / malformed — only major-drift is critical. `core-rules/templates/trellis.config.json.example` is the first reference config template. `config-load.sh` exports `TRELLIS_VERSION`. `core-rules/VERSION` bumped from `0.1.0` to `0.2.0` on the rebrand commit; `v0.2.0` is the next release tag on the public mirror (`v0.1.0` was already taken by the 2026-05-08 meta-audit wrap-up). (spec-kit Phase A, plan: `docs/plans/2026-05-12-spec-kit-adoption.md`)
- **Eval harness runner** — `scripts/run-evals.sh` discovers fixtures under `core-rules/evals/<project>/<id>/`, invokes `claude -p` headless per fixture (n times each, default 5), evaluates `expected.json` assertions against `git status --porcelain` of the seed snapshot, and emits a pass-rate JSON. Supports `--check` (schema-only validation; no model invocation), `--dry-run`, `--filter <glob>`, and `--changed-only`. Workflow `.github/workflows/evals.yml` always runs `--check` on PRs and runs the full suite when `ANTHROPIC_API_KEY` is wired (deferred to P4.5). (P4.3)
- **Eval fixture schema** — `core-rules/evals/SCHEMA.md` is the canonical specification; `core-rules/evals/template/` is a real, executable reference fixture. Required manifest fields: `version`, `id`, `project`, `prompt`. (P4.1)
- **Neev fixture set** — `core-rules/evals/neev/` ships 10 fixtures grounded in `audits/2026-04-26-parent-hook-drift.md` and `audits/2026-05-01-audit-rollup.md`: 6 install-canonical-hook regressions (block-destructive, post-edit-verify, stop-verify, truncation-check, ui-verify, code-review-subagent), 2 rebase-drifted-hook regressions (session-context, block-destructive), 1 husky pre-push-guard install, and 1 negative fixture protecting the project-local `check-module-boundary.sh`. Runner now passes `--add-dir <repo-root>` so fixtures can reference the live canonical via repo-rooted paths. (P4.2)
- **Tgsc fixture set** — `core-rules/evals/tgsc/` ships 10 canonical-conformance fixtures using the same install/rebase/pre-push pattern as neev. Negative fixture protects the project's `CLAUDE.md` from being modified during hooks work. (P4.2)
- **curat.money fixture set** — `core-rules/evals/curat.money/` ships 10 canonical-conformance fixtures using the same install/rebase/pre-push/preserve-claude-md pattern as neev/tgsc. (P4.2)
- **vericite fixture set** — `core-rules/evals/vericite/` ships 10 canonical-conformance fixtures using the same install/rebase/pre-push/preserve-claude-md pattern as the rest of the fleet. (P4.2)
- **lume fixture set** — `core-rules/evals/lume/` ships 10 canonical-conformance fixtures using the same install/rebase pattern. The pre-push fixture targets `.githooks/pre-push` (native git hooks) instead of `.husky/pre-push`, since lume is a Unity project without husky per `core-rules/inheritance.md`. (P4.2)
- **akaushik.org fixture set** — `core-rules/evals/akaushik.org/` ships 10 canonical-conformance fixtures using the same install/rebase/pre-push pattern as neev. Negative fixture protects the project's `CLAUDE.md` from being modified during hooks work. (P4.2)

### Changed

- **audit-report-rollup picks up eval pass-rate** — `scheduled-tasks/audit-report-rollup/prompt.md` now reads `core-rules/evals/.results/<timestamp>.json` files and surfaces a per-project eval pass-rate table with 7-day trend. Implements the "promote rule changes only if pass-rate doesn't regress" guidance from audit §6 P4.4. Until `ANTHROPIC_API_KEY` is wired (P4.4a), the rollup emits a placeholder noting the harness shipped but runtime data is unavailable. (P4.4)
- **Pre-merge eval gate** — `.github/workflows/evals.yml` adds a `gate` summary job combining validate + run results into one status check. The job passes when validate succeeds and run either succeeded or skipped (no secret); fails when run failed (fixture regression). Maintainer wires `evals / gate` as a required status check on `main` per the P4.5 plan instructions. (P4.5)
- **`core-rules/CLAUDE.md`: drop stale `[new policy]` marker** — Definition of done section was tagged "[new policy]" when the receipts-required + Stop-hook-completion-guard rules first landed in 2026-04. Two weeks later, standing policy. First parent-rules edit shipped through the Phase 4 eval gate. (P4.6)
- **Eval schema** — flipped `bare:` default from `false` to `true` for reproducible runs (host isolation). Runner re-injects parent rules via `--append-system-prompt`. Added optional `max_budget_usd` field as per-run dollar cap. (P4.3)

### Fixed

- **Bats CI runner** — `.github/workflows/bats.yml` now configures a default git identity before invoking the suite. Without it, every `setup_project_dir` aborted with `fatal: empty ident name … not allowed` and all 34 tests failed. (P4.1a)
- **Shellcheck CI gate** — `.github/workflows/shellcheck.yml` runs at `--severity=warning` so info+style findings (SC1091 source-file not-following, SC2181 `$?` style, SC2016 single-quoted regex, etc., all intentional patterns) don't fail the gate. The four SC2295 (info) sites — unquoted `${var#$X/}` — are fixed in `scripts/onboard-project.sh`, `scripts/conformance-check.sh`, `scripts/rollout-process-gate-skill.sh`, `core-rules/skills/process-gate/scripts/check-bypass.sh`. (P4.1a)

## [v0.1.0] — 2026-05-08

First tagged checkpoint. Covers everything up to the close of the
2026-05-08 Trellis meta-audit remediation cycle (Phases 0–3 of
`audits/2026-05-08-se-core-meta-audit-plan.md`).

### Added

- **Security-gate skill** — `core-rules/skills/security-gate/` shipped through six phases per `security-gate-plan.md`:
  - Phase 1 — baseline engine + `web-next` profile (Semgrep + OSV-scanner + Gitleaks under a provider-neutral LLM triage layer; default backend: `simonw/llm`).
  - Phase 2 — diff mode + husky `pre-push` wiring; `scripts/onboard-project.sh` symlinks security-gate and runs initial baseline.
  - Phase 3 — quarterly `scheduled-tasks/security-baseline/` (host-pinned, fleet rollup with new/recurring/resolved deltas).
  - Phase 4 — `web-rag-llm` profile: prompt-injection + MCP-tool-misuse Semgrep rules; Garak wrapper.
  - Phase 5 — `unity-game` profile: C# rules covering PlayerPrefs credentials, save HMAC, BinaryFormatter, TLS bypass, hardcoded API keys, in-client IAP; project-local validator spec.
  - Phase 6 — Mode 3 red-team (`scripts/run-redteam.sh`, `prompts/redteam.md`, `references/redteam-runbook.md`) with per-run sign-off.
- **Codex parity** — root `AGENTS.md`, `.agents/` inheritance, canonical `.codex/` hooks, active-project rollout scripts. ADR documenting the oversized parent-layer Codex parity PR.
- **Schema + ADRs** — JSON schema for `trellis.config.json`; `docs/adr/0001-security-gate-stack-consolidation.md` (first ADR; size carve-out for the security-gate consolidation PR).
- **Onboarding installs Claude Tier 1+2 hooks** — `scripts/onboard-project.sh` now seeds `.claude/hooks/*.sh` and `.claude/settings.json` from a canonical template (`core-rules/templates/claude-settings.json`), mirroring `seed_codex_hooks`. (P2.1)
- **Bats regression suite** — `core-rules/hooks/tests/` covers the four Phase 1 hook fixes plus jq fail-closed across all 18 hooks; CI workflow `.github/workflows/bats.yml`. (P3.1)
- **Shared hook lib** — `core-rules/hooks/lib/deps.sh` exposes `_se_require_jq` (replaces the inline P1.5 block in 18 hooks) and `_se_project_dir`. `sync-hooks.sh` / `sync-codex-hooks.sh` / `onboard-project.sh` extended to ship the lib alongside scripts. (P3.5)
- **Self-hosted process-gate against the Trellis canonical clone** — `.claude/skills/process-gate-local/local.config.sh` declares the config stack profile so the gate runs cleanly on the Trellis canonical clone itself. First MERGEABLE verdict. (P3.4)
- **Prompt-shell linter** — `scripts/lint-prompt-shell-blocks.sh` + `.github/workflows/prompt-shell-lint.yml`: extracts ` ```bash` / ` ```sh` blocks from `scheduled-tasks/**/*.md` and `bash -n` syntax-checks each. (P3.9)
- **Audit file taxonomy** — documented 4-class taxonomy (regular audit, remediation report, plan, source audit) in `scheduled-tasks/README.md`; `audit-report-rollup` parser updated to treat each class separately. (P3.8)
- **Recon gap status snapshot** — `recon.md` Status as of 2026-05-08 table marks G1 shipped (TodoWrite-completion guard), G2/G3 skeleton, G4 policy + partial enforcement. (P3.11)
- **Six backfilled ADRs** under `docs/adr/`: bypass-tripwire weekday-only cadence, Tier 2 promotion criteria, test-health host-pinned vs. dep-sandbox walk-back, mypy regex bracket-escaping (fabricated-finding lesson), CLAUDE.md-primary-not-AGENTS.md (D1), rmrf-rule-absolute-outside-cwd (D3). (P3.10)
- **Spec-vs-impl conformance check** — `scripts/conformance-check.sh` + `.github/workflows/conformance.yml`: scans 14 spec docs for inline-code path refs, asserts each resolves at repo root or doc-relative. Current run: clean (114 refs, 0 misses). (P3.6)
- **Shellcheck CI** — `.github/workflows/shellcheck.yml` + `.shellcheckrc`. Resolved all 21 existing violations inline; new violations fail CI. (P3.2)
- **trellis.config.json schema validation on load** — `_pgcfg_validate()` in `scripts/lib/config-load.sh` tries `npx ajv` first, falls back to a jq-based check that enforces `required[]` + non-empty strings + `harnesses minItems=1`. Stripped configs error loudly with a list of missing fields. (P3.3)

### Changed

- Process-gate, onboarding, audits, and template sync now understand Claude Code plus Codex without dropping existing Claude Code hooks.
- `scripts/onboard-project.sh` — also symlinks `security-gate` (Claude Code + Codex paths) and runs the initial Mode 1 baseline at onboarding (`TRELLIS_SKIP_SECURITY_BASELINE=1` to opt out).
- `scheduled-tasks/parent-hook-drift/targets.md` — collapsed inline canonical hook list to single-source-of-truth reference (`core-rules/hooks/README.md` for names, `prompt.md` for matchers). Editing the canonical list now touches one file. (P3.7)
- `core-rules/hooks.md:21` — `block-destructive` rm-rf rule wording updated to "any **absolute path**, `~`, `$HOME`, or `..`" matching the post-P1.1 regex semantics. (P1.1 / D3)

### Fixed

- `core-rules/skills/process-gate/scripts/check-tests.sh` — replaced `[ ... ] && cmd` short-circuit with explicit `if`-block. Previous form returned non-zero from the `run_check` helper when `$worst` was already non-`pass`, which `set -e` propagated and aborted the gate before later checks ran.
- `core-rules/hooks/block-destructive.sh:42` — `rm -rf` rule now blocks absolute paths outside cwd (`rm -rf /Users/me/foo`, `rm -rf ~/work`, `rm -rf $HOME/cache`, `rm -rf ../sibling`). Earlier tail char-class missed any path beyond `/etc`-like roots. Allows `rm -rf .`, `rm -rf ./build`, `rm -rf node_modules`. (P1.1)
- `core-rules/hooks/block-destructive.sh:67-71` — DELETE-without-WHERE now triggers on terminated SQL (`DELETE FROM users;`). Earlier `[^;]*$` clause required no semicolon to EOL — the rule was dead code in production. Handles backticked / double-quoted / schema-qualified table names. (P1.2)
- `core-rules/hooks/stop-verify.sh` — TodoWrite check now runs **before** the dirty-tree skip. Pure-chat turns that close pending todos via TodoWrite no longer slip past the receipts-required guard. (P1.3)
- `core-rules/hooks/save-context-log.sh` — JSONL filter now distinguishes real user prompts (string content) from tool-result wrappers (array content with `tool_result` items). Adds envelope validation: `PROJECT_DIR` must be a directory and `transcript_path` (if present) must exist; loud failure on malformed envelope. (P1.4)
- **jq-missing now fails closed across all 18 hooks** — `if ! command -v jq; then exit 0` replaced with stderr install-help + `exit 1`. `TRELLIS_NO_JQ_DEGRADE=1` opt-out preserves graceful degradation with an audit-trail breadcrumb. (P1.5)

### Project-side (this loop session)

Per Phase 2's hook propagation + onboarding completeness work, the
following landed in fleet projects via per-project PRs: all 9 canonical
hooks + `settings.json` synced to neev, tgsc, akaushik.org, vericite,
lume; `.gitignore` discipline sweep on tgsc / vericite / akaushik
(curat.money deferred — broken husky pre-push shim); ~25 leaked global
Anthropic skills removed from `vericite/.agents/skills/`; akaushik's
`.gitignore` `.claude/` over-ignore corrected to allow per-file
unignore.

### Notes

- Phase 4 (eval harness) is paused per plan decision D4 — requires
  explicit human go-ahead. Phase 5 (strategic adoption) is opportunistic.
- curat.money rollout-process-gate-skill PR remains deferred (P0.2a):
  branch conflicts with main + dirty local worktree blocks safe sync.

## Conventions

- One entry per change. Dated section header `## [YYYY-MM-DD]` when cutting a checkpoint.
- Sections: Added · Changed · Deprecated · Removed · Fixed · Security.
- Each entry links the canonical artifact path so future readers can navigate from changelog to source without searching.
