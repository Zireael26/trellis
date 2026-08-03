# Optional shared local infrastructure

Trellis projects run their applications natively. An operator may separately provide a shared local-infrastructure repository for data services and other reusable development dependencies, but that repository remains outside the Trellis template and outside each application's normal runtime.

The supported shared-service families are PostgreSQL with pgvector, Redis, MinIO, and Mailpit. The external repository decides which of them to provide and how to allocate them; Trellis does not assign public default ports, credentials, databases, indexes, buckets, or message tags.

The public Trellis template does **not** ship or own that external runtime repository, its manifest, credentials, service allocations, or fixed-port map. Trellis only integrates with an operator-supplied repository when the operator opts in.

## Enable or leave disabled

The integration is enabled by the optional `trellis.config.json.shared_infra_root` key:

```bash
SHARED_INFRA_ROOT="$(jq -r '.shared_infra_root // empty' trellis.config.json)"
if [ -n "$SHARED_INFRA_ROOT" ]; then
  test -d "$SHARED_INFRA_ROOT"
  test -f "$SHARED_INFRA_ROOT/Makefile"
fi
```

When the key is absent, shared-infrastructure integration is disabled. Project onboarding continues through the ordinary one-argument flow, Trellis doctor skips shared-infrastructure checks, no manifest entry is required, and legacy onboarding and doctor behavior remain intact.

When the key is present, it must resolve to the separately managed repository. Adding the key does not make Trellis the owner or provisioner of that repository.

Project-side checks accept a `SHARED_INFRA_ROOT` environment override and otherwise compare against the conventional `$HOME/projects/shared-infra` location. If the configured repository lives elsewhere, export `SHARED_INFRA_ROOT` to the configured path when running project-side startup or doctor checks; the seeded preflight wrapper also carries the configured path.

## External repository contract

An opted-in repository is expected to expose these Make targets. Its own documentation and schema remain authoritative.

| Target | Expected boundary |
|---|---|
| `propose` | Inspect a project conservatively and write a reviewable proposal without changing the external manifest. |
| `register` | Atomically add or replace one operator-reviewed project fragment, then validate the candidate manifest. |
| `validate` | Check manifest shape, references, allocations, and fixed-port uniqueness. |
| `preflight` | Reject conflicting declarations or occupied declared ports before project startup. |
| `reconcile` | Converge only the requested declaration and remain safe to repeat. |
| `up` | Start only the externally declared shared-service subset, then reconcile it. |
| `doctor` | Perform read-only manifest, runtime, registry-parity, and port checks. |

Trellis delegates to this interface; it does not define the external repository's Compose topology, credentials, allocation policy, or destructive recovery commands.

## Reviewed declaration

A proposal is evidence, not approval. Review every service and fixed listener before registration. The reviewed file contains only the external repository's `services` and `ports` fragment. A project that consumes no shared service still uses an explicit empty declaration when the integration is enabled:

```yaml
services: {}
ports: {}
```

Non-empty declarations follow the external repository's schema. Use placeholders while reviewing; do not copy credentials or operator allocations into Trellis documentation.

## Onboarding flow

Resolve the optional key first and keep the disabled path ordinary:

```bash
PROJECT_ROOT="${PROJECT_ROOT:?set the absolute project path}"
PROJECT_NAME="${PROJECT_NAME:?set the reviewed registry name}"
SHARED_INFRA_ROOT="$(jq -r '.shared_infra_root // empty' trellis.config.json)"

if [ -n "$SHARED_INFRA_ROOT" ]; then
  PROPOSAL_FILE="${PROPOSAL_FILE:?set a proposal output path}"
  REVIEWED_ENTRY="${REVIEWED_ENTRY:?set the reviewed fragment path}"

  make -C "$SHARED_INFRA_ROOT" propose \
    PROJECT="$PROJECT_NAME" SOURCE="$PROJECT_ROOT" OUTPUT="$PROPOSAL_FILE"
  # Stop here for operator review. After approval:
  ./scripts/onboard-project.sh "$PROJECT_ROOT" --infra-entry "$REVIEWED_ENTRY"
else
  ./scripts/onboard-project.sh "$PROJECT_ROOT"
fi
```

With integration enabled, onboarding delegates registration and project-scoped reconciliation to the external repository and seeds `scripts/local-infra-preflight.sh`. Wire that wrapper into the native startup path before the application or project-owned infrastructure binds a fixed listener.

The wrapper performs project-scoped preflight. An explicit `services: {}` project does not start shared services. A project with declared shared services may delegate project-scoped `up`; migrations and the native application still run from the project repository.

Project shutdown stops only native processes and project-owned infrastructure. It must never stop the shared runtime, invoke a shared `down`, delete shared volumes, or reset another project.

## Verification

Always run the ordinary Trellis checks. Run shared-infrastructure checks only when the optional key is non-empty:

```bash
./scripts/doctor.sh --project "$PROJECT_NAME"

if [ -n "$SHARED_INFRA_ROOT" ]; then
  make -C "$SHARED_INFRA_ROOT" validate PROJECT="$PROJECT_NAME"
  make -C "$SHARED_INFRA_ROOT" doctor \
    PROJECT="$PROJECT_NAME" REGISTRY_FILE="$PWD/registry.md"
  test -x "$PROJECT_ROOT/scripts/local-infra-preflight.sh"
  "$PROJECT_ROOT/scripts/local-infra-preflight.sh"
fi
```

For a live project proof, run preflight before startup, start only the declared shared-service subset and project-owned infrastructure, run migrations, then start the application natively. Record the shared runtime identity before project shutdown and confirm shutdown leaves it unchanged.

## Recovery boundary

Prefer non-destructive, project-scoped recovery. Rerun `make -C "$SHARED_INFRA_ROOT" reconcile PROJECT="$PROJECT_NAME"`, then rerun migrations, the external doctor, Trellis doctor, and the native smoke path. Use any reset or shared-runtime stop operation only through the external repository's operator-approved procedure.

A failed project migration or startup does not justify stopping the shared runtime for other projects. Trellis configuration rollback uses normal version-control reverts; it does not create or preserve a hidden second infrastructure path.
