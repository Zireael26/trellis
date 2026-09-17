# Ship Spec 049 as one reviewed release change

**Status:** accepted for the 1.3.0 release preparation.

## Context

Spec 049 delivers the Trellis-owned user skill store across Claude, Codex, and Pi.
The PR diff is ~2,650 lines across 28 files, which exceeds the 800-line hard cap
under `references/pr-hygiene.md`.

## What is actually in the range

The production code is focused and concise:
- `scripts/skills.sh` — the `trellis skills` CLI command (`list`, `import`, `link`, `unlink`).
- `scripts/lib/skill-roots.sh` — canonical root definitions for shared and per-harness user skills.
- `scripts/lib/surface-plan.sh` — validation rules and planning for release skills linked into user surfaces.
- `scripts/lib/health-checks.sh` and `scripts/doctor.sh` — doctor health checks for user skill integrity, collision detection, and stray/duplicate exposure.
- `scripts/sync-to-template.sh` — mirror publication projection for release user links.
- `core-rules/inheritance-manifest.json` — manifest links declaring Trellis release skills for user surfaces.

The vast majority of the line count consists of thorough test coverage and spec/validation records:
- Test suites: `skills-command.bats`, `doctor.bats`, `surface-plan.bats`, `user-surface.bats`, `mirror-lint.bats`, `sync-to-template-dry-run.bats`, and `setup-runbooks.bats`.
- Spec-kit and validation documentation under `specs/049-trellis-skill-store/`.

## Decision

Ship Spec 049 as a single coherent release unit.

Splitting would ship the manifest links without the doctor check to catch collisions, or
without the `trellis skills import` command required to safely migrate the existing third-party
and user skills they replace. Shipping these components separately would leave an incomplete,
unsafe intermediate state where harness-level collisions or missing skills could break operator
workflows. The components form an indivisible migration and safety unit.

## Consequences

The PR retains an ADR exemption for the branch size. All functionality, migration paths,
and safety gates are reviewed and validated together as a unified minor release (1.3.0).
