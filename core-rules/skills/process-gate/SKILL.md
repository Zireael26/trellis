---
name: process-gate
description: Pre-PR enforcement gate for any registered Trellis project. Use before opening a PR, as the first pass when reviewing someone else's PR, and whenever an agent is unsure whether a change is mergeable. Checks PR hygiene, secrets, bypass markers, tests and coverage, docs discipline, stack-specific gates, security diff, and analyze. Returns a single verdict block (pass/warn/fail per category, overall MERGEABLE/NEEDS CHANGES/BLOCKED). Mandatory before merging to `main`.
---

# process-gate

Harness-agnostic enforcement layer for the Trellis engineering process. Runs in Claude Code, Codex, headless `claude -p`, and CI. The skill is the executor; authoritative rules live in `engineering-process.md` and the project's own `CLAUDE.md`.

When in doubt, those documents win. If a rule here contradicts either, fix the rule here.

## When to use

- **Before opening a PR.** Run the gate locally; fix what it flags.
- **First pass on any PR review.** Spend human review attention on taste, not on rules a script can catch.
- **When an agent is unsure whether a change is mergeable.** Invoke this skill rather than guess.
- **When something broke on `main`.** Confirm whether a gate missed it; expect to write a new rule.

## When NOT to use

- Architectural questions ("should we build this"). Use an ADR or planning doc.
- Visual or copy critique. The gate enforces machine-checkable rules only.
- Day-to-day local verification. Hooks (`stop-verify`, `post-edit-verify`) cover that.

## Gate categories

Eight canonical gates, all harness-agnostic. Each has a reference file, a validator, and a `pass / warn / fail` posture.

| # | Gate | Reference | Validator |
|---|---|---|---|
| 1 | PR hygiene (commit format, size, branch name, description) | [`references/pr-hygiene.md`](references/pr-hygiene.md) | [`scripts/check-pr.sh`](scripts/check-pr.sh) |
| 2 | Secrets in diff | [`references/secrets.md`](references/secrets.md) | [`scripts/check-secrets.sh`](scripts/check-secrets.sh) |
| 3 | Bypass markers (`--no-verify`, force-push, override env vars) | [`references/bypass.md`](references/bypass.md) | [`scripts/check-bypass.sh`](scripts/check-bypass.sh) |
| 4 | Tests & coverage | [`references/tests.md`](references/tests.md) | [`scripts/check-tests.sh`](scripts/check-tests.sh) |
| 5 | Docs discipline (CHANGELOG, gotchas, ADRs) | [`references/docs.md`](references/docs.md) | [`scripts/check-docs.sh`](scripts/check-docs.sh) |
| 6 | Stack-specific gates (design tokens, a11y, forbidden phrases, etc.) | [`references/stack-profiles.md`](references/stack-profiles.md) | project-local — loaded from `local.config.sh` |
| 7 | Security (diff) | [`../security-gate/SKILL.md`](../security-gate/SKILL.md) | [`../security-gate/scripts/run-diff.sh`](../security-gate/scripts/run-diff.sh) |
| 8 | Analyze | [`../analyze/SKILL.md`](../analyze/SKILL.md) | orchestrated by [`scripts/run-all.sh`](scripts/run-all.sh) |

## Project-local configuration

The skill loads project-local config from `process-gate-local/local.config.sh`
beside the harness symlink. Claude Code uses
`<project>/.claude/skills/process-gate-local/local.config.sh`; Codex uses
`<project>/.agents/skills/process-gate-local/local.config.sh`. If both exist,
the active harness's config wins. This is where each project declares
stack-specific commands, thresholds, and stack-profile validators that don't fit
the canonical eight.

Minimal `local.config.sh`:

```bash
# Commands the canonical scripts call.
PROCESS_GATE_TEST_CMD="pnpm test"             # used by check-tests.sh
PROCESS_GATE_TYPECHECK_CMD="pnpm typecheck"   # used by check-tests.sh
PROCESS_GATE_LINT_CMD="pnpm lint"             # used by check-tests.sh
PROCESS_GATE_PR_SIZE_LIMIT=400                # warn threshold (default 400)
PROCESS_GATE_PR_SIZE_HARD=800                 # fail threshold (default 800)

# Stack-profile validators (run after the canonical eight).
PROCESS_GATE_STACK_VALIDATORS=(
  "scripts/check-tokens.sh"          # project-local, e.g. design-tokens guard
  "scripts/check-a11y.sh"            # project-local
)

# Optional: stack profile name (web-next, web-vite, monorepo-pnpm, unity, native-other, n-a)
PROCESS_GATE_STACK_PROFILE="web-next"
```

If `local.config.sh` is missing the canonical scripts use sensible defaults and warn that no stack profile is declared.

## The standard run

When invoked, the skill:

1. Reads each of the eight gate references so its advice reflects current rules (not stale training data).
2. Sources `local.config.sh` if present.
3. Inspects the working tree (or the diff range provided) and runs each validator in order.
4. Emits a verdict section in this exact shape:

```
## process-gate verdict

PR hygiene:        ✅ pass | ⚠️ warn | ❌ fail
Secrets:           ✅ pass | ⚠️ warn | ❌ fail
Bypass markers:    ✅ pass | ⚠️ warn | ❌ fail
Tests & coverage:  ✅ pass | ⚠️ warn | ❌ fail
Docs discipline:   ✅ pass | ⚠️ warn | ❌ fail
Stack profile:     ✅ pass | ⚠️ warn | ❌ fail | ➖ n/a
Security (diff):   ✅ pass | ⚠️ warn | ❌ fail | ➖ n/a
Analyze:           ✅ pass | ⚠️ warn | ❌ fail | ➖ n/a

Overall: MERGEABLE | NEEDS CHANGES | BLOCKED
```

5. For every non-pass row, includes a **Finding** block with what failed, where (`file:line` if locatable), and the exact fix.
6. For every `⚠️ warn`, includes a **Justify or fix** note. Warnings can be accepted by a reviewer but the acceptance must be recorded in the PR description.

A `❌ fail` in any category means **BLOCKED** regardless of other rows.

## Invocation

### Local pre-flight

```bash
SKILL_DIR=".claude/skills/process-gate"
# Codex-enabled projects can use:
# SKILL_DIR=".agents/skills/process-gate"
bash "$SKILL_DIR/scripts/run-all.sh" --range=main..HEAD
```

### Agent-invoked review

1. Checkout the PR branch.
2. Run scripts above with `--range=origin/main..HEAD`.
3. Emit the verdict section verbatim in the PR review comment.
4. For each finding, attach the exact file:line anchor.

### Human-invoked review

Output goes into the PR description's "process-gate" section, pasted verbatim. Accepted warnings carry a one-line justification.

### Autonomy-aware review (L4/L5)

When the active autonomy level is L4 or L5 (resolved per `core-rules/autonomy.md`), agent-invoked review carries an additional clause:

> Additionally: read `<canonical-root>/decisions-log.md`'s entries for this session. The diff under review must be consistent with the logged decisions. If you see implicit decisions in the diff that are NOT in the log (e.g., a non-obvious choice between two valid implementations, a pattern divergence, an interpretation of an ambiguous requirement), flag each as a missing-decision-log finding. Treat omission as a code-review finding; an incomplete decision log undermines the audit trail that L4/L5 depends on.

At L1–L3 the `decisions-log.md` file is not expected and this clause is skipped. All standard `check-*.sh` scripts run identically at every level.

## Stack-profile carve-outs

Some projects don't fit the web-default assumptions baked into the canonical scripts. Document the carve-out in `local.config.sh`:

- `PROCESS_GATE_STACK_PROFILE="unity"` — Tier-1 web checks (design-tokens, a11y) don't apply. Project supplies its own validators (e.g., `check-asset-bundle.sh`, `check-meta-files.sh`).
- `PROCESS_GATE_STACK_PROFILE="native-other"` — generic native stack. Project supplies validators.
- `PROCESS_GATE_STACK_PROFILE="n-a"` — explicitly opt out of stack profile (gate emits `➖ n/a` for the row). Use sparingly; document in project `gotchas.md`.

The canonical eight gates apply regardless of stack profile.

## Scope boundaries

- The skill **does not** run the build, deploy, or modify project files. CI and `stop-verify` cover that.
- The skill **does not** read production data, secrets, or analytics.
- The skill **does** read any file under the repo and may parse `git log` / `git diff` output.

## Updating this skill

The skill and `engineering-process.md` change together. Adding a process in the manual: add an enforcement here. Retiring one: retire here.

Every change to canonical (`$TRELLIS_ROOT/core-rules/skills/process-gate/`) is a PR against the Trellis canonical repo. The skill cannot relax its own rules silently — that's what `parent-hook-drift` (extended to skills) detects.

## Multi-harness support

Identical SKILL.md, references/, and scripts/ are surfaced to:

- **Claude Code** via `<project>/.claude/skills/process-gate/` symlink → canonical.
- **Codex** via `<project>/.agents/skills/process-gate/` symlink → canonical.

Project-local configuration and stack validators live beside those symlinks in
`process-gate-local/`, for example
`<project>/.claude/skills/process-gate-local/local.config.sh` and
`<project>/.agents/skills/process-gate-local/scripts/check-tokens.sh`.
Onboarding seeds both when `harnesses` in `trellis.config.json` includes `"codex"`.
Skills, references, and scripts are byte-identical across harnesses; files under
`process-gate-local/` are the per-project extension points.
