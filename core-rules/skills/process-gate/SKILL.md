---
name: process-gate
description: Pre-PR enforcement gate for any registered Trellis project. Use before opening a PR, as the first pass when reviewing someone else's PR, and whenever an agent is unsure whether a change is mergeable. Checks PR hygiene, secrets, bypass markers, tests and coverage, docs discipline, stack-specific gates, security diff, analyze, and anti-slop. Returns a single verdict block (pass/warn/fail per category, overall MERGEABLE/NEEDS CHANGES/BLOCKED). Mandatory before merging to `main`.
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

Nine canonical gates, all harness-agnostic. Each has a reference file, a validator, and a `pass / warn / fail` posture.

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
| 9 | Anti-slop (evidence doctrine in added lines; opt-in per project) | [`references/anti-slop-gate.md`](references/anti-slop-gate.md) | [`scripts/check-slop.sh`](scripts/check-slop.sh) |

## Where this sits in the verification chain

The gate is the last of four checks on a change, not the only one. In order:
**(1)** the `code-review-subagent` fires per edit-heavy turn against the diff
(`core-rules/hooks.md`); **(2)** `execute` runs the same review core in-body per task,
advisory, before each tick (`../execute/references/verification-step.md`);
**(3)** this gate runs the nine categories pre-PR and emits the verdict; **(4)**
`pre-push` re-runs the security diff and the 006 spec gate at the git boundary. Each
layer assumes the ones before it ran — if you are invoking this gate directly on a
diff no reviewer has seen, say so in the verdict, because Gate 4 and Gate 7 are the
only two categories that re-derive their own evidence.

## Project-local configuration

The skill loads project-local config from `process-gate-local/local.config.sh`
beside the harness symlink. Claude Code uses
`<project>/.claude/skills/process-gate-local/local.config.sh`; Codex uses
`<project>/.agents/skills/process-gate-local/local.config.sh`. If both exist,
the active harness's config wins. This is where each project declares
stack-specific commands, thresholds, and stack-profile validators that don't fit
the canonical nine.

Minimal `local.config.sh`:

```bash
# Commands the canonical scripts call.
PROCESS_GATE_TEST_CMD="pnpm test"             # used by check-tests.sh
PROCESS_GATE_TYPECHECK_CMD="pnpm typecheck"   # used by check-tests.sh
PROCESS_GATE_LINT_CMD="pnpm lint"             # used by check-tests.sh
PROCESS_GATE_PR_SIZE_LIMIT=400                # warn threshold (default 400)
PROCESS_GATE_PR_SIZE_HARD=800                 # fail threshold (default 800)

# Stack-profile validators (run after the canonical nine).
PROCESS_GATE_STACK_VALIDATORS=(
  "scripts/check-tokens.sh"          # project-local, e.g. design-tokens guard
  "scripts/check-a11y.sh"            # project-local
)

# Optional: stack profile name (web-next, web-vite, monorepo-pnpm, unity, native-other, n-a)
PROCESS_GATE_STACK_PROFILE="web-next"
```

If `local.config.sh` is missing the canonical scripts use sensible defaults and warn that no stack profile is declared.

### Gate config is read from the range base, as data

Gate config is read from the BASE of the gated range — `a` in `a..b`, the
merge-base in `a...b`, the revision itself for a single-rev range — with git,
never from the working tree. It covers:

- `process-gate-local/local.config.sh` (both twins, the active harness's
  loaded last so it wins; the deprecated `.claude/skills/process-gate/local.config.sh`
  only when neither twin exists);
- `secrets-allowlist.txt`;
- stack validators and the helpers they declare (below).

Every one of these paths is looked up in the BASE tree, ancestor by ancestor:
each directory on the way (`.claude`, `.agents`, `skills`, the deprecated
`process-gate` directory, a validator's own directories) must be a tree there,
and the file a regular blob. A symlink, submodule or file on the way, a leaf
that is not a regular file, or a failed lookup is `BLOCKED`, never treated as
absent; only true absence counts as absent. An unresolvable base is `BLOCKED`.

`local.config.sh` is parsed as data, not sourced. Allowed lines: blank lines,
`# comments`, `PROCESS_GATE_<NAME>=<value>` and
`PROCESS_GATE_<NAME>=( <value> ... )` (on one line or several, empty items
kept), each optionally followed by ` # comment`. A value is one of:

- a bare word of `A-Z a-z 0-9 _ . / : @ % + , = -`;
- a `"double-quoted"` literal with no `$`, backtick, `;`, `"` or backslash;
- a `'single-quoted'` literal with no `$`, backtick, `;` or `'`;
- `"${PROCESS_GATE_X:-<literal>}"` assigned to that same `PROCESS_GATE_X`
  (an inherited value wins), with nothing nested inside.

Any other line — a function, a command, `export`, `source`, a default for a
different key — makes the run `BLOCKED` with `process-gate local config is not
data`.

**Validator code.** `run-all.sh` copies the regular files of both twins'
`process-gate-local/` trees, every project validator the base config names and
every path in `PROCESS_GATE_VALIDATOR_DEPS` out of the base commit into a
private trusted root, and runs validators only from there. It exports that
root to them as `PG_TRUSTED_ROOT`, set by `run-all.sh` itself and never taken
from the caller; copies keep the exec bit of mode-100755 blobs. A validator
path names a base-tree path: only the project ROOT is resolved physically
(its logical spelling, its physical spelling, or an outside symlink to the
root itself); everything below it is normalised lexically (`.`, `..`, `//`)
and walked in the base tree, never through working-tree symlinks. That one
mapping decides what is copied, what runs and what counts as a change. An
absolute validator outside the project, or reached through a symlink into a
project subdirectory, is refused.

A validator's bytes come from that base copy, but it runs against the
checkout under test: its cwd is the checkout and `PROCESS_GATE_PROJECT_DIR`
holds the checkout's absolute path. A validator that locates the project from
its own file path (`dirname "$0"`) finds the private copy instead; use
`PROCESS_GATE_PROJECT_DIR`.

While a validator runs, a guard loaded through `BASH_ENV` lets `.`/`source`
load files only from the trusted root or this skill; sourcing a missing
sibling, a cwd-relative file or a project helper fails the validator. Its
helper API is narrower than native `source`: with explicit arguments it
behaves natively; with none, the sourced file sees the validator's own
arguments (`--range=<range>`), as at the validator's top level, so a source
inside a function or after `set --`/`shift` must pass its arguments. The
sourced code runs in the caller's variable scope. NOT intercepted:
`builtin source`, `builtin .`, `command .`, helpers a validator executes
rather than sources, and other interpreters. Those are reviewed code (LB-6).

Every other bash the gate starts runs without a startup file or an imported
function: both pre-push carriers and `run-all.sh` clear `BASH_ENV` and `ENV`,
and start every bash with `bash -p`, which imports no exported function and
reads no `BASH_ENV`. Only validators get the guard (so they cannot use `-p`).
`run-all.sh` also drops every function it inherited before it runs anything;
that purge starts with the assignment `POSIXLY_CORRECT=y`, so `unset` is found
before any function and an exported `builtin`, `unset` or `set` cannot
intercept it. A startup file inherited by `run-all.sh` itself runs before any
of that, so a direct caller launches it clean:

```bash
bash -p <skill>/scripts/run-all.sh --mode=merge --range=<base>..<head>
```

The boundary: a project script that a validator or `PROCESS_GATE_TEST_CMD`
executes as the code under test (a test suite, a build, `make lint`) runs
from the range under review. That is reviewed project code, not gate config.
To pin a helper, declare it in `PROCESS_GATE_VALIDATOR_DEPS` and run it from
`$PG_TRUSTED_ROOT`.

**Changes to gate config.** A range that adds, changes, deletes or renames
gate config is still gated with the base config. Gate config here means:

- `process-gate-local/**` or `security-gate-local/**` in either twin;
- the loader paths pi and pi-subagents read, at any depth (pi can start in a
  subdirectory): `.pi/`, `.agents/agents/`, `.agents/workflows/`,
  `.agents/skills/` (each also as the bare path, e.g. replaced by a symlink),
  plus `.trellis/` and `.trellis.json` (its `template.branch` steers the diff
  base), also at any depth;
- `.envrc` and `.env*` at any depth, matched by path only (their contents are
  never read);
- the security scanners' root config (`.gitleaks.toml`, `.gitleaksignore`,
  `.semgrepignore`, `osv-scanner.toml`) and `<audit dir>/*-baseline-*.json`
  for `audits` and every `SECURITY_GATE_AUDIT_DIR` the environment (which
  can only add a dir) or the base-side security-gate config sets, read with
  the security gate's own data grammar; a config it would not read as data
  makes every `*-baseline-*.json` at any depth gate config;
  these and the two items above are the same namespace the security gate's
  diff mode reserves;
- any `secrets-allowlist.txt`;
- the deprecated config;
- a validator path or a declared dependency.

Any changed path with a non-ASCII byte anywhere is gate config (release-owner
ruling: a case-insensitive checkout folds `.agents/ſkills/x` into
`.agents/skills/x`, and no look-alike list is complete). ASCII paths match on
their NFKC + case-folded form (on a case-insensitive checkout `.PI/x` is
`.pi/x`). The fold runs in `python3 -I`; without it the run BLOCKS.

The rules by context:

- **Push mode:** the verdict carries a notice: `gate config changed in range:
  gated with BASE config; merge requires gate-config-approved: <head-sha>`.
- **Merge mode:** `BLOCKED` unless the repo owner has posted the line
  `gate-config-approved: <full head sha>` in a comment or non-dismissed review
  on the one open PR whose head is that SHA. `run-all.sh` reads it with `gh`,
  refuses an incomplete PR search, re-checks the PR is still open at that
  head, and quotes the author and the line. Only the owner posts it; agents
  never post or script it.
- **A push that targets main/master:** pre-push passes `--target=main`. A
  gate-config change is `BLOCKED` whether or not an approved PR exists; it
  must merge through the PR.

There is no override.

## The standard run

When invoked, the skill:

1. Reads each of the nine gate references so its advice reflects current rules (not stale training data).
2. Reads `local.config.sh` (if present) as data from the range base — see above.
3. Inspects the working tree (or the diff range provided) and runs the cheap rows before Tests & coverage, preserving the verdict's category order. In push mode, an always-hard cheap failure skips Tests: that row renders `➖ n/a` with an explicit `Tests: not run` notice and the overall verdict remains `BLOCKED`. Merge mode always runs every row; warnings and push-downgraded PR-shape failures never skip Tests.
4. Emits a verdict section in this exact shape:

```
## process-gate verdict

PR hygiene:        ✅ pass | ⚠️ warn | ❌ fail
Secrets:           ✅ pass | ⚠️ warn | ❌ fail
Bypass markers:    ✅ pass | ⚠️ warn | ❌ fail
Tests & coverage:  ✅ pass | ⚠️ warn | ❌ fail | ➖ n/a (push already BLOCKED)
Docs discipline:   ✅ pass | ⚠️ warn | ❌ fail
Stack profile:     ✅ pass | ⚠️ warn | ❌ fail | ➖ n/a
Security (diff):   ✅ pass | ⚠️ warn | ❌ fail | ➖ n/a
Analyze:           ✅ pass | ⚠️ warn | ❌ fail | ➖ n/a
Anti-slop:         ✅ pass | ⚠️ warn | ❌ fail | ➖ n/a

Overall: MERGEABLE | NEEDS CHANGES | BLOCKED
```

`Anti-slop` renders `➖ n/a` in any project that has not declared
`gate_profiles.anti_slop.posture` in its `.trellis.json` — which is every project
until it opts in. It can only reach `❌ fail` at `posture: "enforced"`.

5. For every non-pass row, includes a **Finding** block with what failed, where (`file:line` if locatable), and the exact fix.
6. For every `⚠️ warn`, includes a **Justify or fix** note. Warnings can be accepted by a reviewer but the acceptance must be recorded in the PR description.

A `❌ fail` in any category means **BLOCKED** regardless of other rows.

## Invocation

### Local pre-flight

```bash
SKILL_DIR=".claude/skills/process-gate"
# Codex-enabled projects can use:
# SKILL_DIR=".agents/skills/process-gate"
bash "$SKILL_DIR/scripts/run-all.sh" --base=main
```

`--base=<ref>` gates `merge-base(<ref>, HEAD)..HEAD`; `--range=<start>..<end>` is used verbatim. Merge mode requires one of the two. In push mode, with neither flag, the diff-base resolver (`scripts/lib/diff-base.sh`) picks the base: PR base cache, recorded parent, creation reflog, upstream, then the default branch. If it cannot derive a base, every commit not on the local `main` (else `master`) is gated and the receipt says `via fallback`; with neither branch the run refuses, never gating only `HEAD~1..HEAD`. The verdict prints one `diff-base:` receipt line under its header naming the range it judged.

### Agent-invoked review

1. Checkout the PR branch.
2. Run scripts above with `--base=origin/main`, or `--base=origin/<pr-base>` for a stacked PR.
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

The canonical nine gates apply regardless of stack profile.

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
