# Changelog

All notable changes to Trellis are documented here.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project uses Conventional Commits. Versioning is rolling — entries are dated, not numbered, since Trellis is a meta-repo for the personal-projects process regime rather than a published artifact.

## Unreleased

## [v0.3.0] — 2026-05-18

### Added

- **Feature primer system — canonical `commands/` slot + opt-in primer infra.** A primer is a compact, hand-validated context document (~150 lines max) pinned to a commit SHA. Future sessions read the primer instead of re-exploring the feature — the goal is replacing 350K-token exploration runs with 30–50K-token primer-assisted runs for testing, debugging, and extending stable features. Three new canonical commands at `core-rules/commands/{primer.md,primer-refresh.md,primer-check.md}` — first occupants of the new `core-rules/commands/` distribution slot, parallel to `core-rules/skills/`. Templates at `core-rules/commands/templates/{primer-template,primer-index-template}.md`. Reference docs at `docs/primers/{plot-md-integration,handoff-integration}.md`. Parent `core-rules/CLAUDE.md` gains a `## Commands` section and a Feature primers block (cascades to all managed projects via `@`-import — no per-project CLAUDE.md edits required). `scripts/onboard-project.sh` extended to symlink the three commands into `.claude/commands/` and `.agents/commands/` (Codex parity) and seed an empty `.claude/primers/INDEX.md` (copied, not symlinked — primer INDEX is project-state and tracked in git, individual primers too). `core-rules/templates/project.gitignore.fragment` sentinel bumped to `(7-skill set + presets + primer commands)`; covers the three new symlinked commands per harness while explicitly preserving primer content files. `scripts/sync-to-template.sh` SYNC_PATHS gains `core-rules/commands/` and `docs/primers/`. Primer files resolve via `git rev-parse --git-common-dir` (canonical-root convention, same pattern as `context-log.md`) so worktree sessions see the same primer set as the main checkout. The three context-log hooks remain untouched. Opt-in per project: projects without `.claude/primers/INDEX.md` skip primer logic entirely. Forward-looking integrations (`active_primers:` in local `plot.md`, post-commit refresh hooks) documented in `docs/primers/` but not implemented in this phase.

---

> This CHANGELOG is new as of the primer-system addition. Earlier Trellis features (versioning + upgrade flow, eval harness, spec-kit phases A–D, presets, rebrand from SE Core to Trellis) shipped before this file existed; reconstructing those entries is deferred.
