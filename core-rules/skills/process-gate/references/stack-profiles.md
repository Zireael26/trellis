# Reference — Stack profiles

The canonical six gates (PR hygiene, secrets, bypass, tests, docs, stack profile) apply to every project. Stack-profile validators handle stack-specific concerns the canonical six don't cover.

Profiles are project-declared. Setting `PROCESS_GATE_STACK_PROFILE` in `local.config.sh` makes the verdict's "Stack profile" row meaningful.

## Profiles in current use

### `web-next` — Next.js / Vercel projects

Typical validators contributors add at the project level:

- `check-tokens.sh` — design-token fidelity (no raw hex outside the token file, no off-scale spacing).
- `check-a11y.sh` — `pnpm test:a11y` against the running preview (axe-core).
- `check-input-font-size.sh` — iOS-zoom guard (input fields ≥ 16px to prevent zoom on focus).
- `check-phrases.sh` — forbidden-phrase list (brand voice).

These are project-specific implementations; the canonical layer doesn't ship them. TGSC's `.claude/skills/process-gate/scripts/` is a worked example.

### `monorepo-pnpm` — pnpm-workspace monorepos

Common validators:

- `check-module-boundary.sh` — package import-boundary enforcement (e.g., `@neev/orders` may not import from `@neev/inventory`).
- `check-package-graph.sh` — circular-dep detection.
- `check-scope-allowlist.sh` — Conventional-Commit scope must match a workspace package name.

Neev is the worked example.

### `service-node` — Node.js HTTP services / APIs

Typical project-local validators contributors might add (none ship canonically — n=0 in the registry today):

- `check-route-surface.sh` — diff the OpenAPI / route table; flag breaking changes without a version bump.
- `check-env-sync.sh` — `.env.example` lists every key consumed by the running service.
- `check-migration-safety.sh` — DB migration adds defaults / handles rollback for any non-additive change.
- `check-dockerfile.sh` — Dockerfile lint (hadolint), pinned base images, no root user at runtime.

These are sketches, not canon. **Promotion to canonical requires the Rule of Three** (`engineering-process.md` §14.1); this profile exists in the registry's taxonomy so backend-shaped projects have a place to land their validators while waiting for n=3.

### `service-python` — Python HTTP services / APIs

Typical project-local validators (same n=0 status as `service-node`):

- `check-route-surface.sh` — same purpose as the Node variant; framework-specific (FastAPI, Flask, Django).
- `check-env-sync.sh` — `.env.example` parity check.
- `check-migration-safety.sh` — Alembic / Django migration audit; flags non-additive changes without a defaults-and-backfill plan.
- `check-dockerfile.sh` — Dockerfile lint, pinned base image, non-root runtime user.

Same Rule-of-Three caveat: nothing canonical ships under `service-python` until three independent backend-shaped projects converge on a shared validator shape.

### `service-go` — Go HTTP services / APIs

Reserved (n=0). Mirrors `service-node` and `service-python`: route-surface diffing (gRPC reflection / OpenAPI), `.env.example` sync, migration safety (sqlc / goose / atlas), Dockerfile lint (hadolint), pinned base images, non-root runtime user.

Same Rule-of-Three caveat: slot exists in the taxonomy so future single-service Go projects have a landing pad for project-local validators.

### `monorepo-polyglot` — multi-language monorepos

Worked example: `clusterbid-console`. Shape: Go workspace (`services/`, `pkg/`, `tools/`) + pnpm workspace (`clients/`, `ts/`) + Python (`py/` + service trees) coordinated by a root Makefile orchestrator. Trellis hits the orchestrator (`make vet|lint|test`) — language-specific tooling stays inside the Makefile, keeping `local.config.sh` language-agnostic.

Candidate project-local validators:

- `check-orchestrator-coverage.sh` — every language subtree is reached by the root `make vet|lint|test`; no orphan trees.
- `check-go-work.sh` — every directory under `services/<go-service>/`, `pkg/`, `tools/` has a matching `use` directive in `go.work`, and vice-versa.
- `check-proto-contract.sh` — generated stubs in Go + TS + Python (`buf generate` outputs) are fresh against `proto/*.proto`; flag if generation lags source.
- `check-ci-subtree-routing.sh` — every language subtree has a corresponding GH Actions `paths:` filter; cross-language workflow leakage flagged.
- `check-pyproject-discipline.sh` — Python files only under sanctioned roots (project-specific allowlist; e.g., for clusterbid: `services/inference-runner/`, `services/fine-tuning-orchestrator/`, `py/`).

Lume-style carve-out: single adopter today (clusterbid-console), validators stay project-local until n=2. The canonical six gates still apply.

Long-form reference: `references/monorepo-polyglot.md`.

### `monorepo-go` — Go-only workspace monorepos

Reserved (n=0). Sibling to `monorepo-polyglot` for the Go-only case. Distinct slot so Rule-of-Three count is independent — a future Go-only workspace project should land here, not be lumped in with polyglot.

Candidate project-local validators:

- `check-go-work.sh` — every directory under `services/`, `pkg/`, `tools/` has a matching `use` directive in `go.work`, and vice-versa.
- `check-module-graph.sh` — `go mod graph` over all workspace modules; flag import cycles or layering violations (e.g., `pkg/*` may not import from `services/*`).
- `check-public-api-drift.sh` — `apidiff` (or `gorelease`) against last release tag for every `pkg/*` module; flag breaking changes without a major-version bump.
- `check-go-vet-coverage.sh` — every workspace module is reached by `make vet`; no orphan modules.

Same Rule-of-Three caveat as `service-node`/`service-python`: nothing canonical ships under this profile until three independent Go-workspace projects converge on a shared validator shape.

### `unity` — Unity / native game projects

Common validators:

- `check-meta-files.sh` — every asset has a paired `.meta` file.
- `check-asset-bundle.sh` — `.unity` and `.prefab` files don't have merge-conflict markers.
- `check-no-binary-bloat.sh` — diff size sanity for binary assets.

Lume is the only current adopter; canonical Unity profile defers to Rule of Three (n=1 today).

### `native-other` — Rust / Go / Python / etc.

Project supplies its own validators. No canonical defaults.

### `n-a` — explicit opt-out

Used when stack-specific gates legitimately don't apply. The verdict row renders as `➖ n/a`. Rare; document the reason in the project's `gotchas.md` and the registry-row notes.

## Adding a stack-profile validator

In the project's `process-gate-local/local.config.sh`:

```bash
PROCESS_GATE_STACK_PROFILE="web-next"
PROCESS_GATE_STACK_VALIDATORS=(
  "scripts/check-tokens.sh"
  "scripts/check-a11y.sh"
  "scripts/check-input-font-size.sh"
  "scripts/check-phrases.sh"
)
```

Relative paths are resolved from the harness-local extension directory first:

- Claude Code: `<project>/.claude/skills/process-gate-local/`
- Codex: `<project>/.agents/skills/process-gate-local/`

If a validator is not found there, `run-all.sh` falls back to the canonical
skill symlink (`<project>/.claude/skills/process-gate/` or
`<project>/.agents/skills/process-gate/`) so promoted canonical validators can
still be referenced by relative path.

Each validator script must:

- Exit `0` for pass, `1` for fail, `2` for warn.
- Print findings to stdout in the format `<file>:<line>: <message>` so they merge into the verdict's Findings section.
- Honor `--range=<gitspec>` if relevant.

## Promoting a profile to canonical

When three independent projects adopt a close variant of the same validator, promote per `engineering-process.md` §14 (Rule of Three):

1. Move the validator into `$TRELLIS_ROOT/core-rules/skills/process-gate/scripts/`.
2. Add a corresponding reference under `references/`.
3. Update this `stack-profiles.md` to reflect the new canonical profile.
4. Run the extended `parent-hook-drift` audit to verify byte-identity across projects.

Profiles waiting for a third witness queue in `core-rules/deferred.md`.

## Lume carve-out

Lume (Unity, 3D) is the sole `unity`-profile project. Stack-specific validators are project-local until n=2. The canonical six gates still apply.

Lume's row in `registry.md` documents the carve-out. The extended `parent-hook-drift` audit treats `PROCESS_GATE_STACK_PROFILE="unity"` with no canonical scripts as expected, not drift.
