# Portable attachment and inheritance

This document defines the local attachment contract for Trellis. It supersedes
tracked direct links into a live control-plane checkout and Trellis-managed
`@`-imports. The installed release's
`core-rules/inheritance-manifest.json` is the machine-readable authority for
native leaves; this document explains its ownership and recovery rules rather
than a command interface.

## 1. Two project surfaces

### Primary portable surface — `.trellis.json`

The only Trellis-controlled **tracked** project state is `<project>/.trellis.json`.
It contains portable identity and policy, such as `project_id`, presets,
autonomy, package-manager policy, loop safety, and gate declarations. It MUST
NOT contain a checkout path, fleet, `TRELLIS_HOME`, source root, installed
release, or attachment/harness state.

A manifest-only clone is intentionally inert. It has no Trellis-generated
native links, settings, hooks, exclusion block, registry entry, warning, or
runtime discovery requirement. Project-owned `CLAUDE.md`, `AGENTS.md`,
`.claude/`, `.agents/`, and `.codex/` content remains project-owned
unless a concrete leaf is recorded by an attachment.

### Secondary local surface — explicit attachment

Attachment is an opt-in, machine-local transaction. Its configuration,
inventory, releases, journals, attachment records, and clone-local hook
dispatcher live below private `TRELLIS_HOME` (default `~/.trellis`), never in
project Git history. The local registry records fleet membership and checkout
locations; it is an inventory index, not the portable identity authority.
Selected-root discovery can rebuild that index from `.trellis.json`.

There is no tracked fleet inventory. The compatibility release's `registry.md`
and `blacklist.md` were removed at `v1.0.0-rc.25`; `trellis registry import`
still reads a Markdown roster the operator supplies from their own history or
backup, and that is the only role those filenames retain. A project becomes
active only after an explicit attachment records it locally.

## 2. Immutable runtime topology

Every attachment has one local absolute anchor and relative native leaves:

```text
<project>/.trellis.json                         tracked, inert
<project>/.trellis/runtime
  -> <TRELLIS_HOME>/releases/<version>/payload  local absolute symlink
<project>/<managed native leaf>
  -> relative path through .trellis/runtime/... local relative symlink
```

The anchor MUST resolve to a verified, read-only installed release payload.
Release installation verifies the recorded release identity and payload tree;
an existing release directory is never silently replaced. A release change is
an explicit, verified adoption that atomically changes the anchor. Attachment,
detach, doctor, recovery, and relink use the release recorded by ownership
state rather than a latest-version guess.

The source checkout is for management and publication only. It is never an
attached project's runtime authority: dirtying it, changing its branch,
moving it, or losing it cannot alter an existing attachment. A managed leaf or
runtime anchor that resolves into a source checkout is corrupt, not a fallback.
There are no Trellis-managed absolute source links, copied policy trees, or
parent `@`-imports in the portable layout.

Most managed links reach release content through the relative runtime anchor.
The project-context leaf `AGENTS.md` instead links
relatively to a regular project `CLAUDE.md` when one exists; otherwise it uses
the immutable runtime fallback. Attachment never creates or overwrites the
project's root `CLAUDE.md` to make that choice possible.

## 3. Manifest-owned native leaves

The release payload's `core-rules/inheritance-manifest.json` is the sole list
used by attach, detach, diagnosis, and worktree reconciliation. It expands
concrete child entries at planning time; no script or runbook may maintain a
second hard-coded leaf list.

The current manifest separates primary context leaves from secondary discovery
and lifecycle leaves:

| Harness | Primary context leaves | Secondary manifest leaves and renders |
|---|---|---|
| Claude Code | `.claude/rules/trellis.md` | eligible skill directories, command and agent Markdown files, executable hook and hook-library files, `.claude/primers/INDEX.md`, and the optional local settings JSON render |
| Codex | `AGENTS.md`; `.agents/rules/trellis.md` | eligible skill directories, command, pi agent and workflow Markdown files, Codex hook and hook-library files, named shared hook-library leaves, `.agents/primers/INDEX.md`, and the optional Codex hook JSON render |

“Owned” always means an exact expanded leaf, its recorded kind, and its
recorded target, content hash, and mode where applicable. It never means a
whole harness directory. For example, a recorded
`.claude/commands/example.md` does not give Trellis ownership of a sibling
project command or of `.claude/commands/` itself. Parent directories are only
transaction-owned when attachment created them, and may be removed only when
empty. The release manifest, not this summary table, decides the exact current
leaf set.

### Skill path-scoping (project-local skills only)

Release-owned skills are global by design: they are workflow-shaped, not
language-shaped, so they apply to the whole repository regardless of which
subtree is being edited. A **project-local** skill — one the project owns, not a
manifest-owned leaf — may opt into path-scoping by carrying a `scope.json` next
to its `SKILL.md`:

```json
{
  "paths": ["services/**", "pkg/**"],
  "reason": "Go-only validators; would noise non-Go subtrees"
}
```

When `scope.json` is present, the agent reads it at session start and
auto-mentions the skill only when the session's working tree, or this turn's
changed files, falls under at least one listed glob. Explicit `/skill <name>`
invocation still works from any path; the scope controls auto-invocation only.

This is a Trellis convention, not a harness engine feature. Agents honour it
because every attached project loads the parent policy, which directs
scope-respecting behavior. A release-owned skill must never carry a
`scope.json`: wanting one means the skill is mis-shaped, and it should be split
into a workflow part (released, global) and a stack-specific part
(project-local, scoped).

## 4. Silent-drop and inert-contributor invariants

Harnesses can silently omit a missing, dangling, or malformed context, skill,
command, or extension leaf. That makes a broken attachment a correctness
failure even when a harness emits no useful error. Attachment therefore has no
fallback to a mutable source tree, copied policy, a parent `@`-import, or a
same-named project file.

Before mutation, attachment expands the verified payload manifest and checks
every planned destination and parent component. It rejects unsafe paths,
symlinked parents, duplicate destinations, paths outside the project boundary,
and any project-owned collision. Existing attachment state is idempotent only
when every recorded artifact and shared local state still matches exactly.
Otherwise it is a conflict, not permission to overwrite or repair by guesswork.

The inverse is equally important: absence of all local attachment artifacts in
a raw or manifest-only clone is expected and MUST NOT create a Trellis warning,
hook invocation, policy injection, or discovery failure. Diagnosis distinguishes
that inert state from a locally recorded attachment whose leaves are missing or
modified.

## 5. Transaction and ownership record

A successful attachment records its fleet, project ID, clone identity, worktree
identity, release, selected harnesses, exact artifacts, rendered-file state,
managed exclude state, and prior hook configuration under
`$TRELLIS_HOME/state/attachments/`. A journal is durable before mutation.
Writes use private temporary siblings and atomic replacement; a failed
transaction rolls back only artifacts it created.

The planner refuses a collision before it writes any leaf, and every refusal
names the path it refused. A regular project file, directory, symlink, rendered
file, hook configuration, or managed block that does not exactly match a
recorded attachment is project-owned or corrupt and MUST be preserved. Neither
attach nor recovery may delete it as a shortcut.

Three shapes are deferred to the project rather than refused, and only these
three. A `render_if_absent` render whose destination already exists is a seed
the project has since authored — `.claude/primers/INDEX.md` and
`.agents/primers/INDEX.md` are seeded that way, and `core-rules/primers.md`
makes the live file project content. A destination that is already the exact
symlink the plan would create — link text byte-for-byte equal to the planned
target — is the attachment's own goal state, not foreign content. A symlink
destination holding a project-authored regular file is the project's own
document, and the same doctrine applies: a project that writes its own
`AGENTS.md` keeps it, rather than losing the whole harness. That third shape is
deliberately narrow — an empty file, or one byte-for-byte identical to a
canonical source, is a dropping rather than authored content and stays a named
refusal. All three are recorded on the owner as `pre_existing`, are absent from
the artifact list and from the managed exclude block, and detach never removes
them. Diagnosis re-derives the same decision from the immutable manifest and
the checkout instead of trusting the record.

Legacy migration holds the same ownership floor with the weaker evidence it
has, and the project-context leaf keeps the asymmetry of its own link rule. A
regular-file root `AGENTS.md` is removed only when its bytes match the
project's own `CLAUDE.md`. Any other content is authored:
migration leaves it in place, does not conflict over it, and names every
left-alone path, because bytes materialized by a release the run cannot compare
against are indistinguishable from a project's own document.

A managed `info/exclude` block is powerless where a tracked `.gitignore`
negation re-includes the same path, because `.gitignore` outranks
`info/exclude`. Attach therefore refuses, before any mutation, when the winning
ignore pattern for an artifact it would create is a negation, and the refusal
names the offending `.gitignore` line. A silently dirty attached checkout is
not an acceptable outcome.

## 6. Rendered local JSON and inverse merge

A manifest `explicit-json` render is the only exception to simple
leaf-is-absent collision refusal. The current manifest uses it for local Claude
settings and local Codex hook configuration.

- The template and an existing destination MUST both be regular JSON objects.
- Attachment recursively adds only missing template leaves. A pre-existing
  template leaf, incompatible object shape, non-object JSON value, symlink, or
  non-regular destination is a collision; attachment does not choose a winner.
- Ownership stores the template leaf paths, created container paths, original
  bytes and mode when present, and the post-merge bytes, hash, and mode.
- On detach, an unchanged render restores its original bytes and mode, or is
  removed if attachment created it. If the project added unrelated keys, detach
  removes only still-exact Trellis-owned leaves and only empty containers it
  created. A changed owned value, type, mode, or path is a conflict and remains
  untouched.

This makes a local settings render additive and reversible without claiming the
surrounding JSON document.

The render helper `merge_missing` is add-only: removing a key from a template
does not remove it from an existing render. `release adopt` replays the owner
record's saved values rather than the new template's values. Template key
removal therefore needs an explicit detach+attach cycle to render the selected
release afresh; adopt and relink do not deliver that removal. A changed owned
value remains a detach conflict; resolve it without discarding the owner record
or unrelated project values before continuing with attach.

## 7. Shared Git state and managed hook chaining

Git worktrees share a common directory, so attachment writes one exact managed
block in `<git-common-dir>/info/exclude`. The block lists only the local runtime
anchor and the concrete manifest-owned artifacts. It does not own a broad
`.claude`, `.agents`, `.codex`, or `.trellis` directory and never edits
the tracked `.gitignore`.

A clone-scoped ownership manager retains that block while any attached worktree
uses it. Detaching one worktree transfers management or keeps the block;
restoration of its prior bytes occurs only after the final attached worktree
leaves. A duplicate, malformed, or modified managed block is a conflict.

Attachment also records the prior local `core.hooksPath` and installs its
absolute dispatcher below `$TRELLIS_HOME/state/git-hooks/<checkout-id>/`. The
dispatcher invokes an executable prior `post-checkout` hook with the original
arguments and inherited standard input before release reconciliation, and does
not hide a prior non-zero result. It is local clone state, not a project
artifact. Detach restores the prior hook setting and removes the dispatcher
only when both still match the record; a changed hook configuration is never
clobbered.

## 8. Clones, worktrees, and SessionStart

Registry and attachment identity are clone-scoped through the real Git common
directory, with a separate worktree record for each root. Every linked worktree
needs its own runtime anchor and native leaves even though the exclude block and
hook dispatcher are shared.

For an already opted-in clone, worktree creation and the managed post-checkout
dispatcher reconcile attachment eagerly after a real checkout, before a harness
should discover the new worktree. A raw clone, an unregistered clone, and a
worktree without a checked-out portable manifest remain inert; no hook creates
Trellis state merely because it sees a Git repository.

SessionStart is a diagnosis-only fallback, never a repair path. Harness
discovery has already run by then. The safety net reads validated local
registry and ownership metadata only; it does not follow or execute a project
runtime path, write project files, attach a worktree, or make the current
session parented. When it finds an opted-in worktree missing a valid attachment,
it reports the condition and requires reconciliation plus a fresh session.

The rendered session surfaces make that boundary mechanical. Attachment renders
each `SessionStart` entry as an invocation of the fixed launcher —
`trellis hook NAME HARNESS PROJECT_ROOT` — behind its own `env -i` boundary
carrying only `HOME`, `TRELLIS_HOME`, and a fixed `PATH`. The launcher verifies
the active release before anything executes; the verified payload's dispatcher
then resolves `NAME` and `HARNESS` against a closed route table and runs the
hook from that payload in a deliberately small environment with no `BASH_ENV`,
no `ENV`, no exported functions, no inherited Git loader or config variables,
and Git configured only by two command-scoped entries. `PROJECT_ROOT` MUST be an
absolute canonical directory; anything else is a usage error, and an
unresolvable one is unavailable. Claude Code has four routes — `session-context`,
`post-compact-context`, `inject-primer-index`, `skill-size-preflight` — and
Codex has the first three; an unsupported route is refused rather than
defaulted. A project's `.trellis/runtime` anchor is consequently data that
diagnosis reads, never a hook source anything executes.

## 9. Detach, recovery, and relink

Detach is the inverse of the recorded attachment, optionally retaining leaves
for harnesses that remain attached. It verifies each owned leaf's type, target,
hash, mode, rendered keys, exclusion block, and hook state before removal. It
removes only matching leaves; restores rendered JSON, shared excludes, and
prior hooks only at the appropriate final-owner boundary; and leaves all
project-owned bytes unchanged.

An interrupted attach or detach leaves a journal. Recovery resolves the one
matching journal from local ownership state, verifies its recorded boundaries,
and either completes the committed operation or rolls back the uncommitted
one. Ambiguous, modified, or mismatched state remains a conflict for operator
resolution rather than an automatic deletion.

Relink repairs a missing local runtime anchor only to the verified release
already recorded for that attachment. It verifies the remaining owned leaves
and shared state first, does not silently select a different release, and never
edits tracked project files. It is the repair path after a local-home relocation
or lost anchor; explicit adoption remains the only way to change release.

## 10. User-global skills

Harness skill roots hold no Trellis-copied skill bodies. Every harness refers
to Trellis-owned skill directories: a harness skill directory is either a
Trellis-managed link or it is not Trellis content at all.

There are two canonical stores. Release skills resolve only into the verified
active release payload through the manifest's `user` surface, whose link
entries each name one destination with `destination_home`. Operator and
third-party skills live as real directories only under
`$TRELLIS_HOME/skills/<name>/`; each harness discovery root holds only
Trellis-managed absolute symlinks into that store. The store is a source for
the skills command below, not a surface-plan destination. No skill body is
copied into a harness directory by Trellis.

A skill declares its harness set (`claude`, `codex`, `pi`; an absent declaration
means all three), and the set maps to native discovery roots by one table,
defined once in `scripts/lib/skill-roots.sh` and shared by the manifest
validator, the skills command, and doctor:

| Harness set | Discovery root |
|---|---|
| `claude` | `~/.claude/skills` |
| `codex` and `pi` together | `~/.agents/skills` (one shared link) |
| `pi` alone | `~/.pi/agent/skills` |
| `codex` alone | `~/.codex/skills` |

The mapping never exposes one skill twice to one harness: the manifest
validator rejects a user skill name that appears under both the shared
`.agents/skills` root and either solo root. The current release surface links
`herdr-foreman` for all three harnesses and `trellis-computer-use` (source
`core-rules/pi/computer-use`) for pi only; the validator rule and the shipped
manifest are proved together by the surface-plan suite.

Operator skills are managed by `trellis skills list|import|link|unlink`. A store
skill carries an optional `trellis-skill.json` naming its harness set; absent
means all three, and an unknown harness or an empty list is a usage error.
`import` moves one real skill directory into the store and removes other copies
of the same name in harness roots only when byte-identical, refusing and naming
differing copies before anything moves; a name already in the store or colliding
with a release user skill is refused the same way. `link` reconciles owned links
from each skill's harness set, `unlink` removes only owned links, and an unowned
existing path is never replaced or deleted. Every created link is recorded in
the Trellis-owned `$TRELLIS_HOME/state/user-skills.json` record, written
atomically under the user-surface lock with the same ownership, journal, and
inverse-detach semantics as `attach --user`.

Diagnosis is report-only. The doctor user-skill check inspects the four harness
roots and warns on real directories (stray copies, with the
`trellis skills import` remedy), dangling or foreign links, and one skill name
visible twice to a single harness under the table above. Harness-managed entries
(`~/.claude/skills/synced`, `~/.codex/skills/.system`) and dot-files are exempt.

## 11. Migration and policy boundary

The old live canonical checkout, absolute direct symlinks, Trellis-managed
`@`-imports, tracked registry/blacklist, and fixed-root clean-`main` runtime
doctrine are not part of portable attachment. They may be recognized only by
compatibility and migration tooling until cutover; they MUST NOT be created for
new attachments.

For migration sequencing and rollback, read
`docs/MIGRATING-LOCAL-FLEETS.md`. For release installation, verification, and
adoption policy, read `docs/UPGRADING.md`. The broader operator and publication
process belongs in `engineering-process.md`. None of those operational guides
changes the ownership, inert-contributor, or immutable-runtime invariants above.
