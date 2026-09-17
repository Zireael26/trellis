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
