# Reference — Bypass markers

Authoritative source: `engineering-process.md` §5 (Hook enforcement) and §6.4 (Branch protection).

The regime is failsafe: hooks fail closed. A "bypass" is any deliberate or accidental action that circumvents that. This gate scans for the patterns. The `bypass-tripwire` audit complements the gate by catching them after-the-fact.

## Patterns flagged

### Commit-time bypass

| Marker | What it means | Posture |
|---|---|---|
| `--no-verify` in `git commit` invocation history (reflog within range) | Skipped Tier-3 hooks | **fail** |
| `git commit --no-gpg-sign` (when project requires signing) | Bypass signing policy | **fail** |
| Commits with no Conventional Commit prefix when `commit-msg` hook is in tree | Hook didn't run | **fail** (gates the diff) |

Detection: `check-bypass.sh` parses `git log --format=%h%n%P%n%s%n%b` for the range and cross-references against the local reflog where available.

### Push-time bypass

| Marker | What it means | Posture |
|---|---|---|
| `TRELLIS_ALLOW_MAIN_PUSH=1` in commit trailer or recent shell history | Used the documented override | **warn** — must be justified in `gotchas.md` |
| Direct push to `main` without a merge commit (i.e., not the result of a PR merge) | Bypassed the PR flow | **fail** |
| `git push --force` or `--force-with-lease` to a protected branch | Bypassed branch protection (or branch protection is missing) | **fail** |

### Hook-time bypass

| Marker | What it means | Posture |
|---|---|---|
| Modified `.husky/*` to short-circuit (e.g., `exit 0` at top) | Disabled the gate | **fail** |
| Removed `core.hooksPath` setting (for native-githooks projects) | Disabled the gate | **fail** |
| `.claude/settings.json` hook entries removed without canonical `parent-hook-drift` clearance | Drift from canonical | **fail** |

## Allowed overrides

`TRELLIS_ALLOW_MAIN_PUSH=1` exists for genuine emergencies (production outage, force-fix, etc.). Each use must be:

1. Documented in the project's `gotchas.md` with date, reason, and resolution.
2. Visible in commit trailers if used during a commit.
3. Reviewed at the next `bypass-tripwire` audit run; the entry confirms it was intentional.

Repeated use without documentation: **fail** (escalates to a process-gap report).

## What this gate does NOT cover

- Whether CI status checks were green when the merge happened — `engineering-process.md` §7 plus GitHub branch protection cover that.
- Whether code review was actually performed — `code-review-subagent` hook covers in-session; PR reviewer requirements (see `pr-hygiene.md`) cover GitHub-side.
- Whether secrets were leaked — see `secrets.md`.

## Remediation

For a `fail`:

1. **Don't merge** until the bypass is reviewed and either undone or formally accepted.
2. **If the bypass was accidental:** revert and re-do without bypassing. Document in `gotchas.md` so the next gap can be closed.
3. **If the bypass was intentional emergency:** document the trailer/`gotchas.md` entry; the gate will still flag, but the reviewer can accept it as warn-with-justification.
4. **If the gate is wrong:** open an issue against this skill. Don't silence the rule.
