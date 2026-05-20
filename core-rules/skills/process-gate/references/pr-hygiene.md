# Reference — PR hygiene

Authoritative source: `engineering-process.md` §6 (Git workflow) and §7 (Definition of done).

## Branch name

- Pattern: `<type>/<kebab-slug>`. Type ∈ `antigravity`, `codex`, `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `perf`, `build`, `ci`, `revert`.
- Examples: `antigravity/workflow-rollout`, `codex/agent-parity`, `feat/avatar-rotation-gesture`, `fix/wardrobe-zoom-reset`, `chore/upgrade-next-15`.
- Anything else: **warn** (rename if the branch is short-lived).

## Commit messages

- Conventional Commits, imperative mood. Enforced by Tier-3 `commit-msg` hook (commitlint), but this gate also checks the PR commit range.
- Subject: `<type>(<scope>): <subject>` — ≤ 72 characters, no trailing period.
- Body: optional. Blank line between subject and body. Use the body for *why*, not *what* (the diff is the *what*).
- Footers: `BREAKING CHANGE:`, `Refs: #123`, `Co-authored-by:`.

Allowed types: `feat`, `fix`, `refactor`, `chore`, `docs`, `style`, `test`, `perf`, `build`, `ci`, `revert`.

Scopes are optional. If the project declares a scope allowlist (e.g., monorepo package names) the gate enforces it. Otherwise unscoped commits pass.

Violations: **fail**.

## PR size

Measured on the diff (additions + deletions, excluding lockfiles, generated files, and test snapshots).

| Lines changed | Posture |
|---|---|
| ≤ `PROCESS_GATE_PR_SIZE_LIMIT` (default 400) | pass |
| Between limit and `PROCESS_GATE_PR_SIZE_HARD` (default 800) | warn — request reviewer ack in PR description |
| > `PROCESS_GATE_PR_SIZE_HARD` | fail — split, or carry a changed ADR under `PROCESS_GATE_ADR_DIR` explaining why splitting harms clarity |

Lockfiles (`pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`, `Cargo.lock`, `go.sum`, `poetry.lock`, etc.), generated files declared via `.gitattributes` `linguist-generated`, and test snapshots do not count.

Override via `local.config.sh`:

```bash
PROCESS_GATE_PR_SIZE_LIMIT=600
PROCESS_GATE_PR_SIZE_HARD=1200
```

When a range exceeds the hard cap, the gate accepts the documented ADR path only
when the same diff changes at least one Markdown file under
`PROCESS_GATE_ADR_DIR` (default `docs/adr`). The ADR should name the oversized
change and explain why splitting it would make review or rollback less clear.

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

## Linear history

- No merge commits on `main`. Linear history enforced by branch protection.
- Rebase feature branches onto `main` before opening PR if behind.
- Don't amend published commits without `--force-with-lease` on the feature branch.
- Never force-push `main`. Blocked at three layers regardless.
