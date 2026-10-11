# Reference — Bypass markers

Authoritative source: `engineering-process.md` §5 (Hook enforcement) and §6.4 (Branch protection).

The regime is fail-closed for the checks it runs. This gate scans for bypass markers within the threat model below. The `bypass-tripwire` audit complements the gate by catching them after-the-fact.

## Threat model

`check-bypass` detects accidental or negligent bypass by trusted operators and agents: stripped or stale hook registrations, a missing, replaced or retargeted owner-recorded `.trellis/runtime` for any attached harness (Claude, Codex or Pi), and hooks disabled by persistent config drift. Managed pre-push resolves `run-all.sh` from the dispatcher's `release-payload` sidecar, not the project's runtime links, so an accidental retarget to a previously installed release still runs the current checker. For an owner with `git_hooks.enabled == true`, exactly one local `core.hooksPath` must literally match `git_hooks.managed_hooks_path`, including in projects with `package.json`. Git identity discovery ignores `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR` and `GIT_INDEX_FILE`; a supplied root must match the owner-recorded worktree path, so an unattached nested Git repository cannot hide an attached ancestor.

It is not a defence against a deliberately malicious same-user project. The attached payload and `TRELLIS_HOME` are same-user writable. Project `local.config.sh` is read from the range base and parsed as data, so a range cannot change the config it is gated with (see SKILL.md, "Gate config is read from the range base, as data"). This is the same-user trust boundary, not cryptographic attestation (Spec 062 §5 and `gotchas.md` G7). The apex ruling of 2026-10-02 disposes deliberate same-user Grok round-2 residuals as out of model; round 4 corrects B2's scope and fixes the accidental paths:

- **B2 (Blocking):** accidental runtime retargeting is now detected on the pre-push path because runner selection uses the managed release sidecar. Only deliberate same-user replacement of the release payload itself (for example, an exit-0 checker) remains out of model.
- **B3 (Closed, B0-4):** project `local.config.sh` was sourced before authentication, so a committed config could exit early or substitute `TRELLIS_HOME`. It is now read from the range base and parsed as data: only `PROCESS_GATE_*` values load, and anything else is `BLOCKED`.
- **H2 (High):** Pi's nearest-ancestor runtime discovery can execute a deliberately planted subdirectory `.trellis/runtime` while the owner-recorded toplevel anchor remains intact.
- **M1 (Medium):** settings authentication is check-then-open; a deliberate same-user racing swap can defeat the parent, hash or hook-key checks (settings-file TOCTOU).

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
| Local `core.hooksPath` unset, duplicated or not literally matching the owner-recorded managed path when `git_hooks.enabled == true` (including husky `prepare` resetting it to `.husky/_`) | Disabled the managed dispatcher; checked even with `package.json` | **fail** — prints `git config --replace-all core.hooksPath <absolute-managed-path>` |
| Removed `core.hooksPath` setting in an unattached native-githooks project with `.githooks/` | Disabled the gate | **fail** |
| Owner-recorded Claude hook events, matchers or commands absent from both `.claude/settings.json` and `.claude/settings.local.json` (either file may satisfy the recorded registration) | Stripped or stale registration | **fail** |
| An event key kept but its entries stripped (`"hooks": {"PreToolUse": []}`), in every settings file present | Registration in name only | **fail** |
| Neither settings file present at all, when the local owner declares Claude attached | Deleted the registration outright | **fail** |
| Owner-recorded `.trellis/runtime` missing, replaced or retargeted for any attached harness | Hooks resolve through a stale or different runtime | **fail** |
| Supplied root differs from the owner-recorded worktree path, including a nested Git toplevel | Attachment identity drift | **fail** |

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

For managed Git hook authority drift, run the finding's `git config --replace-all core.hooksPath <absolute-managed-path>` command from the affected worktree; it restores the same owner-recorded path written by doctor's repair. Owners with `git_hooks.enabled == false` retain the existing checks, without this managed-path requirement.
