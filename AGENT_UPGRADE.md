# AGENT_UPGRADE.md — upgrading a machine and its attached projects

This runbook moves **one machine's local Trellis state, and the projects attached to it**, from one immutable release to another. It is harness-neutral: every command runs through the installed stable launcher at `~/.local/bin/trellis`, so Claude Code, Codex, and Pi execute it identically.

It does not publish, tag, or mirror anything, does not change a project's tracked files, and does not make an attached project run from a source checkout. For first-machine setup use [AGENT_SETUP.md](AGENT_SETUP.md); for onboarding a new project use [AGENT_ONBOARD_PROJECT.md](AGENT_ONBOARD_PROJECT.md); for the reference semantics behind every step here — exit classes, row states, adoption scope rules, and the current release's specifics — use [`docs/UPGRADING.md`](docs/UPGRADING.md).

For the 1.0.0 launcher transition, explicit Pi selection and shared-worktree refresh, follow [Migrating to 1.0.0](docs/MIGRATING-1.0.0.md) alongside this general runbook.

## 0. Read this before running anything

**Latency.** Each launcher invocation independently re-verifies the release payload before it dispatches: it freezes an execution snapshot of roughly 1,438 files, checks the release record, tree, modes, and read-only state, then crosses an `env -i` boundary. Measured cost is **4.55–39 seconds warm — about 39 seconds wall for `show-config` at the top of that range — and 40–125 seconds under load**. Budget accordingly: a command that has produced no output for a minute is verifying, not hung. Do not interrupt it, do not add a timeout shorter than three minutes, and do not conclude the launcher is broken. A loop over a task catalogue or a multi-project fleet runs for many minutes by design.

**Stop conditions.** These are absolute.

- A non-zero exit from `release install`, `release verify`, `registry list`, or `doctor` stops the run at that point. Do not proceed to the next section, and do not retry with a different target to route around it.
- Never substitute `scripts/release.sh` or `scripts/upgrade.sh` from a source checkout for a launcher command. They carry an attestation-based, default-refuse source gate and will exit `2` — including for `--help`. That refusal is the design, not a setup fault.
- Never repair by hand. Do not edit `.trellis/runtime`, `$TRELLIS_HOME/registry.json`, an ownership record, a rendered harness file, or anything under `releases/`. Do not delete a failing artifact to make a command pass.
- Never infer a path. An `unavailable` row is evidence about the machine, not permission to reconstruct a checkout location from a project ID or a sibling directory.
- **A tool refusal, a permission denial, or a hook block is data.** Report it and stop. Do not re-issue the same call through a different mechanism, relax a setting, or work around the boundary that produced it.

**Exit classes.** `0` success, `2` invalid arguments, `3` ownership or identity conflict, `4` invalid or corrupt state, `5` unavailable path, remote, or local capability. A bulk command returns the **highest** class any row produced, so `0` from a fleet command means every selected row reported `0`.

## 1. Establish explicit inputs

Ask for and repeat back before any mutation. Do not derive any of these from a branch, a working tree, or a "latest" lookup.

- `TARGET_RELEASE` — the exact published release version, without the `v` prefix.
- `RELEASE_REMOTE` — a remote carrying annotated tag `v$TARGET_RELEASE`. Omit only if `$TRELLIS_HOME/config.json` already records `release_remote`.
- `FLEET` — the local fleet to upgrade.
- The intended scope: one project, one fleet, or a reviewed all-fleet operation. Choose the narrowest that satisfies the request.

```bash
TRELLIS="$HOME/.local/bin/trellis"
test -x "$TRELLIS"

: "${TRELLIS_HOME:?Set the selected local Trellis home explicitly}"
export TRELLIS_HOME
: "${TARGET_RELEASE:?Set the exact release version, without the v prefix}"
: "${RELEASE_REMOTE:?Set the remote containing annotated tag v$TARGET_RELEASE}"
: "${FLEET:?Set the local fleet explicitly}"
```

`TRELLIS_FLEET` and `TRELLIS_RELEASE` do not survive the launcher's `env -i` boundary. Always pass `--fleet NAME` and `--release VERSION` as flags; exporting them changes nothing. `--home PATH` selects which machine state a command renders — it is not how the launcher finds its own payload, which it resolves from `TRELLIS_HOME`, else `$HOME/.trellis`, before dispatch.

## 2. Record the starting state

Capture what the machine runs now, so the upgrade has a baseline and rollback has a target.

```bash
"$TRELLIS" release list
"$TRELLIS" registry list --fleet "$FLEET"
```

Expected: exit `0` from both. Record the currently adopted release as `ROLLBACK_RELEASE`, and record every row `registry list` reports as `unavailable` or `identity-error` before anything changes — a row that was already broken is not something this upgrade caused, and a row that breaks during it is.

A `--fleet`-scoped listing attests to that fleet and nothing else; it exits `0` while another fleet holds a broken row, by design. For a whole-machine verdict, run `"$TRELLIS" registry list` with no flag.

## 3. Install and verify the release

Installation never adopts. Every attachment stays on its recorded release until section 4.

```bash
"$TRELLIS" release install "$TARGET_RELEASE" --remote "$RELEASE_REMOTE"
"$TRELLIS" release verify "$TARGET_RELEASE"
```

Expected: exit `0` from both; a new immutable payload exists at `$TRELLIS_HOME/releases/$TARGET_RELEASE/`.

Stop conditions specific to this section:

- Exit `3` from `install` means that version is already installed. Installed releases are never overwritten. If the intent was to move *back* onto it, skip to section 7 — this is also why `trellis upgrade` cannot roll back.
- An integrity mismatch, a malformed tag, an unreachable remote, or unwritable local state stops the run. Do not construct a release directory, and do not point the machine at a source checkout.
- A failed `release verify` is an invalid runtime target. Do not adopt it and do not repair files under `releases/`.

## 4. Adopt for the intended scope

Choose exactly one selector form. Each selected attachment is preflighted against its ownership record and the verified target before its runtime anchor moves.

```bash
# One project — --fleet is optional only when PROJECT_ID is unique on this machine.
"$TRELLIS" release adopt "$TARGET_RELEASE" --project "$PROJECT_ID" --fleet "$FLEET"

# One fleet.
"$TRELLIS" release adopt "$TARGET_RELEASE" --fleet "$FLEET"

# Reviewed all-fleet — only after `registry list` with no flag has been read.
"$TRELLIS" release adopt "$TARGET_RELEASE" --all
```

Expected: exit `0`, with one reported result per selected row.

Adoption repoints each selected project's `.trellis/runtime` anchor at the new payload, rewrites the ownership record's release and payload fields, and regenerates managed git-hook dispatchers under `$TRELLIS_HOME/state/git-hooks/`. For an `explicit-json` render, it also restores every recorded owned key to the value captured at attach time while preserving unowned local keys. It does **not** apply values from the target release's templates. Section 5 covers that separate operation.

A fault in one row does not abort the others: adoption continues over the remaining selected rows and returns the highest class any row produced. A global environment fault — a missing hash command, an unreadable release store — is probed once up front and fails the whole command as class `5`. Read the per-row report. A partial report is not evidence that every attachment upgraded.

## 5. Re-render harness surfaces when the release changed a template

Check the release notes in [`docs/UPGRADING.md`](docs/UPGRADING.md) for the target version. If it changed a harness **template**, the affected projects need a fresh render; adoption alone will not apply the new template values. `doctor` detects drift from the attachment's recorded owned values, but it does not report that those values differ from a newer release template.

There is no repair, refresh, or force route. `attach` against an already-attached row prints `already attached: <root>` and returns `0` without rendering. `relink` repairs the anchor and managed hook files, and verifies owned artifacts byte-exact against the ownership record, so it cannot introduce new bytes; when `core.hooksPath` is operator-owned, it leaves that setting unchanged and reports the retained authority. `doctor --fix` is read-only. **The documented route is the detach/attach pair**, the same one used for a checkout move.

```bash
: "${PROJECT_ROOT:?Set the attached project Git worktree top level explicitly}"
: "${PROJECT_ID:?Set the portable project ID explicitly}"

"$TRELLIS" detach --home "$TRELLIS_HOME" --all-worktrees "$PROJECT_ROOT"
"$TRELLIS" attach \
  --home "$TRELLIS_HOME" \
  --fleet "$FLEET" \
  --release "$TARGET_RELEASE" \
  --harness claude \
  --harness codex \
  --harness pi \
  "$PROJECT_ROOT"
```

Expected: exit `0` from both; `attach` prints the attached root, not `already attached`.

What changes on disk: `detach` removes only attachment-owned artifacts — the runtime anchor, the rendered harness surfaces, the managed local exclude block, the ownership record, the local hook dispatchers — and leaves the tracked `.trellis.json` intact and inert. `attach` writes them back from the target payload. Tracked project work, including pre-existing dirty and staged changes, must be preserved. Repeat attachment for every intended registered worktree removed by the group detach; see the 1.0.0 migration guide.

Pass the same harness set that was detached. A set that differs from the recorded attachment is refused as class `3`; detaching first is what makes the set re-selectable at all. Attach the harnesses the project actually has — do not add one because this block lists three.

## 6. Re-materialize scheduled tasks

Materialized task inputs carry the release identity that wrote them and do not follow an adoption. Re-materialize every task this machine schedules, per fleet.

```bash
for TASK in daily-project-digest conductor dep-currency; do
  "$TRELLIS" task materialize --home "$TRELLIS_HOME" --fleet "$FLEET" "$TASK"
done
```

Substitute the tasks this machine actually schedules; use your machine's configured task catalogue. Each call reads one strict registry snapshot and rewrites `$TRELLIS_HOME/tasks/<fleet>/<task>/` atomically. Stdout carries the task root only.

Reading the result correctly matters, because one line looks like a failure and is not:

- `trellis task: excluded row: <project_id>: checkout unavailable in local registry snapshot` on stderr, with exit `0`, is **success**. That project has no usable checkout this run and was dropped from the roster; the task proceeds over the rows that remain. Report the excluded projects; do not stop.
- A manifest with `status: "planned-error"`, or exit class `5`, is a real stop. It means no registered rows at all, no eligible target among the remaining rows, or a registry that failed identity validation.

Section 0's latency warning applies hardest here: this loop is one full launcher verification per task.

## 7. Verify

Run the same scope you adopted.

```bash
"$TRELLIS" release verify "$TARGET_RELEASE"
"$TRELLIS" registry list --fleet "$FLEET"
"$TRELLIS" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"

(
  cd "$PROJECT_ROOT"
  "$TRELLIS" show-config --home "$TRELLIS_HOME" --fleet "$FLEET"
  git status --short
)
```

Expected: exit `0` from each; `show-config` reports the target release; `git status --short` matches the pre-upgrade user-work baseline.

New unexplained changes after an upgrade are a stop condition; pre-existing dirty work must remain intact. Attachment state must never appear in a project commit — not the runtime anchor, not a rendered harness surface, not the local exclude block, not the ownership record, not a hook dispatcher. If any of those show as untracked or modified, report it and stop rather than staging, committing, or deleting.

If `doctor` identifies an interrupted attachment transaction, run recovery for exactly that worktree and re-verify. Do not delete artifacts manually.

```bash
"$TRELLIS" recover --home "$TRELLIS_HOME" "$PROJECT_ROOT"
"$TRELLIS" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"
```

## 8. Roll back

Rollback is an explicit adoption of a previously installed, verified release. It is not `trellis upgrade` — that route begins with an install, and the prior version is already on disk. It is not a source-checkout reset, a retag, or an edit to `.trellis/runtime`.

```bash
: "${ROLLBACK_RELEASE:?Set the previously installed release recorded in section 2}"
"$TRELLIS" release verify "$ROLLBACK_RELEASE"
"$TRELLIS" release adopt "$ROLLBACK_RELEASE" --fleet "$FLEET"
"$TRELLIS" doctor --fleet "$FLEET"
```

Use the same selector form the upgrade used. Two things do not roll back on their own:

- **A re-rendered harness surface.** If section 5 ran for a project, repeat the detach/attach pair with `--release "$ROLLBACK_RELEASE"`. A newer render under an older anchor is not a supported state, because the expected-command pin the render must match lives in the payload.
- **Materialized task inputs.** Repeat section 6 after the rollback.

Keep the target release installed. Installed releases are immutable and are not a cleanup candidate merely because a project rolled back; retaining it is what makes the failure verifiable afterward.

## 9. Final report

Report observed facts only, with the command that produced each.

1. Starting release and target release, the release remote, and the adoption selector actually used.
2. `release install` and `release verify` results.
3. Per-row adoption results, and the highest exit class the run produced.
4. Which projects were re-rendered, with the harness set attached to each; or the explicit statement that the target release changed no template and none were.
5. Which scheduled tasks were re-materialized, and every `excluded row:` project reported, with its reason.
6. Post-upgrade `doctor`, `registry list`, and per-project `git status` results.
7. Every `unavailable` or `identity_error` row and its disposition, separating rows that were already broken at section 2 from rows that broke during the run.
8. Any stop condition hit, quoted verbatim, and the state the machine was left in.

Do not push, commit, tag, mirror, or edit a project's tracked files as part of an upgrade.
