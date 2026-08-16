# 2026-08-12 — Local fleets and immutable releases

**Status:** Accepted

## Context

Trellis previously treated one mutable canonical checkout, a tracked fleet
registry, and project-local live inheritance links as the operating model. That
model made a machine path and the state of one source checkout runtime authority
for every attached project. Moving, dirtying, or changing the source checkout
could therefore change project behavior without an explicit project operation.
The tracked registry also published machine-specific inventory and paths, while
raw contributors inherited mutable local artifacts or had to reconstruct a
machine-specific setup from committed files.

The model cannot safely support multiple local fleets, arbitrary checkout
locations, independently moving source clones, or three native harnesses. It
also conflates project-owned files with Trellis-managed files: a broad harness
directory link or cleanup can overwrite a project-owned surface, and a tracked
ignore fragment is the wrong ownership boundary for local attachment state.

## Decision

Trellis uses portable tracked project policy plus private, machine-local
attachment state. The source checkout is a management and publication checkout;
it is never attached-project runtime authority.

- A project's normal tracked Trellis state is the inert `.trellis.json` manifest.
  It carries portable project identity and policy only. It does not carry a
  filesystem path, fleet, selected release, home directory, or live harness
  state.
- `TRELLIS_HOME` holds private machine configuration, named fleet definitions,
  local registry records, installed releases, attachment ownership records,
  hook dispatch state, and recovery journals. A registry maps a portable project
  ID to the machine's arbitrary checkout and worktree paths; unavailable paths
  remain explicit registry state rather than being removed or reconstructed.
- Attached projects run from one verified immutable release payload. A release
  record binds a version, annotated tag, commit, remote, and complete tree
  inventory. Installation verifies the recorded tree and modes, makes the
  payload read-only, and atomically publishes a new version without replacing an
  existing one. Release selection changes only through explicit installation and
  adoption; there is no implicit "latest" or source-checkout fallback.
- An attachment creates a local absolute `.trellis/runtime` anchor to the
  selected payload. Claude Code, Codex, and OMP surfaces are relative links or
  rendered local settings beneath that anchor, so a release adoption changes the
  anchor rather than copying mutable policy into a project.
- The release-owned `core-rules/inheritance-manifest.json` is the only surface
  inventory. It expands listed leaf links and rendered settings for Claude Code,
  Codex, and OMP; it does not take ownership of an entire harness directory.
  Attachment preflights every destination and parent, refuses project-owned
  collisions, records exact ownership, and writes through a journaled atomic
  transaction. Detach removes only artifacts that still exactly match that
  ownership record.
- Worktrees are attachments under a locally registered clone and its recorded
  immutable release. Their harness surfaces are attached before discovery.
  A clone-local dispatcher may coordinate opted-in worktrees, but raw clones and
  repositories without a local registration remain inert. Session-start
  diagnosis reports missing or inconsistent attachment state; it does not repair
  or execute project paths.
- Local attachment artifacts are excluded through an owned managed block in the
  Git common directory's `.git/info/exclude`, not by generated tracked
  `.gitignore` content. The block persists only while an attachment owns it and
  is restored or removed through the same ownership and transaction rules.
- Commands execute only from a verified release, through one fixed launcher
  installed outside any checkout. The launcher freezes a digest-pinned execution
  snapshot of the active release and runs children from that snapshot rather
  than from the installed release directory; the `release` and `upgrade` routes
  are carried as in-memory command bundles bound to the same digest, so upgrade
  never reopens a script pathname. Gated commands refuse by default unless the
  launcher's attestation is present. Exactly one bootstrap route exists before
  an active release is installed.
- Registry consumers share one row vocabulary named for exit classes —
  `available`, `unavailable`, `identity_error` — and a failed row is reported
  rather than repaired, removed, or reconstructed. A fault in one row lets the
  run continue to the other selected rows; a global environment fault fails the
  whole command. Writes re-validate bound-row identity under the lock and apply
  the whole-file schema, and a command exits on the highest class produced.

## Security boundaries

- **Release trust boundary.** Runtime policy comes only from a verified,
  read-only installed payload whose contents and modes match its release record.
  A mutable source checkout, an environment default, or a missing payload cannot
  silently substitute for the recorded release.
- **Execution boundary.** The source gate on release, upgrade, mirror, and
  configuration-rendering commands is attestation-based and default-refuse: it
  binds to the payload identity the launcher exports and to nothing else, and
  runs before any library is sourced or any argument — including `--help` — is
  parsed. The rejected alternative was identity-based, asking whether a machine
  config named the running copy as its source; that question is undecidable for
  a source copy, a worktree, an unpacked tarball, or a clone at an unnamed path,
  and every undecidable case allowed. A gate whose undecidable case allows is
  not a gate.
- **Diagnostic boundary.** Registry roots and names reach a terminal only
  through the shared control-character-rejecting helper, so a corrupt or hostile
  recorded path cannot rewrite the operator's terminal by being reported.
- **Machine-state boundary.** Fleet membership, checkout paths, release choices,
  attachment records, and recovery data remain private under `TRELLIS_HOME`.
  They are not project policy and are not committed or published.
- **Project-ownership boundary.** Attachment owns only manifest-listed leaves,
  its exact local exclude block, and its recorded hook state. Preflight rejects
  collisions, rollback removes only transaction-created artifacts, and detach
  refuses altered or repointed artifacts instead of deleting project-owned data.
- **Path and process boundary.** Local registry paths are validated as absolute,
  safe records; unavailable locations are diagnostic state. Environment or CLI
  input that conflicts with a recorded attachment fails closed rather than
  retargeting it. A hook or SessionStart check diagnoses an opted-in attachment
  but does not turn a raw checkout into one.

## Compatibility and cutover sequence

1. The compatibility release introduces the private home, local registry,
   immutable release store, transactional attachment, migration/import support,
   and dual-layout diagnosis while retaining legacy direct-link onboarding for
   one release. Existing tracked registry and blacklist data are imported and
   verified as machine-local inventory; they are not deleted at import time.
2. Project owners migrate in reviewable project changes: remove
   Trellis-generated tracked behavior and absolute parent imports, retain
   project-owned harness files, add or migrate the portable `.trellis.json`, and
   prove that a fresh un-attached clone remains inert. The machine then attaches
   the selected checkout and each enabled harness to the verified release.
3. The compatibility release remains operational through a full release interval
   while registry parity, unavailable-path reporting, attachment health, and
   migrated project behavior are proven. Legacy layouts are diagnosed and warned
   about but are not forcibly rewritten.
4. Only after local inventory parity and required migrations are complete, the
   cutover release removes tracked central inventory and legacy direct-link mode,
   materializes local task inputs from private state, and is built and verified
   as a new immutable release. Each fleet or attachment explicitly adopts that
   release; adoption is never inferred from source-checkout movement.

## Rollback

A failed attachment transaction rolls back its own newly created artifacts and
retains recovery state for explicit repair. Before migration, the machine's
local registry and attachment state are snapshotted. During the compatibility
interval, rollback restores that snapshot when needed and explicitly re-adopts
the verified compatibility release; project migration changes remain ordinary,
independently revertible project changes. The cutover does not move an old tag
or mutate an installed payload to simulate rollback.

## Alternatives considered

### Live links to the source checkout

Rejected. A live link makes a mutable development or publication checkout the
runtime authority for every project. Its branch, dirty state, move, or local edit
can silently change attached behavior, and it cannot provide a stable integrity
receipt for the policy an agent executed. The immutable runtime anchor preserves
one explicit installed payload per attachment while allowing the source checkout
to move independently.

### Tracked central registry and blacklist

Rejected. Registry rows encode personal filesystem paths, local availability,
and fleet-specific operational state that cannot be portable project policy.
Tracking them leaks machine topology, makes a single roster falsely authoritative
for every machine, and loses the ability to retain an unavailable path as local
diagnostic state. Private per-machine registry records support multiple fleets
without changing tracked project bytes.

### Whole-directory harness ownership

Rejected. Linking, copying, or deleting a complete `.claude`, `.agents`,
`.codex`, or `.omp` directory makes Trellis responsible for files it did not
create and prevents projects from retaining native configuration. The manifest's
leaf-surface expansion gives Claude Code, Codex, and OMP the managed files they
need while collision preflight and exact ownership protect all other files.

## Consequences

- Attached behavior is reproducible from an explicit verified release and is not
  changed by source-checkout mutation or relocation.
- The same tracked project bytes can be attached to different local paths and
  fleets on different machines; a contributor who does not attach the project
  receives no live Trellis runtime.
- Project and machine ownership are explicit: project PRs review the portable
  manifest and migration cleanup, while attachment, registry, release, hooks,
  and excludes remain private machine state.
- Three harnesses share one deterministic surface contract and one release
  payload, with worktree attachment and recovery using the same ownership model.
- Operators must install, verify, adopt, and retain rollback snapshots for
  releases; that explicit lifecycle is intentional cost for eliminating silent
  mutable runtime changes.

## Supersedes

- [2026-05-30 — Trellis doctor: unified inheritance health-check + repair](2026-05-30-trellis-doctor.md)
- [2026-06-02 — Worktree inheritance seeding](2026-06-02-worktree-inheritance.md)
- [2026-06-05 — Generate the project `.gitignore` Trellis block instead of appending a template](2026-06-05-gitignore-generated-block.md)
