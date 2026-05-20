# ADR: AntiGravity as Trellis's third first-class harness, with native hooks deferred

## Status

Accepted (2026-05-20)

## Context

Google launched AntiGravity 2.0 and the `agy` CLI in May 2026. AntiGravity reads the same `AGENTS.md` + `.agents/{rules,skills,primers}/` surface that Codex already populates under Trellis — meaning a meaningful portion of multi-harness inheritance is solved "for free" by extending the existing Codex parity machinery. The only AntiGravity-specific filesystem path documented in Google's codelabs is `.agents/workflows/<name>.md` for slash commands (Codex uses `.agents/commands/<name>.md`; Claude Code uses `.claude/commands/<name>.md`).

The hook story is less settled. Public documentation as of 2026-05-20 does not describe a workspace hook envelope for AntiGravity, and the standalone Antigravity 2.0 desktop app does not expose a hooks UI in its Customizations panel. The community-maintained `fpozoc/antigravity-hooks` GitHub repository is mis-named — it ships prompt-template fragments, not event-hook scripts. Internal inspection of the bundled Antigravity-IDE main.js does reveal hook-related code paths (an "Agent Hooks Configuration" view, event names `PreToolUse`/`PostToolUse`/`Stop`, and a `hooks.json` reader inside `geminiDir`) — but those are not documented as a public, supported workspace surface today, and the standalone Antigravity 2.0 app does not expose them via UI. Treating undocumented internals as a stable contract would mean shipping config files that may stop working at the next AntiGravity release without warning.

The control plane needs to decide:

1. Whether to admit AntiGravity to the `harnesses` enum at all (or wait for Google to ship a documented hook API first).
2. If admitting, what to seed and what to defer.

## Decision

1. **Admit AntiGravity to the `harnesses` enum now**, with the canonical value `antigravity`. No `agy` alias is added in this phase; aliasing is reserved for a possible Phase 2 if it proves useful.

2. **Seed the shared `AGENTS.md` + `.agents/{rules,skills,primers}/` surface** whenever `antigravity` is enabled — identical to the Codex parity behavior, since both engines read the same files. The `seed_codex_parity` block in `scripts/onboard-project.sh` is refactored into three gates:
   - **Shared surface gate:** `pg_has_harness codex || pg_has_harness antigravity` → seed `AGENTS.md`, `.agents/rules/`, `.agents/skills/`, `.agents/primers/INDEX.md`, `.agents/skills/process-gate-local/local.config.sh`.
   - **Codex-only gate:** `pg_has_harness codex` → seed `.codex/hooks.json`, `.codex/hooks/*.sh`, `.agents/commands/*.md` slash commands.
   - **AntiGravity-only gate:** `pg_has_harness antigravity` → seed `.agents/workflows/*.md` slash commands.

3. **Defer native-hook integration for AntiGravity.** No `.antigravity/` tree is created. No new bats tests are added. The deferral is recorded as a "Known gap" subsection in `core-rules/inheritance.md` so it is visible to every operator reading the inheritance contract. The deferral is empirical (UI doesn't expose a hooks surface; workspace path not documented), not architectural — Trellis is ready to ship a hook envelope as soon as Google publishes the contract.

4. **Document the gap surface.** `CHANGELOG.md`, `README.md` (FAQ), `engineering-process.md` §5.5, and the onboard script's final-echo block all mention that AntiGravity hook enforcement is deferred — operators are not surprised when `.antigravity/` does not appear in their project trees.

## Rationale

- **Don't block Trellis adoption on a Google deliverable.** The shared `.agents/` surface delivers most of the inheritance value today (rules + skills + workflow slash-commands); refusing to add AntiGravity until hooks ship would gate users on a Google roadmap item with no estimated date.
- **No premature commitment.** Seeding speculative hook structures based on undocumented internals would create files that ship before the contract is finalized — exactly the failure mode `core-rules/deferred.md` exists to prevent. Trellis's "Rule of Three" applies even within a single harness's feature set.
- **Symmetry with the Codex parity rollout.** The `2026-05-04-codex-parity-rollout.md` ADR established that adding a harness is a parent-layer change shipped together. AntiGravity is smaller — no new hook envelope, no new sync script — but follows the same shape: schema enum + onboard script + rollout scripts + docs in one parent-layer landing.
- **Easy to re-open.** When Google publishes a hook API (or formally exposes the existing one), a follow-up ADR will reference this one, extend the onboard script's AntiGravity-only branch, and unblock Tier-1 / Tier-2 enforcement parity. No commitments made today preclude that path.

## Consequences

- `scripts/lib/trellis.config.schema.json` accepts `"antigravity"` in the `harnesses` array.
- `scripts/onboard-project.sh` seeds the three-gate shape (shared / codex / antigravity).
- `scripts/rollout-process-gate-skill.sh`, `scripts/rollout-feature-skills.sh`, and `scripts/rollout-presets.sh` honor the shared-surface gate.
- `core-rules/templates/project.gitignore.fragment` sentinel bumps from "7-skill set + presets + primer/explore commands" to "7-skill set + presets + primer/explore commands + antigravity workflows"; the `current_sentinel` literal in `onboard-project.sh` updates in lockstep.
- `core-rules/skills/process-gate/scripts/check-pr.sh` regex and `references/pr-hygiene.md` allowlist both add `antigravity` as a permitted branch-name type.
- `core-rules/VERSION` bumps from `0.3.1` to `0.4.0` (minor bump — new canonical surface).
- AntiGravity sessions in `agy` rely on parent rules + skills + Tier-3 git hooks for enforcement. Tier 1 + 2 hook protection is unavailable until Google publishes a workspace hook API.
- The `cross-project-process-audit` and `parent-hook-drift` audits do **not** require updates: their canonical hook lists are Claude-specific (or Codex-specific via `.codex/`), and the absence of `.antigravity/` is the intended state, not drift.

## References

- `core-rules/inheritance.md` "Multi-harness support" section and "Known gap: AntiGravity native hooks deferred" subsection.
- `docs/adr/2026-05-04-codex-parity-rollout.md` — the analogous prior decision for Codex.
- `docs/adr/2026-05-08-claude-md-primary-not-agents-md.md` — confirms `CLAUDE.md` primacy across harnesses (the `AGENTS.md → CLAUDE.md` symlink pattern this ADR continues to use).
- `scripts/onboard-project.sh` — the three-gate refactor of the parity block.
- Google AntiGravity codelabs — workspace `.agents/` layout, `workflows/` convention.
