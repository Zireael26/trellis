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

## Repair a tracked file takeover after a merge

If a merge starts tracking a regular file where Trellis owned a native symlink
(for example `AGENTS.md`), review the path named by `trellis doctor`, then run:

```sh
trellis attach --refresh-artifacts --home "$TRELLIS_HOME" "$PROJECT_ROOT"
```

The repair retires only that symlink from this worktree's owned inventory and
records the tracked file as project-owned. It does not overwrite project files,
re-render templates, change the attachment identity or release, or edit the
shared exclude block. Keeping the exact recorded block lets older sibling owners
continue to verify. Empty or canonical-source-identical files are not authored
replacements. Missing links, untracked replacements, changed render keys,
runtime-anchor drift, retired native leaves, pending operations and foreign
bindings still refuse the repair; restore those states or use their documented
recovery route first.
Only `--home` and one checkout path may accompany `--refresh-artifacts`.

An already-exact attach (including post-checkout) with a current registry release
and no reconcile journal skips full sibling artifact/inventory reconciliation.
It still verifies the target, immutable release, registry identities, shared
exclude ownership and managed hook authority. Non-donor native drift no longer
blocks another worktree's attach; a reused donor must remain exact and have no
deferred project leaves. Fresh attachment verifies shared managed hook authority
before publishing worktree artifacts or owner/registry state. Release changes and
reconcile-journal recovery retain full group verification. Concurrent attaches
wait up to 15 minutes for the checkout lock, longer than the observed 9–12 minute
large-group attach; unsafe locks and expired waits still refuse.

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
state. Attachment and worktree seeding reuse successful verification within
one controlled shell tree across sibling owners. Within one attach or seed
run, a payload changed after the first verification is caught by the next run,
not the current one. Every script that loads the release store discards
inherited verification memos; a parent PID or an exported success entry is not
verification authority.

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
`relink` do not materialize it. There is no template-refresh or force flag
(the current [`--refresh-artifacts` repair](#repair-a-tracked-file-takeover-after-a-merge)
only retires tracked-file takeovers, not rendered surfaces):
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

## `1.3.21` → `1.4.0` adoption

1.4.0 removes most of the latency Trellis adds to agent work (spec 072) and
moves Herdr integration to the Herdr desktop app's core, `hc` (spec 073). The
gains reach a machine three ways, and adoption alone does not deliver all of
them:

| 1.4.0 change | Delivered by | Why |
|---|---|---|
| shared guard rules, pi in-process guards and batched lifecycle, supervisor wake-up, Python and `eslint` resolution, Stop reuse, delta review, session-context integrity from the stamp, Muse/GLM retirement and `argon` on `antigravity` | adopt alone | payload-resident, reached through `.trellis/runtime` |
| Herdr integration moves to `hc` (spec 073) | adopt | the old `herdr` CLI is not supported; run agents from the Herdr desktop app |
| post-checkout fast paths and hook digest memo | adopt alone | adoption regenerates the managed git-hook dispatchers and records `state/hook-digests/` |
| gate queue, Tests-row reuse, branch-push test-file selector, row order, gate slot, battery changes | adopt alone | payload-resident; they act on projects that run the process gate |
| release stamps, persistent `.exec` snapshot, metadata-only `help` / `heavy --status`, caller PATH for `trellis bench` | launcher reinstall | the stable launcher is installed by `configure`, not by adoption |
| one SessionStart dispatcher route (`trellis hook session-start`); `onFailure`, exec form, timeouts and `if` filters in Claude settings | re-render (`detach`/`attach`) | `.claude/settings.local.json` and `.codex/hooks.json` are attach-time output; `release adopt` does not rewrite them |

A render older than 1.4.0 keeps calling `trellis hook session-context`, which
still works and gets cheap once the launcher is reinstalled. Re-render with the
documented `detach` and `attach` pair (and `relink --user`, which
`configure --release` runs when an owned user attachment exists) when you want
the single `session-start` dispatcher route and the new Claude hook fields.

**Herdr is now the desktop app's core, `hc` (spec 073).** Trellis no longer
reads `HERDR_*` or calls the `herdr` CLI. Run the apex in a Herdr app terminal
(`HC_SCOPE` set; `hc` 0.1.15 or later on PATH). After adoption, re-run
`resolve-roles.py --implementer <agent>` once in each apex terminal: decisions
keyed to the old workspace/pane fields fail closed. Callers of `foreman-start.sh`
now pass a brief file as the second argument and drop `--tab`/direction.
`foreman-prompt.sh` is gone; use `hc send <address> "<text>"`. Remote lanes use
`hc run --on <machine>`.

### Install, adopt and re-key role decisions

Most users install from the public mirror; set `RELEASE_REMOTE` to it. The
stepwise route reviews between operations; `trellis upgrade` is also valid
because 1.4.0 is not installed yet.

1. **Install and verify 1.4.0:**

   ```sh
   (
     set -e
     TARGET_RELEASE=1.4.0
     : "${RELEASE_REMOTE:?Set the remote containing annotated tag v$TARGET_RELEASE}"
     : "${TRELLIS:=trellis}"
     : "${TRELLIS_HOME:=$HOME/.trellis}"
     export TRELLIS_HOME
     "$TRELLIS" release install "$TARGET_RELEASE" --remote "$RELEASE_REMOTE"
     "$TRELLIS" release verify "$TARGET_RELEASE"
   )
   ```

2. **Reinstall the launcher from the 1.4.0 payload**, exactly as
   [Reinstalling the launcher](#reinstalling-the-launcher) describes, with
   `TARGET_RELEASE=1.4.0`. That `configure` call also makes 1.4.0 the active
   management CLI (and relinks an owned user surface). Until the reinstall,
   commands still run on macOS and ext4/XFS: the 1.3.21 launcher verifies and
   copies the release on every call, as before. **On Linux/Btrfs**, every
   launcher from `1.0.0-rc.24` through `1.3.21` (`0d37cf1d3`) reuses an
   `os.listdir(fd)` directory cursor that stays at EOF after the snapshot is
   populated, leaving `release.json` writable (`0600`) so verification refuses
   it. Fixed in 1.4.0 (`a0454d1f2`, `ac0a54412`) by opening fresh directory
   descriptions in `release-store` and the launcher; Linux/Btrfs hosts must
   install the 1.4.0 launcher during the upgrade (run `configure` without
   `--no-install-launcher`, or follow
   [Reinstalling the launcher](#reinstalling-the-launcher)).

3. **Adopt 1.4.0 and check the registry:**

   ```sh
   "$TRELLIS" release adopt 1.4.0 --all
   "$TRELLIS" doctor
   ```

   Use `--fleet NAME` or `--project ID --fleet NAME` for narrower scope. The
   first launcher run per release pays one full verify and writes the schema-2
   release stamp (`state/release-stamps/`) and the execution snapshot
   (`releases/.exec/`); later runs check the stamp. Stamps and snapshots are
   keyed by release digest and are never shared between versions.

4. **Re-run `resolve-roles.py --implementer` once per apex terminal (spec 073):**

   In each Herdr desktop app apex terminal (`HC_SCOPE` and `HC_TERMINAL_ID`
   set), re-key `~/.trellis/state/roles-resolved.json` to the `hc` terminal:

   ```sh
   python3 -I "$HOME/.claude/skills/herdr-foreman/scripts/resolve-roles.py" \
     --implementer <agent>
   ```

   Decisions written by 1.3.21 or older are keyed to
   `herdr_workspace_id`/`herdr_pane_id` and fail closed once until this command
   runs in the apex terminal.

5. **Reclaim disk left by older launchers** (report first, then apply per
   category):

   ```sh
   trellis disk-janitor --scopes releases,release-tmp
   trellis disk-janitor --scopes releases,release-tmp --apply
   ```

   The `releases` scope reaps legacy `.tmp.<version>.exec.*` staging; the
   opt-in `release-tmp` scope reaps orphaned `.exec` work and the snapshots and
   stamps of uninstalled releases. Both keep anything with a live owner or an
   open handle.

### Claude Code floor

`trellis doctor` warns when the installed Claude Code is below **2.1.295**
(1.3.21 warned below 2.1.294), the first version whose `onFailure` field and
exec-form hooks the rendered settings use. It is a WARN, never a failure. Below
2.1.295 (or when `claude --version`, run with the forwarded caller `PATH`,
cannot be read) the renderer emits the legacy pre-exec shell-form hook wiring
without `onFailure`; the guard supervisor still blocks on a crash or timeout,
so the slower wiring is equally safe, and `doctor` accepts the form matching
the client. Upgrade Claude Code first, then re-render, so the render picks up
exec form and `onFailure: "block"` on the three enforcing PreToolUse guards.

### Measure with `trellis bench`

`trellis bench` copies the active installed release into a private sandbox,
attaches a fixture project there, and times hooks, lifecycle routes and,
optionally, a battery. It only reads your store. Run it under `trellis heavy`
when the numbers matter, at normal load (load average below the core count, no
battery running):

```sh
trellis heavy --lane bench -- trellis bench --suite hooks,lifecycle --n 30
```

Sandbox setup installs and attaches a release before timing anything, which
takes minutes. Receipts land in the current directory (or `--out DIR`) as
`bench-<date>-<label>.{json,md}`; home, temp and
user strings are replaced with tokens and PATH is recorded as counts, so a
receipt can be shared. Add `--suite gate --gate-tsv <aggregate.tsv>
--gate-wall <seconds>` to summarize a battery. The launcher forwards your PATH
to `bench` only from 1.4.0, so reinstall it first or hooks are timed under the
sanitized control PATH.

### Optional host settings

Trellis does not change these, and no 1.4.0 target depends on them. `doctor`
checks Spotlight indexing on the worktree root and reports `stop_checks.fast`
(INFO when active, WARN when ignored); it does not inspect macOS Developer
Tools.

- **macOS Developer Tools.** Add your terminal (and any multiplexer that starts
  agents) under System Settings → Privacy & Security → Developer Tools. Without
  it, Gatekeeper and XProtect scan every new executable on first exec, about
  340 ms each, which test stubs and fresh scripts hit constantly.
- **Spotlight.** Exclude the worktree root under System Settings → Spotlight →
  Search Privacy. Current macOS ignores a `.metadata_never_index` file, so the
  sentinel alone does not stop indexing.
- **A faster Stop suite.** `stop_checks.fast` in the machine config; see
  [Optional host setting: a faster Stop test step](#optional-host-setting-a-faster-stop-test-step).

### What changes for agents

- **`hc` only (spec 073) and the retired Muse routes.** Trellis drives Herdr
  only through `hc` (`HC_SCOPE` and `HC_TERMINAL_ID` set); `HERDR_ENV`,
  `HERDR_PANE_ID`, `HERDR_WORKSPACE_ID` and the `herdr` CLI (`0.9.x`) are gone.
  `foreman-start.sh <worktree> <brief-file> [name]` launches the pi foreman
  with one `hc run --bg` as a sub-agent of the calling terminal, passing the
  brief as pi's initial message and binding
  `~/.pi/agent/sessions/trellis-dispatch/<dispatch-id>.jsonl` before launch.
  `--tab`, direction arguments and `foreman-prompt.sh` are removed; workers
  report and ask questions with `hc send <apex> "<text>"`, and the apex waits
  with `hc wait --children`. Delegated agents appear under their apex in the
  app's Agents sidebar without splitting panes. Inside an `hc` terminal, the pi
  cross-family review rung, scoped role decisions and the foreman `SessionStart`
  context run again. Muse (`cheap`, `cheap-1`, `cheap-2`, `muse-meta`) and
  `glm-flash` are removed from the `herdr-foreman` catalog and chains, the
  `cheap-*` and `muse-meta-*` pi agent files are deleted, `argon` runs on
  `antigravity/gemini-4-argon:high` at the head of `reviewer`, and `Explore`,
  `Plan` and `general-purpose` route to Haiku (`docs/adr/2026-11-01-retire-muse.md`).
- **Stop reuse (spec 072).** A passing Stop is reused — and the DoD line says
  so — only while the tree, the raw exported environment (all of it except
  `PWD`, `OLDPWD` and `_`), each check's argv and the identity of every tool it
  runs are unchanged, so a new harness session or any changed input reruns the
  checks once. Reuse applies only to checks run by a listed native interpreter
  (`node`, `nodejs`, `python*`, `perl*`) or an in-worktree script invoked
  through a `#!` naming one of those interpreters or an exact `pnpm` 8–11 shim
  in its own directory (covering `tsc`, `eslint` and `vitest` from
  `node_modules/.bin`, and `pytest` and `mypy` from `.venv`); shell scripts are
  never parsed, any other native tool (such as native `ruff`) gets a full run,
  and `cargo`, `go` and `rustc` checks always rerun. Only a run in which every
  check passed writes a receipt, and only if the full key still matches
  afterwards. When checks run, typecheck, lint and tests run concurrently. The
  pre-push and merge gates never read Stop receipts, and an optional host-only
  `stop_checks.fast` in `$TRELLIS_HOME/config.json` is never reused.
- **The queue and gate (spec 072).**
  - A second local battery queues (under `$HOME/.local/state/trellis-gate`
    regardless of `XDG_STATE_HOME`) and prints its position, the holder's head
    and an estimated start instead of failing `state busy`. Queue wait does not
    count against the run deadline; pass `--no-wait` to keep the fail-fast exit
    `70`.
  - `trellis heavy --lane process-gate --light` now exits `2`; gates need the
    reserved heavy slot. A gate started inside an ordinary `trellis heavy` or
    `--light` wrapper also exits `2` before admission; start it directly.
  - On push, a hard cheap-row failure (secrets, bypass, stack, security or
    anti-slop) refuses before the battery and Tests shows `n/a`. Merge runs
    every row as before.
  - The Tests row reuses a runner-written verdict (up to seven days old) only
    when all bound inputs match, printing the reused run's id and date.
    Branch-only pushes on projects that declare `PROCESS_GATE_TEST_MAP` in the
    range base can narrow to mapped test files (`Tests: narrowed: M selected`);
    tag, mixed and merge gates always run the full suite. A project whose full
    battery already runs the gate's typecheck and lint can declare
    `PROCESS_GATE_TEST_COVERS_STATIC` in its process-gate config to skip the
    duplicate run in full-battery mode.
  - The local gate runner `scripts/run-tests-local.py` is macOS-only (its
    process containment uses `libproc`, unchanged since 1.3.x) and launches
    nothing on Linux. On Linux, run Bats suites directly, or use
    `scripts/trace-full-battery.sh`, which needs `strace`.

### Roll back

Rollback is the reverse adoption plus the 1.3.21 launcher. Before it, delete
any `projects` key from `config.json`: 1.3.21 validates the machine config as a
closed object and refuses it.

```sh
(
  set -e
  ROLLBACK_RELEASE=1.3.21
  : "${TRELLIS:=trellis}"
  "$TRELLIS" release verify "$ROLLBACK_RELEASE"
  "$TRELLIS" release adopt "$ROLLBACK_RELEASE" --all
)
```

Then reinstall the 1.3.21 launcher with the same
[launcher procedure](#reinstalling-the-launcher), `TARGET_RELEASE=1.3.21`. The
1.4.0 launcher can still run the 1.3.21 payload in the meantime, from a
per-run verified copy, because that payload does not declare the snapshot
capability. A project re-rendered under 1.4.0 keeps that render; restore the
1.3.21 render with the detach/attach pair and `--release 1.3.21`. Keep 1.4.0
installed; its stamps and snapshot stay until `disk-janitor --scopes
release-tmp` finds the release uninstalled.

## Optional host setting: a faster Stop test step

From spec 072, the Stop hook can run a faster suite in place of its detected
test step (`npm test`, `pytest`, `cargo test`, `go test ./...`) for a project
you name. It is a host setting only, in the machine config, never in the
repository: a `stop_checks` key in `.trellis.json` or anywhere else in the
checkout is ignored, because a same-user agent can write it.

```json
{
  "projects": {
    "/Users/you/projects/app": { "stop_checks": { "fast": "pnpm vitest run --changed" } }
  }
}
```

- The key is the physical path of the project's main checkout (`pwd -P` in
  it); linked worktrees of that project use the same entry.
- The value is one line of 1–1024 printable characters. It runs from the
  project root. Typecheck and lint still run, a fast run is never reused and
  never writes a pass receipt, and the pre-push and merge gates ignore it.
- It is honoured only while `config.json` is a regular file you own with mode
  0600 or stricter, in a directory with no group or other write bit. Anything
  else, or a malformed value, runs the detected suite and says so in the Stop
  advisory. `trellis doctor` lists projects with a fast suite (INFO) and warns
  when the hook would ignore one.
- Add `projects` only once both `active_cli_release` and the stable launcher
  are on a release that accepts it. Older CLIs validate `config.json` as a
  closed object and stop with `machine config failed schema-aware validation`.
  Remove the key before rolling back to such a release.

Edit the file without loosening its mode:

```sh
(
  set -e
  : "${TRELLIS_HOME:=$HOME/.trellis}"
  root="$(cd /path/to/project && pwd -P)"
  tmp="$(umask 077 && mktemp "$TRELLIS_HOME/.config.XXXXXX")"
  jq --arg r "$root" --arg c 'pnpm vitest run --changed' \
    '.projects[$r].stop_checks.fast = $c' "$TRELLIS_HOME/config.json" > "$tmp"
  mv "$tmp" "$TRELLIS_HOME/config.json"
  trellis doctor
)
```

To stop using it, delete `projects.<root>.stop_checks` (or the whole
`projects` key) the same way.

## `1.3.19` → `1.3.20` adoption

1.3.20 repairs managed-exclude owner metadata left by **any group adoption run
by a CLI older than 1.3.20**, whether or not the release's block changed. Older
CLIs recorded the live file as every owner's after-image; a non-manager must
instead retain its own before-image. Changed blocks or surrounding user edits
can therefore leave `show-config` / `doctor` exiting `4` with
`owner after-image does not exactly derive from its immutable block and recorded
user bytes`. Identical release manifests do not rule out this fault.

1. Inspect the intended registry scope and **deregister confirmed dead worktree
   rows before re-adoption**. Complete committed-owner coverage is required;
   do not delete records for an unavailable volume or guess that a row is dead.
   For each operator-confirmed dead path, use
   `trellis registry deregister --fleet <fleet> --worktree-root <dead-path>`.
2. Install and verify 1.3.20 through the stable launcher, then **switch
   `active_cli_release` to 1.3.20 before invoking adoption**. The launcher runs
   `release.sh` from the active management CLI, not the adoption target. Merely
   installing 1.3.20 and adopting with the active CLI still at 1.3.19 runs the
   old planner and does not deliver the repair.
3. Re-adopt the reviewed scope, then require `trellis doctor --fleet <fleet>`
   for each selected fleet and `trellis show-config` in each affected live
   worktree to exit `0`.

After the dead-row review/cleanup, the stepwise all-fleet route is:

```sh
(
  set -e
  TARGET_RELEASE=1.3.20
  : "${RELEASE_REMOTE:?Set the remote containing annotated tag v$TARGET_RELEASE}"
  : "${TRELLIS:=trellis}"
  : "${TRELLIS_HOME:=$HOME/.trellis}"
  export TRELLIS_HOME
  "$TRELLIS" release install "$TARGET_RELEASE" --remote "$RELEASE_REMOTE"
  "$TRELLIS" release verify "$TARGET_RELEASE"
  "$TRELLIS" configure --home "$TRELLIS_HOME" --release "$TARGET_RELEASE"
  "$TRELLIS" release adopt "$TARGET_RELEASE" --all
)
```

Use `--fleet NAME` or `--project ID --fleet NAME` instead of `--all` for narrower
scope. If 1.3.20 is already installed, verify it rather than reinstalling it;
the active-CLI switch must still precede adoption. Project attachments do not
switch merely because the management CLI changes. Re-adoption rebuilds stale
non-manager after-images from their unchanged restoration snapshots and
preserves live user bytes; **no detach/fresh attach is needed for this fault**.

After a block-changing adoption, a non-manager may report `exact immutable
native-surface block matches; surrounding user bytes drifted`. This is
informational (`HC_OK`), not damage or a reason to edit its restoration snapshot.

## `1.3.18` → `1.3.19` adoption

1.3.19 hardens the Pi hook-directory migration. Adoption removes an empty
`.pi/hooks` or `.pi/hooks/lib` directory only when the old owner record owns
that directory as a parent. Pre-existing, unowned directories stay in place
with the operator-action notice; move them out yourself to stop Pi's startup
warning. Interrupted adoption restores owned directories with their exact
previous modes, including distinct non-default modes.

Rolling back to a release that declares `.pi/hooks` links (1.3.17 or older)
after those owned links have been retired now refuses in preflight with exit
`3`, before changing the checkout's owner, runtime anchor or shared exclude.
The error names the checkout and prints the exact `detach` and `attach`
commands for the target release, preserving its fleet and harness selection.
Follow those commands for each affected checkout, then run `doctor`; an
ordinary reverse pin move cannot recreate the retired links. Forward adoption
still does not add newly declared project leaves, as described in the
Criterion 6 notice above.

## `1.3.17` → `1.3.18` adoption

1.3.18 stops rendering `.pi/hooks`. Pi treats that directory as a deprecated
resource and waits for a keypress at startup while it exists, even empty, so a
prompt sent too early was lost. The Pi dispatcher now runs the release-owned
Codex hook set straight from the attachment's runtime payload
(`.trellis/runtime/core-rules/codex/hooks`); the hooks and their behavior are
unchanged.

Adoption alone delivers it; no detach or fresh attach is needed. For every
Pi-attached checkout, `release adopt` retires the owned `.pi/hooks` links and
then removes the emptied `.pi/hooks/lib` and `.pi/hooks` directories. An
interrupted adoption restores both the directories and the links. If the tree
holds anything Trellis does not own, adoption leaves it in place and prints
`left in place: <root>/.pi/hooks holds files Trellis does not own`; move those
files out and Pi stops warning. Fresh attaches and `trellis worktree sync`
never create `.pi/hooks`.

Doctor and the bypass check still require `.pi/hooks/dispatch.sh` for a
checkout pinned to an older release, because that release declares it.

**Exclude-record caveat.** The 1.3.18 CLI could retire a singleton's links but
retain the old block listing `/.pi/hooks/*`, yielding `owner block does not match
the exact immutable native surface plan`. Separately, any group adoption by a
CLI older than 1.3.20 can leave non-manager after-images stale, block change or
not. See [1.3.19 → 1.3.20 adoption](#1319--1320-adoption) for the active-CLI-first
repair instead of detaching a healthy group. A lone non-manager still refuses
when its block needs re-planning: restore missing committed manager ownership;
never promote the surviving owner or replace its restoration snapshot.

## `1.3.16` → `1.3.17` adoption

1.3.17 updates runtime hooks and the managed pre-push dispatcher without adding
rendered leaves or changing settings. Existing 1.3.16 attachments need only a
scoped pin move: **no detach or fresh attach is required**. Installation and
configuration do not implicitly adopt projects.

Install, verify and activate the exact published release through the stable
launcher:

```sh
TARGET_RELEASE=1.3.17
: "${RELEASE_REMOTE:?Set the remote containing annotated tag v$TARGET_RELEASE}"
: "${TRELLIS:=trellis}"
: "${TRELLIS_HOME:?Set TRELLIS_HOME (or export it) before configuring}"
"$TRELLIS" release install "$TARGET_RELEASE" --remote "$RELEASE_REMOTE"
"$TRELLIS" release verify "$TARGET_RELEASE"
"$TRELLIS" configure --home "$TRELLIS_HOME" --release "$TARGET_RELEASE"
```

Then use `release adopt "$TARGET_RELEASE"` with the reviewed `--project`,
`--fleet` or `--all` selector and verify the selected rows with `doctor`.

The pin move delivers:

- The SessionStart payload-symlink fix for false "Trellis attachment is missing"
  warnings in attached worktrees.
- Root `CLAUDE.md` and `AGENTS.md` exemptions from the spec-gate's gated diff;
  nested instruction files remain counted.
- Durable daily usage-store data checks rather than full scans on every open;
  creation/migration checks, per-open schema/version checks and failed-scan
  refusals remain. No retention or data-pruning change is included.
- Pending-adoption refusal before the chained pre-push suite, while retaining
  carrier and pending-operation rechecks after it.
- A distinct `verification unavailable: dependencies not installed` advisory
  for absent JS installations in Claude/Codex Stop verification, without
  suppressing genuine installed-project failures or receipt/Todo gates. This
  does not change which checkout Stop verifies.
- Byte-exact Pi read results for capability-only notices, delivered separately
  once per session; genuine context and warn/deny advisories are unchanged.

### Repair older private-gate pnpm installations

Worktrees whose dependencies were installed under the gate's private pnpm
config before 1.3.16 can fail `verify-deps-before-run`: that private config had
`enableGlobalVirtualStore` unset, whereas 1.3.16 mirrors the user's `true`.
Adoption alone does not repair the existing installation. In each affected
worktree, run this one-time migration from the **normal shell**:

```sh
cd /path/to/affected-worktree
pnpm install --frozen-lockfile
```

Never install dependencies under the gate's private config. Do not use a gate
invocation to perform this repair.

### Fresh-worktree dependency recipe

After `trellis worktree add <branch>` creates and attaches the new worktree,
enter the reported path in the normal shell and install without lifecycle
scripts:

```sh
cd /path/to/new-worktree
pnpm install --frozen-lockfile --ignore-scripts
```

`--ignore-scripts` prevents Husky's `prepare` from resetting the checkout group's
shared `core.hooksPath`. Never install under the gate's private config.

### Known issue: Pi startup keypress

Fixed in 1.3.18. The rendered `.pi/hooks` directory is still present in 1.3.17. Pi may print
"Hooks have been renamed to extensions" and wait for a keypress. At startup,
dismiss that prompt and **wait for Pi's footer before sending the first
prompt**; a prompt sent earlier may be lost. Do not delete managed hooks as a
workaround. The directory fix is deferred to the next release; this release
does not migrate it.

## `1.3.15` → `1.3.16` adoption

For the Docker endpoint and hooks-path fixes, use the install, verify,
configure and scoped release-adopt steps below with `TARGET_RELEASE=1.3.16`
after the release is published. Adoption updates the managed dispatchers;
passthrough shim bytes are unchanged, so these fixes do not require a detach
or fresh attach.

### Recover a husky-reset hooks path with an unattached sibling

If husky's `prepare` reset the shared `core.hooksPath` to `.husky/_`, run
`trellis doctor --fix --project <project-id>` for the owning checkout's
project. The guarded repair still verifies its recorded owner and dispatcher,
but an unattached sibling no longer blocks restoring the managed hooks path.
Run each printed `trellis worktree sync <sibling-path>` command afterward.
The shared dispatcher refuses that sibling's pushes until it is synced;
doctor does not silently attach it or weaken donor verification.

Session start now prints an exact, shell-quoted restore command when the live
hooks path equals the recorded previous value rather than the managed path.
This is a warning, not an automatic write; prefer the guarded doctor repair.
Other hooks-path drift still requires inspection rather than an unconditional
restore.

### Archive an orphaned project attachment journal

After activating 1.3.16, an operator can archive one prepared attach or detach
journal whose recorded worktree root has vanished, using a surviving root of
the **same checkout**:

```sh
trellis recover --discard-orphan-journal <attachment-uuid> <surviving-checkout-root>
```

This works at any journal phase, but refuses a live root, any remaining owner
record, a live transaction/publisher, foreign checkout identity, unsafe paths
or writes outside the vanished root. If the journal owned shared exclude or
hooks state, another committed owner must verify both the current managed
exclude block and dispatcher exactly. Partial-harness registry changes are
not eligible. On refusal, restore the recorded root and use normal
`trellis recover`; do not hand-delete the journal or edit registry JSON.

The command clears only that exact registry `attachment_id`, retaining the
inventory row. It then moves the journal and any progress log, preserving
bytes and modes, to
`$TRELLIS_HOME/backups/discarded-journals-<UTC-YYYY-MM-DD>/` (the default home
is `~/.trellis`). It prints the retained paths and never overwrites an existing
archive. It does not replay project writes, repair shared state or detach
another owner. Ordinary `recover` still requires a live recorded root.

### Refresh the process-audit task

After activating 1.3.16, re-materialize `cross-project-process-audit` for each
scheduled fleet:

```sh
trellis task materialize --fleet <fleet> cross-project-process-audit
```

Existing materialized prompts remain pinned to their old release until
refreshed. The updated audit accepts either root
instruction document and the verified managed hooks stack; it does not change
audited projects or disable unmanaged-hook checks.

### Refresh pi roster copies and use delivery receipts

After scoped release adoption moves a project's `.trellis/runtime` pin, its
managed `.agents/agents` links follow the updated roster without re-attachment.
Separately copied rosters need an attended refresh from the 1.3.16 definitions
before starting a new pi session. Preserve project-authored changes; the
launcher still refuses differing files rather than blindly overwriting them.
Writable profiles now omit `isolation`, so select `off` or `worktree` at each
invocation instead of relying on a forced agent-file setting. Read-only
profiles still explicitly select `off`.

`foreman-prompt.sh` now submits once and reads a status snapshot without waiting
for turn completion. Use the brief's callback/artifact receipt to establish
completion; do not resend because the snapshot is `idle`. If status retrieval
fails after submission, inspect the session before retrying: the brief may
already have arrived.

### Gate pnpm settings and interrupted detach

Scoped adoption updates the managed dispatcher. It mirrors only the user's
global pnpm `enableGlobalVirtualStore` boolean into the private gate config;
workspace overrides still win, and an unset user value removes a stale private
override. No user rc, credential store or caller HOME is forwarded to the gate.
If the setting cannot be read, the gate warns and continues on pnpm's default.

After a registry-contention failure (exit `5`), retry `trellis recover <root>`
through 1.3.16 with the recorded root present. Other checkouts' stale journals
no longer block that recovery and remain untouched. New full detaches clear
the exact registry attachment ID before owner unlink: a timeout retains the
owner and journal, and an already durable clear can finish without waiting on
another registry writer. Existing ownerless journals remain retryable, not
silently discarded. If the recorded root has vanished, use the guarded orphan
archive command above; do not hand-delete state or a live lock.

### Declare gate environment and Semgrep timeout in a manifest PR

Merge the needed fields into the project's existing `.trellis.json` in a small,
reviewed PR **before** relying on them in a code push:

```json
{
  "gate": { "env_passthrough": ["A31_REQUIRE_DOCKER", "A31_BASE_SHA"] },
  "security_gate": { "semgrep_timeout": 120 }
}
```

The managed dispatcher reads env names only from the local protected
`origin/HEAD` commit, never the candidate or working-tree manifest. Export the
listed values in the pushing shell; explicitly empty values remain set and
unset names stay absent. Only the gate payload and its heavy child inherit
them, not prior hooks or the control interpreter. Secret-looking names and
startup/control names or namespaces are denied, including caller internals,
locale, Docker config, Git, Trellis, Python, Perl, Ruby and loader controls.
Do not place credentials in an allowlisted value. Missing protected authority
or invalid env config forwards no custom values; no network lookup is made.

`security_gate.semgrep_timeout` is an integer from 1 through 600 seconds. The
security gate reads it from the gated range BASE, overriding the older timeout
setting; candidate/worktree edits cannot change their own scan. Use a range
whose base already contains the reviewed setting. The existing default remains
when the field is absent, and incomplete scans still block.

## `1.3.14` → `1.3.15` adoption

1.3.15 changes hook, resolver, gate and roster code inside the release payload. Attached projects run hooks through the `trellis hook` launcher from their pinned release, and no rendered surface changed: no manifest, settings, managed exclude block or owned-leaf changes. **No re-render, detach or fresh attach is needed** for projects already on 1.3.14; moving their pins is enough.

Install, verify and activate the exact published release through the stable launcher:

```sh
TARGET_RELEASE=1.3.15
: "${RELEASE_REMOTE:?Set the remote containing annotated tag v$TARGET_RELEASE}"
: "${TRELLIS:=trellis}"
: "${TRELLIS_HOME:?Set TRELLIS_HOME (or export it) before configuring}"
"$TRELLIS" release install "$TARGET_RELEASE" --remote "$RELEASE_REMOTE"
"$TRELLIS" release verify "$TARGET_RELEASE"
"$TRELLIS" configure --home "$TRELLIS_HOME" --release "$TARGET_RELEASE"
```

Then move pins with `release adopt "$TARGET_RELEASE"` and the reviewed `--project`, `--fleet` or `--all` selector. Install the user-level pi extension copy (`~/.pi/agent/extensions/opencode-go-2.ts`) from the release so pi registers the new Go 2 models; `scripts/pi-guide-parity.sh` reports a stale copy.

## `1.3.13` → `1.3.14` adoption

1.3.14 only neutralizes test fixture names for public mirror publication and
updates release documentation. The runtime code and policy payload are
identical to 1.3.13 apart from the version file: no manifest, rendered settings
or owned-leaf changes. **No re-render, detach or fresh attach is needed** for
projects already on 1.3.13.

Install, verify and activate the exact published release through the stable
launcher:

```sh
TARGET_RELEASE=1.3.14
: "${RELEASE_REMOTE:?Set the remote containing annotated tag v$TARGET_RELEASE}"
: "${TRELLIS:=trellis}"
: "${TRELLIS_HOME:?Set TRELLIS_HOME (or export it) before configuring}"
"$TRELLIS" release install "$TARGET_RELEASE" --remote "$RELEASE_REMOTE"
"$TRELLIS" release verify "$TARGET_RELEASE"
"$TRELLIS" configure --home "$TRELLIS_HOME" --release "$TARGET_RELEASE"
```

Optionally use `release adopt "$TARGET_RELEASE"` with the reviewed `--project`,
`--fleet` or `--all` selector to move existing attachment pins to 1.3.14.
Installation and configuration do not implicitly adopt projects. Machines
still on an earlier release must follow the 1.3.13 render/migration steps below;
this patch does not replace that upgrade.

## `1.3.12` → `1.3.13` adoption

1.3.13 changes where worktrees live and how the janitor treats them, so **a fresh render is needed to deliver it**. The release adds the worktree-convention render (`trellis worktree add` refuses paths outside the central root); the user-surface pieces (Claude Code `WorktreeCreate`/`WorktreeRemove` hooks, single-delivery skills) arrive with install plus `configure`, the pi bash guard with `AGENT_PI_SETUP.md` step 2, and the pnpm setting with `trellis doctor --fix` — detach/attach alone does not re-render those (`core-rules/inheritance.md` §6). Until a group is re-attached it keeps 1.3.12's worktree locations, which doctor reports as layout warnings rather than failures.

On every machine, in this order:

1. Install, verify and activate 1.3.13 (same commands as 1.3.12 with `TARGET_RELEASE=1.3.13`). The install plus `configure` relinks the user surface: WorktreeCreate/WorktreeRemove hooks and single-delivery skills. Install the pi bash guard per `AGENT_PI_SETUP.md` step 2.
2. Set `worktrees.known_parents` (default is the measured parent list) and `worktrees.push_owners` in machine config; run `trellis doctor --fix` for the pnpm dep-sharing row.
3. Point the Codex app at `~/projects/worktrees/_codex` in its Settings → Worktrees (GUI, owner step) — before migrating, since un-repointed roots are held.
4. Detach and attach each **entire checkout group** fresh at `--release 1.3.13`, one group at a time, manager first with the group's recorded `--harness` flags.
5. `trellis worktree root-init` once (creates `~/projects/worktrees` with the Spotlight/Time Machine exclusions).
6. `trellis launchd --with-pi-watchdog` for the report agent plus the truncate-only watchdog. Do NOT enable nightly `--with-apply`; that stays an owner decision.
7. Run `trellis worktree migrate` (dry run) and review the plan. Do not `--apply` machine-wide without owner review (`--only <path>` limits apply to one path; remove/move/preserve wait for review of the dry run).

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
2. From a clean checkout of the approved release commit, run
   `bash scripts/check-mirror-preseal.sh` before building or tagging. This
   mandatory pre-seal check runs the real mirror lint over a disposable staged
   replica of the working tree, including published tests, the publisher's
   allowlist/exclusions, manifest projection and empty fleet-data shells. It
   refuses findings, changed extraction boundaries or an incomplete stage
   (fewer than 1,000 regular files or a missing sentinel). It never opens the
   installed release or mirror checkout. The lint requires the operator's
   registry; `TRELLIS_MIRROR_IDENTITY_SOURCE=/path/to/registry.json` selects an
   explicit offline copy. Never substitute a synthetic registry for a real
   release. Fix findings in source and recut; immutable releases cannot be
   repaired in place.
   Then run the off-main tag consumer gate:
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
| `5` | Unavailable path, remote, local capability, or registry lock after bounded retry | Keep the row explicit; restore the capability/path, or wait for the reported lock holder to finish, then retry. Never delete a live lock. |

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
