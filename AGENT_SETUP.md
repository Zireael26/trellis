# AGENT_SETUP.md — local Trellis setup for agents

This runbook sets up **one machine's local Trellis state**. It is deliberately safe to rehearse in a temporary home, supports personal and work fleets from one policy source clone, and accepts project Git worktrees at arbitrary absolute paths.

It does not create tracked machine configuration, infer paths from project names, make an attached project run from a mutable source checkout, or configure credentials, providers, or harness trust stores. For the architecture and migration rationale, link to—not duplicate—the T23 documents: [`docs/MIGRATING-LOCAL-FLEETS.md`](docs/MIGRATING-LOCAL-FLEETS.md), [`docs/UPGRADING.md`](docs/UPGRADING.md), and [`docs/adr/2026-08-12-local-fleets-immutable-releases.md`](docs/adr/2026-08-12-local-fleets-immutable-releases.md).

## 1. Establish explicit inputs and a safe local home

Start in the policy source clone only to perform the two one-time bootstrap calls below: direct `configure.sh configure` and `configure.sh fleet add`. Never invoke the mutable `scripts/trellis` dispatcher. Select an exact **published** release and the remote that contains its annotated `vVERSION` tag; do not derive either from a branch, working tree, or “latest” lookup.

```bash
SOURCE_ROOT="$(pwd -P)"
BOOTSTRAP_CONFIGURE="$SOURCE_ROOT/scripts/configure.sh"
test -x "$BOOTSTRAP_CONFIGURE"
test -x "$SOURCE_ROOT/scripts/trellis-launcher.sh"

: "${RELEASE_VERSION:?Set the exact published immutable release, without a v prefix}"
: "${RELEASE_REMOTE:?Set a remote containing annotated tag v$RELEASE_VERSION}"
: "${PERSONAL_DISCOVERY_ROOT:?Set an explicit personal scan root}"
: "${WORK_DISCOVERY_ROOT:?Set an explicit work scan root}"

# New private state and an isolated user home for this rehearsal. This shell
# never reads or mutates the operator's ~/.trellis or ~/.local/bin/trellis.
export TRELLIS_HOME="$(mktemp -d "${TMPDIR:-/tmp}/trellis-home.XXXXXX")"
export HOME="$(mktemp -d "${TMPDIR:-/tmp}/trellis-user-home.XXXXXX")"
```

Use a deliberately chosen persistent `TRELLIS_HOME` only after this flow is understood; then run the configure command with the operator's real `HOME` so the fixed launcher installs at `$HOME/.local/bin/trellis`. `TRELLIS_HOME` is local state, not a repository setting. A discovery root bounds an opt-in registry rebuild or scan; it is not a required parent directory for a project you explicitly attach.

## 2. Configure personal and work fleets

Only this block executes a script from the source clone. It writes private machine configuration and both fleet definitions, then atomically installs the fixed launcher at `$HOME/.local/bin/trellis`; it never invokes `scripts/trellis`. The temporary `HOME` makes that fixed destination safe for rehearsal. Once `TRELLIS` is set below, every command—including the first release installation—uses the installed launcher.

```bash
FLEET=personal
"$BOOTSTRAP_CONFIGURE" configure \
  --source "$SOURCE_ROOT" \
  --home "$TRELLIS_HOME" \
  --default-fleet "$FLEET" \
  --discovery-root "$PERSONAL_DISCOVERY_ROOT" \
  --release "$RELEASE_VERSION" \
  --release-remote "$RELEASE_REMOTE" \
  --launcher-template "$SOURCE_ROOT/scripts/trellis-launcher.sh"
"$BOOTSTRAP_CONFIGURE" fleet add work \
  --home "$TRELLIS_HOME" \
  --discovery-root "$WORK_DISCOVERY_ROOT"

TRELLIS="$HOME/.local/bin/trellis"
test -x "$TRELLIS"
```

`$TRELLIS_HOME/config.json` holds this machine's source location, selected release, default fleet, and fleet discovery roots. `$TRELLIS_HOME/registry.json` later records actual attached checkout locations and their availability. Both stay private to this machine.

## 3. Install and verify the immutable release

The configured `active_cli_release` must equal `$RELEASE_VERSION`. Before that release exists locally, the fixed launcher permits exactly its bootstrap-safe installation route: `release install VERSION [--remote URL]`. Use that route; do not fall back to a mutable source dispatcher. Installation fetches the annotated tag, verifies its version and tree, then makes the installed payload immutable. After installation, even verification runs through the stable launcher.

```bash
"$TRELLIS" release install "$RELEASE_VERSION" --remote "$RELEASE_REMOTE"
"$TRELLIS" release verify "$RELEASE_VERSION"
```

The source clone is a bootstrap and later local-configuration input only. A successful project attachment resolves its runtime from the verified release payload recorded under `TRELLIS_HOME`, never from `SOURCE_ROOT`; after the initial bootstrap, normal operations use `"$TRELLIS"` only.

## 4. Understand the inert project boundary

A project may track one optional `.trellis.json` manifest. It contains a stable `project_id` and portable policy such as presets or autonomy; it contains no source path, fleet membership, local release path, local registry row, hook state, or runtime link.

Everything behavior-producing is local attachment state: the immutable runtime anchor, native Claude Code/Codex/OMP surfaces, managed local exclusions, attachment ownership, and recovery journals. A contributor who clones only the tracked project—including `.trellis.json`—has an inert ordinary clone: no Trellis installation is required and no Trellis harness behavior is activated.

Do not create absolute `@` imports, direct live source links, copied hooks/settings, or a tracked central registry as a substitute for attachment. Each harness's credentials and trust decisions remain the user's responsibility.

## 5. Onboard or attach a project at any path

Resolve the operator-supplied Git worktree; never construct it from a discovery root or project ID. The normal command explicitly attaches all three supported harnesses.

```bash
: "${PROJECT_INPUT:?Set the existing project Git worktree path explicitly}"
: "${PROJECT_ID:?Set a stable portable project ID explicitly}"
PROJECT_ROOT="$(git -C "$PROJECT_INPUT" rev-parse --show-toplevel)"

git -C "$PROJECT_ROOT" status --short
"$TRELLIS" onboard \
  --home "$TRELLIS_HOME" \
  --fleet "$FLEET" \
  --release "$RELEASE_VERSION" \
  --project-id "$PROJECT_ID" \
  --harness claude \
  --harness codex \
  --harness omp \
  "$PROJECT_ROOT"
```

`onboard` creates the portable manifest when it is absent and records the actual checkout only locally. Have the project owner review and commit `.trellis.json` as its own project change. Do not stage the local attachment artifacts.

For a clean clone that already has a valid manifest, attach directly with the same explicit release, fleet, and three-harness selection:

```bash
"$TRELLIS" attach \
  --home "$TRELLIS_HOME" \
  --fleet "$FLEET" \
  --release "$RELEASE_VERSION" \
  --harness claude \
  --harness codex \
  --harness omp \
  "$PROJECT_ROOT"
```

## 6. Migrate a legacy project before attachment

If `onboard` reports a legacy or mixed direct-link layout, do not delete artifacts by hand and do not use the compatibility route as the normal setup path. Prepare a reversible migration, review its project diff, and preserve the emitted snapshot path.

```bash
"$TRELLIS" migrate --prepare \
  --home "$TRELLIS_HOME" \
  --project-id "$PROJECT_ID" \
  "$PROJECT_ROOT"
```

The command prints `snapshot: ...` and its exact rollback invocation. After reviewing the result, attach the migrated project through the normal all-three-harness command in the prior section. If migration itself must be reversed before further project changes, use only that recorded snapshot:

```bash
"$TRELLIS" migrate --rollback "$SNAPSHOT"
```

### Import a historical tracked registry

The tracked `registry.md`/`blacklist.md` were removed at `v1.0.0-rc.25`, so `LEGACY_REGISTRY` now names a file the operator supplies — extract it from history with `git show <pre-cutover-sha>:registry.md > /tmp/legacy-registry.md`, or use a backup. A machine coming from the legacy tracked inventory imports it once, into a fleet that already exists in this machine's config — `registry import` refuses a fleet `configure.sh fleet add` has never created, because fleet-scoped rows no `doctor --fleet NAME` can inspect are worse than no rows. Import reads the legacy Markdown read-only and writes only private `registry.json`.

A historical registry usually records a portable shorthand path such as `/personal/<name>`, since a tracked file must carry no machine paths. `--projects-root PATH` is the explicit, operator-supplied statement of where that shorthand lives here: each row path that is not an existing absolute path is resolved as `PATH` + the recorded row path, the resolved path becomes the row root, and the recorded shorthand is retained as `legacy.legacy_path` metadata. A resolved path that does not exist still imports as a visible unavailable row at the resolved path. Without the flag every recorded path is used exactly as written.

```bash
: "${LEGACY_REGISTRY:?Set the exact historical registry.md path}"
: "${PROJECTS_ROOT:?Set the absolute root the recorded shorthand hangs from}"
"$TRELLIS" registry import \
  --home "$TRELLIS_HOME" \
  --fleet "$FLEET" \
  --registry "$LEGACY_REGISTRY" \
  --projects-root "$PROJECTS_ROOT"
"$TRELLIS" registry list --home "$TRELLIS_HOME" --fleet "$FLEET"
```

The complete import, parity-review, and cutover procedure — including the blacklist pair, the seven-cell row contract, and how a literal `|` is written `\|` in a cell — is [`docs/MIGRATING-LOCAL-FLEETS.md`](docs/MIGRATING-LOCAL-FLEETS.md) §2.

## 7. Verify local state and the attached project

Verify the installed payload, inspect only the selected fleet, and make `doctor` resolve the project by its recorded identity. Inspection runs through the same fixed launcher as every other command: `trellis show-config [--home PATH] [--fleet NAME]` executes `scripts/show-config.sh` from the verified immutable payload, never from the mutable source clone.

Two preconditions come with that route, because the launcher crosses an `env -i` boundary before the payload runs:

- The launcher resolves a home of its own — `TRELLIS_HOME`, else `$HOME/.trellis` — and refuses before dispatch if that home has no verified active release. `--home PATH` then selects which machine state to render; it is not a way to reach an unconfigured launcher.
- `TRELLIS_FLEET` does not survive the boundary. Select the fleet with `--fleet NAME`; with neither, the rendered home's `default_fleet` applies.

Sections 1 and 2 already export `TRELLIS_HOME` and set `FLEET`, and section 3 installed and verified the active release into that home, so the block below satisfies both preconditions as written.

```bash
"$TRELLIS" release verify "$RELEASE_VERSION"
"$TRELLIS" registry list --home "$TRELLIS_HOME" --fleet "$FLEET"
"$TRELLIS" doctor \
  --home "$TRELLIS_HOME" \
  --fleet "$FLEET" \
  --project "$PROJECT_ID"

(
  cd "$PROJECT_ROOT"
  "$TRELLIS" show-config --home "$TRELLIS_HOME" --fleet "$FLEET"
  git status --short
)
```

Before the project owner commits a newly created manifest, `git status` may show that intentional tracked file. After it is committed, attachment state must not dirty the project. An unavailable local-registry row remains explicit; do not guess an alternative path or recreate `$PROJECTS_ROOT/<name>`.

## 8. Move, relink, recover, and detach safely

### Move the policy source clone

A moved policy source clone changes only local machine configuration. The existing project runtime stays on its immutable installed payload. Reconfigure the source location, then relink the recorded project only if its owned runtime anchor needs repair:

```bash
: "${NEW_SOURCE_ROOT:?Set the moved policy source clone path explicitly}"
NEW_SOURCE_ROOT="$(cd "$NEW_SOURCE_ROOT" && pwd -P)"
"$TRELLIS" configure --source "$NEW_SOURCE_ROOT" --home "$TRELLIS_HOME" --no-install-launcher
"$TRELLIS" relink --home "$TRELLIS_HOME" --fleet "$FLEET" "$PROJECT_ROOT"
```

### Move a project checkout

`relink` repairs an immutable runtime anchor; it does not guess or rewrite a moved checkout location. Detach before relocating a checkout, then attach the new explicit path.

```bash
: "${NEW_PROJECT_ROOT:?Set the destination checkout path explicitly}"
"$TRELLIS" detach --home "$TRELLIS_HOME" --all-worktrees "$PROJECT_ROOT"
# Move the checkout with the operator's chosen filesystem operation.
"$TRELLIS" attach \
  --home "$TRELLIS_HOME" \
  --fleet "$FLEET" \
  --release "$RELEASE_VERSION" \
  --harness claude \
  --harness codex \
  --harness omp \
  "$NEW_PROJECT_ROOT"
```

### Recover interruption or opt out locally

Run recovery only after `doctor` identifies an interrupted transaction for this exact worktree. Detachment removes only attachment-owned local artifacts and leaves `.trellis.json` intact and inert.

```bash
"$TRELLIS" recover --home "$TRELLIS_HOME" "$PROJECT_ROOT"
"$TRELLIS" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"

"$TRELLIS" detach --home "$TRELLIS_HOME" --all-worktrees "$PROJECT_ROOT"
```

## 9. Adopt or roll back a release explicitly

Never edit a project runtime anchor by hand. Managed adoption first verifies the target immutable release, then changes only strict local-registry rows whose attachment ownership matches. Unavailable rows remain explicit and no path is inferred.

The safe default is one recorded project in one fleet:

```bash
: "${TARGET_RELEASE:?Set the exact immutable release to adopt}"
"$TRELLIS" release verify "$TARGET_RELEASE"
"$TRELLIS" release adopt "$TARGET_RELEASE" --project "$PROJECT_ID" --fleet "$FLEET"
"$TRELLIS" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"
```

`--project "$PROJECT_ID"` without `--fleet` is allowed only when the local registry resolves that ID uniquely; ambiguity fails closed. A reviewed fleet-wide adoption uses `"$TRELLIS" release adopt "$TARGET_RELEASE" --fleet "$FLEET"`; a reviewed all-fleet adoption uses `"$TRELLIS" release adopt "$TARGET_RELEASE" --all`. Choose exactly one scope—do not turn a project repair into a fleet or all-fleet change.

Rollback is the same explicit operation with a previously installed and verified version, never a source-checkout link:

```bash
: "${ROLLBACK_RELEASE:?Set the previously verified immutable release to restore}"
"$TRELLIS" release verify "$ROLLBACK_RELEASE"
"$TRELLIS" release adopt "$ROLLBACK_RELEASE" --project "$PROJECT_ID" --fleet "$FLEET"
"$TRELLIS" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"
```

`release adopt VERSION --runtime-anchor PATH` is compatibility-only. Normal local-fleet setup must use the registry-targeted commands above.

## 10. Failure handling and completion

Treat exit class `2` as bad arguments, `3` as an ownership/identity conflict, `4` as invalid or corrupt local state, and `5` as an unavailable path, remote, or required capability. Read the reported condition; do not delete local state, alter a project-owned file, or guess a missing checkout to force progress.

A complete local setup has all of the following observed facts:

1. A chosen `TRELLIS_HOME` has separate `personal` and `work` fleet configuration.
2. The exact release was installed and verified before any attachment.
3. Each attached project has a reviewed portable `.trellis.json`, a strict local registry row, and all three harnesses explicitly attached from the immutable payload.
4. `trellis doctor` and `trellis show-config` resolve the selected fleet/project through the launcher, without using a common projects root.
5. A raw contributor clone stays inert, while the operator has the migration snapshot, recovery path, detach path, and verified-release rollback procedure needed to undo local changes.
