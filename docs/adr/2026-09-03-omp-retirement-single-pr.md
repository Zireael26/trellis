# OMP retirement ships as one PR

- Status: accepted
- Date: 2026-09-03

## Context

`trellis-instance` retires the `omp` harness entirely and promotes `pi` to the sole foreman/worker harness alongside `claude` and `codex`. The change touches **15,521 lines across ~40 files**: `core-rules/omp` (1,603-line adapter + global agents/skills), `core-rules/hooks` review/session routing (`code-reviewer.sh` 597-line pi ladder, `herdr-foreman-session.sh` pi wording, `propose-rules`/`decision-receipt`/`env-echo`/`session-context`), `core-rules/usage-federation` lane catalog + `config.py` + 8 transcript adapters/fixtures, `scripts/materialize-scheduled-task.sh` harness validators, 5 `rollout-*` scripts, `conductor.wf.js` roster, `herdr`/`usage-federation` fixtures, and `lane-freshness` poller + `scheduled-tasks/lane-freshness`.

The breakdown is the reason for this ADR.

## Decision

Ship as a single PR rather than splitting.

A harness is an atomic cross-cutting surface: `inheritance-manifest.json` declares the harness set, `surface-plan.sh` validates it, `attach`/`doctor` render it, `lane-catalog.json` + `config.py` + `contract.py` + transcript adapters enforce it, and `code-review`/`herdr-foreman` route through it. A half-removed harness leaves those layers inconsistent between PRs — e.g. `attach` would accept `pi` while `lane-catalog` still advertises `omp` lanes, or `doctor` would report `omp` as healthy while `surface-plan` rejects it. Splitting along file-type seams (hooks in one PR, lanes in another, tests in a third) would land an intermediate state where no single PR is green and the next PR must reason about the previous PR's partial surface.

Splitting also harms clarity and safety: the 1,603-line `trellis.ts` adapter, its 1,651-line test, and the 892-line `omp.py` projector are deleted in the same commit that introduces the `pi` ladder and `pi-transcripts` sources, so reviewers see the before/after as one diff. A harness retirement is not feature work that benefits from incremental delivery; it is a cutover.

## Consequences

- One PR carries the full 15.5k-line diff, over the 800-line soft cap, but the executable surface change is the harness set itself (`claude,codex` + `user`); tests and fixtures are evidence that the cutover is complete and `load_catalog` + `bats` remain green.
- No intermediate PR leaves the repository in a half-removed harness state.
- `CHANGELOG.md` records the cutover as `v1.0.0-rc.46` with the pi triad, GLM+DeepSeek strip, and lane-freshness poller.

## Status

Accepted. The single-PR cutover is the only safe shape for an atomic harness retirement.
