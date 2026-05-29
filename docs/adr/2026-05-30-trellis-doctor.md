# 2026-05-30 — Trellis doctor: unified inheritance health-check + repair

## Context

Trellis governs its active projects through an **inheritance mechanism** — a symlink (`<project>/.claude/rules/trellis.md` → canonical `core-rules/CLAUDE.md`), an `@`-import fallback in each project `CLAUDE.md`, and parallel skills / `.agents/` / `.codex/` surfaces. The load-bearing invariant is also the dangerous one: **silent drop**. If a symlink target or import path does not resolve, Claude Code drops the instruction with no error, no warning, no log line. A project silently runs unparented.

Two drift incidents in one working session motivated this ADR:

1. **`curat.money` was running with zero parent rules.** It had no `.claude/rules/trellis.md` symlink at all, its `@`-import pointed at a dead cross-machine path (`/Users/helios/claude/se-core-template/...` — an old name on a different machine), and it was missing the full canonical skill + command set. None of this surfaced until checked by hand.
2. **The canonical checkout was left on a feature branch.** Because every project symlinks to the canonical working tree at a fixed path, a canonical checkout on a feature (or dirty) branch silently feeds *every* project stale rules. No existing tool checks this.

The machinery to detect and repair drift already exists, but it is **fragmented**:

- **Diagnostics** — eight scheduled audits (`cross-project-process-audit`, `parent-hook-drift`, `version-drift`, `preset-drift`, `primer-drift`, `autonomy-drift`, `registry-blacklist-health`, `test-health`). They run weekly, passively, and are **LLM-prompt-interpreted** (non-deterministic, slow, not runnable on demand).
- **Treatments** — idempotent, never-clobber repair scripts (`onboard-project.sh`, `sync-hooks.sh`, `sync-codex-hooks.sh`, `rollout-settings.sh`, the other `rollout-*.sh`).
- **Update flow** — `upgrade.sh` manages the `trellis_version` pin (read-only; `--opt-in` adopts the latest tag) but does **not** verify that adopted rules actually reached the projects.

Nothing ties check → fix into one on-demand command, nothing makes the mechanical checks deterministic, and nothing runs automatically right after an update — the exact moment drift is introduced.

## Decision

Build **`trellis doctor`**: a deterministic, on-demand health-check + repair command that unifies the existing check and fix engines behind one front-end, runs automatically (read-only) after every update, and ships with an agent-followable upgrade guide.

Principles:

1. **Reuse, don't reimplement.** Extract a shared deterministic check library that both `doctor` and the scheduled audits call — one source of truth for "what healthy looks like."
2. **Deterministic core.** Mechanical checks become a bash script (fast, reliable, no LLM variance). LLM judgment stays in the scheduled-audit prompts, layered on top of the scripted checks.
3. **Fix = delegate.** `--fix` calls the existing idempotent treatments (`onboard-project.sh`, `sync-hooks.sh`, `rollout-settings.sh`), inheriting their never-clobber guarantee rather than re-deriving repair logic.
4. **Safe by default.** `doctor` is read-only; `--fix` is explicit; the post-update auto-run is check-only.

## What it checks

**Tier 0 — global preconditions (new; no existing audit covers these):**

- The **canonical clone** is on `main` and clean. The clone to probe is `$TRELLIS_ROOT` resolved from `trellis.config.json` — **not** doctor's cwd, because doctor itself runs from worktrees (it is being built in one right now). The check uses `git -C "$TRELLIS_ROOT" …`; a naive cwd check false-positives. On-main + clean are the load-bearing conditions (a feature/dirty canonical silently poisons every project's inheritance — incident #2). Being *ahead of* `origin/main` is normal for the source-of-truth clone and is never an error; *behind* origin is at most INFO.
- `conformance-check.sh` passes (doc path refs resolve).
- `VERSION` is coherent with the latest `CHANGELOG` entry.

**Tier 1 — per active project (`registry.md` minus `blacklist.md`):**

- `.claude/rules/trellis.md` exists **and resolves to the current canonical path** (catches stale / cross-machine targets — incident #1).
- The `@`-import in the project `CLAUDE.md` resolves and matches the current canonical path (catches dead imports — incident #1).
- Skills + commands symlinks resolve (full canonical set, not a subset).
- Harness-conditional artifacts per the project's own harness config — Codex: `AGENTS.md`, `.agents/rules`, `.agents/skills`, `.codex/hooks`; AntiGravity: `.agents/workflows`.
- Hook freshness (reuse `parent-hook-drift` logic) and `settings.json` hook wiring.
- `trellis_version` pin lag vs canonical `VERSION`.

Each Tier-1 line already has logic inside an existing audit; the work is consolidating it into the shared library, not inventing checks.

## Modes and severity

- `trellis doctor` — read-only diagnosis. Per-project `✓ / ⚠ / ✗` table + summary + exit code (`0` healthy, non-zero on any ERROR). The `brew doctor` shape.
- `trellis doctor --fix [--project <name>] [--dry-run]` — apply repairs by delegating to the idempotent treatments. `--dry-run` prints exactly what `--fix` would change, per project, touching nothing. Symlink / skill / command repair (via `onboard-project.sh`) runs automatically; **hook re-sync is gated** behind an explicit `--fix-hooks` flag / confirmation because it changes enforcement behavior. Anything unfixable locally (e.g. GitHub branch protection) is reported as a manual action, never guessed. `--fix` mutates real project repos and is the high-stakes surface: it lands only after P1 is verified green, and every `--fix` test runs against **constructed fixture projects with deliberate drift**, never the live registry.
- Severity: **ERROR** (inheritance broken / canonical off-main — project gets no parent rules) · **WARN** (degraded — missing skill, hook drift, missing `@`-import fallback, missing harness parity) · **INFO** (version-pin lag — rules current via symlink, pinned features trail).

## Update integration and the agent guide

- `upgrade.sh` gains a final step: after a version is adopted, auto-run `doctor` (read-only); on drift, print the exact `doctor --fix` command. Auto-run is check-only — projects are never mutated unprompted.
- `engineering-process.md` gains an **"Updating Trellis"** section: pull → merge to `main` → `upgrade.sh --opt-in` → `doctor --fix` → verify.
- `docs/UPGRADING.md` — a deterministic runbook written **for an LLM operating a Trellis instance** (Trellis is agent-operated, so the upgrade path must itself be agent-followable). It encodes this session's lessons: verify canonical-is-on-main before trusting inheritance; resolve symlink targets rather than assuming they point where their name implies.

## Implementation shape and phasing

- `scripts/lib/health-checks.sh` — shared deterministic check library (the single source of truth). Sourced by `doctor.sh` and, in P3, by the scheduled audits.
- `scripts/doctor.sh` — the engine.
- **P1** — read-only checker: Tier 0 + Tier 1, report, exit code, `bats` coverage.
- **P2** — `--fix` delegation to the idempotent treatments, with the hook-resync gate.
- **P3** — wire `upgrade.sh`; write `docs/UPGRADING.md`; add a `/doctor` command; add a thin `trellis` dispatcher (`scripts/trellis` → `doctor | onboard | upgrade | sync`) so "trellis doctor" reads naturally; refactor the scheduled audits to source the shared lib.

## What was deliberately NOT chosen

- **No silent auto-fix post-update.** Mutating project repos without a prompt is the wrong default; the auto-run is check-only and prints the fix command.
- **Audits are not replaced.** Cron stays for passive monitoring and the LLM-judgment checks; the audits and doctor share the deterministic lib rather than duplicating it.
- **No remote/branch-protection enforcement in P1.** Branch protection is reported, not enforced; revisit later.

## Consequences

- Drift becomes a one-command, deterministic, seconds-fast check instead of a weekly LLM audit — the `curat.money`-class silent-unparenting bug is caught immediately.
- The Tier-0 canonical-on-main precondition closes the inheritance-poisoning gap incident #2 exposed.
- One source of truth for "healthy" reduces the 8-audit + N-fix-script sprawl.
- Reversible and additive: new scripts only; no change to the inheritance mechanism or to any rule.

## Related

- Fix engines: `scripts/onboard-project.sh`, `scripts/sync-hooks.sh`, `scripts/rollout-settings.sh`.
- Check engines to unify: `scheduled-tasks/{cross-project-process-audit,parent-hook-drift,version-drift,preset-drift,primer-drift,autonomy-drift,registry-blacklist-health,test-health}`.
- Update flow: `scripts/upgrade.sh`.
- Invariants doctor enforces: `core-rules/inheritance.md`.
- Motivating incident: `curat.money` unparented (no rules symlink, dead `@`-import) + canonical checkout left on a feature branch, 2026-05-30.
