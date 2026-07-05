# Reference — Docs discipline

Authoritative source: `engineering-process.md` §9 (Documentation standards).

## What the gate checks

| Check | Posture |
|---|---|
| `CHANGELOG.md` updated when code under tracked dirs changed | **fail** if missing, **warn** if `### Unreleased` exists but no entry added |
| `gotchas.md` updated when commits matched the gotcha-pattern (corrections, surprising discoveries, bug-fix postmortems > 2h) | **warn** — gate suggests; doesn't block |
| ADR added when commits touch architectural-trigger paths (declared in local.config.sh) | **fail** if trigger path changed without an ADR delta or referenced ADR |
| Project `CLAUDE.md` updated if rules changed (new commands, new conventions) | **warn** |
| `README.md` `## Quick start` runs as written if any quick-start commands changed | **warn** (manually verify) |

## CHANGELOG.md

Required at project root for every active project. Format: Keep a Changelog 1.1.0 (Unreleased section + dated releases).

The gate enforces the *mechanical floor* (file present; touched when code changed; a new entry line added — the `### Unreleased`/`- ` warn). The *doctrine* behind the number — semver as a promise, the tag as source of truth, entries curated by impact and written with the change — lives in **`core-rules/references/versioning.md`**. Consult it whenever a change involves a version bump or a public-interface change.

Code changes that must update `CHANGELOG.md`:

```bash
# Default trigger paths — override in local.config.sh
PROCESS_GATE_CHANGELOG_PATHS=(
  "src/**" "app/**" "lib/**" "components/**" "packages/**"
  "scripts/**" "content/**"
)
```

PRs that only touch tests, docs, CI config, or lockfiles: changelog entry not required (but allowed).

If `CHANGELOG.md` is missing entirely: **fail** with instructions to seed it.

## ADRs

Architecture Decision Records. Currently parked at parent layer (Rule of Three not met) — TGSC and Neev use different shapes. Project-local until promoted.

If the project declares ADR triggers in `local.config.sh`:

```bash
PROCESS_GATE_ADR_TRIGGERS=(
  "next.config.*" "middleware.*" "package.json" "tsconfig.json"
  "drizzle.config.*" "prisma/schema.prisma"
)
PROCESS_GATE_ADR_DIR="docs/adr"
```

A change to any ADR-trigger path without:
- A new file in `$PROCESS_GATE_ADR_DIR/`, OR
- A reference in the commit message body to an existing ADR number (`Refs: ADR-0042`)

…is a **fail**.

## gotchas.md

Required at project root. The gate doesn't fail on missing gotcha entries (they're discovered post-hoc), but it warns when commit messages contain phrases that suggest a gotcha entry would be useful:

- "turns out", "surprised", "took two hours", "weird interaction", "incompatible with"
- Reverts of recent commits (`git revert <sha>` where `<sha>` is < 7 days old)

Ignore the warning if the situation truly didn't merit a gotcha. Otherwise add the entry.

## EPM / engineering-process.md changes

Changes to the *parent* `engineering-process.md` happen in the Trellis canonical repo, not in projects. Out of scope for project-level process-gate.

Changes to *project-local* engineering-process docs (e.g., TGSC's `docs/EPM.md`) are project-specific. If declared:

```bash
PROCESS_GATE_PROJECT_EPM="docs/EPM.md"
```

…changes that touch process trigger paths without an EPM update emit a **warn**.

## Receipts in PR description

Per `engineering-process.md` §7, the PR description's "Test plan" + "Receipts" sections must include:

- Verification commands run.
- Exit codes.
- Diff lines or PR-link summary.

This gate's PR-description check (in `pr-hygiene.md`) covers presence; the contributor is responsible for content fidelity.

## Project README

Don't gate on `README.md` content quality (out of scope), but **fail** if any of these are inconsistent:

- `README.md` "Quick start" references commands that don't exist in `package.json` / `Makefile` / equivalent.
- `README.md` "Requirements" mentions a Node version that contradicts `package.json` `engines.node` / `.nvmrc`.

## Templates

Default project file templates live in `$TRELLIS_ROOT/core-rules/templates/`:

- `gotchas.md` — seed format for new projects.
- `context-log.md` — hook-managed; gitignored.

Onboarding (see `engineering-process.md` §10) seeds these via `onboard-project.sh`.
