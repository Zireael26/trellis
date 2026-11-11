# Reference — PR hygiene

Authoritative source: `engineering-process.md` §6 (Git workflow) and §7 (Definition of done).

## Branch name

- Pattern: `<type>/<kebab-slug>`. Type ∈ `codex`, `feature`, `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `perf`, `build`, `ci`, `revert`.
- Examples: `codex/agent-parity`, `feature/portable-multi-fleet-setup`, `feat/avatar-rotation-gesture`, `fix/wardrobe-zoom-reset`, `chore/upgrade-next-15`.
- `feature` is present because the `spec`, `plan`, and `tasks` skills mandate `feature/<slug>`. A branch that followed the canonical pipeline must not fail the gate for doing so.
- Anything else: **warn** (rename if the branch is short-lived).

## Commit messages

- Conventional Commits, imperative mood. Enforced by Tier-3 `commit-msg` hook (commitlint), but this gate also checks the PR commit range.
- Subject: `<type>(<scope>): <subject>` — ≤ 72 characters, no trailing period.
- Body: optional. Blank line between subject and body. Use the body for *why*, not *what* (the diff is the *what*).
- Footers: `BREAKING CHANGE:`, `Refs: #123`, `Co-authored-by:`.

Allowed types: `feat`, `fix`, `refactor`, `chore`, `docs`, `style`, `test`, `perf`, `build`, `ci`, `revert`.

Scopes are optional. If the project declares a scope allowlist (e.g., monorepo package names) the gate enforces it. Otherwise unscoped commits pass.

In a reviewed range, a `Merge ` subject is accepted only on a commit with at least two parents; a standard `Revert "…"` is accepted only with a `This reverts commit <sha>.` body naming an existing commit. Autosquash and `Applying ` subjects must not land in a reviewed range. The local commit-message hooks separately allow verified active Git merges, reverts and `git am`, and autosquash subjects whose target exists on the branch; the text alone is not an exemption.

Violations: **fail**.

## PR size

Measured as range-wide, rename-aware additions + deletions. The checker determines renames with base-tree attributes in a private Git repository and counts text even if an attribute says `-diff` or `binary`. Bare carriage returns are line breaks, while CRLF is one line break. If either side contains a NUL in its first 8 KiB, the changed file is binary: it contributes no countable lines and is reported in `binary-files`. The receipt reports countable lines and separate excluded test, fixture, generated and lockfile lines on pass, warn and fail.

| Countable lines | Posture |
|---|---|
| ≤ `PROCESS_GATE_PR_SIZE_LIMIT` (default 600) | pass |
| > limit and ≤ `PROCESS_GATE_PR_SIZE_HARD` (default 1200) | warn — request reviewer ack in PR description |
| > `PROCESS_GATE_PR_SIZE_HARD` | fail — split, or add an ADR under `PROCESS_GATE_ADR_DIR` explaining why splitting harms clarity |

The exclusions below are case-sensitive, repo-relative, and apply at any depth. Directory names are complete path segments; filename patterns apply to the basename only:

- **Lockfiles:** exact basenames `pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`, `Cargo.lock`, `go.sum`, `poetry.lock`, `uv.lock`, `Pipfile.lock`, `Gemfile.lock`, `composer.lock`. A suffix lookalike such as `parser-uv.lock` counts.
- **Fixtures and snapshots:** directories `fixtures`, `__fixtures__`, `testdata`, `snapshots`, `__snapshots__`, or filenames `*.snap`.
- **Tests:** everything inside directories `test`, `tests`, `__tests__`; elsewhere, basenames `*.bats`, `*_test.go`, `*_test.py`, `test_*.py`, `*.test.<ext>` or `*.spec.<ext>`, where `<ext>` is one of `js`, `jsx`, `ts`, `tsx`, `mjs`, `cjs`, `py`, `rb`. Shipped `scripts/<name>_test.sh`, `api/openapi.spec.yaml`, and `src/contest.ts` count; `src/test_widget.py` does not.
- **Generated:** a regular text file whose first 20 lines within the first 64 KiB contain the case-sensitive marker `@generated` (word boundary after it) or `Code generated ... DO NOT EDIT.` (at least one character between `generated ` and ` DO`); or whose **base-tree** `.gitattributes` sets `linguist-generated` to `set` or `true`. A binary is not inspected for a marker. Marker detection ignores the inspected lines if they contain a NUL byte. Git evaluates nested base-tree attribute patterns and negations; PR-added or edited, working-tree, local `info/attributes`, global and system attributes do not set the policy.

Each changed text line is assigned to one category, in precedence order: lockfile, fixture, test, generated. A file named `.gitattributes` is **never excluded**, even inside an excluded directory or when marked generated. For an addition or deletion, the existing side determines its category. For a modification or rename, **both** sides must have the same excluded category; otherwise all its changed lines count. A modification that adds its first generated marker therefore counts; a new file carrying its own marker can be excluded.

The receipt's `marker-only` is the subset of generated lines in newly added files excluded only by their own marker, not by a base attribute. `binary-code-lines` is the text-mode added + deleted line count of binary pairs whose old or new filename has a code extension (case-insensitive), or whose old or new regular file starts with a `#!` shebang. The extensions are `js`, `jsx`, `mjs`, `cjs`, `ts`, `tsx`, `mts`, `cts`, `py`, `pyi`, `rb`, `go`, `rs`, `c`, `h`, `cc`, `cpp`, `cxx`, `hpp`, `hxx`, `m`, `mm`, `java`, `kt`, `kts`, `swift`, `cs`, `scala`, `sc`, `sh`, `bash`, `zsh`, `php`, `lua`, `sql`, `pl`, `pm`, `ex`, `exs`, `erl`, `hrl`, `hs`, `fs`, `fsx`, `dart`, `vue`, `svelte`, `proto`, `graphql`. When either separate total exceeds `PROCESS_GATE_PR_SIZE_LIMIT`, the row warns and requests reviewer acknowledgement even if countable lines pass; the hard cap does not apply to those excluded lines. Non-code binaries do not trigger the binary-code warning. Attribute changes take effect only after becoming part of a future range's base. For three-dot ranges the base is the merge base; a single revision compares its base to the tracked working tree, but still uses **only base-tree attributes**. Discovery and counting do not run project-local clean filters. Unreadable metadata fails the size check closed.

**Limits:** only edited lines count, so a pure rename from a previously excluded test or generated path to production has zero changed lines. A broad attribute already present in the base can also exclude later matching edits. A binary-to-text rewrite remains outside the countable budget (a large code-file rewrite now warns separately), and a marker-generated file rewritten while retaining its marker is excluded without a marker-only addition warning. Review the policy and path history; these receipts do not prevent two-step laundering.

Override via `local.config.sh`:

```bash
PROCESS_GATE_PR_SIZE_LIMIT=900
PROCESS_GATE_PR_SIZE_HARD=1800
```

Both values must be non-negative decimal integers; invalid values fail the PR-size check instead of disabling a threshold. Leading zeroes are decimal.

When a range exceeds the hard cap, the gate accepts the documented ADR path only
when the same diff **adds** at least one Markdown file under
`PROCESS_GATE_ADR_DIR` (default `docs/adr`). The ADR must name the oversized
change and explain why splitting it would make review or rollback less clear —
so it has to be an ADR this change authored. An ADR that already existed and was
merely edited in passing does not disarm the cap; without that bound, any
incidental touch under `docs/adr` exempted an arbitrarily large diff.

A qualifying ADR downgrades the row from **fail** to **warn**, not to pass. The
line count and the ADR path are named in the finding, and the PR description
still has to record reviewer acknowledgement of the size.

## PR description checklist

Every PR must include these sections in this order:

1. **Why** — 1–3 sentences on motivation.
2. **What changed** — bullet list, user-visible first, implementation second.
3. **Test plan** — what CI covers, what was tested locally.
4. **Receipts** — verification command(s) run with exit codes (per `engineering-process.md` §7).
5. **Rollout / rollback** — how to revert this change.

Optional sections (when applicable):

- **Preview URL** — for projects that auto-deploy preview environments.
- **Screenshots** — before/after for visual changes.
- **ADRs / design docs** — sections touched, or "none".
- **Breaking changes** — what callers must change.

Missing required section: **fail**. Empty required section: **warn**.

## Review requirements

Trellis defaults:

- Direct push to `main`: **forbidden** at three layers (Tier-3 `pre-push` hook, GitHub branch protection, this gate).
- All changes go through a PR.
- Self-review discipline: write the PR description as if explaining to a stranger; wait at least one session before merging; non-trivial changes get a code-review subagent pass.
- Merge style: **merge commit** by default — preserve the full per-commit history of every PR. Do **not** squash-merge, and do not rebase-merge unless the branch's commit history is intentionally clean and linear and the user has explicitly approved that mode for the PR. Squash-merge is forbidden because it discards intermediate review state, agent attribution, and bisect resolution.

Sole-maintainer projects: GitHub branch protection blocks self-approval, so "required reviewers" cannot be set without making the project undeployable. The functional gate is the local `pre-push` guard + CI + the PR window.

Multi-maintainer projects: declare reviewer requirements in the project's own `CLAUDE.md` and `local.config.sh`. The gate reads `PROCESS_GATE_REQUIRED_REVIEWERS` to enforce.

## Agent-authored PRs

PRs authored end-to-end by an agent must include an **Agent review** section containing the verdict block produced by a *different* agent (not the author) running this skill against the PR.

Self-reviewed agent PRs: **fail**.

## History preservation

- Preserve PR commits with the merge-commit default above.
- Reconcile a feature branch with current `main` before merging; preserve published review history.
- Don't amend published commits without `--force-with-lease` on the feature branch.
- Never force-push `main`. Blocked at three layers regardless.
