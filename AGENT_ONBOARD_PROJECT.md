# AGENT_ONBOARD_PROJECT.md — paste-into-agent portable project onboarding

> **For the human:** complete [local machine setup](AGENT_SETUP.md) first. Open an agent in the Trellis policy source clone if convenient, but give it the installed launcher path, the existing Git worktree path, the local fleet, the exact installed release version, and permission to create or migrate the project's tracked `.trellis.json`. Then paste everything below the `--- BEGIN PROMPT ---` line.
>
> This is local opt-in onboarding. It never adds a project to a tracked central registry, never assumes a common projects root, and never makes a source checkout the project's runtime. It attaches Claude Code, Codex, and OMP from a verified immutable release. A contributor who only clones the project and does not attach it remains inert.

For the architecture, migration decision record, and release rollback policy, use the local-fleet documents maintained alongside this runbook: [`docs/MIGRATING-LOCAL-FLEETS.md`](docs/MIGRATING-LOCAL-FLEETS.md), [`docs/UPGRADING.md`](docs/UPGRADING.md), and [`docs/adr/2026-08-12-local-fleets-immutable-releases.md`](docs/adr/2026-08-12-local-fleets-immutable-releases.md).

---

## --- BEGIN PROMPT ---

You are onboarding one existing Git worktree into the operator's **local** Trellis fleet. Work only on the supplied project and the supplied `TRELLIS_HOME`. Do not edit tracked fleet inventory, do not infer a checkout path from a project name, and do not make a project runtime point at or execute its normal operations through this source checkout.

### 1. Establish the local contract

Ask for and repeat back before mutation:

- `PROJECT_INPUT` — an existing project path, anywhere on disk; it must resolve to that Git worktree's top level.
- `FLEET` — the already configured local fleet, such as `personal` or `work`.
- `RELEASE_VERSION` — the exact immutable Trellis release to attach. Never choose “latest” or derive it from the source checkout.
- `PROJECT_ID` — a stable portable ID only when the project has no `.trellis.json` yet. It is not a filesystem path or fleet name.
- Explicit approval to create the portable manifest or to migrate legacy Trellis artifacts.

The policy source clone may be the current directory, but it is not the normal CLI. Establish only variables that make the destination explicit, then use the fixed installed launcher:

```bash
TRELLIS_CLI="$HOME/.local/bin/trellis"
test -x "$TRELLIS_CLI"

: "${TRELLIS_HOME:?Set the selected local Trellis home explicitly}"
export TRELLIS_HOME
: "${PROJECT_INPUT:?Set the existing project path explicitly}"
: "${FLEET:?Set the local fleet explicitly}"
: "${RELEASE_VERSION:?Set the exact installed immutable release explicitly}"

PROJECT_ROOT="$(git -C "$PROJECT_INPUT" rev-parse --show-toplevel)"
git -C "$PROJECT_ROOT" status --short
```

`TRELLIS_HOME` holds machine state: local machine configuration, local registry rows, immutable release payloads, attachment ownership, and recovery journals. It is not committed. The only normal tracked Trellis footprint in the project is `.trellis.json`, which contains portable project identity and policy only. It must not contain a home path, a fleet, a release payload path, or live harness artifacts.

Trellis does not configure credentials, model/provider choices, or harness trust stores. Do not omit a supported surface merely because its host application is not open; this runbook explicitly attaches `claude`, `codex`, and `omp`.

### 2. Preflight the immutable release and project layout

Verify the exact release before any project mutation:

```bash
"$TRELLIS_CLI" release verify "$RELEASE_VERSION"
```

Inspect the manifest state without changing it:

```bash
if [ -L "$PROJECT_ROOT/.trellis.json" ]; then
  printf '%s\n' 'Refuse: .trellis.json must be an ordinary file, never a symlink.' >&2
  exit 3
elif [ -f "$PROJECT_ROOT/.trellis.json" ]; then
  PROJECT_ID="$(jq -r '.project_id' "$PROJECT_ROOT/.trellis.json")"
  printf 'portable manifest present for project ID: %s\n' "$PROJECT_ID"
else
  : "${PROJECT_ID:?Choose and confirm a portable project ID before onboarding}"
  printf 'no portable manifest; onboarding will create one for project ID: %s\n' "$PROJECT_ID"
fi
```

Do not manufacture a `CLAUDE.md` `@` import, copy hooks or settings into the project, create direct links to `SOURCE_ROOT`, or edit `.gitignore` to hide arbitrary paths. Attachment owns its exact local artifacts and its exact Git-local exclusion block.

### 3. Choose the correct path

#### New portable project

For a project with no legacy Trellis artifacts and no manifest, run portable onboarding. It creates the inert tracked manifest and performs one explicit three-harness attachment from the already verified release:

```bash
"$TRELLIS_CLI" onboard \
  --home "$TRELLIS_HOME" \
  --fleet "$FLEET" \
  --release "$RELEASE_VERSION" \
  --project-id "$PROJECT_ID" \
  --harness claude \
  --harness codex \
  --harness omp \
  "$PROJECT_ROOT"
```

If this command reports a legacy or mixed Trellis layout, stop. Do not retry with ad hoc deletes or a direct-link workaround; use the migration path below. `onboard --legacy` is a compatibility-only route and is not the normal portable onboarding path.

#### Existing portable manifest

For a fresh clone or detached checkout that already contains a valid `.trellis.json`, attach it explicitly. This uses the manifest ID and records the current checkout path only in the local registry:

```bash
"$TRELLIS_CLI" attach \
  --home "$TRELLIS_HOME" \
  --fleet "$FLEET" \
  --release "$RELEASE_VERSION" \
  --harness claude \
  --harness codex \
  --harness omp \
  "$PROJECT_ROOT"
```

#### Legacy direct-link project

For legacy links, imports, copied harness state, or a legacy project policy, prepare a reversible migration before attachment. Review the project diff and the emitted snapshot path; `--prepare` never stages or commits the project change.

```bash
"$TRELLIS_CLI" migrate --prepare \
  --home "$TRELLIS_HOME" \
  --project-id "$PROJECT_ID" \
  "$PROJECT_ROOT"
```

The command prints both `snapshot: ...` and the exact rollback command. Record that path as `SNAPSHOT`, then attach all three harnesses only after the migration result is understood:

```bash
"$TRELLIS_CLI" attach \
  --home "$TRELLIS_HOME" \
  --fleet "$FLEET" \
  --release "$RELEASE_VERSION" \
  --harness claude \
  --harness codex \
  --harness omp \
  "$PROJECT_ROOT"
```

If migration must be reverted before any further project change, use only the emitted snapshot:

```bash
"$TRELLIS_CLI" migrate --rollback "$SNAPSHOT"
```

### 4. Separate the tracked manifest from local attachment state

Show the project owner the new or changed `.trellis.json` and have them review it as a normal project change. It is the portable, inert declaration that can be committed. Do not stage or commit local attachment leaves, runtime anchors, generated harness surfaces, local hooks, local exclusions, `$TRELLIS_HOME`, or registry data.

A project clone containing only the committed `.trellis.json` has no active Trellis behavior: it does not require Trellis to be installed and must not trigger Claude Code, Codex, or OMP discovery failures. Local behavior begins only after this explicit attachment command on the operator's machine.

### 5. Verify the local attachment

Use the recorded project identity and fleet; do not reconstruct a path from a project name or a discovery root.

```bash
"$TRELLIS_CLI" release verify "$RELEASE_VERSION"
"$TRELLIS_CLI" registry list --home "$TRELLIS_HOME" --fleet "$FLEET"
"$TRELLIS_CLI" doctor \
  --home "$TRELLIS_HOME" \
  --fleet "$FLEET" \
  --project "$PROJECT_ID"

(
  cd "$PROJECT_ROOT"
  "$TRELLIS_CLI" show-config --home "$TRELLIS_HOME" --fleet "$FLEET"
  git status --short
)
```

`show-config` is a dispatcher route like every other command, so this inspection also runs `scripts/show-config.sh` from the verified immutable payload rather than from the source clone. The launcher crosses an `env -i` boundary to get there, which adds two preconditions the block above already satisfies: `$TRELLIS_CLI` must resolve a launcher home of its own (`TRELLIS_HOME`, else `$HOME/.trellis`) with a verified active release — `--home` selects what to render, not where the launcher looks for its payload — and `TRELLIS_FLEET` is not carried across, so the fleet must come from `--fleet` (otherwise the rendered home's `default_fleet` applies). Before the portable manifest is committed, `git status` may show that intended tracked file. After it is committed, attachment-owned local state must not make the project dirty.

### 6. Handle interruption, movement, detachment, and release changes

For an interrupted attach or detach, first inspect `doctor`; run recovery only for the exact affected worktree:

```bash
"$TRELLIS_CLI" recover --home "$TRELLIS_HOME" "$PROJECT_ROOT"
"$TRELLIS_CLI" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"
```

A source-clone move is repaired through the already installed launcher by updating local machine configuration and relinking the recorded immutable runtime. Do not edit tracked project files or invoke a dispatcher from the moved source clone:

```bash
: "${NEW_SOURCE_ROOT:?Set the moved policy source clone path explicitly}"
NEW_SOURCE_ROOT="$(cd "$NEW_SOURCE_ROOT" && pwd -P)"
"$TRELLIS_CLI" configure --source "$NEW_SOURCE_ROOT" --home "$TRELLIS_HOME" --no-install-launcher
"$TRELLIS_CLI" relink --home "$TRELLIS_HOME" --fleet "$FLEET" "$PROJECT_ROOT"
```

To relocate a project checkout, detach before moving it and attach at its new explicit path. `relink` repairs an attachment's immutable runtime anchor; it does not guess or rewrite a moved checkout path.

```bash
: "${NEW_PROJECT_ROOT:?Set the destination checkout path explicitly}"
"$TRELLIS_CLI" detach --home "$TRELLIS_HOME" --all-worktrees "$PROJECT_ROOT"
# Move the checkout using the operator's chosen filesystem operation.
"$TRELLIS_CLI" attach \
  --home "$TRELLIS_HOME" \
  --fleet "$FLEET" \
  --release "$RELEASE_VERSION" \
  --harness claude \
  --harness codex \
  --harness omp \
  "$NEW_PROJECT_ROOT"
```

For an intentional local opt-out, detach exactly the attached worktree (or use `--all-worktrees` when that is the intent). Detach removes only artifacts it owns and leaves the tracked portable manifest alone:

```bash
"$TRELLIS_CLI" detach --home "$TRELLIS_HOME" --all-worktrees "$PROJECT_ROOT"
```

For release adoption or rollback, never repoint a runtime link by hand and never substitute a mutable source checkout. Verify the exact installed target, adopt it through the local project identity, and rerun `doctor`:

```bash
: "${TARGET_RELEASE:?Set the exact immutable release to adopt}"
"$TRELLIS_CLI" release verify "$TARGET_RELEASE"
"$TRELLIS_CLI" release adopt "$TARGET_RELEASE" --project "$PROJECT_ID" --fleet "$FLEET"
"$TRELLIS_CLI" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"
```

For rollback, replace `TARGET_RELEASE` with a previously installed and verified version and run the same project-targeted adoption. `--project "$PROJECT_ID"` without `--fleet` is valid only when it resolves uniquely; wider `--fleet "$FLEET"` and `--all` adoption require separate explicit operator approval. Compatibility-only `--runtime-anchor` adoption is not a portable onboarding path.

### 7. Final report

Report only observed facts:

1. Project root, project ID, local fleet, exact verified release, and the three attached harnesses.
2. Whether `.trellis.json` was created, already present, or migrated; its review/commit remains the project owner's tracked change.
3. The local verification commands and their results, including any unavailable registry row or recovery journal.
4. The migration snapshot path, if one was created, and the rollback command it printed.
5. Any collision or foreign project-owned file that caused a safe refusal.

Do not push, commit, edit a central registry, or claim that an unattached contributor receives Trellis behavior.

## --- END PROMPT ---
