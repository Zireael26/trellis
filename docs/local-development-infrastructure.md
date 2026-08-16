# Local development infrastructure

Trellis coordinates local infrastructure **selection**; the external
shared-infrastructure repository owns its runtime, manifest, allocations, and
Make targets. This boundary keeps machine paths out of tracked policy and keeps
one fleet from accidentally operating another fleet's services.

## Local source of truth

A shared-infrastructure root is optional, machine-local state at:

```text
<TRELLIS_HOME>/config.json
  .fleets[<selected-fleet>].shared_infra_root
```

It is not a field in `trellis.config.json`, a project manifest, a README, or a
conventional sibling directory. Normal consumers must obtain
`SHARED_INFRA_ROOT` through Trellis's validated local configuration loading for
the selected fleet. They must not accept a guessed path, fall back to
`$HOME/projects/shared-infra`, or derive it from the current checkout.

Selection follows the normal local-state precedence:

1. an explicit `--home` or `--fleet` argument;
2. `TRELLIS_HOME` or `TRELLIS_FLEET`;
3. the validated machine configuration's default fleet.

Configure or update the selected fleet from the Trellis source checkout. These
commands write only local machine state:

```bash
TRELLIS_HOME="/absolute/path/to/trellis-home"
FLEET="personal"
SHARED_INFRA_ROOT="/absolute/path/to/shared-infra"

./scripts/trellis fleet update "$FLEET" \
  --home "$TRELLIS_HOME" \
  --shared-infra-root "$SHARED_INFRA_ROOT"
```

For an initial setup, use `./scripts/trellis configure` with an explicit
`--default-fleet`, one or more `--discovery-root` values, and optionally
`--shared-infra-root`; see `./scripts/trellis configure --help` for the exact
arguments. A configured root is not usable until the local configuration loader
has validated the selected fleet and the root is available as a real directory.
If no `shared_infra_root` is configured, the fleet has no shared-infrastructure
delegation to perform.

## Project identity and worktree boundary

Every infrastructure handoff needs two separate values:

- `PROJECT_ID`: the exact `project_id` registered in the selected local fleet;
- `PROJECT_ROOT`: one exact available `kind: "worktree"` registry `root` for
  that project.

List the selected fleet's local registry before choosing either value:

```bash
./scripts/trellis registry list \
  --home "$TRELLIS_HOME" \
  --fleet "$FLEET" \
  --json
```

Set `PROJECT_ID` and `PROJECT_ROOT` from that output, then verify the exact
pair rather than reconstructing a path from the ID:

```bash
PROJECT_ID="example-project"
PROJECT_ROOT="/absolute/path/copied/from-the-local-registry"

./scripts/trellis registry list \
  --home "$TRELLIS_HOME" \
  --fleet "$FLEET" \
  --json \
| jq -e --arg project "$PROJECT_ID" --arg root "$PROJECT_ROOT" '
    any(.entries[];
      .project_id == $project
      and .kind == "worktree"
      and .availability == "available"
      and .status == "active"
      and ((.excluded // false) | not)
      and .root == $root)
  '
```

A project can have multiple clones or linked worktrees. The caller chooses one
recorded available root deliberately; it must never synthesize
`$PROJECTS_ROOT/$PROJECT_ID`, use a tracked registry row, or substitute a
similarly named directory. A row whose root is unavailable, missing, detached,
or excluded is diagnostic state, not a Make input. Report it and stop or choose
a different available row.

## External shared-infrastructure contract

The external `shared-infra` repository is a separate dependency. It owns:

- the shared runtime and lifecycle;
- the service/allocation manifest and any secrets it references;
- validation, reconciliation, reset, and health semantics;
- atomic allocation changes and rollback behavior.

This repository does **not** implement or attest to the external Make contract.
The following interface is the required delegation shape for a reviewed external
shared-infra release; do not infer that a target is available merely because it
is named here:

| Operation | Required delegated form |
|---|---|
| Validate one identity/root pair | `make -C "$SHARED_INFRA_ROOT" validate PROJECT="$PROJECT_ID" SOURCE="$PROJECT_ROOT"` |
| Preflight a project | `make -C "$SHARED_INFRA_ROOT" preflight PROJECT="$PROJECT_ID" SOURCE="$PROJECT_ROOT"` |
| Start or reconcile a project | `make -C "$SHARED_INFRA_ROOT" up PROJECT="$PROJECT_ID" SOURCE="$PROJECT_ROOT"` |
| Reconcile without native app startup | `make -C "$SHARED_INFRA_ROOT" reconcile PROJECT="$PROJECT_ID" SOURCE="$PROJECT_ROOT"` |
| Diagnose a project | `make -C "$SHARED_INFRA_ROOT" doctor PROJECT="$PROJECT_ID" SOURCE="$PROJECT_ROOT"` |
| Produce a review-only proposal | `make -C "$SHARED_INFRA_ROOT" propose PROJECT="$PROJECT_ID" SOURCE="$PROJECT_ROOT" OUTPUT="$PROPOSAL"` |
| Apply a reviewed allocation | `make -C "$SHARED_INFRA_ROOT" register PROJECT="$PROJECT_ID" SOURCE="$PROJECT_ROOT" ENTRY="$ENTRY"` |

The external prerequisite is a separately reviewed shared-infra change that
accepts this fleet-local identity/root handoff and preserves its atomic
allocation behavior. Until that change is available and verified in the
external repository, do not represent these commands as implemented end-to-end
or add a second local manifest in Trellis.

## Safe delegation procedure

After the selected configuration and exact registry row have both been
validated, an operator may prepare the external call inputs:

```bash
: "${SHARED_INFRA_ROOT:?resolve this from validated selected-fleet state}"
: "${PROJECT_ID:?set the selected local registry project_id}"
: "${PROJECT_ROOT:?set the exact selected available registry root}"

test -d "$SHARED_INFRA_ROOT"
test -f "$SHARED_INFRA_ROOT/Makefile"
```

When the external contract prerequisite is present, proposal and registration
remain separate actions:

```bash
PROPOSAL="/absolute/path/outside-the-project/proposal.yaml"
ENTRY="/absolute/path/to/reviewed-entry.yaml"

make -C "$SHARED_INFRA_ROOT" propose \
  PROJECT="$PROJECT_ID" SOURCE="$PROJECT_ROOT" OUTPUT="$PROPOSAL"
# Review the proposal and allocation deliberately before continuing.
make -C "$SHARED_INFRA_ROOT" register \
  PROJECT="$PROJECT_ID" SOURCE="$PROJECT_ROOT" ENTRY="$ENTRY"
make -C "$SHARED_INFRA_ROOT" reconcile \
  PROJECT="$PROJECT_ID" SOURCE="$PROJECT_ROOT"
```

A project-owned startup wrapper may call project-scoped `preflight` and `up`
only after it has resolved the same validated fleet-local root and exact
registry identity/root pair. It must not call a fleet-wide stop, reset shared
volumes, delete another project's allocation, or treat an unavailable row as a
fallback path.

## Verification and recovery

Use the local registry to verify selection before each delegated operation:

```bash
./scripts/trellis registry list \
  --home "$TRELLIS_HOME" \
  --fleet "$FLEET" \
  --json
```

Then use the external repository's reviewed `validate`, `doctor`, and
project-scoped recovery targets with the same `PROJECT_ID` and `PROJECT_ROOT`.
Trellis's own doctor remains a separate local attachment and registry health
check; it does not prove the external runtime's allocation semantics.

If a worktree becomes unavailable, retain the local registry row and report the
recorded path. Do not remove it as a convenience, do not reconstruct it under a
discovery root, and do not run external Make against it. Recover the volume or
register a different available worktree explicitly. If the configured
`shared_infra_root` is unavailable or no longer validates for the selected
fleet, stop delegation and repair that fleet's local configuration; do not
borrow another fleet's root.

## Non-goals

This guide does not define service names, ports, credentials, containers,
project allocations, reset behavior, or the external repository's implementation
status. Those are owned and documented by the external shared-infrastructure
repository once its fleet-local handoff contract has been reviewed and merged.
