# 2026-05-18 — Anthropic best-practices: bundled rollout in one PR

## Context

Anthropic published [How Claude Code works in large codebases](https://claude.com/blog/how-claude-code-works-in-large-codebases-best-practices-and-where-to-start) in 2026-05. A gap analysis against Trellis surfaced ten changes worth adopting, grouped into three phases (1A-C, 2D-F, 3G-J). The work crosses canonical templates, hooks, skills, commands, the cross-project audit, the schema, and the engineering manual.

The Trellis PR-size hard cap is 800 lines. The bundle totals 844 insertions / 8 deletions across 25 files. Each individual phase is well under the cap, but the rollout was deliberately requested as **one** PR — splitting it would force version-coupled changes (e.g., the `obsolete-rules` audit references the codebase-map convention; the `/explore` command's gitignore-fragment sentinel bump and the `propose-rules` hook share the same `parent-hook-drift` audit update) to land across multiple PRs in a specific order, with each intermediate state failing a different audit.

## Decision

Ship all ten changes as one PR, accept the 52-line breach of the 800-line hard cap, and let this ADR carry the carve-out per the `core-rules/skills/process-gate/references/pr-hygiene.md` "PR size" rules.

## Why splitting harms clarity

1. **Versioning is per release, not per change.** `core-rules/VERSION` bumps 0.2.0 → 0.3.0 because the bundle adds new canonical surfaces (`propose-rules.sh`, `/explore`, `approved_mcps` schema field). Splitting forces either three minor bumps in a week or one bump in the last sub-PR with the preceding ones unversioned — both confuse downstream consumers running `scripts/upgrade.sh`.

2. **Cross-phase audit dependencies.** The Phase 1B codebase-map convention is enforced by the Phase 2F cross-project-process-audit extension. Landing 1B first means one weekly audit cycle where the rule exists on paper but doesn't audit. Landing 2F first means the audit references a convention that does not yet exist in `engineering-process.md` §9.1. The two must move together to keep the rules ↔ audit invariant.

3. **Single conceptual unit.** The diff is the Trellis-side of "what does the Anthropic best-practices guide say to do, sized for solo-DRI use?" Reviewers (here: the maintainer, asynchronously across days) read it once against the source post and either accept the framing or reject it. Splitting forces them to re-derive that framing N times.

4. **Sentinel and gitignore coupling.** Phase 3G bumps the `.gitignore` fragment sentinel to include `primer/explore commands`. Phase 3I (`propose-rules.sh`) and Phase 3J (`approved_mcps`) ride that same fragment. Sequenced PRs would update the same sentinel three times back-to-back, generating noise in every downstream project's next `onboard-project.sh --repair` run.

5. **Single CHANGELOG entry.** Releases group related changes. Three entries with the same provenance ("Anthropic best-practices guide, 2026-05") and overlapping commit ranges would clutter the changelog without adding information.

## Carve-outs explicitly listed

- **PR-size hard cap (800 lines).** Actual diff: 852 lines (844 + 8). Carve-out granted by this ADR.
- **Branch name.** Worktree branch `claude/pedantic-hermann-2eb126` is the agent-supplied worktree name, renamed at push time to `docs/anthropic-best-practices` to satisfy `<type>/<kebab-slug>`.
- **Commit subject length.** Six original subjects ran past 72 characters; all are amended to ≤72 before push. Bodies retain the full context.

## Consequences

- **Visible.** One PR, 11 commits (10 phases + release bump). Each phase is a self-contained commit so `git log -p` is reviewable in passes.
- **Reversible at the commit boundary.** Any single phase can be reverted independently via `git revert <sha>` without touching the others. The only structural coupling is the codebase-map rule ↔ audit pair (1B + 2F) — reverting one without the other restores the silent-drift state and should be done together.
- **Audit posture unchanged.** The PR-size warning is logged, the ADR is referenced by SHA in the PR description, and the audit rubric is satisfied. Future PRs hitting the hard cap require their own ADR; this one does not cover them.

## Related

- Source blog: <https://claude.com/blog/how-claude-code-works-in-large-codebases-best-practices-and-where-to-start>
- Gap analysis lives in this PR's description.
- `core-rules/skills/process-gate/references/pr-hygiene.md` — the carve-out rule this ADR exercises.
