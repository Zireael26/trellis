# Upgrading Trellis through immutable releases

This runbook upgrades the **installed runtime** used by attached Trellis
projects. It does not make a source checkout's branch, cleanliness, or path part
of project runtime. Attached projects run only from verified immutable payloads
under `TRELLIS_HOME` (default `~/.trellis`).

For first-machine configuration, launcher installation, fleet creation, and
attachment recipes, use [AGENT_SETUP.md](../AGENT_SETUP.md). For importing
legacy inventory and preparing project migrations, use
[MIGRATING-LOCAL-FLEETS.md](MIGRATING-LOCAL-FLEETS.md). For an agent executing an
upgrade end to end — any harness, with per-step verification, stop conditions,
and a rollback path — use [AGENT_UPGRADE.md](../AGENT_UPGRADE.md); this document
is the reference it cites.

## What an upgrade changes

An upgrade has four distinct operations:

1. **Install** an exact annotated release tag into the local immutable release
   store.
2. **Verify** the installed payload's release record, tree, modes, and
   immutability.
3. **Adopt** that verified version explicitly for selected existing attachments.
4. **Verify the selected local registry rows** with `doctor`.

Installation never adopts a version. Adoption never infers "latest," a source
branch, a new checkout path, or a fleet. A source checkout may be dirty, on a
feature branch, moved, or absent after a release is installed; none of that
changes an attached project's runtime.

No release command tags, pushes, or mirrors anything. Publishing an annotated
tag and syncing the public template are separate, separately reviewed
operations; an upgrade only touches the local release store and the local
registry rows you select.

### The one-command route

`trellis upgrade` performs **install** (section 1), **verify** (section 2) and
**adopt** (section 4) as one operation against a single selector. It does not
perform section 3, *Inspect the intended local scope* — that review step has no
counterpart in the one-command route:

```sh
trellis upgrade VERSION [--remote URL] --project ID [--fleet NAME]
trellis upgrade VERSION [--remote URL] --fleet NAME
trellis upgrade VERSION [--remote URL] --all
```

`VERSION` is required and positional; it must precede the options. `--remote`
may be omitted only when `TRELLIS_HOME/config.json` carries `release_remote`.
Exactly one selector is accepted — `--project` and `--fleet` may be combined to
disambiguate an ID, but neither may be combined with `--all`. There is no
latest-tag lookup, no tracked pin rewrite, no `--check`, no `--opt-in`, and no
implicit adoption of an unselected row.

The stepwise `release install` / `release verify` / `release adopt` sequence in
sections 1, 2 and 4 remains the supported route when you want to review between
operations, or install a version now and adopt it later. `trellis upgrade` is
the same three calls in the same order, with no intermediate review point.

It is therefore a **forward-only** command. Its first call is `release install`,
and installing a version that already exists locally is refused as an ownership
conflict (class `3`) rather than overwritten — so `trellis upgrade` cannot move
an attachment back onto an already installed release. Use the explicit
`release verify` plus `release adopt` pair for that; see
[Roll back a release adoption](#roll-back-a-release-adoption).

## Where upgrade commands may run

Every command in this runbook is written to run through the **installed stable
launcher**, normally `$HOME/.local/bin/trellis`. For the `release` and `upgrade`
routes that is enforced by the mechanisms below. For the rest of the runbook it
is convention this document follows deliberately, not something a gate checks.

- The launcher resolves its own home (`TRELLIS_HOME`, else `$HOME/.trellis`),
  validates the machine config, and reads `active_cli_release`. It then freezes
  an independently verified **execution snapshot** of that installed release and
  runs only from the snapshot, pinned by the SHA-256 of the release record. The
  installed release directory itself is never handed to a child process.
- The `release` and `upgrade` routes are carried into that child as a **verified
  in-memory command bundle** bound to the same record digest, so `upgrade` never
  reopens a release-script pathname. `trellis upgrade` is therefore *not*
  runnable from the payload's own dispatcher: reaching it there exits `2` with
  the launcher invocation to run instead.
- `release.sh`, `upgrade.sh`, `show-config.sh`, and `sync-to-template.sh` each
  carry an **attestation-based, default-refuse source gate**. The gate binds to
  the payload identity the launcher exports across its `env -i` boundary
  (`TRELLIS_VERIFIED_PAYLOAD` plus `TRELLIS_VERIFIED_RELEASE_VERSION`, required
  to resolve inside the launcher's own home) and to nothing else. No
  attestation means there is nothing to bind to, and the answer is refusal with
  exit `2` — including for `--help`. The gate is deliberately not identity-based:
  a copy of the source tree, a worktree of it, an unpacked tarball, or a clone at
  a path no config names are all undecidable cases, and undecidable here refuses.
- Before the configured active release exists locally, the launcher permits
  exactly one bootstrap route, implemented inside the launcher itself:
  `trellis release install <active_cli_release> [--remote URL]`. It accepts no
  other version and no other flag.

Which runbook commands the gate actually covers:

| Runbook command | Sections | Launcher route |
|---|---|---|
| `release install` / `release verify` / `release adopt` | 1, 2, 4, rollback | **enforced** — `release.sh` carries the source gate |
| `trellis upgrade` | one-command route | **enforced** — `upgrade.sh` carries the source gate, and the payload dispatcher refuses it outright |
| `registry list` | 3 | convention — `registry.sh` carries no source gate |
| `doctor` | 5 | convention — `doctor.sh` carries no source gate |

Consequence for this runbook: do not substitute `scripts/release.sh` or
`scripts/upgrade.sh` from a source checkout for any command below. They will
refuse, and the refusal is the designed behavior rather than a setup problem.
`scripts/registry.sh` and `scripts/doctor.sh` will *not* refuse — nothing stops
you running them from a checkout, which is exactly why they are listed here.
Run them through the launcher anyway, so every command in one upgrade resolves
the same home and reports against the release the attachment actually runs.

## Preconditions

- A local Trellis home and stable `trellis` launcher already exist. Create them
  through [AGENT_SETUP.md](../AGENT_SETUP.md), not by copying source files into
  a project.
- Select an exact published release version without the `v` prefix, and a remote
  that contains its annotated `vVERSION` tag.
- Decide the narrowest intended adoption scope: one project, one fleet, or a
  reviewed all-fleet operation.
- Do not edit `.trellis/runtime`, `~/.trellis/registry.json`, release payloads,
  `.git/info/exclude`, or local hook dispatchers by hand.

The release target must be a published immutable release, not a source checkout
revision. Local machine and project paths are private inputs; do not put them in
an issue, PR, project manifest, or public release note.

For the examples below, set explicit shell variables:

```sh
: "${TARGET_RELEASE:?Set the exact release version, without the v prefix}"
: "${RELEASE_REMOTE:?Set the remote containing annotated tag v$TARGET_RELEASE}"
: "${TRELLIS:=trellis}"
```

Set `TRELLIS_HOME` before invoking the launcher only when you deliberately use a
non-default local home. The explicit `--home PATH` flag has higher precedence
where a command supports it.

## User-global orchestration surface

`trellis attach --user` manages the machine-level user surface from an
installed, verified release. It is separate from project attachments: it takes
no project path, fleet, or harness selector. The manifest's `user` group links
release skills into harness discovery roots alongside two `.claude/` leaves and
the `.claude/settings.json` render: `herdr-foreman` for all three harnesses
(`.claude/skills` and the shared `.agents/skills` root Codex and pi both read)
and `trellis-computer-use` for pi only (`.pi/agent/skills`).

The normal first attach uses the active release (or an explicitly selected
installed release):

```sh
"$TRELLIS" attach --user --home "$TRELLIS_HOME" --release "$TARGET_RELEASE"
```

If the user surface was hand-placed before Trellis owned it, do not delete or
overwrite those files to make the command pass. Without an adoption flag,
`attach --user` treats an existing unowned destination as a conflict and
leaves the existing user surface untouched. For a release-managed JSON
destination, plain attach preserves unrelated operator keys, but any overlap
with a key Trellis renders is a conflict. With `--adopt-identical`, an existing
JSON object is eligible only when every overlapping managed leaf already has the
exact release value; an object/type conflict remains a conflict.

For a one-time migration of hand-placed content that is already identical in
the supported sense, use the explicit `--adopt-identical` opt-in:

```sh
"$TRELLIS" attach --user --adopt-identical \
  --home "$TRELLIS_HOME" --release "$TARGET_RELEASE"
```

This flag applies only to `attach --user`; it is not a project-attachment
option and is not a force/overwrite switch. Adoption is checked per planned
leaf:

- an existing symlink leaf must point to the exact planned target;
- an existing regular-file copy may stand in for a planned symlink only when
  the planned target is a regular file and its bytes match;
- a planned regular-file leaf must match its planned bytes and mode;
- an existing explicit-JSON destination must be an object, and every managed
  leaf already present must equal the release value; unrelated operator keys
  remain;
- missing leaves are created normally, and existing directories are reused only
  as parent directories, not adopted as arbitrary directory trees.

Outside the regular-file-copy case above, a planned regular-file leaf with
unequal required bytes or mode, a different link target, an unequal managed
JSON value/type, or an incompatible file/directory shape remains a conflict.
When a regular-file copy is adopted, its original bytes and mode are retained
for detach restoration. Use adoption once to establish ownership; later
changes use `relink --user`.

To remove the user attachment or roll back that migration:

```sh
"$TRELLIS" detach --user --home "$TRELLIS_HOME"
```

`detach --user` removes only owned release-backed leaves. It restores files that
were displaced during adoption and inverse-merges the rendered JSON keys,
preserving unrelated operator content. If an owned destination was changed,
detach refuses rather than overwriting the operator's changes. A successful
detach leaves the user surface in its pre-attach/pre-adoption state. It does
not select an older release; use `relink --user --release VERSION` for that.

`relink --user` requires an existing owned user attachment, reconciles its
release-backed leaves and renders to the selected release, and refuses unsafe
or unowned conflicts. Omitting `--release` uses the active release. When
`configure --release VERSION` changes the active release and an owned user
attachment exists, configure performs this relink after adoption as one
all-or-nothing transition across machine config, the stable launcher, and the
user surface. If the target user surface is already durably published,
configure finalizes it and succeeds. Otherwise, if relink cannot complete,
configure compensates the user surface, restores the prior configuration and
launcher, and returns the initiating failure; it never reports success with a
mixed configuration and user surface.

### User skill store

Release skills above are one half of the user-global skill surface. The other
half is the operator skill store: third-party and operator-authored skills live
as real directories only under `$TRELLIS_HOME/skills/<name>/`, and each harness
discovery root holds only Trellis-managed links into the store. A skill declares
its harness set in an optional `trellis-skill.json`
(`{"harnesses": ["claude", "codex", "pi"]}`; absent means all three); the set
maps to discovery roots by one table — `claude` → `~/.claude/skills`,
`codex`+`pi` together → the shared `~/.agents/skills` link, `pi` alone →
`~/.pi/agent/skills`, `codex` alone → `~/.codex/skills` — so one skill is never
visible twice to one harness.

Manage the store with `trellis skills list|import|link|unlink`:

```sh
"$TRELLIS" skills list
"$TRELLIS" skills import <dir>...
"$TRELLIS" skills link [name...]
"$TRELLIS" skills unlink <name>
```

`import` moves one real skill directory into the store and removes other copies
of the same name in harness roots only when byte-identical; a differing copy, a
name already in the store, or a collision with a release user skill refuses with
exit `3` and names the path, before anything moves. `link` reconciles owned
links from each skill's harness set (narrowing a set removes the links it drops),
`unlink` removes only owned links and leaves the store untouched, and an unowned
existing path is never replaced or deleted. Every created link is recorded in
`$TRELLIS_HOME/state/user-skills.json`. A malformed harness set exits `2`.

`doctor` reports the state without changing it: a real directory in a harness
root warns as a stray copy (remedy `trellis skills import`), as do dangling or
foreign links and one skill name visible twice to a single harness.

**Criterion 6 notice — project surfaces are separate.** This user-surface
lifecycle does not refresh project attachments. Project templates and links are
rendered at project `attach`; release adoption, project `relink`, `configure`,
and `doctor --fix` do not add newly declared project leaves. If a release adds
or changes a project leaf, use the documented project `detach`/`attach` cycle
with the intended harness set and release, then run `doctor`; there is no
project refresh or force flag. This remains required even when user-global
relink succeeds.

## 1. Install the exact release

Install from the release remote. The command requires an annotated tag named
`v$TARGET_RELEASE` and verifies that `core-rules/VERSION` in that tag equals
`$TARGET_RELEASE` before making the payload read-only.

```sh
"$TRELLIS" release install "$TARGET_RELEASE" --remote "$RELEASE_REMOTE"
```

Success means a new immutable payload exists under
`$TRELLIS_HOME/releases/$TARGET_RELEASE/`. An already installed version is never
overwritten. Do not treat an install as adoption: all existing checkouts remain
on their recorded release until Step 3.

If installation reports an integrity mismatch, malformed tag, unavailable
remote, or unwritable local state, stop. Do not substitute a source directory or
manually construct a release directory. Fix the release or local capability and
repeat this command.

## 2. Verify the installed release

Verification is required before any attachment or adoption. It rechecks the
release record, expected paths, Git blob IDs, symlinks, modes, and read-only
state.

```sh
"$TRELLIS" release verify "$TARGET_RELEASE"
```

A successful verification establishes only that the local release payload is
valid. It does not say any project uses it. A failed verification is an invalid
runtime target; do not adopt it, relink a project to it, or repair it by editing
files under `releases/`.

## 3. Inspect the intended local scope

Inspect local state before changing an attachment. Paths may be arbitrary and
some rows may be unavailable because a volume is unmounted or a checkout moved.
Those rows are evidence, not permission to guess a replacement path.

For a project or fleet operation:

```sh
: "${FLEET:?Set the local fleet name}"
"$TRELLIS" registry list --fleet "$FLEET"
```

Pass the fleet as a flag, as the snippet above does. The launcher exports only
`HOME`, `TRELLIS_HOME`, the payload attestation, a verified SSH agent socket,
and `PATH` across its `env -i` boundary, so **`TRELLIS_FLEET` never reaches the
payload**: exporting it in your shell changes nothing, and the flag is the only
way to select a fleet through the launcher.

What omitting `--fleet` means is per command, so do not carry one answer across
this runbook:

- `registry list` with no `--fleet` lists **every fleet on the machine**, and
  scopes its exit class to the rows it printed. That is the whole-machine review
  used in [Reviewed all-fleet adoption](#reviewed-all-fleet-adoption).
- The commands that act on exactly one fleet — `attach-project`, `sync-hooks`,
  `sync-merge-gate`, `configure` — resolve a single fleet instead, and fall back
  to the rendered home's `default_fleet` when the flag is absent. Because
  `TRELLIS_FLEET` is stripped at the boundary, that fallback is what applies
  under the launcher whenever you omit the flag.

`--home PATH` likewise selects which machine state to render — it does not tell
the launcher where to find its own payload, which it resolves from
`TRELLIS_HOME`, else `$HOME/.trellis`, before dispatch.

For a single project, identify the portable project ID from the manifest/row and
confirm that it names the intended local fleet. The same project ID can validly
exist in more than one fleet; an unqualified project selector is allowed only
when it is unique in the selected Trellis home.

### Reading row state

Every listing — strict or diagnostic — classifies each row with one of exactly
three availability words, and the vocabulary is named for exit classes so a row
state and an exit code never disagree:

| Row state | Class | Meaning |
|---|---|---|
| `available` | `0` | The row is exactly as registered, or (for a rootless `project` row) has no root to classify. |
| `unavailable` | `0` or `5` | Class 0: the root is not reachable and nothing contradicts the row. Class 5: the environment could not answer the question — an uncanonicalizable root, an unusable hash command. |
| `identity_error` | `4` | Live Git identity contradicts the recorded registry state. |

`registry list` renders `identity_error` as `identity-error` in its table.
`not-applicable` is an *identity-state* word in the diagnostic listing's
`.identity.state`, never an availability word.

A failed row is **reported, not repaired and not removed**. An `identity_error`
row stays visible so you can see it; nothing deletes it, reconstructs its path
from a project ID, or promotes a sibling checkout into its place.

Narrowing *within* a listing does not lower the exit class. The state class is
computed from the **full listing** while actions are computed from the
selection, so `--project` cannot make a command exit `0` over a listing it has
just been shown to be corrupt; rows outside the selection that would otherwise
go unreported are printed too.

`--fleet` is **not** that kind of narrowing, and this is the distinction to
carry away. It scopes the listing itself, so it narrows the exit class with it:
`registry list --fleet A` exits `0` while fleet B holds an `identity_error` row,
by design — a fleet-scoped consumer acts only within its fleet and is not made
to fail on a row it cannot touch. So a clean `--fleet` listing attests to that
fleet and to nothing else. For a whole-machine verdict, list with no `--fleet`.

Two checks are genuinely registry-wide regardless of the flag, and they are the
only ones: the file-level structural/schema validation that runs before any row
is classified, and the re-validation every write performs under the registry
lock. A fault in another fleet still blocks any write it could corrupt; it just
does not colour a listing you scoped away from it.

Diagnostics are terminal-safe: roots and names are printed through the shared
control-character-rejecting helper, so a hostile or corrupt path cannot rewrite
your terminal when it is named in an error line.

## 4. Adopt explicitly

Choose **one** selector form. Each selected attachment is preflighted against
its ownership record and the verified target release before its local runtime
anchor changes.

### One project

```sh
: "${PROJECT_ID:?Set the portable project ID}"
"$TRELLIS" release adopt "$TARGET_RELEASE" \
  --project "$PROJECT_ID" \
  --fleet "$FLEET"
"$TRELLIS" doctor --fleet "$FLEET" --project "$PROJECT_ID"
```

`--fleet` is optional only when `PROJECT_ID` is unique in the local registry. If
it is ambiguous, the command fails closed; add the fleet rather than choosing a
row by path or directory name.

### One fleet

```sh
"$TRELLIS" release adopt "$TARGET_RELEASE" --fleet "$FLEET"
"$TRELLIS" doctor --fleet "$FLEET"
```

Fleet adoption reports each local registry row. It does not silently erase or
retarget an unavailable row. Resolve an unavailable checkout through the
migration/rebuild procedure when it is reachable again, then adopt it
explicitly.

### Reviewed all-fleet adoption

Use this only after reviewing every fleet's target and unavailable-row report.

```sh
"$TRELLIS" registry list
"$TRELLIS" release adopt "$TARGET_RELEASE" --all
"$TRELLIS" doctor
```

Bulk commands report per-project results and return the highest relevant exit
class. A partial report is not evidence that every attachment upgraded; review
and resolve each non-zero/unavailable result before declaring the operation
complete.

### Row faults continue; environment faults stop

Adoption distinguishes two kinds of failure, and they behave differently on
purpose:

- A **row fault** is a fault in one registry row — a broken identity, an
  unreachable checkout, an ownership record that no longer matches. Adoption
  continues to the remaining selected rows. A whole-file strict read would abort
  the entire run on the first broken row *anywhere* in the registry, so one
  unrelated `identity_error` row used to fail every healthy adoption target;
  the selection is therefore read diagnostically, per row.
- An **environment fault** is global — a missing hash command, an unreadable
  release store, an unusable local home. It is probed once, up front, and fails
  the whole command as class `5`. It is not a per-row disposition.

Per-row continuation loosens nothing about the target itself. A selected row is
re-validated under the registry lock immediately before it is written, using
**bound-row identity** — exactly the checkout and worktree rows about to be
mutated, with the same validator the strict whole-file reader uses. A target
whose own row is broken still fails class `4` or `5` and is never adopted onto.
The write then applies the **whole-file schema** to the resulting document, so a
per-row read can never publish a registry the strict reader would reject.

The command's exit status is the **highest** class any row or preflight
produced. It never reports below a state class already proven — a class-4
registry cannot be masked by a class-2 usage error or a class-0 row later in the
run.

## 5. Verify the adopted runtime

`doctor` resolves the project through the local registry and verifies attachment
ownership, the immutable release anchor, and manifest-driven native surfaces.
For a narrow upgrade, rerun the narrow project/fleet command from Step 4. For an
all-fleet upgrade, use `"$TRELLIS" doctor` and retain the per-row result.

An attached project should remain Git-clean after the intentionally tracked
`.trellis.json` is already committed. The local runtime anchor, managed harness
leaves, local exclude block, ownership record, and hook dispatcher must not
appear in a project commit.

If `doctor` identifies an interrupted attachment transaction, run the exact
local lifecycle recovery prescribed by [AGENT_SETUP.md](../AGENT_SETUP.md):
`trellis recover` for that worktree, then rerun the scoped doctor. Do not delete
artifacts manually. `trellis relink` repairs an already-owned anchor; it is not
a release upgrade command and cannot choose a different version.

### Reinstalling the launcher

Caller-PATH forwarding (the operator's toolchain reaching `attach`, `onboard`,
`worktree` and `doctor`) lives in the stable launcher, and `configure` refuses
to overwrite an installed launcher that differs from its template. A release
that changes the launcher therefore reaches a machine only through this
explicit reinstall. `doctor` WARNs with `launcher currency` until the installed
launcher is byte-identical to the active release's
`scripts/trellis-launcher.sh`.

```sh
: "${TARGET_RELEASE:?Set the active release version}"
PAYLOAD_LAUNCHER="${TRELLIS_HOME:-$HOME/.trellis}/releases/$TARGET_RELEASE/payload/scripts/trellis-launcher.sh"
# 1. The operator moves the installed launcher aside (keep it until step 4 passes).
mv "$HOME/.local/bin/trellis" "$HOME/.local/bin/trellis.before-$TARGET_RELEASE"
# 2. Install the release's own launcher. Name the template explicitly: without
#    --launcher-template, configure installs the source checkout's copy.
"$HOME/.local/bin/trellis.before-$TARGET_RELEASE" configure --release "$TARGET_RELEASE" \
  --launcher-template "$PAYLOAD_LAUNCHER"
# 3. Both must match the payload's launcher.
cmp "$HOME/.local/bin/trellis" "$PAYLOAD_LAUNCHER"
shasum -a 256 "$HOME/.local/bin/trellis" "$PAYLOAD_LAUNCHER"
```

4. Run `trellis worktree sync <path>` on a scratch attached worktree, then
   `trellis doctor`: it must show no `toolchain provenance` WARN for that
   worktree (its recorded toolchain is not the sanitized control PATH) and no
   `launcher currency` WARN. Only then remove the moved-aside launcher.

A record that already holds the sanitized control PATH makes every push from
its worktree refuse with `toolchain is the sanitized control PATH`. Repair it
from your own shell, where your real PATH is visible:
`trellis attach --refresh-toolchain <path>`. The refresh replaces only the
recorded toolchain, and it refuses unless the worktree's local `core.hooksPath`
is exactly its managed hooks path (fix that first with `trellis doctor --fix`).

## Roll back a release adoption

Rollback is an explicit adoption of a previously installed, verified immutable
version. It is not a source checkout reset, a retag, a copied rule file, or a
manual edit to `.trellis/runtime`. It is also not `trellis upgrade`: that
command begins with an install, and the prior version is already installed.

```sh
: "${ROLLBACK_RELEASE:?Set the prior installed release version}"
"$TRELLIS" release verify "$ROLLBACK_RELEASE"
"$TRELLIS" release adopt "$ROLLBACK_RELEASE" \
  --project "$PROJECT_ID" \
  --fleet "$FLEET"
"$TRELLIS" doctor --fleet "$FLEET" --project "$PROJECT_ID"
```

For a fleet or reviewed all-fleet rollback, use the same selector forms from
Step 4 with `ROLLBACK_RELEASE`. Keep the original target release installed for
forensic verification; installed versions are immutable and are not a cleanup
candidate merely because a project rolled back.

A release rollback changes local runtime state only. If the release required a
tracked project migration, revert that project change independently through its
normal reviewed PR, or restore the exact migration snapshot as documented in
[MIGRATING-LOCAL-FLEETS.md](MIGRATING-LOCAL-FLEETS.md).

## The one-release compatibility window

The portable-fleet **compatibility release** intentionally recognizes legacy
direct-link layouts while machines import local inventory and project owners
migrate. Its boundary is strict:

- It keeps legacy direct-link onboarding and dual-layout doctor support for
  **exactly one release**, with deprecation diagnostics.
- It does not make direct absolute links, absolute `@` imports, copied hooks,
  copied settings, generated tracked ignore blocks, or tracked central inventory
  valid new architecture.
- It does not force migration. A project remains operable while its owner makes
  a reviewable migration and retains the emitted rollback snapshot.
- It is followed by a cutover release only after import parity, migrated-project
  evidence, and attached-project doctor evidence are recorded.

During compatibility, install and verify the compatibility release, import the
historical registry/blacklist into a local fleet, use `trellis migrate --prepare`
for each project, review the project diff, prove a raw clone is inert, then
attach locally from the verified payload. Do not push legacy local onboarding
artifacts as a "temporary" project shape.

The **cutover release** removes tracked central registry/blacklist authority and
legacy direct-link writers. Install and verify it normally, then explicitly
adopt it using Step 4. If cutover behavior must be reversed, adopt the verified
compatibility release and restore only the relevant local migration snapshot;
do not reintroduce live source-checkout inheritance.

`1.0.0-rc.25` is that cutover release. After adopting it:

- `registry.md`/`blacklist.md` are untracked. `trellis registry import` still reads
  a Markdown roster, but only one you supply — recover it with
  `git show <pre-cutover-sha>:registry.md > /tmp/legacy-registry.md`.
- `onboard-project.sh --legacy` and `seed-inheritance-symlinks.sh --legacy-mirror`
  refuse with exit 2. Use `trellis migrate --prepare PATH` then
  `trellis attach --fleet NAME PATH`.
- `doctor` still *recognizes* a legacy or mixed checkout and names
  `trellis migrate --prepare`, but `--fix` never creates a direct link; those rows
  are reported `[manual]`.
- `TRELLIS_ROOT` is no longer accepted as an operator-supplied source root. It
  means only the per-project `.trellis/runtime` anchor.
- Project-local `.trellis.config.json` stays readable but deprecated, for held
  legacy checkouts only.

## `1.0.0-rc.25` → `1.0.0-rc.26`

rc.26 is an ordinary immutable release with no migration and no compatibility
window: install, verify, adopt through the routes above. Two of its fixes are
not delivered by adoption alone, so read this section before running Step 4.

### What changed operationally

- **Scheduled-task materialization excludes an unusable row instead of failing
  the whole task.** `trellis task materialize` previously turned every
  unreachable checkout into a planned error: the manifest went
  `status: "planned-error"` and the command returned class `5`, so one
  unavailable registry row halted 19 of 22 tasks. Unavailable rows are now
  dropped from the run and recorded in `requirements.excluded_rows` as
  `{project_id, reason}`; the manifest stays `ready` and the command exits `0`.
  One line per excluded row goes to stderr, `trellis task: excluded row: <id>:
  checkout unavailable in local registry snapshot`, while stdout still carries
  only the task root. `planned-error` and class `5` are now reserved for three
  whole-task faults: no registered rows at all, no eligible target among the
  rows that remain, or a registry that failed identity validation. A task
  prompt must report excluded rows and proceed; it must stop only on
  `planned-error`. **Existing materialized inputs are pinned to the release that
  produced them and do not change under adoption — re-materialize.**
- **The Codex `SessionStart` hook template resolves its project directory
  through the documented fallback.** Three entries in
  `core-rules/templates/codex-hooks.local.json` passed a bare
  `"$CODEX_PROJECT_DIR"`, which Codex does not reliably set;
  they now pass `"${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"`, the chain
  every other Codex surface in the payload already used. The expected-command
  pin in `scripts/lib/attachment.sh` was updated on the same three strings in
  the same change: the pin and the template are the two sides that must agree,
  and rendering fails closed with class `4` if they diverge. The Claude arm was
  not touched. **This is render-time output, not payload content — see
  [What adoption delivers](#what-adoption-delivers-and-what-it-does-not).**
- **`spec-gate.sh` ships executable in both harness trees.**
  `core-rules/hooks/spec-gate.sh` and `core-rules/codex/hooks/spec-gate.sh` were
  mode `100644` in the index from 2026-07-07. Both harness templates invoke the
  hook by bare path with no `bash` prefix, so it returned `126` in every
  attached project and the harness reported a hook failure rather than a gate
  verdict: the mandatory-pipeline Stop hook was inert everywhere it was
  installed. Both are `100755` now. There is no "spec-gate mode" setting — mode
  here means the file permission bits in the release payload.
- **`trellis hook` resolves its project directory up to the nearest
  `.trellis/runtime` anchor.** The route previously used the directory the
  harness handed it, which for Codex is routinely a subdirectory of the
  checkout; `context-log.md` and `.claude/primers/INDEX.md` live at the root, so
  session-context, post-compact-context, and primer-index injection silently
  found nothing. The route now walks up to the first directory holding a
  runtime anchor. A directory under no attachment resolves to itself, so
  unattached clones are unchanged, and no exit code on the route changed.
- **Security-gate ShellCheck findings reach the verdict, and extensionless shell
  scripts are in scope.** ShellCheck findings fell through the tool-dispatch
  `case` in the gate's diff mode: they updated no severity counter, so a new
  high-severity shell defect still returned `MERGEABLE` and exit `0` on a
  repository that is mostly Bash. ShellCheck now shares the SAST row with
  Semgrep, printing provenance as `shellcheck/SC####`. Scope was also
  suffix-only (`*.sh`, `*.bash`), which left every extensionless script — the
  pre-push hooks that invoke the gate, both `commit-msg` hooks, the `trellis`
  CLI entrypoint — outside both engines; scope is now suffix **plus** any
  changed file whose shebang names `sh`, `bash`, `dash`, or `ksh`. Expect
  previously-silent shell findings on the first rc.26 gate run.
- **`run-tests.sh` and CI enumerate every suite.** Both hand-listed their
  suites and had drifted to 20 of 57, with one omitted suite red at the
  committed tip while the gate reported a pass. `scripts/tests/*.bats` is
  globbed now, `TEST_SUITE_EXCLUSIONS` is the one hand-kept list (each entry
  carrying a scope and a reason), and `scripts/tests/suite-coverage.bats` fails
  on any suite that is neither globbed nor excluded. `run-tests.sh` takes
  `--quick`, `--scope=local|ci`, `--shard=I/N`, and `--list`; CI runs four
  shards. This changes no runtime behavior — it changes what a green gate means.
  The release gate is the local serial run:
  `bash scripts/run-tests.sh --scope=local`. CI is billing-blocked for this
  rollout, so its Actions status is not a claim that the code is green and
  cannot replace the local serial receipt until billing returns.

### What adoption delivers, and what it does not

`release adopt` performs exactly three mutations: it repoints the project's
`.trellis/runtime` anchor at the new payload, rewrites the ownership record's
release and payload fields, and regenerates the managed git-hook dispatchers
under `$TRELLIS_HOME/state/git-hooks/`. It never re-runs the surface plan and
never rewrites a rendered harness file.

| rc.26 fix | Delivered by | Why |
|---|---|---|
| materializer per-row exclusion | adopt **plus** re-materialization | the code is payload-resident, but an already materialized task's manifest is pinned to the release that wrote it |
| `spec-gate.sh` `100755` | adopt alone | the templates reach the hook *through* `.trellis/runtime`, so moving the anchor picks up the payload's modes |
| `trellis hook` anchor walk | adopt alone | payload-resident, in the payload's own dispatcher |
| security-gate ShellCheck | adopt alone | payload-resident skill content |
| suite enumeration | adopt alone | payload-resident; affects the source tree's own gates |
| Codex `SessionStart` fallback | **re-render required** | `.codex/hooks.json` is attach-time output; its bytes are written once, by `attach` |

Nothing reports the stale render for you. `doctor` does not repair a rendered
surface in any mode, and its Codex hook-freshness check is gated on a legacy
`.codex/hooks` **directory**, which a portable attachment does not have — so an
attachment still holding rc.25 render bytes reports clean. Treat the re-render
below as a required step, not a conditional one.

### Upgrade the machine

Use the stepwise route. `trellis upgrade` performs the same install, verify and
adopt against one selector and is valid here — rc.26 is not yet installed, so
the forward-only constraint does not bite — but it offers no review point
between operations, and this release needs one.

```sh
TARGET_RELEASE=1.0.0-rc.26
: "${RELEASE_REMOTE:?Set the remote containing annotated tag v$TARGET_RELEASE}"
: "${TRELLIS:=trellis}"

"$TRELLIS" release install "$TARGET_RELEASE" --remote "$RELEASE_REMOTE"
"$TRELLIS" release verify "$TARGET_RELEASE"
"$TRELLIS" registry list --fleet "$FLEET"
"$TRELLIS" release adopt "$TARGET_RELEASE" --fleet "$FLEET"
"$TRELLIS" doctor --fleet "$FLEET"
```

Keep `1.0.0-rc.25` installed. Installed releases are immutable and are not a
cleanup candidate; rollback adopts one that is already on disk.

### Re-render an attached project's Codex surface

An attached project renders its harness templates from the release payload once,
at attach time. The documented route back to a fresh render is the detach/attach
pair — the same pair
[AGENT_SETUP.md](../AGENT_SETUP.md) §8 uses for a checkout move. This also
applies to any new project leaf declared by a later release: adoption and
`relink` do not materialize it. There is no repair, refresh, or force flag:
`attach` against an already-attached row prints
`already attached: <root>` and returns `0` without rendering, `relink` repairs
the anchor and git hooks and verifies owned artifacts byte-exact against the
ownership record, and `doctor --fix` is read-only.

```sh
"$TRELLIS" detach --home "$TRELLIS_HOME" --all-worktrees "$PROJECT_ROOT"
"$TRELLIS" attach \
  --home "$TRELLIS_HOME" \
  --fleet "$FLEET" \
  --release "$TARGET_RELEASE" \
  --harness claude \
  --harness codex \
  --harness omp \
  "$PROJECT_ROOT"
"$TRELLIS" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"
```

What changes on disk: `detach` removes only attachment-owned artifacts — the
runtime anchor, the rendered harness surfaces, the managed local exclude block,
the ownership record, the local hook dispatchers — and leaves the tracked
`.trellis.json` intact and inert. `attach` writes them back from the rc.26
payload, so `.codex/hooks.json` is rewritten with the three fallback-form
`SessionStart` commands and `.claude/settings.local.json` is re-rendered
unchanged. The project's own tracked files are not touched, and the project must
be Git-clean afterward. Attach the same three harnesses that were detached: a
harness set that differs from the recorded attachment is refused, and detaching
is what makes the set re-selectable.

Re-render only projects with `codex` attached. A Claude-only or OMP-only
attachment picks up every rc.26 fix from adoption alone.

### Re-materialize scheduled tasks

Materialized task inputs carry the release identity that wrote them and do not
follow an adoption. Re-materialize each task the machine schedules, per fleet:

```sh
for TASK in daily-project-digest conductor dep-currency; do
  "$TRELLIS" task materialize --home "$TRELLIS_HOME" --fleet "$FLEET" "$TASK"
done
```

Substitute the tasks this machine actually schedules; the catalogue is
[`scheduled-tasks/README.md`](../scheduled-tasks/README.md). Each call reads one
strict registry snapshot and rewrites `$TRELLIS_HOME/tasks/<fleet>/<task>/`
atomically. A run that prints `excluded row:` lines and exits `0` succeeded —
that is the new behavior, not a partial failure. A `planned-error` manifest or a
class `5` exit is a real stop.

Every launcher invocation re-verifies the release payload before dispatch:
4.55–39 s warm, 40–125 s under load. A loop
over a full task catalogue therefore runs for many minutes. That is the
verification cost, not a hang.

### Roll back

```sh
ROLLBACK_RELEASE=1.0.0-rc.25
"$TRELLIS" release verify "$ROLLBACK_RELEASE"
"$TRELLIS" release adopt "$ROLLBACK_RELEASE" --fleet "$FLEET"
"$TRELLIS" doctor --fleet "$FLEET"
```

A rolled-back project keeps whatever render it last received. If it was
re-rendered under rc.26, repeat the detach/attach pair with
`--release "$ROLLBACK_RELEASE"` to restore the rc.25 render; leaving the rc.26
render in place under an rc.25 anchor is not a supported state, because the
expected-command pin lives in the payload. Re-materialize scheduled tasks after
a rollback for the same reason they are re-materialized after an upgrade.

## `1.3.11` → `1.3.12` adoption

1.3.12 changes rendered harness files, so **adoption alone does not deliver
it**. The release adds a manifest leaf (`hooks/lib/guard-supervise.pl` for the
Claude Code, Codex and pi surfaces) and changes the rendered settings arrays:
bright-line guards are re-registered through the supervisor at 30 s,
`turn-baseline.sh` is registered on `UserPromptSubmit`, four retired hooks are
unregistered, and `.claude/settings.local.json` gains a `permissions.deny`
backstop. `release adopt` replays the owner record's saved values and does not
materialize new leaves, and template key removal needs a fresh render
(`core-rules/inheritance.md` §6). Until a checkout group is detached and
attached fresh it keeps 1.3.11's 5 s, unsupervised guard registrations, which a
stalled guard can turn into an allow; keeps the retired hooks; and still asks
for a DoD receipt on every dirty non-doc Stop.

Several 1.3.12 rules also judge a project's **default branch**, not your
checkout: both gates read their configuration from the range base, and pi
checks project `.pi/` content against the remote default. Land the
preparation in step 1 through ordinary PRs **before** a project adopts 1.3.12:
afterwards each of those changes is a gate-config change that needs the
repository owner's approval.

On every machine, in this order:

1. Prepare each project ([preparation](#1312-project-preparation)).
2. Update the tools ([tool floors](#1312-tool-floors)).
3. Install, verify and activate 1.3.12:

   ```sh
   TARGET_RELEASE=1.3.12
   : "${RELEASE_REMOTE:?Set the remote containing annotated tag v$TARGET_RELEASE}"
   : "${TRELLIS:=trellis}"
   : "${TRELLIS_HOME:?Set TRELLIS_HOME (or export it) before configuring}"
   "$TRELLIS" release install "$TARGET_RELEASE" --remote "$RELEASE_REMOTE"
   "$TRELLIS" release verify "$TARGET_RELEASE"
   "$TRELLIS" configure --home "$TRELLIS_HOME" --release "$TARGET_RELEASE"
   ```

   `configure` relinks the user surface. That replaces the pi
   `trellis-computer-use` skill with its 1.3.12 routing text and the user-level
   `~/.claude/hooks/herdr-foreman-session.sh` with the 1.3.12 hook, which no
   longer probes at SessionStart; project adoption does not touch either.
   1.3.12 does not change `scripts/trellis-launcher.sh`, so the 1.3.11
   launcher can stay.
4. On machines that run pi, update pi and its setup
   ([pi](#1312-pi-110-and-the-pi-setup)), so the pi version row can be clean
   when you verify.
5. Detach and attach each **entire checkout group** fresh, one group at a time
   ([re-render](#1312-re-render-every-checkout-group)), then run its scoped
   `doctor` ([verify](#1312-verify)).

Projects not yet re-rendered keep working under an active 1.3.12: their
`skill-size-preflight` SessionStart call is answered as a silent no-op.
**Attaching at an older release needs that release's own CLI.** Every release
through 1.3.11 renders that SessionStart route and 1.3.12's renderer does not,
so an active 1.3.12 refuses `trellis attach --release 1.3.11` (or earlier) with
`contextual template is malformed or unsafe:
core-rules/templates/claude-settings.local.json` and writes nothing. Run the
older release's own attach, or detach and attach the group at 1.3.12. Worktree
seeding and `doctor` are unaffected: they use the recorded release's own
code.

### 1.3.12 project preparation

Do these on each project's default branch, merged before the project adopts
1.3.12.

- **Make `local.config.sh` data.** Both gates now parse
  `process-gate-local/local.config.sh` and `security-gate-local/local.config.sh`
  (each in `.claude/skills/` and `.agents/skills/`) as data instead of sourcing
  them. Allowed lines are blanks, comments and `NAME=value` with a literal
  value (`PROCESS_GATE_*`, which may also be an array, or `SECURITY_GATE_*` /
  `LLM_*`); the only expansion allowed is `"${NAME:-literal}"` naming its own
  key. A function, a command, `export`, `source`, `$(…)`, a variable reference,
  a `;` inside a value, or a default that names another key makes every run
  BLOCKED with `process-gate local config is not data` (or the security-gate
  equivalent). Move computed values into the commands themselves or into a
  validator:

  ```sh
  # Before (sourced shell): BLOCKED in 1.3.12
  PROCESS_GATE_TEST_CMD="$(./scripts/pick-tests.sh)"
  export PROCESS_GATE_TEST_TIMEOUT=900
  # After (data)
  PROCESS_GATE_TEST_CMD="./scripts/run-gate-tests.sh"
  PROCESS_GATE_TEST_TIMEOUT="${PROCESS_GATE_TEST_TIMEOUT:-900}"
  ```

  The process-gate grammar is in the process-gate skill's "Gate config is
  read from the range base, as data"; the security-gate grammar is in the
  security-gate skill's "Diff mode: config comes from the range base".

- **Point validators at `$PROCESS_GATE_PROJECT_DIR`.** Stack validators now
  run from a private copy taken from the range base, with cwd set to the
  checkout under test and `PROCESS_GATE_PROJECT_DIR` set to its absolute path.
  A validator that finds the project from its own location now finds the
  private copy. The one-line fix:

  ```sh
  # Before
  ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
  # After
  ROOT="$PROCESS_GATE_PROJECT_DIR"
  ```

  A validator may `source` only files from the trusted copy; declare any
  helper it sources in `PROCESS_GATE_VALIDATOR_DEPS` and source it from
  `$PG_TRUSTED_ROOT`. Sourcing a sibling that is not declared fails the
  validator.

- **Commit the security baseline on the default branch.** Diff mode reads
  `<audit dir>/*-baseline-<project>.json` from the range base only. A range
  that adds or edits its own baseline does not use it, and a base without one
  BLOCKS. The baseline has been required since 1.3.10.

- **Inline `.gitleaks.toml` extends.** A base `.gitleaks.toml` with an
  `[extend] path` (in any key casing or quoting) BLOCKS every diff run,
  because gitleaks would resolve that path against the worktree. Inline the
  extended rules into the root `.gitleaks.toml` before adopting.
  `[extend] useDefault = true` is fine and needs no change.

- **Check project pi configuration.** If the project tracks a `.pi/`
  directory or `.agents/agents`, `.agents/workflows` or `.agents/skills`
  content, it must be merged on the remote default branch: from 1.3.12 every
  Trellis pi launcher refuses to start over pi configuration the default
  branch has not approved.

- **Move any `permissions.deny` you added to `.claude/settings.local.json`.**
  The 1.3.12 render owns that key, and attach refuses to render over a file
  that already has a value there. Move those rules to `.claude/settings.json`
  or merge them by hand first.

### 1.3.12 tool floors

- **Scanners.** A required scanner that is missing, crashes or reports a
  partial scan now BLOCKS its row instead of passing: semgrep for changed
  code, ShellCheck for changed shell, osv-scanner when a manifest changes,
  and gitleaks for every range. Install all four where the gate runs, as
  absolute binaries outside any project. gitleaks must support
  `--gitleaks-ignore-path`. A project with a root `.gitleaks.toml` needs
  Python 3.11 or later for `tomllib`.
- **perl** must be on the hook `PATH`: the guard supervisor is a perl script,
  and every guarded tool call is denied without it. `doctor` reports a missing
  perl as an ERROR.
- **Claude Code 2.1.294 or later and Codex 0.116.0 or later** for the
  receipt trigger. `doctor` warns below the Claude Code floor; nothing checks
  the Codex floor yet.
- **pi 1.1.0 or later** on machines that run pi (below).

### 1.3.12 re-render every checkout group

Use the whole-group procedure from the `1.3.6` → `1.3.7` section below: record
every worktree root and its harness selection, detach all worktrees of the
group together, then attach the former manager first and each remaining root
with its recorded `--harness` flags, at `--release 1.3.12`. Do not reattach any
root before the whole group is detached, and do not use the default harness
set. A legacy direct-copy install must also copy `lib/guard-supervise.pl`
beside its hooks; without it every guarded call is denied.

### Gate-config changes need the owner at merge

From 1.3.12 both gates are judged with the configuration on the range base,
and a range that changes gate configuration needs the repository owner. Gate
configuration is:

- at the repository root: the `process-gate-local` and `security-gate-local`
  trees under `.claude/skills/` and `.agents/skills/`, the legacy
  `.claude/skills/process-gate/local.config.sh` (still honoured read-only;
  changing it is likewise a gate-config change), the scanner config
  (`.gitleaks.toml`, `.gitleaksignore`, `.semgrepignore`,
  `osv-scanner.toml`), the security baselines, and the validator paths and
  declared dependencies;
- at any depth: any `secrets-allowlist.txt`, `.trellis.json` and `.trellis/`,
  `.envrc` and `.env*`, and the pi and agent loader paths (`.pi/`,
  `.agents/agents/`, `.agents/workflows/`, `.agents/skills/`);
- any changed path that contains a non-ASCII byte.

- **Push mode** (a feature-branch push): the range is gated with the base
  configuration and the verdict carries a notice.
- **Merge mode** (the gate of record before merging a PR): BLOCKED until the
  repository owner posts the line `gate-config-approved: <full head SHA>` in a
  comment or review on the one open PR whose head is that SHA. Push a new
  commit and the approval must be posted again for the new SHA. Agents never
  post or script this line, and there is no environment override.
- **A push that targets `main` or `master`** (`--target=main`, passed by the
  managed `pre-push`): any gate-config change is BLOCKED, approved or not.
  Merge it through its PR.

`SECURITY_GATE_SKIP=1` is no longer honoured: process-gate reports it as
BLOCKED. Remove it from scripts and aliases, and unset any
`PR_GATE_SHIFTLEFT_*` overrides: they are now ignored, because
`pr-gate-shiftleft` no longer runs the gate.

### Push mode never falls back to the last commit

With no `--range` or `--base`, push mode gates the base the shared diff-base
resolver derives and prints a `diff-base:` receipt line. When the resolver
cannot derive a base it gates every commit not on the local `main` (else
`master`), receipted `via fallback`; with neither branch it refuses before any
check. The 1.3.11 `HEAD~1..HEAD` fallback is gone in every mode, so a scratch
clone with no derivable base and no `main`/`master` now refuses, including a
`pre-push` run with nothing on stdin. Pass `--base=<ref>` or `--range=<a>..<b>`
in scripts and agent runs. Merge mode accepts `--base` as well as `--range`.

The managed `pre-push` also changes for stacked and multi-ref pushes. A first
push whose parent branch is not on the remote gates from the remote default
and prints a hint to push the parent first; push the parent first to gate only
your own commits. With `TRELLIS_ALLOW_MAIN_PUSH=1`, a push of `main` beside a
branch on a different range refuses: push them separately.
`TRELLIS_ALLOW_MAIN_PUSH` is owner-only break-glass; agents stop and report.
A pushed `.trellis.json` cannot remove protection from `main`, `master` or the
remote default's `template.branch`, and a `template.branch` that does not name
a real branch is refused.

`doctor`'s `remote-default` row is now `remote-default-not-protected`, at INFO
when `origin/HEAD` differs from the project's `template.branch` (default
`main`). Fix it with `git remote set-head origin <policy-branch>` if the
difference is unintended.

### Retired hooks and local opt-in

`skill-size-preflight`, `truncation-check`, `propose-rules` and
`primer-capture-nudge` are no longer registered for Claude Code or Codex; the
re-render removes them. The scripts stay in the payload under
`.trellis/runtime/core-rules/hooks/` (Codex: `core-rules/codex/hooks/`). The
pi dispatcher is unchanged. The Skill size budget is still enforced at use by
`skill-preload-guard` and `skill-slash-guard`.

To keep one of them in an attached Claude Code project, register it in a
settings file the project owns, such as the tracked `.claude/settings.json`,
never in the rendered `.claude/settings.local.json` or `.codex/hooks.json`: a
hand edit to a Trellis-owned array becomes a detach conflict. The command form
is the one 1.3.11 rendered, for example:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Grep|Bash|Read",
        "hooks": [
          {
            "type": "command",
            "command": "TRELLIS_ROOT=\"$CLAUDE_PROJECT_DIR/.trellis/runtime\" \"$CLAUDE_PROJECT_DIR/.trellis/runtime/core-rules/hooks/truncation-check.sh\"",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

`propose-rules.sh` and `primer-capture-nudge.sh` go on `Stop` the same way.
`skill-size-preflight.sh` goes on `SessionStart` with the direct script path:
the launcher route it used is now a no-op. Such a registration resolves only
in an attached checkout. Codex reads its hooks from `.codex/hooks.json`,
which Trellis renders, so 1.3.12 documents no Codex opt-in.

### The receipt trigger and its residuals

`stop-verify` now demands the DoD receipt only when the turn changed the tree,
judged against the baseline `turn-baseline.sh` writes at the start of each
turn. A changed tree, a commit that left the tree clean, and a missing or
unreadable baseline still demand it. Two residuals are accepted:

- **Forged baseline.** The baseline and its nonce log are ordinary files owned
  by the agent's own user, under `TRELLIS_HOME`. An agent that deliberately
  rewrites both with the current fingerprint can suppress the demand on a turn
  that changed code. A turn that edits and then exactly reverts to its entry
  state also reads as unchanged. The receipt is a nudge; real verification
  stays in the pre-push and merge gates.
- **Un-arming.** A project is armed only while its settings register
  `turn-baseline.sh`, and `.claude/settings.local.json` is git-ignored. Removing
  that registration does not dirty the tree, and the project then behaves as it
  did before 1.3.12. Re-attaching re-renders the registration.

### 1.3.12 pi 1.1.0 and the pi setup

The recommended pi setup (`AGENT_PI_SETUP.md`) supports pi 1.1.0 and above and
installs 1.1.0. `trellis doctor` warns when pi is below 1.1.0, or missing while
a registered checkout selects the pi harness.

1. **Upgrade pi** (guide step 1):

   ```sh
   npm install --global @earendil-works/pi-coding-agent@1.1.0
   pi --version < /dev/null
   ```

2. **Apply guide step 2.** Its `settings.json` adds
   `"extensions": ["-builtin:mcp"]`, which switches off pi 1.x's built-in MCP
   client, and its trimmed package set drops the MCP adapter and the
   session-messaging package. Reinstall packages with
   `npm ci --legacy-peer-deps` in `~/.pi/agent/npm`, never `npm install`.
3. **Keep workflows off globally** (guide step 6). `foreman-start.sh` turns
   `SubagentWorkflow` on for a foreman's worktree by writing that worktree's
   `.pi/subagents.json`. Do not hand-write one: the interactive `pi()` refuses
   an untracked or branch-modified file.
4. **Remove the retired computer-use profile.** pi no longer carries computer
   use or the session-messaging (intercom) package. Back up
   `~/.pi/agent/settings.json` and `~/.pi/agent/mcp.json`, then:

   ```sh
   pi remove "$HOME/.local/share/trellis/pi-computer-use/node_modules/pi-mcp-adapter"
   if [ -f "$HOME/.pi/agent/mcp.json" ]; then
     jq 'del(.mcpServers.cua)' "$HOME/.pi/agent/mcp.json" > "$HOME/.pi/agent/mcp.json.tmp" &&
       mv "$HOME/.pi/agent/mcp.json.tmp" "$HOME/.pi/agent/mcp.json"
   fi
   ```

   The `pi remove` operand is the adapter package the earlier guide installed
   with `pi install`; if `pi list` shows no such package, skip that line.

   Keep every other package, server and setting. Do not edit
   `~/.pi/agent/skills/trellis-computer-use` by hand; step 3 of the adoption
   order relinks it. The tool prefix
   `~/.local/share/trellis/pi-computer-use`, the `agent-browser` symlink and
   Cua Driver are no longer used by pi; remove them only if nothing else uses
   them. Route computer-use work to Codex CLI in a Herdr pane
   (`herdr agent start <name> --kind codex --pane <id> -- --search`) or to
   Claude Code.
5. **Restart pi** at an attended boundary. A running session keeps the tools
   it started with. In a new session, no `cua_*`, `mcp` or `mcpScript` tool
   is offered.

#### pi worktree root and temp directory

1.3.12 moves pi's durable worktree root from `~/.trellis/pi-worktrees` to
`~/.pi-worktrees`, and sends the temp files of the commands pi runs to a
private `$TMPDIR/pi`. pi writes its bash spill logs to the same root as its
worktrees, and that root must not sit under `~/.trellis`. `foreman-start.sh`
applies the change to Herdr launches. For interactive launches, replace the
`pi()` function in your shell profile with the guide's step 8 version and add
the step 2 `shellCommandPrefix` key to `~/.pi/agent/settings.json`. The new
`pi()` refuses a symlinked or foreign-owned `~/.pi-worktrees`, and refuses
`TMPDIR` set to the home directory.

Worktrees already under `~/.trellis/pi-worktrees` stay there until their work
is merged; do not move them. To see what is stale in the new root, the old
root and the temp directory:

```sh
scripts/disk-janitor.sh --report --scopes pi
```

The pi scope is **report-only** in 1.3.12: `--apply` refuses it and nothing
under a pi root is deleted. Remove what it lists by hand.

### Faster attach and new worktrees

Attach now commits its artifacts from one process (journal v2), hands its
slower checks to a detached background job and returns, and a new worktree of
an already attached checkout reuses a verified sibling's render, falling back
to the full attach on any doubt. The deferred checks are visible:

- `doctor` shows an `attachment checks` row per worktree, and
  `doctor --fix` runs them now.
- `SessionStart` prints one warning when a worktree's checks FAILED or are
  blocked by an unfinished Trellis operation.
- The managed `pre-push` refuses while the checks are FAILED or blocked by a
  pending journal or adoption marker; follow the printed remedy (often
  `trellis recover <root>` or `trellis doctor --fix`). On `ok` it passes; in
  any other state it runs the read-only checks inline.

A journal left by an interrupted 1.3.12 attach is a v2 journal. Recover it
with 1.3.12: an earlier release refuses it rather than rolling back a prefix it
cannot see. If you script delegated recovery with `--expected-journal-sha256`,
a v2 journal's value is the SHA-256 of
`trellis-attachment-journal-v2\n<journal sha256>\n<progress-log sha256, or none>\n`,
where the progress log is `state/attachment-progress/<attachment id>.log`.

### 1.3.12 known residuals

These are accepted for 1.3.12:

- **Journal v2 durability.** The one-process publisher does not `fsync` its
  writes, so its crash safety covers a killed process, not a power loss.
- **Linux exclusive rename.** On Linux the publisher needs `renameat2`
  (glibc 2.28 or later) for its no-replace rename. Without it attach fails
  closed rather than risk replacing a directory; run the attach on a host with
  glibc 2.28 or later.
- **Mixed-release locks.** A release from before journal v2 refuses to
  reclaim a lock left by a v2 attach; use 1.3.12 for that checkout.
- **Refuter degraded.** With Grok retired, four model families remain. The
  herdr-foreman refuter role still requires three seats and can fill two
  beside any producer, so it reports `DEGRADED: refuter has 2/3` and
  `approval_ready` stays false. A seat-count change is deferred.
- **Receipt trigger.** The forged-baseline and un-arming residuals described
  in [The receipt trigger and its residuals](#the-receipt-trigger-and-its-residuals).
- **pi janitor.** `disk-janitor.sh --scopes pi` is report-only; delete what it
  lists by hand.
- **Older releases.** An active 1.3.12 cannot attach a project at 1.3.11 or
  earlier; use that release's own CLI.
- **Validator helpers.** A stack validator may source only files from the
  trusted base copy, and its helper API is narrower than native `source`
  (see the process-gate skill). `run-baseline.sh` still reads
  `security-gate-local/local.config.sh` from the worktree; only the owner
  runs it.
- **Codex version floor.** The receipt trigger needs Codex 0.116.0 or later,
  and nothing checks it yet.

### 1.3.12 verify

After each group is re-rendered, run its scoped `doctor` and confirm:

- no `perl` ERROR and no guard-registration WARN (unsupervised, under 30 s,
  or a missing supervisor);
- the Claude Code version row and, on pi machines, the pi version row are
  clean;
- for each root and each recorded harness, `hooks/lib/guard-supervise.pl` is a
  live link and its exact exclude entry is present.

`doctor` validates recorded values, not the new template, so check the
rendered settings directly as well. For a Claude Code root:

```sh
S="$ROOT/.claude/settings.local.json"
grep -c 'guard-supervise.pl' "$S"   # 3
grep -c 'turn-baseline.sh' "$S"     # 1
grep -cE 'truncation-check|propose-rules|primer-capture-nudge|skill-size-preflight' "$S" || test $? -eq 1   # expect 0
```

For a Codex root, run the same three checks, with the same `|| test $? -eq 1`
on the third, on `$ROOT/.codex/hooks.json`; expect `2`, `1` and `0`.

## `1.3.10` → `1.3.11` adoption

Adoption delivers the 1.3.11 process-gate secrets-allowlist move and the
attach launcher-missing diagnostic. 1.3.11 adds no harness leaves or settings
arrays of its own. Adoption still does not materialize native leaves that an
existing root is missing: a checkout group that reached 1.3.7 or later by
adoption alone still lacks the 1.3.7 `hookspath-guard` leaves until the
whole-group detach and fresh attach in the `1.3.6` → `1.3.7` section below.

### Secrets allowlist moves to `process-gate-local`

`check-secrets.sh` now reads `<project>/.claude/skills/process-gate-local/secrets-allowlist.txt`
(Codex: `<project>/.agents/skills/process-gate-local/secrets-allowlist.txt`;
when both exist the active harness wins, same as `local.config.sh`). The old
`<project>/.claude/skills/process-gate/secrets-allowlist.txt` path (and its
`.agents` twin) is linked read-only to the release runtime at attach time via
the `core-rules/skills` → `.claude/skills` inheritance manifest entry, so a
project file there refuses attach with exit `3`
(`attachment destination is project-owned: .claude/skills/process-gate`).
Move the file before attaching:

```sh
mkdir -p .claude/skills/process-gate-local
mv .claude/skills/process-gate/secrets-allowlist.txt \
  .claude/skills/process-gate-local/secrets-allowlist.txt
# Codex twin: .agents/skills/process-gate-local/secrets-allowlist.txt
```

The legacy path is still read, read-only, with a one-line deprecation notice
on stderr naming both paths (`check-secrets: deprecated allowlist <legacy>;
move it to <new>`). When both exist the overlay file wins and the legacy file
is ignored, with the same notice.

### Attach requires the installed launcher

`attachment_contextual_render_context` requires the installed launcher at
`$HOME/.local/bin/trellis` to be present and executable. A missing launcher
still returns `5` (`TRELLIS_EX_UNAVAILABLE`) and a non-executable launcher
still returns `4` (`TRELLIS_EX_STATE`); each now emits exactly one diagnostic
line naming the expected path and the remedy
(`launcher missing at <path>; install it (docs/UPGRADING.md "Reinstalling the
launcher") and retry` /
`launcher at <path> is not executable; ...`). Reinstall with the
[Reinstalling the launcher](#reinstalling-the-launcher) procedure when doctor
reports `launcher currency`.

### Docker inside managed hooks

The managed git-hook dispatcher runs hooks with `HOME=/dev/null`, so Docker
CLI contexts (e.g. colima's `docker context use colima`, stored under
`~/.docker`) are invisible inside hooks, and a pre-push gate that runs Docker
fails with "Docker run failed". The dispatcher forwards a caller-set
`DOCKER_HOST` but never a context. From 1.3.11 that export reaches the
process-gate payload as well as the prior hooks; under 1.3.10 it reached only
the prior hooks and passthrough shims, never the gate payload — so a
Docker-gated push failed even with `DOCKER_HOST` exported. On context-based
setups (colima, OrbStack, any non-default `docker context`), export the socket
in the shell profile before pushing:

```sh
export DOCKER_HOST="$(docker context inspect --format '{{.Endpoints.docker.Host}}')"
```

`doctor` now WARNs while the export is missing or unreachable: host-level
`docker-host-unset-for-hooks` when a docker CLI is on `PATH`, `DOCKER_HOST`
is unset, and the active context is not `default` (sits alongside the
colima-fleet `docker-context-not-colima` row, which is unchanged; overlap on
a drifted colima machine reports both), and per-row
`docker-not-on-recorded-toolchain` when `docker` resolves on the caller `PATH`
but not on the recorded toolchain `PATH` the gate runs with — refresh it with
`trellis attach --refresh-toolchain`.

### `trellis recover` is only for a journaled, interrupted operation

`trellis recover` recovers a journaled, interrupted attach/detach/adopt
transaction for that worktree. On a healthy attachment with no matching
journal it returns `5` (`TRELLIS_EX_UNAVAILABLE`,
`no matching attachment journal`). That is expected, not a fault in the
attachment: do not delete journals or re-attach to "fix" it.

### Merge mode now requires `--range`

`run-all.sh --mode=merge` (the default) no longer defaults a range: without
an explicit `--range` it refuses with exit `1` and the exact stderr line
`merge mode requires --range/--base` before any check runs. In a scratch clone
with no local `main`/`master` the old default gated only `HEAD~1..HEAD` while
reporting a full merge verdict. Pass `--range=<base>..HEAD` (agents and
scripts) or derive it per ref (the pre-push hook already does). Push mode is
unchanged and keeps its `main..HEAD` / `master..HEAD` / `HEAD~1..HEAD`
fallbacks. (1.3.12 removes the last of these; see
[Push mode never falls back to the last commit](#push-mode-never-falls-back-to-the-last-commit).) Who is affected: any script or agent running merge mode without
a range must add one; ambiguous pushes now fail the push closed instead of
falling back to a default scan.

The pre-push hook fails closed when (i) two or more branch updates
derive different ranges, or (ii) a new branch ref derives nothing because the
remote default does not resolve — the refusal message names which case fired
(push branches one at a time; `git remote set-head origin -a`). Tag refs
(`refs/tags/*`) and branch deletes never count toward ambiguity: a branch+tag
push gates the branch range plus every tag not reachable from its gated tip.
A tag-only push gates each tag range in turn (a payload tag gates exactly its
payload commit). Any underivable tag range refuses before the gates run;
there is no checkout-scan fallback for tags (R31). A delete never widens the
range. `doctor` reports a checkout whose `origin`
default resolves nowhere as `remote-default-unresolved` (remedy: `git remote
set-head origin -a`), and names a resolved non-`main`/`master` default as
info only.

The hook also refuses a branch update whose remote tip is not in the local
object store (`its remote tip is not local; fetch first`), a new branch with
no merge-base with the remote default, and any ref outside `refs/heads/*` and
`refs/tags/*` (`unsupported ref ... push branches or tags only`; deleting such
a ref is still allowed). A push that only deletes refs runs no gate. A new
branch is ranged from its merge-base with `refs/remotes/origin/HEAD` (else
`origin/main` or `origin/master`), so run `git fetch` first: a stale remote-tracking ref makes the
range include commits that are already merged. That over-gates rather than
under-gates, but it can block a push on findings that are not yours.

Enforcement lives in `run-all.sh` alone, by design: it is the single choke
point every gate row passes through, while the individual `check-*.sh`
scripts take no `--mode` flag (a direct invocation cannot name a mode, so
there is nothing to refuse on) and legitimately keep their `main..HEAD`
default for direct use. `pg_parse_range` is the backstop, not the enforcer:
it can never return `HEAD~1..HEAD` in merge, which closes the scratch-clone
hole for direct invocations too.

## `1.3.9` → `1.3.10` adoption

Adoption delivers the 1.3.10 process-gate and security-gate scripts (security
scans and Pi auxiliary checks now fail closed), the attachment and doctor
changes, and the shared-exclude migration for checkout groups. 1.3.10 adds no
harness leaves or settings arrays of its own. Adoption still does not
materialize native leaves that an existing root is missing: a checkout group
that reached 1.3.7 or later by adoption alone still lacks the 1.3.7
`hookspath-guard` leaves until the whole-group detach and fresh attach in the
`1.3.6` → `1.3.7` section below.

On every machine, in this order:

1. Install, verify and activate 1.3.10
   ([user-surface activation](#139--1310-user-surface-activation)).
2. Refresh the launcher (below). Group adoption refuses until this is done.
3. For each project to adopt, generate and commit its security baseline
   ([security baseline prerequisite](#1310-security-baseline-prerequisite)).
   Pi owners with a project-authored `.pi/` deferral fail Bypass and doctor
   after adoption; list them first:

   ```sh
   jq -r 'select(any((.pre_existing // [])[]; .kind == "symlink"
       and .reason == "project-authored-file" and (.path | startswith(".pi/"))))
     | .worktree_root' "${TRELLIS_HOME:-$HOME/.trellis}"/state/attachments/*/*.json
   ```

4. Adopt each whole project group through the refreshed launcher
   ([adopted worktree groups](#139--1310-adopted-worktree-groups)), then run the
   scoped `doctor`.
5. Only where a partial detach/re-attach left the registry release behind its
   owners, use [record/registry release reconciliation](#139--1310-recordregistry-release-reconciliation).

### Refresh the launcher

1.3.10 changes `scripts/trellis-launcher.sh`: its verified `release` and
`upgrade` bundle now also loads `scripts/lib/surface-plan.sh` and
`scripts/attach-project.sh`, which define the group exclude planner.
`release install` and `configure` do not replace an installed launcher that
differs from its template, so a machine keeps its 1.3.9 launcher until it is
reinstalled. With that launcher, adopting a real checkout group (more than one
owner record for the checkout) refuses with
`group exclude planner unavailable; use the verified 1.3.10 CLI to adopt`
(exit `5`). Singleton adoption still succeeds.

Check which launcher is installed:

```sh
grep -c 'EXCLUDE_PLANNER' "$HOME/.local/bin/trellis"
```

`2` is the 1.3.10 launcher. `0` (grep exits `1`) is an older one; reinstall it
with the [Reinstalling the launcher](#reinstalling-the-launcher) procedure:

```sh
TARGET_RELEASE=1.3.10
PAYLOAD_LAUNCHER="${TRELLIS_HOME:-$HOME/.trellis}/releases/$TARGET_RELEASE/payload/scripts/trellis-launcher.sh"
grep -c 'EXCLUDE_PLANNER' "$PAYLOAD_LAUNCHER"            # must print 2
mv "$HOME/.local/bin/trellis" "$HOME/.local/bin/trellis.before-$TARGET_RELEASE"
"$HOME/.local/bin/trellis.before-$TARGET_RELEASE" configure --release "$TARGET_RELEASE" \
  --launcher-template "$PAYLOAD_LAUNCHER"
cmp "$HOME/.local/bin/trellis" "$PAYLOAD_LAUNCHER"
grep -c 'EXCLUDE_PLANNER' "$HOME/.local/bin/trellis"      # must print 2
```

Then finish step 4 of that procedure: a scratch `trellis worktree sync` and a
`trellis doctor` with no `launcher currency` or `toolchain provenance` WARN.
Only then remove `trellis.before-1.3.10`. Never edit the installed launcher by
hand.

## `1.3.9` → `1.3.10` user-surface activation

1.3.10 adds missing-owned-symlink repair to `relink --user`. It restores only
absent symlinks recorded in the committed user owner, verifies their recorded
release, and leaves ownership and rendered settings unchanged during repair.
Modified destinations, missing sources, and missing non-symlink artifacts still
refuse; this is not a force or reconstruction command. Project attachment
migration remains separate.

Install and verify 1.3.10 through the stable launcher, then activate it explicitly:

```sh
TARGET_RELEASE=1.3.10
"$TRELLIS" release install "$TARGET_RELEASE" --remote "$RELEASE_REMOTE"
"$TRELLIS" release verify "$TARGET_RELEASE"
"$TRELLIS" configure --home "$TRELLIS_HOME" --release "$TARGET_RELEASE"
```

**Interrupted activation caveat:** the still-active 1.3.9 runtime runs configure,
which delegates user relinking to 1.3.10. A signal/crash during repair can leave
an `operation: "repair"` user journal that 1.3.9 cannot read. Its configure
recovery runs the old attachment script, so retrying through the launcher can
exit `4` before reaching the new runtime. `trellis recover PATH` is project-only
and cannot recover this user journal.

Run the installed **1.3.10** attachment command directly, even when the journal's
recorded owner release is 1.3.9, then retry activation through the stable launcher:

```sh
"$TRELLIS_HOME/releases/1.3.10/payload/scripts/attach-project.sh" \
  relink --user --home "$TRELLIS_HOME" --release 1.3.10
"$TRELLIS" configure --home "$TRELLIS_HOME" --release 1.3.10
```

Repair interruption diagnostics print this release-specific command with the
actual home and executing runtime version. Recovery discards still-exact,
journal-pinned links and stages, accepts already-absent links, and drops the
repair journal before relink re-plans. It does not require the old payload or
owned JSON to remain exact merely to undo the repair. Foreign replacements and
unsafe paths are preserved, and re-planning still refuses them. Non-signal repair
failures also discard the journal rather than wedging later user commands. Do
not hand-delete journals, edit installed payloads, or recreate links by hand.

## `1.3.10` security baseline prerequisite

Before adopting 1.3.10 for any project, run the current release's security-gate
`run-baseline.sh` against that checkout and confirm its baseline JSON exists:

```sh
bash "$PROJECT_ROOT/.trellis/runtime/core-rules/skills/security-gate/scripts/run-baseline.sh" "$PROJECT_ROOT"
```

Commit the generated baseline JSON so clones and worktrees see it.

A missing security-gate skill or baseline now fails the Security row, including
in attached projects. This row remains always-hard in **pre-push**, so adoption
without a baseline blocks pushes, not just merge reviews. Missing scanner-binary
behaviour is unchanged and is a separate follow-up.

Pi owners with `project-authored-file` entries under `.pi/` now fail Bypass and
doctor after adopting 1.3.10; move the project file aside, then detach and attach again.

## `1.3.9` → `1.3.10` adopted worktree groups

After installing, verifying and activating the 1.3.10 CLI and
[refreshing the launcher](#refresh-the-launcher), explicitly adopt the whole
selected project group through that CLI:

```sh
"$TRELLIS" release adopt 1.3.10 --project "$PROJECT_ID" --fleet "$FLEET"
```

Adoption now derives each root's selected-release exclude plan with legitimate
project-authored deferrals, requires compatible plans and exactly one exclude
manager, and reconciles the recorded/live managed block even when the owners
already say 1.3.10. Every owner receives the same current block/hash and after
snapshot; manager roles, original pre-attach restoration data and every external
exclude byte are preserved. Winning Git ignore negations, divergent deferrals,
unavailable committed siblings, tampered/duplicated blocks and CAS races refuse
instead of publishing a union or accepting stale bytes.

This is **not existing-root native-leaf delivery**: missing hookspath leaves and
associated doctor findings remain until the documented whole-group detach/fresh
attach procedure. Fresh checkout-enabled adds receive the current full surfaces.
The wrapper checks the source group's plan before Git creation; `--no-checkout`
still defers reconciliation. Other checkout/hook failures can still leave a Git
worktree; the wrapper never automatically deletes it or its branch.

On interruption, retry `release adopt` through 1.3.10 with the same selector.
Private plans under `state/release-adoptions/<checkout-id>` retain common-file,
owner, anchor and hook snapshots. Recovery verifies the registry commit boundary
and either recognizes a fully published group or rolls back before re-planning;
it never replays a whole registry snapshot. Pending plans block sync/attach/add.
Foreign changes are preserved and require inspection, not hand-deleted journals.
Sync failures (including quiet seeding) name exclude-plan hashes/missing paths,
invalid donors or owned artifacts, with a remedy; quiet suppresses only success.

## `1.3.9` → `1.3.10` record/registry release reconciliation

If a partial detach/re-attach left the registry release behind the committed
owner, use 1.3.10's `trellis attach --release RECORDED_RELEASE PATH` with the
owner's exact recorded harness selection (`--harness NAME` for each harness).
This is not adoption: the selected release must equal the owner release, and
all live siblings must agree. Attach verifies exact owner artifacts, runtime
anchors, harnesses, UUIDs and checkout binding before aligning **only** the stale
registry release. Owner records and project files are not republished; retained
unavailable inventory and unrelated rows are preserved. Repeating attach is a
no-op. Discovery/rebuild is not evidence of ownership.

An interrupted reconcile leaves a `reconcile-UUID.json` before/after journal.
Retry the same attach or run `trellis recover PATH` through **1.3.10**; recovery
reverifies exact ownership and rolls forward, never restores the stale release.
Foreign UUIDs, tampered owners/anchors, harness drift or changed journal bindings
refuse without reconciliation. Mixed live releases require a separately planned
whole-group detach/attach, not repeated single-owner release changes. Do not edit
registry JSON, hand-delete journals, force-deregister attached rows or run blanket
cleanup; this path does not authorize machine cleanup.

## `1.3.8` → `1.3.9` adoption

Adoption delivers all of 1.3.9: the updated managed `pre-push` dispatcher (the
`post-checkout` dispatcher is unchanged), the immutable pre-push carrier (both
the `githooks` and `husky` variants run from the release payload), the
process-gate `check-bypass.sh`, and the attachment and doctor changes. 1.3.9
adds no harness leaves, managed exclude entries or settings arrays, so no detach
and attach is needed for 1.3.9 itself. A checkout group that came to 1.3.7 or
1.3.8 by adoption alone still lacks the 1.3.7 `hookspath-guard` leaves and
`hooks.PostToolUse` entry; the `1.3.6` → `1.3.7` section below still applies to
it.

Two behaviour changes need attention after adopting:

- **Pushes fail hard on drifted hook authority.** For a managed attachment, a
  guarded push now fails unless the local `core.hooksPath` is exactly the one
  owner-recorded managed path and the effective value matches; a second local
  value or a worktree override also fails. The failure prints
  `git config --replace-all core.hooksPath <managed path>`, plus
  `git config --worktree --unset core.hooksPath` when a worktree override
  exists. For a single drifted value, `trellis doctor --fix` writes the same
  path; it does not repair multiple values. The carrier's verification runs with
  `HUSKY=0`, and both it and the operator's prior hook run with
  `pnpm_config_verify_deps_before_run=error`, so on pnpm 11 a stale
  `node_modules` fails the push instead of running `prepare: husky`.
- **`check-bypass.sh` reads the local owner record.** A manifest-only clone or CI
  checkout (a `.trellis.json` with no owner record under `TRELLIS_HOME`) now warns
  `not attached` instead of failing, so merge-mode gates in unattached clones
  pass this check. An attached checkout must still show every declared
  harness's owner-recorded registrations.

Before adopting a project, run the scoped `doctor`. Every checkout it reports
with a drifted or multi-valued `core.hooksPath` will refuse pushes after
adoption until it is repaired. Doctor checks local values only: in a repository
with `extensions.worktreeConfig` enabled, also run
`git config --worktree --get core.hooksPath` in each worktree and clear any
override. After adoption, run the scoped `doctor` again and confirm each row
reports the target release and a managed `core.hooksPath`.

## `1.3.6` → `1.3.7` adoption

Adoption delivers the new managed `pre-push` and `post-checkout` dispatchers and
immutable pre-push carrier. It does not rerun the surface plan or rewrite
rendered harness files: the new `hookspath-guard.sh` and
`lib/hookspath-check.sh` leaves, their managed exclude entries, and the new
Claude/Codex `hooks.PostToolUse` entry are not delivered. Doctor can report the
missing leaves and exclude entries, but its render check validates recorded
values rather than the new template values; a clean doctor does not prove the
settings entry is present.

Full delivery requires a detach and fresh attach of each **entire checkout
group**. Record every worktree root and its harness selection first; detach all
worktrees together, then attach the former manager first and each remaining root
with its recorded `--harness` flags. Do not use the default harness set or
reattach any root before the whole group has been detached.

After reattachment, run the scoped `doctor`. For every root, verify both new
hookspath leaves are live links and both exact exclude entries are present for
each recorded harness. If attach records a project-owned deferral, inspect the
new owner's `.pre_existing` record instead; deferred paths are not Trellis links
and are omitted from the managed exclude block. Independently compare the
`hooks.PostToolUse` array with
the selected release template for each attached Claude or Codex surface; doctor
does not detect a stale array value. The following is the standard Claude case,
with no recorded deferrals:

```sh
PAYLOAD="$TRELLIS_HOME/releases/$TARGET_RELEASE/payload"
for path in .claude/hooks/hookspath-guard.sh .claude/hooks/lib/hookspath-check.sh; do
  test -L "$ROOT/$path" && test -e "$ROOT/$path" || exit 1
  grep -Fx "/$path" "$COMMON/info/exclude" >/dev/null || exit 1
done
cmp <(jq -S '.hooks.PostToolUse' "$PAYLOAD/core-rules/templates/claude-settings.local.json") <(jq -S '.hooks.PostToolUse' "$ROOT/.claude/settings.local.json")
```

For a Codex-attached root, compare its settings array too:

```sh
cmp <(jq -S '.hooks.PostToolUse' "$PAYLOAD/core-rules/templates/codex-hooks.local.json") <(jq -S '.hooks.PostToolUse' "$ROOT/.codex/hooks.json")
```

For Codex and Pi, substitute `.codex` or `.pi` in the two leaf paths and the
exact exclude lines; do not hand-edit owned settings or exclude state.

## Source checkout and publication boundary

The Trellis source checkout is for development and release publication. It is
not a runtime prerequisite and needs no clean-`main` gate before an attached
project can use an already verified release. Moving it is repaired through
machine configuration/relink flow without changing the attached payload.

Before a compatibility or cutover release is pushed or published:

1. pass the release package, integrity, migration, three-harness, security, and
   process gates;
2. inspect `VERSION`, annotated tag, release record, and public mirror diff;
3. confirm the private source `origin.pushurl` points only at the private
   repository, and public `upstream` is fetch-only there;
4. publish public material from the reviewed mirror/publishing checkout;
5. confirm no local `~/.trellis` state, fleet inventory, source path, release
   anchor, credential, or private-only metadata appears in either publication
   diff.

A failed publication gate leaves push roles unchanged. It is never acceptable to
work around it by pushing a private source checkout at a public remote or by
tracking local machine state.

## Ownerless exclude block

`trellis attach` refuses with `orphan-owner-record` when an owner record under
`$TRELLIS_HOME/state/attachments/<checkout>/` names a worktree that Git no
longer lists for that checkout, usually one that was pruned after its registry
row was dropped. Attach never deletes such a record. Move it aside with its mode
kept, then attach again:

```sh
: "${RECORD:?Set the record path from the refusal line}"
BACKUP="$TRELLIS_HOME/backups/stale-owner-records-$(date +%Y%m%d)"
mkdir -p "$BACKUP" && chmod 700 "$BACKUP"
mv "$RECORD" "$BACKUP/"
```

When that record was the checkout's only one, attach also prints
`orphan-owner-sole`: the managed exclude block in
`<git_common_dir>/info/exclude` was recorded by that record alone, so moving it
aside leaves the block with no owner, and attach still refuses it (`managed
exclude block has no matching committed checkout ownership`). No other
attachment of the checkout depends on the block. Remove it, keeping every other
line of the file, then attach and run the scoped doctor:

```sh
: "${COMMON:?Set the git_common_dir from the orphan-owner-sole line}"
cp -p "$COMMON/info/exclude" "$BACKUP/info-exclude.before"
sed -e '/^# --- Trellis local attachment exclude block ---$/,/^# --- end Trellis local attachment exclude block ---$/d' \
  "$BACKUP/info-exclude.before" > "$COMMON/info/exclude"
"$TRELLIS" attach --fleet "$FLEET" "$WORKTREE"
"$TRELLIS" doctor --fleet "$FLEET" --project "$PROJECT_ID"
```

`trellis doctor` reports every such record as an `orphan-owner-record` warning,
whether or not the registry still has a row for it.

### Cutting a release: the payload tag (from 1.3.7)

From 1.3.7 the release tag names a **payload commit**, not the approved release
commit on `main` (spec 055 Unit 3). The payload commit's sole parent is the
approved release commit; its tree is that commit's tree minus the directories
in `core-rules/payload-exclude.txt` (`specs/` and every test directory); its
author and committer are copied from the release commit, so rebuilding it gives
the same SHA. Every installer, including the 1.3.6 launcher and store, extracts
the tag's tree, so every installer delivers the filtered payload without a code
change. The public mirror stays complete: it restores the test paths it already
publishes from the verified parent.

Cut the release in this order, from the source checkout, after the release PR
has merged to `main`:

1. `git fetch origin main`. The ancestry check in steps 4, 6 and 8 reads the
   fetched `origin/main`, so fetch first.
2. Run the off-main tag consumer gate:
   `bats scripts/tests/release-tag-consumers.bats`. It must pass, including the
   case that pushes a payload tag through the managed pre-push. A new consumer
   hit means reviewing the consumer, not widening the allowlist to pass.
3. Build the payload commit from the approved release commit:
   `payload="$(scripts/release-payload-commit.sh <approved-release-commit>)"`.
   It writes one commit object and touches no ref, index or working-tree file.
4. `scripts/release-payload-commit.sh --verify-candidate "$payload" <approved-release-commit> <VERSION>`.
   It refuses a wrong first parent, anything but the listed deletions, a
   `VERSION` mismatch, or an approved commit that is not on `origin/main`.
5. `git tag -a v<VERSION> -m "release <VERSION>" "$payload"`.
6. `scripts/release-payload-commit.sh --verify-tag v<VERSION> <approved-release-commit>`.
7. `git push origin v<VERSION>` through the managed pre-push. Never
   `--no-verify`: the pre-push gates the tag by the range it adds, which is the
   deletions-only payload commit.
8. Verify the pushed tag, not the local one: clone the remote into scratch
   (`git clone --no-checkout <remote> <scratch>`, which also sets
   `origin/main`) and run step 6 inside it:
   `(cd <scratch> && <source>/scripts/release-payload-commit.sh --verify-tag v<VERSION> <approved-release-commit>)`.
9. Mirror: install the release, then `trellis mirror --template-dir <mirror> --dry-run`.
   `--source-repo <source-checkout>` may fetch the tag and `main` from a local
   checkout in any mode, with the same commit, tree and parent verification;
   it reads that checkout's local `main`, so update it first. Review the diff:
   it must delete no test file and never add `specs/`. Then `--apply` (or
   `--push`), retaining `--source-repo` if used for the dry run. Without it,
   the mirror fetches from the release remote and refuses when it is unreachable.

The mirror pins the tag's commit, the `.commit` of a `release.json` rebuilt
from the fetch, and the installed `.commit` to one value, and requires the
rebuilt and installed `.tree` to match, before it reads anything from the
parent. A tag whose tree has no `core-rules/payload-exclude.txt` (every release
up to 1.3.6) is legacy: it is published from its payload alone and nothing is
restored from any parent.

`git describe` on `main` no longer names the newest release; that is cosmetic.
Nothing in Trellis resolves a release by walking `main`, and
`release-tag-consumers.bats` keeps it that way.

## Failure classes

The portable command family uses these exit classes:

| Exit | Meaning | Safe next action |
|---|---|---|
| `0` | Success | Inspect the scoped doctor/registry result and retain the receipt. |
| `2` | Invalid arguments | Correct the selector or flag; do not improvise another target. |
| `3` | Ownership or identity conflict | Inspect the exact conflicting artifact/row; preserve project-owned bytes. |
| `4` | Invalid, corrupt, or integrity-failed state | Stop using that state; verify/recover through the supported command. |
| `5` | Unavailable path, remote, or local capability | Keep the row explicit and restore the real capability/path before retrying. |

Classes `4` and `5` are also the two reportable row states — see
[Reading row state](#reading-row-state). A bulk command returns the highest
class any row produced, so a `0` from this table means every selected row
reported `0`, not that the command finished.

## Completion record

A completed upgrade records:

- selected version and release remote;
- whether the stepwise route or `trellis upgrade` was used;
- install and verify command results;
- exact adoption selector and per-row result;
- scoped post-adoption doctor result;
- any `unavailable` or `identity_error` rows and their disposition, and the
  highest exit class the run produced;
- for a compatibility/cutover release, the mirror/push-role and migration
  evidence required by the release gate.
