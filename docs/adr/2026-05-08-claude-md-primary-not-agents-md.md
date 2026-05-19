# ADR: CLAUDE.md is the primary parent rules file; AGENTS.md is a symlink

## Status
Accepted (plan decision D1, recorded 2026-05-08 per plan task P3.10)

## Context

The 2026-05-08 Trellis meta-audit raised an "AGENTS.md inversion"
proposal in §5.4 / P5.3: rename / restructure parent rules so AGENTS.md
becomes the primary file, with CLAUDE.md as a symlink, on the theory
that AGENTS.md is the emerging cross-vendor standard (Codex, Cursor,
Aider, etc.) while CLAUDE.md is Anthropic-specific.

This was rejected at plan creation (decision D1). This ADR documents
why, so the proposal doesn't return as drift.

## Decision

CLAUDE.md remains the **primary** parent rules file. AGENTS.md is a
symlink to CLAUDE.md everywhere it appears (project roots, `.agents/rules/`
inheritance points). The audit's inversion proposal is **rejected**.

## Rationale

- **Inertia is real.** Every file in this repo, every audit prompt,
  every per-project memory cites `core-rules/CLAUDE.md` by path. The
  inversion would generate an enormous rename diff for a naming-only
  change with zero behavioral benefit.
- **Symlinks already work.** Codex / Aider / Cursor that look up
  `AGENTS.md` find a symlink to CLAUDE.md and read it identically. The
  cross-vendor standard is satisfied without inverting which file is
  the source.
- **Anthropic-specific naming is not the issue the audit thinks it is.**
  The maintainer is Claude-first; CLAUDE.md being the canonical name
  matches the day-to-day workflow. If the canonical name should change
  in the future, it should change to something neutral
  (e.g., `RULES.md`), not flip to AGENTS.md as the primary.

## Consequences

- `core-rules/CLAUDE.md` stays the source of truth.
- `scripts/onboard-project.sh` continues to seed `AGENTS.md` as a
  symlink to `CLAUDE.md` for Codex-enabled projects.
- The audit's P5.3 entry is permanently rejected — this ADR is the
  paper trail.
- Reopening the question requires either (a) the maintainer changing
  workflows away from Claude-first or (b) genuine behavioral divergence
  between Claude and other harnesses that justifies separate files.

## References

- 2026-05-08 Trellis meta-audit §5.4 / §6 P5.3 (the inversion proposal)
- Plan decision D1
- `core-rules/CLAUDE.md`, `core-rules/AGENTS.md` (symlink to CLAUDE.md)
- `scripts/onboard-project.sh` `seed_symlink "CLAUDE.md" "$PROJECT/AGENTS.md"`
