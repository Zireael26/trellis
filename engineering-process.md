# Trellis — engineering process manual

**Owner:** Trellis maintainers
**Status:** Authoritative process and operating-model guide
**Last revised:** 2026-08-13

Trellis is a shared engineering-process regime for opt-in projects. Its portable
policy is versioned in this repository; its machine inventory and runtime state
are deliberately not. A project that has not been explicitly attached remains
an ordinary repository, even when it tracks a portable `.trellis.json` manifest.

This document explains the human operating model. The executable local-setup
and onboarding recipes live in [AGENT_SETUP.md](AGENT_SETUP.md) and
[AGENT_ONBOARD_PROJECT.md](AGENT_ONBOARD_PROJECT.md). The release and migration
procedures are [docs/UPGRADING.md](docs/UPGRADING.md) and
[docs/MIGRATING-LOCAL-FLEETS.md](docs/MIGRATING-LOCAL-FLEETS.md).

---

## Table of contents

1. [Introduction](#1-introduction)
2. [Principles](#2-principles)
3. [Portable policy and local machine state](#3-portable-policy-and-local-machine-state)
4. [Project regime](#4-project-regime)
5. [Attachment and the three harnesses](#5-attachment-and-the-three-harnesses)
6. [Source development and immutable releases](#6-source-development-and-immutable-releases)
7. [Git workflow and publication roles](#7-git-workflow-and-publication-roles)
8. [Definition of done](#8-definition-of-done)
9. [Code and documentation standards](#9-code-and-documentation-standards)
10. [Onboarding, worktrees, and local recovery](#10-onboarding-worktrees-and-local-recovery)
11. [Audits and fleet operations](#11-audits-and-fleet-operations)
12. [Incident response and rollback](#12-incident-response-and-rollback)
13. [Secrets, dependencies, and local tooling](#13-secrets-dependencies-and-local-tooling)
14. [Evolving Trellis](#14-evolving-trellis)
15. [Glossary and quick reference](#15-glossary-and-quick-reference)

---

## 1. Introduction

### What Trellis is

Trellis supplies a compact parent policy, process skills, deterministic hooks,
and release tooling to projects that explicitly opt in on a particular machine.
It supports Claude Code, Codex, and Pi as first-class native harnesses.

The old model made a source checkout's current files and machine inventory part
of every project's runtime. That model was path-bound, mutable, and unsafe across
machines. The current model has four separate concerns:

- **Tracked policy:** this repository's portable rules, manifests, release
  payload, and documentation.
- **Machine state:** private configuration, fleet membership, registry rows,
  installed releases, journals, and ownership records under `~/.trellis` by
  default.
- **Project identity:** one optional, inert tracked `.trellis.json` manifest
  with a stable project ID and portable project policy.
- **Runtime attachment:** explicit, local harness leaves rooted at one verified
  immutable installed release.

A project is not managed because it is inside a particular directory, appears in
a tracked roster, or happens to have an old link. It is managed only when the
local registry and a committed attachment ownership record agree for its actual
Git checkout.

### Audience

- **Machine operators** configure their local Trellis home, named fleets, and
  installed releases.
- **Project owners and agents** review portable project changes, attach a
  checkout locally, and use the normal engineering process.
- **Non-Trellis contributors** need do nothing: a fresh clone must stay inert,
  clean, and free of Trellis discovery warnings or hook behavior.
- **Trellis maintainers** develop policy in a source checkout and publish
  immutable releases without exposing private fleet state.

### Scope

Trellis governs engineering process for projects that choose to attach. It does
not configure harness credentials, model/provider choices, trust stores, MCPs,
or project-owned continuous integration and branch protection. It also does not
synchronize a machine's `~/.trellis` state to another machine: import, rebuild,
and explicit attachment are the recovery mechanisms.

---

## 2. Principles

1. **Portable tracked bytes; private machine facts.** Source paths, user homes,
   fleet membership, discovery roots, installed versions, release anchors, and
   local hook state are machine facts. They stay under `~/.trellis`, never in a
   tracked project file or public policy payload.
2. **Inert until explicit opt-in.** `.trellis.json` identifies a project and
   carries only portable policy. It never activates Trellis by itself. No
   direct absolute `@` import, source-checkout symlink, copied hook, copied
   settings file, or tracked ignore block may substitute for attachment.
3. **Immutable runtime over mutable source.** Attached projects resolve policy
   through a verified, read-only release payload. A dirty source checkout,
   branch switch, source relocation, or publication worktree cannot change an
   attached project's effective rules.
4. **Manifest-driven native surfaces.** One release-owned inheritance manifest
   describes all Claude Code, Codex, and Pi leaves, plus the `.agents` leaves
   Codex and Pi share. Attach, detach, doctor,
   and worktree repair expand the same plan rather than maintaining separate
   hand-written surface lists.
5. **Ownership before mutation.** Attachment preflights every destination,
   records every owned byte, uses a journal, and rolls back its own work on
   failure. Detach refuses to remove a modified, repointed, or project-owned
   artifact.
6. **Receipts over self-reporting.** A completed change includes the command,
   exit code, and diff evidence that establish its observable result.
7. **Small always-loaded policy; detailed procedures on demand.** Parent rules
   stay terse. Skills, release guides, migration guides, and local state carry
   deeper operational detail.

---

## 3. Portable policy and local machine state

### 3.1 Tracked source policy

`trellis.config.json` remains a tracked compatibility/policy file, but it is
portable. It can express shared policy such as enabled supported harnesses,
loop-safety defaults, the mandatory-pipeline policy, and publication metadata.
It must not contain a machine path, `PROJECTS_ROOT`, a local fleet, a registry
row, a user home, a local release location, or a symlink style.

The release payload contains the exact policy snapshot used at runtime. The
source checkout is not a runtime dependency for attached projects.

### 3.2 Trellis home

A normal machine uses `TRELLIS_HOME`, defaulting to `~/.trellis`. The home is
private (`0700`); its JSON configuration and registry are private (`0600`). Its
important state is:

```text
~/.trellis/
├── config.json                 machine source/publication metadata, default fleet,
│                               discovery roots, release remote, active CLI release
├── registry.json               machine-local fleet/project/checkout/worktree index
├── releases/<version>/         verified, read-only immutable release records/payloads
├── state/attachments/          committed attachment ownership records
├── state/migrations/           local migration rollback snapshots
├── state/git-hooks/            local dispatchers for opted-in Git common directories
└── state/...                   transaction journals and other recoverable local state
```

`config.json.source_root` is a development and publication location only. It
may move without changing the runtime of an attached project. The stable
launcher normally installed at `~/.local/bin/trellis` validates the configured
immutable management release before dispatching any command; it never depends
on a mutable source checkout after installation. Its execution contract is
§6.5.

Resolution is deliberate and fail-closed:

```text
explicit CLI flag
  > TRELLIS_HOME / TRELLIS_FLEET / TRELLIS_RELEASE / TRELLIS_SOURCE_ROOT
  > ~/.trellis/config.json
  > portable defaults
```

An existing attachment's recorded fleet and release win over a contradictory
environment value. `TRELLIS_ROOT` is **not** in that list and is not accepted as
an operator-supplied source root: the one-release compatibility bridge that
published it was removed at `v1.0.0-rc.25`. The name now carries exactly one
meaning anywhere in Trellis — a project's `.trellis/runtime` anchor, exported to
attachment-owned hooks so canonical hook libraries resolve the immutable policy
payload. Read `TRELLIS_SOURCE_ROOT` for the management/publication checkout.

### 3.3 Fleets, arbitrary paths, and unavailable rows

A fleet is a named local grouping such as `personal` or `work`. It has selected
discovery roots and optional local infrastructure metadata, but a project need
not live under any particular root. Direct operations receive the actual
absolute Git worktree path. Discovery roots only bound an explicit registry
rebuild; they are never a formula for constructing a checkout path.

`registry.json` keys a project by `<fleet>/<project_id>`, allowing the same
portable project ID in distinct fleets. It records clones by Git-common-dir
identity and worktrees by worktree identity. This makes multiple clones and
linked worktrees distinguishable without relying on directory names.

An imported or previously attached root that is unavailable remains a visible
`unavailable` row. Fleet tools report it; they do not delete it, create a
replacement from an ID, or infer a sibling path. When the real checkout is
known again, register that exact path through a reviewed rebuild or explicit
attachment. Collisions fail rather than selecting one guessed checkout.

### 3.4 Legacy tracked inventory (removed)

The tracked `registry.md`/`blacklist.md` roster was removed at `v1.0.0-rc.25`
after local parity and project-migration evidence existed. There is no tracked
control plane, audit roster, or runtime authority: the machine-local registry is
it, and `trellis registry rebuild --fleet NAME ROOT...` reconstructs it from
`.trellis.json` manifests under operator-selected roots.

`trellis registry import --fleet NAME --registry FILE [--blacklist FILE]` is
retained for a machine that has not imported yet. It reads a Markdown roster the
operator supplies — from Git history (`git show <pre-cutover-sha>:registry.md`)
or a backup — and never from a tracked path. See
`docs/MIGRATING-LOCAL-FLEETS.md`.

---

## 4. Project regime

### 4.1 The inert portable manifest

A Trellis-capable project tracks at most one `.trellis.json` manifest. Its
required purpose is stable identity; it may additionally hold portable policy,
for example presets, autonomy, package-manager preference, loop safety,
mandatory-pipeline options, or gate profiles. It may not hold a source path,
fleet, user home, installed release, harness selection, local registry state,
runtime anchor, local hook setting, or any machine-specific value.

A contributor who clones only the tracked repository sees ordinary project
files. The manifest does not create rules links, settings, hooks, exclusions,
or a Pi surface. If Trellis is absent, all three harnesses must continue with
no Trellis warning, injection, or discovery failure.

### 4.2 Local attachment is the only activation path

`trellis attach` validates a manifest and a selected installed release, plans
all requested native leaves, preflights project-owned collisions, journals the
transaction, and registers the actual checkout locally. It creates:

- `.trellis/runtime`, a local absolute anchor to one installed release payload;
- release-relative managed leaves for selected harnesses;
- one exact local block in the Git common directory's `info/exclude` file;
- an attachment ownership record and, where needed, a local hook dispatcher.

Those artifacts are intentionally untracked. The managed exclusion is not a
project `.gitignore` policy and must never be copied into a project commit.

Re-running the same attachment is idempotent after ownership verification. A
different release is not an attach option for an already attached checkout:
verify and use explicit `trellis release adopt` instead.

### 4.3 Project-owned content stays project-owned

Trellis owns only manifest-expanded leaves and its exact local state. It does
not take ownership of a harness directory, an arbitrary `AGENTS.md`, a project
`CLAUDE.md`, a project settings file, a project hook manager, or a project
`.gitignore`.

The previous doctrine of absolute source links and `@/absolute/path/...` parent
imports is retired. So are copied canonical hook trees and copied settings
payloads. A project needs neither a source-copy synchronization commit nor a
regenerated tracked ignore fragment to receive current Trellis behavior.

If a planned destination is project-owned, attach fails closed or requires the
explicit merge/adoption flow documented by the release's manifest; it never
silently overwrites a project file.

---

## 5. Attachment and the three harnesses

### 5.1 One manifest, three native surfaces

`core-rules/inheritance-manifest.json` inside the selected immutable payload is
the sole source of truth for attachment, detachment, doctor, and worktree
reconciliation. It describes managed leaf sources and destinations for:

| Harness | Local attachment role |
|---|---|
| **Claude Code** | Parent-rule, skill, command, and lifecycle leaves plus explicit local settings integration where declared by the manifest. |
| **Codex** | Native agent/rule, skill, command/workflow, and lifecycle leaves described by the same release manifest. |
| **Pi** | Its own managed extension and hook-dispatch bridge under `.pi/`, plus the shared `.agents` rule, skill, command/workflow, and agent leaves it discovers alongside Codex — without replacing project-owned Pi configuration. |

The selected release—not the source checkout—is the source for every managed
leaf. Leaves point relatively through `.trellis/runtime`, so adoption swaps one
verified anchor atomically instead of rewriting each harness surface.

### 5.2 Hooks and settings

Trellis no longer copies canonical hooks or settings into projects. The manifest
installs local, release-relative lifecycle surfaces. Where a project already
uses a hook manager, attachment records the existing configuration and installs
an absolute local dispatcher under `~/.trellis/state/git-hooks/<checkout-id>/`.
The dispatcher chains the prior manager with unchanged arguments and standard
input; it does not replace it.

Settings integration is an explicit, manifest-declared merge. A conflicting or
project-owned settings file is a preflight conflict, not permission to overwrite
it. Harness credentials, trust stores, providers, and MCP configuration remain
outside Trellis attachment.

The rendered session surfaces are the clearest example of why a leaf is data
rather than an executable. Attachment renders each `SessionStart` entry as a
call to the fixed launcher — `trellis hook NAME HARNESS PROJECT_ROOT` — crossing
its own `env -i` boundary with only `HOME`, `TRELLIS_HOME`, and a fixed `PATH`.
The launcher verifies the active release, then the payload's dispatcher resolves
`NAME`/`HARNESS` against a closed route table and executes the hook from the
verified payload in a deliberately small environment: no `BASH_ENV`, no `ENV`,
no exported functions, no inherited Git loader or config variables, and Git
configured only by two command-scoped entries. Claude Code receives
`session-context`, `post-compact-context`, `inject-primer-index`, and
`skill-size-preflight`; Codex receives the first three. An unsupported route is
a usage error, not a fallback. The project's `.trellis/runtime` anchor is
therefore something diagnosis reads, never a hook source anything executes.

### 5.3 Clones, worktrees, and reference counting

Git local excludes and hook configuration live in the Git common directory,
while harness leaves live in each worktree. Trellis records both layers:

- a **clone/checkout owner** keyed by the common Git directory;
- a **worktree owner** keyed by the actual worktree root.

The common-dir local exclude block and dispatcher remain while any attached
worktree for that checkout remains. They are restored only when the last
committed worktree owner detaches. A detach therefore cannot accidentally make
a sibling worktree's local artifacts visible or disable its dispatcher.

Use `trellis worktree add` for an opted-in clone so attachment is reconciled
before harness discovery. The local dispatcher can eagerly reconcile a new
worktree only after the clone opted in. A raw clone and an unregistered worktree
remain inert; diagnosis may request a restart when a harness has already
snapshotted discovery.

### 5.4 Local lifecycle commands

The canonical commands are intentionally narrow:

```sh
trellis attach [--fleet NAME] [--release VERSION] \
  [--harness claude|codex|pi]... PATH
trellis relink [--fleet NAME] PATH
trellis recover PATH
trellis detach [--harness claude|codex|pi]... [--all-worktrees] PATH
```

`relink` repairs an existing owned immutable anchor and local dispatcher; it
does not discover a moved checkout or choose a new release. `recover` resolves
an interrupted transaction for the exact worktree named by doctor. `detach`
verifies ownership before removing only Trellis-owned leaves and restores
shared common-dir state only after its reference count reaches zero. Full
operator recipes are in [AGENT_SETUP.md](AGENT_SETUP.md).

---

## 6. Source development and immutable releases

### 6.1 Source checkout role

The source checkout is for changing policy, authoring releases, reviewing the
public mirror, and publishing. It is not an attached project's runtime. A
maintainer may use feature branches, worktrees, and uncommitted source changes
without changing any project's installed payload.

Do not use source-checkout cleanliness or `main` as a runtime health signal.
Release verification, recorded adoption, and `trellis doctor` are the runtime
health signals. Source hygiene still matters for the ordinary reason: changes
to policy and releases go through review before publication.

### 6.2 Installed immutable releases

A release is installed from an annotated `vVERSION` tag. Installation requires
`core-rules/VERSION` to equal `VERSION`, records the release metadata and Git
blob manifest, verifies each payload entry, makes the payload read-only, and
atomically installs it under `~/.trellis/releases/VERSION/`. An existing release
version is never overwritten.

```sh
trellis release install VERSION --remote URL
trellis release verify VERSION
```

`release verify` checks version/tag metadata, payload membership, Git blob IDs,
modes, symlink safety, and immutability. It is required before attachment or
adoption. Installing a release does **not** adopt it for any project.

### 6.3 Explicit adoption

A project remains on its recorded release until an operator explicitly adopts a
verified version. The normal selector forms are:

```sh
trellis release adopt VERSION --project ID [--fleet NAME]
trellis release adopt VERSION --fleet NAME
trellis release adopt VERSION --all
```

A project selector without `--fleet` resolves only if its ID is unique in the
selected Trellis home; duplicate fleet IDs fail closed. Bulk selection prints a
per-project outcome, keeps unavailable paths explicit, and does not infer a
replacement checkout. Adoption changes the owned `.trellis/runtime` anchor only
after the target release and selected ownership records pass preflight.

### 6.4 Compatibility then cutover

The portable architecture ships through two releases:

1. **Compatibility release:** local home, registry, immutable releases,
   attachment, import, migration preparation, and dual-layout doctor are
   available. Legacy direct-link onboarding and diagnosis remain operable for
   this one release only and warn; no project is forced to migrate.
2. **Fleet migration:** import historical inventory into local state; make and
   review one project PR at a time; preserve project-owned bytes; prove an inert
   fresh clone; then attach and verify the local checkout.
3. **Cutover release:** only after parity and migration evidence, remove tracked
   central registry/blacklist authority and legacy direct-link writers, publish
   the next immutable release, and explicitly adopt it.

This is a compatibility window, not a permanent mixed layout. The full sequence
and rollback branches are in [docs/MIGRATING-LOCAL-FLEETS.md](docs/MIGRATING-LOCAL-FLEETS.md)
and [docs/UPGRADING.md](docs/UPGRADING.md).

### 6.5 Launcher-only command execution

"Attached projects run from a verified immutable release" is enforced at the
point of execution, not merely asserted. Every normal command runs through the
fixed launcher installed at `$HOME/.local/bin/trellis`
(`scripts/trellis-launcher.sh` is the template it is copied from).

**Execution snapshot.** The launcher resolves its own home, validates the
private machine config, reads `active_cli_release`, and then freezes an
independently verified *execution snapshot* of that installed release inside the
release store. Children are handed the snapshot, never the installed release
directory, and the snapshot is pinned by the SHA-256 of the release record so a
concurrent mutation of the store cannot be executed. The snapshot is removed
when the command finishes.

**Digest-bound command bundles.** The `release` and `upgrade` routes are not
executed by pathname at all. The launcher emits their bodies as an in-memory
command bundle bound to that same record digest and pipes it into a clean Bash.
`upgrade` therefore never reopens a release-script pathname: it receives the
release body as a preloaded command surface in its own shell. Reaching
`trellis upgrade` through the payload's dispatcher instead exits `2` and prints
the launcher invocation to use.

**Attestation-based, default-refuse source gates.** `release.sh`, `upgrade.sh`,
`show-config.sh`, and `sync-to-template.sh` each refuse to run unless the
launcher's attestation is present and resolves to a payload inside the
launcher's own home. The gate runs before any library is sourced and before any
argument is parsed — including `--help`, which otherwise gave an ungated copy an
exit-0 path. The gate binds to the attestation and to nothing else. An earlier
identity-based shape asked whether a machine config named the running copy as
its `source_root`, and allowed when no config answered; a copy of the source
tree, a worktree of it, an unpacked tarball, and a clone at an unnamed path all
answered "cannot tell", so all of them ran. A gate whose undecidable case allows
is not a gate. Undecidable means refuse.

**One pre-active route.** Before the configured active release exists locally,
the launcher permits exactly one command, implemented inside the launcher
itself: `trellis release install <active_cli_release> [--remote URL]`. It
accepts no other version and no other flag, so bootstrapping never needs a
mutable source dispatcher.

**No publication side effects.** No release, adoption, or upgrade command tags,
pushes, or mirrors. Tagging and public-mirror publication are the separate,
separately gated operations of §7.2.

---

## 7. Git workflow and publication roles

### 7.1 Project Git workflow

Projects use short-lived feature branches and PRs for `main`. Conventional
Commits remain the default. `main` is never force-pushed; revert a merged change
through a PR instead of resetting shared history. Project branch protection,
CI, and project-owned hook managers remain project responsibilities.

Trellis's local attachment does not make otherwise-untracked policy files part
of a project commit. Before committing a migration, review the project diff and
stage only deliberate tracked changes such as `.trellis.json` and removal of
legacy Trellis-generated tracked behavior.

### 7.2 Private source and public publication are different roles

The private source checkout and public publication mirror have different remote
roles:

- the private source's `origin.pushurl` may point only to the private Trellis
  repository after the release gate passes;
- the public `upstream` remains fetch-only in that checkout;
- public publication occurs from the reviewed mirror/publishing checkout, never
  by pushing private machine state from the source checkout.

Before restoring a private push URL or publishing a compatibility/cutover
release, inspect the push URLs and the intended public diff. The gate requires:

1. a reviewed implementation branch and release package;
2. release tag, `VERSION`, and release metadata agreement;
3. immutable-release verification and three-harness smoke evidence;
4. an inspected private/public mirror diff with no `~/.trellis` paths, fleet
   inventory, registry data, source paths, credentials, or operator-only state;
5. normal process/security gates and documented release receipts.

A failed gate leaves push access disabled or unchanged. Never compensate by
pointing a public remote at private state or by copying local registry data into
a tracked file.

### 7.3 Infrastructure publication

Optional shared infrastructure is configured per local fleet, not through a
tracked global root. A project may preflight its declared local allocation and
operate project-owned infrastructure, but it must not stop shared services or
change another project's allocation. Publish cross-repository changes in
contract order, retain the relevant schema/preflight/doctor/lifecycle receipts,
and revert in dependency-reverse order when rollback is necessary.

---

## 8. Definition of done

A change is done only when its applicable observable contract is complete:

1. **Receipts attached:** state the command, exit code, and diff evidence.
2. **In-flight work closed:** complete, defer with reason, or abandon every
   active task before claiming completion.
3. **Appropriate verification:** run the relevant smoke, focused contract test,
   UI confirmation, or deterministic gate—not a weaker substitute.
4. **Review resolved:** address findings from applicable review/gates or record
   a deliberate, bounded deferral.
5. **Portable state respected:** a permanent Trellis change does not leak local
   inventory, source paths, release anchors, or attachment artifacts into
   tracked project or publication bytes.

For an unattended or long run, begin the completion message with a plain
language outcome and any decision that still needs an operator. Put the receipt
below that explanation as evidence, not as a replacement for it.

---

## 9. Code and documentation standards

### 9.1 Planning, scope, and safety

- Use the established feature pipeline for cross-cutting or load-bearing work;
  follow the accepted plan and record a real fork rather than silently widening
  scope.
- Read the relevant caller, public surface, and existing convention before
  changing unfamiliar code. Make surgical changes unless structural rot blocks
  the requested behavior.
- Re-read an existing file before editing it. On a rename or signature change,
  separately search direct calls, types, strings, imports, re-exports, and
  mocks.
- Prefer a general fix over special-casing one input. Do not add speculative
  fallback behavior or an abstraction that has one caller.
- Verify behavior with the smallest command or scenario that can falsify the
  changed contract.

### 9.2 Parent and project documentation

`core-rules/CLAUDE.md` is a terse parent policy contained in each immutable
release. A project `CLAUDE.md` remains project-owned context: its purpose,
current gotchas, architecture notes, and local commands. It must not contain an
absolute parent `@` import or a machine path to Trellis. Attachment supplies the
parent policy locally when the operator opts in.

Keep project documentation portable. `gotchas.md` records genuine corrections;
`context-log.md` is hook-managed local state and is not hand-authored; ADRs use
the repository's existing convention. Do not put a machine's fleet membership,
release state, source-root path, or attachment instructions in a project README
or project configuration.

### 9.3 Hook and skill discipline

Rules that need mechanical enforcement belong in release-owned hooks or skills,
not in copied project files. A project can own local validation configuration
where the manifest explicitly permits it, but it does not edit a released
canonical artifact in place. A recurring cross-project rule earns promotion only
with evidence; project-specific rules stay project-specific.

---

## 10. Onboarding, worktrees, and local recovery

### 10.1 New portable projects

For a project that opts in, establish a stable portable project ID, create or
review `.trellis.json`, commit it as a project change, and only then attach the
actual checkout locally. Use [AGENT_ONBOARD_PROJECT.md](AGENT_ONBOARD_PROJECT.md)
for the executable configure/onboard/attach sequence. Do not hand-create legacy
links, direct imports, copied hook trees, or ignored tracked artifacts.

### 10.2 Existing and legacy projects

During the compatibility release, use `trellis migrate --prepare` to classify
legacy artifacts, create a local rollback snapshot, and make a reviewable
tracked cleanup. Inspect the resulting project diff before staging it. Preserve
project-owned harness content; ambiguous ownership is a conflict to resolve,
not a reason to delete it. The migration guide gives the import, snapshot,
rollback, and five-project rollout requirements.

### 10.3 Worktrees

Attach the main worktree or an explicitly selected worktree, then use
`trellis worktree add` for new worktrees in an opted-in clone. It reconciles the
manifest-defined local leaves early enough for harness discovery. Do not copy
local attachment artifacts from one worktree to another and do not remove a
common-dir exclude block by hand: clone/worktree ownership reference counting
is what makes detach safe.

### 10.4 Moves, repair, recovery, and opt-out

Moving the **source checkout** changes only local configuration. Reconfigure
its source location; attached runtimes continue to use their installed release.
Use `trellis relink` only to repair an existing attachment's recorded release
anchor or dispatcher.

Moving a **project checkout** is explicit: detach while its old identity is
reachable, relocate it using the operator's chosen filesystem procedure, then
attach the new exact path. Do not edit registry JSON or invent a new path from a
project ID. If a transaction was interrupted, run `trellis doctor` and then
`trellis recover` for that exact worktree. To opt out locally, use `trellis
detach`; it leaves the inert `.trellis.json` untouched.

---

## 11. Audits and fleet operations

Fleet-wide commands enumerate the machine-local registry, including unavailable
rows. They never reconstruct paths from a fixed root. `trellis registry list`
and `trellis doctor` are the starting points for local inventory and health.
Scope a command with `--fleet` and, where supported, `--project` whenever the
intent is not genuinely fleet-wide. `trellis show-config` renders portable
policy plus validated local machine context through the same launcher and
verified payload; `trellis task materialize --fleet NAME TASK` materializes a
private scheduled-task input under `$TRELLIS_HOME/tasks/` from the verified
active release and one strict registry snapshot, and never writes a project
root.

### 11.1 One row vocabulary

Every consumer of the local registry classifies a row with the same three words,
and the vocabulary is named for exit classes so a row state and an exit code can
never disagree (`scripts/lib/local-registry.sh` is the normative definition):

| Row state | Class | Meaning |
|---|---|---|
| `available` | `0` | The row is exactly as registered — or, for a rootless `project` row, has no root to classify. |
| `unavailable` | `0` or `5` | Class 0: the root is unreachable and nothing contradicts the row. Class 5: the environment could not answer — an uncanonicalizable root, an unusable hash command. |
| `identity_error` | `4` | Live Git identity contradicts the recorded registry state. |

`not-applicable` is an *identity-state* word in the diagnostic listing, never an
availability word, so both listings agree on the same three-word enum. Failed
rows are **report-only**: they stay visible and are neither deleted,
reconstructed from a project ID, nor replaced by a similarly named checkout.
Roots and names are printed through the shared terminal-safety helper, so a
corrupt or hostile path named in a diagnostic cannot rewrite the terminal.

### 11.2 Row faults continue, environment faults stop

A **row fault** is scoped to one registry row and the run continues to the other
selected rows. A strict whole-file read would abort on the first broken row
*anywhere*, so one unrelated `identity_error` row used to fail every healthy
target; selections are therefore read diagnostically, per row. An **environment
fault** is global — a missing hash command, an unreadable store — and is probed
once, up front, failing the whole command class `5`.

This loosens nothing about a target. Before a write, exactly the checkout and
worktree rows about to be mutated are re-validated under the registry lock by
**bound-row identity**, using the same validator the strict reader uses, and the
resulting document is written under the **whole-file schema**. A target whose
own row is broken still fails class `4` or `5` and is never adopted onto, and a
per-row read can never publish a registry the strict reader would reject.

Narrowing *within* a listing cannot lower the state class: the class is computed
from the full listing while actions are computed from the selection, so
`--project` cannot make a command exit `0` over a listing already shown to be
corrupt, and rows outside the selection that would otherwise go unreported are
printed. `--fleet` is **not** that kind of narrowing — it scopes the listing
itself, so it narrows the state class with it, deliberately: a fleet-scoped
consumer acts only within its fleet and is not made to fail on a row it cannot
touch. A clean `--fleet` listing therefore attests to that fleet and to nothing
else, and a whole-machine verdict needs an unscoped listing. Two checks stay
registry-wide regardless of the flag, and they are the only ones: the file-level
structural/schema validation that runs before any row is classified, and the
re-validation every write performs under the registry lock. A command's exit
status is the **highest** class any row or preflight produced, and no exit path
may report below a state class already proven.

Operator-owned audit schedules and prompts are private local automation. They
may examine selected local fleet rows, but their targets, paths, and reports are
not publication inputs. A useful audit reports facts and proposes a bounded
remediation; it does not rewrite project-owned files or turn an unavailable row
into a guessed replacement.

For drift:

1. identify whether the condition is an immutable-release problem, attachment
   ownership conflict, unavailable checkout, project migration gap, or a
   project-owned configuration issue;
2. verify the installed release and exact registry row before mutation;
3. use attach/relink/recover/detach only for Trellis-owned state;
4. use a reviewed project PR for tracked project changes;
5. rerun the narrow doctor/registry check that establishes the repair.

---

## 12. Incident response and rollback

### 12.1 Triage

1. **Production is broken:** revert the suspect project change through a PR,
   then diagnose. Do not reset or force-push `main`.
2. **Local project behavior is broken:** determine whether the project is
   attached, which immutable release it records, and whether doctor identifies
   corruption, an unavailable root, or an interrupted transaction.
3. **Trellis attachment is broken:** verify the installed release first. Use
   `recover` only for its recorded transaction; use `relink` only for a verified
   owned anchor; detach if local opt-out is the safest recovery.
4. **Source checkout is broken or moved:** repair or reconfigure it as a
   development/publication checkout. It cannot silently alter already attached
   project runtime.

### 12.2 Rollback layers

- **Release rollback:** verify the prior installed immutable release, then
  explicitly adopt it for the affected project, fleet, or reviewed all-fleet
  scope. Installation alone never rolls anything back.
- **Project migration rollback:** use the exact snapshot path printed by
  `trellis migrate --prepare` with `trellis migrate --rollback SNAPSHOT` before
  further project changes. The rollback rejects a changed checkout or changed
  post-prepare file rather than overwriting it.
- **Attachment transaction rollback:** attach and detach journal their own
  work. If interrupted, preserve the journal and invoke `trellis recover`; do
  not remove local leaves or `info/exclude` blocks manually.
- **Tracked project change rollback:** revert the reviewed project PR normally.
- **Source policy rollback:** publish and explicitly adopt a prior verified
  release; do not make a live source checkout the fallback runtime.

### 12.3 Compatibility rollback

The compatibility release retains legacy direct-link support for exactly one
release so a machine can restore a local migration snapshot and use the retained
compatibility behavior while its project PR is corrected. This escape does not
extend the cutover deadline or justify new direct-link onboarding.

---

## 13. Secrets, dependencies, and local tooling

- Never commit secrets. Keep local values in ignored project environment files
  and platform secret stores; never place them in a release payload, registry,
  migration snapshot description, or audit report.
- Read tokens from the process environment only when needed. Do not print,
  persist, or copy them into a command line, URL, documentation example, or
  project configuration.
- Projects own their package-manager and runtime declarations. Trellis can
  carry portable defaults, but no fixed machine path or user-local package store
  becomes project policy.
- Local hooks and agents run in non-login environments. Ensure the necessary
  toolchain is available there, but diagnose a missing tool rather than adding a
  path to tracked policy.

---

## 14. Evolving Trellis

### 14.1 Rule of Three

Cross-project policy earns parent status when three independent projects need
it. Keep a first occurrence project-local, record the second as a candidate,
and promote the third only with the evidence and a release-level verification
plan. Demote a parent rule when it no longer applies broadly or causes real
harm.

### 14.2 Release discipline

A source change becomes runtime behavior only after review, an immutable
annotated release, installation, verification, and explicit adoption. Update
release metadata, migration compatibility notes, public mirror material, and
all three harness surfaces together. Never repair drift by source-copy syncing
files into projects.

### 14.3 Compatibility discipline

A compatibility path needs a named release boundary, a diagnostic signal, a
migration/rollback procedure, and a removal condition. It must not become an
undocumented alternate runtime. The current legacy direct-link path ends after
the portable-fleet compatibility release; cutover requires local registry parity
and migrated-project evidence before its writers and tracked inventory are
removed.

### 14.4 Choosing the track

Size every change before building it. Direct surgical work for a tiny obvious
change; a short design pass and a project-local plan for a self-contained
change; the full pipeline of §14.7 for cross-cutting or load-bearing work. When
two tracks are plausible, take the heavier one — a little extra design is cheap
and a wrong "surgical" change is not. The autonomy level of §14.9 determines who
answers the interactive gates, not whether safety, receipts, review, and
immutable release boundaries apply.

### 14.5 Versioning & the upgrade flow

`core-rules/VERSION` is a single-line semver and the authoritative identity of a
release source revision. It is bumped deliberately when a meaningful rule, hook,
or skill change lands, and a release publishes an annotated `vVERSION` tag whose
`core-rules/VERSION` equals `VERSION` exactly — installation refuses the tag
otherwise.

Consumers do not track a branch and do not resolve "latest". They install a
named annotated tag from an explicit `--remote` or the machine-local
`TRELLIS_HOME/config.json` `release_remote`, verify the installed payload, and
then explicitly adopt it for a selected project, fleet, or reviewed all-fleet
scope. Installing a version already present in the local store is refused as an
ownership conflict rather than overwritten, which is what makes an installed
release a stable forensic artifact.

An optional operator `version-drift` audit walks the local registry and
classifies each row against the current release. Only major drift is critical;
everything else is informational while a rollout reaches each attachment. This
manual deliberately does not restate a version number that will drift — read
`core-rules/VERSION` and the release store.

### 14.6 Updating Trellis

§14.5 is the versioning *machinery*; this is the *sequence*. The full runbook is
[docs/UPGRADING.md](docs/UPGRADING.md); this is the summary, and the step order
is load-bearing.

1. **Install** the exact annotated release into the local immutable store:
   `trellis release install VERSION --remote URL`.
2. **Verify** the installed payload: `trellis release verify VERSION`. Required
   before any attachment or adoption, and success says only that the payload is
   valid — not that any project uses it.
3. **Inspect the intended scope** with `trellis registry list --fleet NAME`.
   Unavailable and `identity_error` rows (§11.1) are evidence, not permission to
   guess a replacement.
4. **Adopt explicitly** with exactly one selector: `--project ID [--fleet NAME]`,
   `--fleet NAME`, or a reviewed `--all`.
5. **Verify the adopted runtime** with the same narrow `trellis doctor` scope.

`trellis upgrade VERSION [--remote URL] <selector>` performs steps 1, 2 and 4 as
one launcher-only operation with no intermediate review point. Because it begins
with an install, it is forward-only: rolling back to an already installed
version uses `release verify` plus `release adopt` instead.

**`doctor` is the verification gate after every update.** A recorded release is
not evidence that the attachment's leaves are intact; the scoped doctor result
is. The older doctrine this replaces — pull the canonical clone, confirm it is
on clean `main`, then trust every project's live symlinks — is retired with the
checkout that made it necessary. Source-checkout cleanliness is no longer a
runtime health signal, because no attached project resolves through it.

### 14.7 The clarify → spec → plan → tasks → analyze pipeline (opt-in)

Five skills take a vague request through structured questioning, formal
specification, technical design, work breakdown, and a coherence check. They are
release-owned under `core-rules/skills/`, and an attached project receives them
as manifest-owned leaves in its native Claude Code surface and in the shared
`.agents` surface Codex and Pi both discover.

- `clarify` — front-step question pass. Use before `spec` when the request is
  vague, contradictory, or leaves any of the five canonical intent dimensions
  unresolved. The five questions are a floor: add the ones whose answers would
  change the architecture, and ask those first.
- `spec` — problem, users, success criteria, non-goals, constraints, risks.
  *What* and *why* only, no implementation detail.
- `plan` — file-by-file technical design, sequencing, test strategy, risks. When
  a working implementation of the semantics already exists, point the plan at
  that code rather than describing it.
- `tasks` — checkbox breakdown, ≤4h per task, each mapped to a spec criterion.
  `tasks.md` is the document of record; `TodoWrite` mirrors the active slice, and
  if they disagree `tasks.md` wins.
- `analyze` — advisory drift check across the artifacts. Verdict only; the
  operator owns whether to act or override.

All three tracks of §14.4 converge on the single builder, `execute`, which runs
*after* these artifacts exist.

**Decision rule.** Invoke the pipeline when any of: three or more acceptance
criteria; net-new behavior across more than two files; cross-cutting or
load-bearing work; or the operator asks for a write-up. Otherwise skip it — bug
fixes with clear reproductions, behavior-preserving refactors, single-file
additions, and operational tasks stay on the surgical default.

**When `mandatory_pipeline` is enabled** in effective portable policy (the
tracked project declaration is `.trellis.json`; default off), that decision rule
stops being a judgment call above the floor. A branch whose net gated diff
exceeds `spec_required_diff_lines` cannot be pushed without one of: a spec triad
added on this branch, a size-capped `/surgical` declaration, or a logged
`/surgical --emergency`. Sub-floor work stays surgical-default at every setting.
The gate is a pure function of git and filesystem state, so it enforces
identically across harnesses. What flexes with autonomy is only *who answers*
the intake interview (§14.9): the block itself fires the same at every level.
Mechanism: `core-rules/hooks.md`.

**Exploration is a different loop from building.** For work whose *shape* is
undecided, explore first in its own session at deliberately low fidelity: set
direction before generating, keep fidelity low while structure is in question,
generate several options and remix, and take the last 5% by hand. Treat the
output as disposable — what carries forward is the chosen direction, not the
exploration code.

**Implementation notes.** While building, keep an untracked
`implementation-notes.md` at the repo root of the active checkout: one line per
place the code had to depart from the plan, and the choice made at that fork.
Repo root and untracked are both load-bearing — `process-gate` looks for it at
the repo root, and keeping it out of the index stops it shifting a task's diff
stat. Delete it before a worktree is reaped, and after harvesting its entries
into the PR description and `gotchas.md`.

**Stopping points.** Review each artifact before dependent work. Existing
authorization and the effective autonomy level determine who answers unresolved
questions, not whether the operator is present. Continue already-authorized
transitions; an explicit plan-only request still ends with the plan. Pause for
consequential unresolved input or actions beyond authorization, retaining all
review gates and destructive-action safeguards. The `spec`→`plan` transition is
not mechanical — a plan that settles an architectural question surfaces inline
even at L5. See `core-rules/autonomy.md` for consultation rules.

Artifacts live at `<project-root>/specs/<NNN>-<slug>/` and stay in git as
historical record after the feature ships.

### 14.8 Presets — layering opt-in rule variants on top of parent

The Rule of Three (§14.1) protects the parent layer from bloat. Presets let two
projects diverge without forcing every project to inherit either side of the
divergence.

Each preset is one Markdown file under `core-rules/presets/`. A project opts in
by listing names in its portable `.trellis.json`:

```json
{ "presets": ["compliance-strict"] }
```

Preset delivery is a separate operator step, not part of attachment: the
inheritance manifest declares no preset leaf group and `attach` expands none.
`scripts/rollout-presets.sh` reads each row's declared array and installs
release-pinned `preset-<name>.md` links into `.claude/rules/` for rows selecting
`claude`, and `.agents/rules/` for rows selecting `codex` or `pi`, pruning links
for presets a project no longer declares.

The policy is **additive, not last-wins**: enabled preset content adds to the
prompt and there is no engine-level override. What is *delivered* to a surface
is not the same claim as what a harness is *observed to load*; verify native
loading separately for each harness. The Pi extension's own policy read targets
`.agents/rules/trellis.md` specifically and carries no preset loader. Delivery
of shared preset links does not prove Pi's native loading of them; retain the
native-loading verification gap for T5.
"Priority" means which layer's voice an agent defers to when prose conflicts —
parent rules, then presets, then the project's own `CLAUDE.md` — not which file
silently overwrites another. In practice a preset extends the parent or states
an explicit written carve-out; it never contradicts silently.

Shipped presets, catalogued in `core-rules/presets/README.md`:

- `compliance-strict` — additions for regulated or audit-bound work: mandatory
  ADR per architectural change, two-human PR sign-off, no `--no-verify` ever,
  mandatory CHANGELOG per PR, hard-fail secrets scan, deploy artifacts encode
  the merge SHA.
- `experimental-loose` — carve-outs only, for throwaway prototypes: direct
  commits to main, skip the pipeline, optional CHANGELOG, PR-size ceiling
  demoted to warn. Time-bound, and the security gate still runs.

Authoring a new preset is governed by `core-rules/presets/README.md`:
single-purpose, ≤50 lines, additions-plus-carve-outs structure, a stated reason,
and a two-project minimum before it ships. An optional operator `preset-drift`
audit compares each local row's declared array against the leaves actually
attached.

### 14.9 Autonomy — the responsibility slider

Trellis ships an L1–L5 responsibility slider that determines *who* answers the
harness's interactive gates: user at the lower levels, agent at the higher ones.
Every gate and quality control remains at every level; the level changes only
the consultation surface. L3 is the default and the historical behavior.

- **L1 Pedagogical** — ask, and explain why you recommend what you recommend.
- **L2 Cautious** — ask, with an embedded recommendation.
- **L3 Standard** — the default.
- **L4 Initiative** — single plan approval, batched questions; architectural
  decisions still surface inline.
- **L5 Autonomous** — silent decision-making plus a decision log; architectural
  decisions still surface inline.

Level resolution reads portable project policy from `.trellis.json`, then the
active immutable release and its declared presets, then a session override, and
finally clamps to the lowest preset `autonomy_ceiling`. Bright-line guardrails —
hard hooks, destructive operations, external messages, secrets, DoD receipts,
the code-review subagent, the untrusted-content boundary — stay mandatory at
every level. At L4/L5, decisions taken on the operator's behalf are recorded in
the project's `decisions-log.md`. Full matrix and precedence:
`core-rules/autonomy.md`.

---

## 15. Glossary and quick reference

**Attachment** — machine-local, ownership-recorded activation of one Git
worktree against a verified immutable release.

**Attestation** — the payload identity the stable launcher exports across its
`env -i` boundary. It is the only thing a gated command binds to when deciding
whether it may run; its absence is a refusal, never a permission.

**Bound-row identity** — under-lock re-validation of exactly the checkout and
worktree rows a write is about to mutate, using the strict reader's validator.

**Environment fault** — a global failure such as a missing hash command or an
unreadable store. Probed once, up front, and fails the whole command class `5`.

**Execution snapshot** — the independently verified, digest-pinned copy of the
active installed release that the launcher freezes and runs from, so a store
mutation cannot be executed mid-command.

**`identity_error`** — the single class-4 row state: live Git identity
contradicts the recorded registry row. Reported, never repaired or removed.

**Compatibility release** — the single release that supports both legacy
direct-link diagnosis/onboarding and the new portable local-fleet path while
projects migrate.

**Fleet** — a named machine-local grouping of registry entries and selected
discovery roots. It is not a tracked project property.

**Immutable release** — a verified, read-only installed payload under
`~/.trellis/releases/<version>/payload` that supplies runtime policy.

**Inert manifest** — the tracked `.trellis.json` identity/policy file that does
not produce Trellis behavior by itself.

**Local registry** — private `~/.trellis/registry.json`, the operational index
of fleet/project identities, checkouts, worktrees, statuses, and attachments.
It is rebuildable; it is not a tracked source of project identity.

**Release adoption** — the explicit verified operation that swaps an attached
project's `.trellis/runtime` anchor to another installed version.

**Row fault** — a failure scoped to one registry row. The run continues to the
other selected rows; the faulting row is reported and left intact.

**Source checkout** — a development and publication checkout of Trellis. It is
not an attached project's runtime and may safely be moved or worked on.

**Unavailable row** — a retained local registry record for a missing or
unmounted checkout. It is reported, never silently removed or guessed.

**Verified command bundle** — the `release` and `upgrade` bodies emitted in
memory, bound to the execution snapshot's record digest, so those routes never
reopen a script pathname.

**Worktree owner** — the per-worktree attachment record nested under a
clone/common-dir owner; common Git state persists until its final owner detaches.

### Quick reference

| I want to… | Do this |
|---|---|
| Configure a machine or create fleets | Follow [AGENT_SETUP.md](AGENT_SETUP.md). |
| Install and verify a release | Follow [docs/UPGRADING.md](docs/UPGRADING.md). |
| Install, verify, and adopt in one step | `trellis upgrade VERSION [--remote URL]` with exactly one selector; launcher-only, forward-only (§14.6). |
| Import or rebuild local inventory | Follow [docs/MIGRATING-LOCAL-FLEETS.md](docs/MIGRATING-LOCAL-FLEETS.md). |
| Attach, move, recover, or detach a checkout | Follow [AGENT_SETUP.md](AGENT_SETUP.md). |
| Migrate a legacy project | Follow [docs/MIGRATING-LOCAL-FLEETS.md](docs/MIGRATING-LOCAL-FLEETS.md). |
| Roll back an adopted release | Verify the prior release, then explicitly adopt it; see [docs/UPGRADING.md](docs/UPGRADING.md). |
| Change parent policy | Make a reviewed source change, publish an immutable release, then explicitly adopt it. |
| Publish Trellis safely | Keep private-source push and public-mirror publication roles separate; pass the release gate first. |

## References

- [core-rules/CLAUDE.md](core-rules/CLAUDE.md) — compact parent policy carried by every immutable release.
- [core-rules/inheritance.md](core-rules/inheritance.md) — manifest-driven local attachment and harness contract.
- [core-rules/hooks.md](core-rules/hooks.md) — deterministic hook and gate policy.
- [AGENT_SETUP.md](AGENT_SETUP.md) — executable local machine setup and lifecycle recipes.
- [AGENT_ONBOARD_PROJECT.md](AGENT_ONBOARD_PROJECT.md) — portable project onboarding recipe.
- [docs/UPGRADING.md](docs/UPGRADING.md) — install, verify, adoption, compatibility, and rollback procedure.
- [docs/MIGRATING-LOCAL-FLEETS.md](docs/MIGRATING-LOCAL-FLEETS.md) — local registry import/rebuild and legacy project migration procedure.
- [docs/adr/2026-08-12-local-fleets-immutable-releases.md](docs/adr/2026-08-12-local-fleets-immutable-releases.md) — architectural decision and supersession record.
