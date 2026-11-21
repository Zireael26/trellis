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
